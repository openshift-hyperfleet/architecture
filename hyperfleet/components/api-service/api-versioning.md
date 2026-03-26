---
Status: Active
Owner: HyperFleet API Team
Last Updated: 2025-12-30
---

# HyperFleet API Versioning Strategy
- **Date:** 2025-10-30
- **Related Jira(s):** [HYPERFLEET-65](https://issues.redhat.com/browse/HYPERFLEET-65)

## 1. Overview & Principles

### What

This document defines the versioning strategy for the **HyperFleet API** - the REST API serving external partners and public consumers. This strategy enables:
- Independent API evolution
- Safe upgrades and rollbacks
- Clear backwards compatibility guarantees
- Predictable partner migration paths

### Semantic Versioning Principles

The HyperFleet API uses semantic versioning (MAJOR.MINOR.PATCH):
- **MAJOR**: Breaking changes that require consumer updates
- **MINOR**: Backwards-compatible new functionality
- **PATCH**: Backwards-compatible bug fixes

**What constitutes a breaking change for the API:**
- Removing endpoints
- Removing fields from responses
- Adding required fields to requests
- Changing field types
- Changing endpoint behavior in non-backwards-compatible ways

**Note:** For container image tagging strategy and release management, see [Git and Release Strategy](../../docs/test-release/git-and-release-strategy.md).

---

## 2. API Versioning (External Contract)

### Versioning Scheme

**URI-based versioning with explicit version requirement**

**API Path Structure:**
```
/api/hyperfleet/{version}/{resource}
```

**Examples:**
```
/api/hyperfleet/v1/clusters
/api/hyperfleet/v1/clusters/{id}
/api/hyperfleet/v2/clusters
/api/hyperfleet/v2/adapters/{id}/status
```

**Version Format:**
- **MAJOR version only in path**: `v1`, `v2`, `v3`
- **Full semantic version**: MAJOR.MINOR.PATCH (e.g., `1.2.3`)

This component uses semantic versioning with the following criteria:
- **MAJOR**: Breaking changes (removing fields, changing types, adding required fields)
- **MINOR**: Additive changes (new endpoints, new optional fields)
- **PATCH**: Bug fixes, no API contract changes

**Rationale for path structure:**
- Follows existing precedent (e.g., `/api/clusters_mgmt/v1/...`, `/api/account_mgmt/v1/...`)
- Namespaced under `/api/hyperfleet/` to distinguish from other services
- Version is explicit in path for clarity and routing simplicity
- MAJOR version only in URL (MINOR/PATCH are backwards compatible, don't need URL changes)

### Version Negotiation and Routing

**Version is REQUIRED** - All API requests MUST explicitly include the version in the path.

**Valid requests:**
```
GET /api/hyperfleet/v1/clusters
POST /api/hyperfleet/v2/clusters
GET /api/hyperfleet/v1/clusters/abc-123
```

**Error response format:**

Error responses follow [RFC 9457 Problem Details](../../standards/error-model.md) format:

```http
HTTP/1.1 404 Not Found
Content-Type: application/problem+json

{
  "type": "https://api.hyperfleet.io/errors/resource-not-found",
  "title": "Resource Not Found",
  "status": 404,
  "detail": "API version 'v5' is not supported.",
  "instance": "/api/hyperfleet/v5/clusters",
  "code": "HYPERFLEET-NTF-005",
  "supported_versions": ["v1", "v2"]
}
```

**Routing Implementation:**
- Path-based routing at gateway level
- Each MAJOR version is a separate deployment (e.g., `hyperfleet-api-v1`, `hyperfleet-api-v2`)
- Gateway/load balancer routes requests based on `/api/hyperfleet/{version}/` prefix
- Separate deployments enable independent scaling, rollbacks, and fault isolation

**Why require an explicit version?**
- **Clarity:** No ambiguity about which API version is being used
- **Safety:** Prevents accidental use of wrong version
- **Logging/Metrics:** Easy to track which versions are in use
- **Team precedent:** Matches existing services (clusters_mgmt, account_mgmt)

### Backwards Compatibility Rules

**Allowed within a MAJOR version (additive changes):**
- New optional fields
- New endpoints

**Not allowed within a MAJOR version (breaking changes require MAJOR bump):**
- Making optional fields required
- Removing fields
- Changing field types

**Field Addition Strategy:**
- New fields in MINOR versions: Always optional, never required
- New required fields: Only allowed in MAJOR versions
- Document defaults clearly for all optional fields

**Example Evolution:**
```
v1.0.0: Initial release with core required fields
v1.1.0: Add optional "metadata" field
v1.2.0: Add new /health endpoint, add optional "tags" field
v2.0.0: Remove deprecated field, make "metadata" required, change "status" from string to enum
```

### Service Version Coupling to API Version

**Critical principle:** Service MAJOR version = API MAJOR version it serves

**Version relationship (separate deployments):**
- Service `1.x.x` → deployed as `hyperfleet-api-v1` → serves **API v1 only**
- Service `2.x.x` → deployed as `hyperfleet-api-v2` → serves **API v2 only**
- Service `3.x.x` → deployed as `hyperfleet-api-v3` → serves **API v3 only**

**Why couple service MAJOR to API MAJOR?**
- Clear signal: Service `2.0.0` means "this deployment serves API v2"
- Semantic: Service MAJOR bump = new API version deployment
- Simple: Service version tells you which API version that deployment serves

**Service MINOR/PATCH bumps:**
- **MINOR**: New features that don't change API contract (e.g., performance improvements, new internal metrics)
- **PATCH**: Bug fixes, security patches

**Key takeaway:** Each service deployment serves ONE API major version. Support for multiple API versions (N and N-1) during deprecation windows is achieved by running two separate deployments concurrently.

### Version Metadata Exposure

**HyperFleet API exposes version information via two endpoints:**

**Health Endpoint (`/api/hyperfleet/health`):** Fast status check for orchestrators and load balancers. Returns HTTP 200 OK when healthy, HTTP 503 Service Unavailable when unhealthy.

**Metadata Endpoint (`/api/hyperfleet/metadata`):** Comprehensive service information for debugging and operations. Returns service version, supported API versions, git SHA, and build timestamp.

**Example metadata response:**
```json
{
  "service": "hyperfleet-api",
  "version": "1.2.3",
  "api_versions": ["v1"],
  "git_sha": "a1b2c3d4e5f6",
  "build_timestamp": "2025-10-30T14:30:00Z"
}
```

---

## References

- [HyperFleet Architecture Summary](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/README.md)
- [HyperFleet Error Model and Codes Standard](../../standards/error-model.md)
- [Semantic Versioning 2.0.0](https://semver.org/)
