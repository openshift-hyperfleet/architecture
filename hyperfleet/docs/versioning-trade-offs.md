---
Status: Pending
Owner: HyperFleet Architecture Team
Last Updated: 2025-10-30
---

# HyperFleet Versioning Trade-offs (Post-MVP)

## 1. Overview

This document captures versioning strategies and policies that are **intentionally out of scope for MVP**. The content here represents good practices and future considerations that may be adopted as HyperFleet matures.

**Why separate this content?**
- Reduces MVP complexity and scope
- Preserves research and design work for future reference
- Provides clear roadmap for post-MVP improvements
- Prevents scope creep during initial implementation

**What's included:**
- SDK versioning and auto-generation
- API support policies and deprecation windows
- Database migration and rollback procedures

## *Versioning considerations that are OUT OF SCOPE for MVP but may be adopted in future iterations*
---

## 2. SDK Versioning (Post-MVP)

**Status:** Out of scope for MVP

**Overview:** The HyperFleet Go SDK would be auto-generated from an OpenAPI 3.0 specification using `oapi-codegen`. The SDK would be consumed by Sentinel and adapters to interact with the HyperFleet API.

### Why MVP doesn't need this

**For MVP, internal services can:**
- Import API client code directly from the API repository
- Use hand-written HTTP clients
- Generate client code locally without publishing a standalone SDK

**Example:**
```go
// Sentinel imports API client directly
import "github.com/openshift-hyperfleet/hyperfleet-api/pkg/client"

// Or uses simple HTTP client
resp, err := http.Post(apiURL+"/v1/clusters", "application/json", body)
```

### Future SDK Strategy

When external partners need programmatic access, we would publish a standalone SDK with the following versioning strategy:

**SDK Semantic Versioning:**
- **MAJOR**: Breaking changes to generated code or wrapper APIs, tied to API MAJOR version
- **MINOR**: New features in wrapper layer, spec updates that add new endpoints/optional fields
- **PATCH**: Bug fixes in wrapper layer, no spec or generated code changes

**SDK MAJOR version = API MAJOR version it supports**
- SDK v1.x.x → works with API v1 only
- SDK v2.x.x → works with API v2 only
- SDK v3.x.x → works with API v3 only

**Rationale:** Tying SDK MAJOR to API MAJOR provides clear signal about compatibility. Consumers know SDK v2.x.x is designed for API v2.

### OpenAPI Spec Versioning

**Spec is source of truth:**
- Spec changes → SDK regeneration required (generated code changes)
- SDK can advance without spec changes (wrapper-only bug fixes)
- Example: Spec v1.2.0 → SDK v1.5.0. Wrapper fix → SDK v1.5.1. Spec v1.3.0 → SDK v1.6.0.

**Version format:** Spec uses semantic versioning to track API contract changes. SDK version advances for both spec changes and wrapper improvements.

### Auto-Generation Strategy

**Trigger:** SDK regeneration happens automatically when OpenAPI spec changes

**Process:**
1. OpenAPI spec updated in repository
2. CI/CD pipeline detects spec change
3. Run `oapi-codegen` to regenerate base client code
4. Run tests to verify generated code + wrapper layer
5. Commit generated code to git (technical debt: larger repo size, but easier consumption)
6. Tag new SDK version and publish
7. Publish to pkg.go.dev for documentation

**Manual triggers:** Can also trigger regeneration manually for wrapper-only changes

**Why commit generated code?** Makes SDK easier to consume (no generation step required), follows precedent from existing OCM SDK.

### Go Modules and Import Paths

**Package publishing:**
- Published as Go module: `github.com/openshift-hyperfleet/hyperfleet-sdk-go`
- Semver git tags: `v1.2.3`, `v2.0.0`, etc.
- Published to pkg.go.dev for documentation

**Import path versioning:**
Breaking changes (MAJOR bumps) require new import paths following Go modules convention:
- SDK v1.x.x: `import "github.com/openshift-hyperfleet/hyperfleet-sdk-go"`
- SDK v2.x.x: `import "github.com/openshift-hyperfleet/hyperfleet-sdk-go/v2"`
- SDK v3.x.x: `import "github.com/openshift-hyperfleet/hyperfleet-sdk-go/v3"`

This allows consumers to gradually migrate to new SDK versions without forced upgrades.

---

## 3. API Support Policy and Deprecation (Post-MVP)

