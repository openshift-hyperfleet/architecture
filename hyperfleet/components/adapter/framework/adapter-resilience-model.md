---
Status: Draft
Owner: HyperFleet Team
Last Updated: 2026-06-16
---

# Adapter Resilience Model

> Part of [Adapter Resource Lifecycle Management Design](./adapter-lifecycle-management-design.md)

**TL;DR;** Do nothing, HyperFleet resiliency is accomplished by Sentinel retriggering events (keep reading only for more explanation)

The adapter does not implement per-resource retry for apply and delete operations. The resilience model for HyperFleet is the Sentinel reconciliation cycle: Sentinel continuously compares observed resource state against the desired spec and generates a new event approximately every 10 seconds for as long as the state has not converged. Once the state converges, Sentinel switches to a periodic drift-check cadence (default: every 30 minutes).

**Reconciliation events**: a transient apply failure leaves the resource state unchanged and unconverged. Sentinel observes continued divergence and sends the next event at the ~10s cadence. No inner retry is needed.

**Drift-check events**: Sentinel also sends periodic events (default every 30 minutes) to detect and correct drift on resources that were previously converged. This introduces a corner case: if the apply fails during a drift-check event, the resource state is unchanged and still appears converged to Sentinel, which would otherwise not retrigger for another 30 minutes. This gap is closed by the adapter reporting `Available=False` on the API resource whenever an apply fails. `Available=False` signals to Sentinel that the resource is not reconciled, causing it to switch from the drift cadence back to the ~10s convergence cadence. The adapter must always surface apply failures via status conditions — this is what keeps the gap closed regardless of which Sentinel cadence triggered the event.

Adding an inner retry loop inside a single event execution creates a two-loop problem:

- **Concurrent execution risk**: a retry with a long `activeDeadline` holds the event execution open while Sentinel generates new events because the resource has not converged (or has reported `Available=False`). Multiple executions attempt the same apply against an already-stressed API server.
- **Redundancy**: the failure classes an inner retry would handle are already covered by the Sentinel cycle, provided the adapter surfaces failures correctly.
- **Backoff amplification**: exponential backoff inside the adapter does not coordinate with Sentinel's cadence. Under sustained API server pressure, both loops fire independently, increasing load rather than reducing it.

The adapter's responsibility is to drive state convergence and always report failure via `Available=False` and status conditions. Retry is a property of the reconciliation loop, not of a single event execution.

The existing retry mechanism in `internal/hyperfleetapi/client.go` (used for precondition API calls) is retained as-is. Precondition calls are synchronous blocking checks where a short backoff before concluding failure is semantically correct. Resource apply and delete do not share this property.

## Alternatives Considered

### §3 — Resilience Model

#### hyperfleet.io/last-updated Annotation

During the design of the Periodic Execution section, a `hyperfleet.io/last-updated` annotation was considered as a framework-stamped RFC3339 timestamp recording when the adapter last successfully applied a resource. This would make time-aware CEL expressions in drift-check cycles straightforward without requiring a precondition API call:

```yaml
lifecycle:
  patch:
    - when:
        expression: >
          resources.?certSecret.hasValue()
          && dig(resources.certSecret.metadata.annotations, "hyperfleet.io/last-updated") < now()
      document:
        metadata:
          annotations:
            example.io/rotated-at: "{{ .now }}"
```

Other uses where this pattern is useful:

- **Rate-limiting expensive operations** — only trigger a heavyweight recreation or API call if the last successful apply was more than N hours ago, even though Sentinel sends drift events every 30 minutes
- **Audit trail on the resource** — operators can `kubectl describe` a resource and see when the adapter last touched it without querying the HyperFleet API
- **Cross-adapter coordination** — a downstream adapter can read `hyperfleet.io/last-updated` stamped by an upstream adapter on a shared resource to condition its own actions on recency

