---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-01-28
---

# HyperFleet Logging Specification

## Overview

This document defines the standard logging approach for all HyperFleet components (API, Sentinel, Adapters).


### Goals

- **Consistency**: All components configure logging the same way
- **Traceability**: Distributed tracing via `trace_id` and correlation fields
- **Observability**: Structured logs that integrate with log aggregation systems

### Non-Goals

- Creating a shared logging library
- Mandating a specific logging framework

### Shared Libraries

Shared libraries (e.g., broker client) MUST inherit the logging context from the calling component:

- When Sentinel publishes to the broker → logs include `component=sentinel`
- When an Adapter subscribes from the broker → logs include `component=adapter-validation`

The shared library should not set its own `component` value - it uses the context provided by the caller.

**Example:**

```go
// ✅ DO: Caller creates logger with context and passes it to the library
logger := slog.With("component", "sentinel", "subset", "clusters")
broker.Publish(ctx, event, broker.WithLogger(logger))

// ✅ DO: Shared library uses the passed logger (preserves caller context)
func (b *Broker) Publish(ctx context.Context, event Event, opts ...Option) {
    cfg := applyOptions(opts)
    cfg.Logger.Info("publishing event", "topic", b.topic)
}

// ❌ DON'T: Shared library creating its own logger loses caller context
func (b *Broker) Publish(ctx context.Context, event Event) {
    logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
    logger.Info("publishing event") // Missing component, subset, trace_id, etc.
}
```

---

## Configuration

All components MUST support configuration via **command-line flags** and **environment variables**. Configuration files are optional.

| Option | Flag | Environment Variable | Default | Description |
|--------|------|---------------------|---------|-------------|
| Log Level | `--log-level` | `HYPERFLEET_LOG_LEVEL` | `info` | Minimum level: `debug`, `info`, `warn`, `error` |
| Log Format | `--log-format` | `HYPERFLEET_LOG_FORMAT` | `text` | Output format: `text` or `json` |
| Log Output | `--log-output` | `HYPERFLEET_LOG_OUTPUT` | `stdout` | Destination: `stdout` or `stderr` |

**Precedence** (highest to lowest): flags → environment variables → config file → defaults

For production, use `LOG_FORMAT=json` for better log aggregation.

---

## Log Levels

Ordered by severity (lowest to highest):

| Level | Description | Examples |
|-------|-------------|----------|
| `debug` | Detailed debugging | Variable values, event payloads |
| `info` | Operational information | Startup, successful operations |
| `warn` | Warning conditions | Retry attempts, slow operations |
| `error` | Error conditions | Failures, invalid configuration |

When `LOG_LEVEL` is set, only messages at that level or higher are output.

---

## Log Fields

### Required Fields

All log entries MUST include:

| Field | Type | Description |
|-------|------|-------------|
| `timestamp` | RFC3339 | When created (UTC) |
| `level` | string | Log level |
| `message` | string | Human-readable message |
| `component` | string | Component name (`api`, `sentinel`, `adapter-validation`) |
| `version` | string | Component version |
| `hostname` | string | Pod name or hostname |

### Correlation Fields

Include when available for distributed tracing:

| Field | Scope | Description |
|-------|-------|-------------|
| `trace_id` | Distributed | OpenTelemetry trace ID (propagated across services) |
| `span_id` | Distributed | Current span identifier |
| `request_id` | Single service | HTTP request identifier (API only) |
| `event_id` | Adapters | CloudEvents ID (from received event) |

### Resource Fields

Include when the log entry relates to a HyperFleet resource:

| Field | Description |
|-------|-------------|
| `cluster_id` | Cluster identifier |
| `resource_type` | Resource type (`clusters`, `nodepools`) |
| `resource_id` | Resource identifier |

> **Note:** For Cluster resources, `cluster_id` is sufficient. For child resources (e.g., NodePools), include `resource_type` and `resource_id` to identify the specific resource.

### Error Fields

Include when logging errors:

| Field | Type | Description |
|-------|------|-------------|
| `error` | string | Error message |
| `stack_trace` | array | Stack trace (only for unexpected errors or debug level) |
| `request_context` | object | Relevant request/payload data for debugging (sensitive data MUST be masked) |

> **Note:** When logging errors, include enough context to investigate incidents without needing to reproduce the issue. Always mask sensitive data per the Sensitive Data section.

