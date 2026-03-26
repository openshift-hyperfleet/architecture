---
Status: Deprecated
Owner: HyperFleet Adapter Team
Last Updated: 2026-01-27
---

# SPIKE REPORT: Define DNS Adapter Requirements and Implementation Plan for GCP

> Spike report from the GCP DNS adapter investigation, documenting findings, challenges, and recommendations from the exploration. Deprecated since GCP specific adapters will be developed by GCP team and out of scope for the core HyperFleet repositories

---
> Note: This spike report is outdated due to the DNS adapter rescope described in HYPERFLEET-55. As a result, the focus has shifted from implementing DNS creation logic to developing a DNS placement adapter that supports DNS zone placement decisions.

---
> This spike report is a draft outlining a GCP DNS adapter that follows a workflow similar to the DNS creation process implemented for CS ROSA HCP.

---
## Metadata
**JIRA Story**: HYPERFLEET-60  
**Date**: December 3, 2025,  
---
Status: Outdated, the following spike report serves as a record of the DNS-related findings.
---
---

## 1. Executive Summary

This spike defines the implementation approach for a **GCP DNS adapter** that runs as part of the adapter framework to automate DNS infrastructure setup for GKE cluster provisioning. The solution leverages **Config Connector DNS Custom Resources** to create and manage Cloud DNS zones and records, following patterns proven in CS ROSA HCP DNS implementation.

### Candidate Solutions
- **Implementation Vehicle**: Config Connector DNS Custom Resources (DNSManagedZone, DNSRecordSet)
- **Deployment**: DNS adapter framework creates DNS CRs when cluster creation events occur
- **Architecture**: Declarative DNS management via Kubernetes CRs
- **Authentication**: Google Service Account (GSA) with cross-project IAM bindings (TBD after HYPERFLEET-253)
- **DNS Flow**: Create private zone → Create public zone → Get public zone nameservers → Add NS record to RH zone → Add CNAME records to customer public zone.

### Primary Risks
- Cross-project IAM permission complexity for DNS management across RH and customer projects
- GCP DNS workflow involves several DNS CRs, which follow a dependency chain. E.g., the public and private zones must be created first. Once the public zone becomes ready, its status.nameservers are used as input to create the NS record in the RH project. Supporting this workflow requires the adapter framework to provide `when` expression capabilities to enforce the correct creation order.

---

## 2. Clusters Service (CS) ROSA HCP DNS Workflow (Route53)
CS ROSA HCP creates the DNS infrastructure for each cluster using AWS Route53, involving both Red Hat managed zones and customer-owned zones. The workflow consists of four main steps:

```text
┌─────────────────────────────────────────────────────────────────┐
│                     CS ROSA HCP DNS Workflow                    │
└─────────────────────────────────────────────────────────────────┘

Step 1: Allocate Base Domain
   └─> Determines: <dnsBaseDomain> (e.g., <random str 4>.s3.devshift.org)

Step 2: Build Ingress Domain
   ├─> Public Zone Name:  rosa.<clusterName>.<dnsBaseDomain>
   ├─> Private Zone Name: rosa.<clusterName>.<dnsBaseDomain> (same)
   └─> Ingress Domain:    apps.rosa.<clusterName>.<dnsBaseDomain>

Step 3: Create Private Zone (Customer Account)
   ├─> Route53 Hosted Zone: rosa.<clusterName>.<dnsBaseDomain>
   ├─> Visibility: Private
   └─> VPC Association: Customer VPC

Step 4: Create Public Zone & Delegation (Customer + RH Accounts)
   ├─> 4.1 Create Public Hosted Zone (Customer Account)
   │   ├─> Name: rosa.<clusterName>.<dnsBaseDomain>
   │   └─> Visibility: Public
   │
   ├─> 4.2 Retrieve Public Zone Nameservers
   │   └─> AWS assigns NS records (e.g., ns-123.awsdns-45.com)
   │
   ├─> 4.3 Locate RH Shard Hosted Zone (RH Account)
   │   └─> Find base domain zone: <dnsBaseDomain>
   │
   ├─> 4.4 Add NS Delegation Record (RH Account)
   │   ├─> Name: rosa.<clusterName>.<dnsBaseDomain>
   │   ├─> Type: NS
   │   └─> Value: [nameservers from customer public zone]
   │
   └─> 4.5 Add CNAME Records (Customer Public Zone)
       ├─> ACME Challenge Record
       │   ├─> Name: _acme-challenge.apps.rosa.<clusterName>.<dnsBaseDomain>
       │   ├─> Type: CNAME
       │   └─> Value: _acme-challenge.<clusterName>.<dnsBaseDomain>
       │
       └─> Ingress CNAME Record
           ├─> Name: apps.rosa.<clusterName>.<dnsBaseDomain>
           ├─> Type: CNAME
           └─> Value: <clusterName>.<dnsBaseDomain>
```

