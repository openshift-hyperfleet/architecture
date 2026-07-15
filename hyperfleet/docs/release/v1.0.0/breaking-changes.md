---
Status: Active
Owner: HyperFleet Team
Last Updated: 2026-06-25
---

# v0.2.0 to v1.0.0 Breaking-Change and Reconfiguration Checklist

> **Audience:** Internal partner teams (GCP, ROSA) upgrading from HyperFleet experimental (v0.2.0) to v1.0.0, and the HyperFleet release team.

## Overview

This document is the deliverable for [HYPERFLEET-1177](https://redhat.atlassian.net/browse/HYPERFLEET-1177). It lists every breaking change and required reconfiguration step between v0.2.0 and v1.0.0 so partner teams can reconfigure and redeploy with no surprises.

## Breaking Changes

### API Contract

| # | Change | Partner Action | Impact if Missed | Classification | Ticket | Parent |
|---|--------|---------------|-----------------|----------------|--------|--------|
| 1 | **Status report: POST to PUT** for clusters and nodepools | Change HTTP method in all adapter post-actions from POST to PUT | **405 Method Not Allowed.** PUT-only routes confirmed in `plugins/clusters/plugin.go`; no POST route exists | Automatable (1178) | [HYPERFLEET-978](https://redhat.atlassian.net/browse/HYPERFLEET-978) | - |
| 2 | **Ready condition removed; replaced by Reconciled** | Replace all `Ready` references with `Reconciled` in status queries, scripts, and monitoring | **Silent hang.** API silently accepts `type="Ready"` in status reports but never aggregates it into resource conditions; scripts polling for Ready=True wait forever | Automatable (1178) | [HYPERFLEET-1052](https://redhat.atlassian.net/browse/HYPERFLEET-1052) | [HYPERFLEET-559](https://redhat.atlassian.net/browse/HYPERFLEET-559) |
| 3 | **Aggregated condition Available renamed to LastKnownReconciled** | Replace `Available` with `LastKnownReconciled` in all resource-level condition queries | **Not found.** Aggregation code produces only `Reconciled` and `LastKnownReconciled`; resource-level `Available` is no longer emitted | Automatable (1178) | [HYPERFLEET-1017](https://redhat.atlassian.net/browse/HYPERFLEET-1017) | - |
| 4 | **List responses: kind field removed** | Remove `kind` expectations in list response parsing | **Parse error** if client schema requires `kind`. Confirmed: `kind` removed from `ClusterList`, `NodePoolList`, `ResourceList`, `AdapterStatusList`; test asserts `raw.NotTo(HaveKey("kind"))` | Automatable (1178) | [HYPERFLEET-1143](https://redhat.atlassian.net/browse/HYPERFLEET-1143) | - |
| 5 | **Pagination query parameters renamed: `pageSize` → `size`, `orderBy` → `order`** | Replace `pageSize` with `size` and `orderBy` with `order` in all API list-endpoint calls (`GET /clusters`, `GET /nodepools`, `GET /resources`). For generated clients (e.g. from the OpenAPI spec), regenerate after the spec update in HYPERFLEET-1279 | **Silent incorrect results.** Old parameter names are not recognized; requests silently fall back to defaults (page 1, size 20, no ordering) with no error returned | Manual | [HYPERFLEET-1280](https://redhat.atlassian.net/browse/HYPERFLEET-1280) | [HYPERFLEET-1272](https://redhat.atlassian.net/browse/HYPERFLEET-1272) |

### Configuration

| # | Change | Partner Action | Impact if Missed | Classification | Ticket | Parent |
|---|--------|---------------|-----------------|----------------|--------|--------|
| 6 | **Sentinel: messaging_system field removed and config parser now strict** | Remove `messaging_system` from all Sentinel configs and `MESSAGING_SYSTEM` env var. Also remove any other unrecognized fields | **Sentinel fails to start.** v0.2.0 used permissive `v.Unmarshal()`; v1.0.0 uses strict `v.UnmarshalExact()` which rejects unknown fields. Any unrecognized field in the config will cause a startup failure | Automatable (1178) | Sentinel CHANGELOG | - |
| 7 | **Sentinel and Adapter CEL: Ready to Reconciled** | Update ALL `message_decision` CEL in Sentinel AND all precondition/capture CEL in Adapter configs | **CRITICAL SILENT FAILURE.** `condition("Ready")` returns a zero-value struct (empty status, generation 0) via fallback in `decision.go`; CEL evaluates to false; Sentinel never publishes events; adapters never fire; clusters stuck in pending. No error logged | Automatable (1178) | [HYPERFLEET-857](https://redhat.atlassian.net/browse/HYPERFLEET-857) | [HYPERFLEET-559](https://redhat.atlassian.net/browse/HYPERFLEET-559) |
| 8 | **Sentinel Helm: config.hyperfleetApi moved to config.clients.hyperfleetApi** | Move API client config from `config.hyperfleetApi.baseUrl` to `config.clients.hyperfleetApi.baseUrl` in Sentinel Helm values | **Sentinel fails to start.** Helm template references `.Values.config.clients.hyperfleetApi.baseUrl`; old path renders empty; validation fails with "clients.hyperfleet_api.base_url required" | Automatable (1178) | [HYPERFLEET-549](https://redhat.atlassian.net/browse/HYPERFLEET-549), [HYPERFLEET-866](https://redhat.atlassian.net/browse/HYPERFLEET-866) | - |
| 9 | **Sentinel Helm: messageDecision params changed from map to list** | Restructure `messageDecision.params` from map format (`key: 'expr'`) to list format (`- name: key, expr: 'expr'`) | **Helm template fails to render.** Template iterates with `.name` and `.expr` fields; old map format has no such fields. Also fixes non-deterministic param ordering | Automatable (1178) | [HYPERFLEET-1011](https://redhat.atlassian.net/browse/HYPERFLEET-1011) | - |
| 10 | **API Helm: jwt.enabled default changed from true to false** | Explicitly set `config.server.jwt.enabled: true` in Helm values if JWT authentication is required | **API accepts unauthenticated requests.** v0.2.0 Helm chart defaulted to `jwt.enabled: true`; v1.0.0 defaults to `false`. Requests that were previously rejected without a valid JWT token are now accepted | Doc-only (1163/1179) | Helm chart values.yaml diff | - |
| 11 | **JWT identity_claim defaults to email** | Set `identity_claim` on each issuer entry under `configs` to match the claim your tokens carry | **Mutating requests fail with 401** if the configured claim is absent from the token. If `identity_claim` is omitted, it defaults to `email` via `ApplyDefaults()`. `identity_claim` is a per-issuer setting (on `JWTIssuerConfig`), not a global setting - each issuer can use a different claim | Doc-only (1163/1179) | [HYPERFLEET-1134](https://redhat.atlassian.net/browse/HYPERFLEET-1134) | [HYPERFLEET-824](https://redhat.atlassian.net/browse/HYPERFLEET-824) |
| 12 | **Default log format changed to JSON (Sentinel and Adapter)** | Update log parsing pipelines if expecting text format from Sentinel or Adapter | **Log parsing breaks** for Sentinel and Adapter output. `DefaultConfig()` changed from `FormatText` to `FormatJSON` in both components (PRs #103 and #109). API was already JSON in v0.2.0 and is unchanged | Doc-only (1163/1179) | [HYPERFLEET-908](https://redhat.atlassian.net/browse/HYPERFLEET-908) | - |

### Auth

| # | Change | Partner Action | Impact if Missed | Classification | Ticket | Parent |
|---|--------|---------------|-----------------|----------------|--------|--------|
| 13 | **OCM SDK removed; standalone JWT handler** | Remove OCM-specific auth config (`server.acl`, `server.authz`); switch to JWT config (issuer_url, audience, identity_claim) | **In raw config files, API fails to start** with unknown-field error (`UnmarshalExact` rejects `server.acl`/`server.authz`). In Helm deployments, these fields were never rendered by the template so they are silently absent. Entire `pkg/client/ocm/` and `pkg/config/ocm.go` removed. Combined with #10 (jwt.enabled defaults to false), the API may start with no authentication unless JWT is explicitly configured | Doc-only (1163/1179) | [HYPERFLEET-492](https://redhat.atlassian.net/browse/HYPERFLEET-492) | - |

### Helm Charts

| # | Change | Partner Action | Impact if Missed | Classification | Ticket | Parent |
|---|--------|---------------|-----------------|----------------|--------|--------|
| 14 | **PgBouncer sidecar replaced by generic sidecars** | Rewrite PgBouncer config as generic sidecar entry in `sidecars` list | **No DB proxy sidecar.** Entire `database.pgbouncer.*` Helm values tree removed (not deprecated); old values silently ignored; pod starts without proxy | Doc-only (1163/1179) | [HYPERFLEET-937](https://redhat.atlassian.net/browse/HYPERFLEET-937) | - |
| 15 | **Sentinel config mount paths changed** | Update any custom scripts, init containers, or sidecar configs referencing `/etc/sentinel/config.yaml` or `/etc/sentinel/broker.yaml` to `/etc/hyperfleet/config.yaml` and `/etc/hyperfleet/broker.yaml` | **Config not found.** Custom scripts or containers referencing old path fail | Doc-only (1163/1179) | [HYPERFLEET-549](https://redhat.atlassian.net/browse/HYPERFLEET-549) | - |
| 16 | **Sentinel BROKER_TOPIC env var removed** | Remove `BROKER_TOPIC` env var overrides; use `broker.topic` in Helm values instead | **Topic override ignored.** Env var no longer injected by deployment template; partners overriding topic via env var will have it silently ignored, falling back to Helm value | Doc-only (1163/1179) | [HYPERFLEET-549](https://redhat.atlassian.net/browse/HYPERFLEET-549) | - |
| 17 | **Adapter Helm: broker.type now explicitly required; RabbitMQ fields validated** | Add explicit `broker.type: rabbitmq` or `broker.type: googlepubsub` to adapter Helm values. For RabbitMQ: `url` and `exchange` are validated as required at render time; `queue` and `exchangeType` are recommended but not enforced | **Helm rendering fails.** `_helpers.tpl` `brokerType` function now uses `required` instead of inference; missing `broker.type` fails at render time. `validateBrokerConfig` template checks `broker.rabbitmq.url` and `broker.rabbitmq.exchange` for RabbitMQ | Automatable (1178) | Adapter Helm chart `_helpers.tpl` | - |

### Database

| # | Change | Partner Action | Impact if Missed | Classification | Ticket | Parent |
|---|--------|---------------|-----------------|----------------|--------|--------|
| 18 | **Fresh database required** | Deploy a completely fresh database. Do not reuse v0.2.0 database | **Policy, not technical limitation.** Migrations technically CAN run on v0.2.0 schema (RENAME COLUMN works), but the project explicitly states "fresh DB, no migration." Reusing old DB risks table locks on rename and untested migration paths | Doc-only (1163/1179) | Epic description | [HYPERFLEET-1176](https://redhat.atlassian.net/browse/HYPERFLEET-1176) |

## Open Actions

1. **Track [HYPERFLEET-1117](https://redhat.atlassian.net/browse/HYPERFLEET-1117):** "API: skip Reconciled and LastKnownReconciled conditions when no required adapters are configured" is in New status. If it merges before v1.0.0, add to this checklist.
