---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-11-10
---

# HyperFleet Repository Creation Guidelines

## Overview

This document lists what a new repository in the `openshift-hyperfleet` organisation needs, who can perform each step, and how to verify it. It is the entry point, not the procedure: each CI system has its own document and is linked here rather than copied, so a change has one place to update.

Following these guidelines gives a repository that builds, tests, merges, and ships the same way as its neighbours. The conventions assume the MVP baseline and are expected to be refined as the platform matures.

---

## Which steps apply

Every repository gets the settings, the files, the team access, Prow, CodeRabbit, and Renovate. Konflux applies only to repositories that ship an artifact as a container image or a Helm chart.

| Step | Applies to |
| ---- | ---------- |
| Repository settings, files, and team access | Every repository |
| Prow CI | Every repository |
| CodeRabbit | Every repository |
| Renovate | Every repository |
| Konflux image pipelines | Repositories that ship a container image |
| Konflux chart pipelines | Repositories that ship a Helm chart |

---

## Repository Naming and Initialization

- Repository name contains relevant keywords for discoverability, use lowercase with hyphens to separate words (kebab-case)
- Repository description is accurate and meaningful: what the repository holds, not its status
- Choose visibility: **public**
- Repository is initialized with README.md during creation
- Repository is initialized with appropriate LICENSE (**Apache-2.0 license**) during creation

---

## Repository Files

These files live in the repository and are reviewed like any other change.

