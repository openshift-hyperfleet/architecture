---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-11-01
---

# SPIKE: OLM Bundle and Catalog Release Process

**Ticket:** [HYPERFLEET-1617](https://issues.redhat.com/browse/HYPERFLEET-1617)

## Context

The current release flow for the hyperfleet components involves helm charts and
container images. Look at [hyperfleet-release-process.md](./hyperfleet-release-process.md) for more information. The current gap is the introduction of the hyperfleet-operator.
The hyperfleet-operator will become the entrypoint for all hyperfleet components, replacing the current helm based installation.

Since the operator will be installed and managed via the Operator Lifecycle Manager (OLM), the release process must now generate OLM-compliant bundles and file-based catalogs (FBC).
This needs to work in conjunction with the current process of cutting each branch at the release version and producing a component image. This spike addresses the question of how we will version and release the operator bundle and catalog. As well as showing how the upgrade path from one operator to the next will be defined.

---

## Bundles

A **bundle** is a container image that packages the metadata and manifests needed
to deploy and manage a specific version of an operator and its operands on
Kubernetes.

### Bundle Image Tagging

Each release bundle build is triggered by a git tag on the operator's release branch
(`bundle-vX.Y.Z-rcN` for release candidates, `bundle-vX.Y.Z` for official
releases). The pipeline builds the bundle image and sets the CSV version to the
tag value with the `bundle-v` prefix stripped (e.g., `bundle-v1.0.0-rc1` ->
`1.0.0-rc1`).

Bundle images are immutable — each version produces a distinct image:

```text
quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-bundle:1.0.0-rc1
quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-bundle:1.0.0-rc2
quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-bundle:1.0.0
```

The CSV version inside the bundle image must match a catalog entry name (e.g.,
`hyperfleet-operator.v1.0.0`). Because this version is baked into the bundle image at
build time, bundles cannot be retagged or promoted — a new version requires a
new build.

### Bundle Build Flow

```text
Release (release branch):
  push bundle-vX.Y.Z[-rcN] git tag -> bundle-tag pipeline -> copy over image to quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-bundle:X.Y.Z[-rcN]
```

### Bundle Annotations

With FBC, the **catalog** is the authority on channel membership, not the
bundle. The bundle's channel annotations in `annotations.yaml` are metadata for
tooling (`operator-sdk bundle validate`, `opm render`) but OLM does not read
them to decide channel membership.

Set them for documentation and validation purposes. The catalog will control which channel each version actually lands in.
These will be set in the `bundle.Dockerfile` based on the `BUILD_ARGS`.

```yaml
annotations:
  operators.operatorframework.io.bundle.channels.v1: stable-vX # stable channel major version X
  operators.operatorframework.io.bundle.channel.default.v1: stable-vX
```

### Bundle Versioning

When managing an operator using OLM and File-Based Catalogs (FBC), releasing
across multiple environments (staging and prod) requires a clear strategy for
how the bundle artifact moves through the pipeline.

#### Decision

**Release Candidate (RC) Workflow:** Build RC-versioned bundles during validation, iterate if issues arise, and build the official release bundle once the final RC is validated. The official release bundle references the exact same component image digests and manifests as the validated RC—the only delta is the version string in the CSV.

**Workflow:** Example for release `v1.0.0` (branch: `release-1.0`)

1. On the release branch, developer tags commit as `bundle-v1.0.0-rc1`, which triggers on-tag bundle pipeline.
   Pushes the rc image as `quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-bundle:1.0.0-rc1`
2. On the main branch, update catalog/release-template based on [Catalogs](#catalogs---fbc) and [Channels](#channels)
3. Validate catalog.
4. If failures: apply fix to the release branch, tag new commit as `bundle-v1.0.0-rc2`, which triggers on-tag bundle pipeline, second rc image will be `quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-bundle:1.0.0-rc2`
5. On the main branch, update again and reiterate step 2 & 3.
6. Once the last RC validates cleanly: on the release branch, tag commit as `bundle-v1.0.0` which triggers on-tag pipeline and pushes image to `quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-bundle:1.0.0`. Update `release-template.yaml` and remove RC entries and add `hyperfleet-operator.v1.0.0` entry and tag new commit as specified in [Catalogs](#catalogs---fbc) and [Channels](#channels).

**Pros:**

- **Clean version history:** No gaps or phantom patch versions in the registry.
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

#### Alternative Considered

**Artifact Promotion (Immutability Model):** Build the operator bundle image **once** and rely on OLM catalog channels to
control when that specific container digest is rolled out to different environments.

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

### Updating dependency on release branch

The release branch in the operator repo will be used to build the operator image and the operator-bundle image. The bundle requires the `config/manifests/prod/kustomization.yaml` to be updated with the release images for `hyperfleet-api`,`hyperfleet-sentinel`, `hyperfleet-operator`, `hyperfleet-adapter`. Currently the build nudge only works on the main branch, so there are no automatic nudges/updates to the release branches.

#### Decision

**Manual Updates to `config/manifests/prod/kustomization.yaml`:**  Keep build nudges as is and manually update the release digest on the release branch when building for the rc and final bundle.
Future work can be scoped to automating this process.

**Pros:**

- No additional components needed
- Simple, no infrastructure changes

**Cons:**

- Error-prone — manual digest copy/paste. Covered with bundle validation.
- Slower release flow

#### Alternative Considered

**Use MintMaker (scheduled Renovate):** Unlike component nudges, MintMaker reads the repo's `renovate.json` and supports `baseBranchPatterns`. Provides the ability to update dependency on release branches. Configure `renovate.json` to scan release branches for outdated image digests and open grouped PRs.

**Pros:**

- No additional components needed
- No configmap changes
- No manual digest copy/paste

**Cons:**

- Scan-based, not event-driven — delay between image build and PR creation (minutes to hours depending on scan interval)
- Introduces unpredictable wait times in the middle of a release flow
- Does not chain — each step (operator -> bundle -> catalog) waits for the next scan cycle
- Release flow becomes dependent on renovate

---

## Catalogs - FBC

A **File-Based Catalog (FBC)** is OLM's declarative, plain-text format for expressing an operator catalog. It is a set of YAML files (distributed as a container image) that describe the catalog's contents using a small number of schemas: `olm.package` (the operator package and its default channel), `olm.channel` (channel membership and the upgrade graph via `replaces`), and `olm.bundle` (a pointer to a bundle image by digest).

For HyperFleet, `catalog/release-template.yaml` is the FBC: the single source of truth for which bundle versions exist, what channel they belong to, and the upgrade edges between them. The `hyperfleet-operator-fbc` image is that YAML packaged for OLM to consume via a `CatalogSource`.

### Catalog Builds

The old `hyperfleet-operator-catalog` image and its push pipeline
(`hyperfleet-operator-catalog-push.yaml`) are deprecated. As part of [HYPERFLEET-1770](https://redhat.atlassian.net/browse/HYPERFLEET-1770), we are creating a `hyperfleet-fbc` Application and Component for the operator File-Based-Catalog (FBC).

| Pipeline                           | Triggers on                     | Purpose                                    |
| ---------------------------------- | ------------------------------- | ------------------------------------------ |
| `hyperfleet-operator-fbc-tag.yaml` | `catalog-vX.Y.Z[-rcN]` git tags | Release catalog builds from tagged commits |

Catalogs will be built and published to `quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-fbc` on every tag build. The tag determines the version. The tagging syntax will be git tag: `catalog-vX.Y.Z[-rcN]` --> image tag: `X.Y.Z[-rcN]`

| Git tag              | Image                                                                                          |
| -------------------- | ---------------------------------------------------------------------------------------------- |
| `catalog-v1.0.0-rc1` | `quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-fbc:1.0.0-rc1` |
| `catalog-v1.0.0`     | `quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-fbc:1.0.0`     |

One caveat is the latest tag, which will only get updated when final releases are built (e.g., `catalog-v1.0.0`). This is a discrepancy from the component and bundle images, that update the `latest` tag on every update in `redhat-services-prod`.

Only once we tag the `catalog-vX.Y.Z` and trigger the final build after RC verification, the `latest` tag updates. This is to ensure that the latest tag never points to a non-verified/RC catalog image.

### RC and Final release Flow

```text
RC (staging):
  push catalog-vX.Y.Z-rcN git tag
    -> fbc-tag pipeline -> image in redhat-user-workloads -> release plan auto releases -> copied to redhat-services-prod, tagged X.Y.Z-rcN

Final (release):
  push catalog-vX.Y.Z git tag
    -> fbc-tag pipeline -> image in redhat-user-workloads -> release plan auto releases -> copied to redhat-services-prod, tagged X.Y.Z + latest
```

#### Release template

Currently the catalog pipeline uses `konflux-template.yaml` to build the catalog image. This is deprecated and we will create a new `release-template.yaml` that will define all channels and upgrade path within the FBC. See [Channels](#channels) below for more details.

---

## Channels

An OLM **channel** is a named stream of bundle versions within a package's catalog (e.g. `stable-v1`). A `Subscription` pins a cluster to one channel, and OLM only ever offers upgrades along the upgrade graph defined inside that channel — each entry's `replaces` field points at the version it upgrades from. Channels therefore determine both update cadence (which versions a subscriber sees) and upgrade path (the edges between them); a cluster stays on its channel until the user explicitly switches.

### Channel Versioning

OLM channels control which bundle versions are available to a subscriber.
Channel naming and lifecycle decisions determine the upgrade graph,
how release-candidate (RC) and production bundles are separated, and how
multiple major versions coexist in the same catalog.

#### Versioning Options for HyperFleet Operator

Currently `konflux-template.yaml` is used, but we want to replace it with
`release-template.yaml`, which will be used to create the RC and final catalog. We have to decide what the best channel strategy is.

##### Decision

**Single channel with RC tag:** One `stable-vX` channel per major version.

- The test catalog contains both RCs and finals in one linear graph:
  `hyperfleet-operator.v1.0.1-rc1` replaces `hyperfleet-operator.v1.0.0`
- The official catalog receives only finals:
  `hyperfleet-operator.v1.0.1` replaces `hyperfleet-operator.v1.0.0`. With no mention of RC entry.
- The RC entry is only ever added to `release-template.yaml` for RC testing, built into a test-only catalog image (e.g. tagged `:1.0.1-rc1`), and consumed only by test/Prow `CatalogSources`.
- Before the official catalog is built, the RC entry is removed from `release-template.yaml` and the final release's `replaces` is repointed straight at the prior official release (e.g. `hyperfleet-operator.v1.0.1 replaces hyperfleet-operator.v1.0.0`, removing the RC entry entirely).
- The official catalog image is then built from that RC-free template, so the official image only ever contains the validated bundles.
- Tradeoff: this relies on a manual template-editing step — pruning the RC and repointing `replaces` before the official release.

**Major version coexistence:** `release-template.yaml` carries every major version that is still supported — when `stable-v2` ships, all `stable-v1` bundles and channels remain in the template alongside the `stable-v2` entries, and `defaultChannel` moves to `stable-v2` so new installs land on the current major by default. Existing `stable-v1` clusters are never upgraded across majors automatically: moving from `stable-v1` to `stable-v2` is an explicit decision by the user, made by switching the OLM `Subscription` (OLM classic) or `ClusterExtension` (OLM v1).

##### Alternative Considered

**Multi-channel (candidate and stable):** Define both `candidate-vX` and `stable-vX` per major version.

- `candidate-v1` — receives every bundle (RCs and finals, linear upgrade chain):

```yaml
- schema: olm.channel
    name: candidate-v1
    package: hyperfleet-operator
    entries:
      - name: hyperfleet-operator.v1.0.0
      - name: hyperfleet-operator.v1.0.1-rc1
        replaces: hyperfleet-operator.v1.0.0
      - name: hyperfleet-operator.v1.0.1
        replaces: hyperfleet-operator.v1.0.1-rc1
      - name: hyperfleet-operator.v1.0.2-rc1
        replaces: hyperfleet-operator.v1.0.1

- schema: olm.channel
    name: stable-v1
    package: hyperfleet-operator
    entries:
      - name: hyperfleet-operator.v1.0.0
      - name: hyperfleet-operator.v1.0.1
        replaces: hyperfleet-operator.v1.0.0
      - name: hyperfleet-operator.v1.0.2
        replaces: hyperfleet-operator.v1.0.1
```

- RC testers subscribe to `candidate-v1` to exercise the upgrade before it's promoted. Once validated, the final release is added to `stable-v1`.

**Pros:**

- `stable-v1` never contains RC entries, so no template-pruning step is needed at official release time (the manual step the single-channel approach accepts).

**Cons:**

- A channel exists to serve subscribers, and none persist: RC tests are one-off installations whose clusters are destroyed afterward. The candidate channel would have no long-term consumers and would not be consumer-facing, so it adds overhead for little benefit.
- Requires mirroring every production entry into `candidate-vX` indefinitely. The two channels drift by design (candidate carries RCs, stable does not), doubling catalog maintenance and creating a second upgrade graph that must be validated.

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

See [Updating dependency on release branch](#updating-dependency-on-release-branch) for the rationale behind the
manual approach.

### Step 3: Tag the bundle RC

Tag the release branch with `bundle-vX.Y.Z-rcN` and push. Bundle tag pipeline
should build.

**Example:** tag `bundle-v1.0.0-rc1` on the operator's `release-1.0` branch. The
bundle tag pipeline triggers and builds the bundle image. The version in the CSV
is set to `1.0.0-rc1` (tag with `bundle-v` prefix stripped). The bundle image published will be
`quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-bundle:1.0.0-rc1`

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

**Note:** Information regarding how to update the release-template.yaml can be found in [RC verification](#rc-verification)

### Step 5: Validate in Preprod

Cut `release-X.Y` branch in `hyperfleet-e2e` repo.

This step is a prerequisite for the release gate. See [Steps for upgrade testing](#steps-for-upgrade-testing) for the proposed installation/testing flow. RC E2E tests should validate operator install of all components, end-to-end functionality and seamlessly upgrade to the newest RC.

### Step 6: Handle failures (if any)

**If the issue is in a component image** (e.g., Operator, Adapter, API,
Sentinel):

1. Fix the component on main, cherry-pick to the release branch
2. Tag a new component RC version (e.g., `v1.0.0-rc2`), keeping the component
   build traceable to the bundle RC it feeds
3. Update the new digest on the operator's `release-X.Y` branch (e.g.,
   `release-1.0`)
4. Tag `bundle-vX.Y.Z-rc2` -> pipeline builds new bundle (e.g.,
   `bundle-v1.0.0-rc2` -> CSV `name: hyperfleet-operator.v1.0.0-rc2`,
   `version: 1.0.0-rc2` -> `quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-bundle:1.0.0-rc2`)

**If the issue is in the bundle itself** (RBAC, CRDs, CSV metadata):

1. Make the required change on main and cherry-pick change to `release-X.Y`
2. Tag `bundle-vX.Y.Z-rc2` -> pipeline builds new bundle (e.g.,
   `bundle-v1.0.0-rc2` -> CSV `name: hyperfleet-operator.v1.0.0-rc2`,
   `version: 1.0.0-rc2` -> `quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-bundle:1.0.0-rc2`)

In both cases, update the `catalog/release-template.yaml` on the `main` branch. Tag the change and rebuild the catalog image and revalidate.

### Step 7: Promote to stable channel

Once everything is validated cleanly, tag the `release-X.Y` branch with
`bundle-vX.Y.Z`. This will trigger the official bundle build -> `quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-bundle:X.Y.Z`. Then update
`catalog/release-template.yaml` on `main` to remove the rc and add the final release and its
`olm.bundle` digest, following the channel structure and upgrade graph defined
in [Final release-template.yaml](#final-release-templateyaml).

Tag the catalog change as `catalog-vX.Y.Z` (no `-rcN` suffix) to build and
release the official catalog. The final catalog image will be `quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-fbc` with tags `:X.Y.Z` and `:latest`.

---

## Proposed Operator Upgrade Workflow (End-to-End)

Step by step guide for installing and upgrading the hyperfleet operator from `v1.0.0` to `v1.0.1`.

### Setup

1. Cut all release branches (`hyperfleet-api`, `hyperfleet-sentinel`,
   `hyperfleet-operator`, `hyperfleet-adapter`)
2. Update rc images in `config/manifests/prod/kustomization.yaml`.
3. Tag the release branch as `bundle-v1.0.1-rc1` and build the bundle image: `quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-bundle:1.0.1-rc1`
4. Add the `hyperfleet-operator.v1.0.1-rc1` entry to the `release-template.yaml`. Look below for next steps.

### RC verification

**Assumption:** We have already done a v1.0.0 release and we need to test
upgrade path before we promote v1.0.1.

Using the aforementioned single channel structure, this is how the `release-template.yaml` entries will look like during RC verification.

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
      - name: hyperfleet-operator.v1.0.1-rc1
        replaces: hyperfleet-operator.v1.0.0
  - schema: olm.bundle
    image: quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-bundle@sha256:<1.0.0-digest>
  - schema: olm.bundle
    image: quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-bundle@sha256:<1.0.1-rc1-digest>
```

#### Steps for upgrade testing

1. Commit and push the changes to the release-template.yaml on the `main` branch.
2. Tag the commit `catalog-v1.0.1-rc1` and push the tag. This should trigger the catalog pipeline to build and push to `quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-fbc:1.0.1-rc1` but won't update the `latest` tag
3. Verification & Testing
   1. Within Prow, set up a cluster and install OLM
   2. Apply the following resources:

      ```yaml
      ---
      apiVersion: v1
      kind: Namespace
      metadata:
        name: hyperfleet
      ---
      apiVersion: operators.coreos.com/v1alpha2
      kind: OperatorGroup
      metadata:
        name: hyperfleet-operator-og
        namespace: hyperfleet
      ---
      apiVersion: operators.coreos.com/v1alpha1
      kind: CatalogSource
      metadata:
        name: hyperfleet-operator-fbc
        namespace: olm
      spec:
        sourceType: grpc
        displayName: HyperFleet Operator Catalog
        image: quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-fbc:1.0.1-rc1
        publisher: Red Hat
      ---
      apiVersion: operators.coreos.com/v1alpha1
      kind: Subscription
      metadata:
        name: sub-hyperfleet-operator
        namespace: hyperfleet
      spec:
        channel: stable-v1
        name: hyperfleet-operator
        source: hyperfleet-operator-fbc
        sourceNamespace: olm
        installPlanApproval: Manual
        startingCSV: hyperfleet-operator.v1.0.0 # start at v1.0.0
      ```

   3. Approve `hyperfleet-operator.v1.0.0` InstallPlan - this will install the 1.0.0 version.

      ```bash
      kubectl get installplans.operators.coreos.com -A

      NAMESPACE    NAME            CSV                              APPROVAL   APPROVED
      hyperfleet   install-gbnnh   hyperfleet-operator.v1.0.0       Manual     false

      export install_plan_v1_0_0=$(kubectl get installplans -n hyperfleet -o json | jq -r '.items[] | select(.spec.clusterServiceVersionNames | index("hyperfleet-operator.v1.0.0")) | .metadata.name')

      kubectl patch installplan $install_plan_v1_0_0 -n hyperfleet --type merge -p '{"spec":{"approved":true}}'
      ```

   4. Verify that `hyperfleet-operator.v1.0.0` is up and running
   5. Upgrade to rc1 by approving the `hyperfleet-operator.v1.0.1-rc1` InstallPlan - this will install the 1.0.1-rc1 version.

      ```bash
      kubectl get installplans.operators.coreos.com -A

      NAMESPACE    NAME            CSV                              APPROVAL   APPROVED
      hyperfleet   install-gbnnh   hyperfleet-operator.v1.0.0       Manual     true
      hyperfleet   install-tqxds   hyperfleet-operator.v1.0.1-rc1   Manual     false

      export install_plan_v1_0_1_rc1=$(kubectl get installplans -n hyperfleet -o json | jq -r '.items[] | select(.spec.clusterServiceVersionNames | index("hyperfleet-operator.v1.0.1-rc1")) | .metadata.name')

      kubectl patch installplan $install_plan_v1_0_1_rc1 -n hyperfleet --type merge -p '{"spec":{"approved":true}}'
      ```

   6. Verify that upgrade was successful.
   7. Continue with E2E RC testing.

### Final release-template.yaml

Once RC verification has been completed and we decide to promote version `v1.0.1`.

1. Update the `release-template.yaml` on the main branch, it should include all final releases available, and remove the rc entry.

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
         - name: hyperfleet-operator.v1.0.1
           replaces: hyperfleet-operator.v1.0.0
     - schema: olm.bundle
       image: quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-bundle@sha256:<v1.0.0-digest>
     - schema: olm.bundle
       image: quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-bundle@sha256:<v1.0.1-digest>
   ```

1. Tag the commit `catalog-v1.0.1` and push the tag. This should trigger the catalog pipeline, which builds the image in `redhat-user-workloads`; the final ReleasePlan auto-releases it, copying it to `quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-fbc:1.0.1` (plus `:latest`).

---

## Required Changes

### `hyperfleet-operator` Repository

#### 1. Amend the bundle tag pipeline

As part of [HYPERFLEET-1764](https://redhat.atlassian.net/browse/HYPERFLEET-1764) we implemented the bundle tag pipeline. The below modifications need to be made in accordance with this updated doc.

1. Update `BUILD_ARGS` to remove the candidate channel reference based on the decision [Decision to have a single stable channel](#decision-2)

   ```yaml
   - name: BUILD_ARGS
     value:
     - $(params.build-args[*])
     - APP_VERSION=$(tasks.parse-tag.results.VERSION)
     - KUSTOMIZE_VARIANT=config/manifests/prod
     - BUNDLE_VERSION=$(tasks.parse-tag.results.VERSION)
     - CHANNELS=stable-$(tasks.parse-tag.results.MAJOR_VERSION)
     - DEFAULT_CHANNEL=stable-$(tasks.parse-tag.results.MAJOR_VERSION)
     - VALIDATE_RELATED_IMAGES=true
   ```

2. Update the `parse-tag` task to extract just the major and version from the git tag

   ```yaml
   pipelineSpec:
     tasks:
      - name: parse-tag
        params:
        - name: TAG_REF
          value: $(params.target-branch)
        taskSpec:
          params:
          - name: TAG_REF
            type: string
          results:
          - name: VERSION
            description: Semantic version extracted from git tag ref
          - name: MAJOR_VERSION
            description: Major version (e.g. v1) extracted from git tag ref
          steps:
          - name: extract
            image: registry.access.redhat.com/ubi9-minimal:latest
            script: |
              #!/usr/bin/env bash
              VERSION="${TAG_REF#refs/tags/bundle-v}"
              MAJOR_VERSION="v${VERSION%%.*}"
              printf '%s' "$VERSION" > "$(results.VERSION.path)"
              printf '%s' "$MAJOR_VERSION" > "$(results.MAJOR_VERSION.path)"
            env:
            - name: TAG_REF
              value: $(params.TAG_REF)
   ```

#### 2. Create a catalog tag pipeline - [HYPERFLEET-1884](https://redhat.atlassian.net/browse/HYPERFLEET-1884)

Add `hyperfleet-operator-fbc-tag.yaml` to `.tekton/`. This pipeline triggers
on a specific `tag` push of `catalog-vX.Y.Z-rcN` (RC) or `catalog-vX.Y.Z`
(final)

Once the [Create a fbc application and component](#1-create-hyperfleet-fbc-application-and-component---hyperfleet-1770) are created, we have to create a `hyperfleet-operator-fbc-tag.yaml` catalog pipeline that requires these changes:

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

3. Add a `parse-tag` task

   ```yaml
   pipelineSpec:
     tasks:
     - name: parse-tag
       params:
       - name: TAG_REF
         value: $(params.target-branch)
       taskSpec:
         params:
         - name: TAG_REF
           type: string
         results:
         - name: VERSION
           description: Semantic version extracted from git tag ref
         - name: MAJOR_VERSION
           description: Major version (e.g. v1) extracted from git tag ref
         steps:
         - name: extract
           image: registry.access.redhat.com/ubi9-minimal:latest
           script: |
             #!/usr/bin/env bash
             VERSION="${TAG_REF#refs/tags/catalog-v}"
             MAJOR_VERSION="v${VERSION%%.*}"
             printf '%s' "$VERSION" > "$(results.VERSION.path)"
             printf '%s' "$MAJOR_VERSION" > "$(results.MAJOR_VERSION.path)"
           env:
           - name: TAG_REF
             value: $(params.TAG_REF)
   ```

4. Update `BUILD_ARGS` to include `APP_VERSION=${VERSION}`

### `konflux-release-data` Repository

#### 1. Create `hyperfleet-fbc` Application and Component - [HYPERFLEET-1770](https://redhat.atlassian.net/browse/HYPERFLEET-1770)

Add a new Application, Component and ImageRepository to `tenants-config/cluster/kflux-prd-rh02/tenants/hyperfleet-tenant/applications/`. This separates the fbc elements into a separate application.

#### 2. Create new ReleasePlan and ReleasePlanAdmission for FBC flow - [HYPERFLEET-1773](https://redhat.atlassian.net/browse/HYPERFLEET-1773)

Create 4 new items within the `hyperfleet-fbc` application.

**Release Plans:**

```yaml
---
# Release Plan for HyperFleet FBC RC releases.
apiVersion: appstudio.redhat.com/v1alpha1
kind: ReleasePlan
metadata:
  namespace: hyperfleet-tenant
  name: hyperfleet-fbc-rc-releaseplan
  annotations:
    release.appstudio.openshift.io/auto-release: |
      "build.appstudio.redhat.com/target_branch" in snapshot.metadata.annotations &&
      snapshot.metadata.annotations["build.appstudio.redhat.com/target_branch"].matches("^refs/tags/catalog-v[0-9]+\\.[0-9]+\\.[0-9]+-rc[0-9]+$")
  labels:
    release.appstudio.openshift.io/releasePlanAdmission: hyperfleet-fbc-rc
    release.appstudio.openshift.io/standing-attribution: "true"
    release.appstudio.openshift.io/author: mahill
spec:
  application: hyperfleet-fbc
  target: rhtap-releng-tenant
---
# Release Plan for final HyperFleet FBC releases.
apiVersion: appstudio.redhat.com/v1alpha1
kind: ReleasePlan
metadata:
  namespace: hyperfleet-tenant
  name: hyperfleet-fbc-releaseplan
  annotations:
    release.appstudio.openshift.io/auto-release: |
      "build.appstudio.redhat.com/target_branch" in snapshot.metadata.annotations &&
      snapshot.metadata.annotations["build.appstudio.redhat.com/target_branch"].matches("^refs/tags/catalog-v[0-9]+\\.[0-9]+\\.[0-9]+$")
  labels:
    release.appstudio.openshift.io/releasePlanAdmission: hyperfleet-fbc
    release.appstudio.openshift.io/standing-attribution: "true"
    release.appstudio.openshift.io/author: mahill
spec:
  application: hyperfleet-fbc
  target: rhtap-releng-tenant
```

**ReleasePlanAdmissions:**

```yaml
apiVersion: appstudio.redhat.com/v1alpha1
kind: ReleasePlanAdmission
metadata:
  labels:
    pp.engineering.redhat.com/business-unit: other
    release.appstudio.openshift.io/block-releases: "false"
  name: hyperfleet-fbc-rc
  namespace: rhtap-releng-tenant
spec:
  applications:
    - hyperfleet-fbc
  origin: hyperfleet-tenant
  policy: app-interface-standard
  data:
    releaseNotes:
      product_name: HyperFleet
      product_version: "1.0"
    mapping:
      registrySecret: konflux-release-service-access-management-token
      defaults:
        tags:
          - "{{ labels.version }}"
          - "{{ git_sha }}"
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
  policy: app-interface-standard
  data:
    releaseNotes:
      product_name: HyperFleet
      product_version: "1.0"
    mapping:
      registrySecret: konflux-release-service-access-management-token
      defaults:
        tags:
          - "{{ labels.version }}"
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

---

### Open Questions

1. Should we add back an on-push fbc/catalog only pipeline? Do we need to validate the catalog on every change to the operator bundle or should our testing automation strictly use the bundles? Do we keep validation of catalogs to release only? See [Catalogs](#catalogs---fbc)
