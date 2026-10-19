---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-10-16
---

# Spike OLM Upgrade Path

Follow up to **Ticket:**
[HYPERFLEET-1617](https://issues.redhat.com/browse/HYPERFLEET-1617)

Defines the upgrade path and testing strategy for hyperfleet-operator during
the release process. [Spike OLM Releases](spike-olm-releases.md) covers the
hyperfleet release flow through bundles and channels; this document covers the
upgrade flow specifically. Draft — still being refined.

## Background

Upgrade path for the `hyperfleet-operator` should be defined in a
`release-template.yaml` file on the `main`.

## Upgrade from v1.0.0 -> v1.0.1

### Setup

1. Cut all release branches (`hyperfleet-api`, `hyperfleet-sentinel`,
   `hyperfleet-operator`, `hyperfleet-adapter`)
2. Update rc images in `config/manifests/prod/kustomization.yaml`.
3. Tag the release branch as `bundle-v1.0.1-rc1` and build the bundle:
   `quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet:hyperfleet-operator-bundle:v1.0.1-rc1`
4. Once we build the bundle v1.0.1-rc1 we are able to add an entry to the
   release-template.yaml. Look below for next steps.

### Upgrade Options

**Assumption:** We have already done a v1.0.0 release and we need to test
upgrade path before we promote v1.0.1.

Currently `konflux-template.yaml` is used, but we want to replace it with
`release-template.yaml`.

`release-template.yaml` will be used by the catalog build to produce the
catalog image that clusters poll for updates.

The structure of that `release-template.yaml` matters. Here are 2 options

#### Option - Multi-channels with consistent tag

Defines two channels, candidate and stable, per major release.

```release-template.yaml
schema: olm.template.basic
entries:
  - schema: olm.package
    name: hyperfleet-operator
    defaultChannel: stable-v1
    description: "HyperFleet Operator"

  # ==========================================
  # CANDIDATE CHANNEL: Includes RCs and Finals
  # ==========================================
  - schema: olm.channel
    name: candidate-v1
    package: hyperfleet-operator
    entries:
      # The official release is added here to upgrade the RC testers
      - hyperfleet-operator.v1.0.0
      # First rc1 replaces official v1.0.0 release
      - name: hyperfleet-operator.v1.0.1-rc1
        replaces: hyperfleet-operator.v1.0.0
      # The second RC skips the first RC
      - name: hyperfleet-operator.v1.0.1-rc2
        replaces: hyperfleet-operator.v1.0.1-rc1
        skipRange: ">=1.0.0 <1.0.1-rc2"

  # ==========================================
  # STABLE CHANNEL: Strictly Official Releases
  # ==========================================
  - schema: olm.channel
    name: stable-v1
    package: hyperfleet-operator
    entries:
      # The official release is added here.
      # Notice it does NOT replace the RC here, because the RC never existed in this channel.
      - name: hyperfleet-operator.v1.0.0

  ... bundle definitions down below
  # ==========================================
  # BUNDLE DEFINITIONS
  # ==========================================
  - schema: olm.bundle
    image: quay.io/redhat-services-prod/.../hyperfleet-operator-bundle@sha256:<v1.0.1-rc1-digest>
  - schema: olm.bundle
    image: quay.io/redhat-services-prod/.../hyperfleet-operator-bundle@sha256:<v1.0.0-digest>
  - schema: olm.bundle
    image: quay.io/redhat-services-prod/.../hyperfleet-operator-bundle@sha256:<v1.0.1-rc2-digest>
```

#### Steps for the multi-channel option (after [Setup](#setup))

1. Commit and push the changes to the release-template.yaml on the `main` branch
2. Tag the commit `catalog-v1.0.1-rc1` and push the tag. This should trigger the
   catalog pipeline to build the catalog to
   `quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet:hyperfleet-operator-catalog:latest`
3. Look at [testing](#option-1-based-on-the-above-multi-channel-option) to see
   how to test the upgrade in Prow.

#### Option - Single channel with rc tag

Defines one `stable` channel per major release.

```release-template.yaml
schema: olm.template.basic
entries:
  - schema: olm.package
    name: hyperfleet-operator
    defaultChannel: stable-v1
    description: "HyperFleet Operator"
  # ==========================================
  # STABLE CHANNEL: Strictly Official Releases
  # ==========================================
  - schema: olm.channel
    name: stable-v1
    package: hyperfleet-operator
    entries:
        # The official release v1.0.0 is set here when v1.0.0
      - name: hyperfleet-operator.v1.0.0
        # We add v1.0.1-rc1 and use replace to define the upgrade path from v1.0.0 -> v1.0.1-rc1
      - name: hyperfleet-operator.v1.0.1-rc1
        replaces: hyperfleet-operator.v1.0.0
  # ==========================================
  # BUNDLE DEFINITIONS
  # ==========================================
  - schema: olm.bundle
    image: quay.io/redhat-services-prod/.../hyperfleet-operator-bundle@sha256:<v1.0.1-rc1-digest>
  - schema: olm.bundle
    image: quay.io/redhat-services-prod/.../hyperfleet-operator-bundle@sha256:<v1.0.0-digest>
```

#### Steps for the single-channel option (after [Setup](#setup))

1. Commit and push the changes to the release-template.yaml on the `main` branch
2. Tag the commit `catalog-v1.0.1-rc1` and push the tag. This should trigger the
   catalog pipeline to build the catalog to
   `quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet:hyperfleet-operator-catalog:rc1`
3. Look at [testing](#option-2-based-on-the-above-single-channel-with-rc-tag) to
   see how to test the upgrade in Prow.

### Proposed Testing Strategy

Within Prow set up a cluster, install OLM, and create these specific resources.

#### Option 1 based on the above [Multi channel option](#option---multi-channels-with-consistent-tag)

Based on option 1 above:

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: hyperfleet-operator-fbc
  namespace: olm
spec:
  sourceType: grpc
  # includes the digest of the latest catalog
  image: quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-fbc:latest
  publisher: Red Hat
```

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: sub-to-hyperfleet-operator
  namespace: hyperfleet
spec:
  channel: candidate-v1
  name: hyperfleet-operator
  source: hyperfleet-operator-fbc # matches the CatalogSource name above
  sourceNamespace: olm
  installPlanApproval: Manual
  startingCSV: 1.0.0
```

#### Option 2 based on the above [Single channel with rc tag](#option---single-channel-with-rc-tag)

Based on option 2 above:

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: hyperfleet-operator-fbc
  namespace: olm
spec:
  sourceType: grpc
  image: quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-fbc:rc1
  publisher: Red Hat
```

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: sub-to-hyperfleet-operator
  namespace: hyperfleet
spec:
  channel: stable-v1
  name: hyperfleet-operator
  source: hyperfleet-operator-fbc # matches the CatalogSource name above
  sourceNamespace: olm
  installPlanApproval: Manual
  startingCSV: 1.0.0
```

Whichever path is chosen, will verify the update from version v1.0.0 ->
v1.0.1-rc1 before promoted v1.0.1 builds. Check the InstallPlan and set to
true to install. Verify resources get upgraded properly and continue with RC
E2E tests.
