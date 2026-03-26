---
Status: Active
Owner: HyperFleet QE Team
Last Updated: 2026-02-03
---

# Spike Report: HyperFleet E2E Test Automation Run Strategy
**JIRA Story:** HYPERFLEET-532  
**Date:** Jan 30, 2026  

## Overview

Spike report on the strategy for running HyperFleet end-to-end tests, including test environment provisioning, test ordering, parallelization, and cleanup. Documents the options evaluated for running E2E tests in CI and the recommended approach for integration with the Prow pipeline.

**Focus:** Deployment lifecycle management, resource isolation, and parallel Test Run execution safety

---

## 1. Problem Statement

HyperFleet E2E testing validates system-level behavior across multiple cooperating components, including:

- HyperFleet API
- Sentinel
- Adapter framework (multiple adapter types)
- Messaging broker (Topics / Subscriptions)

As E2E coverage expands and test pipelines begin executing in parallel, the current approach lacks a clearly defined **E2E test run strategy** to govern:

- Deployment lifecycle ownership
- Resource isolation boundaries
- Race condition prevention in concurrent executions
- Reliable cleanup and observability

This results in:

- Flaky test failures caused by shared resources
- Unclear ownership of deployed components
- Orphaned Kubernetes and broker resources
- Limited scalability of parallel pipelines

This spike defines a **comprehensive E2E test automation run strategy**, focusing on how tests are **deployed, isolated, coordinated, and cleaned up**, rather than on individual test case logic.

---

## 2. Goals and Non-Goals

### 2.1 Goals

This spike aims to define a strategy that:

- Enables **safe parallel execution** of multiple Test Runs
- Ensures **strong resource isolation** between test runs
- Clearly defines **deployment lifecycle ownership**
- Prevents race conditions by design
- Supports **config-driven framework testing** with fake adapters
- Improves **debuggability and maintainability**
- Establishes reusable patterns for future E2E expansion

---

### 2.2 Non-Goals

This spike explicitly does **not** cover:

- Individual test case implementation
- CI/CD pipeline configuration
- Performance or load testing considerations
- External environments not related to HyperFleet (such as cloud resources)

---

## 3. Core Design Principles

### 3.1 Test Run as the Primary Isolation Unit

All test infrastructure, configuration, and resources are scoped to a **single Test Run**.

A Test Run is the smallest unit of:

- Isolation
- Resource ownership

---

### 3.2 Explicit Lifecycle Ownership

Every component participating in E2E testing must have clearly defined ownership for:

- Setup
- Runtime management
- Teardown

Implicit or shared ownership is considered a design flaw.

---

### 3.3 Isolation Over Optimization

When trade-offs exist, this strategy prioritizes:

> Reliability, isolation, and debuggability over startup speed or resource reuse.

---

## 4. E2E Test Run Model

### 4.1 Test Run Definition

A **Test Run** represents one or more E2E test cases executed sequentially as a single unit.

Each Test Run has:

- A globally unique **Test Run ID**
- A well-defined lifecycle: `setup → execute → teardown`
- Exclusive ownership of all resources it creates

---

### 4.2 Test Run Identification

Each Test Run generates a unique identifier (Test Run ID) derived from:

- CI-provided environment variable (when available)
- Unix timestamp with high entropy
- Customized with random components

**Example**: Using `time.Now().UnixNano()` generates a 19-digit number: `1738152345678901234`, resulting in namespace: `e2e-1738152345678901234`.

The Test Run ID is consistently applied to:

- Kubernetes Namespaces
- Resource names
- Broker Topics and Subscriptions
- Labels and annotations

Namespaces are additionally labeled to indicate execution context:

- Label `e2e.hyperfleet.io/ci` distinguishes CI pipeline runs (`yes`) from local developer runs (`no`)
- Enables context-appropriate retention policies
- Does not affect test execution behavior

This ensures **traceability** and **collision avoidance**.

---

### 4.3 Test Run Lifecycle

Each Test Run follows a well-defined lifecycle:

```text
Create Namespace
      ↓
Deploy Infrastructure (helm)
      ↓
Infrastructure Ready
      ↓
Execute Test Suites
      ↓
Cleanup
```

**Step 1: Create Namespace**
- Create dedicated namespace: `e2e-{TEST_RUN_ID}`
- Apply isolation labels (see Section 5.4 for labeling strategy details)

**Step 2: Deploy Infrastructure** (via helm)
- Database (PostgreSQL, deployed with API)
- API and Sentinel
- Custom Resource Definitions (CRDs)
- Fake adapters (deployed with test-specific configurations)
- Pass `test_run_id` to helm deployment for resource tagging

