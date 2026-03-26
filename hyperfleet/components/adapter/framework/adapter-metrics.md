---
Status: Active
Owner: HyperFleet Adapter Team
Last Updated: 2026-02-24
---

# HyperFleet Adapter Metrics - MVP

## Overview

This document defines the minimum set of metrics that all HyperFleet adapters must expose for observability. These metrics enable baseline measurement and identify areas for post-MVP improvement.

---
Status: MVP
Last Updated: November 2025
---

**Related Documentation:**
- [HyperFleet Metrics Standard](../../../standards/metrics.md) - Cross-component metrics conventions
- [Adapter Framework Design](./adapter-frame-design.md) - Framework architecture
- `adapter-observability-config-template.yaml` - Observability configuration template
- [Adapter Deployment Guide](./adapter-deployment.md) - Deployment and operations

---

## CloudEvent Data Structure

The adapter processes CloudEvents with the following structure:

```yaml
specversion: "1.0"
type: "com.hyperfleet.nodepool.reconcile.v1"
source: "sentinel"
id: "00000000-0000-0000-0000-000000000000"
time: "2025-10-23T12:00:00Z"
datacontenttype: "application/json"
data:
  id: "11111111-1111-1111-1111-111111111111"
  kind: "NodePool"  # or "Cluster"
  href: "https://api.hyperfleet.com/v1/clusters/111.../nodepools/222..."
  generation: 5
  owner_references:
    id: "11111111-1111-1111-1111-111111111111"
    kind: "Cluster"
    href: "https://api.hyperfleet.com/v1/clusters/111..."
```

**Key Fields for Metrics**:
- `data.kind` - Used as `resource_kind` label in metrics (e.g., "Cluster", "NodePool")
- `data.id` - Resource identifier (not used in metrics to avoid high cardinality)
- `data.generation` - Resource generation (not used in metrics to avoid high cardinality)

---

## Metrics Format

**Standard**: Prometheus format (OpenMetrics compatible)
**Endpoint**: `/metrics`
**Port**: `9090`
**Protocol**: HTTP

**Required Labels**: All metrics MUST include `component` and `version` labels as defined in the [Metrics Standard](../../../standards/metrics.md).

For complete health and readiness endpoint standards, see [Health Endpoints Specification](../../../standards/health-endpoints.md).

---

## Required Metrics (MVP)

### 1. Event Processing Metrics

#### `hyperfleet_adapter_events_processed_total`

**Type**: Counter  
**Purpose**: Total number of CloudEvents processed by the adapter

**Labels**:
- `adapter_name` - Name of the adapter (e.g., "validation", "dns")
- `resource_kind` - Kind of resource being processed from event.data.kind (e.g., "Cluster", "NodePool")
- `status` - Processing outcome: `success`, `error`, `skipped`

**Example**:
```prometheus
hyperfleet_adapter_events_processed_total{component="adapter-validation",version="v1.0.0",adapter_name="validation",resource_kind="Cluster",status="success"} 1523
hyperfleet_adapter_events_processed_total{component="adapter-validation",version="v1.0.0",adapter_name="validation",resource_kind="Cluster",status="error"} 12
hyperfleet_adapter_events_processed_total{component="adapter-validation",version="v1.0.0",adapter_name="validation",resource_kind="Cluster",status="skipped"} 89
hyperfleet_adapter_events_processed_total{component="adapter-validation",version="v1.0.0",adapter_name="validation",resource_kind="NodePool",status="success"} 342
```

**Usage**:
- Track overall event throughput
- Identify error rates
- Measure skip frequency (preconditions not met)

---

#### `hyperfleet_adapter_event_processing_duration_seconds`

**Type**: Histogram  
**Purpose**: Time taken to process a CloudEvent (end-to-end)

**Labels**:
- `adapter_name` - Name of the adapter
- `resource_kind` - Kind of resource being processed from event.data.kind
- `status` - Processing outcome: `success`, `error`, `skipped`

**Buckets**: `0.1, 0.5, 1, 2, 5, 10, 30, 60, 120` (seconds)

