---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-07-13
---

# HyperFleet Observability Reference

Consolidated reference for metrics and monitoring across HyperFleet's deployable components.

---

## Table of Contents

- [Overview](#overview)
- [Component Metrics and Health Endpoints](#component-metrics-and-health-endpoints)
- [References](#references)

---

## Overview

HyperFleet components expose Prometheus-compatible metrics for monitoring and observability. All metrics follow the [HyperFleet Metrics Standard](../standards/metrics.md) for consistent naming and labeling.

**Key Points:**

- All components expose metrics on **port 9090** at `/metrics` endpoint
- Metrics follow the `hyperfleet_<component>_<metric_name>_<unit>` naming convention
- All metrics include standard labels: `component` and `version`
- Individual component repositories contain detailed metric definitions

---

## Component Metrics and Health Endpoints

HyperFleet's deployable components expose:

- **Metrics** on port **9090** at `/metrics`
- **Health status** on port **8080** at `/healthz` (liveness) and `/readyz` (readiness)

| Component | Repository | Metrics Endpoint | Health Endpoints | Metrics Docs | Architecture Doc |
|-----------|------------|------------------|------------------|--------------|------------------|
| **API** | [hyperfleet-api](https://github.com/openshift-hyperfleet/hyperfleet-api) | `:9090/metrics` | `:8080/healthz`, `:8080/readyz` | [docs/metrics.md](https://github.com/openshift-hyperfleet/hyperfleet-api/blob/main/docs/metrics.md) | [api-service.md](../components/api-service/api-service.md) |
| **Sentinel** | [hyperfleet-sentinel](https://github.com/openshift-hyperfleet/hyperfleet-sentinel) | `:9090/metrics` | `:8080/healthz`, `:8080/readyz` | [docs/metrics.md](https://github.com/openshift-hyperfleet/hyperfleet-sentinel/blob/main/docs/metrics.md) | [sentinel.md](../components/sentinel/sentinel.md) |
| **Adapter Framework** | [hyperfleet-adapter](https://github.com/openshift-hyperfleet/hyperfleet-adapter) | `:9090/metrics` | `:8080/healthz`, `:8080/readyz` | [docs/metrics.md](https://github.com/openshift-hyperfleet/hyperfleet-adapter/blob/main/docs/metrics.md) | [adapter-deployment.md](../components/adapter/framework/adapter-deployment.md) |

**Notes:**

- Components expose separate listener ports: `:9090` for metrics, `:8080` for health checks
- The API service also exposes REST endpoints on port `:8000`
- **Broker**: `hyperfleet-broker` is an embedded library ([broker.md](../components/broker/broker.md)), not a standalone service — it does not expose its own endpoints. Broker metrics and health checks are surfaced through embedding components (Sentinel and Adapter)

---

## References

- [Metrics Standard](../standards/metrics.md) — Naming conventions, required labels, best practices
- [Health Endpoints Standard](../standards/health-endpoints.md) — Health check conventions
- [Logging Specification](../standards/logging-specification.md) — Structured logging format
- [Tracing Standard](../standards/tracing.md) — Distributed tracing conventions
