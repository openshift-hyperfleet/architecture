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
- Maximum shutdown time: 30 seconds (configured via `terminationGracePeriodSeconds`)
- Publishes any pending events before shutdown
- Cleans up broker connections gracefully

**Configuration**:
```yaml
spec:
  template:
    spec:
      terminationGracePeriodSeconds: 30
```

**Operational Impact**: Zero event loss during rolling deployments or pod eviction.

### API Retry Logic

**What**: Automatic retry with exponential backoff for HyperFleet API calls.

**Implementation**:
- **Initial timeout**: 10 seconds per API call (configurable via `hyperfleet_api.timeout`)
- **Retry strategy**: Exponential backoff starting at 1 second
- **Maximum retries**: 3 attempts per polling cycle
- **Failure handling**: Logs error and continues to next polling cycle (doesn't crash)

**Configuration**:
```yaml
hyperfleet_api:
  endpoint: http://hyperfleet-api.hyperfleet-system.svc.cluster.local:8080
  timeout: 10s
```

**Metrics**: Failed API calls tracked via `hyperfleet_sentinel_api_errors_total` metric.

**Operational Impact**: Transient API issues don't stop reconciliation. Service continues polling after API recovery.

### Broker Publish Retry

**What**: Automatic retry for message broker publishing failures.

**Implementation**:
- **Retry strategy**: Exponential backoff with jitter
- **Maximum retries**: 5 attempts per event
- **Timeout**: 30 seconds per publish attempt
- **Failure isolation**: Failed events logged but don't stop processing of other resources
- **Broker support**: GCP Pub/Sub and RabbitMQ with identical retry behavior

**Configuration Example (GCP Pub/Sub)**:
```yaml
# Via environment variables or ConfigMap
BROKER_TYPE: "pubsub"
BROKER_PROJECT_ID: "hyperfleet-prod"
```

**Metrics**: Publishing failures tracked via `hyperfleet_sentinel_broker_errors_total` metric.

**Operational Impact**: Temporary broker outages don't cause event loss. Events are retried until broker recovers.

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

**Recommended Configuration**:
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
- **Single replica per resource selector**: Each Sentinel deployment typically runs 1 replica
- **Multiple Sentinels**: Different resource selectors allow multiple Sentinel deployments
- **Maintenance protection**: PDB prevents voluntary pod eviction during node drains

**Operational Impact**: Cluster maintenance operations respect Sentinel availability requirements.

---

## Metrics Reference

Sentinel exposes 7 Prometheus metrics on port 9090 at `/metrics` endpoint for comprehensive observability.

### Core Metrics

#### `hyperfleet_sentinel_pending_resources`
- **Type**: Gauge
- **Labels**: `component`, `version`, `resource_selector`, `resource_type`
- **Purpose**: Current number of resources matching this Sentinel's selector
- **Use Case**: Capacity planning and load distribution across Sentinel instances
- **Alert Threshold**: Sudden drops may indicate API issues or configuration changes

#### `hyperfleet_sentinel_events_published_total`
- **Type**: Counter
- **Labels**: `component`, `version`, `resource_selector`, `resource_type`, `reason`
- **Purpose**: Total reconciliation events published to message broker
- **Reason Values**: `generation_changed`, `max_age_expired`
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
- **Buckets**: 0.5s, 1s, 2.5s, 5s, 10s, 25s, 60s
- **Purpose**: Time spent in complete polling cycles
- **Use Case**: Performance monitoring and capacity planning

### Error Metrics

#### `hyperfleet_sentinel_api_errors_total`
- **Type**: Counter
- **Labels**: `component`, `version`, `resource_selector`, `resource_type`, `operation`
- **Purpose**: HyperFleet API call failures
- **Operation Values**: `fetch_resources`, `config_validation`
- **Use Case**: Monitor API connectivity and performance issues

#### `hyperfleet_sentinel_broker_errors_total`
- **Type**: Counter
- **Labels**: `component`, `version`, `resource_selector`, `resource_type`, `broker_type`
- **Purpose**: Message broker publishing failures
- **Broker Type Values**: `pubsub`, `rabbitmq`
- **Use Case**: Monitor message broker connectivity and publishing issues

### Configuration Metrics

#### `hyperfleet_sentinel_config_loads_total`
- **Type**: Counter
- **Labels**: `component`, `version`, `resource_selector`, `resource_type`, `status`
- **Purpose**: Configuration load attempts at startup
- **Status Values**: `success`, `failed`
- **Use Case**: Verify configuration changes and troubleshoot startup issues

### Metric Label Standards

All metrics include these standard labels:
- **`component`**: Always `"hyperfleet-sentinel"`
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
expr: up{job="hyperfleet-sentinel"} == 0
for: 1m
labels:
  severity: critical
annotations:
  summary: "Sentinel instance {{ $labels.instance }} is down"
  description: "Hyperfleet Sentinel instance has been down for more than 1 minute"
```
**Impact**: Resource reconciliation stopped for affected resource selector.
**Response**: Check pod status, logs, and resource constraints.

#### SentinelAPIErrors
```yaml
alert: SentinelAPIErrors
expr: rate(hyperfleet_sentinel_api_errors_total[5m]) > 0.1
for: 2m
labels:
  severity: critical
annotations:
  summary: "High API error rate in Sentinel"
  description: "Sentinel is experiencing {{ $value }} API errors per second"
```
**Impact**: Unable to fetch resource status, reconciliation decisions based on stale data.
**Response**: Check HyperFleet API service health and network connectivity.

#### SentinelBrokerErrors
```yaml
alert: SentinelBrokerErrors
expr: rate(hyperfleet_sentinel_broker_errors_total[5m]) > 0.05
for: 3m
labels:
  severity: critical
annotations:
  summary: "High broker error rate in Sentinel"
  description: "Sentinel is experiencing {{ $value }} broker errors per second"
```
**Impact**: Events not reaching adapters, reconciliation loops broken.
**Response**: Check message broker health and Sentinel broker configuration.

### Warning Alerts

#### SentinelHighPollDuration
```yaml
alert: SentinelHighPollDuration
expr: histogram_quantile(0.95, rate(hyperfleet_sentinel_poll_duration_seconds_bucket[5m])) > 30
for: 5m
labels:
  severity: warning
annotations:
  summary: "Sentinel polling cycles taking too long"
  description: "95th percentile polling duration is {{ $value }}s"
```
**Impact**: Delayed reconciliation, potentially missing max age intervals.
**Response**: Check resource count growth and API performance.

#### SentinelNoEventsPublished
```yaml
alert: SentinelNoEventsPublished
expr: increase(hyperfleet_sentinel_events_published_total[10m]) == 0 and hyperfleet_sentinel_pending_resources > 0
for: 10m
labels:
  severity: warning
annotations:
  summary: "Sentinel not publishing events despite pending resources"
  description: "No events published in 10 minutes but {{ $value }} resources pending"
```
**Impact**: Resources may be stuck without reconciliation events.
**Response**: Check decision engine logic and adapter status updates.

#### SentinelHighResourceSkip
```yaml
alert: SentinelHighResourceSkip
expr: rate(hyperfleet_sentinel_resources_skipped_total[5m]) / rate(hyperfleet_sentinel_pending_resources[5m]) > 0.9
for: 5m
labels:
  severity: warning
annotations:
  summary: "High percentage of resources skipped"
  description: "{{ $value | humanizePercentage }} of resources skipped in last 5 minutes"
```
**Impact**: May indicate max age intervals too long or adapter status update issues.
**Response**: Review max age configuration and adapter health.

### Informational Alerts

#### SentinelConfigReload
```yaml
alert: SentinelConfigReload
expr: increase(hyperfleet_sentinel_config_loads_total{status="failed"}[5m]) > 0
for: 0s
labels:
  severity: info
annotations:
  summary: "Sentinel configuration reload failed"
  description: "{{ $value }} config load failures in last 5 minutes"
```
**Impact**: Service may be running with outdated configuration.
**Response**: Check ConfigMap validity and pod restart logs.

#### SentinelResourceGrowth
```yaml
alert: SentinelResourceGrowth
expr: increase(hyperfleet_sentinel_pending_resources[1h]) > 100
for: 0s
labels:
  severity: info
annotations:
  summary: "Rapid resource growth detected"
  description: "Resource count increased by {{ $value }} in last hour"
```
**Impact**: May need capacity planning or additional Sentinel instances.
**Response**: Monitor performance impact and consider scaling strategies.

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
│  selector:          │  │  selector:          │  │  selector:          │
│  region=us-east     │  │  region=us-west     │  │  region=eu-west     │
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

- **`hyperfleet_sentinel_poll_duration_seconds`** > 30s → Scale horizontally
- **`hyperfleet_sentinel_pending_resources`** > 5000 → Consider partitioning
- **CPU utilization** > 70% → Increase resource requests
- **Memory utilization** > 80% → Increase memory limits

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

### Troubleshooting

#### Common Issues and Resolution

**Issue**: Sentinel not publishing events
```bash
# Check metrics
kubectl port-forward svc/sentinel-metrics 9090:9090
curl http://localhost:9090/metrics | grep events_published

# Check decision engine logs
kubectl logs -l app=cluster-sentinel | grep "decision"

# Verify adapter status updates
kubectl logs -l app=cluster-sentinel | grep "last_updated_time"
```

**Resolution**:
- Verify adapters are updating `observed_time` on every check
- Check max age configuration values
- Confirm generation/observed_generation logic

**Issue**: High API error rate
```bash
# Check API connectivity
kubectl exec -it deploy/cluster-sentinel -- wget -qO- http://hyperfleet-api:8080/health

# Check API token
kubectl get secret sentinel-secrets -o yaml

# Review API error details
kubectl logs -l app=cluster-sentinel | grep "api_error"
```

**Resolution**:
- Verify HyperFleet API service health
- Check API token validity and permissions
- Review network policies and service mesh configuration

**Issue**: High polling duration
```bash
# Check resource count
kubectl logs -l app=cluster-sentinel | grep "pending_resources"

# Check API response times
kubectl logs -l app=cluster-sentinel | grep "api_duration"

# Monitor memory usage
kubectl top pod -l app=cluster-sentinel
```

**Resolution**:
- Consider horizontal scaling if >5000 resources
- Increase CPU/memory resources
- Implement resource selector partitioning

**Issue**: Broker publishing failures
```bash
# Check broker configuration
kubectl get configmap hyperfleet-sentinel-broker -o yaml

# Test broker connectivity
kubectl exec -it deploy/cluster-sentinel -- nslookup rabbitmq.hyperfleet-system.svc.cluster.local

# Review broker credentials
kubectl get secret sentinel-secrets -o yaml
```

**Resolution**:
- Verify broker service health (Pub/Sub, RabbitMQ)
- Check broker credentials and permissions
- Review broker configuration syntax

#### Debug Commands

**View current configuration**:
```bash
kubectl exec -it deploy/cluster-sentinel -- cat /etc/sentinel/config.yaml
```

**Check health endpoints**:
```bash
kubectl exec -it deploy/cluster-sentinel -- wget -qO- http://localhost:8080/healthz
kubectl exec -it deploy/cluster-sentinel -- wget -qO- http://localhost:8080/readyz
```

**Monitor polling cycles**:
```bash
kubectl logs -f -l app=cluster-sentinel | grep -E "(polling_cycle|decision_made|event_published)"
```

**Resource selector validation**:
```bash
# Verify resource selector matches expected resources
kubectl logs -l app=cluster-sentinel | grep "resource_selector"
kubectl logs -l app=cluster-sentinel | grep "fetched.*resources"
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
  endpoint: http://hyperfleet-api.hyperfleet-system.svc.cluster.local:8080
  timeout: 10s

message_data:
  resource_id: .id
  resource_type: .kind
  generation: .generation
  region: .metadata.labels.region
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
  endpoint: http://hyperfleet-api.hyperfleet-system.svc.cluster.local:8080
  timeout: 10s

message_data:
  resource_id: .id
  resource_type: .kind
  generation: .generation
  region: .metadata.labels.region
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
  endpoint: http://hyperfleet-api.hyperfleet-system.svc.cluster.local:8080
  timeout: 30s

message_data:
  resource_id: .id
  resource_type: .kind
  generation: .generation
  environment: .metadata.labels.environment
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