**Example**:
```prometheus
hyperfleet_adapter_event_processing_duration_seconds_bucket{component="adapter-validation",version="v1.0.0",adapter_name="validation",resource_kind="Cluster",status="success",le="0.5"} 0
hyperfleet_adapter_event_processing_duration_seconds_bucket{component="adapter-validation",version="v1.0.0",adapter_name="validation",resource_kind="Cluster",status="success",le="1"} 5
hyperfleet_adapter_event_processing_duration_seconds_bucket{component="adapter-validation",version="v1.0.0",adapter_name="validation",resource_kind="Cluster",status="success",le="5"} 142
hyperfleet_adapter_event_processing_duration_seconds_sum{component="adapter-validation",version="v1.0.0",adapter_name="validation",resource_kind="Cluster",status="success"} 456.78
hyperfleet_adapter_event_processing_duration_seconds_count{component="adapter-validation",version="v1.0.0",adapter_name="validation",resource_kind="Cluster",status="success"} 150
```

**Usage**:
- Identify slow event processing
- Track p50, p95, p99 latencies
- Detect performance degradation

---

### 2. Resource Management Metrics

#### `hyperfleet_adapter_resources_created_total`

**Type**: Counter  
**Purpose**: Total number of Kubernetes resources created by the adapter

**Labels**:
- `adapter_name` - Name of the adapter
- `resource_type` - Kubernetes resource kind (e.g., "Job", "Deployment", "ConfigMap")
- `status` - Creation outcome: `success`, `error`

**Example**:
```prometheus
hyperfleet_adapter_resources_created_total{component="adapter-validation",version="v1.0.0",adapter_name="validation",resource_type="Job",status="success"} 45
hyperfleet_adapter_resources_created_total{component="adapter-validation",version="v1.0.0",adapter_name="validation",resource_type="ConfigMap",status="success"} 45
hyperfleet_adapter_resources_created_total{component="adapter-validation",version="v1.0.0",adapter_name="validation",resource_type="Job",status="error"} 2
```

**Usage**:
- Track resource creation activity
- Identify resource creation failures

---

#### `hyperfleet_adapter_resources_deleted_total`

**Type**: Counter  
**Purpose**: Total number of Kubernetes resources deleted by the adapter

**Labels**:
- `adapter_name` - Name of the adapter
- `resource_type` - Kubernetes resource kind
- `status` - Deletion outcome: `success`, `error`

**Example**:
```prometheus
hyperfleet_adapter_resources_deleted_total{component="adapter-validation",version="v1.0.0",adapter_name="validation",resource_type="Job",status="success"} 23
hyperfleet_adapter_resources_deleted_total{component="adapter-validation",version="v1.0.0",adapter_name="validation",resource_type="Job",status="error"} 1
```

**Usage**:
- Track cleanup operations
- Identify deletion failures

---

### 3. API Call Metrics

#### `hyperfleet_adapter_api_requests_total`

**Type**: Counter  
**Purpose**: Total number of API calls made by the adapter

**Labels**:
- `adapter_name` - Name of the adapter
- `api` - API being called: `hyperfleet`, `kubernetes`, `external`
- `method` - HTTP method: `GET`, `POST`, `PATCH`, `DELETE`
- `endpoint` - API endpoint (sanitized, no IDs): e.g., `/clusters/{id}`, `/statuses`
- `status_code` - HTTP status code: `200`, `404`, `500`, etc.

**Example**:
```prometheus
hyperfleet_adapter_api_requests_total{component="adapter-validation",version="v1.0.0",adapter_name="validation",api="hyperfleet",method="GET",endpoint="/clusters/{id}",status_code="200"} 1523
hyperfleet_adapter_api_requests_total{component="adapter-validation",version="v1.0.0",adapter_name="validation",api="hyperfleet",method="POST",endpoint="/statuses",status_code="200"} 1487
hyperfleet_adapter_api_requests_total{component="adapter-validation",version="v1.0.0",adapter_name="validation",api="kubernetes",method="POST",endpoint="/namespaces/{ns}/jobs",status_code="201"} 1432
hyperfleet_adapter_api_requests_total{component="adapter-validation",version="v1.0.0",adapter_name="validation",api="kubernetes",method="GET",endpoint="/namespaces/{ns}/jobs/{name}",status_code="200"} 2145
```

**Usage**:
- Track API call volume
- Identify failed API calls
- Monitor API usage patterns

---

#### `hyperfleet_adapter_api_request_duration_seconds`

**Type**: Histogram  
**Purpose**: Time taken for API requests

**Labels**:
- `adapter_name` - Name of the adapter
- `api` - API being called
- `method` - HTTP method
- `endpoint` - API endpoint (sanitized)

**Buckets**: `0.01, 0.05, 0.1, 0.5, 1, 2, 5` (seconds)