---

## 3. GCP DNS Adapter Requirements
### 3.1 GCP DNS Adapter Workflow

The GCP DNS adapter follows a similar four-step workflow, adapted for Cloud DNS using config-connector:

```text
┌─────────────────────────────────────────────────────────────────┐
│                   GCP DNS Adapter Workflow                       │
└─────────────────────────────────────────────────────────────────┘

Step 1: Determine Base Domain
   └─> Output: <dnsBaseDomain> (placeholder: gcp-hcp.openshiftapps.com)

Step 2: Construct DNS Names
   ├─> Public Zone Name:  gcphcp.<clusterName>.<dnsBaseDomain>
   ├─> Private Zone Name: gcphcp.<clusterName>.<dnsBaseDomain>
   └─> Ingress Domain:    apps.gcphcp.<clusterName>.<dnsBaseDomain>

Step 3: Create Private Managed Zone (Customer GCP Project)
   ├─> DNSManagedZone CR: gcphcp.<clusterName>.<dnsBaseDomain>
   ├─> Visibility: private
   └─> VPC Networks: [customer-vpc-self-link]

Step 4: Create Public Zone & Delegation (Customer + RH Projects)
   ├─> 4.1 Create Public Managed Zone (Customer Project)
   │   ├─> DNSManagedZone CR: gcphcp.<clusterName>.<dnsBaseDomain>
   │   └─> Visibility: public
   │
   ├─> 4.2 Retrieve Public Zone Nameservers
   │   └─> Read from DNSManagedZone.status.nameServers
   │
   ├─> 4.3 Add NS Delegation Record (RH Project - CLM Project)
   │   ├─> DNSRecordSet CR in RH base domain zone
   │   ├─> Name: gcphcp.<clusterName>.<dnsBaseDomain>.
   │   ├─> Type: NS
   │   └─> rrdatas: [nameservers from customer public zone]
   │
   └─> 4.4 Add CNAME Records (Customer Public Zone)
       ├─> ACME Challenge CNAME
       │   ├─> Name: _acme-challenge.apps.gcphcp.<clusterName>.<dnsBaseDomain>.
       │   └─> Value: _acme-challenge.<clusterName>.<dnsBaseDomain>.
       │
       └─> Ingress CNAME
           ├─> Name: apps.gcphcp.<clusterName>.<dnsBaseDomain>.
           └─> Value: <clusterName>.<dnsBaseDomain>.
```

### 3.2 DNS Record Lifecycle Management

**Creation Only (MVP Scope)**:
- Adapter creates DNS resources during cluster provisioning
- No updates or deletions handled in MVP

**Deletion Considerations (Post-MVP)**:
- **Critical Constraint**: DNSManagedZone cannot be deleted if it contains DNSRecordSet records
- **Required Deletion Order**:
  1. Delete all DNSRecordSet CRs in the zone
  2. Wait for Config Connector to remove Cloud DNS records
  3. Delete DNSManagedZone CR
- **Error Handling**

---

## 4. DNS Resource Creation with Config Connector

### 4.1 Config Connector Overview

Config Connector enables declarative management of Google Cloud resources using Kubernetes Custom Resources. For DNS management, it provides two primary CRDs:

