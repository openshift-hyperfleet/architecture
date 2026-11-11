---
Status: Active
Owner: HyperFleet Team
Last Updated: 2026-11-11
---

# Repository Ownership

> Who reviews and who approves changes in each area of the HyperFleet repositories, how a merge works, and the criteria for becoming a reviewer or an approver. The area table below is generated from [`owners.yaml`](owners.yaml), which is the source of truth for every `OWNERS` file in the organisation.

## Summary

Every area of code has named owners: two or more **approvers** and a wider pool of **reviewers**, declared in `OWNERS` files that Prow reads. Review requests go to the people who know the area. A merge needs one approval, from an approver for every path the change touches. Reviewer and approver status is earned against the criteria in this document and nothing else.

## The two roles

These are Prow's own roles. Ownership is by path: a repository has one set of names at the root and different names for the directories that need them. A PR touching two areas needs an approver from each.

| Role | What it means | Where it lives |
| ---- | ------------- | -------------- |
| **Reviewer** | You know the area well enough to give a substantive first review. Prow requests you on PRs in the area automatically. Your approving review sets `lgtm`, and an approver still has to sign off. | `reviewers` in the area's `OWNERS` file |
| **Approver** | You can be the last check on the area. Your `/lgtm` or approving review merges the PR on its own. You are accountable for what merges into the area. | `approvers` in the area's `OWNERS` file |

Approvers are also reviewers. The reviewer pool is where people grow into an area, and the approver set is the gate.

## How a merge works

Two things happen automatically when a PR is opened, and neither gates the merge:

- **Labels.** The `owners-label` plugin reads the `labels` field of every `OWNERS` file covering a changed file and adds those labels to the PR, for example `area/tenancy` and `area/api` for a change under `pkg/tenant`.
- **Reviewer requests.** The `blunderbuss` plugin requests two reviewers, picked at random from the `reviewers` of the closest `OWNERS` file for each touched path.

Review requests and `/assign` reach people as GitHub notifications. To get them as Slack direct messages, connect the GitHub app in Slack and turn on real-time alerts under scheduled reminders in your GitHub settings. A scheduled reminder on the `hyperfleet` GitHub team also posts the PRs waiting for review to the team channel on weekdays.

Then the merge itself:

1. Anyone in the area's reviewer or approver pool reads the PR and either requests changes or approves.
2. If the person who approves is an **area approver** for every touched path, their `/lgtm` or GitHub approving review sets both `lgtm` and `approved`, and Tide merges when CI is green. One person, but the right person.
3. If the person who approves is a **reviewer**, their approval sets `lgtm` only. They `/assign` an area approver, and the approver's `/approve` completes it.

Rules that go with it:

- **No self-approval.** An approver's own PR needs another approver.
- **One approval, not two.** A second required signature costs more than it returns: every rebase wipes the first approval and the PR queues twice. The gate is who the one person is, not how many there are. An approver who wants a second review on a risky change (migrations, tenant isolation, release plumbing, RBAC) asks for it on the PR with `/hold` until it lands.
- **Small PRs are the norm.** Over about 400 non-generated lines, add a short review plan to the description. Over 1,000, explain why it cannot be split.
- **Emergencies.** If no area approver is available to fix a broken `main` or a live incident, a tech lead approves and says so in the PR.
- **Bot PRs are unchanged.** Trusted non-major dependency updates arrive labelled for merge and Tide merges them after CI. Updates labelled `manual-review-required` wait for a human `/lgtm`, which now has to come from an approver for the files they touch. Konflux nudge PRs on the operator merge on their own label.
- **Squash on merge.** Tide squashes the PR into one commit titled from the PR title, so the PR title carries the JIRA key and follows the commit standard. Commits inside the PR do not reach `main`.

## Areas and owners

The tech leads sit in every root approver set as the fallback, not the routine merger, and are not auto-requested as reviewers. Where an area is left with one named approver, the tech-leads alias covers it until someone meets the criteria below.

