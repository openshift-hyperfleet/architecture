---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-10-16
---

# Trigger HyperFleet E2E Jobs via Gangway API

## Overview

The HyperFleet E2E periodic jobs deploy the platform from **pre-built component images** (built
and published by Konflux to `quay.io/redhat-services-prod/hyperfleet-tenant/...`) and run the
E2E suite against them. They do **not** build images — they pull a chosen image **tag**, so you
select what to test with the `MULTISTAGE_PARAM_OVERRIDE_*_IMAGE_TAG` parameters.

This guide shows how to trigger these jobs on demand through the OpenShift CI
[Gangway REST API](https://docs.ci.openshift.org/docs/how-tos/triggering-prowjobs-via-rest/#triggering-a-periodic-job),
without waiting for their schedule:

- **Nightly** — `tier0` / `tier1` / `tier2` suites and the `perf` suite, scheduled daily, runnable on demand.
- **Release Candidate (RC)** — manual-only validation run (`@yearly` cron, i.e. it never fires
  on its own), driven by image-tag and namespace overrides.

All of these are **periodic** jobs and use `job_execution_type: "1"`.

## The jobs

| Job name | Schedule | Scope |
|----------|----------|-------|
| `periodic-ci-openshift-hyperfleet-hyperfleet-e2e-main-e2e-tier0-nightly` | `30 9 * * *` | `tier0` |
| `periodic-ci-openshift-hyperfleet-hyperfleet-e2e-main-e2e-tier1-nightly` | `30 11 * * *` | `tier1 && !perf` |
| `periodic-ci-openshift-hyperfleet-hyperfleet-e2e-main-e2e-tier2-nightly` | `30 13 * * *` | `tier2` |
| `periodic-ci-openshift-hyperfleet-hyperfleet-e2e-main-e2e-perf-nightly` | `30 7 * * *` | `perf` |
| `periodic-ci-openshift-hyperfleet-hyperfleet-e2e-main-rc-e2e-rc-e2e` | `@yearly` (manual only) | `tier0 \|\| tier1` |

The source of truth for these is the
[openshift/release](https://github.com/openshift/release) repo at
`ci-operator/jobs/openshift-hyperfleet/hyperfleet-e2e/openshift-hyperfleet-hyperfleet-e2e-main-periodics.yaml`
(generated) and the matching `__e2e.yaml` / `__rc-e2e.yaml` configs.

## Prerequisites

- Authenticated to the OpenShift CI (`app.ci`) cluster, with a token available via
  `oc whoami -t`.
  - To get one: open the
    [OpenShift CI console](https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com/),
    top-right user menu → **Copy login command** → **Display Token**, then run the printed
    `oc login ...` command.
- `curl` and `jq` available locally.

The Gangway endpoint and request shape are the same for every job:

```text
POST https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/v1/executions
Authorization: Bearer <token>
Content-Type: application/json
```

The request body carries the `job_name`, `job_execution_type` (always `"1"` for these periodic
jobs), and, optionally, parameter overrides under `pod_spec_options.envs`.

## Triggering a nightly job

To run a nightly suite immediately with its default image tags (`latest`):

```bash
curl -X POST \
  -H "Authorization: Bearer $(oc whoami -t)" \
  -H "Content-Type: application/json" \
  -d '{
    "job_name": "periodic-ci-openshift-hyperfleet-hyperfleet-e2e-main-e2e-tier0-nightly",
    "job_execution_type": "1"
  }' \
  https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/v1/executions
```

Swap `tier0` for `tier1` or `tier2` to run a different suite. To test specific image tags
instead of `latest`, add overrides (see [Parameters](#parameters)):

```bash
curl -X POST \
  -H "Authorization: Bearer $(oc whoami -t)" \
  -H "Content-Type: application/json" \
  -d '{
    "job_name": "periodic-ci-openshift-hyperfleet-hyperfleet-e2e-main-e2e-tier0-nightly",
    "job_execution_type": "1",
    "pod_spec_options": {
      "envs": {
        "MULTISTAGE_PARAM_OVERRIDE_API_IMAGE_TAG": "<tag>",
        "MULTISTAGE_PARAM_OVERRIDE_ADAPTER_IMAGE_TAG": "<tag>",
        "MULTISTAGE_PARAM_OVERRIDE_SENTINEL_IMAGE_TAG": "<tag>"
      }
    }
  }' \
  https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/v1/executions
```

## Triggering the RC E2E job

The RC job exists to validate a specific release candidate — you point it at the component image
tags you want to certify. It is the same flow as the nightly, just with the override parameters
filled in.

A minimal trigger pinning all three components to a candidate tag:

```bash
curl -X POST \
  -H "Authorization: Bearer $(oc whoami -t)" \
  -H "Content-Type: application/json" \
  -d '{
    "job_name": "periodic-ci-openshift-hyperfleet-hyperfleet-e2e-main-rc-e2e-rc-e2e",
    "job_execution_type": "1",
    "pod_spec_options": {
      "envs": {
        "MULTISTAGE_PARAM_OVERRIDE_API_IMAGE_TAG": "v0.2.0-rc1",
        "MULTISTAGE_PARAM_OVERRIDE_ADAPTER_IMAGE_TAG": "v0.2.0-rc1",
        "MULTISTAGE_PARAM_OVERRIDE_SENTINEL_IMAGE_TAG": "v0.2.0-rc1",
        "MULTISTAGE_PARAM_OVERRIDE_NAMESPACE_PREFIX": "rc-e2e"
      }
    }
  }' \
  https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/v1/executions
```

Add `MULTISTAGE_PARAM_OVERRIDE_E2E_REF` to the `envs` block to run the suite from a specific
E2E test ref rather than the one baked into the test image. If you trigger the RC job often,
wrapping this call in a small script that reads the tags from environment variables is
straightforward — but not required.

## Parameters

Both the nightly and RC jobs run the `openshift-hyperfleet-e2e` workflow and accept the same
overrides under `pod_spec_options.envs`. Any omitted parameter keeps the job's configured
default.

| Parameter | Purpose | Default |
|-----------|---------|---------|
| `MULTISTAGE_PARAM_OVERRIDE_API_IMAGE_TAG` | Image tag for `hyperfleet-api` | `latest` |
| `MULTISTAGE_PARAM_OVERRIDE_ADAPTER_IMAGE_TAG` | Image tag for `hyperfleet-adapter` | `latest` |
| `MULTISTAGE_PARAM_OVERRIDE_SENTINEL_IMAGE_TAG` | Image tag for `hyperfleet-sentinel` | `latest` |
| `MULTISTAGE_PARAM_OVERRIDE_NAMESPACE_PREFIX` | Prefix for the namespaces the run creates | `e2e` (nightly) / `rc-e2e` (RC) |
| `MULTISTAGE_PARAM_OVERRIDE_E2E_REF` | Git ref of the E2E test code to run | The ref baked into the test image |

Image tags refer to tags published by Konflux in the component repos under
`quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/`.

## Verifying execution

1. A successful POST returns JSON containing the new execution `id`.
2. Watch the run on the [Prow dashboard](https://prow.ci.openshift.org/), filtered by job name,
   e.g.
   `https://prow.ci.openshift.org/?job=periodic-ci-openshift-hyperfleet-hyperfleet-e2e-main-rc-e2e-rc-e2e`.
3. Open the run to follow the build log and **Artifacts**.
4. Results are also posted to the `#hyperfleet-e2e-status` Slack channel.

## Troubleshooting

| Symptom | Cause / Fix |
|---------|-------------|
| `401 Unauthorized` | Token missing or expired. Re-run `oc whoami -t` (re-login to `app.ci` if needed) and resend. |
| `failed to find associated periodic job` / job not found | The `job_name` in the body is wrong. Copy it exactly from the [jobs table](#the-jobs) or the periodics config. |
| HTTP 500 with no `grpc-message` | The job name must be an existing **periodic** job. Re-check against the Prow dashboard. |
| Job runs but tests the wrong build | Set the `MULTISTAGE_PARAM_OVERRIDE_*_IMAGE_TAG` values — by default the job pulls `latest`. |

## References

- [Triggering ProwJobs via REST — periodic](https://docs.ci.openshift.org/docs/how-tos/triggering-prowjobs-via-rest/#triggering-a-periodic-job)
- Generated periodics config:
  [`ci-operator/jobs/openshift-hyperfleet/hyperfleet-e2e/`](https://github.com/openshift/release/tree/master/ci-operator/jobs/openshift-hyperfleet/hyperfleet-e2e)
- [Add Hyperfleet E2E CI Job in Prow](add-hyperfleet-e2e-ci-job-in-prow.md) — how these jobs and
  their step registry are configured
