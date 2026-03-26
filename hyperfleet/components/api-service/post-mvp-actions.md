---
Status: Active
Owner: HyperFleet API Team
Last Updated: 2025-11-25
---

# Post-MVP Tasks (Temporary Record)

## Overview

This document records post-MVP actions we can enhance and additional features we will implement. This file will be updated as more documentation is added. Any tasks determined to be deprecated can be removed directly from this document.

This was recorded on Thursday, November 6th, 2025.

# CLM Foundational components
This document contains the post-MVP features and enhancements that were removed from jira tickets
## Core API Service Foundation
### Design OpenAPI spec
* PATCH /api/hyperfleet/v1/clusters/{id} - Update cluster (full CRUD)
* DELETE /api/hyperfleet/v1/clusters/{id} - Delete cluster (full CRUD)
* PATCH /api/hyperfleet/v1/nodepools/{id} - Update node pool (full CRUD)
* DELETE /api/hyperfleet/v1/nodepools/{id} - Delete node pool (full CRUD)
* DELETE /api/hyperfleet/v1/clusters/{id}/statuses - Delete status (statuses are immutable)

### Implement cluster CREATE and READ endpoints (MVP)
* *PATCH* /api/hyperfleet/v1/clusters/{id} - Update cluster (full CRUD)
* *DELETE* /api/hyperfleet/v1/clusters/{id} - Delete cluster (full CRUD)

### Implement node pool CREATE and READ endpoints
* PATCH /api/hyperfleet/v1/clusters/{cluster_id}/nodepools/{id} - Update node pool (full CRUD)
* DELETE /api/hyperfleet/v1/clusters/{cluster_id}/nodepools/{id} - Delete node pool (full CRUD)

### Database schema
* generation will increment on PATCH operations (post-MVP)

## Status Aggregation System
### Aggregation configuration loader
* HYPERFLEET-28 This is closed and put to post-MVP, and need to discuss more

### Cluster status data model and types
* Granular Phases - Defer to post-MVP:
** No Pending, Provisioning, Degraded, Failed, Deleting phases
** MVP uses only Ready and NotReady

* AdapterState Enum - Not needed for MVP:
** Don't define AdapterState enum
** Adapter state is determined by conditions, not separate field

* Separate Status Table - Not needed for MVP:
** Don't create separate adapter_statuses table
** Use JSONB column in resource tables

* Cluster-Specific Condition Types - Defer to post-MVP:
** No AllAdaptersReady, ValidationPassed condition types
** MVP uses only Available, Applied, Health from adapters

### Adapter status reporting endpoint
* observed_generation Rejection - Defer to post-MVP:
** For MVP: Log warning but accept mismatches
** Don't return 409 Conflict for stale observed_generation
** Post-MVP can add strict validation

### Status aggregation tests
* Granular Phase Tests - MVP doesn't use:
** No test for phase=Pending
** No test for phase=Provisioning
** No test for phase=Failed
** No test for phase=Degraded
** Only test Ready and NotReady

* Phase Transition Tests - Phase not stored:
** No test for Ready → Failed transition
** No test for NotReady → Ready transition
** Phase computed fresh each GET, no history

* Stale observed_generation Tests - MVP accepts:
** Don't test 409 Conflict response
** For MVP: Accept mismatched generations
** Just test warning logged

* Concurrent Update Tests - Defer to post-MVP:
** No test for race conditions
** No test for concurrent POST requests
** JSONB updates are transactional (sufficient for MVP)

* Cluster-Level Condition Tests - Not in MVP:
** No test for AllAdaptersReady condition
** No test for ValidationPassed condition
** MVP returns adapter conditions directly

### Contract validation logic
* observed_generation Rejection - MVP accepts mismatches:
** Don't return 409 Conflict for stale generation
** Don't reject if observed_generation > resource.generation
** Just log warnings
** Post-MVP can add strict validation

* Adapter State Validation - Not in MVP contract:
** Don't validate "state" field (not in MVP contract)
** Don't validate "ready" boolean (not in MVP contract)
** MVP uses condition-based contract only

* Complex Condition Validation - Keep simple:
** Don't validate condition reason against enum
** Don't validate condition message format
** Just check required fields present

* Data Field Schema Validation - Too complex:
** Don't validate data field schema
** Adapters can put arbitrary JSON in data
** Basic JSON validity checked by parser

* Adapter Dependency Validation - Not in MVP:
** Don't check if adapter should wait for other adapters
** No dependency ordering validation
** All adapters run concurrently
