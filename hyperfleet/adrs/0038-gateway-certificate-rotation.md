---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-11-11
---

# 0038 — Gateway Certificate and Key Rotation

## Context

[HYPERFLEET-1523](https://redhat.atlassian.net/browse/HYPERFLEET-1523) asks how certificate rotation should be handled. This record covers every certificate and key on the gateway request path and how to handle the rotation in both Helm-managed and operator-managed deployments.

Secrets that hold the certificates, root CA and signing key:

| Secret | Created by | Mounted by |
|--------|-----------|-------------|
| `hyperfleet-gateway-ca-cert` — root CA | cert-manager | Envoy, HyperFleet API |
| `authorino-server-cert` — Authorino listener | cert-manager | Authorino |
| `authorino-oidc-server-cert` — Authorino OIDC discovery server | cert-manager | Authorino |
| `hyperfleet-api-server-cert` — API serving cert | cert-manager | HyperFleet API |
| `hyperfleet-wristband-signing-key` | Chart hook, `openssl genrsa` | Not mounted — the API gets the public key from Authorino's JSON Web Key Set (JWKS) URL |

## Decision

The Authorino Deployment is restarted with a rolling restart. Authorino loads the mounted `authorino-server-cert` and `authorino-oidc-server-cert` at startup, thus requires a rolling restart on change.
The Envoy Deployment is also restarted with a rolling restart.
To roll the Authorino and Helm-managed Envoy Deployments, Stakater Reloader is used. The operator-managed deployment already has the machinery to restart workloads when a watched Secret changes.
After Envoy proxies are managed by the Envoy Gateway controller ([ADR-0036](0036-management-cluster-ingress-tls-termination.md)), some Secret changes are picked up by the controller and may no longer require a rolling restart.

HyperFleet API ([HYPERFLEET-1917](https://redhat.atlassian.net/browse/HYPERFLEET-1917)), Sentinel ([HYPERFLEET-1678](https://redhat.atlassian.net/browse/HYPERFLEET-1678)) and Adapter ([HYPERFLEET-1677](https://redhat.atlassian.net/browse/HYPERFLEET-1677)) pods use a file-system watcher that updates the certificate and CA bundle in memory when the mounted Secret changes.

## Consequences

**Gains:**

- Rotation is picked up automatically, no manual step needed.
- Restarts are limited only to the Deployments that require it. Workloads which can update the in-memory data after the Secret changes are not restarted at all.

**Trade-offs:**

- Stakater Reloader becomes a dependency of Helm-managed installs: one more controller to deploy. It also needs permission to read Secrets.
- If Reloader is down when a Secret changes, nothing restarts the pods. The operator can have additional control and ensure the certificates have been picked up and are served.
- Once Envoy Gateway manages the proxies, Envoy no longer needs a restart, and Reloader remains only for Authorino.

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| Rolling restart used for the API, Sentinel and Adapter | Sentinel and Adapter currently run as single-replica Deployments. |
| Envoy SDS (Secret Discovery Service, file-based hot reload) | Use the required Stakater Reloader. Envoy Gateway delivers certificates to Envoy over SDS itself once [ADR-0036](0036-management-cluster-ingress-tls-termination.md) lands. |
| Istiod or a service mesh | A second control plane increases complexity without using most of the functionality. |

## References

- [ADR-0020](0020-envoy-authorino-api-gateway.md) — Envoy and Authorino as the API authentication gateway
- [ADR-0036](0036-management-cluster-ingress-tls-termination.md) — Management-Cluster Ingress and TLS Termination ([HYPERFLEET-1681](https://redhat.atlassian.net/browse/HYPERFLEET-1681)), which moves the gateway to Envoy Gateway
