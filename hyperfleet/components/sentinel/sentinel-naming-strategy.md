---
Status: Active
Owner: HyperFleet Sentinel Team
Last Updated: 2025-12-04
---

# Naming Strategy for Multi-Tenant Isolation

> Defines the naming strategy for multi-tenant isolation in HyperFleet, covering how Sentinel instances, Kubernetes resources, and namespaces are named to prevent conflicts between tenants. Documents the naming conventions for Sentinel deployments, ConfigMaps, and the resources they create.

---

### Metadata
- **Date:** 2025-12-03
- **Authors:** Rafael Benevides
- **Related Jira(s):** [HYPERFLEET-283](https://issues.redhat.com/browse/HYPERFLEET-283)

---

## Table of Contents

- [What](#what)
- [Why](#why)
- [Topic Naming Strategy](#topic-naming-strategy)
  - [Topic Name Format](#topic-name-format)
  - [Examples](#examples)
- [Container Image Naming Strategy](#container-image-naming-strategy)
  - [Image Tag Format](#image-tag-format)
  - [Tagging Conventions](#tagging-conventions)
  - [Image Retention Policy](#image-retention-policy)
- [Related Documents](#related-documents)

---

## What

This document defines naming strategies for Sentinel and HyperFleet components to enable multi-tenant and isolated deployments. It covers:

1. **Pub/Sub Topic Naming**: How to isolate message broker topics between tenants in shared development environments
2. **Container Image Naming**: How to tag and organize container images to avoid collisions between developers

---

## Why

In shared development environments (e.g., hyperfleet-dev cluster), multiple developers testing simultaneously can cause message interference if all Sentinels publish to the same topics. By using the namespace and resource type in topic names, each developer or team can isolate their message flows at the topic level, preventing events from one developer's Sentinel from being consumed by another's adapters.

For container images, without clear naming conventions, developers can accidentally overwrite each other's images when pushing to the same registry.

---

## Topic Naming Strategy

### Topic Name Format

```text
{namespace}-{resourceType}
```

Where:
- `namespace`: The Kubernetes namespace where Sentinel is deployed
- `resourceType`: The resource type being watched (`clusters` or `nodepools`)

The topic name is configured via the `BROKER_TOPIC` environment variable. When using Helm, the default is automatically constructed from the namespace and resource type.

### Configuration

The topic name is configured via:

- **Helm**: `broker.topic` value (default: `{namespace}-{resourceType}`)
- **Environment Variable**: `BROKER_TOPIC` (for local development)

### Examples

| Namespace | Resource Type | Topic Name |
|-----------|---------------|------------|
| `hyperfleet-system` | `clusters` | `hyperfleet-system-clusters` |
| `hyperfleet-dev-rafael` | `clusters` | `hyperfleet-dev-rafael-clusters` |
| `hyperfleet-dev-rafael` | `nodepools` | `hyperfleet-dev-rafael-nodepools` |
| `team-a` | `clusters` | `team-a-clusters` |

---

## Container Image Naming Strategy

### Image Tag Format

```text
{registry}/{organization}/{component}:{tag}
```

Where:
- `registry`: Container registry (e.g., `quay.io`)
- `organization`: Organization name (e.g., `hyperfleet`)
- `component`: Component name (e.g., `sentinel`, `adapter-validation`)
- `tag`: Version or build identifier

### Tagging Conventions

| Environment | Tag Format | Example |
|-------------|------------|---------|
| Development | `{namespace}-{git-sha-short}` | `sentinel:hyperfleet-dev-a1b2c3d` |
| Production | `v{semver}` | `sentinel:v1.2.3` |

The namespace prefix in development tags prevents collisions when multiple developers push images from different environments.

### Image Retention Policy

| Tag Type | Retention |
|----------|-----------|
| `v*` (releases) | Keep forever |
| Development tags | Delete after 30 days |

---

## Related Documents

- [Sentinel Architecture](./sentinel.md) - Main Sentinel documentation
- [Sentinel Versioning](./sentinel-versioning.md) - Versioning strategy
