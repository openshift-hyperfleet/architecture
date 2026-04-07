---
Status: Draft
Owner: HyperFleet Team
Last Updated: 2026-06-02
---

# HyperFleet Release Contract

## What & Why

### What

This document defines the formal release contract between the HyperFleet team and its partner teams (GCP Offering Team and ROSA Regional Platform Team). It covers:

- **Release handoff contract**: what artifacts are produced, how partners are notified, and what SLAs apply
- **Integration testing strategy**: how each team gates HyperFleet changes and how tests are coordinated across teams
- **Test ownership map**: which team owns which layer of testing to eliminate redundancy and close coverage gaps

### Why

- Without a defined contract, release handoffs are ad-hoc and require manual coordination between teams, slowing delivery and increasing error risk
- Unclear test ownership creates either coverage gaps (bugs reaching production) or overlapping test suites (longer pipelines without benefit)
- Partner teams deploying HyperFleet via Argo CD and Terraform need predictable, machine-consumable artifacts (OCI Helm charts) to automate rollout
- A shared testing strategy is required before building confidence in continuous delivery pipelines end-to-end

### Out of scope

- No automated deployment of HyperFleet releases to partner integration environments

---

## Partner Teams

| Team | Platform | Deployment Method |
|------|----------|-------------------|
| GCP Offering Team | GCP | Argo CD + Terraform + Tekton Pipelines |
| ROSA Regional Platform | AWS ROSA | Argo CD + Terraform + AWS CodePipelines |

---

## Release Handoff Contract

### Release Artifacts

For each HyperFleet release, the following artifacts are produced and made available to partner teams:

