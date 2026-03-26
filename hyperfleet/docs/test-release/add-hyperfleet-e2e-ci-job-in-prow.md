---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-02-25
---

# Add Hyperfleet E2E CI Job in Prow

## Overview

This document provides a comprehensive guide for adding and managing Hyperfleet Continuous Integration (CI) jobs in Prow. It covers job configuration, step registry setup, monitoring, triggering, and debugging procedures specific to HyperFleet E2E CI test workflows.

## Implementation Steps

### Job Configuration

#### Init the job configuration in Prow

For detailed instructions on initializing job configuration in Prow, please refer to the [Initial Setup](add-job-configuration-in-prow.md#initial-setup) section.

#### Adding Step Registry Content

According to the description in the [Test Step Registry](add-job-configuration-in-prow.md#test-step-registry) section, it needs to add the following files.

For the Hyperfleet E2E test, create a folder like **e2e** under [openshift-hyperfleet](https://github.com/openshift/release/tree/master/ci-operator/step-registry/openshift-hyperfleet). Add step/chain/workflow file follow via your requirements.

For Hyperfleet E2E CI test, we added these [step and workflow](https://github.com/openshift/release/tree/main/ci-operator/step-registry/openshift-hyperfleet/e2e) like this:

```text
ci-operator/step-registry/openshift-hyperfleet/e2e/
├── openshift-hyperfleet-e2e-workflow.yaml           # Main E2E test workflow definition
├── openshift-hyperfleet-e2e-workflow.metadata.json  
│
├── setup/                                            # Hyperfleet platform deployment setup step
│   ├── openshift-hyperfleet-e2e-setup-ref.yaml
│   ├── openshift-hyperfleet-e2e-setup-ref.metadata.json
│   └── openshift-hyperfleet-e2e-setup-commands.sh
│
├── test/                                             # Hyperfleet E2E CI test execution step
│   ├── openshift-hyperfleet-e2e-test-ref.yaml
│   ├── openshift-hyperfleet-e2e-test-ref.metadata.json
│   └── openshift-hyperfleet-e2e-test-commands.sh
│
└── cleanup/                                          # Hyperfleet E2E cleanup steps
    ├── cluster-resources/                            # Clean up shared cluster resources
    │   ├── openshift-hyperfleet-e2e-cleanup-cluster-resources-ref.yaml
    │   ├── openshift-hyperfleet-e2e-cleanup-cluster-resources-ref.metadata.json
    │   └── openshift-hyperfleet-e2e-cleanup-cluster-resources-commands.sh
    │
    └── cloud-provider/                               # Clean up cloud provider resources
        ├── openshift-hyperfleet-e2e-cleanup-cloud-provider-ref.yaml
        ├── openshift-hyperfleet-e2e-cleanup-cloud-provider-ref.metadata.json
        └── openshift-hyperfleet-e2e-cleanup-cloud-provider-commands.sh

```

#### Step Parameters Configuration

**openshift-hyperfleet-e2e-`<folder-name>`-ref.yaml**

- Declaring step parameters: More detailed usage can refer to the [official doc](https://docs.ci.openshift.org/docs/architecture/step-registry/#declaring-step-parameters)
  - If you create folder for step/chain/workflow, you should replace the folder_name.If not, just need to delete it
  - Credentials  config: The secret has been added according to the [doc](prow-vault-access-management.md). For CI job, it requires gcloud credential to get the GKE cluster credential to deploy. We prepared a SA **hyperfleet-e2e** for it and store the credential under hyperfleet-e2e folder in Vault, so please don't delete it.
  - Image: **hyperfleet-e2e** It is built from [Dockerfile](https://github.com/openshift/release/blob/b968e721d74890587b15db562aa6138709543fa2/ci-operator/config/openshift-hyperfleet/hyperfleet-e2e/openshift-hyperfleet-hyperfleet-e2e-main__e2e.yaml#L8) before every test in the job.The Dockerfile is from [hyperfleet-e2e](https://github.com/openshift-hyperfleet/hyperfleet-e2e/blob/main/Dockerfile)

 ```yaml
ref:
  as: openshift-hyperfleet-e2e-<folder-name>
  from: hyperfleet-e2e
  grace_period: 10m
  commands: openshift-hyperfleet-e2e-<folder-name>-commands.sh
  resources:
    requests:
      cpu: 100m
      memory: 300Mi
  timeout: 1h0m0s
  env:
  - name: # environment variable name e.g. HYPERFLEET_E2E_PATH
    default: # (optional) the value assigned if none is provided
    documentation: # (optional) a textual description of the parameter. Markdown supported. 
  credentials:
  - collection: ""
    namespace: test-credentials
    name: hyperfleet-e2e
    mount_path: /var/run/hyperfleet-e2e
 ```

**openshift-hyperfleet-e2e-`<folder-name>`-commands.sh**
- Define the shell script for the job. It depends on different business logic.
  - In above step, it mounts the volume for credential. And the hcm-hyperfleet-e2e.json secret has been added in Vault, so it can get the value directly in the shell script

```bash
<Other steps>
# HYPERFLEET_E2E_PATH can be defined in above environment variable
GCP_CREDENTIALS_FILE="${HYPERFLEET_E2E_PATH}/hcm-hyperfleet-e2e.json"  
```

**openshift-hyperfleet-e2e-`<folder-name>`-ref.metadata.json**
- Store the owners and path

```json
{
  "path": "openshift-hyperfleet/e2e/<folder-name>/openshift-hyperfleet-e2e-<folder-name>-ref.yaml",
  "owners": {
    "approvers": [
      "..."
    ],
    "reviewers": [
      "..."
    ]
  }
}
```

#### Adding the Job Configuration

The job can be added in [`openshift-hyperfleet-hyperfleet-e2e-main__e2e.yaml`](https://github.com/openshift/release/blob/b968e721d74890587b15db562aa6138709543fa2/ci-operator/config/openshift-hyperfleet/hyperfleet-e2e/openshift-hyperfleet-hyperfleet-e2e-main__e2e.yaml#L16) under the `tests` field: 

```yaml
tests:
- as: hyperfleet-e2e-nightly # Define job name
  cron: 30 9 * * * # Job cron time
  steps:
    env: # All required env parameters, it depends on test step/chain/workflow requirements
      <key>: <value>
      ...
    test:
    - ref: <step_name/chain_name> # Required step/chain name for the job
    workflow: <workflow_name>  # Required workflow name for the job
```

### Job URLs and Monitoring

#### Finding Running Jobs

To find and monitor running jobs on Prow:
1. Navigate to the [Prow dashboard](https://prow.ci.openshift.org/).
2. Use the filter bar to search for specific jobs:
   - By job name: [`periodic-ci-openshift-hyperfleet-hyperfleet-e2e-main-e2e-hyperfleet-e2e-test-workflow-nightly`](https://prow.ci.openshift.org/?job=periodic-ci-openshift-hyperfleet-hyperfleet-e2e-main-e2e-hyperfleet-e2e-test-workflow-nightly)
   - By status: Add `&state=pending` or `&state=success` or `&state=failure` to the URL
3. Click on any job to view detailed logs and execution information

### Triggering Jobs

#### Manual Trigger in Prow Dashboard

If you want to trigger the job from Prow dashboard, it requires granting GitHub team permissions via **rerun_auth_configs** in the Prow configuration file.

**Configuration Location:**
The rerun authorization is configured in [_config.yaml](https://github.com/openshift/release/blob/main/core-services/prow/02_config/_config.yaml) file

**Configuration Example:**
```yaml
- repo: openshift-hyperfleet/hyperfleet-e2e
  rerun_auth_configs:
    github_team_slugs:
    - org: openshift-hyperfleet
      slug: hyperfleet
    - org: openshift
      slug: test-platform
```

**Key Configuration Points:**

- **github_team_slugs**: Lists GitHub teams that can rerun CI jobs
  - **org**: The GitHub organization name
  - **slug**: The team slug (the URL-friendly team name from GitHub)
- **github_users**: Lists individual GitHub users who can rerun CI jobs (optional)
  - Use this when specific users need access outside of team membership
  - Example configuration:
    ```yaml
    - repo: openshift-hyperfleet/hyperfleet-e2e
      rerun_auth_configs:
        github_users:
        - username1
        - username2
        github_team_slugs:
        - org: openshift-hyperfleet
          slug: hyperfleet
    ```

**Configured Teams:**
- The `hyperfleet` team from the `openshift-hyperfleet` organization
- The `test-platform` team from the `openshift` organization (standard for CI support)

**Note:** Currently, no `github_users` section is configured for this repository, meaning only team-based permissions are used. If individual user access is needed outside of team membership, add their GitHub usernames to the `github_users` list.

**How to Verify the Team Slug:**
Visit the team page on GitHub (e.g., https://github.com/orgs/openshift-hyperfleet/teams/hyperfleet). The last part of the URL (`hyperfleet`) is the team slug.

After this configuration is merged, members of these teams will be able to rerun and abort CI jobs under the `openshift-hyperfleet/hyperfleet-e2e` repository directly from the Prow dashboard

#### Manual Trigger via command

**Obtaining an Authentication Token**
Each SSO user is entitled to obtain a personal authentication token. Tokens can be retrieved through the UI of the app.ci cluster at [OpenShift Console](https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com/). 

**Triggering a Periodic Job**

```text
curl -v -X POST -H "Authorization: Bearer $(oc whoami -t)" -d '{"job_name": "<JOB_NAME>", "job_execution_type": "1"}' https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/v1/executions

Example:
curl -v -X POST -H "Authorization: Bearer $(oc whoami -t)" -d '{"job_name": "periodic-ci-openshift-hyperfleet-hyperfleet-e2e-main-e2e-hyperfleet-e2e-nightly", "job_execution_type": "1"}' https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/v1/executions
```
More other steps can refer to official [prow doc](https://docs.ci.openshift.org/docs/how-tos/triggering-prowjobs-via-rest/#triggering-a-periodic-job)

#### Manual Trigger in a PR via GitHub Comment

If you want to add some new code for the CI workflow, you can prepare a PR and trigger the job in the PR with the changed code via comment:

```text
/pj-rehearse <job_name>
```

### Creating Additional Jobs

To add another job based on the existing Hyperfleet E2E CI job:

1. **Copy the existing job configuration** to add it in [`openshift-hyperfleet-hyperfleet-e2e-main__e2e.yaml`](https://github.com/openshift/release/blob/b968e721d74890587b15db562aa6138709543fa2/ci-operator/config/openshift-hyperfleet/hyperfleet-e2e/openshift-hyperfleet-hyperfleet-e2e-main__e2e.yaml#L16) Update the following:
   ```yaml
   - as: hyperfleet-e2e-<specified_name> # Job name
     cron: 30 9 * * * # Job cron time
     steps:
       env: # All required env parameters, it depends on test step/chain/workflow requirements
         <key>: <value>
       test:
       - ref: <step_name/chain_name> # Required step/chain name for the job
       workflow: <workflow_name>  # Required workflow name for the job
   ```

2. **Modify the job name and parameters**
   - Update the `as` field
   - Adjust `cron` schedule (for periodic jobs)
   - Modify environment variables as needed under `env`
   - Adjust step registry references via requirement under `ref`

3. **Add the new job**

   Run the command to generate and update the job configuration:
   ```bash
   make jobs
   ```

4. **Submit a PR with the new job configuration**
   - Prow will trigger some precheck jobs to verify the changed code
   - It still requiure to trigger the affected job via adding comment.
   ```text
   /pj-rehearse {test-name}
   ```
   - In the past, it required adding **/pj-rehearse ack** to meet the tidy job once you get a team member approved

### Debugging

#### Viewing Job Logs

1. Follow the [Finding Running Jobs](#finding-running-jobs) steps to locate the job
2. Click the job link to jump to the detailed job page
3. Click **Artifacts** to jump to the log page
4. Navigate to the folder: **artifacts/hyperfleet-e2e-nightly/openshift-hyperfleet-e2e/**
5. You can find the detailed logs under the **artifacts** folder


## CI Jobs Example PRs

- Initial CI jobs structure: [PR #73127](https://github.com/openshift/release/pull/73127)
- Added hyperfleet-e2e test steps to CI Prow job: [PR #73973](https://github.com/openshift/release/pull/73973)

## References

- [Prow Documentation](https://docs.ci.openshift.org/)
- [Step Registry Documentation](https://docs.ci.openshift.org/docs/architecture/step-registry/)
- [OpenShift HyperFleet Repository](https://github.com/openshift/release/tree/master/ci-operator/step-registry/openshift-hyperfleet)
