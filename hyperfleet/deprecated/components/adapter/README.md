---
Status: Historical
Owner: HyperFleet Architecture Team
Last Updated: 2026-03-25
---

# Deprecated Adapters

> This directory contains spike reports, design documents, and exploration notes for adapter approaches that were investigated but not carried forward into the active adapter framework. Each subdirectory preserves the original work as a historical record.

---

## Why These Were Deprecated

Two distinct reasons drove deprecation across these directories:

1. **GCP-specific scope moved out of core HyperFleet** — Early spikes explored GCP-specific adapter implementations (DNS, validation, pull secrets, HyperShift control plane) directly in the core HyperFleet repositories. After HYPERFLEET-55 and subsequent scoping decisions, GCP-specific adapter implementations became the responsibility of the GCP team and are out of scope for the core `openshift-hyperfleet` repositories. The core repo now defines the adapter framework and Maestro integration patterns that GCP (and other cloud) teams build upon.

2. **Implementation approach superseded** — The Maestro CLI integration approach was replaced by the Maestro SDK integration, which provides a more robust programmatic interface without requiring a CLI binary in adapter jobs.

---

## Deprecated Directories

### `deprecated-DNS/`

**What it was**: Spike report for a GCP-specific DNS adapter that would create and manage Cloud DNS zones and records (DNSManagedZone, DNSRecordSet via Config Connector) as part of cluster provisioning.

**Why deprecated**: HYPERFLEET-55 rescoped the DNS work — the focus shifted from implementing DNS creation logic to a DNS placement adapter that supports DNS zone placement decisions. Additionally, GCP-specific adapter implementations moved out of core HyperFleet scope to be owned by the GCP team.

**Replaced by**: The DNS placement adapter concept within the active adapter framework. GCP-specific DNS creation is handled by the GCP team.

**Key document**: `gcp-dns-adapter-spike-report.md`

---

### `deprecated-hypershift/`

**What it was**: Spike report for a GCP-specific HyperShift control plane adapter that creates and manages HostedCluster CRs in a management cluster to provision OpenShift control planes on GCP.

**Why deprecated**: The GCP-specific HyperShift integration approach was superseded by the current adapter framework design. GCP-specific control plane provisioning is out of scope for core HyperFleet repositories.

**Replaced by**: The active adapter framework (`adapter/framework/`) and Maestro integration (`adapter/maestro-integration/`). GCP-specific provisioning is handled by the GCP team.

**Key document**: `hypershift-controlplane-adapter-spike.md`

---

### `deprecated-maestro-cli/`

**What it was**: Design documents for integrating HyperFleet adapters with Maestro using the Maestro CLI binary. Adapters would create Kubernetes Jobs containing the `maestro-cli` binary to submit and track work items in Maestro.

**Why deprecated**: The CLI-based integration approach was replaced by the Maestro SDK integration, which provides a programmatic Go interface without the overhead of embedding a CLI binary in adapter jobs. The SDK approach is more maintainable, testable, and idiomatic for Go services.

**Replaced by**: `adapter/maestro-integration/` — the current Maestro SDK-based integration design.

**Key documents**: `maestro-adapter-integration-strategy.md`, `maestro-cli-implementation.md`

---

### `deprecated-PullSecret/`

**What it was**: Detailed Design Review (DDR) for a GCP Pull Secret Service adapter that managed image registry pull secret lifecycle — storing credentials in GCP Secret Manager and provisioning Kubernetes secrets in the management cluster for HyperShift control plane access.

**Why deprecated**: GCP-specific adapter implementations moved out of core HyperFleet scope. Pull secret management for GCP-provisioned clusters is now the responsibility of the GCP team.

**Replaced by**: GCP team implementation. The adapter framework patterns documented in `adapter/framework/` apply to any adapter the GCP team builds, including pull secret management.

**Key document**: `pull-secret-service-ddr.md`

---

### `deprecated-validation/`

**What it was**: Spike report for a GCP-specific cluster validation adapter that ran as a Kubernetes Job to validate GCP prerequisites (quota, APIs enabled, IAM, WIF configuration) before cluster provisioning.

**Why deprecated**: The GCP-specific validation approach was superseded by the current validation adapter design within the adapter framework. GCP-specific validation logic is out of scope for core HyperFleet repositories.

**Replaced by**: The validation adapter within the active adapter framework. GCP-specific validation is handled by the GCP team.

**Key document**: `gcp-validation-adapter-spike-report.md`

---

## Do These Documents Still Have Value?

Yes — as historical records. They document:

- What was explored and why certain approaches were considered
- Technical details of GCP-specific provisioning flows (DNS, WIF, HostedCluster CRs) that the GCP team may reference
- The reasoning behind the Maestro CLI → SDK decision
- Patterns and risks that informed the current adapter framework design

Do not use these documents as the basis for new adapter implementations. Use the active adapter framework documentation in `adapter/framework/` and `adapter/maestro-integration/` instead.
