---
Status: Active
Owner: Leonardo Dorneles
Last Updated: 2026-11-17
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

Traffic was generated with `curl` loops (~1–2 rps) from in-cluster pods against
`http://hyperfleet-gateway.hyperfleet-local.svc:8000`, carrying mock-issuer
human JWTs. Because the API upstream was not deployed in this environment, an
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
| API-server partitioned (watch dead) | **≥ 25 min, unbounded** | Stale policy kept authorizing traffic for the entire partition (589 requests over 25 min). The watch errored within ~19 s of the partition (`http2: client connection lost`), but re-list was blocked, so Authorino kept serving its last-known state. Denial never happened during the partition. |
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
| Wrong partition (`…/mc-02/…`) | predicate is false | `PERMISSION_DENIED` — "Unauthorized" |

Notes for the rendering story:

- The design's placement of CEL predicates inside
  `authorization.<rule>.patternMatching.patterns[].predicate` is valid
  `v1beta3` syntax; there is no standalone `cel` rule type in `v1beta3`
  ( CEL expressions exist in `when` predicates and `expression` selectors).
- Errors deny with the failing rule's message in the Authorino log, so no
  extra presence/shape checks are strictly required for fail-closed behavior;
  explicit checks remain an option for clearer client-facing errors.

### 3.4 Post-auth local rate limiting keyed by dynamic metadata

**Result: confirmed — the pair supports local rate limiting keyed by caller
class from Authorino dynamic metadata, but not directly: Envoy's local rate
limit filter cannot match on ext_authz dynamic metadata, so a small bridge is
required.**

Working mechanism verified end-to-end on the deployed gateway:

1. Authorino emits the caller class via
   `response.success.dynamicMetadata.hf_caller_class.plain.value`
   (verified reaching Envoy: a Lua filter copied it to an
   `x-hf-caller-class` request header, confirmed at the upstream).
2. Route-level `rate_limits.actions[].request_headers` (header name
   `x-hf-caller-class`, `descriptor_key: caller_class`, `skip_if_absent`)
   produces the descriptor.
3. `envoy.filters.http.local_ratelimit` matches the descriptor
   (`caller_class: remote-applier`) and applies its token bucket.

Burst test (bucket of 2 per pod, 2 replicas, `--concurrency 1`): 4 requests
passed, then **429**; requests without the header (no descriptor) stayed
unlimited (default bucket). **Requirement for HYPERFLEET-1829:** the gateway's
Lua filter (or equivalent) must copy the metadata-derived caller class and
partition into headers before routing, and strip any client-supplied versions.

**Environment caveats recorded:** the local rate limit bucket is
**per Envoy worker** — with the default worker-per-CPU (8 here) a bucket of N
is effectively N×workers×replicas. The Desire Store gateway must either pin
`--concurrency` or size buckets for the worker count. Also note
`RateLimit.Action` has no `header_value` action in Envoy v1.39 — use
`request_headers`.

### 3.5 Example CRs from the design against the deployed Authorino

**Result: confirmed — the DD's `v1beta3` example CR fields are accepted as
written, and the Wristband reaches the upstream request as `x-wristband`.**

A test AuthConfig modeled directly on the DD's binding CR (age predicate and
partition predicate in `patternMatching.patterns[].predicate`;
`response.success.headers["x-wristband"].wristband` with `customClaims`
`value`/`expression`, `tokenDuration: 300`, `signingKeyRefs`
name+`RS256`) was applied and served traffic. A TLS nginx echo server was
deployed as the `hyperfleet-api` upstream; an authorized request's upstream
body showed:

- **`x-wristband`: the full Wristband JWT** with `aud: desire-store-api`,
  `hf_caller_class: remote-applier`, `hf_identity` (from
  `expression: auth.identity.sub`), and `hf_partition: mc-01` (static value) —
  the DD's header-injection contract works.
- `authorization`: replaced with `Bearer <wristband>` by the gateway's Lua
  filter reading ext_authz **dynamic metadata** (the general gateway's
  mechanism).

**Caveat for the gateway story (HYPERFLEET-1829):** the deployed gateway's
Envoy Lua filter fails closed (403 "missing gateway wristband") when Authorino
returns OK without a wristband in **dynamic metadata**. A Desire Store
AuthConfig that emits the wristband only as a response header (as the DD CR
writes it) is rejected by this Envoy config. The Desire Store gateway must
either emit the wristband in both places or adapt the Lua check to the
`x-wristband` header path.

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
- Key rotation is picked up at request time on unknown `kid`: after the mock
  issuer restarted with new keys, a freshly minted token was accepted
  immediately (matches the `refresh JWKS on unknown kid` behavior in
  hyperfleet-api#422).

## 4. Conclusions

All six behaviors the Desire Store detailed design assumes were verified
against the deployed Authorino v0.28.0 / Envoy v1.39.1 pair:

| # | Design assumption | Verdict |
|---|-------------------|---------|
| 1 | Binding deletion denies within 60 s | ✅ **< 1 s** healthy; unbounded under silent partition (infra failure, per design); < 1 s recovery |
| 2 | `issuer` enforced at authentication | ✅ 401 "issued by a different provider" |
| 3 | CEL errors deny, not pass | ✅ PERMISSION_DENIED for type errors and out-of-bounds |
| 4 | Local rate limiting keyed by caller class/partition | ✅ via metadata→header bridge; per-worker buckets are a sizing caveat |
| 5 | Example `v1beta3` CRs work; Wristband as upstream header | ✅ all fields accepted; `x-wristband` reaches upstream; general-gateway Lua check requires metadata too |
| 6 | JWKS refresh bounded, no fan-out | ✅ reconcile-driven, timeout-bounded, cancelled on deletion |

No design rework is required; the findings are refinements for the rendering
and gateway stories.

## 5. Impact on HYPERFLEET-1831 (AuthConfig rendering)

1. **Rely on the `issuer` field** — enforced natively; no `iss` authorization
   rule fallback needed.
2. **CEL predicates belong in `patternMatching.patterns[].predicate`** — there
   is no `cel` authorization rule type in `v1beta3`. Errors deny by
   themselves; explicit presence/shape checks are optional, for clearer
   errors only.
3. **Expect 404 (not 401/403)** as the client-visible status when no
   AuthConfig matches (binding removed or wrong host).
4. **Wristband emission:** render `response.success.headers["x-wristband"]`
   as the DD writes it, **plus** a `dynamicMetadata` wristband (or a gateway
   Lua adaptation) so the deployed gateway's fail-closed wristband check
   passes — coordinate with HYPERFLEET-1829.
5. **Revocation monitoring** should alert on Authorino watch errors
   (visible within ~20 s of a partition) rather than client status codes;
   client-side denial is instant once the control plane is healthy but does
   not happen at all during a silent partition.
6. **Rate-limit descriptors** need the metadata→header bridge and a decision
   on Envoy `--concurrency` for bucket sizing.
