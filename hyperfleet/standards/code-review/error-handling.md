---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-10-27
---

# Code Review: Error Handling

> Go-specific code review standard for error handling completeness, wrapping patterns, and HTTP handler returns. Applies to all diffs containing `.go` files. For the canonical error model (error codes, RFC 9457 responses, wrapping policy), see the [Error Model Standard](../error-model.md) — this document covers what reviewers MUST check during code review.

---

## Table of Contents

1. [Overview](#overview)
2. [Standard](#standard)
3. [Examples](#examples)
4. [Enforcement](#enforcement)
5. [References](#references)

---

## Overview

Unchecked or improperly handled errors are the most common source of silent failures in Go services. This standard defines the mechanical checks reviewers apply to every error-handling site in a diff.

### Risk: Bug

Violations are bugs. An unchecked error can cause nil-pointer panics, data corruption, or silent data loss in production.

---

## Standard

### ERR-01: Error handling completeness

Every function call that returns an `error` MUST have its error value checked. Silently discarding errors (`_, _ =` or bare calls on error-returning functions) MUST be flagged.

If an error is intentionally ignored, the code MUST use an explicit blank identifier with a comment explaining why:

```go
_ = resp.Body.Close() // best-effort cleanup; error already logged by HTTP client
```

**Exception — non-actionable defer close:** when a close error cannot indicate lost data — i.e. the resource was only read from, with nothing buffered for writing (e.g. `resp.Body.Close()`, `rows.Close()`, a file opened read-only) — bare `defer` close MAY be used without a blank identifier or comment. This is idiomatic Go. When the resource was written to and close may flush (e.g. a file opened for writing, a DB handle), the close error MUST be handled, as it can signal data loss.

### ERR-02: Log-and-continue vs return

When an error is logged and execution continues (no `return`), the code MUST be intentional graceful degradation, not a missing `return`. Reviewers SHOULD flag log-and-continue patterns that lack an explicit comment or structural signal (e.g., `continue` in a loop) explaining why the error is non-fatal.

### ERR-03: HTTP handler missing return after error

Every call to `http.Error()`, `w.WriteHeader(<4xx or 5xx>)`, or any framework/project-specific error-response helper that writes an HTTP error status MUST be followed by a `return` statement. Missing `return` after an error response causes the handler to continue writing to a response that has already been committed.

The exact function names depend on the project's handler framework (e.g., gorilla/mux middleware, custom response helpers). Reviewers SHOULD check for missing `return` after ANY error-response write, regardless of the function name.

Calls to `w.WriteHeader()` with 1xx, 2xx, or 3xx status codes (e.g., `http.StatusCreated`) MUST NOT be flagged — these are valid non-error responses that may be followed by a response body write.

### ERR-04: Error wrapping

Error wrapping MUST follow these patterns (see [Error Model Standard](../error-model.md) for the full error model):

- Use `fmt.Errorf("context: %w", err)` to preserve the error chain.
- Error messages MUST be lowercase, without trailing punctuation.
- Use `errors.Is()` and `errors.As()` for error comparison — never `==` against sentinel errors.
- `panic()` MUST only be used for programmer errors (invariant violations), never for expected failure conditions.

---

## Examples

### Error handling completeness

```go
// ✅ Good — error checked and wrapped
data, err := db.GetCluster(id)
if err != nil {
    return fmt.Errorf("failed to get cluster %s: %w", id, err)
}

// ❌ Bad — error silently ignored
data, _ := db.GetCluster(id)
```

### HTTP handler missing return

```go
// ✅ Good — return after error response
if err := validateInput(r); err != nil {
    http.Error(w, err.Error(), http.StatusBadRequest)
    return
}
// handler continues with valid input

// ❌ Bad — missing return after error response
if err := validateInput(r); err != nil {
    http.Error(w, err.Error(), http.StatusBadRequest)
}
// BUG: handler continues and writes to already-committed response
```

### Error wrapping

```go
// ✅ Good — context added, error chain preserved
if err := db.GetCluster(id); err != nil {
    return fmt.Errorf("failed to get cluster %s: %w", id, err)
}

// ❌ Bad — original error lost
if err := db.GetCluster(id); err != nil {
    return errors.New("database error")
}
```

### Intentional ignore with defer

```go
// ✅ Good — close error logged
defer func() {
    if err := file.Close(); err != nil {
        slog.WarnContext(ctx, "failed to close file", "error", err)
    }
}()

// ✅ Good — read-only cleanup, error not actionable
defer resp.Body.Close()

// ❌ Bad — writable resource, close may flush — error signals data loss
defer file.Close()
```

---

## Enforcement

Enforced via the [three-layer review model](../../docs/automated-pr-review-strategy.md).

Partially automated by `errcheck` linter (included in the [Linting Standard](../linting.md) via golangci-lint). The linter catches unchecked errors but does not catch missing `return` after `http.Error()` or improper wrapping patterns — those require review.

---

## References

### Related HyperFleet Standards

- [Error Model and Codes Standard](../error-model.md) — canonical error wrapping policy, RFC 9457, error codes
- [Logging Specification](../logging-specification.md) — error logging format and context requirements
- [Linting Standard](../linting.md) — `errcheck` linter configuration

### External Resources

- [Effective Go — Errors](https://golang.org/doc/effective_go#errors)
- [Go Blog — Error Handling and Go](https://go.dev/blog/error-handling-and-go)
