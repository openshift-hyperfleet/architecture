---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-11-10
---

# 0037 — Human and Machine Identities in E2E Authentication

## Context

[ADR-0018](0018-e2e-jwt-tls-architecture.md) chose Kubernetes service account tokens for every E2E call and rejected a mock OIDC server because service account tokens already gave Kubernetes-native JWT authentication. [ADR-0035](0035-e2e-mode-aware-authentication.md) kept that choice and made the authorization scheme follow the deployed `AUTH_MODE`.

API tenant enforcement ([HYPERFLEET-1531](https://redhat.atlassian.net/browse/HYPERFLEET-1531)) changed what a service account token can do. It is off by default. When it is on, service account callers are System Identities: they bypass tenant scoping and may write only `status` and `conditions`, and the API rejects their create, update and delete calls with `403`. A suite that authenticates only as a machine then fails on its first create.

[HYPERFLEET-1631](https://redhat.atlassian.net/browse/HYPERFLEET-1631) added a test-only Mock OIDC Issuer to `hyperfleet-infra` so the gateway suite could send human tokens. [HYPERFLEET-1843](https://redhat.atlassian.net/browse/HYPERFLEET-1843) moved the E2E suite's normal API calls onto it.

## Decision

The E2E suite uses two identity classes.

- **Human:** normal API operations in `API`, `EDGE` and `EDGE+API`. Each test process mints a token for one default human from the Mock OIDC Issuer (`hyperfleet-mock-oidc`) in the E2E Run Namespace, through the Kubernetes API server service proxy. It reuses the token until 30 seconds before it expires; concurrent callers in one process share one mint. Human requests send `Bearer <token>` in every authenticated mode.
- **Machine:** Kubernetes service account tokens, used only by the test adapters (projected tokens) and the machine-auth specs (TokenRequest API). Machine requests send `ServiceAccount <token>` in `EDGE` and `EDGE+API`, and `Bearer <token>` in `API`.

In `NONE`, the suite sends no token. The runner's `AUTH_MODE` and tenant model must match the deployment.

The [E2E client contract](../docs/gateway-authentication-design.md#e2e-client-contract) gives the scheme each identity class sends per `AUTH_MODE` and the human token flow.

### Relationship to ADR-0018 and ADR-0035

This record replaces the service account token choice that ADR-0018 made and ADR-0035 kept: service account tokens now serve machine identities only. It reverses ADR-0018's rejection of a mock OIDC server, which rested on service account tokens being able to authenticate every call. It also brings human authentication, which ADR-0018 placed out of scope, into the suite, against a mock issuer rather than a production identity provider.

ADR-0035's mode-aware scheme selection remains in force. ADR-0018's cloud-agnostic approach, external runner and exclusion of TLS testing remain in force.

## Consequences

**Gains:**

- In `API`, `EDGE` and `EDGE+API`, specs create, update and delete resources as a user does. In the HYPERFLEET-1843 verification run on kind (`EDGE+API`, tenant enforcement on), all 45 tier0 specs passed; on the same stack, a create sent with a machine token gets `403`.
- In `EDGE` and `EDGE+API` with tenant enforcement on, the suite's API calls run under tenant scoping. This is the precondition for tenant authorization specs, which a machine-only suite cannot run because a System Identity bypasses scoping. The specs themselves are not part of this decision. `API` has no tenant isolation, and `NONE` sends no human token.
- Audit fields (`created_by`, `deleted_by`) carry the human's email in `API` and `EDGE+API`.
- The machine-auth specs and the test adapters still cover the machine path, which needs no external identity provider.

**Trade-offs:**

- The suite never sends a token from the issuer a production deployment trusts. A mismatch between that issuer's claims and the gateway's tenant claim mapping does not fail E2E. This gives up ADR-0018's "real JWT validation, not mocks" gain for the human path.
- Authenticated runs need the Mock OIDC Issuer in the run namespace. `hyperfleet-infra` deploys it by default only for `e2e-kind` and `e2e-gcp`; a run against an external issuer stops at startup.
- The runner's kubeconfig needs `create` and `get` on `services/proxy` in the run namespace, in addition to creating TokenRequests. On GKE, the issuer's NetworkPolicy must admit the API server's `konnectivity-agent`.
- The runner's `AUTH_MODE` and tenant model must match the deployment.
- In `EDGE`, the API does not validate tokens and records `system@hyperfleet.local` as the audit identity.

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| Machine identity for every spec (ADR-0018, ADR-0035) | With tenant enforcement on, System Identities cannot create, update or delete resources, and they bypass tenant scoping. |
| Tenant rights for the E2E service account | The API would have to treat a machine caller as a tenant member, which the HYPERFLEET-1531 model does not support: machine callers are System Identities. Specs would also run on a path no production user takes. |
| Real test issuer (Keycloak, Dex or a hosted identity provider) | HYPERFLEET-1631 required one token helper for kind and GKE with no manual steps, including tokens deliberately missing a required claim. The mock serves both from static token mappings in the run namespace; a real issuer needs an operated deployment or external credentials in CI. ADR-0018 rejected Keycloak and Dex for operational complexity. |
| Port-forward to the mock issuer (the HYPERFLEET-1843 ticket's suggestion) | Needs a tunnel per mint, SPDY dependencies and CA handling. The API server service proxy reaches the issuer with one HTTP request and one NetworkPolicy rule. |

## References

- [ADR-0018: E2E JWT/TLS Architecture](0018-e2e-jwt-tls-architecture.md) - the original service account decision, partly superseded here.
- [ADR-0034: Gateway Authentication Modes and Wristband Trust](0034-gateway-authentication-modes.md) - defines the `AUTH_MODE` values.
- [ADR-0035: Mode-Aware E2E Authentication](0035-e2e-mode-aware-authentication.md) - mode-aware schemes, still in force.
- [Gateway Authentication Design](../docs/gateway-authentication-design.md) - the E2E client contract and token flow.
- [HYPERFLEET-1531](https://redhat.atlassian.net/browse/HYPERFLEET-1531) - API tenant enforcement and the System Identity write rule.
- [HYPERFLEET-1631](https://redhat.atlassian.net/browse/HYPERFLEET-1631) - added the Mock OIDC Issuer to `hyperfleet-infra`.
- [HYPERFLEET-1843](https://redhat.atlassian.net/browse/HYPERFLEET-1843) - moved normal E2E API calls to a human identity (implementation).
- [HYPERFLEET-1858](https://redhat.atlassian.net/browse/HYPERFLEET-1858) - this record.
