---
Status: Draft
Owner: HyperFleet Team
Last Updated: 2026-06-16
---

# Adapter Resource Retention

> Part of [Adapter Resource Lifecycle Management Design](./adapter-lifecycle-management-design.md)

Some adapter resources should accumulate as history rather than be replaced in-place — provisioning jobs, pipeline runs, audit records. The `retention:` block at the resource level enables this: it configures how many historical versions are kept and for how long.

**Retention is not a lifecycle gate.** It is a resource-level policy that runs as a post-apply cleanup pass. It is independent of `lifecycle.recreate.when` — the gate decides *whether* to create a new version; retention decides *how many old versions to keep* after the new one exists.

## Replace mode vs. retain mode

The presence or absence of `retention:` determines the recreation strategy when `lifecycle.recreate.when` fires:

- **Replace mode** (no `retention:` block): the old resource is deleted first, then the new manifest is applied with the same name. One resource exists at a time.
- **Retain mode** (`retention:` block present): the new manifest is applied without deleting the old one first. The adapter author controls the naming to ensure no collision — the name should vary per creation (e.g., include a timestamp or generation suffix). Old versions accumulate and are pruned by retention rules.

This distinction matters because the two modes have incompatible semantics: replace requires the old name to be free before creating; retain requires the old resource to remain alive until pruned.

## Multi-result discovery

In retain mode, discovery must find all existing versions of the logical resource, not a single resource by name. The standard mechanism is a label selector on `hyperfleet.io/resource-id`, which is stamped automatically on every resource (see `§2`):

```yaml
discovery:
  by_selectors:
    label_selector:
      hyperfleet.io/resource-id: "{{ .resourceId }}"
```

This returns a list of all versions sharing the same API resource identity. The executor resolves the **current version** — the entry whose `hyperfleet.io/generation` annotation matches the current event's generation param, or the newest by `metadata.creationTimestamp` as fallback — and exposes only that single resource as `resources.myJob` in CEL expressions. The full version list is an internal executor concern.

**Authors write lifecycle expressions exactly as they do today.** `resources.myJob` is always a single optional resource, never a list. The multi-version behavior (pruning historical versions, applying delete or orphan gates across all versions) is performed by the executor transparently, without the author needing to iterate over versions in CEL.

## Retention rules

```yaml
retention:
  historyLimit: 3    # keep at most N historical versions; oldest pruned first
  ttl: 24h           # delete versions older than this duration
  expression: >      # CEL expression evaluated per item; true = delete
    item.status.conditions.exists(
      c, c.type == "Failed" && c.status == "True")
```

All three rules apply independently. If any enabled rule triggers for an item, it is deleted. The pruning pass runs after the apply step on every event where `retention:` is configured. The current item (the one whose `hyperfleet.io/generation` matches the current event) is never deleted regardless of expression result.

### `expression` — per-item CEL predicate

`expression` evaluates a CEL expression independently against each item returned by discovery. If the expression returns `true`, that item is deleted, regardless of whether `historyLimit` or `ttl` would have triggered for it.

Three variables are available in addition to the standard params and adapter metadata:

| Variable | Value |
|---|---|
| `item` | The discovered resource currently being evaluated |
| `items` | The full list of discovered resources, as returned by discovery |
| `itemIndex` | Zero-based index of `item` within `items` |

This is useful for use cases that age- or count-based rules cannot express:

- **Delete only failed runs**: prune job items that completed with `Failed=True`, retaining successful history even if `historyLimit` would otherwise remove it
- **Delete superseded configs**: prune items whose config hash no longer matches the current adapter config (i.e., created by an old config revision)
- **Delete stale pending items**: prune items stuck in a pending state for longer than a threshold
- **Keep only the N most recent successful runs**: use `itemIndex` and a filter over `items` to count how many successful items precede this one

```yaml
retention:
  historyLimit: 10
  expression: >
    item.status.conditions.exists(c, c.type == "Failed" && c.status == "True")
    || (
      !item.status.conditions.exists(c, c.type == "Complete" && c.status == "True")
      && timestamp(item.metadata.creationTimestamp) < timestamp(now()) - duration("1h")
    )
```

This example deletes failed items immediately and also deletes any item that has not completed within 1 hour — treating a stuck job as prunable while keeping successful history up to `historyLimit`.

All three fields are optional. A `retention:` block with only `expression` and no `historyLimit` or `ttl` relies entirely on the expression to drive pruning, which can leave unbounded history if the expression never returns `true`.

## Delete and orphan semantics with multiple versions

When a event arrives for a resource that is marked for deletion and multi-result discovery is active, all discovered versions of the resource should be affected — not only the current version. Leaving historical versions in place after a delete would orphan them with no cleanup path, since the API resource they reference will be deleted when reporting with `Finalized=True`.

- **`lifecycle.delete.when`**: evaluated once as a gate; if true, the executor deletes all discovered versions.
- **`lifecycle.orphan.when`**: evaluated once as a gate; if true, ownership labels are stripped from all discovered versions before reporting `Finalized=True`. This ensures no version remains visible to the sweep controller.

The precedence rule is unchanged: `lifecycle.orphan.when` is evaluated before `lifecycle.delete.when`. If orphan fires, the delete step is skipped for all versions.

## Example — provisioning job with history

```yaml
resources:
  - name: provisioningJob
    when:
      expression: >
        !resources.?provisioningJob.hasValue()
        || timestamp(resources.provisioningJob.metadata.creationTimestamp)
             < timestamp(now()) - duration("10m")
    transport:
      client: "kubernetes"
    manifest:
      apiVersion: batch/v1
      kind: Job
      metadata:
        name: "{{ .clusterId }}-job-{{ .now | replace \":\" \"-\" }}"
        namespace: "{{ .namespace }}"
        annotations:
          hyperfleet.io/generation: "{{ .generation }}"
    discovery:
      namespace: "{{ .namespace }}"
      by_selectors:
        label_selector:
          hyperfleet.io/resource-id: "{{ .resourceId }}"
    retention:
      historyLimit: 5
      ttl: 48h
    lifecycle:
      recreate:
        when:
          expression: >
            resources.provisioningJob.status.conditions.exists(
              c, c.type == "Complete" && c.status == "True")
            || resources.provisioningJob.status.conditions.exists(
              c, c.type == "Failed" && c.status == "True")
```

The resource-level `when` prevents a burst of convergence events from creating multiple jobs: if the current version is younger than 10 minutes the entire resource is skipped. Once the interval elapses, `lifecycle.recreate.when` is evaluated — it fires when the job has completed or failed, triggering a new run. Retention keeps at most 5 historical runs and discards any older than 48 hours.

## Related Documentation

- [Adapter Resource Lifecycle Management Design](./adapter-lifecycle-management-design.md) — Main index document
- [Adapter Lifecycle Gates](./adapter-lifecycle-gates.md) — §1: Lifecycle Gates (including the `when` gate used for debouncing)
- [Adapter Label Stamping](./adapter-label-stamping.md) — §2: Automatic Label and Annotation Stamping (provides `hyperfleet.io/resource-id` for multi-result discovery)
- [Adapter Resilience Model](./adapter-resilience-model.md) — §3: Resilience Model
- [Adapter Stuck Detection](./adapter-stuck-detection.md) — §4: Stuck Detection
- [Adapter Periodic Execution](./adapter-periodic-execution.md) — §5: Periodic Execution
- [Adapter Sweep Controller](./adapter-sweep-controller.md) — §7: Sweep Controller
