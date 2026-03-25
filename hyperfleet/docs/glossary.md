# HyperFleet Glossary

**Status**: Active
**Owner**: HyperFleet Architecture Team
**Last Updated**: 2026-03-25

> Definitions for HyperFleet-specific terms, concepts, and abbreviations used across architecture documents, standards, and component designs. When a term has a specific meaning in HyperFleet that differs from general industry usage, the HyperFleet-specific meaning is given.

---

## A

### Adapter

A HyperFleet component that consumes reconciliation events from the Message Broker, evaluates preconditions, creates Kubernetes Jobs to execute provisioning tasks, and reports status back to the HyperFleet API. Each adapter handles one specific aspect of cluster lifecycle (e.g., DNS, validation, control plane). Adapters are stateless, idempotent, and driven entirely by events — they do not poll.

See: [Adapter Framework Design](../components/adapter/framework/adapter-frame-design.md)

### AdapterConfig

A Kubernetes Custom Resource Definition (CRD) used to configure a HyperFleet Adapter. It specifies the adapter type, precondition criteria, broker subscription, HyperFleet API connection, and job template. Using a CRD (vs. a ConfigMap) provides type safety, validation, and Kubernetes-native integration.

### Adapter Job

A Kubernetes `Job` created by an Adapter to execute a specific provisioning task (e.g., creating DNS records, validating quotas, provisioning a control plane). Jobs run to completion in isolation from the Adapter service pod, enabling retry semantics, resource limits, and independent logging.

### ADR (Architecture Decision Record)

A document that captures a significant architectural decision, its context, the decision made, and its consequences. In HyperFleet, ADRs are stored in this architecture repository.

### Anemic Event

The pattern used in HyperFleet where reconciliation events published by Sentinel contain only the minimum resource identifiers (kind, id, href, generation) — not the full resource spec. Adapters receiving an anemic event must fetch current resource state from the API before acting. This prevents stale data race conditions.

### Applied (Condition)

One of the three standard adapter status conditions. `Applied: True` means the adapter successfully created the Kubernetes resources needed to perform its work (e.g., a Job was launched). It does not mean the work is complete — that is indicated by `Available`.

