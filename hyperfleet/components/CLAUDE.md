# Claude Code Guidelines for HyperFleet Component Documents

---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-03-25
---

## What Component Documents Are

Component documents are **DESIGN documents** - they describe architectural decisions for individual components. Unlike standards, they are not prescriptive rules but rather documentation of how specific components work and why.

## REQUIRED Sections

Every component document MUST include these sections. **DO NOT SKIP ANY.**

### 1. What & Why

```markdown
## What & Why

**What**: Component purpose and responsibilities

**Why**: Problem it solves, context, what happens without it
```

### 2. How (with Mermaid diagrams)

```markdown
## How

[Technical implementation approach]

\`\`\`mermaid
flowchart TD
    A[Start] --> B[Process]
    B --> C[End]
\`\`\`
```

### 3. Trade-offs (DO NOT SKIP)

**This section is MANDATORY.** Every design involves trade-offs. Document them honestly.

```markdown
## Trade-offs

### What We Gain
- ✅ Benefit with measurable impact
- ✅ Another benefit with context

### What We Lose / What Gets Harder
- ❌ Cost - Technical debt we're accepting
- ❌ Capability we're giving up
- ⚠️ Risk - What could go wrong

### Technical Debt Incurred
- **Debt Item**: Description, impact, remediation plan

### Acceptable Because
- Reason why the trade-off makes sense for MVP/timeline/scope
```

### 4. Alternatives Considered (DO NOT SKIP)

**This section is MANDATORY.** Trade-offs only make sense when compared to alternatives.

```markdown
## Alternatives Considered

### [Alternative Name]
**What**: Brief description of the alternative approach
**Why Rejected**: Specific reason why this wasn't chosen
```

## Component Subdirectories

Components are organized by type:

| Directory | Purpose |
|-----------|---------|
| `adapter/` | Adapter implementations (validation, cloud providers, etc.) |
| `api-service/` | HyperFleet API service design |
| `broker/` | Message broker architecture |
| `claude-code-plugin/` | Claude Code plugin spike and brainstorming |
| `sentinel/` | Sentinel reconciliation service |

## Quantification Guidelines

Be specific, not vague:

| Bad | Good |
|-----|------|
| "Faster" | "Reduces latency from 200ms to 50ms" |
| "More scalable" | "Supports 10x more concurrent requests" |
| "Simpler" | "Reduces components from 6 to 5" |
| "Better" | "Eliminates single point of failure" |

## Status Reporting Pattern

When documenting component status fields, use this pattern:

```markdown
### Status Conditions

| Condition | Meaning |
|-----------|---------|
| Available | Component is deployed and reachable |
| Applied | Desired state has been reconciled |
| Health | Component is operating normally |
```

## Updating Existing Documents

When updating component docs:

1. Read the existing document first
2. Update relevant sections
3. Update "Last Updated" date for meaningful changes
4. If paying down technical debt, strikethrough the item and link to PR:

```markdown
- ~~**No retry logic**: Adapters don't retry failed operations~~
  - **Status**: Resolved in #123
```

## Example: Component Document

See `sentinel/sentinel.md` for an example with:
- Clear What & Why section
- Detailed How section with diagrams
- Test scenarios documented

**Note**: sentinel.md predates these guidelines and does not yet include Trade-offs or Alternatives Considered sections.

## Common Mistakes to Avoid

1. **Skipping Trade-offs** - "This is clearly better" is not acceptable
2. **Skipping Alternatives** - "This was obvious" is not acceptable
3. **Vague benefits** - Quantify or explain specifically
4. **Missing diagrams** - All components need at least one Mermaid diagram
5. **Forgetting dependencies** - Document what the component relies on
6. **Missing configuration** - Consider documenting how to configure the component (if applicable)
