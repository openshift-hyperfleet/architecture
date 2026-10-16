---
Status: Active
Owner: HyperFleet Adapter Team
Last Updated: 2026-10-16
---

# HyperFleet Reconciliation Flow

## Overview

This document provides visual diagrams to help understand the reconciliation flow in HyperFleet v2.

## Table of Contents

1. [Complete System Overview](#complete-system-overview)
2. [Adapter Lifecycle Sequence](#adapter-lifecycle-sequence)
3. [Event Flow Detail](#event-flow-detail)
4. [Deletion Flow](#deletion-flow)

---

## Complete System Overview

This diagram shows how all components work together in the HyperFleet v2 architecture:

```mermaid
flowchart TB
    User[User Creates Cluster] -->|POST /api/hyperfleet/v1/clusters| API[HyperFleet API]
    API -->|Stores in| DB[(PostgreSQL Database)]

    Sentinel[Sentinel Operator] -->|Polls every 5s| API
    Sentinel -->|Evaluates conditions| Decision{Requires Event?}

    Decision -->|Yes| Publish[Publish CloudEvent<br/>resourceType: clusters<br/>resourceId: cls-123]
    Decision -->|No| Skip[Skip - Check next poll]

    Publish -->|Fanout| Broker[Message Broker<br/>RabbitMQ / GCP Pub/Sub]

    Broker -->|Subscribe| ValAdapter[Validation Adapter]
    Broker -->|Subscribe| DNSAdapter[DNS Adapter]
    Broker -->|Subscribe| PlaceAdapter[Placement Adapter]
    Broker -->|Subscribe| HSAdapter[HyperShift Adapter]

    ValAdapter --> GetCluster1[GET /api/hyperfleet/v1/clusters/cls-123]
    GetCluster1 --> API

    ValAdapter --> Criteria{Preconditions Met?}
    Criteria -->|No| ReportNotApplied[Report Status:<br/>Applied=False<br/>Available=False<br/>Health=True]
    Criteria -->|Yes| CheckResources{Resources Exist?}

    CheckResources -->|No| CreateResources[Create Kubernetes Resources]
    CheckResources -->|Yes| CheckPostconditions[Check Postconditions]

    CreateResources --> ReportApplied[Report Status:<br/>Applied=True<br/>Available=False<br/>Health=True]

    CheckPostconditions --> PostconditionsMet{Postconditions<br/>Met?}
    PostconditionsMet -->|No| ReportInProgress[Report Status:<br/>Applied=True<br/>Available=False<br/>Health=True]
    PostconditionsMet -->|Yes| DetermineResult{Workload<br/>Success?}
    DetermineResult -->|Success| ReportSuccess[Report Status:<br/>Available=True<br/>Applied=True<br/>Health=True]
    DetermineResult -->|Failure| ReportFailure[Report Status:<br/>Available=False<br/>Applied=True<br/>Health=True]

    ReportNotApplied --> API
    ReportApplied --> API
    ReportInProgress --> API
    ReportSuccess --> API
    ReportFailure --> API

    DetermineResult --> CheckResourceMgmt{Resource<br/>Management<br/>Cleanup?}
    CheckResourceMgmt -->|Yes| CleanupResources[Delete Kubernetes Resources]
    CheckResourceMgmt -->|No| SkipCleanup[Keep Resources]

    API -->|Updates| DB

    style User fill:#e1f5e1
    style API fill:#fff4e1
    style Broker fill:#ffd4a3
    style ValAdapter fill:#e1e5ff
    style DNSAdapter fill:#e1e5ff
    style PlaceAdapter fill:#e1e5ff
    style HSAdapter fill:#e1e5ff
```

---

## Adapter Lifecycle Sequence

This sequence diagram shows the detailed interactions between components for a single adapter processing an event:

```mermaid
sequenceDiagram
    participant S as Sentinel Operator
    participant API as HyperFleet API
    participant B as Message Broker
    participant A as Adapter Service
    participant K as Kubernetes API
    participant W as Workload Pods

    Note over S: Reconciliation Loop (every 5s)

    S->>API: GET /api/hyperfleet/v1/clusters?labels=shard
    API-->>S: List of clusters

    Note over S: For each cluster:<br/>Evaluate message_decision<br/>params + result

    S->>S: Evaluate: message_decision params + result

    alt Requires event
        S->>B: Publish CloudEvent<br/>{resourceType: "clusters", resourceId: "cls-123"}
        Note over B: Fanout to all adapter subscriptions

        B->>A: Deliver CloudEvent

        Note over A: Parse anemic event
        A->>A: Extract resourceId from event.data

        A->>API: GET /api/hyperfleet/v1/clusters/cls-123
        API-->>A: Full cluster object (spec + status)

        Note over A: Evaluate preconditions from config
        A->>A: Check preconditions (spec.provider == gcp)
        A->>A: Check dependencies (validation adapter Available)

        alt Preconditions NOT met
            A->>A: Log skip reason (debug)

            Note over A: Report status - not applied
            A->>API: PUT /statuses<br/>Applied=False, Available=False, Health=True

            API-->>A: Status updated
            A->>B: Acknowledge message
        else Preconditions MET
            Note over A: Check if resources exist
            A->>K: GET resources (e.g., Deployment, StatefulSet)

            alt Resources do NOT exist
                Note over A: Create Kubernetes resources
                A->>K: POST resources (rendered templates + cluster data)
                K-->>A: Resources created

                Note over A: Report status - resources created
                A->>API: PUT /statuses<br/>Applied=True, Available=False, Health=True

                API-->>A: Status updated
                A->>B: Acknowledge message

            else Resources already exist
                Note over A: Check postconditions
                K-->>A: Resource status

                alt Postconditions NOT met (workload in progress)
                    Note over A: Workload still running
                    A->>API: PUT /statuses<br/>Applied=True, Available=False, Health=True

                    API-->>A: Status updated
                    A->>B: Acknowledge message

                else Postconditions MET
                    alt Workload Succeeded
                        Note over A: Aggregate conditions
                        A->>A: Available=True (all conditions True)
                        A->>API: PUT /statuses<br/>Applied=True, Available=False, Health=True
                        API-->>A: Status updated

                        Note over A: Check resource management
                        A->>A: Cleanup enabled?

                        alt Cleanup enabled
                            A->>K: DELETE resources
                        end

                        A->>B: Acknowledge message

                    else Workload Failed
                        Note over A: Aggregate conditions
                        A->>A: Available=False (workload failed)
                        A->>API: PUT /statuses<br/>Applied=True, Available=False, Health=True
                        API-->>A: Status updated

                        Note over A: Check resource management
                        A->>A: Cleanup enabled?

                        alt Cleanup enabled
                            A->>K: DELETE resources
                        end

                        A->>B: Acknowledge message
                    end
                end
            end
        end
    else Does NOT require event
        Note over S: Skip cluster - log debug
    end

    Note over S: Continue to next cluster
```

---

## Event Flow Detail

This diagram focuses specifically on the event publishing and consumption flow:

```mermaid
flowchart LR
    subgraph Sentinel[Sentinel Decision]
        SC[Fetch Cluster<br/>from API] --> Check{Requires<br/>Event?}
        Check -->|Yes| Create[Create CloudEvent]
        Check -->|No| Skip[Skip]

        Create --> Event["CloudEvent:<br/>{<br/>  type: cluster.reconcile,<br/>  source: sentinel,<br/>  data: {<br/>    resourceType: clusters,<br/>    resourceId: cls-123,<br/>    clusterId: cls-123,<br/>    href: /api/v1/clusters/cls-123,<br/>    generation: 5,<br/>    region: us-east-1<br/>  }<br/>}"]
    end

    Event -->|Publish| Broker[Message Broker<br/>Topic: hyperfleet-events]

    subgraph Adapters[Adapter Subscriptions]
        Broker -->|Fanout| Sub1[Validation<br/>Subscription]
        Broker -->|Fanout| Sub2[DNS<br/>Subscription]
        Broker -->|Fanout| Sub3[Placement<br/>Subscription]
        Broker -->|Fanout| Sub4[HyperShift<br/>Subscription]
    end

    subgraph Processing[Event Processing]
        Sub1 --> Parse1[Parse: resourceId from event]
        Parse1 --> Fetch1[GET event.href]
        Fetch1 --> Eval1[Evaluate Preconditions]
        Eval1 --> Action1{Preconditions<br/>Met?}
        Action1 -->|Yes| CheckResources1{Resources<br/>Exist?}
        Action1 -->|No| ReportNotApplied1[Report Applied=False]
        CheckResources1 -->|No| CreateResources1[Create Resources]
        CheckResources1 -->|Yes| Monitor1[Check Postconditions]
        CreateResources1 --> ReportApplied1[Report Applied=True]
    end

    style Event fill:#ffd4a3
    style Broker fill:#ffe1e1
    style CreateResources1 fill:#e1f5e1
```

---

## Key Takeaways

### Anemic Events Pattern

- Events contain **only** minimal fields: `resourceType`, `resourceId`, `clusterId`, `href`, `generation`, `region`
- Adapters **always** fetch full resource data from API using `href` or constructing endpoint from `resourceType`/`resourceId`
- Single source of truth: HyperFleet API database
- `generation` enables stale event detection
- `clusterId` enables parent-child relationships (e.g., nodepools → cluster)

### Status Upsert Pattern

- Adapters PUT status updates to HyperFleet API
- API handles create-or-update logic server-side
- Idempotent: same PUT multiple times = same result
- Prevents race conditions between adapters

### Status Reporting Pattern

- **Preconditions NOT met**: Report `Applied=False, Available=False, Health=True`
  - Adapter cannot act on this cluster yet (dependencies not satisfied)
- **Resources created**: Report `Applied=True, Available=False, Health=True`
  - Adapter has applied its intent (created Kubernetes resources), but outcome not yet known
- **Workload in progress** (postconditions not met): Report `Applied=True, Available=False, Health=True`
  - Resources are running, postconditions haven't been satisfied yet
- **Workload succeeded** (postconditions met): Report `Applied=True, Available=True, Health=True`
  - Adapter successfully completed its work, all postconditions satisfied
- **Workload failed** (postconditions met): Report `Applied=True, Available=False, Health=True`
  - Adapter applied intent but workload failed, postconditions indicate failure
- **Adapter error**: Report `Applied=False, Available=False, Health=False`
  - Adapter encountered an internal error and cannot perform its work (e.g., can't connect to Kubernetes API, configuration error, timeout)

### Condition Aggregation

- Each adapter reports 3 required conditions: Available, Applied, Health
- Adapters can add custom conditions (e.g., ValidationPassed, DNSRecordsCreated)
- Adapter aggregates ALL its conditions to determine Available status
- API aggregates all adapter statuses to determine cluster `Reconciled` condition

### Reconciliation Loop

1. Sentinel continuously polls HyperFleet API (every 5 seconds)
2. For each cluster, Sentinel checks `Reconciled` condition (`Reconciled=True` vs `Reconciled=False`)
3. Sentinel applies max age interval based on `Reconciled` status (10s for Not Reconciled, 30m for Reconciled)
4. When cluster requires event (max age period passed), Sentinel publishes CloudEvent to broker
5. Adapters receive events, fetch cluster, evaluate preconditions
6. If preconditions met: check if resources exist, create if needed, check postconditions, report status
7. Loop continues - Sentinel keeps polling and publishing events, adapters respond to each event

### Idempotency Pattern

- Adapters check if resources already exist before creating (GET by name/labels)
- Resource naming: `{adapter-name}-{clusterId-short}-gen{generation}`
- If resources exist: check postconditions to determine current state
- If resources don't exist: create new resources
- Handles adapter restarts and duplicate events gracefully
- Each event triggers a fresh evaluation of resource status

### Resource Management

- When workload completes (postconditions met, either success or failure), adapter checks resource management settings
- If cleanup enabled: Delete the created resources from Kubernetes (applies to both success and failure)
- If cleanup disabled: Keep the resources for debugging/auditing purposes
- Cleanup decision happens **after** reporting final status (success or failure)
- This prevents resource accumulation from completed workloads while allowing optional retention for troubleshooting

### Separation of Concerns

- **Sentinel**: Polling + Event publishing
- **Adapter Service**: Orchestration (event handling, precondition evaluation, resource management, status reporting)
- **Workload Pods**: Business logic (validation, DNS creation, cluster provisioning, etc.)

---

## Deletion Flow

For full design details, see [Adapter Deletion Flow Design (Draft)](./lifecycle/adapter-lifecycle-delete-design.md).

### End-to-End Deletion Sequence

```mermaid
sequenceDiagram
    actor User
    participant API as HyperFleet API
    participant DB as Database
    participant Sentinel
    participant Broker as Message Broker
    participant Adapter
    participant K8s as Kubernetes

    Note over User, K8s: Phase 1 - User Requests Deletion

    User->>API: DELETE /resources/{id}
    API->>DB: Mark resource for deletion (set deleted_time)
    API->>DB: Mark ALL subresources for deletion (set deleted_time)
    API->>API: Derive customer-facing state -> Finalizing
    API->>API: Increment generation (Reconciled=False)
    API-->>User: 202 Accepted

    Note over User, K8s: Phase 2 - Sentinel Detects & Publishes

    par Resource Sentinel (resource_type: resources)
        loop Every 5 seconds
            Sentinel->>API: GET /resources (poll)
            API-->>Sentinel: Resource list (includes Finalizing resources)
        end
        Sentinel->>Sentinel: Evaluate message_decision (CEL)
        Sentinel->>Broker: Publish CloudEvent (resource)
    and Subresource Sentinel (resource_type: subresources)
        loop Every 5 seconds
            Sentinel->>API: GET /subresources (poll)
            API-->>Sentinel: Subresource list (includes Finalizing subresources)
        end
        Sentinel->>Sentinel: Evaluate message_decision (CEL)
        Sentinel->>Broker: Publish CloudEvent (subresource)
    end

    Note over User, K8s: Phase 3 - Adapter Processes Deletion

    Broker->>Adapter: Deliver CloudEvent

    rect rgb(240, 248, 255)
        Note over Adapter: Parameter Extraction
        Adapter->>Adapter: Extract resource_id from event
    end

    rect rgb(255, 248, 240)
        Note over Adapter: Preconditions
        Adapter->>API: GET /resources/{id}
        API-->>Adapter: Resource object (deleted_time set)
        Adapter->>Adapter: Capture deleted_time, is_deleting
    end

    rect rgb(255, 240, 240)
        Note over Adapter: Resources Phase (per-resource lifecycle evaluation)
        Adapter->>Adapter: Evaluate lifecycle.delete.when.expression for each resource
        Adapter->>K8s: Discover clusterJob (expression: true)
        Adapter->>K8s: Delete clusterJob (Background)
        Note over Adapter: clusterConfigMap: expression false (clusterJob still exists), skip
        Note over Adapter: clusterNamespace: expression false, skip
        Note over Adapter: Next loop: clusterJob gone, clusterConfigMap expression becomes true
        Adapter->>K8s: Discover clusterConfigMap
        Adapter->>K8s: Delete clusterConfigMap (Background)
    end

    rect rgb(240, 255, 240)
        Note over Adapter: Post-Processing (always runs)
        Adapter->>Adapter: Evaluate conditions (CEL)
        Adapter->>API: PUT /resources/{id}/statuses (Applied=False)
    end

    Note over User, K8s: Phase 4 - API Aggregates & Deletes (Hierarchical)

    API->>API: Recompute subresource Reconciled from adapter Finalized statuses
    API->>API: Subresource Reconciled=True?
    API->>DB: Delete completed subresource records

    API->>API: Recompute resource Reconciled from adapter Finalized statuses
    API->>API: Resource Reconciled=True?
    API->>API: All subresource records deleted?
    API->>DB: Delete resource record
```

### Deletion Strategies

```mermaid
flowchart TD
    A[Resources Phase] --> B[For each resource]
    B --> C{lifecycle.delete defined?}
    C -->|no| CR[Normal Apply Flow]
    C -->|yes| D{when.expression true?}
    D -->|true| E[Discover resource by name/label]
    D -->|false| CR
    E --> T{Transport?}
    T -->|K8s| G["K8s DeleteResource(propagationPolicy)"]
    T -->|Remote| M["Write DeleteDesire to desire store"]

    CR --> H{More resources?}
    G --> H
    M --> H
    H -->|yes| B
    H -->|no| I[Post-Processing]
```

### DSL Changes for Deletion

```mermaid
graph LR
    subgraph "Existing DSL"
        P[parameters]
        PC[preconditions]
        R[resources]
        PP[postProcessing]
    end

    subgraph "New Addition (per resource)"
        LC["lifecycle.delete"]
        S["propagationPolicy:<br/>Background|Foreground|Orphan"]
        W["when.expression:<br/>CEL expression<br/>(deletion trigger + ordering)"]
    end

    LC --> S
    LC --> W
    LC -.->|"evaluated per resource<br/>in resources phase"| R

    style LC fill:#ff9,stroke:#333
    style S fill:#ff9,stroke:#333
    style W fill:#ff9,stroke:#333
```

### Executor Behavior with Deletion

```mermaid
flowchart TD
    A[Resources Phase] --> B[For each resource]
    B --> C{lifecycle.delete defined?}
    C -->|no| D[Apply Flow]
    C -->|yes| E{when.expression true?}
    E -->|true| F[Discover resource]
    E -->|false| D
    F --> T{Transport?}
    T -->|K8s| H["K8s DeleteResource(propagationPolicy)"]
    T -->|Remote| M["Write DeleteDesire to desire store"]

    D --> D1[Render manifest template]
    D1 --> D2[Check if resource exists]
    D2 --> D3{Exists?}
    D3 -->|yes| D4[Skip apply]
    D3 -->|no| D5[Create resource]

    D4 --> I[Next resource]
    D5 --> I
    H --> I
    M --> I
```

### API Delete Signal (Hierarchical)

```mermaid
flowchart TD
    A[DELETE /resources/id] --> B[Set deleted_time on resource]
    B --> B2[Set deleted_time on all subresources]
    B2 --> C[Derive customer-facing state -> Finalizing]
    C --> C2[Increment generation<br/>Reconciled=False]
    C2 --> D[Return 202 Accepted]

    D --> E1[Background: monitor subresource adapter statuses]
    E1 --> F1{Each subresource:<br/>Reconciled=True?}
    F1 -->|No| E1
    F1 -->|Yes| G1[Delete subresource records]

    G1 --> E2[Background: monitor resource adapter statuses]
    E2 --> F2{Resource Reconciled=True<br/>AND all subresources deleted?}
    F2 -->|No| E2
    F2 -->|Yes| G2[Delete resource record]
```

### Resource + Subresource Deletion Flow

```mermaid
sequenceDiagram
    actor User
    participant API
    participant Sentinel
    participant Sub_Adapter as Subresource Adapters
    participant Res_Adapter as Resource Adapters

    User->>API: DELETE /resources/{id}
    API->>API: Set deleted_time on resource
    API->>API: Set deleted_time on ALL subresources
    API-->>User: 202 Accepted

    par Subresource cleanup
        Sentinel->>Sub_Adapter: CloudEvent (subresource)
        Sub_Adapter->>Sub_Adapter: Capture deleted_time, evaluate lifecycle.delete
        Sub_Adapter->>Sub_Adapter: Clean up subresource resources (per-resource ordering)
        Sub_Adapter->>API: PUT status (Applied=False, Health=True, Finalized=True)
    and Resource cleanup (in parallel)
        Sentinel->>Res_Adapter: CloudEvent (resource)
        Res_Adapter->>Res_Adapter: Capture deleted_time, evaluate lifecycle.delete
        Res_Adapter->>Res_Adapter: Clean up resource resources (per-resource ordering)
        Res_Adapter->>API: PUT status (Applied=False, Health=True, Finalized=True)
    end

    API->>API: Subresource Reconciled=True?
    API->>API: Delete subresource records

    API->>API: Resource Reconciled=True?
    API->>API: All subresource records deleted? YES
    API->>API: Delete resource record
```

### Adapter Status Decision Matrix

| Applied | Available | Health | Finalized | Meaning | API Action |
|---------|-----------|--------|-----------|---------|------------|
| `Any` | `Any` | `Any` | `True` | Cleanup confirmed for this adapter | Contributes to deletion `Reconciled=True` |
| `Any` | `Any` | `Any` | `False` | Not finalized yet — adapter has not confirmed cleanup | **Wait** for retry/reconciliation |

If `deleted_time` is not set in an API resource, `Finalized` value is meaningless for computing `Reconciled`.

During deletion, `Available`, `Health`, and `Applied` are informational for operators and do not participate in hard-delete gating. The API gates on `Reconciled=True`.

All adapters participate in deletion `Reconciled`. Resource-owning adapters report `Finalized=True` after cleanup; non-resource-owning adapters report `Finalized=True` immediately. The API gates DB deletion on `deleted_time` set + `Reconciled=True`.

### Deletion Status Reporting Pattern

`Applied`, `Available`, and `Health` reflect real resource state — they are not deletion-aware. Only `Finalized` is deletion-specific.

- **Deletion in progress**: Resources still exist → `Applied`/`Available` reflect real state, `Health=True`, `Finalized=False`
- **Deletion complete**: Resources gone → `Applied=False`, `Available=False`, `Health=True`, `Finalized=True`
- **Deletion failed (can connect)**: Resources still exist → `Applied`/`Available` reflect real state, `Health=False` (error), `Finalized=False`
- **Adapter cannot connect**: Resource state unknown → `Applied=False`, `Available=False`, `Health=False`, `Finalized=False`
