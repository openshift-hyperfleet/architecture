---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-01-09
---

# HyperFleet Graceful Shutdown Standard

## Overview

This document defines the standard approach for graceful shutdown and drain behavior across all HyperFleet components (API, Sentinel, Adapters).


### Goals

- **Consistency**: All components handle shutdown signals the same way
- **Reliability**: No data loss or incomplete operations during shutdown
- **Zero-downtime deployments**: Support rolling updates without request failures

---

## Signal Handling

All HyperFleet applications MUST handle these signals:

| Signal | Behavior |
|--------|----------|
| `SIGTERM` | Initiate graceful shutdown |
| `SIGINT` | Initiate graceful shutdown (for local development) |

**Implementation Notes:**

- Both signals trigger the same graceful shutdown sequence
- Applications MUST NOT exit immediately upon signal receipt
- Applications MUST complete the shutdown sequence before exiting

```go
// Example signal handling in Go
ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
defer stop()

// Start application with cancellable context
if err := app.Start(ctx); err != nil {
    log.Error("application error", "error", err)
}

// When signal received, ctx is cancelled
// Application should begin shutdown sequence
```

---

## Shutdown Sequence

When a shutdown signal is received, applications MUST follow this sequence:

```text
1. Mark Not Ready (/readyz → 503)
         ↓
2. Stop Accepting New Work
         ↓
3. Drain In-Flight Requests/Events
         ↓
4. Cleanup Resources
         ↓
5. Exit
```

### Phase 1: Mark Not Ready

- Set `/readyz` endpoint to return `503 Service Unavailable`
- Kubernetes removes pod from Service endpoints
- New traffic is routed to other healthy pods

### Phase 2: Stop Accepting New Work

- HTTP servers: Stop accepting new connections
- Broker consumers: Stop pulling new messages from subscriptions
- Background workers: Stop scheduling new tasks

### Phase 3: Drain In-Flight Work

- HTTP servers: Wait for active requests to complete
- Broker consumers: Wait for in-flight events to finish processing
- Background workers: Wait for running tasks to complete

### Phase 4: Cleanup Resources

- Close database connections
- Close broker connections
- Flush logs and metrics
- Release file handles and other resources

### Phase 5: Exit

- Exit with code 0 on successful shutdown
- Exit with non-zero code if shutdown errors occurred

