---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-11-01
---

# SPIKE: OLM Bundle and Catalog Release Process

**Ticket:** [HYPERFLEET-1617](https://issues.redhat.com/browse/HYPERFLEET-1617)

## Context

The current release flow for the hyperfleet components involves helm charts and
container images. Look at [hyperfleet-release-process.md](./hyperfleet-release-process.md) for more information. The current gap is the introduction of the hyperfleet-operator. The hyperfleet-operator will become the entrypoint for all hyperfleet components, replacing the current helm based installation.

Since the operator will be installed and managed via the Operator Lifecycle Manager (OLM), the release process must now generate OLM-compliant bundles and file-based catalogs (FBC).
This needs to work in conjunction with the current process of cutting each
branch at the release version and producing a component image. This spike
addresses the question of how we will version and release the operator bundle
and catalog.

---

## Channels

See [Channels](spike-olm-upgrade-path.md#channels) for more information regarding channels.

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

The CSV version inside the bundle image must match a catalog entry name (e.g.,
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
both RC and official builds. The catalog controls which channel each version actually lands in. The specific channels will be decided here in [Versioning Options](./spike-olm-upgrade-path.md#versioning-options-for-hyperfleet-operator).

These will be set in the `bundle.Dockerfile` based on the `BUILD_ARGS`.

```yaml
annotations:
  operators.operatorframework.io.bundle.channels.v1: stable-vX
  operators.operatorframework.io.bundle.channel.default.v1: stable-vX
```

---

## Catalogs

The old `hyperfleet-operator-catalog` image and its push pipeline
(`hyperfleet-operator-catalog-push.yaml`) are deprecated. As part of [HYPERFLEET-1770](https://redhat.atlassian.net/browse/HYPERFLEET-1770), we are creating a `hyperfleet-fbc` Application and Component for the operator File-Based-Catalog (FBC).

| Pipeline                           | Triggers on                     | Purpose                                    |
| ---------------------------------- | ------------------------------- | ------------------------------------------ |
| `hyperfleet-operator-fbc-tag.yaml` | `catalog-vX.Y.Z[-rcN]` git tags | Release catalog builds from tagged commits |

Production CatalogSources reference `hyperfleet-operator-fbc` (see the
[upgrade-path spike](spike-olm-upgrade-path.md)).

**Decision:** No on-push catalog pipeline initially. The catalog is built only from git tags.
Template changes on `main` are validated by a render-only CI check (`opm alpha render-template` in a test job — no image pushed), which catches YAML errors, bad upgrade graphs, and missing bundle references. Merge-time install tests do not use a catalog; they install the merge's bundle image directly with `operator-sdk run bundle`.

**Open question — add an on-push pipeline?** An on-push fbc build that pushes only to
`redhat-user-workloads` is safe by construction (build credentials cannot write to
`redhat-services-prod`, and the fbc ReleasePlan has `auto-release: "false"`). Under the
pinned-digest design such an image would contain only already-released bundles, so its sole
value would be testing catalog _behavior_ (channel resolution, upgrade graph) against a real
OLM install without cutting a tag. Revisit if that workflow materializes.

### Catalog Image Tagging

The catalog image exists in **two registries**, with different write rules:

| Registry                                                                             | Image                                        | Written by                                                                         | Content                             |
| ------------------------------------------------------------------------------------ | -------------------------------------------- | ---------------------------------------------------------------------------------- | ----------------------------------- |
| `quay.io/redhat-user-workloads/hyperfleet-tenant/hyperfleet/hyperfleet-operator-fbc` | version tags (e.g. `:v1.0.1`, `:v1.0.1-rc1`) | `fbc-tag` pipeline directly (builds always land here first)                        | All tag builds — RCs **and** finals |
| `quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-fbc`  | `:latest` + version tags (e.g. `v1.0.1`)     | RPA release pipeline only (`rh-push-to-external-registry`, via Snapshot + Release) | **Final releases only**             |

Key properties:

- **Prod `:latest` is tag-built and final-only.** It has exactly one writer — the
  RPA release pipeline — and only `catalog-vX.Y.Z` tags (no `-rcN` suffix) create
  a Release.
- **RCs never enter the prod registry.** The tag pipeline matches both
  `catalog-vX.Y.Z-rcN` and `catalog-vX.Y.Z`, but the Release-creation step is
  conditional: RC tags build to user-workloads and stop there. Prow RC tests
  point their CatalogSource at the user-workloads image (tagged with the RC
  version, e.g. `:v1.0.1-rc1`) — see the [upgrade-path spike](spike-olm-upgrade-path.md).

**Aggregate catalog strategy:** Each release uses
`catalog/release-template.yaml`, which contains **all** major version channels
(v1, v2, etc.) in a single FBC template. The `:latest` image always contains all
supported major versions. This allows:

- v1 clusters continue receiving v1 updates after v2 ships
- Cross-major upgrades via Subscription channel switch

See [Create a catalog tag pipeline](#2-create-a-catalog-tag-pipeline) for the pipeline configuration. Validation gates should verify that all previously published major versions remain present after each catalog rebuild.

### Catalog Build Flow

The catalog is a release artifact — built only from git tags, never from main merges:

```text
RC (validation):
  push catalog-vX.Y.Z-rcN git tag
    → fbc-tag pipeline → image in redhat-user-workloads
    → no Release created; consumed by Prow tests only

Final (release):
  push catalog-vX.Y.Z git tag
    → fbc-tag pipeline → image in redhat-user-workloads (Snapshot)
    → Release CR → RPA match → EC policy → rh-push-to-external-registry
    → copied to redhat-services-prod, tagged v1.0.1 + latest
```

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
3. Add `v1.0.0-rc1` to the catalog template and build the catalog.
   References: [Catalogs](#catalogs) and [Channels](#channels)
4. If broken: apply fix, build `v1.0.0-rc2`, and iterate.
5. Once the last RC validates cleanly: tag and build the `v1.0.0` official
   release bundle, and add it to the catalog template.

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
bundle image. Once that's updated, builds the bundle image. Current
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
`baseBranchPatterns`. Configure `renovate.json` to scan release branches for outdated
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

The catalog defines the OLM upgrade graph — which bundle versions exist, which
channels they belong to, and how versions upgrade between them. The upgrade
graph strategy (single aggregate `release-template.yaml` on `main`, channel
structure, RC validation flow, and the Prow testing steps) is covered in
[OLM Upgrade Path](spike-olm-upgrade-path.md).

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

On the `main` branch, add the RC bundle to the `catalog/release-template.yaml`. Push this change to main and tag the commit `catalog-vX.Y.Z-rcN`, which will trigger the catalog pipeline.

**Note:** Information regarding how to update the release-template.yaml can be found in [RC verification](./spike-olm-upgrade-path.md#rc-verification)

### Step 5: Validate in Preprod

Cut `release-X.Y` branch in `hyperfleet-e2e` repo.

This step is a prerequisite for the release gate. See [Steps for upgrade testing](spike-olm-upgrade-path.md#steps-for-upgrade-testing) for the proposed installation/testing flow. RC E2E tests should validate operator install of all components, end-to-end functionality and seamlessly upgrade to the newest RC.

### Step 6: Handle failures (if any)

**If the issue is in a component image** (e.g., Operator, Adapter, API,
Sentinel):

1. Fix the component on main, cherry-pick to the release branch
2. Tag a new component version (e.g., `v1.0.1`)
3. Update the new digest on the operator's `release-X.Y` branch (e.g.,
   `release-1.0`)
4. Tag `bundle-vX.Y.Z-rc2` → pipeline builds new bundle (e.g.,
   `bundle-v1.0.0-rc2` → CSV `name: hyperfleet-operator.v1.0.0-rc2`,
   `version: 1.0.0-rc2`)

**If the issue is in the bundle itself** (RBAC, CRDs, CSV metadata):

1. Make the required change on main and cherry-pick change to `release-X.Y`
2. Tag `bundle-vX.Y.Z-rc2` → pipeline builds new bundle (e.g.,
   `bundle-v1.0.0-rc2` → CSV `name: hyperfleet-operator.v1.0.0-rc2`,
   `version: 1.0.0-rc2`)

In both cases, update the `catalog/release-template.yaml` on the `main` branch. Tag the change and rebuild the catalog image and revalidate.

### Step 7: Promote to stable channel

Once everything is validated cleanly, tag the release-X.Y branch with
`bundle-vX.Y.Z`. This will trigger the official bundle build. Then update
`catalog/release-template.yaml` on `main` to remove the rc and add the final release and its
`olm.bundle` digest, following the channel structure and upgrade graph defined
in [OLM Upgrade Path](spike-olm-upgrade-path.md#final-release-templateyaml).

Tag the catalog change as `catalog-vX.Y.Z` (no `-rcN` suffix) to build and
release the official catalog. This will push the catalog image to `quay.io/redhat-user-workloads/hyperfleet-tenant/hyperfleet/hyperfleet-operator-fbc` to complete the catalog release and push image to `quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-fbc` , trigger it manually from the Konflux UI.

---

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

2. Set `BUILD_ARGS`

   ```yaml
   - name: BUILD_ARGS
     value:
       - $(params.build-args[*])
       - KUSTOMIZE_VARIANT=config/manifests/prod
       - BUNDLE_VERSION=$(tasks.parse-version.results.VERSION)
       - APP_VERSION=$(tasks.parse-version.results.VERSION)
       - CHANNELS=stable-$(tasks.parse-version.results.MAJOR)
       - DEFAULT_CHANNEL=stable-$(tasks.parse-version.results.MAJOR)
       - VALIDATE_RELATED_IMAGES=true
   ```

3. `parse-version` task to extract values from git-tag

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

Add `hyperfleet-operator-fbc-tag.yaml` to `.tekton/`. This pipeline triggers
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

2. `opm-run-command` task `OPM_ARGS`

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

### `konflux-release-data` Repository

#### Pending: `hyperfleet-fbc` Application and Component (PR open)

As part of [HYPERFLEET-1770](https://redhat.atlassian.net/browse/HYPERFLEET-1770), add a new Application, Component and ImageRepository to `tenants-config/cluster/kflux-prd-rh02/tenants/hyperfleet-tenant/applications/hyperfleet-fbc/`.

#### 1. Add a ReleasePlan for `hyperfleet-fbc` — with auto-release **disabled**

[HYPERFLEET-1773](https://redhat.atlassian.net/browse/HYPERFLEET-1773)

Add a ReleasePlan in `../tenants-config/cluster/kflux-prd-rh02/tenants/hyperfleet-tenant/release-plan.yaml` , following the
existing `hyperfleet` and `hyperfleet-charts` plans:

```yaml
---
apiVersion: appstudio.redhat.com/v1alpha1
kind: ReleasePlan
metadata:
  labels:
    release.appstudio.openshift.io/auto-release: "false" # critical — see below
    release.appstudio.openshift.io/standing-attribution: "true"
    release.appstudio.openshift.io/releasePlanAdmission: hyperfleet-fbc
  name: hyperfleet-fbc-releaseplan
  namespace: hyperfleet-tenant
spec:
  application: hyperfleet-fbc
  target: rhtap-releng-tenant
```

**Why `auto-release: "false"` matters:** the existing `hyperfleet-releaseplan` has
`auto-release: "true"`, which makes the release service create a Release for **every**
Snapshot. We want the catalog's prod registry (`redhat-services-prod`) to be updated — including its `:latest` tag — **only for final production images**, never for RCs or main-merge builds. The fbc ReleasePlan must therefore not auto-release; Releases are created only by the tag pipeline for final tags (`catalog-vX.Y.Z`, no `-rcN`). RC builds then live and die in
`redhat-user-workloads` and never reach `redhat-services-prod`
(see [Catalog Image Tagging](#catalog-image-tagging)).

#### 2. Create an RPA for the catalog image

[HYPERFLEET-1773](https://redhat.atlassian.net/browse/HYPERFLEET-1773)

Add a ReleasePlanAdmission under
`config/kflux-prd-rh02.0fk9.p1/service/ReleasePlanAdmission/hyperfleet/` as a new file named `hyperfleet-fbc.yaml` so that we can release catalog images to the production Quay registry:

```yaml
---
apiVersion: appstudio.redhat.com/v1alpha1
kind: ReleasePlanAdmission
metadata:
  labels:
    pp.engineering.redhat.com/business-unit: other
    release.appstudio.openshift.io/block-releases: "false"
  name: hyperfleet-fbc
  namespace: rhtap-releng-tenant
spec:
  applications:
    - hyperfleet-fbc
  origin: hyperfleet-tenant
  policy: fbc-standard # confirm with releng — see note below
  data:
    releaseNotes:
      product_name: HyperFleet
      product_version: "1.0"
    mapping:
      registrySecret: konflux-release-service-access-management-token
      defaults:
        tags:
          - "{{ labels.version }}"
          - "{{ labels.version }}-{{ timestamp }}"
          - "{{ git_sha }}"
          - latest
        pushSourceContainer: false
        public: true
      components:
        - name: hyperfleet-operator-fbc
          repositories:
            - url: "quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-fbc"
    slack:
      slack-notification-secret: hyperfleet-slack-webhook-notification-secret
      slack-webhook-notification-secret-keyname: webhook-url
    intention: production
  pipeline:
    pipelineRef:
      resolver: git
      params:
        - name: url
          value: "https://github.com/konflux-ci/release-service-catalog.git"
        - name: revision
          value: production
        - name: pathInRepo
          value: "pipelines/managed/rh-push-to-external-registry/rh-push-to-external-registry.yaml"
    serviceAccountName: release-app-interface-prod
    timeouts:
      pipeline: "4h0m0s"
      tasks: "4h0m0s"
```

**Note:** Confirm this above template would work
