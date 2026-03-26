# Claude Code Guidelines for HyperFleet Architecture Repository

## Repository Purpose

This is a **documentation-only repository** - the single source of truth for all HyperFleet architectural documentation. There is no application code here.

All documents are **living documents** that evolve with design and implementation. Git tracks change history.

## Repository Structure

```
├── README.md                      # Main guide - required reading
├── hyperfleet/
│   ├── README.md                  # System overview (30,000 feet view)
│   ├── components/                # Component design decisions
│   │   ├── adapter/               # Adapter architecture
│   │   ├── api-service/           # API service design
│   │   ├── broker/                # Message broker design
│   │   ├── claude-code-plugin/    # Claude Code plugin
│   │   └── sentinel/              # Sentinel service design
│   ├── adr/                       # Architecture Decision Records
│   ├── deprecated/                # Archived documents (MVP, old adapters, deployment)
│   ├── docs/                      # Implementation guides
│   ├── standards/                 # Prescriptive standards (must follow)
```

## Document Status Values

- **Draft**: Initial design, still being refined
- **Active**: Current implementation
- **Deprecated**: No longer used (link to replacement)

## Use only Active status pages

Unless asked explicitly otherwise, discard any document with `Status` field different than `Active`

Unless asked explicitly otherwise, discard any document with "deprecated" in the name or under a folder with "deprecated" in the name

## Document Header Format

All documents must start with metadata fields, at the beginning of the file

```markdown
---
Status: Active
Owner: Team Name
Last Updated: YYYY-MM-DD
---

# Document Title
```

Update "Last Updated" only for meaningful changes (design changes, new sections, trade-offs modified), not typos or formatting.

## Required Diagram Format

Use **Mermaid diagrams** in all architecture and component documents:
- Text-based, version control friendly
- Renders natively in GitHub markdown
- Consistent across all docs

## Key Navigation Files

| I want to...                    | Start here                                    |
|---------------------------------|-----------------------------------------------|
| Understand HyperFleet           | `hyperfleet/README.md` |
| Design a new component          | `hyperfleet/components/` + see README         |
| Write an implementation guide   | `hyperfleet/docs/`                            |
| Find trade-offs                 | Component docs → "Trade-offs" section         |
| Track technical debt            | Search "Technical Debt Incurred"              |
| See complete component example  | `hyperfleet/components/sentinel/sentinel.md`  |

## Commit Message Format

```
HYPERFLEET-XXX - <type>: <subject>
```

Examples:
- `HYPERFLEET-123 - docs: add sentinel component design`
- `HYPERFLEET-456 - docs: update API trade-offs section`

More info on [commit-standard.md](./hyperfleet/standards/commit-standard.md)

## What Claude Should NOT Do

1. **Do not create code files** - This is a documentation-only repo
2. **Do not skip Trade-offs section** - Every component doc MUST have Trade-offs
3. **Do not skip Alternatives Considered** - Required alongside Trade-offs
4. **Do not add unnecessary files** - No README duplicates, no extra config files
5. **Do not use vague language** - Be specific and quantify impact
6. **Do not create documentation without required sections** - Check README for requirements

## Writing Guidelines

### Be Specific
- Bad: "This makes things faster"
- Good: "This reduces API latency from 200ms to 50ms"

### Quantify Impact
- Bad: "This improves performance"
- Good: "This reduces memory usage by 40%"

### Document Trade-offs Honestly
- Bad: "This is better in every way"
- Good: "This simplifies code but increases latency by 10ms"

## Related CLAUDE.md Files

- `hyperfleet/standards/CLAUDE.md` - Standards document conventions
- `hyperfleet/components/CLAUDE.md` - Component design requirements