<!-- owners-table:start -->
| Area | Paths | Approvers | Reviewers |
|---|---|---|---|
| API | hyperfleet-api root | Dmitrii (kuudori), Phuongnhat (pnguyen44) | Tirth (tirthct), Michaela (Mischulee), Mallory (ma-hill), Martin (mliptak0), Leonardo (ldornele), Rafael (rafabene) |
| Tenancy and auth | `pkg/tenant`, `pkg/auth`, `pkg/middleware`; e2e `e2e/auth` | Phuongnhat (pnguyen44), Martin (mliptak0) | Dmitrii (kuudori), Michaela (Mischulee) |
| Generic model | `pkg/dao`, `pkg/db`, `pkg/registry`, `pkg/services`, `pkg/handlers` | Dmitrii (kuudori), Phuongnhat (pnguyen44) | Tirth (tirthct), Michaela (Mischulee), Mallory (ma-hill), Martin (mliptak0) |
| Search | `pkg/validation`, `pkg/validators`, `pkg/api` | inherits Generic model | Michaela (Mischulee), Mallory (ma-hill), Martin (mliptak0) |
| Contracts | hyperfleet-api-spec, hyperfleet-api-spec-template, `openapi/` | Angel (rh-amarin), Martin (mliptak0), Dmitrii (kuudori), Ciaran (ciaranRoche) | Phuongnhat (pnguyen44), Michaela (Mischulee), Tirth (tirthct) |
| Adapter framework | hyperfleet-adapter root | Angel (rh-amarin), Rafael (rafabene), Dmitrii (kuudori) | Michal (Ruclo), Michaela (Mischulee), Martin (mliptak0), Tirth (tirthct) |
| Desire delivery | adapter `internal/desireclient`, `internal/transportclient`, `internal/transportregistry`; hyperfleet-applier | Dmitrii (kuudori), Angel (rh-amarin), Phuongnhat (pnguyen44) | Michal (Ruclo), Mallory (ma-hill), Tirth (tirthct) |
| Sentinel | hyperfleet-sentinel | Phuongnhat (pnguyen44), Dmitrii (kuudori), Angel (rh-amarin) | Tirth (tirthct), Michal (Ruclo), Leonardo (ldornele), Martin (mliptak0) |
| Broker | hyperfleet-broker | Angel (rh-amarin), Dmitrii (kuudori) | Tirth (tirthct), Phuongnhat (pnguyen44), Michaela (Mischulee) |
| Gateway | infra `helm/hyperfleet-gateway`, `helm/network-policies`, `helm/mock-oidc` | Martin (mliptak0), Dmitrii (kuudori) | Leonardo (ldornele), Phuongnhat (pnguyen44) |
| Observability | `pkg/telemetry`, `pkg/metrics`, `charts/dashboards`; operator `internal/metrics`, `internal/servicemonitor`, `config/prometheus` | Phuongnhat (pnguyen44), Dmitrii (kuudori) | Leonardo (ldornele), Tirth (tirthct), Michal (Ruclo) |
| Release and packaging | `.tekton` everywhere; operator `catalog`, `config/manifests`, `validators`; hyperfleet-release | Mallory (ma-hill), Dmitrii (kuudori) | Tirth (tirthct), Michaela (Mischulee) |
| E2E | hyperfleet-e2e; infra `helmfile` | Dmitrii (kuudori), Mallory (ma-hill) | Phuongnhat (pnguyen44), Tirth (tirthct), Michaela (Mischulee), Martin (mliptak0) |
| Performance | e2e `perf` | Phuongnhat (pnguyen44), Dmitrii (kuudori) | Tirth (tirthct), Mallory (ma-hill) |
| Operator | hyperfleet-operator root | Dmitrii (kuudori), Ciaran (ciaranRoche), Rafael (rafabene), Angel (rh-amarin) | Tirth (tirthct), Mallory (ma-hill), Rafael (rafabene), Leonardo (ldornele), Michal (Ruclo) |
| Infra | hyperfleet-infra root, everything not listed under Gateway, E2E or OCI | Mallory (ma-hill), Dmitrii (kuudori), Rafael (rafabene) | Martin (mliptak0), Phuongnhat (pnguyen44), Tirth (tirthct) |
| OCI | infra `terraform/oci`, `functions/oci-ci-sweep` | Rafael (rafabene), Ciaran (ciaranRoche) | Phuongnhat (pnguyen44), Leonardo (ldornele), Michaela (Mischulee) |
| Team tooling | hyperfleet-claude-plugins, hyperfleet-hooks, coderabbit, .github | Rafael (rafabene), Phuongnhat (pnguyen44) | Dmitrii (kuudori), Tirth (tirthct) |
| Architecture | architecture repository | Ciaran (ciaranRoche), Michael (mbrudnoy), Rafael (rafabene), Angel (rh-amarin) | Dmitrii (kuudori), Phuongnhat (pnguyen44), Tirth (tirthct), Leonardo (ldornele), Mallory (ma-hill), Martin (mliptak0), Michal (Ruclo), Michaela (Mischulee) |
| Platform libraries | hyperfleet-logger, hyperfleet-credential-provider, renovate-config | Dmitrii (kuudori), Mallory (ma-hill) | Michal (Ruclo), Martin (mliptak0) |
<!-- owners-table:end -->

