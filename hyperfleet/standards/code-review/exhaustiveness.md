---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-10-27
---

# Code Review: Exhaustiveness

> Go-specific code review standard for switch/select completeness and nil/bounds safety guards. Applies to all diffs containing `.go` files.

---

## Table of Contents

1. [Overview](#overview)
2. [Standard](#standard)
3. [Examples](#examples)
4. [Enforcement](#enforcement)
5. [References](#references)

---

## Overview

Missing switch cases, unintended select blocking, and nil dereferences are common sources of silent misbehavior and panics. This standard defines the mechanical checks reviewers apply to control flow constructs that must be exhaustive.

### Risk: Bug

Violations cause panics or silent wrong behavior. An unhandled switch case is silently skipped; a nil dereference crashes the process.

---

## Standard

### EXH-01: Switch exhaustiveness

Every `switch` statement added or modified MUST either include a `default` case or explicitly handle all known values of the switched type. A missing `default` MUST be flagged when unrecognized input would silently produce wrong behavior.

For enum-like types (iota constants, string sets), reviewers SHOULD verify that all current values are handled. The `exhaustive` linter (enabled in the [Linting Standard](../linting.md)) automates this for typed constants.

### EXH-02: Select blocking behavior

Every `select` statement MUST have intentional blocking behavior:

- A `select` **without** `default` blocks until a channel is ready. Reviewers MUST flag this if blocking appears unintentional (e.g., could deadlock or stall a goroutine indefinitely without a timeout or context cancellation case).
- A `select` **with** `default` is non-blocking. Reviewers MUST flag a `default` case added without clear intent, as it can introduce spin loops when used inside a `for` loop.

### EXH-03: Nil and bounds safety

Every array/slice indexing and pointer dereference on values that could be nil or empty MUST have a guard. Reviewers MUST flag potential panics from:

- Indexing into a slice without checking `len()`.
- Dereferencing a pointer without a nil check.
- Accessing map values used as pointers without checking existence.
- Type assertions without the comma-ok idiom (`v, ok := x.(T)`).

### Exceptions

Reviewers MUST NOT flag:

- Switch on `string` type where `default` is an intentional catch-all (e.g., command routing with a "not found" default). Only flag missing `default` when the consequence is silent wrong behavior.
- Select statements in well-documented blocking patterns (e.g., `for range ch` consumers that intentionally block until channel close).
- Nil checks on values that are guaranteed non-nil by the type system or constructor (e.g., return values from `NewFoo()` that never return nil).

---

## Examples

### Switch with default

```go
// ✅ Good — default case handles unknown values
switch cluster.Status {
case StatusActive:
    reconcile(cluster)
case StatusDeleting:
    cleanup(cluster)
default:
    slog.WarnContext(ctx, "unknown cluster status", "status", cluster.Status)
    return fmt.Errorf("unrecognized status: %s", cluster.Status)
}

// ❌ Bad — missing default, unknown status silently ignored
switch cluster.Status {
case StatusActive:
    reconcile(cluster)
case StatusDeleting:
    cleanup(cluster)
// BUG: new StatusPending value falls through silently
}
```

### Select with timeout

```go
// ✅ Good — select has timeout to prevent indefinite blocking
select {
case msg := <-ch:
    process(msg)
case <-ctx.Done():
    return ctx.Err()
}

// ❌ Bad — select blocks forever if channel is never written to
select {
case msg := <-ch:
    process(msg)
// BUG: no timeout or cancellation — goroutine hangs if ch is never closed
}
```

### Nil guard before dereference

```go
// ✅ Good — nil check before use
if cluster.Spec.NodePool != nil {
    count = cluster.Spec.NodePool.Replicas
}

// ❌ Bad — no nil check
count = cluster.Spec.NodePool.Replicas // panic if NodePool is nil
```

---

## Enforcement

Enforced via the [three-layer review model](../../docs/automated-pr-review-strategy.md).

Partially automated: the `exhaustive` linter (in the [Linting Standard](../linting.md)) checks switch exhaustiveness for typed constants. `govet` catches some nil-safety issues. `nilnil` is available but not currently enabled. Review is required for runtime-dependent nil/bounds checks and untyped/string switches the linter cannot reach.

---

## References

### Related HyperFleet Standards

- [Linting Standard](../linting.md) — `exhaustive` linter for switch completeness
- [Error Handling](error-handling.md) — error returns from default cases

### External Resources

- [Go Code Review Comments — Don't Panic](https://github.com/golang/go/wiki/CodeReviewComments#dont-panic)
