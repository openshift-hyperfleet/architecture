---
Status: Active
Owner: Architecture Team
Last Updated: 2025-11-07
---

# HyperFleet Architecture Repository

---

## Overview


This repository serves as the **single source of truth** for all architectural documentation related to HyperFleet. All documents are **living documents** that evolve as the design and implementation progress.

**Key Principle**: All significant architectural decisions must be documented here with their trade-offs to track technical debt and enable informed future decisions.

---

## Repository Access & MVP Process

**Current Phase**: MVP Development

**Access & Permissions**:
- All developers in the HyperFleet team are granted **write access** to this repository
- To support quick iteration during MVP, developers have **approve and merge access** if there are no objections from peers
- This temporary process enables rapid documentation of decisions and scope changes

**Repository Usage**:
- This repository primarily records:
  - Architectural decisions and their rationale
  - Trade-offs we're accepting during MVP
  - Changes to MVP scope and priorities
  - Technical debt we're consciously incurring

**Post-MVP**:
- Once MVP is complete, we will establish official processes for:
  - Repository access management
  - PR review requirements
  - Approval workflows
  - Documentation governance

**During MVP, prioritize speed over process while maintaining clear documentation of decisions.**

---

## Repository Structure

```
architecture/
├── README.md                      # This file - repository guide
├── CONTRIBUTING.md                # How to contribute to this repository
├── CLAUDE.md                      # Claude Code guidelines for AI-assisted workflows
├── OWNERS                         # Repository ownership
├── hack/                          # Utility scripts
└── hyperfleet/                    # HyperFleet-specific architecture
    ├── README.md                  # HyperFleet system overview and architecture summary
    ├── components/                # Component-level design decisions
    │   ├── CLAUDE.md              # Component document guidelines
    │   ├── adapter/               # Adapter framework and implementations
    │   │   ├── framework/         # Core adapter design docs
    │   │   ├── maestro-integration/
    │   │   ├── deprecated/        # Deprecated adapters
    │   ├── api-service/           # HyperFleet API service design
    │   ├── broker/                # Message broker design
    │   ├── claude-code-plugin/    # Claude Code plugin spike
    │   └── sentinel/              # Sentinel reconciliation service
    ├── adr/                       # Architecture Decision Records
    ├── docs/                      # Implementation guides and features
    │   └── templates/             # Document templates
    ├── standards/                 # Prescriptive engineering standards
```

---

## Document Types

### 1. Architecture Overview (`hyperfleet/README.md`)

**Purpose**: High-level system architecture (30,000 feet view)

**Contents**:
- System overview and goals
- Component relationships and interactions
- Data flows and communication patterns
- Deployment topology
- Cross-cutting concerns (security, scalability, observability)

**When to update**: Major system redesigns, new architecture proposals

**Living Document**: Update as system architecture evolves

---

### 2. Component Design Documents (`components/`)

**Purpose**: Detailed design for individual components

**Required Sections**:
- **What**: Component purpose and responsibilities
- **Why**: Problem it solves and context
- **How**: Technical implementation approach
- **Trade-offs**: What we gain vs what we lose (REQUIRED)
- **Dependencies**: What this component relies on
- **Interfaces**: APIs, events, data contracts
- **Configuration**: How to configure the component
- **Alternatives Considered**: What we didn't choose and why

**When to create**: New component introduction, major component redesign

**Living Document**: Update as component design evolves during implementation

---

### 3. Implementation Guides (`docs/`)

**Purpose**: Practical guides for developers and operators

**Contents**:
- Step-by-step instructions
- Code examples and patterns
- Configuration examples
- Troubleshooting tips
- Best practices

**When to create**: New feature implementation, operational procedures

**Living Document**: Keep examples current as APIs and configurations change

---

## Tracking Trade-offs and Technical Debt

**Critical Requirement**: Every component design document MUST include both:
1. **"Trade-offs" section** - What we gain and lose with the chosen approach
2. **"Alternatives Considered" section** - What other options existed and why we didn't choose them

These sections work together to provide full context for architectural decisions.

### Trade-offs Template

