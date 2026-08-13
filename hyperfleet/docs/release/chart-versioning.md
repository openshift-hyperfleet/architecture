---
Status: Active
Owner: Ciaran Roche
Last Updated: 2026-08-13
---

# Chart Versioning Strategy

> **Audience:** HyperFleet developers, release owners, and partner teams consuming HyperFleet Helm charts as OCI artifacts.

- **JIRA Story:** [HYPERFLEET-1212](https://redhat.atlassian.net/browse/HYPERFLEET-1212)
- **Parent Epic:** [HYPERFLEET-831](https://redhat.atlassian.net/browse/HYPERFLEET-831)
- **Related:** [Helm OCI Distribution Design](./helm-oci-distribution-design.md) | [Release Pipeline Design](./konflux-release-pipeline-design.md) | [Configuration Map](./operations/configuration-map.md) | [Pipeline Anatomy](./operations/pipeline-anatomy.md)

---

## 1. Overview

HyperFleet chart versioning operates in two modes:

| Mode | Trigger | Version source | Example tag |
|------|---------|----------------|-------------|
| **Dev (continuous)** | Merge to `main` | `build-helm-chart-oci-ta` native fallback | `0.1.469_e8fcb1c` |
| **Release (tagged)** | Push of `vX.Y.Z` / `vX.Y.Z-rcN` tag | Explicit `CHART_VERSION` + `APP_VERSION` from git tag | `1.0.0` |

Both modes use the same `build-helm-chart-oci-ta` Tekton task; the only difference is whether the pipeline supplies explicit version parameters.

---

## 2. How Chart Versions Are Derived

### Dev Builds (push to main)

The `chart-push.yaml` pipeline does **not** pass `CHART_VERSION` or `APP_VERSION` to the build task. The task falls back to its native versioning logic, which looks for `helm-X.Y` git tags. Since HyperFleet repos have no `helm-*` tags, the task applies its final fallback:

```text
0.1.<commit-distance>+<short-sha>
```

For example: `0.1.469+e8fcb1c`.

The `+` (semver build metadata separator) is converted to `_` in the OCI tag (see [OCI Tag Conversion](#5-oci-tag-conversion---_) below), so the pushed tag becomes `0.1.469_e8fcb1c`.

### Release Builds (tag push)

The `chart-tag.yaml` pipeline fires on semver tag pushes (`vX.Y.Z`, `vX.Y.Z-rcN`). An `extract-version` task strips the `refs/tags/v` prefix and passes the result as both `CHART_VERSION` and `APP_VERSION` to `build-helm-chart-oci-ta`:

```text
refs/tags/v1.0.0  →  CHART_VERSION=1.0.0, APP_VERSION=1.0.0
```

The chart publishes as `hyperfleet-api-chart:1.0.0` with `appVersion: "1.0.0"` in the packaged `Chart.yaml`.

---

## 3. Version Relationships

### Coupled Versioning

Chart version, app version, and git tag are coupled — one value, one tag:

```text
git tag v1.0.0
  → chart version: 1.0.0
  → appVersion:    1.0.0
  → OCI tag:       1.0.0
  → image tag:     1.0.0  (from the image tag.yaml pipeline on the same tag)
```

The chart version tracks the image version because both the image `tag.yaml` and the chart `chart-tag.yaml` pipelines fire on the same `vX.Y.Z` git tag and both derive their versions identically.

### Static Chart.yaml Values Are Overridden

Each repo's `Chart.yaml` has static placeholder values:

| Repo | `version` (static) | `appVersion` (static) |
|------|--------------------|-----------------------|
| hyperfleet-api | `1.2.0` | `"0.0.0-dev"` |
| hyperfleet-sentinel | `1.1.0` | `"0.0.0-dev"` |
| hyperfleet-adapter | `2.2.0` | `"0.0.0-dev"` |

The `build-helm-chart-oci-ta` task overrides both fields at build time. The static values exist solely for local `helm template` and `helm lint` ergonomics — they are never published as-is.

### Chart Name Renaming

The build task renames the chart to match the target repository's last path segment. For example, the chart source at `hyperfleet-api/charts/` with `name: hyperfleet-api` in `Chart.yaml` becomes `hyperfleet-api-chart` in the published OCI artifact.

---

## 4. Who Tags and When

Chart releases follow the same workflow as image releases — no separate process:

1. **Release Owner** pushes a `vX.Y.Z` or `vX.Y.Z-rcN` tag to the component repo.
2. **Both pipelines fire** on the same tag:
   - `.tekton/hyperfleet-<svc>-tag.yaml` — builds the container image
   - `.tekton/hyperfleet-<svc>-chart-tag.yaml` — builds the Helm chart
3. Each pipeline produces a Snapshot that auto-releases through its respective RPA (`hyperfleet.yaml` for images, `hyperfleet-charts.yaml` for charts).

No separate chart-only tags are needed. The `vX.Y.Z` tag is the single source of truth for both image and chart versions.

---

## 5. OCI Tag Conversion (`+` → `_`)

Semver allows build metadata after a `+` (e.g. `0.1.469+e8fcb1c`), but OCI tag specifications do not permit `+`. The `build-helm-chart-oci-ta` task converts `+` to `_` when writing the OCI tag:

| Context | Format | Example |
|---------|--------|---------|
| Semver (canonical) | `0.1.469+e8fcb1c` | Used in `Chart.yaml` `version` field |
| OCI tag | `0.1.469_e8fcb1c` | Pushed to Quay registry |
| `helm pull --version` | `0.1.469+e8fcb1c` | Helm resolves via `org.opencontainers.image.version` annotation |

The RPA uses the `{{ oci_version }}` template variable, which reads the `org.opencontainers.image.version` annotation from the OCI manifest — this always contains the canonical semver form (with `+`), and the RPA converts it to the `_` form for the OCI tag.

Release versions (e.g. `1.0.0`) contain no `+`, so no conversion is needed.

---

## 6. Consumer Pinning

### Release Versions

Pin to an exact minor range in `Chart.yaml` dependencies:

```yaml
# hyperfleet-infra/helm/api/Chart.yaml
dependencies:
  - name: hyperfleet-api-chart
    version: "~1.0.0"
    repository: "oci://quay.io/redhat-services-prod/hyperfleet-tenant"
```

Pull a specific release:

```bash
helm pull oci://quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet-api-chart \
  --version 1.0.0
```

### Dev Tracking

For development builds, omit `--version` to pull the latest available version, or pin to a specific dev version:

```bash
# Latest dev build (omit --version; Helm resolves the highest semver)
helm pull oci://quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet-api-chart

# Specific dev build (use the + form, not _)
helm pull oci://quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet-api-chart \
  --version 0.1.469+e8fcb1c
```

As a dependency pointing at a dev build:

```yaml
dependencies:
  - name: hyperfleet-api-chart
    version: "0.1.469+e8fcb1c"
    repository: "oci://quay.io/redhat-services-prod/hyperfleet-tenant"
```

---

## 7. Why Not Native `helm-X.Y` Tags

The `build-helm-chart-oci-ta` task natively supports `helm-X.Y` git tags for version derivation. HyperFleet intentionally does not use them:

| Concern | Using `helm-X.Y` tags | Current approach (reuse `vX.Y.Z`) |
|---------|----------------------|-----------------------------------|
| Tag maintenance | Separate tag series for charts | Reuse existing `vX.Y.Z` tags |
| Version coupling | Chart and image versions can diverge | Always coupled — one tag, one version |
| Pipeline complexity | Task derives version natively | `extract-version` task + explicit params |
| Control | Implicit — task decides | Full control via `CHART_VERSION`/`APP_VERSION` |
| Tag history | All repos would need `helm-*` tags alongside `v*` tags | Repos already have `v0.1.1` through `v0.3.0` — no new tags needed |

The explicit `CHART_VERSION`/`APP_VERSION` parameter approach gives full control over the published version and keeps the tag namespace clean. Maintaining a second tag series (`helm-*`) alongside the existing `v*` tags would add process overhead with no practical benefit.

---
