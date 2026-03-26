---
Status: Active
Owner: HyperFleet Adapter Team
Last Updated: 2026-02-12
---

# SPIKE: Maestro Client Integration for HyperFleet Adapter Framework

---

## Table of Contents

1. [Overview](#overview)
2. [Current State](#current-state)
3. [Problem Statement](#problem-statement)
4. [Proposed Solution: Maestro Transport Integration](#proposed-solution-maestro-transport-integration)
5. [Design Details](#design-details)
   - [1. Updated DSL Structure](#1-updated-dsl-structure)
   - [2. Authentication Configuration](#2-authentication-configuration)
   - [3. Implementation Components](#3-implementation-components)
   - [4. Status Handling & Reporting Cycle](#4-status-handling--reporting-cycle-adaptation)
   - [5. Error Handling & Edge Cases](#5-error-handling--edge-cases)
   - [6. Deployment Configuration](#6-deployment-configuration)
6. [Implementation Strategy](#implementation-strategy)
7. [Risks & Mitigations](#risks--mitigations)
8. [Success Criteria](#success-criteria)
9. [Alternative Approaches](#alternative-approaches)
   - a) [Ultra-High-Volume Watch Processing](#alternative-approach-a)
   - b) [Sentinel-Only Polling - SELECTED](#alternative-approach-b)
   - c) [Bidirectional Event-Driven Architecture](#alternative-approach-c)

---

## Overview

This SPIKE document outlines the integration of Maestro client capabilities into the HyperFleet Adapter Framework to enable remote cluster resource management through CloudEvents transportation. The integration will allow adapters to create and manage Kubernetes resources on remote clusters via the Maestro server infrastructure.

## Current State

### Existing Adapter Framework Architecture
- **CloudEvent Processing**: Adapters consume CloudEvents from Sentinel every 30 minutes (this is configurable when deploy Sentinel) when clusters are ready
- **Direct K8s API**: Current adapters directly manage resources on local/accessible clusters
- **Status Reporting**: Adapters report status back to HyperFleet API via HTTP REST calls
- **DSL-Based Configuration**: Declarative YAML configuration drives adapter behavior

### Resource Reporting Cadence
- **Pre-Ready Polling**: Sentinel posts CloudEvents every 10 seconds before cluster becomes ready
- **Ready Polling**: Sentinel posts CloudEvents every 30 minutes when cluster is ready
- **Implications**: Status updates frequency depends on cluster readiness state

## Problem Statement

While remote clusters could be accessed via kubeconfig, for ARO-HCP and similar architectures, using Maestro transport provides significant advantages:

1. **Security**: No need to distribute and manage kubeconfig credentials for remote clusters
2. **Push-based efficiency**: Maestro pushes changes to agents instead of adapters polling remote clusters
3. **Centralized management**: ManifestWork provides a unified way to manage resources across multiple clusters
4. **Maintain adapter execution model** with minimal changes to existing DSL
5. **Work within reporting cycles** imposed by Sentinel (10s pre-ready, 30min ready)

## Proposed Solution: Maestro Transport Integration

### High-Level Architecture

```text
┌─────────────────┐     ┌─────────────────┐     ┌──────────────────-┐
│   Sentinel      │────▶│ HyperFleet      │────▶│ Deployment Cluster│
│   (CloudEvents) │     │ Adapter         │     │ (via k8s API)     │
│   Every 30min   │     │                 │     │                   │
└─────────────────┘     └─────────────────┘     └──────────────────-┘
                                │
                                ▼
                        ┌─────────────────┐     ┌──────────────────┐
                        │ Maestro Server  │────▶│ Maestro Agent    │
                        │ (CloudEvents)   │     │ (Remote Cluster) │
                        └─────────────────┘     └──────────────────┘
```

### Integration Components

#### 1. Maestro Client Integration
- **Maestro gRPC Source Client**: Create/Update/Delete ManifestWorks
- **Maestro Watch Client**: Monitor resource status changes
- **Connection Management**: Handle gRPC connections and reconnection logic

#### 2. Transport Abstraction Layer
- **Transport Interface**: Abstract transport (Direct K8s API vs Maestro)
- **Maestro Transport Implementation**: Wrap Maestro client operations
- **Resource Conversion**: Transform DSL resources to ManifestWork format

#### 3. Authentication & Configuration
- **Maestro Auth Config**: gRPC endpoints, certificates, authentication tokens
- **Consumer Identity**: Cluster identity for Maestro subscription targeting

## Design Details

### 1. Updated DSL Structure

#### Deployment Configuration (adapter-deployment-config-template.yaml)

Infrastructure settings for Maestro connection. This section is **OPTIONAL** - only configure when maestro transport is used in business logic.

> **See full example:** [`hyperfleet-adapter/charts/examples/maestro/adapter-config.yaml`](https://github.com/openshift-hyperfleet/hyperfleet-adapter/blob/main/charts/examples/maestro/adapter-config.yaml)

#### Business Logic Configuration (adapter-business-logic-template-MVP.yaml)

Per-resource transport configuration with `targetCluster` resolved from captured params.

> **See full example:** [`hyperfleet-adapter/charts/examples/maestro/adapter-task-config.yaml`](https://github.com/openshift-hyperfleet/hyperfleet-adapter/blob/main/charts/examples/maestro/adapter-task-config.yaml)

#### Key Design Decisions

| Aspect | Location | Notes |
|--------|----------|-------|
| Manifest format | Business logic config | Same K8s manifest format for both `kubernetes` and `maestro` transport |
| Generation management | Both transports | Same behavior: check annotation generation, apply update when generation differs |
| Maestro server connection | Deployment config | Static infrastructure settings (grpcServerAddress, httpServerAddress) |
| Authentication (TLS) | Deployment config | Managed via Helm/secrets, supports insecure mode for development |
| consumerName/targetCluster | Business logic config | Dynamic, resolved from precondition captures |
| Transport client per resource | Business logic config | `client: "kubernetes"` or `client: "maestro"` per resource |
| sourceId / clientId | Deployment config | Unique identifiers for CloudEvents routing |
| nestedDiscoveries | Business logic config | Discover sub-resources within ManifestWork for status access |

### 2. Authentication Configuration

#### TLS Certificate-Based Authentication (mTLS)
Authentication is handled via TLS client certificates. Configuration includes:

- **CA Certificate**: Server certificate authority for verification
- **Client Certificate**: Client certificate for mutual TLS authentication
- **Private Key**: Client private key corresponding to certificate
- **Server Name**: Server hostname for TLS verification

Connection settings include timeouts, keepalive parameters, and retry configuration.

### 3. Implementation Components

#### Transport Interface
```go
// Transport defines the unified interface for resource operations
// Implemented by both DirectTransport (K8s API) and MaestroTransport (CloudEvents)
type Transport interface {
    // Create or update a resource
    Apply(ctx context.Context, resource *Resource) (*Resource, error)

    // Get current resource (full object with status)
    Get(ctx context.Context, resource *Resource) (*Resource, error)

    // Delete a resource
    Delete(ctx context.Context, resource *Resource) error

    // List resources via filter
    List(ctx context.Context, options ListOptions) ([]*Resource, error)
}

// Resource represents a full Kubernetes resource with metadata, spec, and status
type Resource struct {
    Name      string
    Namespace string
    Object    *unstructured.Unstructured  // Full K8s object (apiVersion, kind, metadata, spec, status)
    Transport TransportMeta
}

// TransportMeta contains transport-specific information
type TransportMeta struct {
    Client           string  // "kubernetes" or "maestro"
    TargetCluster    string  // For Maestro: consumer name
    ManifestWorkName string  // For Maestro: ManifestWork name
}

// ListOptions for both K8s and Maestro list operations
type ListOptions struct {
    TargetCluster string  // For Maestro: consumer name (target cluster)
    LabelSelector string
    FieldSelector string
    Limit         int64
}

// DirectTransport implements Transport for direct K8s API access
type DirectTransport struct {
    client    dynamic.Interface
    discovery discovery.DiscoveryInterface
    mapper    meta.RESTMapper
}

// MaestroTransport implements Transport for Maestro CloudEvents transport
type MaestroTransport struct {
    client   workv1client.WorkV1Interface
    watcher  watch.Interface
    config   *MaestroConfig
    sourceID string
}
```

#### Maestro Client Wrapper
```go
// MaestroClientManager handles Maestro client connections and ManifestWork operations
type MaestroClientManager struct {
    client   workv1client.WorkV1Interface
    config   *MaestroConfig
    watchers map[string]watch.Interface
    mu       sync.RWMutex
}

// Methods:
// - CreateManifestWork(ctx, consumerName, resource) (*workv1.ManifestWork, error)
// - GetManifestWork(ctx, consumerName, workName) (*workv1.ManifestWork, error)
// - DeleteManifestWork(ctx, consumerName, workName) error
// - WatchManifestWorkStatus(ctx, consumerName) (watch.Interface, error)
```

### 4. Status Handling & Reporting Cycle Adaptation

#### Unified Status Access

The transport layer abstracts status retrieval - business logic accesses resource status regardless of transport type. The framework handles:

- **Kubernetes transport**: Status from K8s API response directly via `resources.?resourceName.?status...`
- **Maestro transport**: Status extracted from ManifestWork via `nestedDiscoveries`

#### Nested Discoveries for ManifestWork

For Maestro transport, use `nestedDiscoveries` to access sub-resource status within a ManifestWork:

```yaml
resources:
  - name: "agentNamespaceManifestWork"
    transport:
      client: "maestro"
    # ...
    nestedDiscoveries:
      - name: "mgmtNamespace"
        discovery:
          bySelectors:
            labelSelector:
              hyperfleet.io/resource-type: "namespace"
```

Status is then accessed via: `resources.?agentNamespaceManifestWork.mgmtNamespace.?status.?phase.orValue("")`

> **See full example:** [`hyperfleet-adapter/charts/examples/maestro/adapter-task-config.yaml`](https://github.com/openshift-hyperfleet/hyperfleet-adapter/blob/main/charts/examples/maestro/adapter-task-config.yaml) (post section)

#### Reporting Cycle Considerations (Sentinel timer is configurable via deployment)
- **Pre-Ready (10s polling)**: More frequent status updates during cluster provisioning
- **Ready (30min polling)**: Standard reporting cadence once cluster is ready
- **Timeout handling**: Framework manages timeouts per transport type

### 5. Error Handling & Edge Cases

#### Connection Failures
- **Retry with backoff**: Configurable max retries and exponential backoff
- **Fallback mode**: Optional fallback to direct API if Maestro connection fails
- **Health checks**: Periodic connection health verification

#### Status Synchronization Issues
- **Partial ManifestWork failures**: Report degraded status with specific failure reasons
- **Late status updates**: Extend timeout for next cycle if critical resources are pending
- **Lost CloudEvents**: Implement status reconciliation on next cycle

### 6. Deployment Configuration

#### Configuration Approach

Maestro transport settings are configured in `AdapterConfig` (see `adapter-deployment-config-template.yaml`), not a separate ConfigMap. This provides:
- Single source of truth for adapter configuration
- CRD schema validation
- Helm values override support

#### Required Secret Mounts

TLS certificates must still be mounted from Kubernetes Secrets:

```yaml
spec:
  containers:
  - name: adapter
    volumeMounts:
    - name: maestro-certs
      mountPath: /etc/maestro/certs
      readOnly: true
  volumes:
  - name: maestro-certs
    secret:
      secretName: maestro-client-certs
```

#### Secret Structure
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: maestro-client-certs
  namespace: hyperfleet-system
type: Opaque
data:
  ca.crt: <base64-encoded-ca-cert>
  hyperfleet-client.crt: <base64-encoded-client-cert>
  hyperfleet-client.key: <base64-encoded-client-key>
```

## Implementation Strategy

### Phase 1: Transport Abstraction
1. **Create Transport Interface**: Define abstraction layer for resource operations (Apply, Get, Delete, List)
2. **Implement DirectTransport**: Wrap K8s dynamic client to implement Transport interface
3. **K8s Client Setup**: Configure K8s client with kubeconfig or service account authentication

### Phase 2: Maestro Transport Implementation
1. **Maestro Client Integration**: Implement MaestroTransport with gRPC client
2. **Configuration Extension**: Add maestro section to adapter DSL
3. **Authentication Handling**: Implement TLS-based authentication
4. **Status Mapping**: Convert ManifestWork status to adapter status

### Phase 3: Config Loader and Executor Implementation
1. **Config Loader**: Parse and validate AdapterConfig and business logic YAML
2. **Resource Executor**: Execute resource operations based on business logic config
3. **Transport Selection**: Route operations to DirectTransport or MaestroTransport based on config
4. **Status Builder**: Build status payloads from CEL expressions in config

### Phase 4: Example Implementation & Helm Integration
1. **Example Adapter**: Implement reference adapter using Maestro transport
2. **Business Logic Example**: Create sample business logic config with maestro resources and nestedDiscoveries
3. **Helm Charts Update**: Add Maestro configuration options to adapter Helm charts
4. **Secret Management**: Helm templates for Maestro TLS certificates

## Risks & Mitigations

### Technical Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| **Maestro Connection Failures** | Medium - Unable to manage remote resources | Retry with backoff, connection health monitoring |
| **ManifestWork Status Delays** | Low - Late status reporting | Sentinel timer syncs on next polling cycle |
| **Resource Conversion Errors** | Medium - Failed resource creation | Same K8s manifest format for both transports, validation at config load |
| **Reporting Cycle Timing** | Low - Status update latency for customers | Pre-ready 10s polling minimizes latency during provisioning; 30min acceptable when cluster is stable |
| **Traceability Gap** | Medium - Hard to trace resource full cycle | Maestro lacks OTel trace_id/span_id support; use resource labels and adapter logs for correlation |

### Operational Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| **Maestro Server Downtime** | High - Complete adapter failure | Multi-region Maestro deployment, circuit breaker pattern |
| **CloudEvent Message Loss** | Low - Missed status updates | Maestro has built-in event management; Sentinel timer syncs status on next polling cycle |
| **Resource Drift** | Medium - Inconsistent cluster state | Implement drift detection, reconciliation cycles |

## Success Criteria

### Functional Requirements
- ✅ **Remote Resource Management**: Successfully create/update/delete resources on remote clusters
- ✅ **Status Reporting**: Accurate status reporting within 30-minute windows
- ✅ **Authentication**: Secure connection to Maestro infrastructure
- ✅ **Backward Compatibility**: Existing adapters continue working without changes
- ✅ **Error Handling**: Graceful failure handling and recovery

### Operational Requirements
- ✅ **Deployment**: Simple configuration and deployment process
- ✅ **Monitoring**: Comprehensive metrics and health checks
- ✅ **Troubleshooting**: Clear error messages and debugging capabilities
- ✅ **Documentation**: Complete development and operational documentation

## Alternative Approaches

<a id="alternative-approach-a"></a>

### Alternative Approach a) Ultra-High-Volume Watch Processing

#### Purpose
This approach aims to resolve status updating latency by continuously watching ManifestWork status changes for a period of time, providing near real-time status updates instead of waiting for Sentinel polling cycles.

#### How It Works
- Keep a Watch connection open to Maestro for ManifestWork status changes
- Process status updates as they arrive rather than polling
- Report status immediately when changes are detected

#### Why We Don't Recommend This Approach

| Concern | Impact |
|---------|--------|
| **Goroutine Management Complexity** | Multiple goroutines for watch, processing, and reporting require careful lifecycle management |
| **Resource Cost** | Long-lived connections and continuous processing consume significant memory and CPU |
| **Framework Instability** | Complex concurrency patterns increase risk of goroutine leaks, deadlocks, and race conditions |
| **Traceability Gap** | Status updates from Maestro broker are not correlated with Sentinel events, making it hard to trace the full request lifecycle |
| **Insufficient CloudEvent Parameters** | Maestro CloudEvents don't contain enough parameters to build payloads; can use ManifestWork labels as workaround, but further implementation needed if more parameters introduced |
| **Diminishing Returns** | Pre-ready 10s polling already provides acceptable latency during provisioning |

#### Recommendation
Use the standard polling-based approach with Sentinel timer:
- **Pre-ready (10s polling)**: Acceptable latency during cluster provisioning
- **Ready (30min polling)**: Sufficient for stable clusters
- **Simpler architecture**: No goroutine management complexity
- **Predictable resource usage**: No long-lived watch connections
- **Better traceability**: All operations triggered by Sentinel events, easier to trace full lifecycle

<a id="alternative-approach-b"></a>

### Alternative Approach b) Sentinel-Only Polling - SELECTED

#### Purpose
Only subscribe to Sentinel events for triggering resource operations and status updates. No Maestro broker watching - status updates are fully controlled by Sentinel polling cycles.

#### How It Works
```text
Sentinel Event → Adapter → Apply Resources via Maestro → Get Status via Maestro → Report to HyperFleet API
```

- **Single event source**: Only Sentinel CloudEvents trigger adapter execution
- **Polling-based status**: Status fetched from Maestro when Sentinel triggers, not pushed
- **Same pattern as K8s**: Follows same logic as direct K8s client - apply and get status on demand

#### Why We Recommend This Approach

| Benefit | Description |
|---------|-------------|
| **Simplicity** | Single goroutine per broker subscription, no complex watch management |
| **Traceability** | All operations tied to Sentinel events, easy to trace full request lifecycle |
| **Consistency** | Same execution pattern for both kubernetes and maestro transports |
| **Predictable** | No background processes, resource usage scales with Sentinel polling rate |

#### Trade-off

| Concern | Impact | Mitigation |
|---------|--------|------------|
| **Status Update Latency** | Customers see status updates only when Sentinel polls | Pre-ready 10s polling minimizes latency during provisioning; 30min acceptable for stable clusters |

#### Why We Selected This Approach

This option is the **simplest solution that will work for MVP**. It keeps the system straightforward:

- **Centralized decision making**: Decisions on when to report status to API are taken at the Sentinel
- **Reactive adapters**: Adapters are reactive only to Sentinel pulses, no autonomous background processing
- **Flexible polling frequency**: Sentinel can increase the frequency of pulses for Ready clusters if required
- **Future extensibility**: Changes to more frequent updates (real-time from Maestro) will be considered after MVP

<a id="alternative-approach-c"></a>

### Alternative Approach c) Bidirectional Event-Driven Architecture

#### Purpose
Create a fully event-driven system where adapters only process events and publish status back through broker infrastructure, with Sentinel handling all HyperFleet API calls.

#### How It Works
```text
Maestro Events → Adapter (Event Processor) → HyperFleet Broker → Sentinel → HyperFleet API
```

- **Adapter**: Pure event transformer, no direct API calls
- **Broker**: Central event hub for status distribution
- **Sentinel**: Centralized API client for HyperFleet

#### Why We Don't Recommend This Approach

| Concern | Impact |
|---------|--------|
| **Infrastructure Complexity** | Requires additional broker infrastructure and topic management |
| **Increased Latency** | Multiple event hops add latency to status reporting |
| **Event Ordering Challenges** | Maintaining event order across distributed components is complex |
| **Operational Overhead** | More components to monitor, debug, and maintain |
| **Over-Engineering** | Current scale doesn't justify this level of decoupling |
