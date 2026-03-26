---
Status: Deprecated
Owner: HyperFleet Adapter Team
Last Updated: 2026-01-27
---

# SPIKE REPORT: Define Validation Adapter Criteria and Implementation Plan for GCP

**JIRA Story**: HYPERFLEET-59   

## 1. Overview

> Spike report from the GCP cluster validation adapter investigation, documenting the validation logic explored for GCP-specific cluster prerequisites. Deprecated — the GCP-specific validation approach was superseded by the current validation adapter within the adapter framework.

This spike defines a **phased implementation approach** for a GCP validation adapter that runs as a Kubernetes Job to validate GCP prerequisites before cluster provisioning. The solution is based on proven patterns from the existing uhc-clusters-service (CS) [GCP preflight logic](https://gitlab.cee.redhat.com/service/uhc-clusters-service/-/blob/master/cmd/clusters-service/service/gcp_preflight/preflight_service.go), adapted for the adapter framework context.

### Key Decisions
- **Deployment**: Validation adapter runs as a Kubernetes Job in a GKE cluster
- **Implementation Vehicle**: Two-container sidecar pattern (validator + status reporter)
- **Architecture**: GCP validator container + reusable status reporter sidecar
- **Authentication**: Workload Identity Federation (WIF)
- **Validation Flow**:
  1. Verify WIF is configured (annotation exists on K8s SA)
  2. Use WIF to check APIs enabled in customer's project
  3. (Post-MVP) Use WIF to check quota available in customer's project
  4. (Post-MVP) Use WIF for network, IAM, region validation
- **Status Reporting**: Sidecar container reads results from shared volume (e.g., EmptyDir), updates Job status

### Primary Risk
Ensuring proper IAM permission configuration for Workload Identity integration within the Job context, especially for GCP cross-project validation scenarios.

---

## 2. Exploration Summary: K8s Job vs Tekton Pipeline

Two implementation approaches were evaluated. The decision can be updated based on the comparison and analysis below.

### Kubernetes Job

**Pros**
- A native Kubernetes resource with minimal external dependencies.

**Cons**
- Requires a sidecar container to collect validation details and update the Job status.
- Limited support for multi-step validation: dependencies, parallelism, and orchestration must be implemented within the Job logic by yourself.

More details refer to [update-job-status](https://gitlab.cee.redhat.com/amarin/update-job-status/).

### Tekton Pipeline

**Pros**
- Designed for multi-stage workflows with built-in support for task dependencies, parallel execution, and easy extension by adding new validation tasks.
- Can write validation results directly into the PipelineRun CR, with flexible mechanisms to aggregate results from multiple tasks.

**Cons**
- Requires installing and maintaining the Tekton operator, requires more resources to run Tekton.
- Each validation task runs in its own Pod; workflows with many tasks will create multiple Pods during execution.

More details refer to [validation-pipeline-demo](https://github.com/86254860/validation-pipeline-demo).

**Decision**: K8s Job selected for initial implementation due to lower operational overhead and alignment with validation use case requirements. This decision remains open for review, and GCP preference will play a key role in guiding our final choice.

## 3. GCP Validation Requirements (Based on CS GCP Preflight Logic)

The validation requirements are derived from the production GCP preflight implementation in [uhc-clusters-service](https://gitlab.cee.redhat.com/service/uhc-clusters-service/-/blob/master/cmd/clusters-service/service/gcp_preflight/preflight_service.go). This ensures alignment with proven validation patterns.

### 3.1 Overview of CS Supported Preflights (WIF Mode)

The validation adapter focuses on the Workload Identity Federation (WIF) flow. The following preflight checks are performed in this mode:

**Authentication:**
- `createGcpClient`: Before executing specific checks, the service attempts to create a GCP client using the provided configuration. This serves as an initial connectivity and authentication check to ensure a valid GCP client can be instantiated.

**Identity & Access:**
- `ValidateWifResources`: Validates WIF configuration resources.
- `APIsEnabled`: Verifies that required GCP APIs are enabled.

**Project & Constraints:**
- `ValidProjectID`: Validates the project ID.
- `ValidProjectConstraints`: Checks for conflicting organizational policies.

**Network Configuration:**
- `ValidNetwork`: General VPC network validation.
- `validatePscSubnet`: Checks Private Service Connect subnets.
- `validateMachineCidr`: Ensures Machine CIDR is valid.
- `validateVpcSubnets`: Verifies existence and configuration of VPC subnets.

**Resource Availability & Quotas:**
- `ValidateAvailabilityZones`: Checks validity and status of requested zones.
- `InstanceTypeSupported`: Verifies machine types are available in the target zones.
- `ServiceUsageQuota`: Checks for sufficient resource quotas (e.g., vCPUs).

**Security:**
- `ValidKeyRings`: Validates KMS Key Ring configuration if encryption is enabled.

### 3.2 Credential Validation (MVP)

**Purpose**: Verify that Workload Identity Federation (WIF) is configured for the validation Job.

**Validation Flow**:
```
Kubernetes Job Pod
├── Step 1: Check if WIF is configured
│
├── Step 2: If WIF exists → Continue to API validation
│   └── API validator will use WIF to check APIs in customer's project
│
└── Step 3+: (Post-MVP) More validators use WIF
    ├── Quota validator
    ├── Network validator
    └── IAM validator
```

**Note**: At initial phase, credential validation only checks if WIF annotation exists. Actual authentication and authorization testing happens when API validator (or other validators) attempt to use WIF.

### 3.3 Required GCP APIs (MVP)

**Implementation Reference**: [CS Required GCP APIs](https://gitlab.cee.redhat.com/service/uhc-clusters-service/-/blob/master/cmd/clusters-service/service/gcp_preflight/preflight_service.go#L44-L63)

The following APIs **must be enabled** before cluster provisioning:

| API Service | Purpose |
|------------|---------|
| `compute.googleapis.com` | Compute Engine (VMs, networks, disks) |
| `iam.googleapis.com` | Identity and Access Management |
| `cloudresourcemanager.googleapis.com` | Project metadata access |
| `serviceusage.googleapis.com` | Quota limit queries |
| `monitoring.googleapis.com` | Quota usage metrics |
| `dns.googleapis.com` | Cloud DNS management |
| `container.googleapis.com` | GKE features |

### 3.4 GCP Quota Validation (Post-MVP)
**Implementation Reference**: [CS quota preflight logic](https://gitlab.cee.redhat.com/service/uhc-clusters-service/-/blob/master/cmd/clusters-service/service/gcp_preflight/preflight_service.go#L190-L191)  

**Regional vCPU Quota Validation Flow**:
```
1. Get project number from project ID
2. Query current vCPU usage (Monitoring API MQL query)
3. Get regional quota limit (Service Usage API - use EffectiveLimit)
4. Calculate: Available = Limit - Usage
5. Validate: Required vCPUs ≤ Available Quota
```

**Required SDK Methods**:
```go
// Step 1: Get project number
import resourcemanager "google.golang.org/api/cloudresourcemanager/v1"
project, _ := crmService.Projects.Get(projectID).Context(ctx).Do()
projectNumber := project.ProjectNumber

// Step 2: Query current vCPU usage
import monitoring "google.golang.org/api/monitoring/v3"
const vCPUUsageQuery = `fetch consumer_quota
| metric 'serviceruntime.googleapis.com/quota/allocation/usage'
| filter  (resource.service == 'compute.googleapis.com')
    && (metric.quota_metric == 'compute.googleapis.com/cpus')
| group_by 1d, [value_usage : max(value.usage)]`

response, _ := monitoringService.Projects.TimeSeries.Query(projectPath, queryRequest).Do()
currentUsage := response.TimeSeriesData[0].PointData[0].Values[0].Int64Value

// Step 3: Get regional quota limit
import serviceusage "google.golang.org/api/serviceusage/v1beta1"
const cpuQuotaMetric = "/services/compute.googleapis.com/consumerQuotaMetrics/compute.googleapis.com%2Fcpus"
metrics, _ := serviceUsageService.Services.ConsumerQuotaMetrics.Get(metricPath).Do()
// Find regional bucket and extract EffectiveLimit
```

**Required IAM Permissions**:
- `monitoring.timeSeries.list` - Query vCPU usage
- `serviceusage.services.get` - Retrieve service info
- `serviceusage.quotas.get` - Get quota limits
- `resourcemanager.projects.get` - Get project metadata

**Quota Calculation Example**:
```
Required vCPUs = Σ (node_count × vCPUs_per_machine_type)
Example:
  - default-pool: 3 nodes × 4 vCPUs (n1-standard-4) = 12 vCPUs
  - compute-pool: 2 nodes × 8 vCPUs (n2-standard-8) = 16 vCPUs
  Total Required: 28 vCPUs

If Regional Limit = 100, Current Usage = 80:
  Available = 100 - 80 = 20 vCPUs
  Validation FAILS (28 > 20)
```

**Extended Quota Validation**:
- Service Account quota (`iam.googleapis.com/quota/service_account_count`)
- Regional external IP addresses
- Persistent disk quota (pd-standard, pd-ssd)
- GPU quotas (if applicable)

### 3.5 Network Configuration Validation (Post-MVP)

**Implementation Reference**: [CS network preflight](https://gitlab.cee.redhat.com/service/uhc-clusters-service/-/blob/master/cmd/clusters-service/service/gcp_preflight/preflight_service.go#L188-196)  

#### VPC and Subnet Existence

**Skip Condition**: Empty VPC name (default VPC scenario)

**Validation Logic**:
```go
// 1. Resolve VPC Project ID (support shared VPC)
vpcProjectId := gcp.ProjectID
if gcp.VpcNetworkProjectId != "" {
    vpcProjectId = gcp.VpcNetworkProjectId
}

// 2. Validate VPC Project exists
import cloudresourcemanager "google.golang.org/api/cloudresourcemanager/v1"
projects, _ := crmService.Projects.List().Context(ctx).Do()
// Verify vpcProjectId in projects list

// 3. Validate VPC Network exists
import compute "google.golang.org/api/compute/v1"
network, err := computeService.Networks.Get(vpcProjectId, vpcName).Context(ctx).Do()
if err != nil {
    return fmt.Errorf("VPC network %s not found in project %s", vpcName, vpcProjectId)
}

// 4. List subnets in target region
filter := fmt.Sprintf("network eq .*%s", vpcName)
req := computeService.Subnetworks.List(vpcProjectId, region).Filter(filter)
var subnets []*compute.Subnetwork
req.Pages(ctx, func(page *compute.SubnetworkList) error {
    subnets = append(subnets, page.Items...)
    return nil
})

// 5. Verify required subnets exist
// Check control plane subnet
// Check compute subnet
```

**Required IAM Permissions**:
- `compute.networks.get` - Retrieve VPC details
- `compute.subnetworks.list` - List subnets
- `compute.subnetworks.get` - Get subnet details
- `resourcemanager.projects.list` - List projects (for shared VPC)

#### CIDR Containment Validation (Post-MVP)

**Skip Condition**: Non-BYO VPC deployments

**Validation Logic**:
```go
// Validate Machine CIDR contains subnet CIDRs
import "net"
_, machineCIDRNet, _ := net.ParseCIDR(machineCIDR)

for _, subnetCIDR := range subnetCidrs {
    subnetIP, subnetNet, _ := net.ParseCIDR(subnetCIDR)
    
    // Check if subnet's first IP is within Machine CIDR
    if !machineCIDRNet.Contains(subnetIP) {
        return fmt.Errorf("subnet CIDR %s not contained in machine CIDR %s", 
            subnetCIDR, machineCIDR)
    }
    
    // Additional: Check subnet size is sufficient
    subnetSize := calculateCIDRSize(subnetNet)
    if subnetSize < minimumSubnetSize {
        return fmt.Errorf("subnet %s too small: %d IPs (minimum: %d)", 
            subnetCIDR, subnetSize, minimumSubnetSize)
    }
}
```

### 3.6 Region and Zone Availability (Post-MVP)

#### Region Existence
```go
import compute "google.golang.org/api/compute/v1"

// List all available regions
regions, err := computeService.Regions.Get(projectID, requestedRegion).Context(ctx).Do()
if err != nil {
    return fmt.Errorf("region %s not available", requestedRegion)
}

// Check region status
if regions.Status != "UP" {
    return fmt.Errorf("region %s status is %s", requestedRegion, regions.Status)
}
```

#### Machine Type Availability (Post-MVP)
```go
// Validate machine types exist in target zones
for _, zone := range requestedZones {
    for _, machineType := range requestedMachineTypes {
        mt, err := computeService.MachineTypes.Get(projectID, zone, machineType).Context(ctx).Do()
        if err != nil {
            return fmt.Errorf("machine type %s not available in zone %s", machineType, zone)
        }
    }
}
```

---

## 4. Validation Adapter Related Configurations

### 4.1 Kubernetes Job Manifest Template

The validation runs as a Kubernetes Job on the GKE cluster using a two-container pattern. To minimize management overhead and avoid dynamic Workload Identity Federation (WIF) configuration changes per cluster, we use a **Shared Platform Identity** model (TBD).

- **Validator Container**: Runs GCP validation checks using baked-in rules and environment variables, writes results to shared volume.
- **Reporter Sidecar**: Reads results from shared volume, updates Job status.

**Pre-requisite**: A shared Kubernetes Service Account `gcp-validator-sa` must exist in the namespace, configured with WIF (see Section 4.3).

Here's the example YAML of the GCP validation job:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: gcp-validate-{{.cluster_id}}-{{.generation}}
  namespace: {{.namespace}}
  labels:
    app: gcp-validator
    cluster-id: "{{.cluster_id}}"
  annotations:
    generation: "{{.generation}}"
    created-by: "adapter-framework"
spec:
  template:
    metadata:
      labels:
        app: gcp-validator
        cluster-id: "{{.cluster_id}}"
    spec:
      # Use the shared pre-configured Service Account
      # It has both WIF configuration (for Validator) and RBAC permissions (for Reporter)
      serviceAccountName: gcp-validator-sa
      
      containers:
      # Container 1: GCP Validator
      # Performs validation checks and writes results to shared volume
      - name: validator
        image: "{{.registry}}/gcp-validator:{{.version}}"
        
        env:
        # Cluster identification
        - name: CLUSTER_ID
          value: "{{.cluster_id}}"
        - name: CLUSTER_NAME
          value: "{{.cluster_name}}"
        
        # Cluster-Specific Configuration (Extracted and passed as Env Vars)
        # Refer to https://github.com/openshift-hyperfleet/hyperfleet-api-spec/tree/main
        - name: GCP_PROJECT_ID
          value: "{{.gcp_project_id}}"
        - name: GCP_REGION
          value: "{{.gcp_region}}"
        # TBD after further discussion about WIF
        # - name: GCP_DEPLOYER_SA_EMAIL
        #   value: "{{.gcp_deployer_sa_email}}"
          
        # Validation Logic Configuration
        # Comma-separated list of checks to perform.
        # Common rules (APIs, quotas, etc.) are integrated into the image.
        - name: VALIDATION_CHECKS
          value: "api_enablement,vpc_subnet_existence,service_account_existence,region_availability"
        
        # Results output path (shared with reporter sidecar)
        - name: RESULTS_OUTPUT_PATH
          value: "/results/validation-report.json"
        
        volumeMounts:
        - name: results
          mountPath: /results
          readOnly: false  # Validator writes results here
        
        resources:
          requests:
            memory: "256Mi"
            cpu: "200m"
          limits:
            memory: "512Mi"
            cpu: "500m"
      
      # Container 2: Status Reporter Sidecar (Reusable across all validators)
      # Waits for validation results, updates Job status, creates events
      - name: status-reporter
        image: "{{.registry}}/validation-status-reporter:{{.reporter_version}}"
        
        env:
        # K8s resource to update
        - name: JOB_NAME
          value: "gcp-validate-{{.cluster_id}}"
        - name: JOB_NAMESPACE
          value: "{{.namespace}}"
        
        # Results input path (shared with validator)
        - name: RESULTS_INPUT_PATH
          value: "/results/validation-report.json"
        
        # Reporter behavior
        - name: POLL_INTERVAL
          value: "2"    # Check for results every 2 seconds
        
        volumeMounts:
        - name: results
          mountPath: /results
          readOnly: true  # Reporter only reads results
        
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "100m"
      
      volumes:
      - name: results
        emptyDir: {}  # Shared volume for result communication
      
      restartPolicy: Never
  
  # Job control
  backoffLimit: 0  # Disable retries. The Job is marked Failed as soon as the Pod fails once.
  activeDeadlineSeconds: 300  # 5 minute timeout

```

### 4.2 Configuration Strategy

We use Environment Variables to simplify management.

**Cluster-Specific Configuration**:
The adapter framework extracts relevant fields from the cluster definition and passes them directly to the container:
- `GCP_PROJECT_ID`: Target project for validation.
- `GCP_REGION`: Target region for resource checks.

**Shared Validation Rules**:
- **Integrated Configuration**: Static validation rules (e.g., list of required APIs, quota limits, IAM roles, error messages) are built directly into the validator image. This ensures consistency and simplifies updates (via image tags).
- **Runtime Control**: The `VALIDATION_CHECKS` environment variable controls which validators are active. This allows flexible execution without changing the image or mounting files.

### 4.3 Service Account and Permissions Configuration

The `gcp-validator-sa` Service Account acts as the central identity, requiring two distinct sets of permissions:

1.  **Kubernetes Permissions (RBAC)**: Allows the `status-reporter` sidecar to update the Job status.
2.  **GCP Permissions (Workload Identity)**: Allows the `validator` container to impersonate the customer's Deployer Service Account.

#### 4.3.1 Kubernetes RBAC (Status Reporter)

This RBAC configuration grants the `gcp-validator-sa` permission to update the status of Jobs in its namespace.

```yaml
# 1. Service Account (Static)
apiVersion: v1
kind: ServiceAccount
metadata:
  name: gcp-validator-sa
  namespace: {{.namespace}}
  annotations:
    # Static link to the Platform's GCP Validator Identity
    # TBD after further discussion about WIF configuration
    iam.gke.io/gcp-service-account: "TBD"

---
# 2. RBAC Role: Allow updating Job status
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: job-status-updater
  namespace: {{.namespace}}
rules:
  - apiGroups: ["batch"]
    resources: ["jobs/status"]
    verbs: ["patch", "update", "get"]

---
# 3. RBAC RoleBinding: Bind SA to Role
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: job-status-updater-binding
  namespace: {{.namespace}}
subjects:
  - kind: ServiceAccount
    name: gcp-validator-sa
    namespace: {{.namespace}}
roleRef:
  kind: Role
  name: job-status-updater
  apiGroup: rbac.authorization.k8s.io
```

#### 4.3.2 GCP IAM Configuration (Validator)

> **Note**: The detailed WIF configuration strategy is **TBD after further discussion**.

This section will define how the platform service account is authorized to access customer projects (e.g., via impersonation or direct access).


### 4.4 GCP Validation Adapter Configuration

After the Kubernetes Job for GCP validation completes, configure the GCP Validation Adapter according to the [latest adapter configuration specification](https://github.com/openshift-hyperfleet/architecture/tree/main/hyperfleet/components/adapter/framework). This ensures the configuration is properly recognized and processed by the adapter framework.

---

## 5. Status Reporter Sidecar (Reusable Component)

### 5.1 Overview

The **Status Reporter Sidecar** is a **cloud-agnostic**, reusable container that handles Job status updates for any validation container. This separation provides:

1. **Reusability**: Same sidecar for GCP, AWS, Azure, or any custom validator
2. **Separation of Concerns**: Validators focus on validation logic, reporter handles K8s integration (requires RBAC)
3. **Standardization**: Consistent status reporting format across all validators
4. **Simplicity**: Validators don't need K8s client libraries

### 5.2 Communication Pattern

**Shared Volume (emptyDir)**:
- Validator writes `validation-report.json` to `/results/`
- Reporter polls for file existence
- Reporter reads JSON, updates Job, exits

```
┌─────────────────────┐         ┌──────────────────────┐
│  Validator Container│         │ Reporter Sidecar     │
│                     │         │                      │
│  1. Run validation  │         │  1. Poll for file    │
│  2. Generate report │         │     (every 2s)       │
│  3. Write JSON ─────┼────────>│  2. File detected    │
│     to /results/    │ Shared  │  3. Read JSON        │
│  4. Exit (0 or 1)   │ Volume  │  4. Update Job       │
│                     │         │  5. Exit             │
└─────────────────────┘         └──────────────────────┘
```

### 5.3 Example to Update Job Status
Here's an k8s yaml example to define a status-updater container using kubectl to update the job status.
```
- name: status-updater
        image: bitnami/kubectl:latest
        command:
        - /bin/bash
        - -c
        - |
          set -e

          # Wait for the worker container to finish and create results.json
          echo "Waiting for results.json..."
          while [ ! -f /data/results.json ]; do
            sleep 1
          done

          # Give a moment for the file to be fully written
          sleep 2

          echo "Found results.json, reading contents..."
          cat /data/results.json

          # Get the Job name and namespace from the pod
          JOB_NAME="${JOB_NAME:-result-processor}"
          NAMESPACE="${NAMESPACE:-default}"

          # Read the JSON file and extract values
          AVAILABLE=$(get the validation result from /data/results.json)
          REASON=$(get the failed validation reason from /data/results.json)
          MESSAGE=$(get the validation message from /data/results.json)

          echo "Parsed values - available: $AVAILABLE, message: $MESSAGE

          # Create status patch with conditions
          TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

          # Build conditions array
          CONDITIONS='[
            {
              "type": "Available",
              "status": "'$AVAILABLE'",
              "lastTransitionTime": "'$TIMESTAMP'",
              "reason": "$REASON",
              "message": "$MESSAGE"
            }
          ]'

          echo "Updating Job status with conditions... ${CONDITIONS}"

          # Patch the Job status
          kubectl patch job "$JOB_NAME" -n "$NAMESPACE" \
            --subresource=status \
            --type=merge \
            -p '{"status":{"conditions":'"$CONDITIONS"'}}'

          echo "Status update completed!"
```

**Note:** RBAC permissions configuration (as defined in Section 4.3) is required to update the job status. More details refer to [this](https://gitlab.cee.redhat.com/amarin/update-job-status/-/blob/main/job.yaml).

---

## 6. Alternative Approach: CRD-Based Status Reporting

### 6.1 Overview

An alternative to updating Job status directly is to use a **Custom Resource Definition (CRD)** for adapter operation status reporting. In this approach, adapter operation results are stored in a dedicated custom resource (`AdapterResult`) rather than in the Job status field.

### 6.2 Trade-offs Analysis

| Aspect | **Job Status** | **AdapterResult CRD (Alternative)** |
|--------|--------------------------|---------------------------------------|
| **Implementation Complexity** | ✅ **Simple** - Uses native K8s resources only | ⚠️ **Complex** - Requires CRD definition, installation, RBAC updates |
| **Setup Overhead** | ✅ **Low** - No additional CRD installation | ❌ **Higher** - CRD must be installed on every cluster |
| **Data Structure** | ⚠️ **Limited** - Job conditions support basic fields (type, status, reason, message) | ✅ **Rich** - Custom schema allows detailed validation metadata, nested structures |
| **Decoupling** | ⚠️ **Tight Coupling** - Results tied to Job lifecycle | ✅ **Decoupled** - Operation results independent of execution method (Job, Pod, other) |
| **Extensibility** | ❌ **Limited** - Hard to add new fields to Job status without breaking compatibility | ✅ **Versioned** - CRD versioning (v1alpha1 → v1beta1 → v1) allows schema evolution |
| **Reporter Changes** | Updates Job status with RBAC for `jobs/status` | Updates CR status with RBAC for `adapterresults/status` |
| **MVP Readiness** | ✅ **Ready** - Minimal changes, proven pattern | ❌ **Delayed** - More upfront design and implementation work |
| **Flexibility** | ❌ **Job-only** - Only works if adapter runs as a Job | ✅ **Resource-agnostic** - Works with Job, CronJob, DaemonSet, or custom controllers |

### 6.3 Decision for MVP vs Post-MVP

**MVP Decision**: **Use Job Status Approach** ✅

**Rationale**:
1. **Simplicity**: MVP goal is to prove the adapter framework architecture works end-to-end. Job status is sufficient for basic pass/fail reporting.
2. **Lower Risk**: No additional dependencies or CRD management complexity.
3. **Faster Implementation**: Team can focus on validation logic rather than infrastructure.
4. **Job Conditions Are Sufficient**: For MVP scope (2 validators: WIF check + API enablement), Job conditions provide adequate status reporting.

**Post-MVP Consideration**: **Evaluate CRD Approach** 🚀

The `AdapterResult` CRD approach should be reconsidered when:
- ✅ **Need Richer Data**: Operation reports require detailed metadata beyond Job conditions (per-validator metrics, DNS records, remediation hints, structured errors)
- ✅ **Multiple Adapter Types**: As more adapters are implemented (DNS, pull secret, etc.), a unified status interface becomes valuable
- ✅ **Multiple Execution Methods**: Adapters may run as Job, Tekton Pipeline, DaemonSet, or other resources
- ✅ **UX Improvements**: Users frequently query adapter results and need better query experience across adapter types

**Benefits of Generic CRD Design**:
- **Single CRD for all adapters**: Validation, DNS, pull secret, and future adapters use the same `AdapterResult` CRD
- **Consistent interface**: Same query patterns work for all adapter types (`kubectl get adapterresults -l adapter-type=<type>`)
- **Easier framework evolution**: Adding new adapter types doesn't require new CRDs

---

### 7.1 MVP - Proof of Concept

**Goal**: Prove the adapter framework architecture works end-to-end with GCP validation adapter - minimal validation logic (credentials + 3-4 API checks).

**Scope**: Absolute minimum to validate the solution architecture:
- Status reporter sidecar (basic version)
- GCP validation logic with TWO validators only:
    - **Credential validation** - Verify GCP credentials exist and are valid
    - **API enablement check** - Check if required APIs are enabled
- Basic integration testing

#### Tasks
- Implement status reporter logic
- Implement GCP validation logic
- Write unit tests for smoke tests
- Dockerfile and Makefile for image build and testing
- RBAC and k8s related YAML files for GCP validation job
- The GCP validation adapter configuration
- Integration with Adapter framework (Configuration, Deployment, Testing)
- Write README with setup instructions, deployment instructions

**Success Criteria**:
- The status reporter sidecar runs successfully
- The GCP validation logic runs successfully
- The k8s job (including GCP validation and status reporter containers) runs successfully
    - Results written to shared volume (EmptyDir)
    - Reporter sidecar updates Job status
    - Job status reflects validation result (pass/fail)
- GCP validation adapter (configuration, logic, etc.) works well with the Adapter framework

---

### 7.2 Post-MVP Enhancements

After MVP is approved and working, implement additional features iteratively.

**Goal**: Make the solution production-ready and add comprehensive validation coverage.

**Production Readiness**:
- ✅ Add Workload Identity authentication support
- ✅ Proper error handling and structured logging
- ✅ Retry logic with exponential backoff
- ✅ ConfigMap-based configuration (replace hardcoded values)
- ✅ Unit tests for both containers (≥80% coverage)
- ✅ Integration tests with test GCP project
- ✅ RBAC resources and security hardening
- ✅ Complete documentation (setup, troubleshooting, runbooks)
- ✅ Complete API enablement checks (all required APIs)

**Additional Validators** (All Post-MVP):
- ✅ VPC/Subnet existence validator
- ✅ Service Account existence validator
- ✅ Region availability validator
- ✅ vCPU quota validation (Monitoring API + Service Usage API)
- ✅ CIDR containment validation
- ✅ IAM role binding validation
- ✅ Machine type availability validation
- ✅ Disk quota validation (pd-standard, pd-ssd)
- ✅ IP address quota validation
- ✅ Service account quota validation
- ✅ IAM permissions testing (TestIamPermissions API)
- ✅ Shared VPC advanced validation
- ✅ Secondary IP ranges validation (GKE)

**Enhanced Features**:
- Enhanced error messages with remediation guidance (gcloud commands)
- Parallel validator execution for performance
- Prometheus metrics export, including validation_job_failures_total, validation_requests_total, validation_duration, etc.
- E2E test suite
- Performance optimization
- Security scanning

**Alternative Status Reporting**:
- ✅ Evaluate CRD-based status reporting (see Section 6) if richer validation data or execution flexibility is needed

---

## 8. Acceptance Criteria for Implementation Tickets

Based on this spike, implementation tickets should have the following acceptance criteria:

### MVP Acceptance Criteria

**Ticket: GCP Validation MVP - Architecture Proof of Concept**

**Goal**: Prove the adapter framework architecture works end-to-end with GCP validation adapter - minimal validation logic (credentials + 3-4 API checks).

**Status Reporter Sidecar** (Basic):
- [ ] Polls for `/results/validation-report.json` on shared emptyDir volume
- [ ] Reads and parses JSON validation report
- [ ] Updates Job status with validation status
- [ ] Basic timeout handling (5 minute max wait), if validation report file doesn't exist until timeout, Job status is updated to `Failed` with timeout message
- [ ] Dockerfile builds successfully
- [ ] Container image runs in K8s

**GCP Validator** (Minimal validation logic):  
- [ ] **Workload Identity Federation** (WIF) for GCP authentication
  - How to setup WIF to access customer's GCP project 
  - How to pass WIF to validator container
- [ ] Implements **Validator 1: WIF Configuration Check**
  - Checks if K8s Service Account has `iam.gke.io/gcp-service-account` annotation
  - Returns Success if annotation exists, Failure if missing
  - Does NOT test if WIF actually works (deferred to API validator)
- [ ] Implements **Validator 2: API Enablement Check** (first to use WIF)
  - Attempts to use WIF to authenticate with GCP
  - Checks if 3-4 critical APIs are enabled in customer's project:
    - `compute.googleapis.com`
    - `iam.googleapis.com`
    - `cloudresourcemanager.googleapis.com`
  - Returns Success if can authenticate AND APIs are enabled
  - Returns Failure if WIF doesn't work OR APIs are disabled
    

- [ ] Writes results to `/results/validation-report.json` (valid JSON schema)
- [ ] Exits with code 0 (success) or 1 (failure)
- [ ] Dockerfile builds successfully
- [ ] Container image runs in K8s

**Integration**:
- [ ] Job manifest with two containers (validator + reporter)
- [ ] Shared emptyDir volume mounted at `/results/` in both containers
- [ ] Minimal ConfigMap with project ID and API list
- [ ] Job deploys and runs in K8s cluster
- [ ] Job status show validation result after completion
- [ ] GCP validation YAML file for adapter framework

**Deliverables**:
- [ ] Two working containers (reporter + validator)
- [ ] Job manifest YAML
- [ ] GCP validation YAML file for adapter framework
- [ ] Basic README
- [ ] Demo showing end-to-end flow with both validators

---

## References

### GCP Documentation
- [GCP Go SDK](https://pkg.go.dev/google.golang.org/api)
- [Compute Engine API](https://cloud.google.com/compute/docs/reference/rest/v1)
- [Service Usage API](https://cloud.google.com/service-usage/docs/reference/rest)
- [Workload Identity](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity)
- [IAM Permissions Reference](https://cloud.google.com/iam/docs/permissions-reference)

### Internal References
- [uhc-clusters-service GCP Preflight](https://gitlab.cee.redhat.com/service/uhc-clusters-service/-/blob/master/cmd/clusters-service/service/gcp_preflight/preflight_service.go)
- [Adapter Framework Documentation](https://github.com/openshift-hyperfleet/architecture/tree/main/hyperfleet/components/adapter/framework)

### Kubernetes Documentation
- [Kubernetes Jobs](https://kubernetes.io/docs/concepts/workloads/controllers/job/)
- [Job Status and Conditions](https://kubernetes.io/docs/concepts/workloads/controllers/job/#job-status)

---
