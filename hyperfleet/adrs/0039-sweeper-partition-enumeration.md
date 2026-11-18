---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-11-18
---

# 0039 - Sweeper Partition Enumeration from Remaining Desires

## Context

The centralized Hub sweeper must discover desires left behind after a management cluster is fully decommissioned. A list derived only from live registrations or AuthConfig omits a partition once its registration is removed, even if apply, delete, or read records remain. Partitions are implicit groupings of desire records by `managementCluster`; they are not a separate registry. [HYPERFLEET-1823](https://redhat.atlassian.net/browse/HYPERFLEET-1823) requires a discovery decision that covers those residual records while preserving API-mediated access and partition isolation for desire-record operations.

## Decision

Select **option 2: enumerate partitions from remaining Desire Store records through a sweeper-only metadata API**.

- Add `GET /api/hyperfleet/desire-store/v1/partitions`, returning distinct partition identifiers represented by at least one `ApplyDesire`, `DeleteDesire`, or `ReadDesire`. Do not filter by registration, AuthConfig, active Applier, owner, or originating API-resource existence. Return identifiers only, without desire content or credentials.
- Use bounded, opaque keyset pagination in ascending bytewise lexicographic order. The [Detailed Design](../docs/desire-store-dd.md#sweeper-partition-enumeration) defines the response and cursor contract, including default `limit` 100, minimum 1, maximum 1000, and 400 above the maximum. Pagination is not a snapshot; each sweep starts a fresh enumeration.
- Implement the query in the Desire Store API/Postgres data layer, outside the shared partition-scoped `SpecStore` interface. Add an explicit metadata operation to the sweeper's HTTP client. Do not introduce a partition registry, an empty/wildcard partition, direct database access for the sweeper, or enumeration methods in every store backend.
- Authenticate through the existing fleet base host using Hub TokenReview, and authorize only the exact deployed sweeper service-account identity. The signed Wristband must carry `hf_caller_class=fleet-scoped`, that sweeper's `hf_identity`, and `hf_operation=partition-list`, with no `hf_partition`. Both gateway and API must match the dedicated method/path and required identity/scope. Mixed metadata and partition claims are rejected.
- Every desire-record operation continues to require its existing non-empty partition claim and matching path. It must reject the metadata operation claim. Adapters and remote Appliers receive no enumeration permission; an ordinary partition-scoped Wristband does not authorize enumeration.

### Relationship to Existing Decisions and v1

This ADR partially supersedes [ADR-0022](0022-api-mediated-desire-store-access.md)'s universal non-empty partition requirement and [ADR-0029](0029-desire-store-authorization.md)'s requirement that every Desire Store Wristband contain an authorized partition, **only for this metadata operation**. API-mediated access, signed Wristband trust, and all desire-record partition and caller rules remain in force.

Record a narrow additive exception to the Detailed Design's v1 compatibility rule: this one new operation and permission may be published in a subsequent minor specification release under `/v1`. It changes no existing caller's behavior or desire-record authorization. This is not a general exception for other operation or authorization changes. [Specification 0.2.0](https://github.com/openshift-hyperfleet/hyperfleet-desire-store-spec/blob/6474ebc035ce005d53aed9dc91e82c50382cf9bc/schemas/desire-store/openapi.yaml) already shipped without enumeration; the API contract and implementations still require follow-up changes under the [API-first decision](0003-openapi-first-contract.md).

### Decision Boundary

This records the partition-discovery, metadata-authorization, store-boundary, and compatibility decisions. It does not settle deletion confirmation after record recreation, destructive supersede of a replacement apply, or origin reappearance after a sweeper-created delete. Those [design gates](../docs/spike-sweeper-orphan-scan.md#review-and-implementation-gates) remain under HYPERFLEET-1823. Enumeration does not prove source absence or remote deletion and cannot restore an unavailable Applier. Recording this ADR alone does not complete all six spike criteria or claim that the endpoint is implemented.

## Consequences

**Gains:**

- Residual partitions remain discoverable even after their registrations are removed, including partitions containing only delete or read records.
- Discovery uses the existing authenticated API boundary and the records that require cleanup, without maintaining a second registry.
- The new privilege exposes only partition identifiers. Desire-record authorization and the shared store interface retain their partition boundaries.

**Trade-offs:**

- The API, Postgres query, sweeper client, gateway policy, and published specification need coordinated additions. Service integration and gateway tests must prove enumeration and separation of metadata scope from record access; the existing store conformance suite does not cover this query.
- Distinct partition queries add database work. Their bounded query/index strategy and contention with Applier polls need validation against the actual schema and workload.
- Concurrent changes can defer discovery until the next scan. Empty partitions disappear from the list; the operation is not a registry or evidence that Kubernetes resources were deleted.
- Unconfirmed cleanup remains unresolved when its Applier is unavailable. No timeout or registration removal substitutes for deletion confirmation.

## Alternatives Considered

| Alternative | Why Not Selected |
| --- | --- |
| Option 1: finish cleanup before removing registration | Useful for orderly decommissioning, but cannot discover leftovers after failed or bypassed teardown or lost registration. It is insufficient as the sole discovery mechanism. |
| Options 1 and 2 together | Compatible, but decommission coordination is not required to solve residual-partition discovery. It may be added separately using the same deletion-safety rules. |
| A new partition registry | Adds persistence and lifecycle coordination when remaining desire records already identify the partitions that need inspection. |
| Enumeration on the shared `SpecStore` interface | Requires coordinated memory, Redis, Postgres, client, and conformance changes for a Hub-only operation. A separate metadata query keeps existing clients partition-scoped. |
| Direct database scan by the sweeper | Violates API-mediated access and distributes database credentials and schema coupling to another service. |

## References

- [Sweeper Orphan-Scan spike](../docs/spike-sweeper-orphan-scan.md)
- [Desire Store Detailed Design](../docs/desire-store-dd.md#sweeper-partition-enumeration)
- [Desire Store Architecture Overview](../docs/desire-store-hld.md)
- [Desire Store Test Plan](../docs/e2e-testing/desire-store-test-plan.md#sweeper-privileges)
- [HYPERFLEET-1840: Centralized desire sweeper](https://redhat.atlassian.net/browse/HYPERFLEET-1840)