**E2E Configuration Requirements**:
- All messaging resources (topics/subscriptions) must be tagged with `test_run_id` for cleanup
- Naming pattern: `{resource-name}-{test-run-id}` for resource isolation

**Infrastructure Ready** means:
- All infrastructure components are healthy
- Broker topics and subscriptions exist
- Fake adapters are operational and subscribed to topics
- Test suites can execute independently

**Test Suite Execution**:
- Suites execute sequentially
- Adapter Suite may hot-plug fake adapters as needed (for negative cases, edge cases)
- Environment state persists across suites within the same Test Run

**Cleanup**:
- Delete cloud messaging resources (topics/subscriptions) tagged with test_run_id
- Uninstall infrastructure components via helm
- Delete namespace
- See Section 9 for detailed cleanup and retention policy

---

### 4.4 Config-Driven Framework Testing

**Problem**: Core Suite needs to validate HyperFleet framework behavior (event flow, status aggregation) without external dependencies. How can we test the adapter framework effectively?

**Decision**: Deploy fake adapters with test-specific configurations

Deploy the adapter framework image multiple times (as separate Kubernetes Deployments) with different YAML configurations stored in the E2E repository. These **fake adapters** do not execute real business logic (no DNS creation, no real placement, etc.) but simulate adapter behavior to test the framework.

**Key Distinction**:
- **Not production adapters**: These adapters don't perform real operations (no cloud API calls, no actual cluster/nodepool provisioning)
- **Framework testing focus**: We test framework behavior (event routing, status aggregation), not adapter business logic
- **Config-driven simulation**: Different configurations simulate different adapter behaviors (success, failure, timeout, precondition failure, etc.)

**Rationale**:
- **Adapter framework is config-driven**: Adapter behaviors are defined via YAML configuration, not code (architecture design principle)
- **Configuration capabilities are comprehensive**: Preconditions (API calls, CEL expressions), Resources (K8s Job/Deployment manifests), Postconditions (CEL validation), Retry/Timeout strategies
- **Simpler than Fixture Adapter**: No custom code implementation needed for error injection - configs handle all scenarios
- **Aligned with framework design**: Leverages existing config-driven architecture
- **Version controlled**: Test configurations stored in E2E repository
- **No hot-plugging prerequisite**: All fake adapters deployed as infrastructure

**Test Scenario Examples via Configuration**:

| Test Scenario | Configuration Approach | Custom Code Needed? |
|---------------|----------------------|---------------------|
| Success path | Preconditions pass → Job with `exit 0` → Available=True | ❌ No |
| Precondition failure | Preconditions fail → Applied=False | ❌ No |
| Job failure | Job with `command: ['sh', '-c', 'exit 1']` | ❌ No |
| Long-running workload | Job with `command: ['sleep', '120']` | ❌ No |
| Timeout | Config: `timeout: 5s` on long-running job | ❌ No |
| Complex validation | CEL expressions in postconditions | ❌ No |

**E2E Repository Structure**:
```
e2e-testing/
├── testdata/
│   └── adapter-configs/
│       ├── cluster-job/               # Cluster event creates Job workload
│       │   ├── adapter-config.yaml
│       │   ├── adapter-task-config.yaml
│       │   └── adapter-task-resource-*.yaml
│       ├── cluster-deployment/        # Cluster event creates Deployment workload
│       ├── cluster-namespace/         # Cluster event creates Namespace
│       └── nodepool-configmap/        # NodePool event creates ConfigMap
```

**Infrastructure Deployment**:
- Deploy multiple fake adapter instances (same framework image, different configs) using Kubernetes Deployments
- Each fake adapter instance subscribes to events independently
- All deployed as infrastructure (before tests execute)
- Test cases trigger events and verify framework behavior (not adapter business logic)

**Benefits**:
- ✅ No custom Fixture Adapter code needed
- ✅ Uses adapter framework's config-driven capabilities
- ✅ Fast iteration (config changes vs. code compilation)
- ✅ Comprehensive coverage (all scenarios config-driven)
- ✅ Simpler architecture (no separate Fixture Adapter repository)
- ✅ Tests framework behavior (not adapter business logic)

---

## 5. Deployment Lifecycle Strategy

### 5.1 One Namespace per Test Run

Each Test Run is assigned a **dedicated Kubernetes Namespace**.

This Namespace serves as the hard isolation boundary for:

