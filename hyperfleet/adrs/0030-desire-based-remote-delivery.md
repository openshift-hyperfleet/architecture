---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-10-15
---

# 0030 — Desire-Based Remote Delivery

## Context

Remote delivery — adapter-authored resources onto management clusters, status back — ran on Maestro and it was the most expensive path in the system to operate and the hardest to author against: a four-part delivery stack, every delivered resource duplicated in AppliedManifestWork wrapper, status reduced to FeedbackRules-selected fields instead of the live object, and an author-facing DSL that leaked OCM and ManifestWork concepts so remote configs read nothing like local ones. The cutover to desire-based delivery landed in October 2026 ([HYPERFLEET-1502](https://redhat.atlassian.net/browse/HYPERFLEET-1502)); this ADR records the decision and its consequences.

## Decision

Remote delivery is desire-based. Adapters write desires to a desire store: rebuildable rows on the hub's shared Postgres ([ADR-0026](0026-co-located-service-databases-shared-postgres-isolation.md)) exposed only through a dedicated private API behind the hub gateway ([ADR-0022](0022-api-mediated-desire-store-access.md), [ADR-0029](0029-desire-store-authorization.md)). One Applier per management-cluster partition reconciles its desires against the local Kubernetes API server and writes status back to each desire. The desire contract is defined in [HYPERFLEET-1418](https://redhat.atlassian.net/browse/HYPERFLEET-1418).

## Consequences

**Gains:**

- **Delivery state is off management-cluster etcd.** Desires are rows in the hub's Postgres; management clusters store only the real resources. Before, a resource was stored in the dedicated Postgres and also in the AppliedManifestWork tracking CR in management-cluster etcd. The Applier records applied state in desire status instead, on the hub's existing shared Postgres ([ADR-0026](0026-co-located-service-databases-shared-postgres-isolation.md)).
- **Decoupled status feedback over the full live object.** The Applier writes the complete live object to desire status on its own schedule; the adapter reads it on the next passes, and its CEL evaluation context exposes the same full live object for local and remote resources ([HYPERFLEET-1419](https://redhat.atlassian.net/browse/HYPERFLEET-1419)). FeedbackRules, by contrast, cherry-picked status fields via JSONPath.
- **The remote path reads like the local path.** Adapter authors write plain Kubernetes resources and name a transport; every OCM and ManifestWork concept disappears from the author-facing DSL ([HYPERFLEET-1420](https://redhat.atlassian.net/browse/HYPERFLEET-1420)).
- **Lower operational weight.** One stateless API service on the hub's existing Postgres replaces the Maestro server, its dedicated Postgres, the MQTT broker, and per-cluster agents — and retires the maestro-cli repository.
- **The store is rebuildable.** It is a delivery channel, not a source of truth; if lost, adapters recompute and rewrite desires from API state. There is no stateful delivery control plane to back up or restore.

**Trade-offs:**

- **The management cluster no longer receives events.** Maestro pushed resources to subscribed agents; the Applier instead polls the desire store over HTTPS with its own cluster's projected service-account JWT, so delivery latency is bounded by the poll interval.
- **Eventual consistency for remote reads.** Writing a desire means the store accepted it, not that the cluster converged. Adapters detect staleness by generation mismatch; dependents may need another reconciliation.
- **No multi-resource bundles.** ManifestWork bundled manifests together; desires are individual records.
- **Polling volume.** Each partition polls the store — at the 10,000-partition planning scale, roughly 2,000 reads/sec and up to 20,000 status writes/sec before deduplication ([HYPERFLEET-1432](https://redhat.atlassian.net/browse/HYPERFLEET-1432)).

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| Keep Maestro | Hub runs many moving parts (server, dedicated Postgres, MQTT broker), plus per-cluster agents; FeedbackRules and ManifestWork concepts stay in the author-facing DSL. |
| OCM-native ManifestWork (ACM operator + work agent) | Work agents on management clusters connect to the hub's kube-apiserver, exposing it beyond the hub boundary; wrapper CRs double-store resources in etcd; carries the full ACM dependency. |
| Direct apply from the hub using management-cluster kubeconfigs | Requires kubeconfig storage and rotation on the hub and inbound access to every management-cluster API server — the credential sprawl Maestro existed to avoid. |

## References

- [Desire Store HLD](../docs/desire-store-hld.md)
- [Desire Identity and Ownership Spike](../docs/spike-desire-identity-ownership.md)
- [ADR-0022: API-Mediated Desire Store Access](0022-api-mediated-desire-store-access.md)
- [ADR-0026: Co-Located Service Databases on Shared Postgres: Isolation Model](0026-co-located-service-databases-shared-postgres-isolation.md)
- [ADR-0028: Serialize Apply Then Delete](0028-apply-delete-ordering.md)
- [ADR-0029: Desire Store Authorization](0029-desire-store-authorization.md)
- [HYPERFLEET-1502: Maestro Decommission and Delivery Cutover](https://redhat.atlassian.net/browse/HYPERFLEET-1502)
- [HYPERFLEET-1418: Applier and Desire Contract](https://redhat.atlassian.net/browse/HYPERFLEET-1418)
- [HYPERFLEET-1419: Adapter Desire Transport](https://redhat.atlassian.net/browse/HYPERFLEET-1419)
- [HYPERFLEET-1420: Adapter DSL v2, Plain Kubernetes Resources](https://redhat.atlassian.net/browse/HYPERFLEET-1420)
