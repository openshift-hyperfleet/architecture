---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-10-29
---

# SPIKE: Choose the Broker's PostgreSQL Backend Design

**Jira**: [HYPERFLEET-1656](https://redhat.atlassian.net/browse/HYPERFLEET-1656)

## Table of Contents

- [Related Documents](#related-documents)
- [Overview](#overview)
- [Evaluation Method](#evaluation-method)
- [Candidates](#candidates)
- [Comparison](#comparison)
- [Evidence Run](#evidence-run)
- [Decision](#decision)

---

## Related Documents

- [ADR-0002: Pluggable Message Broker Library](../adrs/0002-pluggable-message-broker-library.md): the Publisher and Subscriber seam every candidate must plug into.
- [ADR-0026: Co-Located Service Databases on Shared Postgres](../adrs/0026-co-located-service-databases-shared-postgres-isolation.md): decides the shared-instance database layout.
- [Co-located service databases design](co-located-service-databases-postgres-design.md): defers `event_store` backend details to this spike.
- Parent epic: [HYPERFLEET-1655](https://redhat.atlassian.net/browse/HYPERFLEET-1655).

## Overview

This document compares the candidates for the Broker's PostgreSQL backend — River, a purpose-built work queue, a purpose-built event log with cursors, and watermill-sql (added in the [HYPERFLEET-1859](https://redhat.atlassian.net/browse/HYPERFLEET-1859) follow-up) — and records the evidence and the decision.

The proof of concept (POC) proved River works, but not that it is the right amount of machinery for the Broker's contract. The choice sets schema ownership, the migration story, and the dependency footprint for the operator bundle and disconnected installs.

## Evaluation Method

Compare all candidates against the criteria in the [comparison](#comparison); the event log POC supplies the evidence for the purpose-built candidates.

Each candidate is evaluated against the Broker's actual contract:

- Events are small and idempotent by generation.
- Volume is tens of events per second at pipeline scale.
- Delivery loss is tolerable — Sentinel re-publishes on later cycles.

Fixed input: `event_store` is a dedicated database on the shared instance, decided in [ADR-0026](../adrs/0026-co-located-service-databases-shared-postgres-isolation.md).

### Event log POC

- **Scope:** build the event-log-with-cursors backend behind the existing Publisher and Subscriber interfaces.
- **Design:** store each event once in an append-only `broker_events` table with a per-topic monotonic sequence; track each (topic, subscription)'s progress in `broker_cursors` (reserved and acknowledged positions), with replicas reserving ranges whose claims carry the lease expiry.
- **Delivery and recovery:** advance cursors with contiguity plus grace — a hole older than the grace period is treated as a rolled-back insert and skipped; retry handler failures a bounded number of times, then skip, log, and surface them on the subscriber error channel. Delivery is at-least-once within a subscription; duplicates are safe because events are idempotent by generation. Retry counts are scoped per (topic, subscription, sequence), so events do not share a budget and fan-out subscriptions do not consume each other's; the POC simplifies this to a shared per-event counter on the row (`EVENTLOG-POC.md`).
- **Database behavior:** short transactions and plain SQL, no LISTEN/NOTIFY; retention by partition rotation.

## Candidates

### River

- Job queue library behind the broker seam.
- Fan-out via a subscription registry: each (topic, subscription) pair is a queue; replicas sharing a subscription compete on it.

### Purpose-built work queue

- Our own per-subscription table with SELECT FOR UPDATE SKIP LOCKED claims.
- Optional LISTEN/NOTIFY as a wake-up hint; polling is the guarantee.
- Same fan-out shape as River.

### Purpose-built event log with cursors

- One append-only events table with a sequence; one cursor row per (topic, subscription).
- Retention by partition rotation.
- Sentinel is the producer today; an API-emitted outbox later reuses the same table, with its producer and cross-database handoff still to design ([ADR-0026](../adrs/0026-co-located-service-databases-shared-postgres-isolation.md) keeps the API's database separate).

### watermill-sql

- Watermill's SQL implementation, plugging into the Watermill seam the broker already wraps.
- One messages table per topic with an auto-incrementing offset; each consumer group's progress in a per-topic offsets table; only transactions below the snapshot's xmin horizon are readable.

## Comparison

| Criterion | River | Purpose-built work queue | Purpose-built event log with cursors | watermill-sql |
|---|---|---|---|---|
| Dependency and license delta | External: [riverqueue/river](https://github.com/riverqueue/river) (MPL-2.0), with retry and scheduling machinery the contract does not use | None — all code in-repo | None — all code in-repo | External: [ThreeDotsLabs/watermill-sql](https://github.com/ThreeDotsLabs/watermill-sql) (MIT) atop Watermill core (MIT, already a dependency) |
| Schema ownership and operator migrations | River's — upstream releases can change it | Ours | Ours, plus partition-rotation DDL | Library's — per-topic messages and offsets tables; its opt-in initialization creates them at runtime from the app role, or they are pre-created per topic |
| Fan-out cost per subscription | One row per subscription per event | One row per subscription per event | One append per event | One append per event |
| Managed Postgres and PgBouncer | LISTEN/NOTIFY claiming — needs direct or session-pooled connections ([guide](https://riverqueue.com/docs/pgbouncer)) | SKIP LOCKED — transaction-pooling safe | Plain SQL, short transactions — transaction-pooling safe by construction | No LISTEN/NOTIFY and transaction-pooling compatible, but handler batches run inside the polling transaction holding the offsets row lock; needs PostgreSQL 13+ |
| Retention, bloat, and vacuum | Delete-behind — tunable only via River's knobs | Delete-behind — tunable by us | Partition rotation — few dead tuples | None — messages accumulate until deleted by hand or a custom partitioned schema adapter |
| Observability (SQL and metrics) | Built in: riverui, OpenTelemetry; queue-shaped | SQL visibility; metrics ours to build | SQL visibility; metrics ours to build; consumer lag = max sequence minus cursor | SQL visibility (offsets table); metrics ours to build |
| Visibility-ordering correctness | No cross-job ordering | No cross-job ordering | Sequence order; advance bounded by contiguity and the grace period | Correct by construction — only transactions below the snapshot's xmin horizon are readable, ordered by (transaction id, offset) |
| Effort to production | Lowest — the nine scenarios already pass on the POC branch | Build tables, claims, and polling, pass the nine scenarios, plus alerts and a runbook | Build events, cursors, and rotation, pass the nine scenarios, plus alerts and a runbook | Wire the Watermill backend on the existing rabbitmq/googlepubsub pattern; role-split compliance (pre-created tables) and retention are work outside the library |
| Path to an API-emitted outbox | None | None | Table reuse, once the producer and its cross-database handoff are designed (de-weighted, see below) | Table reuse possible, same handoff as the event log (de-weighted, see below) |

**Details and caveats:**

- River's and the purpose-built candidates' migrations ship through the `event_store_migrate` path in the operator bundle; River's are generated by its own tooling and wired into it.
- River's insert-only clients tolerate transaction pooling; its running clients can be configured to poll instead of listening.
- The work queue's LISTEN/NOTIFY hint needs a session-level connection when enabled.
- Event-log cursor advance skips a hole older than the grace period (5s default). The current publisher cannot produce one — sequence allocation and insert share one transaction under the counter row lock — so the grace period guards a future producer that breaks that invariant; publish transactions carry a timeout below the grace period so the guard never fires on a live transaction.
- The outbox criterion is de-weighted: the ticket predates [ADR-0026](../adrs/0026-co-located-service-databases-shared-postgres-isolation.md), and with the API and the Broker on separate databases no backend gets an atomic API-emitted outbox by changing the producer alone — every path needs a cross-database handoff. The event log keeps the cheapest path (same table, new producer), but the criterion no longer decides the choice.
- watermill-sql's schema initialization is opt-in: enabled, it runs CREATE TABLE from the app role at runtime, against the role split; disabled, every new topic needs its tables pre-created through the migrate path.

**Paper comparison outcome:** the event log with cursors is the candidate to build; the evidence run decides between the event log and River.

- **Work queue — eliminated:** River's write amplification and delete-behind retention at self-build cost, and no outbox path.
- **watermill-sql — eliminated:**
  - **Schema:** per-topic tables need runtime creation from the app role or a migration per topic, against the `event_store_migrate`/`event_store_app` role split.
  - **Retention:** none — messages accumulate until deleted by hand.
  - **Transactions:** handler batches run inside the polling transaction holding the offsets row lock.
  - Its only clear win, transaction-id-horizon ordering, does not offset those costs.

## Evidence Run

All evidence is on [`poc/eventlog-backend`](https://github.com/openshift-hyperfleet/hyperfleet-broker/tree/poc/eventlog-backend).

- Correctness: the nine shared integration scenarios, the goroutine leak tests, and the targeted tests pass — visibility under concurrent publishers, crash recovery, and injected hole resolution.
- Storage: in equivalent 30-second runs at 500 events/sec with 5-way fan-out, the event log stored 14,577 events in 5.5MB — about 0.4KB per event — with zero dead tuples. River stored 73,340 job rows in 97MB — about 1.4KB per row, one per subscription per event, about 7KB per event. Neither run triggered retention cleanup (24h default in both). Consumer lag read 0 via SQL after drain.
- Pooling: PgBouncer 1.26 in transaction mode passes the shared scenarios with pgx's default statement caching; no `default_query_exec_mode` override. Live validation on OCI Database with PostgreSQL ([ADR-0023](../adrs/0023-oci-managed-postgresql.md)) is deferred to the implementation stories.

Load — one harness for both backends (parallelism 8, 30-second runs; the event log at batch 10 / cooldown 10ms; local runs on a fresh instance, kind runs through a port-forward to a single Postgres pod):

| Environment | Backend | Scenario | Delivery | p50 | p99 |
|---|---|---|---|---|---|
| Local | Event log | 500 events/sec, 5-way fan-out | 73,755 / 73,755, 0 errors | 6ms | 211ms |
| Local | Event log | 200 events/sec, 3-way fan-out | 17,628 / 17,628, 0 errors | 8ms | 176ms |
| Local | River | 500 events/sec, 5-way fan-out | 73,425 / 73,425, 0 errors | 35ms | 94ms |
| Local | River | 200 events/sec, 3-way fan-out | 17,817 / 17,817, 0 errors | 43ms | 92ms |
| Kind | Event log | 200 events/sec, 3-way fan-out | 17,334 / 17,334, 0 errors | 12ms | 213ms |
| Kind | River | 200 events/sec, 3-way fan-out | 17,283 / 17,283, 0 errors | 44ms | 101ms |

The event log's median is about 5x lower (no queue round trip); River's tail is about 2x tighter (LISTEN/NOTIFY push versus idle-poll wait), and repeat runs on a fresh instance are within a few percent. The event log's p99 is set by the idle `poll_interval` (1s default): at 200ms the p99 drops to 16ms but costs 34 percent more transaction IDs, so 1s stands against the 5-second Sentinel poll floor. River's numbers are in family with `RIVER-POC.md`'s recorded runs: at the recorded local scenario (500 events/sec, 5-way fan-out) this run measures p50 35ms / p99 94ms against the recorded p50 43ms / p99 92ms, and in kind (200 events/sec, 3-way) p50 44ms / p99 101ms against the recorded p50 41ms / p99 88ms.

## Decision

The event log with per-topic sequences and per-subscription cursors is the chosen design.

- **Wins:** dependency footprint (pgx only), schema ownership, write amplification (one row per event), retention (rotation, zero dead tuples), median latency.
- **Accepted cost:** the polling tail (p99 176-211ms against River's 92-94ms), immaterial under the 5-second Sentinel poll floor.
- **Outbox criterion:** de-weighted rather than decisive (see the comparison caveats).
- **Retention evidence:** a design expectation rather than a measured result — neither run aged out partitions (24h default in both); rotation was verified separately with an injected stale partition ([`EVENTLOG-POC.md`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/poc/eventlog-backend/EVENTLOG-POC.md)).

The watermill-sql evaluation (HYPERFLEET-1859) confirmed the choice. Recorded as [ADR-0031](../adrs/0031-broker-postgres-event-log.md) (Active) with the operational rules.
