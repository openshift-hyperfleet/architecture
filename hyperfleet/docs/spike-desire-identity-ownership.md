---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-08-17
---

# Spike: Desire Identity and Ownership Model

**Ticket:** HYPERFLEET-1421

## 1. Context

The desire store is the contract between adapters, which write intent, and the
applier, which enacts it: `CloudEvent → adapter → desire store → applier →
target cluster`. Before the desire types package and the store schema can be
written, three questions have to be answered:

1. **Ownership** (§2) — who may write or change a desire for a given resource,
   and what happens when two writers disagree?
2. **Identity** (§3) — what set of attributes determines whether two desires
   are the same record?
3. **Provenance** (§4) — how does a desire relate back to the API resource
   that caused its existence?

## 2. Ownership

Ownership decides the relationship and cardinality between an adapter, a desire and a target resource.
The two decisions below settle how that binding is established (writer model) and enforced (collision response).

### Problem: can more than one adapter write the same resource?

### Options: writer model

**Single-writer** — one adapter owns a resource exclusively. One ApplyDesire,
one DeleteDesire, and one ReadDesire per resource. `adapter` is **not** part
of the identity; it is stored as an `owner` attribute on the desire. A single
global field manager (e.g. `hyperfleet-applier`) suffices.

**Multi-writer** — adapters co-own a resource, each contributing a slice of
its fields. One ApplyDesire per (target resource, adapter); `adapter` **is** part of
the identity, so two adapters targeting the same resource produce two
distinct ApplyDesires — no collision. The Kubernetes object is co-owned via
one SSA field manager per adapter (`hyperfleet-applier-{adapter}`); the
applied object is the combination of each adapter's fields, and two adapters
setting the *same* field to different values is a genuine conflict.

### Decision: single-writer

There is no current use case for multi-writer, and it collapses the largest
source of complexity for a capability nothing uses. Ownership therefore
attaches to the **target resource**, not to individual desires: there is one `owner`
per target, and every desire for that resource carries it.

If ownership handover or multi-concern composition is needed later, do it in a
consolidating adapter (values merged in the control plane) rather than
relaxing this rule.

### Problem: what happens on a collision?

If a non-owner writes or deletes a resource's desire, what should the store
do?

### Options: collision response

**1a — reject on collision.** On owner mismatch the store rejects the write —
a runtime error in the adapter's Resources phase, surfaced via the adapter's
status. A non-owner `DeleteDesire` is rejected the same way. First owner
wins; the offending write keeps failing until the config is fixed. The store
also logs a WARN and increments an owner-conflict metric, so the collision is
observable, not just a failed apply.

**1b — overwrite and log.** Last-writer-wins: the store overwrites and sets
`owner` to the new writer, logging a WARN and incrementing a metric on the
change. The adapter never fails; the collision is visible via the metric/log,
not silent. A delete requested by a non-owner is logged the same way, then
performed.

### Decision: 1a, reject on collision

Under overwrite (1b), two adapters targeting one resource revert each other's
applies every reconcile — and deletes flap between delete and recreate —
churning the target cluster's API server. Rejecting the second writer keeps
one deterministic owner. Two adapters on one resource means one is
misconfigured; rejecting surfaces that loudly instead of masking it as churn.

## 3. Identity

Identity is the set of attributes that makes two desires the same record —
same tuple, same desire; any difference, two distinct ones. The tuple below
is what the store keys on; everything else is content.

**Identity = `managementCluster, type, group, resource, namespace, name`**

Everything else is **content**: `owner`,
`kubeContent`, `status`, `resource_id`.

| Key field | Value | Format |
|---|---|---|
| managementCluster | management cluster identifier | our field — constrain to an RFC 1123 label, ≤63 |
| type | `apply` \| `delete` \| `read` | record type — one value per desire type (ApplyDesire, DeleteDesire, ReadDesire) |
| group | API group (empty for core) | RFC 1123 DNS subdomain, ≤253 |
| resource | plural (`configmaps`) | RFC 1035 DNS label, ≤63 |
| namespace | empty for cluster-scoped | RFC 1123 DNS label, ≤63 (no dots) |
| name | object name | RFC 1035 DNS label, ≤63 |

Formats follow Kubernetes [Object Names and IDs](https://kubernetes.io/docs/concepts/overview/working-with-objects/names/).

### Examples

| Resource | managementCluster | type | group | resource | namespace | name |
|---|---|---|---|---|---|---|
| ConfigMap in `default` | `mgmt-cluster-01` | `apply` | *(empty)* | `configmaps` | `default` | `my-config` |
| Cluster-scoped ClusterRole | `mgmt-cluster-01` | `apply` | `rbac.authorization.k8s.io` | `clusterroles` | *(empty)* | `admin` |
| Watch a Deployment | `mgmt-cluster-01` | `read` | `apps` | `deployments` | `kube-system` | `coredns` |
| Delete a Namespace | `mgmt-cluster-01` | `delete` | *(empty)* | `namespaces` | *(empty)* | `old-tenant` |

## 4. Provenance

To be able to associate a desire with the underlying API resource which
sparked its existence, resource_id needs to be a part of a desire's content.
This information makes debugging easier and enables a simple resource_id based
correlation check as a garbage collection principle - further investigated in HYPERFLEET-1431

## 5. Out of scope and open questions

- **Store backend** — Redis vs Postgres vs other is settled in [HYPERFLEET-1432](https://redhat.atlassian.net/browse/HYPERFLEET-1432); identity is defined
  store-agnostically (§1).
- **Garbage collection** — [HYPERFLEET-1431](https://redhat.atlassian.net/browse/HYPERFLEET-1432).
- **Field-manager naming** — the per-owner naming scheme — [HYPERFLEET-1424](https://redhat.atlassian.net/browse/HYPERFLEET-1424).
