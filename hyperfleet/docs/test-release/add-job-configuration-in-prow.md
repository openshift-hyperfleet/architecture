---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-01-28
---

# Adding CI Configuration for New Repositories

## Overview

This document provides guidance for adding pre-submit testing and image built-up pipelines for components to OpenShift CI. 

Presubmit jobs are configured per repository and are the primary mechanism to catch regressions before code is merged. They can be configured as required or optional, though required jobs provide stronger guarantees against regressions.

Images published in this manner are produced when the source repository branch is updated (e.g. when a PR merges or the branch is manually updated), not when the images are built as in an in-flight PR.


## Initial Setup

When adding CI configuration for new repositories, use the **make new-repo** target instead of manually creating configuration files under [release repo](https://github.com/openshift/release). This interactive tool walks you through the necessary steps and generates the proper configuration structure:

<details>
<summary> Cmd "make new-repo" interactive mode step by step</summary>

```bash
$ make new-repo
false || podman pull --platform linux/amd64 quay.io/openshift/ci-public:ci_repo-init_latest
Trying to pull quay.io/openshift/ci-public:ci_repo-init_latest...
Getting image source signatures
Copying blob sha256:ba43106cd07089f95e6d0b5bbf7b7556fccce4ce0fc50e2d5a6b4adabd12b074
Copying blob sha256:46a9484471e55e0e501c08ff903616330af0505ba749ef70e8c87e103e07844a
Copying config sha256:3f60382c63fffb91f15cc9bc815ece77915d5c81a84c31e23580140500b37210
Writing manifest to image destination
3f60382c63fffb91f15cc9bc815ece77915d5c81a84c31e23580140500b37210
podman run --platform linux/amd64  --rm -it -v "/Users/yingzhan/ying-work/code/release:/release" quay.io/openshift/ci-public:ci_repo-init_latest --release-repo /release
Welcome to the repository configuration initializer.
In order to generate a new set of configurations, some information will be necessary.

Let's start with general information about the repository...
Enter the organization for the repository: openshift-hyperfleet
Enter the repository to initialize: hyperfleet-logger
Enter the development branch for the repository: [default: main] 

Now, let's determine how the repository builds output artifacts...
Does the repository build and promote container images?  [default: no] 

Now, let's configure how the repository is compiled...
What version of Go does the repository build with? [default: 1.13] 1.25
[OPTIONAL] Enter the Go import path for the repository if it uses a vanity URL (e.g. "k8s.io/my-repo"): 
[OPTIONAL] What commands are used to build binaries in the repository? (e.g. "go install ./cmd/...") 
[OPTIONAL] What commands are used to build test binaries? (e.g. "go install -race ./cmd/..." or "go test -c ./test/...") 

Now, let's configure test jobs for the repository...

First, we will configure simple test scripts. Test scripts
execute unit or integration style tests by running a command
from your repository inside of a test container. For example,
a unit test may be executed by running "make test-unit" after
checking out the code under test.

Are there any test scripts to configure?  [default: no] yes
What is the name of this test (e.g. "unit")?  unit
What commands in the repository run the test (e.g. "make test-unit")?  make test     
Are there any more test scripts to configure?  [default: no] no

Next, we will configure end-to-end tests. An end-to-end test
executes a command from your repository against an ephemeral
OpenShift cluster. The test script will have "cluster:admin"
credentials with which it can execute no other tests will
share the cluster.

Are there any end-to-end test scripts to configure?  [default: no] no

Repository configuration options loaded!
In case of any errors, use the following command to re-
create this run without using the interactive interface:

/usr/bin/repo-init --release-repo /release --config="{\"org\":\"openshift-hyperfleet\",\"repo\":\"hyperfleet-logger\",\"branch\":\"main\",\"base_images\":null,\"images\":null,\"canonical_go_repository\":\"\",\"promotes\":false,\"promotes_with_openshift\":false,\"needs_base\":false,\"needs_os\":false,\"go_version\":\"1.13\",\"build_commands\":\"\",\"test_build_commands\":\"\",\"tests\":[{\"as\":\"unit\",\"from\":\"src\",\"command\":\"make test\"}],\"custom_e2e\":null,\"release_type\":\"\",\"release_version\":\"\",\"operator_bundle\":null}"

Updating Prow configuration ...

Updating Prow plugin configuration ...
......
/Library/Developer/CommandLineTools/usr/bin/make boskos-config
cd core-services/prow/02_config && ./generate-boskos.py
```
</details>

The generated file for the above example is like this: `ci-operator/config/openshift-hyperfleet/hyperfleet-logger/openshift-hyperfleet-hyperfleet-logger-main.yaml`. The file structure should be `ci-operator/config/$org/$repo/$org-$repo-$branch.yaml`

> **Note:** This is the same initial setup described in [onboarding-a-new-component-for-testing-and-merge-automation.md](onboarding-a-new-component-for-testing-and-merge-automation.md). If the file `ci-operator/config/$org/$repo/$org-$repo-$branch.yaml` already exists, you can update it directly and skip the `make new-repo` step.

## Configuration File Structure

CI configuration files are organized under `ci-operator/config/$org/$repo/` with different purposes :

- **`$org-$repo-$branch.yaml`**: Main configuration for simple tests (unit, lint)
- **`$org-$repo-$branch__$variant.yaml`**: The variant should be a meaningful string from its usage.Like presubmits, image,etc.

Variants allow multiple ci-operator configuration files for a single branch. This is useful when a component needs to be built and tested in multiple different ways. Variant configuration files must follow the `$org-$repo-$branch__$VARIANT.yaml` pattern (note the double underscore separating the branch from the variant).

## Configuration Examples

### Basic Unit and Lint Tests

For the `$org-$repo-$branch.yaml` file, if your lint or unit tests don't require a specialized image, the default **src** image is sufficient. You can add test commands directly:

```yaml
build_root:
  image_stream_tag:
    name: release
    namespace: openshift
    tag: golang-1.25
resources:
  '*':
    limits:
      memory: 4Gi
    requests:
      cpu: 100m
      memory: 200Mi
tests:
- as: lint
  commands: make lint
  container:
    from: src
- as: unit
  commands: make test
  container:
    from: src
zz_generated_metadata:
  branch: main
  org: openshift-hyperfleet
  repo: hyperfleet-logger
```

### Integration Tests
For the `$org-$repo-$branch__presubmits.yaml` file, you must add a **variant: presubmits** field.
```yaml
build_root:
  image_stream_tag:
    name: builder
    namespace: ocp
    tag: rhel-9-golang-1.25-openshift-4.21
resources:
  '*':
    requests:
      cpu: 100m
      memory: 200Mi
tests:
- as: integration
  commands: |
    go mod tidy
    make test-integration
  container:
    from: src
zz_generated_metadata:
  branch: main
  org: openshift-hyperfleet
  repo: hyperfleet-logger
  variant: presubmits
```

### Image Build Jobs

Image build jobs publish images to repositories specified via the **promotion** configuration. For publishing to external registries, refer to [Mirror an Image to an External Registry](https://docs.ci.openshift.org/docs/how-tos/mirroring-to-quay/).

```yaml
build_root:
  image_stream_tag:
    name: builder
    namespace: ocp
    tag: rhel-9-golang-1.25-openshift-4.21
images:
- dockerfile_path: Dockerfile # The path to the Dockerfile in your repository
  to: hyperfleet-logger # The image's name
promotion:
  to:
  - namespace: ci
    tag: latest
    tag_by_commit: true # Publish tags based on the git commit being built
resources:
  '*':
    requests:
      cpu: 100m
      memory: 200Mi
zz_generated_metadata:
  branch: main
  org: openshift-hyperfleet
  repo: hyperfleet-logger
  variant: images
```

## Generating Prow Job Files

After creating ci-operator configuration files, you need to generate the corresponding Prow job configuration files.

The Test Platform team provides a [tool](https://github.com/openshift/ci-tools/tree/master/cmd/ci-operator-prowgen) that automatically generates Prow job configuration files from ci-operator configuration files. The generator understands the naming and directory structure conventions in the [openshift/release](https://github.com/openshift/release) repository.

Once you've placed your ci-operator configuration file in `ci-operator/config/$org/$repo`, generate the Prow files by running this command from the root of the openshift/release repository:

```bash
$ make jobs
```

This will create all necessary files under `ci-operator/jobs/$org/$repo` with a sensible default set of Prow jobs.

## Setting Up Team Ownership

### Initial Setup

While the initial PR to [openshift/release](https://github.com/openshift/release) requires review and approval by [root approvers](https://github.com/openshift/release/blob/master/OWNERS), the component configuration should be owned by the component team once merged.

To enable team ownership, place an **OWNERS** file (matching the one in your component repository) in both:
- `ci-operator/config/$org/$repo`
- `ci-operator/jobs/$org/$repo`

You can include the **OWNERS** file in your initial PR if you want the component team to have approval rights immediately.

### Automatic Synchronization

After your onboarding PR is merged, the **periodic-prow-auto-owners** job will automatically sync the **OWNERS** file from your component repository to the relevant directories. This sync:
- Runs periodically
- Pulls from the **OWNERS** file in your repository's base directory
- Syncs all members who are also members of the openshift GitHub organization

This means you only need to maintain the **OWNERS** file in your component repository; the CI configuration will be updated automatically.

## Run Podman in Prow

We have some integration tests with TestContainers that require Podman or Docker. Since Prow does not allow privileged mode, it provides an image configured to run Podman. See the [official documentation](https://docs.ci.openshift.org/docs/how-tos/nested-podman/).

### Base Image
  An image with such requirements is already available in Test Platform CI to be used as base image.
  ```yaml
   base_images:
    nested-podman:
        namespace: ci
        name: nested-podman
        tag: latest
  ```
### Capability
 Only the clusters tagged with the nested-podman capability (see [capabilities](https://docs.ci.openshift.org/docs/how-tos/capabilities/)) are able to run a container within a container. 
  ```yaml
   - as: nested-podman-unit-test
    capabilities:
    - nested-podman
  ```
### Enable the feature on a test
This example includes all the requirements described above, along with comments explaining the purpose of each stanza.
<details>
<summary> Working Example</summary>

```yaml
# Tag the `nested-podman` enabled base image into the test namespace.
base_images:
  nested-podman:
    name: nested-podman
    namespace: ci
    tag: latest
build_root:
  image_stream_tag:
    name: openshift-build
    namespace: jasee
    tag: rhel-9-golang-1.25
images:
# Use the `nested-podman` as a base image for the test.
# Add some tools that are required for the test
- dockerfile_literal: |
    FROM nested-podman
    COPY src/ /opt/app-root/src
    WORKDIR /opt/app-root/src/hyperfleet-logger
    USER root
    RUN dnf install -y go make
    RUN dnf clean all
  from: nested-podman
  inputs:
    src:
      paths:
      - destination_dir: src
        source_path: /go/src/github.com/openshift-hyperfleet/hyperfleet-logger
  to: podman-test
resources:
  '*':
    requests:
      cpu: "1"
      memory: 2Gi
tests:
- as: integration
  # Claim a cluster that support nested containerization
  capabilities:
  - nested-podman
  # Enable the feature
  nested_podman: true
  commands: |
    go get github.com/testcontainers/testcontainers-go
    export DOCKER_HOST=$(podman info --format 'unix://{{.Host.RemoteSocket.Path}}')
    podman system service --time=120 $(DOCKER_HOST) &
    systemctl --user start podman.socket || true
    export TESTCONTAINERS_RYUK_DISABLED=true
    go mod tidy
    make test-integration
  container:
    from: podman-test
zz_generated_metadata:
  branch: main
  org: openshift-hyperfleet
  repo: hyperfleet-logger
  variant: presubmits
```
</details>

## Presubmit/Image jobs example PR
 - For a complete example of adding CI configuration, see this [PR](https://github.com/openshift/release/pull/72905)
 - For an example with Podman, see this [PR](https://github.com/openshift/release/pull/72331)


## Test Step Registry

To prevent naming collisions between all the registry components, the step registry has a very strict naming scheme and directory layout. First, all components have a prefix determined by the directory structure, similar to how the ci-operator configs do. The prefix is the relative directory path with all / characters changed to -. For example, a file under the ipi/install/conf directory would have as prefix of ipi-install-conf. If there is a workflow, chain, or step in that directory, the as field for that component would need to be the same as the prefix. Further, only one of step, chain, or workflow can be in a subdirectory (otherwise there would be a name conflict).

After the prefix, we apply a suffix based on what the file is defining. These are the suffixes for the four file types that exist in the registry:

- Step: -ref.yaml
- Step command script: -commands.sh
- Chain: -chain.yaml
- Workflow: -workflow.yaml

Continuing the example above, a step in the [chart-deployment](https://github.com/openshift/release/tree/master/ci-operator/step-registry/openshift-hyperfleet/chart-deployment) subdirectory would have a filename of openshift-hyperfleet-chart-deployment-ref.yaml and the command would be openshift-hyperfleet-chart-deployment-commands.sh.

Other files that are allowed in the step registry but are not used for testing are OWNERS files and files that end in .md.

More detailed configurations can refer to official doc [Step-Registry](https://docs.ci.openshift.org/docs/architecture/step-registry/)

## Prow References
For more detailed information, refer to the official OpenShift CI documentation:
- [CI Operator Architecture](https://docs.ci.openshift.org/docs/architecture/ci-operator/)
- [Contributing to openshift/release](https://docs.ci.openshift.org/docs/how-tos/contributing-openshift-release/)

