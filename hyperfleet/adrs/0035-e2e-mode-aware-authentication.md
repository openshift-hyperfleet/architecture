---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-11-09
---

# 0035 — Mode-Aware E2E Authentication

## Context

[ADR-0018](0018-e2e-jwt-tls-architecture.md) chose Kubernetes service account tokens for E2E authentication. It describes a fixed gateway-header contract and a `kubectl create token` flow. The gateway now supports multiple authentication modes and an internal Wristband, so the E2E client must match the deployed mode.

With tenant enforcement on, the API limits machine identities to reads and adapter status writes. A suite that creates resources with a machine token gets `403`.

## Decision

The E2E suite sends API requests through Envoy and uses the authentication scheme selected by the deployment mode. It uses two identity classes:

- **Human:** normal API operations in `API`, `EDGE` and `EDGE+API`. Each test process mints a token for one default human from the mock OIDC issuer in the run namespace. It reaches the issuer through the Kubernetes API server service proxy, caches the token per human, and mints a new one before the old one expires. Human requests send `Bearer <token>` in every authenticated mode.
- **Machine:** Kubernetes ServiceAccount tokens, used only by the test adapters (projected tokens) and the machine-auth specs (TokenRequest API). Machine requests send `ServiceAccount <token>` in `EDGE` and `EDGE+API`, and `Bearer <token>` in `API`.

In `NONE`, the suite sends no token. The runner's `AUTH_MODE` and tenant model must match the deployment.

The suite tests client authentication through the gateway and API. The `hyperfleet-infra` suite tests gateway mechanics; TLS termination and certificate handling remain outside the E2E suite's scope.

### Relationship to ADR-0018

This record replaces ADR-0018's fixed `kubectl create token` client flow and its assumption that the API always trusts gateway-injected identity headers. It also replaces the depicted HTTP-only internal application path with the TLS paths in the [Gateway Authentication Design](../docs/gateway-authentication-design.md#internal-tls). Since [HYPERFLEET-1843](https://redhat.atlassian.net/browse/HYPERFLEET-1843), it also replaces ADR-0018's choice of service account tokens for every E2E call and reverses its rejection of a mock OIDC server. ADR-0018's cloud-agnostic approach, external runner, and exclusion of TLS testing remain in force.

See the [E2E client contract](../docs/gateway-authentication-design.md#e2e-client-contract) for the scheme each identity class sends per `AUTH_MODE`, the token flow, and test scope.

## Consequences

**Gains:** The suite exercises the deployed authentication path in each mode. In `API`, `EDGE` and `EDGE+API`, specs create and change resources as a human, as a user does, instead of as a machine that tenant enforcement limits. Only `EDGE` and `EDGE+API` with API tenant enforcement enabled exercise tenant-scoped operations: `API` does not support tenant isolation, and `NONE` sends no human token. Audit fields (`created_by`, `deleted_by`) carry the human's email in `API` and `EDGE+API`. Machine tokens still need no external identity provider.

**Trade-offs:** The runner's mode and tenant model must match the deployment. Authenticated runs need the mock OIDC issuer in the run namespace; `hyperfleet-infra` deploys it by default only for `e2e-kind` and `e2e-gcp`. The runner's kubeconfig needs `create` and `get` on `services/proxy` in that namespace, in addition to creating TokenRequests. In `EDGE`, the API does not validate tokens and records `system@hyperfleet.local` as the audit identity. Gateway mechanics are tested separately in `hyperfleet-infra`; TLS termination and certificate handling are not covered by the E2E suite.

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| `kubectl create token` | Requires the test runner to invoke an external command; the Kubernetes client can request the token directly. |
| Machine identity for every spec | With tenant enforcement on, the API limits machine identities to reads and adapter status writes, so creates get `403`. |
| Port-forward to the mock issuer | Needs a local port and a background process per test process; the API server service proxy reaches the issuer with one HTTP request per mint. |

## References

- [ADR-0018: E2E JWT/TLS Architecture](0018-e2e-jwt-tls-architecture.md)
- [ADR-0034: Gateway Authentication Modes and Wristband Trust](0034-gateway-authentication-modes.md)
- [Gateway Authentication Design](../docs/gateway-authentication-design.md)
- [HYPERFLEET-1636](https://redhat.atlassian.net/browse/HYPERFLEET-1636)
- [HYPERFLEET-1843](https://redhat.atlassian.net/browse/HYPERFLEET-1843)
- [hyperfleet-e2e setup: Authentication mode](https://github.com/openshift-hyperfleet/hyperfleet-e2e/blob/main/docs/setup.md#authentication-mode)
