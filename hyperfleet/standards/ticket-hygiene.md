---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-05-20
---

# HyperFleet Ticket Hygiene Standard

> Defines which JIRA fields are required vs recommended per issue type, lists valid Component and Activity Type values, and establishes the ticket quality bar for sprint readiness. This standard is the single source of truth for field-level completeness — the [Definition of Ready](../docs/working-agreement.md#definition-of-ready) in the working agreement covers content quality (acceptance criteria, dependencies) while this document covers field-level completeness.

---

## Table of Contents

1. [Overview](#overview)
2. [Required and Recommended Fields](#required-and-recommended-fields)
3. [Field Requirements by Issue Type](#field-requirements-by-issue-type)
4. [Valid Components](#valid-components)
5. [Activity Types](#activity-types)
6. [Story Points Scale](#story-points-scale)
7. [Fix Versions](#fix-versions)
8. [Examples](#examples)
9. [Enforcement](#enforcement)
10. [References](#references)

---

## Overview

Consistent ticket metadata enables accurate sprint reporting, capacity planning (Sankey allocation), and workload visibility. When fields like Activity Type or Component are missing, sprint reports become unreliable and capacity allocation is inaccurate.

This standard applies to all tickets in the HYPERFLEET JIRA project. The [required fields](#required-and-recommended-fields) define the sprint-entry baseline for Stories, Tasks, and Bugs. Epics follow the [per-issue-type matrix](#field-requirements-by-issue-type), which relaxes some fields to SHOULD or MAY.

Key words "MUST", "MUST NOT", "SHOULD", "SHOULD NOT", and "MAY" are used per [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119).

---

## Required and Recommended Fields

### Required Fields

Every ticket entering a sprint MUST have these fields set:

| Field | Purpose |
|-------|---------|
| Summary | Clear, concise title under 100 characters |
| Description (What/Why) | Structured description with What (the change) and Why (the motivation) sections |
| Acceptance Criteria | At least 2 clear, testable criteria |
| Story Points | Effort estimate using the [standard scale](#story-points-scale) |
| Component | Which part of the system this work affects (see [Valid Components](#valid-components)) |
| Activity Type | Capacity planning category (see [Activity Types](#activity-types)) |

### Recommended Fields

These fields SHOULD be set when applicable:

| Field | Purpose |
|-------|---------|
| Fix Version | Target release version |
| Labels | Additional categorization (e.g., `follow-up`, `tech-debt`) |
| Priority | Urgency relative to other work (defaults to Normal) |
| Epic Link | Parent epic for feature tracking (MUST for Stories — see [per-type table](#field-requirements-by-issue-type)) |

---

## Field Requirements by Issue Type

| Field | Story | Task | Bug | Epic |
|-------|-------|------|-----|------|
| Summary | MUST | MUST | MUST | MUST |
| Description (What/Why) | MUST | MUST | MUST | MUST (Goal/Scope/Success Criteria) |
| Acceptance Criteria | MUST | MUST | MUST | SHOULD |
| Story Points | MUST | MUST | MUST | MAY |
| Component | MUST | MUST | MUST | SHOULD |
| Activity Type | MUST | MUST | MUST | SHOULD |
| Fix Version | SHOULD | SHOULD | SHOULD | MAY |
| Priority | SHOULD | SHOULD | MUST | SHOULD |
| Epic Link | MUST | SHOULD | SHOULD | N/A |
| Labels | MAY | MAY | MAY | MAY |

### Additional Requirements by Type

#### Bug

Bugs MUST include in their description:

- **Steps to reproduce** or a clear trigger description
- **Expected behavior** vs **actual behavior**
- **Impact** (who is affected and how)

#### Epic

Epics MUST include in their description:

- **Goal** — what the epic delivers when complete
- **Scope** — what is in and out of scope
- **Success criteria** — how to measure completion (replaces Acceptance Criteria for epics)

---

## Valid Components

Each ticket MUST have at least one component assigned. Use the component that best matches the primary area of work.

| Component | Scope | Repository |
|-----------|-------|------------|
| Adapter | Adapter framework, task configs, resource lifecycle | [hyperfleet-adapter](https://github.com/openshift-hyperfleet/hyperfleet-adapter) |
| API | REST API service, handlers, DAOs, middleware | [hyperfleet-api](https://github.com/openshift-hyperfleet/hyperfleet-api) |
| Architecture | Architecture docs, standards, ADRs, working agreements | [architecture](https://github.com/openshift-hyperfleet/architecture) |
| CICD | Prow jobs, Konflux pipelines, release automation | Multiple repos (CI config) |
| Claude Plugins | Claude Code plugins, skills, and AI-assisted tooling | [hyperfleet-claude-plugins](https://github.com/openshift-hyperfleet/hyperfleet-claude-plugins) |
| Documentation | Developer guides, authoring guides, reference docs, pattern docs | Multiple repos |
| E2E Tests | End-to-end test suites and test infrastructure | [hyperfleet-e2e](https://github.com/openshift-hyperfleet/hyperfleet-e2e) |
| Infra | Operator, applier, Helm umbrella charts, deployment scripts | [hyperfleet-infra](https://github.com/openshift-hyperfleet/hyperfleet-infra) |
| Message Broker | Shared broker library (Pub/Sub, RabbitMQ, CloudEvents) | [hyperfleet-broker](https://github.com/openshift-hyperfleet/hyperfleet-broker) |
| OCI | OCI artifact distribution, Helm chart publishing | Multiple repos |
| Sentinel | Sentinel reconciliation service, decision engine | [hyperfleet-sentinel](https://github.com/openshift-hyperfleet/hyperfleet-sentinel) |

> **Note:** If a ticket spans multiple components, assign the primary component. Add secondary components only when the work equally affects both areas.

---

## Activity Types

Activity Type refers to the existing JIRA custom field "Activity Type" — this section documents its valid values and provides guidance on which value to select. Activity Type MUST be set for sprint capacity planning. Tickets without an Activity Type appear as "Uncategorized" in the Sankey capacity reports.

Evaluate top-down — first match wins:

### Tier 1 — Non-Negotiable

SLAs, escalations, CVEs — these take priority regardless of sprint plan.

| Activity Type | When to Use |
|---------------|-------------|
| Associate Wellness & Development | Onboarding, team growth, training, associate experience |
| Incidents & Support | Customer escalations, production incidents, outage response |
| Security & Compliance | CVEs, vulnerabilities, security patches, compliance work |

### Tier 2 — Core Principles

Reduce bug backlog, ensure quality and stability.

| Activity Type | When to Use |
|---------------|-------------|
| Quality / Stability / Reliability | Bug fixes, SLO improvements, tech debt, chores, toil reduction, PMR action items |

### Tier 3 — Balance Remaining Capacity

Split remaining capacity between sustainability and product delivery.

| Activity Type | When to Use |
|---------------|-------------|
| Future Sustainability | Productivity improvements, upstream contributions, proactive architecture, enablement |
| Product / Portfolio Work | Strategic product work, new features, BU product delivery |

### Decision Flow

1. Is it an escalation, incident, CVE, or training/onboarding? → **Tier 1**
2. Does it fix bugs, reduce tech debt, improve SLOs, or reduce toil? → **Tier 2** (Quality / Stability / Reliability)
3. Otherwise → **Tier 3**: Is it proactive improvement or enablement? → Future Sustainability. Is it new product value? → Product / Portfolio Work

---

## Story Points Scale

HyperFleet uses a modified Fibonacci sequence. Everything scales from 1 (trivial).

| Points | Meaning | Typical Scope |
|--------|---------|---------------|
| 0 | Tracking only | Quick task with stakeholder value but negligible effort compared to a 1-pointer |
| 1 | Trivial | One-line change, extremely simple task. No risk, very low effort |
| 3 | Straightforward | Time-consuming but fairly straightforward. Minor risks possible |
| 5 | Medium | Requires investigation, design, or collaboration. Can be complex. Risks involved |
| 8 | Large | Big task requiring investigation and design. Collaboration required. Risks expected. **Design doc required** |
| 13 | Too large | MUST be split into smaller stories before entering a sprint |

### Sizing Guidelines

- **When in doubt, round up** — it is better to overestimate than to carry work across sprints
- **Compare to known work** — look at recently completed tickets with similar scope for calibration
- **8-point tickets MUST have a design doc** — if there is no design doc, the ticket is not ready
- **13-point tickets MUST be split** — break them into 2-3 smaller stories with clear boundaries

---

## Fix Versions

Fix Version tracks which release a ticket targets. Set this field when the ticket is committed to a specific release.

Check the [JIRA project configuration](https://redhat.atlassian.net/projects/HYPERFLEET?selectedItem=com.atlassian.jira.jira-projects-plugin:release-page) for the current list of active versions and their target dates.

---

## Examples

### Good Example: Story

```text
Summary: Add force-delete endpoint for nodepools
Description:
  ### What
  Add a DELETE endpoint to the nodepool API that supports force deletion...
  ### Why
  Orphaned nodepools cannot be cleaned up when the parent cluster is deleted...
Acceptance Criteria:
  - [ ] DELETE /api/v1/nodepools/{id}?force=true returns 204
  - [ ] Force-deleted nodepools bypass adapter reconciliation
  - [ ] Audit log entry created for force-delete operations
Story Points: 5
Component: API
Activity Type: Product / Portfolio Work
Epic Link: HYPERFLEET-834 (Force Deletion)
```

### Bad Example: Story

```text
Summary: Fix nodepool stuff
Description: Nodepools are broken, need to fix them
Acceptance Criteria: (none)
Story Points: (not set)
Component: (not set)
Activity Type: (not set)
```

**What is wrong:** Summary is vague, description lacks What/Why structure, no acceptance criteria, missing required fields (Story Points, Component, Activity Type, Epic Link).

### Good Example: Bug

```text
Summary: Bug: Adapter dependency test has race condition causing flaky nightly failures
Description:
  ### What
  The adapter dependency integration test fails intermittently in tier0 nightly runs...
  ### Steps to Reproduce
  1. Run `make integration-test` with parallel execution enabled
  2. Observe TestAdapterDependency fails ~20% of runs
  ### Expected Behavior
  Test passes consistently regardless of execution order
  ### Actual Behavior
  Test fails with "context deadline exceeded" when another test holds the broker connection
  ### Impact
  Nightly CI is unreliable, requiring manual re-runs
Acceptance Criteria:
  - [ ] Test passes consistently in 10 consecutive CI runs
  - [ ] Race condition root cause identified and fixed
Story Points: 3
Component: Adapter
Activity Type: Quality / Stability / Reliability
Priority: High
```

---

## Enforcement

### Automated Tooling

The [`hyperfleet-jira`](https://github.com/openshift-hyperfleet/hyperfleet-claude-plugins/tree/main/hyperfleet-jira) Claude Code plugin provides automated triage checks:

- **`/jira-triage`** — audits sprint tickets against this standard, flagging missing required fields
- **`/jira-ticket-creator`** — enforces required fields when creating new tickets

These tools use this standard as their source of truth. Discrepancies between plugin behavior and this document SHOULD be reported and fixed in the plugin (see [HYPERFLEET-1105](https://redhat.atlassian.net/browse/HYPERFLEET-1105)).

### Sprint Planning Gate

Before pulling tickets into a sprint, the team SHOULD run `/jira-triage` to audit all candidate tickets. Tickets that fail automated validation MUST NOT enter the sprint until fixed.

---

## References

### Related HyperFleet Standards

- [Commit Standard](./commit-standard.md) — commit message format
- [Working Agreement](../docs/working-agreement.md) — Definition of Ready and team processes

### External Resources

- [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119) — Key words for use in RFCs to indicate requirement levels
