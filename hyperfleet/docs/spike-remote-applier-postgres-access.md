---
Status: Active
Owner: HyperFleet Team
Last Updated: 2026-10-05
---

# SPIKE: Remote Applier Connectivity and Partition-Scoped Access to Postgres

**Jira**: [HYPERFLEET-1519](https://redhat.atlassian.net/browse/HYPERFLEET-1519)

**Parent epic**: [HYPERFLEET-1518](https://redhat.atlassian.net/browse/HYPERFLEET-1518) (Desire Store on Postgres)

**Prior art**:

- [Desire store on API Postgres spike (HYPERFLEET-1432)](desire-store-api-postgres-spike.md)
- [Desire identity and ownership spike (HYPERFLEET-1421)](spike-desire-identity-ownership.md)

## Table of Contents

- [Overview](#overview)
- [Options Evaluated](#options-evaluated)
- [Recommendation](#recommendation)
- [Latency and Availability](#latency-and-availability)
- [Decision](#decision)
- [Open Questions](#open-questions)

## Overview

The Postgres desire store runs on the hub cluster. The Adapter is co-located with it, while each Applier runs on a separate OCI management cluster. This spike evaluates how remote Appliers access the Postgres-backed desire store and how to prevent cross-partition access. OCI-only deployment is the current requirement; multi-cloud portability is a future concern covered by ADR-0019.

## Options Evaluated

| Dimension | API-mediated access | Direct Postgres access |
|-----------|---------------------|------------------------|
| Postgres exposure | Remains inside the hub cluster | Requires a cross-cluster network path |
| Authentication | Requires a cross-cluster identity design through Envoy and Authorino | Requires database credentials, mTLS, cloud IAM, or a credential broker |
| Partition isolation | Enforced once in server-side application code | Requires row-level security, per-cluster credentials, or client enforcement |
| Client coupling | Stable service contract | Postgres schema and connectivity details |
| Availability | Hub API service is on the path | Postgres is directly on the path |

## Recommendation

Use API-mediated access. It keeps Postgres inside the hub cluster and centralizes partition enforcement. [ADR-0022](../adrs/0022-api-mediated-desire-store-access.md) records the selected architecture, including the gateway authentication and partition-scoping requirements.

## Latency and Availability

Appliers poll every 5s, based on the load-modeling assumption from [HYPERFLEET-1432](https://redhat.atlassian.net/browse/HYPERFLEET-1432). Same-region OCI latency is expected to leave sufficient headroom for the additional network hop, but implementation load testing must validate this at production concurrency.

The hub API service becomes a dependency for desire reads and status writes. This is the same hub failure domain that Sentinel already depends on for cluster and NodePool state. Client timeout, retry, and degraded-mode behavior remain implementation work.

## Decision

Adopt API-mediated desire-store access. The resulting architectural decision and its consequences are recorded in [ADR-0022](../adrs/0022-api-mediated-desire-store-access.md).

## Open Questions

The remaining service-design questions, including cross-cluster identity, partition binding, endpoint semantics, availability behavior, hosting, transport, gateway capacity, and defense in depth, are tracked in [HYPERFLEET-1645: Design the desire-store API service and cross-cluster Applier identity](https://redhat.atlassian.net/browse/HYPERFLEET-1645).

See the [Desire Store HLD](desire-store-hld.md) for high-level context; the [detailed design](desire-store-dd.md) provides more detail.

- **OCI security constraints**: Confirm OCI-specific restrictions that affect the hub cluster's internal Postgres deployment. This does not block the API-mediated path.
