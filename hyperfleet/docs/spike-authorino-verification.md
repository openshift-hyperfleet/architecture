---
Status: Active
Owner: Leonardo Dorneles
Last Updated: 2026-11-19
---

# Spike: Verify Authorino Revocation Delay and Issuer Enforcement for the Desire Store Gateway

**Ticket:** [HYPERFLEET-1822](https://redhat.atlassian.net/browse/HYPERFLEET-1822)
**Date:** 2026-11-17
**Related:** [Desire Store detailed design](desire-store-dd.md), [ADR-0020](../adrs/0020-envoy-authorino-api-gateway.md), [ADR-0029](../adrs/0029-desire-store-authorization.md)

## 1. Context

The Desire Store detailed design assumes several Authorino + Envoy behaviors that
are documented upstream but unverified against the version we deploy
(Authorino operator `v0.27.0`, pinned in `hyperfleet-infra`):

- Revocation takes effect within a 60-second accepted window after a binding
  `AuthConfig` is deleted, with no cache planned ([PR #248 review](https://github.com/openshift-hyperfleet/architecture/pull/248#discussion_r4319827581)
  settled that the 60 s is a tolerance bound, not a cache requirement).
- The deployed Authorino enforces the `issuer` field on JWT authentication.
- CEL evaluation errors deny rather than skip or pass.
- Post-auth local rate limiting can key on Authorino dynamic metadata
  (caller class and partition).
- The design's example `v1beta3` AuthConfig CRs work as written, and the
  Wristband reaches the upstream as a request header.
- JWKS refresh is bounded, cancellation-aware, and does not fan out across
  unrelated issuers.

A gap found during AuthConfig rendering implementation (HYPERFLEET-1831) would
force design rework, so this spike verifies the behaviors first and records
findings here.

## 2. Method

**Environment:** local kind cluster (Cilium CNI) with the `hyperfleet-infra`
gateway stack (`HELMFILE_ENV=kind`, `AUTH_MODE=EDGE+API`), mock OIDC issuer
(`OIDC_ISSUER_MODE=mock`), via `make install-gateway`.

**Deployed versions (2026-11-17):**

| Component | Version |
|-----------|---------|
| Authorino operator | v0.27.0 (pinned in `hyperfleet-infra`) |
| Authorino | v0.28.0 |
| Envoy | v1.39.1 |
| Kubernetes (kind) | v1.33+ |

Traffic was generated with sequential `curl` loops from in-cluster pods
against `http://hyperfleet-gateway.hyperfleet-local.svc:8000`, carrying
mock-issuer human JWTs. Nominal loop rates were 0.5–2 rps; effective rates
were lower because each iteration pays its own connection setup (~0.7 rps
effective on the nominal 1 rps partition-run loop). Because the API upstream was not deployed in this environment, an
**authorized request returns 503** (upstream unreachable) and a **denied
request returns 401/403/404** — the upstream never receives denied traffic, so
the status transition alone identifies revocation. Timing is captured with
`date +%s.%N` per request plus Authorino log timestamps. The API-server
partition was enforced with an `iptables` DROP rule on the kind node blocking
the Authorino pod IP → :6443.

## 3. Experiments and Results

### 3.1 Revocation delay after binding AuthConfig deletion

**Result: confirmed — healthy path well inside the 60-second window; stale
policy under partition is unbounded by Authorino and bounded only by
connectivity; recovery after connectivity returns is sub-second.**

| Scenario | Measured delay | Detail |
|----------|----------------|--------|
| Healthy control plane | **< 1 s** | The first request after `kubectl delete authconfig` (~0.5 s later at 2 rps) was denied. |
| API-server partitioned (watch dead) | **~15 min observed, unbounded** | Stale policy kept authorizing traffic for the entire partition (~15 min; ~610 requests — 589 authorized plus 23 token-expiry 401s — at ~0.7 rps effective from a nominal 1 rps sequential curl loop). The watch errored within ~19 s of the partition (`http2: client connection lost`), but re-list was blocked, so Authorino kept serving its last-known state. Denial never happened during the partition. |
| Recovery after partition lifted | **< 1 s** | The reflector was already retrying; on unblock the re-list completed and the next request (~0.5 s later) was denied. |

**Notes for the rendering story (HYPERFLEET-1831):**

- When no AuthConfig matches the request host, Authorino's ext_authz response
  surfaces to the client as **404**, not 401/403. The request is still denied
  (the upstream never sees it), but monitoring and e2e assertions must not
  expect 401/403 for the "binding removed" case.
- The design's statement that a stalled watch "can extend" the 60-second
  window is confirmed, and the extension is **unbounded** — during a silent
  partition, revocation does not take effect at all until connectivity
  returns. This matches the design's position that this is an infrastructure
  failure caught by reconciliation monitoring, not a gateway-enforced bound.
  The revocation-delay alert should therefore watch Authorino watch errors
  (visible in logs within ~20 s of a partition) rather than client status
  codes.
- Environment caveat: blocking the API server with a Cilium
  `CiliumNetworkPolicy` `egressDeny` broke DNS for the selected pod entirely
  (Cilium 1.20 appears to treat an endpoint with any egress policy as
  default-deny for egress, including `egressDeny`-only policies). The
  partition was enforced with node-level `iptables` instead.

### 3.2 Issuer enforcement on JWT authentication

**Steps:**

1. Mint a JWT with a valid signature (trusted JWKS) but a wrong `iss` claim.
2. Send it against a host whose AuthConfig pins `issuer:`.

**Result: confirmed — Authorino v0.28.0 enforces the `issuer` field at
authentication.**

The mock issuer was temporarily patched with a claim mapping that overrides
`iss` to `https://wrong-issuer.example.com`, producing a token signed by the
trusted key with a wrong `iss`. Sent through the gateway:

- Wrong `iss`, valid signature: **401**, Authorino log
  `oidc: id token issued by a different provider, expected …`.
- Control (same key, correct `iss`): authorized (503).

No fallback (enforcing `iss` in an authorization rule) is needed; the rendering
story can rely on the `issuer` field as the design's example CRs write it.

### 3.3 CEL evaluation errors deny, not pass

**Result: confirmed — CEL runtime errors deny (PERMISSION_DENIED), they do not
skip or pass.**

Tested with a dedicated `v1beta3` AuthConfig (`spike-cel-test`, host
`spike-cel-test`) carrying the design's example predicates inside
`patternMatching.patterns`. Verdicts read from Authorino's
`outgoing authorization response` log lines:

| Case | Predicate behavior | Authorino verdict |
|------|--------------------|-------------------|
| Valid token, well-formed path (`…/e/mc-01/desires`, partition at index 6) | all pass | `OK` (authorized) |
| Short path (`/desires`) — partition extraction out of range | `request.path.split('/')[6]` errors | **`PERMISSION_DENIED` — "index out of bounds: 6"** |
| Wrong-type claim used numerically (`auth.identity.org_id - auth.identity.iat`, `org_id` is a string) | type error | **`PERMISSION_DENIED` — "no such overload"** |
| Missing claim used numerically (`auth.identity.custom_age - auth.identity.iat`, `custom_age` is absent from the token) | missing-key error | **`PERMISSION_DENIED` — "no such key: custom_age"** |
| Wrong partition (`…/mc-02/…`) | predicate is false | `PERMISSION_DENIED` — "Unauthorized" |

The missing-claim case was tested in a follow-up run (2026-11-19) with a
predicate referencing a claim the token does not carry (`custom_age`): the
mock issuer cannot mint a token with
`exp` removed (its library hard-fails), and an absent claim referenced
numerically produces the same CEL error class ("no such key") that a missing
age claim would — the AC's "missing or malformed JWT age claims" case.

Notes for the rendering story:

- The design's placement of CEL predicates inside
  `authorization.<rule>.patternMatching.patterns[].predicate` is valid
  `v1beta3` syntax; there is no standalone `cel` rule type in `v1beta3`
  (CEL expressions exist in `when` predicates and `expression` selectors).
- CEL errors deny with the failing rule's message in the Authorino log, so
  they are fail-closed on their own. This does **not** remove the DD's
  mandatory path-shape checks for fleet-scoped partition extraction: the
  extraction must anchor on the `/partitions/` marker and reject malformed
  paths, including paths where the partition appears at the expected index
  without the marker. The spike's positional predicate
  (`request.path.split('/')[6]`) accepted `/a/b/c/d/e/mc-01/desires` — an
  arbitrary prefix with no `/partitions/` marker — which is exactly the
  wrong-partition-injection case the DD's shape checks exist to reject. The
  positional form was used here only to provoke evaluation errors; the
  rendering story must implement the marker-anchored, shape-rejecting
  extraction as the DD requires.

### 3.4 Post-auth local rate limiting keyed by dynamic metadata

**Result: confirmed — the pair supports local rate limiting keyed by both
caller class and partition from Authorino dynamic metadata, but not directly:
Envoy's local rate limit filter cannot match on ext_authz dynamic metadata,
so a small bridge is required.**

Working mechanism verified end-to-end on the deployed gateway:

1. Authorino emits the caller class and partition via
   `response.success.dynamicMetadata.<name>.json.properties` (static
   `value` and path-derived `expression`; verified reaching Envoy: a Lua
   filter copied them to `x-hf-caller-class` and `x-hf-partition` request
   headers, both confirmed at the upstream).
2. Route-level `rate_limits.actions[].request_headers` (header names
   `x-hf-caller-class`/`x-hf-partition`, `descriptor_key:
   caller_class`/`partition`, `skip_if_absent`) produces the descriptors.
3. `envoy.filters.http.local_ratelimit` matches the descriptors
   (`caller_class: remote-applier`, `partition: mc-01`) and applies their
   token buckets.

Burst tests (bucket of 2 per Envoy process, 2 replicas):

- **Caller-class key** (first run, `--concurrency 1`): 4 requests passed,
  then **429**; requests without the header (no descriptor) stayed unlimited
  (default bucket).
- **Partition key** (follow-up run, 2026-11-19): a 10-request burst against `mc-01` passed
  4 (bucket 2 × 2 replicas) then **429**; a 10-request burst against `mc-02`
  — same AuthConfig, same caller class, different partition descriptor —
  passed all 10. The partition key produces **independent per-partition
  buckets**, as the AC requires.

**Fail-open hazard:** the verified mechanism is fail-open. With
`skip_if_absent`, any request that reaches routing without the descriptor —
because the metadata→header bridge failed, the AuthConfig omitted
`dynamicMetadata`, or the Lua filter errored — falls into the default
bucket, which the burst test showed to be **unlimited**. A regression in
any of those components silently disables all Desire Store rate limiting
with no signal. **Additional requirement for HYPERFLEET-1829:** the gateway
must detect or bound the no-descriptor case — either a default catch-all
bucket with a tight, alerted-on limit, or an alert (metric/log) on requests
reaching routing without the expected `x-hf-caller-class` header. The
metadata→header bridge itself (the Lua filter or equivalent) must copy the
metadata-derived caller class and partition into headers before routing,
and strip any client-supplied versions.

**Environment caveat:** in Envoy v1.39.1's default local rate-limit
configuration the token bucket is **shared across all workers**, so the
limit applies **per Envoy process**: a bucket of N is effectively
N×replicas. Size buckets for the replica count and do not divide the
intended capacity by the worker count. The non-default
`local_rate_limit_per_downstream_connection: true` configuration switches
the bucket to per-downstream-connection and must be sized separately if
ever used. Also note `RateLimit.Action` has no `header_value` action in
Envoy v1.39 — use `request_headers`.

### 3.5 Example CRs from the design against the deployed Authorino

**Result: confirmed — the `v1beta3` response-config fields are accepted,
the Wristband reaches the upstream request as `x-wristband`, and the
signing algorithms `RS256` (adopted for the Desire Store) and `ES256`
(verified, not adopted) both work on the Authorino side.**

A test AuthConfig modeled on the DD's binding CR (age predicate and
partition predicate in `patternMatching.patterns[].predicate`;
`response.success.headers["x-wristband"].wristband` with `customClaims`
`value`/`expression`, `tokenDuration: 300`, `signingKeyRefs` name +
algorithm) was applied and served traffic. A TLS nginx echo server was
deployed as the `hyperfleet-api` upstream; an authorized request's upstream
body showed:

- **`x-wristband`: the full Wristband JWT, raw and unprefixed** with
  `aud: desire-store-api`, `hf_caller_class: remote-applier`, `hf_identity`
  (from `expression: auth.identity.sub`), and `hf_partition` (static value
  or path-derived expression both verified) — the DD's header-injection
  contract works. **Format note:** the value is the bare token — Authorino's
  `response.success.headers` cannot emit a scheme prefix. The deployed
  hyperfleet-api JWT handler requires a `Bearer`-prefixed value on every
  configured source header (`pkg/auth/jwt_handler.go`, rejects a raw token
  with 401 "does not use Bearer scheme"), so pointing the API at
  `x-wristband` as-is would reject every request on format. The
  established format is the **raw JWT, no prefix**: the API story must
  accept the raw value on non-`Authorization` source headers (a
  Bearer-prefixed `x-wristband` would need a gateway Lua bridge, which
  reintroduces the dynamic-metadata transport this design rejects).
- `authorization`: replaced with `Bearer <wristband>` by the gateway's Lua
  filter reading ext_authz **dynamic metadata** (the general gateway's
  mechanism).

**ES256 (verified in a dedicated follow-up run on 2026-11-19, not adopted —
see the decision below):** an EC
P-256 key was generated, stored as the `desire-store-wristband-key` Secret
(`key.pem`, same format as the gateway's existing signing-key Secret), and
referenced with `algorithm: ES256`. The emitted Wristband carried header
`{"alg":"ES256","kid":"desire-store-wristband-key"}` and reached the
upstream as `x-wristband`; its signature verified against the EC public key
(openssl, after converting the JWT's raw R||S signature to DER). The first
run of the spike used `RS256` (the gateway's existing key) — both
algorithms work as the DD's `signingKeyRefs` specify them.

**Consumer-side gap (same class as the format gap above, on the signing
algorithm) — resolved by adopting `RS256`:** the ES256 run verifies the
Authorino side only. The API's JWT validation accepts **RS256-signed tokens
only** — every issuer parser is built with `jwt.WithValidMethods([]string{"RS256"})`
(`pkg/auth/jwt_handler.go`, `defaultSigningAlgorithm`) and `JWTIssuerConfig`
has no per-issuer algorithm override — so an ES256 Wristband would be
rejected by the API with 401 regardless of the `x-wristband` format.
**Decision:** the Desire Store signing key is `RS256`, matching the general
gateway's existing key and the API's validation as deployed — this removes
the need for the per-issuer-algorithms API change and keeps one algorithm
across the Hub. The measured trade-off: RS256 signatures are ~200 bytes
larger per Wristband and slower to sign (~1 ms vs ~0.1 ms on the minting
Authorino), both negligible at Hub-internal request rates; ES256 remains the
preferred direction only if the general gateway migrates to EC as well, at
which point per-issuer accepted algorithms should be added to the API's JWT
issuer configuration for both.

**Caveat for the gateway story (HYPERFLEET-1829):** the deployed gateway's
Envoy Lua filter currently reads the wristband from ext_authz **dynamic
metadata** and fails closed (403 "missing gateway wristband") when it is
absent — then rewrites `Authorization: Bearer <wristband>`, the general
gateway's transport. The Desire Store transport is different and singular:
per the DD, `x-wristband` is the API's only authentication credential, and
Desire Store routes carry no Bearer-token middleware. The Desire Store
gateway must therefore be configured for **one end-to-end wristband
transport**: the `x-wristband` response header, with the API's issuer
configured to read `x-wristband` as its token header — and its Lua
fail-closed check must validate that same path (deny when `x-wristband` is
missing), so the API receives the token through the selected path and
nothing else. Emitting the wristband into dynamic metadata as well is
unnecessary for this design and must not become a second transport.

### 3.6 JWKS refresh behavior

**Result: confirmed — no request-driven fan-out across unrelated issuers;
resolution is reconcile-driven, request-driven fetches are bounded by HTTP
client timeouts, and AuthConfig deletion stops the issuer's resolution.**

Verified with Authorino at debug log level and two mock issuers (`/default`,
`/other`) on two AuthConfigs:

- Traffic against one issuer's host produced **no OIDC/JWKS resolution lines
  for the other issuer** — a request triggers resolution only for its own
  AuthConfig's issuer, as the design requires.
- OIDC configuration re-resolution is **reconcile-driven**: it fired when the
  AuthConfig was applied and when a shared dependency (the mock issuer's
  rollout) reconciled the AuthConfigs — 15 `openid connect configuration
  updated` lines, all at reconcile time, none at request time.
- Deleting the second issuer's AuthConfig stopped its resolution (no further
  `/other` lines).
- Request-time fetches are bounded: earlier in the spike, an unreachable JWKS
  endpoint produced `Client.Timeout exceeded while awaiting headers`
  (UNAUTHENTICATED denial), not a hang.
- Key-rotation pickup at request time is **not established by this spike**.
  After the mock issuer restarted with new keys, a freshly minted token was
  accepted — but the restart is the same event that triggered the
  reconcile-driven OIDC re-resolution above (the `openid connect
  configuration updated` lines preceded the traffic), so the acceptance is
  fully explained by reconcile-time re-resolution and cannot be attributed to
  a request-time JWKS fetch on unknown `kid`. Establishing that mechanism
  requires a controlled rotation test: rotate the issuer's keys without
  changing or reapplying any AuthConfig or mounted secret, send a request
  with a token carrying the new `kid`, and confirm a request-time JWKS fetch
  in the Authorino debug log. (The `refresh JWKS on unknown kid` behavior in
  hyperfleet-api#422 is the API's own verifier, not evidence about
  Authorino.)

## 4. Conclusions

The behaviors the Desire Store detailed design assumes were tested against
the deployed Authorino v0.28.0 / Envoy v1.39.1 pair. Every acceptance
criterion of HYPERFLEET-1822 is covered:

| # | Design assumption | Verdict |
|---|-------------------|---------|
| 1 | Binding deletion denies within 60 s | ✅ **< 1 s** healthy; unbounded under silent partition (infra failure, per design); < 1 s recovery |
| 2 | `issuer` enforced at authentication | ✅ 401 "issued by a different provider" |
| 3 | CEL errors deny, not pass | ✅ PERMISSION_DENIED for missing-claim ("no such key"), type ("no such overload") and out-of-bounds ("index out of bounds") errors |
| 4 | Local rate limiting keyed by caller class/partition | ✅ both keys verified via the metadata→header bridge, with independent per-partition buckets; buckets are per Envoy process in the default v1.39.1 configuration (shared across workers) |
| 5 | Example `v1beta3` CRs work; Wristband as upstream header | ✅ signing verified with `RS256` (adopted) and `ES256` (evaluated, not adopted); `x-wristband` reaches upstream; general-gateway Lua check requires metadata too |
| 6 | JWKS refresh bounded, no fan-out | ✅ reconcile-driven, timeout-bounded, cancelled on deletion |

No design rework is required for the verified mechanisms; the findings are
refinements for the rendering and gateway stories. The missing-claim CEL
denial, partition-keyed rate limiting, and signing-algorithm runs that
completed the acceptance criteria are recorded in 3.3–3.5 (the adopted
algorithm is `RS256`; the `ES256` run is the evaluated alternative, see
3.5). One follow-up remains open beyond the ticket's acceptance criteria:

- **Key-rotation pickup at request time** (3.6): not established by this
  spike; a controlled rotation test is still required. This goes beyond the
  ticket's ACs (which require bounded, cancellation-aware refresh with no
  fan-out — confirmed) and is recorded for the gateway story (1829).

## 5. Impact on HYPERFLEET-1831 (AuthConfig rendering)

1. **Rely on the `issuer` field** — enforced natively; no `iss` authorization
   rule fallback needed.
2. **CEL predicates belong in `patternMatching.patterns[].predicate`** — there
   is no `cel` authorization rule type in `v1beta3`. CEL errors deny by
   themselves, but the DD's mandatory path-shape checks for partition
   extraction (anchor on the `/partitions/` marker, reject malformed paths)
   are still required — positional-index extraction accepts paths it must
   reject (see 3.3).
3. **Expect 404 (not 401/403)** as the client-visible status when no
   AuthConfig matches (binding removed or wrong host).
4. **Wristband emission:** render `response.success.headers["x-wristband"]`
   as the DD writes it — the single end-to-end transport, with the API's
   issuer reading `x-wristband` as its token header and the gateway's Lua
   fail-closed check validating that same path (see 3.5). **The header value
   is the raw Wristband JWT, no `Bearer` prefix** — the API story must adapt
   the JWT handler to accept the raw value on non-`Authorization` source
   headers and allow `x-wristband` as a JWT source header (see 3.5).
   **Signing algorithm: use `RS256`** — the API's JWT handler accepts RS256
   only on every issuer (`jwt.WithValidMethods`, no per-issuer override), so
   the Desire Store signing key matches it and the general gateway's
   existing key; ES256 would require an API change for no Hub-internal
   benefit (see 3.5).
   **Rollout-ordering dependency:** the deployed gateway's Lua filter reads
   the wristband from ext_authz dynamic metadata and fails closed (403
   "missing gateway wristband") when it is absent (see 3.5). Rendering the
   AuthConfig with header-only emission while that Lua check is unchanged
   denies every Desire Store request. HYPERFLEET-1831 is therefore
   **blocked on HYPERFLEET-1829** adapting the Lua fail-closed check to the
   `x-wristband` path: 1829 must land first (or 1831 must gate behind it);
   a transitional dual-emission (header + dynamic metadata) window is the
   only safe alternative if the stories must deploy independently, and must
   be removed once 1829 is live. The DD's signing algorithm is `RS256`
   (see 3.5).
5. **Revocation monitoring** should alert on Authorino watch errors
   (visible within ~20 s of a partition) rather than client status codes;
   client-side denial is instant once the control plane is healthy but does
   not happen at all during a silent partition. Watch-error log lines alone
   are not sufficient: a watch can stall without erroring (or have its
   errors suppressed or rate-limited), so the monitoring must also include
   a **liveness signal on watch progress** — an alert on excessive sync age
   (time since the last successful re-list/reconcile) or absence of watch
   progress — so a silently stalled watch triggers an alert even when no
   watch-error line is logged.
6. **Rate-limit descriptors** need the metadata→header bridge. In Envoy
   v1.39.1's default configuration the local rate-limit bucket is shared
   across workers (per Envoy process), so size buckets for the replica
   count — not N×workers×replicas, and do not divide the intended capacity
   by the worker count (see 3.4). The mechanism is fail-open:
   1829 must also detect or bound the no-descriptor case (catch-all bucket
   or alert on missing `x-hf-caller-class`), since the default bucket is
   unlimited (see 3.4).
