---
Status: Active
Owner: HyperFleet QE Team
Last Updated: 2026-11-12
---

# Desire Store Test Plan

**Jira**: [HYPERFLEET-1861]

**Epic**: [HYPERFLEET-1518]

## Table of Contents

- [Scope](#scope)
- [How to Read](#how-to-read)
- [Current and Required Capabilities](#current-and-required-capabilities)
- [Open Contract Decisions](#open-contract-decisions)
- [Scenario Matrix](#scenario-matrix)
  - [Partition and Caller Isolation](#partition-and-caller-isolation)
  - [Authenticated Ownership](#authenticated-ownership)
  - [CAS and Ambiguous Outcomes](#cas-and-ambiguous-outcomes)
  - [Pagination Failures](#pagination-failures)
  - [Non-Retryable Errors](#non-retryable-errors)
  - [Disruptive Recovery](#disruptive-recovery)
  - [Revocation](#revocation)
  - [Signing-Key Rotation](#signing-key-rotation)
  - [Sweeper Privileges](#sweeper-privileges)
  - [Deployment](#deployment)
  - [End-to-End Journeys](#end-to-end-journeys)
  - [Performance](#performance)
- [Store Conformance over REST](#store-conformance-over-rest)
- [Gaps and Deferred Work](#gaps-and-deferred-work)
- [Coverage by Ticket](#coverage-by-ticket)
- [References](#references)

## Scope

This document is the test plan for the API-mediated Postgres Desire Store ([HYPERFLEET-1518]). It maps each behavior to the test that proves it, the place where the test runs, and the ticket that owns it. After you read it, you can list the test obligations of your ticket and the gaps that touch them.

The behavior comes from the [Desire Store Detailed Design](../desire-store-dd.md) on `main`. When the detailed design does not decide a behavior yet, the row names an [open contract decision](#open-contract-decisions). [References](#references) lists the other inputs.

## How to Read

Scenario placement follows the [Test Placement Strategy](test-placement-strategy.md): test at the lowest layer that catches the failure. For each row, ask: "What must be broken for this test to fail?" The Mutation column gives the answer: the test must fail when that change is made. A measurement has no pass or fail result, so its Mutation is "None".

Each scenario has these columns: ID, Scenario and assertion, Layer, Environment, Entry point, Owner, Status, and Mutation. The tables below define the values of Layer, Environment, Entry point, and Status.

The Owner is the ticket that builds the behavior or the test. When the owner's criteria do not require the test yet, the Status names a gap.

No planned test exists yet, so every row has the Status `new` or `manual`. The `hyperfleet-desire-store` repository has only a README and a license on `main`. [Current and Required Capabilities](#current-and-required-capabilities) lists what must exist before the rows can run.

**Layers.** The first seven layers are the seven categories that the [HYPERFLEET-1861] criteria name. Unit and Deployment are added for the rows that fit neither.

| Layer | What runs |
| --- | --- |
| Backend conformance | The [Store Conformance Suite](../glossary.md) against the Postgres backend and a real Postgres |
| Service integration | The Desire Store API binary over HTTP, with a real Postgres and no gateway |
| Client | A Desire Store client against the real API binary |
| Gateway | The deployed Desire Store gateway (Envoy and Authorino). These checks read deployment internals |
| E2E | A user journey on the deployed stack, checked only through what a caller sees |
| Disruptive | A fault injected into the deployed stack, then recovery |
| Performance | Capacity and latency measurements |
| Unit | Code with mocks. No HTTP server and no database |
| Deployment | Rendered charts, or checks on a deployed install |

**Environments:**

| Environment | Description |
| --- | --- |
| `go test` | No database and no cluster. The `hyperfleet-operator` tests also start envtest |
| testcontainers | Postgres in a container that the test starts. In Prow, the job needs nested Podman, as the `hyperfleet-api` `integration` job has |
| helm render | Chart render. No cluster |
| local kind | kind from `hyperfleet-infra` `make local-up-kind`, with the mock OIDC issuer (`OIDC_ISSUER_MODE=mock`) |
| Postgres-only | The [Postgres-Only Environment](../glossary.md), on the cluster type that [HYPERFLEET-1862] states |
| Prow GKE | Nightly jobs on the GKE cluster `hyperfleet-dev-prow`. They use the Redis desire store until [HYPERFLEET-1870] |
| deployed hub | A deployed hub on the shared Postgres instance ([HYPERFLEET-1828]) |

**Entry points:**

| Entry point | Repository and state |
| --- | --- |
| `make test` | Unit tests in `hyperfleet-desire-store`, `hyperfleet-adapter`, `hyperfleet-applier`, and `hyperfleet-operator`. In `hyperfleet-desire-store`, the target is in the scaffold PR ([`hyperfleet-desire-store` PR #1](https://github.com/openshift-hyperfleet/hyperfleet-desire-store/pull/1)), not on `main` |
| `make test-integration` | `hyperfleet-desire-store`. The target does not exist yet. [HYPERFLEET-1865] adds the command; `test-integration` is the name that the [Makefile Conventions](../../standards/makefile-conventions.md) standard gives to integration tests |
| [HYPERFLEET-1893] harness target | `hyperfleet-desire-store`. [HYPERFLEET-1893] adds the target and its name |
| gateway checks | `hyperfleet-infra`. Today `make check-gateway-e2e` runs the general gateway checks on local kind. [HYPERFLEET-1829] and [HYPERFLEET-1863] build the Desire Store gateway. [HYPERFLEET-1932] adds the checks and names their target |
| `make ci-dry-run`, `make validate-desire-delivery` | `hyperfleet-infra`. The `validate` presubmit runs `make ci-dry-run`, which runs `make validate-desire-delivery` |
| `./bin/hyperfleet-e2e test --label-filter=...` | `hyperfleet-e2e`, after `make build`. The `remote-transport` label does not exist yet; [HYPERFLEET-1864] adds it |
| `tier0-nightly`, `tier1-nightly`, `tier2-nightly`, `perf-nightly` | Prow periodic jobs for `hyperfleet-e2e` |
| Manual | A manual run or measurement. The ticket that the row names records the result |

**Status values:**

| Status | Meaning |
| --- | --- |
| `new` | No test exists. Write it |
| `manual` | A manual run or measurement. No automated test |
| `Cn` after a status | The expected result depends on [open contract decision](#open-contract-decisions) `Cn` |
| `Gn` after a status | [Gap](#gaps-and-deferred-work) `Gn` affects the row: the owner's criteria do not require the test, or a prerequisite has no owner. A gap that affects every row in an environment is in [Current and Required Capabilities](#current-and-required-capabilities), not in the rows |

**Tiers.** For E2E and Disruptive rows, the Entry point gives the proposed tier. The Prow job `tier0-nightly` runs Tier0 specs, `tier1-nightly` runs Tier1, and `tier2-nightly` runs Tier2. A kind run gives the tier in its label filter. A Tier0 failure blocks release, Tier1 is advisory, and Tier2 is informational ([`test-design/README.md`](https://github.com/openshift-hyperfleet/hyperfleet-e2e/blob/5462cc781e1036401b03bf1fdf4931517990a1e0/test-design/README.md#L19-L21)).

- **ISO-1 and ISO-2 are Tier0.** The [HYPERFLEET-1861] seed matrix puts the identity matrix in Tier1. This plan proposes Tier0 for these two rows. Per-cluster isolation is a "Platform guarantee", which is a Tier0 criterion ([README line 31](https://github.com/openshift-hyperfleet/hyperfleet-e2e/blob/5462cc781e1036401b03bf1fdf4931517990a1e0/test-design/README.md#L31)). It is also an acceptance criterion of [HYPERFLEET-1518]. The existing gateway authentication specs are Tier0 too ([`jwt_enforcement.go`](https://github.com/openshift-hyperfleet/hyperfleet-e2e/blob/5462cc781e1036401b03bf1fdf4931517990a1e0/e2e/auth/jwt_enforcement.go#L16), [`multi_issuer.go`](https://github.com/openshift-hyperfleet/hyperfleet-e2e/blob/5462cc781e1036401b03bf1fdf4931517990a1e0/e2e/auth/multi_issuer.go#L18)).
- **The other identity rows are Tier1.** They test error handling and secondary paths, which is a Tier1 criterion ([README line 64](https://github.com/openshift-hyperfleet/hyperfleet-e2e/blob/5462cc781e1036401b03bf1fdf4931517990a1e0/test-design/README.md#L64)).
- **REV-3 is Tier1.** It makes only a test-owned mock issuer unreachable. It injects no infrastructure failure.
- **Disruptive rows are Tier2.** They inject infrastructure failures, which is a Tier2 criterion ([README line 91](https://github.com/openshift-hyperfleet/hyperfleet-e2e/blob/5462cc781e1036401b03bf1fdf4931517990a1e0/test-design/README.md#L91)).

**Gateway checks.** Checks that look only at status codes and response bodies go in `hyperfleet-e2e`: the E2E rows. Checks that read deployment internals go in `hyperfleet-infra`: the Gateway rows. Examples are Envoy logs, an echo upstream, and a NetworkPolicy probe such as [`run_network_policy_probe`](https://github.com/openshift-hyperfleet/hyperfleet-infra/blob/84415e8e65d865b1901304eeecdf6c0f9057fc83/scripts/check-gateway-e2e.sh#L491-L511).

The API also enforces the partition and caller rules. So an E2E row that expects a gateway denial must show which component denied the request. An API denial has an [Error Model](../../standards/error-model.md) body (`application/problem+json`). A gateway 401 or 403 has none. ISO-1, ISO-2, and DIS-4 use this difference (G5).

## Current and Required Capabilities

"Current" means that the capability exists on `main` today. "Required" means that a ticket must deliver it before the rows that use it can run. A required capability that no ticket delivers names its gap.

| Capability | State | Evidence or owner |
| --- | --- | --- |
| Store Conformance Suite | Current, in process only. The memory and Redis backends run it in their unit tests | `hyperfleet-applier` [`memory/store_test.go`](https://github.com/openshift-hyperfleet/hyperfleet-applier/blob/f15f3f8630e15fc6f446edc535ccef6f370907e2/pkg/desire/store/memory/store_test.go#L13), [`redis/redis_test.go`](https://github.com/openshift-hyperfleet/hyperfleet-applier/blob/f15f3f8630e15fc6f446edc535ccef6f370907e2/pkg/desire/store/redis/redis_test.go#L56) |
| Postgres in a Prow presubmit | Current in `hyperfleet-api` only. Its `integration` job runs `make test-integration` with nested Podman. The `hyperfleet-applier` `integration` job runs `make test-envtest` and has no container runtime | `openshift/release` [`hyperfleet-api` presubmits](https://github.com/openshift/release/blob/82f95b4fc40e9b0640304f39f39b8c85dceab5bd/ci-operator/config/openshift-hyperfleet/hyperfleet-api/openshift-hyperfleet-hyperfleet-api-main__presubmits.yaml#L37-L69), [`hyperfleet-applier` jobs](https://github.com/openshift/release/blob/82f95b4fc40e9b0640304f39f39b8c85dceab5bd/ci-operator/config/openshift-hyperfleet/hyperfleet-applier/openshift-hyperfleet-hyperfleet-applier-main.yaml#L22-L28) |
| Chart render presubmit | Current. The `hyperfleet-infra` `validate` job runs `make ci-dry-run`. The `integration` job is `optional: true` | `openshift/release` [`hyperfleet-infra` jobs](https://github.com/openshift/release/blob/82f95b4fc40e9b0640304f39f39b8c85dceab5bd/ci-operator/config/openshift-hyperfleet/hyperfleet-infra/openshift-hyperfleet-hyperfleet-infra-main.yaml#L61-L73) |
| Gateway checks on kind | Current for the general API gateway only. `make check-gateway-e2e` runs on local kind with the mock issuer. No HyperFleet Prow job runs it ([HYPERFLEET-1932]) | `hyperfleet-infra` [`Makefile`](https://github.com/openshift-hyperfleet/hyperfleet-infra/blob/84415e8e65d865b1901304eeecdf6c0f9057fc83/Makefile#L326), [`check-gateway-e2e.sh`](https://github.com/openshift-hyperfleet/hyperfleet-infra/blob/84415e8e65d865b1901304eeecdf6c0f9057fc83/scripts/check-gateway-e2e.sh#L134) |
| Mock OIDC issuer tokens in E2E | Current | `hyperfleet-e2e` [`pkg/identity`](https://github.com/openshift-hyperfleet/hyperfleet-e2e/blob/5462cc781e1036401b03bf1fdf4931517990a1e0/pkg/identity/mock.go) ([HYPERFLEET-1843]) |
| Tier and perf nightlies | Current, on the Redis desire store | `openshift/release` [`hyperfleet-e2e` nightlies](https://github.com/openshift/release/blob/82f95b4fc40e9b0640304f39f39b8c85dceab5bd/ci-operator/config/openshift-hyperfleet/hyperfleet-e2e/openshift-hyperfleet-hyperfleet-e2e-main__e2e.yaml#L14-L120); [HYPERFLEET-1870] |
| Desire Store service code and CI | Required. `main` has a README and a license. No Prow configuration exists | [HYPERFLEET-1824], [HYPERFLEET-1918], [HYPERFLEET-1865] |
| Test Wristband signer | Required. No ticket names it (G4) | None |
| HTTP conformance harness | Required. Its criteria do not hold the harness changes (G3) | [HYPERFLEET-1893] |
| Postgres-Only Environment | Required | [HYPERFLEET-1862] |
| Desire Store API access to Postgres through the NetworkPolicy | Required. The Postgres ingress policy admits only API pods (G13) | None |
| Desire Store API and gateway in the nightly environment | Required by every row on Prow GKE | [HYPERFLEET-1870] |
| Second gateway install | Required | [HYPERFLEET-1863], [HYPERFLEET-1829] |
| E2E gateway configuration, fixtures, and the `desire` and `remote-transport` labels | Required. Today `[remote-transport]` is only a tag in spec names ([example](https://github.com/openshift-hyperfleet/hyperfleet-e2e/blob/5462cc781e1036401b03bf1fdf4931517990a1e0/e2e/adapter/adapter_with_remote_transport.go#L46)). [`pkg/labels/labels.go`](https://github.com/openshift-hyperfleet/hyperfleet-e2e/blob/5462cc781e1036401b03bf1fdf4931517990a1e0/pkg/labels/labels.go) has no such label | [HYPERFLEET-1864] |
| Resolution of the per-partition hostnames in test environments | Required. No ticket owns it (G11) | None |
| Signing-key rotation trigger for tests | Required | [HYPERFLEET-1931] |
| `resource_id` on Adapter desires | Required. No ticket owns it (G7) | None |
| On-demand sweeper run in test environments | Required. The planned sweeper cadence is about 12 hours ([HYPERFLEET-1840]), so a nightly spec almost never sees a sweep (G2) | None |
| Prow job for the Desire Store gateway checks | Required | [HYPERFLEET-1932] |

## Open Contract Decisions

The detailed design on `main` does not decide these behaviors. A row that depends on a decision names its ID in the Status column. File references are to `hyperfleet-applier` commit `f15f3f8`, unless the row says otherwise.

[HYPERFLEET-1871] decided the former C1 (timed-out delete recovery) and C2 (owner binding and the owner-conflict code) in the detailed design. The rows state those rules.

| ID | Open decision | Facts | Decided by | Rows |
| --- | --- | --- | --- | --- |
| C3 | Sweeper partition enumeration, deletion confirmation, and record cleanup | A partition-listing route would change the REST v1 contract ([HYPERFLEET-1823]) | [HYPERFLEET-1823] | SWP-4, SWP-5 |
| C6 | Authorino behavior that the gateway rules depend on: issuer enforcement, denial on CEL evaluation errors, and revocation timing | The detailed design lists these under "Verify at implementation" ([Operator and Gateway Changes](../desire-store-dd.md#operator-and-gateway-changes)) | [HYPERFLEET-1822] | ISO-2, REV-1, REV-2, REV-4, REV-5 |
| C7 | Private connectivity and TLS trust from management clusters | [HYPERFLEET-1866] owns this design | [HYPERFLEET-1866] | DEP-5 |
| C8 | `limit` above the maximum: clamp it or return 400 | The detailed design leaves the choice to the OpenAPI specification ([REST API (v1)](../desire-store-dd.md#rest-api-v1)) | [HYPERFLEET-1821] | PAG-1 |

## Scenario Matrix

Each table covers one area of the [HYPERFLEET-1861] criteria. [How to Read](#how-to-read) defines the column values.

### Partition and Caller Isolation

| ID | Scenario and assertion | Layer | Environment | Entry point | Owner | Status | Mutation that turns it red |
| --- | --- | --- | --- | --- | --- | --- | --- |
| ISO-1 | A remote Applier reaches only its bound partition. The gateway denies a path partition mismatch before the request reaches the API | E2E | Prow GKE | `tier0-nightly` | [HYPERFLEET-1833] | new, G5 | Remove the path-partition predicate from the binding AuthConfig. The API then makes the denial, and the response has an Error Model body |
| ISO-2 | Cross-caller authentication fails closed in both directions. A management-cluster token on the base host and a Hub service-account token on a partition host both get 401 from the gateway | E2E | Prow GKE | `tier0-nightly` | [HYPERFLEET-1833] | new, C6, G5 | Add the mock issuer to the fleet-scoped AuthConfig. Authorization then denies with 403, not 401 |
| ISO-3 | The API takes the partition from the Wristband claim. Forged identity, caller-class, partition, and `x-wristband` headers grant no access | Service integration | testcontainers | `make test-integration` | [HYPERFLEET-1865], [HYPERFLEET-1825] | new | Read the partition from the path, not from the claim |
| ISO-4 | The gateway strips client-supplied identity, caller-class, partition, and `x-wristband` headers, and forwards only the Wristband that Authorino issues. An echo upstream or the Envoy access log shows that the forged values do not reach the upstream | Gateway | local kind | gateway checks | [HYPERFLEET-1829] | new | Remove the header-strip filter |
| ISO-5 | A pod that is not the gateway cannot open a TCP connection to the Desire Store API. The probe expects a connection timeout, as `run_network_policy_probe` does, not an HTTP status. The API also rejects a request without a Wristband, so an HTTP status does not prove the NetworkPolicy | Gateway | local kind | gateway checks | [HYPERFLEET-1829] | new | Remove the API ingress NetworkPolicy |
| ISO-6 | The Desire Store Authorino and the general Authorino do not serve each other's AuthConfigs | Deployment | helm render | `make ci-dry-run` | [HYPERFLEET-1863] | new | Remove the shard label selector |
| ISO-7 | A registration with a duplicate issuer, overlapping signing keys, or a duplicate partition is rejected | Unit | `go test` | `hyperfleet-operator` `make test` | [HYPERFLEET-1832] | new | Skip the uniqueness check |
| ISO-8 | Startup fails when the partition enforcement configuration is missing | Unit | `go test` | `hyperfleet-desire-store` `make test` | [HYPERFLEET-1825] | new | Start with enforcement off when the configuration is missing |
| ISO-9 | Only the Desire Store API receives the `desire_store` database credentials | Deployment | helm render | `make ci-dry-run` | [HYPERFLEET-1828] | new | Mount the credentials Secret in a second workload |
| ISO-10 | Only the Desire Store roles have `CONNECT` on the `desire_store` database, so the other services on the shared instance cannot connect to it | Deployment | deployed hub | Manual, recorded on [HYPERFLEET-1828] | [HYPERFLEET-1828] | manual | Grant `CONNECT` on `desire_store` to the API role |
| ISO-11 | The operator replaces a binding when its identity or partition changes | Unit | `go test` | `hyperfleet-operator` `make test` | [HYPERFLEET-1831] | new | Keep the old binding when the partition changes |
| ISO-12 | A partial match of issuer, audience, and subject is denied. Example: the right issuer and subject with the wrong audience | E2E | Prow GKE | `tier1-nightly` | [HYPERFLEET-1833] | new, G1 | Remove the audience check from the binding AuthConfig |
| ISO-13 | A fleet-scoped caller on the base host authenticates through TokenReview and reaches the API | E2E | Prow GKE | `tier1-nightly` | [HYPERFLEET-1833] | new | Remove TokenReview from the fleet-scoped AuthConfig |

### Authenticated Ownership

| ID | Scenario and assertion | Layer | Environment | Entry point | Owner | Status | Mutation that turns it red |
| --- | --- | --- | --- | --- | --- | --- | --- |
| OWN-1 | The stored `owner` is the caller's `hf_identity` ([Owner Binding](../desire-store-dd.md#owner-binding)) | Service integration | testcontainers | `make test-integration` | [HYPERFLEET-1865] | new, G4 | Store the owner from the request body |
| OWN-2 | An owner collision returns `HYPERFLEET-CNF-004`, not the version-conflict code. The Adapter client surfaces it and does not retry | Service integration, Unit, Client | testcontainers; `go test`; testcontainers | `make test-integration`; `hyperfleet-adapter` `make test`; [HYPERFLEET-1893] harness target | [HYPERFLEET-1825], [HYPERFLEET-1837], [HYPERFLEET-1893] | new, G3 | API: return the version-conflict code for an owner collision. Client: send an owner collision to the conflict-retry path |
| OWN-3 | Write split ([Caller-to-Operation Matrix](../desire-store-dd.md#caller-to-operation-matrix)): the Adapter cannot write status, and the Applier cannot write or delete desired state. Each denied request leaves the record unchanged | Service integration | testcontainers | `make test-integration` | [HYPERFLEET-1865] | new | Remove the caller-class check from the status route |
| OWN-4 | A write body that includes `owner` returns 400 | Service integration | testcontainers | `make test-integration` | [HYPERFLEET-1865] | new, G4 | Ignore an `owner` field in the body |

### CAS and Ambiguous Outcomes

| ID | Scenario and assertion | Layer | Environment | Entry point | Owner | Status | Mutation that turns it red |
| --- | --- | --- | --- | --- | --- | --- | --- |
| CAS-1 | The Postgres backend passes the Store Conformance Suite: CAS, listing, status writes, prefix delete, and the rules across desire types | Backend conformance | testcontainers | `make test-integration` | [HYPERFLEET-1671] | new | Skip the version predicate in the update |
| CAS-2 | Each row of [Conflict Responses](../desire-store-dd.md#conflict-responses) returns 409 with its code: a version mismatch `HYPERFLEET-CNF-002`, a create on an existing desire `HYPERFLEET-CNF-001`, and an apply while the delete is not confirmed `HYPERFLEET-CNF-003`. OWN-2 covers `HYPERFLEET-CNF-004`. A status write to a missing desire returns 404 | Service integration | testcontainers | `make test-integration` | [HYPERFLEET-1865], [HYPERFLEET-1825] | new | Upsert on a status write |
| CAS-3 | Status writes follow the decided version and generation rules. An ApplyDesire or DeleteDesire status write with the current `version` returns 204 and increments the version without changing `generation`. A stale `version` returns `HYPERFLEET-CNF-002`, a missing `version` returns 400, and the record is unchanged. A ReadDesire status write carries no `version` ([HYPERFLEET-1511]) and does not change it. GET returns `generation`. A spec update that changes `kubeContent` advances it, and one that does not leaves it unchanged | Service integration, Client | testcontainers | `make test-integration`; [HYPERFLEET-1893] harness target | [HYPERFLEET-1865], [HYPERFLEET-1893] | new, G3, G4 | Accept a status write with a stale `version` |
| CAS-4 | After a timed-out write, the Adapter client reads the desire before it retries | Unit | `go test` | `hyperfleet-adapter` `make test` | [HYPERFLEET-1837] | new | Retry without the read |
| CAS-5 | After a timed-out delete, each client follows the [timed-out delete rule](../desire-store-dd.md#cas--version-semantics). The sweeper reads the desire and retries only when it is present at the same version and still has the sweeper as `owner`. The Adapter either does the same read or retries the conditional `DELETE` directly and treats 404 as success | Unit | `go test` | `make test` in `hyperfleet-adapter` and in the sweeper's repository | [HYPERFLEET-1837], [HYPERFLEET-1840] | new, G2 | Retry when the desire is present at a new version |
| CAS-6 | Envoy retries only before it sends the request upstream, so it never replays a PUT or a DELETE | Gateway | local kind | gateway checks | [HYPERFLEET-1829] | new | Add `5xx` to the retry policy |
| CAS-7 | The Adapter client's CAS and ownership handling holds over HTTP | Client | testcontainers | [HYPERFLEET-1893] harness target | [HYPERFLEET-1893] | new, G3 | Drop `version` from update requests in the client |
| CAS-8 | The rules across desire types hold over HTTP: an apply while a delete is pending is rejected, a confirmed delete allows recreation, one owner covers every desire type of an object, and creating a delete returns 201, removes the apply for the same object, and leaves the read desire. A later status write to the removed apply returns 404 | Service integration, Client | testcontainers | `make test-integration`; [HYPERFLEET-1893] harness target | [HYPERFLEET-1825], [HYPERFLEET-1893] | new, G3 | Accept an apply while the delete is pending |
| CAS-9 | A `DELETE` with no `version`, or with a `version` that is not an integer, returns 400 | Service integration | testcontainers | `make test-integration` | [HYPERFLEET-1865] | new, G4 | Delete at any version when `version` is missing |
| CAS-10 | When both the version and the owner are wrong, a write or delete returns `HYPERFLEET-CNF-002`. The retry with the current version returns `HYPERFLEET-CNF-004` | Service integration | testcontainers | `make test-integration` | [HYPERFLEET-1865] | new, G4 | Check the owner before the version |

### Pagination Failures

| ID | Scenario and assertion | Layer | Environment | Entry point | Owner | Status | Mutation that turns it red |
| --- | --- | --- | --- | --- | --- | --- | --- |
| PAG-1 | Lists use keyset pagination with no total count. A list item carries only the identity fields and `version`, with no `kubeContent`, `status`, `owner`, or `resource_id`. Across all pages, each desire appears exactly once. An invalid cursor returns 400. A `limit` above the maximum follows the decided rule | Service integration | testcontainers | `make test-integration` | [HYPERFLEET-1865] | new, C8 | Use `>=` in the cursor predicate |
| PAG-2 | When a page fails, the Applier keeps its last complete view. It never treats an incomplete list as an empty partition | Unit | `go test` | `hyperfleet-applier` `make test` | [HYPERFLEET-1838] | new | Replace the view before the final page |
| PAG-3 | After a restart, the Applier waits for a successful partition read before it reconciles | Unit | `go test` | `hyperfleet-applier` `make test` | [HYPERFLEET-1838] | new | Reconcile from an empty view |
| PAG-4 | Lists carry references only, and the Applier applies from the GET response | Unit | `go test` | `hyperfleet-applier` `make test` | [HYPERFLEET-1839] | new | Decode the manifest from the list response |

### Non-Retryable Errors

| ID | Scenario and assertion | Layer | Environment | Entry point | Owner | Status | Mutation that turns it red |
| --- | --- | --- | --- | --- | --- | --- | --- |
| ERR-1 | The Adapter client surfaces errors for invalid credentials, permissions, input, and ownership, and does not retry them | Unit | `go test` | `hyperfleet-adapter` `make test` | [HYPERFLEET-1837] | new | Retry on 403 |
| ERR-2 | The Applier client surfaces non-retryable errors. It retries temporary failures with capped exponential backoff and jitter | Unit | `go test` | `hyperfleet-applier` `make test` | [HYPERFLEET-1838] | new | Retry on 401 |
| ERR-3 | A degraded API returns 503 with an Error Model body | Unit | `go test` | `hyperfleet-desire-store` `make test` | [HYPERFLEET-1825] | new | Map a store failure to 500 |
| ERR-4 | The Adapter and Applier clients wait for `Retry-After` before they retry a 429 | Unit | `go test` | `make test` in `hyperfleet-adapter` and `hyperfleet-applier` | [HYPERFLEET-1837], [HYPERFLEET-1838] | new | Ignore `Retry-After` |
| ERR-5 | The gateway returns 429 to a caller over its rate limit, with `Retry-After` and the rate-limit problem type | Gateway | local kind | gateway checks | [HYPERFLEET-1829] | new, G5 | Remove the post-auth rate-limit filter |
| ERR-6 | A bad identifier encoding returns 400, and a name that contains colons decodes correctly. `kubeContent` that does not match the path returns 422 | Service integration | testcontainers | `make test-integration` | [HYPERFLEET-1865] | new, G4 | Split the identifier at every colon |
| ERR-7 | The test stops the Postgres container while the API runs. The API returns 503 with an Error Model body and does not hang. It serves again when Postgres returns | Service integration | testcontainers | `make test-integration` | [HYPERFLEET-1865] | new, G10 | Map a driver connection error to 500 |
| ERR-8 | Concurrent database work is capped: with more slow requests in flight than the cap, Postgres never sees more concurrent queries from the API than the cap, and another caller's request still completes | Service integration | testcontainers | `make test-integration` | [HYPERFLEET-1825] | new | Remove the database concurrency cap |

### Disruptive Recovery

| ID | Scenario and assertion | Layer | Environment | Entry point | Owner | Status | Mutation that turns it red |
| --- | --- | --- | --- | --- | --- | --- | --- |
| DIS-1 | The Desire Store API is unavailable: the Adapter reports the failure. After recovery, the cluster reconciles | Disruptive | Postgres-only; Prow GKE after [HYPERFLEET-1870] | `./bin/hyperfleet-e2e test --label-filter='tier2 && remote-transport'`; `tier2-nightly` | [HYPERFLEET-1771] | new | Report `Applied=True` on a store error |
| DIS-3 | Store loss during a delete does not leave the remote object behind | Disruptive | Postgres-only; Prow GKE after [HYPERFLEET-1870] | `./bin/hyperfleet-e2e test --label-filter='tier2 && remote-transport'`; `tier2-nightly` | [HYPERFLEET-1771], after [HYPERFLEET-1905] | new, G7 | Mark the resource deleted when discovery returns NotFound |
| DIS-4 | Authorino is unavailable: the gateway denies every request. The response has no Error Model body, and the request does not reach the API | Disruptive | Prow GKE | `tier2-nightly` | [HYPERFLEET-1924] | new, G5 | Make external authorization fail open with no other guard for a missing Wristband, for example `failure_mode_allow: true` on the Envoy `ext_authz` filter. The API then answers 401 with an Error Model body |
| DIS-5 | The confirmed `DeleteDesire` is lost after one Adapter reports `Finalized=True` and before the API hard-deletes the record. The next event sets `Finalized` to False, the Adapter writes the `DeleteDesire` again, and it reports `Finalized=True` again after the Applier confirms | Unit | `go test` | `hyperfleet-adapter` `make test` | [HYPERFLEET-1905] | new, G6, G7 | Keep `Finalized=True` when the confirmed `DeleteDesire` is missing |

[HYPERFLEET-1771] accepts DIS-1 on the Postgres-only run. The nightly can run DIS-1 and DIS-3 only after [HYPERFLEET-1870] moves it to the Desire Store API.

### Revocation

| ID | Scenario and assertion | Layer | Environment | Entry point | Owner | Status | Mutation that turns it red |
| --- | --- | --- | --- | --- | --- | --- | --- |
| REV-1 | Deleting the registration record denies the Applier within 60 seconds on a healthy control plane. The spec polls up to that bound plus a margin that it states | E2E | Prow GKE | `tier1-nightly` | [HYPERFLEET-1833] | new, C6 | Keep the AuthConfig after the record is deleted |
| REV-2 | The time that stale policy lasts under a stalled watch is measured once | Gateway | A deployed Authorino and Envoy. [HYPERFLEET-1822] names no cluster | Manual, recorded in the architecture repository | [HYPERFLEET-1822] | manual, C6 | None |
| REV-3 | An unreachable issuer fails only the partition of that issuer | E2E | Prow GKE | `tier1-nightly` | [HYPERFLEET-1833] | new | Deny every partition when any issuer's key fetch fails |
| REV-4 | A token with a lifetime over one hour, or with missing age claims, is denied | E2E | Prow GKE | `tier1-nightly` | [HYPERFLEET-1833] | new, C6, G1 | Remove the age predicate |
| REV-5 | The rendered partition extraction rejects malformed paths | Unit | `go test` | `hyperfleet-operator` `make test` | [HYPERFLEET-1831] | new, C6 | Extract the partition by segment index |

### Signing-Key Rotation

| ID | Scenario and assertion | Layer | Environment | Entry point | Owner | Status | Mutation that turns it red |
| --- | --- | --- | --- | --- | --- | --- | --- |
| KEY-1 | A missing Wristband returns 401. A missing Authorization header alone does not. An unknown key, a bad signature, an expired Wristband, or inconsistent claims are rejected before data access | Unit, Service integration | `go test`; testcontainers | `hyperfleet-desire-store` `make test`; `make test-integration` | [HYPERFLEET-1825], [HYPERFLEET-1865] | new | Skip the `kid` lookup |
| KEY-2 | When key refresh fails, the API accepts only the keys that it already trusts | Unit | `go test` | `hyperfleet-desire-store` `make test` | [HYPERFLEET-1825] | new | Accept the Wristband when refresh fails |
| KEY-3 | Rotation adds the new key first and keeps the previous key | Unit | `go test` | `hyperfleet-operator` `make test` | [HYPERFLEET-1831] | new | Remove the previous key at rotation |
| KEY-4 | A live key rotation causes no 401 through the gateway. The spec is `Serial`, because rotation affects every concurrent spec | E2E | Prow GKE | `tier1-nightly` | [HYPERFLEET-1925] | new | Put the new key first in `signingKeyRefs` while the API holds only the old key set |

### Sweeper Privileges

| ID | Scenario and assertion | Layer | Environment | Entry point | Owner | Status | Mutation that turns it red |
| --- | --- | --- | --- | --- | --- | --- | --- |
| SWP-1 | The sweeper can write `DeleteDesire` records only. Its other writes return 403 | Service integration | testcontainers | `make test-integration` | [HYPERFLEET-1865] | new, G2 | Authorize by caller class, not by `hf_identity` |
| SWP-2 | The sweeper is exempt from the owner-collision check, and the API stores its `hf_identity` as `owner`. After a timed-out delete, the sweeper retries only when the stored `owner` is still its own ([sweeper guard](../desire-store-dd.md#cas--version-semantics)) | Unit, Service integration | `go test`; testcontainers | `make test` in the sweeper's repository; `make test-integration` | [HYPERFLEET-1840], [HYPERFLEET-1865] | new, G2, G15 | Apply the owner check to the sweeper |
| SWP-3 | The fleet-scoped allowlist admits the sweeper and denies a service account that is not on the list | Unit, E2E | `go test`; Prow GKE | `hyperfleet-operator` `make test`; `tier1-nightly` | [HYPERFLEET-1831], [HYPERFLEET-1833] | new, G1 | Allow any service account that has the audience |
| SWP-4 | Orphan journey: the `resource_id` target is gone, the sweeper writes a `DeleteDesire`, the Applier confirms it, and the sweeper removes the record | E2E | Prow GKE | `tier1-nightly` | [HYPERFLEET-1840] | new, C3, G2, G7, G15 | Skip the record removal |
| SWP-5 | The sweeper removes the confirmed `DeleteDesire` records that adapters keep after a delete. [HYPERFLEET-1905] must not ship before this works | Unit | `go test` | `make test` in the sweeper's repository | [HYPERFLEET-1840] | new, C3, G2, G7, G15 | Skip the records that the sweeper does not own |

SWP-3 needs the sweeper's service account ([HYPERFLEET-1840]) in the rendered allowlist.

### Deployment

| ID | Scenario and assertion | Layer | Environment | Entry point | Owner | Status | Mutation that turns it red |
| --- | --- | --- | --- | --- | --- | --- | --- |
| DEP-1 | The Postgres-only render passes validation with no Redis. The shared environments keep their Redis checks | Deployment | helm render | `make validate-desire-delivery` | [HYPERFLEET-1862] | new | Restore the `redis` dependency |
| DEP-2 | Setup and teardown work, including teardown after a partial setup failure | Deployment | The test cluster that [HYPERFLEET-1862] states | Manual, with the setup and teardown commands of [HYPERFLEET-1862], recorded on that ticket | [HYPERFLEET-1862] | manual | Skip teardown of a created resource |
| DEP-3 | Migrations run under the migration role, and the service runs under the runtime role | Service integration, Deployment | testcontainers; deployed hub | `make test-integration`; Manual, recorded on [HYPERFLEET-1828] | [HYPERFLEET-1865], [HYPERFLEET-1828] | new, manual | Run migrations with the runtime role |
| DEP-4 | A weaker `sslmode` or a missing CA bundle fails at startup | Unit | `go test` | `hyperfleet-desire-store` `make test` | [HYPERFLEET-1903] | new | Accept `require` as a valid `sslmode` |
| DEP-5 | Management clusters reach the private gateway and verify its TLS identity | Deployment | A paper assessment where no live topology exists ([HYPERFLEET-1866]) | Manual: the [HYPERFLEET-1866] spike report | [HYPERFLEET-1866] | manual, C7 | None |

### End-to-End Journeys

| ID | Scenario and assertion | Layer | Environment | Entry point | Owner | Status | Mutation that turns it red |
| --- | --- | --- | --- | --- | --- | --- | --- |
| E2E-1 | The Tier0 remote-transport specs pass on the Postgres-Only Environment | E2E | Postgres-only | `./bin/hyperfleet-e2e test --label-filter='tier0 && remote-transport'` | [HYPERFLEET-1862], [HYPERFLEET-1671] | new | Scale the Desire Store API to 0 replicas |
| E2E-2 | The Tier0 and Tier1 specs pass on GKE after the switch from Redis | E2E | Prow GKE | `tier0-nightly`, `tier1-nightly` | [HYPERFLEET-1870] | new | Delete the Applier binding AuthConfig |
| E2E-3 | A smoke test authenticates a caller through the Desire Store gateway and verifies the server's TLS identity | E2E | Postgres-only | `./bin/hyperfleet-e2e test --label-filter='tier1 && remote-transport'` | [HYPERFLEET-1864] | new | Use a wrong CA |

### Performance

| ID | Scenario and assertion | Layer | Environment | Entry point | Owner | Status | Mutation that turns it red |
| --- | --- | --- | --- | --- | --- | --- | --- |
| PRF-1 | Gateway and API capacity at 10,000 partitions, one poll per partition every 5 seconds, and 10 desires per partition | Performance | Not named. [HYPERFLEET-1842] names no environment | Manual benchmark, recorded on [HYPERFLEET-1842] | [HYPERFLEET-1842] | manual | None |
| PRF-2 | Contention when the API, the Broker, and the Desire Store load one Postgres instance together | Performance | kind or a dev instance ([HYPERFLEET-1672]) | Manual soak run, with results in the performance epic | [HYPERFLEET-1672] | manual | None |
| PRF-3 | The perf thresholds are re-derived after the switch from Redis, and `perf-nightly` passes on them | Performance | Prow GKE | `perf-nightly` | [HYPERFLEET-1894] | new | Add a 1 s delay to each Desire Store API response |

## Store Conformance over REST

The [Store Conformance Suite](../glossary.md) is the set of Go tests in `hyperfleet-applier` that every desire store backend must pass. Today it runs in process, against the memory and Redis backends. [HYPERFLEET-1893] runs it through the Adapter's HTTP client against the Desire Store API. Its criteria say that a case that cannot pass over HTTP is recorded with a reason and a follow-up. This table records those cases. G3 records the harness changes that they need.

Line numbers refer to [`pkg/desire/store/conformance/suite.go`](https://github.com/openshift-hyperfleet/hyperfleet-applier/blob/f15f3f8630e15fc6f446edc535ccef6f370907e2/pkg/desire/store/conformance/suite.go) at `hyperfleet-applier` commit `f15f3f8`.

| Cases | Why they cannot pass unchanged over HTTP | What decides them |
| --- | --- | --- |
| `DeleteForeignOwnerRejected` (:577, :651, and the ApplyDesire case that [HYPERFLEET-1920] adds) | The API takes the owner from the caller's credentials ([Owner Binding](../desire-store-dd.md#owner-binding)), so one store cannot act as two owners | The harness sends each owner's calls with that owner's credentials (G3) |
| `DeleteByPrefix` (:1025) | No REST v1 route deletes by prefix. No non-test code in `hyperfleet-adapter` or `hyperfleet-applier` calls it | Backend only: CAS-1 covers it |
| `ManagementClusterListing` (:667) | It asserts `Generation` on listed desires. A list returns only the identity fields and `version`, so `generation` in GET responses alone does not make it pass | Lists carry no `generation` ([Wire Schemas](../desire-store-dd.md#wire-schemas)), so the harness reads each listed desire with GET (G3) |
| `UpdateStatusSuccessIncrementsVersion` (:1166, :1335), `StaleStatusWriteAfterSpecUpdateIsRejected` (:1195), `StaleVersionRejected` (:1399) | The first two read the desire that the status write returns (:1184-1191, :1352-1359, :1216, :1227) and assert `Generation`. A status write returns no body. `StaleVersionRejected` creates its DeleteDesire through the spec store, so it needs the Adapter and Applier calls in one store | The [HYPERFLEET-1838] client sends `version` in the status body ([Wire Schemas](../desire-store-dd.md#wire-schemas)), so the stale-version checks follow the detailed design. All three need the combined store (G3), and the first two also need the harness read after each status write (G3) |
| `UpdateStatusReturnedValueIsIsolatedFromCallerMutation` (:1244, :1371, :1546) | They change the desire that the status write returns, and check that the store is not affected. A status write returns no body | Over HTTP, the harness read (G3) returns a newly decoded value. The case then tests the harness, not the API |
| `KubeContentMirror` (:1579), `StatusWriteDoesNotChangeSpec` (:1298), `UpdateStatusSucceedsWithoutVersionCheck` (:1444), `RecreateAfterDeleteClearsStatus` (:197), `OnlyChangedSpecAdvancesGeneration` (:273), `UpdateSpecPreservesStatus` (:364) | They read the desire that the status write returns: `updated.Status.KubeContent` (:1601), `afterStatus.Spec.KubeContent` (:1316), `afterStatus.Generation` (:1319), `updated.Generation` (:1460), and `withStatus.Version` (:221, :298, :406). A status write returns no body, so these cases fail even though `generation` and `version` are in GET responses | The harness reads the desire after each status write and returns it (G3) |
| `OnlyChangedSpecAdvancesGeneration` (:273), `CreateGetRoundTrip` (:84, :520, :594), `UpdateSpecRejectsEmptyKubeContent` (:176), `RecreateAfterDeleteClearsStatus` (:197), `UpdateSpecSuccessIncrementsVersion` (:247), `UpdateSpecPreservesStatus` (:364), `DifferentOwnerRejected` (:478), `StatusWriteDoesNotChangeSpec` (:1298), `UpdateStatusSucceedsWithoutVersionCheck` (:1444) | They assert `Generation` on the desire that a call returns. `OnlyChangedSpecAdvancesGeneration` also asserts that a stale status write is rejected (:316-319) and that a foreign-owner update returns `ErrOwnerConflict` (:351) | Write desire returns the full record, including `generation` and `version`, on create and update ([Wire Schemas](../desire-store-dd.md#wire-schemas)). Only the status-write cases need the harness read (G3). `OnlyChangedSpecAdvancesGeneration` also needs the two Adapter identities (G3) |
| `ApplyThenDeleteSupersedes` (:757) | It writes an ApplyDesire fixture with no Kubernetes identity (:761) | The detailed design decides the supersede ([CAS / Version Semantics](../desire-store-dd.md#cas--version-semantics)). The case passes over HTTP once the fixture and `resource_id` changes (G3) apply |
| `DeleteThenApplyRejected` (:783), `ConfirmedDeleteThenApplyRecreates` (:799), `CrossTypeOwnership` (:899) | The cases switch owners or caller classes in one store | The detailed design decides these rules ([Conflict Responses](../desire-store-dd.md#conflict-responses)). The harness needs the combined store and the two Adapter identities (G3) |
| Every case that writes an ApplyDesire | The fixtures carry `kubeContent` with no Kubernetes identity: constants such as `{"v":1}` (:20), and inline values such as `{}` (23 times) and `{"kind":"ConfigMap"}` (:87). `identity()` sets group `apps` with resource `configmaps` (:26). ConfigMaps are in the core API group, not `apps`, so no valid manifest matches this identity. The API returns 422 when `kubeContent` does not match the path ([Status Codes](../desire-store-dd.md#status-codes)) | A suite change: `identity()` and every ApplyDesire fixture name a real Kubernetes kind, and the two agree (G3) |
| Every case that writes a desire | The suite never sets `OriginID`, and the write body carries `resource_id` ([Wire Schemas](../desire-store-dd.md#wire-schemas)) | If the API requires `resource_id`, the harness or the suite supplies it (G3) |
| Every case that writes a ReadDesire | None for the field: the write body carries `target_version` ([Wire Schemas](../desire-store-dd.md#wire-schemas)) | The [HYPERFLEET-1837] client sends `TargetVersion` as `target_version`. The fixture and `resource_id` changes (G3) still apply |

## Gaps and Deferred Work

G numbers are labels local to this document, so that rows can refer to a gap. They are not issue IDs, and Jira holds the work. Each gap states the problem and its impact, the proposed action, the proposed owner group, the disposition, the tracking, and the evidence. The owner group is the approvers group in the `OWNERS` file of the repository that the action changes. When a ticket adds the action to its criteria, change the disposition to `Tracked` and remove the G ID from the rows.

**Disposition values:**

| Disposition | Meaning |
| --- | --- |
| `Tracked` | The criteria of the linked ticket require the action |
| `Add to ticket` | The linked ticket is the proposed home. Its criteria do not state the action yet |
| `New ticket` | No ticket fits. A new ticket is necessary |
| `Deferred` | No action until the stated condition holds |

| ID | Gap and impact | Proposed action | Owner | Disposition | Tracking | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| G1 | The criteria of [HYPERFLEET-1833] do not include four cases: a token lifetime over one hour or missing age claims (REV-4), a partial match of issuer, audience, and subject (ISO-12), a service account that is not on the allowlist, and the sweeper on the allowlist (SWP-3). No other ticket tests these gateway rules end to end | Add the four cases to the criteria of [HYPERFLEET-1833] | `e2e-owners` | `Add to ticket` | Comment on [HYPERFLEET-1833] | [HYPERFLEET-1833] criteria; [Token Lifetime and Revocation Behavior](../desire-store-dd.md#token-lifetime-and-revocation-behavior); [Partition Binding](../desire-store-dd.md#partition-binding) |
| G2 | [HYPERFLEET-1840] has no test criterion and names no repository for the sweeper, so CAS-5, SWP-2, and SWP-5 have no place to run. Its planned cadence is about 12 hours, so a nightly spec almost never sees a sweep. [HYPERFLEET-1865] has no sweeper case | Add the sweeper authorization cases (SWP-1, SWP-2) to [HYPERFLEET-1865]. Add to [HYPERFLEET-1840]: the sweeper's repository, the timed-out delete case (CAS-5), the orphan journey (SWP-4), an on-demand sweeper run for test environments, and the removal of the confirmed `DeleteDesire` records that adapters keep (SWP-5) | `desire-owners` | `Add to ticket` | Comments on [HYPERFLEET-1865] and [HYPERFLEET-1840] | [HYPERFLEET-1840] criteria and technical notes; [HYPERFLEET-1865] criteria; [HYPERFLEET-1905] rollout note |
| G3 | [HYPERFLEET-1893] requires the suite to pass unchanged, and its criteria state none of the [harness changes](#g3-harness-changes). Without them, both suites fail on caller permissions, owner identity, and the 422 check before they test anything | Add the harness changes to the criteria of [HYPERFLEET-1893], and record the [Store Conformance over REST](#store-conformance-over-rest) table there | `desire-owners` | `Add to ticket` | Comment on [HYPERFLEET-1893] | [HYPERFLEET-1893] criteria; the line references in [G3 harness changes](#g3-harness-changes) |
| G4 | The criteria of [HYPERFLEET-1865] do not name OWN-1, OWN-4, CAS-3, CAS-9, CAS-10, or ERR-6. No ticket names a test Wristband signer, and the presubmit cannot create Wristbands without one, because it runs no gateway | Add to [HYPERFLEET-1865]: owner binding, 400 for an `owner` in a write body, 400 for a missing or invalid delete `version`, the full CAS-3 scenario including 400 for a missing or non-integer `version` on an ApplyDesire or DeleteDesire status write, the version-before-owner order, a bad identifier encoding (400) including names that contain colons, `kubeContent` that does not match the path (422), and a test Wristband signer that [HYPERFLEET-1893] also uses | `desire-owners` | `Add to ticket` | Comment on [HYPERFLEET-1865] | [HYPERFLEET-1865] criteria; [HYPERFLEET-1893] criteria |
| G5 | [HYPERFLEET-1829] states the rate limits, not the gateway's response bodies. The [HYPERFLEET-1825] Error Model criterion covers API responses, but these come from Envoy. The detailed design says that a rate-limit error carries `Retry-After` and the rate-limit problem type. The clients wait for `Retry-After` (ERR-4). ISO-1, ISO-2, and DIS-4 tell a gateway denial from an API denial by its body, and no ticket states that a gateway 401 or 403 has no Error Model body | Add to [HYPERFLEET-1829]: the 429 response shape, and 401 and 403 denials with no Error Model body, with gateway checks that prove them | `infra-owners` | `Add to ticket` | Comment on [HYPERFLEET-1829] | [HYPERFLEET-1829] criteria; [Error Responses](../desire-store-dd.md#error-responses) |
| G6 | No ticket states a test for DIS-5. [HYPERFLEET-1905] and [HYPERFLEET-1771] do not state it. The window exists when a resource has more than one required Adapter: the API hard-deletes only when every required Adapter reports `Finalized=True` at the current generation | Add the DIS-5 test. The expected result comes from the [PR #260 review](https://github.com/openshift-hyperfleet/architecture/pull/260#discussion_r4513767659) of the spike | `adapter-owners` | `Add to ticket` | Comment on [HYPERFLEET-1905] | [Desires Lost Mid-Deletion spike](../spike-desires-lost-mid-deletion.md); `hyperfleet-api` [`resource.go:922-927`](https://github.com/openshift-hyperfleet/hyperfleet-api/blob/a2f7b52e8aee02d0e4c29345d444bba8832f5177/pkg/services/resource.go#L922-L927) |
| G7 | The sweeper finds orphans by `resource_id` ([HYPERFLEET-1840]). The Adapter does not set it: no non-test file of `hyperfleet-adapter` sets `OriginID` at `0806e99`. [HYPERFLEET-1905] puts setting it out of scope, and [HYPERFLEET-1837] does not state it. SWP-4, SWP-5, and the [HYPERFLEET-1905] rollout wait for it | The Adapter sets `resource_id` on the desires that it writes | `adapter-owners` | `Add to ticket` | Comment on [HYPERFLEET-1837] | [HYPERFLEET-1840] criteria; [HYPERFLEET-1905] out of scope; `git grep OriginID` in `hyperfleet-adapter` `internal` and `pkg` |
| G8 | The detailed design says that Postgres accepts "connections only from the Desire Store API service". [ADR-0026](../../adrs/0026-co-located-service-databases-shared-postgres-isolation.md) puts the API, Desire Store, and Broker databases on one shared instance, so other services connect to the same instance. ISO-10 cannot test the rule as it is written | Change the database rule in [Network Boundary and Bypass Defense](../desire-store-dd.md#network-boundary-and-bypass-defense): only the Desire Store roles can connect to the `desire_store` database, through `CONNECT` grants and credentials | `architecture-approvers` | `Tracked` | [HYPERFLEET-1930] | [Network Boundary and Bypass Defense](../desire-store-dd.md#network-boundary-and-bypass-defense); [ADR-0026](../../adrs/0026-co-located-service-databases-shared-postgres-isolation.md) |
| G9 | The operator manages the signing-key Secrets ([HYPERFLEET-1831]). [HYPERFLEET-1756] puts "the trigger for a scheduled rotation" out of scope. No ticket defines a rotation trigger that a test can use, so KEY-4 cannot run | Define a signing-key rotation trigger that a test can use | `operator-owners` | `Tracked` | [HYPERFLEET-1931] | [HYPERFLEET-1831] criteria; [HYPERFLEET-1756] out of scope |
| G10 | The criteria of [HYPERFLEET-1865] cover HTTP handlers and Postgres persistence, not a database outage. ERR-3 runs against a fake store. The detailed design says only "503 when the API is degraded". It does not say that a lost database counts as degraded | Add ERR-7 to [HYPERFLEET-1865]: stop the Postgres container during the suite | `desire-owners` | `Add to ticket` | Comment on [HYPERFLEET-1865] | [HYPERFLEET-1865] criteria; [Status Codes](../desire-store-dd.md#status-codes) |
| G11 | The gateway serves one hostname per partition ([HYPERFLEET-1829]). No ticket says how test clients resolve these hostnames on kind or on the nightly cluster. Every row in which a remote Applier calls the gateway on Postgres-only or Prow GKE waits for it | Add hostname resolution to the test environments: [HYPERFLEET-1862] for kind, [HYPERFLEET-1870] for the nightly cluster | `infra-owners` | `Add to ticket` | Comments on [HYPERFLEET-1862] and [HYPERFLEET-1870] | Criteria of [HYPERFLEET-1829], [HYPERFLEET-1862], [HYPERFLEET-1864], and [HYPERFLEET-1870]; [Operator and Gateway Changes](../desire-store-dd.md#operator-and-gateway-changes) |
| G12 | The criteria of [HYPERFLEET-1829] and [HYPERFLEET-1863] state the gateway behaviors, not checks that prove them, and no ticket names their target. No HyperFleet Prow job runs the gateway checks: `make check-gateway-e2e` runs only on local kind. The [Coverage Durability](test-placement-strategy.md#coverage-durability) rule requires tests that gate merges, so the Gateway rows do not protect against regressions | Add the Desire Store gateway checks with a named target, and run them in a Prow job | `infra-owners` | `Tracked` | [HYPERFLEET-1932] | `check-gateway` appears in no file under `ci-operator/config/openshift-hyperfleet` or `ci-operator/step-registry/openshift-hyperfleet` in `openshift/release` at `82f95b4`; [HYPERFLEET-1829] and [HYPERFLEET-1863] criteria |
| G13 | The Postgres ingress NetworkPolicy admits only API pods. The Desire Store API uses the same instance ([ADR-0026](../../adrs/0026-co-located-service-databases-shared-postgres-isolation.md)), so it cannot reach Postgres in the test environments, and no ticket's criteria allow it | Allow the Desire Store API through the Postgres ingress policy: [HYPERFLEET-1862] for the Postgres-Only Environment, [HYPERFLEET-1828] for the deployed hub | `infra-owners` | `Add to ticket` | Comments on [HYPERFLEET-1828] and [HYPERFLEET-1862] | `hyperfleet-infra` [`helm/network-policies/values.yaml`](https://github.com/openshift-hyperfleet/hyperfleet-infra/blob/84415e8e65d865b1901304eeecdf6c0f9057fc83/helm/network-policies/values.yaml#L52-L66) |
| G14 | Supersede atomicity is not observable through the store interface. No call reads an ApplyDesire and a DeleteDesire together: the store has separate `ListApplyDesires` and `ListDeleteDesires` calls, and the suite checks only the state after the call (`suite.go:757-781`). A backend that inserts the DeleteDesire and deletes the ApplyDesire in two statements passes CAS-1 and CAS-8. The Adapter relies on the supersede being atomic (`hyperfleet-adapter` [`delete.go:14-15`](https://github.com/openshift-hyperfleet/hyperfleet-adapter/blob/0806e994d7171e9cf76865dca1ce639b7b485dc8/internal/desireclient/delete.go#L14-L15) at `0806e99`) | [HYPERFLEET-1671] tests it by fault injection between the two statements, or records that it is not tested | `desire-owners` | `Add to ticket` | Comment on [HYPERFLEET-1671] | `suite.go:757-781` and `pkg/desire/store.go` list methods at `f15f3f8` |
| G15 | The detailed design exempts the sweeper from the owner check ([Owner Binding](../desire-store-dd.md#owner-binding)), but the shared store checks the owner inside `CreateDeleteDesire`, `DeleteDeleteDesire`, and `DeleteReadDesire`. So the sweeper's DeleteDesire for an adapter-owned object returns `HYPERFLEET-CNF-004` and the orphan is not deleted (SWP-2, SWP-4), and the sweeper's removal of a confirmed DeleteDesire that an adapter owns fails the same way (SWP-5). The sweeper's removal of an adapter-owned ReadDesire also returns `HYPERFLEET-CNF-004`. A supersede leaves the adapter-owned ReadDesire in place, so an accepted sweeper DeleteDesire would put two owners on one object | [HYPERFLEET-1825] owns the store-interface change that lets the sweeper's exemption reach `CreateDeleteDesire`, `DeleteDeleteDesire`, and `DeleteReadDesire`, and states the ReadDesire's owner afterwards | `desire-owners` | `Add to ticket` | Comment on [HYPERFLEET-1825] | `pkg/desire/store/memory/store.go` `:186-188`, `:241-243`, `:310-312` and `pkg/desire/store/redis/redis.go` `:397-399`, `:447`, `:506-508` at `f15f3f8` |

### G3 Harness Changes

The harness for [HYPERFLEET-1893] needs these changes. Line numbers refer to `suite.go` at `f15f3f8`, as in [Store Conformance over REST](#store-conformance-over-rest).

- **One store that combines callers, for both suites.** The spec suite also writes status: it asserts that its store implements `desire.StatusStore` (:199, :281, :388, :801, :976). The status suite also creates desires: it asserts that its store implements `desire.SpecStore` (`seedSpecStore`, :70). The detailed design lets only the Adapter write desired state, and only the Applier write status ([Caller-to-Operation Matrix](../desire-store-dd.md#caller-to-operation-matrix)). So the store sends desired-state writes through the [HYPERFLEET-1837] HTTP store with Adapter credentials, and status writes through the [HYPERFLEET-1838] client with Applier credentials.
- **Two Adapter identities.** The owner-conflict cases switch from `owner-a` to `owner-b` in one store (:134, :488, :585). Over REST, the owner comes from the authenticated caller ([Owner Binding](../desire-store-dd.md#owner-binding)). So the harness sends the calls of each owner with the credentials of that owner.
- **An importable HTTP store.** The harness lives in `hyperfleet-desire-store`, so the [HYPERFLEET-1837] HTTP store must be importable from outside `hyperfleet-adapter`.
- **An empty store for each case.** Each case calls `newStore(t)` and expects an empty store. The Redis tests start a new store each time ([`newMiniStore`](https://github.com/openshift-hyperfleet/hyperfleet-applier/blob/f15f3f8630e15fc6f446edc535ccef6f370907e2/pkg/desire/store/redis/redis_test.go#L28)). The cases reuse the partition `cluster-a` (:86), so the harness empties the database on each `newStore(t)` call.
- **A read after each status write.** A status write returns no body, so the harness reads the desire after each status write and returns it. The production status client ([HYPERFLEET-1838]) does not need this read. The harness also reads each listed desire with GET, because lists carry no `generation`.
- **Valid fixtures.** See the ApplyDesire and `resource_id` rows in [Store Conformance over REST](#store-conformance-over-rest).

### Deferred or Excluded

| Deferred or excluded | Reason | Tracking |
| --- | --- | --- |
| Recurring stalled-watch test | The detailed design treats a stalled watch as an infrastructure failure, not a bound that the gateway enforces ([Token Lifetime and Revocation Behavior](../desire-store-dd.md#token-lifetime-and-revocation-behavior)). REV-2 measures it once | [HYPERFLEET-1822] |
| Shared-instance contention (PRF-2) as a release gate | The [HYPERFLEET-1861] seed matrix puts shared-instance contention outside the MVP gate. The [HYPERFLEET-1518] criteria and the [API on Postgres spike](../desire-store-api-postgres-spike.md) make shared capacity depend on a production-sized benchmark with API and desire load together | [HYPERFLEET-1672] |
| Tier2 spec for a Postgres outage behind a live API | ERR-7 tests this case with the real driver. [HYPERFLEET-1771] injects its fault at the Desire Store API, not at the database. A Tier2 spec that stops Postgres in a shared environment also stops the other databases on the instance ([ADR-0026](../../adrs/0026-co-located-service-databases-shared-postgres-isolation.md)) | [HYPERFLEET-1771] |
| Partner-provided Postgres instances | A separate operator contract | [HYPERFLEET-1710] |

## Coverage by Ticket

Each row lists the scenarios that name the ticket in the Owner column. A note in parentheses marks a ticket that does not build the test.

| Ticket | Rows |
| --- | --- |
| [HYPERFLEET-1671] | CAS-1, E2E-1 |
| [HYPERFLEET-1672] | PRF-2 |
| [HYPERFLEET-1771] | DIS-1, DIS-3 |
| [HYPERFLEET-1822] | REV-2 |
| [HYPERFLEET-1825] | ISO-3, ISO-8, OWN-2, CAS-2, CAS-8, ERR-3, ERR-8, KEY-1, KEY-2 |
| [HYPERFLEET-1828] | ISO-9, ISO-10, DEP-3 |
| [HYPERFLEET-1829] | ISO-4, ISO-5, CAS-6, ERR-5 |
| [HYPERFLEET-1831] | ISO-11, REV-5, KEY-3, SWP-3 |
| [HYPERFLEET-1832] | ISO-7 |
| [HYPERFLEET-1833] | ISO-1, ISO-2, ISO-12, ISO-13, REV-1, REV-3, REV-4, SWP-3 |
| [HYPERFLEET-1837] | OWN-2, CAS-4, CAS-5, ERR-1, ERR-4 |
| [HYPERFLEET-1838] | PAG-2, PAG-3, ERR-2, ERR-4 |
| [HYPERFLEET-1839] | PAG-4 |
| [HYPERFLEET-1840] | CAS-5, SWP-2, SWP-4, SWP-5 |
| [HYPERFLEET-1842] | PRF-1 |
| [HYPERFLEET-1862] | DEP-1, DEP-2, E2E-1 |
| [HYPERFLEET-1863] | ISO-6 |
| [HYPERFLEET-1864] | E2E-3 |
| [HYPERFLEET-1865] | ISO-3, OWN-1, OWN-3, OWN-4, CAS-2, CAS-3, CAS-9, CAS-10, PAG-1, ERR-6, ERR-7, KEY-1, SWP-1, SWP-2, DEP-3 |
| [HYPERFLEET-1866] | DEP-5 |
| [HYPERFLEET-1870] | E2E-2 |
| [HYPERFLEET-1893] | OWN-2, CAS-3, CAS-7, CAS-8 |
| [HYPERFLEET-1894] | PRF-3 |
| [HYPERFLEET-1903] | DEP-4 |
| [HYPERFLEET-1905] | DIS-5, DIS-3 (prerequisite) |
| [HYPERFLEET-1924] | DIS-4 |
| [HYPERFLEET-1925] | KEY-4 |

## References

- [Desire Store Detailed Design](../desire-store-dd.md): caller matrix, REST v1 contract, status codes, CAS, pagination, and failure behavior
- [Desire Store HLD](../desire-store-hld.md): system context
- [ADR-0022: API-mediated Desire Store access](../../adrs/0022-api-mediated-desire-store-access.md)
- [ADR-0026: Co-located service databases](../../adrs/0026-co-located-service-databases-shared-postgres-isolation.md)
- [ADR-0029: Desire Store authorization](../../adrs/0029-desire-store-authorization.md)
- [Desires Lost Mid-Deletion spike](../spike-desires-lost-mid-deletion.md) ([HYPERFLEET-1841]): delete confirmation and the sweeper's role in record cleanup
- [API on Postgres spike](../desire-store-api-postgres-spike.md)
- [Error Model](../../standards/error-model.md)
- [Makefile Conventions](../../standards/makefile-conventions.md)
- [Test Placement Strategy](test-placement-strategy.md)
- [Architecture PR #267](https://github.com/openshift-hyperfleet/architecture/pull/267): the delete-recovery and owner-binding rules in the detailed design ([HYPERFLEET-1871])
- [`hyperfleet-e2e` tier definitions](https://github.com/openshift-hyperfleet/hyperfleet-e2e/blob/5462cc781e1036401b03bf1fdf4931517990a1e0/test-design/README.md)

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
[HYPERFLEET-1918]: https://redhat.atlassian.net/browse/HYPERFLEET-1918
[HYPERFLEET-1920]: https://redhat.atlassian.net/browse/HYPERFLEET-1920
[HYPERFLEET-1924]: https://redhat.atlassian.net/browse/HYPERFLEET-1924
[HYPERFLEET-1925]: https://redhat.atlassian.net/browse/HYPERFLEET-1925
[HYPERFLEET-1930]: https://redhat.atlassian.net/browse/HYPERFLEET-1930
[HYPERFLEET-1931]: https://redhat.atlassian.net/browse/HYPERFLEET-1931
[HYPERFLEET-1932]: https://redhat.atlassian.net/browse/HYPERFLEET-1932