- API
- Sentinel
- Adapters
- Supporting services (databases, brokers, etc.)

**Rationale:**

- Eliminates cross-test interference
- Simplifies cleanup semantics
- Improves debugging clarity
- Avoids complex naming or locking schemes

---

### 5.2 Namespace Naming Convention

Namespace names follow a consistent pattern for operational clarity:

```text
e2e-{TEST_RUN_ID}
```

**Components**:
- `e2e-`: Prefix indicating E2E test resources
- `{TEST_RUN_ID}`: Unique test run identifier

**Rationale**:
- Test Run ID enables correlation of resources across test runs
- Operational teams can identify E2E namespaces without inspecting labels

---

### 5.3 Component Lifecycle Ownership

| Component          | Lifecycle Owner  | Scope        | Notes |
|--------------------|------------------|--------------|-------|
| Namespace          | Test Framework   | Per Test Run | |
| API                | Test Framework   | Per Test Run | |
| Sentinel           | Test Framework   | Per Test Run | Uses broker library to create topics/subscriptions |
| Broker Resources (Topics/Subscriptions) | Sentinel/Adapters | Per Test Run | Created via broker library, tagged with test_run_id |
| Fake Adapters (Core Suite) | Test Framework | Per Test Run | Deployed as infrastructure for normal scenarios |
| Fake Adapters (Adapter Suite) | Test Suite | Per Test Group or Test Case | Hot-plugged for negative/edge cases testing |

**Labeling/Tagging Rule:**

Resources are labeled based on cleanup requirements:

1. **Test Run Namespace**: Must be labeled (enables namespace discovery and retention policy)
2. **Resources within Test Run Namespace**: No labels needed (deleted automatically with namespace)
   - API, Sentinel, Fake Adapters (Deployments, Pods, Services, ConfigMaps, Secrets, etc.)
3. **Resources outside Test Run Namespace**: Must be labeled (require explicit cleanup)
   - Cloud messaging resources (Topics/Subscriptions managed by cloud provider)
   - Cluster namespaces created by adapters via kubectl (in same K8s cluster, different namespace)
   - Other cloud provider resources

**Rationale**: Only label resources that won't be automatically cleaned up by namespace deletion.

---

### 5.4 Resource Labeling Strategy

**Problem**: Which E2E test resources need labels for cleanup and traceability?

**Decision**: Only label resources that require explicit cleanup (outside test run namespace).

**Resources That Need Labels**:

| Resource Type | Location | Labels Required | Cleanup Method |
|---------------|----------|-----------------|----------------|
| Test Run Namespace | Kubernetes | ✅ Yes | Namespace deletion |
| Resources in Test Run Namespace | Kubernetes (within namespace) | ❌ No | Auto-deleted with namespace |
| Cloud Topics/Subscriptions | Cloud provider | ✅ Yes | Cloud CLI with label filter |
| Cluster Namespaces (created by adapters) | Kubernetes (outside test run namespace) | ✅ Yes | kubectl delete with label selector |
| Other cloud resources | Cloud provider | ✅ Yes | Cloud CLI with tag filter |

**Required Labels** (for resources outside namespace):

1. `e2e.hyperfleet.io/test-run-id` - Unique Test Run identifier
2. `e2e.hyperfleet.io/ci` - Execution context (`yes` | `no`)
3. `e2e.hyperfleet.io/managed-by` - Ownership marker (`test-framework`)

**Kubernetes Resources Within Test Run Namespace**:
- API, Sentinel, Fake Adapters (Deployments, Pods, Services, ConfigMaps, Secrets)
- No labels needed - automatically deleted with namespace

**Rationale**:
- **Efficiency**: Only label resources that need explicit cleanup
- **Simplicity**: Namespace deletion handles most resources automatically
- **Cleanup precision**: Labels enable filtering for resources outside namespace
- **Cost control**: Ensures cloud resources are properly tracked and cleaned up

**Note**: Cloud provider resources use simplified tag names (e.g., `test_run_id`) due to platform restrictions on label format.

---

## 6. Resource Isolation Strategy

### 6.1 Kubernetes Resource Isolation

Isolation is achieved via:

- **Namespace-per-Test-Run**: Primary isolation boundary
- **Namespace labeling**: Test Run namespace labeled with `e2e.hyperfleet.io/test-run-id` (for discovery and retention)
- **Resources within namespace**: No additional labeling needed (auto-deleted with namespace)
- Optional but recommended `ResourceQuota` and `LimitRange`

This prevents:

- Pod name collisions
- Service discovery conflicts
- Cross-test communication

