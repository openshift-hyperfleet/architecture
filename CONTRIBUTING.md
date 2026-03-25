# Contributing to HyperFleet Architecture

This repository is a **documentation-only** repository — there is no application code here.
Contributing means adding or updating architectural documents, standards, and design decisions.

---

## Development Setup

```bash
# 1. Clone the repository
git clone https://github.com/openshift-hyperfleet/architecture.git
cd architecture

# 2. Install linting tools (optional, but recommended before submitting PRs)
npm install -g markdownlint-cli2   # Markdown linting
pip install yamllint               # YAML linting
```

**First-time setup notes:**

- No build step required — this is a documentation repository
- The CI pipeline runs `markdownlint`, `yamllint`, and link checking automatically on PRs
- Run linting locally before pushing to catch issues early

---

## Repository Structure

See [README.md](README.md) for the full directory layout. Key directories:

```
architecture/
├── hyperfleet/
│   ├── architecture/    # System-level architecture documents
│   ├── components/      # Component design documents (design decisions, trade-offs)
│   ├── docs/            # Implementation guides and operational docs
│   ├── standards/       # Prescriptive standards all HyperFleet repos must follow
│   ├── deployment/      # Deployment guides (GKE, etc.)
│   ├── e2e-testing/     # E2E testing strategy documents
│   ├── mvp/             # Historical MVP scope and agreements
│   └── test-release/    # Test and release process documents
├── README.md
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

### Required Document Header

Every document **must** start with:

```markdown
# Document Title

**Status**: Active
**Owner**: Team Name
**Last Updated**: YYYY-MM-DD

> [2-4 sentence summary of what this document covers and the key decision or purpose]

---
```

### Component Documents

Every component design document **must** include:

- **What & Why**: Purpose and problem it solves
- **How**: Technical implementation with at least one Mermaid diagram
- **Trade-offs**: What we gain vs. what we lose (REQUIRED — do not skip)
- **Alternatives Considered**: What other approaches were considered and why rejected (REQUIRED)

See `hyperfleet/components/sentinel/sentinel.md` for a reference example.
See `hyperfleet/components/CLAUDE.md` for detailed guidelines.

### Standards Documents

Every standard document must follow the pattern: Overview → Standard → Examples → Enforcement → References.
Use RFC 2119 language (MUST/SHOULD/MAY). See `hyperfleet/standards/CLAUDE.md` for guidelines.

---

## Testing / Linting

```bash
# Run markdown linting
markdownlint-cli2 "**/*.md"

# Run YAML linting
yamllint .

# Check for broken links (CI runs this automatically)
# Install: npm install -g markdown-link-check
find . -name "*.md" | xargs -I{} markdown-link-check {}
```

The CI pipeline enforces these checks on all PRs. Fix any lint errors before requesting review.

---

## Submitting Changes

1. **Create a branch** from `main`:

   ```bash
   git checkout -b HYPERFLEET-XXX-brief-description
   ```

2. **Make your changes** following the document standards above

3. **Commit** following the [commit standard](hyperfleet/standards/commit-standard.md):

   ```
   HYPERFLEET-XXX - docs: brief description of change
   ```

4. **Open a PR** and post the link in [#hcm-hyperfleet-team](https://redhat.enterprise.slack.com/archives/hcm-hyperfleet-team)

5. **Wait 24 hours** for team review (accounts for time zone differences)

6. **Merge** once approved with no objections

---

## Commit Standards

This repository follows the [HyperFleet Commit Standard](hyperfleet/standards/commit-standard.md).

Format: `HYPERFLEET-XXX - <type>: <subject>`

Common types for this repo: `docs`, `chore`, `ci`

Examples:

```
HYPERFLEET-123 - docs: add broker component design document
HYPERFLEET-456 - docs: update sentinel trade-offs section
chore: fix broken links in architecture-summary.md
```

---

## Questions?

- Slack: [#hcm-hyperfleet-team](https://redhat.enterprise.slack.com/archives/hcm-hyperfleet-team)
- Open a PR with your changes — discussion is welcome in PR comments
