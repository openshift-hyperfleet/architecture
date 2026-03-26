---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-03-25
---

# Contributing to HyperFleet Architecture

> How to contribute architectural documents, standards, and design decisions to this repository. This is a documentation-only repository — there is no application code. Read this file before opening a PR.

---

This repository is a **documentation-only** repository — there is no application code here.
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

See [README.md](README.md) for the full directory layout. Key directories:

```
architecture/
├── hyperfleet/
│   ├── architecture/    # System-level architecture documents
│   ├── components/      # Component design documents (design decisions, trade-offs)
│   ├── docs/            # Implementation guides and operational docs
│   │   └── glossary.md  # HyperFleet term definitions — consult before writing
│   ├── standards/       # Prescriptive standards all HyperFleet repos must follow
│   ├── deployment/      # Deployment guides (GKE, etc.)
│   ├── e2e-testing/     # E2E testing strategy documents
│   ├── mvp/             # Historical MVP scope and agreements
│   └── test-release/    # Test and release process documents
├── hack/                # Linting scripts (markdownlint.sh, yamllint.sh, linkcheck.sh)
├── README.md
├── CLAUDE.md            # AI-assisted workflow guidelines
└── CONTRIBUTING.md      # This file
```

---

## Making Changes

### Document Types

| What you're documenting | Where it goes |
|------------------------|---------------|
| System-level architecture | `hyperfleet/architecture/` |
| Component design (what/why/how/trade-offs) | `hyperfleet/components/<component>/` |
| Implementation or operational guide | `hyperfleet/docs/` |
| Engineering standards (must-follow rules) | `hyperfleet/standards/` |
| Deployment procedures | `hyperfleet/deployment/` |

When in doubt about where something belongs, check the [README.md Navigation Guide](README.md#navigation-guide).

### Required Document Header

Every document **must** start with:

```markdown
# Document Title

---
Status: Active
Owner: Team Name
Last Updated: YYYY-MM-DD
---

> [2-4 sentence summary of what this document covers and the key decision or purpose]

---
```

Update `Last Updated` only for meaningful changes (design changes, new sections, trade-offs modified). Not for typos or formatting fixes.

### Component Documents

Every component design document **must** include:

- **What & Why**: Purpose and problem it solves
- **How**: Technical implementation with at least one Mermaid diagram
- **Trade-offs**: What we gain vs. what we lose (REQUIRED — do not skip)
- **Alternatives Considered**: What other approaches were considered and why rejected (REQUIRED)

See `hyperfleet/components/sentinel/sentinel.md` for a reference example.
See `hyperfleet/components/CLAUDE.md` for detailed section requirements.

### Standards Documents

Every standard document must follow the pattern: Overview → Standard → Examples → Enforcement → References.
Use RFC 2119 language (MUST/SHOULD/MAY). See `hyperfleet/standards/CLAUDE.md` for guidelines.

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

## Commit Standards

This repository follows the [HyperFleet Commit Standard](hyperfleet/standards/commit-standard.md).

Format: `HYPERFLEET-XXX - <type>: <subject>`

Common types for this repo: `docs`, `chore`, `ci`

Examples:

```
HYPERFLEET-123 - docs: add broker component design document
HYPERFLEET-456 - docs: update sentinel trade-offs section
chore: fix broken links in hyperfleet/README.md
```

---

## Paying Down Technical Debt

When a previously documented debt item is resolved, update the component document:

```markdown
### Technical Debt Incurred
- ~~**No retry logic**: Adapters don't retry failed operations~~
  - **Status**: Resolved in #123
  - **Resolution**: Added exponential backoff retry logic
```

Then update the `Last Updated` date and include a note in your PR description.

---

## Questions?

- Slack: [#hcm-hyperfleet-team](https://redhat.enterprise.slack.com/archives/hcm-hyperfleet-team)
- Open a PR with your changes — discussion is welcome in PR comments
- See [README.md FAQ](README.md#faq) for common questions about document structure
