---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-03-25
---

# Contributing to HyperFleet Architecture

## Overview

> How to contribute architectural documents, standards, and design decisions to this repository. This is a documentation-only repository — there is no application code. Read this file before opening a PR.

Contributing means adding or updating architectural documents, standards, and design decisions.

---

## Development Setup

```bash
# 1. Clone the repository
git clone https://github.com/openshift-hyperfleet/architecture.git
cd architecture

# 2. Install linting tools (recommended before submitting PRs)
npm install -g markdownlint-cli2 markdown-link-check   # Markdown linting and link checking
pip install yamllint                                    # YAML linting
```

**First-time setup notes:**

- No build step required — this is a documentation repository
- The CI pipeline runs `markdownlint`, `yamllint`, and link checking automatically on PRs
- Run linting locally before pushing to catch issues early
- If using Claude Code for AI-assisted editing, see [CLAUDE.md](CLAUDE.md) for repository-specific guidelines

---

## Repository Structure

See [README.md](README.md) for the full directory layout and navigation guide.

---

## Making Changes

### Where Things Go

See the [README.md Navigation Guide](README.md#navigation-guide) for the document-type routing table. When in doubt, check there first.

### Document Standards

All documents must follow the header format and summary requirements defined in [CLAUDE.md](CLAUDE.md#document-header-format).

- **Component design documents**: See [components/CLAUDE.md](hyperfleet/components/CLAUDE.md) for required sections (What/Why/How/Trade-offs/Alternatives).
- **Standards documents**: See [standards/CLAUDE.md](hyperfleet/standards/CLAUDE.md) for the required structure.

### Terminology

Before introducing new terms or acronyms, consult the [HyperFleet Glossary](hyperfleet/docs/glossary.md). If you introduce a new term not already defined there, add it to the glossary as part of your PR.

---

## Testing / Linting

Use the scripts in `hack/` to run linting locally before pushing:

```bash
# Run markdown linting
./hack/markdownlint.sh

# Run YAML linting
./hack/yamllint.sh

# Check for broken internal links (informational — does not block CI)
./hack/linkcheck.sh
```

**Notes:**
- `linkcheck.sh` only checks **internal links** — external URLs (http/https) are skipped by design
- `linkcheck.sh` always exits 0 (informational only); broken internal links are surfaced as warnings, not failures
- The CI pipeline enforces markdownlint and yamllint on all PRs — fix any errors before requesting review
- Markdownlint rules are configured in `.markdownlint-cli2.yaml` at the repository root

---

## Submitting Changes

1. **Create a branch** from `main`:

   ```bash
   git checkout -b HYPERFLEET-XXX-brief-description
   ```

2. **Make your changes** following the document standards above

3. **Lint locally** using the `hack/` scripts before pushing

4. **Commit** following the [commit standard](hyperfleet/standards/commit-standard.md):

   ```
   HYPERFLEET-XXX - docs: brief description of change
   ```

5. **Open a PR** with a description that includes:
   - **What changed**: Which documents were added or updated
   - **Why**: The architectural context or decision being documented
   - **Reviewers to loop in**: Tag any component owners affected by the change

6. **Post the PR link** in [#hcm-hyperfleet-team](https://redhat.enterprise.slack.com/archives/hcm-hyperfleet-team) for team visibility

7. **Wait 24 hours** for peer review (accounts for time zone differences between regions)
   - For urgent changes, use judgement but ensure the rationale is well-documented in the PR
   - For major architectural changes, strongly consider waiting for at least one Technical Leader review

8. **Merge** once approved with no objections

---

## Questions?

- Slack: [#hcm-hyperfleet-team](https://redhat.enterprise.slack.com/archives/hcm-hyperfleet-team)
- Open a PR with your changes — discussion is welcome in PR comments
- See [README.md FAQ](README.md#faq) for common questions about document structure
