---
Status: Active
Owner: HyperFleet Team
Last Updated: 2026-08-03
---

# Performance Baselines

**Jira**: [HYPERFLEET-1185](https://issues.redhat.com/browse/HYPERFLEET-1185), [HYPERFLEET-1270](https://issues.redhat.com/browse/HYPERFLEET-1270), [HYPERFLEET-1305](https://issues.redhat.com/browse/HYPERFLEET-1305)

---

## Table of Contents

- [Overview](#overview)
- [Environment](#environment)
- [Baselines](#baselines)
  - [API reads](#api-reads)
  - [Reconciliation operations](#reconciliation-operations)
  - [Generic resource CRUD (Channel, Version, WifConfig)](#generic-resource-crud-channel-version-wifconfig)
- [How to reproduce](#how-to-reproduce)

## Overview

Lightweight performance baselines for core HyperFleet operations, captured for the v1.0.0 release. These baselines measure the overhead HyperFleet introduces, not infrastructure capacity.

Baselines are captured from two environments. The Prow CI environment provides the baselines from which CI thresholds are derived. The GKE dev environment is useful for local development comparison.

## Environment

Both environments run the same stack: API, Sentinel (clusters + nodepools), 3 adapters (2 Kubernetes transport, 1 Maestro transport), and GCP Pub/Sub. All nodes are e2-standard-4 (4 vCPU / 16GB RAM) with a 5s Sentinel poll interval.

| Parameter | GKE dev | Prow CI (hyperfleet-dev-prow) |
|---|---|---|
| Execution | `kubectl run` (ClusterIP) | Prow `tier1-nightly` job |
| Database | ~1k seeded clusters | Fresh deploy per run |
| Date captured | 2026-06-18 | 2026-06-23 |

## Baselines

### API reads

| Operation                             | GKE dev | Prow CI |
| ------------------------------------- | ------- | ------- |
| GET /clusters/{id} (small payload)    | 2.19ms  | 32.72ms |
| GET /clusters/{id} (medium payload)   | 2.82ms  | 30.99ms |
| GET /clusters/{id} (large payload)    | 4.34ms  | 32.61ms |
| GET /clusters (no filter)             | 5.10ms  | 32.63ms |
| GET /clusters (search filter)         | 4.89ms  | 33.03ms |
| GET /clusters (size=10)               | 4.22ms  | 31.42ms |
| GET /clusters (page=1, size=10)       | 4.23ms  | 33.30ms |

### Reconciliation operations

| Operation                               | GKE dev | Prow CI |
| ---------------------------------------- | ------- | ------- |
| Cluster create-to-reconciled            | 10.02s  | ~60s    |
| Cluster update-to-re-reconciled         | 20.06s  | ~40s    |
| Cluster delete-to-hard-delete           | 40.09s  | ~40s    |
| Cluster cascade delete (with nodepools) | 40.08s  | ~50s    |
| NodePool create-to-reconciled           | 10.02s  | ~20s    |
| NodePool delete-to-hard-delete          | 20.05s  | ~20s    |

Prow CI latencies are higher than GKE dev due to shared cluster resources.

CI thresholds for both API reads and reconciliation operations are defined in [`pkg/config/thresholds.go`](https://github.com/openshift-hyperfleet/hyperfleet-e2e/blob/main/pkg/config/thresholds.go) in the `hyperfleet-e2e` repo. Thresholds apply a margin over Prow CI baselines to absorb run-to-run variance.

**HYPERFLEET-1305 regression check (2026-07-27):** HYPERFLEET-1159 migrated Cluster and NodePool onto the same generic resource layer (shared `resources`/`resource_labels`/`resource_conditions` tables) that Channel/Version/WifConfig already used. The `tier1-nightly` [run from 2026-07-27](https://prow.ci.openshift.org/view/gs/test-platform-results/logs/periodic-ci-openshift-hyperfleet-hyperfleet-e2e-main-e2e-tier1-nightly/2081703903212081152) confirms no regression: all Cluster/NodePool reconciliation and API read/list thresholds still pass (0 failed). Two operations show a modest increase over the baselines above that's still comfortably within threshold: Cluster create-to-reconciled (70.1s vs. the 60s baseline, threshold 90s) and NodePool create-to-reconciled (30.1s vs. the 20s baseline, threshold 45s) — plausibly attributable to the generic resource DAO's unconditional `Preload("Conditions").Preload("Labels").Preload("References")` on every read, which applies uniformly across all five entity kinds post-migration.

### Generic resource CRUD (Channel, Version, WifConfig)

Channel, Version, and WifConfig carry no `RequiredAdapters` — unlike Cluster/NodePool, they have no reconciliation loop, so create/update/delete are single synchronous API calls with no "reconciled" variant to time separately.

Captured 2026-07-27 on a dedicated GKE dev cluster (`dev-tithakka`, e2-standard-4 nodes, no adapters/Sentinel dependency for these kinds) with ~1k seeded rows per kind (1000 Channels, 1000 WifConfigs, 1000 Versions under one parent Channel — the worst-case shape for a single list query). **No Prow CI numbers exist yet** for these operations: the perf specs are new (added by HYPERFLEET-1305) and haven't run in `tier1-nightly` yet — they'll be picked up automatically (no CI config changes needed, same Ginkgo `perf` label) on the first nightly run after this branch merges to `main`. Revisit this table once that run lands.

| Operation                                   | GKE dev |
| -------------------------------------------- | ------- |
| POST /channels                              | 5.39ms  |
| GET /channels/{id}                          | 3.44ms  |
| GET /channels                               | 8.31ms  |
| PATCH /channels/{id}                        | 5.75ms  |
| DELETE /channels/{id}                       | 9.05ms  |
| POST /channels/{parent_id}/versions         | 8.94ms  |
| GET /channels/{parent_id}/versions/{id}     | 6.37ms  |
| GET /channels/{parent_id}/versions          | 7.39ms  |
| PATCH /channels/{parent_id}/versions/{id}   | 8.00ms  |
| DELETE /channels/{parent_id}/versions/{id}  | 10.07ms |
| POST /wifconfigs                            | 5.03ms  |
| GET /wifconfigs/{id}                        | 3.61ms  |
| GET /wifconfigs                             | 6.86ms  |
| PATCH /wifconfigs/{id}                      | 6.68ms  |
| DELETE /wifconfigs/{id}                     | 5.99ms  |

All operations comfortably clear the shared `ThresholdAPIRead`/`ThresholdAPIList`/`ThresholdAPICreate`/`ThresholdAPIUpdate`/`ThresholdAPIDelete` constants (50ms each) in [`pkg/config/thresholds.go`](https://github.com/openshift-hyperfleet/hyperfleet-e2e/blob/main/pkg/config/thresholds.go) — the largest observed value (10.07ms) is less than a quarter of the threshold.

## How to reproduce

### Prow CI

Prow baselines are captured automatically by the `tier1-nightly` job. To trigger a run on demand, use the [Gangway API](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/docs/release/test-release/trigger-e2e-jobs-via-gangway.md). Results are available in the [Prow dashboard](https://prow.ci.openshift.org/?job=periodic-ci-openshift-hyperfleet-hyperfleet-e2e-main-e2e-tier1-nightly) build logs (search for `[PERF]` lines).

### GKE dev

See the [perf README](https://github.com/openshift-hyperfleet/hyperfleet-e2e/blob/main/perf/README.md) in the `hyperfleet-e2e` repo for prerequisites, infrastructure setup, seeding, and test execution instructions. `perf/seed-clusters.sh` seeds Cluster rows; `perf/seed-resources.sh <channels|wifconfigs|versions>` seeds the generic-resource kinds.
