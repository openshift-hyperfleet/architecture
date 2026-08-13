---
Status: Proposed
Owner: HyperFleet Architecture Team
Last Updated: 2026-08-12
---

# 0019 - Package HyperFleet as a Kubernetes Operator

## Context

HyperFleet ships its components (API, Sentinel, Adapters, Broker) as Helm charts under an umbrella chart ([ADR-0016](0016-helm-oci-distribution.md)). Configuring an install still spans many surfaces - per-chart `values.yaml`, ConfigMap-delivered AdapterConfig and SentinelConfig files, broker credentials, and database secrets - which onboarding and support experience show is a recurring source of day-1 install and day-2 debugging cost. Helm also has no reconciliation loop (no drift correction after install) and no installation-health status.

[ADR-0004](0004-sentinel-stateless-polling-architecture.md) rejected a CRD operator for Sentinel's *data-plane* triggering (per-cluster CRD overhead, modifying target-cluster APIs). This decision concerns a different plane - hub-side packaging and configuration of HyperFleet itself - and installs CRDs only on the hub, never on target clusters. Neither of the two partner environments (managed cloud OpenShift; on-prem air-gapped) has firm configuration requirements yet, which the decision accounts for by shipping the API at `v1alpha1`.

## Decision

Package HyperFleet as a Go-based Kubernetes operator (`hyperfleet-operator`), driven by a single cluster-scoped custom resource `HyperFleetConfig` plus the Secrets and ConfigMaps it references. It consumes a partner-provided Postgres via secret reference; it does not provision Postgres.

- **The CR is the entire partner contract.** The spec expresses partner intent only; everything internal becomes an operator implementation detail, changeable across releases. The CR stays deliberately minimal - each field is a long-term compatibility commitment - so there is no general-purpose override field; needs beyond the exposed fields are handled internally (for example, a new bundle) rather than by escaping the contract.
  - Partner sets in the spec: a `bundle` (defined below), credential locations, auth issuer/audience, TLS, and a sizing profile.
  - Operator owns internally: broker topology, adapter CEL expressions, Sentinel intervals, and inter-component wiring.
- **A `bundle` is a named, partner-meaningful deployment of HyperFleet** (e.g. cloud-hosted, disconnected) that the operator resolves into a concrete component set. It is a different concept from the OLM `registry+v1` bundle in Packaging below (the artifact that installs the operator); the CR field is named `bundle` to match the operator implementation.
- **The operator corrects drift.** It watches the resources it creates and re-applies desired state on divergence, excluding fields owned by other controllers (e.g. HPA-managed `spec.replicas`).
- **Packaging.** Ship an OLM `registry+v1` bundle for classic OLM and OLM v1 (OpenShift 4.18+, the OLM v1 floor), plus a plain-manifest path for non-OLM clusters (Kubernetes 1.29+). A single `HyperFleetConfig` is enforced with a `metadata.name == cluster` CEL rule, since OLM v1 on 4.18 has no webhooks.
- **Status.** The CR reports `Available`, `Progressing`, and `Degraded` conditions (OpenShift ClusterOperator convention, minus `Upgradeable`) plus per-component conditions. This is a distinct layer from the existing adapter- and resource-level condition vocabularies ([ADR-0007](0007-conditions-based-status-model.md), [ADR-0008](0008-dynamic-status-aggregation.md)), which are unchanged.
- **Phased delivery.** The API ships in the operator first - it is shared by every environment and exercises every pattern the operator needs (CR contract, reconciliation, status, packaging, upgrades). Sentinel, adapters, and broker follow. During the transition partners run a hybrid model (operator-managed API, Helm-managed everything else).

## Consequences

**Gains:**

- Collapses the partner-facing surface to one CR plus referenced secrets/ConfigMaps (the end state, reached once all components are operator-managed).
- Kubernetes-native install, upgrade, and installation-health status.
- Drift correction, which Helm does not provide after install.
- A single versioned API that decouples internal evolution from the partner-visible contract.

**Trade-offs:**

- Operator development and testing overhead (controller-runtime, envtest, OLM packaging, upgrade testing).
- A single reconcile loop owns all components, so a wedged component can delay reconciliation of the others. Accepted for Phase 1 simplicity; revisit if it causes problems in practice.
- During phased delivery the hybrid model adds the operator surface on top of the existing Helm/ConfigMap surfaces without removing any, so total configuration load rises until all components are operator-managed.
- Partners lose direct AdapterConfig and per-component Helm access (intentional) and lose `helm template`/`helm diff` preview unless an equivalent dry-run is built.
- The operator is a privileged single point of failure with a cluster-scoped install footprint (its own CRD and ClusterRole).
- Deleting the CR cascade-deletes operator-managed resources via owner references; partner-provided Postgres and fleet data survive.

## Open Questions

- Whether partners can extend HyperFleet with custom adapters for infrastructure the operator does not ship.
- Whether `AdapterConfig` stays a ConfigMap-delivered file or becomes a CRD once adapters enter the operator - in either case operator-internal, not a partner-authored surface, so the single-CR contract holds.
- Whether the operator adopts existing Helm-managed resources or requires a clean cutover. In both cases Helm stops managing the API resources first; the operator then adopts them or creates replacements, so each resource has one manager at all times and the two never reconcile the same object.
- Whether an explicit pre-delete gate is needed to prevent accidental teardown. A finalizer only delays deletion, and on OLM v1 deleting the `ClusterExtension` removes the operator and its CRD, making uninstall destructive to the installation (though partner-owned Postgres and fleet data, being external, survive regardless).

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| Continue with Helm-only delivery ([ADR-0016](0016-helm-oci-distribution.md)) | No drift correction, no installation-health status, no OLM lifecycle; partners still juggle multiple values schemas. |
| Improve the umbrella chart (consolidated values, validation) | Reduces config complexity but still no drift detection, health reporting, or OLM integration. The right choice only if those are not needed. |
| Helm-based operator (operator-sdk wrapping existing charts) | Cheapest single-CR surface, but Helm-rendered manifests limit status aggregation, upgrade sequencing, and cross-component coordination. Viable fallback. |
| ArgoCD Application-of-Applications | Adds an ArgoCD dependency neither partner runs, with no single-CR surface or status aggregation. |
| One CRD per component (multi-CR) as the partner contract | Shared concerns (database, auth) need an orchestrator or manual wiring. The operator may still use per-component CRs internally. |
| Defer until partners produce firm requirements | The configuration surface grows with each component, compounding migration cost; `v1alpha1` lets the team iterate now with low commitment. |

## References

- [ADR-0004 - Sentinel as a Stateless Polling Reconciliation Loop](0004-sentinel-stateless-polling-architecture.md) - rejected a CRD operator for the data plane; this ADR addresses hub-side packaging.
- [ADR-0016 - Helm OCI Distribution via Konflux](0016-helm-oci-distribution.md) - current delivery mechanism, superseded for partner-facing delivery.
- [HyperFleet Configuration Standard](../standards/configuration.md) - the operator maps CR fields to these existing mechanisms.
- [HYPERFLEET-1403](https://redhat.atlassian.net/browse/HYPERFLEET-1403) - HyperFleet Operator Phase 1 epic.
