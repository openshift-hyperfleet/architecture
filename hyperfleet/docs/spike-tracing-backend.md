---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-07-31
---

# Spike: Distributed Tracing Backend and Observability Stack

**Date:** 2026-07-22

---

## 1. Context

HyperFleet has full OTel SDK instrumentation across API, Sentinel, and Adapter with W3C traceparent propagation via HTTP headers and CloudEvent extensions. However, no tracing backend or monitoring infrastructure is deployed — tracing is disabled in all Helm charts, and the existing ServiceMonitor templates have no Prometheus to consume them.

This spike selects a tracing backend, defines the observability stack, and designs span attribute enrichment for cross-component resource tracing.

## 2. Observability Stack

| Component | Role |
|-----------|------|
| **kube-prometheus-stack** | Prometheus, Alertmanager, Grafana, Prometheus Operator — metrics collection and dashboarding |
| **Grafana Tempo** | Trace storage (local filesystem, PVC, or S3-compatible storage) |
| **OpenTelemetry Collector** | Tail-based trace sampling, forwards to Tempo. Chosen for its simplicity and alignment with Red Hat's existing OTel adoption |
| **Loki** | Log aggregation — planned for future |

## 3. Tracing Backend Selection

| Backend | Pros | Cons | Verdict |
|---------|------|------|---------|
| GCP Cloud Trace | Zero ops, managed, native Cloud Logging integration | GCP lock-in, no portability to kind or other clouds | Rejected |
| Jaeger | Full attribute search, mature CNCF project | Requires stateful DB (Elasticsearch or Cassandra) — ongoing ops burden disproportionate for our volume | Rejected |
| Grafana Tempo | Stateless, pluggable storage (local fs / PVC / GCS / S3), TraceQL for attribute search, native Grafana integration | TraceQL less mature than Jaeger search, Grafana UI required for full experience | **Selected** |

Tempo's TraceQL supports attribute-based queries (search by `resource_id`, filter by error status, find slow spans), closing the historical search gap with Jaeger.

## 4. Resource ID on API Traces

### Problem

API request traces carry no resource context. An operator querying Tempo by resource ID gets no API results, making it impossible to find the request that created or mutated a specific cluster or node pool.

### Design

The API service layer sets `hyperfleet.resource_id` as a span attribute on the request's root span. The service layer already enriches logger context with `resource_id` at the same points — adding a span attribute is one extra line per service method:

```go
trace.SpanFromContext(ctx).SetAttributes(
    attribute.String("hyperfleet.resource_id", resource.ID),
)
```

This covers all operations: Create (ID available after insert), Get, Patch, Delete (ID available from input). No API spec, database, or model changes required.

### Why not span links

Span links were considered — store the trace ID from the last write request on the resource, have Sentinel create a span link to it. Rejected for two reasons:

- **Sampling gap**: Span links cross trace boundaries, and tail-based sampling makes independent decisions per trace ID. A linked trace can be dropped while the linking trace is kept, producing dangling references with no standard mechanism to force retention of linked traces.
- **Misleading causality**: Sentinel can publish events after 30 minutes of no state change. A span link to the last write implies that request triggered the reconciliation, when the publish may be entirely unrelated to it.

## 5. Sampling Strategy

Components use the SDK default sampler (`parentbased_always_on`) — no override needed. The OpenTelemetry Collector handles all sampling decisions via tail-based policies:

| Policy | Rule | Rationale |
|--------|------|-----------|
| Errors | Keep all traces with an ERROR span | Always debug failures |
| API writes | Keep all traces where `http.request.method` is POST, PATCH, PUT, or DELETE | Ensures every mutation trace is available for resource lifecycle debugging |
| Reconciliations | Keep all traces where any span has attribute `messaging.operation.type` = `publish` | Actual work — sentinel decided a resource needs reconciliation |
| Baseline | 1% probabilistic | Sample of normal behavior for dashboards |

**Why tail-based:** HyperFleet's trace volume is low enough to buffer all spans in the Collector, making tail-based sampling practical. It is more reliable for debugging than head-based sampling because it retains traces based on outcomes — errors and reconciliations are always kept, rather than randomly dropped by a ratio decision made before the operation executes.

Same policies run in both kind and GKE for consistent behavior.

## 6. Retention

| Signal | Default (Helm chart) | Configuration |
|--------|---------------------|---------------|
| Traces (Tempo) | 48 hours | `compactor.compaction.block_retention` in Tempo Helm values |
| Metrics (Prometheus) | 10 days | `prometheus.prometheusSpec.retention` in kube-prometheus-stack values |

Defaults are set by the upstream Helm charts. Override per environment in `hyperfleet-infra` helmfile values if needed.

## 7. Implementation Scope

| Repository | Change |
|------------|--------|
| `hyperfleet-api` | Service layer sets `hyperfleet.resource_id` span attribute on Create, Get, Patch, and Delete operations |
| `hyperfleet-sentinel` | No changes (already sets `hyperfleet.resource_id` on `sentinel.evaluate` spans) |
| `hyperfleet-adapter` | No changes |
| `hyperfleet-infra` | Helm releases for kube-prometheus-stack, Tempo, and OpenTelemetry Collector. Environment-specific values for Tempo storage, sampling policies, and retention. Update `OTEL_EXPORTER_OTLP_ENDPOINT` in component Helm values to point to the collector |

## 8. Technical Notes

- OTel SDK is already wired in API, Sentinel, and Adapter — no SDK selection needed
- CloudEvent traceparent propagation (Sentinel → Adapter) is already implemented
- All component Helm charts have ServiceMonitor templates ready
- Sentinel Grafana dashboard exists at `deployments/dashboards/sentinel-metrics.json`
- `hyperfleet.resource_id` span attribute is set in the API service layer alongside existing logger context enrichment — no new infrastructure needed
