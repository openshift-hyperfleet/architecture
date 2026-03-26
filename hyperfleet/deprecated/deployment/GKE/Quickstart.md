---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2025-11-17
---

# GKE Cluster with Config Connector - Quickstart Guide

## Overview


This guide provides quick commands to create GKE clusters with Config Connector enabled. For detailed configuration options, see [README.md](README.md).

## Available Configurations

We provide two pre-configured environment files for common development scenarios:

### 1. Development with Standard VMs (Zonal)
- **Path:** `cluster-envs/dev-standard-zonal.env`
- **Description:** Stable cluster using Standard VMs with guaranteed availability, suitable for development workloads requiring stability
- **Machine:** e2-standard-4 (4 vCPUs, 16 GB memory)

### 2. Development with Spot VMs (Zonal)
- **Path:** `cluster-envs/dev-spot-zonal.env`
- **Description:** Cost-optimized cluster using Spot VMs (up to 91% cheaper), suitable for development and testing workloads that can tolerate interruptions
- **Machine:** e2-standard-4 (4 vCPUs, 16 GB memory)

## Quick Commands

### Create a Cluster
```bash
./create-gke-cluster.sh <ENV_FILE>
```

### Get Cluster Credentials
Running `./create-gke-cluster.sh cluster-envs/<ENV-FILE>` will generate a `get-cluster-access.sh` script.
Execute `./get-cluster-access.sh` to get the commands for accessing the cluster, and share them with your team if needed.

Note: This requires the `gke-gcloud-auth-plugin` to be installed on your local environment.

### Verify Cluster
```bash
kubectl get nodes
kubectl get pods -n cnrm-system
```

### Delete a Cluster
```bash
./delete-gke-cluster.sh <ENV_FILE>
```

## Customizing Configurations

To create your own configuration:

```bash
# Copy the template
cp cluster-config.env.template cluster-envs/my-custom.env

# Edit with your values
vi cluster-envs/my-custom.env

# Use it
./create-gke-cluster.sh cluster-envs/my-custom.env
```

For detailed configuration options and troubleshooting, see [README.md](README.md).
