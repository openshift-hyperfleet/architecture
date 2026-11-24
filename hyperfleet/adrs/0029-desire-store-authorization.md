---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-11-18
---

# 0029 - Desire Store Authorization

## Context

[ADR-0022](0022-api-mediated-desire-store-access.md) requires Desire Store clients to use the Hub API rather than connect directly to Postgres or receive Hub/database credentials. The three data-caller classes have different partition scopes: remote Appliers use one management-cluster partition, while Adapters and the centralized sweeper target a partition per request. The caller, trust, and partition-source rules must be consistent across the gateway and API.

## Decision

**Partial supersession:** [ADR-0039](0039-sweeper-partition-enumeration.md) replaces the universal partition-scope requirement below only for sweeper-only partition metadata enumeration. That operation uses an operation-scoped Wristband without a partition. All desire-record operations retain their existing partition and caller rules; API-mediated access and signed Wristband trust remain mandatory.

The Desire Store has three caller classes:

| Caller | Identity and scope | Partition behavior |
|--------|-------------------|--------------------|
| Remote Applier | Management-cluster service-account identity | Bound to exactly one registered partition |
| Adapter | Hub service identity with authorized fleet-wide access | Selects an authorized target partition per request |
| Centralized sweeper | Hub service identity with authorized fleet-wide access | Selects an authorized target partition per cleanup request |

### Remote Appliers

Remote Appliers use projected Kubernetes service-account JWTs issued by their management cluster. The Hub:

- validates the registered issuer, audience, and service-account subject;
- maps the identity `(issuer, subject, audience)` to exactly one partition through AuthConfig; and
- uses that verified binding, not a partition claim in the token, as the partition source.

The Hub operator controls binding onboarding, replacement, and disablement. Authorization changes must have a bounded propagation delay and an emergency invalidation path independent of cache expiry; the Detailed Design will define the TTL and invalidation mechanism.

### Adapters and sweeper

The Adapter and centralized sweeper use authenticated Hub service identities. They may select a target partition per request, but only within their authorized fleet-wide access.

### Gateway-to-API trust

Authorino validates the originating credential and issues an internal signed Hub Wristband containing the caller identity, caller class, and authorized partition:

- For a remote Applier, the partition comes from its fixed AuthConfig binding.
- For the Adapter or sweeper, the partition is the authorized target for that request.

Envoy forwards the Wristband to the API, where its validated claims are the trusted identity and partition source for authorization. It is an internal gateway-to-API token; client-supplied partition headers and raw management-cluster JWT claims are not authoritative.

### Relationship to ADR-0022

[ADR-0022](0022-api-mediated-desire-store-access.md) still governs API-mediated access, mandatory partition enforcement, and the prohibition on direct Postgres access. For Desire Store endpoints, this ADR replaces only the conflicting caller-scope and trust wording. This replacement applies only to Desire Store endpoints; all other decisions remain in force. The resulting changes are:

- **Caller scope:** Remote Appliers remain fixed to one registered partition; Adapters and the sweeper may select an authorized target per request.
- **Trust source:** The API authorizes from the signed Wristband, not injected headers or raw JWT claims.

## Consequences

**Gains:** Each caller class has an explicit scope; remote Applier partition ownership is centrally controlled; Adapters and the sweeper can perform authorized fleet cleanup; and the existing Envoy/Authorino security model remains in use.

**Trade-offs:** AuthConfig reconciliation and JWKS, token, or Wristband caching can delay onboarding, replacement, or revocation; fleet-wide callers require per-request target validation to prevent cross-partition access.

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| Separate identity-to-partition registry | Adds a runtime lookup, cache, and binding-management dependency that operator-managed AuthConfig avoids. |
| OCI workload identity | Couples the caller model to one cloud IAM system and does not provide a portable management-cluster identity model. |
| Hub-minted bearer credentials | Requires a separate Hub credential-issuance service and distributes Hub-issued credentials to management clusters. |
| Partition in a management-cluster token claim | Lets the management-cluster issuer, rather than the Hub, control partition authorization. |
| Deterministic issuer or subject mapping | Couples partition identity to issuer or subject naming and makes identity changes harder to manage. |

## References

- [Desire Store HLD](../docs/desire-store-hld.md)
- [ADR-0020: Envoy and Authorino as the API Authentication Gateway](0020-envoy-authorino-api-gateway.md)
- [ADR-0022: API-Mediated Desire Store Access](0022-api-mediated-desire-store-access.md)
- [Remote Applier Connectivity and Partition-Scoped Access to Postgres spike](../docs/spike-remote-applier-postgres-access.md)
- [HYPERFLEET-1737](https://redhat.atlassian.net/browse/HYPERFLEET-1737)
- [HYPERFLEET-1645](https://redhat.atlassian.net/browse/HYPERFLEET-1645)
