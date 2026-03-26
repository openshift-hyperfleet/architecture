---
Status: Deprecated
Owner: HyperFleet Adapter Team
Last Updated: 2026-01-27
---

# SPIKE REPORT: Define HyperShift Control Plane Adapter Criteria and Implementation Plan for GCP


## 1. Overview

> Spike report exploring the GCP HyperShift control plane adapter implementation. Deprecated — this GCP-specific HyperShift integration approach was superseded by the current adapter framework. See the `adapter/framework/` directory for the active adapter design.

This spike defines the implementation approach for a GCP HyperShift Control Plane adapter that creates and manages
HostedCluster CRs in a management cluster to provision OpenShift control planes. The solution leverages the HyperFleet
config-driven adapter framework and integrates with HyperShift's GCP platform support.

### Key Decisions

- **Deployment**: Adapter runs as event-driven service (Deployment) consuming cluster events from message broker,
  creates Jobs per cluster event
- **Architecture**: Config-driven adapter framework creating HostedCluster CRs via two-container Job pattern
- **GCP Platform**: Uses HyperShift's GCPPlatformSpec (Tech Preview since v0.1.49, requires TechPreviewNoUpgrade feature
  set)
- **Workload Identity Federation**: GCP HostedClusters require WIF configuration (pools, providers, service accounts)
    - **Note:** This refers to WIF for the **HostedCluster CR** (worker node authentication to GCP). For WIF enabling *
      *CLM adapters** to access customer GCP resources, see [WIF Spike](../../../../docs/wif-spike.md). These are two
      separate WIF configurations.
- **Network Configuration**: Requires VPC network and Private Service Connect subnet
- **Control Plane Creation**: Adapter creates HostedCluster CR (HyperShift operator provisions control plane)
- **Status Tracking**: Monitors HostedCluster conditions and reports to HyperFleet API
- **Management Cluster Selection (MVP)**: Assumes single management cluster; consumer name is static/configured (
  post-MVP: dynamic selection based on region/availability)

### Primary Risks

- **Tech Preview Status**: GCP platform support is Tech Preview (alpha), behind TechPreviewNoUpgrade feature gate
- **HostedCluster API Evolution**: API may change as GCP support matures (currently v1beta1)

---

### Prerequisites vs Adapter Scope

**Prerequisites (created BEFORE adapter runs):**

- Workload Identity Pool and Provider in GCP project
- Google Service Accounts with IAM roles and WIF bindings
- VPC network and Private Service Connect subnet
- Management cluster with Maestro installed
- HyperShift operator deployed on management cluster with `TechPreviewNoUpgrade` feature set

**Adapter Responsibilities:**

- Fetch HyperFleet cluster spec from API
- Map cluster spec fields → HostedCluster CR spec (WIF references, network references, region, etc.)
- Create HostedCluster CR in management cluster via Maestro SDK
- Monitor HostedCluster status conditions
- Report status back to HyperFleet API

**Out of Scope:**

- Creating GCP infrastructure (VPC, subnets, WIF pools)
- Managing certificates (handled by HyperShift operator)
- Creating NodePools (separate adapter - HYPERFLEET-147)

---

## 2. HyperShift Control Plane Adapter Requirements

### 2.1 Overview

The HyperShift Control Plane adapter is a **config-driven adapter** that leverages the HyperFleet adapter framework.
This spike focuses on adapter **configuration and Job logic**; adapter service deployment (Helm chart) follows the same
pattern as other adapters.

The adapter provides configuration that defines:

**Preconditions**: Dependencies that must be satisfied (validation complete, DNS ready, pull secret available)

**Resource Template**: HostedCluster CR specification with GCP platform configuration

**Status Mapping**: How to map HostedCluster status conditions to HyperFleet status pattern (Applied/Available/Health)

The adapter framework handles event consumption, precondition evaluation, resource creation via Maestro SDK, and status
reporting to the HyperFleet API.

### 2.2 HostedCluster CRD Requirements

**API Version**: `hypershift.openshift.io/v1beta1`
**Kind**: `HostedCluster`

**GCP Platform Support**: Tech Preview (alpha since v0.1.49), requires `GCPPlatform` feature gate with
`TechPreviewNoUpgrade` feature set.

**Required HostedCluster Fields for GCP**:

```yaml
apiVersion: hypershift.openshift.io/v1beta1
kind: HostedCluster
metadata:
  name: "{{ .cluster_name }}"
  namespace: "clusters"
spec:
  platform:
    type: GCP
    gcp:
      # GCP project and region
      project: "{{ .gcp_project_id }}"
      region: "{{ .gcp_region }}"

      # Network configuration (required)
      networkConfig:
        network:
          name: "{{ .vpc_network_name }}"
        privateServiceConnectSubnet:
          name: "{{ .psc_subnet_name }}"

      # Workload Identity Federation (required)
      workloadIdentity:
        projectNumber: "{{ .gcp_project_number }}"
        poolID: "{{ .wif_pool_id }}"
        providerID: "{{ .wif_provider_id }}"
        serviceAccountsEmails:
          controlPlane: "{{ .control_plane_sa_email }}"
          nodePool: "{{ .nodepool_sa_email }}"

      # API endpoint access (optional, defaults to Private)
      endpointAccess: Private

      # Resource labels (optional, max 60)
      resourceLabels:
        - key: "cluster-id"
          value: "{{ .cluster_id }}"
        - key: "managed-by"
          value: "hyperfleet"

  # OpenShift release
  release:
    image: "quay.io/openshift-release-dev/ocp-release:{{ .openshift_version }}"

  # Networking
  networking:
    clusterNetwork:
      - cidr: "{{ .cluster_network_cidr }}"
    serviceNetwork:
      - cidr: "{{ .service_network_cidr }}"
    machineNetwork:
      - cidr: "{{ .machine_network_cidr }}"

  # Pull secret
  pullSecret:
    name: "{{ .pull_secret_name }}"

  # DNS
  dns:
    baseDomain: "{{ .base_domain }}"
    publicZoneID: "{{ .public_zone_id }}"

  # Infrastructure ID
  infraID: "{{ .cluster_id }}"

  # SSH key
  sshKey:
    name: "{{ .ssh_key_secret_name }}"
```

