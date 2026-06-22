# HyperFleet Naming Conventions Guide

**Version**: 1.1
**Date**: 2026-06-15
**Status**: Active

## Purpose

This document defines standard naming conventions for concepts, components, and infrastructure across all HyperFleet repositories to ensure consistency, reduce cognitive load, and improve maintainability.

**Scope**: This guide focuses on **conceptual naming** (major concerns and components), not general coding style.

---

## Table of Contents

1. [Domain Concepts](#1-domain-concepts)
2. [Architecture Patterns](#2-architecture-patterns)
3. [Infrastructure Components](#3-infrastructure-components)
4. [Configuration & Secrets](#4-configuration--secrets)
5. [Observability](#5-observability)
6. [API & HTTP Conventions](#6-api--http-conventions)
7. [Database Schema](#7-database-schema)
8. [Kubernetes Resources](#8-kubernetes-resources)
9. [Messaging & Events](#9-messaging--events)
10. [Repository Naming](#10-repository-naming)
11. [Binary Naming](#11-binary-naming)
12. [Makefile Conventions](#12-makefile-conventions)
13. [Package & Module Naming](#13-package--module-naming)

---

## 1. Domain Concepts

### 1.1 Resource Types

**Standard**: Use **PascalCase** for resource type names in code, **lowercase** in URLs/config

| Concept | Code (Type) | URL/Config | Plural | Database Table |
|---------|-------------|------------|--------|----------------|
| Cluster | `Cluster` | `cluster` | `clusters` | `clusters` |
| Node Pool | `NodePool` | `nodepool` | `nodepools` | `node_pools` |
| Adapter Status | `AdapterStatus` | `adapter_status` | `adapter_statuses` | `adapter_statuses` |

### 1.2 Resource Phases

> **Note**: Phase constants are aspirational — not yet implemented in existing repos. Current codebase tracks readiness via Kubernetes-style conditions (see §1.3). Introduce these constants when adding explicit phase tracking.

**Standard**: Use **PascalCase** constants, **exact string values** in database

| Phase | Constant Name | String Value | Description |
|-------|---------------|--------------|-------------|
| Not Ready | `PhaseNotReady` | `"NotReady"` | Resource not yet ready |
| Provisioning | `PhaseProvisioning` | `"Provisioning"` | Resource being created |
| Ready | `PhaseReady` | `"Ready"` | Resource is operational |
| Failed | `PhaseFailed` | `"Failed"` | Resource in error state |
| Terminating | `PhaseTerminating` | `"Terminating"` | Resource being deleted |
| Terminated | `PhaseTerminated` | `"Terminated"` | Resource deleted |

### 1.3 Condition Types

**Standard**: Use **PascalCase** for condition types (Kubernetes-style)

| Condition Type | Usage | Status Values |
|----------------|-------|---------------|
| `Ready` | Overall resource readiness | `True`, `False`, `Unknown` |
| `Available` | Resource availability | `True`, `False` |
| `Progressing` | Operation in progress | `True`, `False` |
| `Degraded` | Partial functionality | `True`, `False` |

**Note**: Status values are capitalized (`"True"`, `"False"`), not lowercase.

### 1.4 Field Names

**Standard**: Use **snake_case** in JSON/YAML and database, **PascalCase** in Go structs

| Concept | JSON/YAML | Go Struct | Database Column | Description |
|---------|-----------|-----------|-----------------|-------------|
| Resource ID | `id` | `ID` | `id` | Unique identifier |
| Created time | `created_time` | `CreatedTime` | `created_time` | Creation timestamp |
| Updated time | `updated_time` | `UpdatedTime` | `updated_time` | Last update timestamp |
| Generation | `generation` | `Generation` | `generation` | Spec version counter |
| Observed generation | `observed_generation` | `ObservedGeneration` | `observed_generation` | Last processed version |
| Status phase | `status_phase` | `StatusPhase` | `status_phase` | Current phase |
| Owner ID | `owner_id` | `OwnerID` | `owner_id` | Parent resource ID |

---

## 2. Architecture Patterns

### 2.1 Component Suffixes

**Standard**: Use consistent suffixes for component types

| Component Type | Suffix | Interface Name | Implementation | Package |
|----------------|--------|----------------|----------------|---------|
| Service layer | `Service` | `ClusterService` | `sqlClusterService` | `pkg/services/` |
| Data access | `Dao` | `ClusterDao` | `sqlClusterDao` | `pkg/dao/` |
| HTTP handler | `Handler` | `ClusterHandler` | `clusterHandler` (private) | `pkg/handlers/` |
| HTTP client | `Client` | `HyperFleetClient` | `httpClient` (private) | `pkg/client/`, `internal/client/` |
| Business logic | `Engine` | `DecisionEngine` | `decisionEngine` (private) | `internal/engine/` |
| Configuration | `Config` | `SentinelConfig` | N/A | `pkg/config/`, `internal/config/` |
| Middleware | `Middleware` | `AuthMiddleware` | `jwtMiddleware` (private) | `pkg/middleware/` |

**Pattern**: Public interfaces use PascalCase, private implementations use camelCase.

<details>
<summary>Service/DAO/Handler Pattern Example</summary>

```go
// Service Layer
type ClusterService interface {
    Get(ctx context.Context, id string) (*Cluster, error)
    Create(ctx context.Context, cluster *Cluster) (*Cluster, error)
}

type sqlClusterService struct {
    dao ClusterDao
}

// DAO Layer
type ClusterDao interface {
    Get(ctx context.Context, id string) (*Cluster, error)
    List(ctx context.Context, args *ListArgs) ([]*Cluster, error)
}

type sqlClusterDao struct {
    sessionFactory *SessionFactory
}

// Handler Layer
type ClusterHandler interface {
    List(w http.ResponseWriter, r *http.Request)
    Get(w http.ResponseWriter, r *http.Request)
}

type clusterHandler struct {
    service ClusterService
}
```

</details>

### 2.2 Logger Naming

**Standard**: `HyperFleetLogger` interface across all repositories

Tracked in https://issues.redhat.com/browse/HYPERFLEET-323. Standardize on:
- Configuration (log level, output format)
- Output: structured JSON
- Common log fields (see §5.2)

### 2.3 Error Types

**Standard**: `ServiceError` for business errors, `APIError` for HTTP client errors

```go
const ErrorCodePrefix = "hyperfleet-<service>"  // e.g. "hyperfleet-api", "hyperfleet-adapter"

type ServiceError struct {
    Code     ServiceErrorCode
    Reason   string
    HttpCode int
    Details  []ValidationDetail
}

type APIError struct {
    Method       string
    URL          string
    StatusCode   int
    Retriable    bool
    Attempts     int
    Err          error
}
```

---

## 3. Infrastructure Components

### 3.1 Database Components

| Component | Naming Convention | Example | Notes |
|-----------|-------------------|---------|-------|
| Database name | `hyperfleet_<env>` | `hyperfleet_dev`, `hyperfleet_prod` | Lowercase with underscores |
| Table names | `snake_case`, plural | `clusters`, `node_pools`, `adapter_statuses` | Lowercase, plural |
| Column names | `snake_case` | `created_time`, `status_phase`, `owner_id` | Lowercase with underscores |
| Index names | `idx_<table>_<columns>` | `idx_clusters_name`, `idx_adapter_statuses_owner` | Descriptive, snake_case |
| Foreign keys | `fk_<table>_<ref_table>` | `fk_node_pools_clusters` | Explicit relationship |
| Primary key | `id` | `id` | Always `id`, never `<table>_id` |

<details>
<summary>Complete Table Schema Example</summary>

```sql
CREATE TABLE clusters (
    id VARCHAR(255) PRIMARY KEY,
    name VARCHAR(63) NOT NULL UNIQUE,
    spec JSONB NOT NULL,
    labels JSONB,
    generation INTEGER NOT NULL DEFAULT 1,
    status_phase VARCHAR(50) NOT NULL DEFAULT 'NotReady',
    status_observed_generation INTEGER NOT NULL DEFAULT 0,
    created_time TIMESTAMP NOT NULL,
    updated_time TIMESTAMP NOT NULL,
    deleted_time TIMESTAMP,
    created_by VARCHAR(255) NOT NULL,
    updated_by VARCHAR(255) NOT NULL
);

CREATE INDEX idx_clusters_name ON clusters(name);
CREATE INDEX idx_clusters_status_phase ON clusters(status_phase);

CREATE TABLE node_pools (
    id VARCHAR(255) PRIMARY KEY,
    owner_id VARCHAR(255) NOT NULL REFERENCES clusters(id),
    owner_kind VARCHAR(50) NOT NULL,
    spec JSONB NOT NULL,
    created_time TIMESTAMP NOT NULL
);

ALTER TABLE node_pools
    ADD CONSTRAINT fk_node_pools_clusters
        FOREIGN KEY (owner_id) REFERENCES clusters(id);
```

</details>

### 3.2 Message Broker Components

| Component | Naming Convention | Example | Environment Variable |
|-----------|-------------------|---------|---------------------|
| Topic name | `<resource_type>` | `Cluster`, `NodePool` | `BROKER_TOPIC` |
| Queue/Subscription | `<service>-<resource>-sub` | `adapter-cluster-sub`, `sentinel-cluster-sub` | `BROKER_SUBSCRIPTION_ID` |
| Exchange (RabbitMQ) | `hyperfleet` | `hyperfleet` | `BROKER_EXCHANGE` |
| Exchange type | `topic` | `topic` | `BROKER_EXCHANGE_TYPE` |
| Routing key | `<resource_type>.reconcile` | `Cluster.reconcile`, `NodePool.reconcile` | N/A |

<details>
<summary>Broker Configuration Example</summary>

```yaml
# RabbitMQ
broker:
  type: rabbitmq
  rabbitmq:
    url: amqp://guest:guest@localhost:5672/
    exchange: hyperfleet
    exchange_type: topic

topic: Cluster  # PascalCase resource type
subscription_id: dns-adapter-cluster-sub

# Google Pub/Sub
broker:
  type: googlepubsub
  googlepubsub:
    project_id: hyperfleet-dev
    topic: Cluster
    subscription: sentinel-cluster-sub
```

</details>

### 3.3 Kubernetes Resources

**Standard**: Follow Kubernetes naming conventions

| Resource Type | Naming Pattern | Example | Labels |
|---------------|----------------|---------|--------|
| Namespace | `hyperfleet-<env>` | `hyperfleet-dev`, `hyperfleet-prod` | `hyperfleet.io/environment` |
| Deployment | `<service>-<component>` | `hyperfleet-api`, `dns-adapter`, `sentinel` | `app.kubernetes.io/name`, `app.kubernetes.io/component` |
| Service | `<deployment-name>` | `hyperfleet-api`, `dns-adapter` | `app.kubernetes.io/name` |
| ConfigMap | `<service>-config` | `hyperfleet-api-config`, `dns-adapter-config` | `hyperfleet.io/config-type` |
| Secret | `<service>-secret` | `hyperfleet-api-secret`, `dns-adapter-secret` | `hyperfleet.io/secret-type` |
| ServiceAccount | `<service>-sa` | `hyperfleet-api-sa`, `dns-adapter-sa` | `app.kubernetes.io/name` |

<details>
<summary>Standard Kubernetes Labels</summary>

```yaml
metadata:
  labels:
    # Standard Kubernetes labels
    app.kubernetes.io/name: hyperfleet-api
    app.kubernetes.io/component: api-server
    app.kubernetes.io/part-of: hyperfleet
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/managed-by: helm

    # HyperFleet-specific labels
    hyperfleet.io/environment: production
    hyperfleet.io/tenant: shared
    hyperfleet.io/adapter-type: dns  # For adapters only
```

</details>

### 3.4 Container Images

**Standard**: `<registry>/<org>/<service>:<version>`

| Pattern | Example | Notes |
|---------|---------|-------|
| Development | `quay.io/hyperfleet/hyperfleet-api:dev` | `dev` tag for latest development |
| Feature branch | `quay.io/hyperfleet/hyperfleet-api:feature-abc123` | Git branch + commit SHA |
| Release | `quay.io/hyperfleet/hyperfleet-api:v1.2.3` | Semantic version with `v` prefix |
| Stable | `quay.io/hyperfleet/hyperfleet-api:stable` | Latest stable release |

---

## 4. Configuration & Secrets

### 4.1 Environment Variables

**Standard**: Use `SCREAMING_SNAKE_CASE` with `HYPERFLEET_` service prefix

All environment variables use the `HYPERFLEET_` top-level prefix, followed by a category prefix:

| Category | Prefix | Example | Description |
|----------|--------|---------|-------------|
| HyperFleet API client | `HYPERFLEET_API_` | `HYPERFLEET_API_BASE_URL`, `HYPERFLEET_API_VERSION`, `HYPERFLEET_API_TOKEN`, `HYPERFLEET_API_TIMEOUT` | API client config |
| Message Broker | `HYPERFLEET_BROKER_` | `HYPERFLEET_BROKER_TYPE`, `HYPERFLEET_BROKER_TOPIC`, `HYPERFLEET_BROKER_SUBSCRIPTION_ID` | Message broker config |
| Authentication | `HYPERFLEET_AUTH_`, `OCM_` | `HYPERFLEET_AUTH_ENABLED`, `OCM_CLIENT_ID`, `OCM_BASE_URL` | Auth configuration |
| Tracing / Observability | `HYPERFLEET_TRACING_`, `OTEL_` | `HYPERFLEET_TRACING_ENABLED`, `OTEL_EXPORTER_ENDPOINT` | Monitoring config |
| Server | `HYPERFLEET_SERVER_` | `HYPERFLEET_SERVER_BIND_ADDRESS`, `HYPERFLEET_SERVER_IDENTITY_HEADER` | HTTP server config |
| Kubernetes | `K8S_`, `KUBE_` | `K8S_NAMESPACE`, `KUBE_CONFIG_PATH` | Kubernetes config |

### 4.2 Configuration Files

**Standard**: Use `kebab-case` for filenames, `snake_case` for YAML keys

| File Type | Naming Pattern | Example | Location |
|-----------|----------------|---------|----------|
| Main config | `<service>.yaml` | `sentinel.yaml`, `adapter.yaml` | `configs/` |
| Environment-specific | `<service>-<env>.yaml` | `sentinel-dev.yaml`, `adapter-prod.yaml` | `configs/` |
| Example config | `<service>-example.yaml` | `sentinel-example.yaml` | `configs/` |
| Broker config | `broker.yaml` | `broker.yaml` | Project root |
| Helm values | `values.yaml`, `values-<env>.yaml` | `values.yaml`, `values-prod.yaml` | `charts/<service>/` |

### 4.3 Secrets Management

**Standard**: File-based secrets with standardized naming

| Secret Type | Filename Pattern | Example | Kubernetes Secret Key |
|-------------|------------------|---------|----------------------|
| Database | `db.<property>` | `db.host`, `db.password`, `db.user` | `db-host`, `db-password` |
| API Token | `<service>-token` | `hyperfleet-api-token`, `ocm-token` | `token` |
| Certificate | `<service>.<cert-type>` | `tls.crt`, `tls.key`, `ca.crt` | `tls.crt`, `tls.key` |
| OAuth | `<service>.client-<type>` | `ocm.client-id`, `ocm.client-secret` | `client-id` |

<details>
<summary>Secrets Directory Structure</summary>

```
secrets/
├── db.host
├── db.name
├── db.user
├── db.password
├── db.port
├── hyperfleet-api-token
├── ocm.client-id
├── ocm.client-secret
├── tls.crt
├── tls.key
└── ca.crt
```

</details>

---

## 5. Observability

### 5.1 Metric Names

**Standard**: Prometheus naming conventions with `hyperfleet_` prefix

| Metric Type | Pattern | Example | Labels |
|-------------|---------|---------|--------|
| Counter | `hyperfleet_<object>_<action>_total` | `hyperfleet_events_published_total` | `resource_type`, `topic` |
| Gauge | `hyperfleet_<object>_<state>` | `hyperfleet_resources_pending` | `resource_type`, `phase` |
| Histogram | `hyperfleet_<operation>_duration_seconds` | `hyperfleet_api_request_duration_seconds` | `method`, `endpoint`, `status` |
| Summary | `hyperfleet_<operation>_summary` | `hyperfleet_reconcile_summary` | `adapter`, `result` |

<details>
<summary>Prometheus Metric Definition Example</summary>

```go
var (
    eventsPublishedTotal = prometheus.NewCounterVec(
        prometheus.CounterOpts{
            Name: "hyperfleet_events_published_total",
            Help: "Total number of CloudEvents published",
        },
        []string{"resource_type", "topic"},
    )

    resourcesPendingGauge = prometheus.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "hyperfleet_resources_pending",
            Help: "Number of resources pending reconciliation",
        },
        []string{"resource_type", "phase"},
    )

    apiRequestDuration = prometheus.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "hyperfleet_api_request_duration_seconds",
            Help:    "API request duration in seconds",
            Buckets: prometheus.DefBuckets,
        },
        []string{"method", "endpoint", "status_code"},
    )
)

// Label naming: use snake_case
[]string{"resource_type", "status_code", "error_type"}
```

</details>

### 5.2 Log Levels & Fields

**Standard**: Structured logging with consistent field names

| Log Level | When to Use | Example |
|-----------|-------------|---------|
| `V(1)` (Info) | Normal operations, state changes | `Cluster created`, `Event published` |
| `V(2)` (Debug) | Detailed debugging, function entry/exit | `Entering FetchResources()`, `Cache hit` |
| `V(3)` (Trace) | Very verbose, request/response bodies | `HTTP request: POST /api/v1/clusters` |
| `Warning` | Recoverable errors, deprecated usage | `Retry attempt 3/5`, `Using deprecated config` |
| `Error` | Error conditions | `Failed to connect to broker`, `Database error` |
| `Fatal` | Unrecoverable errors | `Cannot load config`, `Failed to start server` |

**Standard Log Fields**:

| Field Name | Type | Description | Example |
|------------|------|-------------|---------|
| `cluster_id` | string | Cluster identifier | `cluster-abc123` |
| `resource_id` | string | Generic resource ID | `nodepool-xyz789` |
| `resource_type` | string | Resource kind | `Cluster`, `NodePool` |
| `operation` | string | Operation being performed | `create`, `update`, `delete` |
| `adapter` | string | Adapter name | `dns-adapter`, `hypershift-adapter` |
| `error_type` | string | Error classification | `validation_error`, `network_error` |
| `duration_ms` | int64 | Operation duration in milliseconds | `1250` |
| `status_code` | int | HTTP status code | `200`, `404`, `500` |
| `attempt` | int | Retry attempt number | `1`, `2`, `3` |

### 5.3 Trace & Span Names

**Standard**: OpenTelemetry naming conventions (for future distributed tracing)

| Component | Pattern | Example |
|-----------|---------|---------|
| Span name | `<Component> <Operation>` | `HyperFleetAPI CreateCluster`, `DNSAdapter ReconcileCluster` |
| Span attributes | `hyperfleet.<attribute>` | `hyperfleet.cluster_id`, `hyperfleet.adapter_type` |

---

## 6. API & HTTP Conventions

### 6.1 REST Endpoint Patterns

**Standard**: RESTful URLs with versioning

| Resource | Pattern | Example | HTTP Methods |
|----------|---------|---------|--------------|
| Collection | `/api/hyperfleet/<version>/<resources>` | `/api/hyperfleet/v1/clusters` | `GET`, `POST` |
| Single resource | `/api/hyperfleet/<version>/<resources>/{id}` | `/api/hyperfleet/v1/clusters/cluster-123` | `GET`, `PATCH`, `DELETE` |
| Sub-collection | `/api/hyperfleet/<version>/<resources>/{id}/<sub-resources>` | `/api/hyperfleet/v1/clusters/cluster-123/nodepools` | `GET`, `POST` |
| Sub-resource | `/api/hyperfleet/<version>/<resources>/{id}/<sub-resources>/{sub-id}` | `/api/hyperfleet/v1/clusters/cluster-123/nodepools/np-456` | `GET`, `PATCH`, `DELETE` |
| Action | `/api/hyperfleet/<version>/<resources>/{id}/<action>` | `/api/hyperfleet/v1/clusters/cluster-123/statuses` | `POST` |

### 6.2 Query Parameters

**Standard**: Use `snake_case` for query parameters

| Parameter | Purpose | Example | Default |
|-----------|---------|---------|---------|
| `page` | Page number (1-indexed) | `/api/hyperfleet/v1/clusters?page=2` | `1` |
| `size` | Items per page | `/api/v1/clusters?size=50` | `20` |
| `order_by` | Sort field | `/api/hyperfleet/v1/clusters?order_by=created_time` | `created_time` |
| `order` | Sort direction | `/api/hyperfleet/v1/clusters?order=desc` | `asc` |
| `search` | Search query (TSL) | `/api/hyperfleet/v1/clusters?search=name='prod'` | `""` |
| `fields` | Field selection | `/api/hyperfleet/v1/clusters?fields=id,name` | All fields |

### 6.3 HTTP Headers

**Standard**: Standard HTTP headers + custom `X-HyperFleet-*` headers

| Header | Purpose | Example | Required |
|--------|---------|---------|----------|
| `Content-Type` | Request body format | `application/json` | POST/PATCH |
| `Authorization` | Bearer token | `Bearer eyJhbGc...` | Auth enabled |
| `X-HyperFleet-Operation-ID` | Request trace ID | `X-HyperFleet-Operation-ID: abc123` | All requests (auto) |
| `X-HyperFleet-Request-ID` | Client request ID | `X-HyperFleet-Request-ID: client-123` | Optional |
| `X-HyperFleet-Idempotency-Key` | Idempotency key | `X-HyperFleet-Idempotency-Key: uuid` | Optional (POST) |

**Note**: Custom headers use `X-HyperFleet-` prefix with Title-Case-Hyphenation (not `X-hyperfleet-`).

### 6.4 Error Response Format

**Standard**: Consistent error response structure

<details>
<summary>Error Response JSON Example</summary>

```json
{
  "kind": "Error",
  "id": "7",
  "href": "/api/hyperfleet/v1/errors/7",
  "code": "hyperfleet-7",
  "reason": "Cluster not found",
  "operation_id": "2aKxWvCqJzYZ8YJoFsH4P9uJ3Lr",
  "details": [
    {
      "field": "spec.region",
      "error": "field is required"
    }
  ]
}
```

</details>

**Fields**:

| Field | Type | Description | Always Present |
|-------|------|-------------|----------------|
| `kind` | string | Always `"Error"` | ✅ |
| `id` | string | Error code number | ✅ |
| `href` | string | Error documentation URL | ✅ |
| `code` | string | Error code string | ✅ |
| `reason` | string | Human-readable message | ✅ |
| `operation_id` | string | Request operation ID | ✅ |
| `details` | array | Field-level errors | Optional |

---

## 7. Database Schema

### 7.1 Table Naming

**Standard**: `snake_case`, plural nouns (e.g., `clusters`, `node_pools`, `adapter_statuses`)

### 7.2 Column Naming

**Standard**: `snake_case`, descriptive

| Column Type | Pattern | Example | Notes |
|-------------|---------|---------|-------|
| Primary key | `id` | `id` | UUID or KSUID string |
| Foreign key | `<table>_id` | `owner_id`, `cluster_id` | Reference to parent |
| Timestamps | `<action>_time` | `created_time`, `updated_time`, `deleted_time` | UTC timestamps |
| Boolean | `is_<adjective>` or `<verb>_<noun>` | `is_deleted`, `enable_metrics` | Clear intent |
| JSONB | `<noun>` | `spec`, `labels`, `metadata` | No `_json` suffix |
| Enum | `<noun>_<type>` | `status_phase`, `owner_kind` | Clear categorization |

### 7.3 Index Naming

**Standard**: `idx_<table>_<column(s)>` or `idx_<table>_<purpose>`

Examples: `idx_clusters_name`, `idx_clusters_status_phase`, `idx_adapter_statuses_owner_adapter`

Unique constraints: `uniq_<table>_<column>` (e.g., `uniq_clusters_name`)

### 7.4 Constraint Naming

**Standard**: `<type>_<table>_<column(s)>`

| Constraint Type | Prefix | Example |
|----------------|--------|---------|
| Primary key | `pk_` | `pk_clusters` |
| Foreign key | `fk_` | `fk_node_pools_owner` |
| Unique | `uniq_` | `uniq_clusters_name` |
| Check | `chk_` | `chk_clusters_generation_positive` |

---

## 8. Kubernetes Resources

### 8.1 Custom Resource Definitions (CRDs)

> **Note**: AdapterConfig is currently YAML-based configuration, not a registered Kubernetes CRD. The `hyperfleet.redhat.com` API group and CRD pattern below are aspirational — apply when CRDs are introduced.

**Standard**: Follow Kubernetes conventions

<details>
<summary>CRD Example</summary>

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: adapterconfigs.hyperfleet.redhat.com
spec:
  group: hyperfleet.redhat.com
  versions:
    - name: v1alpha1
      served: true
      storage: true
  scope: Namespaced
  names:
    plural: adapterconfigs
    singular: adapterconfig
    kind: AdapterConfig
    shortNames:
      - ac
```

</details>

**Naming Rules**:
- CRD name: `<plural>.<group>`
- Group: `hyperfleet.redhat.com`
- Version: `v1alpha1`, `v1beta1`, `v1`
- Kind: PascalCase (e.g., `AdapterConfig`)
- Plural: lowercase (e.g., `adapterconfigs`)

### 8.2 Labels & Annotations

**Standard**: Use namespaced labels (`app.kubernetes.io/*` and `hyperfleet.io/*`)

<details>
<summary>Recommended Labels & Annotations</summary>

```yaml
metadata:
  labels:
    # Standard Kubernetes labels
    app.kubernetes.io/name: dns-adapter
    app.kubernetes.io/instance: dns-adapter-prod
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/component: adapter
    app.kubernetes.io/part-of: hyperfleet
    app.kubernetes.io/managed-by: helm

    # HyperFleet-specific labels
    hyperfleet.io/adapter-type: dns
    hyperfleet.io/resource-type: clusters
    hyperfleet.io/environment: production
    hyperfleet.io/tenant: shared

  annotations:
    description: "DNS adapter for HyperFleet cluster provisioning"
    hyperfleet.io/config-checksum: "abc123..."
    hyperfleet.io/last-updated-by: "admin@redhat.com"
    hyperfleet.io/provisioner: "dns-adapter-v1.0.0"
```

</details>

### 8.3 Deployment & Service Names

**Standard**: `<service>-<component>` or just `<service>` for single-component services

e.g. Hyperfleet API Service name = `hyperfleet-api`

---

## 9. Messaging & Events

### 9.1 CloudEvents Structure

**Standard**: Follow CloudEvents v1.0 specification

Use lower case for the CloudEvent type, and snake_case for data fields

<details>
<summary>CloudEvents JSON Example</summary>

```json
{
  "specversion": "1.0",
  "type": "com.redhat.hyperfleet.cluster.reconcile",
  "source": "hyperfleet/services/sentinel",
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "time": "2025-12-06T12:00:00Z",
  "datacontenttype": "application/json",
  "data": {
    "type": "Cluster",
    "id": "cluster-abc123",
    "href": "/api/hyperfleet/v1/clusters/cluster-abc123",
    "generation": 5,
    "reason": "MaxAgeExceeded"
  }
}
```

</details>

**Field Standards**:

| Field | Format | Example | Notes |
|-------|--------|---------|-------|
| `type` | `com.redhat.hyperfleet.<resource>.<action>` | `com.redhat.hyperfleet.cluster.reconcile` | Reverse DNS + lowercase resource + action |
| `source` | `<service-name>` | `hyperfleet-sentinel`, `dns-adapter` | Service that emitted event |
| `id` | UUID | `550e8400-e29b-41d4-a716-446655440000` | Unique per event |
| `time` | RFC3339 | `2026-06-15T12:00:00Z` | UTC timestamp |

**Data Payload**: Use `snake_case` for field names (`resource_type`, `resource_id`, `href`, not `resourceType`).

### 9.2 Topic & Queue Naming

See [Section 3.2 Message Broker Components](#32-message-broker-components)

---

## 10. Repository Naming

**Standard**: `hyperfleet-<service>` for all HyperFleet repositories

| Service Type | Repository Name | Description |
|--------------|-----------------|-------------|
| Core API | `hyperfleet-api` | REST API and data layer |
| Orchestration | `hyperfleet-sentinel` | Business logic and event publishing |
| Adapter (generic) | `hyperfleet-adapter` | Generic adapter framework |
| DNS Adapter | `hyperfleet-dns-adapter` | DNS-specific adapter implementation |
| Hypershift Adapter | `hyperfleet-hypershift-adapter` | Hypershift-specific adapter |
| Architecture docs | `architecture` | System architecture documentation |
| API specification | `hyperfleet-api-spec` | TypeSpec API definitions |

**Pattern**: Use lowercase with hyphens, always prefix with `hyperfleet-` (except `architecture`)

---

## 11. Binary Naming

**Standard**: Binary name matches the service component name (without `hyperfleet-` prefix)

| Repository | Binary Name | Build Command | Location |
|------------|-------------|---------------|----------|
| `hyperfleet-api` | `hyperfleet-api` | `go build ./cmd/hyperfleet-api` | `./hyperfleet-api` |
| `hyperfleet-sentinel` | `sentinel` | `go build ./cmd/sentinel` | `./sentinel` |
| `hyperfleet-adapter` | `hyperfleet-adapter` | `go build ./cmd/adapter` | `./hyperfleet-adapter` |

**Pattern**:
- Service-level tools use short names (e.g., `sentinel`)
- Full stack services keep the `hyperfleet-` prefix (e.g., `hyperfleet-api`)
- Output location: project root or `bin/` directory

**CMD Directory Structure**:
```
cmd/
└── <service-name>/    # e.g., sentinel, adapter, hyperfleet-api
    └── main.go
```

---

## 12. Makefile Conventions

**Standard**: Common targets across all repositories

### 12.1 Core Targets

| Target | Purpose | Standard Behavior |
|--------|---------|-------------------|
| `help` | Display available targets | Default target (`.DEFAULT_GOAL := help`) |
| `build` | Build binary | Compile to project root or `bin/` directory |
| `install` | Install to GOPATH | `go install ./cmd/...` |
| `clean` | Remove build artifacts | Delete binaries, coverage files, generated code |
| `test` | Run unit tests | `go test -v -race ./...` |
| `test-unit` | Run unit tests (explicit) | `go test ./...` (excludes integration) |
| `test-integration` | Run integration tests | `go test -tags=integration ./test/integration/...` |
| `test-coverage` | Generate coverage report | `go test -coverprofile=coverage.out ./...` |
| `lint` | Run linters | `golangci-lint run` |
| `verify` | Verify source code | `go vet ./...` and format checks |
| `fmt` | Format code | `gofmt -s -w .` |
| `generate` | Generate code | OpenAPI client, mocks, etc. |
| `generate-mocks` | Generate mock implementations | `mockgen` or equivalent |

### 12.2 Service-Specific Targets

| Target | Purpose | Used By |
|--------|---------|---------|
| `run` | Run the service locally | All services |
| `run-no-auth` | Run without authentication | `hyperfleet-api` |
| `secrets` | Initialize secrets directory | `hyperfleet-api` |
| `db/setup` | Start local database | `hyperfleet-api` |
| `db/migrate` | Run database migrations | `hyperfleet-api` |
| `db/teardown` | Stop local database | `hyperfleet-api` |
| `image` | Build container image | All services |
| `image-push` | Push container image to registry | All services |

### 12.3 Variable Naming

**Standard**: Use `SCREAMING_SNAKE_CASE` for Makefile variables

```makefile
# ✅ CORRECT
PROJECT_NAME := hyperfleet-adapter
BINARY_NAME := sentinel
GO := go
CONTAINER_TOOL ?= podman

# ❌ INCORRECT
project_name := hyperfleet-adapter  # lowercase
BinaryName := sentinel              # camelCase
```

---

## 13. Package & Module Naming

### 13.1 Go Module Names

**Standard**: `github.com/openshift-hyperfleet/<repository>`

Examples: `github.com/openshift-hyperfleet/hyperfleet-adapter`

### 13.2 Go Package Names

**Standard**: Short, lowercase, no underscores

| Package Purpose | Package Name | Path | Notes |
|----------------|--------------|------|-------|
| HTTP handlers | `handlers` | `pkg/handlers/` | Plural |
| Services | `services` | `pkg/services/` | Plural |
| Data access | `dao` | `pkg/dao/` | Abbreviation OK |
| Database | `db` | `pkg/db/` | Abbreviation OK |
| Configuration | `config` | `pkg/config/`, `internal/config/` | Singular |
| Logging | `logger` | `pkg/logger/` | Singular |
| Errors | `errors` | `pkg/errors/` | Plural |
| API models | `api` | `pkg/api/` | Singular |
| Kubernetes client | `k8s` or `k8sclient` | `internal/k8s_client/` | Abbreviation OK |
| Utilities | `util` | `pkg/util/` | Singular, abbreviation OK |

### 13.3 Directory Structure

**Standard**: Consistent across all repositories

<details>
<summary>Standard Directory Layout</summary>

```
<repository>/
├── cmd/                      # Application entry points
│   └── <service>/
│       └── main.go
├── pkg/                      # Public packages (importable)
│   ├── api/                  # API models
│   ├── logger/               # Logging
│   ├── errors/               # Error types
│   └── ...
├── internal/                 # Private packages (not importable)
│   ├── <component>/
│   └── ...
├── test/                     # Integration tests
│   └── integration/
├── configs/                  # Configuration examples
├── charts/                   # Helm charts
│   └── <service>/
├── deployments/              # Deployment artifacts (optional)
│   ├── helm/
│   └── dashboards/
├── docs/                     # Documentation
├── scripts/                  # Build/deployment scripts
├── .github/                  # GitHub Actions workflows
├── Dockerfile
├── Makefile
├── go.mod
├── go.sum
└── README.md
```

</details>

---
