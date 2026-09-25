---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-09-24
---

# 0026 — Co-Located Service Databases on Shared Postgres: Isolation Model

## Context

The **Desire Store** and the **Event Transport** are both landing on the API's PostgreSQL instance. Sharing the instance was settled under [HYPERFLEET-1520](https://redhat.atlassian.net/browse/HYPERFLEET-1520) on the evidence of the [desire store spike](../docs/desire-store-api-postgres-spike.md) and the Event Transport proof of concept, but neither settled the **isolation unit**: the spike used a schema inside the API database, the proof of concept used a separate database, and the two are not equivalent — `CONNECT` is a per-database privilege and vacuum horizons are per database. Both service designs need one answer to build against.

## Decision

**One dedicated database per service on the shared instance.** The API, the Desire Store, and the Event Transport are three separate databases on the same OCI Database with PostgreSQL instance:

- `hyperfleet` — the API database (its current name in the API Helm chart)
- `desire_store` — the Desire Store database
- `event_transport` — the Event Transport database

They do not share a database and do not use schema isolation within databases. `CONNECT` is granted only to the roles that need a database, and never to a service role on `hyperfleet`, so a compromised service credential cannot open a session against the system-of-record database.

This record **supersedes ADR-0023's database naming only** (ADR-0023 is otherwise unchanged): where ADR-0023 wrote `hyperfleet-api`, River (queue), and the desire store, the canonical identifiers are the three above. Aligning the chart and external Secret on `hyperfleet` (they currently differ) is tracked in [HYPERFLEET-1711](https://redhat.atlassian.net/browse/HYPERFLEET-1711), not part of this decision.

[HYPERFLEET-1671](https://redhat.atlassian.net/browse/HYPERFLEET-1671) must build the Desire Store against the dedicated `desire_store` database. The [desire store spike](../docs/desire-store-api-postgres-spike.md) remains evidence for feasibility, load profile, and the initial role and grant sketch, but its schema-inside-the-API-database recommendation is not implementation guidance: this record supersedes it as the isolation unit.

See [Co-Located Service Databases on the Shared Postgres Instance — Design](../docs/co-located-service-databases-postgres-design.md) for the full design: canonical identifiers, role and ACL model, connection budget and demand validation, operational rules, alerts, migration ownership, and the service cutover procedure.

## Consequences

### Gains

- **Hard security boundary:** no service role holds `CONNECT` on `hyperfleet`, so a compromised service credential cannot reach the API's system-of-record state. This is the strongest boundary available while the instance is shared, and the main reason to prefer separate databases over schemas; a dedicated instance per service would isolate further (see Trade-offs).
- **Independent vacuum horizons for ordinary tables:** a long transaction in one database cannot pin snapshot cleanup in another.
- **Independent schema, roles, and limits:** each service owns its schema, indexes, partitioning, migration path, and per-database connection limit without collision.

### Trade-offs

- **More objects to operate:** three databases and their role and ACL sets to provision, monitor, and keep aligned, versus one database with schemas.
- **No cross-database queries:** the API cannot join a service's tables directly; access to a service's data stays behind the owning service ([ADR-0022](0022-api-mediated-desire-store-access.md) for the Desire Store).
- **Instance-scope coupling remains:** databases still share the instance's CPU, I/O, WAL, backup/restore, and failure domain. Those follow from the sharing decision ([HYPERFLEET-1520](https://redhat.atlassian.net/browse/HYPERFLEET-1520)), and their operational handling lives in the design's [trade-offs](../docs/co-located-service-databases-postgres-design.md#design-trade-offs).

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| **Schema isolation within a single database** | `CONNECT` permits a session but does not grant schema `USAGE` or table access; cross-schema reads depend on ACLs, ownership, role membership, default privileges, and `search_path`, which is a larger configuration surface where a misconfiguration could expose API objects. A shared database also shares its vacuum horizon. |
| **Separate Postgres instance per service** | Removes the shared failure domain but triples infrastructure cost and per-instance backup, failover, upgrade, and monitoring, and makes on-prem deployments operationally unfeasible. Reserved as a future move (see the design's scaling and cutover sections) rather than the default. |

## References

- [Co-Located Service Databases on the Shared Postgres Instance — Design](../docs/co-located-service-databases-postgres-design.md) — the full design this record decides on
- [SPIKE: Evaluate Running the Desire Store on the API Postgres](../docs/desire-store-api-postgres-spike.md) — the evidence behind sharing the instance
- [ADR-0023: OCI Database with PostgreSQL as the Managed Instance for the Oracle Deployment Path](0023-oci-managed-postgresql.md) — instance provisioning, HA, admin role boundary
- [ADR-0022: API-Mediated Desire Store Access](0022-api-mediated-desire-store-access.md) — Applier access model (API-mediated, not direct DB)
- [HYPERFLEET-1520](https://redhat.atlassian.net/browse/HYPERFLEET-1520) — the sharing decision this record takes as settled
- [HYPERFLEET-1671](https://redhat.atlassian.net/browse/HYPERFLEET-1671) (Desire Store backend implementation) and [HYPERFLEET-1656](https://redhat.atlassian.net/browse/HYPERFLEET-1656) (Event Transport design spike) — cite this ADR and the design as fixed input
- [HYPERFLEET-1672](https://redhat.atlassian.net/browse/HYPERFLEET-1672) — shared-instance contention benchmark
- [HYPERFLEET-1709](https://redhat.atlassian.net/browse/HYPERFLEET-1709) — Postgres transport security (server identity verification)
- [HYPERFLEET-1710](https://redhat.atlassian.net/browse/HYPERFLEET-1710) — enforcing the contract on partner-provided instances
- [HYPERFLEET-1711](https://redhat.atlassian.net/browse/HYPERFLEET-1711) — aligning the chart and external Secret on `hyperfleet`
