---
Status: Draft
Owner: HyperFleet Team
Last Updated: 2026-10-15
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

- [Desire Store HLD](desire-store-hld.md): records the proposed REST/JSON transport this spike validates.
- [SPIKE: Evaluate Running the Desire Store on the API Postgres](desire-store-api-postgres-spike.md): supplies the workload model this evaluation uses.

## Overview

The Desire Store HLD proposes REST/JSON over HTTPS for the Desire Store API. This spike decides whether it can carry the projected polling workload.

## Evaluation method

The decision is made with a bandwidth model, not an end-to-end benchmark: at these rates, bandwidth is the only constraint that can actually fail, and it is just payload size × request rate, so only the payload size had to be measured.

**Where the numbers come from:**

- The measurement: one Go binary with a fake in-memory Desire Store (the two endpoints the workload uses) and a load generator, over loopback TLS with keep-alive connections.
  - `GET /desires?limit=10`: one partition read, one page of 10 desires. The biggest message at about 20 KB.
  - `PUT /desires/{desire-id}/status`: one ReadDesire status update, about 1 KB in, 204 No Content out.
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

The formula: bytes per message × messages per second × 8 = Mbps.

- Sizes: the measured values from [Evaluation method](#evaluation-method).
- Rates: from the [HYPERFLEET-1432](desire-store-api-postgres-spike.md) workload model, 10,000 partitions polled every 5 seconds gives 2,000 reads/sec plus 20,000 status writes/sec worst case; headroom doubles both.

**Baseline (2,000 reads/s + 20,000 status writes/s, worst case no dedup):**

| Direction | Message | Size (bytes) | Per second | Bytes/sec |
|---|---|---:|---:|---:|
| Out | Read response (10 desires with full kubeContent) | 20,277 | 2,000 | 40,554,000 |
| Out | Status-write response (204) | 64 | 20,000 | 1,280,000 |
| | **Egress total (budgeted)** | | | **41,834,000 = 335 Mbps** |
| In | Read request | 112 | 2,000 | 224,000 |
| In | Status-write request | 1,044 | 20,000 | 20,880,000 |
| | **Ingress total (context only)** | | | **21,104,000 = 169 Mbps** |

**Headroom (4,000 reads/s + 40,000 status writes/s):**

| Direction | Message | Size (bytes) | Per second | Bytes/sec |
|---|---|---:|---:|---:|
| Out | Read response | 20,277 | 4,000 | 81,108,000 |
| Out | Status-write response (204) | 64 | 40,000 | 2,560,000 |
| | **Egress total (budgeted)** | | | **83,668,000 = 669 Mbps** |
| In | Read request | 112 | 4,000 | 448,000 |
| In | Status-write request | 1,044 | 40,000 | 41,760,000 |
| | **Ingress total (context only)** | | | **42,208,000 = 338 Mbps** |

The measured run confirms the totals: 334.7 and 669.3 Mbps egress.

**Dedup assumption:** the worst case (no dedup) is budgeted. In steady state, [HYPERFLEET-1428](https://redhat.atlassian.net/browse/HYPERFLEET-1428) removes about 95% of status writes; reads are unaffected.

The worst case assumes every desire carries its full manifest in every response. If read responses instead say only which resource to watch, ongoing traffic would drop to about 150 Mbps; that figure is computed from the same measured sizes with the kubeContent removed, not a separate run (see [Transport decision](#transport-decision)).

## Budget and sensitivity

**Budget:** headroom egress below 25% of the hub node egress capacity (1,000 Mbps on a 4 Gbps node); ingress is context only.

- **Node capacity:** the OCI workers in the infra terraform are the E4.Flex family, documented at [1 Gbps of network bandwidth per OCPU](https://docs.oracle.com/en-us/iaas/Content/Compute/References/computeshapes.htm) (max 40 Gbps).
  - 2 OCPUs (2 Gbps) breaches the unshaped worst case: 669 Mbps vs. a 500 Mbps budget.
  - 4 OCPUs gives the 1.5x margin.
  - With the response-shaping rule, 2 OCPUs pass steady state.
- **Margin band on a 4 Gbps node:** 1.5x worst case, about 2x for a mixed partition, about 6.8x if reads carry references.
- **Break-even:** about 2.7 KB of kubeContent per desire.
- **Local measurement:** 44,000 requests/sec aggregate, measured with zero errors, target rates sustained, p95 around 1 ms.

## Transport decision

**Recommend REST/JSON over HTTPS.** The gRPC comparison is not necessary: the worst case (669 Mbps) stays inside the budget on hub worker nodes sized at 4 or more OCPUs.

Rationale:

- The worst-case cost driver is a wire-schema choice, not a transport property: the Applier needs the manifest only to apply, so the wire schema should return kubeContent only on apply desires. That drops ongoing egress to about 150 Mbps.
- gRPC would add schema-management complexity for savings the budget does not need.