See also: [Available](#available-condition), [Health](#health-condition)

### Available (Condition)

One of the three standard adapter status conditions. `Available: True` means the adapter's provisioning work completed successfully (e.g., DNS records are live, control plane is running). This is the primary condition Sentinel uses to determine if an adapter has finished its work.

See also: [Applied](#applied-condition), [Health](#health-condition)

---

## B

### Broker

Short for [Message Broker](#message-broker).

### broker.yaml

The YAML configuration file used by the `hyperfleet-broker` library to configure the underlying message broker connection. Specifies `broker.type` (`googlepubsub` or `rabbitmq`), broker-specific connection settings, and subscriber parallelism. The path can be overridden with the `BROKER_CONFIG_FILE` environment variable.

---

## C

### CEL (Common Expression Language)

The expression language used in Sentinel's `message_decision` configuration to define when a resource needs reconciliation. CEL expressions are composed into named params and a boolean `result` expression. Example: `'!is_ready && now - timestamp(ref_time) > duration("10s")'`.

See: [Sentinel Design](../components/sentinel/sentinel.md)

### CloudEvent

A message conforming to the [CloudEvents 1.0 specification](https://cloudevents.io/), used as the event format for all messages published by Sentinel and consumed by Adapters. HyperFleet CloudEvents use the type `com.redhat.hyperfleet.cluster.reconcile.v1` and carry a minimal payload (anemic event pattern).

### Cluster

The primary resource managed by HyperFleet. A cluster represents a HyperShift-managed OpenShift cluster. Clusters have a spec (desired state) and a status (current state aggregated from adapter reports). Referred to as `/clusters` in the API.

### Condition

A structured status field following the Kubernetes conditions pattern. Each adapter reports three standard conditions per resource: `Available`, `Applied`, and `Health`. Conditions include a `type`, `status` (True/False/Unknown), `reason`, `message`, and `last_transition_time`.

See: [Status Guide](status-guide.md)

---

## D

### Dead Letter Queue (DLQ)

A message broker queue that receives messages that could not be processed after the maximum number of retries. HyperFleet uses DLQs (where supported by the broker) to surface persistently failing events for manual inspection and alerting.

### Decision Logic

The CEL-based configuration in a Sentinel instance that determines when to publish a reconciliation event for a resource. Composed of named `params` (intermediate boolean expressions) and a `result` expression that combines them. Defined in the Sentinel's `broker.yaml` / ConfigMap under `message_decision`.

---

## E

### Event

See [CloudEvent](#cloudevent).

---

## F

### Fan-out

The messaging pattern used in HyperFleet where a single reconciliation event published to one topic is independently delivered to multiple adapter subscriptions simultaneously. Each adapter receives its own copy of the event via a dedicated subscription.

---

## G

### Generation

An integer field on HyperFleet API resources that increments each time the resource's spec changes. Adapters include `observed_generation` in their status reports to indicate which version of the spec they reconciled. Sentinel uses generation changes to detect new desired state requiring reconciliation.

### GCP Pub/Sub

Google Cloud Pub/Sub — the primary Message Broker implementation used in GCP-hosted HyperFleet deployments. Configured with `broker.type: googlepubsub` in `broker.yaml`.

---

## H

### Health (Condition)

One of the three standard adapter status conditions. `Health: True` means the adapter is operating normally (no unexpected errors). `Health: False` indicates an infrastructure-level problem (e.g., can't connect to cloud API) as distinct from a business logic failure (e.g., validation failed, which would set `Available: False` but leave `Health: True`).

See also: [Available](#available-condition), [Applied](#applied-condition)

### HyperFleet

The Red Hat platform for managing the lifecycle of HyperShift-based OpenShift clusters at scale. HyperFleet provides APIs, orchestration (Sentinel), event-driven provisioning (Adapters), and observability for multi-cloud cluster provisioning.

### HyperFleet API

The REST API service providing CRUD operations for HyperFleet resources (clusters, node pools) and their statuses. The API is intentionally simple — no business logic, no event creation. It is the data layer for the system.

See: [Architecture Summary](../architecture/architecture-summary.md)

### hyperfleet-broker

The Go library ([openshift-hyperfleet/hyperfleet-broker](https://github.com/openshift-hyperfleet/hyperfleet-broker)) that abstracts message broker communication for HyperFleet components. Provides `Publisher` and `Subscriber` interfaces over GCP Pub/Sub and RabbitMQ backends, with built-in CloudEvents support, metrics, and health checks.

### HyperShift

The Red Hat project for running hosted OpenShift control planes on Kubernetes. HyperFleet manages the provisioning and lifecycle of HyperShift-based clusters.

---

## I

### Idempotent

A property of Adapter operations: processing the same event multiple times produces the same result as processing it once. Required because the Message Broker provides at-least-once delivery (events may be delivered more than once). All HyperFleet Adapters must be idempotent.

---

## L

### Landing Zone Adapter

An adapter that performs preparatory provisioning work before other adapters run — creating namespaces, secrets, and ConfigMaps that subsequent adapters depend on.

---

## M

### Maestro

The work orchestration service that HyperFleet Adapters integrate with to manage distributed provisioning work items. Adapters use the Maestro SDK (not CLI) to submit and track work.

See: [Maestro Integration](../components/adapter/maestro-integration/maestro-architecture-introduction.md)

### Message Broker

The pub/sub infrastructure component that decouples Sentinel from Adapters. Sentinel publishes CloudEvents to a topic; the broker delivers each event to every adapter subscription independently (fan-out). Supported implementations: GCP Pub/Sub (`googlepubsub`) and RabbitMQ (`rabbitmq`).

See: [Broker Design](../components/broker/broker.md)

### message_decision

The Sentinel configuration block that defines when to publish a reconciliation event. Contains `params` (named CEL expressions) and a `result` (boolean CEL expression combining the params). Sentinel evaluates this logic for every resource on every poll cycle.

### MVP (Minimum Viable Product)

The initial release of HyperFleet, completed in late 2024. Documents marked `Status: Historical` in `hyperfleet/mvp/` describe the scope and working agreements from this phase.

---

## N

### NodePool

A group of worker nodes associated with a HyperShift cluster. HyperFleet manages NodePool lifecycle via the same adapter pattern as clusters. Referred to as `/nodepools` in the API.

---

## O

### observed_generation

An integer field included in adapter status reports indicating which resource `generation` the adapter processed. Allows Sentinel to detect when an adapter's status report is stale (refers to an older generation than the current resource spec).

### Outbox Pattern

A message delivery pattern used in HyperFleet v1 (now removed). The API wrote reconciliation events to an "outbox" database table; a separate Outbox Reconciler polled and published them. Replaced in v2 by direct Sentinel publishing, which reduces latency and component count.

---

## P

### Precondition

A condition an Adapter checks before deciding to act on a reconciliation event. Preconditions verify that dependencies are met (e.g., Validation adapter has completed before DNS adapter runs) and that the current resource state requires the adapter's action.

### Pulse

A proposed extension to the HyperFleet status model that introduces periodic heartbeat status updates from adapters. Pulses disambiguate between "new generation not yet reconciled" and "system error" in the `status.phase` field.

See: [Sentinel Pulses](sentinel-pulses.md)

---

## R

### RabbitMQ

An AMQP-based self-hosted message broker used in on-premise HyperFleet deployments. Configured with `broker.type: rabbitmq` in `broker.yaml`.

### Reconciliation

The process of comparing desired state (resource spec) with actual state (cloud provider resources) and taking action to close the gap. In HyperFleet, reconciliation is triggered by Sentinel publishing a CloudEvent, which causes all relevant Adapters to evaluate whether they need to act.

### Ready (Condition / Phase)

The aggregated cluster-level status derived from all adapter conditions. A cluster reaches `phase: Ready` when all registered adapters report `Available: True`. Used by Sentinel's default decision logic to determine when a cluster is fully provisioned.

---

## S

### Sentinel

The HyperFleet reconciliation service that continuously polls the API for resources, evaluates configurable CEL-based decision logic, and publishes CloudEvents to the Message Broker to trigger adapter processing. Multiple Sentinel instances can be deployed with different resource selectors for horizontal scalability (sharding).

See: [Sentinel Design](../components/sentinel/sentinel.md)

### Shard / Sharding

The strategy of deploying multiple Sentinel instances, each watching a different subset of resources (e.g., by region label). Enables horizontal scaling of the reconciliation loop without coordination between instances.

### Subscription

A named queue attached to a Message Broker topic. In HyperFleet, each Adapter has its own subscription to the shared topic, ensuring every adapter independently receives every reconciliation event (fan-out). The subscription ID determines whether multiple instances share messages (same ID = load-balanced) or each receives all messages (different IDs).

---

## T

### Technical Debt

A consciously accepted trade-off that simplifies current implementation at the cost of future work. HyperFleet component documents explicitly track technical debt in a "Technical Debt Incurred" section within the Trade-offs section.

### Topic

A named channel in the Message Broker to which Sentinel publishes events. HyperFleet uses topic naming convention: `hyperfleet.<resourceType>.changed.<version>` (e.g., `hyperfleet.clusters.changed.v1`).

---

## V

### v2 Architecture

The current HyperFleet architecture, which removed the Outbox Pattern from v1. Key change: Sentinel publishes events directly to the broker (vs. the v1 Outbox Reconciler polling a database table). This reduces latency, removes a component, and simplifies the API.

See: [Architecture Summary](../architecture/architecture-summary.md)

---

## W

### Watermill

The Go pub/sub library ([ThreeDotsLabs/watermill](https://github.com/ThreeDotsLabs/watermill)) used as the transport abstraction inside `hyperfleet-broker`. Watermill handles broker-specific protocol details; the HyperFleet broker library adds CloudEvents conversion, metrics, and health checks on top.

---

*To add or update a term, open a PR following the [contribution guidelines](../../CONTRIBUTING.md).*
