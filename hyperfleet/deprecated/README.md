---
Status: Historical
Owner: HyperFleet Architecture Team
Last Updated: 2026-10-15
---

# Deprecated Documents

> Central archive for all deprecated HyperFleet architecture documents. Content is preserved as historical record. Do not use these documents as the basis for new work — see the "Replaced By" column for current alternatives.

---

| Directory | What It Was | Deprecated | Reason | Replaced By |
|-----------|------------|------------|--------|-------------|
| `components/adapter/deprecated-DNS/` | GCP DNS adapter spike report | 2025-12 | GCP-specific adapters moved out of core HyperFleet scope (HYPERFLEET-55) | GCP team repo |
| `components/adapter/deprecated-hypershift/` | GCP HyperShift control plane adapter spike | 2025-12 | GCP-specific; superseded by current adapter framework | `components/adapter/framework/` + GCP team repo |
| `components/adapter/deprecated-maestro-cli/` | Maestro CLI-based integration strategy | 2025-11 | CLI approach superseded by Maestro SDK integration | Adapter authoring guide (`hyperfleet-adapter`) |
| `components/adapter/maestro-integration/` | Maestro SDK integration design (architecture deep dive, adapter integration spike, integration guide) | 2026-10 | Maestro transport removed from the adapter framework ([HYPERFLEET-1504](https://redhat.atlassian.net/browse/HYPERFLEET-1504)) and Maestro torn down from every environment ([HYPERFLEET-1507](https://redhat.atlassian.net/browse/HYPERFLEET-1507)) | Adapter authoring guide (`hyperfleet-adapter`) + desire-based delivery |
| `components/adapter/deprecated-PullSecret/` | GCP Pull Secret Service adapter DDR | 2025-12 | GCP-specific adapters moved out of core HyperFleet scope | GCP team repo |
| `components/adapter/deprecated-validation/` | GCP validation adapter spike report | 2025-12 | GCP-specific; superseded by current adapter framework | `components/adapter/framework/` + GCP team repo |
| `mvp/` | MVP scope and working agreements | 2024-12 | MVP complete | `hyperfleet/README.md` |
