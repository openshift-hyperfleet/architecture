---
Status: Draft
Owner: HyperFleet Team
Last Updated: 2026-06-15
---

# Adapter Resource Lifecycle Management Design

**Jira**: [HYPERFLEET-827](https://issues.redhat.com/browse/HYPERFLEET-827) · [HYPERFLEET-1065](https://issues.redhat.com/browse/HYPERFLEET-1065)

## What & Why

**What**: Add per-resource lifecycle configuration to the adapter framework so adapter authors can control what happens after initial resource creation: how resources are updated, how failures are handled, and how resources are cleaned up.

**Why**: The adapter framework creates real infrastructure (Kubernetes objects, Maestro ManifestWork resources) but treats each event as a fresh operation with no memory of prior state:
- No configurable update strategy — adapter authors cannot express "recreate on generation change" vs "apply in place" vs "never write once created"
- No declarative way to stop managing a resource — adapter authors cannot express "release this resource from HyperFleet management without deleting it"
- No retry for resource operations — a transient K8s API server error fails the entire event and depends on broker redelivery
- No persistent state — execution context is in-memory per event; no state survives across event executions
- No automatic label stamping — standard `hyperfleet.io/*` labels are convention, not enforcement, so sweep-based cleanup cannot be built reliably

**Related Documentation:**
- [Adapter Framework Design](./adapter-frame-design.md) — Core executor architecture
- [Adapter Recreation Flow Design](./adapter-recreation-flow-design.md) — Recreation flow specifics (HYPERFLEET-837)
- [Adapter Status Contract](./adapter-status-contract.md) — Status reporting patterns

### Scope

This design covers seven proposals:

1. **Lifecycle gates** (`§1`) — [adapter-lifecycle-gates.md](./adapter-lifecycle-gates.md): four new per-resource CEL-gated operations following the existing `lifecycle.recreate.when` / `lifecycle.delete.when` pattern:
   - resource-level `when` (`§1.1`) — evaluated before any lifecycle gate; if false, all modification actions (apply, patch, recreate) are skipped for that resource in the current event; primary use case is debouncing using CEL timestamp arithmetic
   - `lifecycle.apply.when` (`§1.2`) — gate whether the apply step runs (create-only use case)
   - `lifecycle.patch` (`§1.3`) — array of conditional JSON merge patches on an already-existing resource
   - `lifecycle.detach.when` (`§1.4`) — conditional resource disownment: strip `hyperfleet.io/*` management labels and report `Finalized=True` without deleting

2. **Automatic label and annotation stamping** (`§2`) — [adapter-label-stamping.md](./adapter-label-stamping.md): the framework injects standard `hyperfleet.io/*` labels on all adapter-created resources at apply time, making them consistently discoverable for tooling and sweep-based cleanup

3. **Resilience model** (`§3`) — [adapter-resilience-model.md](./adapter-resilience-model.md): documents why per-resource retry is not implemented in the adapter and how the Sentinel reconciliation cycle (convergence at ~10s, drift-check at 30 minutes) covers both failure cases, with `Available=False` closing the drift-check corner case

4. **Stuck detection** (`§4`) — [adapter-stuck-detection.md](./adapter-stuck-detection.md): unified reconciliation metrics at the API layer via [HYPERFLEET-1205](https://redhat.atlassian.net/browse/HYPERFLEET-1205), covering both deletion and create/update flows via `Reconciled=False` condition tracking

5. **Periodic execution** (`§5`) — [adapter-periodic-execution.md](./adapter-periodic-execution.md): enables detection of adapter config changes (`adapter.version`) and framework binary changes (`adapter.frameworkVersion`) by including both as `adapter_config_version` and `adapter_framework_version` in every status report; values are stored in the raw statuses endpoint and not surfaced in the customer-facing conditions view; adapter config authors capture last-reported values via a precondition API call and use lifecycle gate expressions to decide what runs on a version change; this design also renames `adapter.version` from a framework binary constraint to an author-declared config version, introducing `adapter.frameworkVersion` as its replacement

6. **Resource retention** (`§6`) — [adapter-resource-retention.md](./adapter-resource-retention.md): per-resource `retention:` configuration that governs how many historical versions of a resource accumulate and for how long; enables recreate-with-history semantics (versus the default delete-before-create replace mode), multi-result label-based discovery, and debounce protection against rapid version creation

7. **Sweep controller** (`§7`) — [adapter-sweep-controller.md](./adapter-sweep-controller.md): a background controller that periodically detects and removes K8s and Maestro resources orphaned by HyperFleet API force-deletes, using the `hyperfleet.io/adapter` and `hyperfleet.io/resource-id` labels stamped automatically by the framework to identify and verify each managed resource against the API

---

## Current State

The adapter executes a 4-phase sequential pipeline per CloudEvent:

1. **Parameter Extraction** — extracts params from event data and env vars
2. **Preconditions** — evaluates CEL or structured conditions; supports API calls with retry/backoff
3. **Resources** — applies, discovers, and deletes resources sequentially
4. **Post-Actions** — CEL-gated HTTP calls or log entries; always runs for error reporting

### What Already Exists

| Capability | Location | Notes |
|---|---|---|
| `recreate_on_change: bool` | `internal/configloader/types.go` | Delete+create when generation changes; superseded by `lifecycle.recreate.when` (HYPERFLEET-837) |
| `lifecycle.delete.when` CEL expression | `resource_executor.go` | Gated deletion ordering per resource |
| `lifecycle.delete.propagationPolicy` | `transportclient/types.go` | Background / Foreground / Orphan (K8s GC sense only) |
| Generation-aware idempotent apply | `internal/manifest/generation.go` | Create / Skip (same gen) / Update / Recreate |
| Retry/backoff for precondition API calls | `internal/hyperfleetapi/client.go` | Exponential, linear, constant + ±10% jitter; 3 attempts default |
| `hyperfleet.io/*` label constants | `pkg/constants/constants.go` | String constants for label/annotation keys (`hyperfleet.io/generation`, `managed-by`, `cluster-id`, `created-by`). Used as a shared reference — the framework does **not** inject these automatically; each adapter's YAML manifest template must add them explicitly |
| `hyperfleet.io/generation` enforcement | `internal/manifest/generation.go` | The one exception: this annotation is mandatory and validated at apply time. The adapter refuses to apply any manifest that is missing it or has a non-numeric value |
| Label/annotation stamping | — | **Not automatic.** No framework mechanism injects `hyperfleet.io/*` labels into manifests. Adapter authors must add them to their YAML templates by hand. This design adds automatic stamping — see [Automatic Label and Annotation Stamping](#automatic-label-and-annotation-stamping) below |

---

## Design

Each proposal is documented in its own file:

| Proposal | Document |
|---|---|
| §1 — Lifecycle Gates | [adapter-lifecycle-gates.md](./adapter-lifecycle-gates.md) |
| §2 — Automatic Label Stamping | [adapter-label-stamping.md](./adapter-label-stamping.md) |
| §3 — Resilience Model | [adapter-resilience-model.md](./adapter-resilience-model.md) |
| §4 — Stuck Detection | [adapter-stuck-detection.md](./adapter-stuck-detection.md) |
| §5 — Periodic Execution | [adapter-periodic-execution.md](./adapter-periodic-execution.md) |
| §6 — Resource Retention | [adapter-resource-retention.md](./adapter-resource-retention.md) |
| §7 — Sweep Controller | [adapter-sweep-controller.md](./adapter-sweep-controller.md) |
