---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-03-20
---

# HyperFleet Metrics Standard

## Overview

This document defines the standard conventions for Prometheus metrics across all HyperFleet components (API, Sentinel, Adapters).

### Goals

- **Consistency**: All components follow the same naming and labeling conventions
- **Predictability**: Engineers can anticipate metric names and labels across repositories
- **Observability**: Standardized metrics enable unified dashboards and alerting

### Non-Goals

- Creating a shared metrics library
- Mandating a specific metrics framework beyond Prometheus compatibility

---

## Metric Naming Convention

All metrics MUST follow the Prometheus naming best practices with HyperFleet-specific prefixes.

### Format

```prometheus
hyperfleet_<component>_<metric_name>_<unit>
```

| Element | Description | Examples |
|---------|-------------|----------|
| `hyperfleet_` | Global prefix for all HyperFleet metrics | Required |
| `<component>` | Component name | `api`, `sentinel`, `adapter` |
| `<metric_name>` | Descriptive name using snake_case | `events_processed`, `request_duration` |
| `<unit>` | Unit suffix (when applicable) | `_seconds`, `_bytes`, `_total` |

### Naming Rules

1. **Use snake_case** for all metric names
2. **Use `_total` suffix** for counters
3. **Use `_seconds` suffix** for durations (always use seconds, not milliseconds)
4. **Use `_bytes` suffix** for sizes
5. **Use `_info` suffix** for info metrics (gauges with static labels)
6. **Avoid redundant prefixes** - don't repeat component name in metric name

### Examples

```prometheus
hyperfleet_api_requests_total
hyperfleet_sentinel_poll_duration_seconds
hyperfleet_adapter_events_processed_total
```

---

## Required Labels

All metrics MUST include these standard labels:

| Label | Description | Example Values |
|-------|-------------|----------------|
| `component` | Component name | `api`, `sentinel`, `adapter-validation` |
| `version` | Component version | `v1.2.3`, `dev-abc123` |

### Example

```prometheus
hyperfleet_sentinel_events_published_total{component="sentinel", version="v1.2.3", resource_type="clusters"} 1523
hyperfleet_adapter_events_processed_total{component="adapter-validation", version="v1.0.0", status="success"} 834
hyperfleet_api_requests_total{component="api", version="v2.1.0", method="GET", status_code="200"} 10234
```

### Label Best Practices

**DO:**
- Use labels for dimensions that need filtering/aggregation
- Keep label cardinality low (< 100 unique values per label)
- Use consistent label names across metrics
- Sanitize dynamic values (replace IDs with placeholders)

**DON'T:**
- Use high-cardinality labels (cluster IDs, user IDs, timestamps)
- Include sensitive information in labels
- Use labels for data that changes frequently

**Endpoint Path Sanitization:**

```text
/clusters/cls-abc123              → /clusters/{id}
/clusters/cls-abc/nodepools/np-1  → /clusters/{id}/nodepools/{id}
/namespaces/ns-123/jobs/job-456   → /namespaces/{ns}/jobs/{name}
```

---

## Standard Metrics

Every HyperFleet component MUST expose these baseline metrics:

### Process Metrics

Go applications automatically expose these via the Prometheus client library:

| Metric | Type | Description |
|--------|------|-------------|
| `go_goroutines` | Gauge | Number of goroutines |
| `go_memstats_alloc_bytes` | Gauge | Bytes allocated and in use |
| `go_gc_duration_seconds` | Summary | GC pause duration |
| `process_cpu_seconds_total` | Counter | Total CPU time |
| `process_resident_memory_bytes` | Gauge | Resident memory size |

### Build Info

Every component MUST expose a build info metric:

```prometheus
hyperfleet_sentinel_build_info{component="sentinel", version="v1.2.3", commit="abc123", go_version="go1.21"} 1
```

### Health Status

Every component SHOULD expose health status as a metric:

```prometheus
hyperfleet_sentinel_up{component="sentinel", version="v1.2.3"} 1
```

---

## Metric Types and Usage

### Counter

Use for values that only increase (can reset to zero on restart).

```prometheus
# Total requests processed
hyperfleet_api_requests_total{component="api", version="v1.0.0", method="GET", path="/clusters/{id}", status_code="200"} 1523

# Total errors
hyperfleet_adapter_errors_total{component="adapter-validation", version="v1.0.0", error_type="api_error"} 12
```

### Gauge

Use for values that can go up or down.

```prometheus
# Current queue depth
hyperfleet_sentinel_pending_resources{component="sentinel", version="v1.2.3", resource_type="clusters"} 42

# Current connections
hyperfleet_api_active_connections{component="api", version="v1.0.0"} 15
```

### Histogram

Use for measuring distributions (latency, size).

```prometheus
hyperfleet_api_request_duration_seconds_bucket{component="api", version="v1.0.0", method="GET", le="0.1"} 1200
hyperfleet_api_request_duration_seconds_bucket{component="api", version="v1.0.0", method="GET", le="0.5"} 1450
hyperfleet_api_request_duration_seconds_bucket{component="api", version="v1.0.0", method="GET", le="+Inf"} 1523
hyperfleet_api_request_duration_seconds_sum{component="api", version="v1.0.0", method="GET"} 234.56
hyperfleet_api_request_duration_seconds_count{component="api", version="v1.0.0", method="GET"} 1523
```

### Summary

Avoid summaries in favor of histograms. Histograms are more flexible for aggregation.

---

## Histogram Bucket Recommendations

Choose buckets based on the expected value distribution:

### API Request Duration

For HTTP API calls (fast operations):

```go
Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10}
```

### Event Processing Duration

For adapter event processing (potentially long operations):

```go
Buckets: []float64{0.1, 0.5, 1, 2, 5, 10, 30, 60, 120}
```

### Database Query Duration

For database operations:

```go
Buckets: []float64{0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1}
```

### General Guidelines

1. Include buckets at expected p50, p90, p95, p99 values
2. Ensure at least 2-3 buckets below typical values
3. Include buckets above SLO thresholds for alerting
4. Maximum 10-15 buckets to limit cardinality

---

## Metrics Exposition

### Port and Path

All HyperFleet components MUST use:

| Port | Path | Description |
|------|------|-------------|
| `9090` | `/metrics` | Prometheus metrics endpoint |

### OpenMetrics Compatibility

All metrics MUST be compatible with OpenMetrics format. The Prometheus Go client handles this automatically.

---

## Component-Specific Metrics

For detailed metrics definitions per component, see:

- **Sentinel**: [Sentinel Operator Guide](https://github.com/openshift-hyperfleet/hyperfleet-sentinel/blob/main/docs/sentinel-operator-guide.md)
- **Adapters**: [Adapter Metrics](../components/adapter/framework/adapter-metrics.md)

---

## References

- [Prometheus Naming Best Practices](https://prometheus.io/docs/practices/naming/)
- [Prometheus Go Client](https://github.com/prometheus/client_golang)
- [OpenMetrics Specification](https://github.com/OpenObservability/OpenMetrics)
- [HyperFleet Health Endpoints](./health-endpoints.md)
- [HyperFleet Logging Specification](./logging-specification.md)
- [HyperFleet Tracing Standard](./tracing.md)
