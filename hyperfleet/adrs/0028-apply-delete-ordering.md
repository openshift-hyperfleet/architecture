---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-10-02
---

# 0028 — Serialize Apply Then Delete

## Context

Apply and delete desires for the same object are different records processed by two different reconcilers. `Identity.Type` is part of the key (`pkg/desire/types.go`), so an ApplyDesire and a DeleteDesire for the same ConfigMap are not the same desire. There is no single identity to order on. Independent passes can let a stale apply recreate an object after its delete was confirmed.

Pass timings for parallel and serial loops are in [Spike: Apply and Delete Ordering](../docs/apply-delete-ordering-spike.md).

## Decision

Run one loop per pass: finish every ApplyDesire, then run the DeleteDesires.

## Consequences

**Gains:** A confirmed delete cannot be undone by a stale apply in the same pass, and from 100 desires through 10,000 the shared client rate limit already sets the wall-clock time on envtest and the immediate mock.

**Trade-offs:** When calls are slower than that limit, serial is the sum of the two passes, and later passes still reapply.

## Alternatives Considered

| Alternative | Why Rejected |
| ----------- | ------------ |
| Parallel apply and delete loops | A stale apply can recreate an object after its delete was confirmed. At 100 and 1,000 desires the shared 20 QPS client already sets wall-clock time on envtest and the immediate mock, so the parallel loops do not shorten those passes. |
| One keyed workqueue per target, as in ROSA and ARO | ROSA and ARO represent apply and delete as variants of the same desire and serialize them through one keyed workqueue. HyperFleet apply and delete desires are different identities, so there is no single desire identity to order on. |
| Independent apply and delete controllers, as in GCP | GCP keeps separate apply, delete, and read records with independent controllers. This allows a stale apply desire to undo a confirmed delete desire.  |
