---
Status: Active
Owner: HyperFleet Team
Last Updated: 2026-08-18
---

# Multi-Tenant Identity and Authorization Design

## Table of Contents

- [Overview](#overview)
- [Problem Statement](#problem-statement)
- [Path A: OPA Integration](#path-a-opa-integration)
  - [Option: ext_authz pattern](#option-ext_authz-pattern)
  - [Option: Middleware hooks](#option-middleware-hooks)
  - [POC Results](#poc-results)
  - [Recommendation (superseded)](#recommendation-superseded)
- [Path B: Data Enrichment](#path-b-data-enrichment)
  - [JWT Claim Mapping](#jwt-claim-mapping)
  - [Schema Changes](#schema-changes)
  - [Query Filtering](#query-filtering)
- [Sentinel and Adapter Identity](#sentinel-and-adapter-identity)
  - [Option: Per-tenant Sentinel](#option-per-tenant-sentinel)
  - [Option: Shared Sentinel with system identity](#option-shared-sentinel-with-system-identity)
  - [Option: Auth-exempt internal routes](#option-auth-exempt-internal-routes)
  - [Recommendation](#recommendation)
  - [Event Pipeline Impact](#event-pipeline-impact)
- [Gateway vs Application-Layer Boundary](#gateway-vs-application-layer-boundary)
  - [Option: Gateway-first (JWT validation + tenant extraction at ingress)](#option-gateway-first-jwt-validation--tenant-extraction-at-ingress)
  - [Option: Application-only (superseded)](#option-application-only-superseded)
  - [Option: Sidecar/proxy (per-service auth)](#option-sidecarproxy-per-service-auth)
  - [Recommendation](#recommendation-1)
- [Recommended Approach](#recommended-approach)
- [Sizing Estimate](#sizing-estimate)
- [Open Questions](#open-questions)

---

## Overview

HyperFleet currently has no tenant isolation. All authenticated API consumers see all resources regardless of tenant. This spike evaluates approaches to enforce tenant-scoped resource visibility and produces a recommended design.

**Spike Ticket:** [HYPERFLEET-1165](https://issues.redhat.com/browse/HYPERFLEET-1165)

**Prior Research:**

- [HYPERFLEET-1134](https://issues.redhat.com/browse/HYPERFLEET-1134) explored OPA/Rego integration

**[ADR-0020](../adrs/0020-envoy-authorino-api-gateway.md) (2026-08-05):** All API traffic, external and internal, goes through an Envoy and Authorino gateway. Authorino authenticates every caller and injects identity and tenant headers. The API trusts these headers and does not extract claims itself.

This supersedes this document's original app-middleware and service-mesh phasing. Gateway deployment, AuthConfig CRs, machine-identity plumbing, and NetworkPolicy are covered by the sibling [Envoy and Authorino Gateway Deployment](https://redhat.atlassian.net/browse/HYPERFLEET-1476) epic and are out of scope here.

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
- Tenant identity (extracted from JWT claims)
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

### Recommendation (superseded)

**Middleware hooks** as the integration point for Path A. It avoids the service mesh dependency and works with HyperFleet's current infrastructure.

Why not ext_authz:

- Requires a service mesh (Envoy/Istio) that HyperFleet does not currently deploy.
- Adds infrastructure complexity for local development and testing.

Accepted trade-offs:

- Application coupled to OPA availability. Mitigated by fail-closed default (reject requests when OPA is unreachable), explicit timeouts, and OPA health checks.

Superseded: [Recommended Approach](#recommended-approach) drops Path A entirely, and [ADR-0020](../adrs/0020-envoy-authorino-api-gateway.md) rejects OPA outright (a policy engine cannot enforce row-level isolation without a database pre-fetch per request). This recommendation is retained for the historical record of what the spike evaluated.

---

## Path B: Data Enrichment

Add tenant identity to the data model and filter at the query layer. No external policy engine required.

### JWT Claim Mapping

**Current state:** Per the gateway decision, Authorino is the primary authenticator. It validates every caller and, on success, injects identity and tenant dimension values as trusted headers: `x-hyperfleet-identity` for caller identity, `x-hyperfleet-system` for the system-identity marker, and, in the reference implementation today, per-dimension headers such as `x-tenant-org` and `x-tenant-project`. See "Dimension-list propagation" below for why tenant dimensions are moving to a single JSON header instead. The API's tenant enforcement middleware reads only these injected headers for identity and tenant resolution. It does not extract tenant claims from the token itself.

Envoy also forwards the original bearer token to the API alongside the injected headers. The API retains in-app JWT validation as defense-in-depth (see [Gateway vs Application-Layer Boundary](#gateway-vs-application-layer-boundary)). If that validation fails, the request is rejected regardless of what the gateway already approved.

If the token's own claims (e.g. `sub`, tenant-related claims) disagree with the Authorino-injected headers, the injected headers govern. They are what the API trusts for identity and tenant dimensions, per [ADR-0020](../adrs/0020-envoy-authorino-api-gateway.md)'s "API trusts only injected headers" rule. The in-app validation is a second check on the token's validity, not a second source of identity.

Per-issuer claim mapping (which JWT claim maps to which tenant dimension) is declared in Authorino `AuthConfig` custom resources, not in HyperFleet application configuration. Each deployment's `AuthConfig` defines its own tenant dimensions and claim mappings. For example, an on-prem partner might map `hd`/`tid`/`org` claims to an `org` dimension, while an Oracle Cloud deployment maps tenancy OCID and compartment claims to `tenancy` and `compartment` dimensions.

The API's own JWT configuration must separately list each accepted issuer and its JWKS source, since its defense-in-depth validation needs to verify a token's signature independently of the gateway. Adding a tenant model or issuer is a configuration change on both sides (`AuthConfig` at the gateway, `JWTIssuerConfig` and tenant dimensions on the API), with zero code changes and no rebuild in any component.

**Header-to-tenant resolution:** Tenant identity is stored as a single JSONB tenancy map per resource. See [Schema Changes](#schema-changes) for the full evaluation.

**System-level bypass:** Internal callers (Sentinel, Adapters) authenticate at the gateway via Kubernetes TokenReview against a subject allowlist. They are not tenant-scoped. Authorino marks every caller with `x-hyperfleet-system`, true for these internal callers and false otherwise. The API's enforcement middleware branches on that header before reading any dimension header at all, for any caller. This is a hard requirement, not an optimization: a missing claim renders as the literal string `<nil>` rather than an absent header, so a dimension header cannot be trusted at face value without first knowing the caller isn't a system identity. See [Sentinel and Adapter Identity](#sentinel-and-adapter-identity) for the full evaluation.

**Runtime header validation:** Applies only to tenant-scoped callers, system callers take the bypass path above and skip it. A deployment's tenant model declares a fixed set of required and optional dimensions (e.g., org required, project optional), the same for every tenant-scoped caller in that deployment. Required dimension headers are guaranteed present, enforced by `AuthConfig` before headers render. Optional dimension headers are emitted only when the caller's underlying claim exists, and cleanly omitted otherwise.

A request is rejected with 403 before any DAO access if any of the following are true:

- it is missing a header its own rule expects
- an expected header value is empty
- it resolves zero dimensions (the matched rule expects none)

The middleware never falls back to an unscoped query.

See [Containment matching semantics](#query-filtering) for how callers scoped to fewer dimensions than a resource still match it, and why zero dimensions specifically must fail closed rather than fall back to unscoped.

**Dimension-list propagation:** No mechanism yet carries the expected-dimension list from the gateway to the API. The tenant model exists in two places that must be edited together: the `AuthConfig` CR and the API's own tenant config, rendered from Helm values. Keeping them in sync is a manual step, and a config-drift risk once multiple tenant models are live.

Two options:

- Per-dimension headers, with Authorino also asserting the expected dimension set. The API would validate against what the gateway asserts rather than a static list.
- Single JSON tenancy header. The API parses it directly as the containment operand.

**Recommendation:** Single JSON tenancy header. The API needs no dimension names at all, and one fixed header name means one fixed Envoy strip list. Authorino's `json` response type is a native, documented capability for composing multiple claims into one object, so this reuses the same `defaults`/emitted-header pattern `AuthConfig` already demonstrates with `hf_system`.

Why not per-dimension headers with an assertion: it leaves the Envoy strip-list gap open. The strip list is a hardcoded superset of every tenant model's headers, so a new dimension header not yet added to it remains client-forgeable. It also has no existing Authorino mechanism to build on for asserting an "expected dimension set," unlike the JSON header option.

### Schema Changes

Options for storing tenant identity on resources:

| Approach | Pros | Cons |
|----------|------|------|
| Fixed columns (`tenant_issuer` + `tenant_value`, composite index) | Unambiguous, no delimiter concerns | One dimension per resource. Cannot express multi-dimensional scoping (e.g., org + project). |
| Single `tenant_id` (concatenated string) | Simple single column | Delimiter choice must avoid collisions, same single-dimension limitation as fixed columns |
| Enrichment table (`resource_id`, `key`, `value`) | Multiple dimensions per resource, new dimensions added without schema migration | JOIN required on every query, extra round trip on write, harder to reason about containment across dimensions |
| Tenancy map (JSONB column with GIN index) | Multiple dimensions per resource, no JOIN, new dimensions added without schema migration, `@>` containment operator maps directly onto the matching semantics needed | Requires a GIN index to keep containment queries fast, less rigid typing than a normalized table |

**Recommendation:** JSONB tenancy map with a GIN index, validated end to end on the reference implementation (`poc/multitenancy-v2`). Each resource carries a single `tenancy` column holding its resolved dimensions as a flat key/value JSON object (e.g., `{"org": "acme-corp", "project": "platform"}`). A GIN index on the column supports the containment queries described in [Query Filtering](#query-filtering) without a JOIN. New dimensions are added without a schema migration. Existing resources still require a data backfill for a new key to be matched under containment.

Why not the others:

- **Fixed columns and single `tenant_id`** rejected because single-dimension scoping cannot isolate resources within a tenant. For example, it breaks when a user in org Y needs access to resources scoped to project Z.
- **Enrichment table** rejected in favor of JSONB. PostgreSQL's `@>` containment operator on a GIN-indexed JSONB column expresses the containment matching directly, avoiding a JOIN on every query and an extra write per dimension.

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

**Containment matching semantics:** A caller is authorized for a resource when the caller's resolved tenancy map is a subset of the resource's tenancy map. Every dimension the caller has must be present on the resource with an equal value, but the resource may carry additional dimensions the caller doesn't have. This is what makes an org-scoped caller (resolved dimensions: `{org: acme}`, because their token carries no optional project claim) see all of that org's projects: a resource scoped to `{org: acme, project: platform}` is a superset and matches. A caller scoped to `{org: acme, project: platform}` does not match a resource scoped to `{org: acme, project: other}`, because the value for the shared `project` key differs.

**Fail-closed rule for zero dimensions:** A request that resolves zero tenant dimensions must be rejected with 403. Under containment semantics, an empty caller map (`{}`) is a subset of every resource's tenancy map. It would contain-match every row, the opposite of isolation. This is enforced in the same place as [runtime header validation](#jwt-claim-mapping): before any DAO access.

**Uniqueness matches differently than visibility:** Resource name uniqueness (HYPERFLEET-1473, [hyperfleet-api#344](https://github.com/openshift-hyperfleet/hyperfleet-api/pull/344)) is enforced by a unique index on `(kind, name, tenancy)`, matched by exact tenancy-document equality, not containment, which is how reads match. A caller scoped to `{org: acme}` and one scoped to `{org: acme, project: p1}` are different tenancy documents, so both can create a resource named `prod`; the `{org: acme}` caller then sees two resources named `prod` under containment-based listing. This can't be fixed by a cleverer index: uniqueness over a containment relation isn't expressible by a btree. This is scoped to root resources: child resources (`owner_id IS NOT NULL`) stay unique on `(kind, owner_id, name)`, excluding tenancy entirely, since their isolation is transitive through the globally-unique owner. Rows with `tenancy = '{}'` reproduce the old global-uniqueness behavior among themselves, since they all share the identical empty tenancy document. These are resources created before enforcement is enabled; see [Open Questions](#open-questions) for the rollout-ordering implications.

**Parameterization invariant:** Tenant dimension values originate from gateway-injected trusted headers, which are sourced from JWT claims resolved per `AuthConfig`. These values are externally controlled. DAO filtering must bind them as query parameters. String interpolation or dynamically constructed predicate fragments from header values are prohibited, regardless of how trusted the gateway is presumed to be. This prevents a compromised or misconfigured `AuthConfig` from using a crafted claim value to alter the query itself.

**Write-path enforcement:** Tenant fields are never accepted from the request body. On resource creation, the API derives the tenancy map from the caller's gateway-injected trusted headers and writes it to the resource's `tenancy` column. This value is immutable after creation. Update requests that attempt to modify it are rejected.

**System-identity writes:** System identities (Sentinel, Adapter) do not create new tenant-scoped resources. They update existing resources where tenant fields are already set and immutable. The system identity write contract is: update status and conditions only, never modify or set tenant ownership fields.

**Destructive blast radius:** The `status`/`conditions` writable-field limit does not bound what a system identity can destroy. Per [ADR-0012](../adrs/0012-hard-delete-mechanism-after-adapter-reconciliation.md), a status write is what triggers permanent deletion: the API hard-deletes a resource inside the same `POST /adapter_statuses` request that computes `Reconciled=True`. A leaked or buggy adapter token can therefore drive any resource in any tenant to hard deletion, with no recovery path, regardless of the writable-field restriction. Restricting delete access for system identities is precluded by this mechanism.

**Enforcement:** This rule must be enforced in code, not just documented as a policy. Tenant fields must be excluded from the writable field set for every caller, regardless of identity type. For system identities specifically, the update handler must further restrict the writable set to only `status` and `conditions`. That way, no code path can modify tenant fields or any other resource field.

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

Single Sentinel authenticates through the same Envoy and Authorino gateway as external traffic. Authorino validates its projected service account token via Kubernetes TokenReview against a subject allowlist (e.g., `system:serviceaccount:hyperfleet:sentinel`). It marks the caller as a system identity via `x-hyperfleet-system`, which the middleware checks before reading any dimension header, since a service account token carries no tenant claims and a dimension header read for this caller cannot be trusted.

Pros:

- Matches the gateway decision: internal traffic is not exempt from the gateway. It authenticates through it via a different `AuthConfig` rule (TokenReview instead of OIDC).
- No new deployment topology needed.
- Subject allowlist is a gateway configuration change, not application code.
- No per-tenant operational overhead for internal services.

Cons:

- If the service account token leaks, and the subject remains on the allowlist, an attacker gains system-identity access to all tenants' resources.
- Requires the subject allowlist to be kept current. An in-cluster service account with the correct audience but an unlisted subject is denied at the gateway, so allowlist drift can also cause outages.
- Audit trail shows "system" as the actor, not the original tenant who triggered the action.

### Option: Auth-exempt internal routes

API exposes a separate internal listener (different port) with no authentication or tenant filtering. Sentinel/Adapter traffic uses this port. Kubernetes NetworkPolicy restricts access to only internal pods.

This option is foreclosed by the gateway decision: [ADR-0020](../adrs/0020-envoy-authorino-api-gateway.md) requires all API traffic, external and internal, to pass through the gateway, with a NetworkPolicy restricting API pod ingress to the gateway only. It is retained here for the historical record of what was evaluated during the spike.

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

**Shared Sentinel with system identity, authenticated at the gateway.**
This aligns with the gateway decision. It requires no new deployment topology and reuses the subject-allowlist mechanism already established for internal callers in [ADR-0020](../adrs/0020-envoy-authorino-api-gateway.md).

Why not the others:

- **Per-tenant Sentinel** rejected because operational overhead scales linearly with tenants. It also contradicts Sentinel's stateless, label-based sharding design.
- **Auth-exempt internal routes** rejected: it removes all identity from internal requests. It is also foreclosed by ADR-0020, which requires that no route to the API bypasses the gateway.

Accepted trade-offs:

- System-identity blast radius is larger than a tenant-scoped identity. Mitigated by short-lived tokens (projected ServiceAccount tokens auto-rotate), the gateway's subject allowlist, and the NetworkPolicy restricting which pods can reach the API at all.
- Audit trail shows the service account name, not the original user. Mitigated by correlating existing `created_by` (original user) and `updated_by` (system service) fields on the resource.

### Event Pipeline Impact

The event contract (kind, id, href, generation) does not change. Tenant context is not carried in CloudEvents because:

- Sentinel polls the API with system identity (no tenant filter) and publishes resource identifiers only
- Adapters fetch full resource details from the API with system identity, receiving tenant identity as part of the resource payload
- No component in the event pipeline needs to filter by tenant; filtering happens at the API boundary for external consumers

---

## Gateway vs Application-Layer Boundary

Where does each responsibility live in the request pipeline?

| Responsibility | Gateway (Envoy + Authorino) | Application (hyperfleet-api) |
|----------------|------------------------------|-------------------------------|
| JWT / token validation | Authorino validates every caller: OIDC for external callers, Kubernetes TokenReview for internal callers | Retains in-app JWT validation as defense-in-depth; rejects the request if the token itself is invalid, but does not override the gateway's decision |
| Tenant claim extraction | Authorino resolves tenant dimensions from validated claims per `AuthConfig` and injects them as trusted headers | None. The API does not extract identity or tenant claims from the token; injected headers are authoritative even if token claims disagree |
| Rate limiting | Per-tenant throttling at network edge | Per-handler or global in-process |
| Tenant filtering | N/A (no DB access) | DAO layer scopes queries to caller's tenant by containment |

See [JWT Claim Mapping](#jwt-claim-mapping) for the full authentication contract, including bearer token forwarding and the precedence of injected headers over token claims.

### Option: Gateway-first (JWT validation + tenant extraction at ingress)

Pros:

- Bad requests rejected before hitting application pods. Saves compute.
- Centralized auth config if HyperFleet adds more services in the future.
- Applies uniformly to external and internal traffic: Sentinel and Adapters authenticate at the same gateway via TokenReview, they are not a separate code path.
- Switching a tenant model or adding an identity provider is a configuration change on both sides (`AuthConfig` at the gateway, `JWTIssuerConfig` and tenant dimensions on the API), with zero code changes and no rebuild.

Cons:

- Coupled to a specific ingress/authorization stack (Envoy, Authorino). Local development and testing must account for the gateway rather than calling the API directly.
- Two places to hold auth-relevant configuration: `AuthConfig` CRs at the gateway, and the API's tenant dimension config for DAO enforcement.

### Option: Application-only (superseded)

Pros:

- Portable. Works anywhere without infrastructure dependencies.
- Single source of truth for auth logic (Go middleware).
- Testable without infrastructure: no gateway to simulate in unit/integration tests.

Cons:

- Every request (including invalid ones) reaches the application before being rejected.
- If HyperFleet adds more services in the future, each would reimplement the same auth logic.
- No structural network boundary: nothing prevents a workload from calling the API pod directly and bypassing authentication entirely.

### Option: Sidecar/proxy (per-service auth)

Auth proxy (e.g., Envoy sidecar) runs alongside each service pod. JWT validation and tenant extraction happen in the proxy before the request reaches the application.

Pros:

- Auth logic decoupled from application code. Partners can configure auth rules without modifying HyperFleet.
- Applies to both external and internal traffic (Sentinel/Adapter to API).
- Reusable across services without reimplementing middleware.

Cons:

- Does not provide a single ingress point for external callers the way a gateway does.
- Adds operational complexity: sidecar config, resource overhead per pod, debugging across proxy and application logs.
- Harder to test locally without the sidecar running.

### Recommendation

**Gateway-first**, per [ADR-0020](../adrs/0020-envoy-authorino-api-gateway.md). Envoy is the API ingress proxy and Authorino the external authorization service for all traffic, external and internal. Authorino performs authentication and tenant claim extraction. The API consumes trusted injected headers and does not extract claims itself. In-app JWT validation is retained as defense-in-depth, not as the primary authentication mechanism.

This supersedes this document's original phased plan (application middleware first, service mesh sidecar later). The gateway decision also resolves the sidecar/proxy option's biggest open question (how to establish a trusted identity-propagation boundary). It does so directly, through early header stripping before the authorization filter runs, trusted header injection after, and a NetworkPolicy restricting API pod ingress to the gateway only.

Why not application-only:

- No structural network boundary. Bypassing auth by calling the API pod directly was possible.
- Identity and tenant-model configuration lived in application code, requiring a rebuild to change.

Why not per-service sidecar without a shared gateway:

- Does not provide a single ingress point or audit point for external callers. A gateway can still be layered with sidecars later without changing the trust model established here.

Accepted trade-offs:

- The gateway is on the availability path of every API call, including internal Sentinel and Adapter traffic. A gateway outage is a full API outage.
- All internal services must route API traffic through the gateway. Pointing directly at the API service is rejected by the NetworkPolicy.

---

## Recommended Approach

**Path B (DAO-layer filtering) as the tenant isolation mechanism.** Path A (OPA) is dropped and out of scope. As the POC confirmed, a policy engine cannot enforce row-level isolation without a database pre-fetch on every request. Partners can still layer a policy engine behind the gateway later for coarse-grained ABAC policies if needed, but it is not part of this design.

Rationale:

- Row-level tenant isolation can only be guaranteed at the data layer. Path B enforces it there directly, with implicit containment filtering at the DAO layer.
- Path B requires no additional infrastructure (no OPA deployment, no bundle server).
- Combined with the gateway decision, Path B is the minimum viable solution: the gateway authenticates and injects tenant headers, and the DAO layer scopes every read, list, delete, and existence check by containment.

Trade-offs:

- A new query path that bypasses the implicit filter (e.g., raw SQL) could expose cross-tenant data. This is mitigated by code review, integration tests per access path, and prohibiting string-built tenant predicates.
- System identity bypass creates a higher-privilege tier. A leaked or misconfigured system-identity token grants read access to all tenants, and its write access, though restricted to `status` and `conditions`, can still drive any resource in any tenant to permanent hard deletion (see [System-identity writes](#query-filtering)), with no recovery path. This is mitigated by short-lived tokens, the gateway's subject allowlist, and the NetworkPolicy restricting which pods can reach the API, though none of these bound the destructive blast radius if a token is actually compromised.

---

## Sizing Estimate

Matches this epic's ([HYPERFLEET-1164](https://issues.redhat.com/browse/HYPERFLEET-1164)) remaining story decomposition. Caller identity context plumbing already exists ([HYPERFLEET-1134](https://issues.redhat.com/browse/HYPERFLEET-1134)). Gateway deployment, `AuthConfig` CRs, and machine-identity plumbing are sized under the sibling [Envoy and Authorino Gateway Deployment](https://redhat.atlassian.net/browse/HYPERFLEET-1476) epic and are not sized here. Each story includes unit tests, end-to-end tenant isolation coverage is its own story.

| Story | Description | Estimate |
|-------|-------------|----------|
| Implement tenant configuration and enforcement middleware | Add tenant configuration and middleware that resolves caller context from gateway-injected trusted headers, failing closed if a dimension is missing | 5 pts |
| Add the resources tenancy column and GIN index | Add a JSONB `tenancy` column with a GIN index and migration | 3 pts |
| Add the read-only tenancy map to the Resource spec | Add a server-populated, read-only tenancy map to the Resource spec, absent from create and patch schemas | 3 pts |
| Scope all resource DAO access by tenancy containment | Scope every read, list, delete, and existence check by JSONB containment; system identities bypass scoping on reads only | 8 pts |
| Server-set tenancy on the resource write path | Derive tenancy from gateway-injected identity on create; keep it immutable and rejected on patch | 3 pts |
| Restrict system-identity writes to status and conditions | Restrict system identities to writing only `status` and `conditions`, enforced in code | 5 pts |
| Make resource name uniqueness tenant-scoped | Scope resource name uniqueness to tenancy so it doesn't leak existence across tenants | 3 pts |
| Expose tenant configuration in the Helm chart | Expose the tenant model decided in [JWT Claim Mapping](#jwt-claim-mapping) (a single JSON tenancy header) via the Helm chart | 3 pts |
| Build the tenant isolation integration suite | Build the integration test suite covering tenant isolation across all access paths | 5 pts |
| **Total** | | **~38 pts** |

---

## Open Questions

- Are there compliance requirements that mandate RLS as a hard requirement (vs. defense-in-depth)?
- What is the expected tenant count at GA? (Impacts whether per-tenant options are viable, and affects indexing strategy.)
- Does a caller's scope need to be asserted independently of tenant claims? (A claim that silently stops being emitted would broaden a caller's visibility under containment, not deny it.)
- Should resource name uniqueness be canonicalized to one dimension, or is duplicate name visibility across broader scopes accepted? (See [Query Filtering](#query-filtering) for the confirmed exact-match-vs-containment mismatch behind this.)
- Can a caller create a resource into a narrower scope than their own? (Creation stamps exactly the creator's dimensions; containment only widens visibility as a caller's map shrinks, never the reverse.)
- What's the cutover order for enabling tenant enforcement against existing resources? (Every pre-existing row defaults to `{}` tenancy, and no non-empty caller map is a subset of `{}`. The moment enforcement turns on, every existing resource becomes invisible to tenant-scoped callers, visible only to system identities.)
