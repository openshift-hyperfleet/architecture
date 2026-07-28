---
Status: Active
Owner: HyperFleet Team
Last Updated: 2026-07-23
---

# Multi-Tenant Identity and Authorization Design

## Table of Contents

- [Overview](#overview)
- [Problem Statement](#problem-statement)
- [Path A: OPA Integration](#path-a-opa-integration)
  - [Option: ext_authz pattern](#option-ext_authz-pattern)
  - [Option: Middleware hooks](#option-middleware-hooks)
  - [POC Results](#poc-results)
  - [Recommendation](#recommendation)
- [Path B: Data Enrichment](#path-b-data-enrichment)
  - [JWT Claim Mapping](#jwt-claim-mapping)
  - [Schema Changes](#schema-changes)
  - [Query Filtering](#query-filtering)
- [Sentinel and Adapter Identity](#sentinel-and-adapter-identity)
  - [Option: Per-tenant Sentinel](#option-per-tenant-sentinel)
  - [Option: Shared Sentinel with system identity](#option-shared-sentinel-with-system-identity)
  - [Option: Auth-exempt internal routes](#option-auth-exempt-internal-routes)
  - [Recommendation](#recommendation-1)
  - [Event Pipeline Impact](#event-pipeline-impact)
- [Gateway vs Application-Layer Boundary](#gateway-vs-application-layer-boundary)
  - [Option: Gateway-first](#option-gateway-first-jwt-validation--tenant-extraction-at-ingress)
  - [Option: Application-only](#option-application-only-current-approach)
  - [Recommendation](#recommendation-2)
- [Recommended Approach](#recommended-approach)
- [Sizing Estimate](#sizing-estimate)
- [Open Questions](#open-questions)

---

## Overview

HyperFleet currently has no tenant isolation. All authenticated API consumers see all resources regardless of tenant. This spike evaluates approaches to enforce tenant-scoped resource visibility and produces a recommended design.

**Spike Ticket:** [HYPERFLEET-1165](https://issues.redhat.com/browse/HYPERFLEET-1165)

**Prior Research:**

- [HYPERFLEET-1134](https://issues.redhat.com/browse/HYPERFLEET-1134) explored OPA/Rego integration

## Problem Statement

- Partners need to isolate resources by tenant identity not currently captured
- HyperFleet must support multiple IdPs (Google, Azure, Keycloak, OCM) with different claim structures for current and future partners
- No tenant isolation mechanism currently exists for partners to use

---

## Path A: OPA Integration

OPA (Open Policy Agent) is a general-purpose policy engine. It evaluates authorization decisions using Rego (its declarative policy language) against structured input (request context, resource attributes).

This path is more flexible (fine-grained ABAC (Attribute-Based Access Control), cross-cutting policies) but requires additional infrastructure (OPA deployment, Rego policies). The following sub-sections evaluate integration patterns.

### Option: ext_authz pattern

Envoy-style external authorization where the gateway or sidecar calls OPA before the request reaches HyperFleet.

How it works: Envoy intercepts the request, sends a check request to OPA with caller identity, resource attributes, and tenant metadata. OPA returns allow/deny. If denied, the request never reaches the API.

Context HyperFleet would need to expose:

- Caller identity (JWT `sub`, `iss`)
- Tenant identity (extracted `tenant_claim` value)
- Resource type and ID (from the URL path)
- HTTP method (GET, POST, DELETE, etc.)

Pros:

- Decoupled from application code. Partner teams write Rego policies without touching HyperFleet.
- Enforced at the network layer. Even if application code has a bug, OPA blocks unauthorized access.
- Standard pattern in service mesh environments (Istio, Envoy natively support it).

Cons:

- Requires a service mesh (Envoy/Istio). HyperFleet does not currently deploy one.
- Adds latency to every request (network hop to OPA sidecar).
- Debugging auth failures requires understanding Rego and Envoy logs, not just application logs.
- Harder to test locally without the full mesh infrastructure.

### Option: Middleware hooks

Go middleware within HyperFleet that calls an OPA endpoint directly via HTTP.

How it works: A middleware function sends a JSON policy query to OPA before the handler runs. OPA responds with allow/deny. No sidecar or service mesh required. OPA can run as a separate deployment in the cluster or as a sidecar container in the same pod.

Pros:

- No service mesh dependency. Works with HyperFleet's current infrastructure.
- Testable without OPA running (mock the OPA HTTP response in unit tests).
- Partner teams write Rego policies and deploy their own OPA instance.

Cons:

- Couples the API to OPA availability. If OPA is down, requests fail.
- HyperFleet code must construct the policy input (caller identity, resource attributes, tenant metadata) for each request.
- Less standardized than ext_authz. Partner teams interact with HyperFleet's specific middleware contract, not a generic Envoy interface.

### POC Results

- Go middleware constructs policy input from JWT claims and request context (resource type, HTTP method), then queries OPA via HTTP
- OPA running as a Docker container (equivalent to a sidecar in production)
- Rego policy enforcing tenant-scoped access: only callers with a matching tenant identity are allowed
- Policy loaded into OPA without touching HyperFleet application code
- Fail-closed behavior: 503 when OPA is unreachable, 403 when policy denies

**Key findings:**

- OPA middleware runs before the database query. It can enforce coarse-grained rules (does this caller have a tenant identity? can they access this resource type?) but cannot do resource-level tenant matching.
- Resource-level tenant matching (does this resource belong to this caller's tenant?) requires a DB lookup that happens after the middleware. Adding this to Path A would require a pre-fetch query on every request.
- Full tenant isolation requires Path B (DAO-layer filtering) regardless of whether Path A is adopted.

### Recommendation

**Middleware hooks** as the integration point for Path A. It avoids the service mesh dependency and works with HyperFleet's current infrastructure.

Why not ext_authz:

- Requires a service mesh (Envoy/Istio) that HyperFleet does not currently deploy.
- Adds infrastructure complexity for local development and testing.

Accepted trade-offs:

- Application coupled to OPA availability. Mitigated by fail-closed default (reject requests when OPA is unreachable), explicit timeouts, and OPA health checks.

---

## Path B: Data Enrichment

Add tenant identity to the data model and filter at the query layer. No external policy engine required.

### JWT Claim Mapping

**Current state:** The API already supports multi-issuer JWT configuration (`JWTConfig` with `[]JWTIssuerConfig`). The config below extends this with a `tenant_claim` field per issuer to extract tenant identity.

Each JWT issuer can carry tenant identity in a different claim. The API config maps issuer to claim:

```yaml
jwt:
  configs:
    # Google
    - issuer_url: "https://accounts.google.com"
      jwk_cert_url: "https://www.googleapis.com/oauth2/v3/certs"
      identity_claim: "email"
      tenant_claim: "hd"
    # Azure
    - issuer_url: "https://login.microsoftonline.com/{tenant-id}/v2.0"
      jwk_cert_url: "https://login.microsoftonline.com/{tenant-id}/discovery/v2.0/keys"
      identity_claim: "sub"
      tenant_claim: "tid"
    # Keycloak
    - issuer_url: "https://sso.example.com/realms/hyperfleet"
      jwk_cert_url: "https://sso.example.com/realms/hyperfleet/protocol/openid-connect/certs"
      identity_claim: "email"
      tenant_claim: "org"
    # OCM (OpenShift Cluster Manager)
    - issuer_url: "https://api.openshift.com"
      jwk_cert_url: "https://api.openshift.com/.well-known/jwks.json"
      identity_claim: "sub"
      tenant_claim: "org_id"
```

`tenant_claim` is configurable per issuer because each IdP puts org identity in a different field. Middleware extracts the value and sets it in the request context.

**Claim-to-tenant resolution:** Tenant identity is stored as two separate NOT NULL columns (`tenant_issuer`, `tenant_value`) with a composite index for query filtering. This models the composite identity as separate fields, avoiding delimiter conventions.

**System-level bypass:** Issuers with `system: true` explicitly set (e.g., Sentinel and Adapter service account issuers) skip tenant filtering entirely. Issuers must have exactly one of `tenant_claim` or `system: true`. Having neither or both is rejected at startup with a configuration validation error. This fail-closed design prevents accidental cross-tenant access from misconfigured issuer entries. See [Sentinel and Adapter Identity](#sentinel-and-adapter-identity) for the full evaluation.

**Runtime claim validation:** If a token from a tenant-scoped issuer (one with `tenant_claim` configured) does not contain the expected claim, or the claim value is empty or non-string, the request is rejected with 403 before any DAO access. The middleware never falls back to an unscoped query.

### Schema Changes

Options for storing tenant identity on resources:

| Approach | Pros | Cons |
|----------|------|------|
| `tenant_issuer` + `tenant_value` (two string columns, composite index) | Unambiguous, no delimiter concerns | Two columns instead of one, requires composite index |
| Single `tenant_id` (concatenated string) | Simple single column | Delimiter choice must avoid collisions |
| Flexible metadata map (JSONB) | Extensible, supports multiple attributes | Harder to index, query, and enforce constraints |

**Recommendation:** `tenant_issuer` + `tenant_value` with a composite index. Models the composite identity (issuer + claim) as separate fields rather than a serialized string.

Considerations:

- HyperFleet is pre-production. Schema changes do not require a migration strategy for existing production data.

### Query Filtering

Options:

| Approach | Pros | Cons |
|----------|------|------|
| Implicit tenant scoping on all queries | Safer (can't forget it), enforced at DAO layer | Less flexible, internal services (Sentinel, Adapter) need a bypass |
| Explicit query parameter | More flexible, caller decides scope | Easy to forget, creates a security hole if someone omits it |
| PostgreSQL Row-Level Security (RLS) | Database-level enforcement as safety net | Requires setting a session variable per request, adds complexity to connection pooling |

**Recommendation:** Use implicit filtering at the DAO layer. It prevents accidental cross-tenant data leaks because developers can't forget the WHERE clause. Internal services that need cross-tenant access (Sentinel, Adapter) would use a bypass mechanism (see Sentinel/Adapter Identity section). RLS can be layered on top as defense-in-depth but should not be the sole mechanism.

**Write-path enforcement:** Tenant fields are never accepted from the request body. On resource creation, the API derives `tenant_issuer` and `tenant_value` from the caller's JWT token (issuer URL + extracted claim value) and sets them on the resource. These fields are immutable after creation; update requests that attempt to modify them are rejected.

**System-identity writes:** System identities (Sentinel, Adapter) do not create new tenant-scoped resources. They update existing resources where tenant fields are already set and immutable. The system identity write contract is: update status and conditions only, never modify or set tenant ownership fields.

---

## Sentinel and Adapter Identity

Internal services need cross-tenant access. Implicit DAO filtering blocks this by default. The following are options to grant a bypass.

### Option: Per-tenant Sentinel

Each tenant gets their own Sentinel instance, scoped to watch only that tenant's resources.

Pros:

- Clean isolation. One tenant's Sentinel can't accidentally touch another tenant's resources.
- If one tenant's Sentinel crashes, others are unaffected.
- Simple security model: no cross-tenant access to design around.

Cons:

- Operational overhead scales linearly with tenants. 100 tenants = 100 Sentinel deployments.
- Config duplication: each instance needs its own config, secrets, broker subscriptions.
- Contradicts Sentinel's current design (stateless, label-based sharding for horizontal scaling, not tenant-based partitioning).
- Monitoring and alerting complexity multiplies per tenant.

### Option: Shared Sentinel with system identity

Single Sentinel authenticates with a service account JWT (e.g., `sub: "sentinel-service-account"`) configured with `system: true` (see [JWT Claim Mapping](#jwt-claim-mapping)).

Pros:

- Matches current architecture. No new deployment topology needed.
- Reuses the config-driven bypass (`system: true` = no filter). No new code patterns required.
- Single instance scales horizontally via label-based sharding as today.
- No per-tenant operational overhead for internal services.

Cons:

- If the system token leaks, attacker has access to all tenants' resources.
- Requires strong controls to prevent external clients from using the system identity: dedicated internal audience, restricted issuer, and network-level enforcement.
- Audit trail shows "system" as the actor, not the original tenant who triggered the action.

### Option: Auth-exempt internal routes

API exposes a separate internal listener (different port) with no authentication or tenant filtering. Sentinel/Adapter traffic uses this port. Kubernetes NetworkPolicy restricts access to only internal pods.

Pros:

- Least code for internal services. No token management, no issuer config, no credential rotation.
- No JWT overhead on internal calls (no signature verification, no JWKS fetching).
- Clear separation: external port = tenant-scoped, internal port = unrestricted.

Cons:

- No identity on internal requests. Audit trail has no "who" for updates made by internal services.
- Any compromised pod on the internal network gets full unauthenticated API access. Blast radius is the entire cluster, not just one service.
- Security relies entirely on network-layer controls (NetworkPolicy). A misconfigured policy silently grants full access.
- Harder to reason about in security audits. "Some routes have no auth" raises flags.

### Recommendation

**Shared Sentinel with system identity.** It aligns with the current architecture, requires no new deployment topology, and reuses the config-driven bypass already designed in JWT Claim Mapping.

Why not the others:

- **Per-tenant Sentinel** rejected because operational overhead scales linearly with tenants and contradicts Sentinel's stateless, label-based sharding design.
- **Auth-exempt internal routes** rejected because it removes all identity from internal requests, leaving no audit trail and relying entirely on network policy for security.

Accepted trade-offs:

- System token blast radius is larger than a tenant-scoped token. Mitigated by short-lived tokens (projected ServiceAccount tokens auto-rotate), Kubernetes NetworkPolicy restricting which pods can reach the API, and mTLS for transport encryption (if a service mesh is deployed).
- Audit trail shows the service account name, not the original user. Mitigated by correlating existing `created_by` (original user) and `updated_by` (system service) fields on the resource.

### Event Pipeline Impact

The event contract (kind, id, href, generation) does not change. Tenant context is not carried in CloudEvents because:

- Sentinel polls the API with system identity (no tenant filter) and publishes resource identifiers only
- Adapters fetch full resource details from the API with system identity, receiving tenant identity as part of the resource payload
- No component in the event pipeline needs to filter by tenant; filtering happens at the API boundary for external consumers

---

## Gateway vs Application-Layer Boundary

Where does each responsibility live in the request pipeline?

| Responsibility | Gateway (ingress) | Application (Go middleware) |
|----------------|-------------------|-----------------------------|
| JWT signature validation | Rejects invalid tokens before they hit the API pod | Current approach; handled in middleware |
| Tenant claim extraction | Inject as header from gateway | Read directly from JWT in middleware |
| Rate limiting | Per-tenant throttling at network edge | Per-handler or global in-process |
| Tenant filtering | N/A (no DB access) | DAO layer scopes queries to caller's tenant |

### Option: Gateway-first (JWT validation + tenant extraction at ingress)

Pros:

- Bad requests rejected before hitting application pods. Saves compute.
- Centralized auth config if HyperFleet adds more services in the future.
- Clear separation: gateway handles AuthN, application handles AuthZ.

Cons:

- Coupled to a specific ingress controller (Envoy, Istio). Harder to test locally without mimicking the gateway.
- Two places to maintain auth config (gateway rules + application config).
- Tenant extraction logic duplicated since the application already reads the JWT for other claims (e.g., `sub` for audit fields).

### Option: Application-only (current approach)

Pros:

- Portable. Works anywhere without infrastructure dependencies.
- Single source of truth for auth logic (Go middleware).
- Testable without infrastructure: no gateway to simulate in unit/integration tests.

Cons:

- Every request (including invalid ones) reaches the application before being rejected.
- If HyperFleet adds more services in the future, each would reimplement the same auth logic.

### Recommendation

**Application-only for now.** JWT validation and tenant extraction both happen in Go middleware. The middleware performs full JWT validation: signature verification via JWKS, issuer matching, audience validation, expiration (required), and algorithm allowlist (RS256). Only the API receives external traffic; Sentinel and Adapter are internal-only. There's no multi-service gateway benefit. The middleware approach is portable and doesn't depend on NetworkPolicy for security (the JWT signature itself prevents spoofing).

Gateway-layer validation can be added later as a performance optimization without changing application code (defense-in-depth, not replacement).

Accepted trade-offs:

- Invalid requests consume application resources before rejection. Acceptable at current scale; gateway-layer rejection can be added later without application changes.
- Only one service is externally-facing today. If additional services need JWT validation in the future, that is the trigger to either extract a shared auth module or adopt a gateway layer.

---

## Recommended Approach

**Path B (DAO-layer filtering) as the primary tenant isolation mechanism.** Path A (OPA) is optional and can be layered on later for fine-grained ABAC policies.

Rationale:

- The POC confirmed that OPA cannot enforce row-level tenant isolation without a DB pre-fetch on every request. Path B handles this naturally with implicit tenant filtering at the DAO layer.
- Path B requires no additional infrastructure (no OPA deployment, no bundle server, no sidecar).
- Path B is the minimum viable solution: add tenant columns, extract claim in middleware, scope all DAO queries.

Trade-offs:

- Path B is less flexible than Path A. Authorization logic lives in HyperFleet application code, not in an externally configurable policy engine.
- A new query path that bypasses the implicit filter (e.g., raw SQL) could expose cross-tenant data. Mitigated by code review, integration tests, and restricting raw queries.
- System identity bypass (`system: true`) creates a higher-privilege tier. A leaked system token grants access to all tenants. Mitigated by short-lived tokens and network-level restrictions.

---

## Sizing Estimate

Preliminary estimates. Caller identity context plumbing already exists ([HYPERFLEET-1134](https://issues.redhat.com/browse/HYPERFLEET-1134)). Each phase includes unit and integration tests.

| Phase | Description | Estimate |
|------|-------------|----------|
| JWT claim mapping | Extract tenant identity from JWT claims per issuer, propagate through request context | 5 pts |
| API spec changes | Add tenant identity fields to resource models | 3 pts |
| Schema change | Add `tenant_issuer` and `tenant_value` columns with composite index | 3 pts |
| DAO filtering | Scope all queries to caller's tenant, allow system identity bypass | 8 pts |
| API integration | Reject requests missing tenant identity, surface clear error responses | 5 pts |
| Sentinel/Adapter identity | Establish system identity for internal services: token acquisition, dedicated audience, middleware bypass wiring | 5 pts |
| Helm + documentation | Expose tenant configuration in Helm chart, update deployment and config docs | 3 pts |
| E2E tests | Verify cross-tenant access is denied end-to-end | 5 pts |
| **Total** | | **~37 pts** |

---

## Open Questions

- Are there compliance requirements that mandate RLS as a hard requirement (vs. defense-in-depth)?
- What is the expected tenant count at GA? (Impacts whether per-tenant options are viable, and affects indexing strategy.)
