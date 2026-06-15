---
Status: Draft
Owner: HyperFleet Team
Last Updated: 2026-06-16
---

# Adapter Lifecycle Gates

> Part of [Adapter Resource Lifecycle Management Design](./adapter-lifecycle-management-design.md)

Adapter resources phase allows per resource lifecycle operations determined by CEL expression gates (`lifecycle.recreate.when`, `lifecycle.delete.when`) evaluated against discovered resource state. This proposal introduces new gates following the same pattern for:
- Executing or not an individual resource (vs using `precondition`, which skips the whole resources phase)
- Applying patches to resources instead of full apply
- Orphan resources, so they remain alive but are no longer managed by HyperFleet

## 1.1 Resource-Level When Gate

A resource-level `when` expression is evaluated before any lifecycle gate. If it evaluates to false, the executor skips all actions for that resource in the current event — no apply, no patch, no recreate.

```yaml
resources:
  - name: "provisioningJob"
    when:
      expression: "..."
    lifecycle:
      ...
```

This gate follows the same CEL evaluation context as all other lifecycle expressions: extracted params, discovered resources, and adapter metadata are all available.

### Discovery always runs

Discovery is executed before evaluating `when`. The executor still discovers the current state of the resource and makes it available as `resources.provisioningJob` (an optional value, absent if nothing was found). This means:

- Values can be used to define the `when` expression on the resource itself.
  - E.g. providing a "create only" feature by skipping any operation once a resource is discovered
  - Provide some "throttling" for rapid events, checking on the last execution report of the same adapter
     - E.g. skip adapter1 resource if `last_updated_time` occured within some time window
- Sibling resources can read `resources.provisioningJob` in their own `when` expressions, `lifecycle.*` expressions, and manifest templates, regardless of whether this resource's `when` gate passed.

### Replace `precondition`

A precondition failure is event-scoped: if a precondition evaluates to false or errors, the executor aborts the entire resources phase — all remaining resources in the event are skipped, not just the one the precondition was intended to guard. This makes preconditions the right tool for event-wide guards ("abort if the cluster is not yet registered") but the wrong tool for resource-specific guards.

The resource-level `when` gate is resource-scoped: if it evaluates to false, only that resource's modification actions are skipped. The executor continues to the next resource in the list without interruption. Other resources are discovered, evaluated, and applied normally. This matters when resources in the same event are logically independent — a debounce on a provisioning job should not prevent an annotation patch on a separate namespace resource from running in the same event.

Resource level `when` conditions can replace the `precondition` feature. There are some tradeoffs:
- For adapter configs with  many resources, a shared `precondition` avoids repetition at every resource
- Increase CEL complexity because of mixing at resource level `when` the conditions for a global skip and specific skip.
  - This can be alleviated by defining a variable like `skipAll` and then at resource level combining like `skipAll && specific-when-for-resource`

## 1.1 Gate apply operations `lifecycle.apply.when`

`lifecycle.apply.when` gates whether the apply step runs for a given resource. If the expression evaluates to false, the apply step is skipped and the executor continues to the next resource.

**Default is True when absent**: the apply step always runs when there is no explicit `lifecycle.apply` defined. Only when defined and evaluates false, the apply is skipped.

The existing generation-aware logic determines the specific action — create if the resource does not exist, skip if the generation is unchanged, update or recreate if the generation has advanced. `lifecycle.apply.when` is an additional gate evaluated before that logic; omitting it leaves the generation-aware behavior unchanged.

The primary use case is create-only behaviour: only write the resource if it does not already exist.

```yaml
resources:
  - name: "bootstrapNamespace"
    transport:
      client: "kubernetes"
    manifest:
      apiVersion: v1
      kind: Namespace
      metadata:
        name: "{{ .clusterId }}"
        annotations:
          hyperfleet.io/generation: "{{ .generation }}"
    discovery:
      by_name: "{{ .clusterId }}"
    lifecycle:
      apply:
        when:
          expression: "!resources.?bootstrapNamespace.hasValue()"
```

The expression has access to the same CEL context as `lifecycle.recreate.when`: extracted params, discovered resources, and adapter metadata. Discovery must be configured so that the current resource state is available in `resources.*` for the expression to evaluate against.


## 1.3 Patch resources `lifecycle.patch`

Patch is an operation on an already-existing resource, not a creation strategy. `lifecycle.patch` is an array — each entry has its own `when` gate and `document`. The executor evaluates every entry independently and applies all whose `when` evaluates to true, in order.

