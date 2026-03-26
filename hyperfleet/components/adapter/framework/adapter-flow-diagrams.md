---
Status: Active
Owner: HyperFleet Adapter Team
Last Updated: 2026-03-20
---

# HyperFleet Reconciliation Flow

## Overview

This document provides visual diagrams to help understand the reconciliation flow in HyperFleet v2.

## Table of Contents
1. [Complete System Overview](#complete-system-overview)
2. [Adapter Lifecycle Sequence](#adapter-lifecycle-sequence)
3. [Event Flow Detail](#event-flow-detail)

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
            A->>API: GET /api/hyperfleet/v1/clusters/cls-123/statuses

            alt ClusterStatus exists (200 OK)
                A->>API: PATCH /statuses/{statusId}<br/>Applied=False, Available=False, Health=True
            else ClusterStatus not found (404)
                A->>API: POST /statuses<br/>Applied=False, Available=False, Health=True
            end

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
                A->>API: GET /api/hyperfleet/v1/clusters/cls-123/statuses

                alt ClusterStatus exists (200 OK)
                    A->>API: PATCH /statuses/{statusId}<br/>Applied=True, Available=False, Health=True
                else ClusterStatus not found (404)
                    A->>API: POST /statuses<br/>Applied=True, Available=False, Health=True
                end

                API-->>A: Status updated
                A->>B: Acknowledge message

            else Resources already exist
                Note over A: Check postconditions
                K-->>A: Resource status

                alt Postconditions NOT met (workload in progress)
                    Note over A: Workload still running
                    A->>API: GET /api/hyperfleet/v1/clusters/cls-123/statuses

                    alt ClusterStatus exists (200 OK)
                        A->>API: PATCH /statuses/{statusId}<br/>Applied=True, Available=False, Health=True
                    else ClusterStatus not found (404)
                        A->>API: POST /statuses<br/>Applied=True, Available=False, Health=True
                    end

                    API-->>A: Status updated
                    A->>B: Acknowledge message

                else Postconditions MET
                    alt Workload Succeeded
                        Note over A: Aggregate conditions
                        A->>A: Available=True (all conditions True)
                        A->>API: PATCH /statuses/{statusId}<br/>Available=True, Applied=True, Health=True
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
                        A->>API: PATCH /statuses/{statusId}<br/>Available=False, Applied=True, Health=True
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
        Sub1 --> Parse1[Parse: resourceId = cls-123]
        Parse1 --> Fetch1[GET /clusters/cls-123]
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
- Adapters POST status updates to HyperFleet API
- API handles create-or-update logic server-side
- Idempotent: same POST multiple times = same result
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
- API aggregates all adapter Available statuses to determine cluster phase

### Reconciliation Loop
1. Sentinel continuously polls HyperFleet API (every 5 seconds)
2. For each cluster, Sentinel checks `status.phase` (Ready vs Not Ready)
3. Sentinel applies max age interval based on phase (10s for Not Ready, 30m for Ready)
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
