---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-01-13
---

# HyperFleet Generated Code Policy

## 1. Overview

This document establishes the policy for handling generated code in HyperFleet repositories.

- **Related Docs:** [Makefile Conventions](makefile-conventions.md)

### What is Generated Code?

Generated code refers to any files automatically created by tools from source specifications. These files should never be manually edited.

**Examples in HyperFleet:**

| File Pattern | Generator | Source |
|--------------|-----------|--------|
| `model_*.go` | oapi-codegen | OpenAPI specification (`openapi.yaml`) |
| `*_mock.go` | mockgen | Go interfaces |
| `*.pb.go` | protoc | Protocol Buffer definitions (`.proto`) |

**Key Decision:** Generated code **MUST NOT** be committed to Git repositories. Instead, it is generated on-demand during the build process.

---

## 2. Rationale

### Why not commit generated code?

| Problem | Impact |
|---------|--------|
| Merge conflicts | Generated files frequently conflict when multiple developers modify source specs |
| Sync issues | Generated code can become out-of-sync with source specifications |
| Repository bloat | Large generated files increase clone times and repository size |
| Accidental edits | Developers may accidentally modify generated files instead of source specs |
| Unclear ownership | Confusion about whether specs or generated code is the source of truth |

### Benefits of on-demand generation

| Benefit | Description |
|---------|-------------|
| Single source of truth | Specifications are the authoritative source |
| Always in sync | Generated code is always derived from current specs |
| Smaller repositories | Reduced clone time and disk usage |
| Clear workflow | Developers know to modify specs, not generated files |
| Industry alignment | Follows best practices for generated artifacts |

---

## 3. Affected Repositories and File Patterns

### Repositories

| Repository | Generated Code Location | Source Specification | Status |
|------------|------------------------|---------------------|--------|
| `hyperfleet-api` | `pkg/api/openapi/`, `*_mock.go` | `openapi/openapi.yaml` (owned) | ✅ Compliant |
| `hyperfleet-sentinel` | `pkg/api/openapi/` | `openapi/openapi.yaml` (fetched from hyperfleet-api) | ✅ Compliant |

**Note:** `hyperfleet-adapter`, `hyperfleet-broker`, and adapter repositories do not currently have generated code.

### File Patterns to Exclude

Each repository should add appropriate patterns to `.gitignore`. Note the distinction between **generated code** (auto-created from specs) and **fetched sources** (downloaded but not generated).

**hyperfleet-api:**

```gitignore
# Generated OpenAPI code (from oapi-codegen)
/pkg/api/openapi/
/data/generated/

# Generated mock files
*_mock.go
```

**hyperfleet-sentinel:**

```gitignore
# Generated OpenAPI client (from oapi-codegen)
pkg/api/openapi/

# Fetched OpenAPI spec (downloaded from hyperfleet-api, not generated)
openapi/openapi.yaml
```

---

## 4. Developer Workflow

### Prerequisites

Developers **MUST** have the following tools installed:

- **Podman** or **Docker** - Required for running code generation in containers
- **Make** - Required for running build targets

### First-time Setup

```bash
# Clone the repository
git clone https://github.com/openshift-hyperfleet/<repo-name>
cd <repo-name>

# Generate code before building or testing
make generate

# Build the project
make build

# Run tests
make test
```

### Daily Workflow

1. **Pull latest changes:** `git pull`
2. **Regenerate code:** `make generate` (or rely on `make build`/`make test` dependencies)
3. **Make changes:** Edit source specifications (not generated files)
4. **Regenerate:** `make generate`
5. **Build and test:** `make build && make test`
6. **Commit:** Only commit source specification changes

### Important Notes

- **Never edit generated files directly** - Changes will be overwritten
- **Always run `make generate` after pulling** - Ensures generated code matches current specs
- **Generation is idempotent** - Safe to run multiple times

---

## 5. Makefile Requirements

All HyperFleet repositories with generated code **MUST** follow the [Makefile Conventions](makefile-conventions.md) with these additional requirements:

