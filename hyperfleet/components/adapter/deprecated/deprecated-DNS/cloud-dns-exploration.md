---
Status: Deprecated
Owner: HyperFleet Adapter Team
Last Updated: 2026-01-27
---

# Exploring Cloud DNS Creation via Config Connector on OSD GCP Cluster

> Exploration document from the GCP DNS adapter spike, investigating Cloud DNS API capabilities and integration options. Deprecated since GCP specific adapters will be developed by GCP team and out of scope for the core HyperFleet repositories

---
## Summary of Exploration
Following the exploration of creating Google Cloud DNS resources using Config Connector, the key findings are as follows:
- The DNS CR status can partially reflect the creation result. See [Check DNS CR Status](#32-check-dns-cr-status) for details.
- DNS CRs can be applied in namespaces different from the one where the Config Connector operator is deployed. See [Option 1](#option-1-specify-the-project-via-annotation-on-each-resource) for details.

#### Considerations for Adapter Design
- **Multiple CRs in a Single Template**     
  The Cloud DNS creation process may require two CRs (DNSManagedZone and DNSRecordSet) to be defined within a single template. It should be confirmed whether the post-condition mechanism can support checking the status of both CRs simultaneously.
- **Dynamic Input Values**     
  The input parameters for DNSRecordSet may include dynamically generated values (e.g., random prefixes). The adapter should clarify whether YAML files can support dynamic values.

---

## 0. Overview
**[Config Connector](https://cloud.google.com/config-connector/docs/overview)** is an open source Kubernetes add-on that allows users to manage **Google Cloud resources** through Kubernetes. It enables declarative configuration and management of Google Cloud services via YAML manifests, similar to native Kubernetes resources.     
     
This document outlines the steps for using Config Connector to manage Google Cloud DNS resources on an OSD GCP cluster.

## 1. Prepare OSD GCP Cluster
The process involves configuring the GCP service account locally and then running [OCM backend tests](https://gitlab.cee.redhat.com/service/ocm-backend-tests/) to provision the cluster.

### 1.1 Configure the GCP service account locally on Mac
Visit [Google Cloud Console](https://console.cloud.google.com/projectselector2/iam-admin/serviceaccounts?supportedpurview=project), select the target project, create a service account key under `osd-css-admin` service account, the key will be downloaded locally
```
mkdir ~/.gcp

# cp this downloaded key file to ~/.gcp/osd-css-admin.json

# Execute gcloud auth
gcloud auth activate-service-account --key-file=/Users/dawang/.gcp/osd-ccs-admin.json 

# Set the active default project
gcloud config set project <PROJECT_ID>

# Set quota project 
gcloud auth application-default set-quota-project <PROJECT_ID>
```
### 1.2 Create OSD GCP cluster 
It supports to create and delete OSD GCP cluster through running `run_profile.py` in [OCM backend tests](https://gitlab.cee.redhat.com/service/ocm-backend-tests/)    
```
# Source token to grant OCM permission
source ocm_api_token

# Run run_profile.py to create OSD on GCP cluster
python run_profile.py --profiles osd-ccs-gcp-ad --env staging

# Remove the OSD on GCP cluster
python run_profile.py --profiles osd-ccs-gcp-ad --env staging --just-clean True
```

Related OCM API to get cluster status and credentials
```
# Get cluster status, credentials and login the OSD GCP cluster
ocm login --use-auth-code --url staging
ocm get /api/clusters_mgmt/v1/clusters/<cluster-id>/status
ocm get /api/clusters_mgmt/v1/clusters/<cluster-id>/credentials

# Get user and passowrd of admin from above return, then oc login
oc login https://api.xxxxx:6443 --username kubeadmin --password <Password>
```

## 2. Install Config Connector
Since the environment is an OSD GCP cluster rather than a GKE cluster, the installation follows [official guidance](https://cloud.google.com/config-connector/docs/how-to/install-other-kubernetes) for other Kubernetes distributions.

### 2.1 Creating an identity for Config Connector
```
# Ensure you have permission to create roles in the cluster (The result is yes)
kubectl auth can-i create roles

# Create an IAM service account.
gcloud iam service-accounts create <SERVICE_ACCOUNT_NAME, e.g., dawang-config-connector>

# Give the IAM service account elevated permissions on your project:
gcloud projects add-iam-policy-binding <PROJECT_ID> \
    --member="serviceAccount:<SERVICE_ACCOUNT_NAME, e.g., dawang-config-connector>@<PROJECT_ID>.iam.gserviceaccount.com" \
    --role="roles/owner"

# Generate a SA key and export its credentials to a file named key.json
gcloud iam service-accounts keys create --iam-account \
    <SERVICE_ACCOUNT_NAME, e.g., dawang-config-connector>@<PROJECT_ID>.iam.gserviceaccount.com key.json

# Applying the credentials to your cluster
# Create the cnrm-system namespace:
kubectl create namespace cnrm-system

# Import the key's credentials as a Secret.
kubectl create secret generic <SECRET_NAME, e.g., dawang-config-connector> \
    --from-file key.json \
    --namespace cnrm-system
```

### 2.2 Installing Config Connector Operator
```
# Download the latest Config Connector Operator tar file:
gcloud storage cp gs://configconnector-operator/latest/release-bundle.tar.gz release-bundle.tar.gz

# Extract the tar file:
tar zxvf release-bundle.tar.gz

# Install the Config Connector Operator on your cluster:
kubectl apply -f operator-system/configconnector-operator.yaml

# Resolve SCC (Security Context Constraints) Error
oc adm policy add-scc-to-user anyuid -z configconnector-operator -n configconnector-operator-system

# Verify if the Config Connector Operator work well
oc describe statefulset -n configconnector-operator-system
oc get pod -n configconnector-operator-system
NAME                         READY   STATUS    RESTARTS   AGE
configconnector-operator-0   1/1     Running   0          17h
```

### 2.3 Configuring Config Connector
Create a file named configconnector.yaml with the following content.
```
apiVersion: core.cnrm.cloud.google.com/v1beta1
kind: ConfigConnector
metadata:
  # the name is restricted to ensure that there is only ConfigConnector
  # instance installed in your cluster
  name: configconnector.core.cnrm.cloud.google.com
spec:
  mode: cluster
  credentialSecretName: <SECRET_NAME, e.g., dawang-config-connector>
  stateIntoSpec: Absent
```

Apply the configuration and resolve SCC errors.
```
kubectl apply -f configconnector.yaml

# Resolve SCC Errors for Config Connector Components
oc adm policy add-scc-to-user anyuid -z cnrm-controller-manager -n cnrm-system
oc adm policy add-scc-to-user anyuid -z cnrm-deletiondefender -n cnrm-system
oc adm policy add-scc-to-user anyuid -z cnrm-resource-stats-recorder -n cnrm-system
oc adm policy add-scc-to-user anyuid -z cnrm-webhook-manager -n cnrm-system

# Config Connector runs all of its components in a namespace named cnrm-system.
# Check if Config Connector work well
kubectl wait -n cnrm-system \
      --for=condition=Ready pod --all
```

## 3. Create Cloud DNS Using Config Connector
### 3.1 Setting Project Options for Cloud DNS Creation
Before creating resources with Config Connector, you must configure where to create your resources. Config Connector provides two options to determine where resources are provisioned. For more information, see [Organizing resources](https://cloud.google.com/config-connector/docs/how-to/organizing-resources/overview).

#### Option 1: Specify the Project via Annotation on Each Resource
```
apiVersion: dns.cnrm.cloud.google.com/v1beta1
kind: DNSManagedZone
metadata:
  name: dawang-anno-public-zone-dd  # Cloud DNS Zone name and k8s DNSManagedZone name 
  namespace: dawang-dns-test        # The namespace where k8s CR created
  annotations:
    cnrm.cloud.google.com/project-id: "<PROJECT_ID>" # Specify which project Cloud DNS resource created
spec:
  dnsName: "dawangannod.<subdomain>"
  description: "Managed by Config Connector dawang annotation testing"

---

apiVersion: dns.cnrm.cloud.google.com/v1beta1
kind: DNSRecordSet
metadata:
  name: www-dawang-a-record
  namespace: dawang-dns-test
  annotations:
    cnrm.cloud.google.com/project-id: "<PROJECT_ID>"
spec:
  name: "www.dawangannod.<subdomain>"
  type: "A"
  ttl: 300
  rrdatas:
    - "192.0.2.2"
  managedZoneRef:
    name: dawang-anno-public-zone-dd

```
This option allows you to apply the CRs in different namespaces since the project is explicitly defined in the annotations of the CR.

#### Option 2: Specify the Project via Namespace Annotation
Annotate the namespace once, so resources within it automatically map to that project.
```
kubectl create namespace dawang-resource

# When annotate your namespace, Config Connector creates resources in the corresponding project, folder or organization
kubectl annotate namespace \
    dawang-resource cnrm.cloud.google.com/project-id=<PROJECT_ID>
```

Create DNS resources in annotated namespace without specifying project annotations in CR.
```
apiVersion: dns.cnrm.cloud.google.com/v1beta1
kind: DNSManagedZone
metadata:
  name: dawang-anno-public-zone-dd
  namespace: dawang-resource
spec:
  dnsName: "dawangannod.<subdomain>."
  description: "Managed by Config Connector dawang annotation testing"

---

apiVersion: dns.cnrm.cloud.google.com/v1beta1
kind: DNSRecordSet
metadata:
  name: www-dawang-a-record
  namespace: dawang-resource
spec:
  name: "www.dawangannod.<subdomain>"
  type: "A"
  ttl: 300 
  rrdatas:
    - "192.0.2.2"
  managedZoneRef:
    name: dawang-anno-public-zone-dd
```

After `kubectl apply -f xx.yaml -n dawang-resource`, Config Connector will create resources in the project specified by the namespace annotations.

### 3.2 Check DNS CR Status
#### Example: Successful DNSManagedZone Status
```
status:
  conditions:
  - lastTransitionTime: "2025-10-29T05:49:12Z"
    message: The resource is up to date
    reason: UpToDate
    status: "True"
    type: Ready
  creationTime: "2025-10-29T05:49:11.959Z"
  managedZoneId: ....
  nameServers:
  - xxx-c1.googledomains.com.
  - xxx-c2.googledomains.com.
  - xxx-c3.googledomains.com.
  - xxx-c4.googledomains.com.
  observedGeneration: 2
```

#### Example: Successful DNSRecordSet Status
```
status:
  conditions:
  - lastTransitionTime: "2025-10-29T05:49:22Z"
    message: The resource is up to date
    reason: UpToDate
    status: "True"
    type: Ready
  observedGeneration: 1
```

#### Example: Failed DNSRecordSet Status
```
status:
  conditions:
  - lastTransitionTime: "2025-10-29T01:52:02Z"
    message: 'Update call failed: error applying desired state: summary: Error creating
      DNS RecordSet: googleapi: Error 400: Invalid value for ''entity.change.additions[wwwanno.dawang.<subdomain>][A].name'':
      ''wwwanno.dawang.<subdomain>'', invalid'
    reason: UpdateFailed
    status: "False"
    type: Ready
  observedGeneration: 1
```

### 3.3. Verify DNS Creation Manually in Google Cloud Console
Visit Google Cloud DNS in [Google Console](https://console.cloud.google.com/net-services/dns/zones?referrer=search&orgonly=true&supportedpurview=organizationId,folder,project) and verify:
- The DNS managed zone is created.
- The DNS record sets exist under the corresponding managed zone.

### 3.4. Delete DNS Resource
When deleting DNS resources, I found that the DNSManagedZone cannot be deleted if it still contains DNSRecordSet records. Tt failed with the following error.
```
status:
    conditions:
    - lastTransitionTime: "2025-10-29T07:33:46Z"
      message: 'Delete call failed: error deleting resource: [{0 Error when reading
        or editing ManagedZone: googleapi: Error 400: The resource named ''dawang-anno-public-zone-ee''
        cannot be deleted because it contains one or more ''resource records''., containerNotEmpty  []}]'
      reason: DeleteFailed
      status: "False"
      type: Ready
```
**Solution**
To successfully delete the DNS resources:
- Delete all associated DNSRecordSet objects first.
- Once all records have been removed, delete the corresponding DNSManagedZone.

This ensures that the managed zone is empty before removal, allowing Config Connector to delete it successfully.

## 4. Potential Issues and Resolutions
### 4.1 IAM_PERMISSION_DENIED Error When Creating a Service Account
```
gcloud iam service-accounts create dawang-config-connector
ERROR: (gcloud.iam.service-accounts.create) [osd-ccs-admin@<PROJECT_ID>.iam.gserviceaccount.com] does not have permission to access projects instance [itpc-gcp-hcm-pe-eng-claude] (or it may not exist): Permission 'iam.serviceAccounts.create' denied on resource (or it may not exist). This command is authenticated as osd-ccs-admin@<PROJECT_ID>.iam.gserviceaccount.com which is the active account specified by the [core/account] property.
- '@type': type.googleapis.com/google.rpc.ErrorInfo
  domain: iam.googleapis.com
  metadata:
    permission: iam.serviceAccounts.create
  reason: IAM_PERMISSION_DENIED
```
**Cause:**     
This happens because your active default project does not match the project where you are trying to create the service account.
     
**Resolution:**     
Update your local default project to the correct one using the following command:
```
# check the active default project
gcloud config list project

# If not correct, set correct one
gcloud config set project <PROJECT_ID>

# Set quota project 
gcloud auth application-default set-quota-project <PROJECT_ID>
```
### 4.2 SCC Error When Installing Config Connector on OSD GCP Cluster
When installing the **Config Connector Operator** or configuring **Config Connector** on an OSD GCP cluster, you may encounter an SCC (Security Context Constraint) error similar to the following.
```
failed error: pods "cnrm-controller-manager-0" is forbidden: unable to validate against any security context constraint: [provider "anyuid": Forbidden: not usable by user or serviceaccount, provider restricted-v2: .containers[0].runAsUser: Invalid value: 1000: must be in the ranges: [1001090000, 1001099999],
```
**Cause:**     
The Config Connector components require permissions to run containers with specific user IDs (runAsUser: 1000), which are restricted by the OpenShift SCC policies by default.
     
**Resolution:**     
Grant the necessary service accounts permission to use the anyuid SCC:
```
oc adm policy add-scc-to-user anyuid -z configconnector-operator -n configconnector-operator-system

oc adm policy add-scc-to-user anyuid -z cnrm-controller-manager -n cnrm-system

oc adm policy add-scc-to-user anyuid -z cnrm-deletiondefender -n cnrm-system

oc adm policy add-scc-to-user anyuid -z cnrm-resource-stats-recorder -n cnrm-system

oc adm policy add-scc-to-user anyuid -z cnrm-webhook-manager -n cnrm-system
```

## References
- https://cloud.google.com/config-connector/docs/how-to/install-other-kubernetes
- https://cloud.google.com/config-connector/docs/reference/resource-docs/dns/dnsmanagedzone
- https://cloud.google.com/config-connector/docs/reference/resource-docs/dns/dnsrecordset
- https://docs.cloud.google.com/config-connector/docs/how-to/organizing-resources/project-scoped-resources#annotate_resource_configuration
- https://docs.cloud.google.com/config-connector/docs/how-to/organizing-resources/project-scoped-resources#annotate_namespace_configuration
