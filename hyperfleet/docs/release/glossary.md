---
Status: Active
Owner: HyperFleet Team
Last Updated: 2026-05-11
---

# Release Glossary

> **Audience:** HyperFleet developers, release owners, and anyone reading the release documentation.

Key terms used across the release docs. Written for someone encountering these systems for the first time.

---

## Konflux and Build Pipeline

| Term | Definition |
|------|------------|
| **Konflux** | Red Hat's build and release platform. Orchestrates container image builds, signing, policy validation, and registry publishing. |
| **PaC** (Pipelines as Code) | Trigger layer. Watches GitHub webhooks and matches events to `.tekton/` pipeline files in component repos via annotations. |
| **Tekton** | Kubernetes-native pipeline framework used by Konflux. Defines Pipelines, Tasks, and PipelineRuns as custom resources. |
| **Tekton Chains** | Controller that automatically signs provenance records (in-toto format) with cosign after every build. Zero configuration needed. |
| **Snapshot** | Immutable record of all component images at specific commits. Created after each build. Releases operate on Snapshots, not individual images. |
| **RPA** (ReleasePlanAdmission) | Defines how releases are processed: component-to-registry mapping, tags, EC policy, release pipeline. Lives in `konflux-release-data`. |
| **ITS** (IntegrationTestScenario) | A test pipeline that runs against a Snapshot before release. Mandatory ITS blocks release on failure. |
| **EC** (Enterprise Contract) | Policy engine validating container images meet compliance requirements. Checks provenance, acceptable bundles, base images. |
| **CEL** (Common Expression Language) | Used in PaC annotations for event matching. RE2 regex via `matches()`. Required for distinguishing RC from release tags. |
| **Provenance** | Signed record proving how and where a container image was built. Enables verification that an image came from a specific commit via Konflux's pipeline. |
| **SBOM** (Software Bill of Materials) | Machine-readable inventory of all packages in a container image. Generated automatically by Konflux builds. |
| **SLSA** (Supply-chain Levels for Software Artifacts) | Framework for build integrity. Konflux achieves Level 3 by default — builds on hardened infrastructure with signed provenance. |

## Prow and Testing

| Term | Definition |
|------|------------|
| **Prow** | Kubernetes-based CI system used by OpenShift. Runs PR validation, E2E tests, and periodic jobs. |
| **ci-operator** | OpenShift CI tool that orchestrates container image builds and test execution. Configured via files in the `openshift/release` repo. |
| **presubmit** | Prow job triggered on PR creation. Runs lint, unit tests, and build checks. Must pass before merge. |
| **postsubmit** | Prow job triggered after code is merged to main. Runs post-merge validations. |
| **periodic** | Prow job triggered on a cron schedule. Used for nightly E2E tests and regression testing. |
| **Gangway** | Prow API that allows external services to trigger Prow jobs programmatically. Used for RC E2E triggering via GitHub Actions. |
| **E2E** (End-to-End) | Tests that validate complete user workflows across all system components deployed to a real environment. |

## Release Process

| Term | Definition |
|------|------------|
| **RC** (Release Candidate) | Pre-release version tagged for validation before GA. Example: `v1.5.0-rc1`. Requires full E2E testing before promotion. |
| **GA** (General Availability) | Final production release version. Example: `v1.5.0`. Signals production-ready status to partner teams. |
| **Feature Freeze** | Point in the release cycle when the release branch is created. No new features after this — only bug fixes. |
| **Code Freeze** | Point after stabilization when only Blocker/Critical fixes are permitted. Strict change control with Release Owner approval. |
| **Release Owner** | Person responsible for coordinating the release: approving cherry-picks, tracking bugs, ensuring release criteria are met. |
| **RELEASE_MANIFEST.yaml** | File in `hyperfleet-release` repo tracking which component versions constitute a validated release. Updated before each RC and GA tag. |
| **Cherry-Pick** | Applying a specific commit from one branch to another. HyperFleet fixes main first, then cherry-picks to the release branch. |
| **Hotfix** | Urgent fix applied to a released version outside the normal release cycle. Patches skip RC — straight to a patch tag. |
| **N-1 Compatibility** | Supporting one version back (e.g., v1.5 compatible with v1.4). |

## Infrastructure

| Term | Definition |
|------|------------|
| **kflux-prd-rh02** | Konflux production cluster hosted by Red Hat. Runs the PaC controller, Tekton Chains, and release pipelines for HyperFleet. |
| **Quay** | Red Hat's container registry. HyperFleet images are published to `quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/`. |
| **OCI** (Open Container Initiative) | Standard for container and artifact distribution. Helm charts are published as OCI artifacts to the same registries as container images. |
| **helm-git** | Deprecated Helm plugin for pulling charts from Git repos. Replaced by OCI distribution (HYPERFLEET-831). No longer required for HyperFleet chart consumption. Still used by the dev-only Maestro umbrella chart in hyperfleet-infra until Maestro is decommissioned. |
| **Pyxis** | Red Hat's container metadata catalog. Images registered here are automatically scanned for CVEs. |
| **ArgoCD** | GitOps-based deployment tool. Partner teams use ArgoCD to consume HyperFleet images from Quay. |
| **konflux-release-data** | GitLab repo containing RPA, constraint, and tenant configuration for Konflux releases. Source of truth for release pipeline config. |
