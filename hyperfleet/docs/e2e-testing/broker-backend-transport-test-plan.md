---
Status: Active
Owner: HyperFleet QE Team
Last Updated: 2026-11-06
---

# Broker Backend and Transport Test Plan

**Jira**: [HYPERFLEET-1867](https://redhat.atlassian.net/browse/HYPERFLEET-1867)

**Epic**: [HYPERFLEET-1655](https://redhat.atlassian.net/browse/HYPERFLEET-1655)

## Table of Contents

- [Scope](#scope)
- [How to Read](#how-to-read)
- [Existing Coverage](#existing-coverage)
- [Contract Matrix](#contract-matrix)
- [Event Log Behaviour](#event-log-behaviour)
- [PostgreSQL-Specific Matrix](#postgresql-specific-matrix)
  - [Migrations, Roles and Retention](#migrations-roles-and-retention)
  - [Connections and TLS Floor](#connections-and-tls-floor)
- [Deployment Wiring](#deployment-wiring)
- [Metrics and Alerts](#metrics-and-alerts)
- [CI Cutover](#ci-cutover)
- [Day-2 Operations](#day-2-operations)
- [Gaps and Deferred Work](#gaps-and-deferred-work)
- [Coverage by Ticket](#coverage-by-ticket)
- [References](#references)

## Scope

This document is the test plan for the Broker's PostgreSQL backend. [ADR-0031](../../adrs/0031-broker-postgres-event-log.md) decides the backend: an event log with per-subscription cursors. [ADR-0032](../../adrs/0032-broker-transport-shared-postgres.md) decides the transport: the shared PostgreSQL instance. [ADR-0033](../../adrs/0033-postgres-transport-security.md) sets the TLS floor.

The plan separates backend-independent contract coverage, event log behaviour, deployment wiring and day-2 operation. It maps each scenario to its build story. The Broker is the `hyperfleet-broker` library, not a service. Sentinel and the adapters embed it, so its wiring rows run in their repositories, and the CI and E2E rows run in hyperfleet-infra, hyperfleet-e2e and Prow. After you read it, you can list the test obligations of your ticket, the place where each one runs, and the gaps that touch them.

This plan lists coverage. A row does not schedule work: each owning story decides when its rows are implemented.

This plan does not cover GCP environments, which stay on managed Pub/Sub, or shared-instance capacity under concurrent API and Broker load. [Gaps and Deferred Work](#gaps-and-deferred-work) records both.

## How to Read

Scenario placement follows the [Test Placement Strategy](test-placement-strategy.md): test at the lowest layer that catches the failure. Each E2E row names a user journey. For each row, ask: "What must be broken for this test to fail?"

Each scenario has these columns: Scenario and assertion, Layer, Environment, Entry point, Owner and Status. Day-2 rows split the first column into Item and Assertion.

A row can run only after the story that owns it merges. E2E rows on the PostgreSQL environment belong to HYPERFLEET-1883, because HYPERFLEET-1879, HYPERFLEET-1880 and HYPERFLEET-1886 block it: those stories supply what the rows check but cannot run them. No planned test can run today, so domain owners validate the rows in review.

**Status values:**

| Status | Meaning |
|---|---|
| `existing` | A test exists on the POC branch. HYPERFLEET-1876 ports it |
| `extend` | A test exists. Add the assertion that the row states |
| `new` | No test exists |
| `procedure` | A documented operator procedure. No automated test |
| `Gn` after a status | Gap `Gn` in [Gaps and Deferred Work](#gaps-and-deferred-work) affects the row |

**Environments:**

| Environment | Description |
|---|---|
| `go test` | No containers |
| testcontainers | PostgreSQL 16 on Podman or Docker. In Prow, the `integration` job runs them in nested Podman |
| helm render | No cluster |
| promtool | Rule evaluation only. No cluster |
| review | Check of a document in the owning PR. Nothing runs |
| local kind | Helmfile environment `kind` or `e2e-kind`, with the dev opt-down |
| Prow GKE | Nightly on `hyperfleet-dev-prow`, on a PostgreSQL helmfile environment that HYPERFLEET-1883 adds (G8), with `verify-full` |

**Entry points:**

| Entry point | Repository |
|---|---|
| `make test`, `make test-integration` | hyperfleet-broker |
| `make test-helm` | hyperfleet-sentinel, hyperfleet-adapter |
| `make test-integration` | hyperfleet-sentinel |
| `make test-alerts` | hyperfleet-adapter has this `promtool test rules` pattern. HYPERFLEET-1882 selects the repository for the Broker rules |
| `make build`, then `./bin/hyperfleet-e2e test --label-filter=...` | hyperfleet-e2e, local runs. Set `HYPERFLEET_API_URL` and `AUTH_MODE` for the cluster |
| `make install-hyperfleet`, `make install-api`, `make install-desire-delivery`, `make install-adapters`, `make install-sentinels`, `make template-helmfile` | hyperfleet-infra |
| `tier0-nightly`, `tier1-nightly`, `tier2-nightly` | Prow jobs for hyperfleet-e2e |
| `integration` | Prow presubmit job for hyperfleet-broker |

**POC branch.** `poc/eventlog-backend` in hyperfleet-broker is the proof of concept (POC) that HYPERFLEET-1876 ports. Existing Coverage and most gap evidence describe it, not main. Links to other repositories carry the commit that was read, so their line numbers stay correct. This records what was read. It is not a version freeze.

**POC names and final names.** The POC uses `broker.type: eventlog` and `test/integration/common`. Main uses `test/integration/testutil`, and HYPERFLEET-1876 specifies `broker.type: postgres`. The ADR-0031 defaults are poll interval 1s, batch size 10, grace period 5s and retention 24h.

**Terms.** The rows use two short names from the [glossary](../glossary.md): "the routine" is the Maintenance Routine, and "the reaper" is the Retention Reaper.

## Existing Coverage

Main runs the shared scenarios on RabbitMQ and Pub/Sub, and it has no event log code or tests. The event log tests below exist only on the POC branch. These limits apply to all of them:

- The tests connect as the superuser `broker` ([`eventlog_test.go`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/test/integration/eventlog/eventlog_test.go#L48)) with `sslmode=disable` ([line 84](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/test/integration/eventlog/eventlog_test.go#L84)).
- [`BuildConfigMap`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/test/integration/common/common.go#L81) sets `create_schema_if_missing=true`, `batch_size=1`, `subscriber.parallelism=1` and `max_attempts=50`.

So no test proves the role split, the TLS floor, migrations, batches above 1 or retry exhaustion.

| Test | Proves | Does not prove |
|---|---|---|
| [`RunPublisherSubscriber`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/test/integration/common/common.go#L120) | One event arrives with the same type, ID and source | Duplicates, payload |
| [`RunMultipleEvents`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/test/integration/common/common.go#L176) | Two events of different types arrive | Order (it compares a set) |
| [`RunSharedSubscription`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/test/integration/common/common.go#L240) | Two subscribers on one ID: 10 events split, each receives at least one | Claims under lease expiry, batches above 1 |
| [`RunFanoutSubscription`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/test/integration/common/common.go#L327) | Two IDs each receive all 5 events | Cursor positions |
| [`RunSlowSubscriber`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/test/integration/common/common.go#L419) | One ID, 20 events: the fast handler takes more | Order, position |
| [`RunErrorSubscriber`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/test/integration/common/common.go#L507) | One failing and one working handler: the working one handles at least 5 of 10 | Full delivery, retry cap, skip, attempts scope |
| [`RunCloseWaitsForInFlightMessages`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/test/integration/common/common.go#L583) | `Close` returns after in-flight handlers finish | Position after close, restart |
| [`RunPanicHandler`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/test/integration/common/common.go#L668) | `Close` does not hang after a panic | Attempts or skip after a panic |
| [`RunErrorChannelNotification`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/test/integration/common/common.go#L747) | The channel exists and closes on `Close` | That an error arrives: it forces no failure ([`common.go:781`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/test/integration/common/common.go#L781)). No RabbitMQ or Pub/Sub test calls it on main at `4856ca8` |
| [`TestVisibilityOrderingUnderConcurrentPublishers`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/test/integration/eventlog/targeted_test.go#L26) | 4 publishers, 25 events each: exactly once and per-publisher order on the happy path | At-least-once under failure, competing workers |
| [`TestCrashRecoveryRedeliversUnackedRange`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/test/integration/eventlog/targeted_test.go#L116) | Lease 500ms: a second subscriber delivers all 5 events, each at most twice | Process death (the handler blocks), positions, no retreat |
| [`TestHoleResolutionAfterInjectedHole`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/test/integration/eventlog/targeted_test.go#L211) | Injected hole: all 5 events arrive, no duplicates | Wait of at least grace, metric exclusion, many holes |
| [`TestTransactionPoolingThroughPgBouncer`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/test/integration/eventlog/targeted_test.go#L281) | Publish, shared and fan-out through transaction pooling | TLS, runtime role, the proxy exception |
| [`TestEventLogGoroutineLeak`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/test/integration/broker_leak_test.go#L399), [`TestEventLogLeakIncreasesWithUsage`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/test/integration/broker_leak_test.go#L411) | At most 4 goroutines remain after `Close`, for 3 and for 1, 3, 5 subscriptions | Failure paths |
| [`TestRabbitMQMultipleSubscriptionsSameTopic`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/test/integration/broker_leak_test.go#L549), [`TestGooglePubSubMultipleSubscriptionsSameTopic`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/test/integration/broker_leak_test.go#L558) | RabbitMQ and Pub/Sub only: no event log variant exists | Second `Subscribe` on the event log (G16) |
| [`broker/eventlog_test.go`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/broker/eventlog_test.go): `TestEventLogConfigValidation`, `TestEventLogConfigDefaults`, `TestEventLogDurationHelpersFallBackOnGarbage`, `TestEventLogPartitionName` | Config parsing, defaults, UTC partition names | DSN quoting, `sslmode`. The URI-only cases end with the discrete fields of HYPERFLEET-1876 |
| [`EVENTLOG-POC.md`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/EVENTLOG-POC.md#L132-L134) retention note | A manual run with an injected stale partition | No test in the suite covers rotation |

## Contract Matrix

| ID | Scenario and assertion | Layer | Environment | Entry point | Owner | Status |
|---|---|---|---|---|---|---|
| C1 | Ported suite, including fan-out, where two IDs each receive every event (`RunFanoutSubscription`). Also `RunPublisherSubscriber`, `RunMultipleEvents`, `RunSlowSubscriber`, `RunErrorSubscriber`, `RunErrorChannelNotification`, `RunCloseWaitsForInFlightMessages`, `RunPanicHandler` and both leak tests | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1876 | existing |
| C2 | Competing replicas: two subscribers, one ID, `batch_size` 10: every event handled, no overlap in `broker_ranges` (`RunSharedSubscription`) | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1876 | extend |
| C3 | Subscription lifecycle: new ID starts at the topic head; known ID resumes at its cursor; `Subscribe` after `Close` returns an error; a second `Subscribe` on a topic follows the G16 decision | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1876 | new, G16 |
| C4 | Reconnect: PostgreSQL restarts: subscriber sends non-fatal errors then resumes; `Publish` fails then recovers; no position retreats | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1876 | new |
| C5 | Restart: subscriber closes and reopens on the same ID: continues from `acked`, redelivers what was unacknowledged | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1876 | new |
| C6 | At-least-once within retention: the handler fails fewer times than `max_attempts`, then succeeds: the event returns each time, then is acknowledged. A range that a stopped subscriber held returns after its lease. Assert at least once, allow duplicates (`TestCrashRecoveryRedeliversUnackedRange`). L2 covers exhaustion | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1876 | extend |
| C7 | Per-topic order, one worker: handler order equals sequence (`TestVisibilityOrderingUnderConcurrentPublishers`) | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1876 | extend |
| C8 | Contiguous cursor, two workers: one range held, `acked` stops at its start and `reserved` moves on; after completion `acked` is the highest contiguous id. Handler order across concurrent ranges is not asserted | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1876 | new |
| C9 | Selection: `broker.type: postgres` constructs the backend; `rabbitmq` and `googlepubsub` do not change (`broker/broker_type_test.go`) | Unit | `go test` | hyperfleet-broker `make test` | HYPERFLEET-1876 | extend |

C7 and C8 do not assert global handler order across replicas. `reserveRange` lets workers hold ranges concurrently, and ADR-0031 defines ordering through the cursor rule.

## Event Log Behaviour

| ID | Scenario and assertion | Layer | Environment | Entry point | Owner | Status |
|---|---|---|---|---|---|---|
| L1 | Retry scope: one of two subscriptions fails: only it reaches the cap, the other delivers; two sequences count separately | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1876 | new, G2 |
| L2 | Skip and advance: at the cap the cursor passes the sequence, the error channel gets one error, the next event arrives | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1876 | new |
| L3 | Failure inside a batch: `batch_size` 10, fifth event fails: retry follows `retry_backoff`, not the full lease | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1876 | new, G5 |
| L4 | Empty topic, no pending range: all rows expired, publish races reconciliation: reconciliation holds the `broker_topic_seq` row lock, and the next published event is the first delivered | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1876 | new, G3 |
| L5 | An idle poll takes no `broker_cursors` row lock | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1876 | new, G4 |
| L6 | Publish: a rollback leaves no gap; the transaction timeout is below the grace period | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1876 | new, G14 |
| L7 | Transaction pooling: PgBouncer scenarios pass under the runtime role, with no LISTEN/NOTIFY (`TestTransactionPoolingThroughPgBouncer`) | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1876 | extend |
| L8 | No runtime DDL: the full suite runs as a non-superuser with no DDL and no direct `DELETE` | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1876 | new, G1 |
| L9 | DSN: an empty password does not swallow `sslmode`; discrete fields assemble in code | Unit | `go test` | hyperfleet-broker `make test` | HYPERFLEET-1876 | new |

For L8, the fixture applies the schema as owner and runs the suite as a non-superuser. The POC's superuser hides [`broker/eventlog.go:819-825`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/broker/eventlog.go#L819-L825) until deployment. HYPERFLEET-1876 merges before HYPERFLEET-1877, so P3 repeats the check on the migrated schema.

## PostgreSQL-Specific Matrix

### Migrations, Roles and Retention

Rotation tests use back-dated partitions that the owner role creates. They do not wait in real time, because `make test-integration` has a 10-minute timeout and retention is 24h.

| ID | Scenario and assertion | Layer | Environment | Entry point | Owner | Status |
|---|---|---|---|---|---|---|
| P1 | Migrations: a second run changes nothing; two concurrent runners serialize on the advisory lock, with no error | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1877 | new |
| P2 | Role split: `event_store_app` cannot run DDL or direct `DELETE` on event-log tables; artifacts run under `event_store_migrate`; no role held by `hyperfleet-operator` gains access | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1877 | new, G1 |
| P3 | Contract suite (C1 to C8) passes on the migrated schema as `event_store_app` | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1877 | new, G2 |
| P4 | Routine does exactly three things: pre-create one day ahead, drop expired, clean pending ranges below the boundary. `event_store_app` can execute it; `PUBLIC` cannot; `search_path` is fixed; references are qualified | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1878 | new, G1 |
| P5 | Reaper executes the routine: a back-dated partition drops and the next-day partition exists | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1878 | new, G6 |
| P6 | Retention boundary: a partition ending after the cutoff stays, one ending before it drops; an event stays readable for at least `retention` ([`eventlog.go:280`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/broker/eventlog.go#L280) keeps it up to `retention` plus 24h) | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1878 | new |
| P7 | A pending range wholly below the oldest retained sequence is deleted, not retried; a straddling range stays | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1878 | new |
| P8 | Reapers on two replicas run together with no error (each pod runs one per minute, [`eventlog.go:78`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/broker/eventlog.go#L78)) | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1878 | new |
| P9 | Empty topic with a pending range: the pending-range deletion runs under the same `broker_topic_seq` row lock as the empty check, sequence-head read and cursor updates; publish races it: the next published event is the first delivered | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1878 | new, G3 |

### Connections and TLS Floor

HYPERFLEET-1900 owns library and chart enforcement, so it owns these rows. HYPERFLEET-1879 and HYPERFLEET-1880 own the wiring (W1, W3). HYPERFLEET-1886 supplies the deployed certificate that X3 checks.

Integration rows use a generated CA. Local kind opts down to `sslmode=disable` under the [ADR-0033](../../adrs/0033-postgres-transport-security.md) dev opt-down. W1, W3 and X3 cover the deployed connections.

| ID | Scenario and assertion | Layer | Environment | Entry point | Owner | Status |
|---|---|---|---|---|---|---|
| T1 | Direct `verify-full` with a trusted CA connects | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1900 | new |
| T2 | Wrong CA or wrong hostname is refused | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1900 | new |
| T3 | Absent, unsupported, `disable`, `require` and `verify-ca` modes are errors, and so is a connection with no CA bundle. Enforcement applies only when the PostgreSQL backend is selected. Test fixtures must opt down explicitly, or C and L rows stop passing | Unit | `go test` | hyperfleet-broker `make test` | HYPERFLEET-1900 | new, G18 |
| T4 | Proxy exception: with the exception selected, a loopback host or Unix socket passes validation; any other host is an error | Unit | `go test` | hyperfleet-broker `make test` | HYPERFLEET-1900 | new, G17 |
| T5 | Client `verify-full` to a PgBouncer that verifies PostgreSQL (`server_tls_sslmode=verify-full`, explicit CA) connects with no exception selected. Control: with the wrong CA in PgBouncer, the connection fails | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1900 | new, G17 |
| T6 | Both charts default the runtime and migration `event_store` connections to `verify-full` with `ca.crt` from the connection Secret. The dev opt-down exists only in dev-only values; production values cannot enable it | Unit (chart render) | helm render | `make test-helm` in hyperfleet-sentinel and hyperfleet-adapter | HYPERFLEET-1900 | new, G18 |
| T7 | Each Broker connection class documents its trust-reload mechanism, including migrations. A pod restart is acceptable ([ADR-0033](../../adrs/0033-postgres-transport-security.md), CA rotation) | Procedure | review | Review of the documentation in the HYPERFLEET-1900 PR | HYPERFLEET-1900 | procedure |

## Deployment Wiring

| ID | Scenario and assertion | Layer | Environment | Entry point | Owner | Status |
|---|---|---|---|---|---|---|
| W1 | Sentinel renders `broker.type: postgres`: discrete fields, Secret credentials, no DSN in values or Secret. The init container uses `event_store_migrate`; the runtime container mounts no migration credential. Values that select `verify-full` reach the runtime and migration connections, with `ca.crt`. The default render stays `googlepubsub`, so GCP is unaffected | Unit (chart render) | helm render | hyperfleet-sentinel `make test-helm` | HYPERFLEET-1879 | new, G11 |
| W2 | PostgreSQL down: `/readyz` returns 503, then recovers | Integration | testcontainers | hyperfleet-sentinel `make test-integration` | HYPERFLEET-1879 | new |
| W3 | Adapter renders postgres, Secret credentials and CA mount, with no migration init container. Two replicas render one subscription ID; C2 proves that they reserve disjoint ranges | Unit (chart render) | helm render | hyperfleet-adapter `make test-helm` | HYPERFLEET-1880 | new, G11 |
| W4 | Journey: "A cluster reaches Reconciled with one adapter at 2 replicas" | E2E | Prow GKE | `tier1-nightly` | HYPERFLEET-1883 | new, G8 |
| W5 | Journey: "A fresh install becomes ready when adapters start before the Sentinel migration" (the helmfile has adapters need the API and gateway, not Sentinel). Install without Sentinel: adapters create no `broker_*` table and do not become ready. Install Sentinel: its init container migrates, and adapters become ready with no manual restart | E2E | local kind | hyperfleet-infra `HELMFILE_ENV=kind make install-api install-desire-delivery install-adapters`, then `HELMFILE_ENV=kind make install-sentinels`, then hyperfleet-e2e `make build` and `./bin/hyperfleet-e2e test --label-filter=tier0` | HYPERFLEET-1883 | new |

## Metrics and Alerts

Two alert thresholds have a source: xmin above 10 minutes and oldest unconsumed above 1 hour ([co-located databases design](../co-located-service-databases-postgres-design.md), Monitoring and alerts). This plan chooses no other number. For the others, it refers to the value that HYPERFLEET-1882 records (G10).

| ID | Scenario and assertion | Layer | Environment | Entry point | Owner | Status |
|---|---|---|---|---|---|---|
| M1 | Signals: oldest unacknowledged age per subscription rises while a handler fails and falls on ack; the stalled hole signal rises for a hole past grace that no worker drains, then clears; pre-creation lag rises when the next-day partition is absent. Labels carry topic and subscription where they apply; publish and delivery metrics are labeled per backend (HYPERFLEET-1876); `max(seq) - acked` stays queryable in SQL. D6 covers the xmin signal | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1881 | new, G10 |
| M2 | Skipped counter rises on the commit that skips and stays after the cursor advances; a handler returning nil (precondition skip), a hole skip and a cursor reconciliation do not change it | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1881 | new |
| A1 | One rule per signal. Each fires at its threshold and stays silent below it, with a configurable evaluation window: oldest unacknowledged age above 1 h; `event_store` xmin horizon age above 10 min; skipped count increases within the window; stalled holes and pre-creation lag at the values HYPERFLEET-1882 records | Unit (promtool) | promtool | `make test-alerts` pattern | HYPERFLEET-1882 | new, G10 |

## CI Cutover

| ID | Scenario and assertion | Layer | Environment | Entry point | Owner | Status |
|---|---|---|---|---|---|---|
| X1 | The event log suite runs in the presubmit next to the RabbitMQ and Pub/Sub suites, inside the 10-minute limit or with the limit raised | Integration | testcontainers | Prow job `integration` | HYPERFLEET-1883 | new |
| X2 | Journey: "I installed HyperFleet on kind and created a cluster, and it became Reconciled". The default is PostgreSQL, with `event_store` on the API chart's instance | E2E | local kind | hyperfleet-infra `HELMFILE_ENV=kind make install-hyperfleet`, then hyperfleet-e2e `make build` and `./bin/hyperfleet-e2e test --label-filter=tier0` | HYPERFLEET-1883 | new |
| X3 | Journeys: "I created a cluster and it became Reconciled" and adapter crash and recovery ([`e2e/cluster/crash_recovery.go`](https://github.com/openshift-hyperfleet/hyperfleet-e2e/blob/f1fb43a4807ce758a9864e04dc34ae0aaead4e8a/e2e/cluster/crash_recovery.go)), with existing tier0, tier1 and tier2 specs unchanged. Embedded PostgreSQL serves a cert-manager certificate (HYPERFLEET-1886), and every Broker connection runs `verify-full` | E2E | Prow GKE | `tier0-nightly`, `tier1-nightly`, `tier2-nightly` | HYPERFLEET-1883 | new, G8 |
| X4 | The `gcp` helmfile environment keeps `googlepubsub` | Unit (chart render) | helm render | hyperfleet-infra `HELMFILE_ENV=gcp make template-helmfile` | HYPERFLEET-1883 | new |

## Day-2 Operations

| ID | Item from the ticket | Assertion | Layer | Environment | Entry point | Owner | Status |
|---|---|---|---|---|---|---|---|
| D1 | Cursor stalled behind an outstanding lease; recovery on expiry | `acked` holds and `reserved` moves past; after expiry the range is reclaimed and `acked` advances; neither position ever decreases; a late completion by the first holder is safe | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1876 | extend |
| D2 | Cursor below the oldest retained sequence; documented loss | Stop the subscriber, drop a back-dated partition, restart: position moves to one below the oldest retained; expired events do not arrive; the next event does; elapsed time is below missing events × grace. M2 covers the skipped counter | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1876 | new, G3 |
| D3a | Missed rotation, DEFAULT partition branch | Publish lands in DEFAULT; the routine later creates the covering partition while DEFAULT holds rows of that range; those rows do not outlive retention | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1878 | new, G6 |
| D3b | Missed rotation, alert-only branch | `Publish` returns an error; running the routine restores publishing. M1 and A1 cover the signal and the alert | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1878 | new, G6 |
| D3c | Missed rotation, alert-only branch: Sentinel recovery | While `Publish` fails, Sentinel keeps polling and records the publish error ([`sentinel.go:257-265`](https://github.com/openshift-hyperfleet/hyperfleet-sentinel/blob/921ceba7d7eef9dab29f5e81f8943c6f489be898/internal/sentinel/sentinel.go#L257-L265)); after publishing recovers, its next cycle publishes the event | Integration | testcontainers | hyperfleet-sentinel `make test-integration` | HYPERFLEET-1879 | new, G6 |
| D4 | Hole older than grace is skipped | Not skipped before grace; skipped after (`TestHoleResolutionAfterInjectedHole`). M1 and M2 cover the metrics | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1876 | extend |
| D5a | Skipped event stays inspectable | Row stays in `broker_events` by SQL until its partition drops. M2 covers the counter | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1876 | new, G7 |
| D5b | Replay through Sentinel regeneration | Journey: "An event is lost and the cluster still reaches Reconciled". Stop an adapter and create a cluster: it is not Reconciled. As the schema owner, set that adapter's `acked` and `reserved` to the topic head N, and leave no pending range, so no original event can return. Start the adapter. A `broker_events` row above N names the cluster, `acked` passes that row, and the cluster reaches Reconciled | E2E | Prow GKE | `tier2-nightly` | HYPERFLEET-1883 | new, G7, G8, G12 |
| D6 | Transaction pinning the xmin horizon | A second role holds a `REPEATABLE READ` snapshot in `event_store`: the metric, read as `event_store_app`, rises and falls on termination; a snapshot in another database does not move it; A1 covers the alert | Integration | testcontainers | hyperfleet-broker `make test-integration` | HYPERFLEET-1881 | new |
| D7 | Runbook procedures | Each procedure in the list below exists, and each of its commands works | Procedure | local kind | Manual dry run of each command after X2 | HYPERFLEET-1873 | procedure, G9 |

**D3 has two branches.** HYPERFLEET-1878 decides the missed-rotation guard: a DEFAULT partition or alert-only. This plan covers both: D3a for the DEFAULT partition, D3b and D3c for alert-only. Remove the branch that HYPERFLEET-1878 does not choose.

**D5 forces the loss.** A deployed adapter does not return a handler error (G7), so an E2E with a failing real adapter cannot reach skip. An integration test with an erroring test handler proves skip (L2, D5a). D5b forces a lost event by a SQL cursor advance. A new row above the advanced cursor proves that Sentinel, not a pending range, recovered the cluster.

**D7 procedures.** The criteria of HYPERFLEET-1873 require:

- R1: no dead-letter topic; retention-based expiry
- R2: recover through Sentinel regeneration
- R3: respond to the skipped-events alert, with labels and SQL to inspect the event

HYPERFLEET-1881 and HYPERFLEET-1882 defer these to HYPERFLEET-1873 (G9):

- R4: stalled cursor
- R5: cursor below retention: record the loss
- R6: missed rotation: restore partitions
- R7: stalled hole
- R8: xmin pin: find and end the session

## Gaps and Deferred Work

G numbers are labels local to this document, so that rows can refer to a gap. They are not issue IDs, and Jira holds the work. Each gap below states the problem and its impact, the action, the proposed owner group from the repository `OWNERS` files, its disposition and its tracking ticket. Code evidence links to the POC branch, so a POC gap stays open until the port in HYPERFLEET-1876 fixes it.

**Disposition values:**

| Disposition | Meaning |
|---|---|
| `Tracked` | The criteria of the linked ticket require the action |
| `Add to ticket` | The linked ticket is the proposed home. Its criteria do not state the action yet |
| `New ticket` | No ticket fits. A new ticket is necessary |
| `Deferred` | No action until the stated condition holds |

| ID | Gap and impact | Action | Owner | Disposition | Tracking | Evidence |
|---|---|---|---|---|---|---|
| G1 | The POC deletes `done` ranges in the ack transaction, but `event_store_app` has no direct `DELETE`. Each ack fails under the runtime role, so the cursor does not advance. The maintenance routine cleans pending ranges and "nothing else", so nothing owns `done`-range cleanup | Remove the direct `DELETE` from the ack path and name what removes `done` ranges. If the maintenance routine does it, change its "nothing else" criterion in HYPERFLEET-1878 | `broker-owners` | `Add to ticket` | [HYPERFLEET-1876](https://redhat.atlassian.net/browse/HYPERFLEET-1876) | [`broker/eventlog.go:819-825`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/broker/eventlog.go#L819-L825); [ADR-0031](../../adrs/0031-broker-postgres-event-log.md), Retention; HYPERFLEET-1877 and HYPERFLEET-1878, criteria |
| G2 | HYPERFLEET-1876 requires an attempts counter per (topic, subscription, sequence), but none of the five tables in HYPERFLEET-1877 holds it. No ticket says where the counter lives or what removes its rows | Add the storage for the counter and its cleanup to the schema | `broker-owners` | `Add to ticket` | [HYPERFLEET-1877](https://redhat.atlassian.net/browse/HYPERFLEET-1877) | HYPERFLEET-1876, criteria; HYPERFLEET-1877, the five listed tables |
| G3 | The POC has no cursor or empty-topic reconciliation, though the HYPERFLEET-1876 notes say it does. A subscriber walks expired rows as holes, at least `grace_period` each: at least 5,000 s for 1,000 expired events at the 5 s default. ADR-0031 holds one lock across the cursor updates and the pending-range deletion, but two stories hold those parts, and `event_store_app` has no direct `DELETE` | Add reconciliation to the criteria. Name the one transaction that holds the cursor updates and the pending-range deletion | `broker-owners` | `Add to ticket` | [HYPERFLEET-1876](https://redhat.atlassian.net/browse/HYPERFLEET-1876), [HYPERFLEET-1878](https://redhat.atlassian.net/browse/HYPERFLEET-1878) | [`broker/eventlog.go:910-922`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/broker/eventlog.go#L910-L922); [ADR-0031](../../adrs/0031-broker-postgres-event-log.md), Retention; HYPERFLEET-1876, technical notes |
| G4 | Each poll of the POC takes the cursor row lock, but ADR-0031 says that idle checks take no locks. Idle subscribers add lock traffic on the shared instance | Add the idle check without a lock to the criteria | `broker-owners` | `Add to ticket` | [HYPERFLEET-1876](https://redhat.atlassian.net/browse/HYPERFLEET-1876) | [`broker/eventlog.go:733-737`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/broker/eventlog.go#L733-L737); [`EVENTLOG-POC.md`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/EVENTLOG-POC.md#L155-L156); [ADR-0031](../../adrs/0031-broker-postgres-event-log.md), Operational rules |
| G5 | In the POC, a failure after the first event of a range matches no row in `releaseRange`, so the retry waits the full lease (30 s default), not `retry_backoff`. `batch_size=1` in the tests hides this, and the default is 10 | Release the range on a failure at any position in the batch | `broker-owners` | `Add to ticket` | [HYPERFLEET-1876](https://redhat.atlassian.net/browse/HYPERFLEET-1876) | [`broker/eventlog.go:781-789`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/broker/eventlog.go#L781-L789), [`:1002`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/broker/eventlog.go#L1002) |
| G6 | The POC starts the retention reaper only in `Subscribe`. Sentinel only publishes, so rotation stops when no adapter runs. Publishing stops when no partition covers the insert | Run rotation when no subscriber runs, and add this to the criteria | `broker-owners` | `Add to ticket` | [HYPERFLEET-1878](https://redhat.atlassian.net/browse/HYPERFLEET-1878) | [`broker/eventlog.go:616-619`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/broker/eventlog.go#L616-L619) |
| G7 | A deployed adapter acknowledges every event and returns no handler error, so skip, the skipped counter and its alert fire only for an undecodable payload or a panic. HYPERFLEET-1654 records this behaviour and HYPERFLEET-1880 says adapter code needs no change, but [ADR-0017](../../adrs/0017-adapter-error-taxonomy.md) still requires selective NACK | Decide: accept the behaviour and align ADR-0017, or make adapters return handler errors | `adapter-owners` | `New ticket` | None | Adapter [`internal/eventhandler/handler.go`](https://github.com/openshift-hyperfleet/hyperfleet-adapter/blob/45d2fd8e42231cb7457b355a3e596b007e44c16a/internal/eventhandler/handler.go#L74-L96); [`broker/eventlog.go:941-947`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/broker/eventlog.go#L941-L947), [`:1008-1015`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/broker/eventlog.go#L1008-L1015); [HYPERFLEET-1654](https://redhat.atlassian.net/browse/HYPERFLEET-1654), problem statement |
| G8 | Prow E2E hard-codes the `e2e-gcp` environment with `googlepubsub`. A passing nightly run proves nothing about PostgreSQL until CI has a PostgreSQL environment. GCP environments must stay unchanged, so the switch needs a new environment | Add a PostgreSQL helmfile environment for Prow and select it in the job | `e2e-owners` | `Tracked` | [HYPERFLEET-1883](https://redhat.atlassian.net/browse/HYPERFLEET-1883) | Release [`openshift-hyperfleet-e2e-setup-commands.sh`](https://github.com/openshift/release/blob/00dac7b5f24894b39476e396972753dfc0541cc7/ci-operator/step-registry/openshift-hyperfleet/e2e/setup/openshift-hyperfleet-e2e-setup-commands.sh#L207); infra [`helmfile/helmfile.yaml.gotmpl`](https://github.com/openshift-hyperfleet/hyperfleet-infra/blob/84415e8e65d865b1901304eeecdf6c0f9057fc83/helmfile/helmfile.yaml.gotmpl#L55-L58) |
| G9 | The criteria of HYPERFLEET-1873 cover only the dead-letter replacement. HYPERFLEET-1881 and HYPERFLEET-1882 defer the other runbook procedures to it, so R4 to R8 have no criterion and operators can get no procedure for those alerts | Add R4 to R8 to the criteria | `adapter-owners` | `Add to ticket` | [HYPERFLEET-1873](https://redhat.atlassian.net/browse/HYPERFLEET-1873) | HYPERFLEET-1873, criteria; HYPERFLEET-1881 and HYPERFLEET-1882, out of scope |
| G10 | Stalled holes and pre-creation lag have no alert threshold, and "stalled" has no definition. HYPERFLEET-1882 says to align with a design that holds neither, so the two rules cannot be written or tested as specified | HYPERFLEET-1881 defines "stalled". HYPERFLEET-1882 records both thresholds | `broker-owners` | `Add to ticket` | [HYPERFLEET-1881](https://redhat.atlassian.net/browse/HYPERFLEET-1881), [HYPERFLEET-1882](https://redhat.atlassian.net/browse/HYPERFLEET-1882) | [Co-located databases design](../co-located-service-databases-postgres-design.md), Monitoring and alerts; [ADR-0031](../../adrs/0031-broker-postgres-event-log.md), Operational rules; HYPERFLEET-1882, criteria |
| G11 | The notes of HYPERFLEET-1879 and HYPERFLEET-1880 point ADR-0033 enforcement at HYPERFLEET-1709, whose criteria are ADR-only. HYPERFLEET-1900 owns it, so a reader of those stories finds the wrong owner | Correct the technical notes of both stories | `broker-owners` | `Add to ticket` | [HYPERFLEET-1879](https://redhat.atlassian.net/browse/HYPERFLEET-1879), [HYPERFLEET-1880](https://redhat.atlassian.net/browse/HYPERFLEET-1880) | HYPERFLEET-1879 and HYPERFLEET-1880, technical notes; HYPERFLEET-1709 and HYPERFLEET-1900, criteria |
| G12 | D5b is in no ticket's criteria, and hyperfleet-e2e has no SQL helper (`pkg/helper` has `ScaleDeployment`). Without both, no test proves recovery through Sentinel regeneration on a deployed stack | Add D5b to the criteria and add the SQL helper | `e2e-owners` | `Add to ticket` | [HYPERFLEET-1883](https://redhat.atlassian.net/browse/HYPERFLEET-1883) | HYPERFLEET-1883, criteria; hyperfleet-e2e [`pkg/helper/k8s.go`](https://github.com/openshift-hyperfleet/hyperfleet-e2e/blob/f1fb43a4807ce758a9864e04dc34ae0aaead4e8a/pkg/helper/k8s.go#L184) |
| G13 | ADR-0031 defers live validation on OCI Database with PostgreSQL to "the implementation stories", and no story lists it. The backend can ship with no run on the managed offering | File a ticket for the live validation | `broker-owners` | `New ticket` | None | [ADR-0031](../../adrs/0031-broker-postgres-event-log.md), Pooling; criteria of HYPERFLEET-1876 to HYPERFLEET-1883 |
| G14 | The spike requires a publish transaction timeout below the grace period. The POC sets none, and HYPERFLEET-1876 does not list it. A publish that outlives the grace period can have its event skipped as a hole | Add the timeout to the criteria | `broker-owners` | `Add to ticket` | [HYPERFLEET-1876](https://redhat.atlassian.net/browse/HYPERFLEET-1876) | [Spike doc](../spike-broker-postgres-backend.md), Comparison; [`broker/eventlog.go:422`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/broker/eventlog.go#L422); HYPERFLEET-1876, criteria |
| G15 | A retired subscription keeps its cursor, and no procedure removes it. `event_store_app` has no direct `DELETE`, so operators need a stated path | Add the removal procedure to the runbook | `adapter-owners` | `Add to ticket` | [HYPERFLEET-1873](https://redhat.atlassian.net/browse/HYPERFLEET-1873) | [ADR-0031](../../adrs/0031-broker-postgres-event-log.md); HYPERFLEET-1877, `DELETE` rule |
| G16 | A second `Subscribe` on one topic returns an error on the event log but succeeds on RabbitMQ and Pub/Sub, so the backends differ at the shared seam. The adapter subscribes once, so no deployed flow hits this today | Record the difference as accepted, or align the backend. C3 follows the decision | `broker-owners` | `Add to ticket` | [HYPERFLEET-1876](https://redhat.atlassian.net/browse/HYPERFLEET-1876) | [`broker/eventlog.go:580-583`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/broker/eventlog.go#L580-L583); [`broker_leak_test.go`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/test/integration/broker_leak_test.go#L549-L565) |
| G17 | Both proxy paths require the proxy to verify PostgreSQL, and the exception also requires the deployment to document the boundary. The library cannot observe either: T5 proves the path on a fixture, not on a deployment | Condition: when a deployment selects a proxy, its ticket must carry proxy verification and the boundary documentation | `broker-owners` | `Deferred` | None | [ADR-0033](../../adrs/0033-postgres-transport-security.md), Decision and Proxy-terminated TLS exception; HYPERFLEET-1900, criteria |
| G18 | HYPERFLEET-1900 has no blocking link, though T3 needs the DSN assembly of HYPERFLEET-1876 and T6 needs the chart wiring of HYPERFLEET-1879 and HYPERFLEET-1880. Its merge order is not set | Add the blocking links | `broker-owners` | `Add to ticket` | [HYPERFLEET-1900](https://redhat.atlassian.net/browse/HYPERFLEET-1900) | HYPERFLEET-1900, linked issues |

| Deferred or excluded | Reason | Tracking |
|---|---|---|
| Shared-instance capacity under concurrent API and Broker load | Outside the close gate of this plan | [HYPERFLEET-1672](https://redhat.atlassian.net/browse/HYPERFLEET-1672) |
| The missed-rotation branch not chosen (D3a, or D3b and D3c) | Remove when the guard is recorded | [HYPERFLEET-1878](https://redhat.atlassian.net/browse/HYPERFLEET-1878) |
| Partner-provided instances; OCI CA retrieval | Linked only | [HYPERFLEET-1710](https://redhat.atlassian.net/browse/HYPERFLEET-1710); [HYPERFLEET-1901](https://redhat.atlassian.net/browse/HYPERFLEET-1901) |
| GCP environments | Stay on managed Pub/Sub | Out of scope |

## Coverage by Ticket

| Ticket | Rows |
|---|---|
| [HYPERFLEET-1873](https://redhat.atlassian.net/browse/HYPERFLEET-1873) | D7, R1 to R8 |
| [HYPERFLEET-1876](https://redhat.atlassian.net/browse/HYPERFLEET-1876) | C1 to C9, L1 to L9, D1, D2, D4, D5a |
| [HYPERFLEET-1877](https://redhat.atlassian.net/browse/HYPERFLEET-1877) | P1 to P3 |
| [HYPERFLEET-1878](https://redhat.atlassian.net/browse/HYPERFLEET-1878) | P4 to P9, D3a, D3b |
| [HYPERFLEET-1879](https://redhat.atlassian.net/browse/HYPERFLEET-1879) | W1, W2, D3c |
| [HYPERFLEET-1880](https://redhat.atlassian.net/browse/HYPERFLEET-1880) | W3 |
| [HYPERFLEET-1881](https://redhat.atlassian.net/browse/HYPERFLEET-1881) | M1, M2, D6 |
| [HYPERFLEET-1882](https://redhat.atlassian.net/browse/HYPERFLEET-1882) | A1 |
| [HYPERFLEET-1883](https://redhat.atlassian.net/browse/HYPERFLEET-1883) | X1 to X4, W4, W5, D5b |
| [HYPERFLEET-1886](https://redhat.atlassian.net/browse/HYPERFLEET-1886) | X3 (supplies the certificate) |
| [HYPERFLEET-1900](https://redhat.atlassian.net/browse/HYPERFLEET-1900) | T1 to T7 |

## References

- [ADR-0017: Adapter error taxonomy](../../adrs/0017-adapter-error-taxonomy.md)
- [ADR-0026: Co-located service databases](../../adrs/0026-co-located-service-databases-shared-postgres-isolation.md)
- [ADR-0031: Event log as the Broker's PostgreSQL backend](../../adrs/0031-broker-postgres-event-log.md)
- [ADR-0032: Broker transport on shared PostgreSQL](../../adrs/0032-broker-transport-shared-postgres.md)
- [ADR-0033: PostgreSQL transport security](../../adrs/0033-postgres-transport-security.md)
- [Co-located databases design](../co-located-service-databases-postgres-design.md)
- [Spike: Broker PostgreSQL backend](../spike-broker-postgres-backend.md)
- [Test Placement Strategy](test-placement-strategy.md)
- [`EVENTLOG-POC.md` at `a4ec1e0`](https://github.com/openshift-hyperfleet/hyperfleet-broker/blob/a4ec1e00ce09cfff3168ffff5bb037aea5cae031/EVENTLOG-POC.md)
