---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-01-22
---

# Sentinel pulses, adapter behavior and API resource status


---

## Overview

This document proposes changes to the current system design for how API and adapter behaves by introducing new API resource root conditions and detailing status reports by adapters and transitions.

## TL;DR; Proposal

**Goal**: Disambiguate the meaning of the `status.phase=Ready/NotReady`, today it conveys:

- new desired generation not reconciled
- system broken

**Proposal**:

- Introduce root level conditions on API resources (clusters, nodepools)
  - `Available`: System is running
    - Contains an additional `observed_generation` property
    - All adapters reported `Available==True` at `observed_generation`
    - Kind of a "last known good configuration"
  - `Ready`: System is running AND at the latest spec generation

- Simplifications **for the MVP**
  - Since we don't have k8s lifecycle management in the adapter framework
  - For the adapter task jobs
    - They will retry until successful completion
    - They don't set TTL to delete jobs (adapter will use the completion value)

## System analysis

Sentinel behaviour changes slightly, now watches for the resources `Ready` condition
Sentinel will publish messages whenever:

- User changes the cluster/nodepool spec
- Time from adapter `last_report_time` has exceeded some TTL
  - For `Ready==False` clusters/nodepools, TTL=10sec
  - For `Ready==True` clusters/nodepools, TTL=30min

Adapters performs some actions in their "resources" phase in order to query the state of the resource and then reports to the HyperFleet API with at least 3 mandatory conditions:

- Applied: the work to be done has been started
- Available: The status of the resource for that adapter is successful/failed
- Health: Additional info about the health of the probe

The actions performed in the "resources" phase make calls to an API:

- k8s to create k8s objects like CRs or Job
- Maestro API (gRPC)
- Other APIs

After the actions, the state is collected to report to the HyperFleet API
Some adapter work will happen asynchronously, the value to return status will have `Available=Unknown`

Scenarios for adapter receiving a message to process a resource:

- API State:
  - No Available condition exists for the adapter in the API
  - There is an Available condition with observed_generation < spec.generation
  - There is an Available condition with observed_generation == spec.generation
- Adapter task resource for current generation:
  - Does not exists
  - Exists
    - Is still in progress
    - Finished successful/failure

#### K8s jobs

Our decision is to avoid putting too much orchestration in k8s primitives, therefore some sort of resource lifecycle management is required in the adapter framework.

- On receiving a message and passing the precondition, the adapter has to decide:
  - Creating a new job
  - Reusing an existing job with a successful completion
  - Recreating a job in case of errors or TTL exceeded

For the MVP:

- The lifecycle management of k8s resources is not implemented yet in the adapter framework
- We will create k8s jobs that will retry indefinitely until success
  - Since we can not recreate jobs, if we allow it finishing with failure, the adapter will report `Available=False` always
  - With retries, the adapter will report `Available=Unknown` while retrying.

#### CRDs

Applying a CRD or manifest (like namespace manifest) should be manage by the same lifecycle management as for jobs.

The adapter should detect if the work to be done by the adapter task is still in progress for the CRD.

For example some k8s objects use `generation` and `status.observedGeneration` to differentiate.

#### API calls

If using an arbitrary API call in the adapter resource phase, the calling service must provide a way to determine work in progress, similar to the CRDs case.

### Use cases solved by the new proposal

1. In-progress adapter task response
    1. cluster `Ready` at `gen=1`
    1. At 30m, event to refresh status for `gen=1`
    1. Adapter starts a new adapter task, and will report:
      - `Applied=True`
      - `Available=Unknown`
    - Another alternative would be to make reporting from adapter configurable with some sort of post-condition

2. Mixed generation for Available conditions
    1. cluster has `Available=True`, `Ready=True` at `gen=1`
    1. User updates spec, `gen=2`
    1. Only one/some adapters report `observed_generation=2` `Available=True`

    - `Ready` transitions to `False` right after the spec update
    - `Available=True` with `gen=1`

3. Cluster transitions to Ready but with mixed generations
    1. cluster has `Available=True`, `Ready=True` at `gen=1`
    1. Then, the first adapter reports `Available=false`
        - cluster transitions `Available=False` `Ready=False` at `gen=1`
    1. User updates `gen=2`
    1. 1st adapter reports `Available=True` `observed_generation=2`
    - `Available` remains `False` at `gen=1`

### API behaviour

The GCP team proposed also to have the logic behind the `Available/Ready` configurable using some type of expressions, eg something like:

```
available=self.items.all(i, 
  i.observed_generation == self.items[0].observed_generation && 
  i.conditions.exists(c, c.type == 'Available' && c.status == 'True')
)
ready= available && self.items.all(i, i.observed_generation == generationN)
```

Since the behaviour of `Ready` is required for Sentinel:

