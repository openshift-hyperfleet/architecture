---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-08-11
---

# 0020 - Envoy and Authorino as the API Authentication Gateway

## Context

HyperFleet's API is accessed by two caller types: external callers (human operators) authenticating with OIDC JWTs, and internal callers (Sentinel and Adapters) using Kubernetes projected service account tokens. Before this decision, each component validated credentials independently in application code.

Three structural problems drove the change:

1. **No single audit point.** External and internal traffic had no canonical interception point; a client-supplied identity header could reach application logic unchallenged.
2. **Identity configuration lived in application code.** Switching tenant models required rebuilding and redeploying the API.
3. **No enforceable network boundary.** Nothing prevented an in-cluster workload from reaching the API pod directly, bypassing any authentication layer.

A [proof-of-concept](https://github.com/ciaranRoche/hyperfleet-infra/tree/poc/multitenancy-v2) validated the approach. The architecture team reviewed the results and made the decision.

## Decision

HyperFleet adopts **Envoy** as the API ingress proxy and **Authorino** as its external authorization service. All API traffic, external and internal, passes through this gateway. No other route to the API is permitted.

The gateway enforces the following contract:

- **Early header stripping.** Envoy removes client-supplied identity and tenant headers before the authorization filter runs, so forged headers cannot reach Authorino or the API regardless of what the client sends.
- **Authorino authenticates every caller via AuthConfig CRs.** External callers are validated against an OIDC issuer. Internal callers (Sentinel, Adapters) are validated via Kubernetes TokenReview against a subject allowlist; an in-cluster service account with the correct audience but an unlisted subject is denied at the gateway. Identity providers, claim mappings, and per-deployment tenant models are declared in AuthConfig custom resources (not application code) so switching a tenant model is a configuration change with no rebuild required.
- **Trusted header injection.** After successful authorization, Authorino injects identity and tenant headers derived from validated claims. The API treats these as authoritative.
- **API trusts only injected headers.** The API trusts the gateway-injected headers for identity. In-app JWT validation is retained as defense-in-depth.
- **Network boundary is a security requirement.** A NetworkPolicy restricts API pod ingress to the Envoy pod only. The gateway is not an optional optimization; bypassing it must be structurally impossible, not merely discouraged.

## Consequences

**Gains:**

- One audit point for all API traffic, internal and external, without per-component authentication logic.
- Adding an identity provider or switching a tenant model is an AuthConfig change (no code change, no rebuild, no redeployment of any HyperFleet component).
- Forged identity headers are stripped before any application logic runs.
- The network boundary is enforceable and testable.

**Trade-offs:**

- The gateway is on the availability path of every API call, including internal Sentinel and Adapter traffic. A highly available deployment with health checks is required from day one. A gateway outage is a full API outage.
- Header stripping must happen at an early filter stage, before the authorization filter runs. Using a later removal mechanism would delete the headers Authorino injects. This ordering constraint is non-obvious and must be guarded by a test.
- All internal services must route API traffic through Envoy. Pointing directly at the API service bypasses authentication and is rejected. Helm charts for Sentinel and Adapters must expose and correctly default the API base URL.

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| **Application-only middleware** | No shared audit point; identity config changes require rebuilds across every component; no enforceable network boundary. |
| **Per-service sidecar (service mesh)** | Does not provide a single ingress point for external callers. Sidecars can be layered on later without changing the trust model established here. |
| **OPA (Open Policy Agent)** | Policy engine, not an authentication service. Does not validate OIDC JWTs or perform TokenReview; a separate validation layer would be required alongside it. Authorino covers both in one CR-driven model. |
| **No shared boundary** | Per-component credential validation; no canonical audit point; identity config embedded in application deployments. Incompatible with the multi-tenant model where header provenance must be guaranteed. |

---

## References

- **POC:** [`poc/multitenancy-v2` branch of `hyperfleet-infra`](https://github.com/ciaranRoche/hyperfleet-infra/tree/poc/multitenancy-v2)
- **Epic:** [Envoy and Authorino Gateway Deployment](https://redhat.atlassian.net/browse/HYPERFLEET-1476)
- **Sibling epic:** [Multi-Tenant Identity and Authorization](https://redhat.atlassian.net/browse/HYPERFLEET-1164)
- **External resources:**
  - [Envoy proxy documentation](https://www.envoyproxy.io/docs/envoy/latest/)
  - [Authorino documentation](https://github.com/Kuadrant/authorino)
  - [Kubernetes TokenReview API](https://kubernetes.io/docs/reference/kubernetes-api/authentication-resources/token-review-v1/)
