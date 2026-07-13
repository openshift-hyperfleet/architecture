---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-07-13
---

# HyperFleet Cluster Status JSON Guide

## Table of Contents

- [Overview](#overview)
- [API Specification Reference](#api-specification-reference)
- [REST API Summary](#rest-api-summary)
  - [Resource Hierarchy](#resource-hierarchy)
  - [Endpoints](#endpoints)
  - [Adapter Status Reporting Flow](#adapter-status-reporting-flow)
  - [Adapter Implementation Pattern](#adapter-implementation-pattern)
- [The Adapter Status Contract](#the-adapter-status-contract)
  - [Reporting Status: Always PUT](#reporting-status-always-put)
  - [CRITICAL: Always Update `observed_time`](#critical-always-update-observed_time)
  - [Implementation via Adapter Configuration (PR #18)](#implementation-via-adapter-configuration-pr-18)
  - [Status Response Structure](#status-response-structure)
  - [ClusterStatus Fields (aggregated, embedded in Cluster resource)](#clusterstatus-fields-aggregated-embedded-in-cluster-resource)
  - [AdapterStatus Fields (returned by GET /statuses)](#adapterstatus-fields-returned-by-get-statuses)
- [The Three Required Conditions](#the-three-required-conditions)
  - [1. Available](#1-available)
  - [2. Applied](#2-applied)
  - [3. Health](#3-health)
- [The Finalized Condition (Deletion Lifecycle)](#the-finalized-condition-deletion-lifecycle)
- [Additional Conditions (Optional)](#additional-conditions-optional)
  - [Rules for Additional Conditions](#rules-for-additional-conditions)
  - [Example: DNS Adapter with Additional Conditions](#example-dns-adapter-with-additional-conditions)
- [The Data Field (Optional)](#the-data-field-optional)
  - [When to Use Data](#when-to-use-data)
  - [Examples](#examples)
- [Cluster and Status Objects](#cluster-and-status-objects)
  - [Cluster Object Structure (with Aggregated Status)](#cluster-object-structure-with-aggregated-status)
  - [Accessing Detailed Status](#accessing-detailed-status)
  - [Check If Adapter Completed](#check-if-adapter-completed)
  - [Check Adapter Health](#check-adapter-health)
- [Complete Status Lifecycle Examples](#complete-status-lifecycle-examples)
  - [1. Adapter Started (Job Created)](#1-adapter-started-job-created)
  - [2. Adapter Succeeded](#2-adapter-succeeded)
  - [3. Adapter Failed (Business Logic)](#3-adapter-failed-business-logic)
  - [4. Adapter Failed (Unexpected Error)](#4-adapter-failed-unexpected-error)
  - [Complete AdapterStatusList Example](#complete-adapterstatuslist-example)
- [Complete Cluster Scenarios](#complete-cluster-scenarios)
  - [Scenario 1: Successful Cluster Provisioning](#scenario-1-successful-cluster-provisioning)
  - [Scenario 2: Cluster Provisioning with Failure](#scenario-2-cluster-provisioning-with-failure)
  - [Scenario 3: Health Issue Hidden Behind a Reconciled Cluster](#scenario-3-health-issue-hidden-behind-a-reconciled-cluster)
  - [Condition Generation Examples](#condition-generation-examples)
- [Common Status Query Patterns](#common-status-query-patterns)
  - [1. Wait for Specific Adapter](#1-wait-for-specific-adapter)
  - [2. Check If Cluster is Reconciled](#2-check-if-cluster-is-reconciled)
  - [3. Get Failed Adapters](#3-get-failed-adapters)
  - [4. Display Adapter Progress](#4-display-adapter-progress)
- [Condition Reference](#condition-reference)
  - [Required Conditions (All Adapters)](#required-conditions-all-adapters)
  - [Common Reason Values](#common-reason-values)
- [Best Practices](#best-practices)
  - [DO](#do)
  - [DON'T](#dont)
- [Adapter Configuration System (PR #18)](#adapter-configuration-system-pr-18)
  - [Overview](#overview-1)
  - [Key Components](#key-components)
  - [Message Broker Configuration](#message-broker-configuration)
  - [Benefits](#benefits)
  - [Integration with Status Contract](#integration-with-status-contract)
  - [Example: Complete Validation Adapter Config](#example-complete-validation-adapter-config)
- [Summary](#summary)
  - [Architecture Overview](#architecture-overview)
  - [Timestamp Fields Explained](#timestamp-fields-explained)
  - [The Contract](#the-contract)
  - [Condition Meanings](#condition-meanings)
  - [Key Principles](#key-principles)

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

```text
/v1/clusters/{clusterId}                    # Cluster resource (with aggregated status)
/v1/clusters/{clusterId}/statuses           # Adapter statuses (paginated AdapterStatusList)
```

### Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| **GET** | `/v1/clusters/{clusterId}` | Get cluster with aggregated status conditions (`Reconciled`, `LastKnownReconciled`) |
| **GET** | `/v1/clusters/{clusterId}/statuses` | Get paginated `AdapterStatusList` with detailed per-adapter statuses |
| **PUT** | `/v1/clusters/{clusterId}/statuses` | Adapter reports status (API handles upsert internally) |

> **Note**: This document will be updated with references to the Adapter Configuration Framework from [PR #18](https://github.com/openshift-hyperfleet/architecture/pull/18) once it is merged. The PR introduces a declarative YAML-based system for adapter configuration, event handling, and status reporting.

### Adapter Status Reporting Flow

When an adapter needs to report its status, it **always PUTs**. The API handles the upsert logic internally.

#### Adapter Action: PUT Status Report

**PUT** `/v1/clusters/{clusterId}/statuses`

```json
{
  "adapter": "validation",           // Identifies which adapter is reporting
  "observed_generation": 1,
  "observed_time": "2025-10-17T12:02:00Z",  // When adapter checked (now())
  "conditions": [
    {
      "type": "Available",
      "status": "True",
      "reason": "JobSucceeded",
      "message": "Job completed successfully"
    },
    {
      "type": "Applied",
      "status": "True",
      "reason": "JobLaunched",
      "message": "Job created successfully"
    },
    {
      "type": "Health",
      "status": "True",
      "reason": "NoErrors",
      "message": "Adapter is healthy"
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
  }
}
```

**Response**: `201 Created` with the persisted `AdapterStatus` object, or `204 No Content` if the report was silently discarded (stale generation or timestamp).

**What Happens (API-side)**:

1. API receives PUT with `adapter` field identifying which adapter is reporting
2. API validates the request: mandatory conditions (Available, Applied, Health) present, `observed_time` within acceptable range
3. API finds the existing `AdapterStatus` for this adapter (or creates one if first report)
4. If first report: API creates the `AdapterStatus` with `created_time = now()`
5. If subsequent report: API updates the `AdapterStatus`, preserving `created_time`
6. API maps `observed_time` to the stored `last_report_time` field
7. API recalculates aggregated resource conditions: `Reconciled` (all required adapters Available=True at current generation) and `LastKnownReconciled` (sticky cross-generation signal)
8. API generates per-adapter `{AdapterName}Successful` conditions from each adapter's Available status
9. If the resource is soft-deleted, aggregation switches to requiring `Finalized=True` instead of `Available=True`

### Adapter Implementation Pattern

**Simple Pattern** (recommended - API handles upsert internally):

```javascript
function reportStatus(clusterId, adapterStatus) {
  // Adapter always PUTs - API decides if INSERT or UPDATE
  PUT /v1/clusters/{clusterId}/statuses
  body = {
    adapter: "dns",              // Identifies which adapter
    observed_generation: 1,
    observed_time: now(),        // When adapter checked
    conditions: [...],
    data: {...}
  }

  // API returns 201 Created or 204 No Content (if stale)
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

### Reporting Status: Always PUT

Adapters **always PUT** to report status. The API handles upsert internally (INSERT if first report, UPDATE if adapter already reported).

**Endpoint**: `PUT /v1/clusters/{clusterId}/statuses`

**Payload Structure**: Adapters send just their status with `adapter` field identifying themselves:

```json
{
  "adapter": "validation",           // Identifies which adapter is reporting
  "observed_generation": 1,
  "observed_time": "2025-10-17T12:02:00Z",   // When adapter checked (now())
  "conditions": [
    {
      "type": "Available",
      "status": "True",
      "reason": "JobSucceeded",
      "message": "Job completed successfully after 115 seconds"
    },
    {
      "type": "Applied",
      "status": "True",
      "reason": "JobLaunched",
      "message": "Kubernetes Job created successfully"
    },
    {
      "type": "Health",
      "status": "True",
      "reason": "AllChecksPassed",
      "message": "All validation checks passed"
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
    "duration": "115s"
  }
}
```

**API Response**: `201 Created` with the persisted `AdapterStatus` object, or `204 No Content` if the report was discarded (stale generation or timestamp)

**Note**: No `generation` field on ClusterStatus itself. Each adapter reports its own `observed_generation`.

### CRITICAL: Always Update `observed_time`

**Required Behavior**: Adapters MUST update their status on EVERY evaluation, regardless of whether they take action or skip work.

**Why This Matters**:

The Sentinel uses `observed_time` (stored as `last_report_time` on the API side) to calculate max age intervals for publishing reconciliation events. If adapters do not report status when they skip work (e.g., preconditions not met), the Sentinel will create an infinite event loop:

```text
Time 10:00 - DNS adapter receives reconciliation event
Time 10:00 - DNS checks preconditions: Validation adapter not complete
Time 10:00 - DNS does NOT update status (skips work)
            ❌ adapter's last_report_time remains at 09:50
Time 10:10 - Sentinel sees stale report time, max age expired (10s)
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
  "observed_time": "2025-10-17T10:00:00Z",  // ← CRITICAL: Update timestamp even when skipping work
  "conditions": [
    {
      "type": "Available",
      "status": "False",
      "reason": "PreconditionsNotMet",
      "message": "Waiting for validation adapter to complete"
    },
    {
      "type": "Applied",
      "status": "False",
      "reason": "PreconditionsNotMet",
      "message": "Waiting for validation adapter"
    },
    {
      "type": "Health",
      "status": "True",
      "reason": "NoErrors",
      "message": "Adapter is healthy"
    }
  ]
}
```

**Integration Testing Requirement**:

Integration tests for adapters MUST verify:

- ✅ Adapter sets `observed_time` to current time when preconditions are met and work is performed
- ✅ Adapter sets `observed_time` to current time when preconditions are NOT met and work is skipped
- ✅ Sentinel correctly calculates max age from adapter report timestamps

**Reference**: See the Sentinel architecture documentation for details on the max age strategy and reconciliation loop.

---

### Implementation via Adapter Configuration (PR #18)

> **Note**: Once [PR #18](https://github.com/openshift-hyperfleet/architecture/pull/18) is merged, this section will be expanded with configuration examples.

Adapters generate this status payload using declarative configuration that defines:

1. **Status Evaluation Rules** - How to calculate each condition (Applied, Available, Health) based on resource state
2. **Payload Templates** - How to construct the JSON payload with dynamic data
3. **API Reporting Actions** - When and how to PUT to the HyperFleet API

#### Example Configuration Snippet

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
      method: "PUT"
      endpoint: "{{.hyperfleetApi}}/api/{{.version}}/clusters/{{.clusterId}}/statuses"
      body: "{{.clusterStatusPayload}}"
```

This configuration-driven approach ensures consistent status reporting across all adapters without requiring code changes.

### Status Response Structure

Status in HyperFleet has two tiers:

1. **Aggregated status** (`ClusterStatus`) is embedded in the Cluster resource at `cluster.status`. It contains only computed `ResourceCondition` entries (`Reconciled`, `LastKnownReconciled`, `{AdapterName}Successful`). You cannot write to it directly.
2. **Adapter statuses** are returned by `GET /clusters/{id}/statuses` as a paginated `AdapterStatusList`. Each item is an individual `AdapterStatus` object.

```json
GET /api/hyperfleet/v1/clusters/cls-550e8400/statuses

{
  "page": 1,
  "size": 2,
  "total": 2,
  "items": [
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
        "duration": "115s"
      },
      "created_time": "2025-10-17T12:00:00Z",
      "last_report_time": "2025-10-17T12:02:00Z"
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
      "created_time": "2025-10-17T12:03:00Z",
      "last_report_time": "2025-10-17T12:05:00Z"
    }
  ]
}
```

### ClusterStatus Fields (aggregated, embedded in Cluster resource)

> **Schema Reference**: See [ClusterStatus schema definition](https://github.com/openshift-hyperfleet/hyperfleet-api-spec/blob/main/schemas/core/openapi.yaml) in the API spec for complete field definitions, types, and validation rules.

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `conditions` | **YES** | array | Aggregated `ResourceCondition` entries computed by the API |

Mandatory conditions (present from resource creation):

- `Reconciled`: True when the resource's desired state has been fully reconciled by all adapters at the current generation
- `LastKnownReconciled`: Sticky cross-generation condition. Stays True as long as all required adapters were reconciled at a common observed generation, even if a newer generation is being processed

Per-adapter conditions (added as adapters report):

- `{AdapterName}Successful`: True when the adapter's `Available` condition is True. `{AdapterName}` is PascalCased by uppercasing only the first letter of each hyphen-separated segment of the adapter name — it does not uppercase whole acronyms. So the `dns` adapter produces `DnsSuccessful`, not `DNSSuccessful`.

### AdapterStatus Fields (returned by GET /statuses)

> **Schema Reference**: See [AdapterStatus schema definition](https://github.com/openshift-hyperfleet/hyperfleet-api-spec/blob/main/schemas/core/openapi.yaml) in the API spec for complete field definitions, types, and validation rules.

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `adapter` | **YES** | string | Adapter name (e.g., "validation", "dns") |
| `observed_generation` | **YES** | integer | Resource generation this adapter reconciled |
| `conditions` | **YES** | array | `AdapterCondition` entries (typically: Available, Applied, Health, Finalized) |
| `data` | **NO** | object | Adapter-specific structured data |
| `metadata` | **NO** | object | Job execution metadata (`job_name`, `job_namespace`, `attempt`, `started_time`, `completed_time`, `duration`) |
| `created_time` | **YES** | timestamp | When this adapter status was first created (API-managed) |
| `last_report_time` | **YES** | timestamp | When this adapter last reported (API-managed, updated every PUT) |

**Key Points**:

- `GET /clusters/{id}/statuses` returns a paginated `AdapterStatusList`, not a single object
- `ClusterStatus` is a computed sub-object on the Cluster resource (read-only). It has no `id`, `type`, or `href` of its own.
- Each `AdapterStatus` is independent. `observed_generation` indicates which resource generation the adapter reconciled.
- Cluster spec has `generation` (user's intent), adapters report `observed_generation` (observed state)
- Adapters always PUT with `adapter` field in payload. The API handles upsert internally.
- `last_report_time` is API-managed and updated on every PUT, even if conditions haven't changed. Sentinel uses it to detect adapter liveness.
- `last_transition_time` appears on conditions in GET responses but is API-managed. Adapters do not send it in PUT requests.
- The Cluster object contains only aggregated status (see below)

---

## The Three Required Conditions

Every adapter status update **MUST** include these three conditions. The API returns `400 Bad Request` if any of the three are missing from the PUT request.

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
  "message": "Validation Job completed successfully"
}

// Failure
{
  "type": "Available",
  "status": "False",
  "reason": "JobFailed",
  "message": "Validation failed: Route53 zone not found for domain example.com"
}

// In Progress
{
  "type": "Available",
  "status": "False",
  "reason": "JobRunning",
  "message": "Validation Job is still executing"
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
  "message": "Kubernetes Job 'validation-cls-123-gen1' created successfully"
}

// Creation Failed
{
  "type": "Applied",
  "status": "False",
  "reason": "ResourceQuotaExceeded",
  "message": "Failed to create Job: namespace quota exceeded"
}

// Not Yet Attempted
{
  "type": "Applied",
  "status": "False",
  "reason": "PreconditionsNotMet",
  "message": "Waiting for validation to complete"
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
  "message": "Adapter executed normally without errors"
}

// Unhealthy (unexpected error)
{
  "type": "Health",
  "status": "False",
  "reason": "UnexpectedError",
  "message": "Failed to connect to Kubernetes API after 3 retries"
}

// Unhealthy (resource missing)
{
  "type": "Health",
  "status": "False",
  "reason": "ResourceNotFound",
  "message": "Job 'validation-cls-123-gen1' not found in cluster"
}
```

---

## The Finalized Condition (Deletion Lifecycle)

When a resource is soft-deleted (i.e., `deleted_time` is set), adapters participate in the deletion lifecycle by reporting a `Finalized` condition. This condition is **optional** during normal provisioning but becomes critical during deletion.

### How Finalized Works

1. Resource is soft-deleted via the API (sets `deleted_time`)
2. Sentinel publishes reconciliation events for the soft-deleted resource
3. Each adapter performs its cleanup work (delete Jobs, DNS records, etc.)
4. Each adapter reports `Finalized: True` at the current generation via PUT
5. Once **all** required adapters report `Finalized: True`, the API hard-deletes the resource from the database

### Aggregation Behavior

The `Reconciled` aggregated condition changes meaning based on deletion state:

- **Normal lifecycle** (no `deleted_time`): `Reconciled=True` when all required adapters have `Available=True` at current generation
- **Deletion lifecycle** (`deleted_time` set): `Reconciled=True` when all required adapters have `Finalized=True` at current generation, and no child resources remain (e.g., no nodepools for a cluster)

### Example: Adapter Reporting Finalized

**PUT** `/v1/clusters/cls-123/statuses`

```json
{
  "adapter": "dns",
  "observed_generation": 2,
  "observed_time": "2025-10-17T13:00:00Z",
  "conditions": [
    {
      "type": "Available",
      "status": "True",
      "reason": "CleanupComplete",
      "message": "DNS records deleted successfully"
    },
    {
      "type": "Applied",
      "status": "True",
      "reason": "ResourcesRemoved",
      "message": "All DNS resources cleaned up"
    },
    {
      "type": "Health",
      "status": "True",
      "reason": "NoErrors",
      "message": "Adapter is healthy"
    },
    {
      "type": "Finalized",
      "status": "True",
      "reason": "CleanupComplete",
      "message": "Adapter has completed all deletion cleanup"
    }
  ]
}
```

### Key Points

- `Finalized` is **not** in the mandatory set (Available, Applied, Health are mandatory). Missing `Finalized` is treated as "not finalized" (same as `False`).
- Adapters only need to report `Finalized` when handling deletion events. During normal create/update flows, omit it.
- The API triggers hard-delete only when the final adapter's PUT includes `Finalized=True` and all other required adapters have already finalized.
- For clusters, hard-delete also requires that no child nodepools remain (`ReconciledWaitingForChildren` reason if nodepools still exist).
- If an adapter fails to report `Finalized` and the resource is stuck in Finalizing state, operators can use the force-delete endpoints (`POST /v1/clusters/{clusterId}/force-delete` or `POST /v1/clusters/{clusterId}/nodepools/{nodepoolId}/force-delete`) as an escape hatch (requires a `reason` for audit).

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

This example shows an adapter status payload (what gets PUT to the API and persisted as an `AdapterStatus` object):

```json
{
  "adapter": "dns",
  "observed_generation": 1,
  "observed_time": "2025-10-17T12:05:00Z",
  "conditions": [
    {
      "type": "Available",
      "status": "True",
      "reason": "AllRecordsCreated",
      "message": "All DNS records created and verified"
    },
    {
      "type": "Applied",
      "status": "True",
      "reason": "JobLaunched",
      "message": "DNS Job created successfully"
    },
    {
      "type": "Health",
      "status": "True",
      "reason": "NoErrors",
      "message": "DNS adapter executed without errors"
    },
    // Additional conditions
    {
      "type": "APIRecordCreated",
      "status": "True",
      "reason": "Route53Updated",
      "message": "Created A record for api.my-cluster.example.com"
    },
    {
      "type": "AppsWildcardCreated",
      "status": "True",
      "reason": "Route53Updated",
      "message": "Created wildcard record for *.apps.my-cluster.example.com"
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

**Control Plane Adapter Data**:

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
- **GET** `/v1/clusters/{id}/statuses` - Detailed adapter statuses (paginated `AdapterStatusList`)

### Cluster Object Structure (with Aggregated Status)

**GET** `/v1/clusters/{id}`

Returns the complete cluster resource including metadata, spec, and aggregated status:

> **Schema Reference**: See [Cluster schema definition](https://github.com/openshift-hyperfleet/hyperfleet-api-spec/blob/main/schemas/core/openapi.yaml) in the API spec for complete field definitions.

```json
{
  "id": "cls-123",
  "kind": "Cluster",
  "name": "my-cluster",
  "href": "/api/hyperfleet/v1/clusters/cls-123",
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
  "labels": {
    "environment": "production",
    "team": "platform"
  },
  "created_time": "2025-10-17T12:00:00Z",
  "updated_time": "2025-10-17T12:10:00Z",
  "created_by": "user-abc123",
  "updated_by": "user-abc123",
  "status": {
    "conditions": [
      {
        "type": "Reconciled",
        "status": "True",
        "reason": "ReconciledAll",
        "message": "All required adapters reported Available=True or Finalized=True at the current generation",
        "observed_generation": 1,
        "created_time": "2025-10-17T12:00:00Z",
        "last_transition_time": "2025-10-17T12:10:00Z",
        "last_updated_time": "2025-10-17T12:10:00Z"
      },
      {
        "type": "LastKnownReconciled",
        "status": "True",
        "reason": "AllAdaptersReconciled",
        "message": "All required adapters report Available=True for the tracked generation",
        "observed_generation": 1,
        "created_time": "2025-10-17T12:00:00Z",
        "last_transition_time": "2025-10-17T12:10:00Z",
        "last_updated_time": "2025-10-17T12:10:00Z"
      },
      {
        "type": "ValidationSuccessful",
        "status": "True",
        "reason": "JobSucceeded",
        "message": "Job completed successfully after 115 seconds",
        "observed_generation": 1,
        "created_time": "2025-10-17T12:00:05Z",
        "last_transition_time": "2025-10-17T12:02:00Z",
        "last_updated_time": "2025-10-17T12:02:00Z"
      },
      {
        "type": "DnsSuccessful",
        "status": "True",
        "reason": "AllRecordsCreated",
        "message": "All DNS records created and verified",
        "observed_generation": 1,
        "created_time": "2025-10-17T12:03:00Z",
        "last_transition_time": "2025-10-17T12:05:00Z",
        "last_updated_time": "2025-10-17T12:05:00Z"
      },
      {
        "type": "ControlplaneSuccessful",
        "status": "True",
        "reason": "ClusterProvisioned",
        "message": "Control plane provisioned and reachable",
        "observed_generation": 1,
        "created_time": "2025-10-17T12:05:30Z",
        "last_transition_time": "2025-10-17T12:10:00Z",
        "last_updated_time": "2025-10-17T12:10:00Z"
      }
    ]
  }
}
```

> **Schema Reference**: See [ClusterStatus Fields](#clusterstatus-fields-aggregated-embedded-in-cluster-resource) above for the full field list — this example shows a fully-reconciled cluster; see [Complete Cluster Scenarios](#complete-cluster-scenarios) for how these conditions evolve over the provisioning lifecycle.

### Accessing Detailed Status

To see detailed conditions, data, and health information for ALL adapters:

**GET** `/v1/clusters/{clusterId}/statuses`

This returns a paginated `AdapterStatusList` (`{page, size, total, items}`) containing one `AdapterStatus` entry per adapter. You can then filter client-side for the specific adapter you need. Because `items` is page-local, keep fetching subsequent pages until the adapter is found or all pages are exhausted.

Each item in the `items` array includes its `observed_generation` field, indicating which cluster generation that adapter has reconciled.

### Check If Adapter Completed

To determine if an adapter has completed successfully:

1. Fetch adapter statuses: `GET /v1/clusters/{clusterId}/statuses`, following pagination until found or all pages are exhausted
2. Find the adapter by `adapter` name in the returned `items`
3. Check `observed_generation === cluster.generation` (not stale)
4. Check the `Available` condition's `status === "True"`

### Check Adapter Health

To check adapter health, you need the detailed `AdapterStatus` object:

1. Fetch: `GET /v1/clusters/{clusterId}/statuses`, following pagination until found or all pages are exhausted
2. Find the adapter by `adapter` name in the returned `items`, filtering client-side on `observed_generation` if you need a specific generation
3. Find the `Health` condition in that adapter's `conditions`
4. Check if `status === "True"`

If `Health: False`, examine the `message` and `data` fields for debugging details.

---

## Complete Status Lifecycle Examples

The following examples show **individual adapter status payloads** that adapters send. These become individual `AdapterStatus` items retrievable via `GET /statuses`.

> **Implementation Note**: Once [PR #18](https://github.com/openshift-hyperfleet/architecture/pull/18) is merged, adapters will generate these payloads using declarative configuration. The `postProcessing.statusEvaluation` section in the adapter config defines how to calculate condition states (Applied, Available, Health) by evaluating resource state, and the `actions` section defines when to PUT these payloads to the HyperFleet API.

### 1. Adapter Started (Job Created)

**Scenario**: Validation adapter received event, created Job. This is the first adapter to report. The API will create a new `AdapterStatus` object for it.

**PUT** `/v1/clusters/cls-123/statuses`

```json
{
  "adapter": "validation",
  "observed_generation": 1,
  "observed_time": "2025-10-17T12:00:05Z",
  "conditions": [
    {
      "type": "Available",
      "status": "False",
      "reason": "JobRunning",
      "message": "Validation Job is executing"
    },
    {
      "type": "Applied",
      "status": "True",
      "reason": "JobLaunched",
      "message": "Kubernetes Job 'validation-cls-123-gen1' created successfully"
    },
    {
      "type": "Health",
      "status": "True",
      "reason": "NoErrors",
      "message": "Adapter is healthy"
    }
  ],
  "metadata": {
    "job_name": "validation-cls-123-gen1",
    "job_namespace": "hyperfleet-jobs"
  }
}
```

**What This Means**:

- Job created successfully (Applied: True)
- Job is running (Available: False - not yet complete)
- No errors (Health: True)

---

### 2. Adapter Succeeded

**Scenario**: Validation Job completed successfully. Validation adapter PUTs to update its status (API handles upsert).

**PUT** `/v1/clusters/cls-123/statuses`

```json
{
  "adapter": "validation",
  "observed_generation": 1,
  "observed_time": "2025-10-17T12:02:00Z",
  "conditions": [
    {
      "type": "Available",
      "status": "True",
      "reason": "JobSucceeded",
      "message": "Job completed successfully after 115 seconds"
    },
    {
      "type": "Applied",
      "status": "True",
      "reason": "JobLaunched",
      "message": "Kubernetes Job created successfully"
    },
    {
      "type": "Health",
      "status": "True",
      "reason": "AllChecksPassed",
      "message": "All validation checks passed"
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
    "completed_time": "2025-10-17T12:02:00Z"
  }
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

**PUT** `/v1/clusters/cls-123/statuses`

```json
{
  "adapter": "validation",
  "observed_generation": 1,
  "observed_time": "2025-10-17T12:02:00Z",
  "conditions": [
    {
      "type": "Available",
      "status": "False",
      "reason": "ValidationFailed",
      "message": "Route53 zone not found for domain example.com. Create a public hosted zone before provisioning the cluster."
    },
    {
      "type": "Applied",
      "status": "True",
      "reason": "JobLaunched",
      "message": "Kubernetes Job created successfully"
    },
    {
      "type": "Health",
      "status": "True",
      "reason": "NoErrors",
      "message": "Adapter executed normally (validation logic failed, not adapter error)"
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
  }
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

**PUT** `/v1/clusters/cls-123/statuses`

```json
{
  "adapter": "validation",
  "observed_generation": 1,
  "observed_time": "2025-10-17T12:00:05Z",
  "conditions": [
    {
      "type": "Available",
      "status": "False",
      "reason": "ResourceCreationFailed",
      "message": "Failed to create validation Job"
    },
    {
      "type": "Applied",
      "status": "False",
      "reason": "ResourceQuotaExceeded",
      "message": "Failed to create Job: namespace resource quota exceeded (cpu limit reached)"
    },
    {
      "type": "Health",
      "status": "False",
      "reason": "UnexpectedError",
      "message": "Adapter could not complete due to resource quota limits"
    }
  ],
  "data": {
    "error": {
      "type": "ResourceQuotaExceeded",
      "message": "CPU limit reached",
      "namespace": "hyperfleet-jobs"
    }
  }
}
```

**What This Means**:

- Job NOT created (Applied: False)
- Work incomplete (Available: False)
- Adapter unhealthy (Health: False) - **unexpected error prevented normal operation**

**Key Point**: `Health: False` because this is an unexpected infrastructure issue, not expected business logic.

---

### Complete AdapterStatusList Example

Here's what `GET /v1/clusters/{id}/statuses` returns with multiple adapters at different stages of the same generation. Like the [Status Response Structure](#status-response-structure) example, this is the paginated `AdapterStatusList` shape — not a single object with an embedded array.

**GET** `/v1/clusters/cls-550e8400/statuses`

```json
{
  "page": 1,
  "size": 3,
  "total": 3,
  "items": [
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
      "created_time": "2025-10-17T12:00:00Z",
      "last_report_time": "2025-10-17T12:02:00Z"
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
      "created_time": "2025-10-17T12:03:00Z",
      "last_report_time": "2025-10-17T12:03:00Z"
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
      "created_time": "2025-10-17T12:00:00Z",
      "last_report_time": "2025-10-17T12:00:00Z"
    }
  ]
}
```

**What This Shows**:

- **validation**: Completed successfully
- **dns**: Currently running
- **controlplane**: Waiting for preconditions (dns completion)
- Each item is an independent `AdapterStatus` object — there's no wrapping cluster-level object here, just the paginated list
- Easy to fetch and display complete cluster provisioning status by iterating `items` across all pages

---

## Complete Cluster Scenarios

This section demonstrates how cluster conditions evolve throughout the complete lifecycle, showing the interplay between adapter statuses and cluster-level condition aggregation.

### Scenario 1: Successful Cluster Provisioning

Timeline: cluster created at 12:00:00Z (generation 1) → validation starts at 12:00:05Z → validation succeeds at 12:02:00Z → dns starts at 12:03:00Z → dns succeeds at 12:05:00Z → controlplane starts at 12:05:30Z → controlplane succeeds at 12:10:00Z (cluster fully reconciled). The required adapters for this cluster are `validation`, `dns`, and `controlplane`.

#### Stage 1: Initial State

**Cluster State**: Just created, no adapters have reported yet. `Reconciled` and `LastKnownReconciled` are present from creation (see [ClusterStatus Fields](#clusterstatus-fields-aggregated-embedded-in-cluster-resource)), both `False`. No per-adapter `{AdapterName}Successful` conditions exist yet — those are only added once an adapter reports.

**GET** `/v1/clusters/cls-123`

```json
{
  "id": "cls-123",
  "kind": "Cluster",
  "name": "my-cluster",
  "generation": 1,
  "spec": {
    "cloud": "aws",
    "region": "us-east-1"
  },
  "created_time": "2025-10-17T12:00:00Z",
  "updated_time": "2025-10-17T12:00:00Z",
  "status": {
    "conditions": [
      {
        "type": "Reconciled",
        "status": "False",
        "reason": "ReconciledMissingAdapters",
        "message": "Required adapters not reporting Available=True: [controlplane, dns, validation]. Currently reporting: []",
        "observed_generation": 1,
        "created_time": "2025-10-17T12:00:00Z",
        "last_transition_time": "2025-10-17T12:00:00Z",
        "last_updated_time": "2025-10-17T12:00:00Z"
      },
      {
        "type": "LastKnownReconciled",
        "status": "False",
        "reason": "AdaptersMissingReports",
        "message": "Required adapters have not yet reported status",
        "observed_generation": 1,
        "created_time": "2025-10-17T12:00:00Z",
        "last_transition_time": "2025-10-17T12:00:00Z",
        "last_updated_time": "2025-10-17T12:00:00Z"
      }
    ]
  }
}
```

#### Stage 2: Validation Started

**Cluster State**: Validation adapter's first PUT (`Applied: True`, `Available: False`) adds `ValidationSuccessful` at `False`. `Reconciled` and `LastKnownReconciled` stay `False` — note `last_transition_time` does not move (the status value is still `False`), but `last_updated_time` does move, since a required adapter's report triggered recomputation.

**GET** `/v1/clusters/cls-123`

```json
{
  "id": "cls-123",
  "kind": "Cluster",
  "name": "my-cluster",
  "generation": 1,
  "spec": {
    "cloud": "aws",
    "region": "us-east-1"
  },
  "created_time": "2025-10-17T12:00:00Z",
  "updated_time": "2025-10-17T12:00:00Z",
  "status": {
    "conditions": [
      {
        "type": "Reconciled",
        "status": "False",
        "reason": "ReconciledMissingAdapters",
        "message": "Required adapters not reporting Available=True: [controlplane, dns, validation]. Currently reporting: [validation]",
        "observed_generation": 1,
        "created_time": "2025-10-17T12:00:00Z",
        "last_transition_time": "2025-10-17T12:00:00Z",
        "last_updated_time": "2025-10-17T12:00:05Z"
      },
      {
        "type": "LastKnownReconciled",
        "status": "False",
        "reason": "AdaptersMissingReports",
        "message": "Required adapters have not yet reported status",
        "observed_generation": 1,
        "created_time": "2025-10-17T12:00:00Z",
        "last_transition_time": "2025-10-17T12:00:00Z",
        "last_updated_time": "2025-10-17T12:00:05Z"
      },
      {
        "type": "ValidationSuccessful",
        "status": "False",
        "reason": "JobRunning",
        "message": "Validation Job is executing",
        "observed_generation": 1,
        "created_time": "2025-10-17T12:00:05Z",
        "last_transition_time": "2025-10-17T12:00:05Z",
        "last_updated_time": "2025-10-17T12:00:05Z"
      }
    ]
  }
}
```

#### Stage 3: Validation Complete, DNS Started

**Cluster State**: `ValidationSuccessful` flips to `True` at 12:02:00Z (`last_transition_time` moves). `DnsSuccessful` appears at `False` (dns just started). `controlplane` hasn't reported at all yet, so it has no condition — this is how per-adapter conditions are added as adapters report.

**GET** `/v1/clusters/cls-123`

```json
{
  "id": "cls-123",
  "kind": "Cluster",
  "name": "my-cluster",
  "generation": 1,
  "spec": {
    "cloud": "aws",
    "region": "us-east-1"
  },
  "created_time": "2025-10-17T12:00:00Z",
  "updated_time": "2025-10-17T12:00:00Z",
  "status": {
    "conditions": [
      {
        "type": "Reconciled",
        "status": "False",
        "reason": "ReconciledMissingAdapters",
        "message": "Required adapters not reporting Available=True: [controlplane, dns]. Currently reporting: [dns, validation]",
        "observed_generation": 1,
        "created_time": "2025-10-17T12:00:00Z",
        "last_transition_time": "2025-10-17T12:00:00Z",
        "last_updated_time": "2025-10-17T12:03:00Z"
      },
      {
        "type": "LastKnownReconciled",
        "status": "False",
        "reason": "AdaptersMissingReports",
        "message": "Required adapters have not yet reported status",
        "observed_generation": 1,
        "created_time": "2025-10-17T12:00:00Z",
        "last_transition_time": "2025-10-17T12:00:00Z",
        "last_updated_time": "2025-10-17T12:03:00Z"
      },
      {
        "type": "ValidationSuccessful",
        "status": "True",
        "reason": "JobSucceeded",
        "message": "Job completed successfully after 115 seconds",
        "observed_generation": 1,
        "created_time": "2025-10-17T12:00:05Z",
        "last_transition_time": "2025-10-17T12:02:00Z",
        "last_updated_time": "2025-10-17T12:02:00Z"
      },
      {
        "type": "DnsSuccessful",
        "status": "False",
        "reason": "JobRunning",
        "message": "DNS Job is executing",
        "observed_generation": 1,
        "created_time": "2025-10-17T12:03:00Z",
        "last_transition_time": "2025-10-17T12:03:00Z",
        "last_updated_time": "2025-10-17T12:03:00Z"
      }
    ]
  }
}
```

#### Stage 4: All Adapters Complete

**Cluster State**: `controlplane` succeeds at 12:10:00Z, the last required adapter to report `Available: True`. `Reconciled` and `LastKnownReconciled` both flip to `True` at that moment.

**GET** `/v1/clusters/cls-123`

```json
{
  "id": "cls-123",
  "kind": "Cluster",
  "name": "my-cluster",
  "generation": 1,
  "spec": {
    "cloud": "aws",
    "region": "us-east-1"
  },
  "created_time": "2025-10-17T12:00:00Z",
  "updated_time": "2025-10-17T12:00:00Z",
  "status": {
    "conditions": [
      {
        "type": "Reconciled",
        "status": "True",
        "reason": "ReconciledAll",
        "message": "All required adapters reported Available=True or Finalized=True at the current generation",
        "observed_generation": 1,
        "created_time": "2025-10-17T12:00:00Z",
        "last_transition_time": "2025-10-17T12:10:00Z",
        "last_updated_time": "2025-10-17T12:10:00Z"
      },
      {
        "type": "LastKnownReconciled",
        "status": "True",
        "reason": "AllAdaptersReconciled",
        "message": "All required adapters report Available=True for the tracked generation",
        "observed_generation": 1,
        "created_time": "2025-10-17T12:00:00Z",
        "last_transition_time": "2025-10-17T12:10:00Z",
        "last_updated_time": "2025-10-17T12:10:00Z"
      },
      {
        "type": "ValidationSuccessful",
        "status": "True",
        "reason": "JobSucceeded",
        "message": "Job completed successfully after 115 seconds",
        "observed_generation": 1,
        "created_time": "2025-10-17T12:00:05Z",
        "last_transition_time": "2025-10-17T12:02:00Z",
        "last_updated_time": "2025-10-17T12:02:00Z"
      },
      {
        "type": "DnsSuccessful",
        "status": "True",
        "reason": "AllRecordsCreated",
        "message": "All DNS records created and verified",
        "observed_generation": 1,
        "created_time": "2025-10-17T12:03:00Z",
        "last_transition_time": "2025-10-17T12:05:00Z",
        "last_updated_time": "2025-10-17T12:05:00Z"
      },
      {
        "type": "ControlplaneSuccessful",
        "status": "True",
        "reason": "ClusterProvisioned",
        "message": "Control plane provisioned and reachable",
        "observed_generation": 1,
        "created_time": "2025-10-17T12:05:30Z",
        "last_transition_time": "2025-10-17T12:10:00Z",
        "last_updated_time": "2025-10-17T12:10:00Z"
      }
    ]
  }
}
```

> **Note the timestamp behavior**: `last_transition_time` on `Reconciled`/`LastKnownReconciled` stayed pinned at `12:00:00Z` through Stages 1-3 even as the `message` text changed, because the *status value* never flipped — it only moved when the condition actually flipped to `True` in Stage 4. `last_updated_time`, by contrast, advanced at every stage because it's refreshed on every relevant adapter report, regardless of whether the status changed. See [Timestamp Fields Explained](#timestamp-fields-explained).

### Scenario 2: Cluster Provisioning with Failure

#### Stage 1: Validation Failure

**Cluster State**: Validation adapter failed due to a missing DNS zone (see [Adapter Failed (Business Logic)](#3-adapter-failed-business-logic)). `ValidationSuccessful` is `False`; `Reconciled` and `LastKnownReconciled` stay `False` since the cluster has never reconciled.

**GET** `/v1/clusters/cls-456`

```json
{
  "id": "cls-456",
  "kind": "Cluster",
  "name": "failed-cluster",
  "generation": 1,
  "spec": {
    "cloud": "aws",
    "region": "us-east-1",
    "domain": "example.com"
  },
  "created_time": "2025-10-17T12:00:00Z",
  "updated_time": "2025-10-17T12:00:00Z",
  "status": {
    "conditions": [
      {
        "type": "Reconciled",
        "status": "False",
        "reason": "ReconciledMissingAdapters",
        "message": "Required adapters not reporting Available=True: [controlplane, dns, validation]. Currently reporting: [validation]",
        "observed_generation": 1,
        "created_time": "2025-10-17T12:00:00Z",
        "last_transition_time": "2025-10-17T12:00:00Z",
        "last_updated_time": "2025-10-17T12:02:00Z"
      },
      {
        "type": "LastKnownReconciled",
        "status": "False",
        "reason": "AdaptersMissingReports",
        "message": "Required adapters have not yet reported status",
        "observed_generation": 1,
        "created_time": "2025-10-17T12:00:00Z",
        "last_transition_time": "2025-10-17T12:00:00Z",
        "last_updated_time": "2025-10-17T12:02:00Z"
      },
      {
        "type": "ValidationSuccessful",
        "status": "False",
        "reason": "ValidationFailed",
        "message": "Route53 zone not found for domain example.com. Create a public hosted zone before provisioning the cluster.",
        "observed_generation": 1,
        "created_time": "2025-10-17T12:00:05Z",
        "last_transition_time": "2025-10-17T12:00:05Z",
        "last_updated_time": "2025-10-17T12:02:00Z"
      }
    ]
  }
}
```

#### Stage 2: After Manual Fix — Retry at Generation 2

**Cluster State**: The user created the missing DNS zone and updated the cluster spec, bumping `generation` to 2. All required adapters re-reconcile and report `Available: True` at generation 2, so both `Reconciled` and `LastKnownReconciled` flip `True`.

**GET** `/v1/clusters/cls-456`

```json
{
  "id": "cls-456",
  "kind": "Cluster",
  "name": "failed-cluster",
  "generation": 2,
  "spec": {
    "cloud": "aws",
    "region": "us-east-1",
    "domain": "example.com"
  },
  "created_time": "2025-10-17T12:00:00Z",
  "updated_time": "2025-10-17T13:05:00Z",
  "status": {
    "conditions": [
      {
        "type": "Reconciled",
        "status": "True",
        "reason": "ReconciledAll",
        "message": "All required adapters reported Available=True or Finalized=True at the current generation",
        "observed_generation": 2,
        "created_time": "2025-10-17T12:00:00Z",
        "last_transition_time": "2025-10-17T13:05:00Z",
        "last_updated_time": "2025-10-17T13:05:00Z"
      },
      {
        "type": "LastKnownReconciled",
        "status": "True",
        "reason": "AllAdaptersReconciled",
        "message": "All required adapters report Available=True for the tracked generation",
        "observed_generation": 2,
        "created_time": "2025-10-17T12:00:00Z",
        "last_transition_time": "2025-10-17T13:05:00Z",
        "last_updated_time": "2025-10-17T13:05:00Z"
      },
      {
        "type": "ValidationSuccessful",
        "status": "True",
        "reason": "JobSucceeded",
        "message": "Job completed successfully",
        "observed_generation": 2,
        "created_time": "2025-10-17T12:00:05Z",
        "last_transition_time": "2025-10-17T13:01:00Z",
        "last_updated_time": "2025-10-17T13:01:00Z"
      },
      {
        "type": "DnsSuccessful",
        "status": "True",
        "reason": "AllRecordsCreated",
        "message": "All DNS records created and verified",
        "observed_generation": 2,
        "created_time": "2025-10-17T13:02:00Z",
        "last_transition_time": "2025-10-17T13:03:00Z",
        "last_updated_time": "2025-10-17T13:03:00Z"
      },
      {
        "type": "ControlplaneSuccessful",
        "status": "True",
        "reason": "ClusterProvisioned",
        "message": "Control plane provisioned and reachable",
        "observed_generation": 2,
        "created_time": "2025-10-17T13:04:00Z",
        "last_transition_time": "2025-10-17T13:05:00Z",
        "last_updated_time": "2025-10-17T13:05:00Z"
      }
    ]
  }
}
```

Because this cluster was never successfully reconciled at generation 1, `LastKnownReconciled` was `False` right up until this point — it had no prior generation to stay "sticky" about. [Scenario 3](#scenario-3-health-issue-hidden-behind-a-reconciled-cluster) below shows the stickiness behavior on a cluster that already succeeded once.

### Scenario 3: Health Issue Hidden Behind a Reconciled Cluster

#### Stage 1: Cluster Fully Reconciled at Generation 1

**Cluster State**: All required adapters (`validation`, `dns`, `controlplane`) have reported `Available: True` at generation 1. This is the same fully-reconciled shape as [Scenario 1, Stage 4](#stage-4-all-adapters-complete), just with a different cluster ID.

**GET** `/v1/clusters/cls-789` returns `Reconciled: True`, `LastKnownReconciled: True`, and `True` for `ValidationSuccessful`, `DnsSuccessful`, and `ControlplaneSuccessful`.

#### Stage 2: `controlplane` Adapter Reports a Health Issue

**Cluster State**: The `controlplane` adapter PUTs again at generation 1 with `Available: True` (the provisioning work is still done) but `Health: False`, reporting an unexpected error.

`{AdapterName}Successful` mirrors only the adapter's `Available` condition (see [ClusterStatus Fields](#clusterstatus-fields-aggregated-embedded-in-cluster-resource)), never `Health`. So `ControlplaneSuccessful` stays `True` and `Reconciled`/`LastKnownReconciled` stay `True` — the Cluster-level `GET` response is unchanged and still looks fully healthy. The health problem is only visible via `GET /v1/clusters/cls-789/statuses`, in that adapter's `Health` condition. This is exactly [Query Pattern #3: Get Failed Adapters](#3-get-failed-adapters) — the aggregated conditions tell you whether work completed, not whether an adapter is currently healthy.

**GET** `/v1/clusters/cls-789/statuses`

```json
{
  "page": 1,
  "size": 1,
  "total": 1,
  "items": [
    {
      "adapter": "controlplane",
      "observed_generation": 1,
      "conditions": [
        {
          "type": "Available",
          "status": "True",
          "reason": "ClusterProvisioned",
          "message": "Control plane provisioned and reachable",
          "last_transition_time": "2025-10-17T12:10:00Z"
        },
        {
          "type": "Applied",
          "status": "True",
          "reason": "ResourcesCreated",
          "message": "Control plane resources created",
          "last_transition_time": "2025-10-17T12:08:00Z"
        },
        {
          "type": "Health",
          "status": "False",
          "reason": "APIConnectionFailed",
          "message": "Lost connection to cloud provider API while polling cluster status",
          "last_transition_time": "2025-10-17T12:20:00Z"
        }
      ],
      "created_time": "2025-10-17T12:05:30Z",
      "last_report_time": "2025-10-17T12:20:00Z"
    }
  ]
}
```

#### Stage 3: New Generation Started While the Health Issue Persists

**Cluster State**: The user updates the cluster spec, bumping `generation` to 2. The `validation` adapter starts reconciling generation 2, but `dns` and `controlplane` haven't reported at generation 2 yet. `Reconciled` flips back to `False` (not all required adapters are current at generation 2), but `LastKnownReconciled` **stays `True`** — because at generation 1, all required adapters *were* reconciled together. This is the clearest illustration in this guide of the "sticky cross-generation" behavior.

```json
"conditions": [
  {
    "type": "Reconciled",
    "status": "False",
    "reason": "ReconciledMissingAdapters",
    "message": "Required adapters not reporting Available=True: [controlplane, dns]. Currently reporting: [controlplane, dns, validation]",
    "observed_generation": 2,
    "created_time": "2025-10-17T12:00:00Z",
    "last_transition_time": "2025-10-17T14:00:00Z",
    "last_updated_time": "2025-10-17T14:00:00Z"
  },
  {
    "type": "LastKnownReconciled",
    "status": "True",
    "reason": "AllAdaptersReconciled",
    "message": "All required adapters report Available=True for the tracked generation",
    "observed_generation": 1,
    "created_time": "2025-10-17T12:00:00Z",
    "last_transition_time": "2025-10-17T12:10:00Z",
    "last_updated_time": "2025-10-17T12:10:00Z"
  }
]
```

Note that `Reconciled` recomputes because validation's new report at generation 2 is a "relevant adapter report": its `observed_generation` advances to `2`, and because its status just flipped True→False, `last_transition_time` moves too. `LastKnownReconciled`, by contrast, is **completely untouched** — same status, reason, message, observed_generation, and both timestamps as before generation 2 started. That's the sticky behavior in its purest form: since `dns`/`controlplane` are still reporting their (stale but) True generation-1 state, the aggregate is still "all-True-but-mixed-generation," and because it was already `True`, it stays `True` without being recomputed at all — not even its timestamps move.

### Condition Generation Examples

These examples show the real aggregated `ResourceCondition` types, reusing the exact values established in [Scenario 1, Stage 4](#stage-4-all-adapters-complete) rather than inventing new ones.

#### Reconciled Condition

Generated when all required adapters report `Available: True` at the current generation:

```json
{
  "type": "Reconciled",
  "status": "True",
  "reason": "ReconciledAll",
  "message": "All required adapters reported Available=True or Finalized=True at the current generation",
  "observed_generation": 1,
  "created_time": "2025-10-17T12:00:00Z",
  "last_transition_time": "2025-10-17T12:10:00Z",
  "last_updated_time": "2025-10-17T12:10:00Z"
}
```

#### LastKnownReconciled Condition

Generated the same way as `Reconciled`, but never flips back to `False` when a new generation starts mid-flight (see [Scenario 3, Stage 3](#stage-3-new-generation-started-while-the-health-issue-persists)):

```json
{
  "type": "LastKnownReconciled",
  "status": "True",
  "reason": "AllAdaptersReconciled",
  "message": "All required adapters report Available=True for the tracked generation",
  "observed_generation": 1,
  "created_time": "2025-10-17T12:00:00Z",
  "last_transition_time": "2025-10-17T12:10:00Z",
  "last_updated_time": "2025-10-17T12:10:00Z"
}
```

#### {AdapterName}Successful Condition

Generated per required adapter, mirroring that adapter's own `Available` condition:

```json
{
  "type": "DnsSuccessful",
  "status": "True",
  "reason": "AllRecordsCreated",
  "message": "All DNS records created and verified",
  "observed_generation": 1,
  "created_time": "2025-10-17T12:03:00Z",
  "last_transition_time": "2025-10-17T12:05:00Z",
  "last_updated_time": "2025-10-17T12:05:00Z"
}
```

---

## Common Status Query Patterns

### 1. Wait for Specific Adapter

To poll until an adapter completes:

1. Fetch adapter statuses: `GET /v1/clusters/{clusterId}/statuses`
2. Find the adapter by `adapter` name in the `items` array
3. If not found, the adapter has not reported yet. Continue polling.
4. Verify `observed_generation === cluster.generation` (not stale)
5. Check `Available` condition:
   - `status: "True"` → adapter succeeded, stop polling
   - `status: "False"` → check `reason`:
     - `JobRunning` or `JobPending` → still in progress, continue polling
     - Other reasons → adapter failed, stop polling
6. Implement timeout (e.g., 10 minutes)

### 2. Check If Cluster is Reconciled

To verify cluster is fully provisioned:

1. Fetch cluster: `GET /v1/clusters/{clusterId}`
2. Check the `Reconciled` condition in `status.conditions`:
   - `status: "True"` → all required adapters report `Available=True` at the current generation
3. For a stickier signal, check `LastKnownReconciled`:
   - `status: "True"` → all adapters were reconciled at a common generation (stays True even while a new generation is being processed)

### 3. Get Failed Adapters

To identify which adapters have failed:

1. Fetch cluster: `GET /v1/clusters/{clusterId}`
2. Check per-adapter conditions in `status.conditions`:
   - `{AdapterName}Successful: "False"` → that adapter has a problem
3. Fetch detailed status for specifics: `GET /v1/clusters/{clusterId}/statuses`
4. For each failed adapter, find it by `adapter` name in `items`:
   - Get `Available` condition's `message` and `reason`
   - Get `Health` condition to determine if it's a health issue
5. Return list with failure details

### 4. Display Adapter Progress

To show progress UI:

1. Fetch adapter statuses: `GET /v1/clusters/{clusterId}/statuses`
2. For each adapter in `items`:
   - Check conditions:
     - `Available: "True"` → Completed
     - `Available: "False"` with `JobRunning` reason → Running
     - `Available: "False"` with failure reason → Failed
     - `Health: "False"` → Unhealthy
     - `Applied: "False"` → Pending
3. Compare `observed_generation` to `cluster.generation` to detect stale adapters
4. Display adapter name, status icon, generation, and message from conditions

**Example Output**:

```text
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
     "message": "Route53 zone not found for domain example.com. Create a public hosted zone before provisioning the cluster."
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
    method: "PUT"
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
- **Simple PUT Pattern** - Framework automatically PUTs status reports (API handles upsert)
- **observed_generation** - Automatically included in status payloads from event parameters
- **Condition Structure** - Templates generate proper `type`, `status`, `reason`, `message` fields
- **Data Field** - Custom data can be included via configuration templates

### Example: Complete Validation Adapter Config

For a complete example of an adapter configuration that implements this status contract, see [PR #18 - adapter-config-template.yaml](https://github.com/openshift-hyperfleet/architecture/pull/18/files).

---

## Summary

### Architecture Overview

**Adapter Statuses** (detailed, per-adapter):

- Adapters always PUT: `PUT /v1/clusters/{clusterId}/statuses` with `adapter`, `observed_generation`, `observed_time`, and required conditions in payload
- API handles upsert internally: INSERT on first report, UPDATE on subsequent reports
- Each `AdapterStatus` contains conditions, data, and metadata for one adapter
- Retrieved as a paginated list via `GET /v1/clusters/{clusterId}/statuses`

**Cluster Object** (complete resource):

- Contains `id`, `name`, `generation`, `spec`, and lifecycle fields
- Contains `status` field with aggregated `ClusterStatus`:
  - `conditions`: Array of `ResourceCondition` entries computed by the API
  - Mandatory: `Reconciled` (all adapters at current generation), `LastKnownReconciled` (sticky cross-generation)
  - Per-adapter: `{AdapterName}Successful` (reflects that adapter's `Available` condition)
- Retrieved via `GET /v1/clusters/{clusterId}`

### Timestamp Fields Explained

Understanding when and how timestamps are set is critical for Sentinel's staleness detection:

| Field | Set By | Purpose | Calculation |
|-------|--------|---------|-------------|
| `AdapterStatus.created_time` | **API** | When this adapter status was first created | API-managed; value derived from the adapter-supplied `observed_time` on first PUT |
| `AdapterStatus.last_report_time` | **API** | When this adapter last reported | API-managed; updated on every PUT (even if conditions are unchanged); value derived from the adapter's `observed_time`, falling back to `time.Now()` only if `observed_time` is zero |
| `AdapterCondition.last_transition_time` | **API** | When this adapter's condition last flipped status | API-managed; adapters do not send this in PUT requests (see [AdapterStatus Fields](#adapterstatus-fields-returned-by-get-statuses)) |
| `ResourceCondition.last_transition_time` | **API** | When this aggregated condition (`Reconciled`, `LastKnownReconciled`, `{AdapterName}Successful`) last flipped status | API-managed; only updates when `status` actually changes, not on every recomputation |
| `ResourceCondition.last_updated_time` | **API** | When this aggregated condition was last recomputed | API-managed; copied from the `last_report_time` of the adapter whose PUT triggered the recomputation |
| PUT payload `observed_time` | **Adapter** | When the adapter observed the resource state it's reporting on | The one genuinely adapter-supplied timestamp; validated against a skew tolerance, then used to set both `created_time` and `last_report_time` |

There is no aggregated status timestamp inside `ClusterStatus` — it contains only `conditions` (see [ClusterStatus Fields](#clusterstatus-fields-aggregated-embedded-in-cluster-resource)); the parent `Cluster` resource still has its own `updated_time`. Sentinel does not compute a `min()` across adapters at the cluster level; it doesn't need to, because it evaluates staleness **per adapter, independently**.

#### How Sentinel Actually Detects Staleness

Sentinel's decision logic tracks each required adapter's `last_report_time` on `AdapterStatus` directly. An adapter is stale if too much time has passed since its `last_report_time` relative to the current `generation` — regardless of whether other adapters are reporting freshly. This is exactly why the [CRITICAL: Always Update `observed_time`](#critical-always-update-observed_time) rule exists: if an adapter skips reporting when it has no work to do, its `last_report_time` goes stale and Sentinel re-publishes a reconciliation event for it specifically, while adapters that are actively reporting are left alone. There's no "confidence" concept and no `min()`/`max()` trick needed — each adapter's liveness is judged on its own `last_report_time`, not blended into a single cluster-wide number.

### The Contract

1. **Three required conditions**: Available, Applied, Health (in each adapter PUT request). API returns `400` if any are missing.
2. **Paginated adapter statuses**: `GET /statuses` returns `AdapterStatusList` with individual `AdapterStatus` items
3. **Optional data field**: JSONB for structured information per adapter
4. **Additional conditions allowed**: All must be positive assertions (e.g., `Finalized` for deletion)
5. **Adapter aggregates**: All condition statuses determine Available
6. **Cluster aggregates**: All adapter `Available` conditions determine `Reconciled` and `{AdapterName}Successful`

### Condition Meanings

- **Available**: Did the work succeed? (True = complete, False = failed/incomplete/in-progress)
- **Applied**: Were resources created? (True = created, False = failed/not-attempted)
- **Health**: Any unexpected errors? (True = healthy, False = unexpected error)

### Key Principles

1. **Two-tier status model** - Aggregated `ClusterStatus` conditions on the Cluster resource for quick access, detailed `AdapterStatus` objects via `GET /statuses` for specifics
2. **Conditions are the contract** - Three required (Available, Applied, Health), plus optional `Finalized` for deletion
3. **Positive assertions** - All condition types should be positive
4. **Aggregation logic** - `Reconciled` reflects all adapters' `Available` at the current generation. `{AdapterName}Successful` mirrors each adapter's `Available`.
5. **Health vs Business Logic** - Health is about adapter errors, not validation failures
6. **Structured data** - Use `data` field for details beyond conditions
7. **API-managed timestamps** - `last_transition_time`, `created_time`, `last_report_time` are set by the API, not by adapters

---