```markdown
## Trade-offs

### What We Gain
- ✅ Benefit 1 with measurable impact
- ✅ Benefit 2 with context
- ✅ Benefit 3

### What We Lose / What Gets Harder
- ❌ Cost 1 - Technical debt we're accepting
- ❌ Cost 2 - Capability we're giving up
- ⚠️ Risk 1 - What could go wrong

### Technical Debt Incurred
- **Debt Item 1**: Description of shortcut taken, impact, remediation plan
- **Debt Item 2**: What we should fix in the future

### Acceptable Because
- Reason 1 why the trade-off makes sense
- Reason 2 (e.g., time constraints, simplicity, MVP scope)
```

### Example: Sentinel Direct Broker Publishing

```markdown
## Trade-offs

### What We Gain
- ✅ Simpler architecture (5 components vs 6)
- ✅ Lower latency (no outbox polling)
- ✅ Easier to understand and maintain

### What We Lose / What Gets Harder
- ❌ Eventual consistency (not guaranteed delivery like outbox pattern)
- ❌ No transactional event creation with database writes
- ⚠️ Risk of events lost if broker is down and Sentinel crashes

### Technical Debt Incurred
- **No event delivery guarantees**: If Sentinel publishes to broker and crashes before updating internal state, we may duplicate events
  - **Impact**: Low (adapters are idempotent)
  - **Remediation**: Post-MVP, add event deduplication in adapters or message broker

### Acceptable Because
- MVP scope prioritizes simplicity over perfect consistency
- Cluster provisioning use case tolerates eventual consistency
- Adapters are designed to be idempotent
```

---

## Living Documents

All documents in this repository are **living documents**:

- **Update freely** as design evolves
- **Mark status** to indicate maturity (Draft, Active, Deprecated)
- **Track changes** via git commit history
- **Pay down debt** by updating "Technical Debt Incurred" sections

### Document Status

- **Draft**: Initial design, still being refined
- **Active**: Current implementation
- **Deprecated**: No longer used (link to replacement)

### Updating Documents

**When to update "Last Updated" date:**

Update the date for **meaningful changes only**:
- ✅ Component design changes
- ✅ New sections added
- ✅ Trade-offs modified
- ✅ Status changes (Draft → Active, Active → Deprecated)
- ✅ Technical debt paid down or added
- ❌ NOT for typos, formatting, or minor clarifications

**Note**: Git commit history tracks all changes. The "Last Updated" date is a quick visual indicator of the last **significant** revision.

**Steps for meaningful updates:**
1. Update the relevant sections
2. Update "Last Updated" date at the top of the document
3. If paying down technical debt, ~~strikethrough~~ the debt item and link to PR

Example of paying down technical debt:
```markdown
### Technical Debt Incurred
- ~~**No retry logic**: Adapters don't retry failed operations~~
  - **Status**: Resolved in #123
  - **Resolution**: Added exponential backoff retry logic
```

### Review and Merge Process

**MVP Process (Current)**:

All HyperFleet team developers have approve and merge access. **Goal**: Move fast while keeping the team informed.

**How to submit and merge changes:**

1. **Create a PR** with your documentation updates
2. **Add a clear description** of what changed and why
3. **Post the PR link** in Slack: #hcm-hyperfleet-team for team visibility
4. **Wait 24 hours** for peer review and objections (accounts for time zone differences between regions)
   - For urgent changes, use judgment but ensure the change is well-documented with clear rationale
   - For major architectural changes, strongly consider waiting for at least one or two Technical Leader reviews
5. **Merge when ready**: Once you have approval from peers and no objections after the 24-hour window, you may merge

**Post-MVP Process** (to be established):
- Formal approval requirements based on change type
- Required reviewers for different document categories
- Defined merge timelines and escalation paths

---

## Navigation Guide

### I want to...

**Understand HyperFleet architecture**
→ Start with `hyperfleet/README.md`

**Design a new component**
→ Add document to `hyperfleet/components/` with required sections (see "Component Design Documents")

**Write an implementation guide**
→ Add guide to `hyperfleet/docs/` with step-by-step instructions

**Find trade-offs for a component**
→ Read component document in `hyperfleet/components/`, look for "Trade-offs" section

**Track technical debt**
→ Search all component docs for "Technical Debt Incurred"

**Look up a HyperFleet term or acronym**
→ See `hyperfleet/docs/glossary.md`

**Find or record an architecture decision**
→ See `hyperfleet/adr/` — follow the template in `hyperfleet/adr/README.md`

---

## Writing Guidelines

