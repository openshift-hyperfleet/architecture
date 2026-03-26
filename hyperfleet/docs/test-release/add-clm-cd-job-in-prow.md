---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-01-19
---

# Add CLM CD Job in Prow


## Overview

This document provides a comprehensive guide for adding and managing CLM (Cluster Lifecycle Management) Continuous Deployment (CD) jobs in Prow. It covers job configuration, step registry setup, monitoring, triggering, and debugging procedures specific to HyperFleet deployment workflows.

## Implementation Steps

### Job Configuration

#### Init the job configuration in Prow

For detailed instructions on initializing job configuration in Prow, please refer to the [Initial Setup](add-job-configuration-in-prow.md#initial-setup) section.

#### Adding Step Registry Content

According to the description in the [Test Step Registry](add-job-configuration-in-prow.md#test-step-registry) section, you need to add the following files.

For the CLM deployment, create a new folder **chart-deployment** under [openshift-hyperfleet](https://github.com/openshift/release/tree/master/ci-operator/step-registry/openshift-hyperfleet). The step files should be:
```text
openshift-hyperfleet-chart-deployment-commands.sh
openshift-hyperfleet-chart-deployment-ref.yaml
openshift-hyperfleet-chart-deployment-ref.metadata.json
OWNERS
```

#### Step Parameters Configuration

**openshift-hyperfleet-chart-deployment-ref.yaml**
- Declaring step parameters: More detailed usage can refer to the [official doc](https://docs.ci.openshift.org/docs/architecture/step-registry/#declaring-step-parameters)
  - Credentials  config: The secret has been added according to the [doc](prow-vault-access-management.md). For CD job, it requires gcloud credential to get the GKE cluster credential to deploy. We prepared a SA **hyperfleet-e2e** for it and store the credential under hyperfleet-e2e folder in Vault, so please don't delete it.
  - Image: hyperfleet-chart-src that is defined in file [openshift-hyperfleet-hyperfleet-chart-main__deployment.yaml](https://github.com/openshift/release/blob/543d4cfe083987b8ff711de3b6f870c7326f6dd9/ci-operator/config/openshift-hyperfleet/hyperfleet-chart/openshift-hyperfleet-hyperfleet-chart-main__deployment.yaml#L22) 

 ```yaml
ref:
  as: openshift-hyperfleet-chart-deployment
  from: hyperfleet-chart-src 
  grace_period: 10m
  commands: openshift-hyperfleet-chart-deployment-commands.sh
  resources:
    requests:
      cpu: 100m
      memory: 300Mi
  timeout: 1h0m0s
  env:
  - name: # environment variable name
    default: # (optional) the value assigned if none is provided
    documentation: # (optional) a textual description of the parameter. Markdown supported. 
  credentials:
  - collection: ""
    namespace: test-credentials
    name: hyperfleet-e2e
    mount_path: /var/run/hyperfleet-e2e
 ```

**openshift-hyperfleet-chart-deployment-commands.sh**
- Define the shell script for the job. It depends on different business logic.
  - In above step, it mounts the volume for credential.And the hcm-hyperfleet-e2e.json secret has been added in Vault, so it can get the value directly in the shell script

```bash
<Other steps>
# HYPERFLEET_E2E_PATH is defined in above environment variable
GCP_CREDENTIALS_FILE="${HYPERFLEET_E2E_PATH}/hcm-hyperfleet-e2e.json" 

```

**openshift-hyperfleet-chart-deployment-ref.metadata.json**
- Store the owners and path

```json
{
  "path": "openshift-hyperfleet/chart-deployment/openshift-hyperfleet-chart-deployment-ref.yaml",
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

### Job URLs and Monitoring

#### Finding Running Jobs

To find and monitor running jobs on Prow:
1. Navigate to the Prow dashboard: https://prow.ci.openshift.org/
2. Use the filter bar to search for specific jobs:
   - By job name: `periodic-ci-openshift-hyperfleet-hyperfleet-chart-main-deployment-hyperfleet-chart-deployment-nightly`
   - By status: Add `&state=pending` or `&state=success` or `&state=failure` to the URL
3. Click on any job to view detailed logs and execution information

### Triggering Jobs

#### Manual Trigger in Prow Dashboard

According to the above step, find the job, then click the button under **Rerun** to trigger the job.

#### Manual Trigger in a PR via GitHub Comment

If you want to add some new code for the CD workflow, you can prepare a PR and trigger the job in the PR with the changed code via comment:

```text
/pj-rehearse periodic-ci-openshift-hyperfleet-hyperfleet-chart-main-deployment-hyperfleet-chart-deployment-nightly
```

### Creating Additional Jobs

To add another job based on the existing CLM CD job:

1. **Copy the existing job configuration**: Update the following:
   ```yaml
   - as: hyperfleet-chart-deployment-nightly # job name
     cron: 30 8 * * * # cron time
     steps:
       env:
         <key>: <value>
       test:
       - ref: openshift-hyperfleet-chart-deployment # step/chain/workflow name
   ```

2. **Modify the job name and parameters**
   - Update the `name` field
   - Adjust `cron` schedule (for periodic jobs)
   - Modify environment variables as needed
   - Update step registry references if different

3. **Add the new job**

   Run the command to generate and update the job configuration:
   ```bash
   make jobs
   ```

4. **Submit a PR with the new job configuration**

### Debugging

#### Viewing Job Logs

1. Follow the [Finding Running Jobs](#finding-running-jobs) steps to locate the job
2. Click the job link to jump to the detailed job page
3. Click **Artifacts** to jump to the log page
4. Navigate to the folder: **artifacts/hyperfleet-chart-deployment-nightly/openshift-hyperfleet-chart-deployment/**
5. You can find the detailed resource logs under the **artifacts** folder
6. **The HyperFleet API external URL** is at the end of the build-log.txt:
```text
[1m19-01-2026T10:06:50  EXTERNAL-IP assigned: 34.28.116.174[0m
[1m19-01-2026T10:06:50  You can access hyperfleet-api via http://34.28.116.174:8000/api/hyperfleet/v1/clusters[0m
```

## CD Jobs Example PRs

- Initial CD jobs structure: [PR #73258](https://github.com/openshift/release/pull/73258)
- Enable the umbrella chart deployed steps to CD Prow job: [PR #73661](https://github.com/openshift/release/pull/73661)

## References

- [Prow Documentation](https://docs.ci.openshift.org/)
- [Step Registry Documentation](https://docs.ci.openshift.org/docs/architecture/step-registry/)
- [OpenShift HyperFleet Repository](https://github.com/openshift/release/tree/master/ci-operator/step-registry/openshift-hyperfleet)
