# Proposed Structure for Deprecated Documents

---
Status: Draft
Owner: HyperFleet Architecture Team
Last Updated: 2026-03-25
---

> Proposal for a consistent, discoverable structure for deprecated documentation across the HyperFleet architecture repository. The current state has deprecation handled inconsistently — this document proposes a unified approach.

---

## Current State

Deprecated documents are handled inconsistently across the repository:

| Location | Current Approach | Problem |
|----------|-----------------|---------|
| `hyperfleet/components/adapter/deprecated/` | Subdirectory per deprecated adapter, no top-level index (now added) | Folder naming is inconsistent (`deprecated-DNS`, `deprecated-PullSecret`, etc.) |
| `hyperfleet/mvp/` | MVP docs with `Status: Historical` | Not clearly marked as non-actionable for new work |
| Individual documents with `Status: Deprecated` | Header field only, no forwarding link | Reader must guess what replaced the document |

---

## Problems with Current Approach

1. **No consistent location**: Deprecated content is mixed into active directories or in ad-hoc `deprecated/` subdirectories.
2. **No forwarding**: Deprecated documents don't always link to what replaced them, leaving readers without a path forward.
3. **Inconsistent naming**: `deprecated-DNS` vs. `DNS-deprecated` vs. just setting `Status: Deprecated`.
4. **Discovery**: There is no index of what has been deprecated and why.
5. **Unclear retention policy**: It is not clear when deprecated documents can be removed vs. should be kept as historical record.

---

## Proposed Structure

### 1. Standard Deprecation Header

Every deprecated document MUST include a deprecation notice immediately after the standard metadata header:

```markdown
# Document Title

---
Status: Deprecated
Owner: HyperFleet Architecture Team
Last Updated: YYYY-MM-DD
---

**Deprecated**: YYYY-MM-DD
**Replaced By**: [Link to replacement document or directory](./path/to/replacement.md)

> ⚠️ **DEPRECATED**: This document is no longer active. [Brief reason — 1 sentence.]
> See [replacement](./path/to/replacement.md) for the current approach.

---
```

### 2. Centralized Deprecated Directory

All deprecated component-level documents move to a single top-level archive:

```
hyperfleet/
└── deprecated/               # NEW — single home for all deprecated content
    ├── README.md              # Index: what was deprecated, when, why, what replaced it
    ├── adapter-dns-gcp/       # Former: components/adapter/DNS-deprecated/
    ├── adapter-hypershift-gcp/ # Former: components/adapter/hypershift-deprecated/
    ├── adapter-maestro-cli/   # Former: components/adapter/maestro-cli-deprecated/
    ├── adapter-pullsecret-gcp/ # Former: components/adapter/PullSecret-deprecated/
    ├── adapter-validation-gcp/ # Former: components/adapter/validation-deprecated/
    └── mvp/                   # Former: hyperfleet/mvp/ (historical MVP scope docs)
```

**Naming convention for deprecated directories**: `<component>-<feature>[-<qualifier>]`
- No `deprecated-` prefix — the parent directory already signals deprecation
- Lowercase, hyphen-separated
- Include qualifier (e.g., cloud provider) only when meaningful

### 3. Forwarding Stubs in Original Locations

When a document or directory is moved to `deprecated/`, leave a short forwarding stub at the original path:

```markdown
# DNS Adapter (GCP)

---
Status: Deprecated — moved to archive
Last Updated: YYYY-MM-DD
---

> This content has been moved to [hyperfleet/deprecated/adapter-dns-gcp/](../../deprecated/adapter-dns-gcp/).
> See the [Deprecated Directory README](../../deprecated/README.md) for context.
```

This ensures that any existing internal links continue to reach a useful page.

### 4. Deprecation Index (deprecated/README.md)

A single README in `hyperfleet/deprecated/` tracks all deprecations:

```markdown
# Deprecated Documents

| Directory | What It Was | Deprecated | Reason | Replaced By |
|-----------|------------|------------|--------|-------------|
| `adapter-dns-gcp/` | GCP DNS adapter spike | 2025-12 | GCP-specific adapters out of core scope | GCP team repo |
| `adapter-maestro-cli/` | Maestro CLI integration | 2025-11 | Superseded by Maestro SDK | `components/adapter/maestro-integration/` |
| `mvp/` | MVP scope and working agreements | 2024-12 | MVP complete | `hyperfleet/architecture/` |
```

### 5. Retention Policy

| Document Type | Retention | Rationale |
|---------------|-----------|-----------|
| Spike reports (exploration, never implemented) | Keep indefinitely | Historical record; GCP team may reference |
| Design docs for replaced approaches | Keep 2 years after replacement | Context for why the current approach was chosen |
| MVP working agreements | Keep indefinitely | Historical record of team decisions |
| Docs replaced by a direct successor | Keep until successor is stable (6 months) | Then review for removal |

---

## Migration Plan

### Phase 1: Standardize Headers (Low effort, high impact)

For every document with `Status: Deprecated`:
1. Add `**Deprecated**: YYYY-MM-DD` field
2. Add `**Replaced By**: [link]` field (or note "No direct replacement — see [x]")
3. Add deprecation notice blockquote

### Phase 2: Create Central Directory

1. Create `hyperfleet/deprecated/` with `README.md` index
2. Move content from `adapter/deprecated/` subdirectories into `hyperfleet/deprecated/`
3. Move `hyperfleet/mvp/` content into `hyperfleet/deprecated/mvp/`
4. Leave forwarding stubs at original paths

### Phase 3: Fix Links

1. Re-run `./hack/linkcheck.sh` to identify broken links from the moves
2. Update cross-references from active documents to point to new locations
3. Verify no active documents depend on deprecated content (and if so, update them)

---

## What This Proposal Does NOT Change

- Documents with `Status: Active` that discuss historical decisions (e.g., the v1 Outbox Pattern section in glossary.md) — these are historical context within active documents, not deprecated documents.
- The `hyperfleet/standards/` directory — standards documents don't get deprecated; they get updated in-place or superseded by a new standard with a forwarding reference.
- The per-file `Status: Deprecated` convention — this is kept; the proposal adds structure around it, not replaces it.

---

## Open Questions

1. **Should the GCP-specific deprecated adapter docs move now, or wait until the GCP team has a dedicated repo?** Moving them now is cleaner but may create link churn.
2. **Should `hyperfleet/mvp/` content move to `hyperfleet/deprecated/mvp/` or stay in place with updated headers?** The current `Historical` status is already well-understood by the team.
3. **Who owns the deprecation index maintenance?** Proposal: Architecture Team, updated as part of any PR that deprecates a document.