## The criteria

<!-- owners-criteria:start -->
**Reviewer and approver status in an area follows the criteria below and nothing else. Title, level, tenure and team do not count, for anyone, including the tech leads.**

The bar is deliberately concrete. It is sized for a team of ten, and the shape is the Kubernetes community ladder: contribute, review, get sponsored, and keep doing it.

### Reviewer in an area

You are ready when all of these are true:

1. You have authored **five PRs** that merged in the area.
2. You have given **five reviews** in the area with comments you wrote yourself. Running the review plugin is fine and encouraged, but the findings you post are yours, and you have read the diff.
3. One current approver of the area **sponsors** you.

### Approver in an area

You are ready when all of these are true:

1. You have been a reviewer in the area for **at least two sprints**.
2. You have been the **primary reviewer on ten PRs** in the area. At least three were substantial (a design change, or over 300 lines), and your review changed at least some of them.
3. You have **shipped one story end to end** in the area with a reviewer other than the area's most active approver, or you have written a design-level change for it (an ADR, a design doc, or the story decomposition of an epic).
4. You know the **tests that cover the area**: which suites exercise it, what they do and do not check, and where a change would need a new one.
5. An existing approver **nominates** you in a PR to `owners.yaml`, and no other approver objects within three working days.

### Staying an approver

- An approver with **no reviews in the area for two sprints** moves back to the reviewer alias at the next sweep. Nothing is lost: review in the area for a sprint and ask, and you are re-added without re-qualifying if it is within six months.
- On loan or extended leave, tell the other approvers in the area and either `/uncc` yourself or move to the reviewer alias for the duration.
- Leaving the team removes you from every alias in the same PR that removes your access.

### How the table was set

The same criteria were applied to everyone at launch, using the last three sprints of authored PRs and reviews. Nobody is an approver on title or on history alone. The same criteria, applied the same way, are used at every quarterly sweep.

<!-- owners-criteria:end -->

### How to apply

