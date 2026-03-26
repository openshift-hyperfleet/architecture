---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-01-26
---

# Prow CI/CD Cluster Documentation


---

## Overview

Describes the Prow CI/CD cluster setup used for HyperFleet's continuous integration and deployment pipelines. Covers the cluster configuration, job types (presubmit, postsubmit, periodic), and how HyperFleet repositories are integrated with the Prow-based CI infrastructure.

This is the long-running reserved GKE cluster for Prow CI/CD job execution. This document shows you how to access it, get information about it, update it, and remove it if needed.

- **Cluster Name**: `hyperfleet-dev-prow`
- **GCP Project**: `hcm-hyperfleet`
- **Connect Command**: `gcloud container clusters get-credentials hyperfleet-dev-prow --zone us-central1-a --project hcm-hyperfleet`

---

## Usage Policy

**This cluster is dedicated to running Prow CI/CD jobs for the team.**

- **Read-only operations** (viewing cluster info, logs, etc.) can be performed by all team members
- **Modifications** (updates, deletions, configuration changes) to the cluster or the `prow-hyperfleet` namespace should follow these best practices:
  1. Get **explicit approval** from team leaders
  2. Send a **team-wide broadcast via Slack** before taking action to ensure everyone is aware of potential impacts

---

## Prerequisites for Viewing Cluster

```bash
# Install required tools
gcloud components install kubectl gke-gcloud-auth-plugin
```

## Prerequisites for Terraform Operations

**Only needed if you want to view Terraform state, update, or remove the cluster.**

```bash
# Install Terraform
brew install terraform  # Terraform >= 1.5

# Clone the infrastructure repository
git clone https://github.com/openshift-hyperfleet/hyperfleet-infra.git
cd hyperfleet-infra
```

---

## How to Access the Cluster

### 1. Authenticate with GCP

```bash
gcloud auth login
gcloud config set project hcm-hyperfleet
```

### 2. Get Cluster Credentials

```bash
gcloud container clusters get-credentials hyperfleet-dev-prow \
  --zone us-central1-a \
  --project hcm-hyperfleet
```

### 3. Verify Access

```bash
kubectl get namespaces
kubectl get pods -n prow-hyperfleet
```

---

## How to Get Cluster Information

### View Cluster Details

```bash
# Cluster status and configuration
gcloud container clusters describe hyperfleet-dev-prow \
  --zone us-central1-a \
  --project hcm-hyperfleet

# Node information
kubectl get nodes -o wide

# Running workloads
kubectl get all -n prow-hyperfleet
```

### View Terraform State and Output of Pub/Sub Resource Information

**First, clone the repo if you haven't already** (see [Prerequisites for Terraform Operations](#prerequisites-for-terraform-operations)).

```bash
cd hyperfleet-infra/terraform

# Initialize with Prow backend
terraform init -backend-config=envs/gke/dev-prow.tfbackend

# View all managed resources
terraform state list

# View outputs (includes Pub/Sub config, etc.)
terraform output

# View Pub/Sub resources
terraform output pubsub_config
terraform output pubsub_resources
```

---

## How to Update the Cluster

**⚠️ REMINDER**: Review the [Usage Policy](#usage-policy) before proceeding. Leader approval and team-wide Slack broadcast are recommended.

**First, clone the repo if you haven't already** (see [Prerequisites for Terraform Operations](#prerequisites-for-terraform-operations)).

### 1. Navigate to Terraform Directory

```bash
cd hyperfleet-infra/terraform
```

### 2. Initialize Terraform with Prow Backend

```bash
terraform init -backend-config=envs/gke/dev-prow.tfbackend
```

### 3. Edit Configuration

Edit `envs/gke/dev-prow.tfvars` with your changes:

```hcl
# Common changes:
node_count                 = 2              # Scale up/down
machine_type               = "e2-standard-8" # Change VM size
use_spot_vms               = false          # Switch to regular VMs
```

### 4. Preview and Apply Changes

```bash
# Review what will change
terraform plan -var-file=envs/gke/dev-prow.tfvars

# Coordinate with team before applying
# Then apply changes
terraform apply -var-file=envs/gke/dev-prow.tfvars
```

### 5. Verify Changes

```bash
kubectl get nodes
kubectl get pods -n prow-hyperfleet
```

---

## How to Remove the Cluster

**⚠️ WARNING**: This destroys the entire Prow cluster. Review the [Usage Policy](#usage-policy) before proceeding. Leader approval and team-wide Slack coordination are strongly recommended.

**First, clone the repo if you haven't already** (see [Prerequisites for Terraform Operations](#prerequisites-for-terraform-operations)).

### 1. Disable Deletion Protection

Edit `envs/gke/dev-prow.tfvars`:

```hcl
enable_deletion_protection = false
```

Apply the change:

```bash
cd hyperfleet-infra/terraform
terraform init -backend-config=envs/gke/dev-prow.tfbackend
terraform apply -var-file=envs/gke/dev-prow.tfvars
```

### 2. Destroy the Cluster

```bash
terraform destroy -var-file=envs/gke/dev-prow.tfvars
```

### 3. Recreate (if needed)

```bash
# Re-enable deletion protection in dev-prow.tfvars
enable_deletion_protection = true

# Create cluster
terraform apply -var-file=envs/gke/dev-prow.tfvars
```

---

## Key Configuration Files in hyperfleet-infra Repo

| File | Purpose |
|------|---------|
| `terraform/envs/gke/dev-prow.tfvars` | Cluster configuration (nodes, machine type, etc.) |
| `terraform/envs/gke/dev-prow.tfbackend` | Remote state configuration |
| `terraform/main.tf` | Main Terraform module |

---

## Troubleshooting

### Can't Connect to Cluster

```bash
# Re-authenticate
gcloud auth login
gcloud container clusters get-credentials hyperfleet-dev-prow \
  --zone us-central1-a \
  --project hcm-hyperfleet
```

### Terraform State Lock Issues

**Note**: Terraform automatically locks the state file when using the remote backend (GCS) to prevent concurrent modifications. This is already enabled and working.

If a Terraform operation is interrupted (crashed, network issue, etc.), the lock may remain stuck. To resolve:

```bash
# First, confirm no one is currently running terraform operations
# Then force-unlock using the lock ID from the error message
terraform force-unlock <LOCK_ID>
```

**⚠️ WARNING**: Only use `force-unlock` after confirming no one else is actively running Terraform operations, as this can cause state corruption if multiple people modify state simultaneously.

---

## Additional Documentation

- **Detailed infrastructure docs**: `terraform/README.md` (in the cloned repo)
- **Shared VPC setup**: `terraform/shared/README.md` (in the cloned repo)

---

**Last Updated**: 2026-01-23
