---
Status: Active
Owner: HyperFleet QE Team
Last Updated: 2026-09-25
---

# Spike Report: E2E Test Alignment with the Generic Resource Model

**JIRA:** [HYPERFLEET-1378](https://redhat.atlassian.net/browse/HYPERFLEET-1378)
**Follow-up:** [HYPERFLEET-1713](https://redhat.atlassian.net/browse/HYPERFLEET-1713)
**Date:** 2026-09-24

## Overview

After [hyperfleet-api#291](https://github.com/openshift-hyperfleet/hyperfleet-api/pull/291) migrated clusters and nodepools to a generic resource model, the E2E suite broke `stuck_deletion` because a helper read a Helm values path (`config.adapters.required.cluster`) that no longer existed. This spike evaluates whether the E2E suite should move from entity-specific naming and behavior to generic entity-model concepts.

**Decision: partially adopt generic behavioral tests (hybrid).**

- Cross-cutting resource semantics that the API now implements generically — delete policy (`restrict` / `cascade`), reference restriction, name uniqueness, generation — move to a **descriptor-driven behavioral test kit** shared by all entity types. Assertions that need only a single service or the DB (response shapes, generation logic, soft-deleted visibility) stay at Unit/Integration per [Test Placement Strategy](test-placement-strategy.md).
- Entity-specific suites are **kept** where the behavior is genuinely entity-specific: the reconcilable pipeline (Cluster and NodePool), per-entity performance baselines, and the adapter/Maestro transport suites.
- Infrastructure helpers are **decoupled from chart internals** so the regression class that triggered this spike is caught at build time instead of only in the nightly run.

The rationale and rejected alternatives are in [Section 4](#4-decision-and-rationale). The implementation scope is tracked in [HYPERFLEET-1713](https://redhat.atlassian.net/browse/HYPERFLEET-1713).

---

## 1. Problem Statement

The HyperFleet API no longer has per-entity code paths. All managed entity types are stored as a single `Resource` with a `kind` discriminator, and a declarative `EntityDescriptor` drives routes, spec validation, status aggregation, delete policy, required adapters, and references — see [Generic Resource Registry — Design Document](../generic-resource-registry-design.md).

The E2E suite, however, still has one package and one set of client wrappers per entity type (`e2e/cluster`, `e2e/nodepool`, `e2e/channel`, `e2e/version`, `e2e/wifconfig`). The question this spike answers:

> Should the E2E suite shift from entity-specific naming and behavior to generic entity-model concepts ("parent with cascade delete policy", "resource with required adapters", "resource without adapters"), or keep entity-specific tests?

The trigger event was an E2E regression described in [HYPERFLEET-1396](https://redhat.atlassian.net/browse/HYPERFLEET-1396): `UpgradeAPIRequiredAdapters` patched `config.adapters.required.cluster`, which the new chart no longer renders. After the migration the correct location is `config.entities[].required_adapters`, so the Helm upgrade became a no-op and `crash_recovery` and `stuck_deletion` stopped validating adapter gating. The one-off was fixed in [hyperfleet-e2e#148](https://github.com/openshift-hyperfleet/hyperfleet-e2e/pull/148); this spike asks whether the broader suite should change.

---

## 2. Current State

Unless noted otherwise, file paths in this section are relative to the `hyperfleet-e2e` repository (this architecture repository contains no Go code); `hyperfleet-api/...` paths are relative to the `hyperfleet-api` repository.

### 2.1 API layer is generic

| Concern | API behavior |
|---------|--------------|
| Storage | One `resources` table; `kind` discriminator (`Cluster`, `NodePool`, `Channel`, `Version`, `WifConfig`) |
| Routing | Auto-generated per descriptor `plural`, with nested routes for children (`/clusters/{id}/nodepools`) |
| Delete policy | `on_parent_delete`: `cascade` (NodePool under Cluster) or `restrict` (Version under Channel) |
| References | Declarative non-ownership associations; deleting a referenced resource returns `409` (Cluster → WifConfig, declared in the infra base API config, not in the chart defaults) |
| Required adapters | `entities[].required_adapters`, set per deployment; empty in the current chart for Channel, Version, and WifConfig |
| Reconciliation | Kinds with a non-empty `required_adapters` list (Cluster and NodePool in the current deployment) reach `Reconciled` via Sentinel → adapters |

Source: `hyperfleet-api/charts/values.yaml` and [generic-resource-registry-design.md](../generic-resource-registry-design.md).

Soft-delete applies only to kinds that declare required adapters: their DELETE marks the row deleted and waits for adapter `Finalized` before hard-delete. Kinds with no required adapters (Channel, Version, WifConfig in the current chart) are hard-deleted inside the DELETE transaction. The delete *outcome* is therefore not fully generic — see [Section 5.1](#51-becomes-generic-descriptor-driven).

### 2.2 E2E client is already generic

The client core is generic: `CreateResource(ctx, path, body)`, `GetResource`, `PatchResource`, `DeleteResource`, `ForceDeleteResource`, and a generic `Resource` / `ResourceList` / `AdapterStatus` model (`pkg/client/resource.go`, 289 lines). The per-entity files are thin logging wrappers over that core:

| Wrapper | Lines |
|---------|-------|
| `pkg/client/cluster.go` | 84 |
| `pkg/client/nodepool.go` | 78 |
| `pkg/client/channel.go` | 52 |
| `pkg/client/version.go` | 52 |
| `pkg/client/wifconfig.go` | 52 |
| **Total wrappers** | **318** (on top of the 289-line generic core) |

So the transport layer already models the generic API. The duplication is in the **test layer**, not the client.

### 2.3 Entity-specific test layer

`e2e/` currently contains 63 `Describe` blocks and 81 `It` blocks across five entity packages plus an adapter package:

| Package | Files | Describe blocks |
|---------|-------|-----------------|
| `e2e/cluster` | 19 | 25 |
| `e2e/nodepool` | 9 | 11 |
| `e2e/channel` | 7 | 7 |
| `e2e/version` | 6 | 6 |
| `e2e/wifconfig` | 7 | 8 |
| `e2e/adapter` | 3 | 6 |
| `e2e/auth` (out of scope — JWT enforcement/renewal, not entity behavior) | 5 | 4 |

### 2.4 Duplication inventory

Three classes of behavior are duplicated across the E2E suite even though the API implements them once:

1. **CRUD lifecycle** — `channel/crud_lifecycle.go`, `version/crud_lifecycle.go`, and `wifconfig/crud_lifecycle.go` are structurally identical (create → get → list → patch spec → patch labels → delete). Each is 100-125 lines; only the spec payload and, for Version, the parent Channel setup and nested paths differ. Cluster and NodePool have their own variants with reconciliation assertions.
2. **Delete policy** — the generic delete semantics are exercised in three separate files: `channel/delete_restrict.go` (Version child, `restrict`), `cluster/delete.go` (NodePool child, `cascade`), and `wifconfig/deletion_protection.go` (Cluster reference, `409`). These are exactly the three semantics the generic delete model defines.
3. **Expected required adapters** — `pkg/config` keeps per-entity `AdaptersConfig{Cluster, NodePool}` used for assertions, duplicating the API's `entities[].required_adapters` list.

### 2.5 The regression that triggered this spike

`pkg/helper/api_config.go` reads Helm release values, mutates `config.entities[].required_adapters`, and re-applies. The current helper selects the entity by `kind` and errors when the kind is missing (the guard added in #148), so a removed kind fails loudly; the residual coupling is to the chart's value field names rather than to an API contract. The coupling is orthogonal to test naming: a fully generic suite would have hit the same bug. This is why the decision addresses the helper seam explicitly.

---

## 3. Evaluation of Options

| Option | Description | Strengths | Weaknesses |
|--------|-------------|-----------|------------|
| A — Keep entity-specific | Status quo; fix the one-off helper bug | Tests mirror real user journeys and per-entity API paths; existing tier labels map cleanly to journeys | Duplicated behavior grows with each entity type; new kinds need dedicated suites; helpers can couple to infra |
| B — Full generic shift | Replace entity-specific suites wholesale with generic entity-model tests | Maximum reuse; new entity type adds only a descriptor row | Would erase valuable reconciliation and user-journey coverage; large refactor; only Cluster/NodePool are reconcilable, so generic phrasing fits most tests poorly |
| C — Hybrid (chosen) | Descriptor-driven generic kit for shared semantics; keep entity-specific suites for reconcilable pipeline, perf, and transport | Removes the duplicated majority; new kinds get coverage for free; preserves real-journey tests; bounded refactor | Requires one descriptor source of truth and a clear authoring rule for "generic vs entity-specific" |

---

## 4. Decision and Rationale

**Adopt Option C.** The E2E suite should use generic entity-model patterns for behavior the API models generically, and entity-specific patterns only for behavior that is genuinely entity-specific.

Rationale:

1. **The API contract is generic.** CRUD, generation, reference restriction, and `restrict`/`cascade` enforcement are the same for every `kind`; the delete *outcome* (soft vs hard) depends on the kind's required adapters. Testing the generic parts through five copies of the same logic adds maintenance cost without adding coverage. A new entity type should gain this coverage by adding one descriptor row, not a new suite.
2. **But not all behavior is generic.** Only Cluster and NodePool are reconcilable (required adapters, Sentinel events, `Reconciled`/`Finalized`, hard-delete, namespace cleanup). Channel/Version/WifConfig are non-reconcilable synchronous resources. Generic phrasing would obscure these real differences and weaken Tier0 user-journey tests.
3. **The regression class is separate.** HYPERFLEET-1396 was caused by a helper binding to chart internals, not by entity naming. The decision therefore also mandates a stable config seam plus a contract test, so the next chart restructure is caught at build time rather than only in the nightly run.
4. **Cost/benefit favors partial adoption now.** The suite is young (Ginkgo v2 + Gomega chosen in [e2e-testing-framework-spike-report.md](e2e-testing-framework-spike-report.md)) and the generic model is still settling; refactoring the duplicated majority now is cheaper than after more entity types land.

### Rejected alternatives

| Alternative | Why rejected |
|-------------|--------------|
| Keep entity-specific (Option A) | Leaves three near-identical CRUD suites and per-entity delete-policy duplication in place; every new kind pays the same cost again |
| Full generic shift (Option B) | Discards legitimate reconciliation and journey coverage; the majority of Cluster/NodePool tests describe reconcilable behavior that has no generic equivalent |
| Do nothing until a new entity type lands | Defers a known, quantified duplication (see [Section 2.4](#24-duplication-inventory)) and leaves the helper coupling unguarded |

---

## 5. Scope of Adoption

### 5.1 Becomes generic (descriptor-driven)

| Generic behavior | Replaces | Driven by |
|------------------|----------|-----------|
| Full-lifecycle journeys over the deployed stack: create → delete, plus re-create after full hard-delete. The adapters/status step applies only to descriptors with a non-empty `required_adapters` list | `channel`, `version`, `wifconfig` `crud_lifecycle.go` | descriptor table |
| Delete policy through the deployed pipeline: parent delete removes children — soft-deleted then hard-deleted when the child has required adapters, hard-deleted in the DELETE transaction otherwise | `channel/delete_restrict.go`; the cascade assertions duplicated from `cluster/delete.go` (Cluster keeps its reconcilable hard-delete and namespace assertions) | descriptor `on_parent_delete` |
| Reference restriction: 409 while referenced | `wifconfig/deletion_protection.go` | descriptor `references` |
| Delete edge cases that require the deployed stack: name reuse after full hard-delete; idempotent re-DELETE on soft-deleted kinds | `cluster` delete-edge-case tests (re-DELETE idempotency, recreate after hard-delete) | descriptor table |

Layer placement follows [Test Placement Strategy](test-placement-strategy.md): HTTP response shapes (including `404` for a non-existent resource), `PATCH` generation/no-op logic, and DB-level cascade propagation stay in the service repos' Unit/Integration suites and are not re-tested here.

### 5.2 Stays entity-specific

| Suite | Why |
|-------|-----|
| Cluster/NodePool reconciliation: `Reconciled`/`Finalized`, adapter statuses, hard-delete, namespace cleanup | Reconcilable pipeline semantics unique to these kinds |
| `stuck_deletion`, `adapter_failure`, `crash_recovery`, `force_delete` | Entity-specific orchestrator/adapter failure behavior |
| Per-entity performance suites (`perf_*`) | Per-entity baselines and thresholds |
| Adapter/Maestro transport suites | Not resource CRUD |
| `e2e/nodepool` sibling isolation during deletion | Needs the reconcilable pipeline (sibling adapter statuses); only `Describe` in `nodepool/delete_edge_cases.go` |

### 5.3 Infrastructure seam

The required-adapters helper must stop reading a Helm values path. The follow-up will replace the direct read-modify-write with a stable interface to the deployed API config — for example, read/patch the API ConfigMap and roll the deployment — and add a contract test that fails when the config schema drifts. There is no API config endpoint today, and descriptors are loaded at startup, so any config change still requires a rollout; the gain is a schema-checked seam and an earlier failure, not a live reload.

---

## 6. Follow-up Implementation Ticket

[HYPERFLEET-1713](https://redhat.atlassian.net/browse/HYPERFLEET-1713) tracks the implementation: descriptor table, generic behavioral kit, refactor of the duplicated suites, the config-seam contract test, and the authoring guideline in `test-design/`.

---

## 7. Consequences and Risks

| Consequence | Mitigation |
|-------------|------------|
| Generic tests can become vague and lose real-journey meaning | Keep entity-specific reconcile/journey suites; document the "generic vs entity-specific" rule |
| Descriptor table can drift from the API's descriptors | Source it from the deployed API config and guard with a contract test |
| Refactor may temporarily reduce coverage | Refactor one behavior class at a time, keeping existing assertions until the generic suite passes |
| Non-reconcilable vs reconcilable split is implicit | Derive `reconcilable` from a non-empty `required_adapters` in the sourced config rather than hand-encoding it |

---

## 8. References

- [HYPERFLEET-1378](https://redhat.atlassian.net/browse/HYPERFLEET-1378) — this spike
- [HYPERFLEET-1396](https://redhat.atlassian.net/browse/HYPERFLEET-1396) — trigger bug (`UpgradeAPIRequiredAdapters` obsolete Helm path)
- [HYPERFLEET-1713](https://redhat.atlassian.net/browse/HYPERFLEET-1713) — follow-up implementation ticket
- [Generic Resource Registry — Design Document](../generic-resource-registry-design.md)
- [Spike Report: E2E Testing Framework](e2e-testing-framework-spike-report.md)
- [Spike Report: E2E Test Automation Run Strategy](e2e-run-strategy-spike-report.md)
- [Test Placement Strategy](test-placement-strategy.md)
- [hyperfleet-e2e test design](https://github.com/openshift-hyperfleet/hyperfleet-e2e/tree/main/test-design)