Open a PR to `owners.yaml` that adds you to the alias, and cite the PRs and reviews that meet each criterion with links. The sponsor (for reviewer) or nominator (for approver) approves the PR. The evidence is the PR list, nothing else is asked for. Then regenerate the `OWNERS` files (see [Changing the table](#changing-the-table)).

### Questions

- **I'm a senior, why am I only a reviewer in this area?** Because approval follows contribution in the area, not level. The path is above and takes about two sprints of doing the work.
- **What about partner engineers?** Same criteria. An engineer from another team who meets the reviewer bar in an area belongs in that alias.
- **What if both approvers are out?** The tech leads are in every root approver set as the fallback. That is what they are for.
- **Can I still review outside my areas?** Yes, please do. Your review counts and is how you grow into the area; an area approver completes the merge.

## What a review and an approval mean

The [working agreement](working-agreement.md#code-review) says review for correctness, consistency, clarity and learning. This adds what the roles commit to.

### Reviewers

- **Acknowledge within four working hours, substantive review within one business day.** If you cannot, say so on the PR, `/uncc` yourself and `/auto-cc` so Blunderbuss requests someone else from the area's pool.
- **Read the whole diff.** A review that only covers the first file is not a review.
- **Say what kind of comment it is.** Every comment is one of: fix before merge, follow-up (with a ticket or a named place it is tracked), or FYI. Pre-production, only reproducible failures block.
- **Aim for about four reviews a week.** That is roughly three hours. It is not forty.

### Approvers

Approving means: I read the whole diff, I checked the behavioural claims against the code, and I would be comfortable debugging this in production.

- **Do not approve what you have not verified.** If the PR says the API hard-deletes kinds without required adapters, you have looked at the function or the test that proves it.
- **Say when you are out of depth.** "This touches the broker, get one of its approvers" is a good approver comment.
- **Approve the change, not the author.** A senior's PR gets the same read as an associate's.

### Authors

- **You own every claim in your PR.** If a tool wrote the description, the design note or the ADR, it is still yours. Behavioural claims cite a file and line or a test. If you cannot point at the code for a claim, take the claim out.
- **Read your own diff before you ask a person to.** CodeRabbit will get there first, and that is fine. What it cannot do is decide whether the change is right, and a green bot is not the same as ready for review.
- **Keep it small.** A 200-line PR gets reviewed today. A 2,000-line PR waits a week, and the review it gets is worse.
- **Answer every comment**, and when you mark something fixed, check the fix across the whole change, not only the line the reviewer pointed at.
- **No force-push or amend once review has started.** Push the fix as a new commit. A rewritten branch throws away the reviewer's "changes since your last review" view. Squash on merge keeps `main` clean, so the branch history does not need to be tidy, only the PR title does. Rebase only when you have to, for example to resolve a conflict.

## Mechanics

- `OWNERS_ALIASES` at each repository root holds the names. `OWNERS` files reference alias names only, so a change of owner is a regenerated file per repository.
- Sub-directory `OWNERS` files exist only where ownership genuinely differs from the root. Everything else inherits the root.
- Every `OWNERS` file carries a `labels` entry so `owners-label` tags PRs by area. The labels are created in every repository by `hack/owners/labels.sh`.
- Prow's `approve` plugin runs with `lgtm_acts_as_approve` and `require_self_approval`, and `lgtm` with `review_acts_as_lgtm`, in the shared openshift/release configuration. No plugin setting changes for this model; the `OWNERS` files are the whole change.
- Blunderbuss is configured once for all of openshift/release (two reviewers per PR, drafts ignored). It reads `reviewers` only, which is why approvers are listed there too.

### Changing the table

1. Open a PR to [`owners.yaml`](owners.yaml) in this repository. For a role change, follow [How to apply](#how-to-apply).
2. Run `make owners` to regenerate the table in this document, the copy of the criteria in the [working agreement](working-agreement.md#repository-roles-reviewer-and-approver), and the `OWNERS` files under `hack/owners/out/`. `make verify-owners` fails when the table or that copy is stale, or when any path's approvers or reviewers differ from its area's row, so the three cannot drift apart. The criteria are edited here only. The scripts under `hack/owners/` run on the bash 3.2 that macOS ships.
3. Once merged, run `hack/owners/open_prs.sh` to open the `OWNERS` PRs in the affected repositories.

## References

- Prow approve plugin and OWNERS semantics: <https://docs.prow.k8s.io/docs/components/plugins/approve/approvers/>
- Kubernetes community membership ladder, which the criteria are adapted from: <https://github.com/kubernetes/community/blob/master/community-membership.md>
- Google's code review guide on speed: <https://google.github.io/eng-practices/review/reviewer/speed.html>
