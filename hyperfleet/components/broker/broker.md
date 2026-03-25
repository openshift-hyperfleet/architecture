# HyperFleet Message Broker

**Status**: Active
**Owner**: HyperFleet Architecture Team
**Last Updated**: 2026-03-25

> The HyperFleet Message Broker is the fan-out layer that decouples the Sentinel reconciliation service from the Adapter Deployments. Sentinel publishes a single CloudEvent per resource reconciliation cycle; the Broker delivers that event to every registered adapter subscription simultaneously, enabling independent parallel execution of provisioning tasks without Sentinel or adapters knowing about each other.

---

## What & Why

**What**: A message broker implementing the fan-out (publish/subscribe) pattern to distribute CloudEvent reconciliation events from the Sentinel service to multiple Adapter Deployments. The broker is accessed via a pluggable abstraction that supports GCP Pub/Sub, RabbitMQ, and an in-memory Stub for local development.

**Why**:

Without a broker, Sentinel would need to know about every adapter and call each one directly. This creates tight coupling: adding a new adapter requires changing Sentinel, and a slow adapter blocks others. The broker solves this by:

- **Decoupling**: Sentinel publishes to a single topic without knowing which adapters exist. Adapters subscribe without knowing about Sentinel or other adapters.
- **Fan-out**: One reconciliation event automatically triggers all registered adapters in parallel.
- **Independent scaling**: Each adapter subscription is consumed independently — a high-volume adapter doesn't affect others.
- **Reliability**: At-least-once delivery guarantees ensure events are not lost if an adapter is temporarily unavailable.
- **Extensibility**: New adapters are added by creating a new subscription — no code changes to Sentinel or existing adapters.

---

## How

### Topic and Subscription Model

```mermaid
graph LR
    S[Sentinel] -->|Publish CloudEvent| T[Topic<br/>hyperfleet.clusters.changed.v1]
    T -->|Fan-out| V[validation-adapter-sub]
    T -->|Fan-out| D[dns-adapter-sub]
    T -->|Fan-out| P[placement-adapter-sub]
    T -->|Fan-out| PS[pullsecret-adapter-sub]
    T -->|Fan-out| CP[hypershift-adapter-sub]
    V --> VA[Validation Adapter]
    D --> DA[DNS Adapter]
    P --> PA[Placement Adapter]
    PS --> PSA[Pull Secret Adapter]
    CP --> CPA[Control Plane Adapter]
```

Each adapter gets its own subscription to the shared topic, so every adapter receives every event independently. Adapters evaluate their own preconditions to decide whether to act on an event.

### CloudEvent Format

