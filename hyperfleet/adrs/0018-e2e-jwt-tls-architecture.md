---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-11-02
---

# 0018 — E2E JWT/TLS Architecture

## Context

The E2E suite ([hyperfleet-e2e](https://github.com/openshift-hyperfleet/hyperfleet-e2e)) runs outside the cluster against a deployed HyperFleet. This record captures how the suite tests authentication. TLS is outside the suite's scope.

**Key Decision Point from Office Hours (2026-07-01)**: The team agreed to define a **cloud-agnostic contract** for TLS and JWT handling to avoid relying on specific cloud provider behaviors (GCP, AWS, Azure, OCI).

The gateway contract is defined in [ADR-0020](0020-envoy-authorino-api-gateway.md). This record covers how the E2E suite exercises it.

## Decision

1. **Exercise the gateway path.** The E2E suite sends API requests through Envoy and uses the authentication scheme selected by the deployment mode.
2. **Use Kubernetes service account tokens.** In authenticated modes, the external runner obtains a token through the Kubernetes TokenRequest API.
3. **Separate authentication and TLS coverage.** The suite tests client authentication through the gateway and API. The `hyperfleet-infra` suite tests gateway mechanics. TLS termination and certificate handling are outside the E2E suite's scope.

The Gateway Authentication Design describes the [E2E client contract](../docs/gateway-authentication-design.md#e2e-client-contract) and the [current and planned TLS paths](../docs/gateway-authentication-design.md#internal-tls).

## Consequences

**Gains:**

- ✅ **Kubernetes-native** — Uses the built-in TokenRequest API; no external identity provider for machine tokens.
- ✅ **Tests the deployed path** — API requests cross the gateway.
- ✅ **Mode-aware** — The same suite runs against all four authentication modes.
- ✅ **Ephemeral tokens** — Generated at suite start and never stored in the cluster.
- ✅ **Cloud-agnostic** — Uses the Kubernetes TokenRequest API instead of a provider-specific token issuer. The runner requires cluster access and permission to request tokens.
- ✅ **No extra infrastructure** — No token-extraction pods and no mock issuer for machine tokens.

**Trade-offs:**

- ⚠️ **Mode coupling** — The runner's authentication mode must match the deployment.
- ⚠️ **Service account identity format** — In `API` and `EDGE+API`, audit fields contain a service account subject rather than a user email.
- ⚠️ **No TLS coverage** — Certificate handling and TLS termination are outside the suite's scope.
- ⚠️ **Split coverage** — Gateway mechanics are asserted in `hyperfleet-infra`, so a change can pass one suite and fail the other.

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| **Job-based token extraction** | Requires deploying a Job pod, waiting for it to complete, and reading the result from an annotation. Direct TokenRequest returns the token with no extra resources. |
| **`kubectl create token`** | Requires a local `kubectl` with cluster access and shells out from the test binary. The TokenRequest API gives the same token through the Kubernetes client already used by the suite. |
| **Mock OIDC server for machine tokens** | Unnecessary infrastructure. Kubernetes issues and signs service account tokens natively. |
| **GCP Identity Tokens** | Violates the cloud-agnostic principle. Cannot run locally or in AWS/Azure CI/CD. |
| **Application-level TLS** | Envoy receives HTTP today; the planned ingress TLS termination sits outside the gateway. Would test behavior that is not deployed. |
| **Skip JWT testing** | Leaves the authentication contract untested and audit fields unverified. |
| **External OIDC (Keycloak, Dex)** | Adds operational complexity for machine callers. Service account tokens are Kubernetes-native and sufficient. |

---

## References

- **Design:** [Gateway Authentication Design](../docs/gateway-authentication-design.md)
- **Related:** [ADR-0020: Envoy and Authorino as the API Authentication Gateway](0020-envoy-authorino-api-gateway.md)
- **Jira:**
  - [HYPERFLEET-1235](https://redhat.atlassian.net/browse/HYPERFLEET-1235) — investigation and original ADR
  - [HYPERFLEET-1342](https://redhat.atlassian.net/browse/HYPERFLEET-1342) — original `kubectl create token` approach, superseded by the TokenRequest API
  - [HYPERFLEET-1484](https://redhat.atlassian.net/browse/HYPERFLEET-1484) — default to `EDGE+API` and run E2E through the gateway
  - [HYPERFLEET-1636](https://redhat.atlassian.net/browse/HYPERFLEET-1636) — this revision
- **External resources:**
  - [Kubernetes TokenRequest API](https://kubernetes.io/docs/reference/kubernetes-api/authentication-resources/token-request-v1/)
  - [Kubernetes Service Account Token Projection](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#serviceaccount-token-volume-projection)
  - [RFC 7519 - JWT](https://datatracker.ietf.org/doc/html/rfc7519)
