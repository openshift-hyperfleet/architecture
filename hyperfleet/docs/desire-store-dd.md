---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-10-20
---

# Desire Store Detailed Design

## Table of Contents

- [Related Documents](#related-documents)
- [Overview](#overview)
- [Authorization and Trust](#authorization-and-trust)
  - [Caller Permissions](#caller-permissions)
    - [Caller-to-Operation Matrix](#caller-to-operation-matrix)
  - [Cross-Cluster Applier Identity](#cross-cluster-applier-identity)
    - [Credential Lifecycle](#credential-lifecycle)
    - [Token Lifetime and Revocation Behavior](#token-lifetime-and-revocation-behavior)
  - [Partition Binding](#partition-binding)
  - [Partition Selection](#partition-selection)
  - [Identity Model Coordination](#identity-model-coordination)
  - [Revocation and JWKS Failure Behavior](#revocation-and-jwks-failure-behavior)
  - [Gateway Trust Contract](#gateway-trust-contract)
    - [Wristband Claims and Validation](#wristband-claims-and-validation)
    - [Signing-Key Rotation and Failure Handling](#signing-key-rotation-and-failure-handling)
    - [Network Boundary and Bypass Defense](#network-boundary-and-bypass-defense)
  - [AuthConfig Structure and Reconciliation](#authconfig-structure-and-reconciliation)
    - [Remote-Applier Binding AuthConfig](#remote-applier-binding-authconfig)
    - [Fleet-Scoped Caller AuthConfig](#fleet-scoped-caller-authconfig)
    - [Operator and Gateway Changes](#operator-and-gateway-changes)
- [API Contract and Runtime Behavior](#api-contract-and-runtime-behavior)
  - [API Operations](#api-operations)
  - [REST API (v1)](#rest-api-v1)
    - [Desire Identifier](#desire-identifier)
    - [Wire Schemas](#wire-schemas)
    - [Status Codes](#status-codes)
    - [Error Responses](#error-responses)
  - [Compatibility](#compatibility)
  - [CAS / Version Semantics](#cas--version-semantics)
  - [Pagination and Consistency](#pagination-and-consistency)
  - [Failure, Retry, and Degraded Behavior](#failure-retry-and-degraded-behavior)

## Related Documents

- [Desire Store HLD](desire-store-hld.md) — describes the high-level architecture and major decisions.
- [ADR-0020: Envoy and Authorino API Gateway](../adrs/0020-envoy-authorino-api-gateway.md) — defines caller authentication, header stripping, and trusted identity injection.
- [ADR-0022: API-Mediated Desire Store Access](../adrs/0022-api-mediated-desire-store-access.md) — establishes the API gateway boundary and mandatory partition enforcement.
- [ADR-0026: Co-Located Service Databases on Shared Postgres](../adrs/0026-co-located-service-databases-shared-postgres-isolation.md) — defines the shared-Postgres database boundary.
- [ADR-0029: Desire Store Authorization](../adrs/0029-desire-store-authorization.md) — defines caller classes, partition scope, and Wristband authorization.
- [Remote Applier Connectivity and Partition-Scoped Access to Postgres spike](spike-remote-applier-postgres-access.md) — records the connectivity decision and remaining design questions.
- [Desire Store on API Postgres spike](desire-store-api-postgres-spike.md) — provides the initial schema, CAS, write-split, and workload findings.
- [SPIKE: Evaluate Desire Store Transport Overhead](spike-desire-store-transport.md) — confirms the REST/JSON transport decision and the references-only list rule.
- [Desire Identity and Ownership Spike](spike-desire-identity-ownership.md) — defines the desire identity tuple and content fields used by the wire schemas.
- [Multi-Tenant Identity and Authorization Design](multi-tenant-identity-authz-design.md) — describes the related tenant and gateway identity model.
- [Desire Garbage Collection Strategy spike](spike-desire-garbage-collection.md) — selects a centralized Hub sweeper and resource-reference correlation for orphan cleanup.

## Overview

This document captures the detailed design for [HYPERFLEET-1645](https://redhat.atlassian.net/browse/HYPERFLEET-1645), covering caller permissions, Applier identity and partition binding, the gateway-to-API Wristband contract, the AuthConfig structure, the REST v1 API contract, consistency, and failure behavior. The [Desire Store HLD](desire-store-hld.md) provides the system context and high-level architectural decisions.

For system context and high-level interactions, see the [topology diagram](desire-store-hld.md#architecture) and [Applier request-flow diagram](desire-store-hld.md#request-flow).

## Authorization and Trust

Defines how callers are authenticated, mapped to partitions, and authorized to use the Desire Store API.

### Caller Permissions

This matrix specifies the operation-level permissions enforced by the gateway and API.

#### Caller-to-Operation Matrix

| Caller | Allowed operations |
|--------|--------------------|
| Adapter | Read desires; write desired state; delete desires |
| Remote Applier | Read its own partition; write status only |
| Centralized sweeper | List and get desires; write `DeleteDesire` records only (orphan cleanup); delete desires — scoped to one partition per request; see the [Desire Garbage Collection Strategy spike](spike-desire-garbage-collection.md) |

### Cross-Cluster Applier Identity

The selected identity model is defined by [ADR-0029: Desire Store Authorization](../adrs/0029-desire-store-authorization.md). This section records the credential lifecycle needed by the implementation.

#### Credential Lifecycle

- **Onboarding:** Configure the identity-to-partition mapping in AuthConfig; see [Partition Binding](#partition-binding).
- **Rotation and revocation:** See [Token Lifetime and Revocation Behavior](#token-lifetime-and-revocation-behavior).

#### Token Lifetime and Revocation Behavior

- **Token:** The management cluster projects and rotates the Applier's service-account token. The Hub rejects expired tokens and tokens whose total lifetime exceeds the maximum, enforced by the binding AuthConfig, which fails closed when the age claims are missing or malformed; the issuer's one-hour TTL is an onboarding expectation.
- **Lifetime:** Use one hour as the starting maximum lifetime and accepted age. This value may be revisited if future security or operational requirements change.
- **Residual window:** Revocation is accepted to take up to 60 seconds under a healthy control plane; a stalled watch or API-server partition can extend it, which is an infrastructure failure caught by reconciliation monitoring and recovery, not a bound the gateway enforces. No cache is planned or required (verified in [AuthConfig Structure and Reconciliation](#authconfig-structure-and-reconciliation)).
- **Revocation:**
  - Deleting the registration record removes the binding; subsequent requests are denied.
  - In-flight requests are not canceled.
  - If policy removal lags, the 60-second window is the accepted fallback delay.
- **Outage:** If Authorino is unavailable or initial issuer discovery fails, the gateway grants no new access.

### Partition Binding

Identity-to-partition bindings are managed as Hub-owned registration records, which the operator renders into AuthConfig. For each remote Applier, the entry contains:

- **AuthConfig fields:**
  - The exact issuer URL.
  - The required audience.
  - The exact service-account subject.
  - The authorized partition.
  - The `remote-applier` caller class.

The following rules apply to each binding:

- **Matching:** The issuer, audience, and subject must match the AuthConfig entry exactly; a partial match is denied. Each active identity maps to exactly one partition from AuthConfig; client headers and management-cluster token claims cannot provide the partition.
- **Lifecycle:** The operator renders the binding when the administrator registers the cluster, replaces it when identity or partition details change, and removes it when the record is deleted on decommission or compromise. AuthConfig status reports resource readiness, not binding state.
- **Propagation:** AuthConfig reconciliation applies changes without restarting the Applier or Desire Store API. A new or changed binding is unusable until the gateway accepts the updated policy.

The concrete `AuthConfig` CR rendered for each binding is defined in [AuthConfig Structure and Reconciliation](#authconfig-structure-and-reconciliation).

### Partition Selection

Every Desire Store route addresses the target partition in its path, as the segment following the fixed `/partitions` prefix — `/partitions/{partition}/desires/...` — and the route paths are uniform for all callers. The authorization rules and the gateway hostnames differ by caller class — the hostname selection is defined in [AuthConfig Structure and Reconciliation](#authconfig-structure-and-reconciliation):

- **Remote Applier:** the path partition must equal the partition in its AuthConfig binding; a mismatch is rejected ([ADR-0022](../adrs/0022-api-mediated-desire-store-access.md)).
- **Adapter and sweeper:** may target any partition per request; the path partition is the requested target, Authorino stamps it into the Wristband, and the API authorizes from that claim (see [Fleet-Scoped Caller AuthConfig](#fleet-scoped-caller-authconfig)).

**Alternatives considered:**

- **Request header:** rejected — the gateway strips client-supplied headers before authorization runs (see [Gateway Trust Contract](#gateway-trust-contract)), so Authorino would never see the requested partition.
- **Query parameter:** rejected — it hides the target from routing and makes the partition just another filter; the path segment keeps the scope explicit and matchable.

**Trade-off:** fleet-scoped callers may write to any partition, including a mistyped one. Partitions are implicit row groupings materialized by the first write, so a typo creates rows no Applier reads until the [sweeper](spike-desire-garbage-collection.md) garbage-collects them.

**Acceptable because:**

- The Adapter and sweeper are trusted Hub service identities, so the risk is data hygiene, not isolation — remote Appliers can still read only their bound partition.
- Rejecting unknown partitions would couple the gateway to a partition registry — the same runtime lookup dependency [ADR-0029](../adrs/0029-desire-store-authorization.md) rejects for identity-to-partition mapping — and would force onboarding order (binding before the first desire write).

### Identity Model Coordination

Remote Appliers use the existing [ADR-0020](../adrs/0020-envoy-authorino-api-gateway.md) AuthConfig and gateway model as a new partition-scoped caller. Existing caller behavior remains unchanged.

### Revocation and JWKS Failure Behavior

The management cluster must publish the registered issuer's discovery and JWKS endpoints over the approved private path and keep them reachable for key refresh.

- Each binding `AuthConfig` contains exactly one issuer configuration, selected by per-partition hostname lookup before authentication (see [AuthConfig Structure and Reconciliation](#authconfig-structure-and-reconciliation)); a request cannot trigger JWKS resolution for an unrelated issuer.
- JWKS refresh is bounded and canceled when the authorization request no longer needs it.
- A refresh failure denies requests that require unavailable keys but does not invalidate unrelated issuer configurations.
- Binding revocation behavior is defined in [Token Lifetime and Revocation Behavior](#token-lifetime-and-revocation-behavior).

### Gateway Trust Contract

Envoy strips client-supplied identity, caller-class, partition, and `x-wristband` headers before authorization. Authorino validates the caller's credential — a management-cluster JWT for remote Appliers, a Hub service-account token for fleet-scoped callers — and issues a signed Hub Wristband. Envoy forwards only the Authorino-issued `x-wristband` to the API, which authorizes only from its validated claims.

#### Wristband Claims and Validation

The Wristband carries the validated caller identity, caller class, authorized partition, issuer, audience, expiry, and signing-key identifier. The API validates the signature and required claims before authorizing an operation. The `x-wristband` header is the API's only authentication credential: Desire Store routes carry no Bearer-token middleware, so a request is never rejected for a missing Authorization header, only for a missing or invalid Wristband. The Wristband is minted per request and has its own lifetime, 300 seconds as the starting value, matching the general gateway; it is independent of the management-cluster token's one-hour lifetime. The caller identity (`hf_identity`) distinguishes the Adapter from the sweeper within the fleet-scoped class, so the API can enforce the sweeper's `DeleteDesire`-only restriction in the [Caller-to-Operation Matrix](#caller-to-operation-matrix).

#### Signing-Key Rotation and Failure Handling

Authorino signs Wristbands with the Hub private key, and the API verifies them with the matching public key identified by `kid`.

- **Key publication:** Publish the new public key before Authorino starts signing Wristbands with its key identifier.
- **Key retention:** Keep the previous public key for at least the maximum Wristband lifetime plus the allowed clock skew.
- **Trust source:** Configure the API with the Hub public-key or JWKS source before serving requests. The API loads trusted keys from that source and refreshes them according to the key-rotation policy.
- **Validation:** Reject an unknown key identifier, invalid signature, expired Wristband, missing claim, or inconsistent claim set before data access.
- **Refresh failure:** If the key set cannot be refreshed, continue only with already trusted keys; do not accept an unverified Wristband.

#### Network Boundary and Bypass Defense

- **NetworkPolicy:** Allow Desire Store API ingress only from its dedicated Envoy gateway.
- **Database:** Keep Postgres private to the Hub and allow connections only from the Desire Store API service.
- **Bypass defense:** Require and validate a signed Wristband before allowing data access, even if the gateway is bypassed.
- **Headers and credentials:** Ignore the client-supplied headers listed in the [Gateway Trust Contract](#gateway-trust-contract) and reject missing, invalid, or expired Wristbands.

### AuthConfig Structure and Reconciliation

The Desire Store gateway uses two kinds of Authorino `AuthConfig` custom resource (CR):

- **One CR per remote-Applier binding**, selected by per-partition hostname.
- **One fleet-scoped CR on the base host**, for the Adapter and sweeper.

Authorino indexes `AuthConfig` resources by hostname, so the hostname is the CR selection key. The API routes stay path-addressed and the path partition must still match the caller's authorization ([ADR-0022](../adrs/0022-api-mediated-desire-store-access.md)). These CRs are served by the Desire Store's dedicated Authorino instance, not the general gateway's. The `hyperfleet.io/desire-store` label on every Desire Store CR is the shard selector:

- The dedicated instance watches only CRs carrying the label.
- The general gateway's Authorino excludes them, so the two instances never overlap.

**Alternatives considered:**

- **One CR holding all bindings:** a single CR exceeds [etcd's default 1.5 MiB request-size limit](https://etcd.io/docs/v3.5/dev-guide/limit/#request-size-limit) at roughly 4,000 bindings (about 400 bytes each, from the example CR below); the [planning estimate](desire-store-api-postgres-spike.md#load-and-isolation) of 10,000 clusters is well past that.
- **Per-binding CRs on a shared host:** Authorino rejects a hostname already taken by another `AuthConfig`.
- **Envoy context-extension routing:** keeps one hostname by supplying the Authorino lookup key from Envoy route configuration, but moves the 10,000-entry partition mapping into non-CRD Envoy config.

**Trade-off:** per-partition hostnames require wildcard DNS and a wildcard TLS certificate, and the operator manages one CR per partition.

**Acceptable because:**

- Each binding has an independent lifecycle.
- Cross-caller protection is fail-closed by credential type — a management-cluster JWT cannot authenticate on the base host (TokenReview only), and a Hub service-account token cannot authenticate on a partition host (issuer check only).
- All Desire Store `AuthConfig` resources share one Wristband issuer value and signing-key set, so the API validates a single issuer and key set regardless of which CR issued the Wristband. The shared value is the fleet-scoped CR's Authorino discovery URL, so the API validates with its standard discovery-based JWT configuration, matching the main gateway.

#### Remote-Applier Binding AuthConfig

A registration record is a Hub-owned custom resource for each registered management cluster:

- **Carries:** the binding fields (issuer URL, service-account subject, audience, partition).
- **Created by:** the Hub administrator at management-cluster onboarding, never the management cluster itself; self-registration would let a cluster choose its own partition and issuer trust.
- **New capability:** the operator does not manage AuthConfigs today; reconciling them from these records is new work for the implementation stories.

The example maps one-to-one to the binding fields in [Partition Binding](#partition-binding); exact Authorino v1beta3 syntax and claim paths are verified at implementation:

```yaml
apiVersion: authorino.kuadrant.io/v1beta3
kind: AuthConfig
metadata:
  name: desire-store-mc-01
  namespace: hyperfleet
  labels:
    hyperfleet.io/desire-store: binding
spec:
  hosts:
  - mc-01.desire-store.hub.example.com
  authentication:
    "mc-01-applier":
      jwt:
        issuerUrl: https://issuer.mc-01.example.com
        issuer: https://issuer.mc-01.example.com # reject a wrong iss claim at authentication
        audiences:
        - hyperfleet-desire-store
  authorization:
    "mc-01-binding":
      patternMatching:
        patterns:
        - selector: auth.identity.sub # exact service-account subject
          operator: eq
          value: system:serviceaccount:hyperfleet:applier
        - predicate: request.path.split('/')[6] == 'mc-01' # path partition must equal the binding
        - predicate: auth.identity.exp - auth.identity.iat <= 3600 # one-hour maximum token lifetime
  response:
    success:
      headers:
        "x-wristband":
          # injected into the upstream request; the API validates it directly (the general gateway's wristband stays in Envoy metadata)
          wristband:
            issuer: https://authorino-oidc.hyperfleet.svc:8083/hyperfleet/desire-store-fleet-scoped/x-wristband
            customClaims:
              "aud":
                value: desire-store-api
              "hf_caller_class":
                value: remote-applier
              "hf_identity":
                expression: auth.identity.sub
              "hf_partition":
                value: mc-01
            tokenDuration: 300
            signingKeyRefs:
            - name: desire-store-wristband-key
              algorithm: ES256
```

#### Fleet-Scoped Caller AuthConfig

The Adapter and sweeper run on the Hub and authenticate using Hub service accounts. Unlike a remote Applier, which is restricted to one partition, they can access different partitions, one per request.

For each request, Authorino reads the target partition from the URL path (`request.path.split('/')[6]`) and includes it in the Wristband. The index form is illustrative: the implementation must anchor the extraction to the `/partitions/` marker rather than a position and reject paths that do not match the expected shape, so route changes fail closed instead of injecting a wrong partition.

Their AuthConfig differs from a remote-Applier binding's in four ways:

- **Host:** uses the shared hostname `desire-store.hub.example.com`.
- **Authentication:** validates Hub service-account tokens using Kubernetes TokenReview with the `hyperfleet-desire-store` audience.
- **Authorization:** allows the deployed adapters' and the sweeper's service-account subjects.
- **Wristband claims:** sets `hf_caller_class` to `fleet-scoped`, `hf_identity` to the caller's service-account subject, and `hf_partition` to the partition from the request path.

The Adapter and sweeper have different permissions, enforced from `hf_identity` ([Wristband Claims and Validation](#wristband-claims-and-validation)). Being fleet-scoped grants different partitions, not unrestricted access to every operation.

#### Operator and Gateway Changes

- **Operator, per binding:** reconcile one binding `AuthConfig` per management-cluster registration record:
  - Create at management-cluster onboarding.
  - Replace on identity or partition change.
  - Delete on decommission — deleting the CR removes the only issuer configuration that accepts that management cluster's tokens, so delete-CR is revocation; the residual window is defined in [Token Lifetime and Revocation Behavior](#token-lifetime-and-revocation-behavior).
- **Operator, fleet-scoped:** render and reconcile the base-host `AuthConfig` and its TokenReview subject allowlist, generated from the deployed adapters (each has its own `<name>-hyperfleet-adapter` service account) and the sweeper, as the general gateway's allowlist is.
- **Operator, registration validation:** reject a registration whose issuer is already claimed by another binding, and reject issuers whose signing keys overlap an existing registration (the main gateway chart already rejects duplicate `issuerUrl` at render, same pattern). With one CR per binding, no request-time component sees two bindings, so issuer uniqueness is what keeps one management cluster's Applier out of another's partition.
- **Operator, keys:** own the shared Wristband signing-key `Secret`s; rotate by putting the new key first in `signingKeyRefs` and retaining the previous key for the retention window ([Signing-Key Rotation and Failure Handling](#signing-key-rotation-and-failure-handling)).
- **Gateway:** a private Envoy listener for the Desire Store:
  - Serves the base host and the `{partition}.desire-store` wildcard hostnames.
  - Uses a wildcard DNS record and a wildcard TLS certificate; issuance follows the platform ingress/TLS architecture ([HYPERFLEET-1681](https://redhat.atlassian.net/browse/HYPERFLEET-1681)), and because HTTP-01 cannot issue wildcards, it needs the DNS-01 path or equivalent. A publicly trusted certificate needs no trust distribution: management clusters verify it with their standard CA bundles.
  - Strips the client-supplied headers defined in the [Gateway Trust Contract](#gateway-trust-contract) before authorization ([ADR-0020](../adrs/0020-envoy-authorino-api-gateway.md)).

**Verify at implementation:**

- The accepted 60-second revocation window in [Token Lifetime and Revocation Behavior](#token-lifetime-and-revocation-behavior) relies on policy-removal speed, not a cache: Authorino has no auth-decision cache (only OIDC and JWKS caching). Verify by deleting a binding CR mid-traffic and confirming requests fail within the window, and by stalling the watch or partitioning the API server to observe how long stale policy persists and how re-list and re-watch bound the recovery.
- Confirm the deployed Authorino version enforces the `issuer` field on JWT authentication; if it predates that field, enforce the `iss` claim in the authorization rule instead.
- Verify that the deployed Authorino version denies requests when a CEL predicate or expression fails to evaluate. Test missing or malformed JWT age claims and malformed paths that cause partition extraction to fail. If evaluation errors do not result in denial, add explicit presence and shape checks before performing the arithmetic or extraction.

## API Contract and Runtime Behavior

This section defines the resource operations and consistency guarantees exposed to the callers listed above.

### API Operations

The Desire Store API exposes these transport-neutral operations:

| Operation | Callers | Purpose |
|----------|---------|---------|
| List desires | Adapter, remote Applier, sweeper | Lists desires in the caller's authorized partition. Supports type filtering and pagination. |
| Get desire | Adapter, remote Applier, sweeper | Gets one desire in the caller's authorized partition. |
| Write desire | Adapter, sweeper | Adapter writes desired state; the sweeper may create `DeleteDesire` records only for orphan cleanup. |
| Write status | Remote Applier | Writes status only. |
| Delete desire | Adapter, sweeper | Deletes a desire. To remove an applied resource, the Adapter creates a `DeleteDesire`. |

The API derives the partition from the Wristband's trusted partition claim, never from a normal client request. All callers address the target partition in the route path; [Partition Selection](#partition-selection) defines the addressing and per-caller rules.

The sweeper is exempt from the owner-collision check on its writes and deletes, per the [Desire Garbage Collection Strategy spike](spike-desire-garbage-collection.md). Sweeper-created `DeleteDesire` records carry the sweeper's identity as `owner`, and the sweeper removes them after the applier confirms deletion, so the transient record does not block a future owner.

### REST API (v1)

REST/JSON over HTTPS is the selected transport, confirmed by the [transport evaluation](spike-desire-store-transport.md) ([HYPERFLEET-1743](https://redhat.atlassian.net/browse/HYPERFLEET-1743)).

The base path is `/api/hyperfleet/desire-store/v1`, and the routes follow the partition addressing defined in [Partition Selection](#partition-selection):

| REST route | Operation |
|------------|-----------|
| `GET /partitions/{partition}/desires?type={type}&cursor={cursor}&limit={limit}` | List desires |
| `GET /partitions/{partition}/desires/{desire-id}` | Get desire |
| `PUT /partitions/{partition}/desires/{desire-id}` | Write desire |
| `PUT /partitions/{partition}/desires/{desire-id}/status` | Write status |
| `DELETE /partitions/{partition}/desires/{desire-id}` | Delete desire |

Query parameters: `type` filters by desire type (`apply`, `delete`, `read`); omitted returns all types. `limit` caps the page size, with a default and maximum defined in the OpenAPI specification — values above the maximum are clamped or rejected with 400, as that specification defines.

#### Desire Identifier

The `{desire-id}` encodes the desire's identity as a single string:

- **Fields, in order:** `type`, `group`, `resource`, `namespace`, `name` — five of the six identity fields from the [Desire Identity Spike](spike-desire-identity-ownership.md). This document supersedes the spike's format for `name`: Kubernetes object-name validation (path-segment names, which permit colons in RBAC objects), not the spike's RFC 1035 label.
- **Format:** the fields joined by `:`, with an empty field as an empty segment.
  - Example: `apply:rbac.authorization.k8s.io:clusterroles::admin` (no namespace — the resource is cluster-scoped).
- **Why `:` is safe:** `type`, `group`, `resource`, and `namespace` are DNS names and cannot contain colons. The `name` is last and may contain colons (for example, the built-in ClusterRoles named `system:controller:*`), so decoding takes the first four segments positionally and joins the remainder as the name. The encoding stays unambiguous and reversible.
- **The sixth field:** `managementCluster` is the partition, so it travels in the path rather than the identifier.

#### Wire Schemas

The desire resource returned by Get:

```json
{
  "id": "apply:apps:deployments:kube-system:coredns",
  "type": "apply",
  "group": "apps",
  "resource": "deployments",
  "namespace": "kube-system",
  "name": "coredns",
  "owner": "cluster-adapter",
  "resource_id": "clusters/cls-123",
  "kubeContent": { "...": "rendered Kubernetes manifest" },
  "status": { "...": "applier-written status" },
  "version": 3
}
```

- **List responses:**
  - Return each desire's reference only — the identity fields and `version` — omitting `kubeContent`, `status`, `owner`, and `resource_id`; Get serves the full record.
  - This is the references-only rule the [transport evaluation](spike-desire-store-transport.md) makes load-bearing; the Applier therefore applies from the GET response, not the list.
  - Carry `next_cursor`, omitted on the last page ([Pagination and Consistency](#pagination-and-consistency)).
- **Write-desire requests:**
  - Carry `owner`, `resource_id`, `kubeContent`, and `version` only; write bodies carry no identity fields, and the path is the sole identity source.
  - An omitted or zero `version` means create; a provided `version` means update ([CAS / Version Semantics](#cas--version-semantics)).
- **Write-status requests:**
  - Carry only the `status` object.
  - Are idempotent: they neither send nor change the desired-state version and return no body.

The implementation story specifies these schemas in an OpenAPI document first, following [ADR-0003](../adrs/0003-openapi-first-contract.md). New v1 wire fields use snake_case (`next_cursor`), matching the Error Model extension fields; inherited desire fields keep their established spellings (`kubeContent`, `resource_id`).

#### Status Codes

| Code | When |
|------|------|
| 200 OK | Get and list responses; successful desire update |
| 201 Created | Desire created by a write |
| 204 No Content | Successful delete or status write |
| 400 Bad Request | Malformed request: invalid identifier encoding, query parameters, or JSON |
| 401 Unauthorized | Missing, invalid, or expired Wristband |
| 403 Forbidden | Caller class not permitted for the operation, or path partition outside the caller's authorization |
| 404 Not Found | Desire absent on a get, update, status write, or delete |
| 409 Conflict | Version mismatch, create on an existing desire, or owner collision |
| 422 Unprocessable Entity | Well-formed JSON that fails semantic validation, such as kubeContent whose Kubernetes identity does not match the path |
| 429 Too Many Requests | Rate limited |
| 500 / 503 | Internal error; 503 when the API is degraded |

#### Error Responses

Errors follow the [Error Model](../standards/error-model.md) standard: RFC 9457 `application/problem+json` with `code`, `timestamp`, and `trace_id` extension fields. Example — a version-conflict response:

```json
{
  "type": "https://api.hyperfleet.io/errors/version-conflict",
  "title": "Version Conflict",
  "status": 409,
  "detail": "Desire was modified by another request. Expected version 3, found version 7.",
  "instance": "/api/hyperfleet/desire-store/v1/partitions/mc-01/desires/apply:apps:deployments:kube-system:coredns",
  "code": "HYPERFLEET-CNF-002",
  "timestamp": "2026-10-19T10:32:00.789Z",
  "trace_id": "6df92f3577b34da6a3ce929d0e0e4738",
  "expected_version": 3,
  "actual_version": 7
}
```

Rate-limit errors add a `Retry-After` header and the standard's [rate-limit problem type](../standards/error-model.md#rate-limit-errors-lmt).

### Compatibility

- Supported v1 Appliers must continue working when the API is deployed independently.
- Operation behavior and authorization rules remain stable in v1.
- Optional additive request and response fields are compatible within v1.
- Changes to required fields, operation behavior, authorization, CAS, or idempotency require a new API version.
- CAS and idempotency details are defined in [CAS / Version Semantics](#cas--version-semantics).

### CAS / Version Semantics

- **Desired-state writes (Write desire, all desire types):** The Adapter sends the current version. The API updates only when it matches, then increases it. A mismatch returns a version-conflict error; the Adapter reads the current record and retries.
- **Status writes (Write status):** These do not require or change the desired-state version used by desired-state writes. An Applier can report status while an Adapter updates the desired state without either write failing because of the other. This preserves the [HYPERFLEET-1511](https://redhat.atlassian.net/browse/HYPERFLEET-1511) decision.
- **Timed-out writes:** If a write times out, the client reads the desire to check whether the requested change was applied. If it matches, the client treats the write as successful. Otherwise, it re-evaluates and retries. Status writes are idempotent because they update only status and do not change the desired-state version.

### Pagination and Consistency

- Partition reads use keyset pagination with an opaque cursor and no total count.
- A multi-page read is not a transactionally consistent snapshot. A changed desire can appear on the next five-second poll instead. This follows [ADR-0015](../adrs/0015-eventual-consistency-for-read-path.md), which accepts eventual consistency to avoid the latency and connection-pool cost of read transactions. The Applier must not treat an incomplete or failed list as an empty partition.
- The Applier collects all pages in a new view. It replaces its cached view only after the final page succeeds. If any page fails, it keeps the previous complete view.

### Failure, Retry, and Degraded Behavior

- **Non-retryable errors:** Return an error for invalid credentials, permissions, input, ownership, or version. The caller must correct the problem before retrying.
- **Rate limits:** Honor the server's retry guidance before retrying.
- **Temporary failures:** Retry network failures, timeouts, and transient service failures with capped exponential backoff and jitter.
- **Suggested starting defaults:**
  - Initial delay: 1 second.
  - Maximum delay: 30 seconds.
  - Jitter: full jitter.
  - Retry window: 2 minutes.
  - These are implementation starting points and may be adjusted if security or operational requirements change.
- **API unavailable:** Continue using the most recent complete partition view. Do not delete local resources because of an API failure. After restart, wait for a successful partition read before reconciling.
