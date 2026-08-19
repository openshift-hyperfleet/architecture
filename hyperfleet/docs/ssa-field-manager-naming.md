---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-08-18
---

# Server-Side Apply Field Manager Naming Scheme

## Overview

The ApplyDesire controller (HYPERFLEET-1425) applies desired-state resources to
managed clusters using Kubernetes Server-Side Apply (SSA) with `Force: true`.
ApplyDesire is implemented in the `hyperfleet-applier` repository — a separate
component from the `hyperfleet-adapter` framework. Adapters produce desire
payloads; the applier alone owns SSA mechanics and the field manager identity,
keeping desire payloads free of any field-manager detail.

SSA tracks field ownership per `fieldManager` name in each resource's
`managedFields`. HyperFleet co-manages clusters with other controllers that may
also write to the same resources — notably ACM's ManifestWork agent, which
**also uses SSA** and is therefore a genuine collision risk, and, on Hosted
Control Plane clusters, HyperShift's control-plane-operator, which is checked
here for completeness even though it turns out **not** to use SSA at all (see
[Collision check](#collision-check) below). A field manager name that collides
with an SSA-participating controller causes silent field-ownership fights:
resources flap between controllers reasserting conflicting field values, and
there is no direct signal pointing at the cause.

This naming scheme must be settled before the apply controller exists —
renaming a field manager after resources carry `managedFields` entries in
production requires a migration (each affected resource must be re-applied to
transfer ownership), which is expensive to do retroactively.

## Naming Scheme

Use a single field manager name for the entire applier, across all resource
types:

```text
hyperfleet-applier
```

No per-resource-type suffix (e.g. `hyperfleet-applier-configmap`) is used. All
resources the ApplyDesire controller manages via SSA carry this same
`fieldManager` value. This value is **mandatory and non-overridable** — the
applier does not expose a `serverSideApply.fieldManager` configuration option;
`hyperfleet-applier` is a fixed constant, not a default. The field manager is
owned entirely by the applier; desire payloads do not carry or reference it.

## Collision check

| Controller | Uses SSA? | Field Manager | Collision with `hyperfleet-applier`? |
|---|---|---|---|
| ACM ManifestWork agent (`work-agent`) | Yes | `work-agent`, kubebuilder-validated against pattern `^work-agent` (custom overrides must keep the `work-agent` prefix, e.g. `work-agent-configmap`) | No — name does not start with `work-agent` |
| HyperShift control-plane-operator | No — uses `controllerutil.CreateOrUpdate` / `c.Update()`, not SSA | Kube-apiserver-assigned user-agent, typically `control-plane-operator` | No collision surface — HyperShift does not participate in SSA field ownership at all |

Sources: `open-cluster-management-io/api/work/v1/types.go`
(`DefaultFieldManager = "work-agent"`, prefix validation),
`open-cluster-management-io/ocm/pkg/work/spoke/apply/server_side_apply.go`
(confirms `metav1.ApplyOptions{FieldManager: fieldManager, Force: force}`
usage); HyperShift's `support/upsert/upsert.go` and the v2 component framework
(confirms `CreateOrUpdate` path, no SSA).

## Consequences

**Gains:**

- One name to configure, log, and grep for across the entire applier — no
  per-resource-type mapping to maintain.
- No collision with ACM's `work-agent` (prefix-validated) or HyperShift (no SSA
  participation).
- Simple to audit: any `managedFields` entry with manager `hyperfleet-applier`
  conventionally identifies ApplyDesire ownership. Note `fieldManager` is a
  client-supplied SSA identifier, not an authenticated identity — any principal
  permitted to submit the request can set it — so incident-response attribution
  of the *authenticated caller* must come from Kubernetes audit records, not
  `managedFields` alone.

**Trade-offs:**

- A single manager name means the applier cannot use SSA's per-resource
  field-splitting to let two different HyperFleet subsystems each own a distinct
  subset of fields on the same resource under separate manager identities. If
  that need arises later, it requires a new decision and a migration.
- Controllers whose field manager names are only visible at runtime (e.g. OLM,
  CVO) were not inspected against a live shared dev cluster as part of this
  decision — see [Follow-up](#follow-up).

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| Per-resource-type suffix (e.g. `hyperfleet-applier-configmap`, `hyperfleet-applier-secret`) | No current requirement for per-type field ownership differentiation; adds a naming/lookup table to maintain for no present benefit. Introducing a suffix later creates a new, distinct `fieldManager` identity from `hyperfleet-applier`'s perspective — every existing resource would need to be re-applied under the new name to transfer field ownership, the same migration cost described in Consequences above. Can still be introduced later if the need arises; it is just not free. |
| Reuse a generic/binary-derived name (e.g. default kube-apiserver user-agent) | Not deterministic across build/deploy contexts, and provides no clear signal in `managedFields` that HyperFleet owns the field. |

## Follow-up

- Before the ApplyDesire controller ships to a shared dev/production cluster,
  inspect live `managedFields` entries (e.g. via
  `kubectl get <resource> -o yaml --show-managed-fields`) for field managers not
  covered by source-code review here (OLM, CVO, and any other cluster-resident
  controllers) to confirm no unexpected collisions.

## References

- [HYPERFLEET-1424](https://redhat.atlassian.net/browse/HYPERFLEET-1424) — SPIKE: Choose the SSA field manager naming scheme
- [HYPERFLEET-1425](https://redhat.atlassian.net/browse/HYPERFLEET-1425) — Implement the ApplyDesire controller
- [Configuration Standard](../standards/configuration.md) — General config precedence rules apply to the applier; the field manager name itself is a fixed constant (see [Naming Scheme](#naming-scheme) above), not a configurable option