**Example**:
```prometheus
hyperfleet_adapter_api_request_duration_seconds_bucket{component="adapter-validation",version="v1.0.0",adapter_name="validation",api="hyperfleet",method="GET",endpoint="/clusters/{id}",le="0.1"} 1200
hyperfleet_adapter_api_request_duration_seconds_bucket{component="adapter-validation",version="v1.0.0",adapter_name="validation",api="hyperfleet",method="GET",endpoint="/clusters/{id}",le="0.5"} 1500
hyperfleet_adapter_api_request_duration_seconds_sum{component="adapter-validation",version="v1.0.0",adapter_name="validation",api="hyperfleet",method="GET",endpoint="/clusters/{id}"} 156.78
hyperfleet_adapter_api_request_duration_seconds_count{component="adapter-validation",version="v1.0.0",adapter_name="validation",api="hyperfleet",method="GET",endpoint="/clusters/{id}"} 1523
```

**Usage**:
- Identify slow API calls
- Track API latency percentiles
- Detect API performance issues

---

### 4. Precondition Metrics

#### `hyperfleet_adapter_preconditions_evaluated_total`

**Type**: Counter  
**Purpose**: Total number of precondition evaluations

**Labels**:
- `adapter_name` - Name of the adapter
- `precondition_name` - Name of the precondition from config (e.g., "clusterStatus", "validationAvailable")
- `result` - Evaluation result: `pass`, `fail`, `error`

**Example**:
```prometheus
hyperfleet_adapter_preconditions_evaluated_total{component="adapter-validation",version="v1.0.0",adapter_name="validation",precondition_name="clusterStatus",result="pass"} 1523
hyperfleet_adapter_preconditions_evaluated_total{component="adapter-validation",version="v1.0.0",adapter_name="validation",precondition_name="validationAvailable",result="fail"} 89
hyperfleet_adapter_preconditions_evaluated_total{component="adapter-validation",version="v1.0.0",adapter_name="validation",precondition_name="quotaStatus",result="error"} 3
```

**Usage**:
- Track precondition success/failure rates
- Identify problematic preconditions
- Monitor dependency health

---

### 5. Status Reporting Metrics

#### `hyperfleet_adapter_status_reports_total`

**Type**: Counter  
**Purpose**: Total number of status reports sent to HyperFleet API

**Labels**:
- `adapter_name` - Name of the adapter
- `status` - Report outcome: `success`, `error`
- `applied` - Applied condition value: `true`, `false`
- `available` - Available condition value: `true`, `false`

**Example**:
```prometheus
hyperfleet_adapter_status_reports_total{component="adapter-validation",version="v1.0.0",adapter_name="validation",status="success",applied="true",available="true"} 834
hyperfleet_adapter_status_reports_total{component="adapter-validation",version="v1.0.0",adapter_name="validation",status="success",applied="true",available="false"} 612
hyperfleet_adapter_status_reports_total{component="adapter-validation",version="v1.0.0",adapter_name="validation",status="success",applied="false",available="false"} 89
hyperfleet_adapter_status_reports_total{component="adapter-validation",version="v1.0.0",adapter_name="validation",status="error",applied="false",available="false"} 7
```

**Usage**:
- Track status reporting success rate
- Monitor condition distribution
- Identify reporting failures

---

### 6. Error Metrics

#### `hyperfleet_adapter_errors_total`

**Type**: Counter  
**Purpose**: Total number of errors encountered by the adapter

**Labels**:
- `adapter_name` - Name of the adapter
- `error_type` - Error category: `api_error`, `k8s_error`, `config_error`, `precondition_error`, `processing_error`
- `error_component` - Internal component where error occurred: `event_processor`, `precondition_evaluator`, `resource_manager`, `status_reporter`

**Example**:
```prometheus
hyperfleet_adapter_errors_total{component="adapter-validation",version="v1.0.0",adapter_name="validation",error_type="api_error",error_component="precondition_evaluator"} 12
hyperfleet_adapter_errors_total{component="adapter-validation",version="v1.0.0",adapter_name="validation",error_type="k8s_error",error_component="resource_manager"} 5
hyperfleet_adapter_errors_total{component="adapter-validation",version="v1.0.0",adapter_name="validation",error_type="processing_error",error_component="event_processor"} 3
```

**Usage**:
- Track overall error rates
- Identify error patterns
- Monitor adapter health

---

### 7. Workload Monitoring Metrics

#### `hyperfleet_adapter_workload_status_total`

