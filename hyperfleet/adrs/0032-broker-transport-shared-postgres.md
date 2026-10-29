---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-10-29
---

# 0032 — The Shared PostgreSQL Instance as the Broker's Transport

## Context

[HYPERFLEET-1654](https://redhat.atlassian.net/browse/HYPERFLEET-1654) removes standalone broker infrastructure and gives the Broker a PostgreSQL backend, but it never compared that choice against a network-service transport. [HYPERFLEET-1859](https://redhat.atlassian.net/browse/HYPERFLEET-1859) evaluates the question before the backend implementation stories are written.

Constraints and requirements:

- The Broker is an in-process library in Sentinel and Adapters, with no pods or chart of its own ([ADR-0002](0002-pluggable-message-broker-library.md))
- Service state consolidates on the shared instance ([ADR-0026](0026-co-located-service-databases-shared-postgres-isolation.md))
- Remote callers reach hub stores through the authenticated gateway, never directly ([ADR-0022](0022-api-mediated-desire-store-access.md), decided for the Desire Store)
- HYPERFLEET-1654 scopes the PostgreSQL backend to the self-managed box (operator bundle, disconnected installs); GCP environments use managed Pub/Sub today, and any change there is a separate decision in that ticket
- The Broker's contract is fan-out signaling: small, idempotent events whose job is to wake consumers, at tens of events per second

Assumptions:

- Occasional delivery loss is acceptable because Sentinel regenerates events: it is stateless and derives its publish decision from resource state on every poll, so a lost event for a still-unreconciled resource is republished on the next cycle ([sentinel design](../components/sentinel/sentinel.md)).
- The shared instance sustains the Broker's messaging load alongside concurrent API traffic. The proof of concept measured a dedicated instance only; the contention benchmark ([HYPERFLEET-1672](https://redhat.atlassian.net/browse/HYPERFLEET-1672)) has not run.
- A gateway-mediated events endpoint for remote consumers is not yet designed, so its feasibility and implementation cost remain uncertain; ADR-0022's caller model and the Desire Store machinery are the pattern it would reuse.

## Decision

In the self-managed box and on the Oracle deployment path ([ADR-0023](0023-oci-managed-postgresql.md)'s shared instance), the Broker's transport is the shared PostgreSQL instance: publishers and subscribers exchange events through tables in `event_store` ([ADR-0031](0031-broker-postgres-event-log.md)'s event log), with no network service in the messaging path. This is a target state: PostgreSQL cannot be selected until the event log backend ships in `hyperfleet-broker` and the Sentinel and Adapter configuration supports its broker type.

**In the box (operator bundle, disconnected installs):** [HYPERFLEET-1654](https://redhat.atlassian.net/browse/HYPERFLEET-1654)'s goal is one stateful service, and the choice keeps it: the box already carries the database, and events become tables in it — nothing added to install, secure, or mirror.

**Remote event consumers:** none is defined today — adapters run on the hub ([ADR-0022](0022-api-mediated-desire-store-access.md)) and management clusters no longer receive events ([ADR-0030](0030-desire-based-remote-delivery.md)). If one is introduced, [ADR-0022](0022-api-mediated-desire-store-access.md)'s principle applies, so it would consume through a gateway-mediated events path rather than an `event_store` pool. That path's design is the open assumption above.

## Consequences

**Gains:**

- One stateful service in the self-managed box.
- Event delivery observable in plain SQL, including consumer lag.
- The API-emitted outbox path stays open ([ADR-0031](0031-broker-postgres-event-log.md)).

**Trade-offs:**

- The database carries the messaging load.
- A remote event consumer, if introduced, needs a gateway-mediated consumption path built.

**Acceptable because:**

- The messaging load is bounded by design — one row per event, retention by partition rotation ([ADR-0031](0031-broker-postgres-event-log.md)) — and the proof of concept, measured on a dedicated instance, sustained 500 events per second against a pipeline volume of tens of events per second ([HYPERFLEET-1656](https://redhat.atlassian.net/browse/HYPERFLEET-1656)). Shared-instance capacity remains unverified pending the contention test in HYPERFLEET-1672.
- A remote event consumer needs a gateway endpoint under either transport — an HTTP transport would be one too; the endpoint's design and cost are the open assumption above.

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| HTTP transport, hub-hosted behind the [Envoy and Authorino gateway](0020-envoy-authorino-api-gateway.md) (e.g. [watermill-http](https://github.com/ThreeDotsLabs/watermill-http)), with adapters consuming over outbound-only HTTPS and no database credentials leaving the hub | Adds a separately deployed service against HYPERFLEET-1654's one-stateful-service goal; connectivity parity under the ADR-0022 gateway pattern is assumed (see Assumptions); no persistence — no retention or replay for slow or restarted consumers, no SQL observability, no outbox path, which requires table access |
| Managed Pub/Sub in all environments | The self-managed box includes disconnected installs with no cloud reachability, so a cloud transport cannot serve it |
| Keep standalone broker infrastructure (RabbitMQ) | Rejected by HYPERFLEET-1654's premise: the last stateful component in the box whose only job is to wake adapters, and one more service to install, secure, and mirror for disconnected deployments |
