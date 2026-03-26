---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-03-17
---

# Linting and Static Analysis Standard


## Overview

This document defines the shared linting and static analysis baseline for all HyperFleet Go repositories.

All HyperFleet Go repositories MUST use [golangci-lint](https://golangci-lint.run/) with a standardized configuration to ensure consistent code quality, security, and style across the project.

## Configuration File

Each repository MUST include a `.golangci.yml` file at the root level. The reference configuration is provided in [.golangci.yml](./golangci.yml).

## Enabled Linters

The following linters are enabled in the standard configuration:

### Code Quality

| Linter | Purpose | Rationale |
|--------|---------|-----------|
| `errcheck` | Checks for unchecked errors | Prevents silent failures by ensuring all errors are handled |
| `govet` | Reports suspicious constructs | Catches common mistakes like printf format mismatches |
| `staticcheck` | Static analysis | Comprehensive checks for bugs, performance, and simplifications |
| `ineffassign` | Detects ineffectual assignments | Identifies assignments that have no effect |
| `unused` | Checks for unused code | Keeps codebase clean by identifying dead code |
| `unconvert` | Removes unnecessary type conversions | Simplifies code by removing redundant conversions |
| `unparam` | Finds unused function parameters | Identifies parameters that could be removed |
| `goconst` | Finds repeated strings that could be constants | Improves maintainability |
| `exhaustive` | Checks exhaustiveness of enum switch statements | Ensures all enum cases are handled when adding new values |

### Code Style

| Linter | Purpose | Rationale |
|--------|---------|-----------|
| `misspell` | Finds misspelled words | Improves code readability and professionalism |
| `lll` | Reports long lines | Maintains readable line lengths (120 chars max) |
| `revive` | Fast, configurable linter | Catches common style issues and potential bugs |
| `gocritic` | Diagnostics for bugs, performance, style | Additional checks beyond other linters |

### Formatters

In golangci-lint v2, formatters are a separate top-level section, not part of `linters`:

| Formatter | Purpose | Rationale |
|-----------|---------|-----------|
| `gofmt` | Checks code is formatted | Ensures consistent formatting across all code |
| `goimports` | Checks import statements | Ensures imports are properly organized and formatted |

### Security

| Linter | Purpose | Rationale |
|--------|---------|-----------|
| `gosec` | Security issues | Identifies potential security vulnerabilities |

## Linter Settings

### errcheck

```yaml
errcheck:
  check-type-assertions: true  # Check type assertion results
  check-blank: true            # Check assignments to blank identifier
```

### govet

```yaml
govet:
  enable-all: true  # Enable all govet checks
```

### goconst

```yaml
goconst:
  min-len: 3          # Minimum string length
  min-occurrences: 3  # Minimum occurrences before suggesting const
```

### misspell

```yaml
misspell:
  locale: US  # Use US English spelling
```

### lll

```yaml
lll:
  line-length: 120  # Maximum line length
```

### revive

```yaml
revive:
  rules:
    - name: exported
      severity: warning
      disabled: true  # Can be too noisy for internal packages
    - name: unexported-return
      severity: warning
      disabled: false
    - name: var-naming
      severity: warning
      disabled: false
```

### unparam

```yaml
unparam:
  check-exported: false  # Don't flag unused params in exported functions
```

### exhaustive

```yaml
exhaustive:
  default-signifies-exhaustive: true    # Allow default case to satisfy exhaustiveness
```

This linter ensures all enum values are handled in switch statements. When a new cloud provider or cluster state is added, the linter will flag any switch statements that need updating.

## Formatter Settings

### gofmt

In golangci-lint v2, `gofmt` is configured under the `formatters` top-level section:

```yaml
formatters:
  enable:
    - gofmt
    - goimports
  settings:
    gofmt:
      simplify: true  # Apply code simplifications
  exclusions:
    generated: lax
    paths:
      - third_party(/|$)
      - builtin(/|$)
      - examples(/|$)
```

## Standard Exclusions

### Generated Code

Generated code MUST be excluded from linting (see [Generated Code Policy](generated-code-policy.md)). Use the `linters.exclusions.paths` setting:

```yaml
linters:
  exclusions:
    generated: lax
    paths:
      - pkg/api/openapi      # OpenAPI generated code
      - data/generated       # Other generated files
      - third_party(/|$)
      - builtin(/|$)
      - examples(/|$)
```

Each repository should add its specific generated code directories to this list. Path patterns use the `(/|$)` suffix to correctly match files nested inside those directories.

### Test Files

Some linters are relaxed for test files to reduce noise. In v2, these are configured under `linters.exclusions.rules`:

```yaml
linters:
  exclusions:
    rules:
      - linters:
          - gosec      # Security checks less critical in tests
          - errcheck   # Error checking less strict in tests
          - unparam    # Unused params common in test helpers
        path: _test\.go
```

## Performance Settings

```yaml
run:
  timeout: 5m           # Allow sufficient time for large codebases
  tests: true           # Include test files in analysis
  modules-download-mode: readonly  # Don't modify go.mod
```

## Output Configuration

```yaml
output:
  formats:
    text:
      path: stdout
```

## Repository-Specific Overrides

Repositories MAY add additional exclusions or settings for legitimate reasons:

### Allowed Overrides

- Additional `linters.exclusions.paths` for repository-specific generated code
- Additional `linters.exclusions.rules` for framework-specific patterns
- Enabling additional linters beyond the baseline

### Not Allowed

- Disabling any linter from the baseline set
- Reducing the `timeout` below 5 minutes
- Disabling `gosec` for production code

### Documenting Overrides

Any overrides MUST be documented with a comment explaining the rationale:

```yaml
linters:
  exclusions:
    rules:
      # OVERRIDE: Framework requires specific pattern that triggers false positive
      - linters:
          - revive
        path: pkg/framework/
        text: "unexported-return"
```

## CI Integration

### Makefile Target

Each repository MUST provide a `make lint` target (see [Makefile Conventions](makefile-conventions.md)):

```makefile
.PHONY: lint
lint:
    golangci-lint run ./...
```

### Pre-commit Hook (Optional)

Repositories MAY use pre-commit hooks for local linting:

```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/golangci/golangci-lint
    rev: v2.1.6
    hooks:
      - id: golangci-lint
```

## Version Requirements

- **golangci-lint**: v2.x (configuration uses `version: 2` format), installed via [bingo](https://github.com/bwplotka/bingo)
- **Go**: As specified in each repository's `go.mod`

## Adopting This Standard

To adopt this standard in an existing repository:

1. Install golangci-lint via bingo: `bingo get golangci-lint@v2`
2. Copy the reference [.golangci.yml](./golangci.yml) to your repository root
3. Add any repository-specific generated code directories to `linters.exclusions.paths`
4. Run `make lint` to identify existing issues
5. Create a tracking ticket for fixing existing violations (separate from adoption)
6. Enable linting in CI pipeline
