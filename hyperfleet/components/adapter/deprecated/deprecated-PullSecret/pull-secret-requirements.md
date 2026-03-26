---
Status: Deprecated
Owner: HyperFleet Adapter Team
Last Updated: 2026-01-27
---

# HyperFleet Pull Secret Adapter - GCP Secret Manager Requirements

---

## Overview
Requirements document for the GCP pull secret management adapter. Deprecated since GCP specific adapters will be developed by GCP team and out of scope for the core HyperFleet repositories

### Purpose

The Pull Secret Adapter is responsible for securely storing and managing image registry pull secrets in GCP Secret Manager for HyperShift-managed OpenShift clusters. These secrets enable cluster nodes to pull container images from authenticated registries (e.g., Red Hat registries, Quay.io).

### Responsibilities

1. **Secret Creation**: Store pull secrets in GCP Secret Manager
2. **Secret Versioning**: Manage secret versions and updates
3. **Access Control**: Configure IAM policies for secret access
4. **Secret Retrieval**: Provide secret references for HyperShift adapter
5. **Status Reporting**: Report adapter status to HyperFleet API
6. **Lifecycle Management**: Handle secret updates and cleanup


---

## GCP Secret Manager Requirements

### API Access

The adapter requires access to the following GCP Secret Manager APIs:

| API Method | Purpose | Required | Reference |
|------------|---------|----------|-----------|
| `secretmanager.secrets.create` | Create new secret | Yes | [secrets.create](https://docs.cloud.google.com/secret-manager/docs/reference/rest/v1/projects.secrets/create) |
| `secretmanager.secrets.get` | Retrieve secret metadata | Yes | [secrets.get](https://docs.cloud.google.com/secret-manager/docs/reference/rest/v1/projects.secrets/get) |
| `secretmanager.secrets.list` | List secrets (for cleanup) | Optional | [secrets.list](https://docs.cloud.google.com/secret-manager/docs/reference/rest/v1/projects.secrets/list) |
| `secretmanager.versions.add` | Add new secret version | Yes | [secrets.addVersion](https://docs.cloud.google.com/secret-manager/docs/reference/rest/v1/projects.secrets/addVersion) |
| `secretmanager.versions.get` | Retrieve secret version | Yes | [versions.get](https://docs.cloud.google.com/secret-manager/docs/reference/rest/v1/projects.secrets.versions/get) |
| `secretmanager.versions.destroy` | Destroy secret version | Optional | [versions.destroy](https://docs.cloud.google.com/secret-manager/docs/reference/rest/v1/projects.secrets.versions/destroy) |
| `secretmanager.secrets.delete` | Delete secret | Optional | [secrets.delete](https://docs.cloud.google.com/secret-manager/docs/reference/rest/v1/projects.secrets/delete) |

### GCP Project Configuration

**Requirements**:
- [GCP Project ID must be specified in cluster spec](https://cloud.google.com/secret-manager/docs/creating-and-accessing-secrets#create-a-secret)
- [Secret Manager API must be enabled in the project](https://cloud.google.com/secret-manager/docs/configuring-secret-manager#enable-api-console)
- [Project must have sufficient quota for secrets](https://cloud.google.com/secret-manager/quotas)

**Cluster Spec Example**:

```yaml
spec:
  provider: gcp
  gcp:
    projectId: "hyperfleet-prod-12345"  # Red Hat Management Cluster project
    region: "us-central1"
  pullSecret:
    source: "hyperfleet-api"  # Pull secret data stored in HyperFleet API
    replicationPolicy: "automatic"  # or "user-managed" with specific locations
```

The secret name will be auto-derived by the adapter as: `hyperfleet-{cluster-id}-pull-secret`

### Secret Labels

All secrets created by the adapter must include these labels:

```yaml
labels:
  managed-by: "hyperfleet"
  adapter: "pullsecret"
  cluster-id: "{clusterId}"
  cluster-name: "{clusterName}"
  resource-type: "pull-secret"
  hyperfleet-version: "v1"
```

**Purpose**:
- Discovery and filtering
- Cost tracking and billing
- Cleanup and lifecycle management
- Audit and compliance

### Replication Policy

**Supported Policies**:

1. **Automatic Replication** (Default for MVP)
   - GCP manages replication across all regions
   - Highest availability, simplest configuration

2. **User-Managed Replication**
   - Specify exact locations for secret replication


**MVP Scope**: Store credentials in Secret Manager


### Secret Format

The pull secret data must be stored in **Dockercfg JSON format** (standard for Kubernetes image pull secrets):

```json
{
  "auths": {
    "registry.redhat.io": {
      "auth": "base64-encoded-credentials",
      "email": "user@example.com"
    },
    "quay.io": {
      "auth": "base64-encoded-credentials",
      "email": "user@example.com"
    }
  }
}
```

**Validation**:
- Must be valid JSON
- Must contain `auths` key
- Each registry entry must have `auth` field (base64-encoded `username:password`)

### GCP Service Account

The Pull Secret Adapter Job requires a **GCP Service Account** with the following IAM permissions:

**Required Roles**:
- `roles/secretmanager.admin` - Create, update, and delete secrets

**Custom IAM Policy** (Least Privilege):

Minimal permissions for Pull Secret Adapter to manage secrets:

- `secretmanager.secrets.create`
- `secretmanager.secrets.get`
- `secretmanager.secrets.update`
- `secretmanager.secrets.delete`
- `secretmanager.versions.add`
- `secretmanager.versions.get`
- `secretmanager.versions.access`
- `secretmanager.versions.list`
- `secretmanager.versions.destroy`  # Only for cleanup



### Quotas and Limits

**GCP Secret Manager Quotas**:

| Resource | Limit | Description |
|----------|-------|------------|
| Secret size | 64 KiB | Pull secrets are typically < 5 KiB |
| API requests (Access) | 90,000 per minute per project | An access request is any call to the [access API method](https://docs.cloud.google.com/secret-manager/docs/reference/rest/v1/projects.secrets.versions/access) |
| API requests (Read) | 600 per minute per project | A read request is any non-mutating operation (an operation that does not modify a secret version) except for access requests |
| API requests (Write)  | 600 per minute per project | A write request is any mutating operation (an operation that modifies or deletes a secret or secret version) |


## References
- [Creating and Accessing Secrets](https://cloud.google.com/secret-manager/docs/creating-and-accessing-secrets)
- [Configuring Secret Manager](https://cloud.google.com/secret-manager/docs/configuring-secret-manager#enable-api-console)
- [Required Roles](https://cloud.google.com/secret-manager/docs/creating-and-accessing-secrets#required-roles)
- [Creating Custom Roles](https://cloud.google.com/secret-manager/docs/configuring-secret-manager#create-roles)
- [Quotas and Limits](https://docs.cloud.google.com/secret-manager/quotas)
- [Choosing a Replication Policy](https://cloud.google.com/secret-manager/docs/choosing-replication)
