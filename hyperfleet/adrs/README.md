---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-05-11
---

# Architecture Decision Records (ADRs)

> This directory contains Architecture Decision Records (ADRs) for HyperFleet. Each ADR captures a significant decision, why it was made, and what was rejected.

---

## When to Write an ADR

Write an ADR when a decision:

- Affects multiple components or teams
- Is hard to reverse
- Has meaningful trade-offs between alternatives
- Would leave future contributors wondering "why did they do it this way?"

Do **not** write an ADR for implementation details, config changes, or decisions that are obvious from the code.

---

## Naming Convention

```text
NNNN-short-title.md
```

Examples: `0001-use-cloudevents-for-adapter-pulses.md`, `0002-sentinel-pull-model.md`

Numbers are sequential. Use the next available number.

---

## Template

Copy this into your new ADR file:

```markdown
---
Status: Proposed | Active | Deprecated
Owner: <team>
Last Updated: YYYY-MM-DD
---

# NNNN — Title of Decision

## Context

What is the problem or situation forcing this decision?
One short paragraph.

## Decision

What did we decide? State it plainly.

## Consequences

**Gains:** What becomes easier or better.
**Trade-offs:** What becomes harder or worse.

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| Option A    | Reason       |
| Option B    | Reason       |
```

---

## ADR Index

| ADR | Title | Status | Date |
|-----|-------|--------|------|
| [0001](0001-cloudevents-as-event-format.md) | CloudEvents as the Inter-Component Event Format | Active | 2026-04-15 |
| [0002](0002-pluggable-message-broker-library.md) | Pluggable Message Broker via hyperfleet-broker Library | Active | 2026-04-15 |
| [0003](0003-openapi-first-contract.md) | OpenAPI 3.0 as the System Contract (API-First Development) | Active | 2026-04-15 |
| [0004](0004-sentinel-stateless-polling-architecture.md) | Sentinel as a Stateless Polling Reconciliation Loop | Active | 2026-04-15 |
| [0005](0005-config-driven-adapter-framework.md) | Config-Driven Adapter Framework (Single Binary, Multiple Deployments) | Active | 2026-04-15 |
| [0006](0006-cel-expression-engine.md) | CEL as the Shared Expression Evaluation Engine | Active | 2026-04-15 |
| [0007](0007-conditions-based-status-model.md) | Kubernetes-Style Conditions-Based Status Model | Active | 2026-04-15 |
| [0008](0008-dynamic-status-aggregation.md) | Dynamic Status Aggregation (Compute on Write) | Active | 2026-04-16 |
| [0009](0009-uuid-v7-resource-identifiers.md) | UUID v7 for Cluster and NodePool Identifiers | Active | 2026-04-15 |
| [0010](0010-jsonb-provider-agnostic-spec.md) | JSONB for Provider-Agnostic Cluster and NodePool Spec Storage | Active | 2026-04-15 |
| [0011](0011-testcontainers-for-integration-tests.md) | Testcontainers for Integration Tests | Active | 2026-04-16 |
| [0012](0012-hard-delete-mechanism-after-adapter-reconciliation.md) | Hard-Delete Ownership and Execution | Proposed | 2026-04-23 |
| [0013](0013-force-delete-scope-db-only.md) | Force Delete Scope: Database-Only | Proposed | 2026-05-01 |
| [0014](0014-konflux-build-and-release.md) | Konflux for Container Image Build and Release | Active | 2026-04-21 |
| [0015](0015-eventual-consistency-for-read-path.md) | Eventual Consistency for the API Read Path | Active | 2026-05-08 |
| [0016](0016-helm-oci-distribution.md) | Helm OCI Distribution via Konflux | Active | 2026-05-11 |
| [0017](0017-adapter-error-taxonomy.md) | Selective Message Acknowledgment in Adapters | Active | 2026-05-25 |
| [0018](0018-e2e-jwt-tls-architecture.md) | E2E JWT/TLS Architecture | Active | 2026-07-07 |
| [0019](0019-package-hyperfleet-as-operator.md) | Package HyperFleet as a Kubernetes Operator | Proposed | 2026-08-11 |
| [0020](0020-envoy-authorino-api-gateway.md) | Envoy and Authorino as the API Authentication Gateway | Active | 2026-08-11 |
| [0021](0021-oci-external-platform.md) | External Platform for the Guest in OCI Hosted Clusters | Active | 2026-09-01 |
