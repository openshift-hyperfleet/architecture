# HyperFleet MVP - Working Agreement

**Status**: Historical
**Owner**: HyperFleet MVP Team
**Last Updated**: 2026-03-25

> Defines the working agreements for the HyperFleet MVP development team of ~12 engineers across two global teams. Covers development process, code review norms, meeting cadence, and communication channels used during the MVP phase. This document is historical — the MVP is complete and team processes have evolved.

---

**Date**: October 31, 2024
**Status**: Active
**Team**: HyperFleet MVP (~12 engineers across 2 global teams)

---

## Purpose

This document defines how we work together to deliver the HyperFleet MVP. Our approach prioritizes **engineer empowerment**, **lightweight process**, and **quality delivery**.

### MVP-Specific Agreement

**This working agreement is valid for the 12-week MVP phase.**

During MVP, we intentionally use a **lightweight, flexible process** to:
- Move fast and learn quickly
- Empower engineers to make decisions
- Minimize ceremony and maximize velocity
- Focus on delivering value

**Post-MVP**: After the 12-week MVP period, we will establish more formal processes based on what we learn:
- Refined collaboration practices
- Formal review and approval workflows
- Enhanced governance for architecture decisions
- Operational processes for production support

**We're learning by doing.** This agreement will evolve based on our experience during MVP delivery.

---

## Core Principles

### 1. Loose Process, High Trust
We operate with a **lightweight, flexible process** for MVP delivery:
- Minimal ceremony, maximum velocity
- Trust engineers to make the right decisions
- Adapt the process as we learn
- Focus on delivering value, not following process

### 2. Engineer Empowerment
**All engineers are empowered to make decisions** within their work:
- Technical implementation choices
- Architecture decisions within their scope
- Tooling and library selections
- Refactoring and optimization approaches

**You don't need permission to do the right thing.**

### 3. Decision-Making Philosophy
- **Make decisions locally**: If it affects your work, you decide
- **Consult when helpful**: Seek input from teammates when beneficial
- **Escalate when needed**: Bring architectural or cross-team impacts to the group
- **Document trade-offs**: Record significant decisions (see below)

---

## Source of Truth: Jira

### Jira Tickets Are Our Contract
- **Jira tickets are the single source of truth** for what we're building
- Each ticket contains **acceptance criteria** that define success
- Engineers should **strive to meet all acceptance criteria**
- If acceptance criteria are unclear or incomplete, update them before starting work

### Handling Trade-offs
When you need to make a trade-off that affects acceptance criteria:

1. **Document the trade-off** in the architecture repo
   - What was the original acceptance criteria?
   - What trade-off did you make?
   - Why was this trade-off necessary?
   - What is the impact?

2. **Update the ticket** to reflect the actual delivery
   - Modify acceptance criteria if needed
   - Add a comment explaining the change
   - Tag relevant stakeholders if the trade-off is significant


**Example**:
```
Original AC: "Adapter supports retry with exponential backoff up to 10 attempts"
Trade-off: "Implemented retry with exponential backoff up to 5 attempts"
Reason: "Testing showed 5 attempts is sufficient for 99% of failure cases.
         10 attempts would delay failure detection beyond acceptable SLA."
Impact: "Reduces max retry time from 17 minutes to 5 minutes."
```

---

## Definition of Done

Our definition of done is simple and non-negotiable:

### ✅ Code
- Implementation meets acceptance criteria (or documented trade-offs)
- Code is production-ready (error handling, logging, etc.)
- Follows established patterns and conventions
- Passes CI pipeline (build, lint, security scans)

### ✅ Tests
- **Unit tests** for core logic (≥80% coverage target)
- **Integration tests** where components interact
- **E2E tests** for critical user flows (where applicable)
- All tests passing in CI

### ✅ Documentation
- **Code documentation**: Comments for complex logic, docstrings for public APIs
- **Usage documentation**: How to use/operate the feature
- **Architecture updates**: See "Architecture Repo Sync" below

**If any of these three elements are missing, the work is not done.**

---

## Architecture Repo Sync

### When to Update the Architecture Repo
**Update the architecture repo when closing a ticket** if the work:
- Changes system architecture or design
- Adds/removes/modifies components or services
- Changes APIs, events, or contracts
- Introduces new patterns or approaches
- Makes significant technical decisions
- Affects deployment, operations, or configuration

**If your work changes how the system works, update the architecture repo.**

### What to Document
When updating the architecture repo (`/architecture/hyperfleet/`):

1. **Design decisions**: Why you chose this approach
2. **Architecture changes**: New components, modified flows, updated diagrams
3. **API/Event changes**: Contract updates, new endpoints, event schema changes
4. **Configuration changes**: New config options, environment variables, deployment changes
5. **Operational impacts**: Monitoring, alerting, runbook updates