**Status:** Out of scope for MVP

**Overview:** Formal support windows and deprecation policies are not enforced for MVP. The API will remain at v1 until product-market fit is established.

### Future Support Policy

**Hybrid support window**: Each deprecated version (N-1) would be supported for **6 months after the next version launches OR until N+1 version launches, whichever comes FIRST**.

**Examples:**
- v2 launches January 2026 → v1 supported until July 2026 OR v3 launch (if v3 launches before July)
- v3 launches March 2026 (2 months after v2) → v1 sunsets March 2026 (N+1 launch triggers sunset)
- v3 launches December 2026 (11 months after v2) → v1 sunsets July 2026 (6 month limit)

**Note:** Major API versions are expected to be extremely rare (measured in years, not months). The 6-month cap ensures we don't run dual deployments indefinitely while still providing ample migration time for these infrequent transitions.

### Stability Requirements Before Deprecation

**New version must be stable before old version deprecation begins:**

The new major version (e.g., v2.0.0) must meet stability criteria before the previous version (v1) enters its deprecation window:

**"Stable and feature-complete" means:**
- All planned features for the new version are implemented
- No known critical bugs in the new version
- Integration tests passing consistently
- At least **3 months of production usage** OR **v2.1.0 release** (whichever comes first)

**Timeline example:**
```
Month 0:  API v2.0.0 launches (beta/early access)
Month 3:  v2.0.0 considered stable (3 months production usage)
Month 3:  v1 deprecation begins, 6-month sunset window starts
Month 9:  v1 sunset date (6 months after deprecation began)
```

**Or with rapid iteration:**
```
Month 0:  API v2.0.0 launches
Month 1:  v2.1.0 releases (proves stability through iteration)
Month 1:  v1 deprecation begins, 6-month sunset window starts
Month 7:  v1 sunset date
```

**Rationale:** Forcing partners to migrate from stable v1 to unstable v2 is poor developer experience. The new version must prove itself before the old version is deprecated.

**What "supported" would mean:**
- API endpoints remain **available and functional**
- API receives **critical security fixes only**
- **No new features** added to deprecated versions
- **No bug fixes** for non-critical issues
- Full support only for current version (N)

**Key principle:** Deprecated versions remain accessible for up to 6 months but are in **maintenance mode** - no active development, only critical fixes.

### Deprecation Communication (Future)

**HTTP Headers** (in-band, automated):
```
Deprecation: true
Sunset: Sat, 31 Jul 2026 23:59:59 GMT  # 6 months from v2 launch OR v3 launch date, whichever is earlier
Link: <https://docs.hyperfleet.io/api/migration/v1-to-v2>; rel="sunset"
```

**Documentation & Changelog**:
- Prominent warnings in API documentation
- Detailed migration guides for each version transition
- Clear "DEPRECATED" markers in changelog

**Partner Communication**:
- Email notifications when new major version launches with concrete sunset date
- Regular reminders about upcoming sunset (3 months before, 1 month before, 1 week before)
- Developer newsletter if available
- Example: "API v2 launched January 2026. API v1 is now deprecated and will sunset July 31, 2026 (6 months) unless v3 launches earlier. Please migrate to v2."

**Response Warnings** (optional):
```json
{
  "data": {...},
  "warnings": ["API v1 is deprecated and will sunset on July 31, 2026. Please migrate to v2."]
}
```

---

## 4. Database Migration and Rollback Procedures (Post-MVP)

**Status:** Out of scope for MVP

**Overview:** Formal migration and rollback procedures are not required for MVP. Database schema will be managed with forward-only migrations, but comprehensive rollback procedures can wait until production scale.

### Future Migration Policy: Forward-Only

**Policy:** HyperFleet would use **forward-only migrations** - all schema changes move forward in time.

**What this means:**
- Only `.up.sql` migration files (no `.down.sql` files)
- Rollbacks achieved through **compensating migrations** (new `.up.sql` that undoes previous change)
- Migration history always moves forward
- Explicit control over every schema change

**Example: Forward-only rollback**
```bash
# Initial migration adds column
1730556789_add_state_column.up.sql

# Later, need to "rollback" (remove the column)
# Create NEW forward migration:
1730643201_remove_state_column.up.sql  # Compensating migration
```