All events conform to the [CloudEvents 1.0](https://cloudevents.io/) specification:

```json
{
  "specversion": "1.0",
  "type": "com.redhat.hyperfleet.cluster.reconcile.v1",
  "source": "sentinel-operator/cluster-sentinel-us-east",
  "id": "evt-abc-123",
  "time": "2025-10-21T14:30:00Z",
  "datacontenttype": "application/json",
  "data": {
    "kind": "Cluster",
    "id": "cls-abc-123",
    "href": "/clusters/cls-abc-123",
    "generation": 1
  }
}
```

The event payload is intentionally minimal (anemic event pattern — see [Design Decisions](#design-decisions)). Adapters fetch full resource details from the API after receiving the event.

### Supported Broker Implementations

The broker library ([openshift-hyperfleet/hyperfleet-broker](https://github.com/openshift-hyperfleet/hyperfleet-broker)) is built on [Watermill](https://watermill.io/), a Go library providing a broker-agnostic pub/sub abstraction. Watermill handles the underlying transport; the HyperFleet broker library adds CloudEvents conversion, metrics, health checks, and a worker pool for parallel processing.

| Implementation | Broker Type Value | Environment | Notes |
|----------------|-------------------|-------------|-------|
| GCP Pub/Sub | `googlepubsub` | Production | Cloud-native, highly available, at-least-once delivery |
| RabbitMQ | `rabbitmq` | On-premise / self-hosted | AMQP-based, suitable for environments without GCP access |

The broker implementation is selected via the `broker.type` field in `broker.yaml`.

### Configuration

The library uses a YAML configuration file (`broker.yaml`). The path defaults to the executable directory but can be overridden with the `BROKER_CONFIG_FILE` environment variable. All fields support environment variable overrides using dot-notation (e.g., `BROKER_TYPE` overrides `broker.type`).

**Sentinel publisher configuration (`broker.yaml`):**

```yaml
broker:
  type: googlepubsub        # or "rabbitmq"
  googlepubsub:
    project_id: hyperfleet-prod
    # topic is passed at publish time via Publisher.Publish(ctx, topic, event)

subscriber:
  parallelism: 1            # number of concurrent message handlers per subscription
```

**Adapter subscriber configuration (`broker.yaml`):**

```yaml
broker:
  type: googlepubsub
  googlepubsub:
    project_id: hyperfleet-prod
    # subscription_id is passed at subscribe time via NewSubscriber(logger, subscriptionID, metrics)

subscriber:
  parallelism: 2            # increase for high-throughput adapters
```

### Event Flow

```mermaid
sequenceDiagram
    participant S as Sentinel
    participant B as Message Broker
    participant V as Validation Adapter
    participant D as DNS Adapter

    S->>B: Publish CloudEvent<br/>{id: cls-123, generation: 1}

    par Fan-out delivery
        B->>V: Deliver event (validation-adapter-sub)
        B->>D: Deliver event (dns-adapter-sub)
    end

    Note over V: Evaluate preconditions
    Note over D: Evaluate preconditions

    V->>B: ACK (preconditions met, job created)
    D->>B: ACK (preconditions not met, no action)
```

---

## Design Decisions

### Anemic Events (Minimal Payload)

**Decision**: Events contain only the resource ID, kind, href, and generation — not the full resource spec.

**Rationale**: Adapters always need fresh resource data when they act, so including full spec in the event creates a race condition (the spec may have changed between when the event was published and when the adapter processes it). The minimal event forces adapters to fetch current state from the API, ensuring they always act on authoritative data.

**Trade-off**: Adds one extra API call per adapter per event. Acceptable given that provisioning operations themselves take seconds to minutes.

### Fan-out via Subscriptions (Not Routing Keys)

**Decision**: All adapters receive all events via independent subscriptions to a single topic. Adapters evaluate their own preconditions to decide whether to act.

**Rationale**: Routing events to specific adapters at the broker level would require the broker or Sentinel to know which adapters exist and what they respond to. Adapter-side precondition evaluation keeps adapter logic self-contained and makes it trivial to add or remove adapters without touching the broker or Sentinel.

### Pluggable Broker Abstraction via Watermill

**Decision**: The broker library is built on [Watermill](https://watermill.io/) and exposes its own `Publisher` / `Subscriber` interfaces with CloudEvents as the first-class message type.

**Rationale**: HyperFleet must support GCP-managed environments (GCP Pub/Sub) and on-premise environments (RabbitMQ). Watermill provides the broker-agnostic transport layer, while the HyperFleet broker library adds CloudEvents conversion, metrics, health checks, and worker pool parallelism on top. Components program against the `Publisher` / `Subscriber` interfaces and are not coupled to either Watermill or the underlying broker backend.

### Worker Pool for Parallel Processing

**Decision**: The Subscriber supports a configurable `parallelism` setting that registers multiple concurrent Watermill handlers per subscription.

**Rationale**: High-throughput adapters may need to process multiple events concurrently. The default parallelism of 1 provides safe sequential processing; adapters can increase it via `subscriber.parallelism` in `broker.yaml` without any code changes.

---

## Trade-offs

### What We Gain

- ✅ **Decoupling**: Sentinel and Adapters have zero direct knowledge of each other
- ✅ **Extensibility**: New adapters are added with zero changes to Sentinel or existing adapters
- ✅ **Parallel execution**: All adapters receive events simultaneously and run in parallel
- ✅ **Independent scaling**: Each adapter subscription scales independently
- ✅ **At-least-once delivery**: Broker guarantees events are not permanently lost
- ✅ **Pluggability**: Same codebase works with GCP Pub/Sub, RabbitMQ, or Stub

### What We Lose / What Gets Harder

- ❌ **Exactly-once semantics**: At-least-once delivery means adapters can receive duplicate events. Adapters must be idempotent.
- ❌ **Ordering guarantees**: Events may be delivered out of order within a subscription. Adapters must tolerate out-of-order delivery.
- ⚠️ **Operational overhead**: Running a message broker is an additional infrastructure component to deploy, monitor, and maintain.
- ⚠️ **Debug complexity**: Tracing an event from Sentinel through the broker to each adapter requires distributed tracing tooling.

### Technical Debt Incurred

- **No dead-letter queue (DLQ) policy defined**: If an adapter consistently fails to process an event, it may be retried indefinitely. A DLQ with alert on accumulation should be defined post-MVP.
  - **Impact**: Low (adapters are designed to be idempotent; retries are expected)
  - **Remediation**: Define DLQ configuration and alerting threshold in broker setup

### Acceptable Because

- At-least-once delivery is sufficient: all adapters are designed to be idempotent (they evaluate preconditions and report current state on every invocation)
- Eventual consistency (5–10 second Sentinel poll interval) is acceptable for cluster provisioning workflows
- Operational overhead is justified by the decoupling and extensibility benefits

---

## Alternatives Considered

### Direct Sentinel-to-Adapter RPC (HTTP/gRPC)

**What**: Sentinel calls each adapter's HTTP or gRPC endpoint directly when reconciliation is needed.

**Why Rejected**:
- Requires Sentinel to maintain a registry of all adapter endpoints — tight coupling
- Adding a new adapter requires a Sentinel configuration change and redeployment
- A slow or failing adapter blocks Sentinel from notifying other adapters
- No built-in retry or delivery guarantees

### Shared Database Polling (Outbox Pattern)

**What**: Sentinel writes reconciliation events to an "outbox" table; adapters poll the database for new rows.

**Why Rejected**: This was the v1 architecture. It was replaced in v2 specifically because:
- Requires an additional Outbox Reconciler component
- Higher latency (polling delay vs. direct publish)
- More complex API (transactional outbox writes alongside CRUD)
- Database becomes a bottleneck at scale

See `hyperfleet/architecture/architecture-summary.md` for the full v1 vs. v2 comparison.

### Single Event Queue (One Subscription for All Adapters)

**What**: All adapters share a single subscription queue; events are consumed by whichever adapter picks them up first (competing consumers).

**Why Rejected**: Competing consumers don't implement fan-out — each event would be processed by only one adapter. The HyperFleet model requires every adapter to evaluate every reconciliation event.

---

## Dependencies

| Dependency | Purpose |
|-----------|---------|
| GCP Pub/Sub (production) | Managed message broker in GCP environments |
| RabbitMQ (on-premise) | Self-hosted broker for non-GCP environments |
| Sentinel | Publishes reconciliation events to the broker topic |
| Adapter Framework | Consumes events from adapter-specific subscriptions |

---

## Interfaces

From [openshift-hyperfleet/hyperfleet-broker](https://github.com/openshift-hyperfleet/hyperfleet-broker):

### Publisher Interface (used by Sentinel)

```go
// Publisher defines the interface for publishing CloudEvents
type Publisher interface {
    // Publish publishes a CloudEvent to the specified topic
    Publish(ctx context.Context, topic string, event *event.Event) error
    // Health checks if the underlying broker connection is healthy
    Health(ctx context.Context) error
    // Close closes the underlying publisher
    Close() error
}
```

Instantiated via `broker.NewPublisher(logger, metrics)` or `broker.NewPublisher(logger, metrics, configMap)`.

### Subscriber Interface (used by Adapters)

```go
// HandlerFunc processes a received CloudEvent
type HandlerFunc func(ctx context.Context, event *event.Event) error

// Subscriber defines the interface for subscribing to CloudEvents
type Subscriber interface {
    // Subscribe subscribes to a topic and processes messages with the provided handler
    Subscribe(ctx context.Context, topic string, handler HandlerFunc) error
    // Errors returns a channel that receives errors from background operations
    Errors() <-chan *SubscriberError
    // Close closes the underlying subscriber
    Close() error
}
```

Instantiated via `broker.NewSubscriber(logger, subscriptionID, metrics)`. The `subscriptionID` determines fan-out vs. load-balancing: different IDs = each subscriber gets every message (fan-out); same ID = messages are shared across instances (competing consumers).

---

## Related Documents

- [Architecture Summary](../../architecture/architecture-summary.md) — system-level view of broker's role
- [Sentinel Design](../sentinel/sentinel.md) — how Sentinel publishes events
- [Adapter Framework Design](../adapter/framework/adapter-frame-design.md) — how adapters subscribe and process events
- [Adapter Design Decisions](../adapter/framework/adapter-design-decisions.md) — anemic event pattern rationale
