# CodeRabbit Effectiveness Report

Observation period: **2026-05-08 to 2026-07-10** (3 sprints)

Reference period: **April 2026** (CodeRabbit on default configuration, before the central custom configuration on 2026-05-08)

Related: [HYPERFLEET-1021](https://redhat.atlassian.net/browse/HYPERFLEET-1021) |
[Automated PR review strategy](automated-pr-review-strategy.md)

## Executive Summary

CodeRabbit has been active org-wide since **2025-11-26** (its first review in the org was on
`hyperfleet-sentinel#13`), running on Red Hat's org-level default configuration. The central custom
configuration landed on **2026-05-08** (the [`coderabbit`](https://github.com/openshift-hyperfleet/coderabbit)
config repo, HYPERFLEET-1020), which marks the start of this observation period. This report therefore
compares CodeRabbit **on the default configuration** (through April 2026) against CodeRabbit **with the
central custom configuration** (May–July); there is no pre-CodeRabbit period in scope.

Over 3 sprints CodeRabbit reviewed **213 of 347 human-authored PRs (61.4%)** across the repositories where it
is active, posting **1,010 review findings**. Per CodeRabbit's own tracking, **672 of those findings
(66.5%) were accepted** — the suggestion was addressed in the code — meaning roughly two in three
findings are acted upon.

PR cycle times remained stable (median ~20h vs 18.8h with the default configuration in April, independently confirmed at 20.48h by
the team DevLake dashboard), while time to first human review improved from 3.1h to 1.3h — possibly
aided by CodeRabbit's PR summary giving reviewers a head start.

While CodeRabbit handles the heavy lifting of surface-level review (style, security patterns,
consistency), human review remains essential for architecture decisions, cross-component impact,
and project-specific convention enforcement that no automated tool can fully capture.

> **Sources:** Finding-level metrics (volume, acceptance, severity, category) are authoritative from
> the [CodeRabbit dashboard export](https://app.coderabbit.ai/dashboard/export). Cycle-time metrics are
> from the GitHub API, cross-checked against the
> [team DevLake dashboard](https://devtools.pages.redhat.com/n8n-pulumi-poc/#/?org=hybridplatforms&product=hypershiftakahostedcontrolplanes&team=openshift-hyperfleet&range=days60).
> See [Methodology](#methodology) and
> [Cross-reference and corroboration](#cross-reference-and-corroboration).

## PR Cycle Time Metrics

Data source: GitHub API for `hyperfleet-api` (primary component, highest PR volume).

| Metric | April 2026 (default config) | Observation Period (May-Jul, custom config) | Delta |
|---|---|---|---|
| Median PR cycle time | 18.8h | 20.3h | +1.5h (+8%) |
| Median time to first human review | 3.1h | 1.3h | -1.8h (-58%) |

> **Note on the reference period.** This is not a pre-CodeRabbit vs post-CodeRabbit comparison:
> CodeRabbit has been active org-wide since 2025-11-26, so there is no pre-CodeRabbit period with
> meaningful PR volume. April 2026 represents CodeRabbit running on Red Hat's org-level **default
> configuration**; the observation period represents CodeRabbit with the **central custom
> configuration** that landed on 2026-05-08. The comparison is therefore default-config vs
> custom-config, not with-vs-without CodeRabbit. These figures are computed from the GitHub API for
> consistency across both periods. The April figure is reported three ways depending on the source —
> 18.8h here (GitHub API, created→merged), 14.3h in HYPERFLEET-1021 (dashboard), and 35.3h in the
> DevLake dashboard (created→close, an outlier month with only 16 PRs closed). We keep the GitHub API
> figure for methodological consistency. Crucially, the **observation-period** cycle time agrees across
> sources (20.3h here vs 20.48h in DevLake), so the core finding is robust regardless of the reference
> choice.

### Monthly Breakdown

| Month | PRs | Median Cycle Time | Median First Human Review |
|---|---|---|---|
| April (default config) | 18 | 18.8h | 3.1h |
| May | 31 | 20.7h | 0.5h |
| June | 36 | 20.6h | 4.8h |
| July (partial) | 14 | 17.0h | 1.9h |

> **Note:** The first human review metric **excludes** CodeRabbit — it measures the time until a human
> reviewer submits a review. We omit "time to first approval" because most PRs merge without a formal
> GitHub `APPROVED` review, making that metric too sparse to be reliable.

## CodeRabbit Coverage

Source: CodeRabbit dashboard export (human-authored PRs, 2026-05-08 to 2026-07-10). "Coverage" is the share
of PRs that received at least one CodeRabbit comment, among repositories where CodeRabbit is active.

| Repository | Human PRs | CR Reviewed | Coverage |
|---|---|---|---|
| hyperfleet-api | 81 | 56 | 69.1% |
| hyperfleet-e2e | 49 | 30 | 61.2% |
| hyperfleet-adapter | 43 | 28 | 65.1% |
| architecture | 43 | 24 | 55.8% |
| hyperfleet-sentinel | 34 | 20 | 58.8% |
| kartograph | 21 | 8 | 38.1% |
| hyperfleet-api-spec | 19 | 13 | 68.4% |
| hyperfleet-infra | 19 | 12 | 63.2% |
| hyperfleet-claude-plugins | 17 | 9 | 52.9% |
| hyperfleet-api-spec-template | 8 | 6 | 75.0% |
| hyperfleet-broker | 6 | 4 | 66.7% |
| hyperfleet-logger | 3 | 1 | 33.3% |
| hyperfleet-credential-provider | 2 | 1 | 50.0% |
| maestro-cli | 2 | 1 | 50.0% |
| **Total** | **347** | **213** | **61.4%** |

CodeRabbit did not comment on ~39% of PRs. This includes PRs excluded by configuration (docs-only
changes, dependency bumps), trivially small PRs, and PRs merged before CodeRabbit processed them.

## Finding Analysis

All figures in this section come from the CodeRabbit dashboard export (human-authored PRs, 2026-05-08
to 2026-07-10). "Posted" is the number of review findings CodeRabbit raised; "accepted" is CodeRabbit's own
tracking of findings whose suggestion was addressed in the code.

### Acceptance Overview

- **1,010 findings posted**, **672 accepted** — an overall **66.5% acceptance rate**
- **338 findings not accepted (33.5%)** — see [Not-accepted findings](#not-accepted-findings) for what
  this does and does not mean
- Roughly **100 hours** of estimated review effort across PRs in the period (`estimated_review_minutes`)

### Severity Breakdown

| Severity | Posted | Accepted | Acceptance |
|---|---|---|---|
| Critical | 59 | 34 | 58% |
| Major | 721 | 479 | 66% |
| Minor | 176 | 133 | 76% |
| Trivial | 54 | 26 | 48% |
| **Total** | **1,010** | **672** | **66.5%** |

The bulk of findings are Major (consistency, error handling). Acceptance is highest for Minor findings
(76%) — small, unambiguous fixes — and lowest for Trivial (48%), which are the most likely to be
skipped as noise.

### Category Breakdown

| Category | Posted | Accepted | Acceptance |
|---|---|---|---|
| Functional correctness | 240 | 181 | 75% |
| Data integrity & integration | 233 | 145 | 62% |
| Maintainability & code quality | 194 | 135 | 70% |
| Stability & availability | 172 | 113 | 66% |
| Security & privacy | 156 | 91 | 58% |
| Performance & scalability | 15 | 7 | 47% |
| **Total** | **1,010** | **672** | **66.5%** |

Functional-correctness findings are both high-volume and highly accepted (75%) — CodeRabbit is most
useful at catching logic and correctness issues. Security findings are accepted less often (58%), but a
review of the not-accepted ones shows this is mostly because they are **deferred to a follow-up ticket
or out of scope** — e.g., an unbounded `io.ReadAll` flagged as CWE-400 in
[hyperfleet-api#316](https://github.com/openshift-hyperfleet/hyperfleet-api/pull/316#discussion_r3667542955)
("will do in the next ticket"), or plaintext RabbitMQ credentials flagged as CWE-922 in
[hyperfleet-adapter#264](https://github.com/openshift-hyperfleet/hyperfleet-adapter/pull/264#discussion_r3683145297)
where the fix requires an out-of-scope chart change — or **not applicable to the deployment model**
(a destructive-migration warning declined in
[hyperfleet-api#270](https://github.com/openshift-hyperfleet/hyperfleet-api/pull/270#discussion_r3514813150)
because the service is not long-running), rather than because CodeRabbit was wrong. Clear-cut security
findings (info leaks, input-length caps, fail-open decoding) were generally fixed.

### Engagement and Acceptance by Repository

| Repository | Findings Posted | Accepted | Acceptance |
|---|---|---|---|
| hyperfleet-api | 226 | 158 | 69.9% |
| kartograph | 130 | 76 | 58.5% |
| hyperfleet-e2e | 128 | 78 | 60.9% |
| architecture | 104 | 75 | 72.1% |
| hyperfleet-adapter | 90 | 51 | 56.7% |
| hyperfleet-api-spec | 87 | 59 | 67.8% |
| hyperfleet-infra | 77 | 54 | 70.1% |
| hyperfleet-claude-plugins | 67 | 61 | 91.0% |
| hyperfleet-sentinel | 64 | 46 | 71.9% |
| hyperfleet-broker | 18 | 8 | 44.4% |
| hyperfleet-api-spec-template | 10 | 4 | 40.0% |
| maestro-cli | 4 | 0 | 0.0% |
| hyperfleet-credential-provider | 4 | 2 | 50.0% |
| hyperfleet-logger | 1 | 0 | 0.0% |
| **Total** | **1,010** | **672** | **66.5%** |

Acceptance is strong across the high-volume repositories (69–72% for `hyperfleet-api`, `architecture`,
`hyperfleet-sentinel`, `hyperfleet-infra`). `hyperfleet-adapter` is the lowest among the busy repos at
56.7%, suggesting CodeRabbit is less calibrated for adapter patterns. Very low-volume repos
(`maestro-cli`, `hyperfleet-logger`) have too few findings to read into.

### Not-accepted findings

Of 1,010 findings, **338 (33.5%) were not accepted**. This is **not** a false-positive rate — a
not-accepted finding may have been a genuine issue the author chose not to address, a suggestion
deferred to a follow-up, a duplicate, or a true false positive. The CodeRabbit export does not
distinguish these, so we do not claim a false-positive figure from it.

As a rough proxy, a separate GitHub API heuristic (comments where CodeRabbit retracted its own
finding after human pushback) put explicit retractions at about **9%** of findings — reasonable for
an automated reviewer — but this is a keyword-matched estimate, not a validated sample.

## Cross-reference and corroboration

The finding metrics above are authoritative from the CodeRabbit dashboard export. We corroborate them
against two independent sources.

### GitHub API heuristic

An independent pass over `coderabbitai[bot]` comments via the GitHub API, using keyword matching for
severity and disposition, produced numbers consistent with — but lower than — the CodeRabbit export:
209 PRs reviewed (vs 213), 812 severity-marked findings (vs 1,010 posted), and 119 findings with an
*explicit* confirmation reply (vs 672 accepted). The heuristic undercounts because it only sees
findings that carry a severity keyword or an explicit "confirmed"/"thanks for the fix" reply; it
misses findings addressed silently in a new commit. The heuristic's 14.7% explicit-confirmation rate
is therefore best read as a **strict lower bound** on the 66.5% acceptance rate CodeRabbit reports.

### Team DevLake dashboard

The [team DevLake dashboard](https://devtools.pages.redhat.com/n8n-pulumi-poc/#/?org=hybridplatforms&product=hypershiftakahostedcontrolplanes&team=openshift-hyperfleet&range=days60)
(Unified Operational Intelligence) ingests the same GitHub repositories and
computes metrics independently. For `hyperfleet-api` over the observation period:

| Metric | This report | DevLake dashboard | Assessment |
|---|---|---|---|
| Median cycle time (observation) | 20.3h | 20.48h | Independent match — core finding confirmed |
| AI review tool | CodeRabbit | coderabbit (100% of AI reviews) | Confirms CodeRabbit is the only AI reviewer |
| Coverage | 69.1% (56/81 human PRs) | 96.8% (92/95 all PRs) | Different denominator — DevLake includes bot PRs |

### CodeRabbit enablement timeline

CodeRabbit has been active in the org far longer than this report's window. Its **first review in the
org was on 2025-11-26** (`hyperfleet-sentinel#13`, review at 17:24 UTC), and older open PRs were swept
in a batch over the following day — the signature of an initial app install. From then until the
observation period it ran on Red Hat's org-level **default configuration**; the CodeRabbit dashboard
export starting 2026-04-09 reflects that export window, not the enablement date.

| Date | Event |
|---|---|
| 2025-11-26 | CodeRabbit first active in the org (default configuration) |
| 2026-05-08 | Central custom configuration added ([`coderabbit`](https://github.com/openshift-hyperfleet/coderabbit) repo, HYPERFLEET-1020) — start of observation period |
| 2026-05-28 | Config tuned (HYPERFLEET-1074) |
| 2026-06-09 | Supply-chain hardening added (HYPERFLEET-1204) |

Consequently there is **no pre-CodeRabbit baseline** in scope: the org's PR history and CodeRabbit's
activity begin at essentially the same time. The DevLake dashboard's report of **161 AI review comments
across 18 PRs (81.8%) in April 2026** is simply CodeRabbit operating normally on the default
configuration, consistent with this timeline. This does not affect the finding analysis (scoped to the
observation period) nor the cycle-time analysis (derived independently of AI-review detection).

## Qualitative Observations

### What CodeRabbit Catches Well

- **Functional correctness**: highest-accepted category (75%) — logic errors, edge cases, incorrect
  conditionals
- **Data integrity**: incorrect error handling, missing rollback markers
- **Consistency**: import ordering, naming conventions, test patterns
- **Documentation drift**: outdated examples, missing code block language identifiers
- **API contract violations**: schema mismatches, missing required fields
- **Project-specific conventions**: CodeRabbit ingests the repo's `CLAUDE.md` and path instructions and
  tailors advice to the correct layer — e.g., it recommends `fmt.Errorf(...%w...)` wrapping for
  DAO/factory/constructor code while respecting the service-layer `*errors.ServiceError` boundary, and
  cites the project's own rules ("as per path instructions, ERR-01 to ERR-04") in
  [hyperfleet-api#310](https://github.com/openshift-hyperfleet/hyperfleet-api/pull/310#discussion_r3640102731),
  [#329](https://github.com/openshift-hyperfleet/hyperfleet-api/pull/329#discussion_r3733096912), and
  [#225](https://github.com/openshift-hyperfleet/hyperfleet-api/pull/225#discussion_r3437787316)

### What CodeRabbit Misses

- **Architecture-level design** (by construction): CodeRabbit reviews files largely in isolation, so it
  structurally cannot assess cross-component design decisions. This is an inherent limitation of
  file-scoped review, not something measured from specific findings.
- **Cross-component impact** (by construction): changes that affect Sentinel, Adapter, and API together
  require a human reviewer who understands the system as a whole — again a structural limit of per-file
  review rather than an observed failure.
- **Consistent test-coverage assessment**: CodeRabbit reliably flags test *structure* issues (e.g., an
  unpassable subtest in
  [hyperfleet-api#316](https://github.com/openshift-hyperfleet/hyperfleet-api/pull/316#discussion_r3667542930),
  non-table-driven loops in
  [#323](https://github.com/openshift-hyperfleet/hyperfleet-api/pull/323#discussion_r3693186397)), and it
  *sometimes* identifies missing scenarios and coverage gaps (untested changed logic in
  [#323](https://github.com/openshift-hyperfleet/hyperfleet-api/pull/323#discussion_r3693186397); a
  business-logic verification gap, CWE-840, in
  [#291](https://github.com/openshift-hyperfleet/hyperfleet-api/pull/291#discussion_r3577216073)) — but
  this scenario-level analysis is inconsistent, so judging whether the *right* scenarios are covered
  still needs a human.

### Team Interaction Patterns

- `hyperfleet-claude-plugins` has the highest acceptance (91%) — its findings are largely
  unambiguous config/docs fixes
- Core service repos land in a healthy 69–72% acceptance band (`hyperfleet-api`, `architecture`,
  `hyperfleet-sentinel`, `hyperfleet-infra`)
- `hyperfleet-adapter` is the lowest among busy repos (56.7%), suggesting CodeRabbit is less
  calibrated for adapter patterns
- Security findings are accepted less often (58%), mostly because the not-accepted ones are deferred to
  follow-up tickets or fall outside a PR's scope (e.g.,
  [hyperfleet-api#316](https://github.com/openshift-hyperfleet/hyperfleet-api/pull/316#discussion_r3667542955),
  [hyperfleet-adapter#264](https://github.com/openshift-hyperfleet/hyperfleet-adapter/pull/264#discussion_r3683145297)),
  not because they are wrong
- Most teams interact with CodeRabbit conversationally, replying to explain design decisions rather
  than dismissing outright

## Recommendation

### Keep CodeRabbit and reinforce human review

CodeRabbit provides clear value as a **first-pass automated reviewer** that handles the
heavy lifting:

1. **66.5% acceptance rate** (672 of 1,010 findings acted upon) — the majority of its findings
   result in real code changes
2. **Strong functional-correctness catch rate** (75% acceptance) — it is most useful exactly where it
   matters most
3. **High engagement** — the team treats it as a useful reviewer, not noise
4. **Instant feedback** — CodeRabbit reviews appear within minutes of PR creation

However, **human review remains indispensable**. The data shows that CodeRabbit's strengths
are concentrated in surface-level and correctness concerns — style, consistency, contract
validation, and localized logic bugs. The areas where human reviewers add irreplaceable value
include:

- **Architecture and design decisions** that span multiple components
- **Emerging conventions** not yet captured in configuration or `CLAUDE.md` (CodeRabbit follows the
  documented rules well, but cannot enforce conventions that have not been written down yet)
- **Business logic correctness** — understanding *why* the code exists, not just *how* it's written
- **Knowledge sharing** — code review is how the team builds shared understanding of the codebase
- **Mentorship** — junior engineers benefit from human feedback that contextualizes suggestions

The lower acceptance in `hyperfleet-adapter` (56.7%) suggests CodeRabbit is less calibrated there, so
its suggestions should be validated by a human who knows the codebase. (The 58% for security findings,
by contrast, mostly reflects findings deferred or out of scope rather than miscalibration — see the
[Category Breakdown](#category-breakdown).) Automated review accelerates the process; it does not
replace the judgment that comes from understanding the system end-to-end.

### Action Items

1. Close HYPERFLEET-1021 — observation period complete, data supports keeping CodeRabbit
2. Update `.coderabbit.yaml` — improve calibration for adapter repos (lowest acceptance at 56.7%) by
   adding adapter-specific path instructions
3. Re-evaluate only if the CodeRabbit configuration changes at the org or Red Hat level

## Methodology

- **Primary finding source**: [CodeRabbit dashboard export](https://app.coderabbit.ai/dashboard/export)
  (from the [CodeRabbit dashboard summary](https://app.coderabbit.ai/dashboard/summary)) — per-PR counts
  of comments posted and accepted, broken down by severity and by category. "Accepted" is CodeRabbit's
  own measure of whether a suggestion was addressed in the code.
- **Cycle-time source**: GitHub API, cycle time calculated from PR `created_at` to `merged_at`;
  primary repo `hyperfleet-api` (highest human PR volume)
- **Time to first human review**: first non-bot, non-pending review `submitted_at` minus `created_at`;
  **excludes** `coderabbitai[bot]`
- **Corroboration sources**: (1) an independent GitHub API heuristic over `coderabbitai[bot]` comments
  (severity/disposition by keyword matching), used as a conservative lower bound; (2) the
  [team DevLake dashboard](https://devtools.pages.redhat.com/n8n-pulumi-poc/#/?org=hybridplatforms&product=hypershiftakahostedcontrolplanes&team=openshift-hyperfleet&range=days60)
  (Unified Operational Intelligence), which computes PR and AI-review metrics independently
- **Scope**: human-authored PRs only; bot-authored PRs (Konflux/MintMaker/Dependabot) excluded
- **Observation period**: 2026-05-08 to 2026-07-10 (CodeRabbit with the central custom configuration);
  April 2026 used as a default-configuration reference. CodeRabbit has been active org-wide since
  2025-11-26, so there is no pre-CodeRabbit baseline in scope