Use this feature if you need for smaller changes than the apply operation.

```yaml
resources:
  - name: "clusterNamespace"
    transport:
      client: "kubernetes"
    discovery:
      by_name: "{{ .clusterId }}"
    lifecycle:
      patch:
        - when:
            expression: >
              resources.?clusterNamespace.hasValue()
              && dig(resources.clusterNamespace.metadata.annotations, "example.io/status") != clusterStatus
          document:
            metadata:
              annotations:
                example.io/status: "{{ .clusterStatus }}"

        - when:
            expression: >
              resources.?clusterNamespace.hasValue()
              && dig(resources.clusterNamespace.metadata.labels, "example.io/tier") != tier
          document:
            metadata:
              labels:
                example.io/tier: "{{ .tier }}"
```

The first entry fires only when the `example.io/status` annotation on the discovered resource differs from the current `clusterStatus` param — the expression reads the live value off the discovered resource and compares it to the desired value. The second entry fires independently when the label drifts. Both can apply in the same event; neither fires if the discovered state already matches.

Each `document` is the patch body, rendered through the normal Go template pipeline and sent as a JSON merge patch (RFC 7396): fields present are set, fields absent are left untouched on the server, fields explicitly set to `null` are removed.

`lifecycle.patch` and the normal apply path are mutually exclusive per resource: if any patch entry fires, the standard apply step is skipped for that resource. This is consistent with how `lifecycle.recreate.when` and `lifecycle.delete.when` take precedence over the default path.

**Transport**: Maestro's `PatchManifestWork` already uses JSON merge patch internally. For K8s, the transport client issues a `Patch` call with `types.MergePatchType`. The `PatchResourceLabels` primitive added for `lifecycle.orphan.when` provides the same transport method.

**Note on recreation**: `recreate_on_change: true` is superseded by `lifecycle.recreate.when` from [Adapter Recreation Flow Design](./adapter-recreation-flow-design.md) (HYPERFLEET-837). Recreation is a lifecycle gate, not a strategy.

### 1.3.1. Alternatives

First of all, using Patch operations is an advance use case, so ideally we should prove the necessity of implementing patch and not select a complex/very flexible solution.


#### Strategic Merge Patch

**What**: Use Kubernetes Strategic Merge Patch (SMP) instead of JSON Merge Patch (RFC 7396) as the patch type for `lifecycle.patch`.

**Why Rejected**: SMP can append to arrays (e.g., adding a container to a Pod spec) rather than replacing them, which is more powerful for some K8s object types. However, SMP is a Kubernetes-specific extension and is not supported by Maestro's `PatchManifestWork`, which uses JSON merge patch internally. Using SMP would require a per-transport patch type switch, or restricting `lifecycle.patch` to K8s-only. JSON merge patch works for the documented use cases (patching metadata annotations and labels) and keeps transport behavior uniform.

#### Server-Side Apply (SSA)

**What**: Replace `lifecycle.patch` with Server-Side Apply using a dedicated field manager, letting the API server track which fields the adapter owns and detect conflicts with other managers.

**Why Rejected**: SSA provides the strongest ownership semantics and conflict detection, but requires the transport client to maintain field manager state across events and handle conflict responses (409). It also does not map to Maestro's patch API. The use cases for `lifecycle.patch` — conditional annotation and label updates on already-existing resources — do not require conflict detection: the `when` expression reads the live value and only fires when a diff is detected. SSA complexity is not justified by these cases.

## 1.4 Detach resources (lifecycle.orphan.when)

An adapter can currently "release" a resource without deleting it: skip the delete step in `lifecycle.delete.when` and report `Finalized=True` in the post-action status conditions. The platform sees `Finalized=True` and stops sending events for that resource.

But the existing resource is left with HyperFleet specific labels, which can cause problems with cleaning jobs identifying resources as orphans to be deleted.

`lifecycle.orphan.when` makes this a first-class lifecycle operation. The expression is typically gated on the event being a deletion and the resource still carrying its management labels — confirming the resource is still managed and this event is the handoff point.

```yaml
resources:
  - name: "provisioningJob"
    transport:
      client: "kubernetes"
    discovery:
      by_name: "{{ .clusterId }}-job"
    lifecycle:
      orphan:
        when:
          expression: >
            is_deleting
            && resources.?provisioningJob.hasValue()
            && "hyperfleet.io/adapter" in resources.provisioningJob.metadata.labels
```

