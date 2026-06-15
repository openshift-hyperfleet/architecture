---
Status: Draft
Owner: HyperFleet Team
Last Updated: 2026-06-22
---

# Adapter Periodic Execution

> Part of [Adapter Resource Lifecycle Management Design](./adapter-lifecycle-management-design.md)

When an adapter config is updated or the framework binary is upgraded, the resources it manages may need to be reconciled again — even if the HyperFleet API spec has not changed. Today there is no mechanism to detect either change: the framework has no memory of which config version or binary version last ran for a given resource, so a drift-check event looks identical to a post-upgrade event and adapter authors cannot distinguish them.

This proposal enables that detection. The framework tracks the adapter config version across executions and injects both the config version and the framework binary version into the CEL evaluation context on every event. Adapter config authors use lifecycle gate expressions to decide which resources or operations should run in response to a version change — the framework provides the signal, the config author decides the action.

To support this, the design introduces two config schema changes and one API contract change: `adapter.version` is repurposed as the author-declared config version; `adapter.frameworkVersion` is added as the framework binary constraint; and both the config version (`adapter_config_version`) and the framework binary version (`adapter_framework_version`) are included in every status report sent to the HyperFleet API, stored in the raw statuses and not surfaced in the customer-facing conditions view.

## Config Schema Changes

Today `adapter.version` is a check against the framework binary version. This design repurposes it and adds a sibling field:

| Field | Before | After |
|---|---|---|
| `adapter.version` | Framework binary version constraint | **Author-declared adapter config version** |
| `adapter.frameworkVersion` | — | Framework binary version constraint (replaces old `adapter.version`) |

```yaml
adapter:
  version: "2.0.0"           # version of this task config, declared by the author
  frameworkVersion: "1.5.0"  # minimum required framework binary version
```

`adapter.version` is a free-form string the config author increments when they make a meaningful change to the config. The framework does not compute or validate it — authorship and cadence are entirely the author's responsibility.

## Detection Mechanism

### API contract

Both the adapter config version and the framework binary version are reported to the HyperFleet API on every status update as new fields in `AdapterStatusCreateRequest`, added as siblings of `adapter`:

```json
{
  "adapter": "provisioner",
  "adapter_config_version": "2.0.0",
  "adapter_framework_version": "1.5.0",
  "observed_generation": 4,
  "observed_time": "2026-06-22T10:00:00Z",
  "conditions": [
    { "type": "Reconciled", "status": "True" }
  ]
}
```

Both fields are included on every report. They are stored in the raw status records returned by `GET /api/hyperfleet/v1/resources/{id}/statuses` and are not surfaced in `resource.status.conditions`, which is the customer-facing view of the resource. This keeps internal adapter bookkeeping out of the conditions API.

### Making version values available in CEL

The framework does not inject version variables automatically. Adapter config authors wire them up using the existing params and precondition mechanisms.

**Current version params** — sourced from the adapter config and the running binary (e.g., via ConfigMap entry and environment variable respectively):

```yaml
params:
  - name: adapterVersion
    source: "configmap.hyperfleet.provisioner-config.adapter\.version"
    type: "string"
  - name: adapterFrameworkVersion
    source: "env.ADAPTER_FRAMEWORK_VERSION"
    type: "string"
```

**Last reported versions** — captured from the raw statuses endpoint in a precondition. Both fields are extracted from the same API call:

```yaml
preconditions:
  - name: "getAdapterStatuses"
    api_call:
      method: "GET"
      url: "/api/hyperfleet/v1/resources/{{ .resourceId }}/statuses"
    capture:
      - name: "lastAdapterVersion"
        expression: |
          getAdapterStatuses.items.filter(s, s.adapter == "provisioner").size() > 0
            ? getAdapterStatuses.items.filter(s, s.adapter == "provisioner")[0].adapter_config_version
            : ""
      - name: "lastAdapterFrameworkVersion"
        expression: |
          getAdapterStatuses.items.filter(s, s.adapter == "provisioner").size() > 0
            ? getAdapterStatuses.items.filter(s, s.adapter == "provisioner")[0].adapter_framework_version
            : ""
```

All four are then available as named variables in lifecycle gate expressions for the rest of the event execution.

### Execution trigger

With the params and captures defined, lifecycle gates can compare current vs last-reported values and conditionally skip or run resources:

| Trigger | How to detect |
|---|---|
| spec.generation changed | Existing generation-aware apply logic |
| `adapter.version` changed | `adapterVersion != lastAdapterVersion` in a `when` expression |
| Framework binary changed | `adapterFrameworkVersion != lastAdapterFrameworkVersion` in a `when` expression |

## Using version context in lifecycle gates

The adapter config author controls what happens when a version change is detected. A resource-level `when` gate scopes execution to version-change events:

```yaml
resources:
  - name: "migrationJob"
    when:
      expression: "adapterVersion != lastAdapterVersion || adapterFrameworkVersion != lastAdapterFrameworkVersion"
    lifecycle:
      apply:
        when:
          expression: "!resources.?migrationJob.hasValue()"
```

This runs the migration job resource only when the config version or framework binary has changed and the job does not already exist — a one-time resource per upgrade. Resources without a version-checking `when` gate run on every event as normal.

## Related Documentation

- [Adapter Resource Lifecycle Management Design](./adapter-lifecycle-management-design.md) — Main index document
- [Adapter Lifecycle Gates](./adapter-lifecycle-gates.md) — §1: Lifecycle Gates
- [Adapter Label Stamping](./adapter-label-stamping.md) — §2: Automatic Label and Annotation Stamping
- [Adapter Resilience Model](./adapter-resilience-model.md) — §3: Resilience Model
- [Adapter Stuck Detection](./adapter-stuck-detection.md) — §4: Stuck Detection
- [Adapter Resource Retention](./adapter-resource-retention.md) — §6: Resource Retention
- [Adapter Sweep Controller](./adapter-sweep-controller.md) — §7: Sweep Controller
