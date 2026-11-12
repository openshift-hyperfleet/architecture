---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-11-12
---

# Spike: Sweeper Orphan-Scan Design

**Ticket:** [HYPERFLEET-1823](https://redhat.atlassian.net/browse/HYPERFLEET-1823)  
**Epic:** [HYPERFLEET-1518](https://redhat.atlassian.net/browse/HYPERFLEET-1518)  
**Consumer:** [HYPERFLEET-1840: Centralized desire sweeper](https://redhat.atlassian.net/browse/HYPERFLEET-1840)

**Decision state: proposed for architecture review.** `Status: Active` identifies a maintained document, not an approved decision. The recommendations below are the output proposed by this spike; they are not claims about implemented behavior. The [review gates](#review-and-implementation-gates) must be resolved before treating the design as ready for implementation or closing the ticket.

## What and Why

The [garbage-collection spike](spike-desire-garbage-collection.md) selected a centralized Hub sweeper. It correlates each desire's `resource_id` with the originating HyperFleet API resource, requests remote cleanup through a `DeleteDesire`, and removes desire records after the Applier confirms deletion. This spike specifies partition discovery, confirmation, record cleanup, and cadence under the API-mediated Desire Store design.

The sweeper complements normal deletion. The API, Sentinel, and Adapter still drive normal resource deletion. The [delete-recovery decision](spike-desires-lost-mid-deletion.md) requires an Adapter to retain a confirmed `DeleteDesire` until the originating API resource is gone, while removing its `ReadDesire`. Those retained records are expected sweeper work even when normal deletion succeeds. An orphaned `ApplyDesire` is a different case: the source has disappeared but intent to keep a remote object present remains.

Partition discovery cannot depend only on live management-cluster registrations. For example, desires remain under partition `mc-01` after its registration is removed. A registration-derived list no longer includes `mc-01`; a list derived from remaining Desire Store records does. Removing a registration does not establish that its Kubernetes objects were deleted, nor does it establish that each desire's originating API resource is gone.

A **partition** is the `managementCluster` dimension of desire identity. It groups records targeting one management cluster; it is not a customer, cloud region, or the originating resource's `resource_id`. Partitions are implicit row groupings, materialized by a first write ([partition selection](desire-store-dd.md#partition-selection)).

## Evidence and Scope

The ticket description and its six acceptance criteria were checked on 2026-11-12. Repository sources were inspected with `gh` at these revisions:

| Source | Verified baseline and relevance |
| --- | --- |
| Architecture | [`7127fe9`](https://github.com/openshift-hyperfleet/architecture/tree/7127fe9360fea3534ded7da5827be25f1b4bb09e): partition-scoped REST routes, owner exemption, conditional record deletes, garbage collection, and retained-delete decisions |
| Applier | [`f15f3f8`](https://github.com/openshift-hyperfleet/hyperfleet-applier/tree/f15f3f8630e15fc6f446edc535ccef6f370907e2): delete execution, conditions, generation, and shared store behavior |
| Adapter | [`0806e99`](https://github.com/openshift-hyperfleet/hyperfleet-adapter/tree/0806e994d7171e9cf76865dca1ce639b7b485dc8): the current [delete writer](https://github.com/openshift-hyperfleet/hyperfleet-adapter/blob/0806e994d7171e9cf76865dca1ce639b7b485dc8/internal/desireclient/delete.go) does not populate `OriginID`; the test plan tracks missing provenance as G7 |
| Pending contract work | [PR #273 / HYPERFLEET-1923](https://github.com/openshift-hyperfleet/architecture/pull/273), open at `19a40b1535901613a7d7b0222b69491825b56061`: proposes GET `generation`, version-checked Apply/Delete status writes, and atomic delete supersede. These are dependencies, not merged REST guarantees |

In scope: discovery through the Desire Store API; safe interpretation of source existence and deletion status; record cleanup; scheduling; API and test obligations. Out of scope: implementing the sweeper, provisioning or destroying management clusters, granting direct database/Kubernetes access to the sweeper, and recovering objects after every ownership record has been lost.

## Proposed Decisions

| Topic | Recommendation |
| --- | --- |
| Partition discovery | Option 2: add a sweeper-only metadata operation listing partitions represented by remaining desire records, across all three desire types |
| Orphan detection | Require an authoritative lookup establishing that the specific `resource_id` is absent. Lookup failures and missing provenance do not establish an orphan |
| Remote deletion | Write a `DeleteDesire` for an orphaned managed target; let its partition's Applier perform Kubernetes deletion. Resolve the supersede race below before enabling this path |
| Confirmation | Read the current `DeleteDesire`; require `Successful=True`, `reason=Deleted`, and `observedGeneration` equal to that record's `generation` |
| Cleanup | After source absence and confirmation, remove the matching orphaned `ReadDesire` first and the confirmed `DeleteDesire` last, including Adapter-owned retained deletes |
| Read-only orphan | Retain and report when neither an ApplyDesire nor a DeleteDesire establishes the target's managed lifecycle. Do not infer permission to delete a Kubernetes object from a read request |
| Unavailable Applier | Retain unconfirmed deletion work and report it; a missing registration, elapsed time, or failed connection is not confirmation |
| Cadence | Retain a configurable 12-hour scheduled sweep, with an on-demand run and no concurrent scheduled/manual runs for the same Hub deployment |

## Partition Enumeration

### API and Authorization

The proposed wire contract and scoped authorization exception are in [Sweeper Partition Enumeration](desire-store-dd.md#sweeper-partition-enumeration-proposed). The operation is `GET /api/hyperfleet/desire-store/v1/partitions` with opaque keyset pagination. It returns partition identifiers only, derived from records still present in the store. It includes partitions containing only retained deletes or reads and does not join to API registrations or AuthConfig.

Only the authenticated sweeper identity receives this permission. Adapters and remote Appliers cannot list partitions. Every desire read, write, status update, and delete remains partition-addressed and partition-authorized. The listing permission must never mean a wildcard partition on a desire route. This is an explicit proposed exception to the universal partition-scope wording in [ADR-0022](../adrs/0022-api-mediated-desire-store-access.md) and [ADR-0029](../adrs/0029-desire-store-authorization.md).

No new partition registry or persisted lifecycle is introduced. Removing the final desire makes a partition cease to appear; it does not invoke a partition-delete API or decommission a management cluster.

### Scanning and Concurrency

1. Enumerate partition pages through the metadata operation. For each returned partition, list all desire types through the existing partition route and follow every page.
2. GET each candidate before deciding: desire lists contain identity and version references, not `resource_id`, owner, or status. Group decisions by the target tuple `(partition, group, resource, namespace, name)` and inspect its current apply/delete/read siblings.
3. Use records positively observed in successful responses. A failed page or an incomplete list proves no absence. Independent candidates already fetched successfully can be evaluated, but the run remains incomplete if enumeration fails.
4. A multi-page scan is not a snapshot. Newly inserted partitions behind the cursor may wait until the next run. Start each scheduled run at the beginning; after restart, rescan rather than assuming a saved cursor represents completed cleanup.
5. Use bounded pages, request concurrency, and retries. On a failed partition, record the failure and continue to other partitions where possible. Do not retain the whole fleet's manifests in memory.

Option 2 closes the **discovery** gap for remaining records. If the management cluster no longer has a working, authorized Applier, it does not create a new means to confirm remote deletion. A previously confirmed delete can still be cleaned up; an unconfirmed delete remains visible as unresolved work.

## Orphan Detection

Interpret `resource_id` as provenance, not Kubernetes identity or the partition identifier. Use a resolver for supported, canonical HyperFleet API resource references. It must use the configured HyperFleet API and an identity permitted to observe those resources; it must not follow an arbitrary URL supplied in desire content.

| Lookup outcome | Sweeper action |
| --- | --- |
| Origin exists, including a resource pending deletion | Preserve the desires; normal deletion and Adapter reconciliation retain authority |
| Authoritative not-found for the exact supported origin | Candidate orphan; inspect current siblings and apply the cleanup rules |
| Timeout, connection error, 429, 5xx, authentication/authorization failure, or ambiguous/not-authoritative 404 | Preserve records, record the failure, and retry as appropriate |
| Missing, malformed, unsupported, or conflicting provenance | Preserve records and report the reference problem; do not guess an origin from target names or a partition |

Revalidate origin absence before issuing a destructive action. Do not carry a negative lookup across runs or use an earlier absent result after observing changed provenance. A positive existence result may defer work until the next run. Define and test the supported reference forms and authoritative not-found response with the API/client integration; the example `clusters/cls-123` in the detailed design is not a complete resolver specification.

## Deletion Confirmation

The [current Applier controller](https://github.com/openshift-hyperfleet/hyperfleet-applier/blob/f15f3f8630e15fc6f446edc535ccef6f370907e2/internal/controllers/deletedesire/controller.go) resolves the Kubernetes target and checks it with GET. If it is already absent, deletion is confirmed. Otherwise it issues DELETE and checks again; a successful DELETE response alone is insufficient while the object still exists. A Kubernetes NotFound during deletion also confirms absence. Finalizers or graceful termination leave the delete pending.

The [status writer](https://github.com/openshift-hyperfleet/hyperfleet-applier/blob/f15f3f8630e15fc6f446edc535ccef6f370907e2/internal/controllers/deletedesire/status.go) writes `Successful=True`, `reason=Deleted`, and `observedGeneration` equal to the desire generation. Pending deletion uses `Successful=False` with `WaitingForDeletion`; failures use `KubeAPIError` or `PreCheckFailed`. The shared [`IsDeleted`](https://github.com/openshift-hyperfleet/hyperfleet-applier/blob/f15f3f8630e15fc6f446edc535ccef6f370907e2/pkg/desire/types.go) helper checks the true condition and `Deleted` reason; it does not itself check freshness.

The sweeper therefore accepts confirmation only from a fresh GET of the specific `DeleteDesire`, with all three condition checks in the decision table. Missing, duplicate/ambiguous, false, unknown, or stale conditions do not confirm deletion. This makes the short `Successful=True` wording in the older spike precise for the sweeper. It does not change the Adapter's confirmation helper in this documentation change.

`generation` belongs to the desire; it is neither the HyperFleet API resource generation nor Kubernetes `metadata.generation`. `version` is the record's compare-and-swap token and is separately needed for record removal. [PR #273](https://github.com/openshift-hyperfleet/architecture/pull/273) must settle their REST representation and status-write behavior before the sweeper client relies on them. Do not substitute a list reference's version for generation.

A missing `DeleteDesire`, a stale/nonexistent read mirror, an Adapter's `Finalized=True`, or the absence of an Applier is not this confirmation. A retained confirmed delete is historical evidence of that deletion; the current Applier can restamp an already-successful condition without re-reading the target object. It is not proof that no external actor ever recreated the same Kubernetes name afterward. Generation and version checks also do not provide unique incarnation identity after a desire is deleted and recreated; the existing contract must not be described as eliminating every stale-status race.

## Record Cleanup

### Eligibility and Scope

The following table applies only after the exact origin is authoritatively absent. If it exists, leave even a confirmed Adapter-owned delete in place, as [HYPERFLEET-1841](spike-desires-lost-mid-deletion.md) requires.

| Current records for one target | Action |
| --- | --- |
| ApplyDesire, with or without a matching read | Propose creating a DeleteDesire with the same target identity and provenance. It supersedes the apply through the store, not a separate sweeper DELETE of the apply. This path is gated on the supersede race decision and working store-level owner exemption |
| Unconfirmed DeleteDesire, with or without a matching read | Retain it and the read. Do not replace it just to claim sweeper ownership. Revisit its status on a later run |
| Confirmed DeleteDesire plus a matching orphaned read | Remove the read first, then the delete, using each record's current version and revalidation below |
| Confirmed DeleteDesire without a read | Remove the delete after revalidation. A missing read is normal after Adapter cleanup |
| ReadDesire only | Retain and report for investigation. A read may observe an object this delivery path never managed; a lost apply cannot be reconstructed from the read alone |
| ApplyDesire and DeleteDesire coexist, sibling provenance conflicts, or an unexpected owner combination appears | Retain and report the inconsistency. Do not select one origin arbitrarily or claim successful cleanup |
| No desire records remain | No action. Do not discover and delete Kubernetes objects without independent ownership evidence |

Ordinary siblings have one owner. During a sweeper takeover, a sweeper-owned delete and an Adapter-owned read are the intended exception: the read keeps its owner and the provenance must match. Other owner mismatches require investigation.

The sweeper creates only `DeleteDesire` records. It does not need to create a `ReadDesire` to confirm deletion; the delete status is sufficient and the [caller matrix](desire-store-dd.md#caller-to-operation-matrix) prohibits its other desired-state writes. Do not copy the Adapter's paired-read creation into the sweeper.

This confirms the original cleanup of both records for managed orphan deletion and extends cleanup to confirmed Adapter-owned deletes. It explicitly limits automatic cleanup of standalone reads. Removing an orphaned read alone could stop an unnecessary watcher, but would discard the remaining evidence without resolving whether a managed target was stranded; that alternative is not selected here. Do not report this retained case as a completed cleanup.

### Removal Order and Recovery

1. Re-read the delete and any read sibling. Require matching target/provenance, no observed replacement apply, current deletion confirmation, and fresh authoritative origin absence.
2. Remove the matching read with its current version. Treat a 404 as that record already being absent, not as evidence of remote deletion. On conflict or an uncertain outcome, re-evaluate before proceeding.
3. Re-read the delete and siblings before removing the delete. If a read is still present, confirmation/provenance changed, an apply appeared, or any required check failed, retain the delete. Otherwise remove it with its current version.
4. A crash between these steps leaves the confirmed delete as evidence; the next run can finish without recreating a read or reissuing remote deletion.

The two removals are not one transaction. Re-reads reduce stale decisions but do not make them atomic. Use the existing [sweeper timeout guard](desire-store-dd.md#cas--version-semantics): after a timed-out delete, a direct retry is allowed only if the re-read record has the same version and the sweeper's own stored owner. Adapter-owned records are eligible for initial confirmed cleanup, but an ambiguous result requires the full eligibility check again, not a blind retry under the exemption. Changed versions, owners, or provenance always require re-evaluation.

### Races That Re-Reads Do Not Solve

**Record removal:** The detailed design already accepts a same-version recreation window because versions restart at 1 and sweeper owner checks are bypassed. The owner/version guard is not a unique record-incarnation check. This spike does not claim to close that window or add an unapproved UID precondition.

**Creating remote deletion intent:** The current [memory store's CreateDeleteDesire](https://github.com/openshift-hyperfleet/hyperfleet-applier/blob/f15f3f8630e15fc6f446edc535ccef6f370907e2/pkg/desire/store/memory/store.go) removes the sibling apply without an expected apply version or expected provenance parameter. The [store interface](https://github.com/openshift-hyperfleet/hyperfleet-applier/blob/f15f3f8630e15fc6f446edc535ccef6f370907e2/pkg/desire/store.go) exposes no such precondition. Once the sweeper owner exemption is implemented, a replacement apply could appear after inspection and be superseded by a delete based on the old origin. That can request deletion of a live target, not merely remove a rebuildable store record.

This is a review gate, not an accepted extension of the record-removal trade-off. The recommendation is to require an atomic guard against replacement of the inspected target intent before enabling orphan-apply sweeping. The API/store owners must settle its wire and store contract, including delete/recreate at the same version, or supply a documented and enforced target-identity invariant that excludes this case. Re-reading or version equality alone is not that guarantee. Do not silently invent an `expected_*` field or assume target names are never reused. Confirmed-delete cleanup and partition discovery can be specified independently of resolving this path.

## Cadence and Operations

Keep the earlier **12-hour** starting interval, configurable, for a complete sweep. This is a scheduling decision, not a measured capacity result or a 12-hour deletion SLA. Start a fresh enumeration each run; expose an on-demand invocation using the same authorization and eligibility checks for tests and operations.

The deployment must serialize scheduled and on-demand runs. HYPERFLEET-1840 must supply and test one exclusion mechanism shared by both entry points, rather than relying on a rule that covers only scheduled runs. It must also define run deadlines and bounded concurrency from measured capacity, without abandoning later partitions silently when an earlier one is slow.

Do not block an entire fleet scan waiting for finalizers or an offline Applier. Leave the delete pending and revisit it on the next sweep. Under healthy scheduling, stable records, and runs completing within the interval, an orphan that becomes eligible just after a scan may wait almost 12 hours for discovery; confirmation after that scan may require another sweep for record removal. Failures, long runs, or inaccessible Appliers extend that time without a fixed bound.

Use the detailed design's capped backoff, jitter, and `Retry-After` handling. Report run completeness, last completed run, partitions/records examined, pending confirmations, unresolved provenance/read-only cases, conflicts, and failures by reason. Keep per-resource identifiers in logs, not unbounded metric labels. A successful scan with retained unresolved work is distinct from successful cleanup of every orphan.

Capacity validation must include all three types, predominantly live origins, large decommissioned partitions, retained deletes, and scan traffic concurrent with Applier polls. Work includes partition/desire pages, candidate GETs, origin lookups, and fresh checks before mutations. Do not estimate it as one request per partition. Page-size limits and an appropriate index/query plan must be validated on the Postgres backend; no fleet-size or throughput result was measured for this document.

## Alternatives and Trade-offs

| Alternative | Assessment |
| --- | --- |
| Option 1: complete cleanup before decommission removes registration | Can keep the Applier reachable during normal teardown, but cannot discover leftovers after a failed/bypassed teardown or lost registration. Requires coordination with the decommission workflow |
| Option 2: enumerate partitions from remaining store rows | Recommended. Covers residual rows without a registry or dependency on live registrations. Adds one metadata API operation, an authorization exception, and database scan work; cannot restore an unavailable Applier |
| Options 1 and 2 together | Compatible, but not required to close the discovery gap. Adds two cleanup entry points and ordering/retry obligations. Reuse the same confirmation rules if decommission cleanup is added separately |
| Accept the registration-list gap | Leaves exactly the fully-decommissioned partitions in the ticket undiscoverable; rejected |
| Direct DB scan by sweeper | Avoids a new API operation but violates API-mediated access and distributes database access; rejected |
| TTL or force cleanup after a deadline | Confuses failed communication with absent ownership or successful deletion; rejected, consistent with the earlier spike |

The cost of conservative cleanup is retained unresolved rows and delayed reclamation. The benefit is that source lookup failures, read-only observations, and missing Appliers cannot by themselves authorize remote deletion. There is no automatic solution here for a Kubernetes object whose ownership desires were all lost, or for unconfirmed deletion after its Applier is permanently removed.

## Review and Implementation Gates

| Gate | Required resolution |
| --- | --- |
| Architecture review | Accept or revise the option-2 route and authorization exception, standalone-read retention, confirmation predicate, and 12-hour cadence |
| Documentation integration | When accepting the decision, amend ADR-0029 to record the metadata exception using its existing relationship to ADR-0022, and update the Desire Store test plan with the validation obligations below. Those documents are unchanged in this draft |
| Pending REST decisions | Reconcile with PR #273 before OpenAPI finalization; generation must be available and stale Apply/Delete status writes must not be accepted as fresh evidence |
| Store-level owner exemption | HYPERFLEET-1825 must make the authorized sweeper exemption reach owner-checked store operations. An API allowlist alone cannot bypass the existing store check; PR #273 identifies this implementation gap |
| Destructive supersede safety | Resolve the atomic guard or enforced identity invariant described above, including same-version recreation. Until then, orphan-apply deletion is not ready to enable |
| Provenance and origin lookup | Resolve test-plan G7: supported `resource_id` values must be populated and resolvable. Agree on authoritative not-found semantics and permissions; do not infer them from a sample path |
| Implementation/test ownership | Assign partition enumeration to the API/backend work, its client support, and gateway/operator changes. Confirm follow-up ticket scope; do not assume existing tickets already contain these new requirements |
| Operational recovery | HYPERFLEET-1840 must expose on-demand execution, shared run exclusion, and unresolved-work reporting. Permanent loss of an Applier needs operator investigation; no force-cleanup API is selected here |

The intended repositories are `architecture` for this decision, `hyperfleet-desire-store-spec` for the contract, `hyperfleet-desire-store` for handlers/storage, `hyperfleet-operator` and the gateway deployment work for authorization, and the clients/test repositories named by the [Desire Store test plan](e2e-testing/desire-store-test-plan.md). The sweeper's repository and on-demand entry point are still test-plan gap G2; this document does not assign a repository that has not been selected.

## Validation Obligations

The existing SWP-1 through SWP-5 and CAS-5 scenarios in the [Desire Store test plan](e2e-testing/desire-store-test-plan.md#sweeper-privileges) remain relevant. After the decision is accepted, extend that plan with the obligations below and confirm their implementation/test ownership. The test plan is unchanged in this draft; its C3 decision remains open. At minimum, tests must prove:

- A partition absent from registrations is still enumerated when any desire type remains; empty partitions disappear. Pagination is bounded, deduplicated, and handles concurrent additions/removals without treating failure as an empty store.
- Only the sweeper can list partition metadata. A metadata Wristband cannot read or mutate desires, and malformed or mixed scope claims fail before any data access.
- An existing/pending-deletion origin, failed lookup, missing provenance, or conflicting siblings causes no destructive action.
- Only fresh `Successful=True` / `Deleted` on the correct delete record confirms completion. Accepted Kubernetes DELETE, finalizers, stale generation, or read-mirror lag do not substitute for it.
- Confirmed Adapter-owned deletes stay while the origin exists and are removed after it is absent; matching reads are removed first. Pending deletes survive an unavailable/revoked Applier.
- A crash between read and delete removal resumes safely. Timeout/conflict handling re-evaluates eligibility and obeys the existing owner guard.
- A standalone read is retained without creating a remote delete. A lost desire is never treated as proof that Kubernetes deletion succeeded.
- A replacement apply inserted between orphan inspection and delete creation is not silently deleted; the chosen supersede-safety resolution must provide the test oracle before this path is enabled.
- Scheduled and on-demand runs cannot overlap, and on-demand tests do not wait 12 hours. Failures and retained unresolved work remain observable.

These are tests to implement, not tests executed by this documentation change.

## Acceptance Criteria Mapping

| Ticket criterion | Coverage and completion requirement |
| --- | --- |
| Decide enumeration, including fully-decommissioned clusters | [Partition Enumeration](#partition-enumeration) proposes option 2 and explicitly separates discovery from remote-deletion capability |
| Define deletion confirmation | [Deletion Confirmation](#deletion-confirmation) names the condition, reason, generation check, and REST dependency |
| Define which delete/read records are removed | [Record Cleanup](#record-cleanup) covers sweeper-owned and Adapter-owned deletes, ordering, standalone reads, and retained failures |
| Confirm or revise roughly 12-hour cadence | [Cadence and Operations](#cadence-and-operations) retains 12 hours and defines its limits |
| Amend detailed design before OpenAPI finalization | The companion [proposed API extension](desire-store-dd.md#sweeper-partition-enumeration-proposed) records the route, schema, and authorization. Resolve review gates before HYPERFLEET-1821 finalizes the contract |
| Record decision in architecture and link from sweeper story | This file records the proposal. After review/publication, link the accepted document from HYPERFLEET-1840; a local file or a link from this file to Jira does not complete that external step |

## References

- [HYPERFLEET-1823](https://redhat.atlassian.net/browse/HYPERFLEET-1823)
- [HYPERFLEET-1840](https://redhat.atlassian.net/browse/HYPERFLEET-1840)
- [Desire Store Detailed Design](desire-store-dd.md)
- [Desire Store Architecture Overview](desire-store-hld.md)
- [Desire Identity and Ownership](spike-desire-identity-ownership.md)
- [Desire Garbage Collection Strategy](spike-desire-garbage-collection.md)
- [Desires Lost Mid-Deletion](spike-desires-lost-mid-deletion.md)
- [Desire Store Test Plan](e2e-testing/desire-store-test-plan.md)
