---
Status: Active
Owner: HyperFleet Adapter Team
Last Updated: 2026-03-25
---

# HyperFleet Adapter Framework - Integration Tests

## Overview

This document defines integration test scenarios and acceptance criteria for the HyperFleet Adapter Framework.

**Related Documentation:**
- [Adapter Framework Design](./adapter-frame-design.md) - Architecture overview
- [Adapter Status Contract](./adapter-status-contract.md) - Status reporting contract
- [Test Release MVP](../../../test-release/test-release-MVP.md) - Testing strategy

---

## Table of Contents

1. [Overview](#overview)
2. [Test Environment Setup](#test-environment-setup)
3. [Test Data Fixtures](#test-data-fixtures)
4. [Test Cases](#test-cases)
5. [Expected Outcomes](#expected-outcomes)

---

## Overview

### Testing Strategy

Integration tests validate the adapter framework's interactions with:
- **Message Broker**: Event consumption and acknowledgment
- **HyperFleet API**: Cluster fetching and status reporting
- **Kubernetes API**: Resource creation, discovery, and tracking
- **Expression Evaluator**: Condition and data evaluation

### Test Framework

- **Language**: Go
- **Testing Framework**: Standard Go `testing` package
- **Container Testing**: `testcontainers` for broker and API simulation
- **Kubernetes Testing**: `controller-runtime/envtest` for Kubernetes API
- **Location**: `test/integration/` directory

### Test Scope

- ✅ Event processing workflow
- ✅ Precondition evaluation
- ✅ Resource creation and tracking
- ✅ Post-processing and status reporting
- ✅ Error handling and retry logic
- ✅ Idempotency and concurrent processing
- ✅ Graceful shutdown

---

## Test Environment Setup

### Components

#### 1. Stub Message Broker

**RabbitMQ Test Container**:
```go
rabbitmqContainer, err := rabbitmq.RunContainer(ctx,
    testcontainers.WithImage("rabbitmq:3.11-management"),
    rabbitmq.WithAdminUsername("admin"),
    rabbitmq.WithAdminPassword("password"),
)
```

**Pub/Sub Emulator** (for GCP testing):
```go
pubsubContainer, err := testcontainers.GenericContainer(ctx, testcontainers.GenericContainerRequest{
    ContainerRequest: testcontainers.ContainerRequest{
        Image:        "gcr.io/google.com/cloudsdktool/cloud-sdk:emulators",
        ExposedPorts: []string{"8085/tcp"},
        Cmd:          []string{"gcloud", "beta", "emulators", "pubsub", "start", "--host-port=0.0.0.0:8085"},
        WaitingFor:   wait.ForLog("Server started"),
    },
    Started: true,
})
```

**Setup Steps**:
1. Start broker container
2. Create test queue/subscription
3. Configure adapter to connect to test broker
4. Cleanup after tests

#### 2. Mock HyperFleet API

**HTTP Test Server**:
```go
apiServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
    // Handle GET /clusters/{id}
    // Handle GET /clusters/{id}/statuses
    // Handle POST /clusters/{id}/statuses
    // Handle PATCH /clusters/{id}/statuses/{statusId}
}))
defer apiServer.Close()
```

**API Endpoints to Mock**:
- `GET /api/hyperfleet/v1/clusters/{clusterId}` - Return cluster object
- `GET /api/hyperfleet/v1/clusters/{clusterId}/statuses` - Return existing status or 404
- `POST /api/hyperfleet/v1/clusters/{clusterId}/statuses` - Create/upsert status
- `PATCH /api/hyperfleet/v1/clusters/{clusterId}/statuses/{statusId}` - Update status

**Request/Response Tracking**:
- Track all API calls made by adapter
- Verify request payloads match expected structure
- Return configurable responses for different test scenarios

#### 3. Kubernetes Test Environment

**envtest Setup**:
```go
import (
    "sigs.k8s.io/controller-runtime/pkg/envtest"
)

testEnv := &envtest.Environment{
    CRDDirectoryPaths: []string{"../../config/crd/bases"},
}

cfg, err := testEnv.Start()
defer testEnv.Stop()

k8sClient, err := client.New(cfg, client.Options{})
```

**Setup Steps**:
1. Start Kubernetes API server (envtest)
2. Install CRDs if needed
3. Create test namespace
4. Cleanup resources after tests

#### 4. Adapter Framework Instance

**Test Adapter Configuration**:
```yaml
apiVersion: hyperfleet.redhat.com/v1alpha1
kind: AdapterConfig
metadata:
  name: test-adapter
spec:
  adapter:
    version: "1.0.0"
  ruleEngine:
    type: "expr"
    compileOnStartup: true
    strictTypes: true
  hyperfleetApi:
    timeout: 2s
  messageBroker:
    maxConcurrency: 10
  kubernetes:
    inCluster: false  # Use kubeconfig for testing
    namespace: "test-namespace"
  # ... test-specific configuration
```

**Setup Steps**:
1. Load test adapter configuration
2. Initialize framework components
3. Connect to test broker, API, and Kubernetes
4. Start adapter service
5. Cleanup on test completion

### Test Helper Functions

```go
// SetupTestEnvironment creates all test dependencies
func SetupTestEnvironment(t *testing.T) (*TestEnvironment, func()) {
    // Setup broker, API, Kubernetes, adapter
    // Return cleanup function
}

// PublishTestEvent publishes a CloudEvent to the test broker
func PublishTestEvent(broker Broker, event CloudEvent) error {
    // Publish event to broker
}

// WaitForStatus waits for adapter to report status
func WaitForStatus(api MockAPI, clusterId string, timeout time.Duration) (*Status, error) {
    // Poll API for status updates
}

// AssertStatusMatches verifies status matches expected values
func AssertStatusMatches(t *testing.T, actual *Status, expected *Status) {
    // Compare conditions, data, etc.
}
```

---

## Test Data Fixtures

### CloudEvent Fixtures

**Basic Event** (`testdata/events/basic-event.json`):
```json
{
  "specversion": "1.0",
  "type": "cluster.reconcile",
  "source": "sentinel",
  "id": "event-123",
  "time": "2025-01-15T10:00:00Z",
  "data": {
    "resourceType": "clusters",
    "resourceId": "cls-test-001",
    "clusterId": "cls-test-001",
    "href": "/api/hyperfleet/v1/clusters/cls-test-001"
  }
}
```

**Update Event** (`testdata/events/update-event.json`):
```json
{
  "specversion": "1.0",
  "type": "cluster.update",
  "source": "sentinel",
  "id": "event-124",
  "time": "2025-01-15T10:05:00Z",
  "data": {
    "resourceType": "clusters",
    "resourceId": "cls-test-001",
    "clusterId": "cls-test-001",
    "href": "/api/hyperfleet/v1/clusters/cls-test-001",
    "generation": 2
  }
}
```

### Cluster Object Fixtures

**Basic Cluster** (`testdata/clusters/basic-cluster.json`):
```json
{
  "id": "cls-test-001",
  "name": "test-cluster",
  "generation": 1,
  "spec": {
    "provider": "gcp",
    "region": "us-east1",
    "vpcId": "vpc-123",
    "nodePools": [
      {
        "name": "worker",
        "minNodes": 1,
        "maxNodes": 3
      }
    ]
  },
  "status": {
    "phase": "Provisioning",
    "adapters": []
  }
}
```

**Cluster with Dependencies** (`testdata/clusters/cluster-with-deps.json`):
```json
{
  "id": "cls-test-002",
  "name": "test-cluster-deps",
  "generation": 1,
  "spec": {
    "provider": "gcp",
    "region": "us-east1"
  },
  "status": {
    "phase": "Provisioning",
    "adapters": [
      {
        "name": "validation",
        "available": "True"
      }
    ]
  }
}
```

### Adapter Configuration Fixtures

**Validation Adapter Config** (`testdata/configs/validation-adapter.yaml`):
```yaml
apiVersion: hyperfleet.redhat.com/v1alpha1
kind: AdapterConfig
metadata:
  name: validation-adapter
spec:
  adapter:
    version: "1.0.0"
  hyperfleetApi:
    timeout: 2s
    retryAttempts: 3
    retryBackoff: exponential
  kubernetes:
    apiVersion: "v1"
  params:
    - name: "clusterId"
      source: "event.id"
      type: "string"
      required: true
  preconditions:
    - name: "clusterStatus"
      apiCall:
        method: "GET"
        url: "{{ .hyperfleetApiBaseUrl }}/api/hyperfleet/{{ .hyperfleetApiVersion }}/clusters/{{ .clusterId }}"
        timeout: 10s
        retryAttempts: 3
        retryBackoff: "exponential"
      capture:
        - name: "clusterPhase"
          field: "status.phase"
        - name: "generationId"
          field: "generation"
      conditions:
        - field: "clusterPhase"
          operator: "equals"
          value: "NotReady"
  resources:
    - name: "validationJob"
      recreateOnChange: true
      manifest:
        apiVersion: batch/v1
        kind: Job
        metadata:
          name: "validation-{{ .clusterId | lower }}"
          labels:
            hyperfleet.io/cluster-id: "{{ .clusterId }}"
            hyperfleet.io/resource-type: "job"
            hyperfleet.io/managed-by: "{{ .metadata.name }}"
        spec:
          template:
            spec:
              containers:
                - name: "validation"
                  image: "quay.io/hyperfleet/validation-job:test"
              restartPolicy: "Never"
      discovery:
        namespace: "{{ .clusterId | lower }}"
        bySelectors:
          labelSelector:
            hyperfleet.io/cluster-id: "{{ .clusterId }}"
            hyperfleet.io/resource-type: "job"
            hyperfleet.io/managed-by: "{{ .metadata.name }}"
  post:
    payloads:
      - name: "statusPayload"
        build:
          adapter: "{{ .metadata.name }}"
          conditions:
            - type: "Applied"
              status:
                expression: |
                  resources.?validationJob.?status.?succeeded.orValue(0) > 0 ? "True" : "False"
              reason:
                expression: |
                  resources.?validationJob.?status.?succeeded.orValue(0) > 0 ? "JobCreated" : "JobPending"
              message:
                expression: |
                  resources.?validationJob.?status.?succeeded.orValue(0) > 0 ? "Validation job created" : "Job creation in progress"
            - type: "Available"
              status:
                expression: |
                  resources.?validationJob.?status.?succeeded.orValue(0) > 0 ? "True" : "False"
              reason:
                expression: |
                  resources.?validationJob.?status.?succeeded.orValue(0) > 0 ? "JobSucceeded" : "JobNotComplete"
              message:
                expression: |
                  resources.?validationJob.?status.?succeeded.orValue(0) > 0 ? "Job completed" : "Job not yet complete"
            - type: "Health"
              status:
                expression: |
                  adapter.?executionStatus.orValue("") == "success" ? "True" : (adapter.?executionStatus.orValue("") == "failed" ? "False" : "Unknown")
              reason:
                expression: |
                  adapter.?errorReason.orValue("") != "" ? adapter.?errorReason.orValue("") : "Healthy"
              message:
                expression: |
                  adapter.?errorMessage.orValue("") != "" ? adapter.?errorMessage.orValue("") : "All adapter operations completed successfully"
          observed_generation:
            expression: "generationId"
          observed_time:
            value: "{{ now | date \"2006-01-02T15:04:05Z07:00\" }}"
    postActions:
      - name: "reportStatus"
        apiCall:
          method: "POST"
          url: "{{ .hyperfleetApiBaseUrl }}/api/hyperfleet/{{ .hyperfleetApiVersion }}/clusters/{{ .clusterId }}/statuses"
          body: "{{ .statusPayload }}"
          timeout: 30s
          retryAttempts: 3
          retryBackoff: "exponential"
          headers:
            - name: "Content-Type"
              value: "application/json"
```

### Expected Status Fixtures

**Preconditions Not Met** (`testdata/statuses/preconditions-not-met.json`):
```json
{
  "adapter": "validation-adapter",
  "observed_generation": 1,
  "conditions": [
    {
      "type": "Applied",
      "status": "False",
      "reason": "PreconditionsNotMet",
      "message": "Preconditions not met: cluster phase is not Provisioning",
    },
    {
      "type": "Available",
      "status": "False",
      "reason": "PreconditionsNotMet",
      "message": "Cannot proceed until preconditions are met",
    },
    {
      "type": "Health",
      "status": "True",
      "reason": "NoErrors",
      "message": "Adapter is healthy",
    }
  ],
  "observed_time": "2025-01-15T10:00:05Z"
}
```

**Job Created** (`testdata/statuses/job-created.json`):
```json
{
  "adapter": "validation-adapter",
  "observed_generation": 1,
  "conditions": [
    {
      "type": "Applied",
      "status": "True",
      "reason": "JobCreated",
      "message": "Validation job created",
    },
    {
      "type": "Available",
      "status": "False",
      "reason": "JobRunning",
      "message": "Job is executing",
    },
    {
      "type": "Health",
      "status": "True",
      "reason": "NoErrors",
      "message": "Adapter is healthy",
    }
  ],
  "observed_time": "2025-01-15T10:00:10Z"
}
```

**Job Succeeded** (`testdata/statuses/job-succeeded.json`):
```json
{
  "adapter": "validation-adapter",
  "observed_generation": 1,
  "conditions": [
    {
      "type": "Applied",
      "status": "True",
      "reason": "JobCreated",
      "message": "Validation job created",
    },
    {
      "type": "Available",
      "status": "True",
      "reason": "JobSucceeded",
      "message": "Job completed successfully",
    },
    {
      "type": "Health",
      "status": "True",
      "reason": "AllChecksPass",
      "message": "Job completed successfully",
    }
  ],
  "data": {
    "job_name": "validation-cls-test-001-gen1",
    "executionTime": "110s"
  },
  "observed_time": "2025-01-15T10:02:00Z"
}
```

---

## Test Cases

### Test Case 1: Event Received, Criteria Met, Job Created Successfully

**Objective**: Verify adapter creates Kubernetes Job when preconditions are met.

**Setup**:
1. Start test environment (broker, API, Kubernetes)
2. Configure adapter with validation adapter config
3. Mock API to return cluster with `phase: "Provisioning"`

**Steps**:
1. Publish CloudEvent: `{resourceType: "clusters", resourceId: "cls-test-001", clusterId: "cls-test-001", href: "/api/hyperfleet/v1/clusters/cls-test-001"}`
2. Wait for adapter to process event (max 5 seconds)
3. Verify API was called: `GET /clusters/cls-test-001`
4. Verify Job was created in Kubernetes
5. Verify status was reported: `POST /clusters/cls-test-001/statuses`

**Expected Outcomes**:
- ✅ Event consumed from broker
- ✅ Cluster fetched from API
- ✅ Preconditions evaluated: `clusterDetails.status.phase == "Provisioning"` → `True`
- ✅ Job created: `validation-cls-test-001-gen1`
- ✅ Status reported: `Applied=True, Available=False, Health=True`
- ✅ Event acknowledged to broker

**Assertions**:
```go
assert.EventConsumed(t, broker, eventId)
assert.APICalled(t, mockAPI, "GET", "/api/v1/clusters/cls-test-001")
assert.JobCreated(t, k8sClient, "validation-cls-test-001-gen1")
assert.StatusReported(t, mockAPI, expectedStatus)
assert.EventAcknowledged(t, broker, eventId)
```

---

### Test Case 2: Event Received, Criteria Not Met, Job Skipped

**Objective**: Verify adapter skips Job creation when preconditions are not met.

**Setup**:
1. Start test environment
2. Configure adapter with validation adapter config
3. Mock API to return cluster with `phase: "Ready"` (not Provisioning)

**Steps**:
1. Publish CloudEvent: `{resourceType: "clusters", resourceId: "cls-test-002", clusterId: "cls-test-002", href: "/api/hyperfleet/v1/clusters/cls-test-002"}`
2. Wait for adapter to process event (max 5 seconds)
3. Verify API was called: `GET /clusters/cls-test-002`
4. Verify Job was NOT created
5. Verify status was reported: `Applied=False, Available=False, Health=True`

**Expected Outcomes**:
- ✅ Event consumed from broker
- ✅ Cluster fetched from API
- ✅ Preconditions evaluated: `clusterDetails.status.phase == "Provisioning"` → `False`
- ✅ Job NOT created
- ✅ Status reported: `Applied=False, Available=False, Health=True` with reason `PreconditionsNotMet`
- ✅ Event acknowledged to broker

**Assertions**:
```go
assert.EventConsumed(t, broker, eventId)
assert.APICalled(t, mockAPI, "GET", "/api/v1/clusters/cls-test-002")
assert.JobNotCreated(t, k8sClient, "validation-cls-test-002-gen1")
assert.StatusReported(t, mockAPI, expectedStatusPreconditionsNotMet)
assert.EventAcknowledged(t, broker, eventId)
```

---

### Test Case 3: Job Succeeds, Available=True Reported

**Objective**: Verify adapter reports `Available=True` when Job completes successfully.

**Setup**:
1. Start test environment
2. Configure adapter with validation adapter config
3. Create Job in Kubernetes with `status.succeeded: 1`

**Steps**:
1. Publish CloudEvent: `{resourceType: "clusters", resourceId: "cls-test-003", clusterId: "cls-test-003", href: "/api/hyperfleet/v1/clusters/cls-test-003"}`
2. Wait for adapter to process event (max 5 seconds)
3. Verify Job exists (already created in previous event)
4. Update Job status: `status.succeeded: 1, status.conditions[Complete]: True`
5. Wait for adapter to process (post-processing)
6. Verify status was reported: `Available=True`

**Expected Outcomes**:
- ✅ Event consumed from broker
- ✅ Job discovered (already exists)
- ✅ Post-processing evaluates conditions: `resources.validationJob.status.succeeded > 0` → `True`
- ✅ Status reported: `Applied=True, Available=True, Health=True`
- ✅ Reason: `JobSucceeded`
- ✅ Event acknowledged to broker

**Assertions**:
```go
assert.EventConsumed(t, broker, eventId)
assert.JobExists(t, k8sClient, "validation-cls-test-003-gen1")
assert.JobSucceeded(t, k8sClient, "validation-cls-test-003-gen1")
assert.StatusReported(t, mockAPI, expectedStatusJobSucceeded)
assert.ConditionStatus(t, status, "Available", "True")
assert.ConditionReason(t, status, "Available", "JobSucceeded")
assert.EventAcknowledged(t, broker, eventId)
```

---

### Test Case 4: Job Fails, Available=False Reported

**Objective**: Verify adapter reports `Available=False` when Job fails.

**Setup**:
1. Start test environment
2. Configure adapter with validation adapter config
3. Create Job in Kubernetes with `status.failed: 1`

**Steps**:
1. Publish CloudEvent: `{resourceType: "clusters", resourceId: "cls-test-004", clusterId: "cls-test-004", href: "/api/hyperfleet/v1/clusters/cls-test-004"}`
2. Wait for adapter to process event
3. Verify Job exists
4. Update Job status: `status.failed: 1, status.conditions[Failed]: True`
5. Wait for adapter to process (post-processing)
6. Verify status was reported: `Available=False`

**Expected Outcomes**:
- ✅ Event consumed from broker
- ✅ Job discovered (already exists)
- ✅ Post-processing evaluates conditions: `resources.validationJob.status.succeeded > 0` → `False`
- ✅ Status reported: `Applied=True, Available=False, Health=True`
- ✅ Reason: `JobFailed`
- ✅ Event acknowledged to broker

**Assertions**:
```go
assert.EventConsumed(t, broker, eventId)
assert.JobExists(t, k8sClient, "validation-cls-test-004-gen1")
assert.JobFailed(t, k8sClient, "validation-cls-test-004-gen1")
assert.StatusReported(t, mockAPI, expectedStatusJobFailed)
assert.ConditionStatus(t, status, "Available", "False")
assert.ConditionReason(t, status, "Available", "JobFailed")
assert.EventAcknowledged(t, broker, eventId)
```

---

### Test Case 5: Job Timeout, Error Status Reported

**Objective**: Verify adapter handles Job timeout and reports error status.

**Setup**:
1. Start test environment
2. Configure adapter with validation adapter config
3. Create Job with `activeDeadlineSeconds: 60`
4. Mock time to exceed deadline

**Steps**:
1. Publish CloudEvent: `{resourceType: "clusters", resourceId: "cls-test-005", clusterId: "cls-test-005", href: "/api/hyperfleet/v1/clusters/cls-test-005"}`
2. Wait for Job creation
3. Advance time to exceed `activeDeadlineSeconds`
4. Verify Job is marked as failed due to timeout
5. Wait for adapter to process
6. Verify status was reported with timeout error

**Expected Outcomes**:
- ✅ Event consumed from broker
- ✅ Job created with timeout
- ✅ Job marked as failed after timeout
- ✅ Status reported: `Applied=True, Available=False, Health=True`
- ✅ Reason: `JobTimeout` or `DeadlineExceeded`
- ✅ Message indicates timeout occurred

**Assertions**:
```go
assert.EventConsumed(t, broker, eventId)
assert.JobCreated(t, k8sClient, "validation-cls-test-005-gen1")
assert.JobTimedOut(t, k8sClient, "validation-cls-test-005-gen1")
assert.StatusReported(t, mockAPI, expectedStatusJobTimeout)
assert.ConditionReason(t, status, "Available", "JobTimeout")
assert.EventAcknowledged(t, broker, eventId)
```

---

### Test Case 6: API Unavailable, Retry Logic Engaged

**Objective**: Verify adapter retries API calls when API is temporarily unavailable.

**Setup**:
1. Start test environment
2. Configure adapter with retry logic: `retryAttempts: 3, retryBackoff: exponential`
3. Mock API to return `500 Internal Server Error` for first 2 calls, then `200 OK`

**Steps**:
1. Publish CloudEvent: `{resourceType: "clusters", resourceId: "cls-test-006", clusterId: "cls-test-006", href: "/api/hyperfleet/v1/clusters/cls-test-006"}`
2. Mock API to return `500` for first 2 calls
3. Mock API to return `200` on third call
4. Wait for adapter to process event
5. Verify API was called 3 times (initial + 2 retries)
6. Verify exponential backoff was used

**Expected Outcomes**:
- ✅ Event consumed from broker
- ✅ API call fails with `500`
- ✅ Retry logic engaged: exponential backoff
- ✅ API called 3 times total
- ✅ Eventually succeeds on retry
- ✅ Event processing completes successfully

**Assertions**:
```go
assert.EventConsumed(t, broker, eventId)
assert.APICallCount(t, mockAPI, "GET", "/api/v1/clusters/cls-test-006", 3)
assert.ExponentialBackoff(t, mockAPI, retryAttempts)
assert.EventuallySucceeds(t, adapter, eventId, 10*time.Second)
assert.EventAcknowledged(t, broker, eventId)
```

---

### Test Case 7: Broker Reconnection Handling

**Objective**: Verify adapter handles broker disconnection and reconnection gracefully.

**Setup**:
1. Start test environment
2. Configure adapter with broker connection
3. Establish connection to broker

**Steps**:
1. Publish CloudEvent to broker
2. Disconnect broker (simulate network failure)
3. Verify adapter detects disconnection
4. Reconnect broker
5. Verify adapter reconnects automatically
6. Publish another CloudEvent
7. Verify event is processed after reconnection

**Expected Outcomes**:
- ✅ Adapter detects broker disconnection
- ✅ Adapter attempts reconnection with backoff
- ✅ Adapter successfully reconnects
- ✅ Events published after reconnection are processed
- ✅ No events are lost during disconnection

**Assertions**:
```go
assert.BrokerConnected(t, adapter, broker)
assert.PublishEvent(t, broker, event1)
assert.BrokerDisconnected(t, broker)
assert.AdapterDetectsDisconnection(t, adapter)
assert.BrokerReconnected(t, broker)
assert.AdapterReconnects(t, adapter, broker)
assert.PublishEvent(t, broker, event2)
assert.EventProcessed(t, adapter, event2)
```

---

### Test Case 8: Graceful Shutdown with In-Flight Events

**Objective**: Verify adapter completes in-flight events before shutting down.

**Setup**:
1. Start test environment
2. Configure adapter
3. Start adapter service

**Steps**:
1. Publish CloudEvent (long-running job)
2. Send SIGTERM to adapter process
3. Verify adapter stops accepting new events
4. Verify in-flight event completes processing
5. Verify adapter shuts down gracefully
6. Verify no events are lost

**Expected Outcomes**:
- ✅ Adapter receives SIGTERM
- ✅ Adapter stops accepting new events
- ✅ In-flight event completes processing
- ✅ Status reported before shutdown
- ✅ Event acknowledged before shutdown
- ✅ Adapter shuts down cleanly
- ✅ No resource leaks

**Assertions**:
```go
assert.PublishEvent(t, broker, event)
assert.SendSignal(t, adapter, syscall.SIGTERM)
assert.AdapterStopsAcceptingEvents(t, adapter)
assert.InFlightEventCompletes(t, adapter, event, 30*time.Second)
assert.StatusReported(t, mockAPI, expectedStatus)
assert.EventAcknowledged(t, broker, eventId)
assert.AdapterShutdown(t, adapter, 5*time.Second)
```

---

### Test Case 9: Multiple Events for Same Cluster (Idempotency)

**Objective**: Verify adapter handles multiple events for the same cluster idempotently.

**Setup**:
1. Start test environment
2. Configure adapter
3. Mock API to return same cluster

**Steps**:
1. Publish CloudEvent 1: `{resourceType: "clusters", resourceId: "cls-test-009", clusterId: "cls-test-009", href: "/api/hyperfleet/v1/clusters/cls-test-009"}`
2. Wait for Job creation
3. Publish CloudEvent 2: `{resourceType: "clusters", resourceId: "cls-test-009", clusterId: "cls-test-009", href: "/api/hyperfleet/v1/clusters/cls-test-009"}` (same cluster)
4. Verify Job is NOT created again (already exists)
5. Verify status is updated (not duplicated)
6. Publish CloudEvent 3: `{resourceType: "clusters", resourceId: "cls-test-009", clusterId: "cls-test-009", href: "/api/hyperfleet/v1/clusters/cls-test-009"}` (same cluster)
7. Verify idempotent behavior

**Expected Outcomes**:
- ✅ First event creates Job
- ✅ Second event discovers existing Job (doesn't create duplicate)
- ✅ Status updated (not duplicated)
- ✅ Third event also idempotent
- ✅ Only one Job exists for cluster
- ✅ Status reflects latest state

**Assertions**:
```go
assert.PublishEvent(t, broker, event1)
assert.JobCreated(t, k8sClient, "validation-cls-test-009-gen1")
assert.PublishEvent(t, broker, event2)
assert.JobNotCreated(t, k8sClient, "validation-cls-test-009-gen1") // Already exists
assert.JobCount(t, k8sClient, "validation-cls-test-009-gen1", 1)
assert.StatusUpdated(t, mockAPI, "cls-test-009", 2) // Updated, not duplicated
assert.PublishEvent(t, broker, event3)
assert.IdempotentBehavior(t, adapter, event3)
```

---

### Test Case 10: Condition Aggregation with Custom Conditions

**Objective**: Verify adapter evaluates and reports custom conditions in addition to required conditions.

**Setup**:
1. Start test environment
2. Configure adapter with custom conditions:
   ```yaml
   post:
     payloads:
       - name: "statusPayload"
         build:
           adapter: "{{ .metadata.name }}"
           conditions:
             - type: "Applied"
               # ... status/reason/message expressions
             - type: "Available"
               # ... status/reason/message expressions
             - type: "Health"
               # ... status/reason/message expressions
             - type: "CustomCondition"
               status:
                 expression: |
                   resources.?validationJob.?status.?succeeded.orValue(0) > 0 &&
                   resources.?dnsJob.?status.?succeeded.orValue(0) > 0 ? "True" : "False"
               reason:
                 expression: |
                   "AllJobsSucceeded"
               message:
                 expression: |
                   "All validation and DNS jobs completed"
   ```

**Steps**:
1. Publish CloudEvent
2. Create multiple Jobs (validation, DNS)
3. Wait for Jobs to complete
4. Verify status includes custom condition
5. Verify custom condition is evaluated correctly

**Expected Outcomes**:
- ✅ Event consumed and processed
- ✅ Multiple Jobs created
- ✅ Post-processing evaluates custom condition
- ✅ Status includes custom condition: `customCondition: True`
- ✅ Custom condition reason and message are correct

**Assertions**:
```go
assert.EventConsumed(t, broker, eventId)
assert.JobCreated(t, k8sClient, "validation-cls-test-010-gen1")
assert.JobCreated(t, k8sClient, "dns-cls-test-010-gen1")
assert.JobSucceeded(t, k8sClient, "validation-cls-test-010-gen1")
assert.JobSucceeded(t, k8sClient, "dns-cls-test-010-gen1")
assert.StatusReported(t, mockAPI, expectedStatus)
assert.CustomConditionExists(t, status, "customCondition")
assert.CustomConditionStatus(t, status, "customCondition", "True")
assert.CustomConditionReason(t, status, "customCondition", "AllJobsSucceeded")
```

---

## Expected Outcomes

### Common Assertions

All test cases should verify:

1. **Event Processing**:
   - Event consumed from broker
   - Event acknowledged (or nacked if retry needed)
   - No duplicate processing

2. **API Interactions**:
   - Correct API endpoints called
   - Request payloads match expected structure
   - Response handling correct

3. **Kubernetes Resources**:
   - Resources created with correct spec
   - Resources tracked correctly
   - Resource discovery works

4. **Status Reporting**:
   - Status reported to correct endpoint
   - Status payload matches contract
   - Conditions evaluated correctly
   - Data field populated correctly

5. **Error Handling**:
   - Errors handled gracefully
   - Retry logic works correctly
   - Error status reported appropriately

### Test Execution

**Run All Tests**:
```bash
make test-integration
```

**Run Specific Test**:
```bash
go test -v ./test/integration -run TestCase1
```

**Run with Verbose Output**:
```bash
go test -v ./test/integration -args -verbose
```

**Run with Coverage**:
```bash
go test -cover ./test/integration
```

### Test Cleanup

All tests should:
1. Clean up created Kubernetes resources
2. Close broker connections
3. Stop mock API servers
4. Clean up test data

**Cleanup Helper**:
```go
func CleanupTestEnvironment(t *testing.T, env *TestEnvironment) {
    // Delete Kubernetes resources
    // Close broker connections
    // Stop mock servers
    // Clean up test data
}
```

---

## Test Metrics

### Success Criteria

- ✅ All test cases pass
- ✅ No resource leaks
- ✅ Tests complete within timeout
- ✅ Test isolation (no shared state)

### Performance Targets

- Event processing: < 5 seconds
- Status reporting: < 2 seconds
- Resource creation: < 3 seconds
- Test execution: < 30 seconds per test case

### Coverage Goals

- Event processing workflow: 100%
- Precondition evaluation: 100%
- Resource creation: 100%
- Status reporting: 100%
- Error handling: 90%+

---

## Maintenance

### Adding New Test Cases

1. Add test case to this document
2. Create test data fixtures
3. Implement test function
4. Add assertions
5. Update test execution documentation

### Updating Test Data

- Test data fixtures versioned with code
- Update fixtures when contract changes
- Maintain backward compatibility where possible

### Debugging Failed Tests

1. Check test logs for errors
2. Verify test environment setup
3. Check mock API request/response logs
4. Verify Kubernetes resource state
5. Check broker message state

