---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-10-27
---

# HyperFleet Logging Specification

## Overview

This document defines the standard logging approach for all HyperFleet Go components and shared libraries. Go code logs through `log/slog` with the [`hyperfleet-logger`](https://github.com/openshift-hyperfleet/hyperfleet-logger) handler.

### Goals

- **Consistency**: All components configure logging the same way
- **Traceability**: Distributed tracing via `trace_id` and correlation fields
- **Observability**: Structured logs that integrate with log aggregation systems

---

## Configuration

All components MUST support configuration via **command-line flags** and **environment variables**. Configuration files are optional.

| Option | Flag | Environment Variable | Default | Description |
|--------|------|---------------------|---------|-------------|
| Log Level | `--log-level` | `HYPERFLEET_LOG_LEVEL` | `info` | Minimum level: `debug`, `info`, `warn`, `error` |
| Log Format | `--log-format` | `HYPERFLEET_LOG_FORMAT` | `json` | Output format: `text` or `json` |
| Log Output | `--log-output` | `HYPERFLEET_LOG_OUTPUT` | `stdout` | Destination: `stdout` or `stderr` |

These flag and environment variable names are the standard. A component that reads other names MUST move to these names. While it moves, it MAY also read the old names as a deprecated fallback.

**Precedence** (highest to lowest): flags → environment variables → config file → defaults

For production, use `HYPERFLEET_LOG_FORMAT=json` for better log aggregation.

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
| `stack_trace` | array | Stack trace. Added by the `hfl.WithStackTrace` filter, for the `error` records the component selects (see [Error logging](#error-logging)) |
| `request_context` | object | Relevant request/payload data for debugging (sensitive data MUST be masked) |

> **Note:** When logging errors, include enough context to investigate incidents without needing to reproduce the issue. Always mask sensitive data per the Sensitive Data section.

---

## Log Formats

### Text Format

For local development:

```text
{timestamp} {LEVEL} [{component}] [{version}] [{hostname}] {message} {key=value}...
```

```text
2025-01-15T10:30:00.123Z INFO  [sentinel] [v1.2.3] [sentinel-7d4b8c6f5] publishing event subset=clusters cluster_id=cls-123
2025-01-15T10:30:05.456Z ERROR [sentinel] [v1.2.3] [sentinel-7d4b8c6f5] failed to publish subset=clusters error="connection refused"
2025-01-15T10:30:05.456Z ERROR [sentinel] [v1.2.3] [sentinel-7d4b8c6f5] unexpected error subset=clusters error="nil pointer"
    main.processCluster() processor.go:89
    main.reconcileLoop() loop.go:45
```

### JSON Format (Production, Default)

For log aggregation:

```json
{
  "timestamp": "2025-01-15T10:30:00.123Z",
  "level": "info",
  "message": "publishing event",
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
  "message": "unexpected error",
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

## Go Implementation

The `hyperfleet-logger` handler (`hfl` in the examples) adds `component`, `version`, `hostname` and the context fields to each record. It writes the [text and JSON formats](#log-formats). The [README](https://github.com/openshift-hyperfleet/hyperfleet-logger/blob/main/README.md) lists all options.

Log messages MUST start with a lowercase letter, except a proper noun or identifier (`HyperFleet`, `RabbitMQ`).

### Logging library

Components MUST log through the package-level `slog.*Context` functions. Components MUST NOT use a logger wrapper or interface, `fmt` or the `log` package for runtime logs.

```go
import (
    "context"
    "log/slog"
)

// ✅ DO: log through slog with the context you received
func publish(ctx context.Context, clusterID string) {
    slog.InfoContext(ctx, "publishing event", "cluster_id", clusterID)
}
```

### Handler setup

Each process MUST make its handler one time at startup with `hfl.NewHandler(component, version, opts...)` and install it with `slog.SetDefault`. Use `hfl.ParseLevel`, `hfl.ParseFormat` and `hfl.ParseOutput` for the configuration values. Application code MUST NOT make other handlers. A process MAY wrap the handler to add a field (the E2E suite adds `test_case`).

```go
import (
    "context"
    "io"
    "log/slog"

    hfl "github.com/openshift-hyperfleet/hyperfleet-logger"

    "example.com/component/internal/logctx" // the component's own logctx package
)

const component = "adapter-validation"

var version = "0.0.0-dev" // set at build time with -ldflags

// ✅ DO: build the handler once, install it as the default
func initLogging(level slog.Level, format hfl.Format, output io.Writer) {
    handler := hfl.NewHandler(component, version,
        hfl.WithLevel(level),
        hfl.WithFormat(format),
        hfl.WithOutput(output),
        hfl.WithContextFields(logctx.ContextFields()...),
        hfl.WithStackTrace(func(_ context.Context, r slog.Record) bool {
            return r.Level >= slog.LevelError
        }),
    )
    slog.SetDefault(slog.New(handler))
}
```

### Context propagation

Give the received `ctx` to each `slog.*Context` call and each function call. Code MUST NOT use `slog.Info`, `slog.Warn` or `slog.Error`, because they ignore `ctx`. On a request or event path, code MUST NOT replace `ctx` with `context.Background()`. In a loop, make a child context for each item.

```go
import (
    "context"
    "log/slog"

    hfl "github.com/openshift-hyperfleet/hyperfleet-logger"
)

// ✅ DO: derive a child context for each item
func reconcileAll(ctx context.Context, clusterIDs []string) {
    for _, id := range clusterIDs {
        itemCtx := hfl.WithResourceType(ctx, "clusters")
        itemCtx = hfl.WithResourceID(itemCtx, id)
        slog.InfoContext(itemCtx, "reconciling cluster")
    }
}

// ❌ DON'T: replace the received context (slog.Info without a context has the same effect)
func reconcileDetached(ctx context.Context, id string) {
    detached := context.Background()
    slog.InfoContext(detached, "reconciling cluster", "cluster_id", id) // trace_id and span_id are lost
}
```

### Component-specific fields

A field that all records in a call chain need is a typed context key. Declare it with `hfl.NewKey` in the component's `internal/logctx` package. Return the keys from `ContextFields()` and give them to `hfl.WithContextFields` at [handler setup](#handler-setup). Use `hfl.StringField` for a string key and `hfl.FieldFromKey` for other types.

```go
package logctx

import (
    "log/slog"

    hfl "github.com/openshift-hyperfleet/hyperfleet-logger"
)

var (
    EventIDKey            = hfl.NewKey[string]("event_id")
    ObservedGenerationKey = hfl.NewKey[int]("observed_generation")
)

func ContextFields() []hfl.ContextField {
    return []hfl.ContextField{
        hfl.StringField(EventIDKey),
        hfl.FieldFromKey(ObservedGenerationKey, slog.IntValue),
    }
}
```

Set the key with `hfl.Set` when the value is known. All records that use this context or a child context get the field, also in callees.

Use `slog.With` only for a `*slog.Logger` that you give to other code, for example `broker.NewSubscriber`. These attributes stay on that logger. They are not on the context, so callees that use `slog.Default()` do not get them.

```go
import (
    "context"
    "log/slog"

    hfl "github.com/openshift-hyperfleet/hyperfleet-logger"
    "github.com/openshift-hyperfleet/hyperfleet-broker/broker"

    "example.com/component/internal/logctx" // the component's own logctx package
)

// ✅ DO: set the field once; this record and every record a callee logs with ctx carry observed_generation
func evaluate(ctx context.Context, generation int) {
    ctx = hfl.Set(ctx, logctx.ObservedGenerationKey, generation)
    slog.InfoContext(ctx, "evaluating resource")
}

// ✅ DO: bind attributes to the logger you pass to a library
func newSubscriber(subscriptionID string, metrics *broker.MetricsRecorder) (broker.Subscriber, error) {
    logger := slog.Default().With("subscription", subscriptionID)
    return broker.NewSubscriber(logger, subscriptionID, metrics)
}

// ❌ DON'T: expect With attributes to reach callees that log through slog.Default()
func evaluateWithReason(ctx context.Context, reason string) {
    logger := slog.Default().With("decision_reason", reason)
    logger.InfoContext(ctx, "evaluating resource") // carries decision_reason
    slog.InfoContext(ctx, "publishing event")      // a callee's record does not
}
```

### Field naming

- Attribute keys MUST be `snake_case` and MUST use the names in [Log Fields](#log-fields) and [Component Guidelines](#component-guidelines) when one applies.
- Values MUST go in attributes, not in the message with `fmt.Sprintf`.

```go
import (
    "context"
    "fmt"
    "log/slog"
)

// ✅ DO: snake_case keys, values in attributes
func published(ctx context.Context, clusterID, topic string) {
    slog.InfoContext(ctx, "published event", "cluster_id", clusterID, "topic", topic)
}

// ❌ DON'T: format values into the message
func publishedFormatted(ctx context.Context, clusterID, topic string) {
    slog.InfoContext(ctx, fmt.Sprintf("published event for cluster %s to %s", clusterID, topic))
}
```

### Common patterns

#### Correlation

Set `trace_id` and `span_id` on the context where a span starts or arrives: in the HTTP middleware, an event handler or a polling loop, and after each child span you start. Code that does not start a span does not set them. Then each record has the `span_id` of the span that is current when it is logged, as the [Correlation Fields](#correlation-fields) table defines.

```go
import (
    "context"
    "log/slog"

    hfl "github.com/openshift-hyperfleet/hyperfleet-logger"
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/trace"
)

// withTrace returns ctx carrying the IDs of the active span, or ctx unchanged when there is none.
func withTrace(ctx context.Context) context.Context {
    sc := trace.SpanContextFromContext(ctx)
    if !sc.IsValid() {
        return ctx
    }
    ctx = hfl.WithTraceID(ctx, sc.TraceID().String())
    return hfl.WithSpanID(ctx, sc.SpanID().String())
}

// ✅ DO: set the IDs again after you start a child span
func fetchCluster(ctx context.Context, id string) {
    ctx, span := otel.Tracer("sentinel").Start(ctx, "fetch cluster")
    defer span.End()
    ctx = withTrace(ctx)

    slog.DebugContext(ctx, "fetching cluster", "cluster_id", id) // has the span_id of "fetch cluster"
}
```

#### HTTP middleware

An HTTP service sets the correlation fields in this order: the request ID, the trace and span IDs (`withTrace`), and the completion record with `method`, `path`, `status_code` and `duration_ms`. The OpenTelemetry HTTP instrumentation starts the span before the trace step.

```text
HTTP request
  -> request ID middleware      (sets request_id)
  -> trace middleware           (withTrace: sets trace_id, span_id)
  -> request logging middleware (logs method, path, status_code, duration_ms on completion)
  -> handler
```

The reference implementation is in `hyperfleet-api`: `pkg/logger/requestid_middleware.go`, `pkg/middleware/otel.go` and `cmd/hyperfleet-api/server/logging/request_logging_middleware.go`.

#### Event handlers

At the start of an event handler, set `event_id` from the CloudEvent ID and the resource fields from the event data.

```go
import (
    "context"
    "fmt"
    "log/slog"

    "github.com/cloudevents/sdk-go/v2/event"
    hfl "github.com/openshift-hyperfleet/hyperfleet-logger"

    "example.com/component/internal/logctx" // the component's own logctx package
)

func handleEvent(ctx context.Context, evt *event.Event) error {
    ctx = hfl.Set(ctx, logctx.EventIDKey, evt.ID())

    var data struct {
        Kind string `json:"kind"`
        ID   string `json:"id"`
    }
    if err := evt.DataAs(&data); err != nil {
        return fmt.Errorf("parse event data: %w", err)
    }
    ctx = hfl.WithResourceType(ctx, data.Kind)
    ctx = hfl.WithResourceID(ctx, data.ID)

    slog.InfoContext(ctx, "processing event", "event_type", evt.Type())
    return nil
}
```

#### Error logging

- Log an error one time, where code handles it: `slog.ErrorContext(ctx, msg, "error", err)`. Code that returns the error wraps it and does not log it.
- Expected conditions (resource not found, retries, cancellation) MUST use `info` or `warn`, not `error`.
- Stack traces come only from the `hfl.WithStackTrace` filter, for `error` records. Code MUST NOT add a stack trace. Each component selects the errors that get one: Sentinel traces all `error` records, and the Adapter skips expected errors.

```go
import (
    "context"
    "errors"
    "log/slog"
)

// ✅ DO: log once where the error is handled, and log expected conditions below error level
func run(ctx context.Context, id string, fetch func(context.Context, string) error) {
    err := fetch(ctx, id)
    switch {
    case errors.Is(err, context.Canceled):
        slog.InfoContext(ctx, "fetch cancelled", "cluster_id", id)
    case err != nil:
        slog.ErrorContext(ctx, "failed to fetch cluster", "cluster_id", id, "error", err)
    }
}

// ❌ DON'T: log an error and also return it, so it is logged again by every caller
func fetchAndLog(ctx context.Context, id string, fetch func(context.Context, string) error) error {
    err := fetch(ctx, id)
    if err != nil {
        slog.ErrorContext(ctx, "failed to fetch cluster", "cluster_id", id, "error", err)
    }
    return err
}
```

### Testing

A test of log output MUST write to a buffer handler and check the decoded fields, not the text. It MUST restore the previous `slog.Default()` in `t.Cleanup`. It MUST NOT use `slog.SetDefault` with `t.Parallel()`, because the default logger is global.

```go
import (
    "bytes"
    "context"
    "encoding/json"
    "log/slog"
    "testing"

    hfl "github.com/openshift-hyperfleet/hyperfleet-logger"
)

func TestResourceFieldsReachTheRecord(t *testing.T) {
    prev := slog.Default()
    t.Cleanup(func() { slog.SetDefault(prev) })

    var buf bytes.Buffer
    slog.SetDefault(slog.New(hfl.NewHandler("test", "v0.0.0", hfl.WithOutput(&buf))))

    ctx := hfl.WithResourceID(context.Background(), "cls-123")
    slog.InfoContext(ctx, "published event", "topic", "clusters")

    var record map[string]any
    if err := json.Unmarshal(buf.Bytes(), &record); err != nil {
        t.Fatalf("decode log record: %v", err)
    }
    if got := record["resource_id"]; got != "cls-123" {
        t.Errorf("resource_id = %v, want cls-123", got)
    }
    if got := record["topic"]; got != "clusters" {
        t.Errorf("topic = %v, want clusters", got)
    }
}
```

### Shared libraries

Shared libraries (for example, the broker client) log for the calling component:

- When Sentinel publishes to the broker → logs include `component=sentinel`
- When an Adapter subscribes from the broker → logs include `component=adapter-validation`

Their records MUST have the caller's `component`, `version` and `hostname`. A record that the library logs with a caller context MUST also have the caller's context fields. The exception below lists the records that have no caller context.

A shared library:

- MUST log only through the `*slog.Logger` the caller passes in
- MUST use the `*Context` methods with the received context
- MAY use `context.Background()` when there is no caller context: for construction, configuration and `Close` records, and for a logger that the library gives to a dependency at construction because the dependency takes no logger or context for each call. These records still have `component`, `version` and `hostname` from the logger the caller passed in, but not the caller's context fields. For example, the broker publisher gives Watermill one logger at construction, so the Watermill records about connection setup and batching have no `trace_id` or `span_id`
- MUST NOT call `slog.SetDefault`, build a handler, or set `component`

```go
import (
    "context"
    "log/slog"
    "os"

    "github.com/openshift-hyperfleet/hyperfleet-broker/broker"
)

// ✅ DO: the caller passes its logger to the library
func newPublisher(metrics *broker.MetricsRecorder) (broker.Publisher, error) {
    return broker.NewPublisher(slog.Default(), metrics)
}

// ❌ DON'T: a library that builds its own logger loses the caller's component, version and context
func publishWithOwnLogger(ctx context.Context, topic string) {
    logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
    logger.Info("publishing event", "topic", topic) // missing component, trace_id, etc.
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

## Enforcement

Enforced via the [three-layer review model](../docs/automated-pr-review-strategy.md).

- Each Go repository's `AGENTS.md` MUST link this standard.
- The HyperFleet review plugins load this standard at review time.

---

## References

- [HyperFleet Tracing Standard](./tracing.md)
- [HyperFleet Metrics Standard](./metrics.md)
- [HyperFleet Health Endpoints](./health-endpoints.md)
- [hyperfleet-logger](https://github.com/openshift-hyperfleet/hyperfleet-logger)
