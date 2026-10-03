---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-09-25
---

# SPIKE: OLM Bundle and Catalog Release Process

**Ticket:** [HYPERFLEET-1617](https://issues.redhat.com/browse/HYPERFLEET-1617)

## Context

The current release flow for the hyperfleet components involves helm charts and images. Look at [hyperfleet-release-process.md](./hyperfleet-release-process.md) for more information. The current gap is the introduction of the hyperfleet-operator. The hyperfleet-operator will become the entrypoint for all hyperfleet components, replacing the current helm based installation. Because the operator will be installed and managed via the Operator Lifecycle Manager (OLM), the release process must now generate OLM-compliant bundles and file-based catalogs (FBC). Releases for the components will be based on that as the entry point. This needs to work in conjunction with the current process of cutting each branch at the release version and producing a component image. This spike addresses the question of how we will version and release the operator bundle and catalog.

## Open Considerations

### Bundle Versioning Options

When managing an operator using OLM and File-Based Catalogs (FBC), releasing across multiple environments (staging and prod) requires a clear strategy for how the bundle artifact moves through the pipeline. Two primary approaches exist:

#### Option 1: Release Candidate (RC) Workflow (Recommended)

Build RC-versioned bundles during validation, iterate if issues arise, and build the official release bundle once the final RC is validated. The official release bundle references the exact same component image digests and manifests as the validated RC—the only delta is the version string in the CSV.

**Workflow:**
Example for release `v1.0.0` (branch: `release-1.0`)

1. Cut release branch release-1.0
2. Developer tags commit as `bundle-v1.0.0-rc1`
3. Build operator bundle `v1.0.0-rc1` referencing the component image digests.
4. Add `v1.0.0-rc1` to the `candidate-1.0` channel and build the catalog.
5. If broken: apply fix, build `v1.0.0-rc2`, and iterate.
6. Once the last RC validates cleanly: tag and build the `v1.0.0` official release bundle, and add it to the `stable-1.0` channel.

**Pros:**

- **Clean version history:** No gaps or phantom patch versions in the registry.
- **Consistent process:** Aligns directly with the existing component release model.
- **Safe iteration:** Bundle issues (RBAC, CRD schemas, install modes) are caught and resolved before the official release version is published.
- **Minimal risk:** The rebuild delta between RC and official release is near zero—the manifests and component digests remain identical, with only the CSV version string changing.

**Cons:**

- The official bundle is technically a different artifact than the last RC (rebuilt, not promoted)
- Requires the tag pipeline to support RC-suffixed tags (already covered by the CEL expression `bundle-v[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?`)

#### Option 2: Artifact Promotion (Immutability Model)

Build the operator bundle image **once** and rely on OLM catalog channels to control when that specific container digest is rolled out to different environments.

**Workflow:**
Example for release `v1.0.0` (branch: `release-1.0`)

1. Cut release branch release-1.0
2. Developer tags commit as `bundle-v1.0.0`
3. CI builds the operator bundle once: `hyperfleet-bundle:v1.0.0`
4. Add `v1.0.0` to the `candidate-1.0` channel and build the catalog.
5. Validates the preprod environment
6. **No rebuild.** The same `v1.0.0` bundle entry is copied into the `stable-1.0` channel and build the catalog again.

**Pros:**

- What you test is byte-for-byte what you ship — true immutability
- Simpler pipeline — one build, promotion is a catalog metadata change

**Cons:**

- If the bundle breaks in `candidate-1.0`, you cannot retag or rebuild `v1.0.0` bundle in an immutable registry. OLM reads the CSV version from **inside** the bundle image, so retagging the image does not fix the internal version mismatch.
- The fix requires bumping to `v1.0.1`, meaning the first production release may not be `v1.0.0` — creating version gaps and a patch version that is not actually a patch.
- Does not align with the existing component release flow, which already uses RCs.

#### Decision

**Option 1 (RC Workflow) is recommended.** Artifact Promotion works well for component images where Konflux already handles build-once-release, but OLM bundles have an additional constraint: the CSV version is baked into the image and must match the catalog entry name. This makes true retagging impossible in an immutable registry and forces version bumps on any bundle fix. The RC model avoids this by iterating on RC versions before the official release.

---

## Proposed Operator Release Workflow (End-to-End)

### Step 1: Cut release branches and build component images

Cut `release-X.Y` branches on each component repo (`hyperfleet-api`, `hyperfleet-sentinel`, `hyperfleet-adapter`, `hyperfleet-operator`). Tag component official versions (`vX.Y.Z`) on their respective release branches—Konflux builds and pushes the component images to Quay automatically via the existing tag pipelines.

### Step 2: Update operator bundle with component images

Renovate detects the new component image digests and opens a PR on the operator's (e.g., `release-1.0`) branch grouping all image updates together. Merge the Renovate PR.

### Step 3: Tag the bundle RC

Tag the release branch with `bundle-vX.Y.Z-rcN` and push. Bundle tag pipeline should build.

Example: tag `bundle-v1.0.0-rc1` on the operator's `release-1.0` branch. The bundle tag pipeline triggers and builds the bundle image. The version in the CSV is set to `1.0.0-rc1` (tag with `bundle-v` prefix stripped).

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

On the release-X.Y branch, add the RC bundle to the `candidate-X.Y` channel in the FBC catalog:

Example: Adding `candidate-1.0` for `release-1.0` and adding the rc1 entry just built

```yaml
schema: olm.channel
name: candidate-1.0
package: hyperfleet-operator
entries:
  - name: hyperfleet-operator.v1.0.0-rc1
```

Push this template change to the `release-X.Y` branch. Tag the commit as
`catalog-vX.Y.0-rc1`.

### Step 5: Validate in preprod

E2E tests validate against the `candidate-1.0` channel. Validate OLM install mechanics (RBAC, CRDs, install modes), component health, and end-to-end functionality in the Prow cluster. Run E2E tests and validate upgrade functionality.

### Step 6: Handle failures (if any)

**If the issue is in a component image** (e.g., Operator, Adapter, API, Sentinel):

1. Fix the component on main, cherry-pick to the release branch
2. Tag a new component version (e.g., `v1.0.1`)
3. Renovate picks up the new digest on the operator's `release-X.Y` branch (e.g., `release-1.0`)
4. Merge the Renovate PR
5. Tag `bundle-vX.Y.0-rc2` → pipeline builds new bundle (e.g., `bundle-v1.0.0-rc2` -> csv `name: hyperfleet-operator.v1.0.0-rc2 version: 1.0.0-rc2`)

**If the issue is in the bundle itself** (RBAC, CRDs, CSV metadata):

1. Make the required change on main and cherry-pick change to `release-X.Y`
2. Tag `bundle-vX.Y.0-rc2` → pipeline builds new bundle (e.g., `bundle-v1.0.0-rc2` -> csv `name: hyperfleet-operator.v1.0.0-rc2 version: 1.0.0-rc2`)

In both cases, update the catalog's `candidate-1.0` channel:

```yaml
schema: olm.channel
name: candidate-1.0
package: hyperfleet-operator
entries:
  - name: hyperfleet-operator.v1.0.0-rc2
    replaces: hyperfleet-operator.v1.0.0-rc1
```

Push template update to release branch, tag the change which will rebuild the catalog image and revalidate.

### Step 7: Promote to stable channel

Once everything is validated cleanly, tag the release-X.Y branch with `bundle-vX.Y.Z`.
This will trigger the official bundle build.

Then add the official bundle to the stable channel. Push and tag that change, which will trigger the official catalog build.

Example:
Tag `bundle-v1.0.0` on the operator's `release-1.0` branch. The tag pipeline builds the official bundle. Add the bundle to the `stable-1.0` channel:

```yaml
schema: olm.channel
name: stable-1.0
package: hyperfleet-operator
entries:
  - name: hyperfleet-operator.v1.0.0
```

Tag this change as `catalog-v1.0.0` and the catalog will build.

**Note:** The `stable-1.0` channel does not need to include the RC chain — it points straight at the official version. The RC upgrade graph only lives in `candidate-1.0`, keeping the production channel clean.

---

## Channels

### Channel Versioning

OLM channels control which bundle versions are available. Channel naming and lifecycle decisions determine upgrade paths, how environments are separated, and how multiple major releases coexist.

### Channel Naming Convention

Each major release gets its own pair of channels:

| Channel         | Purpose                         | Subscribers      |
| --------------- | ------------------------------- | ---------------- |
| `candidate-X.Y` | RC validation before production | preprod clusters |
| `stable-X.Y`    | Production-ready releases       | prod clusters    |

For the v1 release:

- `candidate-1.0` — receives `v1.0.0-rc1`, `v1.0.0-rc2`, etc.
- `stable-1.0` — receives `v1.0.0`, `v1.0.1`, `v1.0.2`, etc.

### Channel Lifecycle Across Releases

Each minor/patch release within a major version adds entries to the **same** channel pair. A new channel pair is only created for a new major version.

```text
stable-1.0
  ├── hyperfleet-operator.v1.0.0
  ├── hyperfleet-operator.v1.0.1  (replaces v1.0.0)
  ├── hyperfleet-operator.v1.1.0  (replaces v1.0.1)
  └── hyperfleet-operator.v1.2.0  (replaces v1.1.0)

stable-2.0  (created only when major version 2 ships)
  ├── hyperfleet-operator.v2.0.0
  └── hyperfleet-operator.v2.0.1  (replaces v2.0.0)
```

### Upgrade Paths

Within a channel, OLM uses the `replaces` field to build the upgrade graph. Each
new entry declares which version it replaces:

```yaml
schema: olm.channel
name: stable-1.0
package: hyperfleet-operator
entries:
  - name: hyperfleet-operator.v1.0.0
  - name: hyperfleet-operator.v1.0.1
    replaces: hyperfleet-operator.v1.0.0
  - name: hyperfleet-operator.v1.1.0
    replaces: hyperfleet-operator.v1.0.1
```

Clusters on `v1.0.0` will upgrade through `v1.0.1` → `v1.1.0` automatically
(or directly to `v1.1.0` if `skips` is used instead of `replaces`).

**Cross-major upgrades** (e.g., `stable-1.0` → `stable-2.0`) require the cluster admin to change their Subscription's channel. This is intentional — major version upgrades may include breaking changes and should not happen automatically.

---
## Bundles

### Bundle Image Tagging

Each bundle build is triggered by a git tag on the operator's release branch (`bundle-vX.Y.Z-rcN` for release candidates, `bundle-vX.Y.Z` for official releases). The pipeline builds the bundle image and sets the CSV version to the tag value with the `bundle-v` prefix stripped (e.g., `bundle-v1.0.0-rc1` → `1.0.0-rc1`).

Bundle images are immutable — each version produces a distinct image:

```text
quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-bundle:v1.0.0-rc1
quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-bundle:v1.0.0-rc2
quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-bundle:v1.0.0
```

The CSV version inside the bundle image must match the catalog entry name (e.g., `hyperfleet-operator.v1.0.0`). Because this version is baked into the image at build time, bundles cannot be retagged or promoted — a new version requires a new build.

### Bundle Build Flow

```text
Release (release branch):
  push bundle-vX.Y.Z[-rcN] git tag → bundle-tag pipeline → bundle image :vX.Y.Z[-rcN]
```

### Bundle Annotations

With FBC, the **catalog** is the authority on channel membership, not the bundle.
The bundle's channel annotations in `annotations.yaml` are metadata for tooling
(`operator-sdk bundle validate`, `opm render`) but OLM does not read them to decide
channel membership.

Set them for documentation and validation purposes using values that work for both
RC and official builds:

These will be set in the `bundle.Dockerfile` based on the `BUILD_ARGS`

```yaml
annotations:
  operators.operatorframework.io.bundle.channels.v1: candidate-X.Y,stable-X.Y
  operators.operatorframework.io.bundle.channel.default.v1: stable-X.Y
```

These do not need to change between RC and official builds. The catalog controls which channel each version actually lands in.

---

## Catalogs

### Catalog Image Tagging

The catalog image uses a mutable tag per major version (e.g., `quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-catalog:v1`).

Each catalog build is triggered by a unique git tag (`catalog-vX.Y.Z-rcN`, `catalog-vX.Y.Z`, etc.) but pushes to the same `:vX` image tag. The digest behind `:vX` updates with each build, and OLM's catalog polling picks up the new content automatically.

When a new major version ships, a new tag is created (e.g., `:v2`).

### Catalog Build Flow

```text
Release (release branch):
  update release-base-template.yaml + release-template.yaml
  push catalog-vX.Y.Z git tag → catalog-tag pipeline → catalog image :vX
```

### Catalog Versioning

The catalog build currently has:

- **One push pipeline** (`hyperfleet-operator-catalog-push.yaml`) that triggers on
  main merges when `catalog/` files change. It passes `TEMPLATEFILE=konflux-template.yaml`.
- **No tag pipeline** — there is no way to build the catalog for release branches.
- **Three template files** that the `catalog.Dockerfile` concatenates with `base-template.yaml`:
  - `dev-template.yaml` — local dev, uses `OVERRIDE_BUNDLE_IMAGE` placeholder
  - `konflux-template.yaml` — Konflux nightly builds, uses the bundle digest
    (auto-updated by build-nudges)
  - `base-template.yaml` — defines the package and a single `stable` channel with
    a hardcoded `v0.0.1` entry

The Dockerfile takes a `TEMPLATEFILE` build arg, concatenates it with
`base-template.yaml`, and runs `opm alpha render-template basic` to produce the
final FBC catalog.

#### Problem

This structure does not support release catalogs because:

1. `base-template.yaml` hardcodes a single unversioned `stable` channel — release
   catalogs need versioned channels (`stable-1.0`, `candidate-1.0`)
2. There is no tag pipeline to build the catalog from a release branch
3. The nightly catalog and release catalog need different channel structures but
   share the same base template
4. `konflux-template.yaml` is updated by build-nudges on main — release branches
   need a separate mechanism to pin bundle digests

**These gaps are addressed in the [Required Changes](#required-changes) section below.**

## Required Changes

### `hyperfleet-operator` Repository

#### 1. Create a bundle tag pipeline

Add `hyperfleet-operator-bundle-tag.yaml` to `.tekton/`. This pipeline triggers
on tag push from release branches and passes the release templates:

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

With BUILD_ARGS set:

```yaml
- name: BUILD_ARGS
  value:
    - $(params.build-args[*])
    - KUSTOMIZE_VARIANT=config/manifests/prod
    - BUNDLE_VERSION=$(params.bundle-version)
    - APP_VERSION=$(params.bundle-version)
    - CHANNELS=candidate-$(tasks.parse-version.results.major-minor),stable-$(tasks.parse-version.results.major-minor)
    - DEFAULT_CHANNEL=stable-$(tasks.parse-version.results.major-minor)
    - VALIDATE_RELATED_IMAGES=true
```

#### 2. Create a catalog tag pipeline

Add `hyperfleet-operator-catalog-tag.yaml` to `.tekton/`. This pipeline triggers
on tag push from release branches and passes the release templates:

```yaml
annotations:
  build.appstudio.openshift.io/repo: https://github.com/openshift-hyperfleet/hyperfleet-operator?rev={{revision}}
  build.appstudio.redhat.com/commit_sha: "{{revision}}"
  build.appstudio.redhat.com/target_branch: "{{target_branch}}"
  pipelinesascode.tekton.dev/cancel-in-progress: "false"
  # Trigger on catalog release tags (e.g., catalog-v1.0.0-rc1 or catalog-v1.0.0)
  pipelinesascode.tekton.dev/on-cel-expression: |
    event == "push"
    && target_branch.matches("^refs/tags/catalog-v[0-9]+\\.[0-9]+\\.[0-9]+(-rc[0-9]+)?$")
```

With BUILD_ARGS set:

```yaml
- name: BUILD_ARGS
  value:
    - $(params.build-args[*])
    - BASEFILE=release-base-template.yaml
    - TEMPLATEFILE=release-template.yaml
```

#### 3. Create a release base template

Add `catalog/release-base-template.yaml` for release branches. This file defines
versioned channels and is updated on the release branch as new bundle versions
are released:

```yaml
---
schema: olm.template.basic
entries:
  - schema: olm.package
    name: hyperfleet-operator
    defaultChannel: stable-1.0
    description: "HyperFleet Operator"
  - schema: olm.channel
    name: candidate-1.0
    package: hyperfleet-operator
    entries:
      - name: hyperfleet-operator.v1.0.0-rc1
  - schema: olm.channel
    name: stable-1.0
    package: hyperfleet-operator
    entries:
      - name: hyperfleet-operator.v1.0.0
```

As new versions are released, entries are added to the appropriate channel in this
file on the release branch. The existing `base-template.yaml` stays unchanged for nightly builds on main —
it continues to use the unversioned `stable` channel with `v0.0.1`.

#### 4. Create a release bundle template

Add `catalog/release-template.yaml` for release branches. This file lists the
bundle image digests for all versions referenced in the release base template:

```yaml
# Updated when new bundle versions are released
- schema: olm.bundle
  image: quay.io/redhat-services-prod/.../hyperfleet-operator-bundle@sha256:abc123
- schema: olm.bundle
  image: quay.io/redhat-services-prod/.../hyperfleet-operator-bundle@sha256:def456
```

Each bundle version referenced in the channel entries needs a corresponding
`olm.bundle` entry pointing to its image digest.

#### 5. Update the catalog Dockerfile

The Dockerfile currently hardcodes `base-template.yaml`. Update it to accept
the base template as a build arg:

```dockerfile
ARG BASEFILE=base-template.yaml
ARG TEMPLATEFILE
COPY catalog/${BASEFILE} ./base-template.yaml
COPY catalog/${TEMPLATEFILE} ./
RUN cat base-template.yaml ${TEMPLATEFILE} > ./template.yaml
```

This keeps the default behavior unchanged for nightly builds (uses
`base-template.yaml`) while allowing release builds to pass
`BASEFILE=release-base-template.yaml`.

#### 6. Updates to `renovate.json`

Update `renovate.json` so that on release branches, Renovate groups all HyperFleet component image updates (API, Sentinel, Adapter, Applier, Operator) into a single PR. Once the component release branches are cut and their images are built, Renovate will open this grouped PR on the operator's release branch automatically.

```json
{
  "extends": ["github>openshift-hyperfleet/renovate-config"],
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "baseBranchPatterns": ["main", "/^release\\/.*/"],
  "packageRules": [
    {
      "matchBaseBranches": ["main"],
      "matchPackagePatterns": ["^quay\\.io/hyperfleet/.*$"],
      "ignoreVersions": [
        "/^v\\d+\\.\\d+\\.\\d+.*$/",
        "/^[0-9]+\\.[0-9]+\\.[0-9]+.*$/"
      ]
    },
    {
      "matchBaseBranches": ["/^release-\\d+\\.\\d+$/"],
      "matchPackagePatterns": ["^quay\\.io/hyperfleet/.*$"],
      "groupName": "HyperFleet Release Components",
      "commitMessageTopic": "HyperFleet component images",
      "automerge": false
    }
  ]
}
```

### `konflux-release-data` Repository

#### 1. Create an RPA for the catalog image

Add a ReleasePlanAdmission in `konflux-release-data` for the catalog component
so that Konflux can release catalog images to the production Quay registry.

## Open Questions

1. **Bundle digest propagation to the release template:** After the bundle tag pipeline builds a new bundle image ([Step 3](#step-3-tag-the-bundle-rc)), its digest needs to be added to [`release-template.yaml`](#4-create-a-release-bundle-template) before the catalog can be updated ([Step 4](#step-4-update-the-catalog)). The mechanism for this needs to be defined — options include a Konflux build-nudge that automatically updates the digest on the release branch, a Renovate rule that detects new bundle images, or a manual step where the developer adds the digest after the bundle build completes.
