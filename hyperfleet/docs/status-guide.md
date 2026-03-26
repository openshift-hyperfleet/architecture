---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-03-11
---

# HyperFleet Cluster Status JSON Guide


---

## Overview

Comprehensive guide to the HyperFleet cluster status JSON structure and the adapter status reporting contract. Explains the condition-based status model (Available, Applied, Health), how adapter statuses are aggregated into cluster-level status, and how Sentinel uses status to make reconciliation decisions. The authoritative reference for implementing status reporting in adapters.

HyperFleet uses a **condition-based status reporting contract** where adapters report their progress through standardized Kubernetes-style conditions. This guide explains:

1. **The REST API** - Endpoints for reading and updating cluster status
2. **The Adapter → API Contract** - Required payload structure for status updates
3. **The Three Required Conditions** - Available, Applied, Health
4. **How to Read Cluster Status** - Interpreting aggregated cluster state
5. **Common Patterns** - Polling, error handling, progress tracking

---

## API Specification Reference

**Official Schema Definitions**: All JSON schemas referenced in this guide are defined in the [hyperfleet-api-spec](https://github.com/openshift-hyperfleet/hyperfleet-api-spec) repository.

- **Cluster Schema**: [Cluster Object](https://github.com/openshift-hyperfleet/hyperfleet-api-spec/blob/main/schemas/core/openapi.yaml)
- **ClusterStatus Schema**: [ClusterStatus Object](https://github.com/openshift-hyperfleet/hyperfleet-api-spec/blob/main/schemas/core/openapi.yaml)
- **Condition Schema**: [Condition Object](https://github.com/openshift-hyperfleet/hyperfleet-api-spec/blob/main/schemas/core/openapi.yaml)

> **Important**: The JSON examples in this guide are illustrative. For authoritative schema definitions, field types, validation rules, and constraints, always refer to the [API specification repository](https://github.com/openshift-hyperfleet/hyperfleet-api-spec).

---

## REST API Summary

### Resource Hierarchy

```
/v1/clusters/{clusterId}                    # Cluster resource (with aggregated status)
/v1/clusters/{clusterId}/statuses           # ClusterStatus resource (detailed adapter statuses)
```

### Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| **GET** | `/v1/clusters/{clusterId}` | Get cluster with aggregated status (phase + adapter availability) |
| **GET** | `/v1/clusters/{clusterId}/statuses` | Get the ClusterStatus with all adapter statuses (optional - for querying) |
| **POST** | `/v1/clusters/{clusterId}/statuses` | Adapter reports status (API handles upsert internally) |

> **Note**: This document will be updated with references to the Adapter Configuration Framework from [PR #18](https://github.com/openshift-hyperfleet/architecture/pull/18) once it is merged. The PR introduces a declarative YAML-based system for adapter configuration, event handling, and status reporting.

### Adapter Status Reporting Flow

When an adapter needs to report its status, it **always POSTs**. The API handles the upsert logic internally.

#### Adapter Action: POST Status Report

**POST** `/v1/clusters/{clusterId}/statuses`

```json
{
  "adapter": "validation",           // Identifies which adapter is reporting
  "observed_generation": 1,
  "conditions": [
    {
      "type": "Available",
      "status": "True",
      "reason": "JobSucceeded",
      "message": "Job completed successfully",
      "last_transition_time": "2025-10-17T12:02:00Z"
    },
    {
      "type": "Applied",
      "status": "True",
      "reason": "JobLaunched",
      "message": "Job created successfully",
      "last_transition_time": "2025-10-17T12:00:05Z"
    },
    {
      "type": "Health",
      "status": "True",
      "reason": "NoErrors",
      "message": "Adapter is healthy",
      "last_transition_time": "2025-10-17T12:02:00Z"
    }
  ],
  "data": {
    "validationResults": {
      "route53ZoneFound": true,
      "s3BucketAccessible": true
    }
  },
  "metadata": {
    "job_name": "validation-cls-123-gen1"
  },
  "last_updated_time": "2025-10-17T12:02:00Z"    // When adapter checked (now())
}
```

**Response**: `200 OK` with updated ClusterStatus object (whether first report or subsequent update)

**What Happens (API-side)**:
1. API receives POST with `adapter` field identifying which adapter is reporting
2. API finds the adapter entry in `adapter_statuses` array (or creates if first time)
3. If first report: API INSERTs adapter with `created_at = now()`
4. If subsequent report: API UPDATEs adapter, preserving `created_at` and updating `updated_at`
5. API recalculates `cluster.status.last_updated_time = min(adapters[].last_updated_time)`
   - This uses the OLDEST adapter timestamp to represent status confidence
   - Ensures Sentinel triggers reconciliation when ANY adapter is stale
6. API recalculates Cluster aggregated status (phase + adapters array)

**Response**: `200 OK` with updated ClusterStatus object (whether first report or update)

### Adapter Implementation Pattern

**Simple Pattern** (recommended - API handles upsert internally):

```javascript
function reportStatus(clusterId, adapterStatus) {
  // Adapter always POSTs - API decides if INSERT or UPDATE
  POST /v1/clusters/{clusterId}/statuses
  body = {
    adapter: "dns",              // Identifies which adapter
    observed_generation: 1,
    conditions: [...],
    data: {...},
    last_updated_time: now()           // When adapter checked
  }

  // API returns 200 OK whether first report or update
}
```

**Why this pattern?**
- **Adapter simplicity**: No GET/POST/PATCH logic needed
- **Idempotent**: Safe to retry on failures
- **API encapsulation**: Upsert logic is API's internal implementation detail
- **Clear responsibility**: Adapter reports, API persists

**Note**: The `adapterStatus` object includes `observed_generation` which tells the API what generation of the cluster spec this adapter has reconciled.

---

## The Adapter Status Contract

### Reporting Status: Always POST

Adapters **always POST** to report status. The API handles upsert internally (INSERT if first report, UPDATE if adapter already reported).

**Endpoint**: `POST /v1/clusters/{clusterId}/statuses`

**Payload Structure**: Adapters send just their status with `adapter` field identifying themselves:

```json
{
  "adapter": "validation",           // Identifies which adapter is reporting
  "observed_generation": 1,
  "conditions": [
    {
      "type": "Available",
      "status": "True",
      "reason": "JobSucceeded",
      "message": "Job completed successfully after 115 seconds",
      "last_transition_time": "2025-10-17T12:02:00Z"
    },
    {
      "type": "Applied",
      "status": "True",
      "reason": "JobLaunched",
      "message": "Kubernetes Job created successfully",
      "last_transition_time": "2025-10-17T12:00:05Z"
    },
    {
      "type": "Health",
      "status": "True",
      "reason": "AllChecksPassed",
      "message": "All validation checks passed",
      "last_transition_time": "2025-10-17T12:02:00Z"
    }
  ],
  "data": {
    "validationResults": {
      "route53ZoneFound": true,
      "s3BucketAccessible": true,
      "quotaSufficient": true
    }
  },
  "metadata": {
    "job_name": "validation-cls-123-gen1",
    "executionTime": "115s"
  },
  "last_updated_time": "2025-10-17T12:02:00Z"   // When adapter checked (now())
}
```

**API Response**: `200 OK` (whether first report or subsequent update)

**Note**: No `generation` field on ClusterStatus itself. Each adapter reports its own `observed_generation`.

### CRITICAL: Always Update `last_updated_time`

**Required Behavior**: Adapters MUST update their status on EVERY evaluation, regardless of whether they take action or skip work.

**Why This Matters**:

The Sentinel uses `last_updated_time` timestamps to calculate max age intervals for publishing reconciliation events. If adapters do not update `last_updated_time` when they skip work (e.g., preconditions not met), the Sentinel will create an infinite event loop:

```
Time 10:00 - DNS adapter receives reconciliation event
Time 10:00 - DNS checks preconditions: Validation adapter not complete
Time 10:00 - DNS does NOT update status (skips work)
            ❌ cluster.status.last_updated_time remains at 09:50
Time 10:10 - Sentinel sees last_updated_time=09:50, max age expired (10s)
Time 10:10 - Sentinel publishes ANOTHER event
Time 10:10 - DNS receives event AGAIN, checks preconditions AGAIN...
            ↻ INFINITE LOOP until validation completes
```

**Correct Behavior - Update Status Even When Skipping Work**:

When an adapter evaluates a cluster but determines it should not take action (preconditions not met), it MUST still report status:

```json
{
  "adapter": "dns",
  "observed_generation": 1,
  "conditions": [
    {
      "type": "Available",
      "status": "False",
      "reason": "PreconditionsNotMet",
      "message": "Waiting for validation adapter to complete",
      "last_transition_time": "2025-10-17T10:00:00Z"
    },
    {
      "type": "Applied",
      "status": "False",
      "reason": "PreconditionsNotMet",
      "message": "Waiting for validation adapter",
      "last_transition_time": "2025-10-17T10:00:00Z"
    },
    {
      "type": "Health",
      "status": "True",
      "reason": "NoErrors",
      "message": "Adapter is healthy",
      "last_transition_time": "2025-10-17T10:00:00Z"
    }
  ],
  "last_updated_time": "2025-10-17T10:00:00Z"  // ← CRITICAL: Update timestamp even when skipping work
}
```

**Integration Testing Requirement**:

Integration tests for adapters MUST verify:
- ✅ Adapter updates `last_updated_time` when preconditions are met and work is performed
- ✅ Adapter updates `last_updated_time` when preconditions are NOT met and work is skipped
- ✅ Sentinel correctly calculates max age from adapter `last_updated_time` timestamps

**Reference**: See the Sentinel architecture documentation for details on the max age strategy and reconciliation loop.

---

### Implementation via Adapter Configuration (PR #18)

> **Note**: Once [PR #18](https://github.com/openshift-hyperfleet/architecture/pull/18) is merged, this section will be expanded with configuration examples.

Adapters generate this status payload using declarative configuration that defines:

1. **Status Evaluation Rules** - How to calculate each condition (Applied, Available, Health) based on resource state
2. **Payload Templates** - How to construct the JSON payload with dynamic data
3. **API Reporting Actions** - When and how to POST/PATCH to the HyperFleet API

**Example configuration snippet** (from PR #18):
```yaml
postProcessing:
  statusEvaluation:
    available:
      status:
        allOf:
          - field: "resources.validationJob.status.succeeded"
            operator: "eq"
            value: 1
      templates:
        true:
          reason: "JobSucceeded"
          message: "Job completed successfully"
        false:
          reason: "JobFailed"
          message: "Validation Job failed"

  actions:
    - type: "api_call"
      method: "PATCH"
      endpoint: "{{.hyperfleetApi}}/api/{{.version}}/clusters/{{.clusterId}}/statuses"
      body: "{{.clusterStatusPayload}}"
```

This configuration-driven approach ensures consistent status reporting across all adapters without requiring code changes.

### ClusterStatus Object Structure

The ClusterStatus object is a **RESTful resource** that contains ALL adapter statuses for a cluster in one place:

```json
{
  "id": "status-cls-550e8400",
  "type": "clusterStatus",
  "href": "/api/hyperfleet/v1/clusters/cls-550e8400/statuses",
  "cluster_id": "cls-550e8400",
  "adapter_statuses": [
    {
      "adapter": "validation",
      "observed_generation": 1,
      "conditions": [
        {
          "type": "Available",
          "status": "True",
          "reason": "JobSucceeded",
          "message": "Job completed successfully after 115 seconds",
          "last_transition_time": "2025-10-17T12:02:00Z"
        },
        {
          "type": "Applied",
          "status": "True",
          "reason": "JobLaunched",
          "message": "Kubernetes Job created successfully",
          "last_transition_time": "2025-10-17T12:00:05Z"
        },
        {
          "type": "Health",
          "status": "True",
          "reason": "AllChecksPassed",
          "message": "All validation checks passed",
          "last_transition_time": "2025-10-17T12:02:00Z"
        }
      ],
      "data": {
        "validationResults": {
          "route53ZoneFound": true,
          "s3BucketAccessible": true,
          "quotaSufficient": true
        }
      },
      "metadata": {
        "job_name": "validation-cls-123-gen1",
        "executionTime": "115s"
      },
      "last_updated_time": "2025-10-17T12:02:00Z"
    },
    {
      "adapter": "dns",
      "observed_generation": 1,
      "conditions": [
        {
          "type": "Available",
          "status": "True",
          "reason": "AllRecordsCreated",
          "message": "All DNS records created and verified",
          "last_transition_time": "2025-10-17T12:05:00Z"
        },
        {
          "type": "Applied",
          "status": "True",
          "reason": "JobLaunched",
          "message": "DNS Job created successfully",
          "last_transition_time": "2025-10-17T12:03:00Z"
        },
        {
          "type": "Health",
          "status": "True",
          "reason": "NoErrors",
          "message": "DNS adapter executed without errors",
          "last_transition_time": "2025-10-17T12:05:00Z"
        }
      ],
      "data": {
        "recordsCreated": ["api.my-cluster.example.com", "*.apps.my-cluster.example.com"]
      },
      "last_updated_time": "2025-10-17T12:05:00Z"
    }
  ],
  "last_updated_time": "2025-10-17T12:05:00Z"
}
```

### ClusterStatus Fields

> **Schema Reference**: See [ClusterStatus schema definition](https://github.com/openshift-hyperfleet/hyperfleet-api-spec/blob/main/schemas/core/openapi.yaml) in the API spec for complete field definitions, types, and validation rules.

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `id` | **YES** | string | Unique ID for this ClusterStatus object |
| `type` | **YES** | string | Always "clusterStatus" |
| `href` | **YES** | string | API path to this ClusterStatus resource |
| `clusterId` | **YES** | string | ID of the cluster this status belongs to |
| `adapter_statuses` | **YES** | array | Array of adapter status objects |
| `last_updated_time` | **YES** | timestamp | When this ClusterStatus was last updated |

### AdapterStatus Fields (within adapter_statuses array)

> **Schema Reference**: See [AdapterStatus schema definition](https://github.com/openshift-hyperfleet/hyperfleet-api-spec/blob/main/schemas/core/openapi.yaml) in the API spec for complete field definitions, types, and validation rules.

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `adapter` | **YES** | string | Adapter name (e.g., "validation", "dns") |
| `observed_generation` | **YES** | integer | Cluster generation this adapter reconciled |
| `conditions` | **YES** | array | **Minimum 3 conditions** (Available, Applied, Health) |
| `data` | **NO** | JSONB | Adapter-specific structured data (optional) |
| `metadata` | **NO** | object | Additional metadata (optional) |
| `last_updated_time` | **YES** | timestamp | When this adapter status was last updated |

**Key Points**:
- **ONE ClusterStatus object per cluster** - All adapter statuses grouped together
- ClusterStatus does NOT have a generation field - it reflects current observed state
- Each adapter in `adapter_statuses` has `observed_generation` indicating which cluster generation it has reconciled
- Cluster spec has `generation` (user's intent), adapters report `observed_generation` (observed state)
- Adapters always POST with `adapter` field in payload - API handles upsert internally
- API creates ClusterStatus on first report, updates adapter entry on subsequent reports
- This is much more RESTful: `/clusters/{id}/statuses` represents the complete status of the cluster
- Prevents scattered status objects - everything in one cohesive resource
- The Cluster object still contains only aggregated status (see below)

---

## The Three Required Conditions

Every adapter status update **MUST** include these three conditions:

### 1. Available

**Purpose**: Has the adapter completed its work successfully? 

**Important**: The adapter aggregates this value based on all its other conditions 

**Meaning**:
- `True` - Adapter finished successfully, all requirements met
- `False` - Adapter failed, incomplete, or still in progress

**Examples**:
```json
// Success
{
  "type": "Available",
  "status": "True",
  "reason": "JobSucceeded",
  "message": "Validation Job completed successfully",
  "last_transition_time": "2025-10-17T12:02:00Z"
}

// Failure
{
  "type": "Available",
  "status": "False",
  "reason": "JobFailed",
  "message": "Validation failed: Route53 zone not found for domain example.com",
  "last_transition_time": "2025-10-17T12:02:00Z"
}

// In Progress
{
  "type": "Available",
  "status": "False",
  "reason": "JobRunning",
  "message": "Validation Job is still executing",
  "last_transition_time": "2025-10-17T12:00:05Z"
}
```

### 2. Applied

**Purpose**: Has the adapter created/applied the Kubernetes resources it needs?

**Meaning**:
- `True` - Resources created successfully (Job launched, ConfigMap applied, etc.)
- `False` - Failed to create resources or not yet attempted

**Examples**:
```json
// Job Created
{
  "type": "Applied",
  "status": "True",
  "reason": "JobLaunched",
  "message": "Kubernetes Job 'validation-cls-123-gen1' created successfully",
  "last_transition_time": "2025-10-17T12:00:05Z"
}

// Creation Failed
{
  "type": "Applied",
  "status": "False",
  "reason": "ResourceQuotaExceeded",
  "message": "Failed to create Job: namespace quota exceeded",
  "last_transition_time": "2025-10-17T12:00:05Z"
}

// Not Yet Attempted
{
  "type": "Applied",
  "status": "False",
  "reason": "PreconditionsNotMet",
  "message": "Waiting for validation to complete",
  "last_transition_time": "2025-10-17T12:00:05Z"
}
```

### 3. Health

**Purpose**: Did anything unexpected or concerning happen?

**Meaning**:
- `True` - No unexpected errors, adapter is healthy
- `False` - Unexpected error occurred (retries exhausted, resource not found, etc.)

**Key Point**: Health is about **unexpected errors**, not business logic failures.

**Examples**:
```json
// Healthy (even if validation fails business logic)
{
  "type": "Health",
  "status": "True",
  "reason": "AllChecksPassed",
  "message": "Adapter executed normally without errors",
  "last_transition_time": "2025-10-17T12:02:00Z"
}

// Unhealthy (unexpected error)
{
  "type": "Health",
  "status": "False",
  "reason": "UnexpectedError",
  "message": "Failed to connect to Kubernetes API after 3 retries",
  "last_transition_time": "2025-10-17T12:02:00Z"
}

// Unhealthy (resource missing)
{
  "type": "Health",
  "status": "False",
  "reason": "ResourceNotFound",
  "message": "Job 'validation-cls-123-gen1' not found in cluster",
  "last_transition_time": "2025-10-17T12:02:00Z"
}
```

---

## Additional Conditions (Optional)

Adapters **MAY** send additional conditions beyond the three required ones. These can provide more granular status information.

### Rules for Additional Conditions

1. **All conditions must be positive assertions**
   - GOOD: `DNSRecordsCreated` (status: True/False)
   - BAD: `DNSRecordsNotCreated` (confusing when status: False)

2. **Adapter aggregates all conditions to determine Available**
   - If any condition is False, Available should be False
   - If all conditions are True, Available should be True

### Example: DNS Adapter with Additional Conditions

This example shows an adapter status payload (what gets PUT to the API and stored in the ClusterStatus `adapter_statuses` array):

```json
{
  "adapter": "dns",
  "observed_generation": 1,
  "conditions": [
    {
      "type": "Available",
      "status": "True",
      "reason": "AllRecordsCreated",
      "message": "All DNS records created and verified",
      "last_transition_time": "2025-10-17T12:05:00Z"
    },
    {
      "type": "Applied",
      "status": "True",
      "reason": "JobLaunched",
      "message": "DNS Job created successfully",
      "last_transition_time": "2025-10-17T12:03:00Z"
    },
    {
      "type": "Health",
      "status": "True",
      "reason": "NoErrors",
      "message": "DNS adapter executed without errors",
      "last_transition_time": "2025-10-17T12:05:00Z"
    },
    // Additional conditions
    {
      "type": "APIRecordCreated",
      "status": "True",
      "reason": "Route53Updated",
      "message": "Created A record for api.my-cluster.example.com",
      "last_transition_time": "2025-10-17T12:04:30Z"
    },
    {
      "type": "AppsWildcardCreated",
      "status": "True",
      "reason": "Route53Updated",
      "message": "Created wildcard record for *.apps.my-cluster.example.com",
      "last_transition_time": "2025-10-17T12:04:45Z"
    }
  ]
}
```

**Aggregation Logic**:
- If any sub-condition is `False`, `Available` should be `False`
- If all sub-conditions are `True`, `Available` should be `True`
- Default to `False` if no other conditions exist

---

## The Data Field (Optional)

The `data` field is a **JSONB object** that adapters can use to send structured information beyond conditions.

### When to Use Data

- Detailed results that don't fit in condition messages
- Structured information for debugging
- Resource identifiers (VPC IDs, IAM role ARNs, etc.)
- Metrics and timing information

### Examples

**Validation Adapter Data**:
```json
{
  "data": {
    "validationResults": {
      "route53": {
        "zoneId": "Z1234567890ABC",
        "zoneName": "example.com",
        "found": true
      },
      "s3": {
        "bucketName": "hyperfleet-clusters",
        "accessible": true,
        "region": "us-east-1"
      },
      "quotas": {
        "vpcLimit": 5,
        "vpcUsed": 2,
        "sufficient": true
      }
    },
    "checksPerformed": 15,
    "checksPassed": 15,
    "checksFailed": 0
  }
}
```

**Control plane Adapter Data**:
```json
{
  "data": {
    "resources": {
      "vpcId": "vpc-123abc456def",
      "subnetIds": ["subnet-111", "subnet-222", "subnet-333"],
      "securityGroupId": "sg-789ghi",
      "natGatewayId": "nat-012jkl"
    },
    "timing": {
      "vpcCreation": "12s",
      "subnetCreation": "8s",
      "totalTime": "45s"
    }
  }
}
```

---

## Cluster and Status Objects

The HyperFleet API provides two endpoints for cluster information:

- **GET** `/v1/clusters/{id}` - Cluster resource with metadata and aggregated status
- **GET** `/v1/clusters/{id}/statuses` - Detailed adapter statuses (ClusterStatus resource)

### Cluster Object Structure (with Aggregated Status)

**GET** `/v1/clusters/{id}`

Returns the complete cluster resource including metadata, spec, and aggregated status:

> **Schema Reference**: See [Cluster schema definition](https://github.com/openshift-hyperfleet/hyperfleet-api-spec/blob/main/schemas/core/openapi.yaml) in the API spec for complete field definitions.

```json
{
  "id": "cls-550e8400",
  "name": "my-cluster",
  "generation": 1,
  "spec": {
    "cloud": "aws",
    "region": "us-east-1",
    "domain": "example.com",
    "networking": {
      "clusterNetwork": "10.128.0.0/14",
      "serviceNetwork": "172.30.0.0/16"
    },
    "hypershift": {
      "version": "4.14.0",
      "releaseImage": "quay.io/openshift-release-dev/ocp-release:4.14.0"
    }
  },
  "metadata": {
    "created_time": "2025-10-17T12:00:00Z",
    "updated_time": "2025-10-17T12:05:00Z",
    "labels": {
      "environment": "production",
      "team": "platform"
    }
  },
  "status": {
    "phase": "Ready",
    "phaseDescription": "All required adapters completed successfully",
    "conditions": [
      {
        "type": "AllAdaptersReady",
        "status": "True",
        "reason": "AllRequiredAdaptersAvailable",
        "message": "All required adapters completed successfully",
        "last_transition_time": "2025-10-17T12:05:00Z"
      },
      {
        "type": "ValidationPassed",
        "status": "True",
        "reason": "AllValidationChecksPassed",
        "message": "Validation adapter completed all checks successfully",
        "last_transition_time": "2025-10-17T12:02:00Z"
      },
      {
        "type": "ControlPlaneReady",
        "status": "True",
        "reason": "AllResourcesProvisioned",
        "message": "Control plane adapter provisioned all required resources",
        "last_transition_time": "2025-10-17T12:04:30Z"
      },
      {
        "type": "DNSConfigured",
        "status": "True",
        "reason": "AllRecordsCreated",
        "message": "DNS adapter created all required records",
        "last_transition_time": "2025-10-17T12:05:00Z"
      }
    ],
    "adapters": [
      {
        "name": "validation",
        "available": "True",
        "observed_generation": 1
      },
      {
        "name": "dns",
        "available": "True",
        "observed_generation": 1
      },
      {
        "name": "controlplane",
        "available": "True",
        "observed_generation": 1
      },
      {
        "name": "nodepool",
        "available": "True",
        "observed_generation": 1
      }
    ],
    "last_updated_time": "2025-10-17T12:05:00Z"
  }
}
```

### Aggregated Status Fields

The `status` field in the cluster object contains the aggregated status computed from all adapter statuses:

| Field | Type | Description |
|-------|------|-------------|
| `phase` | string | Overall cluster state: "Pending", "Provisioning", "Ready", "Failed", or "Degraded" |
| `phaseDescription` | string | Human-readable phase description from configuration |
| `conditions` | array | Cluster-level conditions (generated by expr evaluation) |
| `adapters` | array | Summary of each adapter's status (name, available, observed_generation) |
| `last_updated_time` | timestamp | When the aggregated status was last updated |

### Status Phases

The `phase` field represents the overall cluster state based on adapter statuses.

> **MVP Scope**: For MVP, the system supports **Ready** and **Not Ready** phases only. Additional phases (Pending, Provisioning, Failed, Degraded) are planned for Post-MVP.

#### **Ready** (MVP)
- **When**: All required adapters completed successfully
- **Condition**: All required adapters have `Available: True` for current generation
- **Example**: All adapters finished without errors

```json
{
  "phase": "Ready",
  "conditions": [
    {
      "type": "AllAdaptersReady",
      "status": "True",
      "reason": "AllRequiredAdaptersAvailable",
      "message": "All required adapters completed successfully"
    }
  ]
}
```

#### **Not Ready** (MVP)
- **When**: One or more adapters have not completed successfully
- **Condition**: Any required adapter has `Available: False` or hasn't reported yet
- **Example**: Validation failed, DNS adapter still running, or adapters haven't started

```json
{
  "phase": "Not Ready",
  "conditions": [
    {
      "type": "AllAdaptersReady",
      "status": "False",
      "reason": "RequiredAdaptersNotReady",
      "message": "One or more required adapters not ready"
    }
  ]
}
```

### Phase Calculation Logic (MVP)

For MVP, the phase is determined using simple logic:

```
1. Get list of required adapters (validation, dns, controlplane, nodepool)
2. For each adapter:
   - Check if observed_generation === cluster.generation
   - Check if available === "True"
3. If all adapters are "True" and current → phase: "Ready"
4. Otherwise → phase: "Not Ready"
```

---

### Additional Phases (Post-MVP)

The following phases are planned for Post-MVP releases:

#### **Pending** (Post-MVP)
- **When**: Cluster created but adapters haven't started processing yet
- **Condition**: No adapters have reported status or all are waiting for preconditions
- **Example**: Cluster just created, validation adapter hasn't started

#### **Provisioning** (Post-MVP)
- **When**: One or more adapters are actively working
- **Condition**: At least one adapter has `Applied: True` but `Available: False`
- **Example**: Validation completed, DNS adapter running

#### **Failed** (Post-MVP)
- **When**: One or more required adapters failed (business logic failure)
- **Condition**: Any required adapter has `Available: False` with `Health: True`
- **Example**: Validation failed due to missing DNS zone

#### **Degraded** (Post-MVP)
- **When**: Cluster operational but has health issues
- **Condition**: Any adapter has `Health: False` (unexpected errors)
- **Example**: Control plane completed but monitoring adapter has connection issues

> **Note**: Implementing these additional phases requires careful design of the state machine to avoid complexity. See [Kubernetes discussion on phase deprecation](https://github.com/kubernetes/kubernetes/issues/7856) for context on challenges with complex phase state machines.

**Key Design Decision:** Phase priority is **hardcoded in business logic**, not configurable. This ensures critical states like "Degraded" are never hidden by configuration mistakes, and provides consistent, predictable behavior across all environments.

### Phase Transitions (MVP)

For MVP, phase transitions are simple:

```
Not Ready ←→ Ready
```

A cluster starts as **Not Ready** and transitions to **Ready** when all required adapters complete successfully. It can transition back to **Not Ready** if the cluster generation changes or if adapters report failures.

**Post-MVP**: More complex state transitions (Pending, Provisioning, Failed, Degraded) will be added with careful consideration of state machine complexity.

### Accessing Detailed Status

To see detailed conditions, data, and health information for ALL adapters:

**GET** `/v1/clusters/{clusterId}/statuses`

This returns the complete ClusterStatus object containing all adapter statuses in the `adapter_statuses` array. You can then filter client-side for the specific adapter you need.

Each adapter in the `adapter_statuses` array includes its `observed_generation` field, indicating which cluster generation that adapter has reconciled.

### Check If Adapter Completed

To determine if an adapter has completed successfully:
1. Get the cluster object: `GET /v1/clusters/{clusterId}`
2. Look in `status.adapters` array for the adapter
3. Check `observed_generation === cluster.generation` (not stale)
4. Check `available === "True"`

### Check Adapter Health

To check adapter health, you need the detailed ClusterStatus object:
1. Fetch: `GET /v1/clusters/{clusterId}/statuses?generation={generation}`
2. Find the adapter in the `adapter_statuses` array
3. Find the `Health` condition in that adapter's conditions
4. Check if `status === "True"`

If `Health: False`, examine the `message` and `data` fields for debugging details.

---

## Configuration-driven Aggregation

HyperFleet's status aggregation system uses **rule-based evaluation** to determine cluster phase and conditions from adapter statuses. This section explains how the aggregation engine processes configurations and adapter data.

### Aggregation Engine Architecture

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Detailed      │    │   Aggregation    │    │   Aggregated    │
│   Statuses      │───→│     Engine       │───→│    Status       │
│                 │    │                  │    │                 │
│ /statuses       │    │ • Expr Evaluator │    │ cluster.status  │
│ • Full conditions│   │ • Field Extract  │    │ • phase         │
│ • JSONB data    │    │ • Condition Gen  │    │ • conditions    │
│ • Metadata      │    │ • Phase Calc     │    │ • adapters[]    │
└─────────────────┘    └──────────────────┘    └─────────────────┘
                              ↑
                       ┌──────────────────┐
                       │ AggregationConfig│
                       │ (Custom Resource)│
                       │ • Phase Rules    │
                       │ • Conditions     │
                       │ • Policies       │
                       └──────────────────┘
```

**Data Flow:**
1. **Source**: `GET /v1/clusters/{id}/statuses` - Complete adapter data with all conditions
2. **Processing**: Aggregation engine extracts key fields and applies expr rules
3. **Output**: Aggregated `status` included in `GET /v1/clusters/{id}` response

**Field Mapping:**
```
/statuses                           →    cluster.status
─────────────────────────────────────    ────────────────────────
adapter_statuses[].adapter           →    status.adapters[].name
adapter_statuses[].observed_generation →    status.adapters[].observed_generation
adapter_statuses[].conditions[       →    status.adapters[].available
  type="Available"].status

Config YAML                         →    cluster.status
─────────────────────────────────────    ────────────────────────
phases[phaseName].description       →    status.phaseDescription
```

### Rule Evaluation Process

The aggregation engine follows this process:

#### 1. **Data Collection**
```go
// Collect all adapter statuses for cluster
adapter_statuses := getAdapterStatuses(clusterId, generation)
config := getAggregationConfig(clusterType)
```

#### 2. **Phase Evaluation (Hardcoded Priority)**
```go
// Phase evaluation uses hardcoded priority for robustness
func evaluateClusterPhase(adapter_statuses []AdapterStatus, config AggregationConfig) PhaseResult {
    // 1. DEGRADED - Highest priority (health issues must be visible)
    if evaluatePhaseCondition("degraded", adapter_statuses, config) {
        return PhaseResult{
            Name: "Degraded",
            Description: getPhaseDescription(config, "degraded"),
        }
    }

    // 2. FAILED - Business logic failures
    if evaluatePhaseCondition("failed", adapter_statuses, config) {
        return PhaseResult{
            Name: "Failed",
            Description: getPhaseDescription(config, "failed"),
        }
    }

    // 3. READY - All required adapters completed successfully
    if evaluatePhaseCondition("ready", adapter_statuses, config) {
        return PhaseResult{
            Name: "Ready",
            Description: getPhaseDescription(config, "ready"),
        }
    }

    // 4. PROVISIONING - One or more adapters actively working
    if evaluatePhaseCondition("provisioning", adapter_statuses, config) {
        return PhaseResult{
            Name: "Provisioning",
            Description: getPhaseDescription(config, "provisioning"),
        }
    }

    // 5. PENDING - Initial state (fallback)
    return PhaseResult{
        Name: "Pending",
        Description: getPhaseDescription(config, "pending"),
    }
}

func getPhaseDescription(config AggregationConfig, phaseName string) string {
    for _, phase := range config.Phases {
        if phase.Name == phaseName {
            return phase.Description
        }
    }
    return "" // Fallback if not found
}

// evaluatePhaseCondition evaluates all required conditions for a phase using expr
func evaluatePhaseCondition(phaseName string, adapter_statuses []AdapterStatus, config AggregationConfig) bool {
    phase := config.Phases[phaseName]
    for _, conditionRef := range phase.RequiredConditions {
        condition := findCondition(config.ClusterConditions, conditionRef.Type)
        result := evaluateExprCondition(adapter_statuses, config, condition)

        // Check if result matches expected status
        if (conditionRef.Status == "True" && !result) || (conditionRef.Status == "False" && result) {
            return false
        }
    }
    return true
}
```

**Why Hardcoded Priority is More Robust:**
- **Consistent behavior** across all environments and configurations
- **Prevents misconfiguration** that could hide critical states (e.g., degraded)
- **Business logic enforced** - health issues always visible regardless of config
- **Simpler implementation** - no need for complex priority sorting
- **Predictable outcomes** - phase transitions follow fixed, well-understood rules

#### 3. **Condition Generation**
```go
// Generate cluster conditions based on expr evaluation
for _, conditionRule := range config.ClusterConditions {
    condition := evaluateConditionRule(adapter_statuses, config, conditionRule)
    clusterConditions = append(clusterConditions, condition)
}
```

**Condition Reason/Message Generation:**

The AggregationConfig Custom Resource defines **HOW** to evaluate conditions using expr expressions **AND** provides templates for `reason` and `message`:

```go
func evaluateConditionRule(adapter_statuses []AdapterStatus, config AggregationConfig, rule ConditionRule) Condition {
    // Evaluate the expr expression
    result := evaluateExprCondition(adapter_statuses, config, rule)

    // Get template based on evaluation result
    var template ConditionTemplate
    if result {
        template = rule.Templates.True
    } else {
        template = rule.Templates.False
    }

    return Condition{
        Type:               rule.Type,
        Status:             boolToStatus(result),
        Reason:             template.Reason,   // ← From config template
        Message:            template.Message,  // ← Static message from config
        LastTransitionTime: time.Now(),
    }
}

// evaluateExprCondition evaluates an expr expression
func evaluateExprCondition(adapter_statuses []AdapterStatus, config AggregationConfig, rule ConditionRule) bool {
    // Prepare environment with available data
    env := map[string]interface{}{
        "requiredAdapters":  filterAdapters(adapter_statuses, config.RequiredAdapters),
        "optionalAdapters":  filterAdapters(adapter_statuses, config.OptionalAdapters),
        "allAdapters":       adapter_statuses,
        "adapters":          statusesAsMap(adapter_statuses),
        "currentGeneration": config.CurrentGeneration,
    }

    // Compile and execute expression
    program, err := expr.Compile(rule.Evaluate.Expr, expr.Env(env), expr.AsBool())
    if err != nil {
        // Log error and return false
        log.Error("Failed to compile expression for condition %s: %v", rule.Type, err)
        return false
    }

    result, err := expr.Run(program, env)
    if err != nil {
        // Log error and return false
        log.Error("Failed to execute expression for condition %s: %v", rule.Type, err)
        return false
    }

    return result.(bool)
}

```

**Message Generation:**

The AggregationConfig Custom Resource defines static messages for each condition outcome:

```yaml
apiVersion: hyperfleet.io/v1alpha1
kind: AggregationConfig
metadata:
  name: default-aggregation
  namespace: hyperfleet-system
spec:
  # Example condition with static messages
  clusterConditions:
    - type: "AllAdaptersReady"
      evaluate:
        expr: 'all(requiredAdapters, {.available == "True"})'
      templates:
        true:
          reason: "AllRequiredAdaptersAvailable"
          message: "All required adapters completed successfully"  # ← Static message
        false:
          reason: "RequiredAdaptersNotReady"
          message: "One or more required adapters not ready"      # ← Static message
```

**Example Evaluation:**
```yaml
# Step 1: Evaluate expr expression
expr: 'all(requiredAdapters, {.available == "True"})'
# With requiredAdapters = [
#   {adapter: "validation", available: "False"},
#   {adapter: "dns", available: "False"},
#   {adapter: "controlplane", available: "True"},
#   {adapter: "nodepool", available: "True"}
# ]
# Result: false (not ALL are True)

# Step 2: Select template based on result
# Since result is false, use templates.false

# Step 3: Create condition
{
  "type": "AllAdaptersReady",
  "status": "False",                          # ← From expr result
  "reason": "RequiredAdaptersNotReady",       # ← From template
  "message": "One or more required adapters not ready"  # ← From template
}
```

**Benefits:**

1. **Simple** - No template rendering complexity, just static messages
2. **Fast** - Direct string assignment, no parsing or substitution
3. **Clear** - Messages are exactly as written in configuration
4. **Easy to customize** - Change messages without code changes

**Adding New Conditions - No Code Changes Required:**

To add a new condition like "NodePoolReady", update the AggregationConfig Custom Resource:

```yaml
apiVersion: hyperfleet.io/v1alpha1
kind: AggregationConfig
metadata:
  name: default-aggregation
  namespace: hyperfleet-system
spec:
  clusterConditions:
    # ... existing conditions ...

    # NEW: Add this to config, no source code changes needed!
    - type: "NodePoolReady"
      evaluate:
        expr: 'adapters["nodepool"].available == "True"'
      templates:
        true:
          reason: "ClusterDeployed"
          message: "NodePool cluster deployed and operational"
        false:
          reason: "NodePoolNotReady"
          message: "NodePool cluster not ready"
```

Apply the updated configuration:
```bash
kubectl apply -f aggregation-config.yaml
```

The aggregation service will automatically reload and start evaluating the new condition.

**More Complex Example:**

```yaml
  # NEW: Check NodePool is ready AND healthy with current generation
  - type: "NodePoolFullyReady"
    evaluate:
      expr: 'adapters["nodepool"].available == "True" && adapters["nodepool"].health == "True" && adapters["nodepool"].observed_generation == currentGeneration'
    templates:
      true:
        reason: "ClusterOperational"
        message: "NodePool cluster is fully operational and up-to-date"
      false:
        reason: "NodePoolNotFullyReady"
        message: "NodePool cluster not yet fully operational"
```

**Result:** The aggregation engine automatically:
1. Evaluates the expr expression against current adapter statuses
2. Uses the static reason/message from templates
3. Includes it in cluster conditions array

**No Go code changes required!** The power of expr allows you to express any evaluation logic directly in configuration.

#### 4. **Adapter Status Extraction**
```go
// Extract adapter summaries for cluster.status field from detailed /statuses data
func extractAdapterSummaries(detailedStatus ClusterStatus) []AdapterSummary {
    var adapters []AdapterSummary

    for _, adapterStatus := range detailedStatus.AdapterStatuses {
        // Extract the "Available" condition status
        var availableStatus string = "False" // Default fallback
        for _, condition := range adapterStatus.Conditions {
            if condition.Type == "Available" {
                availableStatus = condition.Status  // "True" or "False"
                break
            }
        }

        // Create adapter summary for cluster.status field
        summary := AdapterSummary{
            Name:                adapterStatus.Adapter,        // Direct copy
            Available:           availableStatus,              // Extracted from Available condition
            ObservedGeneration:  adapterStatus.ObservedGeneration, // Direct copy
        }

        adapters = append(adapters, summary)
    }

    return adapters
}
```

**Field Extraction Rules:**
- **`name`** - Direct copy from `adapterStatus.adapter`
- **`available`** - Extracted from `conditions[type="Available"].status`
- **`observed_generation`** - Direct copy from `adapterStatus.observed_generation`

**Purpose:** The `cluster.status` field provides a **lightweight projection** of the detailed `/statuses` data, extracting only the essential fields needed for:
- Quick phase calculation
- High-level status overview
- Polling and dashboard displays

**Performance Benefits:**
- Avoids parsing full condition arrays for basic status checks
- Enables fast aggregation logic without condition iteration
- Reduces payload size by including only essential adapter summary

**Example Extraction:**

**Step 1: Source Data** - GET `/v1/clusters/{id}/statuses`:
```json
{
  "adapter_statuses": [
    {
      "adapter": "validation",
      "observed_generation": 1,
      "conditions": [
        {"type": "Available", "status": "True", "reason": "JobSucceeded"},
        {"type": "Applied", "status": "True", "reason": "JobLaunched"},
        {"type": "Health", "status": "True", "reason": "NoErrors"}
      ]
    }
  ]
}
```

**Step 2: Aggregation Config** - AggregationConfig Custom Resource:
```yaml
apiVersion: hyperfleet.io/v1alpha1
kind: AggregationConfig
metadata:
  name: default-aggregation
  namespace: hyperfleet-system
spec:
  phases:
    ready:
      description: "All required adapters completed successfully"
```

**Step 3: Result** - `cluster.status` field in GET `/v1/clusters/{id}`:
```json
{
  "phase": "Ready",
  "phaseDescription": "All required adapters completed successfully",
  "adapters": [
    {
      "name": "validation",
      "available": "True",
      "observed_generation": 1
    }
  ]
}
```

**Extraction Logic**:
- `phase` → Calculated from adapter statuses using expr
- `phaseDescription` → From aggregation config
- `adapters[].name` → `adapter`
- `adapters[].available` → `conditions[Available].status`
- `adapters[].observed_generation` → `observed_generation`

### Expression Evaluation with expr-lang

#### Using expr Expressions

HyperFleet uses **[expr-lang/expr](https://expr-lang.org/)** to evaluate conditions. Expr is a powerful, safe expression language with the following guarantees:

- **Memory-safe**: No access to unrelated memory
- **Side-effect-free**: Expressions only compute outputs from inputs (no I/O, network calls)
- **Always terminating**: No infinite loops
- **Type-safe**: Compile-time type checking

#### Available Variables in Expressions

When evaluating expressions, the following variables are available:

| Variable | Type | Description |
|----------|------|-------------|
| `requiredAdapters` | `[]AdapterStatus` | Array of required adapter statuses |
| `optionalAdapters` | `[]AdapterStatus` | Array of optional adapter statuses |
| `allAdapters` | `[]AdapterStatus` | Array of all adapter statuses |
| `adapters` | `map[string]AdapterStatus` | Map of adapter name → status |
| `currentGeneration` | `int` | Current cluster generation |

#### AdapterStatus Fields

Each adapter status object has the following fields accessible in expressions:

```go
type AdapterStatus struct {
    Adapter            string  // Adapter name (e.g., "validation")
    Available          string  // "True" or "False"
    Applied            string  // "True" or "False"
    Health             string  // "True" or "False"
    ObservedGeneration int     // Generation this adapter reconciled
    LastUpdated        time.Time
}
```

#### Common Expression Patterns

**Check all required adapters are ready:**
```yaml
expr: 'all(requiredAdapters, {.available == "True"})'
```

**Check if any adapter is unhealthy:**
```yaml
expr: 'any(allAdapters, {.health == "False"})'
```

**Check specific adapter status:**
```yaml
expr: 'adapters["validation"].available == "True"'
```

**Check multiple conditions:**
```yaml
expr: 'all(requiredAdapters, {.available == "True" && .health == "True"})'
```

**Check with generation:**
```yaml
expr: 'all(requiredAdapters, {.observed_generation == currentGeneration})'
```

**Complex logic:**
```yaml
# At least 3 adapters ready
expr: 'len(filter(requiredAdapters, {.available == "True"})) >= 3'

# Validation ready OR all optional adapters ready
expr: 'adapters["validation"].available == "True" || all(optionalAdapters, {.available == "True"})'

# Check for adapters that are applied but not yet available (provisioning)
expr: 'any(allAdapters, {.applied == "True" && .available == "False"})'
```

#### expr Built-in Functions

Commonly used expr functions:

- **all(array, predicate)** - Returns true if all elements satisfy predicate
- **any(array, predicate)** - Returns true if any element satisfies predicate
- **filter(array, predicate)** - Returns filtered array
- **len(array)** - Returns array length
- **map(array, predicate)** - Returns transformed array

For complete expr documentation, see https://expr-lang.org/docs/language-definition

### Generation Handling

The aggregation engine respects generation constraints to prevent stale data issues. You can check generation in your expressions:

```yaml
# Only count adapters that have reconciled current generation
clusterConditions:
  - type: "AllAdaptersReporting"
    evaluate:
      expr: 'all(requiredAdapters, {.observed_generation == currentGeneration})'

# Check if adapter is current AND ready
  - type: "ValidationPassed"
    evaluate:
      expr: 'adapters["validation"].observed_generation == currentGeneration && adapters["validation"].available == "True"'
```

**Common Generation Checks**:
- `{.observed_generation == currentGeneration}` - Adapter has reconciled current generation
- `{.observed_generation < currentGeneration}` - Adapter is behind (stale)
- `{.observed_generation > currentGeneration}` - Should not happen (error condition)

### Configuration Validation

To ensure configuration correctness, validate all expr expressions during startup or in CI/CD:

```go
// Validate all expressions in configuration
func ValidateAggregationConfig(config AggregationConfig) error {
    // Mock environment for validation
    mockEnv := map[string]interface{}{
        "requiredAdapters":  []AdapterStatus{},
        "optionalAdapters":  []AdapterStatus{},
        "allAdapters":       []AdapterStatus{},
        "adapters":          map[string]AdapterStatus{},
        "currentGeneration": 1,
    }

    for _, condition := range config.ClusterConditions {
        // Compile expression with type checking
        _, err := expr.Compile(
            condition.Evaluate.Expr,
            expr.Env(mockEnv),
            expr.AsBool(), // Ensure expression returns boolean
        )
        if err != nil {
            return fmt.Errorf("invalid expression for condition %s: %w", condition.Type, err)
        }
    }

    return nil
}
```

**CI/CD Integration:**

```go
// tests/config_validation_test.go
func TestAggregationConfigExpressions(t *testing.T) {
    // Load AggregationConfig Custom Resource from Kubernetes
    config := &hyperfleetv1alpha1.AggregationConfig{}
    err := k8sClient.Get(ctx, types.NamespacedName{
        Name:      "default-aggregation",
        Namespace: "hyperfleet-system",
    }, config)
    require.NoError(t, err, "Failed to get AggregationConfig CR")

    err = ValidateAggregationConfig(config.Spec)
    require.NoError(t, err, "Configuration contains invalid expressions")
}
```

### Expression Debugging

When an expression evaluates unexpectedly, use logging to debug:

```go
func evaluateExprCondition(adapter_statuses []AdapterStatus, config AggregationConfig, rule ConditionRule) bool {
    env := prepareEnvironment(adapter_statuses, config)

    program, err := expr.Compile(rule.Evaluate.Expr, expr.Env(env), expr.AsBool())
    if err != nil {
        log.Error("Compile error for condition %s: %v", rule.Type, err)
        log.Error("Expression: %s", rule.Evaluate.Expr)
        return false
    }

    result, err := expr.Run(program, env)
    if err != nil {
        log.Error("Runtime error for condition %s: %v", rule.Type, err)
        log.Error("Expression: %s", rule.Evaluate.Expr)
        log.Debug("Environment: %+v", env)
        return false
    }

    boolResult := result.(bool)

    // Debug logging when condition is false
    if !boolResult {
        log.Debug("Condition %s evaluated to false", rule.Type)
        log.Debug("Expression: %s", rule.Evaluate.Expr)
        log.Debug("Required adapters: %+v", env["requiredAdapters"])
    }

    return boolResult
}
```

**Common Expression Errors:**

| Error | Cause | Solution |
|-------|-------|----------|
| `unknown name "foo"` | Variable not in environment | Check available variables list |
| `invalid operation: string + int` | Type mismatch | Ensure types match in comparisons |
| `cannot use [] on type string` | Invalid array access | Verify variable is array/map |
| `expected bool, got string` | Expression doesn't return boolean | Add comparison (e.g., `== "True"`) |

### Advanced Expression Examples

**Percentage-based checks:**
```yaml
# At least 75% of adapters ready
clusterConditions:
  - type: "MajorityAdaptersReady"
    evaluate:
      expr: 'len(filter(requiredAdapters, {.available == "True"})) >= len(requiredAdapters) * 0.75'
```

**Fallback logic:**
```yaml
# Primary adapter OR backup adapter ready
clusterConditions:
  - type: "ValidationPathReady"
    evaluate:
      expr: 'adapters["validation"].available == "True" || adapters["validation-backup"].available == "True"'
```

**Multi-step validation:**
```yaml
# Validation AND (DNS OR Control plane) ready
clusterConditions:
  - type: "CoreProvisioning"
    evaluate:
      expr: 'adapters["validation"].available == "True" && (adapters["dns"].available == "True" || adapters["controlplane"].available == "True")'
```

**Stale adapter detection:**
```yaml
# Check if any adapter hasn't updated in 10 minutes
clusterConditions:
  - type: "NoStaleAdapters"
    evaluate:
      # Note: This would require adding duration helpers to environment
      expr: 'all(allAdapters, {.observed_generation == currentGeneration})'
```

**Counting specific states:**
```yaml
# Exactly 2 adapters in provisioning state
clusterConditions:
  - type: "TwoAdaptersProvisioning"
    evaluate:
      expr: 'len(filter(allAdapters, {.applied == "True" && .available == "False"})) == 2'
```

### Error Handling and Fallbacks

The aggregation engine handles various error scenarios:

#### Missing Adapter Status
```yaml
# When required adapter hasn't reported yet
defaultBehavior:
  missingAdapter: "pending"    # Default to pending phase
  timeout: "10m"              # Wait timeout before marking failed
```

#### Stale Status Detection
```yaml
policies:
  staleThreshold: "10m"        # Consider status stale after 10 minutes
  staleAction: "degraded"      # Move to degraded if stale
```


---

## Complete Status Lifecycle Examples

The following examples show **individual adapter status payloads** that adapters send. These become entries in the ClusterStatus `adapter_statuses` array.

> **Implementation Note**: Once [PR #18](https://github.com/openshift-hyperfleet/architecture/pull/18) is merged, adapters will generate these payloads using declarative configuration. The `postProcessing.statusEvaluation` section in the adapter config defines how to calculate condition states (Applied, Available, Health) by evaluating resource state, and the `actions` section defines when to POST/PATCH these payloads to the HyperFleet API.

### 1. Adapter Started (Job Created)

**Scenario**: Validation adapter received event, created Job. This is the first adapter to report, so it POSTs to create the ClusterStatus.

**POST** `/v1/clusters/cls-123/statuses`

```json
{
  "generation": 1,
  "adapter_statuses": [
    {
      "adapter": "validation",
      "observed_generation": 1,
      "conditions": [
        {
          "type": "Available",
          "status": "False",
          "reason": "JobRunning",
          "message": "Validation Job is executing",
          "last_transition_time": "2025-10-17T12:00:05Z"
        },
        {
          "type": "Applied",
          "status": "True",
          "reason": "JobLaunched",
          "message": "Kubernetes Job 'validation-cls-123-gen1' created successfully",
          "last_transition_time": "2025-10-17T12:00:05Z"
        },
        {
          "type": "Health",
          "status": "True",
          "reason": "NoErrors",
          "message": "Adapter is healthy",
          "last_transition_time": "2025-10-17T12:00:05Z"
        }
      ],
      "metadata": {
        "job_name": "validation-cls-123-gen1",
        "job_namespace": "hyperfleet-jobs"
      },
      "last_updated_time": "2025-10-17T12:00:05Z"
    }
  ]
}
```

**What This Means**:
- Job created successfully (Applied: True)
- Job is running (Available: False - not yet complete)
- No errors (Health: True)

---

### 2. Adapter Succeeded

**Scenario**: Validation Job completed successfully. Validation adapter POSTs to update its status (API handles upsert).

**POST** `/v1/clusters/cls-123/statuses`

```json
{
  "adapter": "validation",
  "observed_generation": 1,
  "conditions": [
    {
      "type": "Available",
      "status": "True",
      "reason": "JobSucceeded",
      "message": "Job completed successfully after 115 seconds",
      "last_transition_time": "2025-10-17T12:02:00Z"
    },
    {
      "type": "Applied",
      "status": "True",
      "reason": "JobLaunched",
      "message": "Kubernetes Job created successfully",
      "last_transition_time": "2025-10-17T12:00:05Z"
    },
    {
      "type": "Health",
      "status": "True",
      "reason": "AllChecksPassed",
      "message": "All validation checks passed",
      "last_transition_time": "2025-10-17T12:02:00Z"
    }
  ],
  "data": {
    "validationResults": {
      "route53ZoneFound": true,
      "s3BucketAccessible": true,
      "quotaSufficient": true,
      "iamPermissionsValid": true
    },
    "checksPerformed": 15,
    "checksPassed": 15,
    "executionTime": "115s"
  },
  "metadata": {
    "job_name": "validation-cls-123-gen1",
    "completedAt": "2025-10-17T12:02:00Z"
  },
  "last_updated_time": "2025-10-17T12:02:00Z"
}
```

**What This Means**:
- Job created (Applied: True)
- Job succeeded (Available: True)
- No errors (Health: True)
- Detailed results in `data` field

**Next Steps**: DNS adapter can now proceed (validation complete)

---

### 3. Adapter Failed (Business Logic)

**Scenario**: Validation Job ran but found missing Route53 zone

**POST** `/v1/clusters/cls-123/statuses`

```json
{
  "adapter": "validation",
  "observed_generation": 1,
  "conditions": [
    {
      "type": "Available",
      "status": "False",
      "reason": "ValidationFailed",
      "message": "Route53 zone not found for domain example.com. Create a public hosted zone before provisioning cluster.",
      "last_transition_time": "2025-10-17T12:02:00Z"
    },
    {
      "type": "Applied",
      "status": "True",
      "reason": "JobLaunched",
      "message": "Kubernetes Job created successfully",
      "last_transition_time": "2025-10-17T12:00:05Z"
    },
    {
      "type": "Health",
      "status": "True",
      "reason": "NoErrors",
      "message": "Adapter executed normally (validation logic failed, not adapter error)",
      "last_transition_time": "2025-10-17T12:02:00Z"
    }
  ],
  "data": {
    "validationResults": {
      "route53ZoneFound": false,
      "s3BucketAccessible": true,
      "quotaSufficient": true
    },
    "checksPerformed": 15,
    "checksPassed": 14,
    "checksFailed": 1,
    "failedChecks": ["route53_zone"]
  },
  "last_updated_time": "2025-10-17T12:02:00Z"
}
```

**What This Means**:
- Job created (Applied: True)
- Validation failed (Available: False)
- Adapter is healthy (Health: True) - **validation failure is expected behavior**

**Key Point**: `Health: True` because the adapter worked correctly. The validation *logic* failed (missing DNS zone), but the adapter itself had no errors.

---

### 4. Adapter Failed (Unexpected Error)

**Scenario**: Adapter couldn't create Job due to quota exceeded.

**POST** `/v1/clusters/cls-123/statuses`

```json
{
  "adapter": "validation",
  "observed_generation": 1,
  "conditions": [
    {
      "type": "Available",
      "status": "False",
      "reason": "ResourceCreationFailed",
      "message": "Failed to create validation Job",
      "last_transition_time": "2025-10-17T12:00:05Z"
    },
    {
      "type": "Applied",
      "status": "False",
      "reason": "ResourceQuotaExceeded",
      "message": "Failed to create Job: namespace resource quota exceeded (cpu limit reached)",
      "last_transition_time": "2025-10-17T12:00:05Z"
    },
    {
      "type": "Health",
      "status": "False",
      "reason": "UnexpectedError",
      "message": "Adapter could not complete due to resource quota limits",
      "last_transition_time": "2025-10-17T12:00:05Z"
    }
  ],
  "data": {
    "error": {
      "type": "ResourceQuotaExceeded",
      "message": "CPU limit reached",
      "namespace": "hyperfleet-jobs"
    }
  },
  "last_updated_time": "2025-10-17T12:00:05Z"
}
```

**What This Means**:
- Job NOT created (Applied: False)
- Work incomplete (Available: False)
- Adapter unhealthy (Health: False) - **unexpected error prevented normal operation**

**Key Point**: `Health: False` because this is an unexpected controlplane issue, not expected business logic.

---

### Complete ClusterStatus Example

Here's what a complete ClusterStatus object looks like with multiple adapters at different stages:

**GET** `/v1/clusters/cls-550e8400/statuses?generation=1`

```json
{
  "id": "status-cls-550e8400-gen1",
  "type": "clusterStatus",
  "href": "/api/hyperfleet/v1/clusters/cls-550e8400/statuses/status-cls-550e8400-gen1",
  "cluster_id": "cls-550e8400",
  "generation": 1,
  "adapter_statuses": [
    {
      "adapter": "validation",
      "observed_generation": 1,
      "conditions": [
        {
          "type": "Available",
          "status": "True",
          "reason": "JobSucceeded",
          "message": "Job completed successfully after 115 seconds",
          "last_transition_time": "2025-10-17T12:02:00Z"
        },
        {
          "type": "Applied",
          "status": "True",
          "reason": "JobLaunched",
          "message": "Kubernetes Job created successfully",
          "last_transition_time": "2025-10-17T12:00:05Z"
        },
        {
          "type": "Health",
          "status": "True",
          "reason": "AllChecksPassed",
          "message": "All validation checks passed",
          "last_transition_time": "2025-10-17T12:02:00Z"
        }
      ],
      "data": {
        "validationResults": {
          "route53ZoneFound": true,
          "s3BucketAccessible": true,
          "quotaSufficient": true
        }
      },
      "metadata": {
        "job_name": "validation-cls-123-gen1"
      },
      "last_updated_time": "2025-10-17T12:02:00Z"
    },
    {
      "adapter": "dns",
      "observed_generation": 1,
      "conditions": [
        {
          "type": "Available",
          "status": "False",
          "reason": "JobRunning",
          "message": "DNS Job is executing",
          "last_transition_time": "2025-10-17T12:03:00Z"
        },
        {
          "type": "Applied",
          "status": "True",
          "reason": "JobLaunched",
          "message": "DNS Job created successfully",
          "last_transition_time": "2025-10-17T12:03:00Z"
        },
        {
          "type": "Health",
          "status": "True",
          "reason": "NoErrors",
          "message": "DNS adapter is healthy",
          "last_transition_time": "2025-10-17T12:03:00Z"
        }
      ],
      "metadata": {
        "job_name": "dns-cls-123-gen1"
      },
      "last_updated_time": "2025-10-17T12:03:00Z"
    },
    {
      "adapter": "controlplane",
      "observed_generation": 1,
      "conditions": [
        {
          "type": "Available",
          "status": "False",
          "reason": "NotStarted",
          "message": "Waiting for dns to complete",
          "last_transition_time": "2025-10-17T12:00:00Z"
        },
        {
          "type": "Applied",
          "status": "False",
          "reason": "PreconditionsNotMet",
          "message": "Waiting for dns adapter",
          "last_transition_time": "2025-10-17T12:00:00Z"
        },
        {
          "type": "Health",
          "status": "True",
          "reason": "NoErrors",
          "message": "Adapter is healthy",
          "last_transition_time": "2025-10-17T12:00:00Z"
        }
      ],
      "last_updated_time": "2025-10-17T12:00:00Z"
    }
  ],
  "last_updated_time": "2025-10-17T12:03:00Z"
}
```

**What This Shows**:
- **validation**: Completed successfully
- **dns**: Currently running
- **controlplane**: Waiting for preconditions (dns completion)
- All adapter statuses in ONE cohesive ClusterStatus object
- Easy to fetch and display complete cluster provisioning status

---

## Complete Cluster Scenarios with Phase Transitions

This section demonstrates how cluster phases and conditions evolve throughout the complete lifecycle, showing the interplay between adapter statuses and cluster aggregation.

### Scenario 1: Successful Cluster Provisioning

#### Stage 1: Initial State (Pending)

**Cluster State**: Just created, no adapters have started yet.

**GET** `/v1/clusters/cls-123`

```json
{
  "id": "cls-123",
  "name": "my-cluster",
  "generation": 1,
  "spec": {
    "cloud": "aws",
    "region": "us-east-1"
  },
  "metadata": {
    "created_time": "2025-10-17T12:00:00Z"
  },
  "status": {
    "phase": "Pending",
    "phaseDescription": "Waiting for adapters to start processing",
    "conditions": [
      {
        "type": "AllAdaptersReporting",
        "status": "False",
        "reason": "AdaptersNotStarted",
        "message": "Waiting for adapters to begin processing cluster request",
        "last_transition_time": "2025-10-17T12:00:00Z"
      }
    ],
    "adapters": [],
    "last_updated_time": "2025-10-17T12:00:00Z"
  }
}
```

#### Stage 2: Validation Started (Provisioning)

**Cluster State**: Validation adapter started working.

**GET** `/v1/clusters/cls-123`

```json
{
  "id": "cls-123",
  "name": "my-cluster",
  "generation": 1,
  "spec": {
    "cloud": "aws",
    "region": "us-east-1"
  },
  "metadata": {
    "created_time": "2025-10-17T12:00:00Z"
  },
  "status": {
    "phase": "Provisioning",
    "conditions": [
      {
        "type": "ProvisioningInProgress",
        "status": "True",
        "reason": "AdaptersWorking",
        "message": "Adapters actively provisioning resources",
        "last_transition_time": "2025-10-17T12:00:05Z"
      },
      {
        "type": "ValidationPassed",
        "status": "False",
        "reason": "ValidationInProgress",
        "message": "Validation adapter is currently running checks",
        "last_transition_time": "2025-10-17T12:00:05Z"
      }
    ],
    "adapters": [
      {
        "name": "validation",
        "available": "False",
        "observed_generation": 1
      }
    ],
    "last_updated_time": "2025-10-17T12:00:05Z"
  }
}
```

#### Stage 3: Validation Complete, DNS Started (Provisioning)

**Cluster State**: Validation succeeded, DNS adapter now working.

**GET** `/v1/clusters/cls-123`

```json
{
  "id": "cls-123",
  "name": "my-cluster",
  "generation": 1,
  "spec": {
    "cloud": "aws",
    "region": "us-east-1"
  },
  "metadata": {
    "created_time": "2025-10-17T12:00:00Z"
  },
  "status": {
    "phase": "Provisioning",
    "conditions": [
      {
        "type": "ProvisioningInProgress",
        "status": "True",
        "reason": "AdaptersWorking",
        "message": "Adapters actively provisioning resources",
        "last_transition_time": "2025-10-17T12:03:00Z"
      },
      {
        "type": "ValidationPassed",
        "status": "True",
        "reason": "AllValidationChecksPassed",
        "message": "Validation adapter completed all checks successfully",
        "last_transition_time": "2025-10-17T12:02:00Z"
      },
      {
        "type": "DNSConfigured",
        "status": "False",
        "reason": "DNSProvisioningInProgress",
        "message": "DNS adapter is creating Route53 records",
        "last_transition_time": "2025-10-17T12:03:00Z"
      }
    ],
    "adapters": [
      {
        "name": "validation",
        "available": "True",
        "observed_generation": 1
      },
      {
        "name": "dns",
        "available": "False",
        "observed_generation": 1
      }
    ],
    "last_updated_time": "2025-10-17T12:03:00Z"
  }
}
```

#### Stage 4: All Adapters Complete (Ready)

**Cluster State**: All required adapters completed successfully.

**GET** `/v1/clusters/cls-123`

```json
{
  "id": "cls-123",
  "name": "my-cluster",
  "generation": 1,
  "spec": {
    "cloud": "aws",
    "region": "us-east-1"
  },
  "metadata": {
    "created_time": "2025-10-17T12:00:00Z"
  },
  "status": {
    "phase": "Ready",
    "phaseDescription": "All required adapters completed successfully",
    "conditions": [
      {
        "type": "AllAdaptersReady",
        "status": "True",
        "reason": "AllRequiredAdaptersAvailable",
        "message": "All required adapters completed successfully",
        "last_transition_time": "2025-10-17T12:15:00Z"
      },
      {
        "type": "ValidationPassed",
        "status": "True",
        "reason": "AllValidationChecksPassed",
        "message": "Validation adapter completed all checks successfully",
        "last_transition_time": "2025-10-17T12:02:00Z"
      },
      {
        "type": "DNSConfigured",
        "status": "True",
        "reason": "AllRecordsCreated",
        "message": "DNS adapter created all required records",
        "last_transition_time": "2025-10-17T12:05:00Z"
      },
      {
        "type": "ControlPlaneReady",
        "status": "True",
        "reason": "AllResourcesProvisioned",
        "message": "Control plane adapter provisioned all required resources",
        "last_transition_time": "2025-10-17T12:10:00Z"
      },
      {
        "type": "NodePoolReady",
        "status": "True",
        "reason": "ClusterDeployed",
        "message": "NodePool cluster deployed and operational",
        "last_transition_time": "2025-10-17T12:15:00Z"
      }
    ],
    "adapters": [
      {
        "name": "validation",
        "available": "True",
        "observed_generation": 1
      },
      {
        "name": "dns",
        "available": "True",
        "observed_generation": 1
      },
      {
        "name": "controlplane",
        "available": "True",
        "observed_generation": 1
      },
      {
        "name": "nodepool",
        "available": "True",
        "observed_generation": 1
      }
    ],
    "last_updated_time": "2025-10-17T12:15:00Z"
  }
}
```

### Scenario 2: Cluster Provisioning with Failure

#### Stage 1: Validation Failure (Failed)

**Cluster State**: Validation adapter failed due to missing DNS zone.

**GET** `/v1/clusters/cls-456`

```json
{
  "id": "cls-456",
  "name": "failed-cluster",
  "generation": 1,
  "spec": {
    "cloud": "aws",
    "region": "us-east-1",
    "domain": "example.com"
  },
  "metadata": {
    "created_time": "2025-10-17T12:00:00Z"
  },
  "status": {
    "phase": "Failed",
    "conditions": [
      {
        "type": "AdaptersFailed",
        "status": "True",
        "reason": "RequiredAdapterFailure",
        "message": "Validation failed: Route53 zone not found for domain example.com",
        "last_transition_time": "2025-10-17T12:02:00Z"
      },
      {
        "type": "ValidationPassed",
        "status": "False",
        "reason": "ValidationFailed",
        "message": "Route53 zone not found for domain example.com. Create a public hosted zone before provisioning cluster.",
        "last_transition_time": "2025-10-17T12:02:00Z"
      }
    ],
    "adapters": [
      {
        "name": "validation",
        "available": "False",
        "observed_generation": 1
      }
    ],
    "last_updated_time": "2025-10-17T12:02:00Z"
  }
}
```

#### Stage 2: After Manual Fix - Retry (Provisioning)

**Cluster State**: User created DNS zone, cluster spec updated to generation 2, validation restarted.

**GET** `/v1/clusters/cls-456`

```json
{
  "id": "cls-456",
  "name": "failed-cluster",
  "generation": 2,
  "spec": {
    "cloud": "aws",
    "region": "us-east-1",
    "domain": "example.com"
  },
  "metadata": {
    "created_time": "2025-10-17T12:00:00Z",
    "updated_time": "2025-10-17T13:00:00Z"
  },
  "status": {
    "phase": "Provisioning",
    "conditions": [
      {
        "type": "ProvisioningInProgress",
        "status": "True",
        "reason": "AdaptersWorking",
        "message": "Adapters actively provisioning resources",
        "last_transition_time": "2025-10-17T13:00:05Z"
      },
      {
        "type": "ValidationPassed",
        "status": "False",
        "reason": "ValidationInProgress",
        "message": "Validation adapter is currently running checks",
        "last_transition_time": "2025-10-17T13:00:05Z"
      }
    ],
    "adapters": [
      {
        "name": "validation",
        "available": "False",
        "observed_generation": 2
      }
    ],
    "last_updated_time": "2025-10-17T13:00:05Z"
  }
}
```

### Scenario 3: Cluster with Health Issues (Degraded)

#### Stage 1: Operational but Unhealthy (Degraded)

**Cluster State**: All adapters completed but monitoring adapter has health issues.

**GET** `/v1/clusters/cls-789`

```json
{
  "id": "cls-789",
  "name": "degraded-cluster",
  "generation": 1,
  "spec": {
    "cloud": "aws",
    "region": "us-west-2"
  },
  "metadata": {
    "created_time": "2025-10-17T12:00:00Z"
  },
  "status": {
    "phase": "Degraded",
    "conditions": [
      {
        "type": "AdaptersUnhealthy",
        "status": "True",
        "reason": "HealthCheckFailures",
        "message": "Monitoring adapter experiencing API connection failures",
        "last_transition_time": "2025-10-17T12:20:00Z"
      },
      {
        "type": "AllAdaptersReady",
        "status": "True",
        "reason": "AllRequiredAdaptersAvailable",
        "message": "All required adapters completed successfully",
        "last_transition_time": "2025-10-17T12:15:00Z"
      },
      {
        "type": "ValidationPassed",
        "status": "True",
        "reason": "AllValidationChecksPassed",
        "message": "Validation adapter completed successfully",
        "last_transition_time": "2025-10-17T12:02:00Z"
      },
      {
        "type": "MonitoringConfigured",
        "status": "False",
        "reason": "HealthCheckFailures",
        "message": "Monitoring adapter experiencing connectivity issues",
        "last_transition_time": "2025-10-17T12:20:00Z"
      }
    ],
    "adapters": [
      {
        "name": "validation",
        "available": "True",
        "observed_generation": 1
      },
      {
        "name": "dns",
        "available": "True",
        "observed_generation": 1
      },
      {
        "name": "controlplane",
        "available": "True",
        "observed_generation": 1
      },
      {
        "name": "nodepool",
        "available": "True",
        "observed_generation": 1
      },
      {
        "name": "monitoring",
        "available": "True",
        "observed_generation": 1
      }
    ],
    "last_updated_time": "2025-10-17T12:20:00Z"
  }
}
```

### Condition Generation Examples

These examples show how specific cluster conditions are generated based on adapter statuses:

#### AllAdaptersReady Condition
```yaml
# Generated when all required adapters have Available: True
{
  "type": "AllAdaptersReady",
  "status": "True",
  "reason": "AllRequiredAdaptersAvailable",
  "message": "All required adapters completed successfully",
  "last_transition_time": "2025-10-17T12:15:00Z"
}
```

#### ValidationPassed Condition
```yaml
# Generated based on validation adapter status
{
  "type": "ValidationPassed",
  "status": "True",
  "reason": "AllValidationChecksPassed",
  "message": "Validation adapter completed all checks successfully",
  "last_transition_time": "2025-10-17T12:02:00Z"
}
```

#### ProvisioningInProgress Condition
```yaml
# Generated when adapters are actively working
{
  "type": "ProvisioningInProgress",
  "status": "True",
  "reason": "AdaptersWorking",
  "message": "Adapters actively provisioning resources",
  "last_transition_time": "2025-10-17T12:03:00Z"
}
```

---

## Common Status Query Patterns

### 1. Wait for Specific Adapter

To poll until an adapter completes:
1. Fetch the cluster repeatedly (e.g., every 5 seconds): `GET /v1/clusters/{clusterId}`
2. Find the adapter in `status.adapters` array
3. Check if adapter exists (has reported at least once)
4. Verify `observed_generation === cluster.generation` (not stale)
5. Check `available` field:
   - `"True"` → adapter succeeded, stop polling
   - `"False"` → adapter failed or in progress
6. If `"False"`, fetch detailed status to check reason:
   - `GET /v1/clusters/{clusterId}/statuses?generation={generation}`
   - Find the adapter in `adapter_statuses` array
   - Check `Available` condition's `reason`:
     - `JobRunning` or `JobPending` → still in progress, continue polling
     - Other reasons → adapter actually failed, stop polling
7. Implement timeout (e.g., 10 minutes)

### 2. Check If Cluster is Ready

To verify cluster is fully provisioned:
1. Fetch cluster: `GET /v1/clusters/{clusterId}`
2. Check the `Ready` condition in `status.conditions`:
   - `status.conditions.Ready === "True"` — cluster is ready
3. Optionally verify each adapter in `status.adapters`:
   - All have `observed_generation === cluster.generation`
   - All have `available === "True"`

### 3. Get Failed Adapters

To identify which adapters have failed:
1. Fetch cluster: `GET /v1/clusters/{clusterId}`
2. Iterate through `status.adapters`
3. For each adapter:
   - If `observed_generation < cluster.generation` → stale, skip
   - If `available === "False"`, collect adapter name
4. Fetch detailed status for all adapters:
   - `GET /v1/clusters/{clusterId}/statuses?generation={generation}`
5. For each failed adapter (from step 3), find it in `adapter_statuses` array:
   - Get `Available` condition's `message` and `reason`
   - Get `Health` condition to determine if it's a health issue
6. Return list with failure details

### 4. Display Adapter Progress

To show progress UI:
1. Fetch cluster: `GET /v1/clusters/{clusterId}`
2. For each adapter in `status.adapters`:
   - `available: "True"` → Completed
   - `available: "False"` → Need to check details
3. Fetch detailed status: `GET /v1/clusters/{clusterId}/statuses?generation={generation}`
4. For adapters with `available: "False"`:
   - Find adapter in `adapter_statuses` array
   - Check conditions:
     - `Health: False` → Unhealthy
     - `Available: False` with `JobRunning` reason → Running
     - `Available: False` with failure reason → Failed
     - `Applied: False` → Pending
5. Display adapter name, status icon, generation, and message from conditions

**Example Output**:
```
validation - completed (gen 1)
   Job completed successfully after 115 seconds
dns - completed (gen 1)
   Created 5 DNS records
controlplane - running (gen 1)
   Kubernetes Job created successfully
nodepool - pending (gen 0)
   Not started
```

---

## Condition Reference

### Required Conditions (All Adapters)

| Type | True | False |
|------|------|-------|
| `Available` | Work completed successfully | Work failed, incomplete, or still in progress |
| `Applied` | Resources created successfully | Failed to create resources or not yet attempted |
| `Health` | No unexpected errors | Unexpected error occurred |

### Common Reason Values

**Available**:
- `JobSucceeded` - Job completed successfully
- `JobFailed` - Job failed
- `JobRunning` - Job still executing
- `ValidationPassed` - Validation checks passed
- `ValidationFailed` - Validation checks failed

**Applied**:
- `JobLaunched` - Job created successfully
- `ResourceCreationFailed` - Failed to create resource
- `ResourceQuotaExceeded` - Quota limit reached

**Health**:
- `NoErrors` - Adapter is healthy
- `AllChecksPassed` - All health checks passed
- `UnexpectedError` - Unexpected error occurred
- `ResourceNotFound` - Expected resource not found
- `APIConnectionFailed` - Failed to connect to API

---

## Best Practices

### DO

1. **Always include all three required conditions**
   ```json
   {
     "conditions": [
       {"type": "Available", "status": "True", /* ... */},
       {"type": "Applied", "status": "True", /* ... */},
       {"type": "Health", "status": "True", /* ... */}
     ]
   }
   ```

2. **Use positive condition types**
   - `DNSRecordsCreated` (status: True/False)
   - `DNSRecordsFailed` (confusing)

3. **Aggregate conditions to determine Available**
   - If any sub-condition is `False`, set `Available` to `False`
   - If all sub-conditions are `True`, set `Available` to `True`

4. **Provide actionable messages**
   ```json
   {
     "message": "Route53 zone not found for domain example.com. Create a public hosted zone before provisioning cluster."
   }
   ```

5. **Use data field for structured information**
   ```json
   {
     "data": {
       "validationResults": { /* detailed results */ }
     }
   }
   ```

### DON'T

1. **Don't omit required conditions**
   ```json
   // BAD: Missing Health condition
   {
     "conditions": [
       {"type": "Available", /* ... */},
       {"type": "Applied", /* ... */}
     ]
   }
   ```

2. **Don't use negative condition names**
   ```json
   // BAD
   {"type": "ValidationFailed", "status": "True"}

   // GOOD
   {"type": "ValidationComplete", "status": "False"}
   ```

3. **Don't set Health: False for business logic failures**
   ```json
   // BAD: Validation failure is expected behavior
   {
     "type": "Health",
     "status": "False",
     "reason": "ValidationFailed"
   }

   // GOOD: Health is about adapter health, not business logic
   {
     "type": "Health",
     "status": "True",
     "reason": "NoErrors"
   }
   ```

---

## Adapter Configuration System (PR #18)

> **Note**: This section provides a preview of the Adapter Configuration Framework from [PR #18](https://github.com/openshift-hyperfleet/architecture/pull/18). Once merged, this document will be updated with complete implementation details and additional examples.

The Adapter Configuration System provides a **declarative YAML-based framework** for building adapters without writing code. Adapters are defined through configuration files that specify the complete adapter lifecycle: event handling, resource management, and status reporting.

### Overview

The configuration system introduces:

1. **Adapter Configuration Template** - Defines adapter behavior through YAML
2. **Message Broker Abstraction** - Broker-agnostic configuration via ConfigMaps
3. **Declarative Status Evaluation** - Rules-based condition calculation
4. **Automated API Integration** - Automatic status reporting to HyperFleet API

### Key Components

#### 1. Event Handling

Adapters extract parameters from CloudEvents and check preconditions before executing:

```yaml
eventHandlers:
  - eventType: "cluster.created"
    parameters:
      - name: "clusterId"
        source: "event.clusterId"
        required: true
      - name: "generation"
        source: "event.generation"
        required: true

    preconditions:
      - type: "api_call"
        method: "GET"
        endpoint: "{{.hyperfleetApi}}/api/{{.version}}/clusters/{{.clusterId}}"
        storeResponseAs: "clusterDetails"
```

#### 2. Resource Management

Adapters create and track Kubernetes resources (Jobs, Deployments, etc.):

```yaml
resources:
  - apiVersion: "batch/v1"
    kind: "Job"
    metadata:
      name: "validation-{{.clusterId}}-gen{{.generation}}"
      labels:
        hyperfleet.io/cluster-id: "{{.clusterId}}"
        hyperfleet.io/generation: "{{.generation}}"
    spec:
      template:
        spec:
          containers:
            - name: validator
              image: "quay.io/hyperfleet/validator:{{.adapterVersion}}"
```

#### 3. Status Evaluation

Declarative rules determine condition states by evaluating resource status:

```yaml
postProcessing:
  statusEvaluation:
    # Applied: Was the resource created?
    applied:
      status:
        allOf:
          - field: "resources.validationJob.metadata.creationTimestamp"
            operator: "exists"
      templates:
        true:
          reason: "JobLaunched"
          message: "Validation Job created successfully"
        false:
          reason: "JobCreationFailed"
          message: "Failed to create validation Job"

    # Available: Did the work complete successfully?
    available:
      status:
        allOf:
          - field: "resources.validationJob.status.succeeded"
            operator: "eq"
            value: 1
      templates:
        true:
          reason: "JobSucceeded"
          message: "Validation completed successfully"
        false:
          reason: "JobFailed"
          message: "Validation Job failed"

    # Health: Any unexpected errors?
    health:
      status:
        allOf:
          - field: "resources.validationJob.status.failed"
            operator: "eq"
            value: 0
      templates:
        true:
          reason: "NoErrors"
          message: "Adapter is healthy"
        false:
          reason: "UnexpectedError"
          message: "Unexpected errors occurred"
```

#### 4. Status Reporting

Automated API calls to report status using the contract defined in this document:

```yaml
actions:
  - type: "api_call"
    method: "PATCH"
    endpoint: "{{.hyperfleetApi}}/api/{{.version}}/clusters/{{.clusterId}}/statuses"
    body: "{{.clusterStatusPayload}}"
```

The `clusterStatusPayload` is automatically constructed from the status evaluation results, following the adapter status contract.

### Message Broker Configuration

The broker configuration is separate from adapter configuration, provided via ConfigMaps:

```yaml
# broker-configmap-template.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: hyperfleet-message-broker-config
  namespace: hyperfleet-system
data:
  BROKER_TYPE: "pubsub"  # or "awsSns", "rabbitmq"
  BROKER_PROJECT_ID: "my-gcp-project"
  BROKER_SUBSCRIPTION_QUEUE: "validation-adapter-sub"
```

This broker-agnostic approach allows the same adapter configuration to work with:
- Google Cloud Pub/Sub
- AWS SNS/SQS
- RabbitMQ
- Other message brokers

### Benefits

The configuration-driven approach provides:

1. **No Code Changes** - New adapters created by writing YAML configuration
2. **Consistent Behavior** - All adapters follow the same lifecycle
3. **Testable** - Configuration can be validated without deployment
4. **Maintainable** - Changes to adapter logic done through configuration updates
5. **Contract Compliance** - Framework ensures adapters follow the status contract

### Integration with Status Contract

The adapter configuration system implements the status contract defined in this document:

- **Three Required Conditions** - `applied`, `available`, `health` are explicit sections in `statusEvaluation`
- **Simple POST Pattern** - Framework automatically POSTs status reports (API handles upsert)
- **observed_generation** - Automatically included in status payloads from event parameters
- **Condition Structure** - Templates generate proper `type`, `status`, `reason`, `message` fields
- **Data Field** - Custom data can be included via configuration templates

### Example: Complete Validation Adapter Config

For a complete example of an adapter configuration that implements this status contract, see [PR #18 - adapter-config-template.yaml](https://github.com/openshift-hyperfleet/architecture/pull/18/files).

---

## Summary

### Architecture Overview

**ClusterStatus Object** (detailed, verbose):
- ONE ClusterStatus per cluster containing all adapter statuses
- Adapters always POST: `POST /v1/clusters/{clusterId}/statuses` with `adapter` field in payload
- API handles upsert internally: INSERT on first report, UPDATE on subsequent reports
- Contains `adapter_statuses` array with full conditions, data, and metadata for each adapter
- Retrieved via `GET /v1/clusters/{clusterId}/statuses` (optional - for querying)
- **RESTful design**: Single resource represents complete cluster status

**Cluster Object** (complete resource):
- Contains `id`, `name`, `generation`, `spec`, and `metadata`
- Contains `status` field with aggregated status:
  - `phase`: "Pending", "Provisioning", "Ready", "Failed", or "Degraded"
  - `phaseDescription`: Human-readable description from configuration
  - `conditions`: Array of cluster-level conditions (AllAdaptersReady, etc.)
  - `adapters`: Array of `{name, available, observed_generation}`
- Phase calculated by aggregating all adapter `available` conditions using hardcoded priority and expr evaluation
- Retrieved via `GET /v1/clusters/{clusterId}`

### Timestamp Fields Explained

Understanding when and how timestamps are set is critical for Sentinel's max age calculation:

| Field | Set By | Purpose | Calculation |
|-------|--------|---------|-------------|
| `adapters[].last_updated_time` | **Adapter** | When this adapter last checked the resource | Set to `now()` in adapter status report payload |
| `cluster.status.last_updated_time` | **API** | Confidence level of cluster status | `min(adapters[].last_updated_time)` - uses OLDEST adapter timestamp |
| `conditions[].last_transition_time` | **Adapter** | When a condition changed its value | Set by adapter when condition status changes |
| `cluster.status.last_transition_time` | **API** | When cluster phase changed | Updated when aggregated phase changes (post-MVP) |

**Why use `min(adapters[].last_updated_time)` for cluster status?**

Example scenario:
```
status:
  adapters:
    validation:
      available: true
      last_updated_time: 10:00
    dns:
      available: true
      last_updated_time: 10:10
```

**Question**: "What is the cluster phase and how confident are you?"

**Answer**: "With data from 10:00 (not 10:10), the cluster is Ready"

**Why?**: The validation adapter might be stuck and hasn't reported since 10:00. We need to trigger reconciliation based on the oldest adapter's timestamp to detect stale adapters.

If one adapter is stuck but others keep updating, using `max()` or `now()` would hide the problem. Using `min()` ensures Sentinel triggers events when ANY adapter hasn't reported recently.

### The Contract

1. **Three required conditions**: Available, Applied, Health (in each adapter status)
2. **Single ClusterStatus object**: All adapter statuses grouped in `adapter_statuses` array
3. **Optional data field**: JSONB for structured information per adapter
4. **Additional conditions allowed**: All must be positive assertions
5. **Adapter aggregates**: All condition statuses determine Available
6. **Cluster aggregates**: All adapter Available conditions determine phase

### Condition Meanings

- **Available**: Did the work succeed? (True = complete, False = failed/incomplete/in-progress)
- **Applied**: Were resources created? (True = created, False = failed/not-attempted)
- **Health**: Any unexpected errors? (True = healthy, False = unexpected error)

### Key Principles

1. **Two-tier status model** - Aggregated status in cluster object for quick access, detailed adapter statuses in ClusterStatus resource
2. **RESTful design** - ONE ClusterStatus object per cluster with all adapter statuses
3. **expr-based evaluation** - Flexible condition evaluation using expr-lang without code changes
4. **Conditions are the contract** - Required by API (Available, Applied, Health)
5. **Positive assertions** - All condition types should be positive
6. **Aggregation logic** - Available reflects all sub-conditions
7. **Hardcoded phase priority** - Phase evaluation uses fixed business logic, not configurable rules
8. **Health vs Business Logic** - Health is about adapter errors, not validation failures
9. **Structured data** - Use `data` field for details beyond conditions
10. **Phase simplicity (MVP)** - Two phases for MVP: Ready/Not Ready. Additional phases (Pending, Provisioning, Failed, Degraded) planned for Post-MVP

---
