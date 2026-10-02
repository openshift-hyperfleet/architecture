---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-10-02
---

# Spike: Apply and Delete Ordering

Related: [0028 — Serialize Apply Then Delete](../adrs/0028-apply-delete-ordering.md)

## What ran

One reconcile pass was timed for parallel apply and delete loops against one loop that finishes every apply and then runs deletes. Each cell is one pass over a management-cluster partition of `n` desires, half ApplyDesires and half DeleteDesires, on disjoint ConfigMap names. The ApplyDesires have no object yet, so each one is a server-side apply that creates it. Each DeleteDesire is a GET, a DELETE, and a confirming GET. Both loops shared one dynamic client at 20 QPS and a burst of 40. Call count is about `2n`: one call per apply desire and three per delete desire.

The 20 QPS / 40 burst limit is twice the maximum concurrent reconciliations supported by a single HostedCluster or NodePool controller. That sizing does not imply those reconciliations run in parallel.

## Backends

- **envtest** is a real kube-apiserver and etcd.
- **mock** is an httptest server that answers immediately, so the client rate limit is the only wait.
- **degraded** is the same mock that sleeps about 120 ms on every call (median about 100 ms, p99 about 400 ms). The loop issues about 8 requests per second and never reaches the 20 QPS cap.

## Results

Wall-clock seconds for that single pass.

| Backend  | Ordering | 10    | 100   | 1,000  | 10,000  |
| -------- | -------- | ----- | ----- | ------ | ------- |
| envtest  | parallel | 0.034 | 10.00 | 100.00 | 1000.00 |
| envtest  | serial   | 0.050 | 10.00 | 100.00 | 1000.00 |
| mock     | parallel | 0.005 | 8.00  | 98.00  | 998.00  |
| mock     | serial   | 0.008 | 8.00  | 98.00  | 998.00  |
| degraded | parallel | 1.59  | 19.13 | 184.84 |         |
| degraded | serial   | 3.11  | 24.44 | 238.15 |         |

At 100, 1,000, and 10,000 desires the shared client rate limit already sets the wall-clock time on envtest and the immediate mock, so the two orderings roughly match. On the degraded backend the client never reaches 20 QPS, and serial is the sum of the two passes: 238.15 seconds serial against 184.84 seconds parallel at 1,000 desires. Inside the 40-call burst, serial is slightly slower (envtest at 10 desires: 0.050 seconds serial, 0.034 seconds parallel).
