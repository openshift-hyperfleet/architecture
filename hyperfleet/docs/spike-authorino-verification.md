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

**Environment:** local kind cluster with the `hyperfleet-infra` gateway stack
(`HELMFILE_ENV=kind`, `AUTH_MODE=EDGE+API`), mock OIDC issuer
(`OIDC_ISSUER_MODE=mock`), via `make install-gateway`. Traffic is generated with
`curl` loops against the gateway service; timing is captured with
`date +%s.%N` around each request plus Authorino/Envoy log timestamps.

## 3. Experiments and Results

### 3.1 Revocation delay after binding AuthConfig deletion

**Setup:** a request path authorized by a binding AuthConfig under constant
traffic (~1 rps).

**Steps:**

1. Start the traffic loop; record baseline 200s.
2. `kubectl delete authconfig <binding>` at T0.
3. Record the time of the first denied response (401/403) — the revocation delay.
4. Repeat with the Authorino watch stalled (network policy blocking the API
   server :6443 from the Authorino pod) to measure how long stale policy
   persists and how re-list/re-watch bound recovery after the block is lifted.

**Result:** _pending_

### 3.2 Issuer enforcement on JWT authentication

**Steps:**

1. Mint a JWT with a valid signature (trusted JWKS) but a wrong `iss` claim.
2. Send it against a host whose AuthConfig pins `issuer:`.

**Result:** _pending_

### 3.3 CEL evaluation errors deny, not pass

**Steps:**

1. Craft a JWT with missing/malformed age claims (`exp` absent, `iat` malformed)
   so the age predicate `auth.identity.exp - auth.identity.iat <= 3600` errors.
2. Send a request with a path that breaks partition extraction
   (pattern with a missing capture group).
3. Observe the response code and the Authorino log line for the failing rule.

**Result:** _pending_

### 3.4 Post-auth local rate limiting keyed by dynamic metadata

**Steps:**

1. Configure an Envoy local rate-limit filter keyed on Authorino dynamic
   metadata (caller class, partition).
2. Burst requests above the limit and observe 429s only for the limited key.

**Result:** _pending_

### 3.5 Example CRs from the design against the deployed Authorino

**Steps:**

1. Apply the design's example `v1beta3` AuthConfig CRs verbatim.
2. Confirm `wristband` response injection reaches the upstream request as the
   `x-wristband` header (not only Envoy metadata).

**Result:** _pending_

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
