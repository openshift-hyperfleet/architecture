---
Status: Active
Owner: HyperFleet Adapter Team
Last Updated: 2025-12-30
---

# HyperFleet Adapter Framework - Design Decisions

## Overview

This document captures the key design decisions, trade-offs, and rationale behind the HyperFleet Adapter Framework architecture.

**Related Documentation:**
- [Adapter Framework Design](./adapter-frame-design.md) - Architecture overview
- [Adapter Status Contract](./adapter-status-contract.md) - Status reporting contract
- `adapter-config-template-MVP.yaml` - Configuration structure

---

## Table of Contents

1. [Config-Driven Approach](#1-config-driven-approach)
2. [Kubernetes Resource Management](#2-kubernetes-resource-management-vs-in-process-execution)
3. [Anemic Events Pattern](#3-anemic-events-pattern)
4. [Condition-Based Status Reporting](#4-condition-based-status-reporting)
5. [Adapters POST Status Updates](#5-adapters-post-status-updates)
6. [Helm-Based Deployment](#6-helm-based-deployment)
7. [Layered Configuration Architecture](#7-layered-configuration-architecture)
8. [CEL Expression Language](#8-cel-expression-language)
9. [Performance vs Simplicity](#9-performance-vs-simplicity)
10. [Scalability](#10-scalability)
11. [Future Enhancements](#11-future-enhancements)

---

## 1. Config-Driven Approach

**Decision:** Single adapter binary deployed with different YAML configurations for each adapter type.

**Why:**
- **Build once, reuse everywhere** - single binary supports all adapter types
- **Cloud-agnostic** - cloud-specific logic in configuration, not code
- **Rapid development** - new adapters via YAML, no Go compilation required
- **Consistent behavior** - all adapters follow same lifecycle and patterns
- **Independent versioning** - binary and configs evolve separately

**Trade-offs:**
- ✅ Faster development, easier maintenance, cloud-agnostic, flexible with CEL
- ✅ No code compilation required for new adapters or logic changes
- ❌ Very complex custom logic may require framework extensions

**Alternative Rejected:** Code-per-adapter (separate codebase per adapter)
- Requires code duplication, separate testing/deployment, harder to maintain consistency
- Slower iteration (compile, build, test, deploy cycle for each change)

---

## 2. Kubernetes Resource Management vs In-Process Execution

**Decision:** Adapter creates and manages Kubernetes resources (Deployments, Jobs, Services, ConfigMaps, etc.) rather than executing workload logic in-process.

**Why:**
- **Declarative approach** - adapter declares desired state, Kubernetes handles execution
- **Fault isolation** - resource failures don't crash adapter service
- **Resource management** - explicit CPU/memory limits per resource
- **Native observability** - standard K8s monitoring and tooling (pods, events, metrics)
- **Scalability** - workloads distributed across cluster nodes
- **Kubernetes-native** - leverages built-in controllers and lifecycle management
- **Separation of concerns** - adapter orchestrates, Kubernetes executes

**Resources Managed:**
- **Jobs** - Long-running provisioning tasks (e.g., cluster creation, validation)
- **Deployments** - Persistent workloads (e.g., controllers, agents)
- **Services** - Network endpoints (e.g., LoadBalancers, ClusterIP)
- **ConfigMaps/Secrets** - Configuration and credentials
- **Namespaces** - Resource isolation
- **Custom Resources** - Any Kubernetes API objects

**Trade-offs:**
- ✅ Fault isolation, native K8s features, better resource management, declarative
- ❌ Additional latency (resource creation overhead), more complex state tracking

**Alternative Rejected:** In-process execution
- Adapter would need to implement all workload logic, harder resource limits, failures crash adapter, no Kubernetes orchestration benefits

---

## 3. Anemic Events Pattern

**Decision:** CloudEvents contain only minimal fields: `resource_type`, `resource_id`, `cluster_id`, `href`, and `generation`. Adapters fetch full data from HyperFleet API.

**Why:**
- **Single source of truth** - API database is authoritative
- **Minimal payload** - reduces broker message size and costs (~120 bytes vs ~10KB for full cluster)
- **Always fresh data** - no stale data from old events
- **Stable schema** - event schema never changes when cluster schema evolves
- **Essential identifiers** - Just enough data for routing, filtering, and API fetching
- **Parent-child relationships** - `cluster_id` links child resources (nodepools) to parent cluster
- **Version tracking** - `generation` enables stale event detection

**Event Structure (snake_case):**
```json
{
  "resource_type": "clusters",
  "resource_id": "cls-123",
  "cluster_id": "cls-123",
  "href": "/api/hyperfleet/v1/clusters/cls-123",
  "generation": "5"
}
```

**Example: NodePool Event (Child Resource)**
```json
{
  "resource_type": "nodepools",
  "resource_id": "np-456",
  "cluster_id": "cls-123",         // Parent cluster ID
  "href": "/api/hyperfleet/v1/clusters/cls-qe3/nodepools/np-456",
  "generation": "2"
}
```

**Field Usage:**
- `resource_id` - Unique ID of the resource itself (snake_case)
- `resource_type` - Resource kind (clusters, nodepools, etc.) (snake_case)
- `cluster_id` - For clusters: same as resource_id; For nodepools: parent cluster ID (snake_case)
- `href` - Direct API endpoint to fetch full resource data
- `generation` - Resource version for detecting stale events

**Naming Convention:**
- Events and API responses use **snake_case** for field names
- Kubernetes standard fields remain unchanged (metadata.name, status.phase)

**Trade-offs:**
- ✅ Single source of truth, minimal payload, always fresh, stable schema
- ❌ Additional API call per event (latency ~50-100ms), increased API load

**Alternative Rejected:** Full cluster data in events
- Large payloads (10KB+ vs ~120 bytes), stale data risk, schema coupling, higher broker costs

---

## 4. Condition-Based Status Reporting

**Decision:** Adapters report three required conditions (Applied, Available, Health) with status/reason/message.

**Why:**
- **Rich state information** - three dimensions vs binary success/failure
- **Kubernetes-style pattern** - familiar to operators, industry standard
- **Aggregation support** - API aggregates conditions to cluster phase
- **Better debugging** - detailed reason and message fields

**Trade-offs:**
- ✅ Rich state, better debugging, supports dependencies, progressive updates
- ❌ More complex than simple success/failure, requires understanding semantics

**Alternative Rejected:** Simple success/failure boolean
- Too simplistic, can't distinguish states, no detailed diagnostics, no dependency support

**Implementation:**
```yaml
adapter: "example-adapter"  # Adapter name for tracking
conditions:                  # Array of condition objects
  - type: "Applied"          # Resources created/configured
  - type: "Available"        # Workload ready/operational  
  - type: "Health"           # No degradation/errors
data: {}                     # Optional adapter-specific data
observed_generation: 5       # Event generation that was processed
observed_time: "..."         # Timestamp when status was reported
```

**Status Fields:**
- `adapter` - Required: adapter name for tracking which adapter reported status
- `conditions` - Required: array of condition objects (Applied, Available, Health)
- `data` - Optional: adapter-specific data
- `observed_generation` - Event generation processed (for idempotency)
- `observed_time` - When adapter observed this resource state

---

## 5. Adapters POST Status Updates

**Decision:** Adapters POST status updates directly to HyperFleet API without checking if status exists first.

**Why:**
- **Simple flow** - single API call per status update
- **API handles create-or-update** - server-side logic determines if creating or updating
- **Idempotent** - same POST multiple times produces same result
- **Less latency** - no GET call before POST
- **Stateless adapter** - adapter doesn't need to track if status exists

**Implementation:**
```
POST /api/hyperfleet/v1/clusters/{clusterId}/statuses
{
  "adapter": "validation",
  "observed_generation": 1,
  "observed_time": "2025-01-01T10:00:00Z",
  "conditions": [ ... ],
  "data": { ... }
}
```

**Trade-offs:**
- ✅ Simple, single API call, less latency, idempotent, stateless
- ❌ API must handle create-or-update logic server-side

**Alternative Rejected:** GET then POST/PATCH (upsert pattern)
- Two API calls instead of one, more latency, adapter must track status existence

---

## 6. Helm-Based Deployment

**Decision:** Use Helm charts for templating and deploying adapters, not raw YAML.

**Why:**
- **Consistent with HyperFleet architecture** - umbrella chart pattern
- **Templating power** - values files for environment-specific config
- **Lifecycle management** - rollback, upgrades, validation
- **ConfigMap generation** - templates generate ConfigMaps, not manual YAML
- **Reusability** - same chart across dev/staging/prod

**Trade-offs:**
- ✅ Templating, lifecycle management, consistency, reusability
- ❌ Learning curve for Helm, additional tool dependency

**Alternative Rejected:** Raw Kubernetes YAML + Kustomize
- Less powerful templating, no built-in rollback, ConfigMaps must be manually maintained

**Structure:**
```
hyperfleet-adapter/           # Component chart
  templates/
    deployment.yaml
    configmap.yaml
    rbac.yaml
  values.yaml                 # Defaults
  values-dev.yaml             # Dev overrides
  values-prod.yaml            # Prod overrides

hyperfleet-umbrella/          # Umbrella chart
  charts/
    hyperfleet-adapter/
```

---

## 7. Layered Configuration Architecture

**Decision:** Use multiple ConfigMaps for different concerns rather than a single monolithic configuration per adapter.

**Why:**
- **Separation of concerns** - each ConfigMap has a single responsibility
- **Shared configuration** - environment and observability settings shared across adapters
- **Independent updates** - update broker config without touching adapter logic
- **Environment-specific** - different settings per environment (dev/staging/prod)
- **Reduced duplication** - API URLs and observability settings defined once

**Configuration Layers:**

1. **Adapter Logic ConfigMap** (per adapter) - Event filters, resources, post-processing
   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: validation-adapter-config
   data:
     adapter-config.yaml: |
       # Adapter-specific logic (preconditions, resources, post-processing)
   ```

2. **Broker ConfigMap** (per environment) - Message broker connection settings
   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: hyperfleet-broker-config
   data:
     BROKER_TYPE: "pubsub"
     BROKER_PROJECT_ID: "my-project"
     BROKER_SUBSCRIPTION_ID: "hyperfleet-events"
   ```

3. **Environment ConfigMap** (per environment) - API URLs and basic settings
   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: hyperfleet-environment
   data:
     ENVIRONMENT: "production"
     HYPERFLEET_API_BASE_URL: "http://hyperfleet-api:8080"
     HYPERFLEET_API_VERSION: "v1"
   ```

4. **Observability ConfigMap** (per environment) - Logging, metrics, tracing
   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: adapter-observability
   data:
     LOG_LEVEL: "info"
     METRICS_ENABLED: "true"
     METRICS_PORT: "9090"
     TRACE_ENABLED: "true"
     TRACE_SAMPLE_RATE: "0.1"
   ```

5. **Deployment env vars** (per adapter) - Adapter-specific overrides
   ```yaml
   env:
     - name: SUBSCRIPTION_NAME
       value: "validation-adapter-sub"
   ```

6. **Secrets** (per environment) - Sensitive data
   ```yaml
   env:
     - name: HYPERFLEET_API_TOKEN
       valueFrom:
         secretKeyRef:
           name: hyperfleet-api-token
           key: token
   ```

**Trade-offs:**
- ✅ Separation of concerns, reduced duplication, shared configuration, environment-specific
- ❌ More ConfigMaps to manage, need to understand layering

**Alternative Rejected:** Single monolithic ConfigMap per adapter
- Configuration duplication across adapters, harder to update shared settings, tight coupling

---

## 8. CEL Expression Language

**Decision:** Use CEL (Common Expression Language) instead of Expr for all expression evaluation in adapter configurations.

**Why:**
- **Kubernetes standard** - CEL is used in Kubernetes for validation rules, admission control
- **Industry adoption** - Google's standard expression language, used across many projects
- **Type safety** - Strong type checking prevents runtime errors
- **Rich built-ins** - Comprehensive standard library (has(), size(), filter(), map(), etc.)
- **Null safety** - Built-in null-safe operators and functions
- **Better tooling** - IDE support, validation tools, documentation

**Template Design Philosophy:**

The adapter configuration uses a **dual-syntax approach**:

1. **Go Templates (`{{ .var }}`)** - Variable interpolation throughout
   - Example: `"{{ .hyperfleetApiBaseUrl }}/api/{{ .clusterId }}"`

2. **`field` (Simple Path)** - For straightforward JSON path extraction
   - Example: `field: "status.phase"`
   - Internally translated to CEL by the adapter
   - More readable for common cases

3. **`expression` (CEL)** - For complex logic, filtering, transformations
   - Example: `expression: "status.adapters.filter(a, a.name == 'validation')[0].installed"`

**Condition Syntax:**

Both `field` and `expression` are supported in `when` conditions:

**Option 1: Expression Syntax (CEL)**
```yaml
when:
  expression: |
    clusterPhase == "Terminating"
```

**Option 2: Structured Conditions**
```yaml
when:
  conditions:
    - field: "clusterPhase"
      operator: "equals"
      value: "Terminating"
```

**Supported operators:** equals, notEquals, in, notIn, contains, exists, greaterThan, lessThan

**Trade-offs:**
- ✅ Kubernetes alignment, type safety, rich features, better tooling
- ❌ Learning curve for CEL syntax, more verbose than simple expressions

**Alternative Rejected:** Expr (Go expression language)
- Not Kubernetes-standard, less tooling support, less industry adoption

---

## 9. Performance vs Simplicity

**Decision:** Prioritize simplicity and correctness for MVP. Optimize later when needed.

**MVP Design Choices:**
- **Always fetch fresh data** from API (no caching)
- **Evaluate all conditions** every time (no short-circuiting)
- **Synchronous job monitoring** (poll job status)
- **Simple retry logic** (exponential backoff)
- **No distributed locking** (rely on idempotency)

**Why:**
- Simplicity reduces bugs and makes codebase easier to understand
- Premature optimization adds complexity without proven need
- MVP can handle expected load (10-100 events/min)
- Optimize when metrics show bottlenecks

**Trade-offs:**
- ✅ Simple, correct, maintainable, easier to debug
- ❌ Higher API load, more latency, not optimized for high throughput

**Performance Optimizations (Post-MVP):**
- Resource state caching (TTL-based)
- Asynchronous job monitoring (watch API)
- Batch status updates
- Connection pooling

---

## 10. Scalability

### MVP Limitations

**Current Design:**
- Synchronous event processing (one event at a time per adapter)
- No distributed coordination

**Known Bottlenecks:**
- API client (sequential API calls in preconditions)
- Kubernetes client (sequential resource creation - no parallel execution)
- Job monitoring (polling-based)
- Message broker (single consumer)

---

## 11. Future Enhancements

**Security & Authentication:**
- Service Account token authentication for API calls
- External Secrets Operator integration

**Reliability & Performance:**
- Enhanced retry logic (circuit breaker, jitter)
- Resource state caching (TTL-based)
- Batch processing
- Connection pooling

**Resource Management:**
- Resource updates (not just create)
- Resource deletion handling
- Resource lifecycle management

**Event Handling:**
- Topic-based event routing
- Event ordering guarantees
- Webhook-based event delivery

**Observability:**
- OpenTelemetry distributed tracing
- Prometheus metrics enhancements
- Advanced metrics
- Structured logging enhancements (see [Logging Specification](../../../standards/logging-specification.md))

**Deployment & Operations:**
- ArgoCD/Flux GitOps integration
- Helm values schema validation
- Multi-environment configuration management

**Extensibility:**
- Multi-cloud support (AWS, Azure)
- Advanced expression language features
- Custom resource type support