**Why this was not adopted at framework level**: no specific use case in the current design requires it. The HyperFleet API already stores `lastTransitionTime` on the `Reconciled` condition, which is the authoritative timestamp for reconciliation events. Stamping an additional annotation on every managed resource adds a write on every apply cycle for a capability that may never be used by most adapters.

No ecosystem precedent exists for a standalone last-applied timestamp annotation on managed resources — ArgoCD, Flux, and Helm all avoid it, relying on `metadata.managedFields[].time` or status conditions on controller objects instead. Crossplane is the closest precedent, using RFC3339 timestamps on managed resources for creation-lifecycle tracking only.

**For adapter authors who need this**: add the annotation manually to the manifest template. The framework will not overwrite it (fill-gaps-only merge strategy). A custom key is equally valid — there is no requirement to use the `hyperfleet.io/` prefix for adapter-specific bookkeeping:

```yaml
manifest:
  metadata:
    annotations:
      hyperfleet.io/generation: "{{ .generation }}"
      my-adapter.io/last-updated: "{{ .now }}"   # custom key, stamped by adapter author
```

The `now()` template function is available in Go templates used for manifest rendering, providing the current RFC3339 timestamp at event execution time.

#### Per-Resource Retry with Backoff

An earlier version of this design proposed a per-resource retry configuration for apply and delete operations, modeled on the existing retry mechanism for precondition API calls:

```yaml
resources:
  - name: "managedCluster"
    retry:
      maxRetries: 3
      retryBackoff: exponential    # exponential | linear | constant
      activeDeadline: 60s
    transport:
      client: "kubernetes"
    ...
```

The proposed behavior: on a transient transport error (connection refused, timeout, 429, 503), the executor would wait for an exponential/linear/constant backoff interval (±10% jitter) and retry up to `maxRetries` times before surfacing the error as a resource failure. The `activeDeadline` would be enforced via `context.WithDeadline`. Implementation would extract the existing retry loop from `internal/hyperfleetapi/client.go` into a new `pkg/retry` package.

**Why this was not adopted**: The Sentinel reconciliation cycle covers both failure scenarios. For convergence events, a failed apply leaves the resource unconverged and Sentinel retriggers at ~10s. For periodic drift-check events (default every 30 minutes), a failed apply could create a gap — but the adapter closes it by reporting `Available=False` on failure, which signals Sentinel to treat the resource as not reconciled and switch back to the ~10s cadence. Provided the adapter always reports failure correctly via status conditions, no inner retry is needed. An inner retry loop also creates concurrent execution risk: if the resource has not converged (or has reported `Available=False`), Sentinel generates new events while the retry holds the current execution open, causing multiple executions to contend against an already-stressed API server.

The existing retry in `internal/hyperfleetapi/client.go` is not affected — precondition calls are synchronous blocking checks where a short backoff before concluding failure is semantically correct, and they are not subject to Sentinel retriggering.

**If this is revisited**: Any inner retry must complete well within the Sentinel cycle (< 5s total backoff). `maxRetries` should be at most 1–2, with no `activeDeadline` longer than a few seconds. It should be framed as "avoid unnecessary Sentinel cycles for sub-second blips," not as a resilience primitive.

## Related Documentation

- [Adapter Resource Lifecycle Management Design](./adapter-lifecycle-management-design.md) — Main index document
- [Adapter Lifecycle Gates](./adapter-lifecycle-gates.md) — §1: Lifecycle Gates
- [Adapter Label Stamping](./adapter-label-stamping.md) — §2: Automatic Label and Annotation Stamping
- [Adapter Stuck Detection](./adapter-stuck-detection.md) — §4: Stuck Detection
- [Adapter Periodic Execution](./adapter-periodic-execution.md) — §5: Periodic Execution
- [Adapter Resource Retention](./adapter-resource-retention.md) — §6: Resource Retention
- [Adapter Sweep Controller](./adapter-sweep-controller.md) — §7: Sweep Controller
