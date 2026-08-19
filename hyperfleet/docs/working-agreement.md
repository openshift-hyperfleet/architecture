---
Status: Active
Owner: HyperFleet Team
Last Updated: 2026-08-18
---

# HyperFleet Working Agreement

## Purpose

This document defines how the HyperFleet team works together. It captures our processes for delivering work from ticket to merge, reviewing code, maintaining architecture documentation, and making technical decisions.

This is a **living document**. Our processes will evolve as we learn and grow. We will formalize processes as needed when we have production customers. Until then, we stay lightweight and adapt.

> **Supersedes**: [MVP Working Agreement](../deprecated/mvp/mvp-working-agreement.md) (Historical)

---

## Definition of Ready

Before picking up a ticket, confirm:

- [ ] Acceptance criteria are written and clear
- [ ] Dependencies are identified (ticket has no blockers)
- [ ] Open questions are answered
- [ ] Work is sized to complete within a sprint
- [ ] Required JIRA fields set (see [Ticket Hygiene Standard](../standards/ticket-hygiene.md))

If a ticket is not ready, update it before starting work. If acceptance criteria appear out of date, raise it with the [Epic Owner](#work-item-ownership) — they are responsible for keeping acceptance criteria current across their Epic.

---

## Work Item Ownership

Every work item has a clear owner. Ownership is accountability for results — not a promise to do all the work alone. Owners coordinate; they don't work in isolation.

The guiding principle: **decisions flow down to the lowest level that has the context to make them well.** Architectural direction stays with the Architect; execution decisions belong to the Tech Lead; each Epic is delivered by its Epic Owner.

| Level | Owner | Owns |
| ----- | ----- | ---- |
| Feature | **Architect + Tech Lead** (co-owned) | Architect: direction, constraints, success criteria. Tech Lead: scope, priority, cross-epic coordination and staffing |
| Sprint / cross-Epic execution | **Tech Lead** | Sprint planning, commitment, capacity, and unblocking; ensures Epic Owners deliver |
| Epic | **Epic Owner** (a named engineer) | Breaking down and delivering one Epic; tracking and reporting its progress |
| Story / Task | **Assignee** | Delivering the individual work item |

### Two kinds of ownership

Ownership runs on two axes that coexist:

- **Work-item ownership** — who is accountable for *delivering a specific piece of work*: the Feature Owners, the Epic Owner, and the story assignees below. Temporary, tied to the work item.
- **Domain ownership** — who is accountable for the *standing technical health and direction of a component* (API, Sentinel, Adapter, E2E, Release, Observability). The **Domain Owner** is the first escalation point and the decision-maker for technical approach within their domain. Standing, not tied to a single work item.

The two intersect during delivery: the **Epic Owner drives the Epic to done**, but **technical-approach decisions defer to the Domain Owner** of the affected component (and to the Architect for cross-component contracts). Domain ownership — its Contributor → Key Contributor → Owner progression — and the full role ladder are defined in the [HyperFleet Team Operating Model](https://docs.google.com/document/d/1Pqq9EdWGBuMR00wL7sguZHGFiP5_f4aQ2VPoDcW5HCA/edit?tab=t.bthlqz8tix2a).

This section defines the two roles the team asks about most: the **Feature Owner** and the **Epic Owner**.

### Feature Owner (Level 4)

A Feature delivers customer-facing value within a Quarter/Release and spans several Epics, often across teams. Feature ownership is **shared between the Architect and the Tech Lead**, working as a pair — the Architect owns the direction, the Tech Lead owns getting it delivered across Epics.

The **Architect** is responsible for:

- Setting the Feature's **architectural direction, constraints, and sequencing**
- Owning the **success criteria** — what "good" looks like
- **Co-shaping Epic breakdown** with the Tech Lead and Epic Owner (a conversation, not a sign-off)
- Keeping the **Feature Intent** current when scope, constraints, or success criteria change
- Flagging **cross-domain dependencies** that touch other components or teams

The **Tech Lead** is responsible for:

- Owning the Feature's **scope and priority** — stack-ranking active Features so there is a clear priority order, not a flat list, and stating explicitly when priorities shift and why
- **Cross-epic coordination** — ensuring the Epics under the Feature are staffed and progressing
- Making **cross-team trade-off decisions** when Epics compete for capacity

Neither owner tracks individual stories day to day — that belongs to the Epic Owner and the story assignees.

### Epic Owner (Level 3)

An Epic is the team-specific work needed to deliver (part of) a Feature within a single Release. Each Epic has a **single named owner — an engineer**, not the Tech Lead. Typically the engineer assigned to the Epic's scoping spike becomes its Epic Owner; the Architect and Tech Lead co-shape the breakdown with them.

An Epic Owner is responsible for:

- **Breaking down the Epic** into stories — with architectural direction from the Architect, technical-approach input from the affected Domain Owner(s), and execution input from the Tech Lead. Stories should be ready before sprint planning
- Ensuring stories meet the [Definition of Ready](#definition-of-ready) and keeping **acceptance criteria current** and testable
- Identifying and driving dependencies to resolution
- **Tracking and reporting Epic progress** — the Tech Lead and Architect stay informed because the Epic Owner reports, not because they chase the board
- **Providing clarity** — facilitating a sync-up when needed to resolve open questions or implementation uncertainty
- **Coordinating the demo** — ensuring the engineers who built the work present it at sprint review
- **Facilitating the Epic** so contributors can self-serve (see below)

An Epic Owner does **not** assign stories to engineers and does **not** own the implementation — stories are pull-based, owned by whoever picks them up. The Epic Owner is the person who can answer **"where are we on this?"** at any point.

The **Tech Lead** ensures every active and "up next" Epic has an Epic Owner, that the breakdown is done properly, that stories meet the Definition of Ready, and that progress is tracked — but does **not** own Epics directly. If an Epic Owner isn't tracking or communicating, that's a Tech Lead problem to fix.

#### Facilitating the Epic

The Epic Owner keeps the Epic navigable for anyone who picks up its child work. The primary tool is a pinned Epic comment that tells contributors where to start and in what order — which items have no blockers, which should be taken together by one person, and the delivery sequence. This reduces churn and prevents work from being split in ways that create rework. Keep the comment updated as scope and dependencies change.

A good facilitation comment covers:

- **Start here** — the child items with no blockers
- **Take these together** — items that share a code area or abstraction and should be owned by one person to stay consistent
- **Sequencing** — the order in which items unblock each other

Example of a facilitation comment on an Epic:

> **Picking up tasks? Read this first.**
>
> **Start here — no blockers:**
>
> - HYPERFLEET-1083 — TypeSpec models
> - HYPERFLEET-1084 — Resource data layer (independent of 1083, different repo — just agree on schema names like `ChannelSpec` upfront)
>
> **If you pick up HYPERFLEET-1084 → take 1085 and 1093 too.** They build on each other (data layer → service → delete policies). Same code area, same abstractions. Splitting across people will cause churn.
>
> **If you pick up HYPERFLEET-1086 (channel handler) → take 1087 (version handler) too.** Version handler is the same pattern with parent-scoping added. One person doing both = consistent code.
>
> **HYPERFLEET-1088 (E2E tests) goes last.** Needs all handlers + delete policies done first. Ideally done by whoever built the handlers.
>
> **Sequencing:**
>
> 1. 1083 + 1084 (parallel — different repos, agree on schema names)
> 2. 1085 (needs 1084)
> 3. 1086 + 1093 (parallel, both need 1085)
> 4. 1087 (needs 1086)
> 5. 1088 (needs 1087 + 1093)

### The one-line distinction

- **Feature Owner (Architect + Tech Lead)** — the Architect owns *direction and success criteria*, the Tech Lead owns *scope, priority, and cross-epic coordination*, until the Feature becomes a line item in release notes. Altitude: strategy and coordination.
- **Epic Owner (engineer)** — owns *delivering one Epic*: breakdown, readiness, tracking, and demo, within the release. Altitude: execution of a single Epic.
- Beyond co-owning Features, the **Tech Lead** also owns *sprint execution across Epics*: planning, commitment, capacity, and unblocking, and holds Epic Owners accountable for delivery.

> **See also:** the [HyperFleet Team Operating Model](https://docs.google.com/document/d/1Pqq9EdWGBuMR00wL7sguZHGFiP5_f4aQ2VPoDcW5HCA/edit?tab=t.bthlqz8tix2a) for the full role ladder, Domain Ownership model, decision-making framework, and escalation paths (the canonical source for team roles); the [Sprint Planning — Architect & Tech Lead Roles](https://docs.google.com/document/d/1TV5hNX02fgsHVD_2SHjg9SpmMbPHfiDq1RGLYOz8s3I/edit) document for how these roles interact during sprint planning; and the [Work Assignment Process](https://docs.google.com/document/d/1Pqq9EdWGBuMR00wL7sguZHGFiP5_f4aQ2VPoDcW5HCA/edit?tab=t.dssq8ihx7z3) (a tab of the Operating Model) for ticket assignment, the Epic Owner model, and reactive-work capacity.

---

## Ticket-to-Merge Flow

### 1. Pick Up Work

- Work is tracked in Jira (project: HYPERFLEET)
- Each ticket has **acceptance criteria** that define done
- If acceptance criteria are unclear or missing, update them before starting work (see [Definition of Ready](#definition-of-ready))
- If the ticket is estimated at **5 or more story points**, add a collaborator and discuss the approach before starting work — this helps catch misinterpretations early
- Assign yourself and move the ticket to **In Progress**

### 2. Branch and Develop

- Fork the organisation repo and branch from `main` using the naming convention: `HYPERFLEET-XXX-brief-description`
- Follow the [commit standard](../../hyperfleet/standards/commit-standard.md): `HYPERFLEET-XXX - <type>: <subject>`
- Run linting and tests locally before pushing (`make test-all`, see [CONTRIBUTING.md](../../CONTRIBUTING.md#testing--linting))
- Run an AI review locally using `/review-pr` from [hyperfleet-claude-plugins](https://github.com/openshift-hyperfleet/hyperfleet-claude-plugins) to check against team standards before posting for human review

### 3. Open a PR

- Add a clear description: what changed, why, how to test the PR, and who to loop in
- Resolve all CodeRabbit comments before requesting human review — fix valid suggestions and respond to rejected ones with a reason
- Post the PR link in [#hcm-hyperfleet-team](https://redhat.enterprise.slack.com/archives/hcm-hyperfleet-team) and tag `@hyperfleet-code-review` for visibility
- See [CONTRIBUTING.md](../../CONTRIBUTING.md#submitting-changes) for the full submission process

### 4. Review and Merge

- Multiple commits per PR are fine, but each commit message should be meaningful
- Allow **24 hours** for peer review (accounts for time zone differences)
- If a PR has no review activity after 24 hours, bump the Slack thread with a reminder
- For urgent changes, use judgement but document rationale clearly
- For major architectural changes, wait for at least one Technical Leader review
- Use the Jira Development Panel to track PR status directly from the ticket (see [GitHub-Jira Integration](github-jira-integration.md))
- Merge once approved with no objections

### 5. Close the Ticket

- Verify acceptance criteria are met (or trade-offs are documented)
- Update the architecture repo if needed (see [Architecture Doc Maintenance](#architecture-doc-maintenance))
- Link the PR in the Jira ticket (if you followed the branch naming convention, the PR is already linked automatically via the [GitHub-Jira integration](github-jira-integration.md))
- Confirm the PR is **merged** and appears in the Jira Development Panel before moving to **Done**

---

## Code Review

### Expectations

- **Review for correctness**: Bugs, edge cases, error handling
- **Review for consistency**: Patterns align across the codebase and with [engineering standards](../standards/)
- **Review for clarity**: Code is understandable to someone who didn't write it
- **Review for learning**: Share knowledge, suggest patterns, ask questions

### Reviewer Guidelines

- Everyone is welcome to add comments to a review — every question is valid
- Be constructive and specific
- Distinguish between blocking issues and suggestions (prefix with `nit:` for non-blocking)
- If you approve with suggestions, trust the author to address them
- Don't block PRs on style preferences already covered by linting

### Author Guidelines

- Keep PRs focused and reviewable (smaller is better)
- Respond to all review comments, even if just acknowledging
- If you disagree with feedback, discuss it — don't ignore it

---

## Architecture Doc Maintenance

### When to Update

Update the architecture repo when closing a ticket if the work:

- Changes system architecture or component design
- Adds, removes, or modifies components or services
- Changes APIs, events, or contracts
- Introduces new patterns or approaches
- Affects deployment, operations, or configuration

**Rule of thumb**: If your work changes how the system works, update the architecture repo. The [hyperfleet-architecture plugin](https://github.com/openshift-hyperfleet/hyperfleet-claude-plugins/tree/main/hyperfleet-architecture) can help identify what needs updating.

### What to Document

| Change Type                     | Where to Document        |
| ------------------------------- | ------------------------ |
| Component design changes        | `hyperfleet/components/` |
| New standards or conventions    | `hyperfleet/standards/`  |
| Implementation guides, runbooks | `hyperfleet/docs/`       |
| Architecture decisions          | `hyperfleet/adrs/`       |

### How to Keep in Sync

1. Before closing a ticket, ask: "Does the architecture repo still reflect reality?" — the `/is-ticket-implemented` command can help verify this
2. Make documentation updates in the same PR when the change is in the same repo. Use a follow-up PR only for cross-repo changes
3. Link the architecture repo PR in the Jira ticket

---

## Decision-Making

### Principles

- **Decide locally**: If it affects only your work, you decide
- **Consult when helpful**: Seek input when you'd benefit from another perspective
- **Escalate cross-cutting changes**: Bring architectural or cross-team impacts to the group
- **Document trade-offs**: Record significant decisions so future engineers understand the "why"

### When to Document a Decision

Document decisions with architectural impact, cross-team scope, or significant trade-offs using an [Architecture Decision Record](../adrs/README.md). See the ADR README's [When to Write an ADR](../adrs/README.md#when-to-write-an-adr) section for the full criteria.

### Handling Trade-offs Against Acceptance Criteria

When you need to deviate from acceptance criteria:

1. **Document the trade-off** — what was originally expected, what you delivered, why, and the impact
2. **Update the ticket** — modify acceptance criteria or add a comment explaining the change
3. **Tag stakeholders** if the trade-off is significant

---

## Communication

### Channel Map

| Channel                      | Purpose                                         | Response Expectation     |
| ---------------------------- | ----------------------------------------------- | ------------------------ |
| #hcm-hyperfleet-team (Slack) | PR links, team updates, quick questions         | Same business day        |
| Jira comments                | Ticket-specific decisions, trade-offs, blockers | End of next business day |
| Architecture repo PRs        | Design decisions, standards changes             | 24 hours                 |
| Direct Slack DM              | Sensitive or personal topics only               | Best effort              |

### Principles

- **Async-first**: Use Jira, Slack, and the architecture repo for decisions
- **Sync when helpful**: Jump on a call when async becomes inefficient
- **Document outcomes**: Record decisions from sync discussions in Jira or the architecture repo

### Working Across Time Zones

- Update Jira tickets before end of day so the other region has context
- Document blockers clearly — tag people who can unblock you
- Don't block on reviews — keep PRs flowing asynchronously
- Use overlap hours for discussions that need real-time back-and-forth

### Asking for Help

- Ask early, don't struggle alone
- Ask in team channels (helps everyone learn)
- Include context: what you're trying to do, what you've tried, what you need

---

## Meeting Norms

### Daily Standup (Slack)

- Async standup thread in Slack, all time zones
- Every engineer is required to post an update

### Crossover Calls

- 2 calls in NASA-friendly time zones, 3 in APAC-friendly time zones
- Every crossover call bridges European time zone
- Purpose: internal office hours — bring questions, seek clarity, give updates, share knowledge, brown bag sessions
- **Not mandatory, but encouraged**

### Office Hours

- Once a week, alternating between APAC-friendly and NASA-friendly weeks
- Main touch point for coordination with partner teams
- **Encouraged** — this is where cross-team alignment happens

### Sprint Ceremonies

- **Backlog refinement**: Once per sprint. Mandatory for team leads only. Outcomes communicated via Slack and crossover calls
- **Sprint demo**: Once per sprint, with NASA-friendly and APAC-friendly sessions
- **Retrospectives**: Held at each team lead's discretion to reflect on what's working and what isn't

### Focus Time

- Engineers are encouraged to block-book focus time in their own calendars
- Meetings are welcome when they are valuable — the goal is not to avoid meetings, but to protect uninterrupted time for deep work

---

## Definition of Done

A ticket is done when all three are complete:

| Area              | Criteria                                                                                                                                        |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| **Code**          | Meets acceptance criteria (or documented trade-offs). Follows [engineering standards](../standards/). Passes CI (build, lint, security scans).  |
| **Tests**         | Unit tests for core logic. Integration tests where components interact. E2E tests for critical flows where applicable. All tests passing in CI. |
| **Documentation** | Code comments for complex logic. Usage/operational documentation. Architecture repo updated if the work changes system behavior.                |

---

## Quality Expectations

### Production-Ready Means

- Works reliably, not just in ideal conditions
- Handles errors with graceful degradation and clear messages
- Observable: logs, metrics, traces for debugging
- Secure: no vulnerabilities, secrets managed properly
- Maintainable: clear code, documented trade-offs

### Testing Expectations

- Test what matters: critical paths and edge cases
- Test at the right level: unit for logic, integration for interactions, E2E for flows
- No flaky tests in CI
- Fast feedback loop for developers

---

## WIP Limits

- **3 items in progress** and **3 items in review** per engineer
- This is a guideline for now — we may enforce it in Jira if needed

---

## Conflict Resolution

When technical or interpersonal disagreements arise:

1. **Discuss directly** between the people involved
2. **Bring it to a crossover call** if unresolved — use the team for perspective
3. **Escalate to tech lead / engineering manager** if it still cannot be resolved

Ground rules:

- Focus on the idea, not the person
- Disagreement is healthy — it leads to better decisions
- Once a decision is made, align and move forward

---

## Psychological Safety

- It is safe to say "I don't know"
- Mistakes are learning opportunities, not blame events
- Challenging a technical approach is expected, regardless of who proposed it
- Ask questions freely — no question is too basic
- Give feedback with respect, receive feedback with openness

---

## Continuous Improvement

- Retrospectives surface improvements (see [Sprint Ceremonies](#sprint-ceremonies))
- This working agreement is updated based on what we learn
- Anyone can propose changes — open a PR
- **We review this agreement quarterly and when onboarding new team members**

**This document exists to support the team, not constrain it. If something isn't working, change it.**