**Type**: Counter  
**Purpose**: Total number of workload status checks performed

**Labels**:
- `adapter_name` - Name of the adapter
- `workload_type` - Type of workload: `Job`, `Deployment`, `StatefulSet`
- `status` - Workload status: `running`, `succeeded`, `failed`, `unknown`

**Example**:
```prometheus
hyperfleet_adapter_workload_status_total{component="adapter-validation",version="v1.0.0",adapter_name="validation",workload_type="Job",status="running"} 412
hyperfleet_adapter_workload_status_total{component="adapter-validation",version="v1.0.0",adapter_name="validation",workload_type="Job",status="succeeded"} 834
hyperfleet_adapter_workload_status_total{component="adapter-validation",version="v1.0.0",adapter_name="validation",workload_type="Job",status="failed"} 23
```

**Usage**:
- Track workload success/failure rates
- Monitor workload execution patterns
- Identify workload issues

### 8. Health Metrics

#### `hyperfleet_adapter_last_processed_timestamp_seconds`

**Type**: Gauge  
**Purpose**: Unix timestamp of the last successfully processed event. Used as a "Dead Man's Switch" to detect if the adapter has silently stopped processing events.

**Labels**:
- `adapter_name` - Name of the adapter

**Example**:
```prometheus
hyperfleet_adapter_last_processed_timestamp_seconds{component="adapter-validation",version="v1.0.0",adapter_name="validation"} 1698057600
```

**Usage**:
- Detect broken broker connections
- Identify "zombie" adapters that are running but not processing
- Alert if timestamp is too old (e.g., > 5 minutes)

---

## Implementation Guidelines

### 1. Metric Naming Convention

Follow Prometheus naming best practices and HyperFleet standards:
- Use `hyperfleet_adapter_` prefix for all adapter metrics (see [Metrics Standard](../../../standards/metrics.md))
- Use snake_case for metric names
- Use descriptive names that indicate what is being measured
- Use consistent label names across metrics

### 2. Label Best Practices

**DO**:
- Use labels for dimensions that need to be filtered/aggregated
- Keep label cardinality low (avoid unique IDs like cluster IDs)
- Use consistent label names across metrics
- Sanitize endpoint paths (replace IDs with `{id}`, `{name}`, etc.)

**DON'T**:
- Don't use high-cardinality labels (e.g., timestamp, user ID, cluster ID)
- Don't include sensitive information in labels
- Don't use labels for data that changes frequently

**Example of Sanitized Endpoints**:
```
✅ Good: /clusters/{id}
❌ Bad:  /clusters/cls-abc123

✅ Good: /namespaces/{ns}/jobs/{name}
❌ Bad:  /namespaces/cluster-cls-123/jobs/validation-job-gen5
```

### 3. Metric Collection Points

```go
// Example: Instrument event processing
func (a *Adapter) ProcessEvent(event CloudEvent) error {
    startTime := time.Now()

    // Process event
    err := a.processEventInternal(event)

    // Record metrics
    status := "success"
    if err != nil {
        status = "error"
    }

    // Metric: hyperfleet_adapter_events_processed_total
    a.metrics.eventsProcessed.WithLabelValues(
        a.config.Name,
        event.Data.Kind, // e.g., "Cluster", "NodePool"
        status,
    ).Inc()

    // Metric: hyperfleet_adapter_event_processing_duration_seconds
    a.metrics.eventDuration.WithLabelValues(
        a.config.Name,
        event.Data.Kind,
        status,
    ).Observe(time.Since(startTime).Seconds())

    return err
}
```

### 4. Histogram Bucket Configuration

**Event Processing Duration**:
- Buckets: `0.1, 0.5, 1, 2, 5, 10, 30, 60, 120` seconds
- Rationale: Events can range from quick skips (< 1s) to long workload monitoring (> 60s)

**API Request Duration**:
- Buckets: `0.01, 0.05, 0.1, 0.5, 1, 2, 5` seconds
- Rationale: API calls should be fast, most completing in < 1s

### 5. Metric Export

