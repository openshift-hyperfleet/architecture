---
Status: Active
Owner: HyperFleet Team
Last Updated: 2026-10-16
---

# SPIKE: DSL v2 Resource Ordering Model

**Jira**: [HYPERFLEET-1447](https://redhat.atlassian.net/browse/HYPERFLEET-1447)

Related: [SPIKE: Evaluate Running the Desire Store on the API Postgres](desire-store-api-postgres-spike.md) covers the Desire Store path between the Adapter and the Applier.

## Table of Contents

- [Overview](#overview)
- [Executor model](#executor-model)
- [Survey of Existing Adapters](#survey-of-existing-adapters)
- [Options Evaluation](#options-evaluation)
  - [Blessed existing model](#blessed-existing-model)
  - [New primitives](#new-primitives)
- [Edge cases](#edge-cases)
- [Eventual consistency](#eventual-consistency)
- [Desired-state convergence](#desired-state-convergence)
- [Decision](#decision)

---

## Overview

DSL v2 replaces ManifestWork bundling with per-resource delivery. That surfaces apply ordering within a single adapter's `resources` list (e.g. namespace before contents). This spike decides whether the current executor model is sufficient or whether new ordering primitives are needed.

---

## Executor model

| | Apply | Delete |
|---|---|---|
| Ordering | YAML list position; optional `lifecycle.create.when` + `resources.?X.hasValue()` | `lifecycle.delete.when` + `!resources.?X.hasValue()` |
| On failure | Fail-fast | Best-effort (continue, collect errors) |
| Ordering primitive | None (`order`, `depends_on` do not exist) | None |

- Pre-discovery populates all resources into context before any `when` expression runs
- Local post-delete rediscovery updates context after delete (cascade same reconciliation, or wait for next). Remote deletion instead confirms from `DeleteDesire` status via `ProbeDeletion`, then cleans up desires and updates context; read-mirror disappearance is not its confirmation signal
- Each event triggers one full pass from the top; no checkpoint or resume

```yaml
# List optimized for delete (children first); create.when handles apply ordering
resources:
  - name: configmap
    discovery: ...
    lifecycle:
      create:
        when:
          expression: "resources.?namespace.hasValue()"
      delete:
        when:
          expression: "is_deleting"

  - name: namespace
    discovery: ...
    lifecycle:
      delete:
        when:
          expression: "is_deleting && !resources.?configmap.hasValue()"
```

---

## Survey of Existing Adapters

Surveyed all 8 `adapter-task-config.yaml` files in `hyperfleet-infra` at the time of the August 2026 investigation. The counts and Maestro configuration names below are historical evidence; Maestro has since been removed, and this table is not a current deployment inventory. This spike covers ordering within one adapter's `resources` list only; sequencing across adapters via preconditions is out of scope.

| Pattern | Count | Notes |
|---|---|---|
| Single resource per adapter | 8/8 | No multi-resource list ordering in use |
| `lifecycle.create.when` | 0/8 | Shipped (HYPERFLEET-1295) but unused in infra |
| `lifecycle.delete.when` with `!resources.?X.hasValue()` | 0/8 | All use `is_deleting` only; dependency pattern in framework examples |
| ManifestWork bundling (Maestro) | 2/8 | `cl-maestro`, `adapter2` |
| Precondition waits on other adapters | 3/8 | `cl-job`, `cl-deployment`, `np-configmap` via preconditions |

---

## Options Evaluation

### Blessed existing model

Formalize and extend the [executor model](#executor-model) in the authoring guide. The building blocks already exist in separate sections (list order, `lifecycle.create`, delete dependency ordering) but are not documented as a unified ordering model. No schema or executor changes.

**Validation**:

- `discovery` required for lifecycle (existing)
- Authoring guide formalizes ordering conventions

**Pros**:

- No executor work
- `when` expresses conditional gating (e.g. `is_deleting && !resources.?X.hasValue()`) that a plain `order` integer or `depends_on` DAG cannot
- No new failure surface (cycle detection, sort-stability on ties) to design and test

**Cons**:

- Conventions not validated at config load; misordered YAML fails at runtime
- Doesn't scale cleanly past a few resources (no transitive dependency resolution: each sibling needs its own direct `hasValue()` check)

### New primitives

#### Explicit order values

`order` integer per resource; executor sorts before processing. Likely needs separate apply/delete order.

**Validation**:

- Unique or tie-broken `order` values
- Apply and delete would need separate `order` fields if their sequences differ

**Pros**:

- Explicit ordering independent of list position
- Simpler mental model than a DAG (just a number, no graph concepts)

**Cons**:

- Same eventual-consistency limits; extra field(s) to maintain
- Validates only uniqueness/tie-breaking, not correctness (an author can assign the wrong `order` value and nothing catches it)
- Inserting a resource between two existing ones may require renumbering siblings

#### Explicit depends-on (DAG)

`depends_on: [sibling names]`; topological sort; cycle detection at config load; delete order auto-reversed.

**Validation**:

- Cycle detection at config load
- All referenced names must exist

**Pros**:

- Framework enforces order; catches misordered YAML at validation
- Single declaration drives both apply and delete order (delete auto-reversed)

**Cons**:

- Largest implementation scope
- Does not replace `lifecycle.delete.when` for delete gating; async transports still eventually consistent
- Purely structural; can't express conditional gating like `is_deleting && ...`

---

## Edge cases

Applies regardless of which ordering model is chosen.

- **Retry semantics:** no checkpoint or resume. The next event triggers a full pass from the top, re-evaluating every resource's `when` from scratch.
- **Mixed transports:** executor processes local Kubernetes and named remote resources in list order; asynchronous desire-based remote delivery may need multiple reconciliations. The historical survey above does not establish today's transport mix.
- **Delete symmetry:** parents-first apply / children-first delete is convention, not enforced.

---

## Eventual consistency

Applies regardless of which ordering model is chosen.

Ordering guarantees sequential apply/delete **attempts** only. With a named remote transport, a successful desire write means the store accepted the intent, not that the remote cluster has converged. Dependents may need another reconciliation before `when` passes. New primitives do not change this. The Applier's separate apply-before-delete safety guarantee is defined in [ADR 0028](../adrs/0028-apply-delete-ordering.md).

---

## Desired-state convergence

This is the pattern the blessed model relies on:

1. **Adapter declares desired state for the full resource set.** Declaration order and `lifecycle.*.when` are observable controls within a pass, not a transactional apply sequence.
2. **Executor attempts every resource once per pass** (apply/delete failure behavior from the [Executor model](#executor-model) still applies). `lifecycle.create.when` gates creation of absent resources only; existing resources ignore it and reconcile normally (not an update-ordering or workflow guarantee). Other `lifecycle.*.when` conditions may skip or defer a resource when not met; unmet dependencies are not retried in a loop and skipped/deferred resources do not block siblings.
3. **Convergence happens across reconciliations.** Each new event re-evaluates every `when` from scratch (see [Edge cases](#edge-cases)); a resource deferred this pass resolves once its dependency's state changes on a later pass.

---

## Decision

**Recommendation**: Formalize the current executor model in the authoring guide. No new primitives.

**Rationale**: `lifecycle.create.when` and `lifecycle.delete.when`, with pre/post-discovery, cover resource list ordering within one adapter config. Survey shows no production adapter uses multi-resource ordering today (8/8 single-resource). New primitives add cost without demonstrated need.

**Follow-up**: unify ordering guidance in the authoring guide + add multi-resource framework examples.