**Note**: Only resources outside the test run namespace (e.g., cluster namespaces created by adapters) need explicit `e2e.hyperfleet.io/test-run-id` labels.

---

### 6.2 Messaging and Broker Isolation

Messaging resources (Topics / Subscriptions) are isolated using the Test Run ID.

Common patterns include:

- Run-scoped Topics
- Run-scoped Subscriptions
- Adapter-owned Subscription lifecycles

This avoids:

- Cross-test event delivery
- Subscription reuse race conditions
- Message leakage between runs

**Note**: See Section 9.5 for cloud messaging resource cleanup details.

---

## 7. Race Condition Prevention

Race conditions are prevented through **architectural isolation**, not runtime locking.

### 7.1 Unique Resource Identification

The Test Run ID ensures uniqueness across concurrent executions:

- **Namespace name**: `e2e-{TEST_RUN_ID}` (contains Test Run ID)
- **Namespace labels**: `e2e.hyperfleet.io/test-run-id={TEST_RUN_ID}` (for discovery)
- **Broker resources**: Topics/Subscriptions named `{resource-name}-{TEST_RUN_ID}` and tagged with `test_run_id`
- **Resources created by adapters outside namespace**: Labeled with `e2e.hyperfleet.io/test-run-id`

This guarantees uniqueness even under maximum concurrency.

**No Shared Mutable State**: The strategy explicitly avoids shared Namespaces, Topics/Subscriptions, databases, or API instances. Shared mutable state is the primary source of E2E race conditions.

**Note**: Resources within the test run namespace don't need explicit labels - they inherit isolation from the namespace boundary.

---

### 7.2 Parallel Test Run Execution Model

Parallel pipelines are safe because:

- Each Test Run executes within a sealed resource boundary
- No global locks are required
- Failures are contained within a single Namespace

---

## 8. Test Scenario Organization

### 8.1 Lifecycle Management Model

Test infrastructure is managed at the **Test Run level**, not per test case. Infrastructure is deployed once per Test Run and shared across all test suites (see Section 4.3 for lifecycle details and Section 5 for deployment strategy).

---

### 8.2 Test Suite Types

Test suites represent **validation focus**, not environment configurations.

#### 8.2.1 Core Suite

Validates HyperFleet framework behavior using fake adapters deployed with different configurations.

**Purpose**: Fast, stable testing of framework logic without external dependencies or real business logic.

**Environment**:
- Core components (API, Sentinel)
- Messaging infrastructure (topics/subscriptions created by broker library)
- Fake adapters deployed with test-specific configs (see Section 4.4)
- No external dependencies or real cloud services

**What We Test** (framework behavior, NOT adapter business logic):
- **Event flow**: API → Sentinel → Messaging → Adapter → API
- **Async status aggregation**: Framework waits for adapter responses
- **Status reconciliation**: Framework merges adapter conditions into resource status
- **Concurrent processing**: Framework handles multiple resources in parallel
- **Resource lifecycle**: Cluster and NodePool create/update/delete workflows

**Test Approach**:

Different fake adapters handle different event types, each with configuration defining simulated behavior:

| Framework Behavior | Fake Adapter Config | Simulated Behavior |
|-------------------|---------------------|------------|
| Basic data flow | `cluster-job` | Job exits 0 (simulates success) |
| Async aggregation | `cluster-job` (long-running variant) | Job sleeps 30s (simulates long operation) |

**Example Flow**:

```text
1. Test creates Cluster via API (cluster.created event published)
2. Fake adapter (cluster-job config) consumes event
3. Fake adapter evaluates preconditions (configured to pass)
4. Fake adapter creates Kubernetes Job (configured with 'exit 0' - simulates successful operation)
5. Job completes successfully
6. Fake adapter evaluates postconditions, reports Available=True to API
7. Test validates: Cluster phase = Ready
```

**Characteristics**:
- ✅ Fast execution: No external dependencies, no real business logic
- ✅ Stable: Infrastructure deployed once, 100% reproducible
- ✅ Comprehensive: All framework scenarios covered via fake adapter configurations
- ✅ Focused: Tests framework only, not adapter implementation details

---

#### 8.2.2 Adapter Suite

Validates adapter framework's advanced features using fake adapters: negative cases, edge cases, and hot-plugging.

**Purpose**: Test framework's robustness and hot-plugging capabilities with complex scenarios that require adapter deployment/removal.

**Environment**:
- Core components deployed
- Fake adapters hot-plugged with **flexible deployment granularity** (managed by test groups or individual test cases)

