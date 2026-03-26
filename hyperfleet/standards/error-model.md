---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-01-02
---

# HyperFleet Error Model and Codes Standard


## Overview

This document defines the standard error model and error codes for all HyperFleet components (API, Sentinel, Adapters), following [RFC 9457 - Problem Details for HTTP APIs](https://www.rfc-editor.org/rfc/rfc9457.html).

### Goals

- **Standards Compliance**: Follow RFC 9457 for interoperability
- **Consistency**: All components return errors in the same structure
- **Machine-Readable**: Error types enable programmatic error handling
- **Actionable**: Error messages help users understand and resolve issues
- **Traceable**: Errors include correlation IDs for debugging

### Non-Goals

- Defining retry policies (handled by individual components)

### Reference Implementation

A shared Go library implementing this standard will be available at:

**Repository:** `github.com/openshift-hyperfleet/hyperfleet-errors` *(planned - see [HYPERFLEET-415](https://issues.redhat.com/browse/HYPERFLEET-415))*

The library will provide:
- `ProblemDetails` struct following RFC 9457
- Pre-defined error constructors for each error category
- HTTP response writer helpers
- Error parsing utilities for clients

---

## RFC 9457 Problem Details

HyperFleet APIs MUST return errors using the [RFC 9457](https://www.rfc-editor.org/rfc/rfc9457.html) "Problem Details" format with the `application/problem+json` media type.

### Basic Structure

```json
{
  "type": "https://api.hyperfleet.io/errors/validation-error",
  "title": "Validation Error",
  "status": 400,
  "detail": "Cluster name is required",
  "instance": "/api/hyperfleet/v1/clusters"
}
```

### Standard Fields (RFC 9457)

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | URI | Yes | URI reference identifying the problem type |
| `title` | string | Yes | Short, human-readable summary of the problem type |
| `status` | integer | Yes | HTTP status code (100-599) |
| `detail` | string | Yes | Human-readable explanation specific to this occurrence |
| `instance` | URI | No | URI reference identifying the specific occurrence |

### HyperFleet Extension Fields

In addition to RFC 9457 standard fields, HyperFleet errors include these extension fields:

| Field | Type | Description |
|-------|------|-------------|
| `code` | string | Machine-readable error code (e.g., `HYPERFLEET-VAL-001`) |
| `timestamp` | string | RFC3339 timestamp when error occurred |
| `trace_id` | string | Distributed trace ID for correlation |
| `errors` | array | Validation errors array (for multiple errors) |

### Complete Example

```http
HTTP/1.1 400 Bad Request
Content-Type: application/problem+json

{
  "type": "https://api.hyperfleet.io/errors/validation-error",
  "title": "Validation Error",
  "status": 400,
  "detail": "Cluster name is required",
  "instance": "/api/hyperfleet/v1/clusters",
  "code": "HYPERFLEET-VAL-001",
  "timestamp": "2025-01-15T10:30:00.123Z",
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736"
}
```

---

## Problem Types

Each problem type is identified by a URI. HyperFleet defines the following problem types:

### Type URI Format

```text
https://api.hyperfleet.io/errors/{problem-type}
```

### Registered Problem Types

| Type URI | Title | HTTP Status | Category | Description |
|----------|-------|-------------|----------|-------------|
| `.../validation-error` | Validation Error | 400, 422 | `VAL` | Request validation failed (syntactic or semantic) |
| `.../invalid-request` | Invalid Request | 400 | `VAL` | Malformed request body |
| `.../authentication-required` | Authentication Required | 401 | `AUT` | No credentials provided |
| `.../invalid-credentials` | Invalid Credentials | 401 | `AUT` | Credentials invalid or expired |
| `.../permission-denied` | Permission Denied | 403 | `AUZ` | Insufficient permissions |
| `.../resource-not-found` | Resource Not Found | 404 | `NTF` | Requested resource doesn't exist |
| `.../resource-conflict` | Resource Conflict | 409 | `CNF` | Resource state conflict |
| `.../version-conflict` | Version Conflict | 409 | `CNF` | Optimistic locking failure |
| `.../rate-limit-exceeded` | Rate Limit Exceeded | 429 | `LMT` | Too many requests |
| `.../internal-error` | Internal Error | 500 | `INT` | Unexpected server error |
| `.../service-unavailable` | Service Unavailable | 503 | `SVC` | Service temporarily unavailable |
| `.../upstream-error` | Upstream Error | 502, 504 | `SVC` | Upstream service failure (bad gateway or timeout) |

---

## Error Code Format

In addition to RFC 9457 `type` URIs, HyperFleet uses machine-readable error codes for programmatic handling.

### Format

```text
HYPERFLEET-{CATEGORY}-{NUMBER}
```

- `HYPERFLEET`: Prefix identifying HyperFleet errors
- `{CATEGORY}`: 3-letter category code
- `{NUMBER}`: 3-digit sequential number within category

### Error Categories

| Category | Name | HTTP Status | Description |
|----------|------|-------------|-------------|
| `VAL` | Validation | 400, 422 | Request validation failures (syntactic and semantic) |
| `AUT` | Authentication | 401 | Authentication failures |
| `AUZ` | Authorization | 403 | Authorization/permission failures |
| `NTF` | Not Found | 404 | Resource not found |
| `CNF` | Conflict | 409 | Resource conflicts |
| `LMT` | Rate Limit | 429 | Rate limiting exceeded |
| `INT` | Internal | 500 | Internal server errors |
| `SVC` | Service | 502, 503, 504 | Service unavailable or upstream failures |

---

## HTTP Status Code Mapping

Every HTTP status code listed below is mapped to an error category with a corresponding `HYPERFLEET-{CATEGORY}-{NUMBER}` code. This ensures all API errors are machine-readable and consistently categorized.

### Client Errors (4xx)

| HTTP Status | Category | When to Use | Example Scenario |
|-------------|----------|-------------|------------------|
| 400 Bad Request | `VAL` | Malformed request or validation failure | Missing required field, invalid JSON |
| 401 Unauthorized | `AUT` | Missing or invalid authentication | Expired token, no token provided |
| 403 Forbidden | `AUZ` | Valid auth but insufficient permissions | User lacks cluster:create permission |
| 404 Not Found | `NTF` | Resource doesn't exist | Cluster ID not found |
| 409 Conflict | `CNF` | Resource state conflict | Cluster name already exists, optimistic lock failure |
| 422 Unprocessable Entity | `VAL` | Semantically invalid request | Valid JSON but business rule violation |
| 429 Too Many Requests | `LMT` | Rate limit exceeded | Too many API calls |

### Server Errors (5xx)

| HTTP Status | Category | When to Use | Example Scenario |
|-------------|----------|-------------|------------------|
| 500 Internal Server Error | `INT` | Unexpected server error | Unhandled exception, bug |
| 502 Bad Gateway | `SVC` | Upstream service returned invalid response | GCP API returned malformed data |
| 503 Service Unavailable | `SVC` | Service temporarily unavailable | Database connection failed, dependency down |
| 504 Gateway Timeout | `SVC` | Upstream service timeout | GCP API call timed out |

### Mapping Policy

- **400 vs 422**: Use 400 for syntactic errors (malformed JSON, missing fields). Use 422 for semantic errors (valid JSON but violates business rules). Both map to category `VAL`.
- **502/503/504**: All upstream and service availability errors map to category `SVC`. The specific HTTP status indicates the nature of the failure (bad response, unavailable, timeout).

---

## Validation Errors

For validation errors, use the `errors` extension field to provide detailed information about each validation failure.

### Single Validation Error

```http
HTTP/1.1 400 Bad Request
Content-Type: application/problem+json

{
  "type": "https://api.hyperfleet.io/errors/validation-error",
  "title": "Validation Error",
  "status": 400,
  "detail": "Cluster name is required",
  "instance": "/api/hyperfleet/v1/clusters",
  "code": "HYPERFLEET-VAL-001",
  "timestamp": "2025-01-15T10:30:00.123Z",
  "errors": [
    {
      "field": "spec.name",
      "value": null,
      "constraint": "required",
      "message": "Cluster name is required"
    }
  ]
}
```

### Multiple Validation Errors

```http
HTTP/1.1 400 Bad Request
Content-Type: application/problem+json

{
  "type": "https://api.hyperfleet.io/errors/validation-error",
  "title": "Validation Error",
  "status": 400,
  "detail": "Request validation failed with 3 errors",
  "instance": "/api/hyperfleet/v1/clusters",
  "code": "HYPERFLEET-VAL-000",
  "timestamp": "2025-01-15T10:30:00.123Z",
  "errors": [
    {
      "field": "spec.name",
      "value": "",
      "constraint": "required",
      "message": "Cluster name is required"
    },
    {
      "field": "spec.region",
      "value": "invalid-region",
      "constraint": "enum",
      "allowed_values": ["us-central1", "us-east1", "europe-west1"],
      "message": "Region must be one of the allowed values"
    },
    {
      "field": "spec.node_count",
      "value": -1,
      "constraint": "min",
      "min_value": 1,
      "message": "Node count must be at least 1"
    }
  ]
}
```

### Validation Constraint Types

| Constraint | Description | Additional Fields |
|------------|-------------|-------------------|
| `required` | Field is required | - |
| `min` | Minimum value | `min_value` |
| `max` | Maximum value | `max_value` |
| `min_length` | Minimum string length | - |
| `max_length` | Maximum string length | - |
| `pattern` | Regex pattern match | `pattern` |
| `enum` | Value must be in list | `allowed_values` |
| `format` | Format validation (email, uuid, etc.) | `format` |
| `unique` | Value must be unique | - |

---

## Standard Error Codes

### Validation Errors (VAL)

| Code | Title | Description |
|------|-------|-------------|
| `HYPERFLEET-VAL-000` | Validation Error | Multiple validation errors (catch-all) |
| `HYPERFLEET-VAL-001` | Required Field Missing | A required field was not provided |
| `HYPERFLEET-VAL-002` | Invalid Field Value | Field value doesn't meet constraints |
| `HYPERFLEET-VAL-003` | Invalid Request Body | Request body is not valid JSON |
| `HYPERFLEET-VAL-004` | Invalid Query Parameter | Query parameter is invalid |
| `HYPERFLEET-VAL-005` | Invalid Path Parameter | Path parameter is invalid |

> **Note:** `VAL-000` is reserved as the catch-all code for responses containing multiple validation errors. Use specific codes (`VAL-001`, `VAL-002`, etc.) for single-field errors, and `VAL-000` when reporting multiple distinct field failures in the `errors` array.

### Authentication Errors (AUT)

| Code | Title | Description |
|------|-------|-------------|
| `HYPERFLEET-AUT-001` | Authentication Required | No authentication credentials provided |
| `HYPERFLEET-AUT-002` | Invalid Credentials | Credentials are invalid or expired |
| `HYPERFLEET-AUT-003` | Token Expired | Authentication token has expired |
| `HYPERFLEET-AUT-004` | Token Malformed | Token format is invalid |

### Authorization Errors (AUZ)

| Code | Title | Description |
|------|-------|-------------|
| `HYPERFLEET-AUZ-001` | Permission Denied | User lacks required permission |
| `HYPERFLEET-AUZ-002` | Resource Access Denied | User cannot access this resource |
| `HYPERFLEET-AUZ-003` | Action Not Allowed | User cannot perform this action |

### Not Found Errors (NTF)

| Code | Title | Description |
|------|-------|-------------|
| `HYPERFLEET-NTF-001` | Resource Not Found | Requested resource does not exist |
| `HYPERFLEET-NTF-002` | Cluster Not Found | Cluster with given ID not found |
| `HYPERFLEET-NTF-003` | NodePool Not Found | NodePool with given ID not found |
| `HYPERFLEET-NTF-004` | Adapter Not Found | Adapter with given ID not found |
| `HYPERFLEET-NTF-005` | API Version Not Supported | Requested API version does not exist |

### Conflict Errors (CNF)

| Code | Title | Description |
|------|-------|-------------|
| `HYPERFLEET-CNF-001` | Resource Already Exists | Resource with same identifier exists |
| `HYPERFLEET-CNF-002` | Version Conflict | Resource was modified by another request |
| `HYPERFLEET-CNF-003` | State Conflict | Operation not allowed in current state |

### Rate Limit Errors (LMT)

| Code | Title | Description |
|------|-------|-------------|
| `HYPERFLEET-LMT-001` | Rate Limit Exceeded | Too many requests, retry after delay |

### Internal Errors (INT)

| Code | Title | Description |
|------|-------|-------------|
| `HYPERFLEET-INT-001` | Internal Server Error | Unexpected error occurred |
| `HYPERFLEET-INT-002` | Database Error | Database operation failed |
| `HYPERFLEET-INT-003` | Configuration Error | Server misconfiguration |

### Service Errors (SVC)

| Code | Title | Description |
|------|-------|-------------|
| `HYPERFLEET-SVC-001` | Service Unavailable | Service is temporarily unavailable |
| `HYPERFLEET-SVC-002` | Dependency Unavailable | Required dependency is unavailable |
| `HYPERFLEET-SVC-003` | Upstream Timeout | Upstream service timed out |
| `HYPERFLEET-SVC-004` | Upstream Error | Upstream service returned an error |

---

## Error Wrapping and Propagation

### Internal Error Handling

When wrapping errors internally, preserve the original error context:

```go
// DO: Wrap with context
if err := db.GetCluster(id); err != nil {
    return fmt.Errorf("failed to get cluster %s: %w", id, err)
}

// DON'T: Lose original error
if err := db.GetCluster(id); err != nil {
    return errors.New("database error")
}
```

### Security Considerations

- **Never expose stack traces** in production API responses
- **Never expose internal error messages** that may reveal system details
- **Log full error details** internally for debugging
- **Sanitize user input** in error messages to prevent injection

---

## Component-Specific Guidelines

### API Service

- Return `Content-Type: application/problem+json` for all error responses
- Include `instance` field with the request path
- Include `trace_id` for distributed tracing correlation
- Log errors with full context (see [Logging Specification](./logging-specification.md))

### Sentinel

- Log errors with resource context (`cluster_id`, `resource_type`)
- Do not propagate errors to external systems (internal component)
- Record error metrics for monitoring

### Adapters

- Report errors via adapter status (see [Status Guide](../docs/status-guide.md))
- Distinguish between:
  - **Business logic failures**: `Health: True` (adapter worked, validation failed)
  - **Adapter errors**: `Health: False` (unexpected error in adapter)
- Include error details in status data for debugging

---

## Error Logging Integration

Error responses MUST be logged following the [Logging Specification](./logging-specification.md):

```json
{
  "timestamp": "2025-01-15T10:30:00.123Z",
  "level": "error",
  "message": "Request validation failed",
  "component": "api",
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
  "error_code": "HYPERFLEET-VAL-001",
  "error_type": "https://api.hyperfleet.io/errors/validation-error",
  "error": "Cluster name is required",
  "request_context": {
    "method": "POST",
    "path": "/api/hyperfleet/v1/clusters",
    "field": "spec.name"
  }
}
```

---

## Example Error Responses

### Validation Error

```http
HTTP/1.1 400 Bad Request
Content-Type: application/problem+json

{
  "type": "https://api.hyperfleet.io/errors/validation-error",
  "title": "Validation Error",
  "status": 400,
  "detail": "Cluster name is required",
  "instance": "/api/hyperfleet/v1/clusters",
  "code": "HYPERFLEET-VAL-001",
  "timestamp": "2025-01-15T10:30:00.123Z",
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
  "errors": [
    {
      "field": "spec.name",
      "constraint": "required",
      "message": "Cluster name is required"
    }
  ]
}
```

### Resource Not Found

```http
HTTP/1.1 404 Not Found
Content-Type: application/problem+json

{
  "type": "https://api.hyperfleet.io/errors/resource-not-found",
  "title": "Resource Not Found",
  "status": 404,
  "detail": "Cluster 'cls-nonexistent' not found",
  "instance": "/api/hyperfleet/v1/clusters/cls-nonexistent",
  "code": "HYPERFLEET-NTF-002",
  "timestamp": "2025-01-15T10:31:00.456Z",
  "trace_id": "5cf92f3577b34da6a3ce929d0e0e4737"
}
```

### Version Conflict

```http
HTTP/1.1 409 Conflict
Content-Type: application/problem+json

{
  "type": "https://api.hyperfleet.io/errors/version-conflict",
  "title": "Version Conflict",
  "status": 409,
  "detail": "Resource was modified by another request. Expected version 5, found version 6.",
  "instance": "/api/hyperfleet/v1/clusters/cls-123",
  "code": "HYPERFLEET-CNF-002",
  "timestamp": "2025-01-15T10:32:00.789Z",
  "trace_id": "6df92f3577b34da6a3ce929d0e0e4738",
  "expected_version": 5,
  "actual_version": 6
}
```

### Rate Limit Exceeded

```http
HTTP/1.1 429 Too Many Requests
Content-Type: application/problem+json
Retry-After: 60

{
  "type": "https://api.hyperfleet.io/errors/rate-limit-exceeded",
  "title": "Rate Limit Exceeded",
  "status": 429,
  "detail": "Rate limit of 100 requests per minute exceeded. Retry after 60 seconds.",
  "instance": "/api/hyperfleet/v1/clusters",
  "code": "HYPERFLEET-LMT-001",
  "timestamp": "2025-01-15T10:33:00.012Z",
  "trace_id": "7ef92f3577b34da6a3ce929d0e0e4739",
  "limit": 100,
  "window": "1m",
  "retry_after": 60
}
```

### Internal Server Error

```http
HTTP/1.1 500 Internal Server Error
Content-Type: application/problem+json

{
  "type": "https://api.hyperfleet.io/errors/internal-error",
  "title": "Internal Error",
  "status": 500,
  "detail": "An unexpected error occurred. Please try again later.",
  "instance": "/api/hyperfleet/v1/clusters",
  "code": "HYPERFLEET-INT-001",
  "timestamp": "2025-01-15T10:34:00.345Z",
  "trace_id": "8ff92f3577b34da6a3ce929d0e0e4740"
}
```

---

## References

- [RFC 9457 - Problem Details for HTTP APIs](https://www.rfc-editor.org/rfc/rfc9457.html)
- [RFC 7807 - Problem Details for HTTP APIs (obsoleted by RFC 9457)](https://www.rfc-editor.org/rfc/rfc7807.html)
- [HyperFleet Logging Specification](./logging-specification.md)
- [HyperFleet Tracing Standard](./tracing.md)
- [HyperFleet Status Guide](../docs/status-guide.md)
- [HyperFleet API Versioning](../components/api-service/api-versioning.md)
- [Google Cloud API Design Guide - Errors](https://cloud.google.com/apis/design/errors)
