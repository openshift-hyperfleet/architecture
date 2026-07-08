---
Status: Active
Owner: HyperFleet Adapter Team
Last Updated: 2026-07-07
---

# Adapter Common Patterns

> **Audience:** Adapter authors writing task configurations. This document collects copy-paste-ready patterns for the most common adapter scenarios. For the full authoring guide, see `docs/adapter-authoring-guide.md` in the [hyperfleet-adapter](https://github.com/openshift-hyperfleet/hyperfleet-adapter) repository.

---

## Table of Contents

- [1. Precondition Captures](#1-precondition-captures)
- [2. Resource Discovery](#2-resource-discovery)
- [3. Status Payload Conditions](#3-status-payload-conditions)
- [4. Post-Action Gates](#4-post-action-gates)
- [5. CEL Field Access Decision Table](#5-cel-field-access-decision-table)
- [6. Deletion Patterns](#6-deletion-patterns)
- [7. Complete Minimal Adapter](#7-complete-minimal-adapter)

---

## 1. Precondition Captures

### Extract cluster metadata from API response

```yaml
preconditions:
  - name: "clusterStatus"
    api_call:
      method: "GET"
      url: "/clusters/{{ .clusterId }}"
      timeout: 10s
      retry_attempts: 3
      retry_backoff: "exponential"
    capture:
      # Simple field extraction
      - name: "clusterName"
        field: "name"
      - name: "generationId"
        field: "generation"

      # CEL expression for computed values
      - name: "reconciledConditionStatus"
        expression: |
          status.conditions.filter(c, c.type == "Reconciled").size() > 0
            ? status.conditions.filter(c, c.type == "Reconciled")[0].status
            : "False"

      # Deletion detection (required for lifecycle.delete)
      - name: "is_deleting"
        expression: "has(clusterStatus.deleted_time)"
```

### Why `has()` for deletion detection

Using `expression: "has(clusterStatus.deleted_time)"` instead of `field: "deleted_time"` avoids a WARN log on every reconciliation where the field is absent (which is ~99% of the time).

---

## 2. Resource Discovery

### By name (exact match)

```yaml
discovery:
  by_name: '{{ .clusterId }}-namespace'
```

### By label selector

```yaml
discovery:
  by_selectors:
    label_selector:
      hyperfleet.io/cluster-id: "{{ .clusterId }}"
      hyperfleet.io/managed-by: "{{ .adapter.name }}"
      hyperfleet.io/resource-type: "namespace"
```

### Nested discovery (Maestro ManifestWork sub-resources)

```yaml
nested_discoveries:
  - name: mgmtNamespace
    discovery:
      by_selectors:
        label_selector:
          hyperfleet.io/cluster-id: '{{ .clusterId }}'
          hyperfleet.io/resource-type: namespace
  - name: mgmtConfigMap
    discovery:
      by_name: 'cluster-config'
```

---

## 3. Status Payload Conditions

Every adapter reports four condition types. Below are copy-paste-ready templates.

### Applied — resources successfully created

```yaml
- type: "Applied"
  status:
    expression: |
      has(resources.myResource) ? "True" : "False"
  reason:
    expression: |
      has(resources.myResource) ? "ResourceApplied" : "ResourcePending"
  message:
    expression: |
      has(resources.myResource)
        ? "Resource applied successfully"
        : "Resource is pending"
```

### Available — resources are active and ready

```yaml
- type: "Available"
  status:
    expression: |
      resources.?myResource.?status.?phase.orValue("") == "Active"
      ? "True" : "False"
  reason:
    expression: |
      resources.?myResource.?status.?phase.orValue("") == "Active"
      ? "ResourceReady" : "ResourceNotReady"
  message:
    expression: |
      resources.?myResource.?status.?phase.orValue("") == "Active"
      ? "Resource is active and ready"
      : "Resource is not yet ready"
```

### Health — adapter execution status (reusable boilerplate)

```yaml
- type: "Health"
  status:
    expression: |
      adapter.?executionStatus.orValue("") == "success"
        && !adapter.?resourcesSkipped.orValue(false)
      ? "True" : "False"
  reason:
    expression: |
      adapter.?executionStatus.orValue("") != "success"
      ? "ExecutionFailed:" + adapter.?executionError.?phase.orValue("unknown")
      : adapter.?resourcesSkipped.orValue(false)
        ? "ResourcesSkipped"
        : "Healthy"
  message:
    expression: |
      adapter.?executionStatus.orValue("") != "success"
      ? "Adapter failed at phase ["
          + adapter.?executionError.?phase.orValue("unknown")
          + "] step ["
          + adapter.?executionError.?step.orValue("unknown")
          + "]: "
          + adapter.?executionError.?message.orValue(adapter.?errorMessage.orValue("no details"))
      : adapter.?resourcesSkipped.orValue(false)
        ? "Resources skipped: " + adapter.?skipReason.orValue("unknown reason")
        : "Adapter execution completed successfully"
```

### Finalized — deletion cleanup (when adapter handles deletion)

```yaml
# Requires: is_deleting captured in preconditions
- type: "Finalized"
  status:
    expression: |
      is_deleting
        && adapter.?executionStatus.orValue("") == "success"
        && !resources.?myResource.hasValue()
      ? "True" : "False"
  reason:
    expression: |
      !is_deleting ? ""
      : adapter.?executionStatus.orValue("") != "success"
        ? "AdapterUnhealthy"
        : !resources.?myResource.hasValue()
          ? "CleanupConfirmed"
          : "CleanupInProgress"
  message:
    expression: |
      !is_deleting ? ""
      : adapter.?executionStatus.orValue("") != "success"
        ? "Cannot confirm cleanup while adapter is unhealthy"
        : !resources.?myResource.hasValue()
          ? "All managed resources deleted and verified"
          : "Resource cleanup in progress"
```

### Finalized — static (when adapter has no deletion flow)

```yaml
- type: "Finalized"
  status: "False"
  reason: "NotDeleting"
  message: "No pending deletion for this adapter instance"
```

---

## 4. Post-Action Gates

### Skip status report when no work was done

```yaml
post_actions:
  - name: "reportClusterStatus"
    when:
      expression: "!adapter.resourcesSkipped"
    api_call:
      method: "PUT"
      url: "/clusters/{{ .clusterId }}/statuses"
      body: "{{ .clusterStatusPayload }}"
```

### Conditional payloads — build different payloads for create vs delete

```yaml
post:
  payloads:
    - name: "statusPayload"
      when:
        expression: "!adapter.resourcesSkipped"
      build:
        # ... full status with resource data

    - name: "skippedPayload"
      when:
        expression: "adapter.resourcesSkipped"
      build:
        reason:
          expression: 'adapter.skipReason'
```

---

## 5. CEL Field Access Decision Table

| Goal | Function | Example |
|------|----------|---------|
| Check if a map key exists | `has()` | `has(resources.ns)` |
| Check if optional value is present | `.hasValue()` | `resources.?ns.hasValue()` |
| Get value with fallback | `.orValue()` | `resources.?ns.?status.?phase.orValue("")` |
| Check if a resource was deleted | `!.hasValue()` | `!resources.?ns.hasValue()` |
| Guard a deep access chain | `has()` + `&&` | `has(resources.ns) && has(resources.ns.status)` |

### Key distinction

- **`has(resources.X)`** — standard CEL map-key check. Fails if the map itself is nil.
- **`resources.?X.hasValue()`** — optional chaining. Returns `false` cleanly whether the key is absent, was deleted, or was never processed.
- **`!resources.?X.hasValue()`** — the canonical way to check that a resource is gone (deleted or never created). Do NOT use `== null`.

---

## 6. Deletion Patterns

### Single resource

```yaml
lifecycle:
  delete:
    propagationPolicy: Background
    when:
      expression: "is_deleting"
```

### Dependency ordering — delete child before parent

```yaml
# Resource A (child): deleted first
lifecycle:
  delete:
    when:
      expression: "is_deleting"

# Resource B (parent): deleted only after A is gone
lifecycle:
  delete:
    when:
      expression: "is_deleting && !resources.?resourceA.hasValue()"
```

---

## 7. Complete Minimal Adapter

A minimal adapter that creates a Namespace and reports status:

```yaml
params:
  - name: "clusterId"
    source: "event.id"
    type: "string"
    required: true

preconditions:
  - name: "clusterStatus"
    api_call:
      method: "GET"
      url: "/clusters/{{ .clusterId }}"
      timeout: 10s
    capture:
      - name: "clusterName"
        field: "name"
      - name: "generation"
        field: "generation"
    conditions:
      - field: "clusterStatus.status.conditions"
        operator: "exists"
        value: ""

resources:
  - name: "clusterNamespace"
    manifest:
      apiVersion: v1
      kind: Namespace
      metadata:
        name: "{{ .clusterId }}"
        labels:
          hyperfleet.io/cluster-id: "{{ .clusterId }}"
          hyperfleet.io/managed-by: "{{ .adapter.name }}"
    discovery:
      by_name: '{{ .clusterId }}'

post:
  payloads:
    - name: "clusterStatusPayload"
      build:
        adapter: "{{ .adapter.name }}"
        conditions:
          - type: "Applied"
            status:
              expression: |
                has(resources.clusterNamespace) ? "True" : "False"
            reason:
              expression: |
                has(resources.clusterNamespace) ? "NamespaceCreated" : "NamespacePending"
            message:
              expression: |
                has(resources.clusterNamespace)
                  ? "Namespace created successfully"
                  : "Namespace creation in progress"
          - type: "Available"
            status:
              expression: |
                resources.?clusterNamespace.?status.?phase.orValue("") == "Active"
                ? "True" : "False"
            reason:
              expression: |
                resources.?clusterNamespace.?status.?phase.orValue("") == "Active"
                ? "NamespaceReady" : "NamespaceNotReady"
            message:
              expression: |
                resources.?clusterNamespace.?status.?phase.orValue("") == "Active"
                ? "Namespace is active" : "Namespace is not yet active"
          - type: "Health"
            status:
              expression: |
                adapter.?executionStatus.orValue("") == "success" ? "True" : "False"
            reason:
              expression: |
                adapter.?executionStatus.orValue("") == "success" ? "Healthy" : "Unhealthy"
            message:
              expression: |
                adapter.?executionStatus.orValue("") == "success"
                ? "Adapter completed successfully" : "Adapter execution failed"
          - type: "Finalized"
            status: "False"
            reason: "NotDeleting"
            message: "No pending deletion for this adapter instance"
        observed_generation:
          expression: "generation"
        observed_time: "{{ now | date \"2006-01-02T15:04:05Z07:00\" }}"

  post_actions:
    - name: "reportClusterStatus"
      when:
        expression: "!adapter.resourcesSkipped"
      api_call:
        method: "PUT"
        url: "/clusters/{{ .clusterId }}/statuses"
        body: "{{ .clusterStatusPayload }}"
```

---

## References

- [Adapter Authoring Guide](https://github.com/openshift-hyperfleet/hyperfleet-adapter/blob/main/docs/adapter-authoring-guide.md) — full guide with all features
- [CEL Conventions](https://github.com/openshift-hyperfleet/hyperfleet-adapter/blob/main/docs/conventions/cel.md) — CEL implementation details
- [Chart Examples](https://github.com/openshift-hyperfleet/hyperfleet-adapter/tree/main/charts/examples) — tested, working configurations
- [Adapter Status Contract](adapter-status-contract.md) — status reporting design
- [Adapter Deletion Flow](adapter-deletion-flow-design.md) — deletion lifecycle design
