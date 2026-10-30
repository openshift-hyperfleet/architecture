---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-10-16
---
# SPIKE - OLM Upgrade Path

Follow up to **Ticket:**
[HYPERFLEET-1617](https://issues.redhat.com/browse/HYPERFLEET-1617)

Defines the upgrade path and testing strategy for hyperfleet-operator during
the release process. [Spike OLM Releases](spike-olm-releases.md) covers the HyperFleet release flow through bundles and catalogs. This document covers the upgrade path through channels.

**Note:** Catalog builds within the nightly CI will remain as is. Using `catalog/konflux-template.yaml` is sufficient right now.

---

## Channels

### Channel Versioning

OLM channels control which bundle versions are available to a subscribed
cluster. Channel naming and lifecycle decisions determine the upgrade graph,
how release-candidate (RC) and production bundles are separated, and how
multiple major versions coexist in the same catalog.

#### Versioning Options for HyperFleet Operator

Each major version requires at least one channel defined in
`release-template.yaml`. There are two ways to structure those channels,
detailed further in [Upgrade Options - RC verification](#upgrade-options---rc-verification) below:

|                                               | Option 1: Multi-channel                                                        | Option 2: Single-channel with RC tag                                                           |
| --------------------------------------------- | ------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------- |
| Channels per major version                    | 2: `candidate-vX` (RCs + finals) and `stable-vX` (finals only)                 | 1: `stable-vX` (RCs + finals)                                                                  |
| Where RCs appear                              | Only in `candidate-vX`                                                         | In `stable-vX`, but only within the RC/Prow catalog image — never the official                 |
| Does the RC reach the official catalog image? | Yes — included in `candidate-vX`, but `stable-vX` subscribers can't resolve it | No — excluded entirely; the RC only ever exists in a separate test-only image                  |
| Upgrade graph for a patch release             | `stable-vX`: `vX.0.0 -> vX.0.1`                                                | `stable-vX`: `vX.0.0 -> vX.0.1`                                                                |
| RC tester subscription                        | `channel: candidate-v1`                                                        | `channel: stable-v1` (on the test catalog image)                                               |
| `release-template.yaml` complexity            | More entries to maintain (two channels × N major versions)                     | Fewer entries (one channel x N major versions). RC removed when creating the official catalog. |

**Option 1: Multi-channel** — `candidate-vX` and `stable-vX` per major version.

- `candidate-v1` — receives every bundle: `v1.0.0`, `v1.0.1-rc1`, `v1.0.1-rc2`, `v1.0.1`, etc.
- `stable-v1` — receives only finals: `v1.0.0`, `v1.0.1`, `v1.0.2`, etc.
- RC testers subscribe to `candidate-v1` to exercise the upgrade before it's promoted. Once validated, the final release is added to `stable-v1` — note it does **not** replace the RC there, because the RC was never in `stable-v1` to begin with.

**Option 2: Single channel with RC tag** — one `stable-vX` channel per major version.

- In the test catalog, `stable-v1` contains both RCs and finals in one linear graph: `v1.0.0` → `v1.0.1-rc1` → `v1.0.1`. The official catalog receives only finals: `v1.0.0` → `v1.0.1`.
- The RC entry is only ever added to `release-template.yaml` for RC testing, built into a test-only catalog image (e.g. tagged `:rc1`), and consumed only by test/Prow `CatalogSources`.
- Before the official catalog is built, the RC entry is removed from `release-template.yaml` and the final release's `replaces` is repointed straight at the prior official release (e.g. `v1.0.1 replaces v1.0.0`, removing the RC entry entirely).
- The official catalog image (e.g. tagged `:latest`) is then built from that RC-free template, so its `stable-v1` channel only ever contains official releases.
- Tradeoff: this relies on a manual release step — pruning the RC and repointing `replaces` before every official catalog build — rather than catalog structure enforcing it automatically. The test and official catalogs must also never share the same image tag.

## Upgrade Walkthrough: v1.0.0 to v1.0.1

### Setup

1. Cut all release branches (`hyperfleet-api`, `hyperfleet-sentinel`,
   `hyperfleet-operator`, `hyperfleet-adapter`)
2. Update rc images in `config/manifests/prod/kustomization.yaml`.
3. Tag the release branch as `bundle-v1.0.1-rc1` and build the bundle: `quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-bundle:v1.0.1-rc1`
4. Once we build the bundle `hyperfleet-operator.v1.0.1-rc1` we are able to add an entry to the release-template.yaml. Look below for next steps.

### Upgrade Options - RC verification

**Assumption:** We have already done a v1.0.0 release and we need to test
upgrade path before we promote v1.0.1.

Currently `konflux-template.yaml` is used, but we want to replace it with
`release-template.yaml`, which will be used to create the RC and final catalog.

**The structure of that `release-template.yaml` matters. Here are 2 options**

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
      - name: hyperfleet-operator.v1.0.0
      # First rc1 replaces official v1.0.0 release
      - name: hyperfleet-operator.v1.0.1-rc1
        replaces: hyperfleet-operator.v1.0.0
      # The second RC skips the first RC

  # ==========================================
  # STABLE CHANNEL: Only includes the final releases, no RCs
  # ==========================================
  - schema: olm.channel
    name: stable-v1
    package: hyperfleet-operator
    entries:
      # The official release is added here.
      # Notice it does NOT replace the RC here, because the RC never existed in this channel.
      - name: hyperfleet-operator.v1.0.0
  - schema: olm.bundle
    image: quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-bundle@sha256:<v1.0.0-digest>
  - schema: olm.bundle
    image: quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-bundle@sha256:<v1.0.1-rc1-digest>
```

#### Steps for the multi-channel option (after [Setup](#setup))

1. Commit and push the changes to the release-template.yaml on the `main` branch
2. Tag the commit `catalog-v1.0.1-rc1` and push the tag. This should trigger the catalog pipeline to build the catalog to `quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-fbc:latest`
3. Look at [testing](#option-1-based-on-the-above-multi-channel-option) to see how to test the upgrade in Prow.

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
  # STABLE CHANNEL: Only includes the final releases, no RCs
  # ==========================================
  - schema: olm.channel
    name: stable-v1
    package: hyperfleet-operator
    entries:
      # The official release is added here.
      # Notice it does NOT replace the RC here, because the RC never existed in this channel.
      - name: hyperfleet-operator.v1.0.0
      # First rc1 replaces official v1.0.0 release
      - name: hyperfleet-operator.v1.0.1-rc1
        replaces: hyperfleet-operator.v1.0.0
      # The second RC skips the first RC
  - schema: olm.bundle
    image: quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-bundle@sha256:<v1.0.0-digest>
  - schema: olm.bundle
    image: quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-bundle@sha256:<v1.0.1-rc1-digest>
```

#### Steps for the single-channel option (after [Setup](#setup))

1. Commit and push the changes to the release-template.yaml on the `main` branch.
2. Tag the commit `catalog-v1.0.1-rc1` and push the tag. This should trigger the catalog pipeline to build and push to `quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-fbc:rc1`
3. Look at [testing](#option-2-based-on-the-above-single-channel-option) to see how to test the upgrade in Prow.

### Proposed Testing Strategy

Within Prow set up a cluster, install OLM, and create these specific resources.
Depending on which option we go with above the only difference will be the CatalogSource and Subscription

#### Option 1 based on the above [Multi channel option](#option---multi-channels-with-consistent-tag)

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: hyperfleet-operator-fbc
  namespace: olm
spec:
  sourceType: grpc
  displayName: HyperFleet Operator Catalog
  image: quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-fbc:latest
  publisher: Red Hat
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: sub-hyperfleet-operator
  namespace: hyperfleet
spec:
  channel: candidate-v1
  name: hyperfleet-operator
  source: hyperfleet-operator-fbc
  sourceNamespace: olm
  installPlanApproval: Manual
  startingCSV: hyperfleet-operator.v1.0.0
```

#### Option 2 based on the above [Single channel option](#option---single-channel-with-rc-tag)

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: hyperfleet-operator-fbc
  namespace: olm
spec:
  sourceType: grpc
  displayName: HyperFleet Operator Catalog
  image: quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/hyperfleet-operator-fbc:rc1
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

#### Follow up steps - irrespective of release-template.yaml

1. Apply the following resources with `kubectl apply`

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
   ```

2. Approve `hyperfleet-operator.v1.0.0` InstallPlan - this will install the 1.0.0 version

   ```bash
   kubectl get installplans.operators.coreos.com -A

   NAMESPACE    NAME            CSV                              APPROVAL   APPROVED
   hyperfleet   install-gbnnh   hyperfleet-operator.v1.0.0       Manual     false

   export install_plan_v1_0_0=$(kubectl get installplans -n hyperfleet -o json | jq -r '.items[] | select(.spec.clusterServiceVersionNames | index("hyperfleet-operator.v1.0.0")) | .metadata.name') 

   kubectl patch installplan $install_plan_v1_0_0 -n hyperfleet --type merge -p '{"spec":{"approved":true}}'
   ```

3. Test upgrade by approving the `hyperfleet-operator.v1.0.1-rc1` InstallPlan

   ```bash
   kubectl get installplans.operators.coreos.com -A

   NAMESPACE    NAME            CSV                              APPROVAL   APPROVED
   hyperfleet   install-gbnnh   hyperfleet-operator.v1.0.0       Manual     true
   hyperfleet   install-tqxds   hyperfleet-operator.v1.0.1-rc1   Manual     false

   export install_plan_v1_0_1_rc1=$(kubectl get installplans -n hyperfleet -o json | jq -r '.items[] | select(.spec.clusterServiceVersionNames | index("hyperfleet-operator.v1.0.1-rc1")) | .metadata.name') 

   kubectl patch installplan $install_plan_v1_0_1_rc1 -n hyperfleet --type merge -p '{"spec":{"approved":true}}'
   ```

4. Continue with E2E RC testing on version v1.0.1-rc1

## Required Changes

### 1. Create a release template

Prior to creating an official HyperFleet release we must have a designated catalog release template. Add `catalog/release-template.yaml` on `main` branch. This file defines all
versioned channels across all versions. Once [Versioning Options for HyperFleet Operator](#versioning-options-for-hyperfleet-operator) is decided upon, we can create this template.
