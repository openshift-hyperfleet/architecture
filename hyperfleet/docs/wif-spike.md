---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2025-12-19
---

# Workload Identity Federation

## Overview

> Spike report investigating Workload Identity Federation (WIF) for authenticating HyperFleet services to GCP APIs without long-lived service account keys. Documents WIF capabilities, integration approach with GKE workloads, and recommendations for adoption in HyperFleet's GCP adapter deployments.

---

## Problem statement

We need to provide a secure way to access customer's cloud infrastructure from several Hyperfleeet components.

There are different use cases requiring permissions:
- Hyperfleet components (Task Adapters, e.g a k8s job) accessing customer's GCP project to verify things
- Hyperfleet components (Sentinel, Adapter) accessing Hyperfleet GCP resources like PubSub
- Hypershift Operator component accessing customer's GCP project to build infrastructure

Note that the second use case is the same as the first one but considering HYPERFLEET as being the CUSTOMER.

Challenges:
- Obtain customer credentials, or make customer to authorize an identity in our side with permissions
- Align with Hypershift Operator solution to provide a seamless experience for customers
- Ideally, design a solution that can be used in other cloud providers


## TL;DR; solution using Workload Identity Federation for GKE

Workload Identity Federation has been evolving over the years and different approaches are explained in Google's documentation. Here is the simplest solution that fits Hyperfleet use cases.

- A customer has their infrastructure in `CUSTOMER_PROJECT_NAME` GCP project
- A customer creates a HostedCluster with name `HOSTEDCLUSTER_NAME`
- An adapter task runs wants to access customer infrastructure for the `HOSTEDCLUSTER_NAME` HostedCluster
  - It runs in a GKE cluster for the Regional setup
  - In a GCP project with 
     - GCP project name `HYPERFLEET_PROJECT_NAME`
     - GCP project number `HYPERFLEET_PROJECT_NUMBER`
  - In a namespace named `HOSTEDCLUSTER_NAME`
  - With a Kubernetes Service Account named `HOSTEDCLUSTER_NAME`
- For the example, let's say the adapter requires `pubsub.admin` permissions

The customer will have to run this gcloud command to grant permissions (or via API):

```
gcloud projects add-iam-policy-binding  projects/CUSTOMER_PROJECT_NAME \
  --role="roles/pubsub.admin" \
  --member="principal://iam.googleapis.com/projects/HYPERFLEET_PROJECT_NUMBER/locations/global/workloadIdentityPools/HYPERFLEET_PROJECT_NAME.svc.id.goog/subject/ns/HOSTEDCLUSTER_NAME/sa/HOSTEDCLUSTER_NAME" --condition=None 
```

### Q&A

**Question: How does it work for the first use case where there is no customer involved?**  
In that case `CUSTOMER_PROJECT_NAME == HYPERFLEET_PROJECT_NAME` and we grant permissions to the same GCP project that hosts all Hyperfleet infrastructure.

**Question: Do the namespace and Kubernetes Service Account names have to be the same HOSTEDCLUSTER_NAME?**  
No, this is TBD, we simplified this for the example
This makes the assumption that Adaptor Tasks will run each in a namespace named after `HOSTEDCLUSTER_NAME`

**Question: Does the kubernetes namespace + service account need to exist before the permissions are granted?**  
No, it is not required. 

The customer only need the names to grant the permissions.

**Question: Why using `HOSTEDCLUSTER_NAME` instead of `HOSTEDCLUSTER_ID` ?**  
The permission grant occurs before the creation of the HostedCluster, even before the `spec` is stored in our Hyperfleet API, and we need an id.

Implication -> **Hosted Cluster names have to be unique per Hyperfleet Region**

