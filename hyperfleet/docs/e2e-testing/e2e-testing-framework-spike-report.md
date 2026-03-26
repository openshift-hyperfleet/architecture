---
Status: Active
Owner: HyperFleet QE Team
Last Updated: 2026-01-13
---

# Spike Report: E2E Testing Framework for Hyperfleet Core Data Flow
**JIRA Story:** HYPERFLEET-403  
**Date:** Jan 9, 2026  

---

## Overview

This spike report evaluates E2E testing frameworks for **Hyperfleet's core data flow**—testing the end-to-end pipeline: Hyperfleet API → Sentinel → Message Broker → Adapters → back to API.

### ✅ Decision: Ginkgo v2 + Gomega + Markdown Documentation

After evaluating Ginkgo v2, Godog, and Testify across seven dimensions, we select **Ginkgo v2 + Gomega** because this combination excels in:
- **Reliability & Flakiness Prevention**: Gomega's built-in async testing (`Eventually`/`Consistently`) prevents flaky tests in distributed systems
- **AI-Assisted Development**: Pure Go optimizes LLM-driven test generation, maintenance, and debugging
- **Maturity & Ecosystem**: Large community, widely adopted, strong long-term support

**What This Means:**
- **Ginkgo v2**: BDD-style test framework providing test organization, labels, parallel execution, and lifecycle hooks
- **Gomega**: Assertion library with expressive matchers and async testing primitives
- **Markdown**: Documentation format for test scenarios, linked to code via AI-Sync-ID metadata

We mitigate documentation drift risk through AI-powered validation and CI checks (detailed in Section 2.3).

**Scope**: This framework tests our core data flow architecture. Provider-specific adapter implementations (validation, DNS, etc.) are **out of scope** and should have dedicated stories. 

---

## 1. Background & Problem Statement

### 1.1 System Architecture

The target system comprises the **core Hyperfleet data flow framework**:

![Hyperfleet E2E Data Flow Architecture](./hyperfleet-e2e.png)

*Diagram provided by Ciaran*

**Core Data Flow (In Scope):**
1. **User → API**: User creates/queries objects through Hyperfleet API
2. **API → Sentinel**: Sentinel polls API for objects requiring orchestration
3. **Sentinel → Broker**: Sentinel creates topics and publishes to message broker
4. **Broker → Adapter**: Topics are broadcast to adapter(s) for consumption
5. **Adapter → API**: Adapters orchestrate task lifecycle and report state back to API

