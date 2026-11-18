---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-11-11
---

# 0038 — Gateway Certificate and Key Rotation

## Context

[HYPERFLEET-1523](https://redhat.atlassian.net/browse/HYPERFLEET-1523) asks how certificate rotation should be handled. This record covers certificates and keys on the gateway request path and how the deployments handle the update of any of the secrets below.

Secrets that hold the certificates, root CA and signing key and are currently used in the hyperfleet-infra deployment:

| Secret | Created by | Mounted by |
|--------|-----------|-------------|
| `hyperfleet-gateway-ca-cert` — root CA | cert-manager | Envoy, HyperFleet API |
| `authorino-server-cert` — Authorino listener | cert-manager | Authorino |
| `authorino-oidc-server-cert` — Authorino OIDC discovery server | cert-manager | Authorino |
| `hyperfleet-api-server-cert` — API serving cert | cert-manager | HyperFleet API |
| `hyperfleet-wristband-signing-key` | Chart hook, `openssl genrsa` | Not mounted — the API gets the public key from Authorino's JSON Web Key Set (JWKS) URL; Authorino reads it from AuthConfig CR. |

The rotation of `hyperfleet-wristband-signing-key` is tracked in ([HYPERFLEET-1756](https://redhat.atlassian.net/browse/HYPERFLEET-1756)).

## Decision

HyperFleet operator manages the rolling restart of HyperFleet API, Sentinel and Adapter, Envoy and Authorino. Sentinel and Adapter currently run as single-replica Deployments and must be adjusted to allow this.

After Envoy proxies are managed by the Envoy Gateway controller ([ADR-0036](0036-management-cluster-ingress-tls-termination.md)), some Secret changes are picked up by the controller and may no longer require a rolling restart.

## Consequences

**Gains:**

- Rotation is picked up automatically, manual restart needed only in dev environments.
- Rolling restarts are managed centrally by the operator.
- No new dependency needed as the operator-managed deployment already has the machinery to restart workloads when a watched Secret changes.

**Trade-offs:**

- The current Helm-managed deployment gets no rotation since the CI environment won't benefit from this due to short lifespan of the deployment. Locally running kind deployments in dev environment must be rolled manually.
- Once Envoy Gateway manages the proxies, Envoy restart mechanism must be reevaluated.

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| File-system watcher used for the API, Sentinel and Adapter | Authorino loads the mounted `authorino-server-cert` and `authorino-oidc-server-cert` at startup, thus requires a rolling restart on change. This would introduce two different mechanisms describing how to pick up changes in the Secrets.|
| Envoy SDS (Secret Discovery Service, file-based hot reload) | Similar argument as above. In addition, Envoy Gateway delivers certificates to Envoy over SDS itself once [ADR-0036](0036-management-cluster-ingress-tls-termination.md) lands. |
| Istiod or a service mesh | A second control plane increases complexity without using most of the functionality. |

## References

- [ADR-0020](0020-envoy-authorino-api-gateway.md) — Envoy and Authorino as the API authentication gateway
- [ADR-0036](0036-management-cluster-ingress-tls-termination.md) — Management-Cluster Ingress and TLS Termination ([HYPERFLEET-1681](https://redhat.atlassian.net/browse/HYPERFLEET-1681)), which moves the gateway to Envoy Gateway