- We may allow for teams to build additional conditions
- But keep `Available` and `Ready` with our current logic

Some other rules for the API:

1. API should only accept conditions statuses for same or increased condition.observed_generation
    - An adapter update can not replace data from a newer generation
    - e.g. If validation adapter is at gen=2, API only accepts reports of gen>=2
1. API should discard conditions with `Available=Unknown`
    - It can still store in some status log table/file for tracing
    - We can think of optimizing by having a post-condition that discards adapter report
    - It also doesn't update `last_updated_time` for the adapter
1. Available only transitions to True
    - If all the adapters are at the same generation report Available=True
    - Could be that the adapter's reports observed_generation < generation
      - This can happen when updating quickly a spec
      - API will be getting "older" adapter statuses first
      - It can be "Available"" for that generation, but needs reconciliation
      - Eventually it will get newer responses
1. Available transitions to False
    - If any adapter of the `observed_generation` in the condition reports `Available=False`
    - But not for adapters reporting `Available=false` at other `observed_generation`
    - This keeps `Available=true` for `observed_generation` while `Ready=False`
      - Meaning, that the last known generation is still marked available
1. Ready transitions to False for every user spec change
      - Since it will increase generation
      - And all adapters being async have observedGeneration<generation

## Next Action items

1. Changes to API spec:

<details>
<summary>Ticket definition </summary>

  What:
  Change the API spec to align with the sentinel pulses proposal

  Details:

    - Remove `status.phase`
    - Defining `Available` and `Ready` as `status.conditions`
    - Is it possible to define as an array with these two being mandatory?
    - Create and publish openapi contracts
    - Version the release

  Acceptance criteria:
    - New release with openapi contracts for core and GCP
    - Examples for cluster and nodepools responses
    - Examples for statuses

</details>

1. Changes to API

<details>
<summary>Ticket: Change API spec to add Available and Ready resource conditions </summary>
  What:
  Change HyperFleet-api to use the new API spec and behave aligned with the new proposal

  Details:

    - Compute `Available` and `Ready` conditions with rules:
        1. API should only accept conditions statuses for same or increased condition.observed_generation
            - An adapter update can not replace data from a newer generation
            - e.g. If validation adapter is at gen=2, API only accepts reports of gen>=2
        1. API should discard conditions with `Available=Unknown`
            - It can still store in some status log table/file for tracing
            - We can think of optimizing by having a post-condition that discards adapter report
            - It also doesn't update `last_updated_time` for the adapter
        1. Available only transitions to True
            - If all the adapters are at the same generation report Available=True
            - Could be that the adapter's reports observed_generation < generation
              - This can happen when updating quickly a spec
              - API will be getting "older" adapter statuses first
              - It can be "Available"" for that generation, but needs reconciliation
              - Eventually it will get newer responses
        1. Available transitions to False
            - If any adapter of the `observed_generation` in the condition reports `Available=False`
            - But not for adapters reporting `Available=false` at other `observed_generation`
            - This keeps `Available=true` for `observed_generation` while `Ready=False`
              - Meaning, that the last known generation is still marked available
        1. Ready transitions to False for every user spec change
              - Since it will increase generation
              - And all adapters being async have observedGeneration<generation

  Acceptance criteria:
    - API implements the new spec
    - Create tests for new conditions what will be always present
    - Code reviewed and merged
    - Documentation updated
    - Related architecture repository documentation updated
</details>

1. Changes to Sentinel

<details>
<summary>Ticket: Change Sentinel to evaluate based on resource status.Ready condition  </summary>
  What:
  Change Sentinel to use `resource.Ready` property instead of `status.phase`

  Details:
    - Change openapi version to use the one of the proposal
    - Evaluate reason to publish using `resource.Ready` property instead of `status.phase`

  Acceptance criteria:
    - Sentinel no longer uses `status.phase`
    - Documentation updated
    - Related architecture repository documentation updated

</details>
1. Adapter framework
<details>
<summary>Ticket: Document in-progress adapter task status report</summary>
  What: Document how adapters should use the value `Unknown` for reporting in-progress state of the work to be done

  Acceptance criteria:
    - Document the usage of `Available=Unknown`
    - Change job template examples to retry indefinitely

</details>
1. Adapters
<details>
<summary>Ticket: Change validation adapter task job to retry indefinitely</summary>
  What: Change job manifest to keep retrying until success

  Detail:
    - Change adapter task jobs to retry indefinitely
      - Set job `restartPolicy: OnFailure`
      - Set `backoffLimit` to a high number like 1000000
      - This makes retries 10x2 until 360seconds

  Acceptance criteria:
    - Jobs for adapter tasks always finish with success or keep retying
    - Documentation updated

</details>