**Out of Scope:**
- Provider-specific adapter implementations (validation, DNS, pull-secret adapters, etc.)
- Provider-specific infrastructure provisioning
- Multi-provider deployment architecture
- Test case Markdown format details (refer to the [latest template](https://github.com/openshift-hyperfleet/hyperfleet-e2e/blob/main/testcases/template.md); feedback should be tracked in separate tickets)

### 1.2 Testing Challenges

1. **Multi-Component Data Flow:** Validating data flow across API → Sentinel → Broker → Adapter → API
2. **Asynchronous Operations:** Eventual consistency requires intelligent polling and timeout handling
3. **Version Skew:** Rolling deployments require compatibility validation across service versions
4. **Framework Regression:** Changes in one component must not break downstream components

---

## 2. Framework Selection and Evaluation

### 2.1 Evaluation Criteria

Three candidate frameworks were evaluated—**Ginkgo v2**, **Godog**, and **Testify**—across seven critical dimensions:

1. **Integration & Setup**: Ease of integrating testing scenarios, CI pipelines, and tooling requirements
2. **Test Organization & Execution**: Test structure, filtering capabilities, and execution control
3. **Documentation & Communication**: How tests serve as documentation and communicate intent to stakeholders
4. **Reliability & Flakiness Prevention**: Built-in support for eventual consistency, retry logic, and anti-flakiness patterns
5. **AI-Assisted Development**: Suitability for LLM-driven test generation, maintenance, and debugging
6. **Maturity & Ecosystem**: Community size, stability, long-term support, and available resources
7. **Long-term Maintainability**: Ease of debugging, refactoring, and evolving tests over time

### 2.2 Framework Comparison

| Criteria | Ginkgo v2 + Gomega | Godog | Testify |
|----------|-----------|-------|---------|
| **Integration & Setup** | ⭐⭐⭐⭐⭐ Standard Go, minimal dependencies | ⭐⭐⭐☆☆ Requires Godog runner + feature files | ⭐⭐⭐⭐⭐ Standard Go test |
| **Test Organization & Execution** | ⭐⭐⭐⭐⭐ Labels, hierarchical, parallel | ⭐⭐⭐⭐☆ Tags, scenarios, serial by default | ⭐⭐☆☆☆ Flat, name-based |
| **Documentation & Communication** | ⭐⭐⭐☆☆ Requires separate Markdown docs | ⭐⭐⭐⭐⭐ Executable specs, zero drift | ⭐⭐☆☆☆ Code-only |
| **Reliability & Flakiness Prevention** | ⭐⭐⭐⭐⭐ Gomega's Eventually/Consistently, automatic retry | ⭐⭐☆☆☆ Manual polling with custom logic | ⭐⭐☆☆☆ Manual implementation |
| **AI-Assisted Development** | ⭐⭐⭐⭐⭐ Single language, direct debugging | ⭐⭐⭐☆☆ Two languages, higher token cost | ⭐⭐⭐⭐☆ Simple but limited |
| **Maturity & Ecosystem** | ⭐⭐⭐⭐⭐ Large community, widely adopted | ⭐⭐⭐☆☆ Smaller community, growing | ⭐⭐⭐⭐☆ Mature, simpler scope |
| **Long-term Maintainability** | ⭐⭐⭐⭐☆ Doc drift risk, strong tooling | ⭐⭐⭐⭐☆ Two files to maintain, clear intent | ⭐⭐⭐☆☆ Limited structure |

**Key Trade-offs:**

| Framework | Strengths | Weaknesses |
|-----------|-----------|------------|
| **Ginkgo v2 + Gomega** | • Gomega's async testing (`Eventually`/`Consistently`)<br>• Pure Go (AI-friendly, single language)<br>• Rich organization (labels, parallel, ordered)<br>• Expressive matchers for clear assertions | • Separate docs (drift risk)<br>• Less accessible to non-developers |
| **Godog** | • Executable specs (zero drift by design)<br>• Readable by non-developers<br>• Industry-standard Gherkin | • Manual async patterns<br>• Two-file system overhead<br>• Less AI-optimal (context switching) |

**✅ Decision: Ginkgo v2 + Gomega + Markdown**

For Hyperfleet E2E testing, we prioritize **reliability** (Gomega's robust async testing) and **development velocity** (AI-assisted workflows with pure Go) over executable documentation. Meanwhile, we mitigate doc drift through AI-powered validation (Section 2.3).

**Note:** Ginkgo v2 and Gomega are designed to work together—Ginkgo provides the test framework structure while Gomega provides the assertion library with async testing capabilities.

*See Appendix A for detailed framework evaluations.*

### 2.3 Implementation: Ginkgo v2 + Gomega + Markdown Documentation

**This is our chosen approach.** The Hyperfleet E2E testing framework uses **Ginkgo v2** (test framework) with **Gomega** (assertion library) and **Markdown documentation**. 

**Why This Combination:**
- **Ginkgo v2**: Provides BDD-style test organization, label-based filtering, parallel execution, and powerful lifecycle hooks
- **Gomega**: Offers rich, expressive matchers and built-in async testing (`Eventually`/`Consistently`) for distributed systems
- **Markdown**: Flexible documentation format supporting diagrams, code samples, and rich formatting beyond Gherkin limitations

This section details implementation patterns and how we address documentation drift.

#### 2.3.1 Reliability & Flakiness Prevention

Distributed E2E testing requires robust async handling. Ginkgo's built-in patterns eliminate entire classes of flaky tests:

<details>
<summary>Ginkgo Async Testing Patterns (click to expand)</summary>

```go
// Eventual consistency - polls until condition met or timeout
Eventually(func() string {
    return apiClient.GetObjectStatus(ctx, objectID).State
}, 10*time.Minute, 15*time.Second).Should(Equal("COMPLETED"))

// Stable state verification - ensures condition remains true
Consistently(func() bool {
    return brokerClient.IsHealthy(ctx)
}, 2*time.Minute, 5*time.Second).Should(BeTrue())

// Idempotent cleanup
AfterEach(func() {
    defer GinkgoRecover()
    if testObject != nil {
        _ = apiClient.DeleteObject(testObject.ID)
    }
})
```

</details>


#### 2.3.2 AI-Assisted Development

- **Single language**: LLMs parse pure Go without Gherkin/Go context switching
- **Direct debugging**: Stack traces map to exact code locations
- **High generation accuracy**: LLMs produce correct Ginkgo patterns with minimal context

#### 2.3.3 Test Organization
**Label-based filtering:**
```bash
ginkgo --label-filter="smoke && gcp"      # Smoke tests for GCP
ginkgo --label-filter="critical && !day2"    # Critical excluding day2
```

**Ordered execution with shared setup:**
```go
Describe("Nodepool", Ordered, func() {
    BeforeAll(func() { clusterID = createCluster() })
    It("creates nodepool", func() { ... })
    It("scales nodepool", func() { ... })
    AfterAll(func() { deleteCluster(clusterID) })
})
```

#### 2.3.4 Documentation Sync Strategy

**Challenge:** Separate Markdown documentation can drift from test code.

**Solution:** AI-assisted sync validation:

**Approach:**

1. **Metadata anchors** link docs to tests:
   ```markdown
   **AI-Sync-ID:** E2E-FLOW-001
   ```
   ```go
   // @AI-Sync-ID: E2E-FLOW-001
   var _ = Describe("Data Flow", Label("E2E-FLOW-001"), ...)
   ```

2. **AI-powered validation**: LLMs verify sync by scanning AI-Sync-IDs, detect drift

3. **Markdown advantages**: Supports diagrams, links, embedded content beyond Gherkin's limitations

#### 2.3.5 Test Case Structure
**Example:**
```markdown
<!-- scenarios/data_flow.md -->
## Scenario: End-to-End Object Creation Data Flow
**AI-Sync-ID:** E2E-FLOW-001  
**Priority:** Critical
...
```
*Refer to the [Test Case Markdown Template](https://github.com/openshift-hyperfleet/hyperfleet-e2e/blob/main/testcases/template.md) for detailed structure.*

```go
// tests/data_flow_test.go
// @AI-Sync-ID: E2E-FLOW-001
var _ = Describe("End-to-End Data Flow", Label("E2E-FLOW-001", "critical"), func() {
    // Test implementation
})
```

#### 2.3.6 Complete Example Implementation
<details>
<summary>Complete Ginkgo + Gomega + Markdown Test Example (click to expand)</summary>

**Part 1: Markdown Documentation**
*Refer to the [Test Case Markdown Template](https://github.com/openshift-hyperfleet/hyperfleet-e2e/blob/main/testcases/template.md) for detailed structure.*

**Part 2: Go Test Implementation**

```go
// tests/data_flow_test.go
// @AI-Sync-ID: E2E-FLOW-001
var _ = Describe("End-to-End Data Flow Validation", Label("data-flow", "framework", "critical", "E2E-FLOW-001"), func() {
    var ctx context.Context

    BeforeEach(func() {
        ctx = context.Background()
        // Initialize clients and verify prerequisites
    })

    AfterEach(func() {
        defer GinkgoRecover()
        // Cleanup resources
    })

    It("should complete full data flow from API to adapter and back", func() {
        By("creating an object via the API")
        createdObject, err := apiClient.CreateObject(ctx, &clients.CreateObjectRequest{
            Name: "test-object-1",
            Type: "ClusterRequest",
        })
        Expect(err).NotTo(HaveOccurred())

        By("verifying object reaches ready state")
        Eventually(func() string {
            status, _ := apiClient.GetObjectStatus(ctx, createdObject.ID)
            return status
        }, 10*time.Minute, 15*time.Second).Should(Equal("READY"))
    })
})
```

</details>

---

## 3. Compatibility Testing Strategy

### 3.1 Branch-Based Testing Model

**Principle:** Repository branch = CLM Framework version (no version tracking in test code).

**Structure:**
```
e2e-tests/
├── release-1.0.x/        # Tests for Hyperfleet v1.0.x
├── release-1.1.x/        # Tests for Hyperfleet v1.1.x
├── release-1.2.x/        # Tests for Hyperfleet v1.2.x (current)
└── main/                 # Tests for next release (development)
```

Each branch contains tests for that specific framework release. Branch name implicitly defines which API contract tests expect.

### 3.2 Backward Compatibility Testing

Run old tests on new framework to validate backward compatibility:

```bash
# Test current release
git checkout release-1.2
./e2e-runner --env=staging.yaml  # v1.2.0 passes

# Test backward compatibility  
git checkout release-1.1          # Old tests
./e2e-runner --env=staging.yaml   # Same v1.2.0 environment passes
```

**Validates:**
- API contract stability across versions
- Topic format compatibility
- Framework component interoperability

---

## 4. Action Items and Next Steps

This section outlines the implementation roadmap following this spike report. Tasks are organized by phase to ensure systematic framework development and test coverage.

### 4.1 Phase 1: Framework Foundation

#### 4.1.1 Initialize HyperFleet E2E Automation Framework
**Objective:** Establish the base testing infrastructure with Ginkgo v2 + Gomega.

**Related Ticket:** HYPERFLEET-486

#### 4.1.2 Update E2E Testing Image Dockerfile for Optimized Build
**Objective:** Create containerized test execution environment.

**Related Ticket:** HYPERFLEET-487

### 4.2 Phase 2: Core Test Implementation

#### 4.2.1 Automate Cluster Creation Test Case with Status Validation
**Objective:** Validate end-to-end cluster creation flow through the data pipeline.

**Related Ticket:** HYPERFLEET-490

#### 4.2.2 Automate Nodepool Creation Test Case with Status Validation
**Objective:** Validate nodepool creation as dependent resource within cluster lifecycle.

**Related Ticket:** HYPERFLEET-491

### 4.3 Phase 3: CI/CD Integration

#### 4.3.1 Update Prow E2E Testing Step with Real Test Execution
**Objective:** Integrate E2E tests into Prow CI pipeline for automated validation.

**Related Ticket:** HYPERFLEET-488

### 4.4 Phase 4 (Post-MVP): Documentation Standards and AI Validation

#### 4.4.1 Improve Test Case Documentation Templates
**Objective:** Standardize test scenario documentation.

**Tasks:**
- Finalize Markdown template structure
- Create examples for common test patterns
- Document AI-Sync-ID conventions and best practices based on the AI sync validation.
- Provide guidelines for test case authoring

**Deliverables:**
- Test case template
- Contribution guidelines for new test cases

#### 4.4.2 Implement AI-Powered Documentation Sync Validation
**Objective:** Ensure test case Markdown documentation and test code remain synchronized to prevent drift and outdated documentation.

**Tasks:**
- Develop AI-powered validation tool that:
  - Scans AI-Sync-ID metadata in both Markdown files and Go test files
  - Uses LLM to semantically compare test scenarios in docs vs. actual test implementation
  - Detects mismatches in test steps, assertions, preconditions, and expected outcomes
  - Identifies orphaned documentation (no matching code) or undocumented tests
  - Generates detailed drift reports with specific discrepancies
- Integrate validation into CI pipeline (e.g., presubmit hook):
  - Run validation on every PR that modifies test files or documentation
  - Block merges if documentation drift exceeds threshold
  - Provide actionable feedback in PR comments
- Create auto-sync assistance:
  - Generate suggested documentation updates when code changes
  - Propose code updates when documentation is modified
  - Require human review and approval for all changes

**Deliverables:**
- AI validation CLI tool with LLM integration
- CI job configuration for PR-based validation
- User guide for interpreting validation results and resolving drift

#### 4.4.3 AI-Powered Test Case Generation (Including Markdown testcase file and testing code)
**Objective:** Accelerate test case development by using AI to automatically generate both test documentation (Markdown) and implementation code (Ginkgo + Gomega) from high-level test requirements.

**AI Capabilities:**
- **Pattern Recognition:** Analyze existing test suite to learn project-specific patterns
- **Best Practice Application:** Automatically apply async testing patterns (`Eventually`/`Consistently`)
- **Smart Defaults:** Infer reasonable timeouts, poll intervals, and cleanup logic
- **Context Awareness:** Use AI-Sync-ID conventions, label patterns, and file organization from existing tests
- **Anti-Flakiness:** Automatically include idempotent cleanup, proper error handling, and stable assertions

**Deliverables:**
- AI test generation CLI tool with multiple input modes
- Prompt template library for common Hyperfleet test scenarios
- Code validation pipeline ensuring generated tests meet quality standards
- Human review guidelines and approval workflow documentation
- User guide with examples and best practices for AI-assisted test authoring

### 4.5 Phase 5 (Post-MVP): Advanced Test Observability and Debugging Platform

**Objective:** Establish comprehensive test observability and debugging capabilities to accelerate root cause analysis, identify flaky tests, and reduce test failure noise across the E2E test suite.

**Required Capabilities:**

**1. Component-Level Failure Attribution**
- Automatically identify which CLM component caused test failure
- Correlate test failures with service logs and metrics
- Tag failures by component for targeted investigation

**2. Root Cause Analysis Automation**
- Classify failure reasons automatically:
  - Infrastructure issues (timeout, network connectivity, resource exhaustion)
  - Product defects (API bugs, logic errors, state machine issues)
  - Test code issues (flaky assertions, race conditions, cleanup failures)
  - Environmental issues (configuration drift, dependency unavailability)
- Extract error patterns from logs and stack traces
- Link failures to similar historical failures for faster resolution
- Generate suggested remediation actions based on failure patterns

**3. Flaky Test Identification and Management**
- Track test pass/fail patterns across multiple runs
- Reduce false-positive noise in CI results

**4. Advanced Visualization and Dashboards**
- Test suite health overview (pass rate, execution time trends)
- Failure distribution by component, test type, and severity
- Time-series analysis of test reliability over releases
- Comparison views (current vs. previous release, PR branch vs. main)
- Performance regression detection (test execution time trending)

**5. Integration with Development Workflow**
- Automatic GitHub issue creation for new failure patterns
- PR comments with failure analysis and suggested fixes
- Slack/email notifications with actionable context
- Link test failures to relevant code changes (git blame integration)

**Deliverables:**
- Production-ready test analytics platform deployment
- Component-level failure attribution and root cause analysis
- Flaky test identification dashboard with auto-quarantine
- Custom dashboards showing test health, trends, and regressions
- Automated failure notifications with actionable context
- Team training materials and debugging runbooks
- Integration with GitHub for automated issue creation and PR comments

**Insights from OCP:**

The OCP team is currently migrating from ReportPortal to Sippy for their test observability and analytics platform.

Sippy does not support the same type of dashboard as ReportPortal, where you can view test results for each job and each component in a single dashboard. However, Sippy provides:

1. **Component Readiness**: Gives a quick overview of whether each component passes or fails under different scenarios (configurations) based on recent runs
2. **Test-case-level and job-level views**: Allows you to see both aggregated and detailed test results
3. **Failure Alerts**: For failed jobs/testcases, Sippy has alerts to notify the team via Slack messages

**Recommended Approach for Hyperfleet:**

Consider a temporary hybrid usage of both Sippy and ReportPortal during post-MVP phase to support debugging capabilities, unless a better resolution is identified.

### 4.6 Success Criteria

The E2E testing framework is considered ready for production use when:

- ✅ Framework successfully validates core data flow (API → Sentinel → Broker → Adapter → API)
- ✅ Cluster and Nodepool creation tests pass consistently (>95% success rate)
- ✅ Tests execute in CI on every PR with <15 minute runtime for critical suite
- ✅ Backward compatibility validation catches breaking changes before release
- ✅ Documentation sync validation prevents drift between specs and code
- ✅ Team can add new test cases following established patterns

---

## Appendix A: Detailed Framework Evaluations

This appendix provides detailed assessments of each framework for reference.

### A.1 Hybrid Ginkgo + Godog Pattern

**Overview:**
An alternative approach using Ginkgo v2 as the test runner with Godog (Gherkin) for scenario definition in critical user flows.

**Key Characteristics:**
- Executable Gherkin `.feature` files serve as both documentation and test specifications
- Step definitions map Gherkin steps to Go implementation
- Zero drift between documentation and code (tests fail if out of sync)
- Industry-standard Gherkin syntax for cross-tool compatibility

**When This Approach Makes Sense:**
- Organizations with strong compliance/audit requirements requiring traceable documentation
- Cross-functional teams with significant non-developer involvement (Product, QA, Legal, Compliance)
- Projects where business stakeholders must validate test scenarios
- Environments where executable specifications are mandated by policy
- Teams with existing Gherkin/Cucumber expertise and tooling

**Trade-offs vs. Recommended Approach:**
- **Learning Curve:** Requires team to learn Gherkin syntax and step definition patterns
- **Development Velocity:** Slower test creation with AI assistance compared to pure Go
- **Debugging Complexity:** Stack traces require mapping from Gherkin steps to Go code
- **AI Integration:** Lower first-pass accuracy compared to pure Go approach
- **Context Overhead:** Higher LLM token consumption compared to single-file approach
- **Maintenance:** Additional step definition layer to maintain and keep in sync

**Example Implementation:**

<details>
<summary>Complete Godog (Gherkin) Test Example (click to expand)</summary>

```gherkin
# scenarios/data_flow.feature
@data-flow @framework
Feature: End-to-End Data Flow Validation

  @critical @E2E-FLOW-001
  Scenario: Complete data flow for object creation
    Given the Hyperfleet API is available
    And Sentinel is running and polling
    And the message broker is healthy
    And at least one adapter is deployed
    When I create an object via the API
    Then the object should reach "COMPLETED" state within "10 minutes"
```

```go
// Step 1: Define step implementation
func (s *DataFlowSteps) theObjectShouldReachStateWithin(expectedState, timeoutStr string) error {
    timeout := parseDuration(timeoutStr)
    pollInterval := 10 * time.Second
    startTime := time.Now()

    for {
        status, err := apiClient.GetObjectStatus(ctx, s.CreatedObjectID)
        if err == nil && status.State == expectedState {
            return nil
        }
        if time.Since(startTime) > timeout {
            return fmt.Errorf("timeout waiting for state %s", expectedState)
        }
        time.Sleep(pollInterval)
    }
}

// Step 2: Register steps - map Gherkin phrases to Go functions
func (s *DataFlowSteps) RegisterSteps(sc *godog.ScenarioContext) {
    sc.Step(`^the Hyperfleet API is available$`, s.theAPIIsAvailable)
    sc.Step(`^I create an object via the API$`, s.iCreateAnObject)
    sc.Step(`^the object should reach "([^"]*)" state within "([^"]*)"$`, s.theObjectShouldReachStateWithin)
}

// Step 3: Load all scenarios and create Ginkgo Describe blocks for each feature
func registerFeatureTests() {
    scenariosDir := "../scenarios"
    features, _ := discoverFeatures(scenariosDir)

    // Create a Describe block for each feature file
    for _, feature := range features {
        f := feature

        Describe(f.Name, Label(f.Labels...), func() {
            var dataFlowSteps *steps.DataFlowSteps

            BeforeEach(func() {
                dataFlowSteps = steps.NewDataFlowSteps()
            })

            It("executes feature scenarios", func() {
                // Create Godog test suite
                suite := godog.TestSuite{
                    ScenarioInitializer: func(sc *godog.ScenarioContext) {
                        // Register step definitions
                        dataFlowSteps.RegisterSteps(sc)

                        // Setup scenario hooks
                        sc.After(func(ctx context.Context, scenario *godog.Scenario, err error) (context.Context, error) {
                            _ = dataFlowSteps.Cleanup(ctx)
                            return ctx, nil
                        })
                    },
                    Options: &godog.Options{
                        Format:   "pretty",
                        Paths:    []string{f.Path},
                        TestingT: GinkgoT(),
                    },
                }

                // Run Godog scenarios within Ginkgo
                if status := suite.Run(); status != 0 {
                    Fail("Feature scenarios failed")
                }
            })
        })
    }
}
```

</details>

**Verdict:** While technically sound, Godog prioritizes auditability over development velocity. The Ginkgo + Markdown approach achieves similar traceability with better AI integration and developer experience.

---

### A.2 Other Frameworks Considered

**Testify:**
- Lightweight assertion library excellent for unit/integration tests
- Standard Go test integration with zero setup overhead
- **Not suitable for E2E**: Lacks hierarchical organization, parallel execution primitives, and built-in async polling (`Eventually`/`Consistently`)
- No support for eventual consistency testing in distributed systems
- Better suited for unit tests than distributed E2E orchestration

**Cucumber:**
- Industry standard for BDD but requires maintaining Ruby/JavaScript alongside Go
- Adds language complexity and deployment overhead without leveraging team's Go expertise

**Bruno:**
- Open-source API client for manual/semi-automated API testing
- Better suited for ad-hoc API exploration than systematic regression testing

**Markdown Style Test (ty pattern):**
- Python project using markdown files with embedded test assertions
- Designed for unit tests, not distributed E2E scenarios
- Lacks orchestration primitives for multi-service coordination
- Inspired our metadata anchor approach but not directly applicable to distributed systems complexity

---

## References
- [Ginkgo](https://github.com/onsi/ginkgo)
- [Gomega](https://github.com/onsi/gomega)
- [Cucumber for golang](https://github.com/cucumber/godog)
- [Gherkin](https://cucumber.io/docs/gherkin/)
- [Testify](https://github.com/stretchr/testify)
- [API testing tools](https://testguild.com/api-testing-tools/)
- [Bruno](https://github.com/usebruno/bruno/tree/main)
- [Markdown style test suite example of ty](https://github.com/astral-sh/ruff/blob/main/crates/ty_python_semantic/resources/mdtest/typed_dict.md)
- [OpenShift E2E Testing Repository](https://github.com/openshift/origin/)
- [Sippy provides dashboards for the openshift CI test/job data](https://github.com/openshift/sippy)

---
