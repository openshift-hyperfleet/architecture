---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-11-12
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
  - [Owner Binding](#owner-binding)
  - [REST API (v1)](#rest-api-v1)
    - [Desire Identifier](#desire-identifier)
    - [Wire Schemas](#wire-schemas)
    - [Status Codes](#status-codes)
    - [Error Responses](#error-responses)
  - [Sweeper Partition Enumeration (Proposed)](#sweeper-partition-enumeration-proposed)
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
- [Sweeper Orphan-Scan spike](spike-sweeper-orphan-scan.md) — proposes partition enumeration, confirmation, cleanup rules, and cadence for HYPERFLEET-1823; identifies review gates before implementation.

## Overview

This document captures the detailed design for [HYPERFLEET-1645](https://redhat.atlassian.net/browse/HYPERFLEET-1645), covering caller permissions, Applier identity and partition binding, the gateway-to-API Wristband contract, the AuthConfig structure, the REST v1 API contract, consistency, and failure behavior. The [Desire Store HLD](desire-store-hld.md) provides the system context and high-level architectural decisions. [HYPERFLEET-1871](https://redhat.atlassian.net/browse/HYPERFLEET-1871) amends it with the [owner binding](#owner-binding) and the [delete recovery rule](#cas--version-semantics).

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

Every desire-record route addresses the target partition in its path, as the segment following the fixed `/partitions` prefix — `/partitions/{partition}/desires/...` — and the route paths are uniform for all callers. The proposed [partition enumeration operation](#sweeper-partition-enumeration-proposed) is a separate, sweeper-only metadata exception; it does not relax these rules for desire records. The authorization rules and the gateway hostnames differ by caller class — the hostname selection is defined in [AuthConfig Structure and Reconciliation](#authconfig-structure-and-reconciliation):

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

**Trade-off:** per-partition hostnames require wildcard DNS, and the operator manages one CR per partition.

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

For each desire-record request, Authorino reads the target partition from the URL path (`request.path.split('/')[6]`) and includes it in the Wristband. The index form is illustrative: the implementation must anchor the extraction to the `/partitions/` marker rather than a position and reject paths that do not match the expected shape, so route changes fail closed instead of injecting a wrong partition. The proposed metadata operation has a separate exact method/path rule, defined in [Sweeper Partition Enumeration](#sweeper-partition-enumeration-proposed); extraction failure must never select that rule.

Their AuthConfig differs from a remote-Applier binding's in four ways:

- **Host:** uses the shared hostname `desire-store.hub.example.com`.
- **Authentication:** validates Hub service-account tokens using Kubernetes TokenReview with the `hyperfleet-desire-store` audience.
- **Authorization:** allows the deployed adapters' and the sweeper's service-account subjects.
- **Wristband claims:** sets `hf_caller_class` to `fleet-scoped`, `hf_identity` to the caller's service-account subject, and `hf_partition` to the partition from the request path. The `hf_identity` selector is `auth.identity.user.username`. TokenReview returns the caller's name in this field and has no `sub` field. The general gateway's AuthConfig uses the same selector. The value is `system:serviceaccount:<namespace>:<name>`, the same as the token's `sub` claim.

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
  - Uses a wildcard DNS record; TLS certificates are minted from the internal CA ([ADR-0036](../adrs/0036-management-cluster-ingress-tls-termination.md)), and trust distribution to the management clusters is [HYPERFLEET-1866](https://redhat.atlassian.net/browse/HYPERFLEET-1866)'s design.
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

For these desire-record operations, the API derives the partition from the Wristband's trusted partition claim, never from a normal client request. All callers address the target partition in the route path; [Partition Selection](#partition-selection) defines the addressing and per-caller rules. Proposed partition metadata enumeration is specified separately below.

### Owner Binding

A desire's `owner` is the exact `hf_identity` of the caller that writes it. That value is the caller's service-account subject from the Wristband ([Fleet-Scoped Caller AuthConfig](#fleet-scoped-caller-authconfig)), for example `system:serviceaccount:hyperfleet:cluster-adapter-hyperfleet-adapter`. The API sets `owner` from the authenticated caller; clients never send it:

- **Writes:** The API stores the caller's `hf_identity` as the record's `owner`. Write bodies carry no `owner` field, and a body that includes one returns 400.
- **Deletes:** The API uses `hf_identity` as the caller's owner, as it does on writes.
- **Owner collision:** All desires for one Kubernetes object in one partition have the same `owner`: the caller that created the first of them. While one of these desires exists, a different caller gets 409 owner conflict ([Conflict Responses](#conflict-responses)) when it creates, writes, or deletes a desire for that object. The shared store applies this rule.
- **Status writes:** Write status does not check the `owner`. The remote Applier writes status on desires that adapters own. The shared store's status operations also do not check the `owner`.
- **Sweeper exemption:** A request is exempt only when `hf_identity` is the sweeper's service-account subject.
- **Caller's own identity:** Callers still compare a record's `owner` with their own identity before they act on a record they read, as the sweeper guard in [CAS / Version Semantics](#cas--version-semantics) does. They take that identity from the `sub` claim of their service-account token, not from configuration. This value is the same as the `hf_identity` that the API gets ([Fleet-Scoped Caller AuthConfig](#fleet-scoped-caller-authconfig)).

The sweeper is exempt from the owner-collision check on its writes and deletes, per the [Desire Garbage Collection Strategy spike](spike-desire-garbage-collection.md). The exemption lets it remove `DeleteDesire` records that adapters own, including the confirmed records adapters keep after a delete ([HYPERFLEET-1841](spike-desires-lost-mid-deletion.md)). The `DeleteDesire` records it creates carry the sweeper's `hf_identity` as `owner`, like any other caller's writes. The sweeper removes them after the applier confirms deletion, so the transient record does not block a future owner. The exemption covers this confirmed cleanup, not blind version-only retries: its deletes carry `version` like any other delete, and after a timed-out delete it follows the sweeper guard in [CAS / Version Semantics](#cas--version-semantics).

**Alternatives considered:**

- **Validate a submitted `owner` against `hf_identity` (403 on mismatch):** rejected. It grants nothing the Wristband does not, yet it duplicates the caller's identity in every write body while `DELETE` relies on the Wristband alone. Its only benefit is catching a client whose own identity is misconfigured. Taking that identity from the token's `sub` claim removes that misconfiguration instead.
- **Keep the adapter name as `owner` and map it from the service-account name:** rejected. The API would then depend on how adapter service accounts are named. The adapter Helm chart names it `<release>-hyperfleet-adapter` by default, but the chart's `serviceAccount.name` and `fullnameOverride` values can change it. A separate owner claim in the Wristband would need a gateway change.
- **Trust a client-supplied `owner`:** rejected. One adapter could write or delete as another, which defeats reject-on-collision (decision 1a in the [Desire Identity Spike](spike-desire-identity-ownership.md)).

**Trade-off:** Renaming an adapter's service account or namespace changes its `owner`. Its existing desires then collide with 409 owner conflict until they are cleared. A new adapter name has the same effect today, because the adapter sends its configured name as `owner`.

**Acceptable because:**

- String equality with `hf_identity` needs no naming convention and no extra Wristband claim. The fleet-scoped AuthConfig already sets `hf_identity` for authorization.
- The Desire Store is rebuildable, so clearing the old owner's desires after a rename loses no source of truth.

### REST API (v1)

REST/JSON over HTTPS is the selected transport, confirmed by the [transport evaluation](spike-desire-store-transport.md) ([HYPERFLEET-1743](https://redhat.atlassian.net/browse/HYPERFLEET-1743)).

The OpenAPI specification for this API is in [hyperfleet-desire-store-spec](https://github.com/openshift-hyperfleet/hyperfleet-desire-store-spec). The specification does not contain the routes and wire schemas from this section yet. [HYPERFLEET-1821](https://redhat.atlassian.net/browse/HYPERFLEET-1821) adds them.

The base path is `/api/hyperfleet/desire-store/v1`. The desire-record routes follow the partition addressing defined in [Partition Selection](#partition-selection). The proposed partition-listing route has separate [authorization rules](#sweeper-partition-enumeration-proposed):

| REST route | Operation |
|------------|-----------|
| `GET /partitions?cursor={cursor}&limit={limit}` | List partitions (sweeper only; [proposed](#sweeper-partition-enumeration-proposed)) |
| `GET /partitions/{partition}/desires?type={type}&cursor={cursor}&limit={limit}` | List desires |
| `GET /partitions/{partition}/desires/{desire-id}` | Get desire |
| `PUT /partitions/{partition}/desires/{desire-id}` | Write desire |
| `PUT /partitions/{partition}/desires/{desire-id}/status` | Write status |
| `DELETE /partitions/{partition}/desires/{desire-id}?version={version}` | Delete desire |

Query parameters: `type` filters by desire type (`apply`, `delete`, `read`); omitted returns all types. `limit` caps the page size, with a default and maximum defined in the OpenAPI specification — values above the maximum are clamped or rejected with 400, as that specification defines. `version` is required on delete and carries the desire's current version ([CAS / Version Semantics](#cas--version-semantics)).

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
  "owner": "system:serviceaccount:hyperfleet:cluster-adapter-hyperfleet-adapter",
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
  - Carry `resource_id`, `kubeContent`, and `version` only; write bodies carry no identity or ownership fields, and the path is the sole identity source.
  - `owner` is set by the API from the caller's `hf_identity` and appears only in responses ([Owner Binding](#owner-binding)).
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
| 400 Bad Request | Malformed request: invalid identifier encoding, query parameters, or JSON; missing or non-integer `version` on a delete; `owner` in a write body |
| 401 Unauthorized | Missing, invalid, or expired Wristband |
| 403 Forbidden | Caller class not permitted for the operation, or path partition outside the caller's authorization |
| 404 Not Found | Desire absent on a get, update, status write, or delete |
| 409 Conflict | One of four conflicts. The `code` field tells which one ([Conflict Responses](#conflict-responses)) |
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

#### Conflict Responses

Each 409 response has its own [conflict code](../standards/error-model.md#conflict-errors-cnf). The code tells the client if it can retry:

| Cause | Store error | Type | Code | Client action |
|-------|-------------|------|------|---------------|
| The version in a write or delete is not current | `ErrVersionConflict` | `version-conflict` | `HYPERFLEET-CNF-002` | Read the desire again. If the change is still necessary, retry with the current version |
| The caller creates a desire that it already has | `ErrAlreadyExists` | `resource-conflict` | `HYPERFLEET-CNF-001` | Read the desire, then update it with its version |
| The caller creates an `ApplyDesire` while the `DeleteDesire` for the object is not confirmed | `ErrDeletePending` | `resource-conflict` | `HYPERFLEET-CNF-003` | Retry after the Applier confirms the delete. The store then replaces the `DeleteDesire` with the new `ApplyDesire` |
| A different caller owns the object | `ErrOwnerConflict` | `resource-conflict` | `HYPERFLEET-CNF-004` | Do not retry. No request from this caller changes the `owner` |

On a write or a delete, the store checks the version before the `owner`. When both are wrong, the response is `HYPERFLEET-CNF-002`. The retry with the current version then gets `HYPERFLEET-CNF-004`.

The API tests must cover each row. The `HYPERFLEET-CNF-004` test must use a second caller identity.

### Sweeper Partition Enumeration (Proposed)

**Review state:** This is the proposed API amendment for [HYPERFLEET-1823](spike-sweeper-orphan-scan.md), to be accepted or revised before [HYPERFLEET-1821](https://redhat.atlassian.net/browse/HYPERFLEET-1821) finalizes OpenAPI. It is not an implemented endpoint. The spike's confirmation and cleanup rules also depend on the generation/status contract proposed in [PR #273](https://github.com/openshift-hyperfleet/architecture/pull/273); that PR is still open and documents a false-confirmation risk after a DeleteDesire is recreated. The spike records this as a review gate.

#### Operation and Response

Add `GET /partitions?cursor={cursor}&limit={limit}` under the existing `/api/hyperfleet/desire-store/v1` base path. It lists distinct partitions represented by at least one stored desire of any type (`apply`, `delete`, or `read`). It must not filter by registration, AuthConfig, active Applier, owner, or originating API-resource existence. It returns identifiers only, without desire content, credentials, or registration metadata.

Example response (illustrative identifiers and opaque cursor):

```json
{
  "items": [
    { "partition": "mc-01" },
    { "partition": "mc-02" }
  ],
  "next_cursor": "opaque-continuation-token"
}
```

- `items` is required, including an empty array when no partitions remain. Each `partition` has the existing `managementCluster` identifier format. Omit `next_cursor` on the final page; return no total count.
- Use ascending bytewise lexicographic order of the partition identifiers and an opaque keyset cursor, independent of database locale. A cursor belongs to this operation and cannot be used on a desire-list route or vice versa; malformed or incompatible cursors return 400.
- Use the same default/maximum `limit` and over-limit behavior as the desire-list operation, finalized in HYPERFLEET-1821 (test-plan C8). Do not introduce a second paging policy. Both operations need explicit values in OpenAPI; this spike makes no unmeasured capacity claim for those values.
- The response is 200 on success, including an empty list. Use existing 400, 401, 403, 429, 500, and 503 error contracts. Do not turn a database/query failure into an empty 200 response.
- Pagination is not a snapshot. A partition inserted behind the cursor may be found on the next scan; disappearing rows may make a returned partition empty when read. Restart scans from the beginning on subsequent runs. Do not use the list as evidence of source-resource or Kubernetes-object absence.
- The API/backend performs enumeration through its data layer; the sweeper receives no database access. Partition identifiers are derived from remaining records, not a new registry. Select and validate a bounded query/index strategy against the actual schema, including partitions containing only deletes or reads.

#### Metadata Authorization Exception

This operation intentionally has no target partition. Its permission is separate from every desire-record permission:

1. On the existing fleet base host, authenticate the Hub token through TokenReview and require the exact deployed sweeper service-account identity. Other allowlisted Hub identities, including Adapters, cannot use this route. Remote Appliers cannot use it through either hostname class.
2. Match only `GET` on the canonical partition-collection path. Authorino issues a signed Wristband with `hf_caller_class=fleet-scoped`, the sweeper's `hf_identity`, and a new `hf_operation=partition-list` claim. Omit `hf_partition` for this operation; never use an empty or wildcard partition to query desire records. Keep the existing signature, issuer, audience, expiry, and key-validation requirements.
3. The API admits the metadata query only when method/path, identity, caller class, and `hf_operation` all match. A metadata request carrying `hf_partition` is inconsistent and must be rejected. A valid partition-scoped Wristband does not grant metadata permission.
4. On every desire-record route, reject a metadata `hf_operation` claim and continue requiring the existing non-empty partition claim and route equality. The metadata scope is not a fallback when partition extraction fails. Normal partition-scoped Wristbands need no new operation claim.
5. Strip client-supplied identity, scope, partition, and Wristband headers at the gateway as before. Client input must never populate `hf_operation`. Grant the exception only to the enumeration handler/data-layer method, never by disabling shared partition enforcement.

Accepting this proposal requires recording the metadata exception in ADR-0029, using its existing relationship to ADR-0022; those ADRs are unchanged in this draft. The exception would apply only to this metadata operation. Review the AuthConfig generation, gateway route matching, API claim validation, and data-layer interface together. Required negative tests include forged scope, Adapter/Applier access, mixed claims, metadata-token replay on desire routes, malformed paths, and missing partition on ordinary routes. Gateway expression syntax and normalization behavior must be verified in implementation, not inferred from this conceptual claim contract.

### Compatibility

- Supported v1 Appliers must continue working when the API is deployed independently.
- Existing operation behavior and authorization rules remain stable in v1.
- Optional additive request and response fields are compatible within v1.
- The [proposed sweeper-only partition listing](#sweeper-partition-enumeration-proposed) is an additive operation to settle before v1 is finalized. Its metadata permission is limited to one service identity and rejected on every desire-record route. This compatibility assessment is part of the proposal, not an approved API contract.
- After v1 is finalized, changes to required fields, behavior, authorization, CAS, or idempotency of an existing operation require a new API version.
- CAS and idempotency details are defined in [CAS / Version Semantics](#cas--version-semantics).

### CAS / Version Semantics

- **Desired-state writes (Write desire, all desire types):** The Adapter sends the current version. The API updates only when it matches, then increases it. A mismatch returns a version-conflict error; the Adapter reads the current record and retries.
- **Status writes (Write status):** These do not require or change the desired-state version used by desired-state writes. An Applier can report status while an Adapter updates the desired state without either write failing because of the other. This preserves the [HYPERFLEET-1511](https://redhat.atlassian.net/browse/HYPERFLEET-1511) decision.
- **Deletes (Delete desire):** The caller sends the desire's current version as the required `version` query parameter. The API deletes only when it matches and returns 204. A mismatch returns a 409 version-conflict error, the same problem type as on writes. An absent desire returns 404. The shared store's single-desire deletes (`DeleteApplyDesire`, `DeleteDeleteDesire`, `DeleteReadDesire`) also require the exact version and the `owner`.
- **Timed-out writes:** If a write times out, the client reads the desire to check whether the requested change was applied. If it matches, the client treats the write as successful. Otherwise, it re-evaluates and retries. Status writes are idempotent because they update only status and do not change the desired-state version.
- **Timed-out deletes:** If a delete times out, the client reads the desire:
  - Absent: the delete succeeded.
  - Present at the same version: the delete did not happen, or the desire was deleted and created again at the same version (see the trade-off below); the client retries the conditional `DELETE`.
  - Present at a different version: the desire changed or was recreated; the client does not retry and re-evaluates instead.

  For an Adapter, a direct retry of the conditional `DELETE` gives the same results: 204, or 404 (treated as success), or 409. The 409 code is `HYPERFLEET-CNF-002` when the desire changed and `HYPERFLEET-CNF-004` when a different caller owns it. When both are true, the code is `HYPERFLEET-CNF-002` ([Conflict Responses](#conflict-responses)).

- **Sweeper guard on timed-out deletes:** The sweeper is exempt from the owner-collision check, so the API does not stop its retry from deleting another owner's record. After a timed-out delete, the sweeper re-reads the desire and retries only when the stored `owner` is still its own `hf_identity` and the version matches. When the `owner` differs, another owner may have created the desire again, so the sweeper does not retry; it re-evaluates the record as it does any other, and the new owner's record stays in place. The guard's read and the retry are separate requests, so the guard narrows the cross-owner case but does not close it (see the trade-off below).

**Trade-off:** Versions restart at 1 for each record, and once every record for a target is deleted, any owner can create it again at version 1. A delete therefore cannot always tell a recreated desire from the original:

- **Same owner:** If the caller itself creates the desire again at the version it read, the retried delete removes the new record.
- **Another owner, sweeper only:** The sweeper's read and its delete are separate requests, and the API skips the owner check for the sweeper. If the original delete commits after the guard's read and another owner creates the desire at the same version before the retry, the retry removes that owner's record. The same window exists between any sweeper read and the delete that follows it.

**Acceptable because:**

- An Adapter's retry cannot remove another owner's record: the API checks it against the stored `owner` ([Owner Binding](#owner-binding)) and returns 409 owner conflict (`HYPERFLEET-CNF-004`). Only the sweeper can remove another owner's record, and only in the window above. That window needs a delete and a create by a different owner, both at the same desire identity, between two sweeper requests.
- Every lost record is rewritten by its owner. The Desire Store is rebuildable, so an Adapter writes a missing `ApplyDesire` again on its next reconcile, and it requests a missing unconfirmed `DeleteDesire` again instead of treating its absence as a completed delete ([Adapter Deletion Flow Design](../components/adapter/framework/lifecycle/adapter-lifecycle-delete-design.md#remote-transport-resources-9)).

**Alternatives considered:**

- **Client-side read rule with an unconditional `DELETE`:** rejected. A recreate that lands between the read and the retry gets deleted at any version. Also, the shared store conformance tests that reject a delete with an old version (`DeleteStaleVersionRejected`, for `DeleteDesire` and `ReadDesire`) cannot pass over HTTP.
- **`If-Match` header with 412 Precondition Failed:** rejected. It adds a second conflict status and an ETag that this API does not otherwise use, while the store reports both as the same version conflict.
- **Globally unique versions:** rejected. The shared store conformance suite requires version 1 on create and an increase of 1 per update.
- **`Idempotency-Key` header on deletes:** rejected. The API would store each key's result with the delete and return it on a retry, so a timed-out delete's retry could not remove a recreated record. That adds deduplication state with its own expiry to a store that is otherwise rebuildable. It also does not cover the sweeper's window: the sweeper decides from a read and then sends a new request with a new key.
- **Per-incarnation `uid` precondition:** the API assigns a new `uid` on every create, and a delete carries the `uid` it read. A recreated desire never matches, so this closes both the retry case and the sweeper's read-to-delete window. It is rejected for v1 because the shared store delete operations take no parameter for it: adding one changes the store interface, every store implementation, and the conformance suite in `hyperfleet-applier`, to prevent a loss that the owner's next reconcile repairs. As an optional query parameter it can be added later without breaking v1 clients, and it is the preferred fix if records lost to these windows are observed.
- **Expected-owner precondition on sweeper deletes:** the sweeper sends the `owner` it read, and the API checks it atomically with the version. This would close the cross-owner window. It is rejected for v1 because it adds a second delete precondition to the wire contract, and the loss it prevents is already repaired on the owner's next reconcile. Revisit it if records lost to this window are observed; the owner-collision exemption means the owner-conflict metric does not count them.

### Pagination and Consistency

- Partition reads use keyset pagination with an opaque cursor and no total count.
- A multi-page read is not a transactionally consistent snapshot. A changed desire can appear on the next five-second poll instead. This follows [ADR-0015](../adrs/0015-eventual-consistency-for-read-path.md), which accepts eventual consistency to avoid the latency and connection-pool cost of read transactions. The Applier must not treat an incomplete or failed list as an empty partition.
- The Applier collects all pages in a new view. It replaces its cached view only after the final page succeeds. If any page fails, it keeps the previous complete view.

### Failure, Retry, and Degraded Behavior

- **Non-retryable errors:** Return an error for invalid credentials, permissions, input, or ownership. The caller must correct the problem before it retries. A version conflict is different: the caller reads the desire again and retries ([Conflict Responses](#conflict-responses)).
- **Rate limits:** Honor the server's retry guidance before retrying.
- **Temporary failures:** Retry network failures, timeouts, and transient service failures with capped exponential backoff and jitter.
- **Suggested starting defaults:**
  - Initial delay: 1 second.
  - Maximum delay: 30 seconds.
  - Jitter: full jitter.
  - Retry window: 2 minutes.
  - These are implementation starting points and may be adjusted if security or operational requirements change.
- **API unavailable:** Continue using the most recent complete partition view. Do not delete local resources because of an API failure. After restart, wait for a successful partition read before reconciling.