**Prometheus Format**:
```prometheus
# HELP hyperfleet_adapter_events_processed_total Total number of CloudEvents processed by the adapter
# TYPE hyperfleet_adapter_events_processed_total counter
hyperfleet_adapter_events_processed_total{component="adapter-validation",version="v1.0.0",adapter_name="validation",resource_kind="Cluster",status="success"} 1523

# HELP hyperfleet_adapter_event_processing_duration_seconds Time taken to process a CloudEvent
# TYPE hyperfleet_adapter_event_processing_duration_seconds histogram
hyperfleet_adapter_event_processing_duration_seconds_bucket{component="adapter-validation",version="v1.0.0",adapter_name="validation",resource_kind="Cluster",status="success",le="0.1"} 0
hyperfleet_adapter_event_processing_duration_seconds_bucket{component="adapter-validation",version="v1.0.0",adapter_name="validation",resource_kind="Cluster",status="success",le="0.5"} 5
hyperfleet_adapter_event_processing_duration_seconds_bucket{component="adapter-validation",version="v1.0.0",adapter_name="validation",resource_kind="Cluster",status="success",le="+Inf"} 150
hyperfleet_adapter_event_processing_duration_seconds_sum{component="adapter-validation",version="v1.0.0",adapter_name="validation",resource_kind="Cluster",status="success"} 456.78
hyperfleet_adapter_event_processing_duration_seconds_count{component="adapter-validation",version="v1.0.0",adapter_name="validation",resource_kind="Cluster",status="success"} 150
```

---

## Metrics Endpoint

### Health and Metrics Endpoints

**Health Endpoints** (Port `8080`):
- `GET /healthz` - Liveness probe, returns `200 OK` if adapter is alive
- `GET /readyz` - Readiness probe, returns `200 OK` if adapter is ready to serve traffic

**Metrics Endpoint** (Port `9090`):
- `GET /metrics` - Returns Prometheus-formatted metrics

### Example Service Configuration

```yaml
apiVersion: v1
kind: Service
metadata:
  name: validation-adapter
  namespace: hyperfleet-system
  labels:
    app: validation-adapter
spec:
  selector:
    app: validation-adapter
  ports:
    - name: health
      port: 8080
      targetPort: 8080
      protocol: TCP
    - name: metrics
      port: 9090
      targetPort: 9090
      protocol: TCP
  type: ClusterIP
```

### Example ServiceMonitor (Prometheus Operator)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: validation-adapter
  namespace: hyperfleet-system
  labels:
    app: validation-adapter
spec:
  selector:
    matchLabels:
      app: validation-adapter
  endpoints:
    - port: metrics
      path: /metrics
      interval: 30s
      scrapeTimeout: 10s
```

---

## Dashboard Queries (PromQL)

### Event Processing Rate

```promql
# Events processed per second (by status)
rate(hyperfleet_adapter_events_processed_total[5m])

# Success rate percentage
(
  sum(rate(hyperfleet_adapter_events_processed_total{status="success"}[5m]))
  /
  sum(rate(hyperfleet_adapter_events_processed_total[5m]))
) * 100
```

### Event Processing Latency

```promql
# p95 event processing time
histogram_quantile(0.95,
  rate(hyperfleet_adapter_event_processing_duration_seconds_bucket[5m])
)

# Average event processing time
rate(hyperfleet_adapter_event_processing_duration_seconds_sum[5m])
/
rate(hyperfleet_adapter_event_processing_duration_seconds_count[5m])
```

### Resource Creation Rate

```promql
# Resources created per minute
sum(rate(hyperfleet_adapter_resources_created_total{status="success"}[5m])) * 60

# Resource creation success rate
(
  sum(rate(hyperfleet_adapter_resources_created_total{status="success"}[5m]))
  /
  sum(rate(hyperfleet_adapter_resources_created_total[5m]))
) * 100
```

### API Call Performance

```promql
# p99 API latency by endpoint
histogram_quantile(0.99,
  sum by(endpoint, le) (rate(hyperfleet_adapter_api_request_duration_seconds_bucket[5m]))
)

# API error rate by endpoint
sum by(endpoint) (rate(hyperfleet_adapter_api_requests_total{status_code=~"5.."}[5m]))
```

### Precondition Pass Rate

```promql
# Precondition pass rate percentage
(
  sum(rate(hyperfleet_adapter_preconditions_evaluated_total{result="pass"}[5m]))
  /
  sum(rate(hyperfleet_adapter_preconditions_evaluated_total[5m]))
) * 100
```

### Error Rate

```promql
# Total error rate
sum(rate(hyperfleet_adapter_errors_total[5m]))

# Error rate by adapter deployment (component label)
sum by(component) (rate(hyperfleet_adapter_errors_total[5m]))

