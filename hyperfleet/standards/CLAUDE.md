---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-03-05
---

# Claude Code Guidelines for HyperFleet Standards

## What Standards Are

Standards are **PRESCRIPTIVE** - they define rules that MUST be followed across all HyperFleet repositories. They are not suggestions or design documents.

## Standard Document Pattern

Every standard follows this structure:

1. **Overview** - What this standard covers and why it matters
2. **Standard** - The actual requirements (MUST/SHOULD/MAY)
3. **Examples** - Good and bad examples showing compliance
4. **Enforcement** - How the standard is checked (CI, linting, review)
5. **References** - Links to external docs or related standards

## Existing Standards

Reference these when working with standards (non-exhaustive - see `hyperfleet/standards/` for full list):

| Standard | Purpose |
|----------|---------|
| `commit-standard.md` | Commit message format (Conventional Commits + JIRA prefix) |
| `configuration.md` | Configuration management |
| `container-image-standard.md` | Container image requirements |
| `dependency-pinning.md` | Dependency version pinning |
| `directory-structure.md` | Repository structure |
| `error-model.md` | Error handling patterns |
| `generated-code-policy.md` | Generated code management |
| `graceful-shutdown.md` | Shutdown signal handling |
| `health-endpoints.md` | Health check endpoints |
| `helm-chart-conventions.md` | Helm chart structure and conventions |
| `linting.md` | Linting requirements |
| `logging-specification.md` | Logging format and levels |
| `makefile-conventions.md` | Makefile patterns |
| `metrics.md` | Prometheus metrics |
| `tracing.md` | Distributed tracing |

## RFC 2119 Language

Use these keywords with their RFC 2119 meanings:

- **MUST** / **REQUIRED** - Absolute requirement
- **MUST NOT** - Absolute prohibition
- **SHOULD** / **RECOMMENDED** - Strong recommendation with valid exceptions
- **SHOULD NOT** - Strong recommendation against with valid exceptions
- **MAY** / **OPTIONAL** - Truly optional

Example:
```markdown
Services MUST expose a `/healthz` endpoint.
Services SHOULD use structured JSON logging.
Services MAY implement custom metrics beyond the required set.
```

## Adding New Standards Checklist

When creating a new standard:

- [ ] Follows the document pattern (Overview, Standard, Examples, Enforcement, References)
- [ ] Uses RFC 2119 language correctly
- [ ] Includes both good and bad examples
- [ ] Defines how it will be enforced
- [ ] Has proper header (Status, Owner, Last Updated)
- [ ] Links to related standards if applicable

## Common Patterns

### Requirement Tables

```markdown
| Requirement | Level | Notes |
|-------------|-------|-------|
| Health endpoint | MUST | Required for k8s probes |
| Metrics endpoint | MUST | Required for monitoring |
| Tracing headers | SHOULD | Recommended for debugging |
```

### Good/Bad Examples

```markdown
### Good Example
\`\`\`go
// Structured logging with context
log.Info("request processed", "duration", duration, "status", status)
\`\`\`

### Bad Example
\`\`\`go
// Unstructured logging
fmt.Printf("processed request in %v\n", duration)
\`\`\`
```

### Code Blocks

Always specify the language for syntax highlighting:
- `go` for Go code
- `yaml` for YAML configuration
- `bash` for shell commands
- `json` for JSON examples

## Tone and Voice

- Be direct and authoritative
- State requirements clearly
- Avoid hedging language ("maybe", "perhaps", "might want to")
- Explain the "why" briefly, focus on the "what"