---

## Log Formats

### Text Format (Default)

For local development:

```text
{timestamp} {LEVEL} [{component}] [{version}] [{hostname}] {message} {key=value}...
```

```text
2025-01-15T10:30:00.123Z INFO  [sentinel] [v1.2.3] [sentinel-7d4b8c6f5] Publishing event subset=clusters cluster_id=cls-123
2025-01-15T10:30:05.456Z ERROR [sentinel] [v1.2.3] [sentinel-7d4b8c6f5] Failed to publish subset=clusters error="connection refused"
2025-01-15T10:30:05.456Z ERROR [sentinel] [v1.2.3] [sentinel-7d4b8c6f5] Unexpected error subset=clusters error="nil pointer"
    main.processCluster() processor.go:89
    main.reconcileLoop() loop.go:45
```

### JSON Format (Production)

For log aggregation:

```json
{
  "timestamp": "2025-01-15T10:30:00.123Z",
  "level": "info",
  "message": "Publishing event",
  "component": "sentinel",
  "version": "v1.2.3",
  "hostname": "sentinel-7d4b8c6f5",
  "subset": "clusters",
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
  "cluster_id": "cls-123"
}
```

**Error with stack trace and request context:**

```json
{
  "timestamp": "2025-01-15T10:30:05.456Z",
  "level": "error",
  "message": "Unexpected error",
  "component": "sentinel",
  "version": "v1.2.3",
  "hostname": "sentinel-7d4b8c6f5",
  "subset": "clusters",
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
  "cluster_id": "cls-123",
  "error": "nil pointer dereference",
  "stack_trace": [
    "main.processCluster() processor.go:89",
    "main.reconcileLoop() loop.go:45"
  ],
  "request_context": {
    "resource_generation": 5,
    "last_observed_generation": 4
  }
}
```

---

## Component Guidelines

Additional fields per component:

### API

| Field | Description |
|-------|-------------|
| `method` | HTTP method |
| `path` | Request path |
| `status_code` | Response status |
| `duration_ms` | Request duration |
| `user_agent` | Client user agent |

### Sentinel

| Field | Description |
|-------|-------------|
| `decision_reason` | Why event was published (`generation_mismatch`, `max_age_expired`) |
| `topic` | Pub/Sub topic name |
| `subset` | Resource subset identifier (e.g., `clusters`, `nodepools`) |

> **Note:** Use `component=sentinel` with `subset` to identify specific instances. This allows filtering all Sentinels (`WHERE component='sentinel'`) or a specific subset (`WHERE component='sentinel' AND subset='clusters'`).

### Adapters

| Field | Description |
|-------|-------------|
| `adapter` | Adapter type name |
| `job_result` | Outcome (`success`, `failed`, `skipped`) |
| `observed_generation` | Resource generation processed |
| `subscription` | Pub/Sub subscription name |

---

## Distributed Tracing

Components MUST propagate OpenTelemetry trace context:

1. **Incoming**: Extract `trace_id`/`span_id` from W3C headers (`traceparent`)
2. **Outgoing**: Inject trace headers when calling other services
3. **Events**: Include `trace_id` in CloudEvents
4. **Logs**: Always include `trace_id` when available

This enables log correlation across: API → Sentinel → Broker → Adapters

---

## Sensitive Data

The following MUST be redacted or omitted:

- API tokens and credentials
- Passwords and secrets
- Cloud provider access keys
- Personal identifiable information (PII)

---

## Log Size Guidelines

To prevent truncation by log aggregators and control storage costs:

| Element | Recommendation |
|---------|----------------|
| Message | Keep under 1 KB |
| Stack trace | Limit to 10-15 frames |
| Total entry | Keep under 64 KB |

**Best practices:**

- Log resource IDs, not full payloads (use `cluster_id`, not the entire spec)
- Truncate long strings with `...` indicator
- For debugging, log full payloads at `debug` level only
- Avoid logging large binary data or base64-encoded content

> **Note:** Most log aggregation platforms (Cloud Logging, CloudWatch, Splunk) have limits between 64 KB and 256 KB per entry. Keeping entries under 64 KB ensures compatibility across platforms.

---

## References

- [HyperFleet Tracing Standard](./tracing.md)
- [HyperFleet Metrics Standard](./metrics.md)
- [HyperFleet Health Endpoints](./health-endpoints.md)
