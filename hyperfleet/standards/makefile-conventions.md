---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-11-18
---

# HyperFleet Makefile Conventions

## Table of Contents

1. [Overview](#overview)
2. [Goals](#goals)
3. [Standard Targets](#standard-targets)
4. [Repository Type Variations](#repository-type-variations)
5. [Flag Conventions](#flag-conventions)
6. [References](#references)

---

## Overview

This document defines standard Makefile targets and conventions for all HyperFleet repositories. Following these conventions reduces cognitive load when switching between repos, enables consistent CI/CD pipelines, and improves developer onboarding.

### Scope

This standard applies to:

- All HyperFleet service repositories
- All adapter repositories (adapter-pullsecret, adapter-dns, etc.)
- Infrastructure and tooling repositories

### Problem Statement

Currently, different HyperFleet repositories use different target names for similar operations:

- Some use `make compile`, others use `make build` or `make binary`
- Binary output locations vary (some use `bin/`, others use project root)
- CI pipelines have inconsistent invocations across repos
- Engineers must read each Makefile to understand available commands

This inconsistency creates unnecessary friction and slows down development.

---

## Goals

1. **Reduce cognitive load** - Same commands work across all repos
2. **Enable automation** - CI/CD pipelines can use standard targets
3. **Improve onboarding** - New developers learn once, apply everywhere
4. **Increase reliability** - Consistent behavior reduces errors
5. **Support tooling** - Claude plugin and scripts can assume standard targets

---

## Standard Targets

### Required Targets

Other repository types **MUST** use the applicable minimum target set in [Repository Type Variations](#repository-type-variations).

Service repositories **MUST** implement the following targets:

| Target | Description | Expected Behavior | Example Output |
|--------|-------------|-------------------|----------------|
| `help` | Display available targets | Print formatted list of targets with descriptions | Help text to stdout |
| `build` | Build all binaries | Compile source code to executable binaries | Outputs to `bin/` directory |
| `test` | Run unit tests | Execute all unit tests with coverage | Coverage report + pass/fail |
| `lint` | Run linters | Execute configured linters (golangci-lint, yamllint, etc.) | Linting violations or success |
| `clean` | Remove build artifacts | Delete all generated files (binaries, coverage, build cache) | Empty `bin/`, `build/` directories |

### Example: Required targets

```bash
make help           # See all available targets
make build          # Compile binaries
make test           # Run tests
make lint           # Run linters
make clean          # Clean up
```

### Optional Targets

Repositories **MAY** implement these targets if applicable:

| Target | Description | When to Use | Example |
|--------|-------------|-------------|---------|
| `generate` | Generate code from specifications | If repo uses code generation (OpenAPI, Protocol Buffers, etc.) | Generate Go models from OpenAPI specs |
| `test-all` | Run all tests and checks | Comprehensive pre-commit validation | Runs test + lint + test-integration + test-helm |
| `test-integration` | Run integration tests | If repo has integration tests requiring external dependencies | Tests against real GCP/K8s |
| `test-helm` | Run all Helm validation | If repo contains Helm charts | Runs helm-lint + helm-template |
| `image` | Build container image | If repo produces a container image | `make image IMAGE_TAG=v1.0.0` |
| `image-push` | Push container image to registry | If repo publishes to container registry | `make image-push` |
| `helm-lint` | Lint Helm charts | If repo contains Helm charts | Validate chart syntax |
| `helm-template` | Template Helm charts | If repo contains Helm charts | Render templates locally |
| `image-dev` | Build and push to personal registry | For fast dev iteration with lightweight base image | `QUAY_USER=me make image-dev` |
| `deploy` | Deploy to environment | If repo has deployment logic | Deploy to dev/staging |
| `run` | Run the application locally | For services that can run standalone | Start local server |
| `install-hooks` | Install pre-commit hooks | If repo uses [pre-commit](https://pre-commit.com/) for local validation | `pre-commit install` |
| `gofmt` | Check Go formatting | Go repos using [pre-commit hooks](https://github.com/openshift-hyperfleet/hyperfleet-hooks) | Alias for `fmt` |
| `go-vet` | Run go vet | Go repos using [pre-commit hooks](https://github.com/openshift-hyperfleet/hyperfleet-hooks) | Alias for `vet` |

> **Note:** `gofmt` and `go-vet` are optional in general, and become **required for repositories with Go code** that use the `hyperfleet-gofmt` and `hyperfleet-go-vet` hooks. In non-Go repositories, these hooks are skipped via Go file filtering. See the [Pre-Commit Hooks Setup Guide](../docs/pre-commit-hooks.md) for details.

### Example: Optional targets

```bash
make generate                   # Generate code from specs
make test-all                   # Run all tests and checks (recommended before commit)
make test-integration           # Run integration tests
make test-helm                  # Run all Helm validation (lint + template)
make image IMAGE_TAG=v1.0.0    # Build container image
make image-push                 # Push to registry
```

### Target Naming Rules

- Use **lowercase** with hyphens for multi-word targets (e.g., `test-integration`, not `integrationTest`)
- Use **verbs** for action targets (e.g., `build`, `test`, `clean`)
- Keep names **short** but descriptive (max 20 characters)
- Avoid abbreviations (use `test-integration`, not `int-test`)

---

### Binary Output Location

**Rule:** All compiled binaries **MUST** be output to the `bin/` directory.

```makefile
# Good - output to bin/ directory
# Example: go build -o bin/pull-secret ./cmd/pull-secret
build:
 go build -o bin/app-name ./cmd/app-name

# Bad - DO NOT output to project root
build:
 go build -o app-name ./cmd/app-name
```

### Temporary Files

| File Type | Location | Description |
|-----------|----------|-------------|
| Binaries | `bin/` | All compiled executables |
| Build artifacts | `build/` | Temporary build files, cache |
| Test coverage | `coverage.txt`, `coverage.html` | Coverage reports |
| Container images | N/A (tagged only) | Not stored locally after build |

**Important:** All temporary files should be in `.gitignore`:

```gitignore
# Build outputs
bin/
build/

# Test coverage
coverage.txt
coverage.html
coverage.out
*.coverprofile
```

---

## Repository Type Variations

Not all HyperFleet repositories build binaries. Helm-chart and deployment repositories have different build patterns but should still follow consistent conventions. This section documents equivalent targets for different repository types.

### Repository Types

| Type | Description | Examples |
|------|-------------|----------|
| **Service** | Repositories that compile Go binaries | adapter-pullsecret, sentinel |
| **Helm-chart** | Repositories containing only Helm charts for deployment | adapter-landing-zone |
| **Infrastructure** | Repositories with infrastructure-as-code (Terraform, scripts) | hyperfleet-infrastructure |
| **Plugin marketplace** | Repositories distributing developer-assistant plugins, including skills, commands, hooks, and executable helpers | hyperfleet-claude-plugins |
| **Documentation** | Repositories containing only documentation (Makefile not required) | hyperfleet-architecture |

### Target Equivalents for Helm-chart Repositories

Helm-chart repositories do not build binaries, so the standard required targets have different equivalents:

| Standard Target | Helm-chart Equivalent | Notes |
|-----------------|----------------------|-------|
| `build` | N/A | No binaries to build; not applicable for Helm-chart repositories |
| `test` | `test-helm` | Runs `helm-lint` + `helm-template` validation |
| `lint` | `helm-lint` | Validates chart syntax and best practices |
| `clean` | `helm-uninstall` or N/A | Removes installed releases; may be omitted if not applicable |
| `help` | `help` | Still required; lists available targets |

### Targets for Plugin Marketplace Repositories

The `plugin-marketplace` type covers repositories distributing developer-assistant plugins and their supporting scripts and tests. These repositories are not documentation-only, but do not necessarily compile a service binary or produce build artifacts.

| Target | Requirement | Expected Behavior |
|--------|-------------|-------------------|
| `test` | **MUST** | Run all repository test suites through their runners and return nonzero on failure |
| `help` | **MUST** | List existing targets with descriptions without executing them |
| `build` | **MAY**, when applicable | Build plugin artifacts if the repository has a build step |
| `lint` | **MUST** | Validate Markdown and other applicable repository formats using configured linters and return nonzero when any configured linter reports a validation failure |
| `clean` | **MAY**, when applicable | Remove generated artifacts if the repository creates them |

The root Makefile **MUST** provide `help`, `test`, and `lint`; it does not need per-suite targets. Repositories **MUST** document the test and lint commands, runner convention, and dependencies in their contributor documentation. They **MUST NOT** add no-op targets solely to satisfy a service-oriented target check. Optional build and cleanup targets do not waive applicable testing or container-image requirements elsewhere in the standards.

The `test` target **MUST** discover suite runners by a documented path convention, log each runner, propagate failures, and fail when no suites are discovered. Framework and interpreter selection **SHOULD** remain inside each runner so adding a suite does not require a language-specific Makefile target. Discovered paths **MUST** be passed as data, not interpolated into shell source.

For example, a repository can document `<plugin>/tests/run-tests.sh` and `<plugin>/skills/<skill>/scripts/tests/run-tests.sh` as its runner paths. Its root `make test` discovers those runners without maintaining a suite list. New tests in an existing suite reuse that suite's runner.

Declaring `plugin-marketplace` without `help`, `test`, or `lint`, or providing a `test` target that succeeds without discovering any runners, is noncompliant. A `lint` target that performs no validation or returns success when a configured linter reports a validation failure is also noncompliant.

### Repository Type Indicator

To help tooling identify repository types, repositories **SHOULD** include a `.hyperfleet.yaml` file in the root directory. This file is preferred over GitHub Topics because it works offline, is version-controlled, and supports structured metadata:

```yaml
# .hyperfleet.yaml - Repository metadata for HyperFleet tooling
version: v1
repository:
  types: [helm-chart]  # List of repository types (see Repository Types table above)
  name: adapter-landing-zone
  description: Helm charts for adapter deployment landing zone
```

#### Example: Plugin Marketplace Metadata

```yaml
# .hyperfleet.yaml
version: v1
repository:
  types: [plugin-marketplace]
  name: hyperfleet-claude-plugins
  description: Developer-assistant plugin marketplace for HyperFleet
```

### Supported repository types

| Type | Value | Required Targets |
|------|-------|------------------|
| Service | `service` | `help`, `build`, `test`, `lint`, `clean` |
| Helm-chart | `helm-chart` | `help`, `helm-lint`, `helm-template`, `test-helm` |
| Infrastructure | `infrastructure` | `help`, `lint`, `clean` |
| Plugin marketplace | `plugin-marketplace` | `help`, `test`, `lint` |
| Documentation | `documentation` | Makefile not required |

### Audit Tool Behavior

The standards-audit tool recognizes repository type variations:

1. **With `.hyperfleet.yaml`**: The tool reads the repository types and validates against the appropriate target sets
2. **Without `.hyperfleet.yaml`**: The tool defaults to `service` type and expects standard targets
3. **Auto-detection fallback**: If no `.hyperfleet.yaml` exists, the tool may infer type from:
   - Presence of `charts/` directory → `helm-chart`
   - Presence of `go.mod` → `service`
   - Presence of `terraform/` directory → `infrastructure`
   - Only `.md` files → `documentation`

For repositories explicitly declaring `plugin-marketplace`, standards audits **MUST** require `help`, `test`, and `lint` and **MUST NOT** report absent `build` or `clean` targets as violations of this Makefile standard unless another declared type requires them. Review **MUST** verify that `help` lists targets without executing them, `test` follows the documented runner discovery and failure behavior, and `lint` validates Markdown and other applicable formats and returns nonzero when any configured linter reports a validation failure; target presence alone does not establish compliance. Audit tooling must be updated to recognize this type; this document does not imply that existing tool versions already support it.

> **Note:** Targets are additive. The repository types define the **minimum required targets**. A repository with multiple types must include the required targets for each type.

### Example: Service repository with Helm charts

A repository that builds binaries and also contains Helm charts would declare both types:

```yaml
# .hyperfleet.yaml
version: v1
repository:
  types: [service, helm-chart]  # Must satisfy required targets for both types
  name: my-adapter
  description: Adapter service with deployment charts
```

```makefile
# Required targets from 'service' type
help:           ## Show this help
build:          ## Build the binary
test:           ## Run tests
lint:           ## Run linters
clean:          ## Clean build artifacts

# Required targets from 'helm-chart' type
helm-lint:      ## Lint Helm charts
helm-template:  ## Render Helm templates
test-helm:      ## Run Helm tests
```

### Example audit output for Helm-chart repository

```plaintext
Repository: adapter-landing-zone
Types: [helm-chart] (from .hyperfleet.yaml)

Required Targets:
  ✓ help
  ✓ helm-lint
  ✓ helm-template
  ✓ test-helm

Optional Targets:
  ○ helm-uninstall (not found)
  ○ deploy (not found)

Status: COMPLIANT
```

---

## Flag Conventions

### Standard Variables

All Makefiles **SHOULD** support these environment variables:

| Variable | Default | Description | Example Usage |
|----------|---------|-------------|---------------|
| `IMAGE_TAG` | `$(APP_VERSION)` | Container image tag | `make image IMAGE_TAG=v1.0.0` |
| `IMAGE_REGISTRY` | (repo-specific) | Container registry URL | `make image IMAGE_REGISTRY=quay.io/hyperfleet` |
| `IMAGE_NAME` | (repo-specific) | Container image name | `make image IMAGE_NAME=my-service` |
| `GOOS` | (host OS) | Target operating system for build | `make build GOOS=linux` |
| `GOARCH` | (host arch) | Target architecture for build | `make build GOARCH=amd64` |
| `CGO_ENABLED` | `0` | Enable/disable CGO. Existing production services keep `CGO_ENABLED ?= 1` for runtime compatibility; native Go FIPS does not depend on CGO. | `make build CGO_ENABLED=1` |
| `GOEXPERIMENT` | (toolchain default) | FIPS production services **MUST** set `GOEXPERIMENT ?= noboringcrypto` for build compatibility when the incompatible legacy experiment was saved with `go env -w`. Without the negation, Go rejects the combination with `GOFIPS140=v1.0.0`; there is no silent non-FIPS fallback. | `make build GOEXPERIMENT=noboringcrypto` |
| `GOFIPS140` | `off` (upstream default) | FIPS production services **MUST** set `GOFIPS140 ?= v1.0.0` to select the validated Go Cryptographic Module, and `godebug fips140=on` in the main `go.mod` to enable FIPS mode by default on the Red Hat toolset. | `make build GOFIPS140=v1.0.0` |
| `PLATFORM` | `linux/amd64` | Target platform for container builds | `make image PLATFORM=linux/arm64` |
| `CONTAINER_TOOL` | (auto-detected) | Container tool (`podman` or `docker`) | `make image CONTAINER_TOOL=docker` |
| `GIT_SHA` | (auto-detected) | Short git commit hash | — |
| `GIT_DIRTY` | (auto-detected) | `-modified` suffix if working tree is dirty | — |
| `BUILD_DATE` | (auto-detected) | ISO 8601 UTC build timestamp | — |
| `APP_VERSION` | `$(shell git describe --tags --always --dirty 2>/dev/null \|\| echo "0.0.0-dev")` | Application version string. **MUST** use `APP_VERSION` (not `VERSION`) to avoid collision with `ubi9/go-toolset`'s `ENV VERSION=<go-version>` — see [Container Image Standard: APP_VERSION Convention](container-image-standard.md#app_version-convention) | `make image APP_VERSION=v1.2.3` |

### Variable Definition Pattern

Always use `?=` for variables that can be overridden:

```makefile
# Good - allows override
IMAGE_TAG ?= $(APP_VERSION)

# Bad - cannot override
IMAGE_TAG = $(APP_VERSION)
```

---

## Container Tool Auto-Detection

All Makefiles that build container images **MUST** auto-detect whether `podman` or `docker` is available, preferring `podman`:

```makefile
CONTAINER_TOOL ?= $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)
```

Because the shell expansion returns an empty string when neither tool is found, all container targets **MUST** depend on a guard that fails fast with a clear message and installation instructions:

```makefile
.PHONY: check-container-tool
check-container-tool:
ifndef CONTAINER_TOOL
 @echo "Error: No container tool found (podman or docker)"
 @echo ""
 @echo "Please install one of:"
 @echo "  brew install podman   # macOS"
 @echo "  brew install docker   # macOS"
 @echo "  dnf install podman    # Fedora/RHEL"
 @exit 1
endif
```

This allows developers using either tool to run `make image` without additional configuration, while still permitting explicit override via `CONTAINER_TOOL=docker make image`.

> **Note:** The `ifndef` approach is preferred over a shell `if` test because it leverages Make's native conditional evaluation and produces cleaner error output.

---

## Version Information and Git Dirty Detection

### Git Dirty Detection

All Makefiles **MUST** use `git status --porcelain` for dirty detection. Do **not** use `git diff --quiet`, which can miss untracked files:

```makefile
# Correct — detects both staged/unstaged changes and untracked files
GIT_DIRTY ?= $(shell [ -z "$$(git status --porcelain 2>/dev/null)" ] || echo "-modified")

# Incorrect — misses untracked files
# GIT_DIRTY ?= $(shell git diff --quiet 2>/dev/null || echo "-modified")
```

### Standard Version Variables

All service Makefiles **MUST** define these version variables:

```makefile
BUILD_DATE  ?= $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")
GIT_SHA     ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_DIRTY   ?= $(shell [ -z "$$(git status --porcelain 2>/dev/null)" ] || echo "-modified")
APP_VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo "0.0.0-dev")
```

> **Important:** Use `APP_VERSION` (not `VERSION`) for the application version variable. The `ubi9/go-toolset` base image sets `ENV VERSION=<go-toolchain-version>`, which overrides a Makefile `VERSION ?=` inside container builds. See [Container Image Standard: APP_VERSION Convention](container-image-standard.md#app_version-convention) for details.

These values are embedded into binaries via `-ldflags` and passed as `--build-arg` to container builds so that every artifact is traceable back to its source commit.

---

## Go Build Flags

All service Makefiles **MUST** define standard Go build flags for reproducible, traceable builds:

```makefile
GOFLAGS ?= -trimpath
LDFLAGS := -s -w \
           -X main.version=$(APP_VERSION) \
           -X main.commit=$(GIT_SHA) \
           -X main.date=$(BUILD_DATE)
```

| Flag | Purpose |
|------|---------|
| `-trimpath` | Remove local filesystem paths from the binary for reproducibility |
| `-s -w` | Strip debug info and symbol tables to reduce binary size |
| `-X main.version=...` | Embed version string at compile time |
| `-X main.commit=...` | Embed git commit hash at compile time |
| `-X main.date=...` | Embed build date at compile time |

### Example build target

For a shipped FIPS service, Make **MUST** default to `CGO_ENABLED=1`, `GOEXPERIMENT=noboringcrypto`, and `GOFIPS140=v1.0.0`, and export these settings so builds, tests, tools and recipe command substitutions use the same configuration. `noboringcrypto` is retained because the migration must work with the legacy experiment persisted by `go env -w`; without it Go fails before building. The main `go.mod` **MUST** declare `godebug fips140=on` because the Red Hat toolset does not enable FIPS mode merely by selecting the module.

Build flags **MUST** default to `-trimpath -tags=no_openssl`. A FIPS service **MUST** replace the general `GOFLAGS ?= -trimpath` example with this single combined definition, not keep both: the first `?=` assignment wins, so an earlier generic definition would omit the backend tag. Red Hat Go uses an OpenSSL backend by default on Linux with cgo, which aborts during initialization on FIPS-enabled hosts when `fips140` GODEBUG is set. `no_openssl` selects the native backend there and is harmless on upstream Go, so no vendor detection is needed. Use the `-tags=value` form because `GOFLAGS` requires a flag and its value to be one argument.

The supported contract covers the default Make recipes and production image builds, not arbitrary caller overrides. Settings use ordinary `?=` defaults: no empty-value normalization or caller-tag parser is required. A caller overriding `GOFLAGS` or `GO_TEST_TAGS` owns the complete replacement, including `no_openssl`; callers overriding FIPS settings, including supplying empty values, own that configuration. Production images **MUST** still pass the [container build-info gates](container-image-standard.md#fips-compliant-builds), regardless of overrides.

Do not export production `GOFLAGS` to make tests inherit the tag: that also adds `-trimpath` to test binaries, which rewrites the source paths recorded by `runtime.Caller` and breaks tests that locate the repository from them. Instead, default and export `GO_TEST_TAGS` as `no_openssl`, expanding it in the shell as `"$${GO_TEST_TAGS}"` rather than interpolating caller input into recipe source. Test targets **MUST** select the native backend by default too. Targets with additional tags **MUST** combine them in one flag. Normalize whitespace to commas before adding `integration` or `envtest`: Go treats tag lists containing spaces as whitespace-separated, so mixing a comma prefix with a space-separated override can lose the required tag. Integration scripts **MUST** receive and preserve this list as well.

Repositories exposing generic `TESTFLAGS` alongside `GO_TEST_TAGS` **MUST** reject `-tags` in `TESTFLAGS` rather than silently overriding it with a later flag. Document `GO_TEST_TAGS` as the sole test-tag input, for example `make test GO_TEST_TAGS=netgo,no_openssl TESTFLAGS=-count=1`. This keeps one explicit tag list without reintroducing caller-tag merging. Repositories without `TESTFLAGS` do not need this guard.

The recipe line below contains a literal tab required by GNU Make. The MD010 exception applies only to this example.

<!-- markdownlint-disable MD010 -->
```makefile
GO ?= go
# Always honor the main module's godebug directive, including local builds/tests.
override GOWORK := off
export GOWORK
CGO_ENABLED ?= 1
GOEXPERIMENT ?= noboringcrypto
GOFIPS140 ?= v1.0.0
export CGO_ENABLED GOEXPERIMENT GOFIPS140
GOFLAGS ?= -trimpath -tags=no_openssl
GO_TEST_TAGS ?= no_openssl
export GO_TEST_TAGS

build:
	$(GO) build $(GOFLAGS) -ldflags "$(LDFLAGS)" -o bin/my-service ./cmd/my-service

test:
	$(GO) test -tags="$${GO_TEST_TAGS}" -race ./...

test-integration:
	@test_tags=$$(printf '%s' "$${GO_TEST_TAGS}" | tr '[:space:]' ','); \
	$(GO) test -tags="integration,$$test_tags" -race ./test/integration/...
```
<!-- markdownlint-enable MD010 -->

The test target **MUST** pass `CGO_ENABLED`, `GOEXPERIMENT`, and `GOFIPS140` to `go test`, directly or through Make's exported environment, so tests exercise the selected module and `-race` works even if the toolchain saved a different CGO setting. When a `go.work` file is active, Go ignores the `godebug` directive in `go.mod` ([go.dev/doc/godebug](https://go.dev/doc/godebug)). Build, install, run and test recipes **MUST** enforce `GOWORK=off` as shown, rather than requiring callers to remember it; this keeps the main module's FIPS default effective even inside an enclosing workspace. Direct Go invocations outside Make need `GOWORK=off` too, unless the workspace itself declares `godebug fips140=on`. The binary's build info is verified by the [container image standard](container-image-standard.md#fips-compliant-builds), which requires the module selection, `DefaultGODEBUG=fips140=on`, and the native backend tag. FIPS production deployments **MUST NOT** disable that compiled default through runtime overrides, including `GODEBUG=fips140=off` or `GODEBUG=fips140=` (empty entry). The linked standard specifies the environment, `go.work`, and main-package directive forms that deployment review must check.

Validate default build and test recipes, including a toolchain with persisted `GOEXPERIMENT=boringcrypto` and an enclosing workspace without `godebug fips140=on`. The build-info gate must accept the exact `no_openssl` token in any list position and reject near matches such as `not_no_openssl` and `no_openssl_disabled`.

Helpers that compile and run a service **SHOULD** reuse `make build` so they do not bypass these settings. Direct Go invocations do not inherit Make's defaults; document the complete environment and the explicit native backend tag for both builds and tests:

```bash
export CGO_ENABLED=1 GOEXPERIMENT=noboringcrypto GOFIPS140=v1.0.0 GOWORK=off
# Compile check only; make build produces the service executable.
go build -trimpath -tags=no_openssl ./...
go test -tags=no_openssl ./...
```

For services without FIPS requirements, use the ordinary build target:

```makefile
BIN_DIR := bin
BINARY_NAME := $(BIN_DIR)/my-service

build:
 @mkdir -p $(BIN_DIR)
 $(GO) build $(GOFLAGS) -ldflags "$(LDFLAGS)" -o $(BINARY_NAME) ./cmd/my-service
```

---

## Container Image Targets

### Required: `image` and `image-push`

Repositories that produce container images **MUST** pass version build args and specify the target platform:

```makefile
PLATFORM       ?= linux/amd64
IMAGE_REGISTRY ?= quay.io/openshift-hyperfleet
IMAGE_NAME     ?= my-service
IMAGE_TAG      ?= $(APP_VERSION)

.PHONY: image
image: check-container-tool ## Build container image
 $(CONTAINER_TOOL) build \
  --platform $(PLATFORM) \
  --build-arg GIT_SHA=$(GIT_SHA) \
  --build-arg GIT_DIRTY=$(GIT_DIRTY) \
  --build-arg BUILD_DATE=$(BUILD_DATE) \
  --build-arg APP_VERSION=$(APP_VERSION) \
  -t $(IMAGE_REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG) .

.PHONY: image-push
image-push: check-container-tool image ## Build and push container image
 $(CONTAINER_TOOL) push $(IMAGE_REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG)
```

### Optional: `image-dev`

Repositories **MAY** provide an `image-dev` target that builds with a lightweight base image and pushes to a personal registry for development:

```makefile
QUAY_USER      ?=
DEV_BASE_IMAGE ?= registry.access.redhat.com/ubi9/ubi-minimal:latest
DEV_TAG        ?= dev-$(GIT_SHA)

.PHONY: image-dev
image-dev: check-container-tool ## Build and push dev image (requires QUAY_USER)
ifndef QUAY_USER
 @echo "Error: QUAY_USER is not set. Usage: QUAY_USER=myuser make image-dev"
 @exit 1
endif
 $(CONTAINER_TOOL) build \
  --platform $(PLATFORM) \
  --build-arg BASE_IMAGE=$(DEV_BASE_IMAGE) \
  --build-arg GIT_SHA=$(GIT_SHA) \
  --build-arg GIT_DIRTY=$(GIT_DIRTY) \
  --build-arg BUILD_DATE=$(BUILD_DATE) \
  --build-arg APP_VERSION=$(APP_VERSION) \
  -t quay.io/$(QUAY_USER)/$(IMAGE_NAME):$(DEV_TAG) .
 $(CONTAINER_TOOL) push quay.io/$(QUAY_USER)/$(IMAGE_NAME):$(DEV_TAG)
```

---

## References

### Related Documents

- [Container Image Standard](container-image-standard.md) - Dockerfile conventions, base images, and labels
- [Directory Structure Standard](directory-structure.md) - Standard repository layout

### External Resources

- [GNU Make Manual](https://www.gnu.org/software/make/manual/)
- [Makefile Best Practices](https://tech.davis-hansson.com/p/make/)
- [Self-Documented Makefiles](https://marmelab.com/blog/2016/02/29/auto-documented-makefile.html)
