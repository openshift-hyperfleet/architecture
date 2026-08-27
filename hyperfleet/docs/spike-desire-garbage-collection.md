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

A cleanup job must be able to:

- Read resources from HyperFleet API
- Read and Delete desires from Desire Store
- Delete k8s resources from the management cluster

We do not always have access to the management cluster's k8s api from our hub cluster.

## 2. Questions

### Question 1: What are the criteria for garbage collection?

### Approach A: Time-Based Garbage Collection

Set an expiresAt timestamp on every desire, refreshed by the adapter on every interaction.
If the adapter stops interacting, the desire and k8s resource get cleaned up.

**Why Rejected** A Sentinel outage can cause all desires and underlying k8s resources to be aggressively deleted.

### Approach B: Resource Based Correlation Check

Each desire carries `resource_id` (the HyperFleet API resource that caused
it to exist — see [Provenance](spike-desire-identity-ownership.md)). A
sweep checks whether `resource_id` still exists in the HyperFleet API. If
not, the resource is confirmed gone.

**Why Selected** Simplicity and clear semantics signalizing the deletion of a resource without the unforgiveness of TTL-based approach.

### Question 2: How/Where does garbage collection run?

### Approach A: Goroutine in hyperfleet-applier

Run the sweep job in a goroutine of the hyperfleet-applier binary.

**Why Rejected** Bigger blast radius, mixed concerns, requires API credentials in applier

### Approach B: Per-management-cluster hyperfleet-sweeper

Run the sweep job as a separate hyperfleet-sweeper binary in a CronJob in every management cluster.

**Why Rejected** Decentralized deployment, operational overhead of managing sweeper in every management cluster

### Approach C: Centralized hyperfleet-sweeper using DeleteDesires

A hyperfleet-sweeper component running in the hub cluster, creating DeleteDesires to trigger cleanup in the remote cluster(s).

The sweeper:

  1. Finds desires with invalid resource reference
  2. Creates a DeleteDesire for the resource
  3. Cleans up DeleteDesires and ReadDesires after successful deletion of orphaned resources is reported by the applier

The sweeper must have priority over the `owner` field check when deleting the desires.
A DeleteDesire and ApplyDesire cannot coexist, this is currently enforced by
`pkg/desire` in hyperfleet-applier - the sweeper does not need to cleanup apply desires.

**Why Selected** Centralized, no k8s api access required

## 3. Decision

A centralized hyperfleet-sweeper in the hub cluster, running every 12 hours. Simplicity is preferred over TTL's strictness, an adapter task config change or adapter decommissioning can still leave dangling k8s resources and desires behind.