> **Note**: In Go, `http.Server.Shutdown()` handles phases 2-3 automatically for HTTP servers. See [Timeout Configuration](#timeout-configuration) for the recommended shutdown timeout.

---

## Timeout Configuration

Applications MAY support timeout configuration via environment variables:

| Configuration | Environment Variable | Default | Description |
|---------------|---------------------|---------|-------------|
| Shutdown Timeout | `SHUTDOWN_TIMEOUT` | `20s` | Maximum time for graceful shutdown |
| Drain Period | `DRAIN_PERIOD` | `15s` | Time allocated for draining in-flight work |

**Timeout Behavior:**

- If shutdown does not complete within `SHUTDOWN_TIMEOUT`, force exit
- `DRAIN_PERIOD` should be less than `SHUTDOWN_TIMEOUT` to allow cleanup time
- Log warning if shutdown times out

```go
// Example: Graceful shutdown with 20s timeout (terminationGracePeriodSeconds = 30)
ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
defer cancel()
server.Shutdown(ctx)
```

---

## HTTP Server Drain Behavior

HTTP servers MUST implement graceful shutdown:

1. **Stop accepting connections**: Call `server.Shutdown(ctx)`
2. **Complete active requests**: Let in-flight requests finish
3. **Respect timeout**: Cancel long-running requests when drain period expires

```go
// Example HTTP server shutdown
func (s *Server) Shutdown(ctx context.Context) error {
    // Shutdown stops accepting new connections and waits for active ones
    return s.httpServer.Shutdown(ctx)
}
```

**Response Headers:**

During shutdown, respond to new requests with:
- Status: `503 Service Unavailable`
- Header: `Connection: close`

---

## Broker Consumer Drain Behavior

Broker consumers (Pub/Sub, etc.) MUST implement graceful shutdown:

1. **Stop receiving messages**: Stop pulling from subscription
2. **Process in-flight messages**: Complete messages already being processed
3. **Acknowledge or Nack**: Ensure all messages are acknowledged or nacked before exit

```go
// Example broker consumer shutdown
func (c *Consumer) Shutdown(ctx context.Context) error {
    // Stop receiving new messages (Receive returns when context is cancelled)
    c.cancel()

    // Wait for in-flight handlers to complete
    c.wg.Wait()

    return nil
}
```

**Message Handling During Shutdown:**

- Messages received before shutdown signal: Process and acknowledge
- Messages received after shutdown signal: Should not occur (receiver stopped)
- If processing exceeds drain period: Nack message so it can be redelivered

---

## Background Worker Shutdown

Background goroutines MUST be managed for graceful shutdown using context cancellation:

```go
func (w *Worker) Start(ctx context.Context) {
    for {
        select {
        case <-ctx.Done():
            // Context cancelled, stop scheduling new work
            return
        case <-time.After(w.interval):
            w.doWork(ctx)
        }
    }
}
```

---

## Kubernetes Integration

Deployments CAN configure `terminationGracePeriodSeconds` to allow time for graceful shutdown. By [default](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination-flow) Kubernetes defines `30` seconds as the termination grace period.


```yaml
spec:
  terminationGracePeriodSeconds: 30
```

If shutdown does not complete within `terminationGracePeriodSeconds`, Kubernetes sends SIGKILL.

---

## Upgrade Behavior

During rolling updates, applications MUST:

1. **Continue serving**: Process requests until shutdown signal
2. **Honor readiness**: Mark unready immediately when shutdown begins (see [Phase 1](#phase-1-mark-not-ready))
3. **Drain gracefully**: Complete in-flight work before exiting
4. **Not persist upgrade state**: Each pod is stateless

---

## Component Guidelines

### API

| Aspect | Behavior |
|--------|----------|
| HTTP Server | Drain active requests, reject new ones with 503 |
| Database | Close connection pool after requests complete |
| Health endpoints | Return unhealthy immediately on shutdown |

### Sentinel

| Aspect | Behavior |
|--------|----------|
| Polling Loop | Stop after current iteration |
| Event Publishing | Complete in-flight publishes |
| Metrics | Flush before exit |

### Adapters

| Aspect | Behavior |
|--------|----------|
| Broker Consumer | Stop receiving, complete in-flight events |
| Kubernetes Client | Complete in-flight API calls |
| Status Reporting | Report status for processed events before exit |
| Health endpoints | Return unhealthy immediately on shutdown |

---

## Logging During Shutdown

Log shutdown events following the [Logging Specification](./logging-specification.md):

- `info`: Shutdown initiated, drain started/completed, shutdown completed
- `warn`: Drain timeout, shutdown timeout

---

## Testing Requirements

Applications MUST include tests for:

1. **Signal handling**: Verify SIGTERM triggers shutdown
2. **In-flight completion**: Verify active work completes
3. **Timeout behavior**: Verify forced exit on timeout
4. **Clean exit**: Verify exit code 0 on successful shutdown

Example test scenarios:

```go
func TestGracefulShutdown(t *testing.T) {
    // Start server
    server := NewServer()
    go server.Start(ctx)

    // Send request that takes time
    go func() {
        resp, err := http.Get(server.URL + "/slow")
        assert.NoError(t, err)
        assert.Equal(t, 200, resp.StatusCode)
    }()

    // Give request time to start
    time.Sleep(100 * time.Millisecond)

    // Send SIGTERM
    syscall.Kill(syscall.Getpid(), syscall.SIGTERM)

    // Verify request completed
    // Verify server exited cleanly
}
```

---

## Summary

| Aspect | Standard |
|--------|----------|
| Signals | SIGTERM and SIGINT trigger graceful shutdown |
| Sequence | Mark not ready → Stop accepting → Drain → Cleanup → Exit |
| Timeout | 20s default, configurable via `SHUTDOWN_TIMEOUT` |
| HTTP | Use `server.Shutdown()`, return 503 during drain |
| Broker | Stop receiving, complete in-flight, ack/nack all |
| Kubernetes | 30s terminationGracePeriodSeconds |
| Readiness | Return unhealthy immediately on shutdown |

---

## References

- [Kubernetes Pod Termination](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination)
- [Go HTTP Server Shutdown](https://pkg.go.dev/net/http#Server.Shutdown)
- [HyperFleet Health Endpoints Standard](./health-endpoints.md)
- [HyperFleet Logging Specification](./logging-specification.md)
