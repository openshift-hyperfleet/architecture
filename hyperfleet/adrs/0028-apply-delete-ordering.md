---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-11-05
---

# 0028 — Serialize Apply Then Delete

## Context

Apply and delete desires for the same object are different records processed by two different reconcilers. `Identity.Type` is part of the key (`pkg/desire/types.go`), so an ApplyDesire and a DeleteDesire for the same ConfigMap are not the same desire. There is no single identity to order on. Independent passes can let a stale apply recreate an object after its delete was confirmed.

That recreation is not a transient. Once the delete is confirmed, nothing executes the `DeleteDesire` again and no `ApplyDesire` exists, so no pass reapplies or deletes the recreated object. The object stays on the management cluster until someone removes it by hand, and nothing in HyperFleet reports that it exists.

Pass timings for parallel and serial loops are in [Spike: Apply and Delete Ordering](../docs/apply-delete-ordering-spike.md).

## Decision

Run one loop per pass: finish every ApplyDesire, then run the DeleteDesires. The delete phase starts only after every apply call made in the apply phase has returned, so no apply is in flight while a delete is being confirmed.

Each pass lists the store fresh before it starts. The ordering closes the race only because of that listing: creating a DeleteDesire removes the ApplyDesire for the same object from the store, so an apply that was removed during one pass is absent from the next listing and cannot run after the delete it conflicts with. A pass that reuses a listing from an earlier pass reopens the race with the ordering intact, so the fresh listing is part of this decision, not an implementation detail.

The ordering holds only while one pass runs per management-cluster partition at a time. Passes inside one process do not overlap, because each pass starts only after the previous one returns. Two applier processes bound to the same partition would each run their own passes, and the apply phase of one can overlap the delete phase of the other, so the applier runs a single replica per partition. Running more than one replica needs leader election or partition ownership first, and that is outside this decision.

Implementation is tracked in [HYPERFLEET-1741](https://redhat.atlassian.net/browse/HYPERFLEET-1741).

## Consequences

**Gains:** A confirmed delete cannot be undone by a stale apply in the same pass, and from 100 desires through 10,000 the shared client rate limit already sets the wall-clock time on envtest and the immediate mock.

**Trade-offs:** When calls are slower than that limit, serial is the sum of the two passes (238 seconds against 185 seconds at 1,000 desires on the degraded backend), and later passes still reapply every ApplyDesire. How often to reapply is a separate decision, tracked in [HYPERFLEET-1742](https://redhat.atlassian.net/browse/HYPERFLEET-1742).

## Alternatives Considered

| Alternative | Why Rejected |
| ----------- | ------------ |
| Parallel apply and delete loops | A stale apply can recreate an object after its delete was confirmed. From 100 through 10,000 desires the shared 20 QPS client already sets wall-clock time on envtest and the immediate mock, so the parallel loops do not shorten those passes. |
| One keyed workqueue per target, as in ROSA and ARO | Feasible: the ApplyDesire and DeleteDesire for one object share a target key once `Identity.Type` is dropped (management cluster, group, resource, namespace, name), so both could be enqueued under it and ordered per key. Rejected on cost. ROSA and ARO get the ordering for free because apply and delete are variants of one desire; HyperFleet would add a merge of two listings into one keyed queue, a rule for which of an apply and a delete under the same key runs first within a pass, and handling for a desire removed from the store between listing and dequeue. What that buys is concurrency across keys, which only shortens a pass when the apiserver is slower than the client limit: at most 53 seconds per 1,000 desires on the degraded backend (238 seconds serial against 185 seconds parallel), and nothing at 100 through 10,000 desires on envtest or the immediate mock. One loop gets the same ordering with no new queue. |
| Independent apply and delete controllers, as in GCP | GCP keeps separate apply, delete, and read records with independent controllers. This allows a stale apply desire to undo a confirmed delete desire. |

## References

- [HYPERFLEET-1611](https://redhat.atlassian.net/browse/HYPERFLEET-1611) - Benchmark serialized against parallel apply and delete reconciliation (the spike behind this decision).
- [HYPERFLEET-1741](https://redhat.atlassian.net/browse/HYPERFLEET-1741) - Run apply and delete in one reconciler (implementation).
- [HYPERFLEET-1742](https://redhat.atlassian.net/browse/HYPERFLEET-1742) - Decide reapply frequency for the applier's apply reconciler (deferred from this decision).