### Required Target

Repositories with generated code **MUST** implement a `generate` target:

```makefile
.PHONY: generate
generate: ## Generate code from specifications
    # Repository-specific generation commands
```

### Target Dependencies

The `generate` target **MUST** be a prerequisite for `build` and `test` targets:

```makefile
build: generate ## Build the binary
test: generate ## Run unit tests
test-integration: generate ## Run integration tests
```

### Generation Characteristics

| Requirement | Description |
|-------------|-------------|
| Idempotent | Running multiple times produces identical output |
| Deterministic | Same input specifications produce same output |
| Containerized | Uses Podman/Docker for reproducibility |

---

## 6. CI/CD Pipeline Requirements

All CI/CD pipelines **MUST**:

1. Run `make generate` as the **first step** (or rely on `make build` dependency)
2. Fail the build if generation fails
3. Optionally verify no generated files are committed

### Optional: Verify No Generated Files Committed

Add a CI job to ensure generated files are not accidentally committed:

```bash
make generate
if git diff --name-only | grep -E "(model_.*\.go|\.pb\.go|_gen\.go)"; then
  echo "ERROR: Generated files were committed to the repository"
  echo "Please remove them and add patterns to .gitignore"
  exit 1
fi
```

---

## 7. Code generator tool

We selected [oapi-codegen](https://github.com/oapi-codegen/oapi-codegen) tool as the generator for our apps.
Here is a detailed comparison among different alternatives:

### OpenAPI Code Generation Comparison

  Overview

  | Aspect          | (OpenAPI Generator        | ogen                                      | oapi-codegen         |
  |-----------------|---------------------------|-------------------------------------------|----------------------|
  | Files Generated | 34                        | 20                                        | 2                    |
  | Lines of Code   | ~11,274                   | ~20,261                                   | ~2,530               |
  | Runtime Deps    | None (stdlib only)        | ogen-go/ogen, go-faster/jx, OpenTelemetry | oapi-codegen/runtime |

  ---

#### 1. main/ - OpenAPI Generator (Java-based)

  Type Style:

```
  type Cluster struct {
      CreatedTime time.Time `json:"created_time"`
      Name string `json:"name" validate:"regexp=^[a-z0-9]([-a-z0-9]*[a-z0-9])?$"`
      Spec map[string]interface{} `json:"spec"`
      Labels *map[string]string `json:"labels,omitempty"`  // pointer for optional
      Id *string `json:"id,omitempty"`
  }
```

  Strengths:

- ✅ No runtime dependencies - uses only stdlib (encoding/json)
- ✅ Null-safety pattern with NullableCluster wrapper types
- ✅ Constructor functions (NewCluster, NewClusterWithDefaults)
- ✅ Validation in UnmarshalJSON - checks required properties
- ✅ GetXxxOk() methods return tuple (value, bool) for presence checking
- ✅ HasXxx() methods for optional field presence
- ✅ ToMap() method for generic map conversion
- ✅ Mature tooling - widely used, extensive documentation

  Weaknesses:

- ❌ Verbose - each model in separate file with many boilerplate methods
- ❌ Pointer-based optionals (*string) - less idiomatic for Go
- ❌ No built-in validation beyond required field checking
- ❌ Flattens allOf schemas - loses composition structure
- ❌ Java dependency - requires JVM to run generator

  ---

#### 2. ogen/ (Go-native generator)

  Type Style:

```
  type Cluster struct {
      ID          OptString     `json:"id"`           // Optional type wrapper
      Kind        string        `json:"kind"`
      Labels      OptClusterLabels `json:"labels"`
      Name        string        `json:"name"`
      Spec        ClusterSpec   `json:"spec"`
      Generation  int32         `json:"generation"`
      Status      ClusterStatus `json:"status"`
  }

  type OptString struct {
      Value string
      Set   bool
  }
```

  Strengths:

- ✅ Opt[T] types for optionals - explicit presence tracking, no nil pointer issues
- ✅ Built-in validation (oas_validators_gen.go) with structured errors
- ✅ OpenTelemetry integration - tracing/metrics out of the box
- ✅ Enum validation with MarshalText/UnmarshalText
- ✅ High-performance JSON using go-faster/jx (no reflection)
- ✅ Generated getters/setters for all fields
- ✅ Pure Go toolchain - no JVM needed
- ✅ Server + Client generation in same package
- ✅ Type-safe response types (GetClusterByIdRes interface)

  Weaknesses:

- ❌ Largest output (~20k lines) - more code to maintain
- ❌ Heavy runtime dependencies - ogen-go/ogen, go-faster/*, OTel
- ❌ Learning curve - Opt[T] pattern different from idiomatic Go
- ❌ Less flexibility - opinionated about patterns
- ❌ Flattens allOf - doesn't preserve schema composition

  ---

#### 3. oapi-codegen/ (Go-native generator)

  Type Style:

```
  type Cluster struct {
      // Preserves allOf composition!
      ClusterBase `yaml:",inline"`

      CreatedBy   openapi_types.Email `json:"created_by"`  // Typed email
      CreatedTime time.Time           `json:"created_time"`
      Generation  int32               `json:"generation"`
      Status      ClusterStatus       `json:"status"`
  }

  type ClusterBase struct {
      APIResource `yaml:",inline"`
      Kind string `json:"kind"`
      Name string `json:"name"`
      Spec ClusterSpec `json:"spec"`
  }
```

  Strengths:

- ✅ Most compact (~2.5k lines, 2 files) - minimal footprint
- ✅ Preserves allOf composition - embedded structs match schema
- ✅ Semantic types - openapi_types.Email instead of string
- ✅ Lightweight runtime - just oapi-codegen/runtime
- ✅ Pure Go toolchain - no JVM
- ✅ ClientWithResponses - parsed response bodies with type safety
- ✅ RequestEditorFn pattern - clean auth/middleware injection
- ✅ Go-idiomatic - feels like handwritten Go code

  Weaknesses:

- ❌ No built-in validation - must add manually or use external
- ❌ Pointer-based optionals (*string) - though less pervasive
- ❌ Fewer accessor methods - direct field access preferred
- ❌ Less observability - no OTel integration
- ❌ Returns *http.Response - need ClientWithResponses for parsed bodies

  ---
  Comparison Summary

  | Feature            | main/       | ogen/        | oapi-codegen/ |
  |--------------------|-------------|--------------|---------------|
  | Code Size          | Medium      | Large        | Small ✅      |
  | Runtime Deps       | None ✅     | Heavy        | Light         |
  | Optional Handling  | Pointers    | Opt[T] ✅    | Pointers      |
  | Validation         | Basic       | Full ✅      | None          |
  | Schema Composition | Flattened   | Flattened    | Preserved ✅  |
  | Observability      | None        | OTel ✅      | None          |
  | Go Idiomaticity    | Medium      | Medium       | High ✅       |
  | Type Safety        | Good        | Excellent ✅ | Good          |
  | Maintenance        | Java needed | Go           | Go            |

  ---
  **Recommendation**

  For our use case (types + client only):

- oapi-codegen is the best fit if you want minimal, Go-idiomatic code that preserves your schema composition (allOf inheritance). The embedded struct pattern (ClusterBase → Cluster) is clean and matches your OpenAPI design.
- ogen is better if you need built-in validation, observability (OTel), or are building a complete server+client solution. The Opt[T] pattern is cleaner than nil pointers.
- OpenAPI Generator (main/) is worth keeping if you need maximum compatibility or zero runtime dependencies, though the Java requirement and verbose output are downsides.

---

## 8. References

- [Makefile Conventions](makefile-conventions.md)
- [HYPERFLEET-303](https://issues.redhat.com/browse/HYPERFLEET-303)
- [oapi-codegen](https://github.com/deepmap/oapi-codegen)
- [Protocol Buffers](https://protobuf.dev/)
