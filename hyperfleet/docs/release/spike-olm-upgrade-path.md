---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-11-01
---

# SPIKE - OLM Upgrade Path

Follow up to **Ticket:** [HYPERFLEET-1617](https://issues.redhat.com/browse/HYPERFLEET-1617)

Defines the upgrade path and testing strategy for hyperfleet-operator during
the release process. [Spike OLM Releases](spike-olm-releases.md) covers the HyperFleet release flow through bundles and catalogs. This document covers the upgrade path through channels.

---

## Channels

### Channel Versioning

OLM channels control which bundle versions are available to a subscriber.
Channel naming and lifecycle decisions determine the upgrade graph,
how release-candidate (RC) and production bundles are separated, and how
multiple major versions coexist in the same catalog.

#### Versioning Options for HyperFleet Operator

Currently `konflux-template.yaml` is used, but we want to replace it with
`release-template.yaml`, which will be used to create the RC and final catalog.

##### Decision

**Single channel with RC tag** — one `stable-vX` channel per major version.

- The test catalog contains both RCs and finals in one linear graph: `v1.0.0` → `v1.0.1-rc1` → `v1.0.1`
- The official catalog receives only finals: `v1.0.0` → `v1.0.1`.
- The RC entry is only ever added to `release-template.yaml` for RC testing, built into a test-only catalog image (e.g. tagged `:v1.0.1-rc1`), and consumed only by test/Prow `CatalogSources`.
- Before the official catalog is built, the RC entry is removed from `release-template.yaml` and the final release's `replaces` is repointed straight at the prior official release (e.g. `v1.0.1 replaces v1.0.0`, removing the RC entry entirely).
- The official catalog image (e.g. `quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-fbc:latest`) is then built from that RC-free template, so the official image only ever contains the validated bundles.
- Tradeoff: this relies on a manual release step — pruning the RC and repointing `replaces` before the official catalog build and manually releasing the catalog image — rather than allowing auto-releases.

##### Alternative Considered

1. Multi-channel — `candidate-vX` and `stable-vX` per major version.
   - `candidate-v1` — receives every bundle: `v1.0.0`, `v1.0.1-rc1`, `v1.0.1-rc2`, `v1.0.1`, etc.
   - `stable-v1` — receives only finals: `v1.0.0`, `v1.0.1`, `v1.0.2`, etc.
   - RC testers subscribe to `candidate-v1` to exercise the upgrade before it's promoted. Once validated, the final release is added to `stable-v1`.

## Upgrade Walkthrough: v1.0.0 to v1.0.1

Step by step guide for upgrading the hyperfleet operator from `v1.0.0` to `v1.0.1`.

### Setup

1. Cut all release branches (`hyperfleet-api`, `hyperfleet-sentinel`,
   `hyperfleet-operator`, `hyperfleet-adapter`)
2. Update rc images in `config/manifests/prod/kustomization.yaml`.
3. Tag the release branch as `bundle-v1.0.1-rc1` and build the bundle: `quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-bundle:v1.0.1-rc1`
4. Once we build the `hyperfleet-operator.v1.0.1-rc1` bundle we are able to add an entry to the release-template.yaml. Look below for next steps.

### RC verification

**Assumption:** We have already done a v1.0.0 release and we need to test
upgrade path before we promote v1.0.1.

Using the aforementioned single channel structure, this is how the release-template.yaml entries will look like during RC verification.

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
    image: quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-bundle@sha256:<v1.0.0-digest>
  - schema: olm.bundle
    image: quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-bundle@sha256:<v1.0.1-rc1-digest>
```

#### Steps for upgrade testing

1. Commit and push the changes to the release-template.yaml on the `main` branch.
2. Tag the commit `catalog-v1.0.1-rc1` and push the tag. This should trigger the catalog pipeline to build and push to `quay.io/redhat-user-workloads/hyperfleet-tenant/hyperfleet/hyperfleet-operator-fbc:v1.0.1-rc1` based on [Create a Catalog Tag Pipeline](./spike-olm-releases.md#2-create-a-catalog-tag-pipeline)
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
        image: quay.io/redhat-user-workloads/hyperfleet-tenant/hyperfleet/hyperfleet-operator-fbc:v1.0.1-rc1
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
        startingCSV: hyperfleet-operator.v1.0.0
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

Once RC verification has been completed and we decide to promote version `v1.0.1`

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

2. Tag the commit `catalog-v1.0.1` and push the tag. This should trigger the catalog pipeline to build and push to `quay.io/redhat-user-workloads/hyperfleet-tenant/hyperfleet/hyperfleet-operator-fbc:v1.0.1` and `quay.io/redhat-user-workloads/hyperfleet-tenant/hyperfleet/hyperfleet-operator-fbc:latest`, which then can be approved for release and pushed to `quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-fbc:latest`.

**Note:** This is different from the current releases, where all images are auto-released and pushed to the production registry by default. We don't want all main catalog images pushed to quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-fbc:latest because a user of this image will have access to the latest unofficial releases, and depending on their Subscription set up can have auto-upgrades enabled. See [Konflux Required Changes - OLM Releases](./spike-olm-releases.md#konflux-release-data-repository) for more information.

## Required Changes

### 1. Create a release template

Prior to creating an official HyperFleet release we must have a designated catalog release template. Add `catalog/release-template.yaml` on `main` branch. This file defines all versioned channels across all versions and should replace the temporary `catalog/konflux-template.yaml`. As part of [HYPERFLEET-1885](https://redhat.atlassian.net/browse/HYPERFLEET-1885)
