# Architecture Documentation Automatic Change Detection and Assistance System Design

**Version:** v1.0

---

## 1. Background

As the HyperFleet architecture evolves, determining whether changes in component code should be reflected in the Architecture documentation has become a persistent challenge. Current issues include:

- Architecture documentation tends to become outdated.
- Engineers struggle to identify which changes impact Architecture.
- Manual synchronization is costly and prone to omissions.
- Cross-repository design context is hard to propagate automatically.

We currently have a skill plugin that can read documents from the Architecture repository, but it lacks automated assessment and assistance for updates.

---

## 2. Objectives

Build an automated system using the Claude Code Plugin to help developers:

1. Determine whether current code changes (diffs) affect the Architecture documentation.
2. Identify which files in the Architecture repository need updates.
3. Automatically generate AI prompts for subsequent documentation updates.  
   *(The system does not directly modify documents, but assists in generating editing suggestions.)*

The goal is to reduce the risk of outdated documentation and keep Architecture aligned with the actual implementation.

---

## 3. Functional Design

### 3.1 Diff Analysis → Architecture Impact Assessment
The system should automatically determine whether Architecture documentation needs to be updated based on code diffs.

**Criteria:**

#### Changes that do NOT need to be reflected in Architecture:
- Implementation-level changes
- Refactoring without behavioral changes
- Lint or formatting fixes
- Internal logic changes within a single component
- Tooling updates

#### Changes that SHOULD be reflected in Architecture:
- Addition, modification, or removal of system components
- System API or CRD schema modifications
- Changes in component responsibilities
- Cross-component interaction changes
- Changes in build or scheduling workflows
- Introduction of new dependencies or subsystems

---

### 3.2 Architecture File Impact Analysis

Based on diff content, map affected components to files in the Architecture repository, for example:
```
architecture/
components/
deployment/
docs/
test-release/
README.md
```

Affected files are inferred using component names, API names, CRD names, and module paths.

---

### 3.3 Automated Prompt Generation for Documentation Updates

Instead of directly updating documents, the plugin returns a **prompt** for developers to use in Claude CLI or web UI to generate content.

**Example output:**

```
Architecture update required: YES
Affected files:
- components/adapter-versioning.md
- components/api-service/api-versioning.md

Suggested prompt for generating updates:

"""
You are an Architecture documentation editor.
Based on the following diff (high-level system design change), generate content that should be added to the relevant architecture documents.
<DIFF>
"""
```

## 4. Workflow Design
```mermaid
flowchart TD
  A[Developer (CLI)] --> B[Claude Code Plugin]
  B --> C[Collect current diff]
  C --> D[Analyze impact on Architecture]
  D -->|No impact| E[Return "No update required"]
  D -->|Impact detected| F[Identify affected files + Return AI prompt]

```
---

## 5. Plugin Key Components (Pseudo API)

- `analyze_architecture_impact(diff) → {needsUpdate, files}`
- `generate_architecture_prompt(diff, files) → prompt`
- `scanArchitectureRepo()` (provided by existing skill plugin)
- `componentMappingEngine` (maps component → architecture files)

---

## 6. Risks and Limitations

- Frequent minor changes may cause false positives (suppression strategies recommended).
- Architecture assessment depends on code conventions (naming, directory structure).
- Final documentation still requires human review.

---

## 7. Future Extensions

- Introduce a “Architecture Drift Scanner” that triggers automatically in CI.
- Automatically generate Architecture diffs.
- Automatically draw component dependency graphs (topology diagrams).

