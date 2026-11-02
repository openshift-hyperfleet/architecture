---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-11-02
---

# 0020 - Envoy and Authorino as the API Authentication Gateway

## Context

HyperFleet's API is accessed by two caller types: external callers (human operators) authenticating with OIDC JWTs, and internal callers (Sentinel and Adapters) using Kubernetes projected service account tokens. Before this decision, each component validated credentials independently in application code.

Three structural problems drove the change:

1. **No single audit point.** External and internal traffic had no canonical interception point; a client-supplied identity header could reach application logic unchallenged.
2. **Identity configuration lived in application code.** Switching tenant models required rebuilding and redeploying the API.
3. **No enforceable network boundary.** Nothing prevented an in-cluster workload from reaching the API pod directly, bypassing any authentication layer.

A [proof-of-concept](https://github.com/ciaranRoche/hyperfleet-infra/tree/poc/multitenancy-v2) validated the approach. The architecture team reviewed the results and made the decision.

Deployments later gained a selectable authentication mode and a gateway-issued Wristband. This revision records that contract and replaces the earlier rule that the API trusts gateway-injected headers for caller identity.

## Decision

HyperFleet adopts **Envoy** as the API ingress proxy and **Authorino** as its external authorization service. All API traffic, external and internal, passes through Envoy. No other route to the API is permitted.

Each deployment selects where authentication runs:

| Mode | Gateway (Envoy + Authorino) | API |
|------|-----------------------------|-----|
| `NONE` | No authentication | No authentication |
| `API` | Routes only; Authorino absent | Validates the caller's token |
| `EDGE` | Authenticates every caller | No token validation |
| `EDGE+API` | Authenticates every caller, then issues a Wristband | Validates the Wristband |

A **Wristband** is a short-lived token issued by Authorino. In `EDGE+API`, Envoy replaces the client credential with the Wristband. The API trusts Authorino as the issuer and takes caller identity from the Wristband subject, not the original credential or an identity header.

The architectural contract is:

- **Explicit scheme selection in `EDGE` and `EDGE+API`.** `Authorization: ServiceAccount <token>` selects Kubernetes TokenReview for internal callers. `Authorization: Bearer <token>` selects OIDC for human callers. Missing or unknown schemes are denied. Priority-ordered method selection is not permitted: a token can satisfy more than one method, which makes the result order-dependent.
- **Trusted boundary.** Envoy must strip all identity and tenant headers trusted by the API before authorization. The API network boundary permits requests only from Envoy.
- **Machine authorization.** In edge modes, a service account must pass TokenReview and match the machine allow-list.
- **Tenant context.** In `EDGE`, tenant enforcement and the system-caller bypass use Authorino-injected headers. In `EDGE+API`, tenant enforcement uses validated Wristband claims and ignores those headers.
- **Internal TLS.** Internal gateway hops use server TLS, not mTLS.
- **Unauthenticated mode.** Supported deployment paths must default to an authenticated mode. `NONE` is development-only and must not be exposed externally.

> **Warning:** Wristband validation does not re-verify the caller's original credential. Trust depends on gateway configuration and protection of the signing key.

The scheme semantics, [Wristband trust contract](../docs/gateway-authentication-design.md#wristband), TLS hop status, and E2E client contract are in the Gateway Authentication Design.

## Consequences

**Gains:**

- Envoy provides one entry point for internal and external API traffic.
- Identity providers and tenant models can be configured without rebuilding the API.
- In `EDGE+API`, the API obtains caller identity from a signed token rather than an unsigned header.

**Trade-offs:**

- Envoy handles every API request; an Envoy outage makes the API unavailable. In edge modes, requests also depend on Authorino.
- `EDGE+API` adds Wristband signing and validation to every request; the API fetches verification keys from Authorino.
- `EDGE` does not resolve caller identity, so audit fields attribute every write to one synthetic identity. `EDGE` is acceptable only where per-caller attribution is not required.
- Wristband trust depends on Secret access control. Any principal that can read the signing key can mint a Wristband with arbitrary claims.

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| **Application-only middleware** | No shared audit point; identity config changes require rebuilds across every component; no enforceable network boundary. |
| **Per-service sidecar (service mesh)** | Does not provide a single ingress point for external callers. Sidecars can be layered on later without changing the trust model established here. |
| **OPA (Open Policy Agent)** | Policy engine, not an authentication service. Does not validate OIDC JWTs or perform TokenReview; a separate validation layer would be required alongside it. Authorino covers both in one CR-driven model. |
| **No shared boundary** | Per-component credential validation; no canonical audit point; identity config embedded in application deployments. Incompatible with the multi-tenant model where header provenance must be guaranteed. |
| **Priority-ordered Authorino identity methods** | Two methods can evaluate the same token, so the winner depends on evaluation order. On GKE the human OIDC issuer can also sign ServiceAccount tokens, which can misclassify a machine caller as a human caller. |

---

## References

- **Design:** [Gateway Authentication Design](../docs/gateway-authentication-design.md)
- **POC:** [`poc/multitenancy-v2` branch of `hyperfleet-infra`](https://github.com/ciaranRoche/hyperfleet-infra/tree/poc/multitenancy-v2)
- **Epic:** [Envoy and Authorino Gateway Deployment](https://redhat.atlassian.net/browse/HYPERFLEET-1476)
- **Sibling epic:** [Multi-Tenant Identity and Authorization](https://redhat.atlassian.net/browse/HYPERFLEET-1164)
- **External resources:**
  - [Envoy proxy documentation](https://www.envoyproxy.io/docs/envoy/latest/)
  - [Authorino documentation](https://github.com/Kuadrant/authorino)
  - [Kubernetes TokenReview API](https://kubernetes.io/docs/reference/kubernetes-api/authentication-resources/token-review-v1/)
