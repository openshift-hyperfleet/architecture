# Spike: Dedicated GKE Node Pool for Maestro

> Historical evidence only: Maestro has been removed from HyperFleet. The measurements and rollout/rollback examples below record the rejected node-pool proposal; they are not current deployment instructions. See the [current remote transport model](../components/adapter/framework/adapter-frame-design.md#transport-client) for its replacement.

**Ticket:** [HYPERFLEET-1124](https://redhat.atlassian.net/browse/HYPERFLEET-1124)
**Epic:** [HYPERFLEET-1118](https://redhat.atlassian.net/browse/HYPERFLEET-1118) — Maestro Reliability: protect critical pods from autoscaler eviction
**Date:** 2026-06-16
**Author:** Dmitrii Andreev

---

## 1. Context

`hyperfleet-dev-prow` GKE cluster runs maestro (HyperFleet control plane) and E2E test workloads on shared node pool. On 2026-05-25, GKE autoscaler evicted maestro server pod during scale-down, causing E2E failures. Triggered [HYPERFLEET-1118](https://redhat.atlassian.net/browse/HYPERFLEET-1118) — maestro pod protection via multiple layers:

| Ticket | Protection Layer | Status |
|--------|-----------------|--------|
| HYPERFLEET-1119 | `safe-to-evict: "false"` on server pod | Closed |
| HYPERFLEET-1121 | `safe-to-evict: "false"` on agent/db/mqtt pods | Closed |
| HYPERFLEET-1122 | PodDisruptionBudget (`minAvailable: 1`) | Backlog |
| HYPERFLEET-1123 | PriorityClass (`hyperfleet-critical`) | Closed |
| **HYPERFLEET-1124** | **This spike: evaluate dedicated node pool** | **This document** |

**Question:** Should maestro run on dedicated node pool instead of (or alongside) chart-level protections?

### Recent incident (2026-06-16)

Tier1-nightly E2E failed — node hosting API pod restarted during test run. Root cause ambiguous — safe-to-evict annotations may not have been deployed yet (PR #50 merged same day, after nightly). Demonstrates node-level disruptions (autoscaler or maintenance) remain real, recurring problem.

## 2. Current State

### Cluster configuration (live data, 2026-06-16)

| Property | Value |
|----------|-------|
| Cluster | `hyperfleet-dev-prow` |
| Zone | `us-central1-a` (zonal) |
| Nodes | 2x `e2-standard-4` (4 vCPU, 16 GB each) |
| Node pool | `hyperfleet-dev-prow-pool` (single pool) |
| Autoscaling | Enabled, min=2, max=2 (effectively fixed — confirmed via `gcloud` 2026-06-18). Autoscaler scale-down cannot occur under this config. |
| Spot VMs | No |
| Total capacity | 8 vCPU, 32 GB RAM |

**Note:** Terraform (`terraform/envs/gke/dev-prow.tfvars`) says `node_count=1` with no autoscaling. Cluster manually scaled to 2 nodes via GCP Console during resource pressure incident ([HYPERFLEET-1106](https://redhat.atlassian.net/browse/HYPERFLEET-1106)). Terraform state out of sync. [HYPERFLEET-1113](https://redhat.atlassian.net/browse/HYPERFLEET-1113) proposes scaling back to 1 node once E2E cleanup works.

### Node utilization (measured 2026-06-18, idle and under E2E load)

**Under E2E load** (captured during active E2E run, 2026-06-18T17:17–17:40Z):

| Metric | Idle | E2E Peak | Headroom |
|--------|------|----------|----------|
| Node CPU (single node) | 4-5% (193m) | 15% (588m) | 85% free |
| Node memory (single node) | 22% (3033Mi) | 25% (3417Mi) | 75% free |
| Maestro server CPU | 3m | 19m | 481m to limit |
| Maestro server memory | 23Mi | 30Mi | 482Mi to limit |
| All maestro pods CPU | 20m | ~46m | trivial |
| All maestro pods memory | 94Mi | ~98Mi | no growth |

No resource contention observed. E2E tests create rapid namespace churn (~30-60s lifecycle each) that increases maestro server CPU 6x (3m → 19m), but 19m is trivial on a 4-vCPU node. Memory barely moves. Nodes never exceed 25% memory or 15% CPU during E2E.

**Caveat:** This measurement covers tier0 E2E only (sequential execution). Parallel E2E execution would produce higher peak load over a shorter window. The isolation argument strengthens under parallel execution since more concurrent test namespaces mean more simultaneous maestro event processing.

**Idle baseline** (measured 2026-06-16):

| Node | CPU | CPU % | Memory | Memory % |
|------|-----|-------|--------|----------|
| ...g64y | 173m | 4% | 2889Mi | 21% |
| ...gie1 | 101m | 2% | 2278Mi | 17% |

### Maestro resource footprint

| Pod | Actual CPU | Actual Memory | Requested CPU | Requested Memory | Limits CPU | Limits Memory |
|-----|-----------|---------------|---------------|------------------|------------|---------------|
| maestro (server) | 3m | 23Mi | 100m | 256Mi | 500m | 512Mi |
| maestro-agent | 6m | 32Mi | — | — | — | — |
| maestro-db | 10m | 39Mi | — | — | — | — |
| maestro-mqtt | 1m | 0Mi | — | — | — | — |
| **Total** | **20m** | **94Mi** | **100m** | **256Mi** | **500m** | **512Mi** |

*Measured via `kubectl top pods -n maestro` on 2026-06-18 (idle, no E2E running).*

Three of four maestro pods (agent, db, mqtt) have **no resource requests or limits** — not in our values, not in upstream chart. Only server has explicit resource config.

### Other workloads on the cluster

- GKE system pods (~25 pods across `kube-system`, `gmp-system`, etc.)
- `maestro-tls` namespace (3 pods — second maestro instance for TLS testing)
- Orphaned E2E test pods (1 running nginx pod in UUID namespace)
- `gcloud` helper pod in `default` namespace

## 3. Proposed Node Pool Shape

| Property | Value | Rationale |
|----------|-------|-----------|
| Machine type | `e2-small` (0.5 sustained vCPU / burstable to 2, 2 GB) | Maestro uses 20m CPU / 94Mi memory (measured 2026-06-18). e2-small = shared-core: 0.5 sustained vCPU, burst to 2 vCPU. GKE reserves 1060m CPU (flat for shared-core E2) + ~512Mi memory (25% of 2 GB) + 100Mi eviction threshold. Allocatable memory ~1.4 GiB. On a NoSchedule-tainted node, DaemonSet/static pods request **641Mi** (actual usage **~583Mi**, measured 2026-06-18). Effective schedulable memory: **~795Mi** (by requests), actual free: **~853Mi**. CPU reservation exceeds sustained capacity but workloads run via burst — 20m fits trivially. Memory is the binding constraint; ~795Mi schedulable for 94Mi actual usage (8x headroom). |
| Node count | 1 (fixed) | Single node, no autoscaling. Maestro single-replica — no benefit from multiple nodes. |
| Autoscaling | Disabled (`min=max=1`) | Entire point = prevent scale-down eviction. |
| Spot VMs | No | Spot VMs preemptable anytime — defeats purpose of dedicated stable pool. |
| Zone | `us-central1-a` | Same as existing pool. Cross-zone latency unnecessary for dev cluster. |
| Taint | `workload=maestro:NoSchedule` | Prevents E2E pods from scheduling on maestro node. |
| Labels | `workload: maestro` | For `nodeSelector` targeting. |

### Why not e2-micro?

`e2-micro` (1 GB RAM) is ruled out by scheduling math. 1024Mi total − 256Mi system reservation (25% of 1 GB) − 100Mi eviction threshold = ~668Mi allocatable. GKE DaemonSet/static pods on the current cluster request **641Mi** total (measured 2026-06-18: fluentbit-gke 230Mi, gke-metrics-agent 145Mi, gke-metadata-server 100Mi, netd 60Mi, container-watcher 50Mi, collector 36Mi, pdcsi-node 20Mi). That leaves **27Mi** for workload requests — maestro server alone requests 256Mi and would not schedule. `e2-small` (2 GB, ~$6/month more) is the minimum viable size, with ~795Mi of schedulable headroom after DaemonSet requests.

## 4. Cost

Incremental cost of dedicated `e2-small` pool: **~$12/month** ([on-demand, us-central1](https://cloud.google.com/compute/all-pricing)). If cluster stays at 2 nodes and we replace second `e2-standard-4` (~$98/mo) with `e2-small`, **saves ~$86/month**. Negligible either way for dev cluster — cost not a factor. No idle-shutdown concern — `hyperfleet-dev-prow` is labeled `environment: cicd` and explicitly excluded from idle shutdown and TTL enforcement ([architecture PR #160](https://github.com/openshift-hyperfleet/architecture/pull/160), merged 2026-06-16).

## 5. Required Terraform Changes

### Files affected

| File | Change |
|------|--------|
| `terraform/variables.tf` | Declare root-level variables: `maestro_pool_enabled`, `maestro_pool_machine_type`, `maestro_pool_node_count` |
| `terraform/main.tf` | Pass new variables through to `module "gke_cluster"` block |
| `terraform/modules/cluster/gke/main.tf` | Add second `google_container_node_pool` resource with taint + labels |
| `terraform/modules/cluster/gke/variables.tf` | Add module-level variables for dedicated pool |
| `terraform/envs/gke/dev-prow.tfvars` | Enable dedicated pool, set machine type + count |
| `helm/maestro/values.yaml` | Add `nodeSelector` and `tolerations` blocks for all 4 subcharts |

### Rough Terraform diff

```hcl
# terraform/modules/cluster/gke/main.tf — add after existing node pool

resource "google_container_node_pool" "maestro" {
  count    = var.maestro_pool_enabled ? 1 : 0
  name     = "${var.cluster_name}-maestro-pool"
  location = var.zone
  cluster  = google_container_cluster.primary.name
  project  = var.project_id

  node_count = var.maestro_pool_node_count

  node_config {
    machine_type    = var.maestro_pool_machine_type
    disk_size_gb    = 30
    spot            = false
    resource_labels = merge(var.labels, { workload = "maestro" })

    tags = ["gke-${var.cluster_name}"]

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = { workload = "maestro" }

    taint {
      key    = "workload"
      value  = "maestro"
      effect = "NO_SCHEDULE"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}
```

```hcl
# terraform/modules/cluster/gke/variables.tf — new variables

variable "maestro_pool_enabled" {
  description = "Enable a dedicated node pool for maestro workloads"
  type        = bool
  default     = false
}

variable "maestro_pool_machine_type" {
  description = "Machine type for the maestro dedicated node pool"
  type        = string
  default     = "e2-small"
}

variable "maestro_pool_node_count" {
  description = "Number of nodes in the maestro dedicated pool"
  type        = number
  default     = 1
}
```

### Rough tfvars diff

```hcl
# terraform/envs/gke/dev-prow.tfvars — add

maestro_pool_enabled      = true
maestro_pool_machine_type = "e2-small"
maestro_pool_node_count   = 1
```

### Rough Helm values diff

**These values paths do not work yet** — upstream charts do not support `nodeSelector` or `tolerations` (see Section 9, hard blocker). The paths below assume the upstream PR will add these as top-level keys, matching the existing pattern for `podAnnotations` and `priorityClassName`. Actual paths depend on upstream PR implementation. In our umbrella chart, subchart aliases (`server:`, `agent:`) prefix upstream keys.

```yaml
# helm/maestro/values.yaml — add to each subchart section

server:
  nodeSelector:
    workload: maestro
  tolerations:
    - key: workload
      operator: Equal
      value: maestro
      effect: NoSchedule

  postgresql:
    nodeSelector:
      workload: maestro
    tolerations:
      - key: workload
        operator: Equal
        value: maestro
        effect: NoSchedule

  mosquitto:
    nodeSelector:
      workload: maestro
    tolerations:
      - key: workload
        operator: Equal
        value: maestro
        effect: NoSchedule

agent:
  nodeSelector:
    workload: maestro
  tolerations:
    - key: workload
      operator: Equal
      value: maestro
      effect: NoSchedule
```

### Terraform caveats

**State reconciliation:** Terraform state out of sync with actual cluster (tfvars says 1 node, cluster has 2 with autoscaling). Before applying any Terraform changes, state must be reconciled — either import current state or align tfvars with reality.

**Taint changes force pool recreation:** In `google` Terraform provider, modifying taints in `node_config` [forces node pool replacement](https://github.com/hashicorp/terraform-provider-google/issues/16054) — Terraform destroys and recreates pool, not in-place update. Fine for new maestro pool (created fresh with taint). But adding taints to existing primary pool later would be destructive.

## 6. Migration Plan

### Rollout order

0. **[Prerequisite] Submit upstream PR** — Add `nodeSelector` and `tolerations` support to all four upstream deployment templates (server, agent, postgresql, mosquitto) in `openshift-online/maestro`. Wait for merge. Update `Chart.yaml` ref in this repo. **Blocks everything below.**
1. **Reconcile Terraform state** — update `dev-prow.tfvars` to match actual cluster config (2 nodes, autoscaling min=max=2), or import.
2. **Create dedicated pool** — `terraform apply` with `maestro_pool_enabled = true`. Tainted pool comes up empty (no pods can tolerate taint yet).
3. **Add tolerations + nodeSelector** — Update `helm/maestro/values.yaml` with `nodeSelector` and `tolerations` for all 4 deployment templates (server and postgresql/mosquitto in `maestro-server` chart, plus `maestro-agent` chart).
4. **Redeploy maestro** — `make install-maestro`. Pods reschedule from shared pool to dedicated pool.
5. **Verify** — Confirm all 4 pods on dedicated node: `kubectl get pods -n maestro -o wide`.
6. **Scale shared pool** — Once maestro confirmed on dedicated pool, optionally reduce shared pool to 1 node (HYPERFLEET-1113).
7. **Observe** — Monitor 1-2 nightly E2E cycles. Confirm no maestro disruptions.

### maestro-tls instance

The `maestro-tls` namespace (Section 2) runs a second maestro instance for TLS testing. It uses separate Helm values and is not affected by the `nodeSelector`/`tolerations` changes to the primary maestro values. It remains on the shared pool. If it should also be protected, it needs its own values override — but for a TLS test instance, shared-pool placement is acceptable.

### Rollback

If dedicated pool causes issues: remove `nodeSelector`/`tolerations` from Helm values, redeploy, then `terraform destroy` maestro pool resource. Maestro returns to shared pool.

## 7. Maintenance Upgrade Isolation

GKE [maintenance windows](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/maintenance-windows-and-exclusions) are **cluster-scoped** — cannot give individual node pools different maintenance windows. However, GKE supports **per-node-pool maintenance exclusions**, blocking automatic upgrades on specific pools.

**In practice:**

- Cluster-wide maintenance window controls *when* upgrades happen (e.g., weekends only).
- Per-pool maintenance exclusion can block upgrades on maestro pool entirely while shared pool upgrades normally.

**Recommended config:**

- Set cluster-wide maintenance window during off-hours (cluster currently has none — new addition).
- Add [node pool maintenance exclusion](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/maintenance-windows-and-exclusions) on maestro pool to prevent auto-upgrades during E2E test windows.

**Alternative:** Set `auto_upgrade = false` on maestro pool via Terraform (`management { auto_upgrade = false }`). Full manual control over maestro node upgrades, cost = accumulating security patches needing manual apply. Acceptable for dev cluster; document trade-off.

**Note:** Neither approach prevents `auto_repair` (node health-based restarts), which is desirable — broken node should be replaced. See [Section 7a: Single-Node Trade-off](#7a-single-node-trade-off-accepted-risk) for implications.

### 7a. Single-Node Trade-off (Accepted Risk)

Pinning maestro to 1-node tainted pool = single point of failure: if node dies (hardware fault, auto-repair, auto-upgrade restart), pod has **nowhere to reschedule** — taint blocks every other node, only one node in pool. Pod stays `Pending` until GKE auto-repair provisions replacement (~2-5 minutes).

On current 2-node shared pool, pod could immediately reschedule to surviving node.

**Acceptable for CI/dev cluster** because:

- Node-level disruptions mid-test (the motivating incidents) corrupt test results; a clean node-replacement from auto-repair just delays the next run.
- Maestro single-replica, no HA requirement in dev.
- PDB cannot help here (cannot conjure node), but auto-repair restores pool automatically.

If trade-off becomes unacceptable (e.g., maestro serves production traffic), pool can scale to `min=max=2` across two zones — not justified for dev cluster.

## 8. Epic Comparison: How Protections Interact

| Ticket | Protection | With Dedicated Pool | Verdict |
|--------|-----------|-------------------|---------|
| HYPERFLEET-1119 | safe-to-evict on server | Redundant on non-autoscaled pool (autoscaler never considers scale-down). Harmless to leave. | Still valuable as defense-in-depth |
| HYPERFLEET-1121 | safe-to-evict on agent/db/mqtt | Same as above. | Still valuable as defense-in-depth |
| HYPERFLEET-1122 | PDB (minAvailable:1) | **Still necessary.** PDBs protect against voluntary disruptions: `kubectl drain`, GKE auto-upgrade node restarts, auto-repair. Dedicated pool does not eliminate these. | Keep |
| HYPERFLEET-1123 | PriorityClass | **Reduced value** on dedicated tainted pool (no competing pods). Still provides kubelet-level eviction ordering under memory pressure and scheduling priority on node restart. | Keep — low cost, some value |
| HYPERFLEET-1113 | Scale shared pool to 1 node | HYPERFLEET-1113 is gated on E2E cleanup (HYPERFLEET-1106), not on this pool. Dedicated pool makes scale-down safer (maestro has its own node) but is not the prerequisite. | Safer with pool |

**Summary:** Dedicated pool does NOT replace chart-level protections — complements them. Layers protect against different failure vectors:

| Failure Vector | safe-to-evict | PDB | PriorityClass | Dedicated Pool |
|---------------|:---:|:---:|:---:|:---:|
| Autoscaler scale-down | Y | — | — | Y |
| Voluntary disruption (drain, upgrade) | — | Y | — | partial (maintenance exclusion) |
| Scheduling priority under pressure | — | — | Y | Y (taint = no competition) |
| Workload isolation from E2E | — | — | — | Y |

## 9. Recommendation

### Reject — dedicated node pool makes resilience worse, not better

**Rationale:**

1. **Dedicated node worsens node-failure resilience.** On the current 2-node shared pool, if one node dies maestro reschedules immediately to the surviving node. On a 1-node tainted pool, maestro has nowhere to go — taint blocks every other node, pod stays `Pending` until GKE auto-repair provisions a replacement (~2-5 min). Dedicated pool trades immediate reschedule for guaranteed downtime on node failure (see [Section 7a](#7a-single-node-trade-off-accepted-risk)).

2. **Two-node dedicated pool = unjustified overhead.** Scaling the dedicated pool to 2 nodes would solve the SPOF, but running two nodes for a workload using 20m CPU / 94Mi memory is disproportionate. The shared pool already provides multi-node resilience at no extra cost.

3. **Maestro is being replaced.** Maestro will not be part of HyperFleet's future architecture. Upstream chart work, Terraform changes, and ongoing pool maintenance are not justified for a component being phased out.

### Still recommended (independent of node pool)

- **HYPERFLEET-1122: PDB** (`minAvailable: 1`) — protects against voluntary disruptions (drain, upgrade). Not yet implemented.
- **Resource requests/limits** on agent, db, mqtt pods — currently unbounded, actual OOM exposure risk.

---

## Pre-Decision Verification Checklist

Confirm before decision meeting to avoid derailing on verifiable facts:

- [ ] **Terraform state drift:** Compare `terraform/envs/gke/dev-prow.tfvars` with live cluster. Plan: update tfvars or import?

---

## Decision Record

**Decision:** Reject
**Date:** 2026-06-23
**Forum:** Async Slack discussion (office hours)
**Participants:** amarin, dandreev, rbenevideds
**Notes:** Spike analysis (Section 7a) showed dedicated 1-node pool worsens resilience — pod loses immediate reschedule capability. Combined with maestro sunset, complexity not justified. Chart-level protections (safe-to-evict, PDB, PriorityClass) remain the correct approach.
