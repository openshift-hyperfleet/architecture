---
Status: Active
Owner: Ciaran Roche
Last Updated: 2026-05-11
---

# 0016 — Helm OCI Distribution via Konflux

## Context

HyperFleet distributes Helm charts to partner teams (GCP, ROSA) via the `helm-git` plugin, which pulls charts directly from Git repositories. This approach requires every consumer to install the plugin, provides no versioning semantics or content-addressable storage, and lacks signing or provenance. ArgoCD does not ship with `helm-git`, requiring custom images.

The Helm ecosystem has converged on OCI registries as the standard distribution mechanism (Bitnami OCI-only migration, Harbor ChartMuseum removal, Helm 4 OCI-first). Konflux provides native Helm chart OCI support through `build-helm-chart-oci-ta` and a dedicated release pipeline.

## Decision

Publish all HyperFleet Helm charts as OCI artifacts to Quay.io via the Konflux release pipeline.

Key design choices:

- **Konflux native tooling** — `build-helm-chart-oci-ta` for chart packaging. `push-to-external-registry` release pipeline with SA `release-sa-hyperfleet` for chart distribution. No custom Tekton tasks or GitHub Actions.
- **Separate Konflux Components** for chart builds — each component repo registers a `-chart` Component alongside its container image Component. Independent build triggers and Snapshots.
- **Chart-specific EC policy** derived from `registry-standard` with container-specific rules excluded (no base image checks, CVE scanning, SBOM, or label requirements). Provenance verification retained.
- **Standard image references** — chart `values.yaml` defaults point to Konflux-built images, overridable via `image.repository` and `image.tag` for local dev and E2E testing.
- **Coupled versioning** — chart version and appVersion always match the git tag. Chart and app live in the same repo, get the same tag, and `build-helm-chart-oci-ta` derives the version automatically.
- **`hyperfleet-infra` umbrella chart dependencies** migrate from `helm-git` to `oci://` references for versioned, content-addressable chart resolution.

See [Helm OCI Distribution Design](../docs/release/helm-oci-distribution-design.md) for the full design document.

## Consequences

**Gains:**

- No plugin dependency for chart consumers — standard Helm CLI and ArgoCD OCI support
- Immutable, content-addressable chart versions with SHA256 digests
- Supply chain security for charts — Tekton Chains provenance and cosign signing
- Single registry and pipeline for all artifacts (images and charts)
- Chart image defaults point to Konflux-built images, overridable for local dev and E2E

**Trade-offs:**

- Additional Konflux configuration to maintain (Components, RPA, EC policy per chart)
- `hyperfleet-infra` umbrella chart migration requires testing with local dev and E2E workflows

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| Continue with helm-git | Plugin dependency, no versioning/signing/provenance, ArgoCD requires custom images. Industry moving away. |
| GitHub Actions for chart publishing | Split pattern (Konflux for images, GHA for charts). No Chains provenance. Konflux has native support. |
| Traditional Helm repository (ChartMuseum / GitHub Pages) | Separate infrastructure. ChartMuseum deprecated. No content-addressable storage or signing. |
| Single Konflux Component for image + chart | Konflux's Snapshot model produces one artifact per Component. A single Component cannot produce both a container image and a Helm chart OCI artifact. All teams (RHOAI, flightctl) use separate Components. |
