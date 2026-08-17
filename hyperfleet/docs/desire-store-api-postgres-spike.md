---
Status: Active
Owner: HyperFleet Team
Last Updated: 2026-08-17
---

# SPIKE: Evaluate Running the Desire Store on the API Postgres

**Jira**: [HYPERFLEET-1432](https://redhat.atlassian.net/browse/HYPERFLEET-1432)

Related: [SPIKE: DSL v2 Resource Ordering Model](dsl-v2-resource-ordering-spike.md) covers how an adapter orders and declares desired state; this spike covers the transport between adapter and applier.

## Table of Contents

- [Store interface feasibility (JSONB)](#store-interface-feasibility-jsonb)
- [Write-split enforcement (DB roles)](#write-split-enforcement-db-roles)
- [Load and isolation](#load-and-isolation)
- [Deployment footprint](#deployment-footprint)
- [Shared instance vs separate](#shared-instance-vs-separate)
- [Schema and role sketch](#schema-and-role-sketch)

---

## Store interface feasibility (JSONB)

**Evaluated:** `desire_store.desires` on local Postgres 14.23 (`make db/setup`); compare-and-swap update, partition listing, and prefix delete.

**Yes.** Compare-and-swap, partition listing, and prefix delete work with an index on `(partition_key, desire_key text_pattern_ops)`. No JSONB-specific extensions required.

## Write-split enforcement (DB roles)

**Evaluated:** column-level `GRANT`s on the same table; `SET ROLE` as adapter and applier for allowed and forbidden writes.

**Yes.** Column-level `GRANT`s enforce the spec/status write split (adapter→spec, applier→status).

## Load and isolation

**Worst-case write rate (no dedup):** 10,000 clusters × 10 desires / 5s poll ≈ 20,000 writes/sec.

**Worst-case read rate:** 10,000 clusters / 5s poll ≈ 2,000 reads/sec (one partition read per cluster per poll).

**Test setup:** `pgbench` run from a pod inside the GCP dev cluster (no port-forward, avoids tunnel-latency artifacts), against the API Helm chart's built-in PostgreSQL pod (500m CPU / 512Mi limit). Table seeded with 1,000 rows (100 partitions × 10 desires each). Each pgbench transaction does one `SELECT` (read current version for a partition/key) plus one `UPDATE` (CAS: bump status and version, conditioned on the version read). Run with 10 clients, 4 threads, 30 seconds.

For the headroom variant, a second pod ran a curl loop for the same 30 seconds, issuing `GET /clusters?page=1&size=10` and `GET /nodepools?page=1&size=10` against the API service (no auth needed, dev JWT is disabled), producing roughly 19 requests/sec of concurrent read load.

**Measured (desire only):** ~660–686 writes/sec on dev Postgres (500m CPU / 512Mi), ~29x below worst-case.

**Measured (desire + API traffic):** ~621 writes/sec with concurrent API read traffic (~19 requests/sec to `/clusters` and `/nodepools`). Drop of ~5–10% compared to desire-only.

**Interpretation:** Light API traffic does not significantly contend with desire-store writes. The ~29x gap to worst-case is the dominant issue, not API headroom. Dedup ([HYPERFLEET-1428](https://redhat.atlassian.net/browse/HYPERFLEET-1428)) remains required to close that gap; a production-sized load test would narrow remaining uncertainty.

## Deployment footprint

Sharing the API's Postgres adds zero new stateful services per environment; the desire store is just a schema on infrastructure that already exists. A separate backend (Redis or otherwise) means every environment, including on-prem environments where every stateful service counts, needs its own install, monitoring, backup, and upgrade path for one more stateful service. This is the main argument for sharing: one fewer stateful service in the delivery stack.

## Shared instance vs separate

| | Shared API Postgres | Separate backend (e.g. Redis) |
|--|---------------------|----------------------------------|
| Stateful services | None added, reuses existing Postgres | +1 per environment to install, monitor, back up, upgrade |
| Load isolation | One Postgres outage or overload hits API and desire store together | Desire store load does not share the API Postgres instance |
| On-prem | One fewer stateful service in constrained deployments | Extra stateful service to operate |
| Implementation | New schema and role setup only; no new client library | New client integration, own backup and failover plan |

**Recommendation (provisional):** Share the API's Postgres now; the schema/role setup itself is low-risk. Treat shared capacity as *unproven*: it is gated on (1) demonstrated dedup effectiveness ([HYPERFLEET-1428](https://redhat.atlassian.net/browse/HYPERFLEET-1428)) and (2) a production-sized benchmark running API and desire workloads concurrently. Flip to a separate backend if either gate fails or dedup does not land before the backend is built.

## Schema and role sketch

Table, indexes, and role grants validated above, for reference when a future backend story implements the store.

```sql
CREATE TABLE desire_store.desires (
    partition_key text NOT NULL,        -- one partition per managed cluster
    desire_key text NOT NULL,
    kind text NOT NULL CHECK (kind IN ('apply', 'delete', 'read')),
    spec jsonb,                         -- adapter-owned
    status jsonb,                       -- applier-owned
    version integer NOT NULL DEFAULT 0, -- bumped on every write; used for compare-and-swap
    PRIMARY KEY (partition_key, desire_key)
);

CREATE INDEX desires_partition_idx ON desire_store.desires (partition_key);
CREATE INDEX desires_partition_key_prefix_idx
    ON desire_store.desires (partition_key, desire_key text_pattern_ops);

CREATE ROLE adapter_role NOLOGIN;
CREATE ROLE applier_role NOLOGIN;
GRANT USAGE ON SCHEMA desire_store TO adapter_role, applier_role;

-- Adapter: read all; write spec + version only; delete for lifecycle cleanup
GRANT SELECT, INSERT (partition_key, desire_key, kind, spec, version)
    ON desire_store.desires TO adapter_role;
GRANT UPDATE (spec, version) ON desire_store.desires TO adapter_role;
GRANT DELETE ON desire_store.desires TO adapter_role;

-- Applier: read all; write status + version only
GRANT SELECT ON desire_store.desires TO applier_role;
GRANT UPDATE (status, version) ON desire_store.desires TO applier_role;
```