**Status Conditions to Monitor**:

- `Available`: Control plane is ready and operational
- `Progressing`: Control plane provisioning is in progress
- `Degraded`: Control plane has errors or issues
- `ReconciliationSucceeded`: HyperShift operator successfully reconciled

### 2.3 Certificate Management

HyperShift operator automatically manages all certificates for the control plane (API server, etcd, OAuth, client certs,
CA bundles). The operator handles certificate generation, rotation, and renewal.

**Adapter Responsibilities**: Monitor only. The adapter watches for `Degraded=True` conditions with certificate-related
reasons (e.g., `CertificateRotationFailed`) and reports status to HyperFleet API. The adapter does NOT create, rotate,
or fix certificate issues.

---

## 3. Adapter Configuration (Config-Driven)

### 3.1 Event Filter and Preconditions

The adapter uses the HyperFleet adapter framework configuration pattern. Key configuration elements:

**Preconditions** (dependencies check):

```yaml
preconditions:
  - name: "fetch_cluster_details"
    apiCall:
      method: "GET"
      endpoint: "{{ .hyperfleetApiBaseUrl }}/api/v1/clusters/{{ .clusterId }}"
    capture:
      - as: "spec"
        field: "spec"
      - as: "clusterPhase"
        field: "status.phase"
      - as: "validationAvailable"
        expression: |
          status.adapters.filter(a, a.name == 'validation')[0].conditions.filter(c, c.type == 'Available')[0].status == "True"
      - as: "dnsAvailable"
        expression: |
          status.adapters.filter(a, a.name == 'dns')[0].conditions.filter(c, c.type == 'Available')[0].status == "True"
      - as: "pullSecretAvailable"
        expression: |
          status.adapters.filter(a, a.name == 'pullsecret')[0].conditions.filter(c, c.type == 'Available')[0].status == "True"
    expression: |
      validationAvailable == true &&
      dnsAvailable == true &&
      pullSecretAvailable == true
```

**Resources** (HostedCluster CR template):

```yaml
resources:
  - kind: "HostedCluster"
    apiVersion: "hypershift.openshift.io/v1beta1"
    namespace: "clusters"
    name: "{{ .clusterName }}"
    spec:
      platform:
        type: GCP
        gcp:
          project: "{{ .spec.gcp_project_id }}"
          region: "{{ .spec.gcp_region }}"
          networkConfig:
            network:
              name: "{{ .spec.vpc_network_name }}"
            privateServiceConnectSubnet:
              name: "{{ .spec.psc_subnet_name }}"
          workloadIdentity:
            projectNumber: "{{ .spec.gcp_project_number }}"
            poolID: "{{ .spec.wif_pool_id }}"
            providerID: "{{ .spec.wif_provider_id }}"
            serviceAccountsEmails:
              controlPlane: "{{ .spec.control_plane_sa_email }}"
              nodePool: "{{ .spec.nodepool_sa_email }}"
          endpointAccess: "{{ .spec.endpoint_access }}"
          resourceLabels:
            - key: "cluster-id"
              value: "{{ .clusterId }}"
            - key: "managed-by"
              value: "hyperfleet"
      release:
        image: "quay.io/openshift-release-dev/ocp-release:{{ .spec.openshift_version }}"
      networking:
        clusterNetwork: [ { cidr: "{{ .spec.cluster_network_cidr }}" } ]
        serviceNetwork: [ { cidr: "{{ .spec.service_network_cidr }}" } ]
        machineNetwork: [ { cidr: "{{ .spec.machine_network_cidr }}" } ]
      pullSecret:
        name: "{{ .pullSecretName }}"
      dns:
        baseDomain: "{{ .spec.base_domain }}"
        publicZoneID: "{{ .publicZoneId }}"
      infraID: "{{ .clusterId }}"
```

**Post-processing** (status tracking):

```yaml
post:
  parameters:
    - name: "clusterStatusPayload"
      build:
        conditions:
          applied:
            status:
              expression: "resources.hostedCluster.status != nil"
          available:
            status:
              expression: |
                has(resources.hostedCluster.status.conditions) &&
                resources.hostedCluster.status.conditions.filter(c, c.type == 'Available')[0].status == "True"
          health:
            status:
              expression: |
                !has(resources.hostedCluster.status.conditions) ||
                resources.hostedCluster.status.conditions.filter(c, c.type == 'Degraded')[0].status != "True"
        data:
          control_plane_endpoint:
            expression: "resources.hostedCluster.status.controlPlaneEndpoint ?? ''"
          version:
            expression: "resources.hostedCluster.status.version ?? ''"

  postActions:
    - type: "api_call"
      method: "POST"
      endpoint: "{{ .hyperfleetApiBaseUrl }}/api/{{ .hyperfleetApiVersion }}/clusters/{{ .clusterId }}/statuses"
      body: "{{ .clusterStatusPayload }}"
```

> **Note**: Full adapter configuration with all fields will be defined in implementation tickets.

### 3.2 Mapping: HyperFleet Cluster Spec → HostedCluster CR

> **Note:** The adapter captures the entire `spec` object from the HyperFleet API response and references fields as
`.spec.fieldname` in the template (e.g., `{{ .spec.gcp_project_id }}`). This reduces config verbosity compared to
> capturing each field individually.

