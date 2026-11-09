---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-11-09
---

# 0036 — Management-Cluster Ingress and TLS Termination

## Context

[HYPERFLEET-1681](https://redhat.atlassian.net/browse/HYPERFLEET-1681) is the spike deciding the hub cluster's entry architecture and certificate issuance path — the cluster hosting the API and Desire Store gateways, distinct from the remote management clusters it serves. The entry point it starts from:

- **The gateway.** Envoy as the API ingress proxy ([ADR-0020](0020-envoy-authorino-api-gateway.md)), deployed hand-managed since the [HYPERFLEET-1476](https://redhat.atlassian.net/browse/HYPERFLEET-1476) epic (`helm/hyperfleet-gateway`): one public Service on port 8000, plaintext, no Gateway API or Ingress controller.
- **Undecided TLS termination.** [ADR-0018](0018-e2e-jwt-tls-architecture.md) assumed an ingress/LB terminates TLS; ADR-0020 replaced that with raw Envoy and recorded no ingress or TLS decision.
- **No public issuer.** cert-manager is installed, but only for the internal PKI (a self-signed CA and API and Authorino service certificates).
- **No issuance owner.** [HYPERFLEET-1536](https://redhat.atlassian.net/browse/HYPERFLEET-1536) terminates TLS from a secret but excludes issuance.

Constraints:

- **TLS from day one, issued automatically.** HTTP-01 needs public port 80 and a solver route cert-manager can drive; DNS-01 has no OCI solver with meaningful adoption ([HYPERFLEET-1573](https://redhat.atlassian.net/browse/HYPERFLEET-1573)).
- **The gateway trust contract is fixed.** [ADR-0020](0020-envoy-authorino-api-gateway.md) decides it, as amended by [ADR-0034](0034-gateway-authentication-modes.md)'s authentication modes; this record does not renegotiate it.
- **Operator bundle and disconnected installs.** The entry point ships as operator-reconciled operands ([HYPERFLEET-1534](https://redhat.atlassian.net/browse/HYPERFLEET-1534), extending [ADR-0019](0019-package-hyperfleet-as-operator.md) — Proposed — to the gateway); any addition must install from the bundle with no internet dependency.
- **Multiple gateways are coming.** [HYPERFLEET-1866](https://redhat.atlassian.net/browse/HYPERFLEET-1866) designs a private Desire Store gateway alongside the public API gateway; the entry must scale past one gateway without duplicating hand-written proxy configuration.
- **The private gateway's certificates must be verifiable by remote management clusters.** The Desire Store gateway serves per-partition hostnames to management clusters, including on-prem instances, and its issuance cannot depend on a third-party component without meaningful adoption.
- **Surrounding infrastructure is ready.** The `oci.hypershell.app` zone and ExternalDNS are live with the `service` source ([HYPERFLEET-1573](https://redhat.atlassian.net/browse/HYPERFLEET-1573)); ports 80 and 443 open through [ADR-0024](0024-oke-load-balancer-security-nsg.md)'s CCM-owned NSG when the Gateway's Service declares them.

## Decision

The management cluster adopts **Gateway API with Envoy Gateway** as its ingress layer. The hand-managed Envoy deployment is replaced by an Envoy Gateway-managed Envoy: the same data plane, configured through Gateway API resources instead of a hand-written bootstrap.

- **Single entry point.** One Gateway owns the public listeners — 443 for TLS, 80 for the ACME (Automated Certificate Management Environment) HTTP-01 solver — replacing port 8000 as the public surface.
- **Envoy terminates TLS.** cert-manager issues the public hostname's certificate over HTTP-01 (Let's Encrypt) on port 80, and Envoy serves it on 443 — the path for connected installs where HyperFleet owns the zone. A partner-owned domain supplies its certificate as the same TLS Secret the listener reads. The issued certificate is what [HYPERFLEET-1536](https://redhat.atlassian.net/browse/HYPERFLEET-1536)'s TLS termination and network-boundary work consumes.
- **The private gateway uses the internal CA.** Certificates are minted by the internal CA — the cert-manager pattern the chart already runs — with [HYPERFLEET-1866](https://redhat.atlassian.net/browse/HYPERFLEET-1866) owning trust distribution to the management clusters. A private CA is not bound by ACME's challenge-type limitations, so the certificate shape (per-partition or wildcard) is the implementation's choice; the public-CA path is rejected because no OCI DNS-01 solver has meaningful adoption.
- **Trust contract unchanged.** Early header stripping, Authorino enforcement, the trusted-credential hand-off, and the NetworkPolicy confinement — per [ADR-0020](0020-envoy-authorino-api-gateway.md) as amended by [ADR-0034](0034-gateway-authentication-modes.md)'s authentication modes — are unchanged by this record; Authorino keeps its existing Envoy integration.
- **New gateways are configuration, not deployments.** Any future gateway runs under the one Envoy Gateway controller with no per-gateway proxy configuration.
- **DNS keeps the Service path.** ExternalDNS continues to manage the public hostname's record from the Gateway's Service; the existing integration is unchanged.

## Mechanics

- **Gateway and Service.** Envoy Gateway generates the Gateway's public Service, which exposes the listeners; reaching them takes configuration in two places:
  - **On the generated Service:** ADR-0024's security-rule-management mode (without it the load balancer falls back to the shared security list and reintroduces the Terraform drift ADR-0024 prevents) and the ExternalDNS hostname.
  - **On the subnet security lists:** the load balancer → worker path, which the NSG does not cover — ADR-0024 leaves it to the subnets, and the node-port range (TCP 30000-32767) must be allowed between the load balancer and worker subnets.
- **Certificate hand-off.** cert-manager manages certificate issuance and renewal, storing the certificate in a Kubernetes TLS Secret referenced by the Gateway's HTTPS listener.
- **Trust contract.** HTTPRoutes define request routing, while SecurityPolicy configures external authorization through Authorino — scoped to the Gateway's HTTPS listener, so every route on 443 is authenticated by default and the ACME solver route cert-manager creates on the HTTP listener stays reachable without authentication. The HTTP listener serves only that solver route. Existing AuthConfig resources, header-handling behavior, and NetworkPolicy protections must be preserved.

## Consequences

**Gains:**

- One Envoy data plane and one network hop: no second proxy in front of the gateway.
- Certificate issuance is automated end to end where HyperFleet owns the zone — no manual certificate steps for the public hostname.
- Operator reconciliation ([HYPERFLEET-1534](https://redhat.atlassian.net/browse/HYPERFLEET-1534)) targets API resources instead of a raw Deployment plus ConfigMap.

**Trade-offs:**

- The `helm/hyperfleet-gateway` chart is reworked: the hand-written Envoy bootstrap (external-authorization wiring, wristband header plumbing, routing) becomes Gateway API resources.
- The E2E framework's documented access path — port-forward to the Envoy Service on port 8000 ([ADR-0018](0018-e2e-jwt-tls-architecture.md)) — moves to the generated Service's listeners.
- Sentinel and the Adapters call the API through the gateway's in-cluster Service on port 8000. The rework replaces that Service, and the chart rework keeps their calls on the gateway — through a stable in-cluster Service or the generated Service.
- Envoy Gateway and its CRDs join the operator bundle — a controller and API surface to mirror and track for disconnected installs; [HYPERFLEET-1534](https://redhat.atlassian.net/browse/HYPERFLEET-1534)'s operand list changes from the raw Envoy deployment to Envoy Gateway resources
- Automated issuance applies to connected deployments — HTTP-01 needs an ACME CA reachable at runtime. Disconnected installs need a different certificate path, tracked in [HYPERFLEET-1891](https://redhat.atlassian.net/browse/HYPERFLEET-1891).
- Authorization scoped to the HTTPS listener authenticates every route on 443 by default. The HTTP listener is the deliberate unauthenticated surface, serving only the ACME solver route; the chart rework confines it and a test case verifies nothing else answers on port 80.
- The private gateway's trust is ours to run: [HYPERFLEET-1866](https://redhat.atlassian.net/browse/HYPERFLEET-1866) designs CA distribution and rotation to the management clusters, and the same internal CA can serve the disconnected path ([HYPERFLEET-1891](https://redhat.atlassian.net/browse/HYPERFLEET-1891)).
- Envoy Gateway's release cadence and Gateway API maturity become upgrade inputs, pinned and upgrade-tested.

## Alternatives Considered

### Ingress controller in front of Envoy

**What:** A standard Ingress controller (NGINX, or an Envoy-based one) owns ports 80 and 443, terminates TLS, and proxies to the Envoy gateway Service.

**Why Rejected:**

- Adds a second L7 proxy in the path (controller → Envoy → API) and splits entry ownership across two components, without changing ADR-0020's trust contract
- An NGINX controller adds a second proxy technology to a stack standardized on Envoy; an Envoy-based controller adds a second Envoy fleet
- Costs the same bundle weight as Envoy Gateway without the multi-gateway path

### OCI-native / external termination

**What:** TLS terminates at Oracle load-balancing infrastructure or an external party before traffic reaches the cluster; the certificate lives outside the cluster.

**Why Rejected:**

- Issuance leaves cert-manager — no in-cluster HTTP-01 — and the certificate lifecycle moves to Oracle infrastructure
- The entry no longer installs in disconnected or on-prem environments from the operator bundle ([ADR-0019](0019-package-hyperfleet-as-operator.md))
- Usable only as a deployment-specific exception, not as the architecture

### Keep raw Envoy, add TLS to the existing deployment

**What:** The hand-managed Envoy deployment keeps its form and terminates TLS itself on a new 443 port.

**Why Rejected:**

- No supported cert-manager HTTP-01 solver exists without a controller-driven route on port 80 (Ingress or Gateway API); the solver endpoint is ephemeral per challenge, so static Envoy routing cannot answer it
- DNS-01 is not a fallback: no OCI solver with meaningful adoption
- Leaves the public hostname without an issuance path: the internal CA's certificates are not publicly trusted

### Public wildcard via an OCI DNS-01 webhook

**What:** The private Desire Store gateway's wildcard certificates come from a public ACME CA over DNS-01, using a third-party cert-manager webhook for OCI DNS. Publicly trusted certificates need no trust distribution — management clusters verify them with standard CA bundles.

**Why Rejected:**

- No OCI DNS-01 webhook with meaningful adoption exists: the most-adopted [community implementation](https://github.com/clicktruck/cert-manager-webhook-oci) has six stars and last moved seven months before this record, a newer [fork](https://github.com/the-i-engineers/cert-manager-webhook-oci) is maintained but has two stars and a single contributor, and [Oracle's implementation](https://github.com/oracle-cne/cert-manager-webhook-oci) has zero adoption
- Adds DNS zone write access from the management cluster to the solver's IAM surface

## References

- [ADR-0020](0020-envoy-authorino-api-gateway.md) — Envoy and Authorino as the API authentication gateway (amended by this record: deployment form)
- [ADR-0034](0034-gateway-authentication-modes.md) — Gateway Authentication Modes and Wristband Trust, amending ADR-0020's contract
- [ADR-0018](0018-e2e-jwt-tls-architecture.md) — the assumed ingress/LB TLS termination this record replaces
- [ADR-0024](0024-oke-load-balancer-security-nsg.md) — CCM-owned frontend NSG that opens the Gateway Service's ports
- [ADR-0019](0019-package-hyperfleet-as-operator.md) — operator packaging and disconnected-install constraint
- [Gateway API](https://gateway-api.sigs.k8s.io/), [Envoy Gateway](https://gateway.envoyproxy.io/), [cert-manager ACME HTTP-01](https://cert-manager.io/docs/configuration/acme/http01/)
