---
Status: Deprecated
Owner: HyperFleet Platform Team
Last Updated: 2025-11-17
---

# GKE Cluster Automation with Config Connector


These scripts have been deprecated in favor of the [infra](https://github.com/openshift-hyperfleet/hyperfleet-infra) repository.

---

This directory contains automation scripts for creating Google Kubernetes Engine (GKE) clusters with Config Connector enabled. The solution supports both **Autopilot** and **Standard** cluster modes with full network configuration options.

Note: We are not using Autopilot mode due to current policy restrictions.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Cluster Modes](#cluster-modes)
- [Network Options](#network-options)
- [Estimated Monthly Cost](#estimated-monthly-cost)
- [Team Access](#team-access)
- [Troubleshooting](#troubleshooting)

## Overview

This automation provides:

- **Automated GKE cluster creation** with Config Connector add-on
- **Dual cluster mode support**: Autopilot and Standard
- **Flexible networking**: Create new VPC or use existing infrastructure
- **Workload Identity** configuration for Config Connector
- **Team collaboration** with easy credential sharing
- **Production-ready defaults** with customization options

## Prerequisites

### Required Tools

1. **gcloud CLI** - Google Cloud SDK
   ```bash
   # Install from https://cloud.google.com/sdk/docs/install
   # Verify installation:
   gcloud version
   ```

2. **kubectl** - Kubernetes command-line tool
   ```bash
   # Install from https://kubernetes.io/docs/tasks/tools/
   # Verify installation:
   kubectl version --client
   ```

### Required Permissions

Your GCP user account needs the following IAM roles:

- `roles/container.admin` - To create and manage GKE clusters
- `roles/compute.networkAdmin` - To create VPC networks (if creating new networks)
- `roles/iam.serviceAccountAdmin` - For Config Connector service account management
- `roles/serviceusage.serviceUsageAdmin` - To enable required APIs

### Authentication

Authenticate with Google Cloud:

```bash
gcloud auth login
gcloud auth application-default login
```

## Quick Start

For quick commands to create and manage clusters, see [Quickstart.md](Quickstart.md).

**Basic workflow:**

1. Choose a pre-configured environment file from `cluster-envs/` or create your own
2. Run `./create-gke-cluster.sh <ENV_FILE>` to create the cluster
3. Run `./get-cluster-access.sh <ENV_FILE>` to get credentials
4. Verify with `kubectl get nodes` and `kubectl get pods -n cnrm-system`

## Configuration

### Required Configuration

| Variable | Description | Example |
|----------|-------------|---------|
| `PROJECT_ID` | GCP Project ID | `my-gcp-project` |
| `CLUSTER_NAME` | Name for the GKE cluster | `production-cluster` |
| `REGION` | GCP region | `us-central1` |
| `CLUSTER_MODE` | Cluster type: `autopilot` or `standard` | `autopilot` |
| `NETWORK_MODE` | Network setup: `create` or `existing` | `create` |
| `NETWORK_NAME` | VPC network name | `gke-network` |
| `SUBNET_NAME` | Subnet name | `gke-subnet` |

### Optional Configuration - Network Settings

| Variable | Description | Default |
|----------|-------------|---------|
| `SUBNET_RANGE` | Subnet IP range (CIDR) | `10.0.0.0/24` |
| `SSH_SOURCE_RANGES` | SSH access IP ranges | `0.0.0.0/0` |

### Optional Configuration - Standard Mode

**[STANDARD]** These settings only apply when `CLUSTER_MODE=standard`:

| Variable | Description | Default |
|----------|-------------|---------|
| `DEPLOYMENT_TYPE` | `zonal` or `regional` | `regional` |
| `ZONE` | Specific zone (for zonal) | `${REGION}-a` |
| `NUM_NODES` | Nodes per zone | `1` |
| `MACHINE_TYPE` | Node machine type | `e2-medium` |
| `DISK_SIZE` | Boot disk size (GB) | `100` |
| `MIN_NODES` | Min nodes for autoscaling | `1` |
| `MAX_NODES` | Max nodes for autoscaling | `10` |
| `USE_SPOT_VMS` | Use Spot VMs: `true` or `false` | `false` |

### Optional Configuration - Version

| Variable | Description | Default |
|----------|-------------|---------|
| `RELEASE_CHANNEL` | GKE release channel: `rapid`, `regular`, `stable` | `regular` |
| `CLUSTER_VERSION` | Specific GKE version (if no release channel) | `` |

### Optional Configuration - Config Connector

| Variable | Description | Default |
|----------|-------------|---------|
| `CONFIG_CONNECTOR_SA` | Google Service Account name for Config Connector | `hyperfleet-config-connector` |

### Optional Configuration - Labels

| Variable | Description | Default |
|----------|-------------|---------|
| `LABELS` | Cluster labels (comma-separated) | `` |

**Example:**
```bash
LABELS="environment=production,team=platform,cost-center=engineering"
```

## Cluster Modes

### Autopilot Mode

**Best for:**
- Most production workloads
- Teams wanting fully managed infrastructure
- Cost optimization through auto-scaling
- Reduced operational overhead

**Features:**
- Fully managed nodes
- Automatic scaling and updates
- Regional deployment (high availability)
- Pay-per-pod pricing model

**Configuration:**
```bash
CLUSTER_MODE="autopilot"
```

### Known Issues with Autopilot Mode

#### Organization Policy Restrictions

When creating Autopilot clusters in organizations with strict machine type policies, you may encounter the following error:

```
ERROR: (gcloud.container.clusters.create-auto) Operation [<Operation
 clusterConditions: [<StatusCondition
 canonicalCode: CanonicalCodeValueValuesEnum(FAILED_PRECONDITION, 10)
 message: "[CONDITION_NOT_MET]: Instance 'gk3-hyperfleet-dev-default-pool-9d0396f7-wfrl'
 creation failed: Operation denied by org policy: [customConstraints/custom.denyCostlyMachineTypes] :
 This organization policy prevents creating instances with exotic machine types.
```

**Cause:**
GKE Autopilot automatically selects machine types for your workloads. In some organizations, custom organization policies restrict which machine types can be used, causing cluster creation to fail.

**Solutions:**

1. **Use Standard Mode** - Switch to `CLUSTER_MODE="standard"` and specify an approved machine type from your organization's allowed list.
2. **Request Policy Exception** - Contact your organization's cloud team to request an exception for Autopilot mode.
3. **Check Allowed Machine Types** - Review your organization's policy documentation to understand which machine types are permitted.

Note: We are not using Autopilot mode due to current policy restrictions.

### Standard Mode

**Best for:**
- Workloads requiring specific node configurations
- Custom machine types or GPU requirements
- Fine-grained control over cluster resources

**VM Types:**
- **Standard VMs** (default): Guaranteed availability, suitable for production
- **Spot VMs**: Up to 91% cheaper, can be preempted. Best for dev/test, batch jobs, and fault-tolerant workloads

**Deployment Types:**

#### Regional (Recommended for Production)
- Multi-zone deployment across 3 zones
- High availability and fault tolerance
- Nodes distributed evenly across zones

```bash
CLUSTER_MODE="standard"
DEPLOYMENT_TYPE="regional"
NUM_NODES="1"  # Per zone, so 3 total nodes
USE_SPOT_VMS="false"  # or "true" for cost savings
```

#### Zonal (Development/Testing)
- Single zone deployment
- Lower cost
- Suitable for dev/test environments

```bash
CLUSTER_MODE="standard"
DEPLOYMENT_TYPE="zonal"
ZONE="us-central1-a"
NUM_NODES="1"
USE_SPOT_VMS="true"  # Enable Spot VMs for cost optimization
```

## Network Options

### Option 1: Create New Network

The script will create:
- Custom VPC network
- Subnet with specified CIDR range
- Firewall rules for internal communication
- Firewall rules for SSH access

```bash
NETWORK_MODE="create"
NETWORK_NAME="gke-network"
SUBNET_NAME="gke-subnet"
SUBNET_RANGE="10.0.0.0/24"
SSH_SOURCE_RANGES="0.0.0.0/0"  # Restrict in production!
```

**Security Note:** In production, restrict `SSH_SOURCE_RANGES` to your organization's IP ranges.

### Option 2: Use Existing Network

Use existing VPC infrastructure:

```bash
NETWORK_MODE="existing"
NETWORK_NAME="my-existing-vpc"
SUBNET_NAME="my-existing-subnet"
```

The script will validate that the network and subnet exist in the specified region.

## Estimated Monthly Cost

Understanding the cost implications of different GKE cluster configurations is crucial for budget planning. Below are estimated monthly costs for various Standard mode configurations in the `us-central1` region.

**Cost Comparison Table:**

| Configuration | Machine Type | Nodes | Autoscaling | Location Type | VM Type | Estimated Monthly Cost |
|--------------|--------------|-------|-------------|---------------|---------|----------------------|
| 1 | e2-standard-4 | 1 | Disabled | Regional | Standard | $396.51 |
| 2 | e2-standard-4 | 1 | Disabled | Regional | Spot | $220.35 |
| 3 | e2-standard-4 | 1 | Enabled | Regional | Standard | $1,043.53 |
| 4 | e2-standard-4 | 1 | Enabled | Zonal | Standard | $396.51 |
| 5 | e2-medium | 1 | Enabled | Regional | Standard | $383.13 |

**Machine Type Specifications:**

| Machine Type | vCPUs | Memory (GB) |
|--------------|-------|-------------|
| e2-standard-4 | 4 | 16.00 |
| e2-medium | 2 | 4.00 |

**Key Cost Factors:**

1. **Standard VMs vs Spot VMs** (Config #1 vs #2)
   - Spot VMs provide up to **44% cost savings** ($396.51 → $220.35)
   - Spot VMs can be preempted, suitable for fault-tolerant workloads

2. **Autoscaling: Disabled vs Enabled** (Config #1 vs #3)
   - Enabled autoscaling with min/max configuration increases potential cost
   - Config #3 assumes scaling to maximum capacity, actual cost varies with usage

3. **Location Type: Regional vs Zonal** (Config #3 vs #4)
   - Regional clusters deploy across 3 zones (higher availability, higher cost)
   - Zonal clusters deploy in a single zone (**62% cost savings**: $1,043.53 → $396.51)

4. **Machine Type: e2-standard-4 vs e2-medium** (Config #3 vs #5)
   - Smaller machine types reduce costs when less compute is needed
   - **63% cost savings** by choosing appropriate machine size ($1,043.53 → $383.13)

**Cost Optimization Recommendations:**

- **For Development/Testing:** Use Spot VMs in zonal deployment (e.g., `dev-spot-zonal.env`)
- **For Production:** Use Standard VMs in regional deployment with appropriate machine sizing
- **Enable Autoscaling:** Configure `MIN_NODES` and `MAX_NODES` based on actual workload requirements
- **Right-size Machine Types:** Start with smaller instances and scale up as needed

**Note:** These estimates are based on GKE Standard mode pricing and may not include additional costs for:
- Persistent storage (disks)
- Load balancers
- Network egress
- Config Connector resources managed in GCP

For the most accurate pricing, use the [Google Cloud Pricing Calculator](https://cloud.google.com/products/calculator).

## Team Access

Team members can get access to any cluster by using the same environment file that was used to create it.

### Share Access with Team Members

**Recommended: Use the get-cluster-access.sh script**

```bash
./get-cluster-access.sh
```

This displays the exact `gcloud` command team members should run to get cluster credentials.

**Manual command (if needed)**

For **Autopilot** or **Regional Standard** clusters:
```bash
gcloud container clusters get-credentials CLUSTER_NAME \
    --region=REGION \
    --project=PROJECT_ID
```

For **Zonal Standard** clusters:
```bash
gcloud container clusters get-credentials CLUSTER_NAME \
    --zone=ZONE \
    --project=PROJECT_ID
```

### Required IAM Permissions for Team Members

Team members need one of:

- `roles/container.clusterViewer` - Read-only access
- `roles/container.developer` - Full cluster access (recommended)
- `roles/container.admin` - Administrative access

**Grant access:**
```bash
gcloud projects add-iam-policy-binding PROJECT_ID \
    --member="user:teammate@example.com" \
    --role="roles/container.developer"
```

## Config Connector Usage

After cluster creation, Config Connector is ready to manage GCP resources via Kubernetes manifests.

### Verify Config Connector

```bash
# Check Config Connector pods
kubectl get pods -n cnrm-system

# View Config Connector configuration
kubectl get configconnector -o yaml
```

### Example: Create DNS Managed Zone and Record

Config Connector allows you to manage GCP resources like Cloud DNS using Kubernetes manifests.

```yaml
# dns-resources.yaml
apiVersion: dns.cnrm.cloud.google.com/v1beta1
kind: DNSManagedZone
metadata:
  name: my-public-zone
  namespace: default
  annotations:
    cnrm.cloud.google.com/project-id: "my-gcp-project"
spec:
  dnsName: "example.com."
  description: "Managed by Config Connector"

---

apiVersion: dns.cnrm.cloud.google.com/v1beta1
kind: DNSRecordSet
metadata:
  name: www-a-record
  namespace: default
  annotations:
    cnrm.cloud.google.com/project-id: "my-gcp-project"
spec:
  name: "www.example.com."
  type: "A"
  ttl: 300
  rrdatas:
    - "192.0.2.1"
  managedZoneRef:
    name: my-public-zone
```

Apply the resources:
```bash
kubectl apply -f dns-resources.yaml

# Verify DNS resources
kubectl get dnsmanagedzone
kubectl get dnsrecordset
```

### View Config Connector Logs

```bash
kubectl logs -n cnrm-system -l cnrm.cloud.google.com/component=cnrm-controller-manager
```

## Troubleshooting

### Issue: "Project not found" or "Access denied"

**Solution:**
- Verify you're authenticated: `gcloud auth list`
- Check project ID: `gcloud config get-value project`
- Ensure you have the required IAM roles

### Issue: "API not enabled"

**Solution:**
The script automatically enables required APIs. If you see this error:

```bash
gcloud services enable container.googleapis.com \
    compute.googleapis.com \
    --project=PROJECT_ID
```

### Issue: Config Connector pods not ready

**Solution:**
Config Connector can take 3-5 minutes to initialize.

```bash
# Check pod status
kubectl get pods -n cnrm-system

# View pod logs
kubectl logs -n cnrm-system -l cnrm.cloud.google.com/component=cnrm-controller-manager

# Describe pods for more details
kubectl describe pods -n cnrm-system
```

### Issue: Cluster already exists

**Solution:**
The script will prompt you to continue or abort. If you want to recreate:

```bash
# Delete existing cluster
gcloud container clusters delete CLUSTER_NAME \
    --region=REGION \
    --project=PROJECT_ID

# Run the script again
./create-gke-cluster.sh
```

### Issue: kubectl commands timeout

**Solution:**
The script includes `--request-timeout=120s` for kubectl operations. If you still experience timeouts:

```bash
# Increase timeout manually
kubectl get pods -n cnrm-system --request-timeout=300s
```

### Issue: Network already exists

**Solution:**
If `NETWORK_MODE=create` but the network exists, the script will skip creation and use the existing network. To force recreation:

```bash
# Delete the network (ensure no resources are using it)
gcloud compute networks delete NETWORK_NAME --project=PROJECT_ID

# Run the script again
./create-gke-cluster.sh
```

## Additional Resources

- [GKE Documentation](https://cloud.google.com/kubernetes-engine/docs)
- [Config Connector Documentation](https://cloud.google.com/config-connector/docs/overview)
- [GKE Autopilot](https://cloud.google.com/kubernetes-engine/docs/concepts/autopilot-overview)
- [GKE Release Channels](https://cloud.google.com/kubernetes-engine/docs/concepts/release-channels)
- [Workload Identity](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity)

## License

This automation is provided as-is for use with the Hyperfleet project.
