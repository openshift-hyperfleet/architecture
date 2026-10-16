---
Status: Draft
Owner: HyperFleet Architecture Team
Last Updated: 2026-10-14
---

# Generic Resource Registry — Design Document

This document contains the proposal for the Generic Resource Registry and alternatives

---

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [Design Overview](#2-design-overview)
3. [OpenAPI Contract](#3-openapi-contract)
   - [3.1 Core types](#31-core-types)
   - [3.2 Routes](#32-routes)
4. [Data Layer](#4-data-layer)
   - [4.1 GORM types](#41-gorm-types-pkgapiresourcego)
   - [4.2 Database schema](#42-database-schema)
   - [4.3 ResourceDao](#43-resourcedao-pkgdaoresourcego)
5. [Entity Registry](#5-entity-registry)
   - [5.1 EntityDescriptor](#51-entitydescriptor-pkgregistrydescriptorgo)
   - [5.2 Global registry](#52-global-registry-pkgregistryregistrygo)
   - [5.3 Entity configuration examples](#53-entity-configuration-examples)
   - [5.4 Href generation](#54-href-generation)
6. [Spec Field Validation](#6-spec-field-validation)
   - [6.1 Current implementation](#61-current-implementation)
   - [6.2 Additional OpenAPI contract](#62-additional-openapi-contract-spec-schemas)
7. [Handler Layer](#7-handler-layer)
   - [7.1 Shared presenter](#71-shared-presenter-pkgapipresentersresourcego)
   - [7.2 ResourceHandler](#72-resourcehandler-pkghandlersresourcego)
   - [7.3 ResourceStatusHandler](#73-resourcestatushandler-pkghandlersresource_statusgo)
   - [7.4 Auto route registration](#74-auto-route-registration-pkghandlersentity_routesgo)
8. [Delete Model for Owned Resources](#8-delete-model-for-owned-resources)
   - [8.1 Descriptor-driven delete policy](#81-descriptor-driven-delete-policy)
   - [8.2 Service layer implementation](#82-service-layer-implementation)
9. [Resource References](#9-resource-references)
   - [9.1 Overview](#91-overview)
   - [9.2 API representation](#92-api-representation)
   - [9.3 Deletion restriction](#93-deletion-restriction)
   - [9.4 Reverse lookup](#94-reverse-lookup)
10. [No Migration, No Backward Compatibility](#10-no-migration-no-backward-compatibility)
11. [Alternatives and Tradeoffs](#11-alternatives-and-tradeoffs)
    - [11.1 Separate tables vs. JSONB for labels and conditions](#111-separate-tables-vs-jsonb-for-labels-and-conditions)
    - [11.2 Delete model for owned resources](#112-delete-model-for-owned-resources)
    - [11.3 Entity configuration: where entity types are defined](#113-entity-configuration-where-entity-types-are-defined)
    - [11.4 Naming the generic entity type](#114-naming-the-generic-entity-type)
    - [11.5 Computed vs. stored conditions](#115-computed-vs-stored-conditions)
    - [11.6 Child entity creation via the generic root endpoint](#116-child-entity-creation-via-the-generic-root-endpoint)
    - [11.7 Resource references design](#117-resource-references-design)
12. [Risks](#12-risks)

- [Appendix A. Current State](#appendix-a-current-state)

---

## 1. Problem Statement

HyperFleet API currently has two managed entity types — Cluster and NodePool — and more are expected. Adding each new entity type requires changing the code, which is mostly duplicated code and releasing a new version.

This is not desirable since it slows down HyperFleet customers willing to add new functionality and having to wait until these changes are coordinated and deployed

**Goals:**

- Streamline the process of adding new entities to the HyperFleet API
- New entity types require only registration code, no shared infrastructure changes.
- All routes, spec validation, status aggregation, and delete semantics are derived automatically from a declarative entity descriptor.
- The system supports hierarchical ownership (child entities accessible under parent routes) without per-entity handler code.

---

## 2. Design Overview

The design rests on four ideas:

1. **Generic OpenAPI contract**: the API exposes a single `Resource` response type.
    - The `spec` field is an untyped JSON object at the API layer;
    - Entity-specific spec shapes are validated by a separate schema contract file.
2. **Single Go type**: all entities share one GORM struct (`Resource`) with a `kind` discriminator.
    - One `resources` table.
3. **Entity registry**: each entity type is described by an `EntityDescriptor` registered at startup.
    - The registry drives route generation, spec validation, status aggregation, and delete behavior.
    - Entities are defined in the configuration file.
4. **Declarative resource references**: non-ownership associations between entity types are declared in the descriptor and stored in a `resource_references` join table.
    - Referenced resources cannot be deleted while in use.
    - Reverse lookup is available via query parameters on the referencing entity's list endpoint.

---

## 3. OpenAPI Contract

The main API contract moves from per-entity types (`Cluster`, `NodePool`) to a single generic `Resource` type. Entity-specific spec structure is validated separately (see [§7](#7-handler-layer)).

The development approach is contract-first with the OpenAPI spec generated in the hyperfleet-api-spec repository and copied over to the hyperfleet-api repository.

In the future the hyperfleet-api may add more endpoints that are not managed Entities, and these will also follow contract-first approach.

### 3.1 Core types

<details>
<summary>OpenAPI type definitions (YAML)</summary>

```yaml
Resource:
  required: [id, kind, name, spec, status, generation, created_time, updated_time, created_by, updated_by]
  properties:
    id:               { type: string }
    kind:             { type: string }   # "Cluster", "NodePool", etc.
    name:             { type: string }
    href:             { type: string }
    spec:             { type: object, additionalProperties: true }
    labels:           { type: object, additionalProperties: { type: string } }
    status:           { $ref: '#/components/schemas/ResourceStatus' }
    generation:       { type: integer, format: int32 }
    owner_references: { $ref: '#/components/schemas/ObjectReference' }  # optional
    references:                                                          # optional — see §9
      type: object
      additionalProperties:
        type: array
        items: { $ref: '#/components/schemas/ObjectReference' }
    created_time:     { type: string, format: date-time }
    updated_time:     { type: string, format: date-time }
    created_by:       { type: string, format: email }
    updated_by:       { type: string, format: email }

ResourceCreateRequest:
  required: [kind, name, spec]
  properties:
    kind:       { type: string }
    name:       { type: string }
    spec:       { type: object, additionalProperties: true }
    labels:     { type: object, additionalProperties: { type: string } }
    references:                                                          # optional — see §9
      type: object
      additionalProperties:
        type: array
        items: { $ref: '#/components/schemas/ObjectReference' }

ResourcePatchRequest:
  properties:
    spec:       { type: object, additionalProperties: true }
    labels:     { type: object, additionalProperties: { type: string } }
    references:                                                          # optional — null/absent = no-op; {} = clear all; map = replace; see §9
      type: object
      additionalProperties:
        type: array
        items: { $ref: '#/components/schemas/ObjectReference' }

ResourceList:
  required: [items, total, size, page]
  properties:
    items: { type: array, items: { $ref: '#/components/schemas/Resource' } }
    total: { type: integer, format: int64 }
    size:  { type: integer, format: int32 }
    page:  { type: integer, format: int32 }

ResourceStatus:
  properties:
    conditions: { type: array, items: { $ref: '#/components/schemas/ResourceCondition' } }
```

</details>

Existing types `ResourceCondition`, `ObjectReference`, `AdapterStatus`, and `AdapterStatusList` are unchanged — they were already generic.

### 3.2 Routes

The API contract defines the routes for the `Resource` entity and methods:

```text
# Top-level (all entity types)
GET                /api/hyperfleet/v1/resources
POST               /api/hyperfleet/v1/resources      # resources without parent
GET PATCH,DELETE   /api/hyperfleet/v1/resources/{id}
POST               /api/hyperfleet/v1/resources/{id}/force-delete
GET PUT            /api/hyperfleet/v1/resources/{id}/statuses

```

Additionally, for each registered entity type, the following routes are generated:

```text
# Top-level (all entity types)
GET POST           /api/hyperfleet/v1/{plural}
GET PATCH,DELETE   /api/hyperfleet/v1/{plural}/{id}
GET POST           /api/hyperfleet/v1/{plural}/{id}/force-delete
GET PUT            /api/hyperfleet/v1/{plural}/{id}/statuses

# Nested (child entity types only — when ParentType != "")
GET POST           /api/hyperfleet/v1/[{parent-plural}/{parent_id}...]/{plural}
GET PATCH DELETE   /api/hyperfleet/v1/[{parent-plural}/{parent_id}...]/{plural}/{id}
GET POST           /api/hyperfleet/v1/[{parent-plural}/{parent_id}...]/{plural}/{id}/force-delete
GET POST           /api/hyperfleet/v1/[{parent-plural}/{parent_id}...]/{plural}/{id}/statuses
```

The `[ ...]` denotes the full hierarchy of parent resources.

Example with Cluster (top-level) and NodePool (parent: Cluster):

```text
GET POST         /api/hyperfleet/v1/clusters
GET PATCH DELETE /api/hyperfleet/v1/clusters/{id}
POST             /api/hyperfleet/v1/clusters/{id}/force-delete
GET PUT          /api/hyperfleet/v1/clusters/{id}/statuses

GET POST         /api/hyperfleet/v1/nodepools
GET PATCH DELETE /api/hyperfleet/v1/nodepools/{id}
POST             /api/hyperfleet/v1/nodepools/{id}/force-delete
GET PUT          /api/hyperfleet/v1/nodepools/{id}/statuses

GET POST         /api/hyperfleet/v1/clusters/{parent_id}/nodepools
GET PATCH DELETE /api/hyperfleet/v1/clusters/{parent_id}/nodepools/{id}
POST             /api/hyperfleet/v1/clusters/{parent_id}/nodepools/{id}/force-delete
GET PUT          /api/hyperfleet/v1/clusters/{parent_id}/nodepools/{id}/statuses
```

---

## 4. Data Layer

### 4.1 GORM types (`pkg/api/resource.go`)

`Labels` and `StatusConditions` are stored in dedicated tables rather than JSONB columns. The `Resource` struct holds them as GORM `HasMany` associations.

<details>
<summary>Resource GORM struct</summary>

```go
// Resource is the single Go type for all HyperFleet managed entities.
// Entity kinds are differentiated by the Kind field (e.g., "Cluster", "NodePool").
type Resource struct {
    Meta                                // ID, CreatedTime, UpdatedTime, DeletedAt

    Kind       string         `gorm:"column:kind;size:100;not null"`
    Name       string         `gorm:"column:name;size:100;not null"`
    Href       string         `gorm:"column:href;size:500"`
    CreatedBy  string         `gorm:"column:created_by;size:255;not null"`
    UpdatedBy  string         `gorm:"column:updated_by;size:255;not null"`

    // Parent reference — empty string for top-level entities
    OwnerID    string         `gorm:"column:owner_id;size:255"`
    OwnerKind  string         `gorm:"column:owner_kind;size:100"`
    OwnerHref  string         `gorm:"column:owner_href;size:500"`

    Spec       datatypes.JSON `gorm:"column:spec;not null"`
    Generation int32          `gorm:"column:generation;default:1;not null"`

    // Associations — stored in separate tables, loaded via Preload
    Labels     []ResourceLabel     `gorm:"foreignKey:ResourceID"`
    Conditions []ResourceCondition `gorm:"foreignKey:ResourceID"`
}

type ResourceList []Resource
```

</details>

**`ResourceLabel`** — one row per label key-value pair per resource:

```go
// ResourceLabel stores a single key-value label for a Resource.
// Table: resource_labels. Natural composite PK (resource_id, key) — no surrogate ID.
type ResourceLabel struct {
    ResourceID string `gorm:"primaryKey;column:resource_id;size:255"`
    Key        string `gorm:"primaryKey;column:key;size:255"`
    Value      string `gorm:"column:value;size:255;not null"`
}
```

**`ResourceCondition`** — one row per condition type per resource. Mirrors the OpenAPI `ResourceCondition` schema fields:

```go
// ResourceCondition stores a single status condition for a Resource.
// Table: resource_conditions. Natural composite PK (resource_id, type) — no surrogate ID.
type ResourceCondition struct {
    ResourceID         string    `gorm:"primaryKey;column:resource_id;size:255"`
    Type               string    `gorm:"primaryKey;column:type;size:255"`
    Status             string    `gorm:"column:status;size:50;not null"`  // "True", "False"
    Reason             string    `gorm:"column:reason;size:255"`
    Message            string    `gorm:"column:message;type:text"`
    ObservedGeneration int32     `gorm:"column:observed_generation;not null"`
    CreatedTime        time.Time `gorm:"column:created_time;not null"`
    LastUpdatedTime    time.Time `gorm:"column:last_updated_time;not null"`
    LastTransitionTime time.Time `gorm:"column:last_transition_time;not null"`
}
```

**`ResourceReference`** — one row per (source, refType, target) triple:

```go
// ResourceReference stores a single non-ownership association between two resources.
// Table: resource_references. Natural composite PK (source_id, ref_type, target_id).
type ResourceReference struct {
    SourceID   string `gorm:"primaryKey;column:source_id;size:255"`
    RefType    string `gorm:"primaryKey;column:ref_type;size:255"`
    TargetID   string `gorm:"primaryKey;column:target_id;size:255"`
    TargetKind string `gorm:"column:target_kind;size:100;not null"`
}
```

`TargetKind` is stored alongside `TargetID` so `PresentResource` can construct the `ObjectReference` without a secondary lookup.

GORM lifecycle hooks (`BeforeCreate`, `BeforeUpdate`) on `Resource` handle ID generation, timestamp management, and generation initialization — identical to the current per-entity hook logic. Neither `ResourceLabel`, `ResourceCondition`, nor `ResourceReference` has a surrogate ID — all use natural composite PKs set by the DAO on insert.

### 4.2 Database schema

<details>
<summary>Table: resources</summary>

| Column | Type | Notes |
|---|---|---|
| `id` | `VARCHAR(255)` PK | RFC 4122 UUID v7 |
| `kind` | `VARCHAR(100)` NOT NULL | Discriminator — e.g., "Cluster", "NodePool" |
| `name` | `VARCHAR(100)` NOT NULL | |
| `href` | `VARCHAR(500)` | Computed |
| `created_by` / `updated_by` | `VARCHAR(255)` | |
| `owner_id` / `owner_kind` / `owner_href` | `VARCHAR(255/100/500)` | Empty string for top-level |
| `spec` | `JSONB` NOT NULL | |
| `generation` | `INT4` DEFAULT 1 | |
| `created_time` / `updated_time` / `deleted_at` | `TIMESTAMPTZ` | |

`labels` and `status_conditions` are **not columns** on this table.

</details>

<details>
<summary>Table: resource_labels</summary>

| Column | Type | Notes |
|---|---|---|
| `resource_id` | `VARCHAR(255)` NOT NULL FK → `resources(id)` | Part of composite PK |
| `key` | `VARCHAR(255)` NOT NULL | Part of composite PK |
| `value` | `VARCHAR(255)` NOT NULL | |

Primary key: `(resource_id, key)` — enforces label key uniqueness per resource. No surrogate ID.

</details>

<details>
<summary>Table: resource_conditions</summary>

| Column | Type | Notes |
|---|---|---|
| `resource_id` | `VARCHAR(255)` NOT NULL FK → `resources(id)` | Part of composite PK |
| `type` | `VARCHAR(255)` NOT NULL | Part of composite PK — e.g., `"Ready"`, `"Available"`, `"Adapter1Successful"` |
| `status` | `VARCHAR(50)` NOT NULL | `"True"` or `"False"` |
| `reason` | `VARCHAR(255)` | |
| `message` | `TEXT` | |
| `observed_generation` | `INT4` NOT NULL | |
| `created_time` / `last_updated_time` / `last_transition_time`  | `TIMESTAMPTZ` NOT NULL | |

Primary key: `(resource_id, type)` — enforces one condition per type per resource. No surrogate ID.

</details>

**Indexes:**

<details>
<summary>Database indexes</summary>

```sql
-- resources: name uniqueness per kind for top-level entities
CREATE UNIQUE INDEX idx_resources_kind_name
    ON resources (kind, name)
    WHERE owner_id = '' AND deleted_at IS NULL;

-- resources: name uniqueness per kind + owner for child entities
CREATE UNIQUE INDEX idx_resources_kind_owner_name
    ON resources (kind, owner_id, name)
    WHERE owner_id != '' AND deleted_at IS NULL;

-- resources: child lookups
CREATE INDEX idx_resources_owner_id ON resources (owner_id) WHERE owner_id != '';

-- resources: kind filter (drives all list queries)
CREATE INDEX idx_resources_kind ON resources (kind);

-- resources: soft delete
CREATE INDEX idx_resources_deleted_at ON resources (deleted_at);

-- resource_labels: no extra index needed — the composite PK (resource_id, key) is the leading index
-- and covers all "WHERE resource_id = ?" queries efficiently.

-- resource_conditions: no extra index needed — the composite PK (resource_id, type) is the leading
-- index and covers all "WHERE resource_id = ?" queries efficiently. Uniqueness per (resource_id, type)
-- is enforced by the PK itself.

-- resource_references: target lookup for deletion restriction and reverse lookup queries
CREATE INDEX idx_resource_references_source ON resource_references (source_id);
CREATE INDEX idx_resource_references_target ON resource_references (target_id);
```

</details>

<details>
<summary>Table: resource_references</summary>

| Column | Type | Notes |
|---|---|---|
| `source_id` | `VARCHAR(255)` NOT NULL FK → `resources(id)` | Part of composite PK |
| `ref_type` | `VARCHAR(255)` NOT NULL | Part of composite PK — e.g., `"wif_config"`, `"network"` |
| `target_id` | `VARCHAR(255)` NOT NULL FK → `resources(id)` | Part of composite PK |
| `target_kind` | `VARCHAR(100)` NOT NULL | Kind of the target resource — e.g., `"WifConfig"` |

Primary key: `(source_id, ref_type, target_id)` — allows multiple targets per refType, enforces no duplicates. No surrogate ID.

`idx_resource_references_source` covers reference preloading on `Get`. `idx_resource_references_target` covers `FindReferencers` (deletion restriction) and `FindByTypeAndTarget` (reverse lookup).

</details>

Name uniqueness is scoped **per entity kind**: a Cluster named `"prod"` and a NodePool named `"prod"` can coexist. Two Clusters named `"prod"` cannot.

### 4.3 `ResourceDao` (`pkg/dao/resource.go`)

Single DAO interface replacing `ClusterDao` and `NodePoolDao`. All queries include `kind = ?` as a scope condition. `Get` and `GetByOwner` always preload `Labels` and `Conditions`. List operations preload them via `GenericService`'s `Preload` chain.

<details>
<summary>ResourceDao interface</summary>

```go
type ResourceDao interface {
    // Get fetches a resource with its Labels, Conditions, and References preloaded.
    Get(ctx context.Context, resourceType, id string) (*api.Resource, error)

    // GetByOwner fetches a resource and validates it belongs to the given owner.
    // Labels, Conditions, and References are preloaded.
    GetByOwner(ctx context.Context, resourceType, id, ownerID string) (*api.Resource, error)

    // Create inserts the resource row, then inserts all Labels and References.
    // Conditions are empty on create; they are set later by UpdateConditions.
    Create(ctx context.Context, resource *api.Resource) (*api.Resource, error)

    // Replace updates the resource row and replaces all Labels (delete + insert).
    // Conditions are not touched by Replace; use UpdateConditions for that.
    // Increments Generation when Spec or Labels change.
    Replace(ctx context.Context, resource *api.Resource) (*api.Resource, error)

    // UpdateConditions replaces all ResourceCondition rows for the given resource.
    UpdateConditions(ctx context.Context, resourceID string, conditions []api.ResourceCondition) error

    // ReplaceReferences replaces all resource_references rows for sourceID atomically
    // (delete + bulk insert). Called by Create and Replace when references are present.
    ReplaceReferences(ctx context.Context, sourceID string, refs []api.ResourceReference) error

    // FindReferencers returns resources that hold a reference to targetID.
    // Returns only enough rows to construct a descriptive error message (kind + name of the first referencer).
    // Used by the deletion restriction check in Delete.
    FindReferencers(ctx context.Context, targetID string) ([]api.ResourceSummary, error)

    // FindByTypeAndTarget returns all resources of resourceType whose references map
    // contains targetID under refType. Used for reverse lookup list queries.
    FindByTypeAndTarget(ctx context.Context, resourceType, refType, targetID string) (api.ResourceList, error)

    Delete(ctx context.Context, resourceType, id string) error
    CountByOwner(ctx context.Context, resourceType, ownerID string) (int64, error)
    FindByType(ctx context.Context, resourceType string) (api.ResourceList, error)
    FindByTypeAndOwner(ctx context.Context, resourceType, ownerID string) (api.ResourceList, error)
    FindByIDs(ctx context.Context, ids []string) (api.ResourceList, error)
}
```

</details>

**Key implementation notes:**

- `Create` — inserts the resource row first (omitting associations), then bulk-inserts labels and references. Conditions are not inserted by the DAO; `ResourceService.Create` calls `UpdateStatusFromAdapters` immediately after to initialize them.
- `Replace` — fetches the existing row with its labels preloaded, increments `Generation` if either `Spec` or `Labels` changed, updates the resource row, then replaces labels with a delete + bulk-insert. When `references` is present in the PATCH body, calls `ReplaceReferences` for that resource. Conditions are intentionally excluded; they are written only by `UpdateConditions`.

`UpdateConditions` — called exclusively by the status aggregation path. Replaces all condition rows for the resource atomically.

`Replace` and `UpdateConditions` are on separate code paths deliberately: `Replace` is called by user-initiated spec/label updates; `UpdateConditions` is called only by the status aggregation pipeline. This separation keeps user-writable and system-computed state from interfering.

---

## 5. Entity Registry

### 5.1 `EntityDescriptor` (`pkg/registry/descriptor.go`)

The descriptor is the complete, declarative definition of an entity type. Registering a descriptor is the only action needed to add a new entity type to the system.

Entity descriptors are loaded from the application's existing config YAML at startup and used to populate the registry. No Go code is required for standard entities.

<details>
<summary>EntityDescriptor struct</summary>

```go
// ReferenceDescriptor declares a non-ownership association from this entity type to another.
// Min/Max constrain how many referenced resources of this type the entity may hold.
type ReferenceDescriptor struct {
    // RefType is the key used in the references map on the Resource API type.
    // Must be unique within an entity's References slice. e.g., "wif_config", "network".
    RefType string

    // TargetKind is the Kind of the referenced entity. Must resolve to a registered
    // EntityDescriptor at startup. e.g., "WifConfig", "Network".
    TargetKind string

    // Min is the minimum number of references of this type the entity must hold.
    // 0 = optional. Enforced on Create and Patch.
    Min int

    // Max is the maximum number of references of this type the entity may hold.
    // 0 = unlimited. Must satisfy: Max == 0 OR Max >= Min.
    Max int
}

// OnParentDeletePolicy determines what happens to a child entity when its parent is deleted.
type OnParentDeletePolicy string

const (
    // OnParentDeleteRestrict prevents deletion of the parent while this child exists (default).
    OnParentDeleteRestrict OnParentDeletePolicy = "restrict"
    // OnParentDeleteCascade soft-deletes this child when its parent is deleted.
    OnParentDeleteCascade OnParentDeletePolicy = "cascade"
)

// EntityDescriptor defines everything specific to a HyperFleet entity type.
// Registering a descriptor auto-generates all routes, spec validation,
// status aggregation, and delete behavior for that entity type.
type EntityDescriptor struct {
    // Type is the discriminator value stored in Resource.Kind.
    // Must be unique across all registered descriptors. e.g., "Cluster", "NodePool".
    Type string

    // Plural is the URL path segment for this entity's endpoints.
    // e.g., "clusters", "nodepools".
    Plural string

    // NameMinLen and NameMaxLen constrain the name field on Create and Patch.
    NameMinLen int
    NameMaxLen int

    // ParentType is the Type value of this entity's owner.
    // Empty string means this is a top-level entity (no parent route generated).
    // e.g., "" for Cluster; "Cluster" for NodePool.
    ParentType string

    // OnParentDelete determines what happens to this entity when its parent is deleted.
    // Only meaningful when ParentType != "".
    // OnParentDeleteRestrict (default): parent deletion is rejected with 409 if this entity exists.
    // OnParentDeleteCascade: this entity is soft-deleted when its parent is deleted.
    OnParentDelete OnParentDeletePolicy

    // RequiredAdapters lists the adapter names that must report for this entity's
    // Ready and Available conditions to be computed.
    RequiredAdapters []string

    // SearchDisallowedFields prevents specific fields from being used in TSL search.
    // Key and value are both the field name. e.g., {"spec": "spec"}.
    SearchDisallowedFields map[string]string

    // SpecSchemaName is the name of the schema component in the additional OpenAPI
    // contract (server.openapi_schema_path) used to validate the spec field on
    // Create and Patch requests.
    // Empty string = no spec validation (accept any JSON object).
    // e.g., "ClusterSpec", "NodePoolSpec".
    SpecSchemaName string

    // References declares the non-ownership associations this entity type may hold.
    // Each entry is validated at startup: TargetKind must resolve to a registered
    // descriptor, RefType must be unique within the slice, and Max == 0 OR Max >= Min.
    // See [§9](#9-resource-references) for the full reference model.
    References []ReferenceDescriptor
}
```

</details>

### 5.2 Global registry (`pkg/registry/registry.go`)

```go
func Register(d *EntityDescriptor)                       // panics on duplicate Type
func Get(entityType string) (*EntityDescriptor, bool)
func MustGet(entityType string) *EntityDescriptor        // panics if not found
func All() []*EntityDescriptor                           // all registered descriptors
func ChildrenOf(parentType string) []*EntityDescriptor   // descriptors with ParentType == parentType

// LoadFromConfig reads entity descriptors from the application config and registers them.
// Called during Env.Initialize() before route registration.
func LoadFromConfig(cfg config.ApplicationConfig)

// Validate checks all ParentType references resolve, all ReferenceDescriptor TargetKinds
// resolve, RefType uniqueness within each entity, Max == 0 OR Max >= Min for each reference,
// and SpecSchemaName existence in the provider OpenAPI spec. Called at startup before
// the server accepts requests. Panics with a descriptive message on failure.
func Validate()
```

Descriptors are loaded from the application config file. The `Validate()` call in `Env.Initialize()` catches missing parent registrations, invalid reference descriptors, and schema mismatches immediately at startup.

### 5.3 Entity configuration examples

Entity types are declared in the application's existing config YAML (e.g., `config.yaml`). No Go code is required for standard entities — only a new config entry and a redeploy.

```yaml
# In config.yaml — entities section
entities:
  - type: Cluster
    plural: clusters
    nameMinLen: 3
    nameMaxLen: 53
    specSchemaName: ClusterSpec
    requiredAdapters: [provisioner, lifecycle]
    searchDisallowedFields: [spec]
    references:
      - refType: wif_config
        targetKind: WifConfig
        min: 1      # one is required
        max: 1      # at most one WifConfig per Cluster; max: 0 means unlimited
      - refType: network
        targetKind: Network
        min: 0
        max: 0      # unlimited Networks per Cluster

  - type: NodePool
    plural: nodepools
    nameMinLen: 3
    nameMaxLen: 15
    parentType: Cluster
    onParentDelete: cascade
    specSchemaName: NodePoolSpec
    requiredAdapters: [provisioner, lifecycle]
    searchDisallowedFields: [spec]

  - type: WifConfig
    plural: wifconfigs
    nameMinLen: 3
    nameMaxLen: 63
    specSchemaName: WifConfigSpec
    requiredAdapters: []
    # No references declared — WifConfig is only ever the target of references.
```

That is all per-entity configuration required. No DAO, no service, no handler, no presenter, no Go code.

### 5.4 Href generation

Each resource carries a relative `href` field that uniquely identifies it within the API. The href is computed once at creation time by the service layer using the entity's descriptor and its resolved parent chain and stored in the `resources.href` column. It is never recomputed after creation because the `id` (UUID) and the `Plural` path segment are both stable for the lifetime of the resource.

**Format:**

```text
# Top-level entity
/api/hyperfleet/v1/{plural}/{id}

# Child entity — embeds the full parent path
/api/hyperfleet/v1/[{parent-plural}/{parent_id}...]/{plural}/{id}
```

Examples for a NodePool (parent: Cluster):

```text
/api/hyperfleet/v1/clusters/c-abc123/nodepools/np-xyz789
```

The href is relative (no scheme or host). Clients that need an absolute URL prepend the base URL from their configuration. This avoids storing environment-specific hostnames in the database and prevents href staleness across environment promotions.

#### Constraint: child entity creation requires parent context in the URL

Because the child href embeds the parent ID, it can only be constructed correctly when the parent ID is known at the moment of creation. The parent ID is available in the URL path variable (`{parent_id}`) on the nested generated routes, but is absent from the generic root endpoint:

```text
# Parent ID is in the URL — href can be constructed
POST /api/hyperfleet/v1/clusters/{parent_id}/nodepools   ✓

# No parent ID in the URL — href cannot be constructed
POST /api/hyperfleet/v1/resources                          ✗ (for child entity types)
```

**Design decision:** `POST /api/hyperfleet/v1/resources` is restricted to top-level entity types only (descriptors with `ParentType == ""`). Attempting to create a child entity type via the generic root endpoint returns `422 Unprocessable Entity` with a message directing the caller to the nested route. See [§11.6](#116-child-entity-creation-via-the-generic-root-endpoint) for the alternative considered.

---

## 6. Spec Field Validation

HyperFleet accepts JSON as the `spec` property of a `Resource`. To provide greater guarantees about the data being stored, a validation process is performed on the `spec` contents using a provider-specific OpenAPI schema with the full detail of the entities schemas.

### 6.1 Current implementation

`SchemaValidationMiddleware` (`pkg/middleware/schema_validation.go`) already validates the `spec` field of POST and PATCH requests before they reach the handler. It uses `SchemaValidator` (`pkg/validators/schema_validator.go`) to evaluate the spec against a named schema component in the OpenAPI YAML at `server.openapi_schema_path`.

The current implementation hardcodes the entity type → schema name mapping (`"cluster"` → `ClusterSpec`, `"nodepool"` → `NodePoolSpec`) and uses URL pattern matching to detect the entity type.

### 6.2 Additional OpenAPI contract (spec schemas)

A separate YAML file (configured via `server.openapi_schema_path`) contains provider-specific spec schemas for entities. This is the OpenAPI exposed to final customers, provided by the ROSA/GCP teams.

The `SpecSchemaName` field on `EntityDescriptor` replaces the hardcoded mapping, allowing the schema name to be specified per entity kind in the config.

**Startup validation:** During `registry.Validate()`, the system loads the OpenAPI document at `server.openapi_schema_path` and checks every registered descriptor:

1. The `SpecSchemaName` must resolve to an existing schema component. If missing, the server panics with: `entity "Cluster": specSchemaName "ClusterSpec" not found in OpenAPI spec at <path>`.
2. If the resolved schema defines `minLength`/`maxLength` on the `name` property, these are cross-checked against the descriptor's `NameMinLen`/`NameMaxLen`. A mismatch produces a startup warning.
3. If `SpecSchemaName` is empty (no spec validation for this entity), the check is skipped.

A CI integration test should load the production config and the provider's OpenAPI spec, run `LoadFromConfig()` + `Validate()`, and fail the build on any mismatch — catching drift before deployment.

**Request-time validation:** When a request is made (POST/PATCH) containing a `spec`, the middleware uses the entity registry to look up the `SpecSchemaName` for the entity kind and validates the payload against that schema.

No changes to the middleware or validator are required, only how to extract the name of the schema to use from the entity registry.

---

## 7. Handler Layer

### 7.1 Shared presenter (`pkg/api/presenters/resource.go`)

Replaces all per-entity `ConvertCluster`, `PresentCluster`, `ConvertNodePool`, `PresentNodePool` functions.

<details>
<summary>ConvertResource + PresentResource</summary>

```go
func ConvertResource(
    req *openapi.ResourceCreateRequest,
    entityKind, ownerID, ownerKind, ownerHref, createdBy string,
) *api.Resource {
    specJSON, _ := json.Marshal(req.Spec)

    // Build []ResourceLabel from the request labels map.
    var labels []api.ResourceLabel
    for k, v := range req.Labels {
        labels = append(labels, api.ResourceLabel{Key: k, Value: v})
    }

    // Build []ResourceReference from the request references map.
    var refs []api.ResourceReference
    for refType, targets := range req.References {
        for _, t := range targets {
            refs = append(refs, api.ResourceReference{
                RefType:    refType,
                TargetID:   t.Id,
                TargetKind: t.Kind,
            })
        }
    }

    return &api.Resource{
        Kind:       entityKind,
        Name:       req.Name,
        Spec:       specJSON,
        Labels:     labels,
        References: refs,
        OwnerID:    ownerID,
        OwnerKind:  ownerKind,
        OwnerHref:  ownerHref,
        CreatedBy:  createdBy,
        UpdatedBy:  createdBy,
    }
}

func PresentResource(r *api.Resource) openapi.Resource {
    var spec map[string]interface{}
    json.Unmarshal(r.Spec, &spec)

    // Labels are typed structs from the resource_labels table — no JSON unmarshal needed.
    labels := make(map[string]string, len(r.Labels))
    for _, l := range r.Labels {
        labels[l.Key] = l.Value
    }

    // References are typed structs from the resource_references table.
    // Group by RefType; TargetKind is stored alongside TargetID to avoid secondary lookups.
    references := make(map[string][]openapi.ObjectReference)
    for _, ref := range r.References {
        references[ref.RefType] = append(references[ref.RefType], openapi.ObjectReference{
            Id:   ref.TargetID,
            Kind: ref.TargetKind,
            Href: hrefForReference(ref),
        })
    }

    // Conditions are typed structs from the resource_conditions table — no JSON unmarshal needed.
    result := openapi.Resource{
        Id: r.ID, Kind: r.Kind, Name: r.Name, Href: r.Href,
        Spec: spec, Labels: labels, Generation: r.Generation,
        References:  references,
        CreatedTime: r.CreatedTime, UpdatedTime: r.UpdatedTime,
        CreatedBy: openapi_types.Email(r.CreatedBy),
        UpdatedBy: openapi_types.Email(r.UpdatedBy),
        Status: openapi.ResourceStatus{Conditions: toOpenAPIConditions(r.Conditions)},
    }
    if r.OwnerID != "" {
        result.OwnerReferences = &openapi.ObjectReference{
            Id: r.OwnerID, Kind: r.OwnerKind, Href: r.OwnerHref,
        }
    }
    return result
}
```

</details>

### 7.2 `ResourceHandler` (`pkg/handlers/resource.go`)

A single handler struct, instantiated once per registered descriptor. Handles CRUD for one entity type via the `handlerConfig` pipeline.

<details>
<summary>ResourceHandler struct and method signatures</summary>

```go
type ResourceHandler struct {
    descriptor *registry.EntityDescriptor
    service    services.ResourceService
    generic    services.GenericService
}

// Top-level routes
// List supports optional reference filter query params: ref_type + ref_target_id (see §9.4).
func (h *ResourceHandler) List(w http.ResponseWriter, r *http.Request)
func (h *ResourceHandler) Create(w http.ResponseWriter, r *http.Request)
func (h *ResourceHandler) Get(w http.ResponseWriter, r *http.Request)
func (h *ResourceHandler) Patch(w http.ResponseWriter, r *http.Request)
func (h *ResourceHandler) Delete(w http.ResponseWriter, r *http.Request)

// Nested routes — child entity accessed under parent path
func (h *ResourceHandler) ListByOwner(w http.ResponseWriter, r *http.Request)
func (h *ResourceHandler) CreateWithOwner(w http.ResponseWriter, r *http.Request)
func (h *ResourceHandler) GetByOwner(w http.ResponseWriter, r *http.Request)
func (h *ResourceHandler) PatchByOwner(w http.ResponseWriter, r *http.Request)
func (h *ResourceHandler) DeleteByOwner(w http.ResponseWriter, r *http.Request)
```

</details>

Example — `GetByOwner` (child entity accessed via parent path):
<details>
<summary>GetByOwner handler</summary>

```go
func (h *ResourceHandler) GetByOwner(w http.ResponseWriter, r *http.Request) {
    vars := mux.Vars(r)
    parentID, id := vars["parent_id"], vars["id"]

    handleGet(w, r, &handlerConfig{
        Action: func() (interface{}, *errors.ServiceError) {
            // Verify parent exists
            _, err := h.service.Get(r.Context(), h.descriptor.ParentType, parentID)
            if err != nil { return nil, err }

            resource, err := h.service.GetByOwner(r.Context(), h.descriptor.Type, id, parentID)
            if err != nil { return nil, err }

            return presenters.PresentResource(resource), nil
        },
    })
}
```

</details>

Example — `Delete` (policy driven by descriptor, no query parameter):

<details>
<summary>Delete handler</summary>

```go
func (h *ResourceHandler) Delete(w http.ResponseWriter, r *http.Request) {
    id := mux.Vars(r)["id"]
    handleDelete(w, r, &handlerConfig{
        Action: func() (interface{}, *errors.ServiceError) {
            return nil, h.service.Delete(r.Context(), h.descriptor.Type, id)
        },
    }, http.StatusAccepted)
}
```

</details>

### 7.3 `ResourceStatusHandler` (`pkg/handlers/resource_status.go`)

Handles `GET` and `PUT` on `/{id}/statuses` for all entity types. The `{id}` path variable is the same whether accessed via a top-level or nested route.

<details>
<summary>ResourceStatus handler</summary>

```go
type ResourceStatusHandler struct {
    descriptor       *registry.EntityDescriptor
    resourceService  services.ResourceService
    adapterStatusSvc services.AdapterStatusService
}

func (h *ResourceStatusHandler) List(w http.ResponseWriter, r *http.Request)
func (h *ResourceStatusHandler) Create(w http.ResponseWriter, r *http.Request)
```

</details>

### 7.4 Auto route registration (`pkg/handlers/entity_routes.go`)

Called once from `cmd/hyperfleet-api/server/routes.go`, after config loading and `registry.Validate()` complete. Replaces all per-entity plugin route registration calls.

<details>
<summary>RegisterEntityRoutes</summary>

```go
func RegisterEntityRoutes(
    apiV1Router *mux.Router,
    resourceService services.ResourceService,
    adapterStatusService services.AdapterStatusService,
    genericService services.GenericService,
) {
    for _, descriptor := range registry.All() {
        h := NewResourceHandler(descriptor, resourceService, genericService)
        sh := NewResourceStatusHandler(descriptor, resourceService, adapterStatusService)

        base := "/" + descriptor.Plural
        r := apiV1Router.PathPrefix(base).Subrouter()
        r.HandleFunc("", h.List).Methods(http.MethodGet)
        r.HandleFunc("", h.Create).Methods(http.MethodPost)
        r.HandleFunc("/{id}", h.Get).Methods(http.MethodGet)
        r.HandleFunc("/{id}", h.Patch).Methods(http.MethodPatch)
        r.HandleFunc("/{id}", h.Delete).Methods(http.MethodDelete)
        r.HandleFunc("/{id}/statuses", sh.List).Methods(http.MethodGet)
        r.HandleFunc("/{id}/statuses", sh.Create).Methods(http.MethodPost)

        if descriptor.ParentType != "" {
            parent := registry.MustGet(descriptor.ParentType)
            pr := apiV1Router.PathPrefix("/" + parent.Plural + "/{parent_id}/" + descriptor.Plural).Subrouter()
            pr.HandleFunc("", h.ListByOwner).Methods(http.MethodGet)
            pr.HandleFunc("", h.CreateWithOwner).Methods(http.MethodPost)
            pr.HandleFunc("/{id}", h.GetByOwner).Methods(http.MethodGet)
            pr.HandleFunc("/{id}", h.PatchByOwner).Methods(http.MethodPatch)
            pr.HandleFunc("/{id}", h.DeleteByOwner).Methods(http.MethodDelete)
            pr.HandleFunc("/{id}/statuses", sh.List).Methods(http.MethodGet)
            pr.HandleFunc("/{id}/statuses", sh.Create).Methods(http.MethodPost)
        }
    }
}
```

</details>

---

## 8. Delete Model for Owned Resources

### 8.1 Descriptor-driven delete policy

Delete behavior for child entities is declared on the **child's** `EntityDescriptor` via `OnParentDelete`. This mirrors database foreign key semantics (`ON DELETE CASCADE` / `ON DELETE RESTRICT`) and keeps the policy co-located with the entity it governs. See [§11.2](#112-delete-model-for-owned-resources) for alternatives considered.

```go
type OnParentDeletePolicy string

const (
    OnParentDeleteRestrict OnParentDeletePolicy = "restrict" // default
    OnParentDeleteCascade  OnParentDeletePolicy = "cascade"
)
```

When a resource is deleted, the service iterates all registered child types and applies each child's policy:

- **`restrict`** — if any active children of this type exist, return `409 Conflict`. No partial deletion occurs.
- **`cascade`** — mark all children of this type deleted recursively (DFS, innermost first) before deleting the parent. Each child then follows the service-layer soft/hard rule: a child participating in adapter deletion reconciliation is soft-deleted until all adapters report `Finalized=True` and its own soft-deleted children are gone; a child not participating in adapter deletion reconciliation is hard-deleted in the same transaction, unless it still has soft-deleted children of its own, in which case it stays soft-deleted until a subsequent DELETE (it has no finalization event of its own — see [HYPERFLEET-1721](https://redhat.atlassian.net/browse/HYPERFLEET-1721)).

Different child types of the same parent can have different policies. For example, a Cluster might have NodePools (`cascade`) and AuditLogs (`restrict`) — deleting the Cluster cascades to NodePools but is blocked if AuditLogs exist.

There is no caller-supplied query parameter. The API surface is simply:

```text
DELETE /clusters/{id} → 202 Accepted  (NodePools cascade)
                      → 409 Conflict    (if a restrict-policy child exists)
```

### 8.2 Service layer implementation

A single `Delete` method handles all cases. `DeleteCascade` is not a separate method.

The snippet below illustrates only the child-policy loop; the service also checks references ([§9.3](#93-deletion-restriction)) and applies the per-resource soft/hard decision described above — a resource participating in adapter deletion reconciliation, or with soft-deleted children, is soft-deleted; the rest are hard-deleted in the same transaction.

<details>
<summary>Delete service implementation</summary>

```go
func (s *sqlResourceService) Delete(ctx context.Context, resourceType, id string) *errors.ServiceError {
    for _, child := range registry.ChildrenOf(resourceType) {
        count, _ := s.dao.CountByOwner(ctx, child.Type, id)
        if count == 0 {
            continue
        }
        switch child.OnParentDelete {
        case registry.OnParentDeleteCascade:
            children, _ := s.dao.FindByTypeAndOwner(ctx, child.Type, id)
            for _, c := range children {
                if err := s.Delete(ctx, c.Type, c.ID); err != nil {
                    return err
                }
            }
        default: // OnParentDeleteRestrict
            return errors.Conflict("HYPERFLEET-CNF-001",
                "cannot delete %s %q: has %d active %s(s)",
                resourceType, id, count, child.Type)
        }
    }
    return handleDeleteError(resourceType, s.dao.Delete(ctx, resourceType, id))
}
```

</details>

All delete bookkeeping happens within the existing transaction-per-request middleware: the tree is marked deleted atomically or not at all, and any resource that does not need to wait for adapter finalization is hard-deleted in the same transaction. A resource participating in adapter deletion reconciliation is left soft-deleted until all adapters report `Finalized=True` and no soft-deleted children remain; a resource not participating in adapter deletion reconciliation that still has soft-deleted children is left soft-deleted until a subsequent DELETE (nothing re-evaluates it once its children are gone — see [HYPERFLEET-1721](https://redhat.atlassian.net/browse/HYPERFLEET-1721)). If a restrict-policy child is found after some cascade-policy children have already been deleted, the transaction rolls back and nothing is persisted.

---

## 9. Resource References

### 9.1 Overview

Resource references model non-ownership associations between entities. Unlike the owner/child relationship ([§8](#8-delete-model-for-owned-resources)), a referenced resource does not own the referencing resource, and the same resource can be referenced by many others.

**Example:** `WifConfig` can be associated with a `Cluster`. A single `WifConfig` can be used by many Clusters. The association is optional and does not make `WifConfig` the owner of `Cluster`.

**Properties:**

- Declared statically per entity type in config — no Go code required (see [§5.1](#51-entitydescriptor-pkgregistrydescriptorgo) for `ReferenceDescriptor`, [§5.3](#53-entity-configuration-examples) for config examples).
- Stored in a dedicated `resource_references` join table (see [§4.1](#41-gorm-types-pkgapiresourcego)–[§4.3](#43-resourcedao-pkgdaoresourcego)).
- Exposed as a typed map on the `Resource` API type with values always as arrays of `ObjectReference` (see [§3.1](#31-core-types)).
- Mutable: a PATCH replaces the full `references` map.
- Required references enforced at Create and Patch time.
- Deleting a referenced resource is **blocked** (`409 Conflict`) if any resource holds a reference to it.

---

### 9.2 API representation

The `references` field is a map keyed by `refType`. Values are always arrays of `ObjectReference`, regardless of the declared `max`. Keys absent from the map mean the entity holds no entries for that `refType`.

**Example — Cluster with a WifConfig and two Networks:**

```json
{
  "id": "cl-abc123",
  "kind": "Cluster",
  "name": "prod",
  "references": {
    "wif_config": [{"id": "wc-xyz", "kind": "WifConfig", "href": "/api/hyperfleet/v1/wifconfigs/wc-xyz"}],
    "network":    [
      {"id": "net-1", "kind": "Network", "href": "/api/hyperfleet/v1/networks/net-1"},
      {"id": "net-2", "kind": "Network", "href": "/api/hyperfleet/v1/networks/net-2"}
    ]
  }
}
```

**PATCH semantics:** the `references` field follows a three-way distinction:

| PATCH body value | Meaning | Effect |
|---|---|---|
| field absent / `null` | "I am not changing references" | References are left untouched |
| `{}` (empty object) | "I want zero references" | All existing reference rows are deleted; `min > 0` constraints are enforced and return `422` if violated |
| `{"wif_config": [...]}` | "Replace references with this map" | Existing rows are deleted and replaced atomically; `min`/`max` constraints are enforced across the resulting map |

When `references` is present (including `{}`), the service validates the resulting state against every declared `ReferenceDescriptor` (`min`/`max`) before persisting. `null` and a missing field are treated identically — neither triggers `ReplaceReferences`.

---

### 9.3 Deletion restriction

The reference restriction applies to **every** resource deletion, whether initiated directly or as part of an owned-children cascade ([§8](#8-delete-model-for-owned-resources)). Before deleting a resource, the service checks whether any other resource holds a reference to it:

```go
func (s *sqlResourceService) Delete(ctx context.Context, resourceType, id string) *errors.ServiceError {
    // Reference restriction — checked before owned-children cascade/restrict.
    // Applies on every recursive cascade call, not just the root delete.
    referencers, _ := s.dao.FindReferencers(ctx, id)
    if len(referencers) > 0 {
        r := referencers[0]
        return errors.Conflict("HYPERFLEET-REF-001",
            "cannot delete %s %q: referenced by %s %q — remove the reference before deleting",
            resourceType, id, r.Kind, r.Name)
    }

    // Owned-children policy (existing §8 logic follows).
    for _, child := range registry.ChildrenOf(resourceType) {
        // ...
    }
    return handleDeleteError(resourceType, s.dao.Delete(ctx, resourceType, id))
}
```

`FindReferencers` replaces the coarse `CountByTarget` — it returns the first referencing resource (kind + name) so the error message names exactly what is blocking the deletion and what the caller must remove.

#### Interaction with cascade deletes

Because `Delete` is called recursively during cascade, the reference check applies at every level of the ownership tree. Consider:

```text
Cluster "prod"
  └── NodePool "workers"    (OnParentDelete: cascade)

UpgradePolicy "nightly"     (references NodePool "workers" via ref_type: target_node_pool)
```

`DELETE /clusters/prod` proceeds as follows:

1. Reference check on `prod` → nothing references the Cluster → proceed
2. Cascade: `Delete(NodePool, "workers")` is called
3. Reference check on `workers` → `UpgradePolicy "nightly"` references it → **409 Conflict**

```text
409 Conflict: cannot delete NodePool "workers": referenced by UpgradePolicy "nightly"
              — remove the reference before deleting
```

The error surfaces on a Cluster delete request but names the NodePool and the UpgradePolicy blocking it. This is intentional: the restriction is strict and conservative. The caller must remove `UpgradePolicy "nightly"` (or its reference to `workers`) before the Cluster can be deleted.

This is a deliberate choice over cascade-deleting referencers or skipping the check during cascade — both of which risk silently destroying resources the caller did not intend to remove. See [§11.7](#117-resource-references-design) for alternatives considered.

---

### 9.4 Reverse lookup

Callers can find all resources of a given type that reference a specific resource using two query parameters on the standard list endpoint:

| Parameter | Description |
|---|---|
| `ref_type` | The `refType` key on the referencing entity (e.g., `wif_config`) |
| `ref_target_id` | The ID of the referenced resource (e.g., `wc-xyz`) |

**Example — all Clusters using WifConfig `wc-xyz`:**

```text
GET /api/hyperfleet/v1/clusters?ref_type=wif_config&ref_target_id=wc-xyz
```

Both parameters must be provided together. Providing only one returns `400 Bad Request`. The handler validates that `ref_type` is a declared `refType` on the entity's descriptor before querying, returning `400` for unknown values.

The query joins `resource_references` on `source_id = resources.id` filtered by `ref_type` and `target_id`, leveraging `idx_resource_references_target`. Pagination, ordering, and TSL search compose with these filters normally.

---

## 10. No Migration, No Backward Compatibility

The database is initialized from scratch. There is no existing data to migrate and no requirement to maintain API compatibility with the current per-entity endpoints.

**What this removes from the implementation scope:**

- Data migration SQL
- Parallel API versioning
- Backward-compatible field defaults or shims
- Feature flags for old/new code path switching

**Database migrations:**

```text
202604080001_add_resources.go           — CREATE TABLE resources + indexes
202604080002_add_resource_labels.go     — CREATE TABLE resource_labels
202604080003_add_resource_conditions.go — CREATE TABLE resource_conditions
202604080004_add_resource_references.go — CREATE TABLE resource_references + indexes
```

The `clusters` and `node_pools` tables are not dropped — the database is initialized from scratch with no pre-existing tables.

The `adapter_statuses` table is unchanged. Its `resource_type` column already stores the entity kind string (`"Cluster"`, `"NodePool"`) and needs no migration.

---

## 11. Alternatives and Tradeoffs

This section documents the most critical design decisions, the alternatives considered, and why each was accepted or rejected.

### 11.1 Separate tables vs. JSONB for labels and conditions

**Chosen:** `resource_labels` and `resource_conditions` as dedicated tables with natural composite PKs.

**Alternative — Keep JSONB columns on `resources` (original design)**

Store `labels JSONB` and `status_conditions JSONB` on the `resources` row.

- Pro : No joins; simpler DAO with no association preloading
- Pro : Single-row reads for `Get`
- Con : Filtering by label key/value requires GIN index + JSONB operators (`@>`, `?`) — more complex queries
- Con : DB cannot enforce uniqueness of condition `type` per resource — duplicates possible
- Con : Updating a single condition requires full JSON replace at the application level
- Con : `UpdateConditions` and `Replace` write to the same column — status aggregation and user edits can race or interfere

**Alternative — Generated/stored columns computed from `status_conditions JSONB`**

Keep the JSONB column — an array of condition records (`[{"type": "Reconciled", "status": "False", ...}, ...]`), matching the shape `jsonb_path_query_first` already used for the expression indexes HYPERFLEET-536 removed — but add `GENERATED ALWAYS AS (...) STORED` columns for specific condition type/subfield pairs, e.g. a `reconciled_status` column defined as `jsonb_path_query_first(status_conditions, '$[*] ? (@.type == "Reconciled")') ->> 'status'`, with a normal B-tree index on each.

- Pro : A plain B-tree index on the generated column sidesteps the jsonpath/Squirrel placeholder conflict entirely — no expression-index tricks needed
- Pro : Less invasive than full normalization — additive, no new table or association preloading
- Con : Doesn't generalize — every new condition type or subfield that needs fast lookup requires its own generated column and migration, which works against a registry meant to support arbitrary condition types across N entity kinds
- Con : Updating conditions is still a full-JSON replace from the application; none of the plain-JSONB write-complexity cons above are solved
- Con : DB still cannot enforce uniqueness of a condition `type` inside the JSONB blob — only the pre-chosen generated columns get structure, everything else stays an unconstrained blob

**Why chosen:** Both JSONB-based alternatives only make a handful of pre-selected condition lookups fast; neither solves the general case the registry needs — arbitrary condition types, uniqueness per `(resource_id, type)`, and simple writes — without the application re-encoding and replacing the whole blob on every update. Dedicated tables solve all of that uniformly, with ordinary indexes and ordinary SQL, at the cost of a join most callers already pay for via `Preload`.

---

### 11.2 Delete model for owned resources

**Chosen:** Descriptor-driven `OnParentDelete` policy on the child entity. See [§8](#8-delete-model-for-owned-resources) for the implementation.

<details>
<summary><strong>Alternative A — Restrict only</strong></summary>

A parent cannot be deleted while it has active children. `409 Conflict` always; no cascade option.

- Pro : Safest; impossible to accidentally delete a tree
- Pro : Simplest service implementation — no cascade path
- Con : UX friction for deep hierarchies; caller must delete children bottom-up in multiple round trips

</details>

<details>
<summary><strong>Alternative B — Cascade always</strong></summary>

Deleting a parent immediately soft-deletes all descendants recursively, with no opt-out.

- Pro : Single operation removes the entire tree
- Con : Destructive with no warning; easy to delete large trees accidentally
- Con : A large tree (thousands of children) can cause the request to time out

</details>

<details>
<summary><strong>Alternative C — Caller-controlled cascade (`?cascade=true`) — previously chosen</strong></summary>

Default behavior is Restrict. The caller passes `?cascade=true` to opt into recursive soft-delete. `EntityDescriptor.AllowCascadeDelete` controls whether the flag is accepted.

```text
DELETE /clusters/{id}              → 409 Conflict (has active children)
DELETE /clusters/{id}?cascade=true → 202 Accepted
```

- Pro : Explicit: the caller signals intent at the call site
- Pro : Same DELETE endpoint; behavior toggled by a query parameter
- Con : Behavior is split between the API call and the descriptor — two places to understand
- Con : All children of a parent cascade or restrict uniformly; different policies per child type require multiple `AllowCascadeDelete` flags and more complex handler logic
- Con : Clients must know to pass the flag; forgetting it returns 409 even when cascade is the only sensible behavior

</details>

**Why chosen (descriptor-driven `OnParentDelete`):** The policy belongs to the child entity, not to the caller or the API call. Different child types of the same parent can legitimately require different behaviors — cascade for NodePools, restrict for hypothetical audit-log children — which a single `?cascade=true` flag cannot express. Placing the policy on the child's descriptor makes behavior inspectable at startup, eliminates a query parameter from the API surface, and keeps the `Delete` handler trivially simple.

There is a hard deletion option via `POST /{id}/force-delete` that will cascade delete all entities from a root entity for administrative tasks, bypassing the reference restriction and `OnParentDelete` policies.

---

### 11.3 Entity configuration: where entity types are defined

**Chosen:** Entity descriptors declared in the application's existing config YAML file, with startup validation that cross-checks every descriptor against the provider's OpenAPI spec. The server reads them at startup to populate the registry. No Go code is required for standard entities.

```yaml
# config.yaml — entities section
entities:
  - type: Cluster
    plural: clusters
    nameMinLen: 3
    nameMaxLen: 53
    specSchemaName: ClusterSpec
    requiredAdapters: [provisioner, lifecycle]
    searchDisallowedFields: [spec]
```

**Config–OpenAPI sync enforcement:**

The `EntityDescriptor` contains fields that reference the provider's OpenAPI spec (e.g., `SpecSchemaName: ClusterSpec`). These two artifacts — the config YAML and the OpenAPI spec at `server.openapi_schema_path` — must stay in sync. The design enforces this at two levels:

1. **Startup validation** — `registry.Validate()` loads the OpenAPI document and asserts that every descriptor's `SpecSchemaName` resolves to an existing schema component. A missing schema causes a startup panic with a descriptive message naming the entity kind and the expected schema (e.g., `entity "Cluster": specSchemaName "ClusterSpec" not found in OpenAPI spec at <path>`). Additionally, if the resolved schema defines `minLength`/`maxLength` on the `name` property, these are cross-checked against the descriptor's `NameMinLen`/`NameMaxLen` — a mismatch produces a startup warning.

2. **CI integration test** — A test loads the production config YAML and the provider's OpenAPI spec, runs `LoadFromConfig()` + `Validate()`, and fails the build on any mismatch. This catches drift before deployment and ensures no silent failures if the config or the OpenAPI spec evolves independently.

- Pro : Adding a standard entity requires only a new config entry and a redeploy — no Go code
- Pro : Config is readable, diffable, and reviewable without Go knowledge
- Pro : Integrates with existing config management — same file, same deployment tooling, same GitOps workflows
- Pro : `registry.Validate()` catches misconfiguration at startup: unknown `parentType`, missing OpenAPI schemas, name constraint divergence
- Pro : Provider's OpenAPI spec remains clean and customer-facing — no HyperFleet-specific metadata injected
- Con : Two artifacts (config YAML + OpenAPI spec) must stay in sync — but the contract is machine-verified at startup and in CI, not manually enforced
- Con : Route registration still happens at startup; config must be fully loaded before the router is built. No hot-reload without a server restart

**Why chosen:** All current `EntityDescriptor` fields for Cluster and NodePool are plain config values — no custom hooks exist. Defining entities in the application config eliminates all per-entity Go code while keeping the deployment and configuration model consistent. The startup validation and CI test close the sync gap between config and OpenAPI, making mismatches fail-fast rather than silent. Compiled Go descriptors remain available as an escape hatch for entities that need behavior hooks.

<details>
<summary><strong>Alternative A — OpenAPI-augmented (x-hyperfleet vendor extensions)</strong></summary>

The provider's OpenAPI spec becomes the single configuration source. Each entity schema carries `x-hyperfleet` vendor extensions that declare the non-derivable descriptor fields. At startup, the server parses the OpenAPI file, discovers all schemas with `x-hyperfleet` extensions, and builds EntityDescriptors from them.

```yaml
# In the provider's OpenAPI spec
ClusterSpec:
  x-hyperfleet:
    plural: clusters
    requiredAdapters: [provisioner, lifecycle]
    searchDisallowedFields: [spec]
  properties:
    name:
      type: string
      minLength: 3
      maxLength: 53
    # ... full spec schema
```

The entity kind is derived from the schema name (`ClusterSpec` → `Cluster`). `SpecSchemaName` is implicit — it is the schema itself. `NameMinLen`/`NameMaxLen` are read directly from the schema's `name` property constraints.

- Pro : Single source of truth — no sync gap possible; if the schema is removed, its entity registration disappears
- Pro : Providers already own and maintain the OpenAPI file
- Pro : Name constraints cannot diverge — they come from the schema definition
- Con : Pollutes the provider's customer-facing OpenAPI spec with internal infrastructure metadata (`x-hyperfleet`); code generators and API consumers see fields they cannot interpret
- Con : `ParentType` and `OnParentDelete` create cross-references between schemas (e.g., `NodePoolSpec.x-hyperfleet.parentType: Cluster`) that are awkward to express and validate in OpenAPI
- Con : Vendor extensions are opaque to standard OpenAPI tooling — linters, documentation generators, and SDK generators ignore them
- Con : Providers must learn the `x-hyperfleet` extension schema and keep it correct alongside their own spec definitions

</details>

<details>
<summary><strong>Alternative B — Thin config YAML + convention-based auto-discovery</strong></summary>

Config YAML declares only fields that cannot be derived from OpenAPI: `Plural`, `ParentType`, `OnParentDelete`, `RequiredAdapters`, `SearchDisallowedFields`. The `SpecSchemaName` field is removed. Instead, the system uses a naming convention: entity kind `Cluster` maps to schema `ClusterSpec` (i.e., `{Kind}Spec`). `NameMinLen`/`NameMaxLen` are read from the schema's `name` property constraints at startup.

```yaml
entities:
  - type: Cluster
    plural: clusters
    requiredAdapters: [provisioner, lifecycle]
    searchDisallowedFields: [spec]
```

Startup validation confirms the derived schema exists and extracts name constraints. No manual `specSchemaName` to drift.

- Pro : Reduces config surface — fewer fields that can desync with the OpenAPI spec
- Pro : Name constraints have one source (the schema)
- Pro : Provider's OpenAPI stays clean — no vendor extensions
- Con : Rigid naming convention — breaks if a provider names their schema differently (e.g., `ClusterConfiguration` instead of `ClusterSpec`)
- Con : Could add an optional `specSchemaName` override as an escape hatch, which reintroduces the sync risk for overridden entries
- Con : Convention must be documented and enforced across all providers; a team that doesn't know the rule silently fails

</details>

<details>
<summary><strong>Alternative C — Kubernetes CRDs</strong></summary>

Entity types are defined as Kubernetes Custom Resource Definitions. The API server reads CRD files from a folder at boot time to populate the registry.

```yaml
apiVersion: hyperfleet.io/v1alpha1
kind: EntityType
metadata:
  name: machinepool
spec:
  plural: machine-pools
  parentType: NodePool
  nameMinLen: 3
  nameMaxLen: 30
  specSchemaName: MachinePoolSpec
  requiredAdapters: [provisioner, lifecycle]
```

CRDs can embed OpenAPI v3 validation schemas directly, so the spec schema itself is not duplicated. However, the provider must translate their existing OpenAPI spec into CRD format (`apiVersion`, `metadata`, `spec` wrapper), maintaining two representations of the same entities in different formats.

- Pro : Standard Kubernetes extension mechanism — operators and GitOps workflows apply naturally
- Pro : CRD schema validation (via OpenAPI v3 in the CRD spec) can enforce descriptor correctness at apply time
- Pro : If the API server runs inside a Kubernetes cluster, CRDs can be watched for dynamic registration
- Con : Requires the API server to run inside (or alongside) a Kubernetes cluster — rules out bare-metal or non-k8s deployments
- Con : Dynamic route registration is fundamentally incompatible with gorilla/mux, which builds its routing tree at startup; routes cannot be added at runtime without restarting the router. CRD watching is limited to static boot-time loading.
- Con : Adds a hard dependency on the Kubernetes API and `controller-runtime` or `client-go` — significant operational complexity
- Con : Entity type changes become a cluster operation rather than a code change; harder to test locally
- Con : Providers already maintain a complete OpenAPI spec with all entity schemas. CRDs require re-expressing entity metadata in Kubernetes-native format, adding a translation step that must be kept aligned with the OpenAPI source

</details>

<details>
<summary><strong>Alternative D — Entity types in a database table</strong></summary>

Entity types are stored in a `entity_types` table. The API server reads them at startup (or on each request) and builds descriptors dynamically.

- Pro : Entity types can be added without redeploying — a DB row insert is enough
- Pro : No Kubernetes dependency
- Pro : Standard CRUD tooling can manage entity type definitions
- Con : `RequiredAdapters` is a function of the runtime adapter config — it cannot be stored as a plain DB column; adapter requirements would need a separate join table or JSON column
- Con : Dynamic route registration has the same problem as CRDs: gorilla/mux cannot add routes after startup without a server restart
- Con : Behavior hooks (`ValidateSpec`) are Go functions — they cannot be stored in a DB row; only configuration can be persisted, not logic
- Con : The DB becomes a source of truth for schema-level concerns, coupling schema evolution (migrations) with runtime configuration
- Con : A misconfigured row (e.g., a `parentType` that doesn't exist) can corrupt the registry at runtime; the current design catches this at startup via `registry.Validate()`
- Con : When creating a new environment, we need to populate the database with the entities. This makes less descriptive/GitOps operations

</details>

<details>
<summary><strong>Alternative E — Compiled Go descriptors</strong></summary>

Entity types are declared as Go `EntityDescriptor` structs and registered at startup via `init()` — compiled directly into the binary.

```go
func init() {
    registry.Register(&registry.EntityDescriDtor{
        Type:           "Cluster",
        Plural:         "clusters",
        NameMinLen:     3,
        NameMaxLen:     53,
        SpecSchemaName: "ClusterSpec",
        RequiredAdapters: func(cfg config.AdapterRequirementsConfig) []string {
            return cfg.RequiredClusterAdapters()
        },
        SearchDisallowedFields: map[string]string{"spec": "spec"},
    })
}
```

- Pro : Type-safe: compiler catches missing fields and type mismatches
- Pro : Behavior hooks (`RequiredAdapters` as a typed function) are natively expressible
- Pro : No config schema to define or keep in sync
- Con : Adding a new entity type requires a Go code change and a new release — no config-only path
- Con : `RequiredAdapters` as a function of runtime config is more indirection than needed for the current entity set
- Con : Per-entity `init()` registration in plugin packages creates coupling between plugin structure and registry bootstrapping

</details>

**Why not chosen (alternatives A–E):** Alternative A (vendor extensions) eliminates the sync gap but pollutes the provider's customer-facing OpenAPI spec with internal metadata. Alternative B (convention-based) reduces config surface but imposes a rigid naming convention that providers may not follow. Alternative C (CRDs) adds Kubernetes infrastructure dependencies and requires providers to maintain entity metadata in a second format. Alternative D (database) couples schema concerns with runtime state and loses GitOps workflows. Alternative E (compiled Go) adds unnecessary release friction for what are currently plain config values. The chosen approach (config YAML + startup validation) preserves the simplicity of config-driven registration while machine-verifying the contract between config and OpenAPI spec — making mismatches fail-fast rather than silent.

---

### 11.4 Naming the generic entity type

The single Go/OpenAPI/DB type that unifies all entity kinds needs a name. This name appears in the API route (`/resources`), the OpenAPI schema (`Resource`), the Go struct (`Resource`), and the DB table (`resources`).

Some alternative names for `Resource` could be selected.

| Name | API route | Go type | DB table |
|---|---|---|---|
| **`Resource`** (chosen) | `/resources` | `Resource` | `resources` |
| `Entity` | `/entities` | `Entity` | `entities` |
| `ManagedEntity` | `/managed-entities` | `ManagedEntity` | `managed_entities` |
| `Object` | `/objects` | `Object` | `objects` |

**Chosen: `Resource`**

Standard REST vocabulary, recognized by API consumers across OpenAPI ecosystems and major cloud APIs (AWS, GCP, Azure all use "resource" for generic managed objects). The `kind` discriminator field makes the concrete entity kind unambiguous regardless of the container name.

- Con : "resource" is already a broad REST term that can refer to any endpoint, not specifically this type
- Accepted : the `kind` field disambiguates at the value level; callers always work with typed responses

<details>
<summary><strong>Alternative A — <code>Entity</code></strong></summary>

Precise to the domain concept; avoids overloading the REST meaning of "resource".

- Pro : Maps cleanly to "entity" in domain modeling and the document's own language
- Con : Creates terminology collision with `EntityDescriptor` in the registry — two distinct concepts share the word "entity", which makes the doc and code harder to follow
- Con : Less familiar as an API surface term; most HTTP APIs use "resource" or "object"

</details>

<details>
<summary><strong>Alternative B — <code>ManagedEntity</code></strong></summary>

Distinguishes HyperFleet-managed things from any other REST resources the API might expose.

- Pro : Explicitly signals lifecycle management intent
- Pro : Avoids collision with both REST "resource" and the registry's "entity"
- Con : Verbose everywhere: `/managed-entities`, `ManagedEntity`, `ManagedEntityList`, `managed_entities`, `managed_entity_labels` — all table and type names grow
- Con : The "managed" qualifier is implicit for everything served by this API; it adds no information

</details>

<details>
<summary><strong>Alternative C — <code>Object</code></strong></summary>

Used by Kubernetes for all API objects (`metav1.Object`, object store, etc.).

- Pro : Familiar to teams coming from the Kubernetes ecosystem
- Con : Extremely generic — no domain signal at all
- Con : `Object` in Go conventionally suggests `interface{}` or an untyped value, which conflicts with the concrete, typed struct this represents
- Con : HyperFleet is not a Kubernetes API; importing Kubernetes naming without the Kubernetes machinery is likely to confuse rather than clarify

</details>

---

### 11.5 Computed vs. stored conditions

**Chosen:** Conditions are computed by `AggregateResourceStatus` when adapter statuses change and persisted to the `resource_conditions` table. Reads serve stored rows directly.

#### Alternative — Compute conditions on every read

The new design changed the Status Conditions from JSON to its own table. One additional change could be simplifying it or even eliminating and computing the values on request.

When a `GET` request arrives, fetch the resource row and its `adapter_statuses` rows, run `AggregateResourceStatus` in-process, and return the result without writing anything.

- Pro : Write path simplifies: `PUT /{id}/statuses` writes one `adapter_statuses` row and returns — no aggregation, no secondary write
- Pro : Conditions are always current — no stale window between an adapter report and the next read
- Pro : Removes `resource_conditions` table, `ResourceDao.UpdateConditions`, and the two-step `Create` workflow that initializes conditions immediately after insert
- Pro : `ProcessAdapterStatus` becomes a pure single-row write with no side effects
- Con : **`LastTransitionTime` semantics break.** The field is only meaningful when compared against the previously stored status. Without history, you can only report the time the adapter last wrote — not when the condition actually transitioned.
- Con : **`CreatedTime` semantics break.** Currently preserved from the first time a condition appears. Without storage there is no record of when a condition type first existed.
- Con : Every `GET /{id}` now requires two reads: resource row + `adapter_statuses`. Currently a single preloaded read suffices.
- Con : List queries become heavier: a page of N resources requires fetching `adapter_statuses` for all N IDs (one batched query, but significantly more data).
- Con : Aggregation cost moves from writes (amortized, triggered only on change) to reads (on every request). Under read-heavy workloads this increases CPU and DB load proportionally to request rate.

**Why not chosen:** `LastTransitionTime` and `CreatedTime` are the blocking issue. Both fields record *when* something happened — information that cannot be derived from the current adapter reports alone. Dropping them would be a breaking API contract change and would remove signals that operators rely on to understand how long a cluster has been in a degraded state. Preserving them requires storing at least the previous condition state per resource, which is what the `resource_conditions` table does. Any lighter alternative (e.g., storing only transition timestamps) offers marginal savings while keeping most of the complexity.

If the API contract were ever relaxed to remove `LastTransitionTime` and `CreatedTime`, this approach becomes viable and would meaningfully simplify the write path.

---

### 11.6 Child entity creation via the generic root endpoint

**Chosen:** `POST /api/hyperfleet/v1/resources` is restricted to top-level entity types. Child entities must be created through their generated nested route (`POST /{parent-plural}/{parent_id}/{plural}`), which provides the parent ID in the URL. Attempting to create a child type via the root endpoint returns `422 Unprocessable Entity`.

**Why this constraint exists:** The child's `href` embeds the parent ID (e.g., `/api/hyperfleet/v1/clusters/c-abc/nodepools/np-xyz`). The parent ID is only available from the URL path on the nested route. Without it, the service cannot construct a correct, stable href at creation time.

**Alternative — Accept `owner_references` in `ResourceCreateRequest` for child entities**

Extend `ResourceCreateRequest` with an optional `owner_references` field:

```yaml
ResourceCreateRequest:
  required: [kind, name, spec]
  properties:
    kind:             { type: string }
    name:             { type: string }
    spec:             { type: object, additionalProperties: true }
    labels:           { type: object, additionalProperties: { type: string } }
    owner_references: { $ref: '#/components/schemas/ObjectReference' }  # optional
```

The service would validate that `owner_references` is present and refers to a valid parent when the entity type has a `ParentType`, then use it to look up the parent resource and construct the child href.

- Pro : The generic `POST /resources` endpoint works uniformly for all entity types — no need for callers to discover and use nested routes
- Con : The request body becomes the authority on ownership — a caller could supply an incorrect or unauthorized parent ID. The nested route derives ownership from the URL, which is easier to authorize via middleware
- Con : `ResourceCreateRequest` becomes partially entity-aware: the `owner_references` field is required for child types and meaningless for top-level types, with no schema-level enforcement of that distinction
- Con: Goes against common REST conventions

**Why not chosen:** The nested routes already encode ownership structurally. Allowing root-level creation of child entities trades route clarity for endpoint uniformity and introduces ownership validation concerns that the URL-based approach avoids by construction.

---

### 11.7 Resource references design

**Chosen:** `resource_references` join table with `(source_id, ref_type, target_id)` composite PK; references exposed as a typed map on the `Resource` API type keyed by `refType`, values always arrays of `ObjectReference`; cardinality and optionality expressed via `min`/`max` on `ReferenceDescriptor`; deletion of a referenced resource is blocked with `409`; reverse lookup via query parameters `ref_type` + `ref_target_id` on the list endpoint of the referencing entity type.

<details>
<summary><strong>Alternative A — Store reference IDs inside <code>spec</code></strong></summary>

Reference IDs are plain fields in the entity's `spec` JSON blob. No new table. The caller sets `spec.wif_config_id = "wc-xyz"` and the server validates it exists.

- Pro : No schema changes — references are just another spec field
- Pro : No new table or DAO methods
- Con : References are invisible to the infrastructure — no deletion restriction is enforceable without scanning every entity's JSONB spec
- Con : Reverse lookup ("all Clusters using WifConfig X") requires a GIN index on `spec` and a JSONB query — expensive and fragile
- Con : Cardinality, required status, and target kind are opaque to the registry — cannot be validated at startup or enforced uniformly at the handler layer
- Con : `href` for the referenced resource cannot be included in the response without a secondary DB read per reference

</details>

<details>
<summary><strong>Alternative B — Separate column per reference type on the <code>resources</code> table</strong></summary>

Add `wif_config_id VARCHAR(255)`, `network_ids TEXT[]`, etc. as columns on the `resources` table. Each new reference type requires a migration.

- Pro : Standard FK semantics enforceable at the DB level for single-value references
- Pro : Simple indexed lookups
- Con : Every new reference type requires a schema migration and a new column — defeats the goal of adding entity types without code or migration changes
- Con : Array columns (`TEXT[]`) for multi-valued references have limited indexing support and no FK enforcement
- Con : Cannot be driven by config — the column must exist before the descriptor is registered

</details>

<details>
<summary><strong>Alternative C — Cascade-delete referencing resources when referenced resource is deleted</strong></summary>

Instead of blocking deletion of a referenced resource, cascade-delete all resources that reference it.

- Pro : Single DELETE operation removes the entire graph without 409 friction for the caller
- Con : Referencing resources (e.g., Clusters) are far more expensive and consequential than the referenced resource (e.g., WifConfig) — silently deleting Clusters because a WifConfig was removed would be destructive and surprising
- Con : The caller deleting a lightweight shared resource may not know which high-value resources depend on it
- Con : Unlike owner/child cascade (where the parent's deletion is clearly the authoritative event), a shared resource deletion is not semantically "the end" of its dependents

</details>

<details>
<summary><strong>Alternative D — Reverse lookup via a generated nested route on the referenced entity</strong></summary>

Generate routes like `GET /wifconfigs/{id}/clusters` that list all resources referencing the given WifConfig. Mirrors the parent/child route pattern from [§3.2](#32-routes).

- Pro : Clean REST hierarchy — consumers of WifConfig are nested under it
- Pro : No new query parameters; route structure is self-documenting
- Con : The referenced entity (WifConfig) is not the owner — embedding referencing resources as nested routes implies ownership semantics that do not exist
- Con : Route count grows with every reference relationship declared, whereas query parameters on existing list routes add no new routes
- Con : The referenced entity ID must appear in the URL path, constraining how the route can be composed with other filters

</details>

**Why chosen:** The `resource_references` join table gives the infrastructure visibility into all relationships without scanning JSONB, enables indexed reverse lookups, and supports deletion restriction with a targeted query. `min`/`max` on the descriptor unifies required/optional and single/multiple into one expressive field while keeping cardinality enforcement in one place. Blocking deletion (rather than cascading) is the safe default for shared resources that have no ownership semantics. Query parameters for reverse lookup avoid adding new routes and compose naturally with existing pagination and filtering.

#### Cascade delete interaction (explicitly chosen: always restrict)

The reference restriction applies at every level of an owned-children cascade, not just at the root. When `Delete` is called recursively on a cascade-deleted child, the child's inbound references are checked before it is removed. Two alternatives were rejected:

- *Skip reference check during cascade* — leaves `resource_references` rows pointing to soft-deleted resources, producing dangling references that corrupt subsequent queries and reverse lookups.
- *`OnTargetDelete` policy on `ReferenceDescriptor`* (cascade or restrict per refType) — adds complexity and creates a path to silently deleting resources the caller did not intend to remove. Shared resources (e.g., a `WifConfig` or an `UpgradePolicy`) referenced by multiple entities should never be destroyed as a side effect of another entity's cascade.

The chosen approach is conservative: if any resource in the cascade tree is referenced, the entire operation fails with a 409 that names the blocking resource and its referencer, giving the caller a clear remediation path.

---

## 12. Risks

### R1 — Single-table database performance

All entity types share the `resources` table. As the number of entity types and total row count grows, queries that filter by `type` (every list operation) compete for the same table, indexes, and WAL. A burst of writes for one entity type increases I/O pressure for all others.

**Remediation:** The `idx_resources_kind` index covers the common filter path and limits full-table scans. If a single entity type grows to dominate the table (tens of millions of rows), PostgreSQL declarative partitioning by the `type` column can be applied without changing the application — the table structure and GORM struct are unchanged. Monitor per-type row counts and query latency from the start so partitioning can be introduced before it becomes urgent.

---

### R2 — Loss of domain modeling flexibility

The generic `EntityDescriptor` captures configuration (name constraints, adapters, spec schema, delete policy) but has no slot for entity-specific business logic — pre-create validation, state machine transitions, cross-entity consistency checks, or derived fields. If a future entity type requires rules that go beyond what the descriptor fields can express, there is no standard extension point.

**Remediation:** The Go `Register()` path is the intended escape hatch: an entity that needs custom logic registers its descriptor in code rather than config, and the relevant service methods can be overridden by wrapping `ResourceService` with a type-specific decorator. The pattern should be documented so teams know how to extend without forking the shared infrastructure. If multiple entities accumulate custom logic, introduce a `Hooks` field on `EntityDescriptor` with well-defined `BeforeCreate`, `BeforeDelete`, and `AfterStatusUpdate` callbacks.

**Remediation 2:** If business logic required is not too complex, a CEL expression engine can be added to perform certain checks on entities and customizable through the registry.

---

## Appendix A. Current State

Context on the pre-generalization codebase — the duplication that motivates this design.

### A.1 Entity anatomy

Both Cluster and NodePool share the following structure across all layers:

| Layer | Shared fields / behavior |
|---|---|
| GORM model | `Meta` (ID, timestamps, soft delete), `Kind` (discriminator), `Name`, `Href`, `CreatedBy`, `UpdatedBy`, `Spec` (JSONB), `Labels` (JSONB), `StatusConditions` (JSONB), `Generation` |
| DAO interface | `Get`, `Create`, `Replace`, `Delete`, `FindByIDs`, `All` |
| Service interface | `Get`, `Create`, `Replace`, `Delete`, `All`, `FindByIDs`, `UpdateStatusFromAdapters`, `ProcessAdapterStatus` |
| Handler | `List`, `Get`, `Create`, `Patch`, `Delete` via `handlerConfig` pipeline |
| Plugin | `RegisterService`, `RegisterRoutes`, `RegisterPath`, `RegisterKind` |

### A.2 What differs per entity

| Dimension | Cluster | NodePool |
|---|---|---|
| Name max length | 53 chars | 15 chars |
| Parent reference | None (top-level) | `owner_id` → Cluster |
| Name uniqueness scope | Global per type | Per parent per type |
| Route prefix | `/clusters` | `/clusters/{id}/nodepools` |
| Adapter config accessor | `RequiredClusterAdapters()` | `RequiredNodePoolAdapters()` |
| Spec schema name | `ClusterSpec` | `NodePoolSpec` |

### A.3 Existing generic abstractions (must be preserved and extended)

- `pkg/dao/generic.go` — chainable query builder for List (pagination, TSL search, ordering, joins)
- `pkg/services/generic.go` — reflection-based List with JSONB field support (~417 lines)
- `pkg/services/aggregation.go` — `AggregateResourceStatus()` is fully entity-agnostic
- `pkg/api/adapter_status_types.go` — `AdapterStatus` already uses `ResourceType` + `ResourceID` for polymorphism
- `pkg/middleware/schema_validation.go` — validates `spec` field against a named OpenAPI schema component
- `pkg/validators/schema_validator.go` — loads and evaluates OpenAPI schema components

### A.4 Code duplication quantified

| Layer | Lines per entity | Duplication |
|---|---|---|
| DAO (`cluster.go` / `node_pool.go`) | ~102 | ~95% |
| Service (`cluster.go` / `node_pool.go`) | ~310 | ~80% |
| Presenter (`cluster.go` / `node_pool.go`) | ~150 | ~85% |
| Plugin + handler | ~270 | ~75% |
| **Total** | **~832** | |

---
