---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-10-27
---

# Code Review: Code Hygiene

> Language-agnostic code review standard for TODO tracking, log level correctness, and typo detection. Applies to all diffs regardless of file types.

---

## Table of Contents

1. [Overview](#overview)
2. [Standard](#standard)
3. [Examples](#examples)
4. [Enforcement](#enforcement)
5. [References](#references)

---

## Overview

Orphaned TODOs, mismatched log levels, and typos in identifiers are small defects individually but accumulate into significant maintenance burden. This standard defines the mechanical checks reviewers apply to every diff for hygiene issues.

### Risk: Debt

Violations produce working code but degrade codebase quality over time. An untracked TODO becomes permanent debt; a wrong log level either floods logs or hides incidents.

---

## Standard

### HYG-01: TODOs and FIXMEs without ticket

Every `TODO`, `FIXME`, `HACK`, and `XXX` comment added or modified in a diff SHOULD reference a ticket ID per the format defined in the [Commit Message Standard](../commit-standard.md).

TODOs without a ticket reference SHOULD be flagged — they represent untracked work that will be forgotten.

### HYG-02: Log level appropriateness

Every log statement added or modified in a diff MUST use the correct level (see [Logging Specification](../logging-specification.md) for the full standard):

| Level | When to use |
|-------|-------------|
| `debug` | Detailed debugging information — variable values, event payloads |
| `info` | Operational information — startup, successful operations, state transitions |
| `warn` | Warning conditions — retry attempts, slow operations, degraded service |
| `error` | Error conditions — failures, invalid configuration, unrecoverable issues |

Reviewers SHOULD flag:

- `error` level for conditions that are expected and handled (should be `warn` or `info`).
- `info` level for errors (should be `error` or `warn`).
- Log statements in loops or hot paths that could generate excessive output.
- Inconsistent log levels for the same type of event within the diff.

### HYG-03: Typo detection

Reviewers SHOULD check human-written text (identifiers, comments, strings, log messages, error messages, documentation, YAML values, markdown) for:

- **Misspelled words** in comments, doc strings, log/error messages, and documentation.
- **Misspelled identifiers** — variable names, function names, struct fields that contain common misspellings (e.g., `recieve` → `receive`, `seperator` → `separator`).
- **Inconsistent spelling** within the diff — the same concept spelled differently (e.g., `canceled` vs `cancelled`).

Exceptions:

- Intentional abbreviations and domain jargon (e.g., `k8s`, `ctx`, `cfg`, `mgr`, `msg`, `req`, `resp`).
- Third-party identifiers (imported package names, external API fields).
- Generated code.
- Single-letter variables in small scopes.

---

## Examples

### TODO with ticket reference

```go
// ✅ Good — tracked work
// TODO(HYPERFLEET-456): switch to batch API when available

// ❌ Bad — untracked, will be forgotten
// TODO: fix this later
```

### Log level correctness

```go
// ✅ Good — error level for actual errors
slog.ErrorContext(ctx, "failed to reconcile cluster", "cluster_id", id, "error", err)

// ✅ Good — info level for operational events
slog.InfoContext(ctx, "cluster reconciliation complete", "cluster_id", id, "duration_ms", elapsed)

// ❌ Bad — error level for expected condition
slog.ErrorContext(ctx, "cluster not found, skipping", "cluster_id", id)
// should be: slog.InfoContext or slog.WarnContext (cluster not existing is expected in some flows)

// ❌ Bad — info level in hot loop
for _, event := range events {
    slog.InfoContext(ctx, "processing event", "id", event.ID) // floods logs under load
    // should be: slog.DebugContext
}
```

### Go-specific

#### Logging framework

```go
// ✅ Good — structured logging with slog (per Logging Specification)
// component comes from the handler and subset from the context
slog.InfoContext(ctx, "publishing event", "cluster_id", clusterID)

// ❌ Bad — unstructured logging
fmt.Printf("processed request in %v\n", duration)
log.Println("cluster created:", clusterID)
```

#### TODO format

```go
// ✅ Good — follows commit standard ticket format
// TODO(HYPERFLEET-789): add retry logic for transient errors

// ❌ Bad — no ticket reference
// FIXME: this is broken
// HACK: workaround for API bug
```

---

## Enforcement

Enforced via the [three-layer review model](../../docs/automated-pr-review-strategy.md).

Partially automated:

- `markdownlint` catches some documentation issues.
- `misspell` linter detects common English misspellings in Go source.
- Pre-commit hooks enforce commit message format (see [Pre-commit Hooks Guide](../../docs/pre-commit-hooks.md)).
- Generated code is excluded per the [Generated Code Policy](../generated-code-policy.md).

---

## References

### Related HyperFleet Standards

- [Commit Message Standard](../commit-standard.md) — ticket reference format
- [Logging Specification](../logging-specification.md) — log levels, structured logging format
- [Linting Standard](../linting.md) — `misspell` linter
- [Generated Code Policy](../generated-code-policy.md) — exclusion rules

### External Resources

- [Go Code Review Comments](https://github.com/golang/go/wiki/CodeReviewComments)
