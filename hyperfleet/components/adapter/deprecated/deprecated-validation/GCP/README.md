# Validation Adapter (GCP) — Deprecated

**Status**: Deprecated
**Owner**: HyperFleet Adapter Team
**Last Updated**: 2026-03-25
**Deprecated Since**: 2024-Q4

---

> This directory contains the spike report from the GCP cluster validation adapter investigation. This approach was deprecated in favor of the generic adapter framework.

## What Was Here

The GCP Validation adapter was an early investigation into implementing cluster creation prerequisite validation (quota checks, networking, policies) as a GCP-specific adapter with direct GCP API calls embedded in the adapter service code.

## Why It Was Deprecated

The GCP-specific adapter approach was replaced by the **HyperFleet Adapter Framework** — a config-driven framework where validation logic runs inside Kubernetes Jobs (not the adapter service process). The job-based approach:

- Isolates GCP-specific validation code inside Jobs with proper resource limits and timeout enforcement
- Follows the same pattern as all other adapter types (DNS, pull secret, control plane, etc.)
- Makes it easier to run, test, and update validation logic independently

## What Replaced It

- **Active design**: [`adapter/framework/`](../../framework/) — the current adapter framework design
- The Validation Adapter is one of the first-class adapter types in the active MVP scope (see `hyperfleet/architecture/architecture-summary.md`)

## Documents in This Directory

| File | Description |
|------|-------------|
| `gcp-validation-adapter-spike-report.md` | GCP cluster validation adapter spike findings |

These documents are preserved for historical context only.
