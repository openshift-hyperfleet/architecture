---
Status: Active
Owner: HyperFleet Adapter Team
Last Updated: 2025-11-05
---

# HyperFleet Adapter Versioning Strategy
- **Date:** 2025-10-30
- **Related Jira(s):** [HYPERFLEET-65](https://issues.redhat.com/browse/HYPERFLEET-65)

## 1. Overview

> Defines the versioning strategy for HyperFleet Adapters, covering binary versioning, configuration versioning, and compatibility guarantees with Sentinel and the HyperFleet API. Establishes how adapter versions are incremented, what constitutes a breaking change, and how backward compatibility is maintained during upgrades.

**What are Adapters?**

Adapters are event-driven services that:
1. Consume CloudEvents from Sentinel
2. Execute provisioning tasks (e.g., create DNS records, provision infrastructure)
3. Report status back to the HyperFleet API

Adapters use a **config-driven deployment model** - a single binary is deployed multiple times with different configurations to support different adapter types (DNS, infrastructure, validation, etc.).

This document defines the versioning strategy for both the adapter **binary** and the adapter **configs**.

---

## 2. Adapter Binary Versioning

### Versioning Scheme

**Adapter Binary:** This component uses semantic versioning with the following criteria:
- **MAJOR**: Breaking changes to config schema, breaking event schema support, breaking API interactions
- **MINOR**: New adapter types, new config options, new event schema support (additive)
- **PATCH**: Bug fixes, performance improvements, no config or schema changes

**Example:**
```
v1.0.0: Initial adapter binary supporting DNS and validation adapter types
v1.1.0: Add support for infrastructure adapter type (new adapter type = MINOR)
v1.1.1: Fix bug in DNS record creation (bug fix = PATCH)
v2.0.0: Change config schema format from YAML to custom format (breaking = MAJOR)
```

---

## 3. Adapter Config Versioning

### Overview

**Critical concept:** Config version is **independent** from binary version.

Adapters are deployed as a single binary with different configurations:
- Each deployment has its own config (e.g., DNS adapter config, infrastructure adapter config)
- Configs are packaged and versioned separately as Helm charts
- **Config version != Binary version**

### Config Schema Versioning

**Config Schema: Coupled to Adapter Binary MAJOR.MINOR**
- Config schema version = Adapter Binary MAJOR.MINOR (e.g., Adapter v1.2.3 uses config schema `1.2`)
- PATCH versions of the binary never change the config schema
- Each config deployment includes schema version for validation
- Same binary can be deployed with multiple different configs

**Example:**
```
Adapter Binary v1.2.5 uses Config Schema 1.2
  ├─ DNS Adapter Config v0.5.2 (uses schema 1.2)
  ├─ Infrastructure Adapter Config v0.3.1 (uses schema 1.2)
  └─ Validation Adapter Config v1.0.0 (uses schema 1.2)
```

### Config Evolution Rules

**MAJOR version bumps (breaking config changes):**
- Removing required config fields
- Changing field types
- Renaming fields
- Changing field semantics

**MINOR version bumps (additive config changes):**
- Adding new optional config fields
- Adding support for new adapter types
- Adding new broker types

**PATCH version bumps:**
- Bug fixes
- Performance improvements
- No config schema changes

### Config Packaging and Distribution

**Helm Chart Versioning:**
- Each adapter config is packaged as a Helm chart
- Helm chart version follows semantic versioning independently
- Chart version != Binary version != Schema version

**Example deployment manifest:**
```yaml
# DNS Adapter Helm Chart v0.5.2
apiVersion: v1
kind: ConfigMap
metadata:
  name: dns-adapter-config
  labels:
    hyperfleet.io/config-version: "0.5.2"
    hyperfleet.io/schema-version: "1.2"
    hyperfleet.io/binary-version: "1.2.5"
data:
  config.yaml: |
    schemaVersion: "1.2"
    adapterType: dns
    broker:
      type: rabbitmq
      url: amqp://rabbitmq:5672
    dns:
      provider: route53
      zoneId: Z1234567890ABC
```

**Key relationships:**
```
DNS Adapter Config v0.5.2
  ├─ Uses Config Schema 1.2 (from Binary v1.2.x)
  ├─ Deployed with Binary v1.2.5
  └─ Packaged as Helm Chart v0.5.2
```

### Version Independence Example

**Scenario:** Same binary, different config versions

```
Adapter Binary v1.2.5 is deployed 3 times:

Deployment 1: DNS Adapter
  - Binary: v1.2.5
  - Config: DNS Adapter Config v0.5.2
  - Schema: 1.2

Deployment 2: Infrastructure Adapter
  - Binary: v1.2.5
  - Config: Infrastructure Adapter Config v0.3.1
  - Schema: 1.2

Deployment 3: Validation Adapter
  - Binary: v1.2.5
  - Config: Validation Adapter Config v1.0.0
  - Schema: 1.2
```

**Why different config versions?**
- Each adapter type evolves independently
- DNS config might need frequent updates for new DNS providers
- Infrastructure config might be stable
- Validation config might add new validation checks

### Testing Matrix

**Critical requirement:** Test matrix must cover **binaries × configs × platforms**

**Example test matrix:**
```
Binary Versions: v1.2.4, v1.2.5, v1.3.0
Config Versions (DNS): v0.5.1, v0.5.2, v0.6.0
Config Versions (Infra): v0.3.0, v0.3.1
Platforms: GCP, AWS

Test Coverage:
✓ Binary v1.2.5 + DNS Config v0.5.2 + GCP
✓ Binary v1.2.5 + DNS Config v0.5.2 + AWS
✓ Binary v1.2.5 + Infra Config v0.3.1 + GCP
✓ Binary v1.3.0 + DNS Config v0.6.0 + AWS
... etc
```

**Why this matters:**
- Config changes might work with one binary version but break with another
- Platform-specific behavior might differ
- Helm chart upgrades need validation across supported binary versions

---

## 4. Adapter ↔ Sentinel Compatibility (Event Consumption)

**Adapters consume CloudEvents published by Sentinel** - see [Sentinel Versioning Strategy](../sentinel/sentinel-versioning.md) for full details on event schema versioning.

**Adapter implementation requirements:**
- **AsyncAPI code generation**: Event structs are generated from AsyncAPI schema (similar to API client generation from OpenAPI)
- **Schema version from spec**: Schema version embedded in generated code from AsyncAPI spec file
- **Multi-schema support**: Adapters must support multiple event schema versions during transitions
- **Forward compatibility**: Adapters MUST ignore unknown fields in events

**Schema support documentation:**
Each adapter version documents supported event schemas in its release notes and exposes schema version via metadata endpoint:

```
Adapter Binary v1.0.0 → supports Sentinel schema 1.0
Adapter Binary v1.1.0 → supports Sentinel schema 1.0, 1.1
Adapter Binary v2.0.0 → supports Sentinel schema 1.1, 2.0 (for migration)
Adapter Binary v2.1.0 → supports Sentinel schema 2.0 only
```

**Coordinated updates for breaking changes:**
When Sentinel introduces a breaking event schema change, follow the expand-contract pattern (see Sentinel Versioning Strategy).

---

## 5. Adapter ↔ HyperFleet API Compatibility

**Adapters interact with HyperFleet API for READ and WRITE operations:**
- Fetch cluster details (READ)
- Report adapter status and provisioning results (WRITE)

**Adapter status report payloads:**
- When adapters report status or provisioning results, they POST/PUT to HyperFleet API endpoints
- Status payload structure follows the API schema version from the imported API client library

**API version targeting:**
- Adapters target ONE HyperFleet API version at a time
- API version determined by the imported client library in `go.mod`
- No need to support multiple API versions simultaneously

**For MVP:**
- Adapters import API client code from API repository or use generated OpenAPI client
- Example: `import "github.com/openshift-hyperfleet/hyperfleet-api/pkg/client"`
- Version coupling: Adapter Binary v1.x.x imports API v1 client, Adapter Binary v2.x.x imports API v2 client

**When API version changes:**
1. New API major version released (e.g., v2 launches)
2. Update Adapter Binary's `go.mod` to import API v2 client library
3. Update Adapter Binary code to handle any API changes
4. Rebuild and deploy updated Adapter Binary
5. Configs continue working (no config changes needed if only API client changed)

**Rationale:** Cluster status endpoints are unlikely to change frequently. When they do, the adapter binary can be updated and redeployed independently.

---

## 6. Version Metadata Exposure

**Adapters expose version information via:**

**Internal HTTP endpoints** (can be disabled via flag for security-sensitive deployments):
- Health/readiness endpoints for Kubernetes liveness and readiness probes
- Prometheus metrics endpoint exposing version labels
- Metadata endpoint (internal-only) returning binary version, config version, schema version, git SHA, and build timestamp

**Example metadata response:**
```json
{
  "service": "hyperfleet-adapter",
  "binary_version": "1.2.5",
  "config_version": "0.5.2",
  "config_schema_version": "1.2",
  "adapter_type": "dns",
  "supported_event_schemas": ["1.0", "1.1", "1.2"],
  "git_sha": "a1b2c3d4e5f6",
  "build_timestamp": "2025-10-30T14:30:00Z"
}
```

**Container image tags:**
```
quay.io/openshift-hyperfleet/adapter:1.2.5      # Binary semantic version
quay.io/openshift-hyperfleet/adapter:a1b2c3d    # Git SHA
```

**Kubernetes pod labels and annotations:**
```yaml
labels:
  app.kubernetes.io/version: "1.2.5"                    # Binary version
  hyperfleet.io/adapter-type: "dns"
  hyperfleet.io/config-version: "0.5.2"                 # Config version
annotations:
  hyperfleet.io/config-schema-version: "1.2"
  hyperfleet.io/supported-event-schemas: "1.0,1.1,1.2"
```

---

## 7. Deployment Recommendations

### Config Version Bumping Guidelines

**When to bump config version:**
- **MAJOR**: Breaking changes to adapter-specific config (e.g., changing DNS provider field structure)
- **MINOR**: New optional fields, new features (e.g., adding support for new DNS record types)
- **PATCH**: Bug fixes, documentation updates, no functional changes

**Example: DNS Adapter Config evolution:**
```
v0.1.0: Initial DNS adapter config
v0.2.0: Add support for CloudFlare provider (new optional field)
v0.2.1: Fix typo in Route53 example
v1.0.0: Stable release after testing
v1.1.0: Add support for CNAME records (new feature)
v2.0.0: Rename "zoneId" to "hostedZoneId" (breaking change)
```

### Binary and Config Compatibility Matrix

**Supported combinations:**
```
Binary v1.2.x supports Config Schema 1.2
  ├─ DNS Config v0.5.x ✓
  ├─ DNS Config v0.6.x ✓
  ├─ Infra Config v0.3.x ✓
  └─ Validation Config v1.0.x ✓

Binary v1.3.x supports Config Schema 1.3
  ├─ DNS Config v0.7.x ✓ (updated for new schema)
  ├─ DNS Config v0.5.x ✗ (old schema, incompatible)
  └─ Infra Config v0.4.x ✓ (updated for new schema)
```

**Rule:** Config schema version MUST match Binary schema version (Binary MAJOR.MINOR).

---

## References

- [HyperFleet Architecture Summary](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/README.md)
- [Sentinel Versioning Strategy](../sentinel/sentinel-versioning.md)
- [API Versioning Strategy](../api-service/api-versioning.md)
- [Semantic Versioning 2.0.0](https://semver.org/)
- [Helm Chart Best Practices](https://helm.sh/docs/chart_best_practices/)
