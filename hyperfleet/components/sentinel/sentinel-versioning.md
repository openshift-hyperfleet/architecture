---
Status: Active
Owner: HyperFleet Sentinel Team
Last Updated: 2025-12-03
---

# HyperFleet Sentinel Versioning Strategy

> Defines the versioning strategy for the HyperFleet Sentinel service, covering binary versioning, configuration versioning, and compatibility guarantees with the HyperFleet API and Adapters. Establishes how Sentinel versions are incremented and how backward compatibility is maintained during upgrades.

---

## *Define versioning strategy for Sentinel to enable independent evolution while maintaining compatibility with HyperFleet API and Adapters*

**Metadata**
- **Date:** 2025-10-30
- **Authors:** Alex Vulaj
- **Related Jira(s):** [HYPERFLEET-65](https://issues.redhat.com/browse/HYPERFLEET-65)

---

## 1. Overview

**What is Sentinel?**

Sentinel is a polling service that:
1. Fetches cluster data from the HyperFleet API
2. Publishes reconciliation events to a message broker
3. Events are in CloudEvents 1.0 format
4. Adapters consume these events and perform provisioning tasks

This document defines Sentinel's versioning strategy, including event schema evolution and compatibility with both the API and adapters.

---

## 2. Sentinel Versioning Scheme

**Sentinel Service:** This component uses semantic versioning with the following criteria:
- **MAJOR**: Breaking schema changes, breaking configuration changes
- **MINOR**: New features, new optional schema fields, new event types
- **PATCH**: Bug fixes, performance improvements, no schema changes

**CloudEvents Schema: Coupled to Sentinel MAJOR.MINOR**
- Schema version = Sentinel MAJOR.MINOR (e.g., Sentinel v1.2.3 publishes schema `1.2`)
- PATCH versions never change the schema
- Schema version included in every event for adapter compatibility detection

**Example:**
```
Sentinel v1.0.0 → publishes CloudEvents with schema 1.0
Sentinel v1.2.5 → publishes CloudEvents with schema 1.2
Sentinel v2.0.0 → publishes CloudEvents with schema 2.0
```

---

## 3. Schema Evolution Rules

### MAJOR version bumps (breaking changes):
- Removing fields
- Changing field types (e.g., string → enum)
- Renaming fields
- Changing field semantics

### MINOR version bumps (additive changes):
- Adding new optional fields
- Adding new event types
- Expanding enum values (if backwards compatible)

### PATCH version bumps:
- Bug fixes in event publishing logic
- Performance improvements
- No schema changes allowed

---

## 4. AsyncAPI Specification Versioning

**AsyncAPI spec is source of truth for event schema:**
- AsyncAPI spec version = Sentinel MAJOR.MINOR (e.g., Sentinel v1.2.3 uses AsyncAPI spec `1.2`)
- Spec changes → Adapters regenerate event structs (similar to API client generation from OpenAPI)
- Adapters can advance without spec changes (adapter-only bug fixes)

**Spec version coupling:**
- Sentinel MAJOR.MINOR determines AsyncAPI spec version
- PATCH versions never change the spec
- Breaking changes to AsyncAPI spec require Sentinel MAJOR bump
- Adapters generate event structs from AsyncAPI spec and expose supported schema versions via metadata endpoint

**Rationale:** AsyncAPI spec defines the contract between Sentinel and Adapters. Coupling spec version to Sentinel MAJOR.MINOR ensures schema version consistency and enables adapters to detect compatibility.

**Example AsyncAPI spec evolution:**
```
asyncapi-1.0.yaml → Sentinel v1.0.x, v1.1.x
asyncapi-1.2.yaml → Sentinel v1.2.x, v1.3.x (added optional field)
asyncapi-2.0.yaml → Sentinel v2.0.x (breaking change: enum for reason field)
```

---

## 5. Sentinel ↔ HyperFleet API Compatibility

**Single API version targeting:**
- Sentinel targets ONE HyperFleet API version at a time
- API version determined by the imported API client library
- No need for Sentinel to support multiple API versions simultaneously

**For MVP:**
- Sentinel imports API client code from API repository or uses generated OpenAPI client
- Example: `import "github.com/openshift-hyperfleet/hyperfleet-api/pkg/client"`
- Version coupling: Sentinel v1.x.x imports API v1 client, Sentinel v2.x.x imports API v2 client

**When API version changes:**
1. New API major version released (e.g., v2 launches)
2. Update Sentinel's `go.mod` to import API v2 client library
3. Update Sentinel code to handle any API changes
4. Rebuild and deploy updated Sentinel
5. Adapters continue working (event schema unchanged)

**Rationale:** Cluster fetch endpoints are unlikely to change frequently. When they do, Sentinel can be updated and redeployed independently without affecting adapters.

---

## 6. Sentinel ↔ Adapter Version Independence

**Goal:** Independent deployment within schema compatibility constraints

**Adapter Schema Support:**
- Each adapter documents which event schema versions it supports
- Adapters MUST ignore unknown fields (forward compatibility)
- Adapters must support multiple event schema versions during transitions

**Compatibility Matrix Example:**
```
Sentinel v1.0.0 → publishes schema 1.0
Sentinel v1.1.0 → publishes schema 1.1 (added optional "priority" field)
Sentinel v2.0.0 → publishes schema 2.0 (changed "reason" from string to enum)

Adapter v1.0.0 → supports schema 1.0
Adapter v1.1.0 → supports schema 1.0, 1.1
Adapter v2.0.0 → supports schema 1.1, 2.0 (for migration period)
Adapter v2.1.0 → supports schema 2.0 only (dropped old schema support)
```

---

## 7. Handling Breaking Changes: Expand-Contract Pattern

When Sentinel introduces a breaking schema change (MAJOR version bump), use the **expand-contract pattern**:

### Phase 1: Expand
- Adapters deploy new version supporting both old and new schemas
- All adapters must support new schema before Sentinel upgrade
- Adapters can still process old schema events (backwards compatible)

### Phase 2: Switch
- Deploy new Sentinel version publishing new schema
- Adapters receive events in new schema format
- Adapters process using new schema handlers

### Phase 3: Contract
- After all events in old schema are processed
- Adapters remove old schema support in next release
- Clean up backwards compatibility code

**Key principle:** Consumers (adapters) adapt first, then producers (Sentinel) change.

**Timeline example:**
```
Week 0: Sentinel v1.5.0 publishing schema 1.5
Week 1: Deploy Adapter v2.0.0 supporting schemas 1.5 and 2.0
Week 2: All adapters updated to v2.0.0
Week 3: Deploy Sentinel v2.0.0 publishing schema 2.0
Week 4+: Monitor, verify all adapters processing successfully
Month 3: Deploy Adapter v2.1.0 removing schema 1.5 support (contract phase)
```

---

## 8. Version Metadata Exposure

**Sentinel exposes version information via:**

**Internal HTTP endpoints** (can be disabled via flag for security-sensitive deployments):
- Health/readiness endpoints for Kubernetes liveness and readiness probes
- Prometheus metrics endpoint exposing version labels
- Metadata endpoint (internal-only) returning service version, git SHA, and build timestamp

**Container image tags:**
```
quay.io/openshift-hyperfleet/sentinel:v1.2.3                  # Semantic version (production)
quay.io/openshift-hyperfleet/sentinel:hyperfleet-dev-a1b2c3d  # Namespace + SHA (development)
```

> **Note:** For detailed image tagging conventions, see [Naming Strategy](./sentinel-naming-strategy.md#container-image-naming-strategy).

**Kubernetes pod labels and annotations:**
```yaml
labels:
  app.kubernetes.io/version: "1.2.3"
annotations:
  hyperfleet.io/schema-version: "1.2"
```

**CloudEvents metadata:**
Sentinel includes `schemaversion` field in all published events:
```json
{
  "specversion": "1.0",
  "type": "com.redhat.hyperfleet.cluster.reconcile.v1",
  "source": "sentinel",
  "schemaversion": "1.2",
  "data": { ... }
}
```

**Service metrics and logs:**
- Metrics include version labels for filtering/grouping
- Logs include version in structured logging context

---

## References

- [HyperFleet Architecture Summary](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/README.md)
- [AsyncAPI Specification](https://www.asyncapi.com/docs/reference/specification)
- [CloudEvents 1.0 Specification](https://cloudevents.io/)
- [Semantic Versioning 2.0.0](https://semver.org/)
