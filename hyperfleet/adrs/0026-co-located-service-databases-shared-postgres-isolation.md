---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-10-01
---

# 0026 — Co-Located Service Databases on Shared Postgres: Isolation Model

## Context

HyperFleet's recommended and tested PostgreSQL layout gives the API, the Desire Store, and the PostgreSQL backend for the Broker their own databases on one shared instance. Partners may provision PostgreSQL differently; the components consume connection Secrets ([ADR-0019](0019-package-hyperfleet-as-operator.md)). The layout needs one isolation unit: a schema inside the API database and a separate database are not equivalent, because `CONNECT` is a per-database privilege and ordinary primary-side transaction horizons are per database. The Desire Store and the PostgreSQL backend for the Broker need one answer to build against.

## Decision

**One dedicated database per service on the shared instance.** The recommended PostgreSQL layout uses three separate databases on the same OCI Database with PostgreSQL instance:

- `hyperfleet` — the API database (its current name in the API Helm chart)
- `desire_store` — the Desire Store database
- `event_store` — the database used by the PostgreSQL backend for the Broker

They do not share a database and do not use schema isolation within databases. `CONNECT` is granted only to the roles that need a database, and never to a service role on `hyperfleet`, so a compromised service credential cannot open a session against the system-of-record database.

In this layout, components consume connection Secrets for their databases; the separate-database isolation is what HyperFleet recommends and tests, not a constraint on how a partner provisions PostgreSQL. This record does not require the Broker's RabbitMQ or Pub/Sub backends to use a PostgreSQL database.

This record **supersedes ADR-0023's database naming only** (ADR-0023 is otherwise unchanged): where ADR-0023 wrote `hyperfleet-api`, River (queue), and the desire store, the canonical identifiers are the three above. Alignment of the API Helm chart and the external Secret on `hyperfleet` belongs to the design's [canonical identifiers](../docs/co-located-service-databases-postgres-design.md#databases-and-canonical-identifiers), not this decision.

In the recommended layout, the Desire Store uses the dedicated `desire_store` database. The [desire store spike](../docs/desire-store-api-postgres-spike.md) remains evidence for feasibility and load profile, but its schema-inside-the-API-database recommendation is not implementation guidance for this layout: this record supersedes it as the isolation unit.

See [Co-Located Service Databases on the Shared Postgres Instance — Design](../docs/co-located-service-databases-postgres-design.md) for the full design: canonical identifiers, role and ACL model, connection budget and sizing, operational rules, alerts, and migration ownership.

## Consequences

### Gains

- **Hard security boundary (in the model we ship):** no service role holds `CONNECT` on `hyperfleet`, so a compromised service credential cannot reach the API's system-of-record state. This is the strongest boundary available while the instance is shared and the main reason to prefer separate databases over schemas; a dedicated instance per service would isolate further (see Trade-offs). Where the Desire Store runs inside the API pods, one pod holds both credentials, so the boundary holds per credential, not per process.
- **Independent primary-side transaction horizons for ordinary tables:** an ordinary transaction in one database does not pin snapshot cleanup in another; this does not isolate replication-related retention or shared instance resources (see the design's [transaction profile](../docs/co-located-service-databases-postgres-design.md#transaction-profile)).
- **Independent schema, roles, and connection budgets:** each service owns its schema, indexes, partitioning, migration path, and pool sizing. The platform admin or partner applies the PostgreSQL `CONNECTION LIMIT` for each database.

### Trade-offs

- **No cross-database transactions or joins:** a transaction cannot span the three databases, and the API cannot join a service's tables directly; access to a service's data stays behind the owning service ([ADR-0022](0022-api-mediated-desire-store-access.md) for the Desire Store).
- **One pool split three ways:** per-database `CONNECTION LIMIT` divides the instance's connections into fixed budgets, so a busy database cannot borrow idle capacity from another.
- **Instance-scope coupling remains:** databases still share the instance's CPU, I/O, WAL, backup/restore, and failure domain; their operational handling lives in the design's [trade-offs](../docs/co-located-service-databases-postgres-design.md#design-trade-offs).

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| **Schema isolation within a single database** | `CONNECT` permits a session but does not grant schema `USAGE` or table access; cross-schema reads depend on ACLs, ownership, role membership, default privileges, and `search_path`, which is a larger configuration surface where a misconfiguration could expose API objects. A shared database also shares its vacuum horizon. |
| **Separate Postgres instance per service** | Removes the shared failure domain but triples infrastructure cost and per-instance backup, failover, upgrade, and monitoring, and makes on-prem deployments operationally unfeasible. Reserved as a future move (see the design's scaling section) rather than the default. |

## References

- [Co-Located Service Databases on the Shared Postgres Instance — Design](../docs/co-located-service-databases-postgres-design.md) — the full design this record decides on
- [SPIKE: Evaluate Running the Desire Store on the API Postgres](../docs/desire-store-api-postgres-spike.md) — load profile and feasibility evidence
- [ADR-0023: OCI Database with PostgreSQL as the Managed Instance for the Oracle Deployment Path](0023-oci-managed-postgresql.md) — instance provisioning, HA, admin role boundary
- [ADR-0019: Package HyperFleet as a Kubernetes Operator](0019-package-hyperfleet-as-operator.md) — partner-provided PostgreSQL contract
- [ADR-0022: API-Mediated Desire Store Access](0022-api-mediated-desire-store-access.md) — Applier access model (API-mediated, not direct DB)
- [ADR-0033: PostgreSQL Transport Security](0033-postgres-transport-security.md) — server identity verification for the connections this layout's roles open
