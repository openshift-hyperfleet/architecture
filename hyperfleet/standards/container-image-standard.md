---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-11-18
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
FROM registry.access.redhat.com/ubi9/go-toolset:1.26 AS builder
```

**Why UBI9 Go toolset?**

- Red Hat-supported and maintained
- FIPS-validated cryptographic libraries available
- Consistent with Red Hat OpenShift ecosystem
- Regular security updates

> **Note:** The Go toolset image includes `make`. It comes with the image's `gcc`, which the `CGO_ENABLED=1` build also needs. Do not install `make` in the builder stage.

### Production Runtime

The default production runtime image **MUST** be Red Hat UBI9 Minimal:

```dockerfile
ARG BASE_IMAGE=registry.access.redhat.com/ubi9/ubi-minimal:latest
FROM ${BASE_IMAGE}
```

Using `ARG BASE_IMAGE` makes the runtime configurable for different build scenarios:

| Scenario | Base Image | Notes |
|----------|-----------|-------|
| Standard production | `registry.access.redhat.com/ubi9/ubi-minimal:latest` | Default. Ships glibc, CA certificates and `microdnf`; what all shipped services use |
| Static tooling (`CGO_ENABLED=0`, e.g. `hyperfleet-hooks`) | `registry.access.redhat.com/ubi9-micro:latest` | Opt-in. Smallest runtime for static binaries that need no shell and no CA bundle from RPMs |
| Development / debugging | `registry.access.redhat.com/ubi9/ubi-minimal:latest` | Includes shell and microdnf for troubleshooting |

Under this standard, `ubi9-micro` is an opt-in for static tooling binaries built with `CGO_ENABLED=0` that need neither a shell nor RPM-provided CA certificates. A tooling binary that makes TLS connections on micro must copy the bundle from the builder stage. Both micro and minimal include glibc; the reason to retain minimal for services is its shell, package-management tooling and CA certificates, not the presence of glibc. Image sizes vary by tag and architecture; compare pinned digests for the target platform before claiming a size saving.

---

## Multi-Stage Build Pattern

All service Dockerfiles **MUST** use multi-stage builds with the following structure:

```dockerfile
ARG BASE_IMAGE=registry.access.redhat.com/ubi9/ubi-minimal:latest

# ── Builder stage ──
FROM registry.access.redhat.com/ubi9/go-toolset:1.26 AS builder

ARG GIT_SHA=unknown
ARG GIT_DIRTY=""
ARG BUILD_DATE=""
ARG APP_VERSION="0.0.0-dev"

USER root
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
    GOOS=linux \
    GIT_SHA=${GIT_SHA} GIT_DIRTY=${GIT_DIRTY} BUILD_DATE=${BUILD_DATE} \
    make build

# ── Runtime stage ──
FROM ${BASE_IMAGE}

WORKDIR /app

COPY --from=builder /build/bin/<service-name> /app/<service-name>

USER 65532:65532

EXPOSE 8080
ENTRYPOINT ["/app/<service-name>"]
```

### Key Practices

- **CA certificates** ship in the default `ubi9-minimal` runtime — a `ubi9-micro` runtime instead needs the bundle copied from the builder stage, which is why [Production Runtime](#production-runtime) treats micro as opt-in
- **Cache mounts** for Go module and build caches to speed up rebuilds
- **`go mod download`** as a separate layer before copying source for better layer caching
- **`--chown=1001:0`** on COPY commands for the builder stage (UBI9 convention)
- **`WORKDIR /app`** in the runtime stage to keep a clean layout
- **Build args** passed through to `make build` for version embedding

---

## Non-Root Users

All container images **MUST** run as non-root users.

### Builder Stage (UBI9 Go Toolset)

The UBI9 Go toolset image provides user `1001` by default. Switch to `root` only for steps that need it, such as creating `/build`, then switch back:

```dockerfile
USER root
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
| `0` (default) | Static binaries and tooling images (`hyperfleet-hooks`) | `ubi9-micro` (opt-in) |
| `1` | Shipped control-plane services; retained for existing runtime compatibility | `ubi9/ubi-minimal` (default) |