### Where to Document
- **`/architecture/hyperfleet/architecture/`**: System design, component architecture
- **`/architecture/hyperfleet/components/`**: Component-specific documentation
- **`/architecture/hyperfleet/docs/`**: Operational docs, runbooks, guides
- **`/architecture/hyperfleet/mvp/`**: MVP-specific decisions and scope

### How to Keep in Sync
1. **Before closing the ticket**: Review if architecture repo needs updates
2. **Update the repo**: Make necessary documentation changes
3. **Link in ticket**: Add link to architecture repo commit/PR in Jira ticket
4. **Close the ticket**: Mark as done once code, tests, docs, and architecture repo are all updated

**The architecture repo should always reflect the current state of HyperFleet.**

---

## Decision Documentation

### When to Document Decisions
Document significant decisions in the architecture repo when:
- The decision has architectural impact
- The decision affects multiple components/teams
- The decision involves a trade-off worth remembering
- Future engineers would benefit from understanding the "why"

### How to Document Decisions
The architecture repo README provides comprehensive guidance on documenting decisions, trade-offs, and technical debt.

**See**: [Architecture Repo README](../../README.md) for:
- Component design document templates (required sections)
- Trade-offs and alternatives templates
- Technical debt tracking
- Living document practices
- Review and merge process

**Quick Links**:
- [Document Types](../../README.md#document-types) - Architecture, components, guides
- [Tracking Trade-offs](../../README.md#tracking-trade-offs-and-technical-debt) - Required trade-offs template
- [Living Documents](../../README.md#living-documents) - How to update documents
- [Review Process](../../README.md#review-and-merge-process) - How to submit changes

---

## Collaboration Practices

### Communication
- **Async-first**: Use Jira, Slack, and architecture repo for decisions
- **Sync when helpful**: Jump on a call when async is inefficient
- **Document outcomes**: Record decisions from sync discussions

### Code Review
- **Review for quality**: Look for bugs, edge cases, performance issues
- **Review for learning**: Share knowledge and patterns
- **Review for consistency**: Ensure patterns align across the codebase
- **Empower the author**: Trust engineers to make the right calls

### Asking for Help
- **Ask early**: Don't struggle alone
- **Ask publicly**: Share questions in team channels (helps everyone learn)
- **Ask specifically**: Include context, what you've tried, what you need

---

## Quality Expectations

### Production-Ready Means:
- **Works reliably**: Not just "works once in ideal conditions"
- **Handles errors**: Graceful degradation, clear error messages
- **Observable**: Logs, metrics, traces for debugging
- **Secure**: No vulnerabilities, secrets managed properly
- **Maintainable**: Clear code, good patterns, documented trade-offs

### Testing Expectations:
- **Test what matters**: Focus on critical paths and edge cases
- **Test at the right level**: Unit tests for logic, integration for interactions, E2E for flows
- **Make tests reliable**: No flaky tests in CI
- **Keep tests fast**: Fast feedback loop for developers

---

## Working Across Time Zones

With 2 global teams, we optimize for async collaboration:

### Handoffs
- **Clear state in Jira**: Update tickets before end of day
- **Document blockers**: Call out what's blocking progress
- **Tag for help**: Mention teammates who can unblock you

### Overlaps
- **Leverage overlap time**: Schedule sync discussions during overlap hours
- **Record decisions**: Document outcomes for teammates in other zones
- **Async reviews**: Don't block on reviews, keep PRs flowing

---

## Continuous Improvement

### Retrospectives
- Regular retrospectives to reflect and improve
- What's working? What's not?
- Adjust this working agreement as needed

### Experiment and Learn
- Try new approaches
- Share learnings with the team
- Update practices based on what we learn

**This working agreement is a living document. If something isn't working, let's change it.**

---

## Summary

**MVP-Specific**: This agreement is valid for the 12-week MVP phase. Post-MVP, we'll establish more formal processes based on what we learn.

| Principle | Practice |
|-----------|----------|
| **Timeframe** | 12-week MVP phase (lightweight), Post-MVP (more formal) |
| **Process** | Loose process, high trust, adapt as we learn |
| **Decisions** | Engineers empowered to decide, escalate when needed |
| **Source of Truth** | Jira tickets with acceptance criteria |
| **Trade-offs** | Document in Jira, update acceptance criteria |
| **Definition of Done** | Code + Tests + Docs |
| **Architecture Sync** | Update architecture repo when closing tickets |
| **Quality** | Production-ready from day one |
| **Collaboration** | Async-first, document outcomes, ask for help |

---

**Remember**: We trust you to make good decisions, deliver quality work, and keep the team informed. This working agreement exists to support you, not constrain you.

**We're learning by doing**: This lightweight process is intentional for MVP. We'll refine our practices based on what we learn over the next 12 weeks.


