---
Status: Proposed
Owner: HyperFleet Architecture Team
Last Updated: 2026-10-26
---

# 0031 — Event Log with Per-Subscription Cursors as the Broker's PostgreSQL Backend

## Context

[HYPERFLEET-1654](https://redhat.atlassian.net/browse/HYPERFLEET-1654) replaces standalone broker infrastructure with a PostgreSQL backend inside the `hyperfleet-broker` library ([ADR-0002](0002-pluggable-message-broker-library.md)), storing state in `event_store` on the shared instance ([ADR-0026](0026-co-located-service-databases-shared-postgres-isolation.md)). The Broker's contract is fan-out signaling: events are small and idempotent by generation, volume is tens of events per second, and delivery loss is tolerable because Sentinel re-publishes on later cycles. The chosen design must not preclude an API-emitted outbox.

[HYPERFLEET-1656](https://redhat.atlassian.net/browse/HYPERFLEET-1656) compared River, a purpose-built work queue, and a purpose-built event log with cursors; the [spike doc](../docs/spike-broker-postgres-backend.md) records the comparison and the evidence run.

## Decision

Use the purpose-built event log with per-topic sequences and per-subscription cursors.

- **Storage:** `broker_events` is an append-only table, partitioned daily, one row per event with a per-topic sequence from `broker_topic_seq`; publish is one transaction (bootstrap, allocate, insert) whose cost is independent of subscription count.
- **Coordination:** each (topic, subscription) tracks progress in `broker_cursors` (acked and reserved positions); replicas reserve disjoint sequence ranges through `broker_ranges` claims with per-range leases; a reservation is one transaction holding the cursor row lock.
- **Delivery:** acks only on handler success — at-least-once within a subscription while events are within the retention window, safe because events are idempotent by generation; bounded retries tracked by an attempts counter scoped per (topic, subscription), then skip and surface on the subscriber error channel.
- **Ordering:** the acked cursor advances only over contiguous ids; a hole older than the grace period (default 5s, configurable) is treated as a rolled-back insert and is skipped. The grace period must exceed the longest publish transaction so a live insert is never mistaken for a rolled-back one.
- **Retention:** daily partitions created a day ahead, dropped after the retention window (default 24h). Partition DDL runs as `event_store_migrate` on a schedule — the runtime role (`event_store_app`) holds DML only, per [ADR-0026](0026-co-located-service-databases-shared-postgres-isolation.md). When both cursor positions fall behind the oldest retained sequence, they advance to one below it, accepting the documented loss.
- **Pooling:** no LISTEN/NOTIFY and no extensions — short transactions and plain SQL only, so transaction pooling (PgBouncer) is safe by construction and [ADR-0023](0023-oci-managed-postgresql.md)'s OCI Database with PostgreSQL constraints are met; live validation on that offering is deferred to the implementation stories.

Operational rules:

- No NOTIFY inside hot write transactions.
- Claim and reservation transactions stay short.
- Idle checks take no locks — the cursor row lock is taken only when there is work.
- Retention by rotation rather than delete-behind.
- Alert on the age of the oldest unacknowledged event per subscription and on holes stalled past the grace period — the grace rule is the time-based stand-in for the xmin horizon.

Evidence (both backends run on one machine with one harness; repeat runs on a fresh instance; 30-second runs at 200-500 events/sec with 3-5 way fan-out, pre-pruning against default 24h retention):

- The nine shared integration scenarios, the goroutine leak tests, and the targeted correctness tests pass for both candidates.
- 100 percent delivery and zero publish errors in every run, locally and in-kind.

| Backend | p50 | p99 | Storage per event |
|---------|-----|-----|-------------------|
| Event log | 6-8ms | 176-211ms | 0.4KB, zero dead tuples |
| River | 35-43ms | 92-94ms | about 7KB at 5-way fan-out |

River's figures are our same-machine runs; they reproduce `RIVER-POC.md`'s recorded local run (p50 43ms, p99 92ms). In-kind (single Postgres pod, port-forward): event log p50 12ms / p99 213ms, River p50 44ms / p99 101ms — River reproduces its recorded in-kind figures (p50 41ms, p99 88ms).

POC records in `hyperfleet-broker`: [`EVENTLOG-POC.md`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/poc/eventlog-backend/EVENTLOG-POC.md) and [`RIVER-POC.md`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/poc/eventlog-backend/RIVER-POC.md).

## Consequences

**Gains:**

- No dependency beyond pgx.
- Schema, migrations, and retention owned in-repo through the `event_store_migrate` path.
- Append-only storage with no delete-behind vacuum load on the shared instance.
- Per-topic sequence ordering.
- Consumer lag observable in one SQL query.
- The same table becomes an API-emitted outbox by changing the producer.

**Trade-offs:**

- A polling latency tail — p99 about 200ms, set by the idle `poll_interval` (1s default; the load harness does not override it). At 200ms the p99 drops to 16ms but costs 34 percent more transaction IDs and 38 percent more WAL. The 1s default is chosen because the 5-second Sentinel poll floor does not require tighter latency, and idle polls with no locks (see the operational rules) make the cost acceptable.
- Per-topic publish serialization on the counter row, immaterial at contract volume.
- Range coordination adds two small tables and one transaction per batch.
- Metrics and tooling are in-repo (`MetricsRecorder` plus SQL) rather than provided by a library.

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| River ([riverqueue/river](https://github.com/riverqueue/river), MPL-2.0) | External dependency controls its schema and migrations; higher storage from one job row per subscription per event (about 7KB vs 0.4KB at 5-way fan-out); delete-behind retention adds vacuum overhead; LISTEN/NOTIFY imposes connection-pooling constraints; no direct path to the API-emitted outbox |
| Purpose-built work queue (per-subscription tables, SELECT FOR UPDATE SKIP LOCKED) | Retains the per-subscription storage and delete-behind retention while requiring custom implementation; no outbox path |
