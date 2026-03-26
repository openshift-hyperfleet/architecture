---
Status: Deprecated
Owner: HyperFleet Adapter Team
Last Updated: 2026-01-27
---

# Maestro Integration Spike


## Overview

Documents the original strategy for integrating adapters with Maestro via the Maestro CLI. Deprecated — the CLI-based integration approach was replaced by the Maestro SDK integration. See `adapter/maestro-integration/` for the current approach.

Maestro is a system that leverages CloudEvents to transport Kubernetes resources to target clusters and return status updates. This spike document provides comprehensive information for integrating HyperFleet with Maestro.

| | |
|---|---|
| **Repository** | https://github.com/openshift-online/maestro |
| **Container Image** | `quay.io/redhat-user-workloads/maestro-rhtap-tenant/maestro/maestro@sha256:062efc1b4a78e45c714f1925528443d49201acd0c7ce447c20e60706138550ec` |
| **Reference Doc** | [Maestro Service Architecture](https://docs.google.com/document/d/1wHTDIFIonfyVYlJcOBXz8jW4s7xVWtm3UFBZGcB7oiE/edit?tab=t.0#heading=h.r9mskro39h4i) |

---

## Integration Strategy for HyperFleet

### Recommended Approach: Job-Based maestro-CLI

**Pattern**: Adapters create Kubernetes Jobs with maestro-cli binary that handles resource operations.

### Broker Choice: gRPC Mode
- Minimal infrastructure overhead
- Better performance for HyperFleet's use cases
- Integrated with server deployment
- Easier certificate management

### Resource ManifestWork Strategy: One ManifestWork Per Adapter Per Cluster

**Chosen Approach**: One ManifestWork per adapter per cluster
- **One ManifestWork per adapter per cluster** to avoid race conditions
- **Independent adapter operations** with no coordination needed
- **Landing Zone tracks multiple ManifestWork names** per cluster for each adapter

### Multi-Cluster Naming Strategy

**Naming Convention**: `hyperfleet-{cluster-name}-{adapter-type}`

**Example multi-cluster resource organization:**
```
cluster-west-1 (consumer):
├── hyperfleet-cluster-west-1-namespace   (Landing Zone decides name)
├── hyperfleet-cluster-west-1-nodepool    (Nodepool Adapter decides name)
├── hyperfleet-cluster-west-1-idp         (IDP Adapter decides name)
└── hyperfleet-cluster-west-1-ingress     (Ingress Adapter decides name)

cluster-east-2 (consumer):
├── hyperfleet-cluster-east-2-namespace   (Landing Zone decides name)
├── hyperfleet-cluster-east-2-nodepool    (Nodepool Adapter decides name)
├── hyperfleet-cluster-east-2-idp         (IDP Adapter decides name)
└── hyperfleet-cluster-east-2-ingress     (Ingress Adapter decides name)
```

**Example ManifestWork mapping:**
```go
// ManifestWork for cluster-west-1
workv1.ManifestWork{
    ObjectMeta: metav1.ObjectMeta{
        Name:      "hyperfleet-cluster-west-1-nodepool",  // Cluster name first
        Namespace: "cluster-west-1",                      // Consumer (target cluster)
    },
    Spec: workv1.ManifestWorkSpec{
        Workload: workv1.ManifestsTemplate{
            Manifests: [...], // Kubernetes resources for nodepool
        },
    },
}
```

**Benefits of cluster-name-first pattern:**
- Resources for same cluster are grouped together when sorted
- Easy to identify all ManifestWorks for a specific cluster
- Clear association between ManifestWork name and target cluster

**Alternative Considered**: One ManifestWork Per Cluster (Rejected)
- **Single shared ManifestWork** containing all resources for the cluster
- **All adapters coordinate** to update the same ManifestWork
- **Simpler cluster deletion** - delete one ManifestWork cleans up entire cluster

**Why One ManifestWork Per Cluster Was Rejected**:

The one ManifestWork per cluster approach creates critical race conditions that lead to **resource loss**:

<details>
<summary>Race condition scenario that causes resource loss</summary>

```bash
# Initial shared ManifestWork: [namespace, configmap]
# Problem: Multiple adapters updating same ManifestWork concurrently

Timeline:
T1: Adapter A (nodepool) fetches ManifestWork → gets [namespace, configmap]
T2: Adapter B (IDP) fetches ManifestWork → gets [namespace, configmap]
T3: Adapter A adds nodepool → submits [namespace, configmap, nodepool] ✅ Success
T4: Adapter B adds IDP → submits [namespace, configmap, IDP] ✅ "Success" but OVERWRITES nodepool!

Result: nodepool resource is LOST even though both operations "succeeded"
```

**Root Cause**:
- maestro-cli requires **complete manifests** for apply operations
- Each adapter only knows about resources it manages
- Maestro version control prevents corruption but doesn't prevent resource loss
- "Successful" second update overwrites resources from first update

</details>

**Why One ManifestWork Per Adapter Per Cluster Eliminates This Problem**:
- Each adapter works with its own ManifestWork → no shared state to corrupt
- Concurrent operations are truly independent → no race conditions possible
- Resource loss impossible → adapters can't overwrite each other's resources

### Communication Pattern: Hybrid Approach
```bash
# Resource operations: Use gRPC (required)
maestro-cli apply --manifest-file=job.yaml --consumer=cluster-west-1     # gRPC - creates new ManifestWork
maestro-cli apply --manifest-file=job-updated.yaml --consumer=cluster-west-1  # gRPC - updates existing ManifestWork
maestro-cli delete --name=hyperfleet-cluster-west-1-job --consumer=cluster-west-1 --all  # gRPC - deletes ManifestWork

# Status monitoring: Use HTTP polling (simple and reliable)
maestro-cli wait --name=hyperfleet-cluster-west-1-job --consumer=cluster-west-1 --condition=Applied --watch  # HTTP polling
maestro-cli get --name=hyperfleet-cluster-west-1-job --consumer=cluster-west-1   # HTTP
maestro-cli list --consumer=cluster-west-1                               # HTTP
```

**Benefits:**
- ✅ **Simplicity**: No gRPC connection management for monitoring
- ✅ **Reliability**: HTTP polling works regardless of broker type
- ✅ **Safety**: No event consumption conflicts
- ✅ **Efficiency**: gRPC for operations, HTTP for monitoring

---

## Multi-Resource ManifestWork Strategies

### ARO HCP Pattern (Not recommended for HyperFleet)

**Approach**: Single ManifestWork per hosted cluster containing all customer-facing resources:

```yaml
# Main customer-facing ManifestWork
apiVersion: work.open-cluster-management.io/v1
kind: ManifestWork
metadata:
  name: aro-hcp-cluster-abc123  # One per hosted cluster
  namespace: management-cluster
spec:
  workload:
    manifests:
    - # Control plane resources
    - # Node pools
    - # Networking
    - # Ingress
    # ALL customer-facing resources in one ManifestWork
```

**Separate ManifestWork for secrets:**

```yaml
# Separate secret/readonly ManifestWork
apiVersion: work.open-cluster-management.io/v1
kind: ManifestWork
metadata:
  name: aro-hcp-secrets-abc123
spec:
  workload:
    manifests:
    - # Pull secrets
    - # Certificates
    - # Read-only configs
```

### HyperFleet Jobs Pattern (Component-based)

**Alternative**: Separate ManifestWorks per job component:

```yaml
# Option B: Separate ManifestWorks per job component
apiVersion: work.open-cluster-management.io/v1
kind: ManifestWork
metadata:
  name: hyperfleet-job-456
spec:
  workload:
    manifests:
    - # Job namespace
    - # Job configuration
    - # Kubernetes Job
    - # Optional service
```

### Pattern Comparison

| **Aspect** | **ARO HCP Pattern** | **HyperFleet Jobs Pattern** |
|------------|--------------------|-----------------------------|
| **Scope** | One ManifestWork per hosted cluster | One ManifestWork per job/component |
| **Granularity** | Cluster-level resources | Job-level resources |
| **ManifestWork Size** | Large (entire cluster) | Small to medium (per job) |
| **Update Impact** | Updates entire cluster state | Updates individual job only |
| **Resource Isolation** | Cluster-level isolation | Job-level isolation |
| **Status Tracking** | One status per hosted cluster | One status per job |

### When to Use Each Pattern

| **Choose ARO HCP Pattern When:** | **Choose HyperFleet Jobs Pattern When:** |
|-----------------------------------|------------------------------------------|
| • Managing entire hosted clusters | • Managing individual job workloads |
| • Need cluster-level atomicity | • Need job-level isolation |
| • Infrequent cluster-wide updates | • Frequent individual job updates |
| • Centralized cluster management | • Distributed job management |

---

## Implementation Details

### maestro-CLI Commands

```bash
# Core operations
maestro-cli apply --manifest-file=job.yaml --consumer=cluster-west-1 --watch --timeout=5m
maestro-cli apply --manifest-file=job-updated.yaml --consumer=cluster-west-1 --watch
maestro-cli delete --name=hyperfleet-cluster-west-1-job --consumer=cluster-west-1 --all --watch

# Status monitoring
maestro-cli get --name=hyperfleet-cluster-west-1-job --consumer=cluster-west-1
maestro-cli list --consumer=cluster-west-1 --status=Applied
maestro-cli wait --name=hyperfleet-cluster-west-1-job --consumer=cluster-west-1 --condition=Applied --timeout=10m
maestro-cli describe --name=hyperfleet-cluster-west-1-job --consumer=cluster-west-1

# Utilities
maestro-cli validate --manifest-file=job.yaml --consumer=cluster-west-1
maestro-cli diff --name=hyperfleet-cluster-west-1-job --consumer=cluster-west-1 --manifest-file=job.yaml
```

### Job Template for Adapters

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: maestro-handler-${event-id}
  namespace: hyperfleet-adapters
spec:
  template:
    spec:
      containers:
      - name: maestro-cli
        image: hyperfleet/maestro-cli:latest
        command: ["maestro-cli", "apply"]
        args:
        - --manifest-file=/config/manifest.yaml
        - --consumer=${target-cluster}
        - --watch
        - --timeout=5m
        - --grpc-endpoint=maestro-grpc:8090
        volumeMounts:
        - name: manifest-config
          mountPath: /config
      restartPolicy: Never
```

**Status Reporting:**
- Handled by existing [HyperFleet status-reporter](https://github.com/openshift-hyperfleet/status-reporter)
- No custom sidecar container needed
- Status-reporter monitors job completion and updates HyperFleet components

---

## Deployment Requirements

### Infrastructure Components

| Component | Required | Version |
|-----------|----------|---------|
| PostgreSQL Database | ✅ | 17.2+ |
| Maestro Server (with gRPC broker) | ✅ | - |
| Maestro Agents (per target cluster) | ✅ | - |

**Note:** HyperFleet uses gRPC broker mode (integrated with Maestro Server). No separate message broker infrastructure required.

### gRPC Mode Configuration

```yaml
# Agent configuration
grpc-server: maestro-grpc-broker.maestro:8091
grpc-server-ca-file: /path/to/ca.crt
grpc-client-cert-file: /path/to/client.crt
grpc-client-key-file: /path/to/client.key
```

---

## Security Considerations

### Network Security
- **TLS encryption** for all communications
- **mTLS** for agent authentication
- **Network policies** to restrict access

### Authentication Strategy
```yaml
# HTTP API: JWT for monitoring/management (optional)
Authorization: Bearer <jwt-token>

# gRPC: mTLS for ManifestWork operations
grpc-client-cert-file: /path/to/hyperfleet-client.crt
grpc-client-key-file: /path/to/hyperfleet-client.key
grpc-server-ca-file: /path/to/maestro-ca.crt
```

---

## Next Steps

| # | Action | Description |
|---|--------|-------------|
| 1 | Environment Setup | Deploy Maestro in test environment with gRPC mode |
| 2 | Authentication | Implement certificate management for mTLS |
| 3 | maestro-cli | Implement maestro-cli for ManifestWork operations |
| 4 | Resource Templates | Create HyperFleet-specific ManifestWork templates |
| 5 | Agent Deployment | Deploy Maestro agents on target clusters |
| 6 | Integration Testing | Validate end-to-end resource delivery |
| 7 | Production Deployment | Plan production rollout with proper security and monitoring |

---

## Job-Based Integration Pattern

### Kubernetes Job Template

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: maestro-handler-${event-id}
  namespace: hyperfleet-adapters
  labels:
    hyperfleet.io/component: "maestro-handler"
    hyperfleet.io/event-id: "${event-id}"
spec:
  template:
    spec:
      containers:
      # Main maestro-cli container
      - name: maestro-cli
        image: hyperfleet/maestro-cli:latest
        command: ["maestro-cli", "apply"]
        args:
        - --manifest-file=/config/manifest.yaml
        - --consumer=${target-cluster}
        - --watch
        - --timeout=5m
        - --grpc-endpoint=maestro-grpc:8090
        - --http-endpoint=maestro-http:8000
        - --results-path=/shared/results.json   # Override env var if needed
        env:
        - name: EVENT_ID
          value: "${sentinel-event-id}"
        - name: RESULTS_PATH
          value: "/shared/results.json"
        volumeMounts:
        - name: shared-status
          mountPath: /shared
        - name: manifest-config
          mountPath: /config
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 256Mi

      # Status reporting handled by existing status-reporter component
      # See: https://github.com/openshift-hyperfleet/status-reporter

      volumes:
      - name: shared-status
        emptyDir: {}
      - name: manifest-config
        configMap:
          name: ${manifest-config-name}

      restartPolicy: Never
  backoffLimit: 3
```

### Status Reporting Integration

**Status reporting is handled by the existing HyperFleet status-reporter component.**

See: https://github.com/openshift-hyperfleet/status-reporter

**Integration points:**
- **maestro-cli** writes status to `RESULTS_PATH` environment variable location
- **status-reporter** monitors job status and updates HyperFleet components
- **No custom sidecar needed** - leverages existing infrastructure

**Status Output Format:**
```go
type StatusResult struct {
    ManifestWorkName string            `json:"manifestWorkName"`
    Consumer        string            `json:"consumer"`
    Status          string            `json:"status"`           // Applied, Failed, InProgress
    Message         string            `json:"message"`
    Timestamp       time.Time         `json:"timestamp"`
    Resources       []ResourceStatus  `json:"resources,omitempty"`
}

func writeStatusResult(status StatusResult, flags *MaestroCLIFlags) error {
    resultsPath := getResultsPath(flags)
    if resultsPath == "" {
        return nil // No results output requested
    }

    data, _ := json.Marshal(status)
    return os.WriteFile(resultsPath, data, 0644)
}

func getResultsPath(flags *MaestroCLIFlags) string {
    // Priority: flag > env var > default
    if flags.ResultsPath != "" {
        return flags.ResultsPath
    }

    if envPath := os.Getenv("RESULTS_PATH"); envPath != "" {
        return envPath
    }

    return ""
}
```

**Status Flow:**
```
maestro-cli (writes RESULTS_PATH) → status-reporter (reads RESULTS_PATH) → HyperFleet status updates
```

---

## Landing Zone Integration

### Adapter Usage Pattern

**Landing Zone is already implemented.** Following adapters simply need to create Kubernetes Jobs with maestro-cli to deploy resources to target clusters' namespace created by LandingZone adapter.

### Adapter Integration Steps

1. **Independent ManifestWork Creation**: Each adapter creates its own Kubernetes Job with `maestro-cli apply` to establish its resources on agent cluster (creates new ManifestWork per adapter)
2. **Report ManifestWork Name**: Each job writes its ManifestWork name to $RESULTS_PATH, and adapter reports ManifestWork name back to cluster spec status data
3. **No Cross-Adapter Coordination**: Each adapter manages only its own ManifestWork, eliminating race conditions between adapters

### ManifestWork Name Tracking

**ManifestWork name flow:**
```
Each Adapter define name rule → K8s Job (maestro-cli apply) → Maestro → Creates ManifestWork with semantic name → Stored in Adapter's status data
```

**Usage by adapters:**
- **Each adapter**: Uses `maestro-cli apply` to create its own ManifestWork with semantic naming
- **Subsequent updates**: Each adapter uses `maestro-cli apply` with the same manifest file for updates
- **ManifestWork name** is stored in each adapter's status data for independent tracking

---

## Race Condition Handling

### Concurrent ManifestWork Updates

**Scenario**: Multiple adapters updating the same ManifestWork simultaneously (e.g., customer updates control plane and node pool at the same time).

**Maestro Protection**: Maestro server and agent provide version control and conflict resolution for ManifestWork resources.

**maestro-cli Role**: Simple client that submits requests - does not handle race conditions or retries.

### Version Control Mechanism

**Maestro handles version control internally:**
- Maestro server maintains ManifestWork resource versions
- Concurrent updates are detected and resolved by Maestro
- Version conflicts result in error responses to clients
- Successful updates increment ManifestWork version

**maestro-cli behavior:**
- Submits gRPC request to Maestro
- Returns success/failure based on Maestro response
- No retry logic or conflict resolution in CLI

### Race Condition Scenarios

| **Scenario** | **Maestro Behavior** | **maestro-cli Behavior** |
|--------------|----------------------|---------------------------|
| **Simultaneous Updates** | Version conflict detection, one succeeds | Reports success or failure (no retries) |
| **Control Plane + Node Pool** | Serializes updates, maintains consistency | Simple submit and report result |
| **Multiple Adapter Jobs** | Version control prevents lost updates | Jobs succeed or fail independently |

### Critical Race Condition: Resource Loss

**Problem Scenario**: When multiple adapters update the same ManifestWork concurrently without coordination:

```bash
# Initial ManifestWork contains: [namespace, configmap]
# T1: Adapter A (nodepool) fetches ManifestWork → gets [namespace, configmap]
# T2: Adapter B (IDP) fetches ManifestWork → gets [namespace, configmap]
# T3: Adapter A adds nodepool → submits [namespace, configmap, nodepool] ✅ Success
# T4: Adapter B adds IDP → submits [namespace, configmap, IDP] ❌ OVERWRITES, loses nodepool!

# Result: nodepool resource is lost even though both operations "succeeded"
```

**Root Cause**:
- maestro-cli requires **complete manifests** in apply operations
- Each adapter only knows about resources it manages
- No coordination mechanism between concurrent adapter jobs
- Maestro version control prevents corruption but doesn't prevent resource loss

### Version Conflict vs Resource Loss

**Version Conflict (Handled by Maestro)**:
```bash
# Same version scenario - Maestro rejects the second update
# T1: Adapter A fetches ManifestWork (version: v1)
# T2: Adapter B fetches ManifestWork (version: v1)
# T3: Adapter A submits update (v1 → v2) ✅ Success
# T4: Adapter B submits update (still v1) ❌ Version conflict - REJECTED
```

**Resource Loss (NOT prevented)**:
```bash
# Different timing - both updates "succeed" but resources are lost
# T1: Adapter A fetches ManifestWork (version: v1) → [resource1]
# T2: Adapter A adds resource2 → submits [resource1, resource2] (v1 → v2) ✅
# T3: Adapter B fetches ManifestWork (version: v2) → [resource1, resource2]
# T4: Adapter B adds resource3 → submits [resource1, resource3] (v2 → v3) ✅
# Result: resource2 is LOST
```

### Safety Guarantees

- **No lost updates**: Version conflicts prevent overwriting concurrent changes
- **Eventual consistency**: Failed operations retry with latest ManifestWork state
- **Complete ManifestWork state**: Each update includes full desired state
- **Agent-level protection**: Maestro agent enforces version control

### HyperFleet Solution: Eliminate Race Conditions

**HyperFleet uses One ManifestWork Per Resource Per Cluster(pattern B)** to completely eliminate race conditions:

```bash
# Each resource gets its own ManifestWork - maximum isolation
Landing Zone        → ManifestWork: hyperfleet-cluster123-namespace
PullSecret Adapter  → ManifestWork: hyperfleet-cluster123-pullsecret
Ingress Adapter     → ManifestWork: hyperfleet-cluster123-ingress
Nodepool Adapter    → ManifestWork: cluster123-nodepool-workers
Nodepool Adapter    → ManifestWork: cluster123-nodepool-gpu
Nodepool Adapter    → ManifestWork: cluster123-nodepool-storage
```

**Benefits**:
- ✅ **Completely eliminates race conditions** - no shared state anywhere
- ✅ **No fetching required** - each resource is independent
- ✅ **True parallel execution** - concurrent nodepool operations safe
- ✅ **Simple implementation** - direct apply without coordination
- ✅ **Independent resource lifecycle** - scale/update nodepools independently
- ✅ **Fine-grained status tracking** - per-resource status visibility

**Trade-offs**:
- ❌ **More ManifestWorks to manage** - many ManifestWorks per cluster
- ❌ **Higher operational overhead** - tracking multiple resources
- ❌ **Less atomic cluster operations** - can't update related resources together

### ManifestWork Granularity Patterns

#### Pattern A: One ManifestWork Per Adapter Per Cluster
```bash
# Each adapter manages its own ManifestWork - requires --name for updates
Nodepool: maestro-cli apply --name=hyperfleet-cluster-1-nodepool --manifest-file=nodepool.yaml --consumer=cluster-1
          # Creates/updates ManifestWork: hyperfleet-cluster-1-nodepool
IDP:      maestro-cli apply --name=hyperfleet-cluster-1-idp --manifest-file=idp.yaml --consumer=cluster-1
          # Creates/updates ManifestWork: hyperfleet-cluster-1-idp
Ingress:  maestro-cli apply --name=hyperfleet-cluster-1-ingress --manifest-file=ingress.yaml --consumer=cluster-1
          # Creates/updates ManifestWork: hyperfleet-cluster-1-ingress
```

#### Pattern B: One ManifestWork Per Resource Per Cluster (Recommended for HyperFleet)
```bash
# Each resource gets its own ManifestWork - maximum granularity
Nodepool-1: maestro-cli apply --name=cluster-1-nodepool-workers --manifest-file=nodepool-1.yaml --consumer=cluster-1
            # Creates/updates ManifestWork: cluster-1-nodepool-workers
Nodepool-2: maestro-cli apply --name=cluster-1-nodepool-gpu --manifest-file=nodepool-2.yaml --consumer=cluster-1
            # Creates/updates ManifestWork: cluster-1-nodepool-gpu
PullSecret:        maestro-cli apply --name=cluster-1-pullsecret --manifest-file=idp.yaml --consumer=cluster-1
            # Creates/updates ManifestWork: cluster-1-idp
Ingress:    maestro-cli apply --name=cluster-1-ingress --manifest-file=ingress.yaml --consumer=cluster-1
            # Creates/updates ManifestWork: cluster-1-ingress
```

#### Pattern C: One ManifestWork Per Cluster (Future - maybe with framework integration)
```bash
# Single shared ManifestWork per cluster - all adapters coordinate
All:        maestro-cli apply --name=hyperfleet-cluster-1 --manifest-file=cluster-1-complete.yaml --consumer=cluster-1
            # Creates/updates ManifestWork: hyperfleet-cluster-1
            # Contains: namespace, nodepool, idp, ingress - ALL resources
```

**Note:** This pattern requires in-process coordination to avoid race conditions. Not recommended for job-based approach, but may become viable with framework integration.

### ManifestWork Granularity Patterns Comparison

| **Pattern** | **Benefits** | **Disadvantages** | **Best For** |
|-------------|--------------|------------------|---------------|
| **Pattern A: Per Adapter Per Cluster** | ✅ No race conditions<br>✅ Simple implementation<br>✅ Clear ownership<br>✅ Easy status tracking | ❌ Multiple ManifestWorks to track<br>❌ Less atomic operations | **Recommended** - Different adapter types |
| **Pattern B: Per Resource Per Cluster** | ✅ Maximum granularity<br>✅ Independent resource lifecycle<br>✅ Parallel nodepool operations<br>✅ Fine-grained status tracking | ❌ Many ManifestWorks to manage<br>❌ Complex coordination<br>❌ Higher operational overhead | Multiple nodepools per cluster |
| **Pattern C: Per Cluster** | ✅ Single ManifestWork per cluster<br>✅ Atomic cluster operations<br>✅ Simple deletion (one ManifestWork) | ❌ Race conditions between adapters<br>❌ Resource loss risk<br>❌ Requires coordination | Future - with framework integration |

### Recommended Approach for HyperFleet

**Use Pattern A (One ManifestWork Per Adapter Per Cluster)** when:
- **Each adapter manages single resources** (one namespace, one IDP config, one ingress)
- **Adapter operations are infrequent**
- **Simpler ManifestWork tracking** is preferred over performance

**Limitations of Pattern A**:
- ⚠️ **Still requires fetching** if adapter manages multiple resources (e.g., multiple nodepools)
- ⚠️ **Race conditions possible** within same adapter (concurrent nodepool operations)
- ⚠️ **Must use `maestro-cli build`** to fetch and merge existing resources

**Use Pattern B (Per Resource Per Cluster)** when:
- **Multiple nodepools** need independent lifecycle management
- **Parallel nodepool scaling** is critical for performance
- **True parallel operations** needed (no fetching/coordination required)
- **High-frequency resource operations**

**Benefits of Pattern B for Multi-Nodepool Scenarios**:
- ✅ **No fetching needed** - each resource is independent
- ✅ **True parallel execution** - no coordination between nodepool operations
- ✅ **Eliminates race conditions entirely** - no shared state even within adapter

---

## Future: Adapter Framework Integration

**Current State (MVP):** Job-based maestro-cli approach - each adapter creates Kubernetes Jobs to run maestro-cli commands.

**Future State:** Direct adapter framework integration with Maestro client libraries for higher performance scenarios.

### When to Consider Framework Integration

| Scenario | Job-Based (Current) | Framework Integration (Future) |
|----------|---------------------|-------------------------------|
| **Operation Frequency** | Low to medium | High frequency operations |
| **Latency Requirements** | Seconds acceptable | Sub-second required |
| **Resource Efficiency** | Job startup overhead (~2-5s) | Persistent process, minimal overhead |
| **Complexity** | Simple, isolated jobs | More complex, shared state management |
| **Scaling** | Horizontal via more jobs | Connection pooling, batching |

### Framework Integration Considerations

**Framework integration would involve:**
1. **Direct WorkClient integration** - Embed `grpcsource.NewMaestroGRPCSourceWorkClient` in adapter process
2. **Connection pooling** - Reuse gRPC connections across operations
3. **Subscribe to broker/stream** - Listen for ManifestWork status events from Maestro
4. **Event-driven status updates** - On receiving events, either:
   - Publish events to Sentinel for downstream processing, or
   - Update cluster status directly via HyperFleet API
5. **Sentinel optimization** - No longer need to send health check events without new generation; status updates are event-driven from Maestro stream
6. **ManifestWork pattern reconsideration** - With persistent adapter process (vs isolated jobs), race condition scenarios differ; shared ManifestWork patterns may become viable with proper in-process coordination
7. **Event filtering per adapter** - Each adapter needs to identify and handle only relevant events (e.g., Nodepool Adapter should acknowledge cluster-level events without processing them). Alternative: consolidate multiple adapters into a unified adapter that handles all resource types for a cluster

### Migration Path

**Framework Migration:**
1. **Phase 1 (Current):** Job-based maestro-cli for all adapters
2. **Phase 2:** Identify high-frequency adapters that need optimization
3. **Phase 3:** Integrate Maestro client library directly into specific adapters
4. **Phase 4:** Evaluate deprecating job-based approach for optimized adapters

**ManifestWork Pattern Migration (Pattern A/B → Pattern C):**

If transitioning existing clusters from per-adapter ManifestWorks to shared per-cluster ManifestWork:

1. **Inventory existing ManifestWorks** - List all ManifestWorks per cluster (namespace, nodepool, pullsecret, ingress, etc.)
2. **Create consolidated ManifestWork** - Build new shared ManifestWork containing all resources
3. **Apply consolidated ManifestWork** - Deploy the new shared ManifestWork to cluster
4. **Delete old ManifestWorks** - Remove individual adapter ManifestWorks after verification
5. **Update adapter configuration** - Point adapters to use shared ManifestWork name

**Migration considerations:**
- Requires coordination window to avoid race conditions during transition
- Rollback plan: Keep old ManifestWorks until new pattern is verified
- Status tracking: Update cluster status to reference new ManifestWork name

**Decision criteria for framework migration:**
- Job startup overhead > 50% of total operation time
- Operation frequency > 10 ops/minute per adapter
- Latency SLA < 1 second

---

## Conclusion

Maestro provides a robust, scalable solution for multi-cluster Kubernetes resource management that aligns well with HyperFleet's needs.

**Key takeaways:**
1. **Use gRPC mode** for broker communication (recommended for HyperFleet)
2. **HTTP API is read-only** for monitoring and consumer management
3. **gRPC is required** for ManifestWork lifecycle operations (create, update, delete)
4. **Job-based maestro-cli** provides optimal balance of simplicity and functionality
5. **Hybrid communication pattern** (gRPC for operations, HTTP for monitoring) offers best reliability
