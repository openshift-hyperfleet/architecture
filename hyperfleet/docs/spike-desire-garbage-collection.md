---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-08-17
---

# Spike: Desire Garbage Collection Strategy

**Ticket:** HYPERFLEET-1431
**Date:** 2026-08-17

## 1. Context

There is no garbage collection today. If an adapter that created a desire
stops interacting with it, the desire remains in desire store indefinitely.
The applier continues reconciling it on every poll tick, and the K8s resource
on the management cluster becomes un-deletable. We want to clean up both orphaned
desires and k8s resources.

The cleanup procedure must be able to:

- Read resources from HyperFleet API
- Read and Delete desires from Desire Store
- Delete k8s resources from the management cluster

We do not always have access to the management cluster's k8s api from our hub cluster.

## 2. Questions

### Question 1: What are the criteria for garbage collection?

### Approach A: Time-Based Garbage Collection

Set an expiresAt timestamp on every desire, refreshed by the adapter on every interaction.
If the adapter stops interacting, the desire and k8s resource get cleaned up.

**Why Rejected** A Sentinel outage can cause all desires and underlying k8s resources to be agressively deleted.

### Approach B: Resource Based Correlation Check

Each desire carries `resource_id` (the HyperFleet API resource that caused
it to exist — see [Provenance](spike-desire-identity-ownership.md)). A
sweep checks whether `resource_id` still exists in the HyperFleet API. If
not, the resource is confirmed gone.

**Why Selected** Simplicity and clear semantics signalizing the deletion of a resource without the unforgiveness of TTL-based approach.

### Question 2: How/Where does garbage collection run?

The garbage collection procedure needs access to list our resources from API, delete from desire entries and delete k8s resources.

### Approach A: Separate Component

Run the sweep job as a separate hyperfleet-sweeper component as a CronJob/Deployment

**Why Rejected** Setup and additional infra in constrained on-prem environment outweighs the benefits from potential reduced blast radius in case of applier/sweeper failure.

### Approach B: Goroutine in hyperfleet-applier

Run the sweeb job in a goroutine of the hyperfleet-applier binary.

**Why Selected** Ease of setup, ability to move to a new component if needed

## 3. Decision

A goroutine running in hyperfleet-applier every 12 hours doing a resource based correlation-check.

The control flow:

1. Fetch k8s resources with `kubernetes.io/managed-by: hyperfleet-applier` label (all resources must have a label applied by hyperfleet-applier)

2. If a desire referencing this k8s resource exists and the desire is orphaned (doesn't reference a valid api resource):\
Delete the desire

3. If a desire referencing this k8s resource doesnt exist:\
  Delete the k8s resource
