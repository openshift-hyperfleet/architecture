---
Status: Active
Owner: HyperFleet QE Team
Last Updated: 2026-11-27
---

# Operator E2E Test Plan

**Jira**: [HYPERFLEET-1868](https://redhat.atlassian.net/browse/HYPERFLEET-1868)

**Epic**: [HYPERFLEET-1872](https://redhat.atlassian.net/browse/HYPERFLEET-1872)

## Table of Contents

- [Scope](#scope)
- [How to Read](#how-to-read)
- [Test Layers](#test-layers)
  - [Coverage Baseline](#coverage-baseline)
  - [Coverage Matrix](#coverage-matrix)
    - [Manager and Operands](#manager-and-operands)
    - [OLM Integration](#olm-integration)
    - [Upgrade](#upgrade)
    - [Day-One Integration Set](#day-one-integration-set)
  - [Full-Integration Installation Path](#full-integration-installation-path)
  - [Shared E2E Cutover to the Operator](#shared-e2e-cutover-to-the-operator)
  - [Upgrade Placement and Cadence](#upgrade-placement-and-cadence)
  - [Isolation, Cleanup, Diagnostics and Evidence](#isolation-cleanup-diagnostics-and-evidence)
  - [Implementation Decisions](#implementation-decisions)
  - [How This Plan Uses Existing Tickets](#how-this-plan-uses-existing-tickets)
  - [Gaps and Follow-Up Work](#gaps-and-follow-up-work)
    - [Coverage Matrix Changes](#coverage-matrix-changes)
  - [References](#references)

## Scope

This plan places the OP-01 to OP-20 cases from HYPERFLEET-1868 in the appropriate suites and records the coverage baseline, owners, required evidence and follow-ups.

The owning tickets track implementation progress, scope, estimates, cadence and sprint commitments. [How This Plan Uses Existing Tickets](#how-this-plan-uses-existing-tickets)

The operand epics own standalone tests for adapters, applier and gateway ([HYPERFLEET-1666](https://redhat.atlassian.net/browse/HYPERFLEET-1666), [HYPERFLEET-1667](https://redhat.atlassian.net/browse/HYPERFLEET-1667), [HYPERFLEET-1530](https://redhat.atlassian.net/browse/HYPERFLEET-1530)). The [Sentinel epic](https://redhat.atlassian.net/browse/HYPERFLEET-1665) owns Sentinel operand coverage through HYPERFLEET-1869. OCI-specific coverage ([HYPERFLEET-1543](https://redhat.atlassian.net/browse/HYPERFLEET-1543)) and load testing are out of scope.

## How to Read

Scenario placement follows the [Test Placement Strategy](test-placement-strategy.md): test at the lowest layer that catches the failure. Envtest runs an API server without controllers or a kubelet, so it cannot prove Pod readiness or garbage collection, nor that a Deployment actually rolls out. A repository-local row exists only when one of those is the failure mode. An integration row exists only when the failure needs catalog resolution, the shipped bundle, or the rest of the deployed HyperFleet stack.

**Terms.** An OLM bundle contains the CSV. `cloud-capi` is the HyperFleet bundle selected by `spec.bundle`. **Kind mode** deploys a locally built manager. **CI mode** installs the PR bundle through OLM. [Glossary](../glossary.md)

`Status` describes each case at the planning baseline.

| Status | Meaning |
|---|---|
| `existing` | A test on `main` covered the assertion |
| `extend` | Add the stated assertion to an existing test |
| `new` | Add a test for the stated assertion |
| `envtest` | Unit or envtest coverage proves the failure mode. No E2E test is planned |
| `deferred` | Not scheduled. The row states why and names the ticket that owns it |
| `Gn` or `Dn` after a status | Gap `Gn` or decision `Dn` affects the row |

**Cadence values:**

| Cadence | Meaning |
|---|---|
| PR | Prow presubmit on the owning repository |
| nightly | Prow periodic against artifacts built from `main` |
| release gate | Runs against a release candidate before promotion to the stable channel |

## Test Layers

| Layer | Repository | Installation method | Proves | Does not prove | Local entry point | CI entry point | Cadence | Owning ticket | Required evidence |
|---|---|---|---|---|---|---|---|---|---|
| Unit and envtest | hyperfleet-operator | None; envtest control plane | Rendering, validation, condition aggregation, rollout scoping, drift and no-op reconciles against a real API server | Pod readiness, rollouts, garbage collection, shipped images | `make test` | Prow `unit` (required) | PR | Existing; no change | Green `unit` job on the PR |
| Bundle validation | hyperfleet-operator | None; image build only | CSV, bundle manifests and related images pass the `operator-sdk bundle validate` and related-images steps in `bundle.Dockerfile` | That OLM installs the bundle | `make bundle-build KUSTOMIZE_VARIANT=config/manifests/prod VALIDATE_RELATED_IMAGES=true` | `presubmits-ci-bundle-hyperfleet-operator-bundle`, which builds `bundle.Dockerfile` on every PR | PR | HYPERFLEET-1895 | Green bundle build job |
| Repository-local E2E | hyperfleet-operator | Kind mode uses a local image and `make install deploy` with kustomize. CI installs the PR bundle with `operator-sdk run bundle` on an AWS OpenShift claim | Manager and operand RBAC, readiness, migration and reconciliation on a real cluster | Catalog and channel resolution, shared journeys, upgrades, and OLM installation in Kind mode | `make test-e2e-kind KIND_CLUSTER=<name>` | Proposed `presubmits-e2e` job runs `make test-e2e-ci` | PR | HYPERFLEET-1707, HYPERFLEET-1869, FU1, FU2, FU8 | JUnit report and failure diagnostics |
| Full integration | hyperfleet-e2e, with Prow configuration in openshift/release | OLM classic catalog and a scenario-specific `HyperFleetConfig` | Catalog resolution, reconciliation with OLM-granted RBAC, pinned operand images, gateway authentication after G5, and OLM uninstall. After cutover, also covers shared journeys | Upgrades | `./bin/hyperfleet-e2e test` with the [day-one filters](#day-one-integration-set) | Operator periodic (FU7a) and tier nightlies after FU6a and FU6b | nightly | FU3 to FU7a | JUnit report, OLM object dumps, CSV and InstallPlan status, Operator and operand logs |
| Upgrade | hyperfleet-operator `test/e2e/upgrade` | OLM classic with manual InstallPlan approval from N-1 to N in one catalog on an isolated cluster | CSV replacement succeeds, `HyperFleetConfig` stays usable, operands converge to N's declared images, rollouts happen only where an input changed | Downgrades are out of scope | `make test-e2e-upgrade` | Proposed on-demand `rc-olm-upgrade` job and [per-change CI](#upgrade-placement-and-cadence) | Every relevant change. D2 proposes an additional release gate | HYPERFLEET-1413, FU7b for the proposed release gate | Run report with N-1 and N bundle digests, catalog digest, condition history and workload history |

## Coverage Baseline

| Capability | Baseline | Evidence or follow-up |
|---|---|---|
| Unit, envtest and bundle validation | Demonstrated | Prow runs `lint` and `unit`, builds the Operator image and validates the bundle on every PR. [Operator CI config](https://github.com/openshift/release/blob/main/ci-operator/config/openshift-hyperfleet/hyperfleet-operator/openshift-hyperfleet-hyperfleet-operator-main.yaml) · [Bundle presubmit config](https://github.com/openshift/release/blob/main/ci-operator/config/openshift-hyperfleet/hyperfleet-operator/openshift-hyperfleet-hyperfleet-operator-main__presubmits.yaml) |
| Repository-local E2E in Kind | Demonstrated | `make test-e2e-kind` runs the tests listed below, including the Sentinel cases from HYPERFLEET-1869. [Operator PR #282](https://github.com/openshift-hyperfleet/hyperfleet-operator/pull/282) |
| Classic OLM install from a PR bundle | Demonstrated | `presubmits-e2e-in-cluster-install` proved PR bundle installation with `operator-sdk run bundle` on an AWS OpenShift 4.22 claim. [Prow PR #88745](https://github.com/openshift/release/pull/88745) |
| Kind in Prow | Prototypes | The investigations explored nested Podman and GCE VMs. G1 covers runner qualification. [Prow PR #88436](https://github.com/openshift/release/pull/88436) · [Prow PR #88494](https://github.com/openshift/release/pull/88494) |
| Repository-local E2E in Prow | Follow-up | The HYPERFLEET-1707 design runs `make test-e2e-ci` in `presubmits-e2e` and skips changes limited to `config/manifests/prod/kustomization.yaml`, including operand image pin updates. G1 covers the Kind-only assertions. [Prow PR #89110](https://github.com/openshift/release/pull/89110) · [Operator PR #284](https://github.com/openshift-hyperfleet/hyperfleet-operator/pull/284) |
| Catalog-based integration and shared nightlies | Follow-up | FU3, FU4, FU5 and FU7a cover the classic OLM installation path and integration periodic. FU6a and FU6b cover the shared nightly cutover after D3. |
| OLM v1 integration | Deferred | FU9 depends on the HYPERFLEET-1616 Part 2 findings and D1. |
| Upgrade harness | Demonstrated | One live GKE run used test-only `0.1.0` and `0.2.0-rc1` bundles. G3 and G6 cover release qualification. [Operator PR #268](https://github.com/openshift-hyperfleet/hyperfleet-operator/pull/268) |
| On-demand upgrade job | Follow-up | `rc-olm-upgrade` is the design for on-demand execution. G3 and G6 cover qualification against published RCs. [Prow PR #89116](https://github.com/openshift/release/pull/89116) |
| Per-change upgrade CI and release gate | Follow-up | Per-change CI is required by HYPERFLEET-1413. D2 and FU7b cover the proposed release gate. |

The repository-local suite provisions PostgreSQL and RabbitMQ and applies one `cloud-capi` `HyperFleetConfig` in both modes. [Suite](https://github.com/openshift-hyperfleet/hyperfleet-operator/blob/main/test/e2e/e2e_test.go) · [Fixture](https://github.com/openshift-hyperfleet/hyperfleet-operator/blob/main/test/e2e/hyperfleetconfig.yaml)

| Test | Row | Ticket |
|---|---|---|
| `should run successfully` | OP-01 | HYPERFLEET-1707 |
| `should ensure the metrics endpoint is serving metrics`, `should serve metrics over verified TLS with bearer authentication` | OP-02 | HYPERFLEET-1707 |
| `should have the RBAC the operator needs to manage operands` | OP-03 | HYPERFLEET-1707 |
| `should create every expected API operand` | OP-04 | HYPERFLEET-1707 |
| `should migrate a fresh database before the API becomes ready` | OP-06 | HYPERFLEET-1707 |
| `should create every expected Sentinel operand per cloud-capi entity`, `should render the expected config.yaml for each Sentinel`, `should render each Sentinel broker.yaml without rabbitmq creds` | OP-05 | HYPERFLEET-1869 |
| `should run each Sentinel ready against the broker without crashloops` | OP-09a | HYPERFLEET-1869 |
| `restricts management-cluster registration to explicitly delegated Hub administrators` | None; no seed case. Denials run in Kind mode only (G1) | HYPERFLEET-1707 |

`make test` covers operand owner references (OP-04, OP-05), per-component Secret rotation (OP-11), missing Secret conditions (OP-12), drift correction (OP-13) and stable transition times on a no-op reconcile (OP-14). [Controller tests](https://github.com/openshift-hyperfleet/hyperfleet-operator/blob/main/internal/controller/hyperfleetconfig_controller_test.go)

## Coverage Matrix

Cases keep their seed IDs. The seed assigned OP-01 to OP-16 to GKE. Repository-local E2E covers the assertions that need only a real kubelet and controllers. The [Coverage Matrix Changes](#coverage-matrix-changes) record the revised placement, splits, deferred or dropped cases, and the additions OP-21 and OP-22.

Rows inherit repository, installation method, entry points, cadence and evidence from the [Test Layers](#test-layers) table. Each row states its assertions. OP-22 uses OLM v1. OP-09b runs in `tier0-nightly` on the Step 2 deployment.

Every `hyperfleet-e2e` spec carries a tier label. The nightly jobs select `tier0`, `tier1 && !perf`, or `tier2`. The `operator` label selects the OLM integration specs for the dedicated periodic. The tier nightlies and RC job exclude those specs (FU4).

### Manager and Operands

Layer: repository-local E2E. Rows run in both modes unless the row says otherwise.

| ID | Case and assertion | Owner | Status |
|---|---|---|---|
| OP-01 | Manager installs: one non-terminating manager Pod `Running`; the leader-election Lease names that Pod; restart count stays 0 for 60 s | FU1 | extend |
| OP-02 | Metrics: plain endpoint serves controller-runtime and HyperFleet metrics; in Kind mode only, the TLS endpoint rejects a missing, tampered or untrusted-CA request | HYPERFLEET-1707 | existing, G1 |
| OP-03 | RBAC scope: operand verbs allowed in the Operator namespace; cluster-scoped `HyperFleetConfig` access; in Kind mode only, for Deployments, Services, ServiceAccounts, ConfigMaps, Roles and RoleBindings, verbs denied in other namespaces and no `delete`. NetworkPolicies are excluded: the manager may delete them | HYPERFLEET-1707 | existing, G1 |
| OP-04 | API operands: Deployment, Service, ServiceAccount, ConfigMap, Role and RoleBinding exist. Envtest proves ownership and OP-15 proves garbage collection, so no E2E ownership assertion is added | HYPERFLEET-1707 | existing |
| OP-05 | Sentinel operands: for each `cloud-capi` entity, Deployment, ServiceAccount, Sentinel ConfigMap, broker ConfigMap and NetworkPolicy exist. Each `config.yaml` carries the API `base_url`, `resource_type`, broker topic and auth block | HYPERFLEET-1869 | existing |
| OP-06 | Migration before readiness: API Deployment Available only after the migration; an API Pod restart re-runs it idempotently | HYPERFLEET-1707 | existing |
| OP-07 | Conditions on a healthy install: `Available=True` with `DeploymentAvailable`, `Progressing=False` with `RolloutComplete`, `Degraded=False` with `AsExpected`; `status.observedGeneration` and each condition's `observedGeneration` equal `metadata.generation` | FU1 | new |
| OP-08 | Through the API Service, `/readyz`, `/healthz` and a cluster list return HTTP 200. When API JWT validation is enabled, the HYPERFLEET-1950 Kind test calls the API directly and checks that it accepts a valid, scoped Wristband and rejects one for the wrong tenant or with a required dimension missing. | FU1, HYPERFLEET-1950 for Wristband validation | new |
| OP-09a | Sentinels run: every Sentinel Pod `Running` with zero restarts for 2 minutes against the RabbitMQ fixture; no broker connection error in the logs | FU8, under HYPERFLEET-1665 | extend |
| OP-10 | Spec change rolls out: point `spec.api.database.secretRef.name` at a copy of the database Secret; generation increments; `Progressing=True` observed, then `Available=True` with `observedGeneration` advanced; API Pod template hash changed; Sentinel Deployments keep their template hash | FU2 | new |
| OP-12 | Missing Secret degrades and recovers: delete the database Secret; `Degraded=True` with `ReferencedSecretMissing` and a message that is identical across two reads 30 s apart; recreate it; `Degraded=False` and the API Available. The API is expected to roll, because its config hash includes the Secret's `resourceVersion`; Sentinel Deployments keep their template hash | FU2 | new |
| OP-13 | Drift self-heals. Delete the API Deployment and one Sentinel ConfigMap out of band. Verify both return with new UIDs within 2 minutes of deletion and the replacement Deployment becomes Available within 2 minutes of recreation. | FU2 | new |
| OP-14 | After deleting the manager Pod and waiting for the new leader to reconcile, verify that operand template hashes, operand count and the full `status.conditions` objects keyed by type are unchanged. | FU2 | new |
| OP-15 | Delete CR cleans up: delete `HyperFleetConfig/cluster`; every operand is garbage collected; the user-created Secrets remain; no other object owned by the CR remains in the namespace | FU2 | new |
| OP-16 | TLS advertisement: with `spec.api.tls` set, the API Service advertises the HTTPS port and the API serves TLS; the rendered Sentinel `base_url` uses `https`. A Sentinel connection over HTTPS waits for custom CA support | FU2; live Sentinel connection deferred to HYPERFLEET-1678 | new, G4 |

OP-11 has no row. See [Coverage Matrix Changes](#coverage-matrix-changes).

### OLM Integration

The classic OLM rows run in the full-integration layer with `tier0` and `operator` labels. OP-08b also carries `auth`. FU5 depends on FU3 and FU4. OP-22 has a proposed tier of `tier0` when D1 schedules it.

| ID | Case and assertion | Owner | Status |
|---|---|---|---|
| OP-17 | Verify the CatalogSource is `READY` and the Subscription references that source and the package and channel recorded by the job. Verify the InstallPlan is approved and `status.installedCSV` matches the expected CSV in phase `Succeeded`. Verify the `HyperFleetConfig` and `ManagementClusterRegistration` CRDs exist and the OperatorGroup selects all namespaces. [CSV `installModes`](https://github.com/openshift-hyperfleet/hyperfleet-operator/blob/main/config/manifests/bases/hyperfleet-operator.clusterserviceversion.yaml) | FU5 | new, G2 |
| OP-18 | CSV permissions sufficient: the OLM-installed manager reaches the OP-07 conditions with no `forbidden` entry in its log; the CSV `permissions` and `clusterPermissions` match the RBAC generated from `config/rbac` | FU5 | new |
| OP-19 | Image pinning: every operand container image equals a CSV `spec.relatedImages` digest; no operand uses a tag | FU5 | new |
| OP-21 | Run `operator-sdk scorecard` on the bundle image digest selected for OP-17 and verify that its packaged Scorecard tests pass. HYPERFLEET-1895 assigns this check to an OLM job. [Operator SDK Scorecard](https://sdk.operatorframework.io/docs/testing-operators/scorecard/#command-args) | FU5 | new |
| OP-08b | Verify gateway authentication at the [day-one endpoint](#day-one-integration-set). A cluster list with the E2E human token returns HTTP 200. A request without a token or with an invalid signature returns HTTP 401. [ADR-0037](../../adrs/0037-e2e-human-and-machine-identities.md) | FU5 | new, G5 |
| OP-15b | Record the manager Deployment and the namespaced and cluster-scoped RBAC that OLM derives from the installed CSV. Delete `HyperFleetConfig/cluster`, wait for operand garbage collection, then delete the Subscription and CSV. Verify the manager Deployment, recorded RBAC, CSV and InstallPlan are gone and the referenced Secrets and owned CRDs remain. Run this case last. | FU5 | new |
| OP-22 | Install the Operator in `AllNamespaces` mode using a `ClusterExtension` that selects the package from a `ClusterCatalog`. Verify the OP-07 conditions and the manager's RBAC against the bundle, and check its logs for authorization failures. | FU9. HYPERFLEET-1616 Part 2 provides the prototype evidence required by D1. | deferred, D1 |

### Upgrade

OP-20 runs in the Operator's upgrade suite and has no hyperfleet-e2e tier. Cadence and the proposed release gate: [Upgrade Placement and Cadence](#upgrade-placement-and-cadence).

| ID | Case and assertion | Owner | Status |
|---|---|---|---|
| OP-20 | With `HyperFleetConfig` Available on release N-1, approve N's InstallPlan from the same Subscription. Verify CSV N reaches `Succeeded`, the API matches N's declared image, `Available` stays within the scenario's `maxUnavailable` budget, and config hashes change exactly when their inputs change. Verify the CR and API data survive and no operand is orphaned. For the API image transition, require `Progressing` to go True then False and API migration to succeed. | HYPERFLEET-1413 | existing, G3, G6. Proposed release gate also depends on D2 |

### Day-One Integration Set

The periodic covers install, reconciliation, readiness, image pinning, Scorecard and uninstall (OP-17, OP-18, OP-19, OP-21, OP-15b). Day-one acceptance includes OP-08b before uninstall once a G5 route is ready.

- **Before G5.** Run once with `HYPERFLEET_AUTH_MODE=NONE` and `--label-filter='operator && !auth'`. Point `HYPERFLEET_API_URL` at a loopback port-forward to the `hyperfleet-api` ClusterIP Service.
- **After G5.** Switch to one `--label-filter=operator` invocation via a loopback port-forward to `hyperfleet-gateway`. Use `EDGE` with the Helm gateway while API JWT validation is off and `EDGE+API` when the API validates Wristbands.

FU4 supplies the scenario fixtures with a database Secret reference and test issuer configuration. The `NONE` fixture leaves API TLS off (G4). FU3 supplies the gateway and mock issuer for OP-08b.

## Full-Integration Installation Path

| Item | Installation requirements |
|---|---|
| OLM classic | Create the CatalogSource, OperatorGroup and Subscription. Approve the InstallPlan manually. Apply the scenario's `HyperFleetConfig` after the CSV succeeds. |
| OLM v1 | Deferred to D1. OP-22 will qualify the bundle using `ClusterCatalog`, `ClusterExtension` and an installer ServiceAccount. [OpenShift 4.22 cluster extension documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/extensions/cluster-extensions) |
| Install modes | The bundle supports only `AllNamespaces`. `OwnNamespace`, `SingleNamespace` and `MultiNamespace` are `supported: false`. |
| Catalog and bundle sources | Nightlies install from the job-built test catalog and bundle from a pinned Operator `main` commit (G2). Release qualification uses Konflux-published RC artifacts (G3). Reference catalogs by digest. |
| Cluster requirements | Kubernetes 1.27 or later, access to the artifact registries, PostgreSQL and a Sentinel broker. Use one Operator per job cluster because `HyperFleetConfig/cluster` is a singleton. Apply differing fixtures sequentially or on separate clusters. [Operator OLM guide](https://github.com/openshift-hyperfleet/hyperfleet-operator/blob/main/docs/olm.md) |

| Mode | Use | Limits |
|---|---|---|
| A. OpenShift cluster claim | Day-one path informed by HYPERFLEET-1616. Install from the nightly test catalog. | Availability depends on AWS pool capacity. |
| B. Ephemeral GKE via hyperfleet-infra Terraform | Fallback when OpenShift claims are unavailable. Use `operator-sdk olm install`, then the Konflux catalog for release artifacts or the test catalog for a nightly. | Report results as GKE with upstream OLM. OpenShift SCC coverage requires mode A. |

## Shared E2E Cutover to the Operator

The shared nightlies and RC job use Helm on a shared GKE cluster. Operator-mode jobs need a cluster per run and separate PostgreSQL provisioning. D3 resolves the mismatch between `cloud-capi` and the shared suite's fixture entities and adapter names. [Helmfile](https://github.com/openshift-hyperfleet/hyperfleet-infra/blob/main/helmfile/helmfile.yaml.gotmpl) · [Cloud CAPI bundle](https://github.com/openshift-hyperfleet/hyperfleet-operator/blob/main/internal/bundle/bundle.go)

- **Step 1, Operator integration.** Run the [day-one set](#day-one-integration-set) on an OpenShift claim with PostgreSQL and RabbitMQ.
- **Step 2, shared nightly cutover.** After Step 1 is stable and D3, G5, G7 and HYPERFLEET-1950 are resolved, replace the Helm-managed API and Sentinels with Operator-managed operands on ephemeral GKE. Use Pub/Sub. Keep the Helm adapters, gateway, issuer and Applier in the Operator's per-job namespace so the adapters and Sentinels share topics.

After Step 2, `tier0-nightly` exercises the following full-integration case through the existing cluster creation journey.

| ID | Case and assertion | Tier | Owner | Status |
|---|---|---|---|---|
| OP-09b | Create a cluster through the API on the Operator-managed stack. Verify the D3 journey reaches `Reconciled=True` as evidence that Sentinel publishing and adapter processing completed. | `tier0` | FU6a | new, D3, G7 |

## Upgrade Placement and Cadence

OP-20 reuses the HYPERFLEET-1413 harness, which must run in CI on every relevant change. Each run needs qualified N-1 and N bundle digests and a digest-pinned catalog in which N directly replaces N-1. Published artifact qualification depends on G3 and G6.

**Per-change CI.** Add a presubmit for changes to Operator reconciliation, rendering or dependencies, owned CRDs, production operand pins, bundle or catalog inputs, or the harness. Qualify the latest stable bundle in the target major as N-1. Build the candidate Operator image and newer RC bundle from the tested revision.

The scenario declares whether the API digest changes and which operands roll. Extend the harness to accept equal digests for scenarios that expect them. When templates change, verify that only the expected workloads roll and `Progressing` goes True then False. Check migration when the API rolls. For unchanged templates, require `Available=True`, `Progressing=False`, stable hashes and workload identities, and zero operand rollouts.

**Proposed release gate (D2).** If the release owner adopts the gate, run `rc-olm-upgrade` through Gangway on an OpenShift claim. Use the newest stable bundle in the candidate's major and the published RC. Pin both bundle digests, catalog digest, channel, Operator commit, qualification commit and directory in `hyperfleet-release`, and PostgreSQL and RabbitMQ image digests in the release record.

## Isolation, Cleanup, Diagnostics and Evidence

| Layer | Isolation | Cleanup after success | Cleanup after failure | Diagnostics on failure | Evidence for the owning PR |
|---|---|---|---|---|---|
| Unit and envtest | Process-local envtest control plane | Automatic | Automatic | `go test` output | Green Prow `unit` |
| Repository-local E2E | One disposable Kind cluster or OpenShift claim per run | Clean up the CR and suite resources. Kind also removes the Operator, its CRDs and namespace. Cluster teardown clears remaining fixtures. | Attempt suite cleanup. Prow retires the claim. Use `make destroy-kind-cluster` after local debugging. | Manager logs, events and Pod descriptions. FU1 adds operand and dependency logs and `HyperFleetConfig` YAML with status. | JUnit report and diagnostics in Prow. Record the local command and cluster name in the PR. |
| Full integration | One cluster per job, one Operator per cluster, resources labelled with the E2E run ID | OP-15b uninstall, then cluster deletion | Cluster deletion in a post step that always runs, using Terraform destroy for the GKE fallback | CatalogSource, Subscription, InstallPlan and CSV YAML, OLM catalog-operator and olm-operator logs, Operator and operand logs, `HyperFleetConfig` status and namespace events | JUnit report, OLM dumps and bundle selection evidence from G2 in Prow artifacts |
| Upgrade | Isolated cluster with a cleanup receipt. The Prow design uses an AWS OpenShift claim. | Remove resources from the receipt. FU7b adds always-run teardown for a retained stack. | Attempt receipt-based cleanup. Run `make cleanup-e2e-upgrade` if needed. Prow retires the claim. | OLM and Pod summaries, Pod logs, CSV recovery, and condition and workload history | Bundle and catalog digests, history and per-assertion results |

## Implementation Decisions

| ID | Decision | Options | Blocks |
|---|---|---|---|
| D1 | When does OLM v1 coverage become required? Use classic OLM for day one. Schedule OP-22 with ClusterCatalog prototype evidence from HYPERFLEET-1616 Part 2. | Before or after the first stable release, through FU9 | Scheduling of OP-22 |
| D2 | Should OP-20 gate promotion to the stable channel? | Require `rc-olm-upgrade` with the published RC artifacts before promotion, or rely on per-change CI. | Release-gate wiring in FU7b |
| D3 | How the shared suite's fixture entities and test adapters run on an Operator-managed API | A: a test bundle or an entity and required-adapter override in `HyperFleetConfig`; B: the shared suite moves to the `cloud-capi` entities and adapter names; C: Operator mode runs only the journeys that `cloud-capi` supports | OP-09b, FU6a, FU6b |

If D2 adds the release gate, two further decisions apply.

- **Tier0 follow-on.** The release, Operator and E2E owners decide whether `hyperfleet-e2e` should run tier0 journeys on the retained installation after OP-20, with the prerequisites in FU7b.
- **Ineligible release pairs.** If a first release or a new major has no eligible predecessor, record why OP-20 cannot run and require the release owner's sign-off to promote. Apply the same policy to unchanged API digests until the same-digest scenarios are qualified.

## How This Plan Uses Existing Tickets

| Ticket | Role in this plan |
|---|---|
| [HYPERFLEET-1707](https://redhat.atlassian.net/browse/HYPERFLEET-1707) | Owns CI for the repository-local tests, including the decision in G1 about the Kind-only checks. |
| [HYPERFLEET-1869](https://redhat.atlassian.net/browse/HYPERFLEET-1869) | Delivered OP-05 and the Sentinel readiness check used in OP-09a. FU8 adds runtime assertions under the Sentinel epic. |
| [HYPERFLEET-1616](https://redhat.atlassian.net/browse/HYPERFLEET-1616) | The [spike report](../spike-olm-install-testing-prow.md) recommends OpenShift cluster claims for classic OLM, which FU3 uses. FU9 depends on the Part 2 findings and D1 for OLM v1. |
| [HYPERFLEET-1413](https://redhat.atlassian.net/browse/HYPERFLEET-1413) | Provides the upgrade harness reused by OP-20. Owns G6 harness qualification and CI on every relevant change. |
| [HYPERFLEET-1895](https://redhat.atlassian.net/browse/HYPERFLEET-1895) | Delivered bundle validation in presubmit. FU5 includes the proposed Scorecard test (OP-21). |
| [HYPERFLEET-1846](https://redhat.atlassian.net/browse/HYPERFLEET-1846) | Resolved the dependency for Sentinel coverage in OP-05 and OP-09. |

## Gaps and Follow-Up Work

| ID | Gap and impact | Action | Tracking |
|---|---|---|---|
| G1 | HYPERFLEET-1707 requires a Kind presubmit that verifies cross-namespace RBAC denial. The OLM presubmit leaves secure metrics and the operand and registration RBAC denials to Kind because OLM manages the Deployment and grants broader RBAC. | Qualify Kind setup and cleanup in Prow and run those checks, or record revised criteria approved by the HYPERFLEET-1707 owner. | HYPERFLEET-1707 |
| G2 | The nightly catalog must resolve to the bundle built from its pinned Operator `main` commit. | Use `catalog/konflux-template.yaml` with the built bundle's digest. Validate the `hyperfleet-operator` package and `stable` channel entry against the bundle's CSV name and digest. Record the commit, digests, package, channel and expected CSV for OP-17. | FU3 |
| G3 | A published N-1 to N pair needs a release catalog with both bundle digests and the upgrade edge. [Tag pipeline](https://github.com/openshift-hyperfleet/hyperfleet-operator/blob/main/.tekton/hyperfleet-operator-fbc-tag.yaml) | Supply the release template and plan, then publish the catalog for the qualified pair. | [HYPERFLEET-1773](https://redhat.atlassian.net/browse/HYPERFLEET-1773), [HYPERFLEET-1885](https://redhat.atlassian.net/browse/HYPERFLEET-1885) |
| G4 | Sentinel cannot trust a custom CA, so a Sentinel to API connection over HTTPS fails on a self-signed certificate | Add custom CA support; then extend OP-16 with a live connection | [HYPERFLEET-1678](https://redhat.atlassian.net/browse/HYPERFLEET-1678) |
| G5 | OP-08b needs a gateway route. The Helm gateway requires verified HTTPS to the API. [Envoy config](https://github.com/openshift-hyperfleet/hyperfleet-infra/blob/main/helm/hyperfleet-gateway/templates/configmap.yaml) | For Helm `EDGE`, configure `spec.api.tls` with a gateway-issued certificate and install the gateway in the Operator namespace once Sentinel supports custom CA trust (G4). For Operator-managed `EDGE+API`, qualify API Wristband validation and Sentinel routing (G7). | [HYPERFLEET-1534](https://redhat.atlassian.net/browse/HYPERFLEET-1534), HYPERFLEET-1678, [HYPERFLEET-1950](https://redhat.atlassian.net/browse/HYPERFLEET-1950) |
| G6 | The baseline harness expects one owned CRD and the CSV declares two. The original `HyperFleetConfig` must survive the upgrade. [Authentication change](https://github.com/openshift-hyperfleet/hyperfleet-operator/pull/283) · [Artifact checks](https://github.com/openshift-hyperfleet/hyperfleet-operator/blob/main/test/e2e/upgrade/catalog.go) | Include `ManagementClusterRegistration` in validation and the cleanup receipt. Qualify a final N-1 that supports `spec.authentication` and a newer same-major RC. Require different API image digests for the API image-transition case. | HYPERFLEET-1413 |
| G7 | Operator-managed Sentinels send ServiceAccount tokens as `Bearer`. Direct calls with those tokens fail when the API requires Wristbands. [Sentinel config](https://github.com/openshift-hyperfleet/hyperfleet-operator/blob/main/internal/component/sentinel/config.go) | When enabling API Wristband validation, route Sentinel calls through the gateway with the `ServiceAccount` scheme and allowlist the Operator-created Sentinel ServiceAccounts. [Gateway auth policy](https://github.com/openshift-hyperfleet/hyperfleet-infra/blob/main/helm/hyperfleet-gateway/templates/authconfig.yaml) | HYPERFLEET-1950, HYPERFLEET-1534 |

**Proposed follow-up tickets.** These do not overlap with each other or with the existing tickets.

| ID | Scope | Rows | Depends on | Repository | Estimate |
|---|---|---|---|---|---|
| FU1 | Repository-local startup, status and API scenarios. Add operand and dependency diagnostics and JUnit reports for both modes. Archive the CI evidence in Prow. | OP-01, OP-07, OP-08 | None | hyperfleet-operator | 3 |
| FU2 | Repository-local lifecycle and resilience scenarios | OP-10, OP-12, OP-13, OP-14, OP-15, OP-16 | None | hyperfleet-operator | 5 |
| FU3 | Build the nightly artifacts (G2) and automate classic OLM install and failure diagnostics on a job cluster. Provision PostgreSQL, RabbitMQ and fixture Secrets for the Operator periodic. Add the mock issuer and gateway for OP-08b. [Installation path](#full-integration-installation-path) | Enables OP-17, OP-18, OP-19, OP-21, OP-08b, OP-15b | G5 for OP-08b | openshift/release step registry, hyperfleet-infra | 8 |
| FU4 | Add OLM helpers, scenario fixtures, readiness waits and diagnostics. Replace the Helm startup entity check for Operator installs. Include `operator-sdk` in the E2E image for OP-21. Add the `operator` label and exclude it from tier nightly and RC runs. [Suite startup check](https://github.com/openshift-hyperfleet/hyperfleet-e2e/blob/main/pkg/e2e/suite.go) | Enables FU5 and FU6b | None | hyperfleet-e2e, openshift/release | 3 |
| FU5 | Operator install scenarios in hyperfleet-e2e | OP-17, OP-18, OP-19, OP-21, OP-08b, OP-15b | FU3, FU4; G5 for OP-08b | hyperfleet-e2e | 5 |
| FU6a | Reuse FU3 on ephemeral GKE. Update Helm dependencies and network policy selectors. Provision PostgreSQL, its Secrets and the `EDGE+API` route. Create namespace-derived Pub/Sub topics and attach the adapters' subscriptions. Grant Sentinel publish and adapter pull access. Always remove subscriptions before topics. | OP-09b and the existing tier journeys | FU3, D3, G5, G7, HYPERFLEET-1950 | hyperfleet-infra, openshift/release | 8 |
| FU6b | Use `HyperFleetConfig` patches for supported API reconfiguration. Update Sentinel selectors and scale checks for Operator reconciliation. Exclude specs that depend on changes the Operator reverts. | Existing tier1 and tier2 specs | FU4, D3 | hyperfleet-e2e | 5 |
| FU7a | Add the Operator integration periodic with the filters, auth modes and port-forwards in the [day-one integration set](#day-one-integration-set). | OP-17, OP-18, OP-19, OP-21, OP-08b, OP-15b in CI | FU3, FU5, G5 for the authenticated run | openshift/release | 3 |
| FU7b | Wire the proposed release gate and verify the exact candidate's result. If approved, run tier0 on the retained stack with always-run cleanup. [Upgrade Placement and Cadence](#upgrade-placement-and-cadence) | OP-20 as an additional release gate | D2, G3, G6 and the Prow upgrade job. The tier0 run also needs FU6b, D3 and G5, plus the FU6a gateway, issuer and adapters on the retained cluster. | openshift/release, hyperfleet-release | 3 |
| FU8 | Sentinel runtime assertions, under the Sentinel epic HYPERFLEET-1665: zero restarts for 2 minutes and no broker connection error in the logs | OP-09a | None | hyperfleet-operator | 1 |
| FU9 | OLM v1 install coverage: ClusterCatalog and ClusterExtension install automation in Prow, and the OP-22 scenario | OP-22 | D1; HYPERFLEET-1616 Part 2 findings | openshift/release, hyperfleet-e2e | 5 |

### Coverage Matrix Changes

| Seed ID | Change | Reason |
|---|---|---|
| OP-01 to OP-16 | Layer GKE becomes repository-local | Their failure modes need a real kubelet and controllers, not catalog resolution or the full stack |
| OP-02 | TLS and bearer rejection checks run in Kind mode only | G1 |
| OP-03 | Denial in other namespaces and of `delete` runs in Kind mode only, for six resource types; NetworkPolicies excluded | G1; the manager's role allows NetworkPolicy `delete` |
| OP-04, OP-05 | No E2E ownership assertion; OP-05 adds NetworkPolicy and `config.yaml` checks | Envtest proves owner references; OP-15 proves that garbage collection uses them |
| OP-08 | Split into OP-08 for direct API checks and OP-08b for gateway authentication | The API's Wristband assertion belongs to HYPERFLEET-1950. OP-08b verifies the gateway accepts the human token and rejects unauthenticated calls. |
| OP-09 | Split into OP-09a for local broker connectivity and OP-09b for the tier0 journey. Retire the seed's one-poll-interval bound. | `Reconciled=True` verifies journey completion. Its timing includes Sentinel polling, broker delivery and adapter processing. |
| OP-10 | Trigger is the database `secretRef` name, not the API profile | The renderer ignores `spec.api.profile`, so changing it does not change the API Pod template |
| OP-11 | Dropped from E2E; `envtest` | Envtest `rolls only the components that reference a rotated secret` proves rollout scope per Secret; OP-10 proves that a template change rolls out on a real cluster |
| OP-12 | Uses the database Secret instead of the JWKS Secret; one case | Operator PR #283 removed `spec.api.auth`, so no JWKS Secret is referenced. "No spurious rollout" becomes: the API rolls because it references the Secret; the Sentinels do not. Envtest covers the variants |
| OP-13 | Require replacements with new UIDs by a 2-minute recovery deadline. | The two deletes can enqueue separate reconciles. |
| OP-14 | Compare the full conditions by type and the operand count. | Reason and message can change with the same `lastTransitionTime`. |
| OP-15 | Adds OP-15b on integration | Uninstall through OLM is a different failure mode from CR deletion |
| OP-20 | CI on every relevant change replaces the seed's weekly cadence. A release gate using published bundles is proposed as an additional run | HYPERFLEET-1413 sets the CI cadence. The added release gate would exercise the artifacts selected for promotion |
| OP-21 | Added | HYPERFLEET-1895 hands scorecard to an OLM installation job |
| OP-22 | Added, `deferred` | OLM v1 needs separate installation evidence from HYPERFLEET-1616 Part 2. D1 sets when this coverage becomes required. |

## References

- [Test Placement Strategy](test-placement-strategy.md)
- [Spike: OLM bundle and catalog release process](../release/spike-olm-releases.md)
- [Spike report: OLM install testing in Prow](../spike-olm-install-testing-prow.md)
- [Operator OLM guide](https://github.com/openshift-hyperfleet/hyperfleet-operator/blob/main/docs/olm.md)
- [Operator `HyperFleetConfig` reference](https://github.com/openshift-hyperfleet/hyperfleet-operator/blob/main/docs/hyperfleetconfig-reference.md)
- [Operator upgrade testing](https://github.com/openshift-hyperfleet/hyperfleet-operator/blob/main/docs/upgrade-testing.md)