| HyperFleet Cluster Field      | HostedCluster CR Field                                                  | Notes                          |
|-------------------------------|-------------------------------------------------------------------------|--------------------------------|
| `spec.gcp_project_id`         | `spec.platform.gcp.project`                                             | GCP project ID                 |
| `spec.gcp_project_number`     | `spec.platform.gcp.workloadIdentity.projectNumber`                      | GCP project number (for WIF)   |
| `spec.gcp_region`             | `spec.platform.gcp.region`                                              | GCP region                     |
| `spec.vpc_network_name`       | `spec.platform.gcp.networkConfig.network.name`                          | VPC network name               |
| `spec.psc_subnet_name`        | `spec.platform.gcp.networkConfig.privateServiceConnectSubnet.name`      | Private Service Connect subnet |
| `spec.wif_pool_id`            | `spec.platform.gcp.workloadIdentity.poolID`                             | Workload Identity pool ID      |
| `spec.wif_provider_id`        | `spec.platform.gcp.workloadIdentity.providerID`                         | Workload Identity provider ID  |
| `spec.control_plane_sa_email` | `spec.platform.gcp.workloadIdentity.serviceAccountsEmails.controlPlane` | Control plane GSA email        |
| `spec.nodepool_sa_email`      | `spec.platform.gcp.workloadIdentity.serviceAccountsEmails.nodePool`     | NodePool GSA email             |
| `spec.endpoint_access`        | `spec.platform.gcp.endpointAccess`                                      | Private or PublicAndPrivate    |
| `metadata.id`                 | `spec.platform.gcp.resourceLabels[0].value`                             | Cluster ID label               |
| `spec.openshift_version`      | `spec.release.image`                                                    | Maps to release image URL      |
| `spec.cluster_network_cidr`   | `spec.networking.clusterNetwork[0].cidr`                                | Pod network CIDR               |
| `spec.service_network_cidr`   | `spec.networking.serviceNetwork[0].cidr`                                | Service CIDR                   |
| `spec.machine_network_cidr`   | `spec.networking.machineNetwork[0].cidr`                                | VPC CIDR                       |
| `spec.base_domain`            | `spec.dns.baseDomain`                                                   | From DNS adapter               |
| Pull secret (from adapter)    | `spec.pullSecret.name`                                                  | Created by pull secret adapter |

---

## 4. Implementation Approach

### 4.1 Job Container Pattern (Two-Container Sidecar)

