---
Status: Proposed
Owner: HyperFleet Architecture Team
Last Updated: 2026-10-29
---

# 0033 — PostgreSQL Transport Security: Server Identity Verification for Direct Connections

## Context

[HYPERFLEET-1709](https://redhat.atlassian.net/browse/HYPERFLEET-1709) decides the transport-security contract for the direct PostgreSQL connections in the [ADR-0026](0026-co-located-service-databases-shared-postgres-isolation.md) layout:

- **Who connects directly:** the API, the Desire Store, and the Broker library inside Sentinel and Adapters, each with its migration executor. `hyperfleet-operator` opens no connection.
- **Current state:** encryption is a recommendation today, not a requirement — the charts default to `sslmode=disable` — and the [co-located databases design](../docs/co-located-service-databases-postgres-design.md) deferred the verification question to this record.
- **The gap:** authentication, not confidentiality. `sslmode=require` encrypts but does not authenticate the server, so an attacker who can intercept or redirect the connection receives the role's credentials while impersonating PostgreSQL. ADR-0026's role split limits what a stolen runtime credential reaches, but migration credentials own their database's schema — credentials worth stealing cross every direct hop.
- **The proxy case:** not every deployment connects directly — some front PostgreSQL with a TLS-terminating proxy or connection pooler, so the floor needs an exception defining when that is acceptable.

## Decision

Direct connections must verify the server's identity: `sslmode=verify-full` against a certificate authority (CA) the deployment trusts — certificate chain plus hostname check — or the driver's equivalent. `sslmode=require` and `sslmode=disable` are not acceptable for direct connections. The floor is uniform across connection classes:

| Connection class | Connections | Minimum mode |
|------------------|-------------|--------------|
| API runtime | API pods to `hyperfleet` | `verify-full` |
| API migrations | `db-migrate` init container to `hyperfleet` | `verify-full` |
| Desire Store runtime | Desire Store service pods to `desire_store` | `verify-full` |
| Desire Store migrations | migration executor to `desire_store` | `verify-full` |
| Broker runtime | `hyperfleet-broker` pools in Sentinel and Adapters to `event_store` | `verify-full` |
| Broker migrations | migration executor to `event_store` | `verify-full` |

**CA distribution:**

- The instance owner supplies the CA bundle alongside the connection details, and the component charts mount it as configuration.
  - The instance owner is the platform admin or partner in [ADR-0026](0026-co-located-service-databases-shared-postgres-isolation.md)'s model, or HyperFleet itself on the Oracle path ([ADR-0023](0023-oci-managed-postgresql.md)).
- Only public CA certificates are distributed to clients in the trust bundle.
- CA private keys remain with the certificate issuer and are never placed in client Secrets, images, or pods.

**CA rotation:**

- The bundle may hold more than one CA, so rotation needs no coordination window:
  - Add the new CA to every client trust bundle.
  - Restart each client or reload its trust configuration.
  - Verify that all six connection classes trust the new CA before switching the server certificate.
  - Remove the old CA after the server and every client use the new trust configuration.
- Each connection class must document its trust-reload mechanism. A pod restart is acceptable when live reload is not supported; live reload is not required.

**Proxy-terminated TLS exception:**

A deployment may terminate database TLS in a proxy or connection pooler (e.g., PgBouncer) instead of verifying end to end, but only when all of the following hold:

- The unverified hop uses same-pod loopback or a Unix socket; it must not cross a node, namespace, or Service network.
- The proxy-to-PostgreSQL connection uses `sslmode=verify-full`, or the equivalent certificate-chain and hostname verification in the proxy, with an explicit trusted CA bundle. Encryption-only or CA-only validation is insufficient.
- The deployment documents the boundary: where TLS terminates, what is verified, and what confines the unverified hop.

For example, a proxy listening on the pod's loopback interface: the application connects to it over plaintext, the unverified hop never leaves the pod, and the proxy holds the verified connection to the database.

**Scope and enforcement:**

- The floor applies to the reference deployment and to partner-provided instances alike: the partner supplies the CA with the connection contract ([ADR-0019](0019-package-hyperfleet-as-operator.md)), and an instance that cannot meet the floor goes through the partner-contract path ([HYPERFLEET-1710](https://redhat.atlassian.net/browse/HYPERFLEET-1710)) rather than a silent downgrade.
- Shipped chart defaults move to the floor, so a missing CA bundle fails the connection at startup — fail closed.
- Ephemeral local development (kind's embedded PostgreSQL, testcontainers) may opt down to `sslmode=disable` explicitly in dev-only values; every other exception is the documented proxy path above.
- Chart and coverage changes are implementation work outside this record.

## Consequences

**Gains:**

- Impersonation is closed on every direct hop: role credentials are delivered only to a verified server.
- The transport boundary is checkable: nothing silently degrades to plaintext or unverified encryption.
- One rule for all three databases, aligned with [ADR-0026](0026-co-located-service-databases-shared-postgres-isolation.md)'s per-database roles; no per-chart policy drift.

**Trade-offs:**

- New setup toil: every persistent environment must distribute the instance's CA before components connect; a deployment that omits it breaks, by design.
- CA lifecycle becomes operational work: expiry must be tracked and rotation staged, or connections fail cluster-wide.
- Deployments relying on today's `sslmode=disable` defaults break on upgrade until they supply a CA bundle or take a documented exception.
- Private networking no longer carries the argument alone: environments that leaned on it must present a verifiable certificate.

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| `sslmode=require` as the floor (encrypt, do not verify) | Encrypts the hop but leaves the server unauthenticated, so the impersonation threat stands. |
| `sslmode=verify-ca` as the floor (chain check, no hostname check) | A valid certificate for a different endpoint satisfies it; without the hostname check the connection is not bound to the instance it dialed. |
| Network controls only (the always-private OCI endpoint, VCN isolation, security groups) | Reachability is not identity: misrouting or a compromised peer inside the private network still impersonates PostgreSQL, and the hop is plaintext. |
| Mutual TLS (client certificates as well as server verification) | Stronger, but pushes certificate issuance and rotation onto every service role; this contract's gap is server identity, and role credentials already authenticate the client. A future option if credential-based client authentication is replaced. |
| Leave the floor to the partner contract ([HYPERFLEET-1710](https://redhat.atlassian.net/browse/HYPERFLEET-1710)) | The partner contract governs partner-provided instances; the reference deployment needs the floor in its own charts and connection configuration regardless, and the contract can only verify what this record defines. |
