---
Status: Active
Owner: HyperFleet Team
Last Updated: 2026-06-22
---

# Release Documentation

## Start Here

| Document | Purpose |
|----------|---------|
| [Konflux Release Pipeline Design](./konflux-release-pipeline-design.md) | How the build and release pipeline works — architecture, flows, and design decisions |
| [HyperFleet Release Process](./hyperfleet-release-process.md) | The release process — cadence, checklists, branching, bug handling, hotfixes |
| [Helm OCI Distribution Design](./helm-oci-distribution-design.md) | How Helm charts are published as OCI artifacts via Konflux |
| [Chart Versioning Strategy](./chart-versioning.md) | How chart versions are derived, tagged, and consumed |
| [Glossary](./glossary.md) | Definitions of terms used across the release docs |
| [ADR 0014](../../adrs/0014-konflux-build-and-release.md) | Decision record for adopting Konflux |
| [ADR 0016](../../adrs/0016-helm-oci-distribution.md) | Decision record for Helm OCI distribution |

## Operations

Engineer-facing operational docs — what to read *during* a release or *when something fails*. The `operations/` subdirectory.

| Document | Purpose |
|----------|---------|
| [Release Runbook](./operations/release-runbook.md) | Copy-paste command sequence for RC → GA, fix cycle, and hotfix |
| [Pipeline Anatomy](./operations/pipeline-anatomy.md) | Reading a Konflux PipelineRun, the build-vs-release distinction, where to look in the UI |
| [Debugging](./operations/debugging.md) | Failure-mode runbook organized by symptom |
| [Configuration Map](./operations/configuration-map.md) | Every release-related config file across the six repos — what it does, who reviews it |
| [Notifications](./operations/notifications.md) | Slack `#hyperfleet-e2e-status`, Pyxis, GitHub PR checks, and Prow status signals |
| [Support](./operations/support.md) | Slack channels, JIRA queues, Konflux UI, escalation contacts |

## Prow Test and Release

The `test-release/` subdirectory contains Prow-specific docs for CI job setup and E2E testing infrastructure.

| Document | Purpose |
|----------|---------|
| [Add Hyperfleet E2E CI Job in Prow](./test-release/add-hyperfleet-e2e-ci-job-in-prow.md) | Configure E2E CI jobs in Prow and trigger periodic jobs via Gangway |
| [Trigger HyperFleet E2E Jobs via Gangway API](./test-release/trigger-e2e-jobs-via-gangway.md) | Run the nightly and RC E2E jobs on demand via the Gangway API, with image-tag overrides |
