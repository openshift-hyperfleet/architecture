---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-11-04
---

# Spike: Desires Lost Mid-Deletion

**Ticket:** [HYPERFLEET-1841](https://redhat.atlassian.net/browse/HYPERFLEET-1841)
**Date:** 2026-11-04

## Context

The Desire Store is a rebuildable delivery channel. Desires that disappear while a delete is in flight can leave the management-cluster object in place. With no desires left, the cleanup during deletion-flow succeeds, and the executor marks the resource deleted. The apply-flow, on the other hand, won't be able to wait and observe the success of the previous deletion. We have two options how to deal with lost desires:

## Options

### Desire cleanup uses backward recovery

`CleanupAfterDeletion` must observe confirmed DeleteDesire and a ReadDesire at the beginning. If any of them are missing, it should recreate them and return `ErrDeletionPending`.

**Why Selected.** A dropped unconfirmed delete is rewritten from the adapter's current intent, which is the rebuild behavior the store already promises for apply.

### Applier cleans up leftover objects

The applier, or the sweeper, deletes a management-cluster object that no longer has desires.

**Why Rejected.** The applier deletes an object only when a `DeleteDesire` names it. An object with no desire is also an object this delivery path never owned. The desire was that ownership record.

## Decision

`CleanupAfterDeletion` restores a `ReadDesire` and a `DeleteDesire` instead of treating an empty store as a finished delete. That restore runs only while the adapter still intends to delete. If the desires were dropped before confirmation and the adapter wants to apply the object, it writes an `ApplyDesire` and does not wait for delete confirmation. [HYPERFLEET-1771](https://redhat.atlassian.net/browse/HYPERFLEET-1771) can assert store loss during a delete against this behavior once the adapter change lands.
