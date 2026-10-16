---
Status: Active
Owner: HyperFleet Team
Last Updated: 2026-10-16
---

# SPIKE: Evaluate Desire Store Transport Overhead

**Jira**: [HYPERFLEET-1743](https://redhat.atlassian.net/browse/HYPERFLEET-1743)

## Table of Contents

- [Related Documents](#related-documents)
- [Overview](#overview)
- [Evaluation method](#evaluation-method)
- [Bandwidth math](#bandwidth-math)
- [Budget and sensitivity](#budget-and-sensitivity)
- [Transport decision](#transport-decision)

---

## Related Documents

- [Desire Store HLD](desire-store-hld.md): records the REST/JSON transport decision.
- [SPIKE: Evaluate Running the Desire Store on the API Postgres](desire-store-api-postgres-spike.md): supplies the workload model this evaluation uses.

## Overview

The Desire Store HLD proposed REST/JSON over HTTPS for the Desire Store API. This spike decides whether it can carry the projected polling workload.

## Evaluation method

The decision is made with a bandwidth model, not an end-to-end benchmark: at these rates, bandwidth is the only constraint that can actually fail, and it is just payload size × request rate, so only the payload size had to be measured.

**Where the numbers come from:**

- The measurement: one Go binary with a fake in-memory Desire Store and a load generator, over loopback TLS with keep-alive connections.
  - `GET /desires?limit=10`: one partition read, one page of 10 desires, 20,277 bytes. The biggest message.
  - `PUT /desires/{desire-id}/status`: one ReadDesire status update, about 1 KB in, 64-byte 204 No Content out.
  - A single-desire GET response, about 2.1 KB, is derived from the measured list response (per-desire share plus headers).
  - 15 seconds of warmup, then three 60-second measured runs per scenario at the workload rates.
  - Sizes are identical in every run.
- The content is real: each desire's kubeContent is rendered Helm output from the hyperfleet-api and hyperfleet-sentinel charts, 0.3 to 4 KB per desire.
- The counting rules:
  - HTTP/1.1 with uncompressed JSON, the worst case for header overhead, so the counts are an upper bound.
  - Headers included, TLS overhead excluded.
  - JSON parsed and re-marshaled on every request.

**Caveats:**

- Rate and latency numbers are a single-process laptop ceiling, not server capacity.
- Postgres, the gateway, auth, dedup, and cross-cluster latency are not in the measured path.

## Bandwidth math

The formula: bytes per pass × passes per second × 8 = Mbps.

- Sizes: the measured and derived values from [Evaluation method](#evaluation-method).
- Rates: from the [workload model](desire-store-api-postgres-spike.md) in [HYPERFLEET-1432](https://redhat.atlassian.net/browse/HYPERFLEET-1432), 10,000 partitions polled every 5 seconds gives 2,000 passes/sec; headroom doubles.
- Each pass is the applier's full cycle, not a single list call:
  - 3 lists per pass, one per desire type. Same total bytes, about 3x the read requests.
  - A GET of the full desire before every apply and delete.
  - A status write per read desire.
  - Per [ADR-0028](../adrs/0028-apply-delete-ordering.md), every pass lists fresh and reapplies every ApplyDesire, so the GETs run every pass until reapply frequency is decided ([HYPERFLEET-1742](https://redhat.atlassian.net/browse/HYPERFLEET-1742)).

**Per-pass egress at headroom, with full-content lists (4,000 passes/sec; baseline is half):**

| Partition | Lists | GETs | Write responses | Per pass | Egress (per pass × 4,000 × 8) |
|---|---|---|---|---|---|
| Read-only (10 read desires) | 20.3 KB | none | 0.6 KB | 20.9 KB | about 669 Mbps |
| Mixed (3 apply/delete, 7 read) | 20.3 KB | 6.3 KB | 0.4 KB | 27.0 KB | about 865 Mbps |
| All-apply (10 apply/delete desires) | 20.3 KB | 21.2 KB | none | 41.5 KB | about 1,330 Mbps |

The read-only row matches the measured run, which recorded 669.3 Mbps headroom egress. The GET round pushes apply-heavy partitions over the budget, because apply and delete content crosses the wire twice per pass.

With references-only lists (each desire returns its reference, not its kubeContent), the list column drops to about 4.0 KB (derived: the measured 20,277-byte list minus its 16,235 bytes of kubeContent): read-only about 150 Mbps, mixed about 340 Mbps, all-apply about 810 Mbps.

**Dedup assumption:** the worst case (no dedup) is budgeted. The [HYPERFLEET-1428](https://redhat.atlassian.net/browse/HYPERFLEET-1428) dedup skips about 95% of status writes in steady state, a POC measurement cited in that ticket; reads are unaffected.

## Budget and sensitivity

**Budget:** headroom egress below 25% of the hub node egress capacity (1,000 Mbps on a 4 Gbps node); ingress is context only.

- **Node capacity:** the hub's OKE workers default to E5.Flex at 4 OCPUs per node (oci-infra `02-oke-workers`), documented at [1 Gbps of network bandwidth per OCPU](https://docs.oracle.com/en-us/iaas/Content/Compute/References/computeshapes.htm) (max 40 Gbps).
  - 2 OCPUs (2 Gbps) breaches even the read-only case.
  - The default 4 OCPUs covers read-only and mixed partitions; all-apply with full-content lists (about 1,330 Mbps) exceeds it.
- **Margin band on a 4 Gbps node:** 1.5x read-only, 1.2x all-apply with references-only lists, 0.75x all-apply with full-content lists.
- **Sensitivity:** wire bytes scale linearly with desire content, and apply and delete content counts twice with full-content lists (list plus GET), once with references-only lists.
- **Local measurement:** 44,000 requests/sec aggregate, measured with zero errors, target rates sustained, p95 around 1 ms; the real pass is about 52,000 requests/sec at headroom.

## Transport decision

**Recommend REST/JSON over HTTPS.** The gRPC comparison is still not necessary: with references-only lists, even the all-apply case (about 810 Mbps) stays inside the budget on hub worker nodes sized at 4 or more OCPUs.

Rationale:

- The worst-case cost driver is the wire schema plus the reapply pattern, not the transport: apply and delete content crosses the wire twice per pass until [HYPERFLEET-1742](https://redhat.atlassian.net/browse/HYPERFLEET-1742) gates reapply, so lists should return references for all desire types, with kubeContent served by the GET. That drops all-apply egress from about 1,330 to about 810 Mbps.
- Without that rule, apply-heavy partitions exceed the 4-OCPU budget; the fallbacks are 8-OCPU nodes or waiting on HYPERFLEET-1742.
- gRPC would add schema-management complexity for savings the budget does not need once lists return references only.