- **DNSManagedZone**: Represents a Cloud DNS managed zone
- **DNSRecordSet**: Represents DNS records within a managed zone

**Key Benefits**:
- Declarative configuration
- Built-in reconciliation and status reporting
- Kubernetes-native resource management
- Automatic retry and error handling

### 4.2 Project Specification Options

Config Connector supports two methods to specify the target GCP project for DNS resources:

#### Option 1: Per-Resource Annotation
```yaml
apiVersion: dns.cnrm.cloud.google.com/v1beta1
kind: DNSManagedZone
metadata:
  name: customer-public-zone
  namespace: dns-adapter
  annotations:
    cnrm.cloud.google.com/project-id: "customer-project-123"
spec:
  dnsName: "gcphcp.mycluster.gcp.devshift.org."
  visibility: public
```

**Use Case**: Adapter creates resources across multiple projects (customer + RH projects) from a single namespace.

#### Option 2: Namespace Annotation
```bash
kubectl annotate namespace dns-adapter \
  cnrm.cloud.google.com/project-id=customer-project-123
```

**Use Case**: All resources in the namespace default to the same project (requires separate namespaces for multi-project scenarios).

**MVP Decision**: Use **Option 1 (Per-Resource Annotation)** for flexibility in cross-project DNS management.

### 4.3 Examples for DNS Resource Creation

#### Example 1: Create Private Managed Zone (Customer Project)

**Purpose**: Provide private DNS resolution within the customer's VPC.

**DNSManagedZone CR**:
```yaml
apiVersion: dns.cnrm.cloud.google.com/v1beta1
kind: DNSManagedZone
metadata:
  name: gcphcp-mycluster-private-zone
  namespace: dns-adapter
  annotations:
    cnrm.cloud.google.com/project-id: "customer-project-123"
  labels:
    cluster-id: "mycluster-abc123"
    zone-type: "private"
spec:
  dnsName: "gcphcp.mycluster.gcp.devshift.org."
  description: "Private DNS zone for GCP HCP cluster mycluster"
  visibility: private
  privateVisibilityConfig:
    networks:
      # Customer VPC where GKE cluster will be deployed
      - networkRef:
          # If using external reference (VPC in different project):
          external: "projects/customer-project-123/global/networks/customer-vpc"
```

**Expected Status** (after successful creation):
```yaml
status:
  conditions:
    - lastTransitionTime: "2025-12-02T11:43:06Z"
      message: The resource is up to date
      reason: UpToDate
      status: "True"
      type: Ready
  creationTime: "2025-12-02T11:43:06.006Z"
  managedZoneId: xxxxx
  nameServers:
    - ns-gcp-private.googledomains.com.
  observedGeneration: 2
```
---

#### Example 2: Create Public Managed Zone (Customer Project)

**Purpose**: Provide public DNS resolution for cluster ingress endpoints.

**DNSManagedZone CR**:
```yaml
apiVersion: dns.cnrm.cloud.google.com/v1beta1
kind: DNSManagedZone
metadata:
  name: gcphcp-mycluster-public-zone
  namespace: dns-adapter
  annotations:
    cnrm.cloud.google.com/project-id: "customer-project-123"
  labels:
    cluster-id: "mycluster-abc123"
    zone-type: "public"
spec:
  dnsName: "gcphcp.mycluster.gcp.devshift.org."
  description: "Public DNS zone for GCP HCP cluster mycluster"
  visibility: public
```

**Expected Status** (after successful creation):
```yaml
status:
  conditions:
    - lastTransitionTime: "2025-12-02T11:43:07Z"
      message: The resource is up to date
      reason: UpToDate
      status: "True"
      type: Ready
  creationTime: "2025-12-02T11:43:06.951Z"
  managedZoneId: xxxxx
  nameServers:
    - ns-cloud-d1.googledomains.com.
    - ns-cloud-d2.googledomains.com.
    - ns-cloud-d3.googledomains.com.
    - ns-cloud-d4.googledomains.com.
  observedGeneration: 2
```

**Critical**: The `status.nameServers` field contains the Google-assigned nameservers required for Step 4.3.

---

