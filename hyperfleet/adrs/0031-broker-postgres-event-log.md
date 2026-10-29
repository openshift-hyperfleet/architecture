---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-10-29
---

# 0031 — Event Log with Per-Subscription Cursors as the Broker's PostgreSQL Backend

## Context

[HYPERFLEET-1654](https://redhat.atlassian.net/browse/HYPERFLEET-1654) replaces standalone broker infrastructure with a PostgreSQL backend inside the `hyperfleet-broker` library ([ADR-0002](0002-pluggable-message-broker-library.md)), storing state in `event_store` on the shared instance ([ADR-0026](0026-co-located-service-databases-shared-postgres-isolation.md)). The Broker's contract is fan-out signaling: events are small and idempotent by generation, volume is tens of events per second, and delivery loss is tolerable because Sentinel re-publishes on later cycles. The chosen design must not preclude an API-emitted outbox.

[HYPERFLEET-1656](https://redhat.atlassian.net/browse/HYPERFLEET-1656) compared River, a purpose-built work queue, and a purpose-built event log with cursors; the [spike doc](../docs/spike-broker-postgres-backend.md) records the comparison and the evidence run. [HYPERFLEET-1859](https://redhat.atlassian.net/browse/HYPERFLEET-1859) added watermill-sql to the comparison. The transport-level decision is [ADR-0032](0032-broker-transport-shared-postgres.md).

## Decision

Use the purpose-built event log with per-topic sequences and per-subscription cursors.

- **Storage:** `broker_events` is an append-only table, partitioned daily, one row per event with a per-topic sequence from `broker_topic_seq`; publish is one transaction (bootstrap, allocate, insert) whose cost is independent of subscription count.
- **Coordination:** each (topic, subscription) tracks progress in `broker_cursors` (acked and reserved positions); replicas reserve disjoint sequence ranges through `broker_ranges` claims with per-range leases; a reservation is one transaction holding the cursor row lock.
- **Delivery:** acks only on handler success — at-least-once within a subscription while events are within the retention window, safe because events are idempotent by generation; bounded retries tracked by an attempts counter scoped per (topic, subscription, sequence), then skip and surface on the subscriber error channel; a skipped event advances the cursor like an acknowledged one, so the cursor is the highest contiguous id that has been acknowledged or skipped. The dead-letter path is the log itself: an exhausted event remains in `broker_events` until the retention window, inspectable by SQL, and replay is Sentinel regenerating still-unreconciled work on later cycles — no separate DLQ topic. For this backend it supersedes [ADR-0017](0017-adapter-error-taxonomy.md)'s broker-native DLQ: the guide's operator re-publish replay and 7-day expiry ([Adapter Error Handling](../components/adapter/framework/adapter-error-handling.md)) become Sentinel regeneration and the retention window, and the DLQ-depth alert maps to the age-of-oldest-unacknowledged-event alert in the operational rules.
- **Ordering:** the acked cursor advances only over contiguous ids. The current publisher allocates the per-topic sequence and inserts the event in one transaction holding the counter row lock, so it cannot leave an in-flight or rolled-back gap behind the cursor; a future producer, such as an API-emitted outbox, must keep the same invariant. A hole older than the grace period (default 5s, configurable) is treated as a rolled-back insert and skipped — the guard for a producer that violates the invariant. The grace period must exceed the longest publish transaction so the guard never fires on a live insert.
- **Retention:** daily partitions created a day ahead, dropped after the retention window (default 24h). Partition DDL runs as `event_store_migrate` on a schedule — the runtime role (`event_store_app`) holds DML only, per [ADR-0026](0026-co-located-service-databases-shared-postgres-isolation.md). Cursor positions reconcile independently: a position below the oldest retained sequence advances to one below it, accepting the documented loss — acked stalled behind an already-advanced reserved (handler failure with the range lease outstanding) recovers on its own. Lease expiry never retreats a position, it only releases the range for reclaim; a pending range lying entirely below the oldest retained sequence is deleted rather than retried. When a topic has no retained rows, both positions advance to the topic's sequence head and its pending ranges are deleted, so the next published event is the first delivered.
- **Pooling:** no LISTEN/NOTIFY and no extensions — short transactions and plain SQL only, so transaction pooling (PgBouncer) is safe by construction and [ADR-0023](0023-oci-managed-postgresql.md)'s OCI Database with PostgreSQL constraints are met; live validation on that offering is deferred to the implementation stories.

Operational rules:

- No NOTIFY inside hot write transactions.
- Claim and reservation transactions stay short.
- Idle checks take no locks — the cursor row lock is taken only when there is work.
- Retention by rotation rather than delete-behind.
- Alert on the age of the oldest unacknowledged event per subscription, on holes stalled past the grace period, and on `event_store`'s xmin horizon age — the grace rule covers cursor holes, while a transaction pinning the horizon blocks vacuum with or without one (defined in the [co-located databases design](../docs/co-located-service-databases-postgres-design.md)).

Evidence (both backends run on one machine with one harness; repeat runs on a fresh instance; 30-second runs at 200-500 events/sec with 3-5 way fan-out, pre-pruning against default 24h retention):

- The nine shared integration scenarios, the goroutine leak tests, and the targeted correctness tests pass for both candidates.
- 100 percent delivery and zero publish errors in every run, locally and in-kind.

| Backend | p50 | p99 | Storage per event |
|---------|-----|-----|-------------------|
| Event log | 6-8ms | 176-211ms | 0.4KB, zero dead tuples |
| River | 35-43ms | 92-94ms | about 7KB at 5-way fan-out |

River's figures are our same-machine runs. Local (500 events/sec, 5-way fan-out): River measures p50 35ms / p99 94ms against `RIVER-POC.md`'s recorded p50 43ms / p99 92ms. In-kind (single Postgres pod, port-forward, 200 events/sec, 3-way fan-out): event log p50 12ms / p99 213ms, River p50 44ms / p99 101ms against its recorded p50 41ms / p99 88ms.

POC records in `hyperfleet-broker`: [`EVENTLOG-POC.md`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/poc/eventlog-backend/EVENTLOG-POC.md) and [`RIVER-POC.md`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/poc/eventlog-backend/RIVER-POC.md).

## Consequences

**Gains:**

- No dependency beyond pgx.
- Schema, migrations, and retention owned in-repo through the `event_store_migrate` path.
- Append-only storage with no delete-behind vacuum load on the shared instance.
- Per-topic sequence ordering.
- Consumer lag observable in one SQL query.
- The same table can host an API-emitted outbox once its producer and cross-database handoff are designed; changing the producer alone does not make the outbox atomic with the API's write, since [ADR-0026](0026-co-located-service-databases-shared-postgres-isolation.md) keeps the API and the Broker on separate databases.

**Trade-offs:**

- A polling latency tail — p99 about 200ms, set by the idle `poll_interval` (1s default; the load harness does not override it). At 200ms the p99 drops to 16ms but costs 34 percent more transaction IDs.
- Per-topic publish serialization on the counter row.
- Range coordination adds two small tables and one transaction per batch.
- Metrics and tooling are in-repo (`MetricsRecorder` plus SQL) rather than provided by a library.

**Acceptable because:**

- The 5-second Sentinel poll floor does not require tighter latency, and idle polls take no locks, so the 1s default's cost is bounded.
- Publish serialization is immaterial at contract volume.
- Range coordination buys crash recovery and competing consumers without a central coordinator.
- In-repo metrics are the price of the no-dependency gain (pgx only).

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| River ([riverqueue/river](https://github.com/riverqueue/river), MPL-2.0) | External dependency controls its schema and migrations; higher storage from one job row per subscription per event (about 7KB vs 0.4KB at 5-way fan-out); delete-behind retention adds vacuum overhead; LISTEN/NOTIFY imposes connection-pooling constraints; no direct path to the API-emitted outbox |
| Purpose-built work queue (per-subscription tables, SELECT FOR UPDATE SKIP LOCKED) | Retains the per-subscription storage and delete-behind retention while requiring custom implementation; no outbox path |
| watermill-sql ([ThreeDotsLabs/watermill-sql](https://github.com/ThreeDotsLabs/watermill-sql), MIT) | Library-owned per-topic schema — opt-in initialization runs CREATE TABLE from the app role at runtime, against the `event_store_migrate`/`event_store_app` role split, and disabling it means a migration per topic; no retention mechanism (delete-behind by hand); handler batches run inside the polling transaction holding the offsets row lock, against the short-transaction rule; its correct-by-construction ordering (transaction-id horizon) does not offset the operational costs |
| watermill-http ([ThreeDotsLabs/watermill-http](https://github.com/ThreeDotsLabs/watermill-http), MIT) | Not a Postgres backend — an HTTP transport with no storage, so the comparison criteria do not apply; decided in [ADR-0032](0032-broker-transport-shared-postgres.md) |
