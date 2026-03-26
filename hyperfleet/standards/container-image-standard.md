---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-03-09
---

# HyperFleet Container Image Standard

## Table of Contents

1. [Overview](#overview)
2. [Base Images](#base-images)
3. [Multi-Stage Build Pattern](#multi-stage-build-pattern)
4. [Non-Root Users](#non-root-users)
5. [Go Build Parameters](#go-build-parameters)
6. [Container Labels](#container-labels)
7. [.dockerignore](#dockerignore)
8. [Reference Dockerfile](#reference-dockerfile)
9. [References](#references)

---

## Overview

This document defines the standard conventions for Dockerfiles, base images, and container build practices across all HyperFleet service repositories.

### Goals

1. **Consistent base images** - All services use the same approved Red Hat UBI builder and runtime images, eliminating variation across Debian, Alpine, and other base images
2. **Security by default** - Non-root users in all stages, enforced consistently across all repositories
3. **Reproducible builds** - Standard version embedding and build flags across all services
4. **Konflux / Enterprise Contract compliance** - All base images must come from allowed registry prefixes (`registry.access.redhat.com/`, `registry.redhat.io/`) to pass `EnterpriseContractPolicy` checks enforced by Konflux pipelines via [Conforma](https://github.com/conforma/cli) (formerly Enterprise Contract). FIPS considerations documented and supported
5. **Efficient builds** - Multi-stage builds with layer caching, proper `.dockerignore`, and minimal build context

### Scope

This standard applies to all HyperFleet repositories that produce container images (repository type `service` in `.hyperfleet.yaml`).

---

## Base Images

### Builder Stage

All Go service Dockerfiles **MUST** use Red Hat UBI9 Go toolset as the builder image:

```dockerfile
FROM registry.access.redhat.com/ubi9/go-toolset:1.25 AS builder
```

**Why UBI9 Go toolset?**
- Red Hat-supported and maintained
- FIPS-validated cryptographic libraries available
- Consistent with Red Hat OpenShift ecosystem
- Regular security updates

> **Note:** The Go toolset image does not include `make` by default. Install it as root, then switch back to the non-root user (see [Multi-Stage Build Pattern](#multi-stage-build-pattern)).

### Production Runtime

The default production runtime image **MUST** be Red Hat UBI9 Micro:

```dockerfile
ARG BASE_IMAGE=registry.access.redhat.com/ubi9-micro:latest
FROM ${BASE_IMAGE}
```

Using `ARG BASE_IMAGE` makes the runtime configurable for different build scenarios:

| Scenario | Base Image | Notes |
|----------|-----------|-------|
| Standard production | `registry.access.redhat.com/ubi9-micro:latest` | Default. Minimal UBI with glibc, Red Hat supported |
| FIPS-compliant (`CGO_ENABLED=1`) | `registry.access.redhat.com/ubi9-micro:latest` | Same image; includes glibc required for boringcrypto |
| Development / debugging | `registry.access.redhat.com/ubi9/ubi-minimal:latest` | Includes shell and microdnf for troubleshooting |

---

## Multi-Stage Build Pattern

All service Dockerfiles **MUST** use multi-stage builds with the following structure:

```dockerfile
ARG BASE_IMAGE=registry.access.redhat.com/ubi9-micro:latest

# ── Builder stage ──
FROM registry.access.redhat.com/ubi9/go-toolset:1.25 AS builder

ARG GIT_SHA=unknown
ARG GIT_DIRTY=""
ARG BUILD_DATE=""
ARG APP_VERSION="0.0.0-dev"

USER root
RUN dnf install -y make && dnf clean all
WORKDIR /build
RUN chown 1001:0 /build
USER 1001

ENV GOBIN=/build/.gobin
RUN mkdir -p $GOBIN

COPY --chown=1001:0 go.mod go.sum ./
RUN --mount=type=cache,target=/opt/app-root/src/go/pkg/mod,uid=1001 \
    go mod download

COPY --chown=1001:0 . .

RUN --mount=type=cache,target=/opt/app-root/src/go/pkg/mod,uid=1001 \
    --mount=type=cache,target=/opt/app-root/src/.cache/go-build,uid=1001 \
    CGO_ENABLED=0 GOOS=linux \
    GIT_SHA=${GIT_SHA} GIT_DIRTY=${GIT_DIRTY} BUILD_DATE=${BUILD_DATE} \
    make build

# ── Runtime stage ──
FROM ${BASE_IMAGE}

WORKDIR /app

# ubi9-micro doesn't include CA certificates; copy from builder for TLS (e.g. Google Pub/Sub)
COPY --from=builder /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
COPY --from=builder /build/bin/<service-name> /app/<service-name>

USER 65532:65532

EXPOSE 8080
ENTRYPOINT ["/app/<service-name>"]
```

### Key Practices

- **CA certificates** copied from builder stage — `ubi9-micro` doesn't include `ca-certificates`; required for TLS connections to external services
- **Cache mounts** for Go module and build caches to speed up rebuilds
- **`go mod download`** as a separate layer before copying source for better layer caching
- **`--chown=1001:0`** on COPY commands for the builder stage (UBI9 convention)
- **`WORKDIR /app`** in the runtime stage to keep a clean layout
- **Build args** passed through to `make build` for version embedding

---

## Non-Root Users

All container images **MUST** run as non-root users.

### Builder Stage (UBI9 Go Toolset)

The UBI9 Go toolset image provides user `1001` by default. Temporarily switch to `root` only when installing system packages, then switch back:

```dockerfile
USER root
RUN dnf install -y make && dnf clean all
WORKDIR /build
RUN chown 1001:0 /build
USER 1001
```

### Runtime Stage

Use the standard nonroot user `65532:65532`:

```dockerfile
USER 65532:65532
```

---

## Go Build Parameters

### CGO_ENABLED

| Value | When to Use | Runtime Image |
|-------|-------------|---------------|
| `0` (default) | Standard builds producing static binaries | `ubi9-micro` (default) |
| `1` | FIPS-compliant builds with `GOEXPERIMENT=boringcrypto` | `ubi9-micro` (includes glibc required for boringcrypto) |

Document this decision in your Dockerfile:

```dockerfile
# CGO_ENABLED=0 produces a static binary. The default ubi9-micro runtime
# supports both static and dynamically linked binaries.
# For FIPS-compliant builds, use CGO_ENABLED=1 + GOEXPERIMENT=boringcrypto.
```

### Build Flags

All Go builds **MUST** include:

| Flag | Purpose |
|------|---------|
| `-trimpath` | Remove local filesystem paths from binary for reproducibility |
| `-s -w` (via `-ldflags`) | Strip debug symbols to reduce binary size |
| `-X` (via `-ldflags`) | Embed version, commit hash, and build date |

Standard ldflags:

```makefile
LDFLAGS := -s -w \
           -X main.version=$(APP_VERSION) \
           -X main.commit=$(GIT_SHA) \
           -X main.date=$(BUILD_DATE)
```

### Platform

Container builds **MUST** specify the target platform:

```makefile
PLATFORM ?= linux/amd64
```

```bash
$(CONTAINER_TOOL) build --platform $(PLATFORM) ...
```

---

## Container Labels

All production images **MUST** include standardized OCI labels. Place the `LABEL` instruction at the end of the Dockerfile (after `ARG` re-declarations) so it doesn't invalidate earlier layer caches:

```dockerfile
ARG APP_VERSION="0.0.0-dev"
LABEL name="<service-name>" \
      vendor="Red Hat" \
      version="${APP_VERSION}" \
      summary="<one-line summary>" \
      description="<detailed description of what the service does>"
```

### Required Labels

| Label | Description | Example |
|-------|-------------|---------|
| `name` | Service name (matches image name) | `hyperfleet-sentinel` |
| `vendor` | Organization | `Red Hat` |
| `version` | Semantic version or git-derived version | `abc1234` |
| `summary` | One-line description | `HyperFleet Sentinel - Resource polling and event publishing service` |
| `description` | Detailed description of the service | `Watches HyperFleet API resources and publishes reconciliation events to message brokers` |

---

## .dockerignore

All repositories producing container images **MUST** include a `.dockerignore` file at the repository root.

The reference `.dockerignore` is maintained as a standalone file: [`.dockerignore`](.dockerignore). Copy it into your repository root:

```bash
curl -sSL -o .dockerignore \
  https://raw.githubusercontent.com/openshift-hyperfleet/architecture/main/hyperfleet/standards/.dockerignore
```

Services **MAY** append additional service-specific entries (e.g. generated code directories) after copying.

### Why?

- **Prevents `-buildvcs` errors**: Git metadata inside the build context causes failures with Go's VCS stamping during container builds
- **Reduces build context size**: The `.git/` directory can be large and is never needed inside the container
- **Faster builds**: Smaller context means faster transfer to the Docker daemon

---

## Reference Dockerfile

A complete reference Dockerfile incorporating all standards above. Replace `<service-name>` with the actual service binary name:

```dockerfile
ARG BASE_IMAGE=registry.access.redhat.com/ubi9-micro:latest

FROM registry.access.redhat.com/ubi9/go-toolset:1.25 AS builder

ARG GIT_SHA=unknown
ARG GIT_DIRTY=""
ARG BUILD_DATE=""
ARG APP_VERSION="0.0.0-dev"

USER root
RUN dnf install -y make && dnf clean all
WORKDIR /build
RUN chown 1001:0 /build
USER 1001

ENV GOBIN=/build/.gobin
RUN mkdir -p $GOBIN

COPY --chown=1001:0 go.mod go.sum ./
RUN --mount=type=cache,target=/opt/app-root/src/go/pkg/mod,uid=1001 \
    go mod download

COPY --chown=1001:0 . .

# CGO_ENABLED=0 produces a static binary. The default ubi9-micro runtime
# supports both static and dynamically linked binaries.
# For FIPS-compliant builds, use CGO_ENABLED=1 + GOEXPERIMENT=boringcrypto.
RUN --mount=type=cache,target=/opt/app-root/src/go/pkg/mod,uid=1001 \
    --mount=type=cache,target=/opt/app-root/src/.cache/go-build,uid=1001 \
    CGO_ENABLED=0 GOOS=linux \
    GIT_SHA=${GIT_SHA} GIT_DIRTY=${GIT_DIRTY} BUILD_DATE=${BUILD_DATE} \
    make build

FROM ${BASE_IMAGE}

WORKDIR /app

# ubi9-micro doesn't include CA certificates; copy from builder for TLS (e.g. Google Pub/Sub)
COPY --from=builder /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
COPY --from=builder /build/bin/<service-name> /app/<service-name>

USER 65532:65532

EXPOSE 8080
ENTRYPOINT ["/app/<service-name>"]

ARG APP_VERSION="0.0.0-dev"
LABEL name="<service-name>" \
      vendor="Red Hat" \
      version="${APP_VERSION}" \
      summary="<one-line service summary>" \
      description="<detailed service description>"
```

---

## APP_VERSION Convention

### Problem

The `ubi9/go-toolset` base image sets `ENV VERSION=<go-toolchain-version>` (e.g. `1.25.7`). In Docker/Podman, an inherited `ENV` always shadows an `ARG` with the same name inside `RUN` commands. If a Dockerfile declares `ARG VERSION` and the Makefile uses `VERSION ?=`, the Go toolchain version leaks into the binary instead of the intended application version.

### Solution

All HyperFleet Dockerfiles and Makefiles **MUST** use `APP_VERSION` instead of `VERSION` for the application version variable:

```dockerfile
ARG APP_VERSION="0.0.0-dev"
```

Since the Makefile uses `APP_VERSION` exclusively, the base image's `ENV VERSION=<go-version>` is harmless — nothing reads it. No `ENV VERSION` override is needed.

### Version Flow

```
Makefile (APP_VERSION via git describe)
  ├─ go build -ldflags "-X ...Version=$(APP_VERSION)"    → binary version (local builds)
  └─ docker build --build-arg APP_VERSION=$(APP_VERSION)  → Dockerfile
       └─ ARG APP_VERSION                                  → available in RUN commands
            └─ make build                                  → Makefile picks up APP_VERSION
```

### Default Version Semantics

| Scenario | APP_VERSION Value | Source |
|----------|------------------|--------|
| Untagged local build | `a1b2c3d` (or `a1b2c3d-dirty`) | `git describe --tags --always --dirty` (abbreviated commit SHA) |
| Dev build from tagged repo | `v0.1.1-3-gabcdef` | `git describe --tags --always --dirty` |
| Release build (at tag) | `v0.1.1` | `git describe` returns the tag automatically; explicit `APP_VERSION=v0.1.1` is optional, useful for shallow clones where `git describe` may fail |
| No git metadata available | `0.0.0-dev` | Makefile fallback when `git describe` fails |
| Raw `go build` (no Make) | `0.0.0-dev` | Source code default constant |

---

## References

### Related Documents

- [Makefile Conventions](makefile-conventions.md) - Standard Makefile targets and variables
- [Directory Structure Standard](directory-structure.md) - Standard repository layout

### External Resources

- [Red Hat UBI9 Go Toolset](https://catalog.redhat.com/software/containers/ubi9/go-toolset)
- [Red Hat UBI9 Micro](https://catalog.redhat.com/software/containers/ubi9-micro)
- [OCI Image Spec - Annotations](https://github.com/opencontainers/image-spec/blob/main/annotations.md)
- [Dockerfile Best Practices](https://docs.docker.com/build/building/best-practices/)