| File | What it is | Reference |
| ---- | ---------- | --------- |
| `OWNERS` | Who reviews and who approves changes in each area | [Repository Ownership](owners.md) |
| `.hyperfleet.yaml` | The repository type, read by HyperFleet tooling | [Repository Type Indicator](../standards/makefile-conventions.md#repository-type-indicator) |
| `Makefile` | The targets the declared repository type requires | [Makefile Conventions](../standards/makefile-conventions.md) |
| `.pre-commit-config.yaml` | The `hyperfleet-hooks` set, including commitlint | [Pre-commit Hooks](pre-commit-hooks.md) |
| `renovate.json` | Dependency automation, extending the shared config | [Renovate](#renovate) |

The `.hyperfleet.yaml` file states the type instead of leaving tooling to infer it from `go.mod` or a `charts/` directory:

```yaml
# .hyperfleet.yaml - Repository metadata for HyperFleet tooling
version: v1
repository:
  types: [service]
  name: example-service
  description: One line describing what the repository holds
```

Do not hand-write `OWNERS` from scratch. The area table in [Repository Ownership](owners.md) is generated from [`owners.yaml`](owners.yaml), which is the source of truth for every `OWNERS` file in the organisation.

---

## Branch Protection Configuration

### Default Branch

- Set `main` as the default branch

### Branch Protection Rules

Navigate to: **Settings → Rules → Rulesets → New branch ruleset**

- Ruleset name: `hyperfleet-main-protection`
- Enforcement status: **Active**
- Target branches: **Include default branch**
- Rules:
  - **Restrict deletions**
  - **Block force pushes**
  - **Require a pull request before merging**, with these parameters:

| Parameter | Value | Why |
| --------- | ----- | --- |
| Required approvals | `0` | The gate is who approves, not how many. See [How a merge works](owners.md#how-a-merge-works) |
| Dismiss stale reviews on push | enabled | A push after approval needs a fresh look |
| Require review from code owners | disabled | Ownership is enforced by Prow's `OWNERS` files, not by GitHub |
| Require approval of the most recent push | disabled | The approver is not necessarily the last pusher |
| Require extra approval for unattributed pull requests | left at the GitHub default | It adds one approval on top of the configured count for a pull request opened by an app identity, and does nothing at a count of zero |
| Require conversation resolution | disabled | Review threads are a review concern, not a merge gate |
| Allowed merge methods | merge, squash, rebase | Tide squashes on merge; the other methods stay available for manual work |

The ruleset gates the *shape* of a merge, not who signed off. With zero required approvals GitHub would itself accept a pull request nobody approved, and the extra-approval setting above has no effect at that count. The approval requirement comes from Prow instead: Tide merges only a pull request that carries the `lgtm` and `approved` labels, which the `OWNERS`-driven plugins set from an area approver, and only once the presubmit contexts are green. The ruleset has no bypass actors, so it applies to organisation admins as well.

The ruleset carries no required status checks, and there is a second mechanism that does: Prow's branch protector. The `branch-protection` section of [`core-services/prow/02_config/_config.yaml`](https://github.com/openshift/release/blob/main/core-services/prow/02_config/_config.yaml) enables `protect-tested-repos`, so once a repository has jobs the protector adds classic branch protection to `main` with a required context per presubmit — `ci/prow/validate-commits`, `ci/prow/lint`, `ci/prow/unit`, and `ci/prow/presubmits-integration` where that step exists — with `strict: false` and no required reviews. Duplicating those contexts in the ruleset would mean two lists to keep in sync, and a job renamed in `openshift/release` would block every merge until someone edited the ruleset.

The protector runs on a schedule, so a repository that has just merged its Prow configuration still has an unprotected `main` for a while. Until the protector has run, `gh api repos/openshift-hyperfleet/<repo>/branches/main/protection` answers `Branch not protected`, and a manual merge goes through with failing presubmits.

---

## Team Access Configuration

All HyperFleet repositories **MUST** be configured with the following team access levels:

### hyperfleet Team - Write Access

**Path**: Settings → Access → Collaborators and teams → Add teams

1. Click **Add teams**
2. Search and select **hyperfleet**
3. Grant **Write** access

### automation-bots Team - Admin Access

**Path**: Settings → Access → Collaborators and teams → Add teams

1. Click **Add teams**
2. Search and select **automation-bots**
3. Grant **Admin** access

`automation-bots` holds the CI robots (`openshift-ci-robot`, `openshift-merge-robot`) and must have admin for them to label, trigger, and merge.

---

## Prow CI

A repository with no `ci-operator` configuration reports `no checks reported` on every PR, and `/lgtm` and `/approve` do nothing. The merge automation only starts working once the repository is configured in [openshift/release](https://github.com/openshift/release).

Follow [Onboarding a New Component for Testing and Merge Automation](release/test-release/onboarding-a-new-component-for-testing-and-merge-automation.md). It covers bootstrapping `core-services/prow/02_config/$org/$repo/_pluginconfig.yaml` with `make new-repo`, copying `OWNERS` into the same directory, and adding the presubmits.

The presubmits every HyperFleet Go repository carries are the commit-message check and the repository's own `make lint` and `make test`, so the Makefile targets are the contract: a target that does not exist in the repository fails the job.

---

## Konflux

Konflux builds and releases the artifacts. Two Applications exist: `hyperfleet` for images and `hyperfleet-charts` for charts. Each artifact is a Component named after the repository, and a repository that ships both has a Component in each Application.

| Artifact | PipelineRuns in the repository | Component | Output image |
| -------- | ------------------------------ | --------- | ------------ |
| Image | `<name>-push.yaml`, `<name>-tag.yaml` | `<name>` in `hyperfleet` | `quay.io/redhat-user-workloads/hyperfleet-tenant/hyperfleet/<name>` |
| Chart | `<name>-chart-push.yaml`, `<name>-chart-tag.yaml` | `<name>-chart` in `hyperfleet-charts` | `quay.io/redhat-user-workloads/hyperfleet-tenant/hyperfleet/<name>-chart` |

The PipelineRuns build on push to `main` and on version tags only, so they add no check to a pull request. PR validation is Prow's: a pull request shows the presubmit contexts from the Prow section above and nothing from Konflux. An empty check list means the Prow configuration is missing, not that Konflux has not been wired up yet.

Registration is not a click in the Konflux UI: it is an MR against the `releng/konflux-release-data` GitLab repository with a Component and an `ImageRepository` per artifact, the kustomization entry, the regenerated output, and the ReleasePlanAdmission component mapping. The files and their locations are listed in the [release configuration map](release/operations/configuration-map.md); the naming and pipeline conventions are in the [Konflux Release Pipeline Design](release/konflux-release-pipeline-design.md).

---

## CodeRabbit

CodeRabbit reviews every PR. The organisation configuration in `openshift-hyperfleet/coderabbit/.coderabbit.yaml` applies to all repositories with `auto_review` enabled, so a repository does not need its own `.coderabbit.yaml` and must not add one: a local file overrides the shared rules.

The App is installed per repository, so a new repository is silently unreviewed until it is added. Only an organisation admin can change the installation.

Two behaviours are worth knowing before opening the first PR:

- The installation does not review PRs opened before it. A PR that predates the installation needs a `@coderabbitai review` comment.
- The evidence that the wiring works is a walkthrough comment from `coderabbitai[bot]` on the PR, not the absence of a check failure.

---

## Renovate

Renovate opens dependency PRs through MintMaker. The repository carries a `renovate.json` whose only content is the shared configuration:

```json
{
  "extends": [
    "github>openshift-hyperfleet/renovate-config"
  ]
}
```

Schedule, grouping, and update policy live in `openshift-hyperfleet/renovate-config`, so a repository-level override is an exception that needs a reason in the PR.

As with CodeRabbit, the App is installed per repository and only an organisation admin can change it. The evidence that it works is a dependency dashboard issue or a dependency PR in the repository. Watch the first run for `pre-commit` pins: the `rev: <sha>  # frozen: <tag>` format exists because Renovate once rewrote those pins to mutable tags.

---

## Who Can Perform Each Step

Some steps need more than repository admin, which is worth knowing before planning the work.

| Step | Performed by |
| ---- | ------------ |
| Create the repository, set the ruleset, add the teams | Whoever creates the repository, with admin on it |
| Add the repository files and the scaffold | Any maintainer, through a PR |
| Prow configuration | A PR to `openshift/release`, approved by its release approvers |
| Konflux registration | An MR to `releng/konflux-release-data`, reviewed by releng |
| CodeRabbit and Renovate App access | An organisation admin |
| First release | Release owners, after the Prow and Konflux steps are green |

---

## Verification Checklist

Each item names the evidence to check. A green checklist means the repository is configured, not that someone clicked through the settings.

### Repository Basics

- [ ] Repository name follows the naming conventions
- [ ] Repository description explains what it holds
- [ ] Visibility is Public (unless justified otherwise)
- [ ] `README.md` exists and documents how to build, test, and run
- [ ] Apache-2.0 `LICENSE` is present
- [ ] `.hyperfleet.yaml` declares the repository type
- [ ] `Makefile` provides the targets the declared type requires
- [ ] `.pre-commit-config.yaml` uses the `hyperfleet-hooks` set, with commitlint on `commit-msg`
- [ ] `renovate.json` extends the shared config and adds no local policy
- [ ] `OWNERS` matches the area table in [Repository Ownership](owners.md)

### Branch Configuration

- [ ] `main` is the default branch
- [ ] A ruleset named `hyperfleet-main-protection` is active on the default branch
- [ ] The ruleset blocks deletion and force pushes
- [ ] The ruleset requires a pull request and dismisses stale reviews on push
- [ ] The ruleset sets zero required approvals and no required status checks, and has no bypass actors, as in the table above
- [ ] `main` reports classic branch protection with the `ci/prow/*` contexts, which Prow's branch protector applies after the Prow configuration merges
- [ ] The approval gate is Prow's: Tide reports `Needs approved, lgtm labels` on a pull request that has neither

### Team Access

- [ ] `hyperfleet` team has Write access
- [ ] `automation-bots` team has Admin access

### CI and Automation

- [ ] `ci-operator/config/openshift-hyperfleet/<repo>` exists in `openshift/release`, and a PR reports its presubmits instead of `no checks reported`
- [ ] `/lgtm` and `/approve` work on a PR, which needs the Prow plugins for the repository
- [ ] Repositories that ship an artifact have their PipelineRuns in `.tekton/` and their Component registered, and the first build on `main` is green
- [ ] `coderabbitai[bot]` commented on a PR
- [ ] A dependency dashboard issue or dependency PR exists, and no `pre-commit` pin was rewritten to a tag

---

## References

- [Repository Ownership](owners.md): areas, reviewers, approvers, and how a merge works
- [Makefile Conventions](../standards/makefile-conventions.md): standard targets and the repository type indicator
- [Pre-commit Hooks](pre-commit-hooks.md): the shared hook set
- [Onboarding a New Component for Testing and Merge Automation](release/test-release/onboarding-a-new-component-for-testing-and-merge-automation.md): the Prow procedure
- [Konflux Release Pipeline Design](release/konflux-release-pipeline-design.md): Applications, Components, and PipelineRun conventions
- [Release Configuration Map](release/operations/configuration-map.md): where each Konflux resource lives
- [Container Image Standard](../standards/container-image-standard.md): image build, FIPS, and runtime requirements