| Artifact | Location | Format | Notes |
|----------|----------|--------|-------|
| Container images | `quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-{component}:{version}` | OCI image | Built automatically by Konflux on release tag push (PaC tag-triggered pipeline); includes signed provenance (SLSA L3) and SBOM |
| Helm charts | `quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet-{component}-chart:{version}` (see [Helm Chart Distribution](#helm-chart-distribution)) | OCI artifact | Published via Konflux `build-helm-chart-oci-ta` task; required for ROSA/Argo CD consumption |
| API contract lib | [api-spec](https://github.com/openshift-hyperfleet/hyperfleet-api-spec) | NPM library | Base TypeSpec types for API contract |
| API contract template | [api-spec-template](https://github.com/openshift-hyperfleet/hyperfleet-api-spec-template) | GitHub repository | Used as example |
| Release notes | `hyperfleet-release` repo, `releases/release-X.Y/` | Markdown | Compatibility matrix, breaking changes, upgrade guide |
| Compatibility matrix | `hyperfleet-release` repo | Markdown table | Maps validated component version combinations |
| Git tags | Per-component repos + `hyperfleet-release` | `vX.Y.Z` / `release-X.Y` | See [Release Process](release/hyperfleet-release-process.md) |


When a GA release is published, it will have detail of which ROSA/GCP versions have passed the integration tests to use as compatibility matrix. This allows to potentially introduce a breaking change in one release, that may be only deployable by another pillar.

### Helm Chart Distribution

HyperFleet team publishes charts as OCI artifacts to `quay.io/redhat-services-prod/hyperfleet-tenant/` via Konflux (using the `build-helm-chart-oci-ta` task), eliminating the temporary workaround and the Git coupling. Blocked on the Konflux team providing a managed release pipeline for external registries (RELEASE-2363).


### Notification SLA

When a HyperFleet GA release is published:

| Event | Channel | Timeline | Recipients |
|-------|---------|----------|------------|
| Release candidate available | `#hyperfleet-releases` Slack | RC cut day | GCP team, ROSA team |
| GA release published | `#hyperfleet-releases` Slack | GA day | GCP team, ROSA team |
| Breaking change in next release | `#hyperfleet-releases` Slack | ≥ 1 sprint before GA | GCP team, ROSA team |
| Hotfix / patch release | `#hyperfleet-releases` Slack | Within 2 hours of GA tag | GCP team, ROSA team |


At this point in time (Jun 26) breaking changes are not blockers to HyperFleet releases as ROSA/GCP teams do not have to keep long running clusters and migrate data.

### Rollback / Recovery

HyperFleet uses a **roll-forward** strategy for MVP: issues are fixed via patch releases rather than rollback. See [Release Process — Release Recovery Strategy](release/hyperfleet-release-process.md#55-release-recovery-strategy).

HyperFleet commits to (exact times TBD):

- Producing a patch release within **48 hours** for Blocker/Critical regressions
- Producing a patch release within **1 week** for Major regressions
- Maintaining N-1 backward compatibility so partner teams can remain pinned to the previous validated release while a fix is in flight

---

## Integration Testing Strategy

### Decision: Nightly Runs with OCI Chart Injection

**Agreed approach** (as of March 31, 2026 meeting):

- Start with **nightly runs** against HyperFleet `main` branch, not presubmit jobs
- Test against the **latest known-good stable version** of the ROSA regional platform (production Maestro version), replacing only the HyperFleet component under test
- The ROSA team will **temporarily enable OCI chart pushing** so the HyperFleet team can inject PR-built charts into the ROSA deployment pipeline
- Evaluate **non-blocking presubmit** integration with the HyperFleet release repository as a follow-up

**Rationale**: Running full ROSA environment provisioning (~40 minutes + E2E duration) as a presubmit would significantly impact development velocity without proportional benefit at the current team scale. Nightly runs provide meaningful feedback without blocking day-to-day development.

**Note on ROSA's existing pre-merge capability**: The ROSA repo already has a working cross-component E2E pre-merge mechanism (triggered via Prow comment on PRs). The decision to start with nightly runs is about HyperFleet's readiness to onboard to that mechanism — not a limitation of the ROSA infrastructure. Per-PR testing remains the target once the OCI chart injection step is stable.


### Team Test Ownership

| Layer | Owner | Scope | Runs on |
|-------|-------|-------|---------|
| Unit tests | HyperFleet | Each component in isolation | Every PR (presubmit) |
| Integration tests | HyperFleet | Cross-component API contracts | Every PR (presubmit) |
| HyperFleet E2E | HyperFleet | HyperFleet stack end-to-end | Nightly (main branch) |
| ROSA integration | ROSA Team | Full ROSA region + HyperFleet override | Nightly (HyperFleet main) |
| GCP integration | GCP Team | GCP deployment + HyperFleet | Nightly (HyperFleet main) via Tekton `gcp-region-e2e-pipeline` |
| Release gate | HyperFleet | All of the above must pass | Before GA tag |

**Important**: HyperFleet releases ship with a compatibility matrix for the ROSA/GCP versions tested. If newer ROSA/GCP integration tests fail, that doesn't gate the HyperFleet release as long as it passes the successful ROSA/GCP compatible versions.

---

## Alternatives Considered

### 1. Non-blocking Presubmit on HyperFleet Release Repository

Run the full ROSA integration pipeline as an optional, non-blocking presubmit job triggered on the `hyperfleet-release` repo.

**Rejected for now**: A ~40-minute+ non-blocking job provides weak signal — developers may ignore it, especially if failures are infrequent. Starting with nightly runs builds confidence in the pipeline before promoting it to presubmit. This remains a **future action**.

### 2. Consumer-Driven Contract Testing (Pact-style)

Define formal API contracts using a consumer-driven contract testing tool (e.g., Pact). ROSA and GCP publish their expectations; HyperFleet CI verifies them on every PR.

**Rejected for MVP**: The integration surface between HyperFleet and partner teams is primarily at the Helm chart / deployment configuration level, not a REST API contract boundary. Consumer-driven contract testing tools are better suited to service-to-service REST contracts. Helm value schema validation is a lighter-weight alternative to investigate post-MVP.

### 3. Automated Rollout to Integration Environments on GA

Trigger automatic deployment of each HyperFleet GA release to ROSA and GCP integration environments via webhooks.

**Rejected for MVP**: ROSA's pipeline takes ~40 minutes per run and requires environment-specific configuration overrides. Automating this safely requires tooling (OCI charts via Konflux, pipeline webhooks) not yet in place. Deferred to post-Q2 2026.

---

## Related Documents

- [HyperFleet Release Process](release/hyperfleet-release-process.md) — release cadence, branching, artifacts
- [Konflux Release Pipeline Design](release/konflux-release-pipeline-design.md) — build and release pipeline architecture, CEL tag matching, version injection
- [Helm OCI Distribution Design](release/helm-oci-distribution-design.md) — how Helm charts are published as OCI artifacts via Konflux
- [ADR 0014 — Konflux for Container Image Build and Release](../adrs/0014-konflux-build-and-release.md)
- [ADR 0016 — Helm OCI Distribution via Konflux](../adrs/0016-helm-oci-distribution.md)
- [Versioning Trade-offs](versioning-trade-offs.md) — SDK versioning, rollback considerations
- [E2E Testing Framework Spike Report](e2e-testing/e2e-testing-framework-spike-report.md)
- [E2E Run Strategy Spike Report](e2e-testing/e2e-run-strategy-spike-report.md)
- [ROSA — Adding a Component for Pre-merge E2E Testing](https://github.com/openshift-online/rosa-regional-platform/blob/main/docs/adding-component-pre-merge.md) — onboarding guide for the `/test rosa-regionality-compatibility-e2e` Prow trigger
- [ROSA — Testing Strategy Design](https://github.com/openshift-online/rosa-regional-platform/blob/main/docs/design/testing-strategy.md) — three CI workflows (pre-merge, nightly integration, nightly ephemeral)
- GCP-334 — CLM Components Deployment (linked Jira epic)
- HYPERFLEET-633 — Define release contract and integration testing strategy
