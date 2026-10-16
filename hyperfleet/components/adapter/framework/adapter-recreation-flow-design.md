---
Status: Draft
Owner: HyperFleet Team
Last Updated: 2026-10-16
---

# Adapter Resource Recreation Flow Design

**Jira**: [HYPERFLEET-837](https://issues.redhat.com/browse/HYPERFLEET-837)

## Implementation Status

This document is a proposal, not the shipped adapter contract. `lifecycle.recreate.when` is not implemented. This design and the [adapter authoring guide](https://github.com/openshift-hyperfleet/hyperfleet-adapter/blob/main/docs/adapter-authoring-guide.md) must be updated together when the feature is implemented. The shipped `recreate_on_change` flag is local-Kubernetes-only and is rejected for remote resources. The examples and sequences below describe the proposed local flow, not working configuration for the current binary. Remote recreation semantics must be revisited when the feature is implemented; in particular, remote delete confirmation uses `DeleteDesire` status rather than read-mirror disappearance.

## What & Why

**What**: Design the recreation workflow for resources that cannot be updated in-place (e.g., Kubernetes Jobs with immutable fields). When certain conditions change, the adapter deletes the old resource and creates a new one.

**Why**: Some resources have immutable fields that cannot be patched. Without a clear recreation mechanism:

- Config authors have no way to express "recreate this resource when X changes"
- Recreation must be safe across Sentinel's ~10s retry loop (may receive same event multiple times)
- Deletion may span multiple reconciliation loops due to finalizers or async behavior
- Creation must never be attempted while deletion is still pending

**Related Documentation:**

- [Adapter Framework Design](./adapter-frame-design.md) — Core executor architecture
- [Adapter Status Contract](./adapter-status-contract.md) — Status reporting patterns

### Scope

- CEL expression evaluation for recreation triggers (`lifecycle.recreate.when`)
- Stateless, transport-agnostic delete+apply flow
- Handling async deletion (finalizers, eventual consistency)
- Safe retry across Sentinel's polling loop

### Out of Scope

- Stuck deletion timeout behavior and alerts (Will be covered by [HYPERFLEET-1205](https://redhat.atlassian.net/browse/HYPERFLEET-1205))

---

## Design

### Flow & Lifecycle

When a resource is configured with `lifecycle.recreate.when`, the executor:

1. **Pre-discovers** the current resource state (if any) so CEL expressions can compare incoming parameters with the current resource to detect changes that require recreation.

2. **Deletion short-circuit**: `lifecycle.delete.when` is evaluated first. If it evaluates to true, `lifecycle.recreate.when` is never evaluated — see [Conflict Resolution: Delete vs. Recreate](#conflict-resolution-delete-vs-recreate) below.

3. **Evaluates** `lifecycle.recreate.when` (a CEL expression). If true, enters the recreation flow; otherwise, uses the normal apply path (update in-place or create).

4. **In the recreation flow**:
   - Trigger deletion of the old resource (asynchronously) using `Background` propagation policy
   - Perform post-discovery to check whether the resource has been deleted
   - If resource is gone (404/NotFound): proceed to create the new resource
   - If resource still exists (has `deletionTimestamp` or other deletion state): return early with `Operation=Recreate, Reason="deletion pending"` — do NOT attempt creation
   - This flow is safe to retry — multiple attempts converge to the same end state

   **Handling pending deletions**: When post-discovery still sees the resource (even with `deletionTimestamp`), we rely on Sentinel's existing retry mechanism (~10s interval) to re-trigger the adapter. This avoids introducing nested polling loops within the adapter, which would increase complexity and cost at scale. The recreation will complete on a subsequent reconciliation once the resource is fully deleted.

### Configuration Structure

Configure resource recreation by adding a `lifecycle.recreate.when` expression that detects when the resource should be deleted and recreated:

```yaml
resources:
  - name: "job"
    manifest:
      apiVersion: batch/v1
      kind: Job
      metadata:
        name: "{{ .clusterId }}-job-{{ .generation }}"
        namespace: "{{ .namespace }}"
        labels:
          hyperfleet.io/cluster-id: "{{ .clusterId }}"
          hyperfleet.io/resource-type: "job"
        annotations:
          hyperfleet.io/generation: "{{ .generation }}"
      spec:
        backoffLimit: 0
        ttlSecondsAfterFinished: 300
        template:
          spec:
            restartPolicy: Never
            containers:
              - name: hello
                image: alpine:3.19
                command: ["/bin/sh", "-c", "echo 'Hello World!' && exit 0"]

    # Required: discovery allows the CEL expression to compare current vs. desired state
    discovery:
      namespace: "{{ .namespace }}"
      by_selectors:
        label_selector:
          hyperfleet.io/cluster-id: "{{ .clusterId }}"
          hyperfleet.io/resource-type: "job"

    lifecycle:
      # Deletion configuration
      delete:
        propagationPolicy: "Background"
        when:
          expression: "is_deleting"
      # Recreation trigger: when the expression is true, delete old resource and create new
      recreate:
        when:
          expression: |
            resources.?job.hasValue()
            && has(resources.job.metadata)
            && has(resources.job.metadata.annotations)
            && string(generation) != resources.job.metadata.annotations["hyperfleet.io/generation"]
```

### Proposed Validation Requirements

- **Discovery block required**: If `discovery` is absent, the adapter rejects the config and fails to start — this prevents silent runtime failure where the CEL expression evaluates against an empty resource context
- **Expression required**: `lifecycle.recreate.when.expression` must be present and non-empty

### Conflict Resolution: Delete vs. Recreate

Both `lifecycle.delete.when` and `lifecycle.recreate.when` can evaluate to true simultaneously. A common case: when `deleted_time` is set, the existing resource still carries the old generation annotation, which triggers a generation mismatch in the recreate expression.

The framework resolves this with explicit evaluation ordering:

| Priority | Expression | If true |
|----------|-----------|---------|
| 1 (higher) | `lifecycle.delete.when` | Execute deletion, stop. `lifecycle.recreate.when` is never evaluated. |
| 2 | `lifecycle.recreate.when` | Enter recreation flow. |

This ordering is framework-enforced and not configurable. Config authors do not need to write `!is_deleting` in recreate expressions.

### Recreation Flow Implementation

The detailed recreation flow is described in step 4 of [Flow & Lifecycle](#flow--lifecycle) above. Key implementation details:

- **Idempotent deletion**: `TransportClient.DeleteResource()` can be called multiple times safely
- **Post-delete verification**: Uses same discovery mechanism to check if resource is gone
- **Convergence**: Multiple retry attempts from Sentinel converge to the same end state
- **No special flags**: Uses standard `ApplyResource()` after deletion confirms completion

### Multi-Resource Recreation Ordering

When multiple resources are configured, they are processed **sequentially in config list order** — there is no parallelism and no automatic dependency resolver.

Before the loop begins, a single **pre-discovery pass** runs for all resources and populates their current state into `execCtx.Resources`. This ensures `lifecycle.recreate.when` CEL expressions can reference sibling resource state regardless of their position in the list.

| Scenario | Behavior |
|----------|----------|
| Resource A recreation is deletion pending | Loop continues — resource B is still processed in the same reconciliation |
| Resource A delete succeeds (fully gone) | Resource B's `recreate.when` can reference `resources.?A.hasValue() == false` in the same reconciliation |
| Resource A delete is still pending | Resource B sees A's mid-deletion state in `resources.A` (object present with `deletionTimestamp`) |

Config authors control ordering via: (1) list position in config, and (2) CEL expressions that reference sibling resource state to create implicit dependencies.

### Status Reporting During Recreation

Post-processing always runs after the resources phase, **including when deletion is still pending**. There is no framework-level guard that skips post-processing during recreation. When the resource hasn't been fully removed yet, `resources.<name>` contains the **still-present, mid-deletion object** — typically with `metadata.deletionTimestamp` set. Config authors encode awareness of this state into their CEL conditions.

Status conditions are built in the `post` section using CEL expressions that access:

- **Discovered resources**: `resources.?resourceName` (contains the current state, including metadata and status)
- **Adapter execution state**: `adapter.executionStatus` (success/failed), `adapter.resourcesSkipped`, `adapter.errorMessage`
- **Parameters from preconditions**: `is_deleting`, `generation`, etc.

**Detecting pending deletion during recreation:**

When recreation is in progress but deletion hasn't completed yet (finalizers pending, async deletion), the discovered resource will still exist in `resources.?resourceName`. Status conditions can detect this state:

```yaml
post:
  payloads:
    - name: "statusPayload"
      build:
        conditions:
          # Applied: Resource exists (may be pending deletion during recreation)
          - type: "Applied"
            status:
              expression: |
                resources.?job.?metadata.?creationTimestamp.hasValue() ? "True" : "False"
            reason:
              expression: |
                resources.?job.?metadata.?deletionTimestamp.hasValue()
                  ? "RecreationPending"
                  : (resources.?job.?metadata.?creationTimestamp.hasValue()
                      ? "ResourceApplied"
                      : "ResourceNotYetCreated")
            message:
              expression: |
                resources.?job.?metadata.?deletionTimestamp.hasValue()
                  ? "Resource deletion in progress, recreation will complete after finalizers"
                  : (resources.?job.?metadata.?creationTimestamp.hasValue()
                      ? "Resource successfully applied"
                      : "Resource not yet created")

          # Available: Check if resource is actually available (not during deletion)
          - type: "Available"
            status:
              expression: |
                resources.?job.?metadata.?deletionTimestamp.hasValue()
                  ? "False"
                  : (resources.?job.?status.?succeeded.orValue(0) > 0 ? "True" : "False")
            reason:
              expression: |
                resources.?job.?metadata.?deletionTimestamp.hasValue()
                  ? "DeletionPending"
                  : (resources.?job.?status.?succeeded.orValue(0) > 0
                      ? "JobCompleted"
                      : "JobRunning")
```

**Key detection pattern**: `resources.?resourceName.?metadata.?deletionTimestamp.hasValue()` indicates the resource is pending deletion (finalizers or async deletion in progress).

**After successful recreation** (new resource created, no deletionTimestamp):

- `Applied=True` with `Reason="ResourceApplied"`
- `Available` depends on postconditions (job completion, etc.)
- Standard post-apply discovery populates `resources.?resourceName` with the new resource state

See [Adapter Status Contract](./adapter-status-contract.md) for details on the standard status condition patterns.

### Happy Path Sequence

```mermaid
sequenceDiagram
    participant Sentinel as Sentinel
    participant Adapter as Adapter
    participant Transport as Local Kubernetes Transport
    participant API as HyperFleet API

    Sentinel->>Adapter: Event (generation=2)

    Note over Adapter,Transport: Phase 1: Parameter Extraction
    Adapter->>Adapter: Extract params from event<br/>(clusterId, generation, namespace, etc.)

    Note over Adapter,Transport: Phase 2: Preconditions
    Adapter->>Adapter: Evaluate preconditions (CEL)

    Note over Adapter,Transport: Phase 3: Resources
    Note over Adapter,Transport: Pre-Discovery
    Adapter->>Transport: GetResource(Job)
    Transport-->>Adapter: {generation=1, Active}
    Adapter->>Adapter: Store in execCtx.Resources["job"]

    Note over Adapter: Evaluate lifecycle.delete.when → false
    Note over Adapter: Evaluate lifecycle.recreate.when → true<br/>(generation mismatch detected)

    Note over Adapter,Transport: Recreation Flow: Delete + Wait + Create
    Adapter->>Transport: DeleteResource(Job, propagationPolicy=Background)
    Transport-->>Adapter: 200 OK

    Adapter->>Transport: GetResource(Job) - poll for deletion
    Transport-->>Adapter: 404 Not Found
    Note over Adapter: Deletion confirmed

    Adapter->>Adapter: Render manifest template (generation=2)
    Adapter->>Transport: CreateResource(Job, generation=2)
    Transport-->>Adapter: 201 Created

    Note over Adapter,Transport: Post-Apply Discovery
    Adapter->>Transport: GetResource(Job)
    Transport-->>Adapter: {generation=2, Active}
    Adapter->>Adapter: Update execCtx.Resources["job"]

    Note over Adapter,API: Phase 4: Post Actions
    Adapter->>Adapter: Build status payload (CEL)
    Adapter->>API: POST /api/v1/clusters/{id}/status
    API-->>Adapter: 200 OK

    Note over Adapter: Success: Recreate
```

### Pending Deletion Sequence

This is the critical case: deletion can potentially take multiple adapter reconciliation loops due to finalizers / async behavior / grace periods when deleting k8s resources. Sentinel sends the same event repeatedly (~10s intervals). Recreation must be safe to retry.

```mermaid
sequenceDiagram
    participant Sentinel as Sentinel
    participant Adapter as Adapter
    participant Transport as Local Kubernetes Transport
    participant API as HyperFleet API

    Sentinel->>Adapter: Event (generation=2)

    Note over Adapter: Phase 1: Parameter Extraction
    Adapter->>Adapter: Extract params (generation=2, etc.)

    Note over Adapter: Phase 2: Preconditions
    Adapter->>Adapter: Evaluate preconditions → met

    Note over Adapter,Transport: Phase 3: Resources
    Adapter->>Transport: GetResource(Job) - pre-discovery
    Transport-->>Adapter: {generation=1, Active}
    Adapter->>Adapter: Store in execCtx.Resources["job"]

    Note over Adapter: Evaluate lifecycle.recreate.when → true
    Adapter->>Transport: DeleteResource(Job, propagationPolicy=Background)
    Transport-->>Adapter: 200 OK (deletion initiated)

    Adapter->>Transport: GetResource(Job) - poll for deletion
    Transport-->>Adapter: {deletionTimestamp=2026-06-10T10:00:00Z, finalizers=[...]}
    Note over Adapter: Still present (finalizers pending)<br/>Skip CreateResource, store partial state
    Adapter->>Adapter: Update execCtx.Resources["job"]<br/>(contains deletionTimestamp)

    Note over Adapter,API: Phase 4: Post Actions
    Adapter->>Adapter: Build status payload<br/>Detect deletionTimestamp in resources.job
    Adapter->>API: POST status (Applied=True, reason=RecreationPending)
    API-->>Adapter: 200 OK

    Note over Sentinel,API: Retry 1 after 10s - deletion still pending
    Sentinel->>Adapter: Event (generation=2, same)

    Note over Adapter: Phase 1-2: Extract & Preconditions
    Adapter->>Adapter: Extract params, evaluate preconditions

    Note over Adapter,Transport: Phase 3: Resources
    Adapter->>Transport: GetResource(Job) - pre-discovery
    Transport-->>Adapter: {deletionTimestamp=2026-06-10T10:00:00Z, finalizers=[...]}
    Note over Adapter: Evaluate lifecycle.recreate.when → true
    Adapter->>Transport: DeleteResource(Job) - idempotent re-issue
    Transport-->>Adapter: 200 OK (no-op, already deleting)

    Adapter->>Transport: GetResource(Job) - poll for deletion
    Transport-->>Adapter: {deletionTimestamp=2026-06-10T10:00:00Z}
    Note over Adapter: Still present, skip CreateResource

    Note over Adapter,API: Phase 4: Post Actions
    Adapter->>API: POST status (Applied=True, reason=RecreationPending)
    API-->>Adapter: 200 OK

    Note over Sentinel,API: Retry 2 after 20s - deletion complete, creating new resource
    Sentinel->>Adapter: Event (generation=2, same)

    Note over Adapter: Phase 1-2: Extract & Preconditions
    Adapter->>Adapter: Extract params, evaluate preconditions

    Note over Adapter,Transport: Phase 3: Resources
    Adapter->>Transport: GetResource(Job) - pre-discovery
    Transport-->>Adapter: 404 Not Found
    Note over Adapter: No existing resource found<br/>Evaluate lifecycle.recreate.when → false (no current)<br/>Skip delete, proceed to create

    Adapter->>Adapter: Render manifest template (generation=2)
    Adapter->>Transport: CreateResource(Job, generation=2)
    Transport-->>Adapter: 201 Created

    Adapter->>Transport: GetResource(Job) - post-discovery
    Transport-->>Adapter: {generation=2, Active}
    Adapter->>Adapter: Update execCtx.Resources["job"]

    Note over Adapter,API: Phase 4: Post Actions
    Adapter->>Adapter: Build status payload<br/>No deletionTimestamp in resources.job
    Adapter->>API: POST status (Applied=True, Available=True)
    API-->>Adapter: 200 OK

    Note over Adapter: Success: Recreate
```

**Key property**: Delete is idempotent. Re-issuing DELETE when the resource already has `deletionTimestamp` is safe. Sentinel's retry loop naturally handles pending deletions without special logic.

### CEL Evaluation Context

`lifecycle.recreate.when` expressions have access to:

| Context Variable | Description | Example |
|-----------------|-------------|---------|
| Extracted parameters | From event/preconditions | `generation`, `clusterId`, `namespace` |
| Discovered resources | Current resource state | `resources.?job.metadata.annotations` |
| Adapter metadata | Execution state | `adapter.executionStatus`, `adapter.errorMessage` |

**Safe access patterns:**

- **Optional chaining**: `resources.?job.hasValue()` — prevents crashes on missing resources
- **`has()` macro**: `has(resources.job.metadata)` — checks for nested field existence

**Common expressions:**

```cel
# Recreate when generation annotation mismatches (recommended)
resources.?job.hasValue()
&& has(resources.job.metadata.annotations)
&& string(generation) != resources.job.metadata.annotations["hyperfleet.io/generation"]

# Recreate when spec field changes
resources.?cluster.hasValue()
&& has(resources.cluster.spec)
&& resources.cluster.spec.region != currentRegion

# Always recreate (testing/debugging)
true
```

### Edge Cases & Handling

| Scenario | Behavior |
|----------|----------|
| Resource doesn't exist at pre-discovery | Skip delete step, go directly to apply (create new resource) |
| Post-delete discovery fails (non-API error) | Assume resource still present due to transient error. Return early with "deletion pending". Retry on next Sentinel event. |
| CEL accesses non-existent resource | Use optional chaining (`resources.?job.hasValue() && ...`) to avoid crashes. CEL short-circuits evaluation. |
| Both delete and recreate expressions are true | Framework uses explicit evaluation ordering — see [Conflict Resolution](#conflict-resolution-delete-vs-recreate) |

---

## Responsibilities & Trade-offs

**What the proposed framework would provide:** Declarative recreation via CEL expressions. Safe to retry (delete is idempotent). Explicit delete-before-recreate evaluation ordering enforced by the framework. This is not shipped behavior.

**What config authors own:**

- Test recreation flow in staging environment before production
- Validate that stuck deletions are prevented through proper RBAC, finalizers, and cleanup logic in their domain

**Trade-off:** Deletion is fire-and-forget; actual deletion may span multiple reconciliation loops. The framework cannot recover from stuck deletions — prevention through proper design in the staging environment is the only viable approach.

**Why propose replacing `recreate_on_change`:** The shipped flag is local-Kubernetes-only. The proposed CEL-based lifecycle would make recreation explicit and stateless; its implementation and transport-specific behavior remain pending.
