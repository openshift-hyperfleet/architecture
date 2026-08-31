---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-09-01
---

# 0021 — External Platform for the Guest in OCI Hosted Clusters

## Context

HyperFleet is building support for HyperShift hosted OpenShift clusters on Oracle Cloud Infrastructure (OCI). Two platform types live at two different layers, and it is essential not to conflate them:

- **The HostedCluster platform type** (`HostedCluster.spec.platform.type` in `hypershift/api`) drives how the hosted control plane and worker infrastructure are provisioned. HyperFleet is delivering this as a **first-class `OCI` type**, behind a feature gate, with `OCIPlatformSpec` driving the Cluster API Provider for OCI (CAPOCI) to create the VCN, load balancers, and machines. This is not in scope of this decision — it is the surrounding feature.
- **The guest cluster platform type** (`Infrastructure.status.platformStatus.type` in `openshift/api`) is what the in-guest cluster operators — cloud controller manager, storage, image registry, ingress, machine API — switch on. This ADR decides **only** this layer.

This spike ([HYPERFLEET-1593](https://redhat.atlassian.net/browse/HYPERFLEET-1593)) answers: should the guest present the **External** platform (`platformStatus.type: External` with `platformName: OCI`), or a **first-class `OCI` platform type in `openshift/api`** that every cluster operator learns to handle? The epic framing is explicit: "the platform model the guest cluster sees (External or a first-class OCI platform)" ([HYPERFLEET-1539](https://redhat.atlassian.net/browse/HYPERFLEET-1539)).

Two pieces of evidence anchor the answer. First, `openshift/api` documents `ExternalPlatformType` as a deliberately generic provider whose `platformName` is informational only and not to be used for decision-making (`config/v1/types_infrastructure.go`); its only per-platform switch is `platformStatus.external.cloudControllerManager.state`. Standalone Red Hat OpenShift on OCI already ships GA on this path (installer [#7217](https://github.com/openshift/installer/pull/7217) introduced the generic External type; assisted-service [#5548](https://github.com/openshift/assisted-service/pull/5548) sets it for OCI): Oracle supplies `oci-cloud-controller-manager` and the OCI CSI driver and sets `cloudControllerManager.state: External`. Second, HyperFleet's own prototype ran a full 4.20 hosted control plane on OKE on 2026-08-25 with **OCI mapped to the External platform** for the guest, confirming the control plane and the guest platform configuration render correctly before any cloud integration is added. That run did not exercise the guest side — no worker has joined (CAPOCI was not deployed), so the worker-facing consequences of External described below come from reading each operator's source, not from a running guest.

## Decision

The guest cluster presents the **External platform**: `Infrastructure.status.platformStatus.type: External`, `Infrastructure.spec.platformSpec.external.platformName: OCI`, and `Infrastructure.status.platformStatus.external.cloudControllerManager.state: External`. HyperFleet does **not** add a first-class `OCI` platform type to `openshift/api`.

This is orthogonal to the HostedCluster using the first-class `OCI` type in `hypershift/api`: CAPOCI provisions the infrastructure and machines, while the guest OpenShift cluster it produces reports `External`. The GCP platform is the reference for the *set* of in-guest components that must exist; HyperFleet builds that set as operands rather than as `openshift/api` platform cases.

Because no in-guest cluster operator provides OCI-specific integration on `External` (see the matrix below), HyperFleet owns the OCI-specific operands a named guest platform would otherwise provide: the OCI cloud controller manager, a CSI driver and default `StorageClass`, the cloud-provider `ConfigMap` and Infrastructure platform status, image-registry storage, and DNS. These operands are selected on the management side by the HostedCluster's first-class `OCI` platform type (`HostedCluster.spec.platform.type: OCI`), not by the guest's informational `platformName`. This ADR decides only that these must be **present**; which component owns each one's lifecycle is left to the delivery stories. Delivery is tracked in the Control Plane Operator Integration epic ([HYPERFLEET-1539](https://redhat.atlassian.net/browse/HYPERFLEET-1539)).

### Cluster operators affected under each option

For each in-guest cluster operator, `External` requires HyperFleet to supply what the operator would render for a named guest platform. All five switch on `PlatformType`; none provides OCI-specific integration on `External` — some render nothing, others reconcile to a generic default (verified against each operator's source on the `release-4.20` branch). The live consequence: on External with no cloud integration, a joining worker stays tainted as uninitialised, the guest has no storage class, the registry has nowhere to store, and nothing resolves the apps wildcard (the `api`/`api-int` records are the environment administrator's responsibility under External, not HyperFleet's).

| Cluster operator | On External (chosen path) | On a first-class guest OCI platform | HyperFleet owns under External |
|------------------|---------------------------|-------------------------------------|--------------------------------|
| cloud-controller-manager-operator | No CCM rendered (no `External` case → default returns no resources). The node-initialization taint semantics come from `cloudControllerManager.state: External`: new nodes stay tainted as uninitialized until an external CCM initializes them. (In HyperShift the control plane operator already renders `--cloud-provider=external` for every platform, so that flag is not what this field controls here.) | An `OCI` case renders and manages an OCI CCM. | Deploy and manage the OCI CCM (`oci-cloud-controller-manager`) as an operand. |
| cluster-storage-operator | No CSI driver operator started (no `Platform: External` entry). | An OCI `CSIOperatorConfig` starts an OCI CSI driver operator. | Ensure an OCI block-volume CSI driver and a default `StorageClass` are present (owner decided by the storage story). |
| cluster-image-registry-operator | No backend configured → registry bootstraps as `managementState: Removed`. | An `OCI` case wires an OCI Object Storage backend. | Enable the registry by flipping `managementState` from `Removed` to `Managed` and configuring storage — OCI Object Storage (S3-compatible) for production, `emptyDir` only for dev/test (it loses images on registry-pod restart and cannot scale past one replica). The S3 endpoint, credential Secret, and rotation are delivery-story detail. |
| cluster-ingress-operator | `HostNetwork` publishing (default) and a no-op (`FakeProvider`) DNS provider — no cloud LB, no DNS records. | LoadBalancerService publishing and an OCI DNS provider. | Set the rendered `IngressController` to `LoadBalancerService` publishing (not the `HostNetwork` default) so the OCI CCM provisions the apps-wildcard LB, and supply the apps-wildcard DNS records; the `api`/`api-int` records are owned by the environment administrator under External. |
| machine-api-operator / control-plane-machine-set | No-op controller (`clusterAPIControllerNoOp`); in-guest Machine API not run. | Identical — hosted-cluster guests never run in-guest Machine API under either option. | Worker machines come from HyperShift NodePools via CAPOCI, the same as every other hosted-cluster platform (a point in this decision's favour, not against it). |

## Consequences

**Gains:**

- Builds on the proven, GA, Red Hat-certified OCI contract. `External` + Oracle's CCM and CSI is exactly how standalone OpenShift on OCI already runs, and HyperFleet's own prototype ran a hosted control plane on OKE this way, so the guest cloud-provider and storage contracts are validated rather than invented.
- Avoids adding OCI cases to `openshift/api` and its downstream operators — a change spanning repositories the team does not own and, historically, multiple OpenShift releases (Nutanix: enhancement proposal to 4.11 GA ≈ 1 year).
- Keeps OCI-specific in-guest logic inside HyperFleet-owned operands, consistent with HyperFleet's cloud-agnostic-core / provider-specific-in-operands principle, and mirrors how GCP's in-guest components were built (the epic's reference).
- No conflict with the first-class OCI HostedCluster work: CAPOCI-based provisioning and an External guest are complementary, so both workstreams proceed in parallel.

**Trade-offs:**

- The operational lifecycle of the OCI CCM and CSI driver — deployment, upgrades, monitoring, and credential plumbing — falls to HyperFleet rather than to an in-guest cluster operator as it would on a named guest platform. This ADR fixes only that the burden is HyperFleet's; which HyperFleet component owns each operand is left to the delivery stories (see Decision). Their images are not in the OpenShift release payload, another question for those stories.
- `External` is a generic contract, so there is no in-guest platform-status payload (region, compartment) beyond what HyperFleet renders explicitly; `ExternalPlatformStatus` has no such fields, so anything a named `platformStatus.oci` would expose must be carried in the cloud-provider `ConfigMap` (or a HyperFleet-owned resource) instead.
- Divergence from how OpenShift integrates first-class guest platforms (GCP/Azure/Nutanix). If a future requirement genuinely needs in-guest operators to switch on OCI natively, that would be a separate, larger `openshift/api` effort (see Alternatives).

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| First-class `OCI` platform in `openshift/api` for the guest (day 1) | Requires an enhancement proposal plus coordinated changes across `openshift/api`, `openshift/installer`, and every platform-switching guest operator — repos the team does not own, historically ~1 year and multiple releases (Nutanix). The prototype already proved the guest runs correctly on External, so the cost buys nothing for day one. It remains available if a real requirement ever needs in-guest operators to switch on OCI natively. |
| Skip the first-class OCI HostedCluster type; drive everything from a generic HostedCluster surface | Out of scope of this ADR, and contradicted by the feature: worker provisioning needs CAPOCI, which needs the `OCI` HostedCluster type and `OCIPlatformSpec` (feature gate, VCN/subnets, machine templates). The guest-External decision does not remove that need. |
| Commit now to migrating the guest to first-class on a fixed timeline | Prematurely commits to the larger `openshift/api` investment before any requirement demands in-guest operators switch on OCI natively. It remains available, gated on a real need. |

## References

- [HYPERFLEET-1593](https://redhat.atlassian.net/browse/HYPERFLEET-1593) — [SPIKE] Decide External platform versus a first-class OCI platform for hosted clusters (this spike).
- [HYPERFLEET-1539](https://redhat.atlassian.net/browse/HYPERFLEET-1539) — [HO] Control Plane Operator Integration for OCI (epic; the guest-path delivery is tracked here).
- [openshift/api `config/v1/types_infrastructure.go`](https://github.com/openshift/api/blob/release-4.20/config/v1/types_infrastructure.go) — `ExternalPlatformType`, `ExternalPlatformSpec` (informational-only `platformName`), `CloudControllerManagerStatus`.
- [openshift/installer#7217](https://github.com/openshift/installer/pull/7217) — introduces the generic External platform type in the installer (OCPCLOUD-2036, merged 2023-07-21).
- [assisted-service#5548](https://github.com/openshift/assisted-service/pull/5548) — sets `CloudControllerManager: External` for OCI in standalone OpenShift.
- [OpenShift External platform onboarding guide](https://docs.providers.openshift.org/platform-external/) — partner responsibilities under External.
- Cluster operator sources (behavior on `External`, pinned to the `release-4.20` branch used for the matrix): [cluster-cloud-controller-manager-operator](https://github.com/openshift/cluster-cloud-controller-manager-operator/blob/release-4.20/pkg/cloud/cloud.go), [cluster-storage-operator](https://github.com/openshift/cluster-storage-operator/blob/release-4.20/pkg/operator/csidriveroperator/csioperatorclient/gcp-pd.go), [cluster-image-registry-operator](https://github.com/openshift/cluster-image-registry-operator/blob/release-4.20/pkg/storage/storage.go), [cluster-ingress-operator](https://github.com/openshift/cluster-ingress-operator/blob/release-4.20/pkg/operator/controller/ingress/controller.go), [machine-api-operator](https://github.com/openshift/machine-api-operator/blob/release-4.20/pkg/operator/config.go).
