---
Status: Draft
Owner: HyperFleet Team
Last Updated: 2026-06-16
---

# Adapter Automatic Label and Annotation Stamping

> Part of [Adapter Resource Lifecycle Management Design](./adapter-lifecycle-management-design.md)

**Current state**: The framework defines a set of standard `hyperfleet.io/*` label and annotation keys as string constants in `pkg/constants/constants.go` (`hyperfleet.io/generation`, `adapter`, `cluster-id`, `created-by`). These are a shared reference for adapter authors — the framework does not inject them. Each adapter's manifest template must add them explicitly by hand. The only exception is `hyperfleet.io/generation`: this annotation is mandatory and validated at apply time by `internal/manifest/generation.go`, which refuses to apply any manifest missing it or carrying a non-numeric value.

This means label coverage across adapter-created resources is inconsistent: adapters that omit `hyperfleet.io/adapter` or `hyperfleet.io/cluster-id` from their templates are invisible to any tooling that relies on those labels for discovery, ownership tracking, or sweep-based cleanup.

**Proposal**: The framework injects the standard set of `hyperfleet.io/*` labels and annotations at apply time, before the manifest reaches the transport client. Adapter authors no longer need to add them manually. The merge strategy is fill-gaps-only: labels already present in the adapter's manifest template take precedence, so intentional overrides are preserved and no existing adapter is broken.

**Standard labels stamped on every resource:**

| Label / Annotation | Value Source | Notes |
|---|---|---|
| `hyperfleet.io/adapter` | Adapter config: `adapter.name` | Identifies the adapter instance managing this resource |
| `hyperfleet.io/resource-id` | TBD — pending HYPERFLEET-896 alignment | Stable identifier across recreations |
| `hyperfleet.io/generation` | Event param: `generation` | Already enforced; automatic stamping is a no-op if already present |

**Implementation**: A `stampLabels(manifest, frameworkLabels)` function called in `resource_executor.go` before `ApplyResource()`. Works identically for K8s and Maestro.

## Alternatives Considered

### §2 — Automatic Label Stamping

#### Enforce at apply time

**What**: Similar to how enforcement of `generation` label, check the other required labels are set before applying

**Why Rejected**: Reduces the developer experience by adding these HyperFleet specific concerns when creating adapter tasks and pollutes manifests files.

#### Fail Fast at Config Load

**What**: Instead of injecting missing labels at runtime, validate at adapter startup that every manifest template includes the required `hyperfleet.io/*` labels. Fail to start if any are missing.

**Why Rejected**: Manifest templates are Go templates rendered at event time with per-event params — static analysis cannot guarantee the rendered output will contain a label that is computed from a template expression. Validation would have to be done on the rendered manifest at apply time anyway, which is equivalent to the injection approach. Runtime injection is strictly less breaking: adapters that already include the labels are unaffected; adapters that omit them gain coverage automatically.

#### Kubernetes Admission Webhook

**What**: Deploy a mutating admission webhook on the management cluster that stamps `hyperfleet.io/*` labels on any resource created by an adapter service account.

**Why Rejected**: Works only for the direct Kubernetes transport path — Maestro ManifestWork objects are created on the management cluster, but the labels need to appear on the ManifestWork itself, not on the nested spoke-cluster manifests that Maestro eventually applies. The webhook cannot reach those. A webhook also requires cluster-level infrastructure (certificate rotation, webhook registration) that is out of scope for an adapter framework change. Framework-side injection covers both transports uniformly.

## Related Documentation

- [Adapter Resource Lifecycle Management Design](./adapter-lifecycle-management-design.md) — Main index document
- [Adapter Lifecycle Gates](./adapter-lifecycle-gates.md) — §1: Lifecycle Gates
- [Adapter Resilience Model](./adapter-resilience-model.md) — §3: Resilience Model
- [Adapter Stuck Detection](./adapter-stuck-detection.md) — §4: Stuck Detection
- [Adapter Periodic Execution](./adapter-periodic-execution.md) — §5: Periodic Execution
- [Adapter Resource Retention](./adapter-resource-retention.md) — §6: Resource Retention
- [Adapter Sweep Controller](./adapter-sweep-controller.md) — §7: Sweep Controller
