---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-11-10
---

# 0035 — Mode-Aware E2E Authentication

> **Superseded in part.** [ADR-0037](0037-e2e-human-and-machine-identities.md) limits the service account token choice below to machine identities; in `API`, `EDGE` and `EDGE+API`, normal API calls now run as a human with a token from the mock OIDC issuer. `NONE` still sends no token and needs no issuer. The mode-aware scheme selection remains in force. The text below is unchanged from the original decision.

## Context

[ADR-0018](0018-e2e-jwt-tls-architecture.md) chose Kubernetes service account tokens for E2E authentication. It describes a fixed gateway-header contract and a `kubectl create token` flow. The gateway now supports multiple authentication modes and an internal Wristband, so the E2E client must match the deployed mode.

## Decision

The E2E suite sends API requests through Envoy and uses the authentication scheme selected by the deployment mode. In authenticated modes, the external runner obtains a Kubernetes service account token through the TokenRequest API.

The suite tests client authentication through the gateway and API. The `hyperfleet-infra` suite tests gateway mechanics; TLS termination and certificate handling remain outside the E2E suite's scope.

### Relationship to ADR-0018

This record replaces ADR-0018's fixed `kubectl create token` client flow and its assumption that the API always trusts gateway-injected identity headers. It also replaces the depicted HTTP-only internal application path with the TLS paths in the [Gateway Authentication Design](../docs/gateway-authentication-design.md#internal-tls). ADR-0018's cloud-agnostic approach, external runner, service account token choice, and exclusion of TLS testing remain in force.

See the [E2E client contract](../docs/gateway-authentication-design.md#e2e-client-contract) for mode-specific schemes and test scope.

## Consequences

**Gains:** The suite exercises the deployed authentication path in each mode and obtains machine tokens without an external identity provider.

**Trade-offs:** The runner's mode must match the deployment. Gateway mechanics are tested separately in `hyperfleet-infra`; TLS termination and certificate handling are not covered by the E2E suite.

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| `kubectl create token` | Requires the test runner to invoke an external command; the Kubernetes client can request the token directly. |
| One authentication scheme for every mode | Does not match the distinct gateway and API authentication paths. |

## References

- [ADR-0018: E2E JWT/TLS Architecture](0018-e2e-jwt-tls-architecture.md)
- [ADR-0034: Gateway Authentication Modes and Wristband Trust](0034-gateway-authentication-modes.md)
- [Gateway Authentication Design](../docs/gateway-authentication-design.md)
- [HYPERFLEET-1636](https://redhat.atlassian.net/browse/HYPERFLEET-1636)