**Validates** (framework advanced features, NOT business logic):
- **Hot-plugging functionality**: Dynamic adapter deployment and removal without restarting API/Sentinel
- **Negative cases**: Deployment failures, invalid configurations, error injection
- **Edge cases**: Timeout scenarios, resource conflicts, concurrent deployments
- Adapter removal and cleanup completeness
- Framework behavior under failure conditions

**Adapter Management Decision**:

We evaluated two deployment granularities for managing adapter lifecycle:

| Approach | Adapter Scope | When Deployed | When Removed | Trade-offs |
|----------|---------------|---------------|--------------|------------|
| **Test Group-level** (Ordered + BeforeAll/AfterAll) | Shared within a test group | Once per test group | After all tests in group | ✅ Faster (deploy once)<br>✅ Good for read-only tests<br>⚠️ Tests in group share adapter state |
| **Test Case-level** (BeforeEach/AfterEach) | Isolated per individual test | Before each test case | After each test case | ✅ Complete isolation<br>✅ No state pollution<br>✅ Required for negative cases<br>❌ Slower (deploy per test) |

**Decision: Support both granularities within Adapter Suite**

**Rationale**:
- Different test types have different isolation needs
- Basic validation tests (e.g., verify adapter registered) benefit from Test Group-level sharing
- **Negative cases** (e.g., error injection, deployment failures, invalid configs) require Test Case-level isolation
- **Hot-plugging validation** requires testing deployment and removal per case
- Edge cases need complete isolation to avoid state contamination
- Mixed approach optimizes for both speed and test quality

**Test Organization**:
- Test groups use scoped `Describe` blocks to control adapter lifecycle
- Test Group-level: `Describe` + `Ordered` + `BeforeAll`/`AfterAll`
- Test Case-level: `Describe` + `BeforeEach`/`AfterEach`
- Multiple test groups can coexist with different strategies

---

### 8.3 Suite Execution Order

**Recommended Order**:

Within a Test Run, suites typically execute in this order:

1. **Core Suite** - Validates framework data flow (normal scenarios)
2. **Adapter Suite** - Validates framework advanced features (negative cases, edge cases, hot-plugging)

**Rationale**:
- Core Suite runs first to validate basic framework functionality
- Core Suite provides fast feedback on infrastructure and normal flows
- Adapter Suite tests complex scenarios and hot-plugging after basic validation

**Flexibility**:
- Suites can run independently if infrastructure is ready
- Multiple Test Runs can execute in parallel, each isolated in separate namespace (e2e-{TEST_RUN_ID})

---

### 8.4 Test Organization Guidelines

**Problem**: When should tests use Test Group-level vs Test Case-level adapter deployment?

**Decision Matrix**:

| Test Characteristics | Recommended Strategy | Rationale |
|---------------------|---------------------|-----------|
| Basic validation (adapter registration, health checks) | Test Group-level | Tests don't interfere, share setup cost |
| Hot-plugging validation | Test Case-level | Must test deployment and removal per case |
| Negative cases (deployment failures, error injection) | Test Case-level | State contamination risk, need fresh adapter |
| Edge cases (timeouts, conflicts, race conditions) | Test Case-level | Unpredictable state, need isolation |
| Configuration variations | Test Case-level | Different adapter configs required |

**Conceptual Structure**:

```go
Describe("Adapter Suite", func() {

  // Test Group 1: Shared fake adapter (Test Group-level)
  Describe("Basic Validation", Ordered, func() {
    var adapter *FakeAdapter
    BeforeAll: Deploy fake adapter once
    It: Test adapter registration with framework
    It: Test subscription to topics
    It: Test health reporting
    AfterAll: Remove adapter
  })

  // Test Group 2: Isolated fake adapters (Test Case-level) - NEGATIVE CASES
  Describe("Negative Cases", func() {
    var adapter *FakeAdapter
    BeforeEach: Deploy fresh fake adapter
    It: Test deployment with invalid config (should fail gracefully)
    It: Test error injection and framework recovery
    It: Test deployment failure handling
    AfterEach: Remove adapter
  })

  // Test Group 3: Isolated fake adapters (Test Case-level) - EDGE CASES
  Describe("Edge Cases", func() {
    var adapter *FakeAdapter
    BeforeEach: Deploy fresh fake adapter
    It: Test timeout scenarios
    It: Test concurrent adapter deployments
    It: Test resource conflicts
    AfterEach: Remove adapter
  })

  // Test Group 4: Hot-plugging validation (Test Case-level)
  Describe("Hot-plugging Lifecycle", func() {
    var adapter *FakeAdapter
    BeforeEach: Deploy fake adapter (test hot-plug deployment)
    It: Verify framework detects new adapter
    It: Verify adapter subscribes to events dynamically
    It: Verify adapter processes events without restart
    AfterEach: Remove adapter (test hot-plug removal)
  })
})
```

