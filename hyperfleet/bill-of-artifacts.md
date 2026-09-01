# HyperFleet MVP — Bill of Artifacts

**Status**: Active
**Owner**: HyperFleet Team
**Last Updated**: 2026-08-24

---

## Executive Summary

This document provides a comprehensive inventory of all artifacts delivered as part of the HyperFleet MVP milestone. HyperFleet is a cloud-agnostic, event-driven platform for automated cluster lifecycle management built to provision and manage hosted OpenShift clusters at scale.

This bill of artifacts serves as both a single reference for external stakeholders (leadership, partner teams, new joiners) and a baseline for tracking work beyond MVP.

---

## Table of Contents

- [1. Core Platform Services](#1-core-platform-services)
- [2. Supporting Services and Tools](#2-supporting-services-and-tools)
- [3. API Contracts and Specifications](#3-api-contracts-and-specifications)
- [4. Infrastructure and Deployment](#4-infrastructure-and-deployment)
- [5. Testing](#5-testing)
- [6. CI/CD and Release Infrastructure](#6-cicd-and-release-infrastructure)
- [7. Integration Points](#7-integration-points)

---

## 1. Core Platform Services

The platform follows an event-driven architecture: the API stores data, the Sentinel makes orchestration decisions, the Broker distributes events, and Adapters execute cloud-specific operations.

### 1.1 HyperFleet API

| Field | Value |
|-------|-------|
| **Repository** | [hyperfleet-api](https://github.com/openshift-hyperfleet/hyperfleet-api) |
| **Language** | Go 1.24+ |
| **State** | Active, production-ready |
| **Helm Chart** | v1.0.0 |
| **Container Image** | `quay.io/openshift-hyperfleet/hyperfleet-api` |

Stateless REST API serving as the pure CRUD data layer for cluster lifecycle management. Intentionally contains no business logic or event creation — separation of concerns is a core design principle.

- REST operations covering Cluster, NodePool, and Status resources (supported operations: CREATE, GET, LIST)
- PostgreSQL database with GORM ORM, generation-aware status aggregation
- Kubernetes-style conditions (`Ready`, `Available`) aggregated from adapter reports
- Label-based search and filtering via TSL (Tree Search Language)
- Plugin-based resource registration, embedded OpenAPI spec and Swagger UI
- Helm chart with HPA (HorizontalPodAutoscaler), PDB (PodDisruptionBudget), ServiceMonitor, optional PostgreSQL or external DB mode

### 1.2 HyperFleet Sentinel

| Field | Value |
|-------|-------|
| **Repository** | [hyperfleet-sentinel](https://github.com/openshift-hyperfleet/hyperfleet-sentinel) |
| **Language** | Go 1.25 |
| **State** | Active, production-ready |
| **Helm Chart** | v1.0.0 |
| **Container Image** | `quay.io/openshift-hyperfleet/hyperfleet-sentinel` |

Stateless reconciliation trigger service implementing a poll-decide-publish loop. The orchestration brain of HyperFleet.

- CEL-based configurable decision engine with three-part decision strategy: never-processed (immediate for new resources), state-based (immediate on unprocessed spec changes), and time-based reconciliation (periodic max age intervals)
- Publishes CloudEvents v1 with CEL (Common Expression Language) for both decision logic and dynamic payload building, plus W3C trace propagation
- Horizontal scaling via config-driven label selectors for workload partitioning — no leader election needed
- Broker abstraction: GCP Pub/Sub, RabbitMQ, and Stub backends via the [`hyperfleet-broker`](https://github.com/openshift-hyperfleet/hyperfleet-broker) library
- Exponential backoff retry with transient/permanent error classification
- Helm chart with PDB, PodMonitoring (GKE/GMP), ServiceMonitor, PrometheusRule
- Pre-built Grafana dashboard and 8 alert rules

### 1.3 HyperFleet Adapter Framework

| Field | Value |
|-------|-------|
| **Repository** | [hyperfleet-adapter](https://github.com/openshift-hyperfleet/hyperfleet-adapter) |
| **Language** | Go 1.25 |
| **State** | Active, production-ready |
| **Helm Chart** | v2.0.0 |
| **Container Image** | `quay.io/openshift-hyperfleet/hyperfleet-adapter` |

Configuration-driven framework for executing provisioning tasks. Single binary, infinite configurations — you write YAML, not Go code.

- Four-phase execution pipeline: Param Extraction, Precondition Evaluation (structured conditions or CEL), Resource Application, Post Actions (CEL-driven API calls including status reporting)
- Two-config architecture: AdapterConfig (infrastructure) + AdapterTaskConfig (business logic)
- Dual transport backends: Kubernetes (client-go for in-cluster) and Maestro (gRPC + HTTP to Maestro server for remote cluster delivery via ManifestWork)
- Generation-based idempotent reconciliation (CREATE / UPDATE / SKIP / RECREATE)
- Dry-run mode for local development without infrastructure dependencies
- Helm chart v2.0.0 with auto-generated RBAC, HPA, PDB, ServiceMonitor

### 1.4 HyperFleet Broker

| Field | Value |
|-------|-------|
| **Repository** | [hyperfleet-broker](https://github.com/openshift-hyperfleet/hyperfleet-broker) |
| **Language** | Go 1.25 |
| **State** | Active, stable |

Shared Go library providing a unified pub/sub messaging abstraction with built-in CloudEvents support. Imported by Sentinel and Adapter — not a standalone service.

- Two backends: RabbitMQ (Watermill AMQP) and Google Cloud Pub/Sub (Watermill Google Cloud)
- CloudEvents v1.0 automatic wrapping/unwrapping, dead letter topic support
- Two messaging patterns: load balancing (shared subscription) and fanout (separate subscriptions)
- Publisher health checks for readiness probes, Prometheus metrics, configurable worker pools

### 1.5 HyperFleet Applier

| Field | Value |
|-------|-------|
| **Repository** | [hyperfleet-applier](https://github.com/openshift-hyperfleet/hyperfleet-applier) |
| **Language** | Go 1.26 |
| **State** | Active |
| **Helm Chart** | v0.1.0 (not yet released — no RC tag cut) |
| **Container Image** | `quay.io/openshift-hyperfleet/hyperfleet-applier` |

A per-management-cluster agent that reads desires from the desire store and reconciles them against the local Kubernetes API server - server-side apply for ApplyDesires, delete for DeleteDesires, watch/mirror for ReadDesires - writing status back to each desire. The reference binary is `hyperfleet-applier`. Replaces the Maestro/OCM work agent in the desire-based delivery model.

---

## 2. Supporting Services and Tools

| Repository | Description | Language | Used by |
|-----------|-------------|----------|---------|
| [maestro-cli](https://github.com/openshift-hyperfleet/maestro-cli) | CLI for ManifestWork lifecycle management through Maestro (apply, delete, get, list, watch). Dual-protocol: gRPC + HTTP. | Go 1.25 | Adapter (Maestro transport), developers for debugging |

---

## 3. API Contracts and Specifications

### 3.1 HyperFleet API Spec (TypeSpec)

| Field | Value                                                                                |
|-------|--------------------------------------------------------------------------------------|
| Repository | [hyperfleet-api-spec](https://github.com/openshift-hyperfleet/hyperfleet-api-spec)   |
| Language | TypeSpec                                                                             |
| Version | 1.0.2                                                                                |
| Consumed by | `hyperfleet-api` and `hyperfleet-sentinel` via the `github.com/openshift-hyperfleet/hyperfleet-api-spec` Go module |

TypeSpec definitions generating OpenAPI 3.0 specifications (with optional OpenAPI 2.0 conversion for legacy tooling), published as GitHub Release artifacts. Supports multi-cloud provider variants via alias-based type switching (`aliases-core.tsp`, `aliases-gcp.tsp`). Key models: Cluster, NodePool, Status, Error (RFC 9457). Interactive API docs via GitHub Pages.

> **Note:** Both `hyperfleet-api` and `hyperfleet-sentinel` consume the OpenAPI schema directly from the `hyperfleet-api-spec` Go module — `openapi/openapi.yaml` is extracted from the module cache at code-generation time and is not tracked in git in either repository. See [openapi/README.md](https://github.com/openshift-hyperfleet/hyperfleet-api/blob/main/openapi/README.md) in `hyperfleet-api` and [openapi/README.md](https://github.com/openshift-hyperfleet/hyperfleet-sentinel/blob/main/openapi/README.md) in `hyperfleet-sentinel` for full details.

### 3.2 CloudEvents Contract

All inter-service events use CloudEvents v1.0 with anemic payloads (resource ID, kind, generation only) and W3C `traceparent` for distributed tracing. Formal schema defined in [`hyperfleet/components/broker/asyncapi.yaml`](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/components/broker/asyncapi.yaml).

- `ReconcileCluster` — event type: `com.redhat.hyperfleet.cluster.reconcile.v1`, payload: `ObjectReference` + `generation`
- `ReconcileNodePool` — event type: `com.redhat.hyperfleet.nodepool.reconcile.v1`, payload: `ObjectReference` + `generation` + `owner_references`

---

## 4. Infrastructure and Deployment

### 4.1 HyperFleet Infra

| Field | Value |
|-------|-------|
| **Repository** | [hyperfleet-infra](https://github.com/openshift-hyperfleet/hyperfleet-infra) |
| **State** | Active |

Infrastructure as Code for HyperFleet environments. Makefile-driven provisioning (Terraform) and deployment (Helm).

**Terraform Modules:** GKE cluster (`terraform/modules/cluster/gke/`), Google Pub/Sub (`terraform/modules/pubsub/`), shared VPC infrastructure (`terraform/shared/`). Multi-cloud stubs (EKS, AKS) present for post-MVP expansion.

**Helm Umbrella Charts (7):** `api`, `adapter1`, `adapter2`, `adapter3`, `sentinel-clusters`, `sentinel-nodepools`, `maestro` — each wrapping the upstream component chart with environment-specific values.

**Additional:** RabbitMQ dev manifest, broker Helm values generator script, full lifecycle Makefile targets (`install-all`, `uninstall-all`, `status`).

---

## 5. Testing

### 5.1 E2E Testing Framework

| Field | Value |
|-------|-------|
| **Repository** | [hyperfleet-e2e](https://github.com/openshift-hyperfleet/hyperfleet-e2e) |
| **Language** | Go 1.25 |
| **State** | Active |

Black-box E2E testing framework for validating Critical User Journeys (CUJ). Ginkgo-based with ephemeral resource management, parallel execution, label-based filtering, JUnit XML reports, and container image support for CI.

**Test Suites:**

| Suite | Tier | What it validates |
|-------|------|-------------------|
| Cluster Creation | Tier 0 | End-to-end cluster lifecycle: creation, initial conditions, adapter execution, final Ready state |
| NodePool Creation | Tier 0 | End-to-end nodepool lifecycle: creation under a parent cluster, adapter execution, Ready state |
| Adapter with Maestro Transport | Tier 0 | Full Maestro transport path: ManifestWork creation, Maestro agent applies to target cluster, adapter reports status back via discovery |
| Cluster Concurrent Creation | Tier 1 | 5 simultaneous cluster creations reach Ready state without resource conflicts |
| NodePool Concurrent Creation | Tier 1 | 3 simultaneous nodepools under the same cluster reach Ready state with isolated resources |
| Cluster Adapter Failure | Tier 1 | Adapter precondition failures are reflected in cluster top-level status |
| Adapter Failover | Tier 1 | Adapter framework detects invalid Kubernetes resources and reports failures with clear error messages |

### 5.2 Per-Component Testing

All core services use golangci-lint for code quality. Integration tests use testcontainers-go or controller-runtime envtest, depending on the component.

| Component | Unit Tests | Integration Tests | Helm Tests | Notable |
|-----------|-----------|-------------------|------------|---------|
| hyperfleet-api | Handlers, services, DAO, auth, middleware, presenters | Testcontainers + PostgreSQL: adapter status, clusters CRUD, node pools, API contract, search field mapping | Multiple scenarios covering external DB, autoscaling, PDB, ServiceMonitor, auth | Mock factories for clusters/nodepools, gotestsum runner |
| hyperfleet-sentinel | Config, decision engine, payload builder, metrics, health | Testcontainers + real message brokers | Multiple scenarios covering PDB, RabbitMQ, Pub/Sub, PodMonitoring, PrometheusRule | Mock HyperFleet API server for load testing, profiling tools |
| hyperfleet-adapter | Config loader, CEL criteria, executor pipeline, manifest generation, dry-run engine | Dual strategy: envtest (unprivileged, CI-friendly) and K3s (faster); Maestro client TLS tests | Multiple scenarios covering broker, API config, PDB, autoscaling, probes | Dual integration strategy: envtest (CI) and K3s (local) |
| hyperfleet-broker | CloudEvents conversion, config, health checks, metrics | Testcontainers + RabbitMQ and Pub/Sub emulator | — | Performance benchmarks, leak detection tests |
| hyperfleet-applier | Desire types, store backends, apply-desire controller | controller-runtime envtest (`-tags envtest`) | — | Envtest excluded from `make test`; Prow `integration` presubmit runs `make test-envtest` |

---

## 6. CI/CD and Release Infrastructure

| Field | Value |
|-------|-------|
| **Release Process** | [hyperfleet-release-process.md](./docs/release/hyperfleet-release-process.md) |
| **Pipeline Design** | [konflux-release-pipeline-design.md](./docs/release/konflux-release-pipeline-design.md) |
| **ADR** | [0014 — Konflux for Container Image Build and Release](./adrs/0014-konflux-build-and-release.md) |

### 6.1 Konflux (Build and Release)

Container images are built and released via Konflux on the `kflux-prd-rh02` cluster. PaC tag-triggered pipelines build images, Tekton Chains signs provenance, and the `rh-push-to-external-registry` pipeline publishes to `quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/`. Helm charts will be published as OCI artifacts via the `build-helm-chart-oci-ta` task to `quay.io/redhat-services-prod/hyperfleet-tenant/` (pending a managed release pipeline for external registries from the Konflux team). See [Konflux Release Pipeline Design](./docs/release/konflux-release-pipeline-design.md) and [Helm OCI Distribution Design](./docs/release/helm-oci-distribution-design.md) for full architecture.

### 6.2 Prow CI

CI system for PR validation and E2E testing. Presubmit and postsubmit jobs across all core repositories covering unit tests, integration tests, linting, and Helm chart validation. Job definitions are externally managed. Dedicated Prow CI cluster provisioned on GCP.

---

## 7. Integration Points

| Consumer Team | Status | Integration Details |
|---------------|--------|---------------------|
| **GCP** | Primary MVP target | GKE cluster provisioning (Terraform), Cloud Pub/Sub as production message broker, Cloud DNS for cluster provisioning, Compute/IAM/CRM API validation, Workload Identity Federation for keyless auth |
| **ROSA / AWS** | Post-MVP | Multi-cloud foundation in place (credential provider supports AWS/EKS, API spec alias system supports provider variants). ROSA/AWS adapter implementation planned for post-MVP |

---

## Change Log

| Date | Version | Change | Author |
|------|---------|--------|--------|
| 2026-03-25 | 1.0 | Initial Bill of Artifacts | Tirth Chetan Thakkar |
| 2026-05-11 | 1.1 | Updated Konflux section: cluster to kflux-prd-rh02, added Helm OCI distribution, fixed ADR reference | Ciaran Roche |
| 2026-08-24 | 1.2 | Added HyperFleet Applier as a core service (HYPERFLEET-1435) | Dmitrii Andreev |