**Why forward-only?** Running migrations backwards in production is extremely rare and risky. Forward-only migrations provide explicit history, prevent accidental data loss, eliminate `.down.sql` sync issues, and require full review for rollbacks. Trade-off: local development is slower and rollbacks require manual compensating migrations, but production safety is worth it.

### Database Schema Versioning Strategy

**Golden Rule: Support N and N-1 During Deprecation Window**

**Critical principle:** Database schema MUST support both the current API MAJOR version (N) and the previous API MAJOR version (N-1) during the deprecation window (up to 6 months).

**What this means:**
- When API v2.0 launches (Jan 2026), API v1.x is supported until sunset (July 2026 or v3 launch, whichever first)
- Database must have fields/tables needed by BOTH v1 and v2 during this window (up to 6 months)
- Can remove old schema elements after v1 sunset date (July 2026)

**Enforcement:**
- **No automated enforcement** - This requires engineering discipline
- **Code review** - Reviewers must verify schema changes don't break N-1
- **Testing** - CI should run both API v1 and v2 against the same database
- **Documentation** - Maintain schema compatibility matrix

**The rule in practice:**
- **DON'T:** Remove `status` column when launching API v2 (v1 still needs it)
- **DON'T:** Rename `old_field` to `new_field` (breaks v1 instantly)
- **DON'T:** Change column types in place (breaks existing API version)
- **DO:** Add new `state` column alongside existing `status` column
- **DO:** Wait for v1 sunset before removing old fields
- **DO:** Use expand-contract pattern for all breaking changes

### Expand-Contract Pattern for API N-1 Support

**Problem:** API v1 and v2 run simultaneously during N-1 support period

**Solution:** Three-phase database migrations

**Phase 1: Expand** - Add new schema elements without removing old ones
- Add new columns/tables alongside existing ones
- Populate new columns from existing data
- Both API versions work simultaneously (v1 uses old schema, v2 uses new schema)

**Phase 2: Migrate** - Transition period (both old and new schema exist)
- API v2 writes to both old and new schema elements for backwards compatibility
- Monitor for API v1 traffic
- Wait for v1 sunset date (6 months after v2 launch OR v3 launch, whichever first)

**Phase 3: Contract** - Remove old schema elements
- After API v1 sunset, remove old columns/tables
- Clean up backwards compatibility code

### Service Rollback Procedure

**Scenario:** Bad HyperFleet API deployment in production

**Approach:**
1. Assess severity of the issue
2. Rollback application deployment to previous version if critical
3. Handle database migration state (expand phase = safe, contract phase = risky)
4. Monitor application health and metrics post-rollback

**Database considerations:**

**Expand Phase (SAFE):** Both old and new schema elements exist. Roll back application deployment to previous version; leave schema as-is (both columns remain). Optional: clean up unused new columns later via compensating migration.

**Contract Phase (RISKY):** Old schema elements removed. Application rollback fails because old code expects removed schema. Options: (1) Forward-fix application instead of rollback (recommended), or (2) Restore old schema via compensating migration or database backup (extreme). Prevention: Never contract until N-1 fully sunset.

**Dirty Migration (Failed Migration):** Migration failed mid-execution. Force to a specific version (current or previous successful), then continue forward with migrations. No .down.sql executed - forward-only policy maintained.

### Testing Rollback Procedures

**Approach:** Test rollbacks regularly in non-production environments to verify procedures work and train team.

**Test scenarios:**
- Staging environment rollback drills (practice full procedure)
- Database migration rollback tests (verify expand-phase safety)
- Pre-production verification (test rollback before every major release)

---

## 5. When to Adopt These Practices

**Triggers for implementing post-MVP features:**

**SDK Publishing:**
- When external partners request programmatic API access
- When manual API integration becomes too burdensome for partners
- When we have 3+ external consumers

**Support Policy:**
- When launching API v2 (first MAJOR version bump)
- When we have production SLAs with partners
- When compliance/contractual obligations require formal support windows

**Database Rollback Procedures:**
- When managing production database with customer data
- After first production incident requiring rollback
- When team size grows beyond 5 engineers (discipline harder to maintain)

---

## References

- [RFC 8594 - The Sunset HTTP Header Field](https://www.rfc-editor.org/rfc/rfc8594.html)
- [Semantic Versioning 2.0.0](https://semver.org/)
- [golang-migrate Documentation](https://github.com/golang-migrate/migrate)
- [oapi-codegen](https://github.com/deepmap/oapi-codegen)