**Key Principles**:
- **Test Group-level** (Describe + Ordered + BeforeAll/AfterAll): Basic validation tests that share adapter
- **Test Case-level** (Describe + BeforeEach/AfterEach): Required for negative cases, edge cases, and hot-plugging
- **All use fake adapters**: No real business logic, focus on framework behavior under complex scenarios
- **Scoped test groups**: Each Describe block defines a focused scope for adapter lifecycle management

---

### 8.5 State Management and Suite Independence

Test isolation is achieved through namespace-level separation (Test Run isolation) and adapter lifecycle management (Test Group or Test Case isolation). Each Test Run executes in its own namespace (`e2e-{TEST_RUN_ID}`), ensuring complete separation of infrastructure resources.

**State Ownership Model**:

Test Run state is categorized by lifetime and ownership:

| State Type | Lifetime | Owner | Examples |
|------------|----------|-------|----------|
| Infrastructure State | Test Run | Test Framework | Namespace, API, Sentinel, Fake Adapters (Core Suite) |
| Hot-plugged Adapter State | Test Group or Test Case | Test Group (Describe block) | Fake adapters deployed/removed by Adapter Suite |
| Test Data | Test Case | Test Case | Clusters, NodePools, test-specific resources |

**Isolation Principles**:

1. **Infrastructure persists** - Core components and fake adapters (Core Suite) remain active throughout the Test Run
2. **Hot-plugged fake adapters are ephemeral** - Adapter Suite dynamically deploys/removes fake adapters per test group or test case
3. **Test data is scoped** - Each test case manages its own test resources
4. **Unique naming prevents collision** - Resources use unique identifiers to avoid cross-test interference

**Suite Independence**:

- Suites can run independently if infrastructure is ready
- Suite execution strategy:
  - **Fail-fast**: Core suite failures (API, Sentinel, Messaging) block dependent suites
  - **Fail-tolerant**: Independent suite failures are collected without blocking independent suites
  - Ensures early termination on infrastructure failures while maximizing test coverage
- Each suite validates its prerequisites at startup

**Cleanup Responsibility**:

- Test cases and suites clean their own state (hot-plugged fake adapters, test data)
- Infrastructure cleanup handled by Test Framework (see Section 9 for retention policy)

---

## 9. Resource Management and Cleanup

### 9.1 Cleanup Ownership Model

Cleanup is a shared responsibility between two actors:

1. **E2E Test Flow**: Responsible for setting retention policy and deleting passed tests
2. **Reconciler Job**: Responsible for enforcing TTL and handling edge cases

No single component owns all cleanup. This separation prevents single points of failure.

---

### 9.2 Retention Policy

#### 9.2.1 Default Retention (Safe Fallback)

All namespaces are annotated with a default retention policy at creation:

- **Default TTL**: 2 hours from creation
- **Purpose**: Safety net if E2E flow is interrupted or fails before updating retention
- Ensures orphaned namespaces are automatically cleaned up

#### 9.2.2 Test Result-Based Retention

E2E flow updates namespace retention annotations based on test outcome:

| Test Result | CI Context | Local Context | Retention |
|-------------|------------|---------------|-----------|
| **Passed** | Any | Any | 10 minutes |
| **Failed** | `e2e.hyperfleet.io/ci=yes` | - | 24 hours |
| **Failed** | `e2e.hyperfleet.io/ci=no` | `e2e.hyperfleet.io/ci=no` | 6 hours |

**Rationale**:
- Passed tests have minimal debugging value → short retention conserves quota
  - 10-minute window prevents race conditions between E2E flow and reconciler deletion
- Failed tests need retention for post-mortem
  - CI (24h): Global team across time zones
  - Local (6h): Developer actively investigating
- Default 2h retention: Covers interrupted E2E flows

#### 9.2.3 Retention Override

Environment-based configuration allows overriding default retention policy.

**Use Cases**:
- Extended debugging sessions
- Demonstration environments
- Manual investigation

Override values are stored in namespace annotations for reconciler consumption.

---

### 9.3 Cleanup Reconciliation

#### 9.3.1 Reconciler Responsibilities

A scheduled reconciler job enforces TTL-based cleanup:

