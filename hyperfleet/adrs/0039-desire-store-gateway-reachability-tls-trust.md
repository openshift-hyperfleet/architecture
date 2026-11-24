---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-11-24
---

# 0039 — Desire Store Gateway Reachability and TLS Trust

## Context

The Desire Store gateway must serve remote management clusters in Oracle Cloud Infrastructure (OCI) and on premises, at a planning scale of 10,000 partitions. The [high-level design](../docs/desire-store-hld.md) assumed private-only reachability, but no private path is provisioned today.

[ADR-0036](0036-management-cluster-ingress-tls-termination.md) established the hub's public entry and required an internal certificate authority (CA) for Desire Store. It left gateway reachability, certificate coverage, and trust distribution open.

## Decision

- **Public by default:** Use a separate Desire Store Gateway under the hub's one Envoy Gateway controller, served by its own load balancer, the controller's default of one Envoy proxy fleet per Gateway. Require listener-scoped, fail-closed authentication through the dedicated Authorino. There is no unauthenticated mode.
- **Private deployment paths:** Deployments can resolve the same hostnames to a private endpoint without changing the certificate or verification rules. Private-only deployments use an internal load balancer, with no public address or public DNS records for the gateway.
- **Dedicated server identity:** Use a rotatable internal CA separate from the hub's in-cluster root. Issue one certificate per served zone covering both `desire-store.<zone>` and `*.desire-store.<zone>`.
- **Mandatory client verification:** The Applier verifies the certificate chain against the distributed CA bundle and checks the hostname. Production clients cannot bypass either check.

This record amends [ADR-0036](0036-management-cluster-ingress-tls-termination.md)'s single-public-listener slice only.

## Mechanics

- **Trust bootstrap:** The authenticated registration handoff carries the CA bundle to the management-cluster operator at onboarding, and the operator loads it into the Applier's operand configuration for connected and disconnected installs alike. The Applier serves no endpoint to receive the bundle, and the hub opens no connection into the management cluster to deliver it. The bundle is not secret; its integrity depends on the same registration channel that protects the identity-to-partition binding.
- **CA rollover:** Rotate trust without interrupting clients, in this order:
  - **Bundle rollout:** Distribute both roots through the registration handoff, the same operator-mediated channel for initial registration, re-registration, and rollover delivery to already-enrolled clusters. The Applier reloads the bundle in place where supported; otherwise the operator rolls the pods.
  - **Cutover gate:** Serve the certificate signed by the new CA only after every enrolled management cluster holds both roots, not a subset; the hub operator confirms rollout completion per cluster before proceeding. The concrete completion signal and stale-bundle alerting are implementation decisions this record does not fix.
  - **Certificate pickup:** The Envoy Gateway controller delivers the reissued certificate Secret to the gateway's proxies, the form [ADR-0036](0036-management-cluster-ingress-tls-termination.md) decides; [ADR-0038](0038-gateway-certificate-rotation.md) owns rolling restarts for workloads not yet in that form.
  - **Retirement:** Retire the old root only after every gateway instance serves the new certificate and an overlap margin has elapsed; a client that drops the old root earlier fails verification against an instance still serving the old certificate.
- **Issuer discovery:** The Applier initiates HTTPS to the gateway. This does not create a reverse path: issuer publication must not assume the hub can initiate connections to management clusters at request time.

## Consequences

**Gains:**

- OCI and on-premises clusters with outbound HTTPS can onboard without peering, a circuit, or a tunnel. Trust bootstrap does not require internet access.
- A wildcard DNS record and a wildcard certificate cover all partition names in a served zone, without per-partition DNS records or certificate issuance.

**Trade-offs:**

- The public endpoint adds exposure to internet attacks and denial of service. Fail-closed authentication and client TLS verification protect access and server identity, not availability. Rate limiting can mitigate but does not eliminate exposure.
- The dedicated load balancer keeps Desire Store traffic and failures separate from the general API gateway's data plane, at the cost of one more public load balancer to operate.
- Deployments that require a private path must provision it and own its resolver policy.
- A stale CA bundle on a management cluster fails TLS verification, a failure mode distinct from an unreachable gateway that the Applier must signal separately.

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| OCI peering and private DNS as the default | Requires network provisioning and does not cover clusters without a private path into OCI. |
| Customer-provisioned VPN or FastConnect as a prerequisite | Makes onboarding depend on customer network work. |
| Outbound-initiated tunnel | Adds an always-on hub relay and per-cluster tunnel clients. |
| Public CA certificates | Ruled out by ADR-0036. |
| Per-partition certificates | Listener limits and issuance overhead are a poor fit at planning scale. Partition revocation belongs to caller credentials, not the server certificate. |
| Mutual TLS for client authentication | Adds a second credential lifecycle without replacing the JSON Web Token (JWT) identity and partition binding in the [detailed design](../docs/desire-store-dd.md#gateway-trust-contract). Remains an option for hardening. |

## References

- [Connectivity and TLS trust spike](../docs/spike-desire-store-gateway-connectivity-tls.md): option comparison, scaling limits, and probe results.
- [ADR-0033](0033-postgres-transport-security.md): precedent for verifying both the server's certificate chain and hostname.
