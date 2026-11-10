---
Status: Active
Owner: HyperFleet Team
Last Updated: 2026-11-10
---

# Spike Report: OLM Install Testing in Prow

**Ticket:** [HYPERFLEET-1616](https://redhat.atlassian.net/browse/HYPERFLEET-1616)

## Overview

This spike investigates how to test the installation of the hyperfleet operator in Prow. The operator is the entry point to HyperFleet, and its deployment path is Operator Lifecycle Manager (OLM), which follows a catalog-driven distribution model: for releases we package the operator into a bundle and catalog (see [the OLM releases spike](release/spike-olm-releases.md)). Think of OLM as distribution and lifecycle management — it does not change the operator's runtime or reconciliation logic.

This is the first part of HYPERFLEET-1616. The investigation covers presubmit testing of changes in the hyperfleet-operator repo and consists of 4 options based on OLM v0 installation. OLM v1 installation can be verified in a similar fashion, this document is just the first iteration.

Cost figures are on-demand estimates for `us-central1` as of November 2026, assuming ~10 presubmit runs/day (upper bound); need to verify billing, these are rough estimates.

## Presubmit Installation of hyperfleet-operator via OLM v0

### Option 1 — GKE based installation

**Note:** OLM technically permits installing the operator in more than one namespace, but this would not exercise real workflows, since `HyperFleetConfig` is a cluster-scoped singleton — one install per cluster.

**Workflow:**

1. Spin up a single-node GKE cluster on every PR
2. Install OLM v0.28.0 on the cluster
3. Build the operator image
4. Build the operator bundle
5. Install the operator bundle
6. Validate that the operator provisioned successfully

**Time frame:**

1. GKE provisioning: 3-10 minutes
2. Installing OLM: 30s - 2 minutes
3. Building the operator image: 1-2 minutes
4. Building the operator bundle: 30s - 1 minute
5. Installing the hyperfleet operator bundle: 30s - 2 minutes
6. **Total:** ~6-17 minutes

**Cost Estimate:** ~$82-$100/month, 200 nodes created, running for 17 minutes each. Instance: e2-standard-4, 4 vCPUS, 16 GB of RAM and 200 GB boot disk.

**Pros:**

- We already have a working example of this approach for infra

**Cons:**

- Might be overkill for every PR
- GKE control plane adds cost and provisioning time per run

### Option 2 — GCE kind based installation — long running

**Workflow:**

1. Use a long-running GCE instance, prebuilt with kind and docker
2. Create a new kind cluster on the instance
3. Install OLM v0.28.0 on the kind cluster
4. Build the operator image
5. Build the operator bundle
6. Install the operator bundle
7. Validate that the operator provisioned successfully

**Time frame:**

1. Creating a kind cluster: 1-2 minutes
2. Installing OLM: 30s - 2 minutes
3. Building the operator image: 1-2 minutes
4. Building the operator bundle: 30s - 1 minute
5. Installing the operator bundle: 30s - 2 minutes
6. **Total:** ~4-9 minutes

**Cost Estimate:** ~$258-$300/month. ~480 hours per month, w/ weekend governance. Instance: e2-standard-16, 16 vCPUs, 64 GB of RAM and 200 GB boot disk.

**Pros:**

- No GCE instance provisioning per run
- Prebuilt image already has all binaries we need
- PR separation — each PR gets its own kind cluster

**Cons:**

- Long-running instance is a continuous cost, even when idle
- Instance must be large enough to handle ~10 concurrent kind clusters
- Cleanup of stale kind clusters from failed runs
- Shared instance is a single point of failure for all presubmits

### Option 3 — GCE kind based installation — one per run

**Workflow:**

1. Spin up a new GCE instance for every PR, prebuilt with kind and docker
2. Create a new kind cluster on the instance
3. Install OLM v0.28.0 on the kind cluster
4. Build the operator image
5. Build the operator bundle
6. Install the operator bundle
7. Validate that the operator provisioned successfully

**Time frame:**

1. Creating the GCE instance: 1-3 minutes
2. Creating a kind cluster: 1-2 minutes
3. Installing OLM: 30s - 2 minutes
4. Building the operator image: 1-2 minutes
5. Building the operator bundle: 30s - 1 minute
6. Installing the operator bundle: 30s - 2 minutes
7. **Total:** ~5-12 minutes

**Cost Estimate:** ~$17-20/month. 200 instances (10Prs X 20 days). Instance: e2-standard-4, 4 vCPUs, 16GB of RAM and 100 GB boot disk.

**Pros:**

- Separation on every build — no dependency on the previous PR run
- Instance size can be tuned per run
- Instance and cluster are destroyed together, no stale-state cleanup

**Cons:**

- Slower start than Option 2 — every run pays for instance provisioning and SSH readiness
- Instance provisioning adds a moving part that can fail independently of the change under test
- Ensure cleanup of instances or could leak costs.

### Option 4 — Vcluster

Vcluster is a tool for creating and managing virtual Kubernetes clusters — basically a cluster within a cluster. A virtual cluster lives inside a namespace on a host cluster, but appears to a user as its own standalone cluster.

**Workflow:**

1. Use a long-running GKE cluster, similar to the prow cluster
2. Install vcluster and run `vcluster create cluster-<build_num>`, which creates a virtual cluster and its namespace
3. Switch to the newly created virtual cluster (happens automatically)
4. Install OLM v0.28.0 on the virtual cluster
5. Build the operator image
6. Build the operator bundle
7. Install the operator bundle
8. Validate that the operator provisioned successfully

**Time frame:**

1. Creating a virtual cluster: 30s - 1 minute
2. Installing OLM: 30s - 2 minutes
3. Building the operator image: 1-2 minutes
4. Building the operator bundle: 30s - 1 minute
5. Installing the bundle: 30s - 2 minutes
6. **Total:** ~3-8 minutes

**Cost Estimate:** ~$77-$90/month. 2 nodes running ~480 minutes (8 hours) per day on weekdays only, with weekends off. 1 zonal cluster. Instance: e2-standard-8, 8 vCPUs, 32 GB of RAM and 100 GB boot disk.

**Pros:**

- Isolation from other PRs — separation between installs
- No need to spin up a new cluster for every PR
- No need to create a kind cluster for every PR
- No need to create a new instance for every PR
- Simulates a new cluster on every build while running on the same GKE cluster

**Cons:**

- Learning curve for vcluster
- Requires cleanup of old virtual clusters from failed runs
- Long-running GKE cluster (control plane) is a continuous cost
- Virtual clusters depend on the host cluster's health — shared failure domain
- Virtual clusters are not full Kubernetes clusters — some API behavior differs from a real cluster, which may not catch (or may falsely catch) install issues

## Presubmit hyperfleet-operator E2E testing — [HYPERFLEET-1707](https://redhat.atlassian.net/browse/HYPERFLEET-1707)

Whichever option is chosen, we can extend the presubmit CI to also run the hyperfleet-operator E2E tests. No additional infrastructure is required: the E2E suite runs against the same cluster the operator was installed into. We would need to modify the E2E tests to drop their own operator image build and installation steps, since the presubmit flow installs the operator via OLM before the tests run.

**Note:** Cost estimates are approximate and taken from the [google pricing calculator](https://cloud.google.com/products/calculator). Estimations may need to be modified.

## Open Questions

- Is it duplicative to run image and bundle builds in Prow when Konflux already builds them? There is no way around it for presubmits: E2E tests need images built from the PR's changes, which Konflux does produce.
