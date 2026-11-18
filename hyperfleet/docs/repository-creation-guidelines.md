---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-11-11
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
| `renovate.json` | Dependency automation, extending the shared preset | [`renovate-config`](https://github.com/openshift-hyperfleet/renovate-config) |

The `.hyperfleet.yaml` file states the type instead of leaving tooling to infer it from `go.mod` or a `charts/` directory. The format and the valid types are in [Repository Type Indicator](../standards/makefile-conventions.md#repository-type-indicator); this document does not repeat the example, so a change to the format has one place to land.

Do not hand-write `OWNERS` from scratch, and do not copy another repository's. Ownership is declared once, in [`owners.yaml`](owners.yaml), and the files are generated from it. For a new repository:

1. Name the area it belongs to. A repository that continues an existing area reuses that area's row; a repository that starts one needs a new entry under `areas:` with at least two approvers and its reviewers, chosen by the tech leads from the people who will do the work. The reviewer and approver criteria in [Repository Ownership](owners.md) apply to everyone who joins that area afterwards.
2. Add the repository under `repos:` with a root (`""`) entry pointing at the area, and one entry per path that another area owns. A repository that ships an artifact needs `.tekton` under Release and packaging, or Prow falls back to the root approvers for its pipelines: `""` at `{area: Desire delivery, approvers: [desire-owners, tech-leads], reviewers: [desire-reviewers], labels: [area/desire-delivery]}` and `.tekton` at `{area: Release and packaging, approvers: [release-owners], reviewers: [release-reviewers], labels: [area/release]}`.
3. Run `make owners`. It refreshes the area table in [Repository Ownership](owners.md) and writes the `OWNERS` and `OWNERS_ALIASES` files for every repository to `hack/owners/out/`.
4. Copy the generated tree to its two destinations: into the new repository (the root files and the `OWNERS` for each sub-path), and into `core-services/prow/02_config/openshift-hyperfleet/<repo>/OWNERS` in `openshift/release`, where Prow's `approve` and `owners-label` plugins read it. A missing copy on the Prow side makes `/approve` and the area labels silently do nothing.
5. Create the area labels. `owners-label` only applies labels that already exist, and `hack/owners/labels.sh` creates them from `owners.yaml` in every listed repository; without it the `OWNERS` files are correct and the pull requests carry no `area/*` label, with nothing failing.

Send the `owners.yaml` change and the rendered table in a pull request here. In `openshift/release`, send `_pluginconfig.yaml`, `_prowconfig.yaml`, and the `OWNERS` copy. The generated tree goes in the new repository. `make verify-owners` fails when `owners.yaml` and the rendered table in [Repository Ownership](owners.md) disagree, or when the YAML is inconsistent; it does not look at the generated files, so step 3 is still the author's to remember.

---

## Branch Protection Configuration

### Default Branch

- Set `main` as the default branch

### Branch Protection Rules

The organisation owns this ruleset; a repository does not create its own.

- Ruleset: `hyperfleet-main-protection` (organisation ruleset, id 15199170)
- Enforcement status: **Active**
- Target: the default branch of every repository it lists
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
| Require an additional approval for unattributed pull requests | `true` (GitHub default) | Requires one more approval than the configured count when Copilot opens a pull request that is not attributed to a person; GitHub states it has no effect at a count of zero, so it is recorded here rather than relied on |
| Require conversation resolution | disabled | Review threads are a review concern, not a merge gate |
| Allowed merge methods | merge, squash, rebase | Tide squashes on merge; the other methods stay available for manual work |

The ruleset does not cover a new repository automatically. It lists its target repositories, and an organisation admin adds the new one under **Organization settings → Repository → Rulesets → `hyperfleet-main-protection` → Target repositories**. Until that happens the default branch is unprotected, whatever the repository settings say. Do not create a repository-level ruleset with the same name: it duplicates the organisation ruleset, drifts from it, and disappears as a reference the next time the organisation ruleset changes.

The ruleset gates the *shape* of a merge, not who signed off. With zero required approvals GitHub would accept a pull request nobody approved, and the extra-approval setting above has no effect at that count. The ruleset has no bypass actors, so it applies to organisation admins as much as to anyone else; it simply asks for no approval.

The approval requirement comes from Prow. Tide merges a pull request only when it carries the `lgtm` and `approved` labels, which the `OWNERS`-driven plugins set from an area approver, and the required contexts are green. That is a convention as much as a gate: a merge performed by hand, outside Tide, needs no label and is subject only to the status checks, and the labels are not universal either, since [trusted dependency updates and Konflux nudge pull requests](owners.md#how-a-merge-works) arrive already labelled for merge by the automation that opened them.

The ruleset carries no required status checks, and there is a second mechanism that does: Prow's branch protector. The `branch-protection` section of [`core-services/prow/02_config/_config.yaml`](https://github.com/openshift/release/blob/main/core-services/prow/02_config/_config.yaml) enables `protect-tested-repos`, so once a repository has jobs the protector adds classic branch protection to `main` with a required context for each presubmit that runs on every pull request — `ci/prow/validate-commits`, `ci/prow/lint`, `ci/prow/unit`, and `ci/prow/presubmits-integration` where that step exists — with `strict: false` and no required reviews. A presubmit restricted by `run_if_changed` or `skip_if_only_changed`, or marked `optional: true`, does not become a required context: Prow cannot require a status that may not exist on every pull request. Duplicating the required contexts in the ruleset would mean two lists to keep in sync, and a job renamed in `openshift/release` would block every merge until someone edited the ruleset.

The protector runs on a schedule, so a repository that has just merged its Prow configuration still has an unprotected `main` for a while. Until the protector has run, `gh api repos/openshift-hyperfleet/<repo>/branches/main/protection` answers `Branch not protected`, and a manual merge goes through with failing presubmits.

A repository without presubmits gets nothing from the protector, because there is no context of its own to require. That is the case where the `branch-protection` block in its `_prowconfig.yaml` asks for the `tide` context, described in [Prow CI](#prow-ci), and it is the only check such a repository needs.

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

Three pieces of configuration live in [openshift/release](https://github.com/openshift/release), all of them under `core-services/prow/02_config/$org/$repo/` or `ci-operator/config/$org/$repo/`.

- **The plugins**, in `_pluginconfig.yaml`. They provide `/lgtm`, `/approve`, `/hold`, `/assign`, and the `OWNERS`-driven labels. Without this file those commands do nothing and a pull request reports `no checks reported`.
- **The Tide query**, in `_prowconfig.yaml`. It declares which repositories Tide merges, and with which labels — for HyperFleet, `approved` and `lgtm`. The `branch-protection` block in the same file is where a repository asks for the `tide` required context.
- **The jobs**, in `ci-operator/config/$org/$repo/`. They provide the `ci/prow/*` contexts.

Follow [Onboarding a New Component for Testing and Merge Automation](release/test-release/onboarding-a-new-component-for-testing-and-merge-automation.md). It covers bootstrapping `_pluginconfig.yaml` with `make new-repo`, copying `OWNERS` into the same directory, and adding the presubmits.

The presubmits every HyperFleet Go repository carries are the commit-message check and the repository's own `make lint` and `make test`, so the Makefile targets are the contract: a target that does not exist in the repository fails the job.

Tide is the merge gate for pull requests: one merges only when Tide says it is mergeable, which means the `lgtm` and `approved` labels and green required contexts. Tide's verdict can also be required from GitHub as a status context named `tide`, which is what stops a merge made by hand. A repository with its own presubmits does not need it, because those contexts are the required checks; a repository without any declares it in `_prowconfig.yaml`:

```yaml
branch-protection:
  orgs:
    openshift-hyperfleet:
      repos:
        <repo>:
          branches:
            main:
              protect: true
              required_status_checks:
                contexts:
                - tide
```

Six repositories declare it today: `hyperfleet-api-spec`, `hyperfleet-api-spec-template`, `hyperfleet-release`, `coderabbit`, `.github`, and `renovate-config`.

---

## Konflux

Konflux builds and releases the artifacts. Two Applications exist: `hyperfleet` for images and `hyperfleet-charts` for charts. Each artifact is a Component named after the repository, and a repository that ships both has a Component in each Application.

| Artifact | PipelineRuns in the repository | Component | Output image |
| -------- | ------------------------------ | --------- | ------------ |
| Image | `<name>-push.yaml`, `<name>-tag.yaml` | `<name>` in `hyperfleet` | `quay.io/redhat-user-workloads/hyperfleet-tenant/hyperfleet/<name>` |
| Chart | `<name>-chart-push.yaml`, `<name>-chart-tag.yaml` | `<name>-chart` in `hyperfleet-charts` | `quay.io/redhat-user-workloads/hyperfleet-tenant/hyperfleet/<name>-chart` |

The PipelineRuns build on push to `main` and on version tags only, so they add no check to a pull request. PR validation is Prow's: a pull request shows the presubmit contexts from the Prow section above and nothing from Konflux. An empty check list means the Prow configuration is missing, not that Konflux has not been wired up yet.

Registration is not a click in the Konflux UI: it is an MR against the `releng/konflux-release-data` GitLab repository with a Component and an `ImageRepository` per artifact, the kustomization entry, the regenerated output, and the ReleasePlanAdmission component mapping. The files and their locations are listed in the [release configuration map](release/operations/configuration-map.md); the naming and pipeline conventions are in the [Konflux Release Pipeline Design](release/konflux-release-pipeline-design.md).

The order matters: that MR creates the tenant namespace and the Components the `.tekton` PipelineRuns refer to, so it has to merge before the first push to `main` can build. Until it does, the PipelineRun fails on a Component that does not exist yet, which looks like a broken pipeline rather than a missing registration.

---

## CodeRabbit

CodeRabbit reviews every pull request. The organisation configuration lives in [`openshift-hyperfleet/coderabbit`](https://github.com/openshift-hyperfleet/coderabbit), whose `.coderabbit.yaml` applies to every repository in the organisation that does not have its own, with `auto_review` enabled for the ones that are not drafts or work in progress. A repository must not add a local `.coderabbit.yaml`: it overrides the shared rules.

There is no setup step in the new repository: the App is installed at the organisation level, and a repository created today is reviewed on its first pull request. `hyperfleet-desire-store` was created and had its first pull request reviewed by `coderabbitai[bot]` minutes later, with no configuration in between. The lever, if a new repository is missed, is the App's repository access list under **Organization settings → GitHub Apps → CodeRabbit → Configure**, and only an organisation admin can change it.

Two behaviours are worth knowing before opening the first PR:

- A repository created minutes ago may not be picked up until CodeRabbit syncs its repository list, and a pull request opened in that window gets no review until someone comments `@coderabbitai review`. That is the normal first-PR step for a new repository, not a sign of a broken installation.
- The evidence that the wiring works is a walkthrough comment from `coderabbitai[bot]` on the pull request, not the absence of a check failure.

---

## Renovate

Dependency updates come from one of two services, and which one covers a repository depends on whether Konflux builds it. The repository side is identical in both cases: a `renovate.json` that extends the shared preset, whose format and policy are documented in [`openshift-hyperfleet/renovate-config`](https://github.com/openshift-hyperfleet/renovate-config). Copy the consumer example from that README rather than from here, so the `$schema` line and the preset name have one place to change.

| The repository ships | Service | Bot that opens the PRs |
| -------------------- | ------- | ---------------------- |
| A container image or a chart, registered in Konflux | MintMaker, which runs per Konflux tenant | `red-hat-konflux-kflux-prd-rh02` |
| Nothing Konflux builds | The hosted Renovate App | `renovate` |

Schedule, grouping, and update policy live in `renovate-config`, so a repository-level override is an exception that needs a reason in the PR. Coverage follows from the route above rather than from a setting in the repository: a repository registered as a Component in the `hyperfleet` Konflux tenant is covered by MintMaker with no further request, and one Konflux does not build depends on the hosted Renovate App's repository access list under **Organization settings → GitHub Apps → Renovate → Configure**, which an organisation admin edits. Either way the evidence is a dependency dashboard issue or the first dependency PR from the bot for the row that applies. A repository that falls through both opens no dependency PRs at all, which is easy to miss: `hyperfleet-e2e`, `hyperfleet-logger`, and `hyperfleet-broker` carry `renovate.json` and have no bot PRs. Watch the first run for `pre-commit` pins: the `rev: <sha>  # frozen: <tag>` format exists because Renovate once rewrote those pins to mutable tags.

---

## Who Can Perform Each Step

Some steps need more than repository admin, which is worth knowing before planning the work.

| Step | Performed by |
| ---- | ------------ |
| Create the repository and add the teams | Whoever creates the repository, with admin on it |
| Add the repository to the `hyperfleet-main-protection` ruleset | An organisation admin |
| Add the repository files and the scaffold | Any maintainer, through a PR |
| Declare the area in `owners.yaml` and copy the generated `OWNERS` | A PR against this repository, merged by an area approver |
| Prow plugins, Tide query, and jobs | A PR to `openshift/release`, approved by its release approvers |
| The `tide` required context, in `_prowconfig.yaml` | The same PR to `openshift/release` |
| Konflux registration | An MR to `releng/konflux-release-data`, reviewed by releng |
| CodeRabbit coverage | Automatic for a new repository; an organisation admin only if the bot never reviews |
| Dependency bot coverage | MintMaker follows the Konflux registration; otherwise an organisation admin adds the repository to the Renovate App |
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
- [ ] `OWNERS` and `OWNERS_ALIASES` are the ones generated from [`owners.yaml`](owners.yaml), not a copy from another repository

### Branch Configuration

- [ ] `main` is the default branch
- [ ] The repository is a target of the organisation ruleset: `gh api repos/openshift-hyperfleet/<repo>/rules/branches/main` reports `ruleset_source_type: Organization` and `ruleset_id` 15199170
- [ ] The ruleset blocks deletion and force pushes
- [ ] The ruleset requires a pull request and dismisses stale reviews on push
- [ ] The ruleset sets zero required approvals and no required status checks, as in the table above; the absence of bypass actors is a property of the organisation ruleset, which an organisation admin confirms
- [ ] `main` reports classic branch protection with the `ci/prow/*` contexts, which Prow's branch protector applies after the Prow configuration merges
- [ ] A repository without presubmits requires the `tide` context from its `_prowconfig.yaml` instead, and a repository with presubmits does not
- [ ] The approval gate is Prow's: Tide reports `Needs approved, lgtm labels` on a pull request that has neither

### Team Access

- [ ] `hyperfleet` team has Write access
- [ ] `automation-bots` team has Admin access

### CI and Automation

- [ ] `_pluginconfig.yaml` and `_prowconfig.yaml` exist in `core-services/prow/02_config/openshift-hyperfleet/<repo>/` in `openshift/release`, the latter with the Tide query, and `/lgtm` and `/approve` work on a PR
- [ ] `OWNERS` exists both in the repository and in `core-services/prow/02_config/openshift-hyperfleet/<repo>/`, generated from `owners.yaml` in both places
- [ ] `hack/owners/labels.sh` has run for the repository, and a PR carries its `area/*` label
- [ ] `ci-operator/config/openshift-hyperfleet/<repo>` exists, and a PR reports its presubmits instead of `no checks reported`, unless the repository deliberately has none
- [ ] Repositories that ship an artifact have their PipelineRuns in `.tekton/`, their Component registered before the first push to `main`, and that first build green
- [ ] `coderabbitai[bot]` commented on a PR, after the `@coderabbitai review` a brand-new repository needs on its first one
- [ ] A dependency PR or dependency dashboard issue exists from the bot that matches the repository: `red-hat-konflux-kflux-prd-rh02` when Konflux builds it, `renovate` when it does not
- [ ] No `pre-commit` pin was rewritten to a tag

---

## References

- [Repository Ownership](owners.md): areas, reviewers, approvers, and how a merge works
- [Makefile Conventions](../standards/makefile-conventions.md): standard targets and the repository type indicator
- [Pre-commit Hooks](pre-commit-hooks.md): the shared hook set
- [Onboarding a New Component for Testing and Merge Automation](release/test-release/onboarding-a-new-component-for-testing-and-merge-automation.md): the Prow procedure
- [Konflux Release Pipeline Design](release/konflux-release-pipeline-design.md): Applications, Components, and PipelineRun conventions
- [Release Configuration Map](release/operations/configuration-map.md): where each Konflux resource lives
- [Container Image Standard](../standards/container-image-standard.md): image build, FIPS, and runtime requirements
