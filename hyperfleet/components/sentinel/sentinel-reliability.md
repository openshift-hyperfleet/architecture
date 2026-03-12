# Sentinel Reliability and Observability

**Status**: Active
**Owner**: Architecture Team
**Last Updated**: 2026-03-11

---

## Overview

This document provides comprehensive operational documentation for teams deploying and operating the HyperFleet Sentinel service. It covers built-in reliability features, observability capabilities, alerting configurations, and operational best practices.

---

## Reliability Features

The Sentinel service is designed with multiple layers of reliability to ensure continuous reconciliation of HyperFleet resources.

### Stateless Design

**What**: Sentinel maintains no persistent state between polling cycles.

**Implementation**:
- All reconciliation decisions are made based on current resource state from the HyperFleet API
- No local databases or persistent storage requirements
- Configuration loaded once at startup from YAML files and environment variables
- Each polling cycle starts fresh from API data

**Benefits**:
- Simple horizontal scaling (no state coordination needed)
- Fast recovery after restarts (no state reconstruction)
- Eliminates state corruption issues
- Simplified deployment (no persistent volumes)

**Operational Impact**: Sentinel instances can be stopped/started without data loss. Resource reconciliation continues from the last adapter-reported status.

### Graceful Shutdown

**What**: Sentinel responds to SIGTERM/SIGINT signals with controlled shutdown.

**Implementation**:
- Listens for termination signals during main polling loop
- Completes current polling cycle before exiting
- Maximum shutdown time: 20 seconds for HTTP server shutdown
- Publishes any pending events before shutdown
- Cleans up broker connections gracefully

**Configuration**:
```yaml
spec:
  template:
    spec:
      terminationGracePeriodSeconds: 30
```

**Operational Impact**: Graceful shutdown minimizes event loss by attempting to publish pending events before exit, subject to the grace period.

### API Retry Logic

**What**: Automatic retry with exponential backoff for HyperFleet API calls.

**Implementation**:
- **Timeout**: 5 seconds per API call (configurable via `hyperfleet_api.timeout`)
- **Initial interval**: 500ms (first retry after 500ms)
- **Max interval**: 8 seconds (maximum retry interval)
- **Multiplier**: 2.0 (doubles interval each retry: 500ms → 1s → 2s → 4s → 8s)
- **Randomization**: 10% jitter added to prevent thundering herd
- **Max elapsed time**: 30 seconds total (time-based retry, not attempt-based)
- **Failure handling**: Logs errors, continues with next resource after max elapsed time

**Configuration**:
```yaml
hyperfleet_api:
  endpoint: http://hyperfleet-api.hyperfleet-system.svc.cluster.local:8000
  timeout: 5s
```

**Metrics**: Failed API calls tracked via `hyperfleet_sentinel_api_errors_total` metric.

**Operational Impact**: Transient API issues don't stop reconciliation. Service continues polling after API recovery.

### Broker Publish Retry

**What**: Automatic retry for message broker publishing failures.

**Implementation**:
- **External library**: Retry behavior handled by `hyperfleet-broker` library
- **Broker support**: GCP Pub/Sub and RabbitMQ with library-managed retry logic
- **Failure isolation**: Failed events logged but don't stop processing of other resources
- **Error handling**: Log error, record metric, continue to next resource

