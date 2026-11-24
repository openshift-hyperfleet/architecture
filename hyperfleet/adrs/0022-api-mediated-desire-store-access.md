---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-11-18
---

# 0022 - API-Mediated Desire Store Access

## Context

The Postgres desire store is hosted on the hub cluster, while each Applier runs on a separate OCI management cluster. The Adapter runs on the hub and is co-located with Postgres. Remote Appliers must read their partition's desires and write desire status without gaining access to other management clusters' rows.

Direct Postgres access would require separate decisions for cross-cluster network exposure, client credential lifecycle, and partition enforcement. It would also expose the database beyond the hub cluster. HyperFleet already uses the Envoy and Authorino gateway to authenticate internal callers and inject trusted identity headers.

## Decision

**Partial supersession:** [ADR-0039](0039-sweeper-partition-enumeration.md) replaces the universal partition-scope requirement below only for sweeper-only partition metadata enumeration. That operation uses an operation-scoped Wristband without a partition. All desire-record operations retain their existing partition and caller rules; API-mediated access and signed Wristband trust remain mandatory.

Adapters and Appliers access the desire store through an authenticated, hub-hosted API service. Postgres is not exposed directly to clients outside the hub cluster.

The service exposes the bounded desire-store operations: partition reads, desire writes, and status writes. Partition enforcement is mandatory and cannot be disabled by an optional server configuration flag. The service configuration must declare the partition dimension, and startup must fail if that dimension or its enforcement configuration is missing. Envoy removes caller-supplied identity and tenant headers. The gateway validates each remote Applier through a trusted cross-cluster identity mechanism and maps the validated identity to exactly one partition before injecting trusted identity headers. Every request must resolve a non-empty partition scope exclusively from those injected headers before reaching the data layer; missing or invalid tenant context is rejected, requested scope that does not match the caller is rejected, and no unscoped query is permitted. The service never derives scope from client-supplied parameters or untrusted JWT claims.

This extends ADR-0020's gateway caller model with a third caller type: remote, partition-scoped machines. The issuer trust and credential lifecycle for this caller type are follow-up design decisions in [HYPERFLEET-1645: Design the desire-store API service and cross-cluster Applier identity](https://redhat.atlassian.net/browse/HYPERFLEET-1645).

The transport (REST or gRPC) and whether the endpoints run in the existing API or a dedicated hub service are follow-up design decisions, not implementation details. They must be recorded before implementation in [HYPERFLEET-1645: Design the desire-store API service and cross-cluster Applier identity](https://redhat.atlassian.net/browse/HYPERFLEET-1645). The design must evaluate end-to-end capacity across the gateway, service, and Postgres. Both options must use the gateway and partition-scoping contract defined here.

## Consequences

**Gains:**

- Postgres remains inaccessible outside the hub cluster, eliminating direct DB network exposure and client database credentials.
- Partition isolation is enforced once in testable server-side application code, without Postgres row-level security or per-cluster database accounts.
- Clients depend on a stable desire-store contract rather than the Postgres schema, allowing the storage backend to change without client changes.

**Trade-offs:**

- The hub API service is on the availability path for desire reads and status writes. Client timeout, retry, and degraded-mode behavior must be defined by the implementation work.
- The service adds a network hop and serialization overhead. The assumed 5s poll interval is expected to accommodate this, but load testing must validate it at production concurrency.
- HyperFleet must implement and version the desire-store endpoints. Clients now have an API compatibility dependency rather than a database dependency.
- Hosting the endpoints in the existing API shares its failure domain. A dedicated service can isolate that risk but adds deployment complexity.
- The cross-cluster identity mechanism, including its issuer trust, credential lifecycle, revocation behavior, and Authorino configuration, requires a follow-up design.
- Partition isolation resides in the service layer. A defect in partition-scope resolution could expose multiple partitions, and all remote Appliers share the hub service and Postgres capacity. Postgres row-level security and per-caller gateway quotas can be added as defense in depth without changing this decision; their evaluation is follow-up design work in [HYPERFLEET-1645: Design the desire-store API service and cross-cluster Applier identity](https://redhat.atlassian.net/browse/HYPERFLEET-1645).

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| Direct Postgres access from Appliers | Requires cross-cluster database exposure, database credential distribution and rotation, and a separate partition-isolation design using row-level security, per-cluster credentials, or client enforcement. |
| Direct access through VPN, tunnel, private link, or proxy | Solves only connectivity. It still requires database authentication and partition-isolation mechanisms, and adds infrastructure or cloud-specific operational dependencies. |
| Per-cluster Postgres credentials | Provides strong database-level isolation but makes provisioning, rotation, and revocation scale with the number of management clusters. |
| Postgres row-level security with shared credentials | Adds database-level defense in depth but relies on correct client session state and does not remove the need to expose and authenticate direct database connections. |

## References

- [Remote Applier Connectivity and Partition-Scoped Access to Postgres spike](../docs/spike-remote-applier-postgres-access.md)
- [ADR-0020: Envoy and Authorino as the API Authentication Gateway](0020-envoy-authorino-api-gateway.md)
- [ADR-0019: Package HyperFleet as a Kubernetes Operator](0019-package-hyperfleet-as-operator.md)
