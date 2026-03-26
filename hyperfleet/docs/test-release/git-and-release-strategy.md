---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-03-10
---

# HyperFleet Git Workflow and Release Management

## 1. Overview

This document defines HyperFleet's Git workflow, branching strategy, release process, and hotfix procedures. It applies to all HyperFleet components: API, Sentinel, and Adapters.

---

## 2. Container Image Tagging Strategy

All HyperFleet components use the same container tagging workflow.

**Tag Format:**
```
quay.io/openshift-hyperfleet/{component}:1.2.3    # Specific version (immutable)
quay.io/openshift-hyperfleet/{component}:a1b2c3d  # Git commit SHA (immutable)
quay.io/openshift-hyperfleet/{component}:1.2      # Latest patch in 1.2.x (mutable)
quay.io/openshift-hyperfleet/{component}:1        # Latest minor in 1.x (mutable)
quay.io/openshift-hyperfleet/{component}:latest   # Not recommended for production (mutable)
```

**Key principle:** Semver tags are applied once at release time to an already-existing SHA-tagged image. This preserves immutability - you never have multiple different images tagged with the same semver.

### Dev Image Builds

Dev images built via `make image-dev` **must** use a hardcoded version of `0.0.0-dev` rather than deriving the version from `git describe --tags`. This ensures:

- Dev images are clearly distinguishable from release builds
- No misleading release version strings are baked into dev binaries
- Consistent versioning across all developer environments regardless of local git tag state

**Implementation:** The `image-dev` Makefile target must pass `--build-arg APP_VERSION=0.0.0-dev` instead of `--build-arg APP_VERSION=$(APP_VERSION)`.

**Dev image tag format:**
```
quay.io/{user}/{component}:dev-{short-sha}    # Dev image (personal registry)
```

This convention applies to all HyperFleet components (API, Sentinel, Adapters).

**Image tag immutability:**
- **Once published, semantic version and git SHA tags are IMMUTABLE**
- `quay.io/openshift-hyperfleet/api:1.2.3` never changes after publication
- `quay.io/openshift-hyperfleet/api:a1b2c3d` never changes after publication
- Never overwrite or republish an existing semver or git SHA tag
- Never delete a published semver or git SHA tag
- Mutable tags (`latest`, `1`, `1.2`) can be updated (but not for production)
- **Why immutable?** Ensures reproducible deployments, prevents "it works on my machine" issues, enables reliable rollbacks

---

## 3. Branching Strategy: GitHub Flow

**Model:** Simplified GitHub Flow with fork-based development

**Why GitHub Flow?**
- Simple and lightweight (only one long-lived branch: `main`)
- Works well for open source projects
- Continuous delivery to staging from main
- Team size (~10 people) doesn't need complex branching

### Branch Structure

**Long-lived branches:**
- `main` - Production-ready code, always deployable

**Short-lived branches:**
- `feature/*` - New features (e.g., `feature/add-cluster-status`)
- `fix/*` - Bug fixes (e.g., `fix/null-pointer-crash`)
- `hotfix/*` - Critical production fixes (e.g., `hotfix/v1.2.4`)
- `chore/*` - Maintenance tasks (e.g., `chore/update-dependencies`)

**No long-lived branches for:**
- `develop` (not needed - main serves this purpose)
- `release/*` branches (releases tagged from main)
- Feature-specific long-lived branches

### Development Workflow

**Fork-based workflow:**
1. Fork repository, create feature branch in your fork
2. Develop and commit changes
3. Open PR from fork to upstream `main`
4. Code review (min 1 approval) and CI checks
5. Squash and rebase to `main`, delete feature branch
6. CI builds container image tagged with git SHA
7. Triggers deployment to integration/staging

### Branch Protection Rules

**`main` branch protection:**
- Require pull request reviews (min 1 approval), dismiss stale approvals on new commits
- Require status checks to pass: CI build, unit tests, integration tests, linting
- Require branches up to date before merging
- Require conversation resolution before merging
- No bypassing protections (even for admins)
- No direct commits to main

---

## 4. Release Process

**Process:**

1. **Verify main is stable**
   ```bash
   # Check that integration/staging deployments are healthy
   # Review recent commits since last release
   # Ensure no open critical bugs
   ```

2. **Automated release (GitHub Actions)**
   - Triggers weekly on schedule or manual workflow dispatch
   - Determines next version (bump PATCH by default, or use conventional commits)
   - Generates changelog from commits/PRs
   - Creates Git tag and GitHub Release
   - Builds and pushes container image with both semver and SHA tags
   - Triggers production deployment

3. **Post-release verification**
   - Monitor production metrics
   - Verify health endpoints
   - Check error rates

### Version Tagging Conventions

**Tag format:** `vMAJOR.MINOR.PATCH`

**Examples:** `v1.2.3` (PATCH), `v1.3.0` (MINOR), `v2.0.0` (MAJOR breaking changes)

**Tagging rules:**
- Tags created from `main` branch only (except hotfixes)
- Tags are immutable (never delete or move tags)
- Tags follow semantic versioning strictly
- Annotated tags preferred (include release notes summary)

**Creating tags:**
```bash
# Automated (preferred)
# GitHub Actions creates tags on release

# Manual (if needed)
git tag -a v1.2.3 -m "Release v1.2.3: Bug fixes and performance improvements"
git push origin v1.2.3
```

### Release Notes Generation

**Approach:** Auto-generated using GitHub Releases from PR titles, commit messages, and PR labels. Maintainers can edit before publishing to add migration guides for breaking changes.

---

## 5. Hotfix Process

**When to use hotfixes:**
- Critical bug in production
- Security vulnerability
- Data loss risk
- Complete service outage

**Process:**
1. Create hotfix branch from production tag in your fork
2. Make minimal fix with tests, commit and push
3. Tag the hotfix (e.g., `v1.2.4`) and push tag to upstream
4. Deploy to production (automated via GitHub Actions)
5. Backport to `main` via PR (requires approval + CI), delete hotfix branch after merge

### Hotfix Decision Tree

```
Critical bug in production?
│
├─ YES → Is main "close to releasable"?
│   │
│   ├─ YES → Consider early release from main instead of hotfix
│   │        (e.g., expedite next scheduled release)
│   │
│   └─ NO → Use hotfix process
│        1. Branch from production tag
│        2. Fix bug
│        3. Tag hotfix (v1.2.4)
│        4. Deploy to production
│        5. Backport to main via PR
│
└─ NO → Fix in main, wait for next scheduled release
```

---

## References

- [GitHub Flow](https://guides.github.com/introduction/flow/)
- [Semantic Versioning 2.0.0](https://semver.org/)
- [Conventional Commits](https://www.conventionalcommits.org/)
