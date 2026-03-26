---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-03-19
---

# HyperFleet Commit Message Standard

> Defines the commit message format for all HyperFleet repositories, extending the Conventional Commits specification with a JIRA ticket prefix (`HYPERFLEET-XXX - <type>: <subject>`). Covers commit types, character limits, breaking change notation, and enforcement via CI linting. All HyperFleet repos — services, adapters, infrastructure, and this architecture repo — must follow this standard.

---

This guide defines the commit message format and conventions for all HyperFleet repositories.

---

## Table of Contents

1. [Overview](#overview)
2. [Commit Message Format](#commit-message-format)
3. [Commit Types](#commit-types)
4. [Body](#body)
5. [Footer](#footer)
6. [Breaking Changes](#breaking-changes)
7. [Examples](#examples)
8. [Enforcement](#enforcement)
9. [References](#references)

---

## Overview

This standard is based on the [Conventional Commits](https://www.conventionalcommits.org/) specification. Following these conventions ensures:

- Consistent git history across all repositories
- Automated changelog generation capability
- Clear context for code reviewers
- Easy navigation through commit history

### Applicability

This standard applies to:
- All HyperFleet service repositories
- All adapter repositories
- Infrastructure and tooling repositories
- Architecture documentation repository

### Standard Extensions

HyperFleet extends Conventional Commits with two additional types:
- `style` - Go formatting and linting tool changes (gofmt, goimports)
- `perf` - Performance-only improvements with no functional changes

---

## Commit Message Format

Every commit message consists of a **header**, an optional **body**, and an optional **footer**:

```text
HYPERFLEET-XXX - <type>: <subject>

[optional body]

[optional footer(s)]
```

When there is no associated JIRA ticket:

```text
<type>: <subject>

[optional body]

[optional footer(s)]
```

The **header** is mandatory.

### Character Limits

**Subject line:** The `<type>: <subject>` portion (excluding JIRA ticket prefix) MUST NOT exceed 72 characters.

**Body:** No hard line length limit. Use natural paragraph formatting with complete sentences.

**Examples:**

Good - `<type>: <subject>` is less than 72 characters:
```
HYPERFLEET-123 - feat: add comprehensive cluster validation with adapters
```

Bad - `<type>: <subject>` exceeds 72 characters:
```
HYPERFLEET-123 - feat: add comprehensive cluster validation logic for all cloud providers globally
```

---

## Commit Types

Use the following types to categorize your commits:

| Type | Description | Example |
|------|-------------|---------|
| `feat` | A new feature | Adding a new API endpoint |
| `fix` | A bug fix | Fixing a null pointer exception |
| `docs` | Documentation only changes | Updating README or API docs |
| `style` | Code style changes (formatting, semicolons, etc.) | Running gofmt |
| `refactor` | Code change that neither fixes a bug nor adds a feature | Restructuring code without changing behavior |
| `perf` | Performance improvements | Optimizing database queries |
| `test` | Adding or correcting tests | Adding unit tests for a function |
| `build` | Changes to build system or dependencies | Updating Makefile or go.mod |
| `ci` | Changes to CI configuration | Updating GitHub Actions workflow |
| `chore` | Other changes that don't modify src or test files | Updating .gitignore |
| `revert` | Reverting a previous commit | Reverting a problematic change |

### Type Selection Guidelines

- Use `feat` only for user-facing features or significant new capabilities
- Use `fix` for bug fixes, not for fixing typos in code (use `style` or `chore`)
- Use `refactor` when restructuring code without changing external behavior
- Use `chore` for maintenance tasks that don't fit other categories

---

## Body

The body is optional. Use it only when the commit message alone isn't clear enough and the JIRA ticket doesn't provide sufficient context.

---

## Footer

The footer might be used for:
1. **Breaking change notices**
2. **Co-authored-by credits**
3. **Additional references** (when commit relates to multiple tickets)

### Additional Ticket References

When a commit relates to multiple tickets, the primary ticket goes in the header and additional references go in the footer:

```text
HYPERFLEET-123 - feat: add cluster validation

Refs: HYPERFLEET-456
```

---

## Breaking Changes

Breaking changes must be clearly indicated in the commit message using `BREAKING CHANGE:` in the footer.

The breaking change message must include:
1. **What changed** - the specific API, field, or behavior that changed
2. **Impact** - what will break for consumers
3. **Migration** - what consumers need to do to adapt

---

## Examples

```text
HYPERFLEET-249 - feat: add generation-based reconciliation trigger
HYPERFLEET-401 - fix: handle nil pointer when cluster is deleted
HYPERFLEET-425 - docs: add commit message standard
HYPERFLEET-312 - refactor: extract validation logic to separate package
HYPERFLEET-376 - ci: add golangci-lint to GitHub Actions workflow
build: upgrade go version to 1.23
chore: update .gitignore to exclude coverage files
```

### Breaking Change

```text
HYPERFLEET-567 - feat: rename cluster phase to status

BREAKING CHANGE: ClusterStatus.phase field renamed to ClusterStatus.status.
API clients reading cluster status will receive errors on the old field.
Update all references from .phase to .status in your code.
```

---

## Enforcement

This standard will be enforced through automated tooling:

### CI Validation (Planned)

- **GitHub Actions** with [commitlint](https://commitlint.js.org/) to validate commit messages on pull requests
- PR titles must also follow this format for squash merges
- See [HYPERFLEET-432](https://issues.redhat.com/browse/HYPERFLEET-432) for implementation status

### Local Development (Optional)

Developers may optionally configure local commit hooks using [husky](https://typicode.github.io/husky/) for immediate feedback during development.

---

## References

### External Resources

- [Conventional Commits Specification](https://www.conventionalcommits.org/)
- [Angular Commit Message Guidelines](https://github.com/angular/angular/blob/main/CONTRIBUTING.md#commit)
- [How to Write a Git Commit Message](https://cbea.ms/git-commit/)

### Related HyperFleet Standards

- [Makefile Conventions](./makefile-conventions.md)
- [Linting Standard](./linting.md)