The adapter uses the **two-container sidecar pattern** (same as Dandan's validation adapter) to decouple Maestro SDK
operations from status reporting. This pattern enables clean separation between Applied (ManifestWork created) and
Available (HostedCluster ready) conditions with different timing requirements.

**Job Manifest**:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: "hypershift-controlplane-{{ .clusterId }}-gen{{ .generationId }}"
  namespace: hyperfleet-adapters
  labels:
    hyperfleet.io/adapter: controlplane
    hyperfleet.io/cluster-id: "{{ .clusterId }}"
spec:
  ttlSecondsAfterFinished: 60  # Auto-delete after 1 minute (triggers fresh creation on next Sentinel pulse)
  template:
    spec:
      serviceAccountName: maestro-adapter-sa  # Kubernetes auto-mounts token
      restartPolicy: Never

      containers:
        # Container 1: Control Plane Adapter (Maestro SDK operations)
        - name: adapter
          image: "{{ .registry }}/hypershift-controlplane-adapter:{{ .version }}"
          env:
            - name: CLUSTER_ID
              value: "{{ .clusterId }}"
            - name: MAESTRO_API_URL
              value: "{{ .maestroApiUrl }}"
            - name: MAESTRO_GRPC_URL
              value: "{{ .maestroGrpcUrl }}"
            - name: MANAGEMENT_CLUSTER_CONSUMER
              value: "{{ .managementClusterConsumer }}"  # MVP: static/configured value
            - name: RESULTS_OUTPUT_PATH
              value: "/results/adapter-report.json"
          volumeMounts:
            - name: results
              mountPath: /results
              readOnly: false  # Adapter writes results here

        # Container 2: Status Reporter Sidecar (Reusable component)
        - name: status-reporter
          image: "{{ .registry }}/adapter-status-reporter:{{ .reporterVersion }}"
          env:
            - name: RESULTS_INPUT_PATH
              value: "/results/adapter-report.json"
            - name: POLL_INTERVAL
              value: "2"  # Check for results every 2 seconds
          volumeMounts:
            - name: results
              mountPath: /results
              readOnly: true  # Reporter only reads results

      volumes:
        - name: results
          emptyDir: { }  # Shared volume for result communication
```

**Main Adapter Container Responsibilities**:

The adapter container performs Maestro SDK operations and writes results to `/results/adapter-report.json`:

1. **Check if ManifestWork exists** (idempotency via `Get` call)
2. **Create ManifestWork if missing** (via `Create` call) → Set Applied=True, Available=False
3. **Query ManifestWork status if exists** (via `Get` call) → Extract HostedCluster status from feedback
4. **Map HostedCluster conditions** to Applied/Available/Health semantics
5. **Write JSON results** to shared volume and exit

**Adapter Logic Pattern** (pseudocode):

```go
// Read ServiceAccount token (auto-mounted by Kubernetes)
token, _ := os.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/token")

// Create Maestro SDK client
workClient, err := grpcsource.NewMaestroGRPCSourceWorkClient(ctx, logger, maestroAPIClient, grpcOpts, "controlplane-adapter")

// Check if ManifestWork exists
consumerName := os.Getenv("MANAGEMENT_CLUSTER_CONSUMER") // MVP: static value like "us-east-mgmt-01"
workName := fmt.Sprintf("hostedcluster-%s", clusterID)

existing, err := workClient.ManifestWorks(consumerName).Get(ctx, workName, metav1.GetOptions{})

var conditions []Condition
if errors.IsNotFound(err) {
    // ManifestWork doesn't exist - create it
    work := buildHostedClusterManifestWork(clusterID, consumerName)
    _, err = workClient.ManifestWorks(consumerName).Create(ctx, work, metav1.CreateOptions{})

    conditions = []Condition{
        {Type: "Applied", Status: "True", Reason: "ManifestWorkCreated", Message: "HostedCluster CR sent to management cluster"},
        {Type: "Available", Status: "False", Reason: "Provisioning", Message: "Control plane provisioning in progress"},
        {Type: "Health", Status: "True", Reason: "NoIssues", Message: "No degradation detected"},
    }
} else if err == nil {
    // ManifestWork exists - check HostedCluster status from feedback
    hostedClusterStatus := extractStatusFromManifestWorkFeedback(existing)

    conditions = []Condition{
        {Type: "Applied", Status: "True", Reason: "ManifestWorkExists", Message: "HostedCluster CR exists in management cluster"},
        {Type: "Available", Status: checkAvailableCondition(hostedClusterStatus), Reason: "...", Message: "..."},
        {Type: "Health", Status: checkHealthCondition(hostedClusterStatus), Reason: "...", Message: "..."},
    }

    // Extract additional data
    controlPlaneEndpoint = hostedClusterStatus.ControlPlaneEndpoint
    version = hostedClusterStatus.Version
} else {
    // Maestro SDK error (network, auth, etc.)
    conditions = []Condition{
        {Type: "Applied", Status: "False", Reason: "MaestroError", Message: err.Error()},
        {Type: "Available", Status: "False", Reason: "Unknown", Message: "Cannot determine status"},
        {Type: "Health", Status: "False", Reason: "AdapterError", Message: "Maestro SDK call failed"},
    }
}

// Write results to shared volume
results := map[string]interface{}{
    "conditions": conditions,
    "data": map[string]string{
        "control_plane_endpoint": controlPlaneEndpoint,
        "version":                version,
    },
}
file, _ := os.Create("/results/adapter-report.json")
json.NewEncoder(file).Encode(results)
file.Close()

// Exit (sidecar handles status reporting)
os.Exit(0)
```

**Helper Functions** (referenced in pseudocode above):

```go
// buildHostedClusterManifestWork constructs a ManifestWork that wraps the HostedCluster CR
func buildHostedClusterManifestWork(clusterID, consumerName string) *workv1.ManifestWork {
    // Build HostedCluster YAML from template
    hostedClusterYAML := fmt.Sprintf(`
apiVersion: hypershift.openshift.io/v1beta1
kind: HostedCluster
metadata:
  name: %s
  namespace: clusters
spec:
  platform:
    type: GCP
    gcp:
      project: %s
      region: %s
      networkConfig:
        network:
          name: %s
        privateServiceConnectSubnet:
          name: %s
      workloadIdentity:
        projectNumber: %s
        poolID: %s
        providerID: %s
        serviceAccountsEmails:
          controlPlane: %s
          nodePool: %s
      endpointAccess: Private
      resourceLabels:
        - key: "cluster-id"
          value: %s
        - key: "managed-by"
          value: "hyperfleet"
  release:
    image: %s
  networking:
    clusterNetwork:
      - cidr: %s
    serviceNetwork:
      - cidr: %s
    machineNetwork:
      - cidr: %s
  pullSecret:
    name: %s
  dns:
    baseDomain: %s
    publicZoneID: %s
  infraID: %s
`,
        clusterName, gcpProjectID, gcpRegion, vpcNetworkName, pscSubnetName,
        gcpProjectNumber, wifPoolID, wifProviderID, controlPlaneSA, nodepoolSA,
        clusterID, releaseImage, clusterNetworkCIDR, serviceNetworkCIDR,
        machineNetworkCIDR, pullSecretName, baseDomain, publicZoneID, clusterID,
    )

    return &workv1.ManifestWork{
        ObjectMeta: metav1.ObjectMeta{
            Name:      fmt.Sprintf("hostedcluster-%s", clusterID),
            Namespace: consumerName, // ← Management cluster consumer name
            Labels: map[string]string{
                "hyperfleet.io/cluster-id": clusterID,
                "hyperfleet.io/adapter":    "controlplane",
            },
        },
        Spec: workv1.ManifestWorkSpec{
            Workload: workv1.ManifestsTemplate{
                Manifests: []workv1.Manifest{
                    {
                        RawExtension: runtime.RawExtension{
                            Raw: []byte(hostedClusterYAML),
                        },
                    },
                },
            },
            // CRITICAL: FeedbackRules tell Maestro what status to return
            ManifestConfigs: []workv1.ManifestConfigOption{
                {
                    ResourceIdentifier: workv1.ResourceIdentifier{
                        Group:     "hypershift.openshift.io",
                        Resource:  "hostedclusters",
                        Namespace: "clusters",
                        Name:      clusterName,
                    },
                    UpdateStrategy: &workv1.UpdateStrategy{
                        Type: workv1.UpdateStrategyTypeServerSideApply,
                    },
                    // FeedbackRules: Extract HostedCluster status from management cluster
                    FeedbackRules: []workv1.FeedbackRule{
                        {
                            Type: workv1.JSONPathsType,
                            JsonPaths: []workv1.JsonPath{
                                {
                                    Name: "status",  // Referenced when reading feedback
                                    Path: ".status", // JSONPath to HostedCluster status field
                                },
                            },
                        },
                    },
                },
            },
            DeleteOption: &workv1.DeleteOption{
                PropagationPolicy: workv1.DeletePropagationPolicyTypeForeground,
            },
        },
    }
}

// extractStatusFromManifestWorkFeedback parses HostedCluster status from ManifestWork feedback
func extractStatusFromManifestWorkFeedback(mw *workv1.ManifestWork) (*HostedClusterStatus, error) {
    // ManifestWork.Status.ResourceStatus.Manifests contains feedback from management cluster
    if len(mw.Status.ResourceStatus.Manifests) == 0 {
        return nil, fmt.Errorf("no manifest status found")
    }

    // Find the status feedback (matches feedbackRule name "status")
    for _, manifestStatus := range mw.Status.ResourceStatus.Manifests {
        for _, feedback := range manifestStatus.StatusFeedbacks.Values {
            if feedback.Name == "status" {
                // Parse the JSON status returned from management cluster
                var status HostedClusterStatus
                if err := json.Unmarshal([]byte(*feedback.Value.JsonRaw), &status); err != nil {
                    return nil, fmt.Errorf("failed to parse status: %w", err)
                }
                return &status, nil
            }
        }
    }

    return nil, fmt.Errorf("status feedback not found")
}

type HostedClusterStatus struct {
    Conditions           []Condition `json:"conditions"`
    ControlPlaneEndpoint string      `json:"controlPlaneEndpoint"`
    Version              string      `json:"version"`
}

type Condition struct {
    Type    string `json:"type"`
    Status  string `json:"status"`
    Reason  string `json:"reason"`
    Message string `json:"message"`
}

// checkAvailableCondition maps HostedCluster Available condition to HyperFleet Available
func checkAvailableCondition(status *HostedClusterStatus) (string, string, string) {
    // Find Available condition in HostedCluster status
    for _, cond := range status.Conditions {
        if cond.Type == "Available" {
            if cond.Status == "True" {
                return "True", "ControlPlaneReady", "Control plane is ready and operational"
            } else {
                // Available=False - check if Progressing
                for _, c := range status.Conditions {
                    if c.Type == "Progressing" && c.Status == "True" {
                        return "False", "Provisioning", "Control plane provisioning in progress"
                    }
                }
                return "False", "NotReady", "Control plane not ready"
            }
        }
    }
    // Condition not found - default to False
    return "False", "Unknown", "Control plane status unknown"
}

// checkHealthCondition maps HostedCluster Degraded condition to HyperFleet Health
func checkHealthCondition(status *HostedClusterStatus) (string, string, string) {
    // Find Degraded condition in HostedCluster status
    for _, cond := range status.Conditions {
        if cond.Type == "Degraded" {
            if cond.Status == "True" {
                return "False", "Degraded", fmt.Sprintf("Control plane is degraded: %s", cond.Message)
            }
        }
    }
    // No degradation = healthy
    return "True", "NoIssues", "No degradation detected"
}
```

**JSON Schema** (`/results/adapter-report.json`):

```json
{
  "conditions": [
    {
      "type": "Applied",
      "status": "True",
      "lastTransitionTime": "2024-12-11T10:30:00Z",
      "reason": "ManifestWorkCreated",
      "message": "HostedCluster CR sent to management cluster"
    },
    {
      "type": "Available",
      "status": "False",
      "lastTransitionTime": "2024-12-11T10:30:00Z",
      "reason": "Provisioning",
      "message": "Control plane provisioning in progress"
    },
    {
      "type": "Health",
      "status": "True",
      "lastTransitionTime": "2024-12-11T10:30:00Z",
      "reason": "NoIssues",
      "message": "No degradation detected"
    }
  ],
  "data": {
    "control_plane_endpoint": "",
    "version": ""
  }
}
```

**Status Reporter Sidecar**:

The status reporter is a **reusable component** (same one used by validation adapter). It:

1. Polls for `/results/adapter-report.json` (every 2 seconds)
2. Reads the JSON file once it appears
3. Patches `Job.status.conditions` via `kubectl patch --subresource=status`
4. Exits

The adapter framework reads `Job.status.conditions` and reports to HyperFleet API. The sidecar doesn't need to
understand
Applied/Available/Health semantics - it just copies the conditions array from JSON to Job status.

**Flow Summary**:

```
Sentinel Pulse → Framework checks: Does Job exist?
                   ↓
                 NO: Create new Job (no report yet)
                   ↓
                 [Job Runs Asynchronously]
                 [Main Container] Maestro SDK calls → Write JSON → Exit
                   ↓
                 [Sidecar] Read JSON → Patch Job.status.conditions → Exit
                   ↓
Next Sentinel Pulse → Job exists → Read Job.status.conditions → Report to HyperFleet API
                   ↓
                 (Repeated pulses continue reading Job.status and reporting)
                   ↓
                 Job auto-deleted after TTL expires (60 seconds)
                   ↓
Next Sentinel Pulse → Job doesn't exist → Create fresh Job (repeat cycle)
```

**Why This Pattern Works**:

- **Applied=True after ~30 seconds**: First Job run creates ManifestWork, reports Applied=True + Available=False
- **Available=True after 10-30 minutes**: Subsequent Jobs (after TTL deletion) query ManifestWork status, detect
  HostedCluster Available=True, report updated conditions
- **Clean separation**: Adapter logic doesn't need to handle Job status patching (sidecar handles it)
- **Reusable sidecar**: Same status-reporter image used across all adapters

### 4.2 Adapter Workflow

The adapter follows the standard adapter framework pattern with HostedCluster CR-specific logic:

- **Idempotency**: Checks if ManifestWork exists via Maestro SDK `Get` call before creating
- **Creation**: Creates ManifestWork wrapping HostedCluster CR if it doesn't exist
- **Monitoring**: Fetches ManifestWork status with HostedCluster feedback if CR already exists
- **Reporting**: Maps HostedCluster conditions to HyperFleet status (Applied/Available/Health) via JSON schema

**Job TTL Pattern**: Jobs auto-delete after `ttlSecondsAfterFinished: 60`. When deleted, the adapter framework sees "Job
doesn't exist" on the next Sentinel pulse and creates a fresh Job, triggering a new Maestro SDK `Get` call to check
updated HostedCluster status.

> **Note**: The 60-second TTL assumes Sentinel pulses occur every ~10 seconds, providing multiple opportunities to read Job status before deletion. If Sentinel pulse intervals are longer or inconsistent, the TTL may need to be increased to prevent status loss.

### 4.3 Status Reporting Patterns

Status reports to HyperFleet API include:

- **Conditions**: Applied (ManifestWork created), Available (control plane ready), Health (no degradation)
- **Data**: `control_plane_endpoint` (API endpoint URL), `version` (OpenShift version)
- **Metadata**: `observed_generation`, `observed_time`

**State Transitions**: Provisioning (Available=False, empty endpoint/version) → Ready (Available=True, populated
endpoint/version) → Degraded (Health=False if issues)

---

## 5. Maestro Integration

### 5.1 Cross-Cluster Architecture

The HyperFleet architecture uses separate clusters:

- **Regional Clusters**: Run HyperFleet adapters
- **Management Clusters**: Run HyperShift operator and host HostedCluster CRs

Adapters run in regional clusters but create HostedCluster CRs in management clusters, requiring **cross-cluster
resource management**. Maestro provides the transportation layer between regional and management clusters, handling
authentication, resource propagation, and status feedback.

**For detailed Maestro integration patterns, see
**: [Maestro Integration Guide](../../../../components/adapter/framework/maestro-integration-guide.md)

### 5.2 Adapter Framework Integration

The adapter configuration specifies Maestro as the resource backend:

```yaml
resources:
  - name: "hostedCluster"
    backend: "maestro"
    targetCluster: "{{ .managementClusterName }}"
    manifest:
      apiVersion: hypershift.openshift.io/v1beta1
      kind: HostedCluster
      # ... HostedCluster spec from Section 3.2
```

The adapter framework handles:

- Creating ManifestWork via Maestro SDK (gRPC)
- Wrapping HostedCluster CR with consumer targeting and feedback rules
- Authenticating with ServiceAccount token
- Idempotency checks before creation

**Consumer Targeting (MVP)**: The `targetCluster` field specifies the consumer name (management cluster). For MVP, this
is a static/configured value (e.g., `us-east-mgmt-01`). Post-MVP, this will be dynamic selection based on region,
availability, and load balancing via HyperFleet API query.

### 5.3 Status Monitoring

**Status Flow**:
The adapter uses the two-container sidecar pattern (Section 4.1) to monitor HostedCluster status. Each Job run makes a
fresh Maestro SDK `Get` call to retrieve ManifestWork status, which includes HostedCluster status feedback from the
management cluster. Jobs auto-delete after TTL expires, ensuring each Sentinel pulse gets updated status.

**HostedCluster Status Mapping**:
The adapter maps HostedCluster status conditions to HyperFleet status pattern:

| HostedCluster Condition | HyperFleet Condition | Notes                                         |
|-------------------------|----------------------|-----------------------------------------------|
| (ManifestWork created)  | Applied=True         | HostedCluster CR exists in management cluster |
| Available=True          | Available=True       | Control plane ready                           |
| Progressing=True        | Available=False      | Control plane provisioning                    |
| Degraded=True           | Health=False         | Control plane has issues                      |

### 5.4 Error Handling

The adapter handles Maestro SDK errors with appropriate retry strategies:

| Error Type           | Example                      | Retry Strategy                            | Adapter Action                                   |
|----------------------|------------------------------|-------------------------------------------|--------------------------------------------------|
| Transient Network    | Maestro gRPC unavailable     | Exponential backoff (1s initial, 60s max) | Retry Job                                        |
| Permanent Auth       | Invalid ServiceAccount token | No retry                                  | Exit with error, report Applied=False            |
| Permanent Validation | Invalid HostedCluster spec   | No retry                                  | Exit with error, report Applied=False            |
| Resource Conflict    | ManifestWork already exists  | Check ownership                           | If owned: report status. If not: exit with error |

**Error Reporting**:
Errors are reported to HyperFleet API with detailed context including failure reason and remediation guidance.

---

## 6. Success/Failure Conditions

### 6.1 Success Criteria

**Applied Condition**:

- `True`: HostedCluster CR exists in management cluster
- `False`: HostedCluster CR not created (preconditions not met or creation failed)

**Available Condition**:

- `True`: HostedCluster status.conditions[type=Available].status == "True"
- `False`: Control plane not ready yet or failed

**Health Condition**:

- `True`: HostedCluster status.conditions[type=Degraded].status != "True"
- `False`: Control plane is degraded or adapter encountered errors

### 6.2 HostedCluster Status Monitoring

The adapter monitors these HostedCluster conditions:

| HostedCluster Condition        | Meaning                          | Maps to HyperFleet |
|--------------------------------|----------------------------------|--------------------|
| `Available=True`               | Control plane ready              | Available=True     |
| `Progressing=True`             | Provisioning in progress         | Available=False    |
| `Degraded=True`                | Control plane has issues         | Health=False       |
| `ReconciliationSucceeded=True` | Operator reconciled successfully | Applied=True       |

---

## 7. Control Plane Updates and Deletion Strategy

**MVP scope only implements creation**; these strategies inform future implementation.

### 7.1 Configuration Updates Strategy

HyperShift HostedCluster CRs have both mutable and immutable fields. The adapter must validate updates and reject
changes to immutable fields.

**Immutable Fields**: Platform type, GCP project/region, networking CIDRs, infraID
**Mutable Fields**: `spec.release.image` (for version upgrades), resource tags, DNS config, SSH key

**Version Upgrades**: Adapter detects generation increments, compares `spec.release.image` between HyperFleet spec and
HostedCluster CR, updates if changed, and monitors HostedCluster status conditions to track upgrade progress.

**Update Validation**: Adapter configuration includes immutable field validation rules. Attempts to change immutable
fields are rejected with `Applied=False` and detailed error reporting.

### 7.2 Deletion and Cleanup Strategy

**Deletion Trigger**: Cluster phase = `"Terminating"` in HyperFleet API or deletion event from message broker.

**Cleanup Order**: HyperShift requires NodePools to be deleted before HostedCluster. Adapter checks NodePool count via
API call; if NodePools exist, reports `Applied=False` with reason `NodePoolsExist` and waits for NodePool adapter.

**Finalizer Handling**: HostedCluster CRs have finalizers that prevent deletion until cleanup completes. Adapter
monitors deletion progress and reports status (deletion initiated → finalizers running → fully deleted). If finalizers
are stuck for > 30 minutes, reports `Health=False` with remediation guidance.

---

## 8. MVP vs Post-MVP

### 8.1 MVP Scope

**Goal**: Prove adapter framework works for HostedCluster CR management

**Deliverables**:

- Adapter configuration (preconditions, HostedCluster template, post-processing)
- RBAC configuration for management cluster access
- Status reporting based on HostedCluster conditions
- Integration with adapter framework
- Unit tests for configuration validation
- Integration tests with HostedCluster CRD (may use mocked management cluster)

**MVP Assumptions**:

- Single management cluster (consumer name is static/configured value)
- No dynamic management cluster selection logic

**Success Criteria**:

- Adapter creates HostedCluster CR when preconditions met
- Adapter tracks HostedCluster status conditions
- Adapter reports status to HyperFleet API using 3-condition pattern
- Configuration validates against adapter framework schema

### 8.2 Post-MVP

**Dynamic Management Cluster Selection**:

- Query HyperFleet API (`/api/v1/management-clusters?region={region}&status=healthy`) to get available management
  clusters
- Implement selection logic based on region matching, availability, and load balancing
- Support multiple management clusters per region for high availability
- Handle management cluster failures and automatic failover

**Configuration Updates**:

- Support HostedCluster updates (version upgrades, configuration changes)
- Validate immutable field changes and reject invalid updates
- Track update progress and report upgrade status

**Deletion Strategy**:

- Coordinate with NodePool adapter for ordered deletion
- Monitor finalizer progress and report deletion status
- Handle stuck finalizers with timeout and remediation guidance

---

## 9. Dependencies and Risks

### 9.1 Dependencies

1. **Maestro API Access**: Job containers need Maestro REST API endpoint and ServiceAccount token for authentication
2. **Management Cluster**: GKE cluster with HyperShift operator deployed and `TechPreviewNoUpgrade` feature set enabled
3. **GCP Prerequisites**: WIF pools/providers, VPC network, and Private Service Connect subnet must exist (see Section 1
   Prerequisites)
4. **Adapter Preconditions**: DNS adapter, Pull Secret adapter, and Validation adapter must complete first (defined in
   adapter config)
5. **Adapter Service RBAC**: ServiceAccount needs permissions to create/read Jobs (`batch/jobs` create, get, watch) -
   configured in Helm chart deployment

### 9.2 Risks and Mitigations

| Risk                                         | Impact | Mitigation                                                                  |
|----------------------------------------------|--------|-----------------------------------------------------------------------------|
| Tech Preview stability                       | HIGH   | Test thoroughly in non-production environments; plan for API changes        |
| WIF configuration complexity                 | HIGH   | Validate WIF setup in validation adapter; provide clear documentation       |
| Network prerequisites missing                | HIGH   | Validation adapter must verify VPC and PSC subnet exist before provisioning |
| HostedCluster API changes                    | MEDIUM | Track HyperShift releases, use versioned API (v1beta1), test upgrades       |
| Management cluster access issues             | HIGH   | Design proper RBAC early, test with actual management cluster               |
| CR creation pattern differs from Job pattern | MEDIUM | Validate adapter framework supports CR creation                             |
| Feature gate not enabled                     | HIGH   | Document TechPreviewNoUpgrade requirement; validate in deployment checks    |

---

## 10. Acceptance Criteria for Implementation

### MVP Acceptance Criteria

**Adapter Configuration**:

- [ ] Preconditions defined (validation, DNS, pull secret dependencies)
- [ ] HostedCluster CR template with GCP platform spec
- [ ] Post-processing configuration for status tracking
- [ ] Configuration validates against adapter framework schema

**RBAC Configuration**:

- [ ] Service Account created in management cluster
- [ ] Role grants HostedCluster create/read/list permissions
- [ ] RoleBinding associates SA with Role

**Integration**:

- [ ] Adapter creates HostedCluster CR when preconditions met
- [ ] Adapter skips creation if HostedCluster already exists
- [ ] Adapter fetches HostedCluster status and evaluates conditions
- [ ] Adapter reports status to HyperFleet API

**Testing**:

- [ ] Unit tests for configuration validation
- [ ] Integration tests with HostedCluster CRD (may use mock)
- [ ] E2E test with actual management cluster (if available)

**Documentation**:

- [ ] Spike report complete (this document)
- [ ] Configuration documented with field mappings
- [ ] RBAC requirements documented
- [ ] Update HYPERFLEET-58 epic acceptance criteria

### 10.2 Implementation Task Breakdown

Based on this spike's findings, the following implementation stories should be created:

**HYPERFLEET-XXX: Create HyperShift Control Plane Adapter Configuration**

- **Deliverable**: `hypershift-controlplane-adapter-config.yaml` with preconditions, HostedCluster template, and
  post-processing
- **Estimate**: 3 story points
- **Dependencies**: Adapter framework supports Custom Resource creation

**HYPERFLEET-XXX: Setup RBAC for Management Cluster Access**

- **Deliverable**: ServiceAccount, Role, RoleBinding YAML files
- **Estimate**: 2 story points
- **Dependencies**: Management cluster with HyperShift operator deployed

**HYPERFLEET-XXX: Implement ManifestWork Feedback Extraction Logic**

- **Deliverable**: Code to extract HostedCluster status from ManifestWork feedback (
  extractStatusFromManifestWorkFeedback function)
- **Estimate**: 3 story points
- **Dependencies**: Maestro SDK integration complete

**HYPERFLEET-XXX: Implement HostedCluster Status Monitoring Logic**

- **Deliverable**: Post-processing configuration to monitor HostedCluster conditions (Available, Progressing, Degraded)
- **Estimate**: 3 story points
- **Dependencies**: ManifestWork feedback extraction complete

**HYPERFLEET-XXX: Add Validation for Immutable Field Changes**

- **Deliverable**: Validation rules in adapter configuration to reject updates to immutable fields
- **Estimate**: 2 story points
- **Dependencies**: HostedCluster status monitoring complete

**HYPERFLEET-XXX: Write Unit Tests for Adapter Configuration**

- **Deliverable**: Unit tests validating configuration schema and preconditions
- **Estimate**: 2 story points
- **Dependencies**: Adapter configuration complete

**HYPERFLEET-XXX: Integration Testing with HostedCluster CRD**

- **Deliverable**: Integration tests with mocked management cluster or test environment
- **Estimate**: 5 story points
- **Dependencies**: Adapter configuration and RBAC complete

**HYPERFLEET-XXX: E2E Testing with Real Management Cluster**

- **Deliverable**: End-to-end test creating HostedCluster and verifying status reporting
- **Estimate**: 5 story points
- **Dependencies**: TechPreviewNoUpgrade feature set enabled, WIF infrastructure created, test management cluster
  available

**HYPERFLEET-XXX: Document Adapter Configuration and Deployment**

- **Deliverable**: README with setup instructions, configuration examples, troubleshooting guide
- **Estimate**: 2 story points
- **Dependencies**: All implementation complete

**HYPERFLEET-XXX: Create Helm Chart for Adapter Service Deployment**

- **Deliverable**: Helm chart deploying adapter service (follows adapter-landing-zone pattern)
- **Estimate**: 3 story points
- **Dependencies**: Adapter configuration complete, RBAC requirements defined

**HYPERFLEET-XXX: Update HYPERFLEET-58 Epic Acceptance Criteria**

- **Deliverable**: Epic acceptance criteria updated with HyperShift control plane adapter findings
- **Estimate**: 1 story point
- **Dependencies**: Spike complete

**Total Estimated Effort**: 31 story points

**Critical Path Dependencies**:

1. HyperShift GCP support requires TechPreviewNoUpgrade feature set on management cluster
2. Workload Identity Federation infrastructure must be created before E2E testing
3. Management cluster with HyperShift operator must be available for integration/E2E testing
4. Adapter framework must support Custom Resource creation (validation needed)

---

## 11. Next Steps

**Immediate Actions** (Post-Spike):

1. **Update HYPERFLEET-58 Epic Acceptance Criteria**:
    - Add findings from this spike to epic description
    - Document decision to use Maestro SDK for cross-cluster resource management
    - Note Tech Preview status and TechPreviewNoUpgrade feature gate requirement
    - Include WIF and network prerequisites
    - Include certificate management approach (operator-managed, adapter monitors only)

2. **Create Implementation Stories**:
    - Break down tasks from Section 10.2 into individual JIRA stories
    - Link all stories to HYPERFLEET-58 epic
    - Assign story points and priorities
    - Add acceptance criteria to each story

3. **Schedule Technical Review**:
    - Present spike findings to team (15-20 minute walkthrough)
    - Review WIF and network prerequisites
    - Review approach for updates and deletion strategy (Section 7)
    - Confirm decision to use Maestro SDK for cross-cluster resource management (Section 5)
    - Discuss Tech Preview implications for production readiness
    - Discuss testing strategy (mocked vs real management cluster for integration tests)
    - Get approval to proceed with implementation

4. **Validate Adapter Framework Support**:
    - Confirm adapter framework can create and manage Custom Resources (not just Jobs)
    - Test framework with sample HostedCluster CR in dev environment
    - Identify any framework enhancements needed before implementation

5. **Setup WIF Infrastructure**:
    - Create Workload Identity Pool and Provider in test GCP project
    - Create Google Service Accounts with required IAM roles
    - Configure WIF bindings for service accounts
    - Document WIF setup process for production deployments

6. **Prepare Test Environment**:
    - Provision GKE management cluster with HyperShift operator
    - Enable TechPreviewNoUpgrade feature set on management cluster
    - Setup RBAC for adapter service account
    - Create VPC network and Private Service Connect subnet
    - Create test GCP project for HostedCluster provisioning
    - Document environment setup for team

**Success Criteria**:

- [ ] Epic HYPERFLEET-58 updated with spike findings
- [ ] 10 implementation stories created and estimated
- [ ] Team technical review completed and approach approved
- [ ] Adapter framework validation complete
- [ ] WIF infrastructure created and validated
- [ ] Test environment ready for development

---

## 12. References

### HyperShift Documentation

- [HyperShift GitHub Repository](https://github.com/openshift/hypershift)
- [HyperShift API Reference](https://hypershift-docs.netlify.app/reference/api/)
- [HostedCluster CRD Types](https://github.com/openshift/hypershift/blob/main/api/hypershift/v1beta1/hostedcluster_types.go)
- [GCP Platform Spec](https://github.com/openshift/hypershift/blob/main/api/hypershift/v1beta1/gcp.go)

### HyperFleet Documentation

- [Adapter Framework Design](../../../../components/adapter/framework/adapter-frame-design.md)
- [Adapter Status Contract](../../../../components/adapter/framework/adapter-status-contract.md)
- [GCP Validation Adapter Spike](../deprecated-validation/gcp-validation-adapter-spike-report.md)

### Kubernetes Documentation

- [Custom Resources](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/)
- [RBAC Authorization](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)

---

## Sources

- [HyperShift GitHub Repository](https://github.com/openshift/hypershift)
- [HyperShift API Documentation](https://hypershift-docs.netlify.app/reference/api/)
- [HostedCluster Types (Go Package)](https://pkg.go.dev/github.com/openshift/hypershift/api/v1beta1)
- [GCP Platform Spec Source](https://github.com/openshift/hypershift/blob/main/api/hypershift/v1beta1/gcp.go)