- Runs periodically (frequency configurable, typically 30 minutes)
- Scopes to namespaces labeled as E2E test framework managed
- Deletes namespaces based on retention annotation expiry

**Simplicity Principle**: Reconciler does not distinguish between:
- Normal vs orphaned namespaces
- CI vs local runs

All policy decisions are encoded in namespace annotations. Reconciler is stateless.

---

### 9.4 Orphaned Resource Handling

**Definition**: Orphaned resources occur when E2E flow is interrupted before setting final retention.

**Handling**:
- No special orphan detection needed
- Default 2-hour retention set at creation covers this case
- Reconciler treats orphans identically to any expired namespace

**Monitoring**: High orphan rate (inferred from default retention deletions) indicates E2E flow reliability issues.

---

### 9.5 Cloud Resource Cleanup

**Scope**: Cloud messaging resources (GCP Pub/Sub Topics and Subscriptions) require explicit cleanup beyond namespace deletion.

**Creation** (during infrastructure deployment):
- Topics/subscriptions auto-created during helm deployment
- All resources tagged with `test_run_id` for cleanup tracking

**Cleanup Process** (during teardown):

1. **Delete cloud resources FIRST**:
   - Delete topics/subscriptions filtered by `test_run_id` tag
   - Example (GCP): `gcloud pubsub topics delete --filter="labels.test_run_id=1738152345678901234"`
   - Example (GCP): `gcloud pubsub subscriptions delete --filter="labels.test_run_id=1738152345678901234"`
2. **Then helm uninstall** (removes all infrastructure components)
3. **Finally delete namespace**
4. **Reconciler**: Periodically scans for orphaned cloud resources (tagged but older than retention TTL) and deletes them

**Why This Order**:
- Cloud resources deleted **before** namespace deletion (cleanup script needs cluster access)
- Kubernetes namespace deletion does not remove cloud resources
- Cloud resources incur costs and quota consumption

---

## 10. Testing Infrastructure Considerations

### 10.1 Image Build and Distribution

**Image Architecture**:

Test infrastructure uses two container images with distinct responsibilities:

1. **Cloud Platform Tools** - Target cluster authentication
   - Contains cloud provider CLIs (gcloud, aws, etc.)
   - Runs as init container to generate cluster credentials
   - Low change frequency (rebuilt only when cloud tooling updates)

2. **E2E Test Framework** - Infrastructure deployment and test execution
   - Contains helm CLI, test code, and deployment charts
   - Manages entire Test Run lifecycle
   - High change frequency (rebuilt on test code or chart changes)

**Rationale**:
- Infrastructure deployment is orchestrated by Test Framework
- Fake adapter configurations stored in E2E repository enable config-driven testing
- Separation by change frequency optimizes CI/CD build efficiency

---

## 11. Observability and Debugging

Debuggability is enabled by:

- One Namespace per Test Run
- Consistent labeling and naming conventions
- Clear lifecycle boundaries
- Namespace retention on failure
- Component version reporting

**Version Transparency**:

Test framework outputs component versions at Test Run start:
- Core components (API, Sentinel)
- Fake adapters (framework image version + config checksums)
- Hot-plugged fake adapters (logged when Adapter Suite deploys/removes them)

Version information is logged during infrastructure deployment phase, enabling correlation between test results and component versions for failure investigation.

Engineers can:

- Inspect all failed-test resources in a single Namespace
- Correlate logs, events, and message flows
- Reproduce failures with exact component versions
- Identify version-specific issues

---

## 12. Action Items and Next Steps

Implementation follows a phased approach to establish e2e testing infrastructure with config-driven framework validation.

---

### 12.1 Phase 1: MVP with Config-Driven Testing (Immediate)

**Goal**: Establish e2e testing infrastructure with Core Suite validation using fake adapter configurations.

**HYPERFLEET-XXX: Container Image Architecture**
- [ ] Build Cloud Platform Tools image (gcloud, aws cli, kubeconfig generation)
- [ ] Build E2E Test Framework image (helm cli, test code, deployment charts)
- [ ] Set up image build pipeline

**HYPERFLEET-XXX: Fake Adapter Configurations**
- [ ] Create testdata/adapter-configs directory in E2E repository
- [ ] Create adapter configs using naming convention: {resource-type}-{workload-type} (e.g., cluster-job/, nodepool-configmap/)
- [ ] Document configuration patterns for simulating different adapter behaviors