An alternative is having the customer trust all workloads in the Hyperfleet Regional cluster, regardless of namespace+service account ([docs](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/workload-identity#kubernetes-resources-iam-policies)). Another doc describing [GCP principal identifiers](https://docs.cloud.google.com/iam/docs/principal-identifiers#allow)

But is good to have a namespace+ksa per customer, in case a token is leaked, only that customer is exposed

**Does the customer need to create a Workload Identity Pool and a Provider?**  
No, setting IAM permissions to a `principal` following the naming conventions is everything that is required on their side.

**Question: the name/Id of the Hyperfleet Regional cluster is not specified when granting permissions, why?**
All GKE clusters share the same Workload Identity Pool. Any cluster in `HYPERFLEET_PROJECT_NAME` with a workload running in a namespace+ksa named `CLUSTER_NAME` will have the granted permissions.

**Question: can access be restricted in a more fine grained way?**

First, we can use `add-iam-policy-binding` directly on resources. E.g. we can apply it on a specific existing topic.

We can also use the `--condition` parameter can be used to evaluate the permission.

e.g. limit access to topics that have a project tag "purpose" with value "hyperfleet"

```
gcloud projects add-iam-policy-binding  projects/CUSTOMER_PROJECT_NAME \
  --role="roles/pubsub.admin" \
  --member="principal://iam.googleapis.com/projects/HYPERFLEET_PROJECT_NUMBER/locations/global/workloadIdentityPools/HYPERFLEET_PROJECT_NAME.svc.id.goog/subject/ns/HOSTEDCLUSTER_NAME/sa/HOSTEDCLUSTER_NAME"     --condition=^:^'expression=resource.matchTag("CUSTOMER_PROJECT_NAME/purpose", "hyperfleet"):title=hyperfleet-tag-condition:description=Grant access only for resources tagged as purpose hyperfleet'
``` 

note:
- GCP tags are different from labels)
- Specifying some conditions is tricky when using gcloud
  - tag names require to be prefixed with  `CUSTOMER_PROJECT_NAME/`
  - since the condition contains a `,` we need to specify another separator for condition properties using the syntax `^:^`


**Question: If Hyperfleet moves to another GCP project, does the customer need to re-grant permissions?**
Yes, since permissions are associated to a pool with HYPERFLEET_PROJECT_NAME, if that changes, the customer needs to grant permissions to the new Workload Identity Pool.

Note that this is similar to having a Google Service Account as identity, since it will also be associated with a GCP project.

**Question: Do we need to annotate Kubernetes Service Accounts or create Google Service Accounts?**
No. We are using "Workload Identity Federation for GKE" note the suffix "for GKE

In the past, it was required to have a Google Service Account created and then associate the Kubernetes Service Account with it using annotations in the descriptor.



**Question: If I have two Hyperfleet clusters in the same GCP project, with the same namespace name and same Kubernetes Service Account name.... do they really share customer permissions?**

Yes, that is named "identity sameness", it is explained also in GCP documentation: https://docs.cloud.google.com/kubernetes-engine/docs/concepts/workload-identity#identity_sameness

As with the `HOSTEDCLUSTER_NAME` discussion before, there are other `principals` that can be used for identity, or we can set `conditions` to make it more fine grained.


**Do I need to configure the Google Cloud SDK in any special way?**  
No, the SDK will recognize the Google identity automatically when running in the pod


## Alternative 1: Current GCP team approach for Hypershift Operator

The current approach by GCP team for Hypershift Operator in their PoC is a temporal solution sharing customer generated credentials. 

- Customer's use a Hypershift provided CLI tool to:
  - Create a private_key/public_key credentials pair
  - Upload the public key to the customer's Workload Identity Pool 
    - In the customer's GCP project that will host the worker nodes
  - Grant permissions in the customer's GCP project to certain kubernetes service accounts in the customer HostedCluster to be created
    - This step only requires the name of the customer_k8s_sa (to be created later)
    - As an example: `"principal://iam.googleapis.com/projects/[HYPERFLEET_MANAGEMENT_CLUSTER_GCP_PROJECT_NUMBER]/locations/global/workloadIdentityPools/[HYPERFLEET_MANAGEMENT_CLUSTER_GCP_PROJECT_NAME].svc.id.goog/subject/system:serviceaccount:[NAMESPACE]:[K8S_SERVICE_ACCOUNT]"`
  - Transfer the private_key to the Hypershift Operator leveraging CLM
    - CLM API accepts the private_key as part of the cluster.spec
    - CLM will transfer the private_key to HO using the "maestro adapter"
    - The HO will create a HostedCluster control plane that will use the provided private_key
    - Creates k8s_sa in the HostedCluster 
    - The HostedCluster will sign tokens for these k8s_sa using the provided private_key
  - The k8s_sa signed tokens have to be used by some HO component that live outside the HostedCluster
     - GCP team has developed a "minter" application that retrieves tokens from the HostedCluster
     - This is possible since HO has access to the kubeconfig for the HostedCluster

Pros:
- Each customer GCP project trust a different private_key/public_key, specific for the customer
  - No single Provider managed identity (or credential) has access to multiple customer projects
  - Still, access to all customer's infrastructure is possible since the ManagementCluster has access to all HostedClusters, so leaking those credentials would mean exposing all customers

Cons:
- Managing private_key/public_key lifecycle is challenging
  - Generating them 
  - Where to store them
  - Transfering them to HO through CLM
  - Rotating the credentials

### Suitability of this approach for CLM components

CLM can leverage the proposed mechanism but it comes with many challenges.
- Enable an API endpoint to accept the private_key (or have it in the `cluster.spec`)
  - An alternative is that a CLM component will create the private_key/public_key so it doesn't have to be transmitted from the customer
- Store the private_key securely
- Retrieve the private_key from the adapters that require it
- Create a signed token per request

For Hypershift Operator, the component that stores the key and signs tokens is the HostedCluster

Pros:
- No changes to the existing UX for the customer. They will leverage the CLI to drive the process


## Alternative 2: Workloads requiring access to customer infrastructure runs on Management Clusters

The adapter tasks are owned by provider teams (GCP, ROSA, etc...).  One approach to avoid access to customer infrastructure from CLM is to run the tasks in the Management Clusters.

This way, provider teams are more autonomous on how to solve security when accessing customer resources. One team can decide to use cloud IAM, and another to manage their own private/public keys.

This solution requires a method to run tasks in the Management Clusters, e.g. using Maestro or having access to MC kubeconfig.

This removes the need to deal with customer resources access from CLM components.



## Exploring Workload Identity Federation

Some explanation results when using Workload Identity Federation for GKE

1. Create a Kubernetes Namespace and Service Account
```
NAME=myname
kubectl create namespace $NAME
kubectl create serviceaccount $NAME -n $NAME
```


2. Create a pod with gcloud in a cluster running with the created Service Account in the namespace

<details>
<summary>gcloud-sdk-deployment.yaml</summary>

```
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gcloud
  namespace: $NAME
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gcloud
  template:
    metadata:
      labels:
        app: gcloud
    spec:
       serviceAccountName: $NAME
      containers:
      - name: gcloud
        image: google/cloud-sdk:slim
        command: ["/bin/sh", "-c", "--"]
        args: ["while true; do sleep 30; done;"]

EOF
```
</details>

2. Getting the Google identity associated to the pod

```
kubectl exec -ti $POD -- gcloud auth list

Credentialed Accounts
ACTIVE  ACCOUNT
*       PROJECT_NAME.svc.id.goog
```

All GKE cluster in a GCP project with Workload Identity enabled use the same Workload Identity Pool named `PROJECT_NAME.svc.id.goog`. This is a Google managed Identity Pool that is not visible in the GCP console.

For example, for the GCP project `hcm-hyperfleet` the identity pool is `hcm-hyperfleet.svc.id.goog` and can be checked with the command:

```
gcloud iam workload-identity-pools describe hcm-hyperfleet.svc.id.goog  --location=global --project hcm-hyperfleet

name: projects/275239757837/locations/global/workloadIdentityPools/hcm-hyperfleet.svc.id.goog
state: ACTIVE
```

But it can not be found when listing other Workload Identity pools that are usually used for external identity federation like AWS or Azure

```
gcloud iam workload-identity-pools list  --location=global --project hcm-hyperfleet

Listed 0 items.
```

Note: Even if all clusters in a GCP project are destroyed, the Workload Identity Pool managed by Google remains.

4. Auth tokens

GKE automatically injects tokens in the file system at `/var/run/secrets/kubernetes.io/serviceaccount/token`, let's explore the contents with the (jwt-cliL[https://github.com/mike-engel/jwt-cli]) utility to decode the JWT 

```
kubectl exec -ti $POD -- cat /var/run/secrets/kubernetes.io/serviceaccount/token \
xargs jwt decode
```

<details>
<summary>Contents of JWT token</summary>

```
Token header
------------
{
  "alg": "RS256",
  "kid": "wzQEgawE7XtHecI3Ob1Wy_ucMaUDmIdr6JUSueVqFYA"
}

Token claims
------------
{
  "aud": [
    "https://container.googleapis.com/v1/projects/hcm-hyperfleet/locations/us-central1-a/clusters/hyperfleet-dev"
  ],
  "exp": 1796970676,
  "iat": 1765434676,
  "iss": "https://container.googleapis.com/v1/projects/hcm-hyperfleet/locations/us-central1-a/clusters/hyperfleet-dev",
  "jti": "ff08f939-8e17-4ff0-8ebf-c0ed4012cc24",
  "kubernetes.io": {
    "namespace": "amarin",
    "node": {
      "name": "gke-hyperfleet-dev-default-pool-78e4bad4-882j",
      "uid": "e85d0fce-d62c-46b8-87f7-6bca42909d26"
    },
    "pod": {
      "name": "gcloud-66b75ff5dc-c8zqr",
      "uid": "d4202860-0f9d-4c81-8a25-559de58b5c01"
    },
    "serviceaccount": {
      "name": "gcloud-ksa",
      "uid": "8c1869ef-b894-46ee-8b88-548cb1509cf1"
    },
    "warnafter": 1765438283
  },
  "nbf": 1765434676,
  "sub": "system:serviceaccount:amarin:gcloud-ksa"
}
```
</details>

Some of these assertions in the JWT token can be used to set conditions to limit for example to a single cluster

References:

A note of caution. The are multiple scattered references for Workload Identity, Workload Identity Federation and Workload Identity Federation for GKE. Each may have subtle differences


- Workload Identity Federation for GKE: https://docs.cloud.google.com/kubernetes-engine/docs/how-to/workload-identity#authenticating_to
- Workload Identity Sameness: https://medium.com/google-cloud/solving-the-workload-identity-sameness-with-iam-conditions-c02eba2b0c13