# Error rate by internal error source (error_component label)
sum by(error_component) (rate(hyperfleet_adapter_errors_total[5m]))
```

---

## Alerting Rules (Examples)

### Silent Failure (Dead Man's Switch)

```yaml
- alert: AdapterNotProcessing
  expr: |
    (time() - hyperfleet_adapter_last_processed_timestamp_seconds) > 300
  for: 5m
  labels:
    severity: critical
  annotations:
    summary: "Adapter {{ $labels.adapter_name }} has stopped processing events"
    description: "Last successful event was processed {{ $value | humanizeDuration }} ago (threshold: 5m)"
```

### High Error Rate

```yaml
- alert: AdapterHighErrorRate
  expr: |
    (
      sum(rate(hyperfleet_adapter_events_processed_total{status="error"}[5m]))
      /
      sum(rate(hyperfleet_adapter_events_processed_total[5m]))
    ) > 0.05
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "Adapter {{ $labels.adapter_name }} has high error rate"
    description: "Error rate is {{ $value | humanizePercentage }} (threshold: 5%)"
```

### Slow Event Processing

```yaml
- alert: AdapterSlowEventProcessing
  expr: |
    histogram_quantile(0.95,
      rate(hyperfleet_adapter_event_processing_duration_seconds_bucket[5m])
    ) > 60
  for: 10m
  labels:
    severity: warning
  annotations:
    summary: "Adapter {{ $labels.adapter_name }} is processing events slowly"
    description: "p95 processing time is {{ $value }}s (threshold: 60s)"
```

### API Errors

```yaml
- alert: AdapterHighAPIErrorRate
  expr: |
    (
      sum(rate(hyperfleet_adapter_api_requests_total{status_code=~"5.."}[5m]))
      /
      sum(rate(hyperfleet_adapter_api_requests_total[5m]))
    ) > 0.01
  for: 5m
  labels:
    severity: critical
  annotations:
    summary: "Adapter {{ $labels.adapter_name }} has high API error rate"
    description: "API error rate is {{ $value | humanizePercentage }} (threshold: 1%)"
```

---

## Baseline Metrics (Expected Values)

These are rough estimates for baseline metrics to help identify anomalies:

| Metric | Expected Range | Notes |
|--------|----------------|-------|
| Event processing duration (p95) | 2-10s | For events with preconditions met |
| Event processing duration (p95, skipped) | < 1s | For events skipped due to preconditions |
| API request duration (p95) | 100-500ms | For HyperFleet API calls |
| Kubernetes API duration (p95) | 50-200ms | For K8s resource operations |
| Event success rate | > 95% | Percentage of successfully processed events |
| Precondition pass rate | 60-80% | Many events skipped due to preconditions |
| Resource creation success rate | > 98% | K8s resource creation should rarely fail |
| Status report success rate | > 99% | Status reporting should be very reliable |

**Note**: These are initial estimates. Actual baselines should be established during MVP testing.

---

## Post-MVP Improvements

After establishing baselines, consider these additional metrics:

1. **Detailed Workload Metrics**:
   - Job execution time distribution
   - Pod restart counts
   - Container failure reasons

2. **CEL Expression Metrics**:
   - Expression evaluation time
   - Expression evaluation errors
   - Expression cache hit rate

3. **Message Broker Metrics**:
   - Message acknowledgment latency
   - Message redelivery count
   - Queue depth

4. **Memory and CPU Metrics**:
   - Heap memory usage
   - GC pause time
   - CPU utilization

5. **Business Metrics**:
   - Clusters processed by phase
   - Adapter availability by cluster
   - Generation lag (event generation vs processed generation)

---

## Implementation Checklist

For each adapter, ensure:

- [ ] All required metrics are implemented
- [ ] Metrics endpoint is exposed on `/metrics`
- [ ] ServiceMonitor is configured for Prometheus scraping
- [ ] Labels follow naming conventions
- [ ] Endpoint paths are sanitized (no high-cardinality values)
- [ ] Histogram buckets are appropriate for the metric
- [ ] Basic alerting rules are configured
- [ ] Grafana dashboard is created for the adapter

---

## References

- [HyperFleet Metrics Standard](../../../standards/metrics.md) - Cross-component metrics conventions
- [Prometheus Best Practices](https://prometheus.io/docs/practices/naming/) - Metric naming conventions
- [Prometheus Go Client](https://github.com/prometheus/client_golang) - Go client library
- [OpenMetrics Specification](https://github.com/OpenObservability/OpenMetrics) - Metrics format specification

---