#### Example 3: Add NS Delegation Record (RH Project - CLM Project for MVP)

**Purpose**: Delegate DNS queries from RH's base domain zone to the customer's public zone.

**Assumptions for MVP**:
- RH base domain zone `gcp.devshift.org` exists in the CLM deployment project
- Pre-existing DNSManagedZone: `gcp-devshift-org-base-zone`

**DNSRecordSet CR**:
```yaml
apiVersion: dns.cnrm.cloud.google.com/v1beta1
kind: DNSRecordSet
metadata:
  name: gcphcp-mycluster-ns-delegation
  namespace: dns-adapter
  annotations:
    cnrm.cloud.google.com/project-id: "rh-clm-project-456"  # RH project, not customer
  labels:
    cluster-id: "mycluster-abc123"
    record-type: "delegation"
spec:
  name: "gcphcp.mycluster.gcp.devshift.org."
  type: "NS"
  ttl: 300
  managedZoneRef:
    # Reference the RH base domain zone (must exist in rh-clm-project-456)
    name: gcp-devshift-org-base-zone
  rrdatas:
    # Nameservers from created customer's public zone
    - "ns-cloud-d1.googledomains.com."
    - "ns-cloud-d2.googledomains.com."
    - "ns-cloud-d3.googledomains.com."
    - "ns-cloud-d4.googledomains.com."
```

**Expected Status**:
```yaml
status:
  conditions:
    - lastTransitionTime: "2025-12-02T11:51:46Z"
      message: The resource is up to date
      reason: UpToDate
      status: "True"
      type: Ready
  observedGeneration: 1
```
---

#### Example 4: Add CNAME Records (Customer Public Zone)

**Purpose**: Create DNS aliases for ACME certificate validation and ingress routing.

##### ACME Challenge CNAME Record

**DNSRecordSet CR**:
```yaml
apiVersion: dns.cnrm.cloud.google.com/v1beta1
kind: DNSRecordSet
metadata:
  name: gcphcp-mycluster-acme-challenge
  namespace: dns-adapter
  annotations:
    cnrm.cloud.google.com/project-id: "customer-project-123"
  labels:
    cluster-id: "mycluster-abc123"
    record-type: "acme-challenge"
spec:
  name: "_acme-challenge.apps.gcphcp.mycluster.gcp.devshift.org."
  type: "CNAME"
  ttl: 300
  managedZoneRef:
    # Reference customer's public zone
    name: gcphcp-mycluster-public-zone
  rrdatas:
    - "_acme-challenge.mycluster.gcp.devshift.org."
```

##### Ingress CNAME Record

**DNSRecordSet CR**:
```yaml
apiVersion: dns.cnrm.cloud.google.com/v1beta1
kind: DNSRecordSet
metadata:
  name: gcphcp-mycluster-ingress-cname
  namespace: dns-adapter
  annotations:
    cnrm.cloud.google.com/project-id: "customer-project-123"
  labels:
    cluster-id: "mycluster-abc123"
    record-type: "ingress"
spec:
  name: "apps.gcphcp.mycluster.gcp.devshift.org."
  type: "CNAME"
  ttl: 300
  managedZoneRef:
    # Reference customer's public zone
    name: gcphcp-mycluster-public-zone
  rrdatas:
    - "mycluster.gcp.devshift.org."
```

**Expected Status** (for both records):
```yaml
status:
  conditions:
  - type: Ready
    status: "True"
    reason: UpToDate
    message: "The resource is up to date"
  observedGeneration: 1
```

---

## 5. Authentication and Authorization

**Current Status**: An authentication mechanism is **TBD** pending completion of **HYPERFLEET-253** (WIF Research and PoC).

**Note:** We use the simplest approach here—the **Google Service Account (GSA)** method for authentication. This approach will be refined or replaced based on HYPERFLEET-253 findings.

### 5.1 GSA Setup and IAM Roles

**Required GSA**: `hyperfleet-config-connector@<RH CLM Project>.iam.gserviceaccount.com`

**IAM Role Grants**:

**In RH CLM Project** (for NS delegation records):
```bash
gcloud projects add-iam-policy-binding rh-clm-project-456 \
  --member="serviceAccount:hyperfleet-config-connector@<RH CLM Project>.iam.gserviceaccount.com" \
  --role="roles/dns.admin"
```

**In Customer Project** (for zone and record creation):
```bash
gcloud projects add-iam-policy-binding customer-project-123 \
  --member="serviceAccount:hyperfleet-config-connector@<RH CLM Project>.iam.gserviceaccount.com" \
  --role="roles/dns.admin"
```

### 5.2 Config Connector Configuration

**ConfigConnector Resource** (in GKE cluster):
```yaml
apiVersion: core.cnrm.cloud.google.com/v1beta1
kind: ConfigConnector
metadata:
  name: configconnector.core.cnrm.cloud.google.com
spec:
  mode: cluster
  googleServiceAccount: "hyperfleet-config-connector@<RH CLM Project>.iam.gserviceaccount.com"
```

**Effect**: All Config Connector operations use this GSA for GCP API authentication.

---

## 6. Multi-Project Architecture and Trade-offs

The GCP DNS adapter spans multiple GCP projects, including the CLM deployment project, the management cluster project, and the customer project. As part of the workflow, an NS delegation record must be created in the Red Hat (RH) project. This step requires a DNS placement mechanism to decide which RH-managed zone will host the delegation.

GCP imposes default quotas of 10,000 managed zones per project and 10,000 RRsets per managed zone. To ensure the solution scales and avoids hitting these limits, a placement strategy is needed to select the appropriate managed zone.

**For the MVP, to keep the design simple and reduce complexity, we can use a single fixed managed zone in the RH project and defer dynamic placement logic to a later phase.**

---

## 7. MVP Scope - Happy Path of GCP DNS Setup

**Goal**: Prove the DNS adapter architecture works end-to-end with Config Connector for basic DNS zone creation and delegation.

**In Scope**:
- ✅ Create private DNS managed zone in customer project
- ✅ Create public DNS managed zone in customer project
- ✅ Retrieve public zone nameservers from CR status
- ✅ Create NS delegation record in RH CLM project zone
- ✅ Create ACME challenge CNAME record (basic)
- ✅ Create ingress CNAME record (basic)
- ✅ Monitor DNS CR statuses (Ready condition)
- ✅ Report DNS setup success/failure to adapter framework

**Out of Scope (Post-MVP)**:
- ❌ Base domain selection logic (use hardcoded `gcp.devshift.org`)
- ❌ Domain prefix uniqueness verification
- ❌ DNS resource deletion handling
- ❌ Multi-zone placement decision
- ❌ Organization-based base domain mapping
- ❌ Advanced error recovery and retry logic

**MVP Assumptions**:
- RH base domain zone (`gcp-devshift-org-base-zone`) already exists in CLM project
- Config Connector already configured with GSA authentication
- Customer project has granted `roles/dns.admin` to Config Connector GSA
- Customer VPC already exists (VPC self-link provided in cluster spec)

**MVP Deliverables**:
- [ ] DNS adapter configuration YAML (`dns-adapter-config.yaml`)
- [ ] DNS CR templates for 5 resources (2 zones + 3 records)
- [ ] Integration with adapter framework (event handling + CR creation logic)
- [ ] Status monitoring and result reporting
- [ ] Basic validation (DNS names end with `.`, required fields present)
- [ ] Integration testing with test GCP project
- [ ] Documentation (setup guide, DNS workflow diagram, troubleshooting)

**Success Criteria**:
- [ ] Adapter triggers on GCP cluster creation event
- [ ] All 5 DNS CRs created successfully
- [ ] Private zone associated with customer VPC
- [ ] Public zone nameservers retrieved and propagated to NS record
- [ ] NS delegation record created in RH CLM project zone
- [ ] All CRs reach `Ready=True` status within 10 minutes
- [ ] DNS resolution works end-to-end:
- [ ] Adapter reports success result to HyperFleet API with DNS metadata

---

## 8. MVP Acceptance Criteria

### Ticket: GCP DNS Adapter MVP - Config Connector-Based DNS Management

