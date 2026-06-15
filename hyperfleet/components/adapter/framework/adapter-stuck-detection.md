---
Status: Draft
Owner: HyperFleet Team
Last Updated: 2026-06-16
---

# Adapter Stuck Detection

> Part of [Adapter Resource Lifecycle Management Design](./adapter-lifecycle-management-design.md)

**Current state**: The HyperFleet API already exposes deletion-specific stuck detection via `hyperfleet_api_resource_pending_deletion_stuck` — a gauge computed on each Prometheus scrape by querying the database for resources with `deleted_time` set beyond a configurable threshold (default 30 minutes). This covers the deletion flow only and has no equivalent for create and update reconciliations.

**Planned** ([HYPERFLEET-1205](https://redhat.atlassian.net/browse/HYPERFLEET-1205)): A unified reconciliation metrics system that extends the same pattern to all reconciliation flows using the `Reconciled=False` condition already stored on API resources.

New metrics:

| Metric | Type | Description |
|---|---|---|
| `hyperfleet_api_reconciliation_requests_total` | Counter | Incremented when `Reconciled` transitions to `False` |
| `hyperfleet_api_resource_pending_reconciliation` | Gauge | Resources currently in `Reconciled=False` state |
| `hyperfleet_api_resource_pending_reconciliation_stuck` | Gauge | Resources where `Reconciled=False` has persisted beyond the stuck threshold |
| `hyperfleet_api_resource_pending_reconciliation_stuck_duration_seconds` | Gauge | Maximum duration any resource has been stuck |

All metrics carry an `is_delete` label (`true` when `deleted_time IS NOT NULL`) to differentiate deletion flows from create/update flows. The existing deletion metrics become redundant and will be removed once HYPERFLEET-1205 ships.

**Why no adapter-side annotation is needed**: the API stores the `Reconciled=False` condition with a transition timestamp in its database. Duration and stuck detection are computed from that timestamp via DB queries at scrape time — the API is the authoritative source. The adapter's responsibility is to correctly report `Available=False` on apply failure, which drives `Reconciled=False` on the API resource. Sentinel picks up the signal and retriggers; if `Reconciled=False` persists beyond the threshold, the API metrics surface it. No annotation on the managed K8s resource is required.

## Related Documentation

- [Adapter Resource Lifecycle Management Design](./adapter-lifecycle-management-design.md) — Main index document
- [Adapter Lifecycle Gates](./adapter-lifecycle-gates.md) — §1: Lifecycle Gates
- [Adapter Label Stamping](./adapter-label-stamping.md) — §2: Automatic Label and Annotation Stamping
- [Adapter Resilience Model](./adapter-resilience-model.md) — §3: Resilience Model
- [Adapter Periodic Execution](./adapter-periodic-execution.md) — §5: Periodic Execution
- [Adapter Resource Retention](./adapter-resource-retention.md) — §6: Resource Retention
- [Adapter Sweep Controller](./adapter-sweep-controller.md) — §7: Sweep Controller