### Trade-offs and Alternatives Are Required

Every component document MUST document both trade-offs AND alternatives considered. These go hand-in-hand:
- **Trade-offs** explain what you gain and lose with your chosen approach
- **Alternatives** explain what other options you considered and why you rejected them

Without alternatives, trade-offs lack context. Why did you accept this trade-off? What were you comparing against?

### Be Specific

❌ Bad: "This makes things faster"
✅ Good: "This reduces API latency from 200ms to 50ms"

### Quantify Impact

❌ Bad: "This improves performance"
✅ Good: "This reduces memory usage by 40%"

### Document Trade-offs Honestly

❌ Bad: "This is better in every way"
✅ Good: "This simplifies code but increases latency by 10ms"

### Include Diagrams

All architecture and component documents should include Mermaid diagrams.

---

## Diagram Guidelines

### Use Mermaid for Diagrams

All diagrams should use Mermaid syntax for:
- Maintainability (text-based, version control friendly)
- GitHub rendering (renders in markdown)
- Consistency

---

## Quality Standards

### Component Design Documents Must Have

- [ ] Clear "What" section (component purpose)
- [ ] "Why" section (problem context)
- [ ] "How" section (implementation approach)
- [ ] **"Trade-offs" section** (what we gain vs lose) - REQUIRED
- [ ] **"Alternatives Considered" section** - REQUIRED (trade-offs only exist because you chose one approach over alternatives)
- [ ] Dependencies clearly listed
- [ ] Interfaces documented (APIs, events)
- [ ] Configuration examples
- [ ] At least one diagram

**Note**: Trade-offs and Alternatives go hand-in-hand. If you document trade-offs, you MUST document what alternatives you considered and why you didn't choose them.

### Guides Must Have

- [ ] Clear target audience
- [ ] Step-by-step instructions
- [ ] Code/configuration examples
- [ ] Troubleshooting section
- [ ] Links to related documents

---

## Searching for Technical Debt

Use these commands to find technical debt across documents:

```bash
# Find all technical debt items
grep -r "Technical Debt" hyperfleet/components/

# Find all trade-offs
grep -r "## Trade-offs" hyperfleet/

# Find all "What We Lose" sections
grep -r "What We Lose" hyperfleet/

# Find deprecated documents
grep -r "Status: Deprecated" hyperfleet/
```

---

## Examples

### Good Component Document

See: `hyperfleet/components/sentinel/sentinel.md`
- Clear purpose and responsibilities
- Detailed trade-offs section
- Alternatives considered
- Technical debt identified
- Diagrams included

### Good Guide

See: `hyperfleet/docs/status-guide.md`
- Step-by-step instructions
- Code examples
- Clear troubleshooting

---

## FAQ

**Q: Do I need to document every implementation detail?**
A: No. Focus on architectural decisions and component design. Implementation details belong in code comments and inline documentation.

**Q: What if I don't know the trade-offs yet?**
A: Document what you know and mark unknowns:
- "⚠️ Unknown: Performance impact needs measurement"
- "⚠️ To investigate: Scalability limits"

Update the document as you learn more.

**Q: How detailed should component docs be?**
A: Detailed enough that someone unfamiliar with the component can:
- Understand its purpose
- Understand the trade-offs
- Start implementing or operating it

Avoid implementation minutiae (that's for code comments).

**Q: Can I update someone else's document?**
A: Yes! These are living documents. Update freely as design evolves. Use git history to track changes.

**Q: When should I create a new document vs update existing?**
A: Update existing documents when:
- Refining the existing design
- Adding implementation details
- Paying down technical debt
- Fixing errors or clarifications

Create new documents when:
- Adding a completely new component
- Major redesign that deprecates old approach
- New feature guide or operational procedure

---

## Related Resources

- [C4 Model](https://c4model.com/) - Architecture diagram inspiration
- [Mermaid Documentation](https://mermaid.js.org/) - Diagram syntax
- [Technical Debt Metaphor](https://www.martinfowler.com/bliki/TechnicalDebt.html) - Understanding technical debt

---

## Contact

**Questions or suggestions?**
- Slack: [#hcm-hyperfleet-team](https://redhat.enterprise.slack.com/archives/hcm-hyperfleet-team)
- Architecture Team: Open a PR or post in the Slack channel above
- Pull requests welcome for documentation updates

---