**DNS Resource Creation**:
- [ ] Adapter creates `DNSManagedZone` CR for private zone in customer project, CR reaches `Ready=True` status
- [ ] Adapter creates `DNSManagedZone` CR for public zone in customer project, CR reaches `Ready=True` status
- [ ] Adapter retrieves public zone nameservers from CR status, wait up to 5 minutes for nameservers to appear
- [ ] Adapter creates `DNSRecordSet` CR for NS delegation in RH CLM project zone with record data from public zone status.nameServers
- [ ] Adapter creates `DNSRecordSet` CR for ACME challenge CNAME, CR reaches `Ready=True` status
- [ ] Adapter creates `DNSRecordSet` CR for ingress CNAME, CR reaches `Ready=True` status

**Configuration and Integration**:
- [ ] GCP DNS Adapter configuration
  - DNS config (baseDomain, zone naming patterns, TTL, RH project config)
  - 5 CR templates (2 zones + 3 recordsets)
  - Configure DNS CR Dependencies
  - Extract cluster metadata (name, ID, projectID, VPC, region)
  - Precondition
  - Post-action
  - Status aggregation and reporting rules

**Status Monitoring and Reporting**:
- [ ] Adapter reports success to API when:
  - All 5 DNS CRs reach `Ready=True` status
  - Public zone nameservers successfully propagated to NS record
- [ ] Adapter reports failure to API when:
  - Any CR fails to create (K8s API error)
  - Any CR reaches `Ready=False` status (Config Connector error)
  - Timeout occurs before all CRs ready
  - Public zone nameservers not available within 5 minutes
- [ ] Result includes DNS metadata:
  - Private zone managed zone ID
  - Public zone managed zone ID
  - Public zone nameservers (array of 4 nameserver FQDNs)

**Validation and Testing**:
- [ ] Cross-project resource creation validated:
  - Private/public zones created in customer project
  - NS delegation record created in RH CLM project
  - Project IDs in CR annotations match expected targets
- [ ] Integration test with test GCP project:
  - Create test cluster spec with real GCP project ID and VPC
  - Trigger adapter with cluster creation event
  - Verify all 5 DNS CRs created and reach Ready status
  - Verify DNS zones visible in GCP Console (both projects)
  - Verify NS record visible in RH CLM project zone
- [ ] DNS resolution test

**Deliverables**:
- [ ] GCP DNS adapter configuration
- [ ] Integration test suite
- [ ] Documentation (setup, workflow, troubleshooting)
- [ ] Demo showing end-to-end DNS setup for test cluster

---

## 9. References
- [GKE Cluster Creation Automation Script with Config Connector Add-on Enabled](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/deployment/GKE/create-gke-cluster.sh)
- [Explore Cloud DNS Creation via Config Connector on OSD on GCP Cluster](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/components/adapter/DNS/GCP/cloud-dns-exploration.md)
- [DNS Build of CS ROSA HCP](https://gitlab.cee.redhat.com/service/uhc-clusters-service/-/blob/master/pkg/clusterprovisioner/acm/rosa/rosa_hcp_provision_job_dns.go)
- [DNS.md of CS ROSA HCP](https://gitlab.cee.redhat.com/service/uhc-clusters-service/-/blob/master/docs/rosa_hcp/DNS.md)
- [HyperShift DNS ADR](https://docs.google.com/document/d/18nnp2uqaXs2p20Ht90dw20m3GREOoE199x0aO02dRYc/edit?tab=t.0#heading=h.bupciudrwmna)
- [GCP HCP - DNS Management Proposal](https://docs.google.com/document/d/1xa_QQic8h2_n_fjpCuiLmQOal_9JOzvZO0PR1v9k8_s/edit?tab=t.0)
- [Cloud DNSManagedZone](https://docs.cloud.google.com/config-connector/docs/reference/resource-docs/dns/dnsmanagedzone?hl=en)
- [Cloud DNSRecordSet](https://docs.cloud.google.com/config-connector/docs/reference/resource-docs/dns/dnsrecordset?hl=en)
---
