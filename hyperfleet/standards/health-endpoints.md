---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-03-20
---

# HyperFleet Health and Readiness Endpoint Standard


## Overview

This document defines the standard contract for health and readiness endpoints across all HyperFleet components (API, Sentinel, Adapters).


### Goals

- **Consistency**: All components expose the same endpoints on the same ports
- **Kubernetes Integration**: Proper liveness and readiness probe configuration
- **Observability**: Metrics endpoint for Prometheus scraping

---

## Port and Endpoint Configuration

All HyperFleet components MUST use the following configuration:

| Port   | Endpoint   | Purpose                             | Probe Type       |
| ------ | ---------- | ----------------------------------- | ---------------- |
| `8080` | `/healthz` | Liveness - is the process alive?    | `livenessProbe`  |
| `8080` | `/readyz`  | Readiness - can it receive traffic? Can a rolling update proceed? | `readinessProbe` |
| `9090` | `/metrics` | Prometheus metrics                  | ServiceMonitor   |

---

## Endpoint Specification

### `/healthz` - Liveness Probe

**Purpose**: Indicates whether the application is running.

| Status                    | Meaning                  | Kubernetes Action |
| ------------------------- | ------------------------ | ----------------- |
| `200 OK`                  | Application is alive     | None              |
| `503 Service Unavailable` | Application is unhealthy | Restart pod       |

**Response Body**:

```json
{ "status": "ok" }
```

Or on failure:

```json
{ "status": "error", "message": "out of memory" }
```

**What to Check**:

- Application can respond to HTTP requests (implicitly verified by the probe itself)
- No fatal internal state (e.g., unrecoverable panic, deadlock)

**What NOT to Check**:

- External dependencies (database, API, broker)
- Downstream service availability

**Rationale**: Liveness probes should only verify the process itself is healthy. Checking external dependencies can cause cascading restarts during infrastructure issues. If a dependency is down, the pod should remain running but marked as not ready (via `/readyz`).

---

### `/readyz` - Readiness Probe

**Purpose**: 
 - Indicates whether the application is ready to receive traffic.
 - Controls replacement and concurrency during rollout

| Status                    | Meaning                  | Kubernetes Action             |
| ------------------------- | ------------------------ | ----------------------------- |
| `200 OK`                  | Ready to receive traffic, perform rolling update | Add to service endpoints      |
| `503 Service Unavailable` | Not ready                | Remove from service endpoints |

For services that do not serve traffic, the readyz probe does not affect the pods serving behind a service but have effect during a rolling update

- A Pod that is NotReady:
  - counts as Unavailable
  - blocks Kubernetes from terminating old Pods (depending on maxUnavailable)

- A Pod that becomes Ready:
  - is considered a valid replacement
  - allows Kubernetes to scale down old consumers

➡️ Readiness controls when Kubernetes is allowed to reduce old consumers.


**Response Body**:

```json
{
  "status": "ok",
  "checks": {
    "config": "ok",
    "broker": "ok",
    "api": "ok"
  }
}
```

Or on failure:

```json
{
  "status": "error",
  "checks": {
    "config": "ok",
    "broker": "error",
    "api": "ok"
  },
  "message": "broker connection failed"
}
```

**What to Check**:

- Configuration loaded successfully
- Required connections established (broker, API client)
- Startup initialization complete

**Component-Specific Checks**:

| Component | Readiness Checks                                                           |
| --------- | -------------------------------------------------------------------------- |
| API       | Database connection, configuration loaded                                  |
| Sentinel  | HyperFleet API reachable, broker connected, configuration loaded           |
| Adapters  | Broker subscription active, HyperFleet API reachable, configuration loaded |

---

### `/metrics` - Prometheus Metrics

**Purpose**: Expose application metrics for Prometheus scraping.

**Response**: Prometheus text format (OpenMetrics compatible)

**Required Metrics**: See component-specific documentation:

- [Sentinel Operator Guide](https://github.com/openshift-hyperfleet/hyperfleet-sentinel/blob/main/docs/sentinel-operator-guide.md) - Sentinel metrics
- [Adapter Metrics](../components/adapter/framework/adapter-metrics.md) - Adapter metrics

---

## Kubernetes Probe Configuration

### Probe Timing

| Probe     | initialDelaySeconds | periodSeconds | timeoutSeconds | failureThreshold |
| --------- | ------------------- | ------------- | -------------- | ---------------- |
| Liveness  | 15                  | 20            | 5              | 3                |
| Readiness | 5                   | 10            | 3              | 3                |

### Helm Values Template

```yaml
observability:
  healthPort: 8080
  metricsPort: 9090
  probes:
    liveness:
      path: /healthz
      initialDelaySeconds: 15
      periodSeconds: 20
      timeoutSeconds: 5
      failureThreshold: 3
    readiness:
      path: /readyz
      initialDelaySeconds: 5
      periodSeconds: 10
      timeoutSeconds: 3
      failureThreshold: 3
```

### Deployment Probe Template

```yaml
terminationGracePeriodSeconds: 30
livenessProbe:
  httpGet:
    path: /healthz
    port: 8080
  initialDelaySeconds: 15
  periodSeconds: 20
  timeoutSeconds: 5
  failureThreshold: 3
readinessProbe:
  httpGet:
    path: /readyz
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 10
  timeoutSeconds: 3
  failureThreshold: 3
```

---

## Graceful Degradation

### Startup Behavior

1. Start HTTP servers for health and metrics endpoints immediately
2. `/healthz` returns `200 OK` as soon as the process starts
3. `/readyz` returns `503 Service Unavailable` until initialization completes
4. Once all readiness checks pass, `/readyz` returns `200 OK`

### Shutdown Behavior

1. On `SIGTERM`, set `/readyz` to return `503 Service Unavailable`
2. Kubernetes removes pod from Service endpoints
3. Graceful shutdown completes in-flight work
4. Exit cleanly

For complete shutdown specifications, timeout configuration, and code examples, see [Graceful Shutdown Standard](./graceful-shutdown.md).

---

## References

- [Kubernetes Liveness and Readiness Probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)
- [Prometheus Exposition Formats](https://prometheus.io/docs/instrumenting/exposition_formats/)
- [HyperFleet Graceful Shutdown Standard](./graceful-shutdown.md)
- [HyperFleet Logging Specification](./logging-specification.md)
