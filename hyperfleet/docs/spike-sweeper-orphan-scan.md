---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-11-24
---

# Spike: Sweeper Orphan-Scan Design

**Ticket:** [HYPERFLEET-1823](https://redhat.atlassian.net/browse/HYPERFLEET-1823)\
**Epic:** [HYPERFLEET-1518](https://redhat.atlassian.net/browse/HYPERFLEET-1518)\
**Consumer:** [HYPERFLEET-1840: Centralized desire sweeper](https://redhat.atlassian.net/browse/HYPERFLEET-1840)

**Decision state: option 2 recorded in [ADR-0039](../adrs/0039-sweeper-partition-enumeration.md).** This PR records partition enumeration from remaining desire rows, the API/Postgres metadata boundary, and the narrow authorization and v1 compatibility exceptions. The ADR, earlier ADR references, detailed design, HLD, glossary, and test plan are updated together. This is a design decision, not a claim that the endpoint is published or implemented. HYPERFLEET-1823 remains open for the separate deletion-safety decisions, remaining recommendations, and ticket/specification integration described in the [design gates](#review-and-implementation-gates) and [acceptance-criteria mapping](#acceptance-criteria-mapping).

## What and Why

The [garbage-collection spike](spike-desire-garbage-collection.md) selected a centralized Hub sweeper. It correlates each desire's `resource_id` with the originating HyperFleet API resource, requests remote cleanup through a `DeleteDesire`, and removes desire records after the Applier confirms deletion. This spike specifies partition discovery, confirmation, record cleanup, and cadence under the API-mediated Desire Store design.

The sweeper complements normal deletion. The API, Sentinel, and Adapter still drive normal resource deletion. The [delete-recovery decision](spike-desires-lost-mid-deletion.md) requires an Adapter to retain a confirmed `DeleteDesire` until the originating API resource is gone, while removing its `ReadDesire`. Those retained records are expected sweeper work even when normal deletion succeeds. An orphaned `ApplyDesire` is a different case: the source has disappeared but intent to keep a remote object present remains.

Partition discovery cannot depend only on live management-cluster registrations. For example, desires remain under partition `mc-01` after its registration is removed. A registration-derived list no longer includes `mc-01`; a list derived from remaining Desire Store records does. Removing a registration does not establish that its Kubernetes objects were deleted, nor does it establish that each desire's originating API resource is gone.

A **partition** is the `managementCluster` dimension of desire identity. It groups records targeting one management cluster; it is not a customer, cloud region, or the originating resource's `resource_id`. Partitions are implicit row groupings, materialized by a first write ([partition selection](desire-store-dd.md#partition-selection)).

## Evidence and Scope

The ticket and relevant delivery stories were rechecked on 2026-11-24. Code observations below refer to the pinned revisions.

| Source | Verified baseline and relevance |
| --- | --- |
| Architecture | [`7127fe9`](https://github.com/openshift-hyperfleet/architecture/tree/7127fe9360fea3534ded7da5827be25f1b4bb09e): partition-scoped REST routes, owner exemption, conditional record deletes, garbage collection, and retained-delete decisions |
| Applier | [`f15f3f8`](https://github.com/openshift-hyperfleet/hyperfleet-applier/tree/f15f3f8630e15fc6f446edc535ccef6f370907e2) is the delete-controller baseline. [Applier PR #86](https://github.com/openshift-hyperfleet/hyperfleet-applier/pull/86) added `SweeperStore` in memory and Redis. The service still needs to wire the exemption through the API and Postgres |
| Adapter | [`0806e99`](https://github.com/openshift-hyperfleet/hyperfleet-adapter/tree/0806e994d7171e9cf76865dca1ce639b7b485dc8) predates Adapter provenance. Open [Adapter PR #366](https://github.com/openshift-hyperfleet/hyperfleet-adapter/pull/366) adds `OriginID` from the event ID for apply, delete, and read creation (test-plan G7) |
| Published wire contract | [Spec PR #2](https://github.com/openshift-hyperfleet/hyperfleet-desire-store-spec/pull/2) published 0.2.0 for HYPERFLEET-1821. [Spec PR #3](https://github.com/openshift-hyperfleet/hyperfleet-desire-store-spec/pull/3) corrected per-type CNF-001 recovery and clarified the store exemption. The current [specification 0.2.2](https://github.com/openshift-hyperfleet/hyperfleet-desire-store-spec/blob/v0.2.2/schemas/desire-store/openapi.yaml) defines all five desire-record operations, GET `generation`, version-checked Apply/Delete status writes, and atomic delete supersede. It has no partition-listing operation |
| Contract alignment | [Architecture PR #273 / HYPERFLEET-1923](https://github.com/openshift-hyperfleet/architecture/pull/273) merged on 2026-11-19. Its shared status-version, GET schema, supersede, and owner-collision rules are the baseline. It resolved test-plan C4 and C5 and added G15 for the sweeper exemption. The stale-status-after-recreation limit remains open |

HYPERFLEET-1821 is closed. [HYPERFLEET-1937](https://redhat.atlassian.net/browse/HYPERFLEET-1937) delivered the shared-store exemption in [Applier PR #86](https://github.com/openshift-hyperfleet/hyperfleet-applier/pull/86). [HYPERFLEET-1840](https://redhat.atlassian.net/browse/HYPERFLEET-1840) names `hyperfleet-sweeper` as the service repository and includes an on-demand test trigger. [HYPERFLEET-1938](https://redhat.atlassian.net/browse/HYPERFLEET-1938) owns the chart and deployment wiring. The metadata route still needs implementation ownership.

In scope: discovery through the Desire Store API; safe interpretation of source existence and deletion status; record cleanup; scheduling; API and test obligations. Out of scope: implementing the sweeper, provisioning or destroying management clusters, granting direct database/Kubernetes access to the sweeper, and recovering objects after every ownership record has been lost.

## Recorded Decision and Remaining Recommendations

Only partition enumeration and its associated API, authorization, and compatibility choices are recorded by ADR-0039. The other rows remain recommendations subject to the design gates below.

| Topic | Decision or recommendation |
| --- | --- |
| Partition discovery | **Recorded in ADR-0039.** Option 2: add a sweeper-only metadata operation listing partitions represented by remaining desire records, across all three desire types |
| Orphan detection | Require an authoritative lookup establishing that the specific `resource_id` is absent. Lookup failures and missing provenance do not establish an orphan |
| Remote deletion | Proposed: write a `DeleteDesire` for an orphaned managed target and let its partition's Applier perform Kubernetes deletion. Resolve the supersede safety gate and publish/enforce the target-identity invariant that A1 relies on before enabling this path |
| Confirmation | Read the current `DeleteDesire`; require `Successful=True`, `reason=Deleted`, and `observedGeneration` equal to that record's `generation`. Before relying on this for cleanup, prevent a status from a previous record incarnation from confirming a recreated delete |
| Cleanup | Following source absence and confirmation, remove the matching orphaned `ReadDesire` under the atomic sibling checks below, then remove the `DeleteDesire`. Apply the same eligibility rules to Adapter-owned retained deletes |
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
4. A multi-page scan is not a snapshot. Resume an unfinished scheduled traversal using the [saved scan position](#cadence-and-operations). Start from the beginning after reaching the final page so a partition inserted behind the position is considered in the next traversal.
5. Use bounded pages, request concurrency, and retries. On a failed partition, record the failure and continue to other partitions where possible. Do not retain the whole fleet's manifests in memory.

Option 2 closes the **discovery** gap for remaining records. If the management cluster no longer has a working, authorized Applier, it does not create a new means to confirm remote deletion. A delete whose current stored status still satisfies the confirmation predicate is eligible for cleanup, subject to the incarnation-safety gate below; previously observed success alone is insufficient. An unconfirmed delete remains visible as unresolved work.

## Orphan Detection

Interpret `resource_id` as provenance, not Kubernetes identity or the partition identifier. For API-created resources, the canonical value is the resource UUID returned as `event.id`, not a path such as `clusters/<name>`. Resolve it with the kind-agnostic `GET /api/hyperfleet/v1/resources/{id}` lookup. That lookup returns 200 while the resource is in `Finalizing`; the row disappears only on hard delete. It must not follow an arbitrary URL supplied in desire content.

The 404 is authoritative only for a system caller. Resource lookups pass through tenant scoping, so a tenant-scoped caller receives the same 404 for another tenant's live resource. The sweeper's API identity must therefore resolve with `hf_system=true` (the general gateway's ServiceAccount classification), not merely be a fleet-scoped Desire Store caller. A tenant-scoped lookup must be treated as non-authoritative. Record the exact identity and permission in HYPERFLEET-1840/HYPERFLEET-1938; a Desire Store Wristband does not authorize this HyperFleet API lookup.

| Lookup outcome | Sweeper action |
| --- | --- |
| Origin exists, including a resource pending deletion | Preserve Adapter-owned desires and stop orphan cleanup. If a sweeper-owned `DeleteDesire` already exists, report a possible A1 counterexample as described below; do not claim that stopping cleanup cancels remote work already in flight |
| Authoritative not-found for the exact supported origin | Candidate orphan; inspect current siblings and apply the cleanup rules |
| Timeout, connection error, 429, 5xx, authentication/authorization failure, or a 404 from a tenant-scoped/otherwise non-authoritative caller | Preserve records, record the failure, and retry as appropriate. Only a system-scoped lookup can establish authoritative absence |
| Missing, malformed, unsupported, or conflicting provenance | Preserve records and report the reference problem; do not guess an origin from target names or a partition |

### Working Assumption and Open Question

**A1 (pending validation):** From the sweeper's final API check that confirms the source is absent, through `DeleteDesire` creation and until remote deletion is confirmed, supported HyperFleet operations cannot restore that same API resource or assign its Kubernetes target to another live source.

**Evidence reviewed on 2026-11-19:**

- `hyperfleet-api` generates a new UUID v7 in [`Resource.BeforeCreate`](https://github.com/openshift-hyperfleet/hyperfleet-api/blob/fd9dee702caecd1731569ab3fe8e97568a8f6190/pkg/api/resource.go#L53-L60) using [`uuid.NewV7`](https://github.com/openshift-hyperfleet/hyperfleet-api/blob/fd9dee702caecd1731569ab3fe8e97568a8f6190/pkg/api/resource_id.go). No restore or undelete route exists. A new resource receives a new ID, and `Finalizing` keeps the original row until hard delete.
- The kind-agnostic [`GET /resources/{id}` route](https://github.com/openshift-hyperfleet/hyperfleet-api/blob/fd9dee702caecd1731569ab3fe8e97568a8f6190/cmd/hyperfleet-api/server/routes_entities.go#L89) calls `GetByID`; the [DAO](https://github.com/openshift-hyperfleet/hyperfleet-api/blob/fd9dee702caecd1731569ab3fe8e97568a8f6190/pkg/dao/resource.go#L223-L229) applies [`tenant.ScopeDB`](https://github.com/openshift-hyperfleet/hyperfleet-api/blob/fd9dee702caecd1731569ab3fe8e97568a8f6190/pkg/tenant/scope.go#L17-L27) and filters only by ID. A `Finalizing` row is therefore visible, while a tenant-scoped miss is not authoritative absence.
- The Adapter task configurations inspected in `hyperfleet-adapter`, `hyperfleet-infra`, and `hyperfleet-e2e` build the target name or its namespace from the event resource ID (`event.id`, exposed as `clusterId`, `nodepoolId`, or `resourceId`). Fixed names occur inside those resource-derived namespaces. Kubernetes object names are unique within a GVK and namespace, so a differently identified resource does not naturally land on the same target.

**Required invariant:** One remote Kubernetes object belongs to one HyperFleet resource. Its name, or the namespace that contains it, is derived from that resource's immutable ID; a shared or fixed target across resources is not permitted. The invariant must be stated in the [Adapter authoring guide](https://github.com/openshift-hyperfleet/hyperfleet-adapter/blob/main/docs/adapter-authoring-guide.md) and covered by configuration tests before A1 is treated as enforced.

**Evidence boundary:** This is a reviewed convention, not a current runtime guard. The PoC repositories and every future adapter configuration were not audited by this review. Existing RBAC resources shipped by Helm charts are not adapter-managed desires and are outside the invariant. A configuration that reuses a target across resources is already broken for lifecycle deletion, but until the invariant is documented and validated, A1 remains a design precondition rather than a proof for all deployments. The invariant establishes target identity, not apply ordering: a delayed, duplicated, or in-flight event for the deleted origin can still write an `ApplyDesire` for that same target after the final absence check. That is a same-origin stale apply, not a restored source, so it does not violate A1, but it leaves the destructive-supersede and paired-read cleanup gates open.

**Q1:** Does any supported recovery, restore, Adapter handover, or non-conforming adapter configuration violate A1 before `DeleteDesire` creation or while deletion is pending? The inspected API and adapter configuration set provides no such transition under the required invariant. The spike owner must publish and test that invariant, and audit adapters that do not follow it. A1 does not establish ownership for the separate same-version desire-record and status-write races below, an atomic source-absence precondition across the HyperFleet API and Desire Store, or the absence of a delayed apply for the deleted origin.

**Proposed handling if detected:** If a fresh check finds a reappeared origin or conflicting live provenance, stop initiating further cleanup for that target, retain the records, and report the case for investigation. No automatic cancellation or recovery mechanism is selected by this proposal. Stopping cleanup or removing a `DeleteDesire` cannot revoke Kubernetes work already read by the Applier or prove that the target survived.

Revalidate origin absence before issuing a destructive action. Do not carry a negative lookup across runs or use an earlier absent result after observing changed provenance. A final re-read narrows but does not close the gap before the separate store create. A positive existence result defers ordinary records; if sweeper-created deletion intent already exists, report it as a possible Q1 counterexample. Test the UUID reference form, `Finalizing` as present, an authoritative system-caller 404 as absent, and a tenant-scoped 404 as non-authoritative.

## Deletion Confirmation

The [current Applier controller](https://github.com/openshift-hyperfleet/hyperfleet-applier/blob/f15f3f8630e15fc6f446edc535ccef6f370907e2/internal/controllers/deletedesire/controller.go) resolves the Kubernetes target and checks it with GET. If it is already absent, deletion is confirmed. Otherwise it issues DELETE and checks again; a successful DELETE response alone is insufficient while the object still exists. A Kubernetes NotFound during deletion also confirms absence. Finalizers or graceful termination leave the delete pending.

The [status writer](https://github.com/openshift-hyperfleet/hyperfleet-applier/blob/f15f3f8630e15fc6f446edc535ccef6f370907e2/internal/controllers/deletedesire/status.go) writes `Successful=True`, `reason=Deleted`, and `observedGeneration` equal to the desire generation. Pending deletion uses `Successful=False` with `WaitingForDeletion`; failures use `KubeAPIError` or `PreCheckFailed`. The shared [`IsDeleted`](https://github.com/openshift-hyperfleet/hyperfleet-applier/blob/f15f3f8630e15fc6f446edc535ccef6f370907e2/pkg/desire/types.go) helper checks the true condition and `Deleted` reason; it does not itself check freshness.

**Pre-check limitation and planned Applier fix:** At `f15f3f8`, the controller calls `setupResourceClient` before checking `IsDeleted`. A mapping or namespace-validation failure can therefore replace a previously successful condition with `PreCheckFailed`. The Applier owner will change the order to check the freshly read `IsDeleted` condition before resolving the resource client, so a confirmed delete keeps its terminal condition when its CRD or API mapping has since been removed; the follow-up ticket ID is not yet linked. A new delete for an unresolvable type remains `PreCheckFailed`; a `NoMatch` or discovery failure is not treated as authoritative object absence because a broken aggregated API can look the same. Until that change ships, this design retains and reports both cases and does not restore a remembered success.

The sweeper's proposed confirmation predicate starts with a fresh GET of the specific `DeleteDesire` and all three condition checks in the decision table. Missing, duplicate/ambiguous, false, unknown, or stale conditions do not confirm deletion. This makes the short `Successful=True` wording in the older spike precise for the sweeper. It does not change the Adapter's confirmation helper in this documentation change.

`generation` belongs to the desire; it is neither the HyperFleet API resource generation nor Kubernetes `metadata.generation`. `version` is the record's compare-and-swap token and is separately needed for record removal. The published specification defines GET generation and the version precondition on Apply/Delete status writes. Use that published representation; do not substitute a list reference's version for generation. Version checking rejects stale writes after a version advance, but does not distinguish records recreated at the same version.

A missing `DeleteDesire`, a stale/nonexistent read mirror, an Adapter's `Finalized=True`, or the absence of an Applier is not this confirmation. A retained confirmed delete is historical evidence of that deletion; the current Applier can restamp an already-successful condition without re-reading the target object. It is not proof that no external actor ever recreated the same Kubernetes name afterward.

The condition, reason, and generation checks are necessary but insufficient if the record was deleted and recreated. The [merged detailed design](desire-store-dd.md#cas--version-semantics) documents that an old Applier status write can match a recreated `DeleteDesire` at the same version, mark it `Deleted`, and cause the Applier to skip the new deletion. The recreated delete starts at generation 1, so matching `observedGeneration` does not distinguish the two records. PR #273 records this as a remaining v1 limitation, not a fix; the status-version check and the HYPERFLEET-1937 exemption leave this gate open. HYPERFLEET-1823 retains responsibility for the safety decision with the API/store and Applier owners: specify a verified incarnation-safe confirmation mechanism and its delivery owner, or obtain explicit acceptance of this risk for sweeper cleanup. This proposal recommends the former and does not accept the risk. Until that decision is recorded, confirmation-based cleanup is not ready for implementation.

**Reviewed v1 risk-acceptance proposal (owner sign-off required):** The race needs a `delete → apply → delete` chain on the same target, plus an old Applier leader that was paused past the 120-second lease and whose status write for the first delete is processed after the new leader completes that chain. Within one leader, apply and delete passes and their status writes are serial, so a live leader cannot create this ordering itself. Leader election is not fencing; the leadership gate limits writes but cannot undo a request the API server already accepted. The result is a late `Deleted` at version 1 confirming the new delete, which leaves the remote object in place while cleanup treats it as deleted: a leaked object, not an incorrect deletion. A longer sweeper cadence narrows the opportunity but is not a guard; a stale status write can still confirm a sweeper-created delete. HYPERFLEET-1823 owners may accept that narrow v1 leak and track monotonic record versions as a follow-up, or require an incarnation-safe mechanism before cleanup. This document records the evidence and the proposed acceptance conditions but does not claim the risk has been accepted until the owners record that decision.

## Record Cleanup

### Eligibility and Scope

The following table applies only after the exact origin is authoritatively absent. If it exists, leave even a confirmed Adapter-owned delete in place, as [HYPERFLEET-1841](spike-desires-lost-mid-deletion.md) requires.

| Current records for one target | Action |
| --- | --- |
| ApplyDesire, with or without a matching read | Propose creating a DeleteDesire with the same target identity and provenance. It supersedes the apply through the store, not a separate sweeper DELETE of the apply. This path requires resolution of the supersede safety gate, publication and enforcement of the A1 target-identity invariant, and a working store-level owner exemption |
| Unconfirmed DeleteDesire, with or without a matching read | Retain it and the read. Do not replace it just to claim sweeper ownership. Revisit its status on a later run |
| Previously confirmed DeleteDesire now reporting `PreCheckFailed` | Retain it and any read; report unresolved cleanup. A removed CRD or failed mapping is not confirmation. The planned Applier pre-check ordering fix should prevent this overwrite; until it ships, treat the record as unconfirmed |
| Confirmed DeleteDesire plus a matching orphaned read | After the read-cleanup gate below is resolved, remove the read first under an atomic check of current delete confirmation and absence of a replacement apply. Until then retain and report the pair |
| Confirmed DeleteDesire without a read | Remove the delete after revalidation. A missing read is normal after Adapter cleanup |
| ReadDesire only | Retain and report for investigation. A read may observe an object this delivery path never managed; a lost apply cannot be reconstructed from the read alone |
| ApplyDesire and DeleteDesire coexist, sibling provenance conflicts, or an unexpected owner combination appears | Retain and report the inconsistency. Do not select one origin arbitrarily or claim successful cleanup |
| No desire records remain | No action. Do not discover and delete Kubernetes objects without independent ownership evidence |

Ordinary siblings have one owner. During a sweeper takeover, a sweeper-owned delete and an Adapter-owned read are the intended exception: the read keeps its owner and the provenance must match. Other owner mismatches require investigation.

The sweeper creates only `DeleteDesire` records. It does not need to create a `ReadDesire` to confirm deletion; the delete status is sufficient and the [caller matrix](desire-store-dd.md#caller-to-operation-matrix) prohibits its other desired-state writes. Do not copy the Adapter's paired-read creation into the sweeper.

The intended cleanup covers both records for managed orphan deletion and extends to confirmed Adapter-owned deletes, subject to the safety gates below. It explicitly limits automatic cleanup of standalone reads. Removing an orphaned read alone could stop an unnecessary watcher, but would discard the remaining evidence without resolving whether a managed target was stranded; that alternative is not selected here. Do not report retained records as completed cleanup.

### Removal Order and Recovery

1. Re-read the delete and any read sibling. Require matching target/provenance, no observed replacement apply, current deletion confirmation, and fresh authoritative origin absence.
2. Once the read-cleanup gate is resolved, remove the matching read only if the store can atomically check that the inspected delete is still the same confirmed record at the same version, the read is still the same matching record at its checked version, and no replacement apply exists. If any check fails, retain the read and re-evaluate before removing either record. Treat a missing read as absence of that record only. Re-evaluate conflicts and uncertain outcomes.
3. Re-read the delete and siblings before removing the delete. If a read is still present, confirmation/provenance changed, an apply appeared, or any required check failed, retain the delete. Otherwise remove it with its current version.
4. A crash between these steps leaves the delete record. On the next run, recheck its current confirmation and eligibility before continuing. Cleanup never recreates the read or reissues remote deletion solely because a prior removal was interrupted.

The two removals are not one transaction. Re-reads reduce stale decisions but do not make them atomic. Use the existing [sweeper timeout guard](desire-store-dd.md#cas--version-semantics): after a timed-out delete, a direct retry is allowed only if the re-read record has the same version and the sweeper's own stored owner. Adapter-owned records are eligible for initial confirmed cleanup, but an ambiguous result requires the full eligibility check again, not a blind retry under the exemption. Changed versions, owners, or provenance always require re-evaluation.

### Races That Re-Reads Do Not Solve

**Record removal:** The detailed design accepts a same-version recreation window because versions restart at 1. The cross-owner sweeper case applies only after the API and Postgres use the HYPERFLEET-1937 sweeper exemption; until then the store rejects the cross-owner operation. The owner/version guard is not a unique record-incarnation check. This spike does not claim to close that window or add an unapproved UID precondition.

**Read cleanup after a confirmed delete:** The shared store permits an Adapter to create a new `ApplyDesire` after a confirmed `DeleteDesire`, [retiring that delete](https://github.com/openshift-hyperfleet/hyperfleet-applier/blob/f15f3f8630e15fc6f446edc535ccef6f370907e2/pkg/desire/store/memory/store.go#L60-L82) while leaving a same-target `ReadDesire` in place. The [Adapter apply path](https://github.com/openshift-hyperfleet/hyperfleet-adapter/blob/0806e994d7171e9cf76865dca1ce639b7b485dc8/internal/desireclient/apply.go#L143-L158) writes it from an event; the desire write itself performs no authoritative origin-existence check, and it [leaves a same-version mirror untouched](https://github.com/openshift-hyperfleet/hyperfleet-adapter/blob/0806e994d7171e9cf76865dca1ce639b7b485dc8/internal/desireclient/apply.go#L225-L231). The read can therefore remain at version 1. A sweeper that inspected the old confirmed-delete/read pair can then delete the read after the apply becomes live: the current conditional read delete checks the read's version and owner, not whether an apply sibling exists. The HYPERFLEET-1937 exemption also allows removal of an Adapter-owned read once the API and Postgres integrate it. Even the same Adapter owner can replace a confirmed delete, so this is not limited to a cross-owner or pending-delete case under working assumption A1. The Adapter may recreate a missing read on a later reconcile, but no maximum delay is established; that repair is not an accepted safety bound.

**Delete confirmation changes during read cleanup:** If the Applier writes `PreCheckFailed` after the sweeper's final inspection, it advances the delete version without changing the read version. The existing [single-record `DeleteReadDesire`](https://github.com/openshift-hyperfleet/hyperfleet-applier/blob/155664cf7969e7d766654c1276475317066379c2/pkg/desire/store.go) could remove the read and leave an unresolved delete. Keep both records if confirmation is lost before the atomic check and report the unresolved cleanup.

Keep automatic paired-read removal disabled until the API/store and Adapter owners define and test the atomic sibling checks in step 2. They must serialize with status writes and changes to apply, delete, or read siblings. The store must distinguish delete and read records recreated at the same version. A separate re-read, read version, or owner comparison cannot enforce these requirements. Record the API/store contract, implementation owner, and tests under HYPERFLEET-1823. A confirmed delete whose read is already absent remains eligible subject to the other cleanup gates.

**Creating remote deletion intent:** The current [memory store's CreateDeleteDesire](https://github.com/openshift-hyperfleet/hyperfleet-applier/blob/f15f3f8630e15fc6f446edc535ccef6f370907e2/pkg/desire/store/memory/store.go) removes the sibling apply without an expected apply version or expected provenance parameter. The [store interface](https://github.com/openshift-hyperfleet/hyperfleet-applier/blob/f15f3f8630e15fc6f446edc535ccef6f370907e2/pkg/desire/store.go) exposes no such precondition. Once the API and Postgres use the sweeper owner exemption, a replacement apply could appear after inspection and be superseded by a delete based on the old origin. That can request deletion of a live target, not merely remove a rebuildable store record.

An atomic guard on the inspected apply would not close the separate source gap. If a supported restore or reassignment makes the origin or target live after the final HyperFleet API absence check but before `CreateDeleteDesire` commits, the Adapter may not yet have written a replacement apply. The store guard can then pass against unchanged siblings. No reviewed source establishes an atomic cross-system source-absence precondition for the store create; a last-moment re-read is still a separate request.

This is a design gate owned by HYPERFLEET-1823, not an accepted extension of the record-removal trade-off or work already assigned by HYPERFLEET-1937. Before enabling orphan-apply sweeping, require both a store-level guard against replacement of the inspected target intent and publication, validation, and enforcement of the target-identity invariant that excludes live-source reassignment across the create and pending-delete intervals. HYPERFLEET-1823 must obtain the API/store/Adapter owners' contract decision, including same-version recreation and the pre-create origin gap, then record implementation and test owners. Re-reading or version equality alone is not a guarantee. Do not silently invent an `expected_*` field or assume every future adapter follows the naming convention. Partition discovery is independent; confirmed-delete cleanup also has the separate incarnation-safety gate above.

**Origin or target becomes live around deletion intent:** The reviewed API and adapter configurations support A1 under the target-identity invariant, but that invariant is not yet published or enforced. An unconfirmed sweeper-owned delete blocks an Adapter apply through the owner check (`HYPERFLEET-CNF-004`), and ADR-0028 orders Applier apply/delete passes; these protections narrow the post-create scenario but do not address a non-conforming adapter or prove the pre-create interval. The Applier does not revalidate the HyperFleet origin before Kubernetes DELETE, and removal of the store record cannot revoke work already in flight. Select and test coordination with in-flight Applier work before enabling orphan remote deletion if the invariant audit finds a violation. This open question does not block partition enumeration.

## Cadence and Operations

Use the earlier **12-hour** starting interval for scheduled runs, configurable. A traversal can span multiple runs when it reaches a deadline. Expose an on-demand invocation using the same authorization and cleanup eligibility checks.

Serialize scheduled and on-demand runs within the deployment. HYPERFLEET-1840 must supply and test one exclusion mechanism shared by both entry points. Use measured capacity to set a run deadline, bounded concurrency, and a per-partition work budget so an early partition cannot monopolize the run.

For scheduled runs, persist the metadata page's request cursor and the last partition in that page that has been either attempted or explicitly recorded as deferred. Advance the position only across contiguous partitions in enumeration order. Record a failed or budget-limited partition as unresolved work and retry it on the next traversal. After a deadline or restart, re-fetch the saved page, skip identifiers through the saved partition, and continue with later identifiers and pages. A failed metadata page leaves the position at that page. If the API rejects the saved cursor, report the interrupted traversal and restart from the first page. At the end of each traversal, clear the position so the next scheduled run starts at the first page. On-demand runs start at the first page and leave scheduled progress alone.

For a stable list of `N` partitions, if each scheduled run advances across at least `K` partitions or reaches the end, the traversal reaches every partition within `ceil(N / K)` runs. Report deadline-limited runs as incomplete even when they save progress. Keep scan progress distinct from confirmed record cleanup and report unresolved partitions separately. Never carry an earlier orphan or deletion check across runs.

Do not block an entire fleet scan waiting for finalizers or an offline Applier. Leave the delete pending and revisit it on the next traversal or an eligible on-demand run. Under healthy scheduling, stable records, and runs completing within the interval, an orphan that becomes eligible just after a scan may wait almost 12 hours for discovery; confirmation after that scan may require another sweep for record removal. Failures, long runs, or inaccessible Appliers extend that time without a fixed bound.

**Ownership delay:** The current [memory](https://github.com/openshift-hyperfleet/hyperfleet-applier/blob/f15f3f8630e15fc6f446edc535ccef6f370907e2/pkg/desire/store/memory/store.go#L65-L83) and [Redis](https://github.com/openshift-hyperfleet/hyperfleet-applier/blob/f15f3f8630e15fc6f446edc535ccef6f370907e2/pkg/desire/store/redis/redis.go#L286-L310) stores check target ownership before retiring a confirmed delete on Apply creation. Thus even a confirmed sweeper-owned delete blocks a new Adapter owner with `HYPERFLEET-CNF-004` until cleanup removes it and any other old-owner records. The delay can extend through the next scheduled traversal or longer under the failures above; confirmation does not release ownership immediately. An authorized on-demand sweep can shorten the wait once all cleanup checks pass, but does not bypass them. Surface the conflict and pending cleanup; do not tell the Adapter to retry an owner conflict unchanged.

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

The cost of conservative cleanup is retained unresolved rows, delayed reclamation, and delayed acquisition by a different owner. The benefit is that source lookup failures, read-only observations, and missing Appliers cannot by themselves authorize remote deletion. There is no automatic solution here for a Kubernetes object whose ownership desires were all lost, unconfirmed deletion after its Applier is permanently removed, confirmation overwritten by a failed resource pre-check, or residual rows after the management cluster and its Applier are decommissioned.

## Review and Implementation Gates

### Design Closure: HYPERFLEET-1823

The spike owner retains these unresolved design and coordination actions under HYPERFLEET-1823. Recording them here does not close them. Implementation need not finish to close a spike, but an accepted design and explicit delivery/test ownership are required.

| Gate | Required resolution before closing HYPERFLEET-1823 |
| --- | --- |
| Remaining design decisions | Option 2, the API/Postgres metadata boundary, and its narrow authorization/v1 exceptions are recorded in ADR-0039. Settle the deletion-safety gates below and record the remaining cleanup/retention and 12-hour cadence decisions, including the ownership delay |
| Decommissioned-partition row cleanup | Discovery is decided; row cleanup is not. When a registration and its AuthConfig are removed, no Applier remains to confirm a new delete, and standalone reads are retained by this design. Decide who removes those rows and under which authorization and safety rule: an existing decommission mechanism, a sweeper partition-delete operation, or the cluster lifecycle/decommission flow. If no mechanism is selected, explicitly accept permanent retention of those rows and record the owner. Enumeration alone does not satisfy this gate |
| Confirmation after recreation | With API/store and Applier owners, select a mechanism and record its implementation/test ticket, or explicitly accept the documented leaked-object risk under the conditions above and track monotonic versions as a follow-up. PR #273 only documents the limit; this document does not yet record acceptance |
| Destructive supersede safety | With API/store and Adapter owners, settle the store-side atomic guard for the inspected apply, including same-version recreation, and enforce the A1 invariant across both intervals. The invariant excludes reassignment by a differently identified live source but leaves same-origin replacement applies and the separate source-absence check to be addressed. Record the implementation/test owner and ticket |
| Read cleanup after confirmed delete | With API/store and Adapter owners, define and test atomic read removal against the same confirmed delete and absence of a replacement apply, including an intervening `PreCheckFailed` status write. Retain the read when the guard fails. Assign implementation and test ownership |
| A1 target-identity invariant and Q1 | The inspected API and adapter configurations support A1: IDs are generated server-side UUID v7 values with no restore route, and inspected adapters derive target names or namespaces from that ID. Before enabling orphan remote deletion, publish the exclusive ownership and ID-derived naming rule in the Adapter authoring guide, add configuration/conformance tests for it, and audit adapters or PoC repositories that do not follow it. Record the owner and ticket for that work. If an adapter cannot follow the rule, specify and test coordination with in-flight Applier work. A1 does not close the separate same-version record/status races or exclude a delayed apply for the deleted origin. Enumeration can proceed independently |
| Architecture integration | ADR-0039, ADR-0022/0029, HLD, glossary, and SWP-6 through SWP-9 record partition enumeration. C3 tracks the remaining cleanup decisions. G2 tracks sweep testing and G15 tracks the API/Postgres integration of the merged store exemption |
| Ticket and specification integration | HYPERFLEET-1821 is closed, so the original “before OpenAPI finalization” criterion can no longer be met in sequence. Update HYPERFLEET-1823's AC5 to require the Detailed Design amendment and follow-up OpenAPI publication before implementing the new operation. Record follow-up IDs and scope acceptance for the metadata route, authorization, clients, provenance, and tests; narrow the one-partition wording in HYPERFLEET-1840 and affected API/gateway stories to desire-record operations. Link the accepted decision from HYPERFLEET-1840 to satisfy AC6 |

**Decommissioned-row evidence:** No existing row-cleanup mechanism was found. The operator reference records that deleting a registration does not yet revoke its AuthConfig and assigns AuthConfig rendering and removal to HYPERFLEET-1831; no management-cluster decommission flow is documented. The sweeper can enumerate these partitions but cannot confirm a new delete after their Applier is gone. Row removal therefore needs an owner in the decommission/registration lifecycle or an explicit retention decision; this PR does not add a partition-delete operation.

### Delivery and Test Tracking

Existing tickets below provide confirmed ownership only for their current scope. Entries marked **proposed extension** require owner agreement and a ticket update or a separate follow-up recorded under HYPERFLEET-1823; they are not claims that the new work is already assigned.

| Work | Delivery/test tracking and repository |
| --- | --- |
| Metadata wire contract | **New follow-up required**, tracked for assignment by HYPERFLEET-1823 in `hyperfleet-desire-store-spec`. Publish the accepted route, paging rules, authorization, and specific compatibility exception in a release after 0.2.2. HYPERFLEET-1821 is closed |
| Metadata handler and Postgres query | **New follow-up required** in `hyperfleet-desire-store`, with owner assignment tracked by HYPERFLEET-1823. [HYPERFLEET-1825](https://redhat.atlassian.net/browse/HYPERFLEET-1825) is closed with the five desire-record operations; [HYPERFLEET-1671](https://redhat.atlassian.net/browse/HYPERFLEET-1671) is in progress for listing within a selected partition through the existing store interface, not the separate fleet metadata query. Include service integration tests and agree any [HYPERFLEET-1865](https://redhat.atlassian.net/browse/HYPERFLEET-1865) CI scope extension |
| Metadata gateway/operator permission | **Proposed extension** to [HYPERFLEET-1831](https://redhat.atlassian.net/browse/HYPERFLEET-1831) AuthConfig rendering in `hyperfleet-operator` and [HYPERFLEET-1833](https://redhat.atlassian.net/browse/HYPERFLEET-1833) gateway isolation tests. Record the exact route rule, claim validation, negative tests, and owner acceptance before implementation |
| Store owner exemption | [HYPERFLEET-1937](https://redhat.atlassian.net/browse/HYPERFLEET-1937) merged `SweeperStore` and memory/Redis conformance in [Applier PR #86](https://github.com/openshift-hyperfleet/hyperfleet-applier/pull/86). HYPERFLEET-1671's Postgres backend must implement the same contract. The API must call it only for an authorized sweeper and cover that dispatch with service integration tests (G15) |
| Applier pre-check ordering | The Applier owner will check the freshly read `IsDeleted` condition before `setupResourceClient`. The follow-up ticket ID is not yet linked; record it here and add a regression test that removes the mapping after confirmation while preserving the terminal condition. Until it ships, treat an overwritten `PreCheckFailed` as unresolved |
| Provenance and source lookup | Open [Adapter PR #366](https://github.com/openshift-hyperfleet/hyperfleet-adapter/pull/366) for [HYPERFLEET-1837](https://redhat.atlassian.net/browse/HYPERFLEET-1837) writes the originating event ID as `OriginID` for each newly created desire. Track rollout of that change separately from the sweeper resolver tests for the UUID lookup, `Finalizing`, and system versus tenant-scoped 404s (G7, SWP-12) |
| Sweeper client and execution | [HYPERFLEET-1840](https://redhat.atlassian.net/browse/HYPERFLEET-1840) owns `hyperfleet-sweeper`, on-demand invocation, retained Adapter-delete cleanup, and the timeout-owner guard. Its metadata client, source-lookup client and system identity, shared scheduled/manual exclusion, durable scan progress, unresolved-work reporting, and the additional tests below are **proposed scope extensions** |
| Deployment and orphan E2E | [HYPERFLEET-1938](https://redhat.atlassian.net/browse/HYPERFLEET-1938) owns the sweeper chart, deployment wiring, and service-account allowlist integration with HYPERFLEET-1831. It must also wire the sweeper's HyperFleet API identity so the gateway classifies it as `hf_system=true`; a fleet-scoped Desire Store identity is insufficient. A dedicated orphan-journey E2E follow-up was requested in HYPERFLEET-1840's discussion, dependent on the sweeper and Adapter provenance; no accepted ticket ID was verified. HYPERFLEET-1823 must record that owner/ticket and update G2/SWP-4 before closure |

The deletion-safety decisions and the A1 invariant work remain separately tracked in the design table; they are not assigned to PR #273 or HYPERFLEET-1937 by inference. This PR records the enumeration decision and its architecture integration; it creates no Jira tickets or implementation artifacts for those follow-ups.

## Validation Obligations

The existing SWP-1 through SWP-5 and CAS-5 scenarios in the [Desire Store test plan](e2e-testing/desire-store-test-plan.md#sweeper-privileges) remain relevant. SWP-6 through SWP-9 now specify partition-enumeration and metadata-authorization tests for ADR-0039; their implementation/test ownership still requires assignment. C3 records that decision separately from unresolved cleanup safety. Extend the cleanup tests after their design gates are resolved. At minimum, tests must prove:

- A partition absent from registrations is still enumerated when any desire type remains; empty partitions disappear. Pagination is bounded, deduplicated, and handles concurrent additions/removals without treating failure as an empty store.
- Only the sweeper can list partition metadata. A metadata Wristband cannot read or mutate desires, and malformed or mixed scope claims fail before any data access.
- An existing/pending-deletion origin, failed lookup, missing provenance, or conflicting siblings causes no destructive action.
- Validate A1 against supported API recovery, Adapter naming, and ownership-handover paths before enabling orphan remote deletion. Interleave restoration or reassignment after the final absent lookup but before `CreateDeleteDesire`, with no replacement apply yet. The accepted contract must either reject that supported transition or prevent delete creation for the now-live source; a fresh lookup or store-only guard is insufficient. Also test reappearance after creation: the sweeper reports it and initiates no further cleanup for that target without claiming to cancel an in-flight Applier. If Q1 finds a supported counterexample, define and test coordination with in-flight Applier work before enabling this path.
- Only `Successful=True` / `Deleted` with matching generation on the current delete record can confirm completion. A status written for a previous incarnation must not confirm a recreated record. Accepted Kubernetes DELETE, finalizers, stale generation, or read-mirror lag do not substitute for confirmation.
- A failed resource pre-check after earlier confirmation, and a new delete for an unresolvable resource type, retain their records and report unresolved work. Do not fall back to remembered success or equate discovery failure with object absence.
- Confirmed Adapter-owned deletes stay while the origin exists and are eligible for removal after it is absent; a matching read is removed first only after the read-cleanup safety gate is resolved. Pending deletes survive an unavailable/revoked Applier.
- A crash between read and delete removal resumes safely. Timeout/conflict handling re-evaluates eligibility and obeys the existing owner guard.
- After the sweeper inspects a confirmed delete and unchanged read, try both a replacement apply and a status write that replaces confirmation with `PreCheckFailed` before read removal. In each case, the atomic check must retain the read and leave the sweeper to re-evaluate (SWP-10).
- A standalone read is retained without creating a remote delete. A lost desire is never treated as proof that Kubernetes deletion succeeded.
- A replacement apply inserted between orphan inspection and delete creation is not silently deleted; the chosen supersede-safety resolution must provide the test oracle before this path is enabled.
- Scheduled and on-demand runs cannot overlap. Force repeated scheduled deadlines and a restart midway through a metadata page. Later runs must reach every partition in a stable set, report deferred work and incomplete runs, and start from the first page on the next traversal. An on-demand test run must neither wait 12 hours nor advance the saved scheduled position (SWP-13).
- A different Adapter owner receives CNF-004 while a sweeper-owned delete remains, even when confirmed. Ownership becomes available only after eligible cleanup removes all conflicting records; an on-demand run reduces scheduling delay without bypassing safety checks.

These are tests to implement, not tests executed by this documentation change.

## Acceptance Criteria Mapping

| Ticket criterion | Status with this PR | Completion requirement |
| --- | --- | --- |
| Decide enumeration, including fully-decommissioned clusters | Decision recorded | [ADR-0039](../adrs/0039-sweeper-partition-enumeration.md) selects option 2, its metadata contract and authorization, and separates discovery from remote-deletion capability. This decision and its supporting documents are included for review and merge |
| Define deletion confirmation | Recommendation; safety decision open | [Deletion Confirmation](#deletion-confirmation) names condition, reason, and generation checks; resolve incarnation safety before relying on them for cleanup |
| Define which delete/read records are removed | Recommendation; safety decisions open | [Record Cleanup](#record-cleanup) proposes record ordering and retention; resolve destructive supersede and read-cleanup safety, and publish/enforce the target-identity invariant that A1 relies on |
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
