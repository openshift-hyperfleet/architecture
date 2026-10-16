---
Status: Active
Owner: HyperFleet QE Team
Last Updated: 2026-09-29
---

# Spike Report: E2E Test Alignment with the Generic Resource Model

**JIRA:** [HYPERFLEET-1378](https://redhat.atlassian.net/browse/HYPERFLEET-1378)
**Follow-up:** [HYPERFLEET-1713](https://redhat.atlassian.net/browse/HYPERFLEET-1713)
**Date:** 2026-09-24

## Overview

**Decision: full generic shift — a generic suite over controlled fixture kinds, with platform and release testing as a separate suite.**

- **Generic suite.** Controlled fixture kinds and test adapters named for their role — `parent`, `child-cascade`, `child-restrict`, `referencer` / `target`, adapter-backed or not. It covers all shared resource behavior, including the adapter-backed journeys, and runs for every deployment.
- **Platform suite.** Full platform and release testing, where real clusters are created with provider workloads. It stays separate so one provider does not gate the others, and is out of scope for this spike.
- The helper and config layer (`pkg/helper`, `pkg/config`) is entity-keyed; making it descriptor-keyed is the core of aligning the suite.

The rationale and rejected alternatives are in [Section 4](#4-decision-and-rationale). Implementation is tracked in [HYPERFLEET-1713](https://redhat.atlassian.net/browse/HYPERFLEET-1713).

---

## 1. Problem Statement

The HyperFleet API no longer has per-entity code paths. All managed entity types are stored as a single `Resource` with a `kind` discriminator, and a declarative `EntityDescriptor` drives routes, spec validation, status aggregation, delete policy, required adapters, and references — see [Generic Resource Registry — Design Document](../generic-resource-registry-design.md).

A deployment can define many kinds, but their behavior is assembled from the capabilities and rules the API supports: required adapters or none, parent/child relationships, delete policies, references, name rules, and condition mappers. Changing `kind` from `Resource1` to `CustomerResource` does not, by itself, introduce a new rule. The question this spike answers:

> Now that the API has a shared resource contract, generic handlers, and declarative descriptors, should tests still be organized around entity names — or around capabilities, exercised by a small set of controlled fixture kinds?

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
| Reconciliation | Kinds a Sentinel is configured for (Cluster and NodePool in the current deployment) reach `Reconciled` via adapters |

Source: [hyperfleet-api `charts/values.yaml`](https://github.com/openshift-hyperfleet/hyperfleet-api/blob/main/charts/values.yaml) for the descriptors and chart defaults, plus the [infra base API config](https://github.com/openshift-hyperfleet/hyperfleet-infra/blob/main/helmfile/values/base-api.yaml.gotmpl) that adds the Cluster → WifConfig reference; the delete rules live in the [Generic Resource Registry](../generic-resource-registry-design.md#8-delete-model-for-owned-resources).

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

So the transport layer already models the generic API. The entity-specific surface is the helper/config layer ([Section 2.5](#25-the-helper-and-config-layer-is-entity-keyed)) and the tests, not the client.

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

### 2.5 The helper and config layer is entity-keyed

The generic client is wrapped by an entity-keyed helper layer (`pkg/helper`). Sixteen methods name an entity directly: `GetTestCluster`, `PollCluster`, `PollNodePool`, `PollClusterAdapterStatuses`, `PollNodePoolAdapterStatuses`, `PollClusterHTTPStatus`, `PollNodePoolHTTPStatus`, `CleanupTestCluster`, `CleanupTestNodePool`, `CleanupTestChannel`, `CleanupTestWifConfig`, `DeferClusterCleanup`, `DeferChannelCleanup`, `DeferWifConfigCleanup`, `GetAPIRequiredClusterAdapters`, and `cleanupClusterScopedResources`. The config layer is entity-keyed too: `AdaptersConfig{Cluster, NodePool}` and `TimeoutsConfig{Cluster, NodePool, Adapter}` in `pkg/config`. Together these are what make even the reconcilable suites look entity-specific despite the generic client, and they mean a new kind still needs code. Descriptor-keying both layers is the core of aligning the suite with the generic model.

---

## 3. Evaluation of Options

| Option | Description | Strengths | Weaknesses |
|--------|-------------|-----------|------------|
| A — Keep entity-specific | Status quo; fix the one-off helper bug | Tests mirror today's API paths; existing tier labels map cleanly to journeys | Duplicates the capability matrix per kind; new kinds need dedicated suites; production names leak into shared tests; the helper/config layer stays entity-keyed |
| B — Full generic shift (chosen) | A generic suite over controlled fixture kinds and role-named test adapters; platform/release testing kept separate | One capability tested once; a new kind adds a descriptor row; shared tests name roles, not production kinds | Needs controlled fixture kinds and test adapters; the platform/release suite is deferred |
| C — Hybrid | Generic suite plus kept entity-named tests | Preserves current names | Keeps two models; named tests duplicate capability behavior the generic suite already covers; production names leak into shared tests |

---

## 4. Decision and Rationale

**Adopt Option B (full generic shift).**

Rationale:

1. **Capabilities, not names.** A descriptor is a composition of capabilities (required adapters or none, parent/child, `restrict`/`cascade`, references, name rules, condition mappers). Renaming `kind` adds no rule, so repeating the same assertions per kind adds maintenance without coverage. Capability tests over a curated fixture set cover the rules and their meaningful combinations once.
2. **Adapter-backed journeys are one rule.** Reconcile, finalize, hard-delete, namespace cleanup, stuck deletion, adapter failure, crash recovery, and force-delete are all "an adapter creates and removes resources for a kind"; they work the same for any adapter-backed kind and belong to the generic suite with role-named test adapters. The only distinct downstream outcome is provisioning a real cluster against a provider, which is platform-specific and belongs to the separate platform suite.
3. **The helper and config layer is the core.** The client is already generic, but `pkg/helper` and `pkg/config` are entity-keyed ([Section 2.5](#25-the-helper-and-config-layer-is-entity-keyed)). Descriptor-keying them is what actually aligns the suite; without it, generic tests would still be written against entity-named helpers and per-kind config.
4. **Cost/benefit favors the shift now.** The suite is young (Ginkgo v2 + Gomega chosen in [e2e-testing-framework-spike-report.md](e2e-testing-framework-spike-report.md)) and the generic model is still settling; building the fixture kinds and descriptor-keyed layer now is cheaper than after more entity types land.

### Rejected alternatives

| Alternative | Why rejected |
|-------------|--------------|
| Keep entity-specific (Option A) | Duplicates the capability matrix per kind and keeps production names in shared tests; every new kind pays the same cost again |
| Hybrid (Option C) | Keeps named tests for behavior the generic suite already covers, so it maintains two models and leaks production names into shared tests |
| Do nothing until a new entity type lands | Defers a known, quantified duplication (see [Section 2.4](#24-duplication-inventory)) and leaves the helper/config layer entity-keyed |

---

## 5. Scope of Adoption

### 5.1 Controlled fixture kinds

Tests name roles, not production kinds. The fixture set is small and configured in the test deployment:

| Fixture kind | Role | Capability |
|--------------|------|------------|
| `parent` | root | ownership (root) |
| `child-cascade` | child of `parent`, `on_parent_delete: cascade` | cascade |
| `child-restrict` | child of `parent`, `on_parent_delete: restrict` | restrict |
| `referencer` | root referencing `target` | references |
| `target` | referenced by `referencer` | reference restriction |
| test adapters (`adapter-success`, `adapter-failure`, …) | named for their role | adapter-backed |

Each fixture can be configured adapter-backed or not via `required_adapters`.

Adapter-backed fixtures carry a deployment cost: a Sentinel instance watches a single `resource_type`, so each adapter-backed fixture needs its own Sentinel, plus a deployed test adapter that reports `Finalized` for it. Budget one Sentinel and one role-named test adapter per adapter-backed fixture.

Capabilities a descriptor can declare:

| Capability | Values |
|------------|--------|
| Adapter-backed | `required_adapters` empty / non-empty |
| Ownership | root / child (`parent_kind`) |
| Delete policy | child `on_parent_delete`: `restrict` / `cascade` |
| References | none / optional / required |
| Name rules | uniqueness, min/max length |
| Spec schema | declared / not |
| Condition mapper | CEL condition rules declared / not |

### 5.2 Capability coverage and layer placement

The generic suite is table-driven from the fixture descriptors and runs at the layer [Test Placement Strategy](test-placement-strategy.md) assigns:

| Capability behavior | Layer |
|---------------------|-------|
| Synchronous CRUD, name uniqueness, generation increment/no-op, response shapes, soft-deleted visibility, spec-schema validation | Integration (`hyperfleet-api`) |
| Restrict refusal, reference restriction (the `referencer`/`target` fixture), no-adapter deletion | Integration (`hyperfleet-api`) |
| Condition-mapper (CEL) evaluation | Integration (`hyperfleet-api`) |
| Adapter-backed journey: an adapter creates and removes resources, finalization → hard-delete, namespace cleanup | E2E |
| Adapter failure: a failing adapter is isolated; the resource reconciles despite it, or reports the failure | E2E |
| Adapter crash → resource stuck → adapter restored → reconciled | E2E |
| Stuck finalization: an adapter cannot finalize, blocking hard-delete; restore or force-delete unblocks | E2E |
| External resource deletion: adapters finalize cleanly despite missing downstream resources | E2E |
| Conflicting operations: delete during reconciliation, update during deletion | E2E |
| Cascade through the deployed pipeline (an adapter-backed `child-cascade`) | E2E |
| Re-create after hard-delete; re-DELETE is idempotent while deletion cannot advance; name reuse after the final hard-delete | E2E |

Capabilities that need a single service or the DB stay in `hyperfleet-api` Integration and are not re-tested in E2E. This replaces the per-kind suites: `channel`/`version`/`wifconfig` `crud_lifecycle.go`, `channel/delete_restrict.go`, and `wifconfig/deletion_protection.go` move to Integration, while `e2e/cluster` and `e2e/nodepool` — the bulk of the current suite — are replaced by the adapter-backed fixture in the generic suite. Their reconciliation, delete, negative, and update specs become capability tests over that fixture, and their per-entity performance baselines become per-fixture baselines or are dropped where they measure the same path. Only platform/release provisioning stays outside ([Section 5.3](#53-platform-and-release-suite-out-of-scope)).

### 5.3 Platform and release suite (out of scope)

Full platform and release testing — provisioning real clusters with provider workloads and validating the provider-specific downstream state — is kept in a separate suite so one provider does not gate the others. It is out of scope for this spike and is followed up when the need arises.

### 5.4 Descriptor-keyed helper and config layer

The follow-up replaces the entity-named helper and config members with descriptor-keyed equivalents:

- `pkg/helper`: `PollCluster` / `PollNodePool` collapse into one `Poll`, `CleanupTestCluster` / `CleanupTestNodePool` / `CleanupTestChannel` / `CleanupTestWifConfig` into one `CleanupTestResource`, `DeferClusterCleanup` / `DeferChannelCleanup` / `DeferWifConfigCleanup` into one `DeferCleanup`, and `GetAPIRequiredClusterAdapters` reads the descriptor's `required_adapters`.
- `pkg/config`: `AdaptersConfig{Cluster, NodePool}` and `TimeoutsConfig{Cluster, NodePool, Adapter}` become descriptor-keyed (a map keyed by the descriptor table) so a new kind needs no config code.

A caller passes the descriptor (kind, plural, parent kind, nested path) from the descriptor table.

---

## 6. Follow-up Implementation Ticket

[HYPERFLEET-1713](https://redhat.atlassian.net/browse/HYPERFLEET-1713) tracks the implementation: the descriptor table and controlled fixture kinds, the descriptor-keyed helper and config layer, the capability-based tests placed per layer, the removal of the per-kind suites, and the authoring guideline in `test-design/`.

---

## 7. Consequences and Risks

| Consequence | Mitigation |
|-------------|------------|
| Capability combinations can explode | Curate a minimal fixture set that covers each capability and only the meaningful combinations |
| Fixture kinds drift from the API's descriptors | Source the descriptor table from the deployed API config and guard with a contract test |
| A new kind still needs code if config is not keyed | Include `pkg/helper` and `pkg/config` in the descriptor-keying scope ([Section 5.4](#54-descriptor-keyed-helper-and-config-layer)) |
| Refactor may temporarily reduce coverage | Move one capability at a time: land the lower-layer test, then delete the E2E duplicate |
| Entity-keyed helpers reappear as new kinds land | Require helpers and config to take a descriptor, not a kind name |

---

## 8. References

- [HYPERFLEET-1378](https://redhat.atlassian.net/browse/HYPERFLEET-1378) — this spike
- [HYPERFLEET-1396](https://redhat.atlassian.net/browse/HYPERFLEET-1396) — separate bug: `UpgradeAPIRequiredAdapters` obsolete Helm path (not part of this decision)
- [HYPERFLEET-1713](https://redhat.atlassian.net/browse/HYPERFLEET-1713) — follow-up implementation ticket
- [HYPERFLEET-1721](https://redhat.atlassian.net/browse/HYPERFLEET-1721) — follow-up: adapter-less parent hard-delete gap
- [Generic Resource Registry — Design Document](../generic-resource-registry-design.md)
- [Spike Report: E2E Testing Framework](e2e-testing-framework-spike-report.md)
- [Spike Report: E2E Test Automation Run Strategy](e2e-run-strategy-spike-report.md)
- [Test Placement Strategy](test-placement-strategy.md)
- [hyperfleet-e2e test design](https://github.com/openshift-hyperfleet/hyperfleet-e2e/tree/main/test-design)
