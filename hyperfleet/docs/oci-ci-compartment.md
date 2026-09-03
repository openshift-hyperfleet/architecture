---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-09-03
---

# OCI CI Compartment

---

## Overview

Describes the `hyperfleet-ci` Oracle Cloud Infrastructure (OCI) compartment: a dedicated, quota-fenced compartment for running the OCI end-to-end test suite, with a scheduled sweep as the backstop for anything a CI run fails to tear down and a budget that alerts on spend (not a hard enforcement boundary — see [Budget and quota](#budget-and-quota)).

- **Compartment Name**: `hyperfleet-ci`
- **Tenancy**: `rhelcert`
- **Parent Compartment**: `HyperFleet` (the team compartment)
- **Region**: `us-sanjose-1` (rhelcert's home region)
- **Provisioned by**: Terraform in [`hyperfleet-infra`](https://github.com/openshift-hyperfleet/hyperfleet-infra), under `terraform/oci/`

`hyperfleet-ci` is a sibling of the team's existing `hyperfleet-sandbox`, `hyperfleet-poc`, and `hyperfleet-demos` compartments under `HyperFleet` — never created directly inside `HyperFleet` itself, per team convention (every resource lives in a sub-compartment so spend is attributable to a lifecycle).

---

## Usage Policy

**This compartment is dedicated to the OCI e2e CI suite. It is not a general-purpose sandbox** — for ad hoc experiments, use `hyperfleet-sandbox` instead.

### Sweep policy

A scheduled OCI Function sweeps the compartment and deletes anything older than the run window: OKE clusters, load balancers, block volumes, and DB systems.

| Setting | Value |
|---|---|
| Run window | 8 hours |
| Schedule | Hourly (`0 * * * *`) |
| Exemption | Freeform tag `hyperfleet-keep=true` holds a resource regardless of age, for manual debugging |

The sweep is the **backstop**, not the primary cleanup mechanism: the e2e CI job is expected to tear down every billable resource at the end of each run (including failed runs). The sweep only catches what that per-run teardown misses — a leaked resource costs at most a few hours of spend before the sweep removes it, rather than sitting forgotten indefinitely. That bound only holds for a non-exempt resource once the sweep actually runs and deletes successfully: a resource tagged `hyperfleet-keep=true` is held indefinitely by design, and a sweep left in `DRY_RUN` or otherwise not running normally won't delete anything at all.

Past the tag exemption, the sweep's decision is age-only; it does not know which team member or CI run created a resource, so tag anything you want preserved past the run window with `hyperfleet-keep=true` before it ages out.

### Budget and quota

| Guardrail | Value | Enforced by |
|---|---|---|
| Monthly budget | $150 | Budget alert rules at 50/80/100% actual spend, 100% forecast |
| Concurrent OKE clusters | 2 | Compartment quota (`container-engine` / `cluster-count`) |
| Compute cores | 16 (`Standard.E4.Flex`) | Compartment quota (`compute` / `standard-e4-core-count`) |

At list price, a running OKE cluster with three small nodes costs about $7/day. The quota is a sanity cap on concurrency, not a mathematical guarantee that spend stays under budget — a bug that kept both quota slots occupied for a full month would still cost roughly $420, well over budget. The budget alerts are the real early-warning mechanism: at 2 concurrent clusters, the 50/80/100% thresholds fire after roughly 11, 17, and 21 cluster-days of usage respectively, out of the ~60 cluster-days theoretically possible in a 30-day month — comfortably before the worst case is reached.

---

## Notifications

**Owner**: `#hcm-hyperfleet-team`.

Budget alerts (50/80/100% actual spend, 100% forecast) are delivered by email, using the alert rule's built-in `recipients` delivery — no Slack app, webhook, or Notifications-topic wiring involved. Current recipients (`budget_alert_recipients` in `ci.tfvars`):

- `mbrudnoy@redhat.com`
- `croche@redhat.com`
- `rbenevid@redhat.com`

The sweep does not send notifications of any kind; it only logs its decisions (see [Sweep policy](#sweep-policy)). Update the recipient list the same way as any other setting — see [How to Change Quota, Budget, or Sweep Settings](#how-to-change-quota-budget-or-sweep-settings).

---

## Prerequisites

```bash
# Install the OCI CLI and Terraform
brew install oci-cli terraform  # Terraform >= 1.5

# Clone the infrastructure repository
git clone https://github.com/openshift-hyperfleet/hyperfleet-infra.git
cd hyperfleet-infra/terraform/oci
```

Authenticate with either a durable API key or a browser SSO session token:

```bash
# Browser SSO (session token, expires periodically)
oci session authenticate

# OR durable API key: place your key under ~/.oci and reference it in ci.tfvars
```

---

## How to Access the Compartment

### View compartment contents (read-only, any team member)

```bash
oci iam compartment list --compartment-id <HyperFleet-compartment-ocid> \
  --query "data[?name=='hyperfleet-ci']"

oci ce cluster list --compartment-id <hyperfleet-ci-ocid>
```

### View Terraform state and outputs

```bash
cd hyperfleet-infra/terraform/oci
cp ci.tfbackend.example ci.tfbackend   # if you don't already have one; edit prefix if needed
terraform init -backend-config=ci.tfbackend
terraform state list
terraform output
```

---

## How to Change Quota, Budget, or Sweep Settings

**First, clone the repo if you haven't already** (see [Prerequisites](#prerequisites)).

```bash
cd hyperfleet-infra/terraform/oci
cp ci.tfvars.example ci.tfvars       # if you don't already have one
cp ci.tfbackend.example ci.tfbackend # if you don't already have one; edit prefix if needed
terraform init -backend-config=ci.tfbackend
```

Edit `ci.tfvars`:

```hcl
# Common changes:
budget_amount             = 150   # Monthly budget (USD)
sweep_run_window_hours    = 8     # Age before the sweep deletes a resource
sweep_schedule_recurrence = "0 * * * *"  # Cron expression
quota_statements = [
  "set compute quota standard-e4-core-count to 16 in compartment hyperfleet-ci",
  "set container-engine quota cluster-count to 2 in compartment hyperfleet-ci",
]
budget_alert_recipients = ["mbrudnoy@redhat.com", "croche@redhat.com", "rbenevid@redhat.com"]
```

If the CI clusters' worker shape changes, re-derive the compute quota name before editing `quota_statements`:

```bash
oci limits definition list --compartment-id <tenancy_ocid> --service-name compute
```

Applying a `quota_statements` change requires an identity with the `quota` resource-type manage permission at the tenancy level (`allow group <your-group> to manage quota in tenancy`) — not full tenancy administration. `oci_limits_quota` is created at the tenancy root even though its statements target `hyperfleet-ci` specifically, so a compartment-scoped identity is not sufficient.

```bash
terraform plan -var-file=ci.tfvars
terraform apply -var-file=ci.tfvars
```

---

## Key Configuration Files in hyperfleet-infra Repo

| File | Purpose |
|---|---|
| `terraform/oci/ci.tfvars.example` | Compartment, quota, budget, and sweep configuration |
| `terraform/oci/ci.tfbackend.example` | Remote state configuration |
| `terraform/oci/main.tf` | Root module wiring the compartment, quota, budget, and sweep modules |
| `terraform/modules/{compartment,quota,budget,lifecycle}/oci/` | Individual resource modules |
| `functions/oci-ci-sweep/` | The sweep function's Go source |

---

## Troubleshooting

### Sweep isn't removing an expected resource

Check the function's logs (Logging service, `oci-ci-sweep` function) for the per-resource action and reason. Common causes: the resource carries `hyperfleet-keep=true`, it's younger than the run window, or `DRY_RUN` is still `true` on the function.

### Quota apply fails with a permissions error

`oci_limits_quota` requires `manage quota in tenancy` permissions (see [How to Change Quota, Budget, or Sweep Settings](#how-to-change-quota-budget-or-sweep-settings)) — a compartment-scoped identity is not sufficient.

### Budget alert emails never arrived

Check `budget_alert_recipients` in `ci.tfvars` for typos, and check spam/junk folders — the alert rule's email delivery is OCI's built-in mechanism, not a separate subscription to confirm.

---

## Additional Documentation

- **Detailed infrastructure docs**: `terraform/oci/README.md` (in the cloned repo)
- **Sweep function internals**: `functions/oci-ci-sweep/README.md` (in the cloned repo)

---
