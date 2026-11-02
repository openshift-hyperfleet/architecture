---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-11-02
---

# 0033 — Gateway Authentication Modes and Wristband Trust

## Context

[ADR-0020](0020-envoy-authorino-api-gateway.md) establishes Envoy and Authorino as the API gateway and trusts gateway-injected headers for API identity. Deployments now select where authentication runs, and `EDGE+API` uses an Authorino-issued Wristband for gateway-to-API trust.

## Decision

All API traffic passes through Envoy. Each deployment selects an authentication mode:

| Mode | Gateway | API |
|------|---------|-----|
| `NONE` | Routes without authentication | No authentication |
| `API` | Routes without authentication | Validates the caller's token |
| `EDGE` | Authorino authenticates callers | No token validation |
| `EDGE+API` | Authorino authenticates callers and issues a Wristband | Validates the Wristband |

In `EDGE` and `EDGE+API`, the authorization scheme selects the authentication method. Service account callers must pass Kubernetes TokenReview and the machine allow-list. Envoy must strip every identity and tenant header trusted by the API before authorization.

In `EDGE`, tenant enforcement and the system-caller bypass use gateway-injected headers. In `EDGE+API`, the API validates the Wristband and uses its subject for caller identity and its claims for tenant enforcement, rather than trusting those headers. Wristband validation does not re-verify the original client credential.

Internal gateway hops use server TLS, not mTLS. Supported deployment paths must default to an authenticated mode. `NONE` is development-only and must not be exposed externally.

### Relationship to ADR-0020

This record replaces ADR-0020's requirements that Authorino authenticates every caller in all deployments and that the API always trusts injected identity headers. It also qualifies header stripping: Envoy strips the configured headers, which must include every header the API trusts. ADR-0020's Envoy entry point, edge-mode Authorino authentication, and API network boundary remain in force.

See the [Gateway Authentication Design](../docs/gateway-authentication-design.md) for the schemes, Wristband trust contract, and TLS paths.

## Consequences

**Gains:** Deployments select the authentication boundary. In `EDGE+API`, the API receives signed caller and tenant context rather than trusting unsigned headers.

**Trade-offs:** Envoy remains on every API request path. Edge modes also depend on Authorino; `EDGE+API` adds Wristband signing and validation. In `EDGE`, audit fields use a synthetic identity, so the mode is acceptable only where per-caller attribution is not required. Wristband trust depends on gateway configuration and signing-key access control.

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| Trust gateway-injected headers in every mode | In `EDGE+API`, unsigned headers would remain authoritative for identity or tenant scope despite Wristband validation. |
| Priority-ordered identity methods | One token can satisfy multiple methods, making caller classification depend on evaluation order. |

## References

- [ADR-0020: Envoy and Authorino as the API Authentication Gateway](0020-envoy-authorino-api-gateway.md)
- [Gateway Authentication Design](../docs/gateway-authentication-design.md)
- [HYPERFLEET-1636](https://redhat.atlassian.net/browse/HYPERFLEET-1636)
