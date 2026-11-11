---
Status: Active
Owner: HyperFleet QE Team
Last Updated: 2026-11-10
---

# Desire Store Test Plan

## Table of Contents

- [Overview](#overview)
- [Test Layers](#test-layers)
- [Current and Required Capabilities](#current-and-required-capabilities)
- [Open Contract Decisions](#open-contract-decisions)
- [Scenario Matrix](#scenario-matrix)
- [Store Conformance over REST](#store-conformance-over-rest)
- [Deferred Coverage](#deferred-coverage)
- [Follow-ups](#follow-ups)

## Overview

This plan maps each behavior of the API-mediated Postgres Desire Store ([HYPERFLEET-1518]) to the test that proves it. For each behavior, it gives:

- the test layer, which sets the environment and the entry point;
- the proposed tier, for E2E layers only;
- the owning ticket;
- the mutation that turns the test red.

This is a coverage plan. It is not a commitment to implement every scenario in Sprint 19.

The design inputs are:

- [Desire Store Detailed Design](../desire-store-dd.md) (the DD): caller matrix, REST v1 contract, status codes, CAS, pagination, and failure behavior
- [Desire Store HLD](../desire-store-hld.md): system context
- [ADR-0022](../../adrs/0022-api-mediated-desire-store-access.md): API-mediated store access
- [ADR-0029](../../adrs/0029-desire-store-authorization.md): Desire Store authorization
- [Desires Lost Mid-Deletion spike](../spike-desires-lost-mid-deletion.md) ([HYPERFLEET-1841]): delete confirmation and the sweeper's role in record cleanup

Test placement follows the [Test Placement Strategy](test-placement-strategy.md): test at the lowest layer that can catch the failure mode. Tier definitions come from [`hyperfleet-e2e/test-design/README.md`](https://github.com/openshift-hyperfleet/hyperfleet-e2e/blob/main/test-design/README.md): Tier0 blocks release, Tier1 is advisory, and Tier2 is informational.

### How to Read This Plan

1. Find the behavior in the [Scenario Matrix](#scenario-matrix).
2. Use its Layer code in [Test Layers](#test-layers) to find the environment and the entry point.
3. Use its Owner to find the ticket that implements the test.
4. Use its Mutation as the falsifiability note: the test must fail when this change is made.
5. If the row names a `C` ID, the expected result depends on an [open contract decision](#open-contract-decisions).
6. If the row names an `F` ID, no current ticket covers it. See [Follow-ups](#follow-ups).

A ticket is an owner only when its text states the coverage. If no ticket states it, the row names a follow-up.

When a contract decision is made, update the rows that name its ID. When an owning ticket changes scope, update the rows that name it.

## Test Layers

The Category column maps each layer to a category of the coverage matrix. Unit and Deployment validation are not among the seven categories, so they have their own rows.

| Layer | Category | Environment | Entry point | Gates merge |
| --- | --- | --- | --- | --- |
| UNIT | Unit tests (clients and service) | Unit presubmit in each repository | `make test`; the service repository gets it from [HYPERFLEET-1824] | Yes, per repository policy |
| BACK | Backend conformance | testcontainers Postgres | Service integration presubmit. [HYPERFLEET-1671] defines the target; it is not named yet | Yes, when it is a required check |
| HTTP | Service integration | Nested podman, ephemeral Postgres, no gateway, test-signed Wristbands (F7) | Canonical command from [HYPERFLEET-1865] | Yes, when it is a required check |
| CLNT | Client tests | Same presubmit as HTTP: service binary, Postgres, test-signed Wristbands (F7) | Make target from [HYPERFLEET-1893] | Yes, its acceptance criteria make it a required check |
| DEP | Deployment validation | Chart render, then the `hyperfleet-infra` `validate` and `integration` jobs | `make ci-dry-run`. [HYPERFLEET-1862] defines the setup entry point; it is not named yet | `validate` only; `integration` is `optional: true` |
| GW | Gateway and component | kind with the mock issuer (`OIDC_ISSUER_MODE=mock`) | A `hyperfleet-infra` script target. [HYPERFLEET-1829] and [HYPERFLEET-1863] define it; it is not named yet | No, `make check-gateway-e2e` does not run in Prow |
| KIND | E2E | Postgres-only kind environment | `hyperfleet-e2e test --label-filter='(tier0 \|\| tier1) && remote-transport'`; [HYPERFLEET-1864] adds the `remote-transport` label | No, local run |
| NIGHT | E2E | GKE cluster `hyperfleet-dev-prow`, after [HYPERFLEET-1870] moves it to the Desire Store API | Prow `tier0-nightly` and `tier1-nightly` | No; a Tier0 failure blocks release |
| DIS | Disruptive recovery | Same as NIGHT, `Serial`, `disruptive` label. A ticket can accept a Postgres-only kind run instead. That run must also select Tier2, which the KIND entry point does not | Prow `tier2-nightly` | No, informational |
| MAN | Performance and spikes | One per scenario. See [Manual Scenarios](#manual-scenarios) | Manual run, with the evidence recorded on the ticket | No |
| PERF | Performance | GKE | Prow `perf-nightly` | No |

The CLNT row runs a client against the real service binary. Client behavior that does not need the service binary stays in UNIT, per the placement rule.

## Current and Required Capabilities

"Current" means the capability exists on `main` today. "Required" means a ticket must deliver it before the rows that use it can run.

| Capability | State | Evidence or owner |
| --- | --- | --- |
| Store Conformance Suite | Current, in process only | `hyperfleet-applier` `pkg/desire/store/conformance/suite.go`; the memory and Redis backends run it in their unit tests |
| Nested-podman integration job | Current in `hyperfleet-api` only | The `hyperfleet-api` `integration` presubmit runs `make test-integration`. The `hyperfleet-applier` `integration` job runs `make test-envtest` and has no container runtime |
| Mock issuer and gateway suite | Current for the general API gateway, kind only | `hyperfleet-infra` `make check-gateway-e2e` with `OIDC_ISSUER_MODE=mock` |
| Tier and perf nightlies | Current, Redis desire store | `tier0-nightly`, `tier1-nightly`, `tier2-nightly`, and `perf-nightly` in the `openshift/release` `hyperfleet-e2e` configuration |
| Mock human tokens | Current | `hyperfleet-e2e` `pkg/identity` ([HYPERFLEET-1843]) |
| Desire Store service repository and CI | Required | [HYPERFLEET-1824], [HYPERFLEET-1865] |
| Test-signed Wristbands | Required. [HYPERFLEET-1865] states the coverage, but no ticket names the test signer | [HYPERFLEET-1865], F7 |
| HTTP conformance harness | Required | [HYPERFLEET-1893] |
| Postgres-Only Environment | Required | [HYPERFLEET-1862] |
| Desire Store API and gateway in the nightly environment | Required. The nightlies use the Redis desire store today. Every NIGHT row needs this, and so does every DIS row that runs on the nightly. [HYPERFLEET-1771] accepts DIS-1 on the Postgres-only kind run | [HYPERFLEET-1870] |
| Second gateway install | Required | [HYPERFLEET-1863], [HYPERFLEET-1829] |
| E2E gateway configuration, fixtures, and the `desire` and `remote-transport` labels | Required. The labels are not in `hyperfleet-e2e` `pkg/labels/labels.go` | [HYPERFLEET-1864] |
| Per-partition hostnames (wildcard DNS) and their certificate in test environments | Required, owner `[unverified]` | [HYPERFLEET-1829] allows a temporary certificate. No ticket names the owner of the test DNS records; [HYPERFLEET-1862] and [HYPERFLEET-1864] are the candidates |
| Signing-key rotation trigger in test environments | Required. The operator owns the signing-key Secrets and reverts a manual edit ([HYPERFLEET-1831]). [HYPERFLEET-1756] puts the rotation trigger out of scope | F15 |
| `resource_id` on Adapter desires | Required. The sweeper finds orphans by `resource_id`, and the Adapter does not set it today ([HYPERFLEET-1905]) | F13 |
| On-demand sweeper run in test environments | Required. The planned sweeper cadence is about 12 hours ([HYPERFLEET-1840]), which is too long for a nightly spec | F5 |

## Open Contract Decisions

These decisions are not in the DD on `main`. Rows that depend on a decision name its ID. Until the decision is made, the row records the scenario but not the expected result.

| ID | Decision | Settled by | Rows affected |
| --- | --- | --- | --- |
| C1 | Read-after-timeout rule for delete | [HYPERFLEET-1871]; proposal in [architecture PR #267](https://github.com/openshift-hyperfleet/architecture/pull/267) | CAS-5, SWP-2 |
| C2 | The API binds the submitted owner to the caller identity, or derives the owner from it. It also sets the error code for an owner collision. The DD on `main` has no separate code: it lists an owner collision under 409 with version mismatch, and the [Error Model](../../standards/error-model.md) has no owner-conflict code. PR #267 proposes `HYPERFLEET-CNF-004` | [HYPERFLEET-1871]; proposal in [architecture PR #267](https://github.com/openshift-hyperfleet/architecture/pull/267) | OWN-1, OWN-2, SWP-2 |
| C3 | Sweeper partition enumeration, deletion confirmation, and record cleanup. A partition-listing route can amend REST v1 | [HYPERFLEET-1823] | SWP-4 |
| C4 | Version behavior of Apply and Delete status writes. See [C4, C5, C9, and C10 detail](#c4-c5-c9-and-c10-detail) | [HYPERFLEET-1923] | CAS-3 |
| C5 | `generation` on the wire. See [C4, C5, C9, and C10 detail](#c4-c5-c9-and-c10-detail) | [HYPERFLEET-1923] | CAS-3 |
| C6 | Authorino issuer enforcement, denial on CEL evaluation errors, and revocation timing | [HYPERFLEET-1822] | ISO-2, REV-1, REV-2, REV-4, REV-5 |
| C7 | Private connectivity and TLS trust for management clusters | [HYPERFLEET-1866] | DEP-5 |
| C8 | `limit` above the maximum: clamp it or return 400 | [HYPERFLEET-1821] | PAG-1 |
| C9 | Rules across desire types for one object: an apply while a delete is pending, a delete that supersedes an apply, recreation after a confirmed delete, and one owner across types. Includes their status codes. See [C4, C5, C9, and C10 detail](#c4-c5-c9-and-c10-detail) | [HYPERFLEET-1871] (proposal in [architecture PR #267](https://github.com/openshift-hyperfleet/architecture/pull/267)) for all but the supersede rule; [HYPERFLEET-1923] for the supersede rule | CAS-8 |
| C10 | The ReadDesire target version on the wire. See [C4, C5, C9, and C10 detail](#c4-c5-c9-and-c10-detail) | [HYPERFLEET-1923] | CAS-7 |

C4, C5, C9, and C10 also decide the conformance cases in [Store Conformance over REST](#store-conformance-over-rest).

### C4, C5, C9, and C10 Detail

The DD and the current code disagree, or the DD is silent. The affected rows cannot have an expected result until the decision is made. File references are to `hyperfleet-applier` commit `f15f3f8`.

- **C4, status version:**
  - The DD says that status writes "do not require or change the desired-state version" and that this preserves [HYPERFLEET-1511] ([CAS / Version Semantics](../desire-store-dd.md#cas--version-semantics)).
  - [HYPERFLEET-1511] removed CAS from ReadDesire status writes only. It kept CAS on Apply and Delete status writes.
  - The store interface requires an exact version on these writes (`pkg/desire/store.go:146`). The Applier sends it (`internal/controllers/applydesire/controller.go:137`).
  - The DD rule removes stale-status rejection, which the Store Conformance Suite asserts (`StaleStatusWriteAfterSpecUpdateIsRejected`).
- **C5, generation:**
  - The DD wire schemas do not include `generation`.
  - The Applier stamps `ObservedGeneration` in the status it writes (`internal/controllers/applydesire/status.go`).
  - Many Store Conformance Suite cases assert generation. See [Store Conformance over REST](#store-conformance-over-rest).
- **C9, rules across desire types:**
  - The store rejects an apply while a delete is pending with `ErrDeletePending` (`pkg/desire/store.go:28`). The DD on `main` has no status code or REST rule for it.
  - The Store Conformance Suite asserts that a delete supersedes an apply, that a confirmed delete lets a new apply recreate the object, and that all desire types for one object share one owner. The DD on `main` states none of these rules.
  - [architecture PR #267](https://github.com/openshift-hyperfleet/architecture/pull/267) proposes `HYPERFLEET-CNF-003` for an apply while a delete is pending, recreation after a confirmed delete, and one owner for all desires of one object. It does not state the supersede rule.
  - The [Desires Lost Mid-Deletion spike](../spike-desires-lost-mid-deletion.md) requires `ConfirmedDeleteThenApplyRecreates` to pass.
- **C10, ReadDesire target version:**
  - A ReadDesire requires `TargetVersion` (`pkg/desire/types.go:137`, checked in `pkg/desire/validate.go:136`).
  - The Adapter sets it when it creates a ReadDesire (`hyperfleet-adapter` `internal/desireclient/apply.go:241` at `0806e99`).
  - The DD write body carries `owner`, `resource_id`, `kubeContent`, and `version` only ([Wire Schemas](../desire-store-dd.md#wire-schemas)). No field carries the target version.

## Scenario Matrix

The Layer column gives the environment and the entry point (see [Test Layers](#test-layers)). The Tier column applies to E2E layers only. The Mutation column is the falsifiability note. `n/a` marks a measurement, which has no pass or fail result to falsify.

| Category | Area |
| --- | --- |
| ISO | Partition and caller isolation |
| OWN | Authenticated ownership |
| CAS | CAS and ambiguous outcomes |
| PAG | Pagination failures |
| ERR | Non-retryable errors |
| DIS | Disruptive recovery |
| REV | Revocation |
| KEY | Signing-key rotation |
| SWP | Sweeper privileges |
| DEP | Deployment |
| E2E | End-to-end journeys |
| PRF | Performance |

| ID | Behavior | Layer | Tier | Owner | Mutation that turns it red |
| --- | --- | --- | --- | --- | --- |
| ISO-1 | A remote Applier reaches only its bound partition. The gateway denies a path partition mismatch before the request reaches the API | NIGHT | Tier0 | [HYPERFLEET-1833]; prerequisite [HYPERFLEET-1864] | Remove the path-partition predicate from the binding AuthConfig. The API then makes the denial, and the test sees an Error Model body |
| ISO-2 | Cross-caller authentication fails closed in both directions: the gateway returns 401 at authentication (C6) | NIGHT | Tier0 | [HYPERFLEET-1833] | Add the mock issuer to the fleet-scoped AuthConfig. Authorization then denies with 403, not 401 |
| ISO-3 | The API authorizes the partition from the Wristband claim. Forged headers grant no access | HTTP | | [HYPERFLEET-1865], [HYPERFLEET-1825] | Read the partition from the path, not the claim |
| ISO-4 | The gateway strips client identity, caller-class, and partition headers. It replaces a client-supplied `x-wristband` with the Wristband that Authorino issues. An echo upstream or the Envoy access log shows the forged values are gone | GW | | [HYPERFLEET-1829] | Remove the header-strip filter |
| ISO-5 | A pod that is not the gateway cannot open a TCP connection to the Desire Store API. The probe expects a timed-out connection, as `run_network_policy_probe` does, not an HTTP status, because the API also rejects a request without a Wristband | GW | | [HYPERFLEET-1829] | Remove the API ingress NetworkPolicy |
| ISO-6 | AuthConfig shards do not cross between gateways | DEP | | [HYPERFLEET-1863] | Remove the shard label selector |
| ISO-7 | Duplicate issuers, overlapping signing keys, and duplicate partitions are rejected | UNIT | | [HYPERFLEET-1832] | Skip the uniqueness check |
| ISO-8 | Startup fails when the partition enforcement configuration is missing | UNIT | | [HYPERFLEET-1825] | Set enforcement to off by default |
| ISO-9 | Only the Desire Store API receives the `desire_store` database credentials | DEP | | [HYPERFLEET-1825] | Mount the credentials Secret in a second workload |
| ISO-10 | Only the Desire Store roles have `CONNECT` on the `desire_store` database. The other services on the shared instance cannot connect to it. The DD wording needs F14 | MAN | | [HYPERFLEET-1828] | Grant `CONNECT` on `desire_store` to the API role |
| ISO-11 | A binding is replaced when its identity or partition changes | UNIT | | [HYPERFLEET-1831] | Keep the old binding when the partition changes |
| ISO-12 | A partial match of issuer, audience, and subject is denied | NIGHT | Tier1 | F2 | Remove the audience check from the binding AuthConfig |
| OWN-1 | The stored owner is the authenticated caller, not a value that the client chooses (C2) | HTTP | | F7 | Store the owner from the request body |
| OWN-2 | An owner collision has its own error code, which differs from a version conflict, and is not retried (C2) | UNIT, CLNT | | [HYPERFLEET-1837], [HYPERFLEET-1893] | Send an owner collision to the conflict-retry path |
| OWN-3 | Write split: only the Applier writes status, and the Adapter cannot write status | HTTP | | [HYPERFLEET-1865] | Remove the caller-class check from the status route |
| CAS-1 | The Store Conformance Suite passes against Postgres: CAS, listing, status, prefix delete, and the rules across desire types | BACK | | [HYPERFLEET-1671] | Skip the version predicate in the update |
| CAS-2 | Version conflict, create on an existing desire, and 404 on a status write to a missing desire | HTTP | | [HYPERFLEET-1865] | Upsert on a status write |
| CAS-3 | Status-write version and generation behavior (C4, C5) | HTTP, CLNT | | [HYPERFLEET-1923], then [HYPERFLEET-1865] | Pending [HYPERFLEET-1923] |
| CAS-4 | After a timed-out write, the client reads the desire before it retries | UNIT | | [HYPERFLEET-1837] | Retry without the read |
| CAS-5 | Timed-out delete: the desire is absent, at the same version, or at a new version (C1) | UNIT | | [HYPERFLEET-1837], [HYPERFLEET-1840] | Retry when the desire is present at a new version |
| CAS-6 | Envoy retries only before the request is sent upstream | GW | | [HYPERFLEET-1829] | Add `5xx` to the retry policy |
| CAS-7 | Client CAS and ownership behavior holds over HTTP (C10) | CLNT | | [HYPERFLEET-1893] | Drop `version` from update requests in the client |
| CAS-8 | The rules across desire types hold over HTTP (C9) | HTTP, CLNT | | [HYPERFLEET-1923], then [HYPERFLEET-1893] | Pending [HYPERFLEET-1923] |
| PAG-1 | Keyset pagination, no total count, invalid cursor rejected, and the `limit` rule (C8) | HTTP | | [HYPERFLEET-1865] | Use `>=` in the cursor predicate |
| PAG-2 | A failed page keeps the last complete view. An incomplete list is never treated as empty | UNIT | | [HYPERFLEET-1838] | Replace the view before the final page |
| PAG-3 | After a restart, the Applier waits for a successful read before it reconciles | UNIT | | [HYPERFLEET-1838] | Reconcile from an empty view |
| PAG-4 | Lists carry references only. The Applier applies from the GET response | UNIT | | [HYPERFLEET-1839] | Decode the manifest from the list response |
| ERR-1 | The Adapter client surfaces non-retryable errors and does not retry them | UNIT | | [HYPERFLEET-1837] | Retry on 403 |
| ERR-2 | The Applier client surfaces non-retryable errors and retries temporary failures with capped backoff and jitter | UNIT | | [HYPERFLEET-1838] | Retry on 401 |
| ERR-3 | A degraded API returns 503 with an [Error Model](../../standards/error-model.md) body | UNIT | | [HYPERFLEET-1825] | Map a store failure to 500 |
| ERR-4 | The Adapter and Applier clients wait for `Retry-After` before they retry a 429 | UNIT | | [HYPERFLEET-1837], [HYPERFLEET-1838] | Ignore `Retry-After` |
| ERR-5 | The gateway returns 429 to a caller over its rate limit, with `Retry-After` and the rate-limit problem type | GW | | [HYPERFLEET-1829] for the limit; F8 for `Retry-After` and the problem type | Remove the post-auth rate-limit filter |
| ERR-6 | A bad identifier encoding returns 400, and a name that contains colons decodes correctly. kubeContent that does not match the path returns 422 | HTTP | | F7 | Split the identifier at every colon |
| ERR-7 | A lost Postgres connection behind a live API returns 503 with an Error Model body, and the request does not hang. The API serves again when Postgres returns. The test stops the Postgres container during the suite | HTTP | | F16 | Map a driver connection error to 500 |
| DIS-1 | The Desire Store API is unavailable: the Adapter reports the failure, and recovery reconciles. [HYPERFLEET-1771] accepts the spec on the Postgres-only kind run. The nightly runs it after [HYPERFLEET-1870] | DIS | Tier2 | [HYPERFLEET-1771] | Report `Applied=True` on a store error |
| DIS-3 | Store loss during a delete does not leave the remote object behind | DIS | Tier2 | [HYPERFLEET-1771], after [HYPERFLEET-1905] | Mark the resource deleted when discovery returns NotFound |
| DIS-4 | Authorino is unavailable: the gateway denies every request. The response has no Error Model body, and the request does not reach the API | DIS | Tier2 | [HYPERFLEET-1924] | Make external authorization fail open with no other guard for a missing Wristband, for example `failure_mode_allow: true` on the Envoy `ext_authz` filter. The API then answers 401 with an Error Model body |
| DIS-5 | The confirmed `DeleteDesire` is lost after one Adapter reports `Finalized=True` and before the API hard-deletes the record. The next event sets `Finalized` to False, the Adapter recreates the `DeleteDesire`, and it reports `Finalized=True` again. A parent is not orphaned | UNIT | | F11 | Keep `Finalized=True` when the confirmed `DeleteDesire` is missing |
| REV-1 | Deleting the registration denies the Applier within 60 seconds on a healthy control plane (C6). The test polls to that bound plus a margin that the spec states | NIGHT | Tier1 | [HYPERFLEET-1833] | Keep the AuthConfig after the record is deleted |
| REV-2 | Stale policy under a stalled watch is measured (C6) | MAN | | [HYPERFLEET-1822] | n/a |
| REV-3 | An unreachable issuer fails only that issuer | NIGHT | Tier1 | [HYPERFLEET-1833] | Point two bindings at one issuer |
| REV-4 | A token with a lifetime over one hour, or with missing age claims, is denied (C6) | NIGHT | Tier1 | F2; evidence from [HYPERFLEET-1822] | Remove the age predicate |
| REV-5 | Malformed paths fail closed (C6) | UNIT | | [HYPERFLEET-1831]; evidence from [HYPERFLEET-1822] | Extract the partition by segment index |
| KEY-1 | A missing Wristband returns 401; a missing Authorization header alone does not. An unknown key, a bad signature, an expired Wristband, or inconsistent claims are rejected before data access | UNIT, HTTP | | [HYPERFLEET-1825], [HYPERFLEET-1865] | Skip the `kid` lookup |
| KEY-2 | When key refresh fails, the API accepts only keys that it already trusts | UNIT | | [HYPERFLEET-1825] | Accept the Wristband when refresh fails |
| KEY-3 | Rotation adds the new key first and keeps the previous key | UNIT | | [HYPERFLEET-1831] | Remove the previous key at rotation |
| KEY-4 | Live key rotation causes no 401 through the gateway. The spec is `Serial`, because rotation affects every concurrent spec. Needs a rotation trigger (F15) | NIGHT | Tier1 | [HYPERFLEET-1925] | Put the new key first in `signingKeyRefs` while the API still holds only the old key set |
| SWP-1 | The sweeper can write `DeleteDesire` records only. Its other writes return 403 | HTTP | | F5, then [HYPERFLEET-1865] | Authorize by caller class, not by `hf_identity` |
| SWP-2 | The sweeper is exempt from owner collision and writes its own identity as owner (C1, C2) | UNIT, HTTP | | [HYPERFLEET-1840], F5 | Apply the owner check to the sweeper |
| SWP-3 | The allowlist admits the sweeper and denies a service account that is not on the list. Needs the sweeper service account from [HYPERFLEET-1840] | UNIT, NIGHT | Tier1 | [HYPERFLEET-1831], F2 | Allow any service account that has the audience |
| SWP-4 | Orphan journey: the `resource_id` target is missing, the sweeper writes a `DeleteDesire`, the Applier confirms, and the sweeper removes the record (C3). Needs an on-demand sweeper run and `resource_id` on Adapter desires (F13) | NIGHT | Tier1 | F5 | Skip the record removal |
| SWP-5 | The sweeper removes the confirmed `DeleteDesire` records that adapters keep after a delete. [HYPERFLEET-1905] needs this before it ships. Needs `resource_id` on Adapter desires (F13) | UNIT | | [HYPERFLEET-1905] states it for [HYPERFLEET-1840] | Skip records that the sweeper does not own |
| DEP-1 | The Postgres-only render passes with no Redis. Shared environments keep their Redis checks | DEP | | [HYPERFLEET-1862] | Restore the `redis` dependency |
| DEP-2 | Setup and teardown work, including teardown after a partial setup failure | DEP | | [HYPERFLEET-1862] | Skip teardown of a created resource |
| DEP-3 | Migrations run under the migration role and the service runs under the runtime role; deployment wiring is correct | HTTP, MAN | | [HYPERFLEET-1865], [HYPERFLEET-1828] | Run migrations with the runtime role |
| DEP-4 | A weaker `sslmode` or a missing CA bundle fails at startup | UNIT | | [HYPERFLEET-1903] | Accept `require` as a valid `sslmode` |
| DEP-5 | Private connectivity and CA trust from management clusters (C7) | MAN | | [HYPERFLEET-1866] | n/a |
| E2E-1 | Tier0 remote-transport specs pass on Postgres-only kind | KIND | Tier0 | [HYPERFLEET-1862], [HYPERFLEET-1671] | Scale the Desire Store API to 0 replicas |
| E2E-2 | Tier0 and Tier1 pass on GKE after the cutover | NIGHT | Tier0, Tier1 | [HYPERFLEET-1870] | Delete the Applier binding AuthConfig |
| E2E-3 | Gateway smoke test with verified TLS | KIND | Tier1 | [HYPERFLEET-1864] | Use a wrong CA |
| PRF-1 | Gateway and API capacity at 10,000 partitions, one poll per partition every 5 seconds, and 10 desires per partition | MAN | | [HYPERFLEET-1842] | n/a |
| PRF-2 | Shared-instance contention | MAN | | [HYPERFLEET-1672] | n/a |
| PRF-3 | Perf thresholds re-derived after the cutover | PERF | | [HYPERFLEET-1894] | n/a |

### Manual Scenarios

Each MAN scenario names its environment here. Where the owning ticket names none, the cell says so.

| Scenario | Environment | Source |
| --- | --- | --- |
| ISO-10, DEP-3 (deployment wiring) | A deployed Desire Store API whose `desire_store` database is on a shared Postgres instance. The ticket names no cluster | [HYPERFLEET-1828] requires "a deployed verification run"; [ADR-0026](../../adrs/0026-co-located-service-databases-shared-postgres-isolation.md) |
| REV-2 | A deployed gateway with Authorino. The ticket names no cluster | [HYPERFLEET-1822] measures the stalled watch on "the deployed Authorino" |
| DEP-5 | None required. The spike accepts a paper assessment when no live topology exists | [HYPERFLEET-1866] |
| PRF-1 | Open. The ticket sets the workload but names no environment. [HYPERFLEET-1842] must name one | [HYPERFLEET-1842] |
| PRF-2 | A harness on kind or a dev instance | [HYPERFLEET-1672] |

### Tier Choices

- **ISO-1 and ISO-2 are Tier0.** Per-cluster isolation is a fundamental platform contract, which is the Tier0 "Platform guarantee" criterion. It is also an acceptance criterion of [HYPERFLEET-1518]. The existing gateway authentication specs are Tier0 too (`hyperfleet-e2e` `e2e/auth/jwt_enforcement.go`, `e2e/auth/multi_issuer.go`).
- **Other identity rows are Tier1.** They cover error handling and secondary paths, which the tier definitions put in Tier1.
- **REV-3 is Tier1, not Tier2.** It makes only a test-owned mock issuer unreachable. It does not touch shared infrastructure and its result does not depend on timing. It proves that one issuer failure does not spread to other partitions.
- **DIS rows are Tier2.** They inject infrastructure failures, which the tier definitions put in Tier2.

### Gateway Checks: Black-Box and Deployment-Internal

- Black-box checks (status codes and denials seen by a caller) go in `hyperfleet-e2e`: the NIGHT and KIND rows.
- Checks that read deployment internals go in `hyperfleet-infra`: the GW rows. Examples are Envoy logs, an echo upstream, and NetworkPolicy bypass probes, such as `run_network_policy_probe` in `scripts/check-gateway-e2e.sh`.
- The API also enforces partition and caller rules, so a black-box check must show which component denied the request. An API denial has an Error Model body (`application/problem+json`). ISO-1 and ISO-2 assert that the gateway made the denial.

## Store Conformance over REST

[HYPERFLEET-1893] runs the Store Conformance Suite through a client over HTTP. It allows a case that cannot hold over HTTP when the case is recorded with a reason and a follow-up. This table records those cases.

Line numbers refer to [`pkg/desire/store/conformance/suite.go`](https://github.com/openshift-hyperfleet/hyperfleet-applier/blob/f15f3f8630e15fc6f446edc535ccef6f370907e2/pkg/desire/store/conformance/suite.go) at `hyperfleet-applier` commit `f15f3f8`.

| Cases | Why they do not hold unchanged over REST | Disposition |
| --- | --- | --- |
| `DeleteStaleVersionRejected` (:562, :636, and the ApplyDesire case that [HYPERFLEET-1920] adds) | DELETE has no version precondition in the DD | Depends on C1 |
| `DeleteForeignOwnerRejected` (:577, :651, and the ApplyDesire case that [HYPERFLEET-1920] adds) | DELETE has no owner input | Depends on C2 |
| `DeleteByPrefix` (:1025) | No REST v1 route is a prefix delete ([REST API (v1)](../desire-store-dd.md#rest-api-v1)). No non-test caller in the Adapter or the Applier uses it | Backend only (CAS-1) |
| `ManagementClusterListing` (:667) | Lists carry references only, with no generation | Depends on C5 |
| `UpdateStatusSuccessIncrementsVersion` (:1166, :1335), `StaleStatusWriteAfterSpecUpdateIsRejected` (:1195), `StaleVersionRejected` (:1399) | Status requests carry only `status` ([Wire Schemas](../desire-store-dd.md#wire-schemas)). The first two also assert generation | Depends on C4; the first two also on C5 |
| `UpdateStatusReturnedValueIsIsolatedFromCallerMutation` (:1244, :1371, :1546) | A status write returns no body ([Wire Schemas](../desire-store-dd.md#wire-schemas)) | Client-side only |
| `KubeContentMirror` (:1579), `StatusWriteDoesNotChangeSpec` (:1298), `UpdateStatusSucceedsWithoutVersionCheck` (:1444), `RecreateAfterDeleteClearsStatus` (:197), `OnlyChangedSpecAdvancesGeneration` (:273), `UpdateSpecPreservesStatus` (:364) | They read the desire that the status write returns: `updated.Status.KubeContent` (:1601), `afterStatus.Spec.KubeContent` (:1316) and `afterStatus.Generation` (:1319), `updated.Generation` (:1460), and `withStatus.Version` (:221, :298, :406). A status write returns no body ([Wire Schemas](../desire-store-dd.md#wire-schemas)), so these fail even when `generation` is on the wire | The test harness reads the desire after the write and returns it, or F6 changes the suite. The read is not atomic with the write, so it stays in the harness and not in the production status client. Cases that read `Generation` also depend on C5, and cases that read `Version` also depend on C4 |
| `OnlyChangedSpecAdvancesGeneration` (:273), `CreateGetRoundTrip` (:84, :520, :594), `UpdateSpecRejectsEmptyKubeContent` (:176), `RecreateAfterDeleteClearsStatus` (:197), `UpdateSpecSuccessIncrementsVersion` (:247), `UpdateSpecPreservesStatus` (:364), `DifferentOwnerRejected` (:478), `StatusWriteDoesNotChangeSpec` (:1298), `UpdateStatusSucceedsWithoutVersionCheck` (:1444) | They assert `Generation`, which is not on the wire | Depends on C5. `OnlyChangedSpecAdvancesGeneration` also asserts a stale status write is rejected (C4) and that a foreign-owner update returns `ErrOwnerConflict` (:351), so it also depends on C4 and C2 |
| `ApplyThenDeleteSupersedes` (:757), `DeleteThenApplyRejected` (:783), `ConfirmedDeleteThenApplyRecreates` (:799) | The DD has no rule or status code for these cases. The spike requires `ConfirmedDeleteThenApplyRecreates` to pass | Depends on C9 |
| `CrossTypeOwnership` (:899) | The DD does not say that one owner covers all desire types for one object | Depends on C9 and C2 |
| Every case that writes an ApplyDesire | The fixtures carry `kubeContent` with no Kubernetes identity: the constants such as `{"v":1}` (:20) and inline values such as `{}` and `{"kind":"ConfigMap"}`. The API returns 422 when `kubeContent` does not match the path ([Status Codes](../desire-store-dd.md#status-codes)) | Needs a suite change for every ApplyDesire fixture, so that each manifest matches its identity. `identity()` sets group `apps` with resource `configmaps` (:26) (F6) |
| Every case that writes a desire | The suite never sets `OriginID`, and the DD write body carries `resource_id` ([Wire Schemas](../desire-store-dd.md#wire-schemas)) | If the API requires `resource_id`, the harness or the suite must supply it (F6) |
| Every case that writes a ReadDesire | The write body has no field for `TargetVersion` | Depends on C10 |

The suite cannot run unchanged through one HTTP client. The harness needs these:

- **One store that combines callers, for both suites.** The spec suite also writes status: it asserts that its store implements `desire.StatusStore` (:199, :281, :388, :801, :976). The status suite also creates desires: it asserts that its store implements `desire.SpecStore` (`seedSpecStore`, :70). The DD allows only the Adapter to write desired state and only the Applier to write status ([Caller-to-Operation Matrix](../desire-store-dd.md#caller-to-operation-matrix)). So the store sends desired-state writes through the [HYPERFLEET-1837] HTTP store with Adapter credentials, and status writes through the [HYPERFLEET-1838] client with Applier credentials.
- **Two Adapter identities.** The owner-conflict cases switch from `owner-a` to `owner-b` in one store (:134, :488, :585). Over REST the owner comes from the authenticated caller (C2), so the harness routes each owner's calls through that owner's credentials.
- **An importable HTTP store.** The harness lives in the service repository, so the [HYPERFLEET-1837] store cannot sit under an Adapter `internal/` package. The Adapter's `internal/desireclient.Client` only wraps a `desire.SpecStore`, so the suite cannot use it as its store.
- **A fresh store per case.** Each case calls `newStore(t)` and expects an empty store. The memory and Redis tests start a new store each time (`redis_test.go` `newMiniStore`). The cases reuse the partition name `cluster-a`, so the harness must empty the database on each `newStore(t)` call.
- **A status write that returns the desire.** The suite reads the returned desire after a status write. The API returns 204 with no body, so the harness reads the desire after each status write and returns it. This read is not atomic with the write: another caller can change or delete the desire between the two. It is safe in the suite, because each case has one caller at a time. The production status client does not need it, and it must not report a failed write when only the read fails. See the status-write rows in the table above.
- **Valid fixtures.** See the ApplyDesire and `resource_id` rows in the table above.

F6 records these scope changes for [HYPERFLEET-1893].

## Deferred Coverage

| Coverage | Rationale | Owner |
| --- | --- | --- |
| Recurring stalled-watch test | The DD treats a stalled watch as an infrastructure failure, not a bound that the gateway enforces ([Token Lifetime and Revocation Behavior](../desire-store-dd.md#token-lifetime-and-revocation-behavior)). REV-2 measures it once | [HYPERFLEET-1822] |
| CI for GW rows | The gateway suite runs only locally on kind. Until a Prow job runs it, GW coverage does not gate merges, which the [Coverage Durability](test-placement-strategy.md#coverage-durability) rule requires | [HYPERFLEET-1829] |
| Partner-provided Postgres instance contract | A separate operator contract | [HYPERFLEET-1710] |
| Shared-instance contention (PRF-2) | Outside the MVP gate in the [HYPERFLEET-1861] seed matrix. The [HYPERFLEET-1518] Risks and the [API on Postgres spike](../desire-store-api-postgres-spike.md) make shared capacity depend on this benchmark. These two sources conflict, so this deferral is provisional until [HYPERFLEET-1518] settles the conflict | [HYPERFLEET-1672] |
| Tier2 spec for a Postgres outage behind a live API | ERR-7 tests a lost Postgres connection in the HTTP layer, with the real driver. ERR-3 uses a fake store, so it does not. DIS-1 stops the API, not the database ([HYPERFLEET-1771]). A Tier2 spec that stops Postgres in a shared environment would also stop the other databases on the instance ([ADR-0026](../../adrs/0026-co-located-service-databases-shared-postgres-isolation.md)) | F16 |
| Store loss during a delete (DIS-3) | Waits for [HYPERFLEET-1905], which waits for [HYPERFLEET-1840] and [HYPERFLEET-1823] | [HYPERFLEET-1771] |

## Follow-ups

Each follow-up covers a scenario that no current ticket states. The Raised on column says where the follow-up stands. A follow-up that is not raised, or has no owner, is open: no ticket tracks it. When the owner adds the case to the ticket text, replace the F ID with the ticket key.

| ID | Action | Why no current ticket covers it | Raised on |
| --- | --- | --- | --- |
| F2 | Add these cases to [HYPERFLEET-1833]: a token lifetime over one hour or missing age claims, a partial issuer, audience, and subject match, a service account that is not on the allowlist, and the sweeper allowlist | Its acceptance criteria name none of these cases | Comment on [HYPERFLEET-1833] |
| F5 | Add sweeper authorization cases to [HYPERFLEET-1865]. Add to [HYPERFLEET-1840], or to a new spec: the orphan journey and an on-demand sweeper run for test environments | [HYPERFLEET-1840] has no test criterion, and [HYPERFLEET-1823] decides its cadence of about 12 hours. [HYPERFLEET-1865] names no sweeper case | Comments on [HYPERFLEET-1865] and [HYPERFLEET-1840] |
| F6 | Amend [HYPERFLEET-1893]: build the combined store with two Adapter identities and one Applier identity, empty the database for each case, make the [HYPERFLEET-1837] HTTP store importable, make the test harness read the desire after each status write, change the suite fixtures so they pass the 422 check and carry `resource_id` if the API requires it, and record the [Store Conformance over REST](#store-conformance-over-rest) table | [HYPERFLEET-1893] states none of these. Without them both suites fail on caller permissions, owner identity, and the 422 check before they test anything | Comment on [HYPERFLEET-1893]. The comment does not yet mention the status read after a write |
| F7 | Add to [HYPERFLEET-1865]: owner binding (after C2), a bad identifier encoding (400) including names that contain colons, kubeContent that does not match the path (422), and a test Wristband signer that [HYPERFLEET-1893] also uses | [HYPERFLEET-1865] names none of these cases, and no ticket names the test signer | Comment on [HYPERFLEET-1865] |
| F8 | Add the 429 response shape to [HYPERFLEET-1829]: Envoy returns `Retry-After` and the rate-limit problem type, and a gateway check proves it | [HYPERFLEET-1829] states the limits, not the response shape. The [HYPERFLEET-1825] Error Model criteria apply to the API, but this 429 comes from Envoy | Comment on [HYPERFLEET-1829] |
| F11 | Add a test for DIS-5. The expected result comes from the [PR #260 review](https://github.com/openshift-hyperfleet/architecture/pull/260) of the spike | The spike requires this test. [HYPERFLEET-1905] and [HYPERFLEET-1771] do not state it. The API hard-deletes only when every required Adapter reports `Finalized=True` at the current generation (`hyperfleet-api` `pkg/services/aggregation.go`), so the window exists when a resource has more than one Adapter | Not raised. No owner. [HYPERFLEET-1905] is the closest ticket, because it changes the delete flow |
| F13 | The Adapter sets `resource_id` on the desires it writes | The sweeper finds orphans by `resource_id`, and the DD write body requires it. [HYPERFLEET-1905] puts setting it out of scope, and [HYPERFLEET-1837] does not state it | Raised on [HYPERFLEET-1840] as a prerequisite that nobody owns. No owner. SWP-4, SWP-5, and the [HYPERFLEET-1905] rollout wait for it |
| F14 | Reword the DD [Network Boundary and Bypass Defense](../desire-store-dd.md#network-boundary-and-bypass-defense) database rule: it means the `desire_store` database, enforced by `CONNECT` grants and credentials | The DD says Postgres allows "connections only from the Desire Store API service", but [ADR-0026](../../adrs/0026-co-located-service-databases-shared-postgres-isolation.md) puts the API, Desire Store, and Broker databases on one shared instance | Comment on [HYPERFLEET-1828]. It says the DD needs a fix and the plan records it. No owner for the DD edit |
| F15 | Define a signing-key rotation trigger that a test can use | The operator owns the keys ([HYPERFLEET-1831]). [HYPERFLEET-1756] puts the trigger out of scope. [HYPERFLEET-1925] records the dependency | Recorded as a dependency in [HYPERFLEET-1925]. No owner defines the trigger |
| F16 | Add to [HYPERFLEET-1865]: stop the Postgres container during the suite. The API returns 503 with an Error Model body, does not hang, and serves again when Postgres returns | The [HYPERFLEET-1865] acceptance criteria cover HTTP handlers and Postgres persistence, not a database outage. ERR-3 runs against a fake store. The DD states only "503 when the API is degraded" and does not say that a lost database counts as degraded | Not raised. [HYPERFLEET-1865] is the proposed owner, because it runs the HTTP suite on ephemeral Postgres |

[HYPERFLEET-1511]: https://redhat.atlassian.net/browse/HYPERFLEET-1511
[HYPERFLEET-1518]: https://redhat.atlassian.net/browse/HYPERFLEET-1518
[HYPERFLEET-1671]: https://redhat.atlassian.net/browse/HYPERFLEET-1671
[HYPERFLEET-1672]: https://redhat.atlassian.net/browse/HYPERFLEET-1672
[HYPERFLEET-1710]: https://redhat.atlassian.net/browse/HYPERFLEET-1710
[HYPERFLEET-1756]: https://redhat.atlassian.net/browse/HYPERFLEET-1756
[HYPERFLEET-1771]: https://redhat.atlassian.net/browse/HYPERFLEET-1771
[HYPERFLEET-1821]: https://redhat.atlassian.net/browse/HYPERFLEET-1821
[HYPERFLEET-1822]: https://redhat.atlassian.net/browse/HYPERFLEET-1822
[HYPERFLEET-1823]: https://redhat.atlassian.net/browse/HYPERFLEET-1823
[HYPERFLEET-1824]: https://redhat.atlassian.net/browse/HYPERFLEET-1824
[HYPERFLEET-1825]: https://redhat.atlassian.net/browse/HYPERFLEET-1825
[HYPERFLEET-1828]: https://redhat.atlassian.net/browse/HYPERFLEET-1828
[HYPERFLEET-1829]: https://redhat.atlassian.net/browse/HYPERFLEET-1829
[HYPERFLEET-1831]: https://redhat.atlassian.net/browse/HYPERFLEET-1831
[HYPERFLEET-1832]: https://redhat.atlassian.net/browse/HYPERFLEET-1832
[HYPERFLEET-1833]: https://redhat.atlassian.net/browse/HYPERFLEET-1833
[HYPERFLEET-1837]: https://redhat.atlassian.net/browse/HYPERFLEET-1837
[HYPERFLEET-1838]: https://redhat.atlassian.net/browse/HYPERFLEET-1838
[HYPERFLEET-1839]: https://redhat.atlassian.net/browse/HYPERFLEET-1839
[HYPERFLEET-1840]: https://redhat.atlassian.net/browse/HYPERFLEET-1840
[HYPERFLEET-1841]: https://redhat.atlassian.net/browse/HYPERFLEET-1841
[HYPERFLEET-1842]: https://redhat.atlassian.net/browse/HYPERFLEET-1842
[HYPERFLEET-1843]: https://redhat.atlassian.net/browse/HYPERFLEET-1843
[HYPERFLEET-1861]: https://redhat.atlassian.net/browse/HYPERFLEET-1861
[HYPERFLEET-1862]: https://redhat.atlassian.net/browse/HYPERFLEET-1862
[HYPERFLEET-1863]: https://redhat.atlassian.net/browse/HYPERFLEET-1863
[HYPERFLEET-1864]: https://redhat.atlassian.net/browse/HYPERFLEET-1864
[HYPERFLEET-1865]: https://redhat.atlassian.net/browse/HYPERFLEET-1865
[HYPERFLEET-1866]: https://redhat.atlassian.net/browse/HYPERFLEET-1866
[HYPERFLEET-1870]: https://redhat.atlassian.net/browse/HYPERFLEET-1870
[HYPERFLEET-1871]: https://redhat.atlassian.net/browse/HYPERFLEET-1871
[HYPERFLEET-1893]: https://redhat.atlassian.net/browse/HYPERFLEET-1893
[HYPERFLEET-1894]: https://redhat.atlassian.net/browse/HYPERFLEET-1894
[HYPERFLEET-1903]: https://redhat.atlassian.net/browse/HYPERFLEET-1903
[HYPERFLEET-1905]: https://redhat.atlassian.net/browse/HYPERFLEET-1905
[HYPERFLEET-1920]: https://redhat.atlassian.net/browse/HYPERFLEET-1920
[HYPERFLEET-1923]: https://redhat.atlassian.net/browse/HYPERFLEET-1923
[HYPERFLEET-1924]: https://redhat.atlassian.net/browse/HYPERFLEET-1924
[HYPERFLEET-1925]: https://redhat.atlassian.net/browse/HYPERFLEET-1925
