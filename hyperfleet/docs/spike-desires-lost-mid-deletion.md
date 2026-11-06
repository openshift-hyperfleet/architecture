---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-11-05
---

# Spike: Desires Lost Mid-Deletion

**Ticket:** [HYPERFLEET-1841](https://redhat.atlassian.net/browse/HYPERFLEET-1841)
**Date:** 2026-11-05

## Context

The Desire Store is a rebuildable delivery channel. Desires that disappear while a delete is in flight can leave the management-cluster object in place. With no desires left, the cleanup during deletion-flow succeeds, and the executor marks the resource deleted. We have four options for dealing with lost desires:

## Options

### Desire cleanup uses backward recovery

`CleanupAfterDeletion` must observe confirmed DeleteDesire and a ReadDesire at the beginning. If either or both are not found (`ErrNotFound`), it should recreate them and return `ErrDeletionPending`.

**Why Rejected.** After a normal delete the store is empty, which is also what a lost delete looks like, so every event with `when` true and no desires re-requests the delete.

### Applier cleans up leftover objects

The applier, or the sweeper, deletes a management-cluster object that no longer has desires.

**Why Rejected.** The applier deletes an object only when a `DeleteDesire` names it. An object with no desire can be a previously owned object whose desires were lost, or an object this delivery path never owned. Without an independent ownership record, the applier cannot distinguish these cases. The desire was the ownership record. An empty store could cause all resources to be wiped.

### Document the case as unsupported

The documentation states that desires lost mid-deletion are possible, and an operator removes the stranded management-cluster object by hand.

**Why Rejected.** The failure is silent. The adapter can report `Finalized=True` and the API hard-deletes the record in the same transaction, so nothing in HyperFleet reports the stranded object afterward.

### Adapter keeps the confirmed desires and the sweeper removes them

The adapter stops removing the confirmed `DeleteDesire` after a delete and deletes only the `ReadDesire` to stop the applier side informers from running. The sweeper ([HYPERFLEET-1840](https://redhat.atlassian.net/browse/HYPERFLEET-1840)) removes the `DeleteDesire` once the API resource is gone.

**Why Selected.** A finished delete and a lost delete no longer leave the same store contents during the API resource's lifespan. Re-triggers after finalization see a confirmed `DeleteDesire`, report `Finalized=True` again, preserving idempotency.

**Costs.** Every deleted resource leaves its `DeleteDesire` behind until the sweeper runs, and the applier lists and re-reads each retained `DeleteDesire` on every pass. That is one store read per record per pass and no Kubernetes calls.

## Decision

The adapter keeps the confirmed `DeleteDesire` after a delete and removes only the `ReadDesire`, as described in the last option. The sweeper removes the `DeleteDesire` once the API resource is gone. A delete counts as confirmed only when the `DeleteDesire` status says `Successful=True`. The resulting remote delete flow is in the [Adapter Deletion Flow Design](../components/adapter/framework/lifecycle/adapter-lifecycle-delete-design.md#remote-transport-resources-9).

[HYPERFLEET-1771](https://redhat.atlassian.net/browse/HYPERFLEET-1771) can assert store loss during a delete against this behavior once the adapter change lands.

## Follow-ups

- **Adapter change** - HYPERFLEET-1905
- [HYPERFLEET-1771](https://redhat.atlassian.net/browse/HYPERFLEET-1771) asserts store loss during a delete once the adapter change lands.
