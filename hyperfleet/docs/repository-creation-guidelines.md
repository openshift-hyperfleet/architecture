---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2025-12-09
---

# HyperFleet Repository Creation Guidelines

---

## Overview

This document outlines the mandatory configuration steps and conventions for creating new repositories within the HyperFleet organization. Following these guidelines ensures consistency, security, and proper collaboration across all HyperFleet repositories.

**Key Areas Covered:**
1. Repository Naming and Initialization
2. Branch Protection Configuration
3. Team Access Configuration

**Purpose**: Standardized conventions for creating and configuring new repositories in the HyperFleet project.  
**Note**: This document provides the MVP baseline. More conventions will be introduced and refined after the MVP phase. 
---

## Repository Naming and Initialization
- Repository name contains relevant keywords for discoverability, use lowercase with hyphens to separate words (kebab-case)
- Repository description is accurate and meaningful
- Choose visibility: **public**
- Repository is initialized with README.md during creation
- Repository is initialized with appropriate LICENSE (**Apache-2.0 license**) during creation

---

## Branch Protection Configuration

### Default Branch
- Set `main` as the default branch

### Branch Protection Rules

Navigate to: **Settings → Branches → New branch ruleset**
- Ruleset Name: e.g., `main`
- Enforcement status: **Active**
- Target branches: Add target -> Include default branch
- Branch rules 
  - Require a pull request before merging
    - Required approvals: 1
  - Require status checks to pass before merging

---

## Team Access Configuration

All HyperFleet repositories **MUST** be configured with the following team access levels:

### hyperfleet Team - Write Access

**Path**: Settings → Access → Collaborators and teams → Add teams

1. Click **Add teams**
2. Search and select **hyperfleet**
3. Grant **Write** access

### automation-bots Team - Admin Access

**Path**: Settings → Access → Collaborators and teams → Add teams

1. Click **Add teams**
2. Search and select **automation-bots**
3. Grant **Admin** access

---

## CICD Jobs for Repository
- If a presubmit job or image build job is required, please create the corresponding JIRA tickets to request the setup.   
- For reference, you may refer to similar tickets such as HYPERFLEET-135, HYPERFLEET-134.

---

## Verification Checklist

Use this checklist to verify proper repository configuration:

### Repository Basics
- [ ] Repository name follows naming conventions
- [ ] Repository has meaningful description
- [ ] Visibility is set to Public (unless justified otherwise)
- [ ] README.md exists and is populated
- [ ] Apache-2.0 LICENSE file is present

### Branch Configuration
- [ ] `main` is set as default branch
- [ ] Branch protection ruleset is created and active
- [ ] Pull request requirement is enabled (1 approval)
- [ ] Status checks requirement is enabled

### Team Access
- [ ] `hyperfleet` team has Write access
- [ ] `automation-bots` team has Admin access

---