**HYPERFLEET-XXX: Test Run Lifecycle**
- [ ] Implement Test Run ID generation
- [ ] Implement namespace creation with isolation labels (test-run-id, ci, managed-by)
- [ ] Implement infrastructure deployment via helm (API, Sentinel, CRDs, fake adapters with configs)
- [ ] Pass test_run_id to helm deployment for resource tagging (used by broker library to tag topics/subscriptions)
- [ ] Deploy multiple fake adapter instances with different configurations (part of helm deployment)
- [ ] Add infrastructure readiness checks (all pods healthy, adapters can publish/consume messages)
- [ ] Output component versions at Test Run start (API, Sentinel, fake adapters)
- [ ] Implement cleanup: delete cloud resources (topics/subscriptions filtered by test_run_id) + helm uninstall + namespace deletion

**HYPERFLEET-XXX: Core Suite**
- [ ] Implement Core Suite test cases (framework behavior validation, NOT business logic)
- [ ] Test success path with cluster-job fake adapter
- [ ] Test precondition failure scenarios
- [ ] Test job failure scenarios
- [ ] Test async processing with long-running workloads
- [ ] Test timeout handling
- [ ] Validate framework data flow: API → Sentinel → Messaging → Fake Adapter → API
- [ ] Add infrastructure health validation

**HYPERFLEET-XXX: E2E Test Run Strategy Guide**
- [ ] Document Test Run lifecycle for developers
- [ ] Document config-driven testing approach with fake adapters
- [ ] Clarify Core Suite vs Adapter Suite (normal scenarios vs complex scenarios, both use fake adapters)
- [ ] Document fake adapter configuration patterns for different test scenarios
- [ ] Document Core Suite organization
- [ ] Document cleanup and troubleshooting

---

### 12.2 Phase 2: Adapter Suite (Future)

**Goal**: Implement Adapter Suite for framework advanced features testing: negative cases, edge cases, and hot-plugging.

**Prerequisites**: Requires HyperFleet system to support runtime adapter hot-plugging (dynamic adapter deployment without API/Sentinel restart).

**HYPERFLEET-XXX: Adapter Suite - Fake Adapter Configs for Complex Scenarios**
- [ ] Create fake adapter configs for negative cases (invalid config schemas, missing required fields)
- [ ] Create fake adapter configs for edge cases (timeout scenarios, resource conflicts)
- [ ] Create fake adapter configs for hot-plugging validation
- [ ] Document configuration patterns for simulating complex failure scenarios

**HYPERFLEET-XXX: Adapter Suite - Test Implementation**
- [ ] Implement flexible adapter deployment strategies (Ordered + BeforeAll/AfterAll, BeforeEach/AfterEach)
- [ ] Write hot-plugging validation tests (deploy and remove fake adapters dynamically without restart)
- [ ] Write negative case tests (deployment failures, invalid configs, error injection)
- [ ] Write edge case tests (timeouts, concurrent deployments, resource conflicts)
- [ ] Validate framework behavior under failure conditions
- [ ] Add cleanup completeness verification
- [ ] Implement mixed strategy examples (Test Group-level for basic validation, Test Case-level for negative/edge cases)

**HYPERFLEET-XXX: E2E Test Run Strategy Guide (Phase 2)**
- [ ] Write suite organization guide (Core Suite for normal scenarios vs Adapter Suite for complex scenarios)
- [ ] Document test organization strategies (Ordered + BeforeAll, BeforeEach/AfterEach, mixed approach)
- [ ] Document when to use Test Group-level vs Test Case-level deployment
- [ ] Clarify both suites use fake adapters (different scenarios, not different adapter types)
- [ ] Document hot-plugging validation patterns
- [ ] Document negative case and edge case testing patterns

---

### 12.3 Post-MVP Enhancements

The following enhancements are deferred to post-MVP:

**HYPERFLEET-XXX: Retention Policy**
- [ ] Implement namespace retention annotation logic
- [ ] Add test result-based retention updates (passed: 10min, failed: 24h/6h)
- [ ] Configure default 2-hour TTL for orphaned namespaces
- [ ] Write retention policy unit tests

**HYPERFLEET-XXX: Cleanup Reconciler Job**
- [ ] Implement TTL-based namespace reconciler
- [ ] Add orphaned resource detection and cleanup
- [ ] Add orphaned cloud resource cleanup (topics/subscriptions filtered by test_run_id tag)
- [ ] Configure reconciler schedule (30-minute default)
- [ ] Add reconciler monitoring and alerts

---

**Document Status**: Draft for Review
**Next Steps**: Team review and approval, then create implementation tickets
