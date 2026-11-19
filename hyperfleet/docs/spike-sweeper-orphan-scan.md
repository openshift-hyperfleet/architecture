---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-11-19
---

# Spike: Sweeper Orphan-Scan Design

**Ticket:** [HYPERFLEET-1823](https://redhat.atlassian.net/browse/HYPERFLEET-1823)  
**Epic:** [HYPERFLEET-1518](https://redhat.atlassian.net/browse/HYPERFLEET-1518)  
**Consumer:** [HYPERFLEET-1840: Centralized desire sweeper](https://redhat.atlassian.net/browse/HYPERFLEET-1840)

**Decision state: option 2 recorded in [ADR-0039](../adrs/0039-sweeper-partition-enumeration.md).** This PR records partition enumeration from remaining desire rows, the API/Postgres metadata boundary, and the narrow authorization and v1 compatibility exceptions. The ADR, earlier ADR references, detailed design, HLD, glossary, and test plan are updated together. This is a design decision, not a claim that the endpoint is published or implemented. HYPERFLEET-1823 remains open for the separate deletion-safety decisions, remaining recommendations, and ticket/specification integration described in the [design gates](#review-and-implementation-gates) and [acceptance-criteria mapping](#acceptance-criteria-mapping).

## What and Why

The [garbage-collection spike](spike-desire-garbage-collection.md) selected a centralized Hub sweeper. It correlates each desire's `resource_id` with the originating HyperFleet API resource, requests remote cleanup through a `DeleteDesire`, and removes desire records after the Applier confirms deletion. This spike specifies partition discovery, confirmation, record cleanup, and cadence under the API-mediated Desire Store design.

The sweeper complements normal deletion. The API, Sentinel, and Adapter still drive normal resource deletion. The [delete-recovery decision](spike-desires-lost-mid-deletion.md) requires an Adapter to retain a confirmed `DeleteDesire` until the originating API resource is gone, while removing its `ReadDesire`. Those retained records are expected sweeper work even when normal deletion succeeds. An orphaned `ApplyDesire` is a different case: the source has disappeared but intent to keep a remote object present remains.

Partition discovery cannot depend only on live management-cluster registrations. For example, desires remain under partition `mc-01` after its registration is removed. A registration-derived list no longer includes `mc-01`; a list derived from remaining Desire Store records does. Removing a registration does not establish that its Kubernetes objects were deleted, nor does it establish that each desire's originating API resource is gone.

A **partition** is the `managementCluster` dimension of desire identity. It groups records targeting one management cluster; it is not a customer, cloud region, or the originating resource's `resource_id`. Partitions are implicit row groupings, materialized by a first write ([partition selection](desire-store-dd.md#partition-selection)).

## Evidence and Scope

The ticket description and its six acceptance criteria were rechecked on 2026-11-18; linked implementation stories were checked on 2026-11-16. Repository sources were inspected with `gh` at these revisions; code observations below refer to the pinned revisions:

| Source | Verified baseline and relevance |
| --- | --- |
| Architecture | [`7127fe9`](https://github.com/openshift-hyperfleet/architecture/tree/7127fe9360fea3534ded7da5827be25f1b4bb09e): partition-scoped REST routes, owner exemption, conditional record deletes, garbage collection, and retained-delete decisions |
| Applier | [`f15f3f8`](https://github.com/openshift-hyperfleet/hyperfleet-applier/tree/f15f3f8630e15fc6f446edc535ccef6f370907e2): delete execution, conditions, generation, and shared store behavior |
| Adapter | [`0806e99`](https://github.com/openshift-hyperfleet/hyperfleet-adapter/tree/0806e994d7171e9cf76865dca1ce639b7b485dc8): the current [delete writer](https://github.com/openshift-hyperfleet/hyperfleet-adapter/blob/0806e994d7171e9cf76865dca1ce639b7b485dc8/internal/desireclient/delete.go) does not populate `OriginID`; the test plan tracks missing provenance as G7 |
| Published wire contract | [Specification 0.2.0 at `6474ebc`](https://github.com/openshift-hyperfleet/hyperfleet-desire-store-spec/blob/6474ebc035ce005d53aed9dc91e82c50382cf9bc/schemas/desire-store/openapi.yaml), merged by [spec PR #2](https://github.com/openshift-hyperfleet/hyperfleet-desire-store-spec/pull/2) on 2026-11-12 for HYPERFLEET-1821: five desire-record operations, GET `generation`, version-checked Apply/Delete status writes, and atomic delete supersede. No `GET /partitions` operation |
| Contract alignment | [Architecture PR #273 / HYPERFLEET-1923](https://github.com/openshift-hyperfleet/architecture/pull/273), open at [`434a044`](https://github.com/openshift-hyperfleet/architecture/commit/434a0443e4d8754c0c080c90853a32808ea23386) when checked on 2026-11-18, owns the shared status-version, supersede, owner-collision, and GET-schema text; it documents but does not solve the stale-status-after-recreation limit. [Spec PR #3](https://github.com/openshift-hyperfleet/hyperfleet-desire-store-spec/pull/3) merged on 2026-11-16, correcting per-type CNF-001 recovery and qualifying the unimplemented store exemption |

**Merge dependency:** PR #273 must merge first. Rebase this PR afterward and keep only metadata and sweeper-specific additions in the detailed design. PR #273 owns the baseline owner-collision, GET schema, status-version, and delete-supersede wording; this PR retains the sweeper ownership-delay clarification after that baseline lands. Gap G15 is introduced by PR #273 and is not on `main` yet. The C4/C5 rows do exist on `main` as open contract decisions; PR #273 resolves them, so this PR must not treat their current text as the final rule. Do not merge this PR against the older shared-contract text or treat those pending rows as approved decisions.

HYPERFLEET-1821 is closed. [HYPERFLEET-1937](https://redhat.atlassian.net/browse/HYPERFLEET-1937) now owns the shared-store sweeper exemption. [HYPERFLEET-1840](https://redhat.atlassian.net/browse/HYPERFLEET-1840) names `hyperfleet-sweeper` as the service repository and includes an on-demand test trigger; [HYPERFLEET-1938](https://redhat.atlassian.net/browse/HYPERFLEET-1938) owns its chart and deployment wiring. These allocations do not by themselves add the recorded metadata route to any implementation ticket.

In scope: discovery through the Desire Store API; safe interpretation of source existence and deletion status; record cleanup; scheduling; API and test obligations. Out of scope: implementing the sweeper, provisioning or destroying management clusters, granting direct database/Kubernetes access to the sweeper, and recovering objects after every ownership record has been lost.

## Recorded Decision and Remaining Recommendations

Only partition enumeration and its associated API, authorization, and compatibility choices are recorded by ADR-0039. The other rows remain recommendations subject to the design gates below.

| Topic | Decision or recommendation |
| --- | --- |
| Partition discovery | **Recorded in ADR-0039.** Option 2: add a sweeper-only metadata operation listing partitions represented by remaining desire records, across all three desire types |
| Orphan detection | Require an authoritative lookup establishing that the specific `resource_id` is absent. Lookup failures and missing provenance do not establish an orphan |
| Remote deletion | Proposed: write a `DeleteDesire` for an orphaned managed target and let its partition's Applier perform Kubernetes deletion. Resolve both the supersede safety gate and the unverified A1 lifecycle gate below before enabling this path |
| Confirmation | Read the current `DeleteDesire`; require `Successful=True`, `reason=Deleted`, and `observedGeneration` equal to that record's `generation`. Before relying on this for cleanup, prevent a status from a previous record incarnation from confirming a recreated delete |
| Cleanup | After source absence and confirmation, remove the matching orphaned `ReadDesire` first and the confirmed `DeleteDesire` last, including Adapter-owned retained deletes |
| Read-only orphan | Retain and report when neither an ApplyDesire nor a DeleteDesire establishes the target's managed lifecycle. Do not infer permission to delete a Kubernetes object from a read request |
| Unavailable Applier | Retain unconfirmed deletion work and report it; a missing registration, elapsed time, or failed connection is not confirmation |
| Cadence | Retain a configurable 12-hour scheduled sweep, with an on-demand run and no concurrent scheduled/manual runs for the same Hub deployment |

## Partition Enumeration

### API and Authorization

The wire contract and scoped authorization exception recorded by [ADR-0039](../adrs/0039-sweeper-partition-enumeration.md) are in [Sweeper Partition Enumeration](desire-store-dd.md#sweeper-partition-enumeration). The operation is `GET /api/hyperfleet/desire-store/v1/partitions` with opaque keyset pagination. It returns partition identifiers only, derived from records still present in the store. It includes partitions containing only retained deletes or reads and does not join to API registrations or AuthConfig.

Only the authenticated sweeper identity receives this permission. Adapters and remote Appliers cannot list partitions. Every desire read, write, status update, and delete remains partition-addressed and partition-authorized. The listing permission must never mean a wildcard partition on a desire route. ADR-0039 records this narrow exception to the universal partition-scope wording in [ADR-0022](../adrs/0022-api-mediated-desire-store-access.md) and [ADR-0029](../adrs/0029-desire-store-authorization.md).

No new partition registry or persisted lifecycle is introduced. Removing the final desire makes a partition cease to appear; it does not invoke a partition-delete API or decommission a management cluster.

The selected implementation boundary is an API/Postgres metadata query outside the shared `SpecStore`, plus an explicit metadata operation in the sweeper's HTTP client. Existing `List*Desires` calls remain partition-scoped. This avoids adding fleet enumeration to every store backend and Adapter/Applier client; it requires separate Postgres integration and metadata-authorization tests. See the [detailed store boundary and alternative](desire-store-dd.md#operation-and-response).

### Scanning and Concurrency

1. Enumerate partition pages through the metadata operation. For each returned partition, list all desire types through the existing partition route and follow every page.
2. GET each candidate before deciding: desire lists contain identity and version references, not `resource_id`, owner, or status. Group decisions by the target tuple `(partition, group, resource, namespace, name)` and inspect its current apply/delete/read siblings.
3. Use records positively observed in successful responses. A failed page or an incomplete list proves no absence. Independent candidates already fetched successfully can be evaluated, but the run remains incomplete if enumeration fails.
4. A multi-page scan is not a snapshot. Newly inserted partitions behind the cursor may wait until the next run. Start each scheduled run at the beginning; after restart, rescan rather than assuming a saved cursor represents completed cleanup.
5. Use bounded pages, request concurrency, and retries. On a failed partition, record the failure and continue to other partitions where possible. Do not retain the whole fleet's manifests in memory.

Option 2 closes the **discovery** gap for remaining records. If the management cluster no longer has a working, authorized Applier, it does not create a new means to confirm remote deletion. A delete whose current stored status still satisfies the confirmation predicate is eligible for cleanup, subject to the incarnation-safety gate below; previously observed success alone is insufficient. An unconfirmed delete remains visible as unresolved work.

## Orphan Detection

Interpret `resource_id` as provenance, not Kubernetes identity or the partition identifier. Use a resolver for supported, canonical HyperFleet API resource references. It must use the configured HyperFleet API and an identity permitted to observe those resources; it must not follow an arbitrary URL supplied in desire content.

| Lookup outcome | Sweeper action |
| --- | --- |
| Origin exists, including a resource pending deletion | Preserve Adapter-owned desires and stop orphan cleanup. If a sweeper-owned `DeleteDesire` already exists, report a possible A1 counterexample as described below; do not claim that stopping cleanup cancels remote work already in flight |
| Authoritative not-found for the exact supported origin | Candidate orphan; inspect current siblings and apply the cleanup rules |
| Timeout, connection error, 429, 5xx, authentication/authorization failure, or ambiguous/not-authoritative 404 | Preserve records, record the failure, and retry as appropriate |
| Missing, malformed, unsupported, or conflicting provenance | Preserve records and report the reference problem; do not guess an origin from target names or a partition |

### Working Assumption and Open Question

**A1 (unverified):** After an authoritative lookup establishes that the originating API resource is absent and the sweeper creates a `DeleteDesire`, supported HyperFleet operations neither make that same canonical resource reference live again nor reassign or reuse the Kubernetes target `(partition, group, resource, namespace, name)` for a live source while the delete is pending. The target could be handled by the same or a different Adapter. This assumption does not prohibit reuse after deletion and cleanup satisfy the existing ownership rules, or resolve a replacement apply created before the sweeper creates its delete. It is a planning hypothesis, not an accepted architectural guarantee or approval to perform remote deletion.

**Evidence boundary:** [ADR-0009](../adrs/0009-uuid-v7-resource-identifiers.md) selects UUID resource identifiers, and [ADR-0028](../adrs/0028-apply-delete-ordering.md) serializes Applier apply/delete passes. Neither establishes a permanent source-to-target binding or a complete restore/reassignment policy. The [identity decision](spike-desire-identity-ownership.md#3-identity) stores `resource_id` as content outside the desire identity.

**Q1:** Do supported API recovery or restore operations, Adapter target-naming rules, or ownership handovers violate A1? The HYPERFLEET-1823 spike owner must obtain evidence from API, Adapter, and Applier owners of the supported lifecycle rules and tests, or record a concrete counterexample. Until A1 is verified for supported lifecycles or a tested coordination mechanism handles counterexamples, do not enable sweeper creation of remote deletion intent. The partition-enumeration decision in ADR-0039 is independent.

**Proposed handling if detected:** If a fresh check finds a reappeared origin or conflicting live provenance, stop initiating further cleanup for that target, retain the records, and report the case for investigation. No automatic cancellation or recovery mechanism is selected by this proposal. Stopping cleanup or removing a `DeleteDesire` cannot revoke Kubernetes work already read by the Applier or prove that the target survived.

Revalidate origin absence before issuing a destructive action. Do not carry a negative lookup across runs or use an earlier absent result after observing changed provenance. A positive existence result defers ordinary records; if sweeper-created deletion intent already exists, report it as a possible Q1 counterexample. Define and test the supported reference forms and authoritative not-found response with the API/client integration; the example `clusters/cls-123` in the detailed design is not a complete resolver specification.

## Deletion Confirmation

The [current Applier controller](https://github.com/openshift-hyperfleet/hyperfleet-applier/blob/f15f3f8630e15fc6f446edc535ccef6f370907e2/internal/controllers/deletedesire/controller.go) resolves the Kubernetes target and checks it with GET. If it is already absent, deletion is confirmed. Otherwise it issues DELETE and checks again; a successful DELETE response alone is insufficient while the object still exists. A Kubernetes NotFound during deletion also confirms absence. Finalizers or graceful termination leave the delete pending.

The [status writer](https://github.com/openshift-hyperfleet/hyperfleet-applier/blob/f15f3f8630e15fc6f446edc535ccef6f370907e2/internal/controllers/deletedesire/status.go) writes `Successful=True`, `reason=Deleted`, and `observedGeneration` equal to the desire generation. Pending deletion uses `Successful=False` with `WaitingForDeletion`; failures use `KubeAPIError` or `PreCheckFailed`. The shared [`IsDeleted`](https://github.com/openshift-hyperfleet/hyperfleet-applier/blob/f15f3f8630e15fc6f446edc535ccef6f370907e2/pkg/desire/types.go) helper checks the true condition and `Deleted` reason; it does not itself check freshness.

**Pre-check limitation:** The current controller calls `setupResourceClient` before checking `IsDeleted`. A mapping or namespace-validation failure can therefore replace a previously successful condition with `PreCheckFailed`. For example, removing a CRD after confirmed deletion can leave the retained desire unconfirmed on a later reconciliation. A new delete whose resource type cannot be resolved also cannot reach the GET/DELETE checks. This proposal retains and reports both cases; it does not interpret discovery failure as authoritative object absence or restore a remembered success. Preserving terminal confirmation or treating a demonstrably removed resource type as absence would require a separately reviewed Applier change. No such behavior is assumed here.

The sweeper's proposed confirmation predicate starts with a fresh GET of the specific `DeleteDesire` and all three condition checks in the decision table. Missing, duplicate/ambiguous, false, unknown, or stale conditions do not confirm deletion. This makes the short `Successful=True` wording in the older spike precise for the sweeper. It does not change the Adapter's confirmation helper in this documentation change.

`generation` belongs to the desire; it is neither the HyperFleet API resource generation nor Kubernetes `metadata.generation`. `version` is the record's compare-and-swap token and is separately needed for record removal. Specification 0.2.0 already defines GET generation and the version precondition on Apply/Delete status writes. Use that published representation; do not substitute a list reference's version for generation. Version checking rejects stale writes after a version advance, but does not distinguish records recreated at the same version.

A missing `DeleteDesire`, a stale/nonexistent read mirror, an Adapter's `Finalized=True`, or the absence of an Applier is not this confirmation. A retained confirmed delete is historical evidence of that deletion; the current Applier can restamp an already-successful condition without re-reading the target object. It is not proof that no external actor ever recreated the same Kubernetes name afterward.

The condition, reason, and generation checks are necessary but insufficient if the record was deleted and recreated. [PR #273 at `434a044`](https://github.com/openshift-hyperfleet/architecture/blob/434a0443e4d8754c0c080c90853a32808ea23386/hyperfleet/docs/desire-store-dd.md#cas--version-semantics) documents that an old Applier status write can match a recreated `DeleteDesire` at the same version, mark it `Deleted`, and cause the Applier to skip the new deletion. The recreated delete starts at generation 1, so matching `observedGeneration` does not distinguish the two records. PR #273 records this as a remaining v1 limitation, not a fix; neither its merge nor HYPERFLEET-1937 would close this gate. HYPERFLEET-1823 retains responsibility for the safety decision with the API/store and Applier owners: specify a verified incarnation-safe confirmation mechanism and its delivery owner, or obtain explicit acceptance of this risk for sweeper cleanup. This proposal recommends the former and does not accept the risk. Until that decision is recorded, confirmation-based cleanup is not ready for implementation.

## Record Cleanup

### Eligibility and Scope

The following table applies only after the exact origin is authoritatively absent. If it exists, leave even a confirmed Adapter-owned delete in place, as [HYPERFLEET-1841](spike-desires-lost-mid-deletion.md) requires.

| Current records for one target | Action |
| --- | --- |
| ApplyDesire, with or without a matching read | Propose creating a DeleteDesire with the same target identity and provenance. It supersedes the apply through the store, not a separate sweeper DELETE of the apply. This path requires resolution of the supersede safety gate, the A1 lifecycle gate, and a working store-level owner exemption |
| Unconfirmed DeleteDesire, with or without a matching read | Retain it and the read. Do not replace it just to claim sweeper ownership. Revisit its status on a later run |
| Previously confirmed DeleteDesire now reporting `PreCheckFailed` | Retain it and any read; report unresolved cleanup. A removed CRD or failed mapping is not confirmation under this predicate |
| Confirmed DeleteDesire plus a matching orphaned read | After the read-cleanup safety gate below is resolved, remove the read first and the delete last. Until then retain and report the pair; separate re-reads and a read-version check cannot exclude a concurrent replacement apply |
| Confirmed DeleteDesire without a read | Remove the delete after revalidation. A missing read is normal after Adapter cleanup |
| ReadDesire only | Retain and report for investigation. A read may observe an object this delivery path never managed; a lost apply cannot be reconstructed from the read alone |
| ApplyDesire and DeleteDesire coexist, sibling provenance conflicts, or an unexpected owner combination appears | Retain and report the inconsistency. Do not select one origin arbitrarily or claim successful cleanup |
| No desire records remain | No action. Do not discover and delete Kubernetes objects without independent ownership evidence |

Ordinary siblings have one owner. During a sweeper takeover, a sweeper-owned delete and an Adapter-owned read are the intended exception: the read keeps its owner and the provenance must match. Other owner mismatches require investigation.

The sweeper creates only `DeleteDesire` records. It does not need to create a `ReadDesire` to confirm deletion; the delete status is sufficient and the [caller matrix](desire-store-dd.md#caller-to-operation-matrix) prohibits its other desired-state writes. Do not copy the Adapter's paired-read creation into the sweeper.

The intended cleanup covers both records for managed orphan deletion and extends to confirmed Adapter-owned deletes, subject to the safety gates below. It explicitly limits automatic cleanup of standalone reads. Removing an orphaned read alone could stop an unnecessary watcher, but would discard the remaining evidence without resolving whether a managed target was stranded; that alternative is not selected here. Do not report retained records as completed cleanup.

### Removal Order and Recovery

1. Re-read the delete and any read sibling. Require matching target/provenance, no observed replacement apply, current deletion confirmation, and fresh authoritative origin absence.
2. Once the read-cleanup safety gate below is resolved, remove the matching read under the accepted guard against a live replacement apply. Its current version alone is insufficient. Treat a 404 as that record already being absent, not as evidence of remote deletion. On conflict or an uncertain outcome, re-evaluate before proceeding.
3. Re-read the delete and siblings before removing the delete. If a read is still present, confirmation/provenance changed, an apply appeared, or any required check failed, retain the delete. Otherwise remove it with its current version.
4. A crash between these steps leaves the confirmed delete as evidence; the next run can finish without recreating a read or reissuing remote deletion.

The two removals are not one transaction. Re-reads reduce stale decisions but do not make them atomic. Use the existing [sweeper timeout guard](desire-store-dd.md#cas--version-semantics): after a timed-out delete, a direct retry is allowed only if the re-read record has the same version and the sweeper's own stored owner. Adapter-owned records are eligible for initial confirmed cleanup, but an ambiguous result requires the full eligibility check again, not a blind retry under the exemption. Changed versions, owners, or provenance always require re-evaluation.

### Races That Re-Reads Do Not Solve

**Record removal:** The detailed design accepts a same-version recreation window because versions restart at 1. The cross-owner sweeper case applies only after HYPERFLEET-1937's store exemption is implemented and integrated; until then the store rejects the cross-owner operation. The owner/version guard is not a unique record-incarnation check. This spike does not claim to close that window or add an unapproved UID precondition.

**Read cleanup after a confirmed delete:** The shared store permits an Adapter to create a new `ApplyDesire` after a confirmed `DeleteDesire`, retiring that delete while leaving a same-target `ReadDesire` in place. The read can remain at version 1. A sweeper that inspected the old confirmed-delete/read pair can therefore delete the read after the apply becomes live: the current conditional read delete checks the read's version and owner, not whether an apply sibling exists. The owner exemption in HYPERFLEET-1937 would also allow removal of an Adapter-owned read. Even the same Adapter owner can replace a confirmed delete, so this is not limited to a cross-owner or pending-delete case under working assumption A1. The Adapter may recreate a missing read on a later reconcile, but no maximum delay is established; that repair is not an accepted safety bound.

Do not enable sweeper removal of a read paired with a confirmed delete until the API/store and Adapter owners define and test a safe handoff. It must prevent the sweeper from removing a read needed by a live replacement apply, including an apply arriving between inspection and deletion, and ensure a newly live apply retains or obtains its read mirror. A separate re-read, read version, or owner comparison does not provide that guarantee. Record the wire/store change, implementation owner, and tests under HYPERFLEET-1823. Until then, retain the confirmed delete/read pair where it still exists and report unresolved cleanup. This does not prevent cleanup of a confirmed delete whose read is already absent, subject to the other safety gates.

**Creating remote deletion intent:** The current [memory store's CreateDeleteDesire](https://github.com/openshift-hyperfleet/hyperfleet-applier/blob/f15f3f8630e15fc6f446edc535ccef6f370907e2/pkg/desire/store/memory/store.go) removes the sibling apply without an expected apply version or expected provenance parameter. The [store interface](https://github.com/openshift-hyperfleet/hyperfleet-applier/blob/f15f3f8630e15fc6f446edc535ccef6f370907e2/pkg/desire/store.go) exposes no such precondition. Once the sweeper owner exemption is implemented, a replacement apply could appear after inspection and be superseded by a delete based on the old origin. That can request deletion of a live target, not merely remove a rebuildable store record.

This is a design gate owned by HYPERFLEET-1823, not an accepted extension of the record-removal trade-off or work already assigned by HYPERFLEET-1937. The recommendation is to require an atomic guard against replacement of the inspected target intent before enabling orphan-apply sweeping. HYPERFLEET-1823 must obtain the API/store owners' wire and store decision, including delete/recreate at the same version, and record the implementation owner and ticket before closing. An alternative is a documented and enforced target-identity invariant excluding this case. Re-reading or version equality alone is not that guarantee. Do not silently invent an `expected_*` field or assume target names are never reused. Partition discovery is independent; confirmed-delete cleanup also has the separate incarnation-safety gate above.

**Origin reappears after deletion intent:** [Working Assumption and Open Question](#working-assumption-and-open-question) have not established whether this is excluded from supported lifecycles. An unconfirmed sweeper-owned delete blocks an Adapter apply through the owner check (`HYPERFLEET-CNF-004`), and ADR-0028 orders Applier apply/delete passes; these protections narrow the scenario but do not prove A1. The Applier does not revalidate the HyperFleet origin before Kubernetes DELETE, and removal of the store record cannot revoke work already in flight. If Q1 finds a supported counterexample, select and test safe coordination with in-flight Applier work before enabling orphan remote deletion. This open question does not block partition enumeration.

## Cadence and Operations

Keep the earlier **12-hour** starting interval, configurable, for a complete sweep. This is a scheduling decision, not a measured capacity result or a 12-hour deletion SLA. Start a fresh enumeration each run; expose an on-demand invocation using the same authorization and eligibility checks for tests and operations.

The deployment must serialize scheduled and on-demand runs. HYPERFLEET-1840 must supply and test one exclusion mechanism shared by both entry points, rather than relying on a rule that covers only scheduled runs. It must also define run deadlines and bounded concurrency from measured capacity, without abandoning later partitions silently when an earlier one is slow.

Do not block an entire fleet scan waiting for finalizers or an offline Applier. Leave the delete pending and revisit it on the next sweep. Under healthy scheduling, stable records, and runs completing within the interval, an orphan that becomes eligible just after a scan may wait almost 12 hours for discovery; confirmation after that scan may require another sweep for record removal. Failures, long runs, or inaccessible Appliers extend that time without a fixed bound.

**Ownership delay:** The current [memory](https://github.com/openshift-hyperfleet/hyperfleet-applier/blob/f15f3f8630e15fc6f446edc535ccef6f370907e2/pkg/desire/store/memory/store.go#L65-L83) and [Redis](https://github.com/openshift-hyperfleet/hyperfleet-applier/blob/f15f3f8630e15fc6f446edc535ccef6f370907e2/pkg/desire/store/redis/store.go#L289-L309) stores check target ownership before retiring a confirmed delete on Apply creation. Thus even a confirmed sweeper-owned delete blocks a new Adapter owner with `HYPERFLEET-CNF-004` until cleanup removes it and any other old-owner records. The delay can extend through the next scheduled sweep or longer under the failures above; confirmation does not release ownership immediately. An authorized on-demand sweep can shorten the wait once all cleanup checks pass, but does not bypass them. Surface the conflict and pending cleanup; do not tell the Adapter to retry an owner conflict unchanged.

Use the detailed design's capped backoff, jitter, and `Retry-After` handling. Report run completeness, last completed run, partitions/records examined, pending confirmations, unresolved provenance/read-only cases, conflicts, and failures by reason. Keep per-resource identifiers in logs, not unbounded metric labels. A successful scan with retained unresolved work is distinct from successful cleanup of every orphan.

Capacity validation must include all three types, predominantly live origins, large decommissioned partitions, retained deletes, and scan traffic concurrent with Applier polls. Work includes partition/desire pages, candidate GETs, origin lookups, and fresh checks before mutations. Do not estimate it as one request per partition. Page-size limits and an appropriate index/query plan must be validated on the Postgres backend; no fleet-size or throughput result was measured for this document.

## Alternatives and Trade-offs

| Alternative | Assessment |
| --- | --- |
| Option 1: complete cleanup before decommission removes registration | Can keep the Applier reachable during normal teardown, but cannot discover leftovers after a failed/bypassed teardown or lost registration. Requires coordination with the decommission workflow |
| Option 2: enumerate partitions from remaining store rows | Selected in ADR-0039. Covers residual rows without a registry or dependency on live registrations. Adds a metadata route, a separate API/Postgres query and sweeper client operation, an authorization exception, and integration tests. Keeps the shared partition-scoped store interface unchanged; cannot restore an unavailable Applier |
| Options 1 and 2 together | Compatible, but not required to close the discovery gap. Adds two cleanup entry points and ordering/retry obligations. Reuse the same confirmation rules if decommission cleanup is added separately |
| Accept the registration-list gap | Leaves exactly the fully-decommissioned partitions in the ticket undiscoverable; rejected |
| Direct DB scan by sweeper | Avoids a new API operation but violates API-mediated access and distributes database access; rejected |
| TTL or force cleanup after a deadline | Confuses failed communication with absent ownership or successful deletion; rejected, consistent with the earlier spike |

The cost of conservative cleanup is retained unresolved rows, delayed reclamation, and delayed acquisition by a different owner. The benefit is that source lookup failures, read-only observations, and missing Appliers cannot by themselves authorize remote deletion. There is no automatic solution here for a Kubernetes object whose ownership desires were all lost, unconfirmed deletion after its Applier is permanently removed, or confirmation overwritten by a failed resource pre-check.

## Review and Implementation Gates

### Design Closure: HYPERFLEET-1823

The spike owner retains these unresolved design and coordination actions under HYPERFLEET-1823. Recording them here does not close them. Implementation need not finish to close a spike, but an accepted design and explicit delivery/test ownership are required.

| Gate | Required resolution before closing HYPERFLEET-1823 |
| --- | --- |
| Remaining design decisions | Option 2, the API/Postgres metadata boundary, and its narrow authorization/v1 exceptions are recorded in ADR-0039. Settle the deletion-safety gates below and record the remaining cleanup/retention and 12-hour cadence decisions, including the ownership delay |
| Confirmation after recreation | With API/store and Applier owners, select a mechanism and record its implementation/test ticket, or explicitly accept the documented risk. PR #273 only documents the limit; this proposal does not accept it |
| Destructive supersede safety | With API/store owners, settle the atomic guard or enforced identity invariant, including same-version recreation; record the implementation/test owner and ticket. No verified follow-up currently owns this new requirement |
| Read cleanup after confirmed delete | With API/store and Adapter owners, define a safe handoff that preserves the read mirror of any live replacement apply; assign the implementation and test owner. A separate read and version-checked delete leave this race open, and no bounded recovery time has been established |
| A1 assumption validation (open question Q1) | Before enabling orphan remote deletion, validate with API, Adapter, and Applier owners whether supported recovery, naming, and handover can reappear or reassign a live target during pending deletion. Record evidence and tests that A1 holds, or select and test coordination with in-flight Applier work for a counterexample. ADR-0039 does not accept this destructive risk or decide cancellation; enumeration can proceed independently |
| Architecture integration | **Partition-enumeration integration is included in this PR:** ADR-0039, partial-supersession links from ADR-0022/0029, HLD, glossary, and metadata tests SWP-6 through SWP-9. C3 records enumeration as decided but retains the cleanup-safety questions. Complete that remaining C3 work; reconcile C8 with specification 0.2.0, G2 with HYPERFLEET-1840/1938, and PR #273's pending G15 with HYPERFLEET-1937 before closure |
| Ticket and specification integration | HYPERFLEET-1821 is closed, so the original “before OpenAPI finalization” criterion can no longer be met in sequence. Update HYPERFLEET-1823's AC5 to require the Detailed Design amendment and follow-up OpenAPI publication before implementing the new operation. Record follow-up IDs and scope acceptance for the metadata route, authorization, clients, provenance, and tests; narrow the one-partition wording in HYPERFLEET-1840 and affected API/gateway stories to desire-record operations. Link the accepted decision from HYPERFLEET-1840 to satisfy AC6 |

### Delivery and Test Tracking

Existing tickets below provide confirmed ownership only for their current scope. Entries marked **proposed extension** require owner agreement and a ticket update or a separate follow-up recorded under HYPERFLEET-1823; they are not claims that the new work is already assigned.

| Work | Delivery/test tracking and repository |
| --- | --- |
| Metadata wire contract | **New follow-up required**, tracked for assignment by HYPERFLEET-1823 in `hyperfleet-desire-store-spec`. Publish the accepted route, paging rules, authorization, and specific compatibility exception after 0.2.0; do not reopen or silently expand completed HYPERFLEET-1821 |
| Metadata handler and Postgres query | **New follow-up required** in `hyperfleet-desire-store`, with owner assignment tracked by HYPERFLEET-1823. [HYPERFLEET-1825](https://redhat.atlassian.net/browse/HYPERFLEET-1825) is closed with the five desire-record operations; [HYPERFLEET-1671](https://redhat.atlassian.net/browse/HYPERFLEET-1671) is in progress for listing within a selected partition through the existing store interface, not the separate fleet metadata query. Include service integration tests and agree any [HYPERFLEET-1865](https://redhat.atlassian.net/browse/HYPERFLEET-1865) CI scope extension |
| Metadata gateway/operator permission | **Proposed extension** to [HYPERFLEET-1831](https://redhat.atlassian.net/browse/HYPERFLEET-1831) AuthConfig rendering in `hyperfleet-operator` and [HYPERFLEET-1833](https://redhat.atlassian.net/browse/HYPERFLEET-1833) gateway isolation tests. Record the exact route rule, claim validation, negative tests, and owner acceptance before implementation |
| Store owner exemption | [HYPERFLEET-1937](https://redhat.atlassian.net/browse/HYPERFLEET-1937) owns shared-store changes in `hyperfleet-applier`, including memory/Redis conformance and preserving the Adapter-owned read on takeover. HYPERFLEET-1671's Postgres backend and the HTTP clients must integrate that contract; HYPERFLEET-1825 is not the owner of the shared-store fix |
| Provenance and source lookup | `resource_id` population was requested in a comment on [HYPERFLEET-1837](https://redhat.atlassian.net/browse/HYPERFLEET-1837), but is not yet in its acceptance criteria. HYPERFLEET-1823 must secure explicit ownership for that `hyperfleet-adapter` work and the corresponding HYPERFLEET-1840 resolver tests, including supported forms, authoritative not-found, and permissions (G7) |
| Sweeper client and execution | [HYPERFLEET-1840](https://redhat.atlassian.net/browse/HYPERFLEET-1840) owns `hyperfleet-sweeper`, on-demand invocation, retained Adapter-delete cleanup, and the timeout-owner guard. Its metadata client, shared scheduled/manual exclusion, unresolved-work reporting, and the additional tests below are **proposed scope extensions** |
| Deployment and orphan E2E | [HYPERFLEET-1938](https://redhat.atlassian.net/browse/HYPERFLEET-1938) owns the sweeper chart, deployment wiring, and service-account allowlist integration with HYPERFLEET-1831. A dedicated orphan-journey E2E follow-up was requested in HYPERFLEET-1840's discussion, dependent on the sweeper and Adapter provenance; no accepted ticket ID was verified. HYPERFLEET-1823 must record that owner/ticket and update G2/SWP-4 before closure |

The three safety decisions and the A1 validation question remain separately tracked in the design table; they are not assigned to PR #273 or HYPERFLEET-1937 by inference. This PR records the enumeration decision and its architecture integration; it creates no Jira tickets or implementation artifacts for those follow-ups.

## Validation Obligations

The existing SWP-1 through SWP-5 and CAS-5 scenarios in the [Desire Store test plan](e2e-testing/desire-store-test-plan.md#sweeper-privileges) remain relevant. SWP-6 through SWP-9 now specify partition-enumeration and metadata-authorization tests for ADR-0039; their implementation/test ownership still requires assignment. C3 records that decision separately from unresolved cleanup safety. Extend the cleanup tests after their design gates are resolved. At minimum, tests must prove:

- A partition absent from registrations is still enumerated when any desire type remains; empty partitions disappear. Pagination is bounded, deduplicated, and handles concurrent additions/removals without treating failure as an empty store.
- Only the sweeper can list partition metadata. A metadata Wristband cannot read or mutate desires, and malformed or mixed scope claims fail before any data access.
- An existing/pending-deletion origin, failed lookup, missing provenance, or conflicting siblings causes no destructive action.
- Validate A1 against supported API recovery, Adapter naming, and ownership-handover paths before enabling orphan remote deletion: establish whether an absent origin can reappear or its target can be reassigned to a live source while deletion is pending. Inject an A1 counterexample to check that the sweeper reports it and initiates no further cleanup for that target, without claiming to cancel an in-flight Applier. If Q1 finds a supported counterexample, define and test coordination with in-flight Applier work before enabling this path.
- Only `Successful=True` / `Deleted` with matching generation on the current delete record can confirm completion. A status written for a previous incarnation must not confirm a recreated record. Accepted Kubernetes DELETE, finalizers, stale generation, or read-mirror lag do not substitute for confirmation.
- A failed resource pre-check after earlier confirmation, and a new delete for an unresolvable resource type, retain their records and report unresolved work. Do not fall back to remembered success or equate discovery failure with object absence.
- Confirmed Adapter-owned deletes stay while the origin exists and are eligible for removal after it is absent; a matching read is removed first only after the read-cleanup safety gate is resolved. Pending deletes survive an unavailable/revoked Applier.
- A crash between read and delete removal resumes safely. Timeout/conflict handling re-evaluates eligibility and obeys the existing owner guard.
- A confirmed delete can be retired by an Adapter apply while its read remains at the same version. An apply arriving before or during sweeper cleanup must not lose the live target's read mirror; test the accepted atomic handoff. Without one, retain and report the pair rather than claiming cleanup succeeded.
- A standalone read is retained without creating a remote delete. A lost desire is never treated as proof that Kubernetes deletion succeeded.
- A replacement apply inserted between orphan inspection and delete creation is not silently deleted; the chosen supersede-safety resolution must provide the test oracle before this path is enabled.
- Scheduled and on-demand runs cannot overlap, and on-demand tests do not wait 12 hours. Failures and retained unresolved work remain observable.
- A different Adapter owner receives CNF-004 while a sweeper-owned delete remains, even when confirmed. Ownership becomes available only after eligible cleanup removes all conflicting records; an on-demand run reduces scheduling delay without bypassing safety checks.

These are tests to implement, not tests executed by this documentation change.

## Acceptance Criteria Mapping

| Ticket criterion | Status with this PR | Completion requirement |
| --- | --- | --- |
| Decide enumeration, including fully-decommissioned clusters | Decision recorded | [ADR-0039](../adrs/0039-sweeper-partition-enumeration.md) selects option 2, its metadata contract and authorization, and separates discovery from remote-deletion capability. This decision and its supporting documents are included for review and merge |
| Define deletion confirmation | Recommendation; safety decision open | [Deletion Confirmation](#deletion-confirmation) names condition, reason, and generation checks; resolve incarnation safety before relying on them for cleanup |
| Define which delete/read records are removed | Recommendation; safety decisions open | [Record Cleanup](#record-cleanup) proposes record ordering and retention; resolve destructive supersede and read-cleanup safety, and track the A1 assumption/open question for origin reappearance or target reassignment |
| Confirm or revise roughly 12-hour cadence | Recommendation awaiting decision | [Cadence and Operations](#cadence-and-operations) recommends 12 hours and describes its limits; record the cadence decision |
| Amend detailed design before OpenAPI finalization | Amendment recorded; original sequence missed | Specification 0.2.0 already shipped. This PR records the [subsequent amendment](desire-store-dd.md#sweeper-partition-enumeration); update HYPERFLEET-1823's AC5 to require publication of the follow-up OpenAPI specification before implementing the new endpoint |
| Record decision in architecture and link from sweeper story | Architecture record included; story link outstanding | ADR-0039 and the related architecture updates record enumeration. Add the reverse link from HYPERFLEET-1840 and record the remaining spike decisions; a Jira link from this file does not satisfy that criterion |

**Jira alignment required before closing HYPERFLEET-1823:** AC5 still uses the original timing. Proposed replacement: "If the decision changes the Desire Store API surface, amend the Detailed Design and publish the follow-up OpenAPI contract before implementing the new operation." AC6 still requires a link from HYPERFLEET-1840 back to the architecture decision; add that link to the sweeper story after this ADR is published. These ticket changes are not made by this repository edit.

## References

- [HYPERFLEET-1823](https://redhat.atlassian.net/browse/HYPERFLEET-1823)
- [HYPERFLEET-1840](https://redhat.atlassian.net/browse/HYPERFLEET-1840)
- [ADR-0039: Sweeper Partition Enumeration](../adrs/0039-sweeper-partition-enumeration.md)
- [Desire Store Detailed Design](desire-store-dd.md)
- [Desire Store Architecture Overview](desire-store-hld.md)
- [Desire Identity and Ownership](spike-desire-identity-ownership.md)
- [Desire Garbage Collection Strategy](spike-desire-garbage-collection.md)
- [Desires Lost Mid-Deletion](spike-desires-lost-mid-deletion.md)
- [Desire Store Test Plan](e2e-testing/desire-store-test-plan.md)
