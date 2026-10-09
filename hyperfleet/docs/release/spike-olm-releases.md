---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-10-08
---

# SPIKE: OLM Bundle and Catalog Release Process

**Ticket:** [HYPERFLEET-1617](https://issues.redhat.com/browse/HYPERFLEET-1617)

## Context

The current release flow for the hyperfleet components involves helm charts and
container images. Look at
[hyperfleet-release-process.md](./hyperfleet-release-process.md) for more
information. The current gap is the introduction of the hyperfleet-operator. The
hyperfleet-operator will become the entrypoint for all hyperfleet components,
replacing the current helm based installation. Because the operator will be
installed and managed via the Operator Lifecycle Manager (OLM), the release
process must now generate OLM-compliant bundles and file-based catalogs (FBC).
This needs to work in conjunction with the current process of cutting each
branch at the release version and producing a component image. This spike
addresses the question of how we will version and release the operator bundle
and catalog.

---

## 1. Bundle Versioning

When managing an operator using OLM and File-Based Catalogs (FBC), releasing
across multiple environments (staging and prod) requires a clear strategy for
how the bundle artifact moves through the pipeline.

### Release Candidate (RC) Workflow

Build RC-versioned bundles during validation, iterate if issues arise, and build
the official release bundle once the final RC is validated. The official release
bundle references the exact same component image digests and manifests as the
validated RC—the only delta is the version string in the CSV.

**Workflow:** Example for release `v1.0.0` (branch: `release-1.0`)

1. Developer tags commit as `bundle-v1.0.0-rc1`
2. Build operator bundle `v1.0.0-rc1` referencing the component image digests.
3. Add `v1.0.0-rc1` to the `candidate-v1` channel and build the catalog.
   References: [Catalogs](#catalogs) and [Channels](#channels)
4. If broken: apply fix, build `v1.0.0-rc2`, and iterate.
5. Once the last RC validates cleanly: tag and build the `v1.0.0` official
   release bundle, and add it to the `stable-v1` channel.

**Pros:**

- **Clean version history:** No gaps or phantom patch versions in the registry.
- **Consistent process:** Aligns directly with the existing component release
  model.
- **Safe iteration:** Bundle issues (RBAC, CRD schemas, install modes) are
  caught and resolved before the official release version is published.
- **Minimal risk:** The rebuild delta between RC and official release is near
  zero—the manifests and component digests remain identical, with only the CSV
  version string changing.

**Cons:**

- The official bundle is technically a different artifact than the last RC
  (rebuilt, not promoted)
- Requires the tag pipeline to support RC-suffixed tags (already covered by the
  CEL expression `bundle-v[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?`)

### Alternatives Considered

#### Artifact Promotion (Immutability Model)

Build the operator bundle image **once** and rely on OLM catalog channels to
control when that specific container digest is rolled out to different
environments.

**Workflow:** Example for release `v1.0.0` (branch: `release-1.0`)

1. Developer tags commit as `bundle-v1.0.0`
2. CI builds the operator bundle once: `hyperfleet-bundle:v1.0.0`
3. Add `v1.0.0` to the `candidate-v1` channel and build the catalog.
4. Validates the preprod environment
5. **No rebuild.** The same `v1.0.0` bundle entry is copied into the `stable-v1`
   channel and the catalog is rebuilt.

**Cons:**

- If the bundle breaks in `candidate-v1`, you cannot retag or rebuild `v1.0.0`
  bundle in an immutable registry. OLM reads the CSV version from **inside** the
  bundle image, so retagging the image does not fix the internal version
  mismatch.
- The fix requires bumping to `v1.0.1`, meaning the first production release may
  not be `v1.0.0` — creating version gaps and a patch version that is not
  actually a patch.
- Does not align with the existing component release flow, which already uses
  RCs.

## 2. Component Updates

**Problem:** Release workflow needs to update release images `hyperfleet-api`,
`hyperfleet-sentinel`, `hyperfleet-operator`, `hyperfleet-adapter` and
accurately update them in the `config/manifests/prod/kustomization.yaml`.
Currently there is a build nudge workflow where new API/Operator images trigger
update to `config/manifests/prod/kustomization.yaml` which builds the operator
bundle image. Once that's updated, builds the catalog bundle image. Current
blocker is all components reference the `main` branch. No automatic nudge to
release branches.

### Option 1: Manually update images on the release branch (Recommended)

After component images are built from release tags, manually update the digests
in `config/manifests/prod/kustomization.yaml` on the release branch.

**Pros:**

- No additional components needed
- Simple, no infrastructure changes

**Cons:**

- Error-prone — manual digest copy/paste. Covered with bundle validation.
- Slower release flow

### Option 2: Use MintMaker (scheduled Renovate) for release branch updates

Unlike component nudges, MintMaker reads the repo's `renovate.json` and supports
`baseBranches`. Configure `renovate.json` to scan release branches for outdated
image digests and open grouped PRs:

```json
{
  "extends": ["github>openshift-hyperfleet/renovate-config"],
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "baseBranchPatterns": ["main", "/^release\\/.*/"],
  "packageRules": [
    {
      "matchBaseBranches": ["main"],
      "matchPackagePatterns": [
        "^quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/.*$"
      ],
      "ignoreVersions": [
        "/^v\\d+\\.\\d+\\.\\d+.*$/",
        "/^[0-9]+\\.[0-9]+\\.[0-9]+.*$/"
      ]
    },
    {
      "matchBaseBranches": ["/^release-\\d+\\.\\d+$/"],
      "matchPackagePatterns": [
        "^quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/.*$"
      ],
      "groupName": "HyperFleet Release Components",
      "commitMessageTopic": "HyperFleet component images",
      "automerge": false
    }
  ]
}
```

MintMaker would detect new image digests in
`config/manifests/prod/kustomization.yaml` on release branches and open PRs
automatically.

**Pros:**

- No additional components needed — works with existing three components on
  `main`
- No ConfigMap changes — entirely repo-level configuration
- No manual digest copy/paste

**Cons:**

- Scan-based, not event-driven — delay between image build and PR creation
  (minutes to hours depending on scan interval)
- Introduces unpredictable wait times in the middle of a release flow
- Does not chain — each step (operator → bundle → catalog) waits for the next
  scan cycle
- Release flow becomes "tag, wait for MintMaker, merge, tag next, wait again"

### Decision

Manually update release digests on `hyperfleet-operator` release branches.
Future work can be scoped to automating this process.

## 3. Catalog Upgrade Path

**Problem:** The catalog defines the OLM upgrade graph — which bundle versions
exist, which channels they belong to, and how clusters upgrade between them.
Because bundles are built from individual release branches (`release-1.0`,
`release-1.1`), the upgrade graph spans multiple branches. No single release
branch has the complete picture of all versions in the channels. If the catalog
templates lived on release branches, each branch would only know about its own
versions. A cluster on `v1.0.1` (from `release-1.0`) wouldn't have an upgrade
path to `v1.1.0` (from `release-1.1`) unless the `release-1.1` branch carried
forward all prior entries — and hotfixes on older branches would need to be
propagated forward to whichever branch is "latest."

**Solution:** Single aggregate catalog on `main`

The catalog templates live on `main` in a single `release-template.yaml` file
that contains all major versions:

### Proposed catalog directory structure

```text
catalog/
├── konflux-template.yaml
└── release-template.yaml
```

The `release-template.yaml` is the **single source of truth** for all major
versions' upgrade graphs. When a new bundle is released (e.g., `v1.1.0`), its
channel entry and bundle digest are added to the appropriate channel
(`candidate-v1` or `stable-v1`) via a PR.

This approach works because:

- **All major versions in one file** — `release-template.yaml` contains both v1
  and v2 channels, so the rendered catalog always includes all supported major
  versions
- **Complete upgrade graph in one place** — no carrying forward entries between
  branches, no directory aggregation needed
- **Catalog builds from a tagged commit** — when you tag `catalog-v1.1.0` on
  `main`, the pipeline builds from that exact commit. Later merges to `main`
  don't affect the build
- **Release branches stay focused** — they own the bundle (component digests in
  `kustomization.yaml`, CSV). The catalog is a separate concern on `main`
- **No additional components or branches** — the existing catalog component on
  `main` can build release catalogs using the single template

The nightly dev catalog (`konflux-template.yaml`) remains unchanged on `main` —
it continues to use the unversioned `stable` channel with `v0.0.1` for CI
builds.

Required Changes:

- [Create a catalog tag pipeline](#2-create-a-catalog-tag-pipeline)
- [Create a release template](#3-create-a-release-template)

---

## Proposed Operator Release Workflow (End-to-End)

### Step 1: Cut release branches and build component images

Cut `release-X.Y` branches on each component repo (`hyperfleet-api`,
`hyperfleet-sentinel`, `hyperfleet-adapter`, `hyperfleet-operator`). Tag
component RC versions (`vX.Y.Z-rcN`) on their respective release branches.
Konflux builds and pushes the component images to Quay automatically via the
existing tag pipelines.

### Step 2: Update the component images

Open a PR on the operator's release branch to update the component image digests
in `config/manifests/prod/kustomization.yaml` with the digests produced by the
release tag builds in Step 1. Merge the PR before tagging the bundle RC.

See [Component Updates](#2-component-updates) for the rationale behind the
manual approach.

### Step 3: Tag the bundle RC

Tag the release branch with `bundle-vX.Y.Z-rcN` and push. Bundle tag pipeline
should build.

**Example:** tag `bundle-v1.0.0-rc1` on the operator's `release-1.0` branch. The
bundle tag pipeline triggers and builds the bundle image. The version in the CSV
is set to `1.0.0-rc1` (tag with `bundle-v` prefix stripped).

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: ClusterServiceVersion
metadata:
  name: hyperfleet-operator.v1.0.0-rc1
  namespace: placeholder
spec:
  displayName: HyperFleet Operator
  version: 1.0.0-rc1
```

### Step 4: Update the catalog

On the `main` branch, add the RC bundle to the `candidate-vX` channel in
`catalog/release-template.yaml`. Push this change to main and tag the commit
`catalog-vX.Y.Z-rcN`, which will trigger the catalog-tag pipeline.

**Example:** Adding `candidate-v1` for `release-1.0` and adding the rc1 entry
that was built in step 3.

```yaml
schema: olm.channel
name: candidate-v1
package: hyperfleet-operator
entries:
  - name: hyperfleet-operator.v1.0.0-rc1
```

**Note:** Information regarding this decision can be found here:
[Catalog Upgrade Path](#3-catalog-upgrade-path)

### Step 5: Validate in Preprod

Cut `release-X.Y` branch in `hyperfleet-e2e` repo.

This step is a prerequisite for the release gate. Configure the Prow job to
install HyperFleet from the catalog's `candidate-vX` channel before running this
validation.

After that setup exists, E2E tests validate OLM install mechanics (RBAC, CRDs,
install modes), component health, end-to-end functionality, and upgrades in the
Prow cluster.

### Step 6: Handle failures (if any)

**If the issue is in a component image** (e.g., Operator, Adapter, API,
Sentinel):

1. Fix the component on main, cherry-pick to the release branch
2. Tag a new component version (e.g., `v1.0.1`)
3. Update the new digest on the operator's `release-X.Y` branch (e.g.,
   `release-1.0`)
4. Tag `bundle-vX.Y.0-rc2` → pipeline builds new bundle (e.g.,
   `bundle-v1.0.0-rc2` -> csv
   `name: hyperfleet-operator.v1.0.0-rc2 version: 1.0.0-rc2`)

**If the issue is in the bundle itself** (RBAC, CRDs, CSV metadata):

1. Make the required change on main and cherry-pick change to `release-X.Y`
2. Tag `bundle-vX.Y.0-rc2` → pipeline builds new bundle (e.g.,
   `bundle-v1.0.0-rc2` -> csv
   `name: hyperfleet-operator.v1.0.0-rc2 version: 1.0.0-rc2`)

In both cases, update the `candidate-vX` channel in
`catalog/release-template.yaml` on the `main` branch. Tag the change and rebuild
the catalog image and revalidate.

**Example:**

```yaml
schema: olm.channel
name: candidate-v1
package: hyperfleet-operator
entries:
  - name: hyperfleet-operator.v1.0.0-rc1
    skipRange: "<1.0.0"
  - name: hyperfleet-operator.v1.0.0-rc2
    replaces: hyperfleet-operator.v1.0.0-rc1
  - schema: olm.bundle
    image: quay.io/redhat-services-prod/.../hyperfleet-operator-bundle@sha256:<digest-rc1>
  - schema: olm.bundle
    image: quay.io/redhat-services-prod/.../hyperfleet-operator-bundle@sha256:<digest-rc2>
```

### Step 7: Promote to stable channel

Once everything is validated cleanly, tag the release-X.Y branch with
`bundle-vX.Y.Z`. This will trigger the official bundle build. Update the
`stable-vX` channel and add the `olm.bundle` entry in
`catalog/release-template.yaml` on the `main` branch. Tag the change and rebuild
the catalog image.

**Example:**

1. Tag `bundle-v1.0.0` on the operator's `release-1.0` branch, which will
   trigger the tag pipeline to build the official bundle
2. Add the bundle to the `stable-v1` channel and its `olm.bundle` digest to
   `catalog/release-template.yaml` on `main`, tag that change as
   `catalog-v1.0.0` and build the catalog image

```yaml
schema: olm.template.basic
entries:
  - schema: olm.package
    name: hyperfleet-operator
    defaultChannel: stable-v1
    description: "HyperFleet Operator"
  - schema: olm.channel
    name: stable-v1
    package: hyperfleet-operator
    entries:
      - name: hyperfleet-operator.v1.0.0
        skipRange: "<1.0.0"
  # Add the olm.bundle entry for the newly built official bundle
  - schema: olm.bundle
    image: quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-bundle@sha256:<digest>
```

**Note:** The `stable-v1` channel does not need to include the RC chain — it
points straight at the official version. The RC upgrade graph only lives in
`candidate-v1`, keeping the production channel clean.

---

## Channels

### Channel Versioning

OLM channels control which bundle versions are available. Channel naming and
lifecycle decisions determine upgrade paths, how environments are separated, and
how multiple major releases coexist.

### Channel Naming Convention

Each major release gets its own pair of channels:

| Channel        | Purpose                         | Subscribers      |
| -------------- | ------------------------------- | ---------------- |
| `candidate-vX` | RC validation before production | preprod clusters |
| `stable-vX`    | Production-ready releases       | prod clusters    |

For the v1 release:

- `candidate-v1` — receives `v1.0.0-rc1`, `v1.0.1-rc2`, etc.
- `stable-v1` — receives `v1.0.0`, `v1.0.1`, `v1.0.2`, etc.

### Channel Lifecycle Across Releases

Each minor/patch release within a major version adds entries to the **same**
channel pair. A new channel pair is only created for a new major version.

```text
stable-v1
  ├── hyperfleet-operator.v1.0.0
  ├── hyperfleet-operator.v1.0.1  (replaces v1.0.0)
  ├── hyperfleet-operator.v1.1.0  (replaces v1.0.1)
  └── hyperfleet-operator.v1.2.0  (replaces v1.1.0)

stable-v2 (created only when major version 2 ships)
  ├── hyperfleet-operator.v2.0.0
  └── hyperfleet-operator.v2.0.1  (replaces v2.0.0)
```

### Upgrade Paths

Within a channel, OLM uses the `replaces` field to build the upgrade graph. Each
new entry declares which version it replaces:

```yaml
schema: olm.channel
name: stable-v1
package: hyperfleet-operator
entries:
  - name: hyperfleet-operator.v1.0.0
  - name: hyperfleet-operator.v1.0.1
    replaces: hyperfleet-operator.v1.0.0
  - name: hyperfleet-operator.v1.1.0
    replaces: hyperfleet-operator.v1.0.1
```

Clusters on `v1.0.0` will upgrade through `v1.0.1` → `v1.1.0` automatically.
Channels will be the single source of truth for the upgrade graph.

#### Using `skipRange` for direct upgrades

The `skipRange` field allows clusters to jump directly to a newer version,
bypassing all intermediate releases within a semver range. This is useful when
intermediate patch versions are safe to skip (no required migration steps).

```yaml
schema: olm.channel
name: stable-v1
package: hyperfleet-operator
entries:
  - name: hyperfleet-operator.v1.0.0
  - name: hyperfleet-operator.v1.0.1
    replaces: hyperfleet-operator.v1.0.0
  - name: hyperfleet-operator.v1.1.0
    replaces: hyperfleet-operator.v1.0.1
    skipRange: ">=1.0.0 <1.1.0"
```

With this configuration:

- A cluster on `v1.0.0` or `v1.0.1` can upgrade **directly** to `v1.1.0`
- No need to enumerate individual versions

**Cross-major upgrades** (e.g., `stable-v1` → `stable-v2`) require the cluster
admin to change their Subscription's channel. This is intentional — major
version upgrades may include breaking changes and should not happen
automatically.

---

## Bundles

### Bundle Image Tagging

Each bundle build is triggered by a git tag on the operator's release branch
(`bundle-vX.Y.Z-rcN` for release candidates, `bundle-vX.Y.Z` for official
releases). The pipeline builds the bundle image and sets the CSV version to the
tag value with the `bundle-v` prefix stripped (e.g., `bundle-v1.0.0-rc1` →
`1.0.0-rc1`).

Bundle images are immutable — each version produces a distinct image:

```text
quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-bundle:v1.0.0-rc1
quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-bundle:v1.0.0-rc2
quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-bundle:v1.0.0
```

The CSV version inside the bundle image must match the catalog entry name (e.g.,
`hyperfleet-operator.v1.0.0`). Because this version is baked into the image at
build time, bundles cannot be retagged or promoted — a new version requires a
new build.

### Bundle Build Flow

```text
Release (release branch):
  push bundle-vX.Y.Z[-rcN] git tag → bundle-tag pipeline → bundle image :vX.Y.Z[-rcN]
```

### Bundle Annotations

With FBC, the **catalog** is the authority on channel membership, not the
bundle. The bundle's channel annotations in `annotations.yaml` are metadata for
tooling (`operator-sdk bundle validate`, `opm render`) but OLM does not read
them to decide channel membership.

Set them for documentation and validation purposes using values that work for
both RC and official builds:

These will be set in the `bundle.Dockerfile` based on the `BUILD_ARGS`

```yaml
annotations:
  operators.operatorframework.io.bundle.channels.v1: candidate-vX,stable-vX
  operators.operatorframework.io.bundle.channel.default.v1: stable-vX
```

These do not need to change between RC and official builds. The catalog controls
which channel each version actually lands in.

---

## Catalogs

### Catalog Image Tagging

The catalog image uses a single mutable tag:
`quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-catalog:latest`.

Each catalog build is triggered by a unique git tag (`catalog-vX.Y.Z-rcN`,
`catalog-vX.Y.Z`, etc.) and pushes to `:latest`. Production CatalogSources
reference this `:latest` tag.

**Aggregate catalog strategy:** Each release uses
`catalog/release-template.yaml`, which contains **all** major version channels
(v1, v2, etc.) in a single FBC template. The `:latest` image always contains all
supported major versions. This allows:

- v1 clusters continue receiving v1 updates after v2 ships
- Cross-major upgrades via Subscription channel switch

See [Required Changes](#2-create-a-catalog-tag-pipeline) for the pipeline
configuration. Validation gates should verify that all previously published
major versions remain present after each catalog rebuild.

### Catalog Build Flow

```text
Release (main branch):
  update catalog/release-template.yaml
  push catalog-vX.Y.Z git tag → catalog-tag pipeline → catalog image :latest
```

### Current Catalog Build

The catalog has one push pipeline (`hyperfleet-operator-catalog-push.yaml`) that
triggers on main merges when `catalog/` files change. The pipeline's
`run-opm-command` task renders `catalog/konflux-template.yaml` into an FBC
catalog, then `catalog.Dockerfile` packages the rendered output into the final
image.

This does not support release catalogs because:

1. `konflux-template.yaml` hardcodes a single unversioned `stable` channel —
   release catalogs need versioned channels (`stable-v1`, `candidate-v1`)
2. There is no tag pipeline to build the catalog from tagged commits
3. `konflux-template.yaml` is updated by build-nudges on main — release digests
   should not be automatically updated

These gaps are addressed in the
[Create a catalog tag pipeline](#2-create-a-catalog-tag-pipeline) and
[Create a release template](#3-create-a-release-template) sections below.

## Required Changes

### `hyperfleet-operator` Repository

#### 1. Create a bundle tag pipeline

Add `hyperfleet-operator-bundle-tag.yaml` to `.tekton/`. This pipeline triggers
on release tag push:

The bundle-tag pipeline requires these changes:

1. Annotations

```yaml
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  annotations:
    build.appstudio.openshift.io/repo: https://github.com/openshift-hyperfleet/hyperfleet-operator?rev={{revision}}
    build.appstudio.redhat.com/commit_sha: "{{revision}}"
    build.appstudio.redhat.com/target_branch: "{{target_branch}}"
    # Trigger on bundle release tags (e.g., bundle-v1.0.0-rc1, bundle-v1.0.0)
    pipelinesascode.tekton.dev/on-cel-expression: |
      event == "push"
      && target_branch.matches("^refs/tags/bundle-v[0-9]+\\.[0-9]+\\.[0-9]+(-rc[0-9]+)?$")
```

1. Set `BUILD_ARGS`

```yaml
- name: BUILD_ARGS
  value:
    - $(params.build-args[*])
    - KUSTOMIZE_VARIANT=config/manifests/prod
    - BUNDLE_VERSION=$(tasks.parse-version.results.VERSION)
    - APP_VERSION=$(tasks.parse-version.results.VERSION)
    - CHANNELS=candidate-$(tasks.parse-version.results.MAJOR),stable-$(tasks.parse-version.results.MAJOR)
    - DEFAULT_CHANNEL=stable-$(tasks.parse-version.results.MAJOR)
    - VALIDATE_RELATED_IMAGES=true
```

1. `parse-version` task to extract values from git-tag

```yaml
# parse-version task and add the git-tag param
spec:
  params:
    - name: git-tag
      value: "{{git_tag}}"
...
pipelineSpec:
  tasks:
    - name: parse-version
      params:
        - name: GIT_TAG
          value: $(params.git-tag)
      taskSpec:
        results:
          - name: VERSION
            description: Version extracted from git tag ref, dropped the v
          - name: MAJOR
            description: Major extracted from git tag persist the v
        steps:
          - name: parse
            image: registry.access.redhat.com/ubi9-minimal:latest
            script: |
              #!/usr/bin/env bash
              VERSION="${GIT_TAG#bundle-v}"
              MAJOR="v${VERSION%%.*}"
              printf '%s' "$VERSION" > "$(results.VERSION.path)"
              printf '%s' "$MAJOR" > "$(results.MAJOR.path)"
```

#### 2. Create a catalog tag pipeline

Add `hyperfleet-operator-catalog-tag.yaml` to `.tekton/`. This pipeline triggers
on a specific `tag` push of `catalog-vX.Y.Z-rcN` (candidate) or `catalog-vX.Y.Z`
(stable)

The catalog-tag pipeline requires these changes:

1. Annotations

```yaml
annotations:
  build.appstudio.openshift.io/repo: https://github.com/openshift-hyperfleet/hyperfleet-operator?rev={{revision}}
  build.appstudio.redhat.com/commit_sha: "{{revision}}"
  build.appstudio.redhat.com/target_branch: "{{target_branch}}"
  build.appstudio.redhat.com/git_tag: "{{git_tag}}"
  pipelinesascode.tekton.dev/cancel-in-progress: "false"
  # Trigger on catalog release tags (e.g., catalog-v1.0.0-rc1 or catalog-v1.0.0)
  pipelinesascode.tekton.dev/on-cel-expression: |
    event == "push"
    && target_branch.matches("^refs/tags/catalog-v[0-9]+\\.[0-9]+\\.[0-9]+(-rc[0-9]+)?$")
```

1. `opm-run-command` task `OPM_ARGS`

```yaml
# OPM_ARGS uses the single release template containing all major versions
- name: OPM_ARGS
  value:
    - alpha
    - render-template
    - basic
    - --migrate-level=bundle-object-to-csv-metadata
    - -o
    - yaml
    - catalog/release-template.yaml
```

#### 3. Create a release template

Add `catalog/release-template.yaml` on `main` branch. This file defines all
versioned channels across all major versions. As new bundles are released, the
appropriate channel is updated and bundle digests are appended. The existing
`konflux-template.yaml` stays unchanged for nightly builds on main — it
continues to use the unversioned `stable` channel with `v0.0.1`.

**Example:** `catalog/release-template.yaml` showing both v1 and v2 channels
(state after v2 ships)

```yaml
---
schema: olm.template.basic
entries:
  - schema: olm.package
    name: hyperfleet-operator
    defaultChannel: stable-v2
    description: "HyperFleet Operator"
  # v1 channels
  - schema: olm.channel
    name: candidate-v1
    package: hyperfleet-operator
    entries:
      - name: hyperfleet-operator.v1.0.0-rc1
  - schema: olm.channel
    name: stable-v1
    package: hyperfleet-operator
    entries:
      - name: hyperfleet-operator.v1.0.0
      - name: hyperfleet-operator.v1.0.1
        replaces: hyperfleet-operator.v1.0.0
  # v2 channels (added when v2 ships)
  - schema: olm.channel
    name: candidate-v2
    package: hyperfleet-operator
    entries:
      - name: hyperfleet-operator.v2.0.0-rc1
  - schema: olm.channel
    name: stable-v2
    package: hyperfleet-operator
    entries:
      - name: hyperfleet-operator.v2.0.0
  # Bundle image references for all versions
  - schema: olm.bundle
    image: quay.io/redhat-services-prod/.../hyperfleet-operator-bundle@sha256:<v1.0.0-rc1-digest>
  - schema: olm.bundle
    image: quay.io/redhat-services-prod/.../hyperfleet-operator-bundle@sha256:<v1.0.0-digest>
  - schema: olm.bundle
    image: quay.io/redhat-services-prod/.../hyperfleet-operator-bundle@sha256:<v1.0.1-digest>
  - schema: olm.bundle
    image: quay.io/redhat-services-prod/.../hyperfleet-operator-bundle@sha256:<v2.0.0-rc1-digest>
  - schema: olm.bundle
    image: quay.io/redhat-services-prod/.../hyperfleet-operator-bundle@sha256:<v2.0.0-digest>
```

**Note:** When v2 ships, update the `defaultChannel` to `stable-v2` and add the
v2 channel entries. All v1 channels and bundles remain in the file so the
catalog continues to serve both major versions.

### `konflux-release-data` Repository

#### 1. Create an RPA for the catalog image

Add a ReleasePlanAdmission in `konflux-release-data` for the catalog component
so that Konflux can release catalog images to the production Quay registry.
Default tags are currently set as:

```yaml
tags:
  - "{{ labels.version }}"
  - "{{ labels.version }}-{{ timestamp }}"
  - "{{ git_sha }}"
  - latest
```

```yaml
- name: hyperfleet-operator-catalog
  repositories:
    - url: "quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-catalog"
```
