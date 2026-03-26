---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-03-26
---

# Architecture Decision Records (ADRs)

> This directory contains Architecture Decision Records (ADRs) for HyperFleet. Each ADR captures a significant decision, why it was made, and what was rejected.

---

## When to Write an ADR

Write an ADR when a decision:

- Affects multiple components or teams
- Is hard to reverse
- Has meaningful trade-offs between alternatives
- Would leave future contributors wondering "why did they do it this way?"

Do **not** write an ADR for implementation details, config changes, or decisions that are obvious from the code.

---

## Naming Convention

```
NNNN-short-title.md
```

Examples: `0001-use-cloudevents-for-adapter-pulses.md`, `0002-sentinel-pull-model.md`

Numbers are sequential. Use the next available number.

---

## Template

Copy this into your new ADR file:

```markdown
---
Status: Proposed | Accepted | Superseded by ADR-NNNN | Deprecated
Owner: <team>
Last Updated: YYYY-MM-DD
---

# NNNN — Title of Decision

## Context

What is the problem or situation forcing this decision?
One short paragraph.

## Decision

What did we decide? State it plainly.

## Consequences

**Gains:** What becomes easier or better.
**Trade-offs:** What becomes harder or worse.

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| Option A    | Reason       |
| Option B    | Reason       |
```

---

## ADR Index

| ADR | Title | Status | Date |
|-----|-------|--------|------|
| — | *(no ADRs yet)* | — | — |