> **Note**: Specific retry parameters (attempts, timeouts, backoff strategy) are implemented in the external [hyperfleet-broker](https://github.com/openshift-hyperfleet/hyperfleet-broker) library and not configurable at the Sentinel level.

**Configuration Example (GCP Pub/Sub)**:
```yaml
# Via environment variables or ConfigMap
BROKER_TYPE: "pubsub"
BROKER_PROJECT_ID: "hyperfleet-prod"
```

**Metrics**: Publishing failures tracked via `hyperfleet_sentinel_broker_errors_total` metric.

**Operational Impact**: Temporary broker outages don't cause event loss. Events are retried by the broker library, but durability depends on broker availability and Sentinel remaining active.

### Per-Resource Error Isolation

**What**: Failures processing one resource don't affect processing of other resources.

**Implementation**:
- Each resource evaluated independently in the polling loop
- Decision engine errors logged but processing continues
- Event publishing failures logged but don't stop the polling cycle
- API errors for specific resources don't abort the entire fetch operation

**Example Flow**:
```
Polling Cycle:
├── Fetch 100 clusters from API
├── Process cluster-1 → Event published
├── Process cluster-2 → Log error, continue
├── Process cluster-3 → Event published
└── Complete cycle, sleep, repeat
```

**Operational Impact**: Problematic resources (e.g., malformed data) don't prevent reconciliation of healthy resources.

### Functional Health Probes

**What**: Kubernetes readiness and liveness probes that verify actual service functionality.

**Implementation**:

**Liveness Probe** (`/healthz`):
- Verifies main polling goroutine is running
- Checks broker connection status
- Returns 200 OK if service can perform reconciliation
- **Failure threshold**: 3 consecutive failures
- **Period**: 20 seconds

**Readiness Probe** (`/readyz`):
- Verifies configuration loaded successfully
- Validates HyperFleet API connectivity
- Confirms broker configuration is valid
- Returns 200 OK when ready to process traffic
- **Period**: 10 seconds

**Configuration**:
```yaml
livenessProbe:
  httpGet:
    path: /healthz
    port: 8080
  initialDelaySeconds: 15
  periodSeconds: 20
readinessProbe:
  httpGet:
    path: /readyz
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 10
```

**Operational Impact**: Kubernetes automatically restarts unhealthy pods and removes unready pods from service.

### PodDisruptionBudget

**What**: Ensures minimum Sentinel availability during cluster maintenance.

**Configuration for Single-Replica Deployments** (typical topology):
```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: sentinel-pdb
  namespace: hyperfleet-system
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: hyperfleet-sentinel
```

**Operational Impact**:
- **Single replica protection**: `minAvailable: 1` blocks voluntary pod eviction when only 1 replica exists
- **Maintenance blocking**: Node drains will be delayed until Sentinel pods are manually drained or scaled up
- **Multiple Sentinels**: Each Sentinel deployment (per resource selector) can have its own PDB
- **Trade-off**: Maintenance operations may require manual intervention for single-replica Sentinels

> **Note**: Cluster maintenance operations respect Sentinel availability requirements.

---

## Metrics Reference

Sentinel exposes 7 Prometheus metrics on port 9090 at `/metrics` endpoint for comprehensive observability.

### Core Metrics

#### `hyperfleet_sentinel_pending_resources`
- **Type**: Gauge
- **Labels**: `component`, `version`, `resource_selector`, `resource_type`
- **Purpose**: Number of resources requiring reconciliation due to max age expiry or generation changes
- **Use Case**: Monitor reconciliation workload, processing queue depth, and scaling decisions
- **Alert Threshold**: Sustained high values may indicate processing bottlenecks or API issues

#### `hyperfleet_sentinel_events_published_total`
- **Type**: Counter
- **Labels**: `component`, `version`, `resource_selector`, `resource_type`, `reason`
- **Purpose**: Total reconciliation events published to message broker
- **Reason Values**: `generation_mismatch`, `max_age_exceeded`
- **Use Case**: Monitor reconciliation activity and generation-based vs time-based triggers

#### `hyperfleet_sentinel_resources_skipped_total`
- **Type**: Counter
- **Labels**: `component`, `version`, `resource_selector`, `resource_type`, `ready_state`
- **Purpose**: Resources skipped due to max age not expired
- **Ready State Values**: `ready`, `not_ready`
- **Use Case**: Verify max age intervals are working correctly

### Performance Metrics

#### `hyperfleet_sentinel_poll_duration_seconds`
- **Type**: Histogram
- **Labels**: `component`, `version`, `resource_selector`, `resource_type`
- **Buckets**: 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, +Inf (Prometheus default buckets)
- **Purpose**: Time spent in complete polling cycles
- **Use Case**: Performance monitoring and capacity planning

### Error Metrics

#### `hyperfleet_sentinel_api_errors_total`
- **Type**: Counter
- **Labels**: `component`, `version`, `resource_selector`, `resource_type`, `error_type`
- **Purpose**: HyperFleet API call failures
- **Use Case**: Monitor API connectivity and performance issues

#### `hyperfleet_sentinel_broker_errors_total`
- **Type**: Counter
- **Labels**: `component`, `version`, `resource_selector`, `resource_type`, `error_type`
- **Purpose**: Message broker publishing failures
- **Use Case**: Monitor message broker connectivity and publishing issues

### Configuration Metrics

#### `hyperfleet_sentinel_last_successful_poll_timestamp_seconds`
- **Type**: Gauge
- **Labels**: `component`, `version`
- **Purpose**: Unix timestamp of the last successful poll cycle completion (dead man's switch)
- **Use Case**: Monitor if Sentinel polling loop has stopped or is stuck

### Metric Label Standards

All metrics include these standard labels:
- **`component`**: Always `"sentinel"`
- **`version`**: Service version (e.g., `"v1.2.0"`)
- **`resource_selector`**: String representation of label selector (e.g., `"region=us-east"`)
- **`resource_type`**: Resource being watched (e.g., `"clusters"`, `"nodepools"`)

---

## Alert Rules Reference

The following 8 alert rules provide comprehensive monitoring for production Sentinel deployments.

### Critical Alerts

#### SentinelDown
```yaml
alert: SentinelDown
expr: absent(up{service="sentinel"}) or up{service="sentinel"} == 0
for: 5m
labels:
  severity: critical
  component: sentinel
annotations:
  summary: "Sentinel service is down"
  description: "Sentinel metrics endpoint is not responding. Service may be down or unreachable."
```
**Impact**: Resource reconciliation stopped completely.
**Response**: Check pod status, logs, and resource constraints.

#### SentinelAPIErrorRateHigh
```yaml
alert: SentinelAPIErrorRateHigh
expr: rate(hyperfleet_sentinel_api_errors_total[5m]) > 0.1
for: 5m
labels:
  severity: critical
  component: sentinel
annotations:
  summary: "High API error rate in Sentinel"
  description: "Sentinel is experiencing {{ $value }} API errors/sec for resource_type {{ $labels.resource_type }}. Check HyperFleet API availability."
```
**Impact**: Unable to fetch resource status, reconciliation decisions based on stale data.
**Response**: Check HyperFleet API service health and network connectivity.

#### SentinelBrokerErrorRateHigh
```yaml
alert: SentinelBrokerErrorRateHigh
expr: rate(hyperfleet_sentinel_broker_errors_total[5m]) > 0.05
for: 5m
labels:
  severity: critical
  component: sentinel
annotations:
  summary: "High broker error rate in Sentinel"
  description: "Sentinel is experiencing {{ $value }} broker errors/sec for resource_type {{ $labels.resource_type }}. Check message broker connectivity."
```
**Impact**: Events not reaching adapters, reconciliation loops broken.
**Response**: Check message broker health and Sentinel broker configuration.

#### SentinelPollStale
```yaml
alert: SentinelPollStale
expr: |
  hyperfleet_sentinel_last_successful_poll_timestamp_seconds > 0
  and time() - hyperfleet_sentinel_last_successful_poll_timestamp_seconds > 60
for: 1m
labels:
  severity: critical
  component: sentinel
annotations:
  summary: "Sentinel poll loop is stale"
  description: "Sentinel has not completed a successful poll cycle in over 60 seconds. The service may be hung or unable to poll."
```
**Impact**: Complete polling failure, no reconciliation events generated.
**Response**: Check Sentinel logs and restart if necessary.

### Warning Alerts

#### SentinelSlowPolling
```yaml
alert: SentinelSlowPolling
expr: histogram_quantile(0.95, rate(hyperfleet_sentinel_poll_duration_seconds_bucket[5m])) > 5
for: 10m
labels:
  severity: warning
  component: sentinel
annotations:
  summary: "Sentinel polling cycles are slow"
  description: "95th percentile poll duration is {{ $value }}s for {{ $labels.resource_type }}. This may indicate API latency or processing issues."
```
**Impact**: Delayed reconciliation, potentially missing max age intervals.
**Response**: Check resource count growth and API performance.

#### SentinelNoEventsPublished
```yaml
alert: SentinelNoEventsPublished
expr: |
  hyperfleet_sentinel_pending_resources > 0
  unless on(resource_type, resource_selector)
  rate(hyperfleet_sentinel_events_published_total[15m]) > 0
for: 15m
labels:
  severity: warning
  component: sentinel
annotations:
  summary: "Sentinel not publishing events"
  description: "Sentinel has pending resources but hasn't published any events in 15 minutes. Service may be stuck."
```
**Impact**: Resources may be stuck without reconciliation events.
**Response**: Check decision engine logic and adapter status updates.

#### SentinelHighPendingResources
```yaml
alert: SentinelHighPendingResources
expr: sum(hyperfleet_sentinel_pending_resources) > 100
for: 10m
labels:
  severity: warning
  component: sentinel
annotations:
  summary: "High number of pending resources in Sentinel"
  description: "{{ $value }} resources are pending reconciliation for more than 10 minutes. This may indicate processing bottleneck or API issues."
```
**Impact**: May indicate capacity issues or API problems.
**Response**: Check resource count growth and consider horizontal scaling.

### Informational Alerts

#### SentinelHighSkipRatio
```yaml
alert: SentinelHighSkipRatio
expr: |
  (
    rate(hyperfleet_sentinel_resources_skipped_total[10m]) /
    (rate(hyperfleet_sentinel_resources_skipped_total[10m]) +
     rate(hyperfleet_sentinel_events_published_total[10m]))
  ) > 0.95
for: 30m
labels:
  severity: info
  component: sentinel
annotations:
  summary: "High resource skip ratio in Sentinel"
  description: "{{ $value | humanizePercentage }} of resources are being skipped. This may indicate max_age configuration issues."
```
**Impact**: May indicate max age intervals too long or adapter status update issues.
**Response**: Review max age configuration and adapter health.

---

## Operational Guidance

### Resource Requirements

#### Production Recommendations
```yaml
resources:
  requests:
    cpu: 100m      # Baseline for polling every 5s
    memory: 128Mi  # Baseline for ~1000 resources
  limits:
    cpu: 500m      # Handle traffic spikes
    memory: 512Mi  # Memory for large resource sets
```

> **Note**: Resource requirements will be validated and updated based on actual consumption profiling in HYPERFLEET-556.

#### Scaling Guidelines

**CPU Scaling**:
- **Base load**: 50-100m for basic polling
- **Per 1000 resources**: Additional 50m CPU
- **High churn environments**: Additional 100m for frequent events

**Memory Scaling**:
- **Base load**: 64Mi for service overhead
- **Per 1000 resources**: Additional 32Mi memory
- **Complex resource selectors**: Additional 16Mi per selector rule

**Example Calculation**:
```
5000 resources + complex selectors:
CPU: 100m + (5 × 50m) + 100m = 450m
Memory: 64Mi + (5 × 32Mi) + 16Mi = 240Mi
```

### Scaling Strategy

#### Horizontal Scaling (Label Partitioning)

**Approach**: Deploy multiple Sentinel instances with different `resource_selector` configurations.

**Benefits**:
- Linear performance scaling
- Fault isolation (one failure doesn't affect all resources)
- Regional deployment (Sentinel near managed resources)
- Different configurations per environment

**Example Multi-Instance Deployment**:
```
                            ┌───────────────────┐
                            │  HyperFleet API   │
                            └─────────┬─────────┘
                                      │
                              Step 1: fetch resources
                                      │
                                      ▼
┌─────────────────────┐  ┌─────────────────────┐  ┌─────────────────────┐
│   Sentinel US-East  │  │   Sentinel US-West  │  │   Sentinel EU-West  │
│  resource_selector: │  │  resource_selector: │  │  resource_selector: │
│  - label: region    │  │  - label: region    │  │  - label: region    │
│    value: us-east   │  │    value: us-west   │  │    value: eu-west   │
│  max_age_ready=30m  │  │  max_age_ready=1h   │  │  max_age_ready=45m  │
└──────────┬──────────┘  └──────────┬──────────┘  └──────────┬──────────┘
           │                        │                        │
           │                        ▼                        │
           └────────────► Step 2: publish events ◄───────────┘
                                    │
                                    ▼
                            ┌───────────────────┐
                            │  Message Broker   │
                            └───────────────────┘
```

**Important**: This is **NOT leader election**. Multiple Sentinels can overlap resource selectors if needed. Operators must ensure appropriate coverage.

#### Resource Selector Strategies

**Regional Partitioning**:
```yaml
# Sentinel A
resource_selector:
  - label: region
    value: us-east

# Sentinel B
resource_selector:
  - label: region
    value: us-west
```

**Environment Partitioning**:
```yaml
# Production Sentinel
resource_selector:
  - label: environment
    value: production

# Development Sentinel
resource_selector:
  - label: environment
    value: development
```

**Hybrid Partitioning**:
```yaml
# Production US-East
resource_selector:
  - label: region
    value: us-east
  - label: environment
    value: production
```

#### Performance Monitoring

Monitor these metrics to determine scaling needs:

- **`hyperfleet_sentinel_poll_duration_seconds`** → Watch for increasing latency trends
- **`hyperfleet_sentinel_pending_resources`** → Monitor growth over time
- **CPU/Memory usage** → Use `kubectl top pod` to check resource consumption
- **`hyperfleet_sentinel_api_errors_total`** → Monitor API connectivity issues

> **Note**: Specific threshold values are not defined in the implementation. Operators should establish baselines based on their environment and resource scale, then monitor for trends indicating performance degradation or capacity constraints.

### Deployment Configuration

#### Single Instance Deployment

**Use Case**: MVP deployments, small resource counts (<1000), single region

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cluster-sentinel
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cluster-sentinel
  template:
    spec:
      containers:
      - name: sentinel
        image: quay.io/hyperfleet/sentinel:v1.0.0
        args:
        - --config=/etc/sentinel/config.yaml
        env:
        - name: HYPERFLEET_API_TOKEN
          valueFrom:
            secretKeyRef:
              name: sentinel-secrets
              key: api-token
        volumeMounts:
        - name: config
          mountPath: /etc/sentinel
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi
```

#### Multi-Instance Deployment

**Use Case**: Production deployments, multiple regions, >1000 resources

```yaml
# Deploy multiple Sentinel instances with different selectors
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cluster-sentinel-us-east
  labels:
    sentinel.hyperfleet.io/partition: us-east
spec:
  replicas: 1
  template:
    spec:
      containers:
      - name: sentinel
        volumeMounts:
        - name: config
          mountPath: /etc/sentinel
        # Mount us-east specific config
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cluster-sentinel-us-west
  labels:
    sentinel.hyperfleet.io/partition: us-west
spec:
  replicas: 1
  template:
    spec:
      containers:
      - name: sentinel
        volumeMounts:
        - name: config
          mountPath: /etc/sentinel
        # Mount us-west specific config
```

---

## Configuration Examples

### Basic Production Configuration
```yaml
# sentinel-config.yaml
resource_type: clusters
poll_interval: 5s
max_age_not_ready: 10s
max_age_ready: 30m

# Watch all clusters (no filtering)
resource_selector: []

hyperfleet_api:
  endpoint: http://hyperfleet-api.hyperfleet-system.svc.cluster.local:8000
  timeout: 5s

# CloudEvent data payload using CEL expressions
message_data:
  resource_id: "resource.id"        # CEL expression accessing resource.id field
  resource_type: "resource.kind"   # CEL expression accessing resource.kind field
  generation: "resource.generation" # CEL expression accessing resource.generation field
  region: "resource.labels.region" # CEL expression accessing nested labels.region field
```

### Multi-Region Configuration
```yaml
# sentinel-us-east-config.yaml
resource_type: clusters
poll_interval: 5s
max_age_not_ready: 10s
max_age_ready: 30m

resource_selector:
  - label: region
    value: us-east

hyperfleet_api:
  endpoint: http://hyperfleet-api.hyperfleet-system.svc.cluster.local:8000
  timeout: 5s

message_data:
  resource_id: "resource.id"
  resource_type: "resource.kind"
  generation: "resource.generation"
  region: "resource.labels.region"
```

### Development Environment Configuration
```yaml
# sentinel-dev-config.yaml
resource_type: clusters
poll_interval: 10s      # Slower polling for dev
max_age_not_ready: 30s  # Longer intervals for dev
max_age_ready: 2h

resource_selector:
  - label: environment
    value: development

hyperfleet_api:
  endpoint: http://hyperfleet-api.hyperfleet-system.svc.cluster.local:8000
  timeout: 5s

message_data:
  resource_id: "resource.id"
  resource_type: "resource.kind"
  generation: "resource.generation"
  environment: "resource.labels.environment"
```

---

## Related Documentation

- **[Sentinel Architecture](./sentinel.md)**: Core design and implementation approach
- **[Sentinel Deployment](./sentinel-deployment.md)**: Kubernetes manifests and deployment options
- **[Sentinel Naming Strategy](./sentinel-naming-strategy.md)**: Topic naming and multi-tenant isolation
- **[HyperFleet Status Guide](../../docs/status-guide.md)**: Adapter status contract and generation semantics
- **[Metrics Standard](../../standards/metrics.md)**: Cross-component metrics conventions
- **[Health Endpoints Specification](../../standards/health-endpoints.md)**: Health and readiness probe standards
- **[Graceful Shutdown Standard](../../standards/graceful-shutdown.md)**: Service termination requirements