When `lifecycle.orphan.when` evaluates to true, the executor:

1. Discover existing resources
2. Skips the delete step entirely
3. Issues a label-strip patch via the transport client, removing `hyperfleet.io/*` labels and annotations.

The label presence check in the expression (`"hyperfleet.io/adapter" in resources.provisioningJob.metadata.labels`) ensures the gate is idempotent: if the event is redelivered after labels have already been stripped, the expression evaluates to false and neither delete nor orphan fires.

**Precedence**: `lifecycle.orphan.when` is evaluated before `lifecycle.delete.when`. If orphan fires, delete is skipped.

**Implementation**: Add `orphan.when` CEL field to `LifecycleConfig`. Add a `PatchResourceLabels(ctx, gvk, namespace, name, remove []string, target)` method to the `TransportClient` interface for the label-strip operation.

**Maestro compatibility**: For Maestro ManifestWork resources, the label-strip is applied to the ManifestWork object itself, not to the nested manifests. The sweep controller must account for this when reconciling Maestro-managed resources.

### 1.4.1 Alternatives

#### Recreate Without HyperFleet Labels

**What**: Instead of stripping labels from the existing resource in place, delete it and recreate it without the `hyperfleet.io/*` labels. The new resource carries no HyperFleet ownership markers and is invisible to the sweep controller.

**Why Rejected**: Recreation contradicts the fundamental semantic of the orphan operation. Orphan means preserve the existing resource without disruption — delete + create does the opposite:

- **Cascading deletion**: Deleting the resource triggers GC on all children (ownerReferences, finalizers). A Namespace deletion removes everything inside it. For Maestro ManifestWork, deletion propagates to all spoke-managed manifests — destroying exactly what the operation is meant to preserve.
- **Identity break**: Recreation produces a new UID, `creationTimestamp`, and `resourceVersion`. Any external system holding a reference by UID, ownerReference, or watch sees the original as gone and the replacement as an unrelated object.
- **Race window**: Between delete and create, the sweep controller may observe the labeled resource disappearing and treat cleanup as complete, or the new unlabeled resource may arrive before HyperFleet stops sending events and be double-managed.

The label-strip patch is the correct primitive because it is in-place: the resource keeps its identity, its children, its running state, and its UID. Only HyperFleet's claim is removed.

#### Alternative Names to orphan

The term "orphan" carries two conflicting meanings in this domain — Kubernetes uses it for the GC `propagationPolicy: Orphan` (leave children in place when parent is deleted), while this design uses it to mean "release a resource from HyperFleet management." This ambiguity is a readability risk for adapter authors familiar with K8s.

| Name | Rationale | Concern |
|---|---|---|
| `lifecycle.release.when` | "Release from management" reads naturally in context | `release` is also used for software releases; ambiguous in a CI/CD platform context |
| `lifecycle.disown.when` | Precise: strip ownership, leave in place | Less common English; may read as aggressive/negative |
| `lifecycle.handoff.when` | Conveys transfer of responsibility to another owner | Implies a receiver exists; disownment is unconditional |
| `lifecycle.finalize.when` | Mirrors the `Finalized=True` condition it produces | `Finalized` in K8s means object is being deleted (finalizer cleared) — opposite meaning |

**Recommendation to revisit**: `lifecycle.release.when` is the least ambiguous in context and avoids the K8s GC collision. If the project glossary settles on "release" for this concept, rename accordingly. Until then, `orphan.when` is retained as the design name with an explicit note in the glossary entry distinguishing it from `propagationPolicy: Orphan`.

## Related Documentation

- [Adapter Resource Lifecycle Management Design](./adapter-lifecycle-management-design.md) — Main index document
- [Adapter Label Stamping](./adapter-label-stamping.md) — §2: Automatic Label and Annotation Stamping
- [Adapter Resilience Model](./adapter-resilience-model.md) — §3: Resilience Model
- [Adapter Stuck Detection](./adapter-stuck-detection.md) — §4: Stuck Detection
- [Adapter Periodic Execution](./adapter-periodic-execution.md) — §5: Periodic Execution
- [Adapter Resource Retention](./adapter-resource-retention.md) — §6: Resource Retention
- [Adapter Sweep Controller](./adapter-sweep-controller.md) — §7: Sweep Controller
