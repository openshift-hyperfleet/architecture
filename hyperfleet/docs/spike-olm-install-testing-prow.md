---
Status: Active
Owner: HyperFleet Team
Last Updated: 2026-11-16
---
# Spike Report: OLM Install Testing in Prow

**Ticket:** [HYPERFLEET-1616](https://redhat.atlassian.net/browse/HYPERFLEET-1616)

## Overview

This spike investigates how to test the installation of the hyperfleet operator in Prow. The operator is the entry point to HyperFleet, and its deployment path is Operator Lifecycle Manager (OLM), which follows a catalog-driven distribution model: for releases we package the operator into a bundle and catalog (see [the OLM releases spike](release/spike-olm-releases.md)). Think of OLM as distribution and lifecycle management — it does not change the operator's runtime or reconciliation logic.

This is the first part of HYPERFLEET-1616. The investigation covers presubmit testing of changes in the hyperfleet-operator repo and consists of 4 options based on OLM v0 installation. OLM v1 installation can be verified in a similar fashion, this document is just the first iteration.

**Note:** Cost estimates are approximate and taken from the [google pricing calculator](https://cloud.google.com/products/calculator). Estimations may need to be modified.

- ~10 PR/day * ~avg 3 runs/PR (upper bound)

## Presubmit Installation of hyperfleet-operator via OLM v0

**Note:** Each of these options requires installing the hyperfleet operator on a fresh cluster — there can only be one version of the hyperfleet operator per cluster.

### Option 1 — GKE based installation

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
3. Building the operator image: 4 minutes
4. Building the operator bundle: 3 minutes
5. Installing the hyperfleet operator bundle: 30s - 2 minutes
6. Validating that the operator provisioned successfully: 1-3 minutes
7. **Total:** ~12-23 minutes

**Cost Estimate:** ~ `$117 - $130/month`. 600 nodes (20 days × 10 PRs/day × ~3 runs/PR), usage time ~30 minutes (upper bound). Zonal cluster. Instance: e2-standard-4, 4 vCPUs, 16 GB of RAM and 100 GB boot disk.

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
3. Building the operator image: 4 minutes
4. Building the operator bundle: 3 minutes
5. Installing the operator bundle: 30s - 2 minutes
6. Validating that the operator provisioned successfully: 1-3 minutes
7. **Total:** ~10-16 minutes

**Cost Estimate:** ~ `$148.66 - $200/month`. ~240 hours per month w/ weekend governance (12 hours/day, 5 days/week, 4 weeks/month). Instance: e2-standard-16, 16 vCPUs, 64 GB of RAM and 200 GB boot disk.

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
4. Building the operator image: 4 minutes
5. Building the operator bundle: 3 minutes
6. Installing the operator bundle: 30s - 2 minutes
7. Validating that the operator provisioned successfully: 1-3 minutes
8. **Total:** ~11-17 minutes

**Cost Estimate:** ~ `$36 - $40/month`. 600 instances (20 days × 10 PRs/day × ~3 runs/PR) running for ~20 minutes each (upper bound). Instance: e2-standard-4, 4 vCPUs, 16GB of RAM and 100 GB boot disk.

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
2. Installing OLM: 2 minutes
3. Building the operator image: 4 minutes
4. Building the operator bundle: 3 minutes
5. Installing the bundle: 30s - 2 minutes
6. Validating that the operator provisioned successfully: 1-3 minutes
7. **Total:** \~11-15 minutes

**Cost Estimate:** ~ `$200 - $300/month`. ~240 hours per month w/ weekend + nightly governance (12 hours/day, 5 days/week, 4 weeks/month). 2 node zonal cluster. Instance: e2-standard-8, 8 vCPUs, 32 GB of RAM and 100 GB boot disk.

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

### Option 5 -- Prow job with configured cluster claim (Recommended)

A Prow job that claims a cluster from an OpenShift CI cluster pool. The pool maintains a set of pre-provisioned OpenShift clusters that idle until claimed; the job claims one, runs the OLM installation and validation on it, and the cluster is destroyed and re-provisioned for the next consumer. Each PR run gets a fresh, real OpenShift cluster without paying provisioning time or managing any infrastructure ourselves.

Example run: [presubmits-e2e-in-cluster-install](https://prow.ci.openshift.org/view/gs/test-platform-results-public/pr-logs/pull/openshift_release/88745/rehearse-88745-pull-ci-openshift-hyperfleet-hyperfleet-operator-main-presubmits-e2e-in-cluster-install/2122460143546273792)

Timeframe:

1. Building the operator image: 4 minutes
2. Building the operator bundle: 3 minutes
3. Claiming a cluster: 0 minutes (cluster is idle in the pool, not provisioned per run)
4. Running install and validation: 2 minutes
5. Running post test clean up/gather info: 9 minutes

Total time: ~18 minutes

**Pros:**

- Fresh, real OpenShift cluster per run -- same isolation guarantees as Option 3, but zero provisioning time in the job
- No HyperFleet-owned infrastructure -- cluster pools are operated by the OpenShift CI platform, so we carry no cloud cost, no cleanup duty, and no single point of failure we have to maintain
- OLM is preinstalled and managed by the cluster itself -- we test against the OLM version OpenShift actually ships, instead of installing a pinned OLM v0.28.0 and maintaining that pin
- Tests on the target platform -- HyperFleet will be installed on OpenShift, so exercising the install path on real OpenShift is higher-fidelity than any GKE- or kind-based option
- Builds a new operator and bundle image on each run -- the test always exercises the PR's code
- Reuses the existing OpenShift CI/Prow ecosystem we already depend on -- no new tooling (vcluster) or new GCP patterns to learn and maintain
- Extensible -- the same job can run the hyperfleet-operator E2E suite after installation, and can be pointed at OLM v1 clusters by claiming from a different pool

**Cons:**

- Runtime estimates are not yet measured in an actual Prow job -- the example run above is a rehearsal; real job time needs confirming before we treat ~18 minutes as the baseline
- Depends on cluster pool capacity and health -- a busy or broken pool queues our presubmits, and it is outside our control to fix

### Why Option 5 is recommended

Every other option makes us own some piece of throwaway infrastructure per run (GKE cluster, GCE instance, or kind/vcluster lifecycle) and pays for it in job time, monthly cost, or cleanup burden. Option 5 outsources all of that to the OpenShift CI cluster pools, which exist precisely for this use case and are operated as a supported platform service. Compared against the alternatives:

| Concern | Option 1 (GKE) | Option 2/3 (kind) | Option 4 (vcluster) | Option 5 (cluster claim) |
|---------|----------------|-------------------|---------------------|--------------------------|
| Job time | ~12-23 min | ~10-17 min | ~11-15 min | ~18 min |
| Monthly cost | ~$117-130 | ~$36-200 | ~$200-300 | $0 (platform-operated) |
| Target-platform fidelity | No -- GKE, not OpenShift | No -- kind, not OpenShift | No -- virtual clusters differ from real clusters in API behavior | Yes -- real OpenShift |
| OLM under test | Pinned v0.28.0 we install | Pinned v0.28.0 we install | Pinned v0.28.0 we install | Shipped by the cluster |
| Infrastructure we own | GKE cluster per run | GCE instance(s), kind lifecycle | Host GKE cluster, vcluster lifecycle | None |
| Cleanup burden | Per-run teardown | Stale kind clusters | Stale virtual clusters | None (pool reclaims) |

Option 5's only meaningful trade-off is the dependency on shared pool capacity, which does not outweigh eliminating all of our infrastructure ownership, cost, and cleanup -- and unlike the other options, it tests on the platform the operator actually targets.

## Presubmit hyperfleet-operator E2E testing — [HYPERFLEET-1707](https://redhat.atlassian.net/browse/HYPERFLEET-1707)

Whichever option is chosen, we can extend the presubmit CI to also run the hyperfleet-operator E2E tests on the same infrastructure. The E2E suite could run on the same cluster and run after the installation of the operator. We would need to modify the E2E tests to drop the test BeforeSuite that builds the operator image.

## Open Questions

- Is presubmit the best place to verify OLM installation? Presubmit testing requires building the operator and bundle image in each PR. Konflux builds the final image on push to main. Which obviously cannot be consumed by the presubmit job, what would be the advantages or disadvantages of moving this to a nightly job, using the most recent konflux artifacts?
- If we decide to go with one of the long running options vcluster or gce instance, what would it look like if a PR is created outside of the 12 hour window when the machines are running?