`CGO_ENABLED` is a Makefile-level decision (see [Makefile Conventions](makefile-conventions.md#standard-variables)). It does **not** select FIPS mode. The existing shipped services keep `CGO_ENABLED=1`; the native FIPS module does not require CGO or system OpenSSL.

### FIPS-Compliant Builds

Shipped HyperFleet control-plane Go services **MUST** build FIPS-compliant, currently `hyperfleet-api`, `hyperfleet-operator`, `hyperfleet-applier`, `hyperfleet-sentinel`, and `hyperfleet-adapter`. This FIPS requirement does **not** apply to CI/developer tooling images such as `hyperfleet-hooks`, which builds a static validation CLI with `CGO_ENABLED=0`. The container-image standard still applies to tooling repositories that declare `types: [service]`; that metadata classification alone does not make a tooling binary a production control-plane service.

Production Dockerfiles **MUST** select Go's [native FIPS 140-3 module](https://go.dev/doc/security/fips140)
with `GOFIPS140=v1.0.0`. This pinned module has [CMVP Certificate #5247](https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/5247).
FIPS is enabled only in the image build; local builds and tests do not enable it
by default. Do not set a module-wide `godebug fips140=on` or add FIPS defaults to
Make. The deprecated BoringCrypto experiment is incompatible with native FIPS
and **MUST NOT** be selected in the production builder.

The main package **MUST** contain a `fips.go` file selected only by the `fips`
build tag. Red Hat Go does not enable FIPS merely by selecting the module, so
this file **MUST** enable it explicitly and reject startup if runtime overrides
disable it:

```go
//go:build fips

//go:debug fips140=on

package main

import "crypto/fips140"

func init() {
    if !fips140.Enabled() {
        panic("FIPS 140-3 mode is not enabled")
    }
}
```

The Dockerfile **MUST** invoke `make build GOFLAGS="-trimpath -tags=fips,no_openssl"`
with `GOFIPS140=v1.0.0`. The Make target must build the main package directory,
not a single `main.go` file, or the tagged file will be omitted. If Make pins a
local toolchain, pass `GOTOOLCHAIN=local` to keep the Red Hat image's compiler.

On a Red Hat Go toolset, a `linux` build with cgo uses the OpenSSL crypto backend by default (`crypto/internal/backend`), not the module the `GOFIPS140` setting selects. That backend aborts during package initialization on a FIPS-enabled host once a `fips140` GODEBUG value is present: `panic: opensslcrypto: GOLANG_FIPS and GODEBUG=fips140 are mutually exclusive`. Production image builds therefore **MUST** select Go's native backend with the `no_openssl` build tag. Upstream Go ignores the tag, so no vendor detection is needed. Without it a Red Hat Linux+cgo binary keeps a runtime dependency on the host OpenSSL and its FIPS provider.

FIPS production builds and deployments **MUST NOT** disable the mode through runtime overrides or compiled defaults. This includes `GODEBUG=fips140=off` and `GODEBUG=fips140=` (empty value), including either entry in a comma-separated `GODEBUG` value; `GODEBUG=fips140ems=0`, which drops Extended Master Secret enforcement for TLS 1.2 in FIPS mode (Go 1.27, backported to Go 1.26.6); `godebug fips140=off`, `godebug fips140=`, or `godebug fips140ems=0` directives in `go.mod` or `go.work`; and `//go:debug fips140=off`, `//go:debug fips140=`, or `//go:debug fips140ems=0` directives in the main package. An empty `fips140=` entry is not equivalent to leaving the setting unspecified; an unset or entirely empty `GODEBUG` environment variable preserves the compiled default.

The image build **MUST** verify the `GOFIPS140` module selection, the compiled
`DefaultGODEBUG=fips140=on`, and successful startup with `GOLANG_FIPS=1`.
The startup check exercises the Red Hat backend path used on FIPS-enabled hosts
instead of checking the backend tag only as build metadata. The compiled-default
check **MUST** also reject `fips140ems=0`, including alongside `fips140=on`.
The runtime guard rejects a disabled FIPS mode, but does not detect an EMS bypass;
build and deployment review **MUST** still check for `fips140ems=0` overrides.

The default runtime image in [Production Runtime](#production-runtime) is `registry.access.redhat.com/ubi9/ubi-minimal:latest`, which ships the libraries and CA certificates the shipped services need. With the native backend selected, native FIPS does not load OpenSSL: do not require an OpenSSL FIPS provider solely for this build mode. If a service moves to `ubi9-micro`, check its CGO runtime dependencies and copy a CA bundle if the service needs TLS.

```dockerfile
ARG BASE_IMAGE=registry.access.redhat.com/ubi9/ubi-minimal:latest
```

Verify the build setting:

```bash
go version -m <binary> | grep -E 'CGO_ENABLED|GOEXPERIMENT|GOFIPS140|DefaultGODEBUG'
# Must show: GOFIPS140=v1.0.0-<hash> (or v1.0.0),
# DefaultGODEBUG including fips140=on, and no BoringCrypto.
```

Container builds **MUST** reject binaries lacking the pinned module or compiled
FIPS default, or failing the startup smoke check. The Go build info may include
a resolved module hash suffix; accept that suffix but not arbitrary versions.
The following three checks include the required EMS rejection:

```dockerfile
RUN go version -m /build/bin/<service-name> | grep -Eq 'GOFIPS140=v1[.]0[.]0(-[[:xdigit:]]+)?$' || { echo "FIPS check FAILED: missing GOFIPS140=v1.0.0"; exit 1; }
RUN go version -m /build/bin/<service-name> \
    | grep -E '^[[:space:]]*build[[:space:]]+DefaultGODEBUG=([^,]*,)*fips140=on(,|$)' \
    | grep -Ev 'DefaultGODEBUG=([^,]*,)*fips140ems=0(,|$)' \
    || { echo "FIPS check FAILED: require fips140=on without fips140ems=0"; exit 1; }
RUN GOLANG_FIPS=1 /build/bin/<service-name> --help >/dev/null || { echo "FIPS check FAILED: binary does not start in FIPS mode"; exit 1; }
```

CI **SHOULD** also start the final runtime image with `GOLANG_FIPS=1` and verify
that `GODEBUG=fips140=off` causes startup to fail. The builder-stage smoke check
does not validate final-image runtime dependencies or end-to-end functionality.
A simulated FIPS host is not a substitute for acceptance on a FIPS-enabled kernel.

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
      vendor="Red Hat, Inc." \
      version="${APP_VERSION}" \
      summary="<one-line summary>" \
      description="<detailed description of what the service does>"
```

### Required Labels

| Label | Description | Example |
|-------|-------------|---------|
| `name` | Service name (matches image name) | `hyperfleet-sentinel` |
| `vendor` | Organization | `Red Hat, Inc.` |
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

A complete reference Dockerfile for a shipped FIPS service incorporating the standards above. Replace `<service-name>` with the actual service binary name:

```dockerfile
ARG BASE_IMAGE=registry.access.redhat.com/ubi9/ubi-minimal:latest

FROM registry.access.redhat.com/ubi9/go-toolset:1.26 AS builder

ARG GIT_SHA=unknown
ARG GIT_DIRTY=""
ARG BUILD_DATE=""
ARG APP_VERSION="0.0.0-dev"

USER root
WORKDIR /build
RUN chown 1001:0 /build
USER 1001

ENV GOBIN=/build/.gobin
RUN mkdir -p $GOBIN

COPY --chown=1001:0 go.mod go.sum ./
RUN --mount=type=cache,target=/opt/app-root/src/go/pkg/mod,uid=1001 \
    go mod download

COPY --chown=1001:0 . .

# Enable FIPS only in the image; include the tagged main-package guard.
RUN --mount=type=cache,target=/opt/app-root/src/go/pkg/mod,uid=1001 \
    --mount=type=cache,target=/opt/app-root/src/.cache/go-build,uid=1001 \
    GOOS=linux GOFIPS140=v1.0.0 \
    GIT_SHA=${GIT_SHA} GIT_DIRTY=${GIT_DIRTY} BUILD_DATE=${BUILD_DATE} \
    make build GOFLAGS="-trimpath -tags=fips,no_openssl"

RUN go version -m /build/bin/<service-name> | grep -Eq 'GOFIPS140=v1[.]0[.]0(-[[:xdigit:]]+)?$' || { echo "FIPS check FAILED: missing GOFIPS140=v1.0.0"; exit 1; }
RUN go version -m /build/bin/<service-name> \
    | grep -E '^[[:space:]]*build[[:space:]]+DefaultGODEBUG=([^,]*,)*fips140=on(,|$)' \
    | grep -Ev 'DefaultGODEBUG=([^,]*,)*fips140ems=0(,|$)' \
    || { echo "FIPS check FAILED: require fips140=on without fips140ems=0"; exit 1; }
RUN GOLANG_FIPS=1 /build/bin/<service-name> --help >/dev/null || { echo "FIPS check FAILED: binary does not start in FIPS mode"; exit 1; }

FROM ${BASE_IMAGE}

WORKDIR /app

COPY --from=builder /build/bin/<service-name> /app/<service-name>

USER 65532:65532

EXPOSE 8080
ENTRYPOINT ["/app/<service-name>"]

ARG APP_VERSION="0.0.0-dev"
LABEL name="<service-name>" \
      vendor="Red Hat, Inc." \
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

```text
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
