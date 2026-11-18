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

**Steps:**

1. Configure an Envoy local rate-limit filter keyed on Authorino dynamic
   metadata (caller class, partition).
2. Burst requests above the limit and observe 429s only for the limited key.

**Result:** _pending_

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

**Steps:**

1. Configure two AuthConfigs with distinct issuers.
2. Send requests hitting only one; watch Authorino logs / metrics for JWKS
   fetches — confirm no fetch for the unrelated issuer.
3. Delete the unused issuer's AuthConfig mid-refresh; confirm cancellation.

**Result:** _pending_

## 4. Conclusions

_pending_

## 5. Impact on HYPERFLEET-1831 (AuthConfig rendering)

_pending_
