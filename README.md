# template-terraform-azure-webapp

A **GitHub template repository** — the infrastructure-as-code archetype for provisioning secure, observable Azure infrastructure for containerised web applications.

When used with the **workshop-platform-eng** provisioning workflow:

1. The platform creates a new repository from this template, named `{app-name}-infra`.
2. The platform runs `terraform plan` and `terraform apply` against this infrastructure code.
3. The provisioned infrastructure (App Service, VNet, Private Endpoint, Log Analytics, autoscale, etc.) is deployed across `dev`, `staging`, `prod` environments.

---

## Infrastructure Architecture

| Component | Description | Environment-Specific |
|-----------|-------------|----------------------|
| **Resource Group** | Logical container for all Azure resources | Yes (rg-{app}-{env}) |
| **Virtual Network** | Private network with segregated subnets (Web App integration, Private Endpoints) | Yes (unique CIDR ranges per env) |
| **Network Security Groups** | Firewall rules (app egress, PE inbound) | All environments |
| **Private DNS Zone** | DNS resolution for private endpoints | All environments |
| **VNet Flow Logs** | Network traffic diagnostics to storage | All environments |
| **Private Endpoint** | Private inbound access to Web App | All environments |
| **App Service Plan** | Compute hosting the container | Yes (P0v3/dev, P1v3/staging, P2v3/prod with zone redundancy) |
| **Web App** | Container runtime with managed identity, HTTPS-only, health checks | Yes (per env with env-specific settings) |
| **Autoscale Rules** | Dynamic instance scaling (CPU, memory) | Staging & Prod only |
| **Deployment Slot** | Staging slot for zero-downtime blue/green swaps | Staging & Prod only |
| **Log Analytics** | Centralized log aggregates | Yes (retention: 30/60/90 days per env) |
| **Metric Alerts** | CPU high, memory high, no healthy instance | All environments |
| **Application Insights** | Observability & diagnostics | Yes (created or linked per env) |

---

## Resource Groups

Each environment gets its own resource group named `rg-<app_name>-<env>` (for example `rg-myapp-dev`), and one further group, created by the platform, holds the Terraform state:

| Group | Contains | Created by |
|---|---|---|
| `rg-<app_name>-<env>` | All resources for one environment — VNet, App Service Plan, Web App, Private Endpoint, Log Analytics Workspace, Application Insights, metric alerts, NSGs, Private DNS Zone, and VNet Flow Log storage | Terraform, in this repo (per environment) |
| `rg-<app_name>-tfstate` | The Terraform state storage account | Bootstrap script in **workshop-platform-eng** |

An Azure resource group is a container, not a query: every resource lives in exactly one group, and deleting the group deletes its contents. That makes the environment group the containment boundary for everything this template creates.

Practical implications:

- **Deletion protection**: the `azurerm` provider is configured with
  `prevent_deletion_if_contains_resources = true`. Attempting to delete the
  resource group while it still contains resources will fail, preventing
  accidental teardown. Use `tofu destroy` to remove resources in dependency
  order first.
- **Cost visibility**: because every resource lands in the same group, Azure
  Cost Management can show per-environment spend by filtering on the resource
  group name.
- **RBAC scope**: assigning a role at the resource group level grants it to all
  resources inside. This is the recommended scope for environment-level access
  (for example giving a team read access to `rg-myapp-staging`).

The resource group answers "what is in this environment?" but not "what does this application own across environments?" — those live in three separate groups. Every resource also carries the `application`, `environment`, `managed-by`, and `platform` tags, so use a tag query to span them:

```bash
az resource list --tag application=$APP_NAME -o table
```

State storage is deliberately outside the environment groups: one storage account
in `rg-<app_name>-tfstate` serves every environment, each with its own state key.
It must exist before Terraform can run at all — it *is* the backend, so nothing
in this repo can own it — and it must survive a `tofu destroy` of any environment.
The bootstrap script creates it once per app/account; see [Step 1](#step-1--bootstrap-terraform-state-one-time-per-appaccount).

---

## Module Structure

``` text
terraform/
├── environments/
│   ├── dev/           # Development environment (P0v3, no HA, public endpoint open)
│   ├── staging/       # Staging environment (P1v3, autoscale, staging slot)
│   └── prod/          # Production environment (P2v3, zone-redundant, 3+ instances, PE-only)
│
└── modules/
    ├── monitoring/    # Log Analytics Workspace, metric alerts
    ├── networking/    # VNet, Subnets, NSGs, Private DNS, Flow Logs
    └── webapp/        # App Service Plan, Web App, Identity, ACI, Private Endpoint, Autoscale, Diagnostics

scripts/
└── verify.sh          # Post-apply control-plane verification (see below)
```

State-backend bootstrap is not here — it lives in **workshop-platform-eng** as a
cross-cutting platform concern. See
[Step 1](#step-1--bootstrap-terraform-state-one-time-per-appaccount).

---

## Verification

This template owns its own post-apply verification at the canonical path
`scripts/verify.sh`. After `tofu apply`, the **workshop-platform-eng**
orchestrator checks out the generated `{app-name}-infra` repository and runs
this script, then surfaces the pass/fail counts. Because the assertions live
next to the Terraform that defines the expectations, the orchestrator stays
template-agnostic: any infra template that exposes `scripts/verify.sh` plugs
in without changing the platform.

### Interface

| Variable | Required | Purpose |
|----------|----------|---------|
| `APP_NAME` | Yes | Application name |
| `ENVIRONMENT` | Yes | One of `dev`, `staging`, `prod` |

### Outputs

| Variable | Required | Purpose |
|----------|----------|---------|
| `GITHUB_STEP_SUMMARY` | -- | Path appended with a Markdown summary (set automatically by GitHub Actions) |
| `VERIFY_SUMMARY_FILE` | -- | Machine-readable `key=value` summary path. Defaults to `/tmp/verify-summary.txt`. |

### Exit codes

| Code | Meaning |
|------|---------|
| `0` | Every check passed |
| `1` | Checks ran; at least one failed |
| `2` | Invalid invocation — a required variable is missing or `ENVIRONMENT` is not recognised. No checks ran. |

**Every exit path writes the summary file** (and the markdown summary when
`GITHUB_STEP_SUMMARY` is set), exit `2` included. A caller can always parse
`VERIFY_SUMMARY_FILE` and never has to distinguish "checks failed" from "the script
never started". Invalid invocations report *all* problems at once rather than
aborting on the first, so a caller missing two variables learns about both in one
run.

### What it checks

Grouped assertions: resource group, App Service Plan (SKU, zone redundancy,
worker count), Web App (state, HTTPS-only, managed identity, TLS, FTPS, HTTP/2),
Private Endpoint, diagnostic settings, Log Analytics (including per-environment
retention: 30/60/90 days), Application Insights, metric alerts (CPU, memory,
health — existence and enablement, since evaluation state needs metric history a
fresh apply lacks), autoscale, networking (VNet, subnets, flow-log storage),
staging slot, and public endpoint.

All but the last are control-plane assertions. The **public endpoint** group is
the one that sends real traffic: it issues an HTTPS `GET` against the default
`*.azurewebsites.net` hostname and expects `200`. Because `curl` validates the
certificate chain by default, this doubles as a check that Azure's wildcard
certificate is serving correctly — a TLS failure surfaces as `000`, not a status
code.

That probe runs for **dev only**, which keeps its public endpoint open for
exactly this purpose. Staging and prod are reachable only through the Private
Endpoint, so a request from a runner outside the VNet would fail on a perfectly
healthy deployment; those environments are verified through the control plane
alone and the group reports a pass explaining the skip.

Groups that don't apply to an environment always report a passing check saying
so — a skipped group never disappears silently from the output.

### Running locally

An active `az login` session is required:

```bash
APP_NAME=<app> ENVIRONMENT=<env> bash scripts/verify.sh
```

---

## Environment-Specific Baselines

Every row below genuinely differs by environment. Settings that are identical
everywhere — TLS version, Private Endpoint, managed identity, tagging,
encryption — are documented once under
[Security & Compliance](#security--compliance) rather than repeated per column.

| | `dev` | `staging` | `prod` |
|---|---|---|---|
| **Compute** | P0v3 — smallest Premium v3 SKU that supports VNet integration | P1v3 | P2v3 |
| **Instances** | 1 fixed, no autoscale | Autoscale 1–3 on CPU/memory | Autoscale 3–10 (min 3 for zone redundancy) |
| **Availability** | Single region, no zone redundancy | Single region, no zone redundancy | Zone redundant across Availability Zones |
| **Public endpoint** | Open — HTTP smoke tests from GitHub-hosted runners, which have no fixed IP and are not in the VNet | Closed | Closed |
| **VNet CIDR** | `10.10.0.0/16` | `10.20.0.0/16` | `10.30.0.0/16` |
| **Log retention** | 30 days | 60 days | 90 days |
| **Deployment slot** | Disabled | Enabled — pre-swap validation | Enabled — zero-downtime blue/green swaps |
| **Post-apply probe** | HTTPS `GET` on the default hostname, expects `200` | Control plane only | Control plane only |
| **Checkov baseline** | `.checkov.nonprod.yaml` (relaxed) | `.checkov.nonprod.yaml` (relaxed) | `.checkov.yaml` (strict) |

---

## Security & Compliance

### Network Isolation

- **Egress**: App Service VNet integration + NSGs restrict outbound to Azure services (HTTPS 443, DNS 53) only
- **Inbound**: Private Endpoint + optional IP restrictions on public endpoint (dev only)
- **Flow Logs**: Network traffic diagnostics logged to dedicate storage for compliance audit trails

### Identity & Access

- **Managed Identity**: User-assigned identity per Web App for Azure service authentication (no secrets in config)
- **RBAC**: Role assignments (AcrPull for container registry, Key Vault access for secrets)
- **TLS**: 1.3 only, in every environment. The `webapp` module defaults `minimum_tls_version` to `"1.3"` and its validation block accepts no other value, so no caller can weaken the floor to 1.2. The floor covers the Web App, the deployment slot, and both SCM (Kudu) endpoints, whose provider default would otherwise be 1.2. Production passes the value explicitly as documentation of intent; dev and staging inherit the same default. `scripts/verify.sh` re-asserts `minTlsVersion` and `scmMinTlsVersion` = 1.3 against the deployed app in all three environments. One documented exception: the flow-log storage account sits at `TLS1_2` because Azure Storage's `minimumTlsVersion` offers no 1.3 value — its only client is Microsoft's own flow-log writer.

### Compliance

- **Checkov**: Infrastructure security policy enforcement with environment-specific baselines (prod strict, dev/staging relaxed)
- **Logging**: Comprehensive logging to Log Analytics (HTTP logs, console logs, audit logs, platform logs)
- **Encryption**: End-to-end TLS encryption (App Service end-to-end enabled via azapi provider)

---


## Customization

### App Settings

App-specific environment variables are passed via `app_settings` map in each environment's `.tfvars`; they become App Service app settings, exposed to the container as environment variables. Do not put secrets here — use [Key Vault Integration](#key-vault-integration) instead. Example:

```hcl
app_settings = {
  DATABASE_URL = "postgresql://..."
  API_KEY      = "..."
}
```

### Key Vault Integration

Optional integration for storing & referencing secrets:

```hcl
key_vault_id = "/subscriptions/.../resourceGroups/.../providers/Microsoft.KeyVault/vaults/myvault"
key_vault_secrets = {
  DB_PASSWORD = "db-password-secret-name"
  API_TOKEN   = "api-token-secret-name"
}
```

### Container Registry

The pull happens at runtime, by the Web App's managed identity or stored
registry credentials — never by the identity running Terraform. The auth path
is selected by what you provide:

| Registry | Configure | Pull authenticates as |
|---|---|---|
| Public (`mcr.microsoft.com`, public Docker Hub/GHCR) | `container_registry_url` only | Anonymous — no credentials involved |
| Private ACR (`*.azurecr.io`) | `container_registry_url` only | The Web App's managed identity; the template grants it `AcrPull` |
| Private GHCR / Docker Hub | `container_registry_url` + `container_registry_username` + `container_registry_password` | The provided username + token, stored in the app's registry settings |

```hcl
container_registry_url = "myregistry.azurecr.io"
container_image        = "myregistry.azurecr.io/myapp:v1.2.3"
```

For username/password registries, inject the pair from CI secrets — never
from a tfvars file:

```bash
tofu plan ... -var="container_registry_username=$REGISTRY_USER" -var="container_registry_password=$REGISTRY_TOKEN"
```

The password variable is `sensitive`, so it is redacted from plan output and
logs; like all Terraform inputs it is persisted in state, which is one of the
reasons state lives in an access-controlled storage account. After first
creation, CI/CD owns the container configuration (the template ignores drift
on `application_stack`), so rotate registry credentials through the
deployment pipeline rather than by re-applying Terraform.

### Hostnames and TLS

Every environment serves on its Azure-assigned hostname,
`app-<app>-<env>.azurewebsites.net`, which Azure covers with a platform-managed
wildcard certificate for `*.azurewebsites.net`. **There is no certificate for
this template to provision, bind, or renew** — TLS works out of the box in all
three environments, and nothing expires under your ownership. This is the
configuration the template is built and verified against; the template
deliberately has no custom-domain input.

---

## Local End-to-End Test

This section mirrors the steps the **workshop-platform-eng** provisioning
workflow executes in CI. Run them locally to validate changes before pushing.

### Prerequisites

The following tools must be installed and on `$PATH`:

| Tool | Purpose |
|------|---------|
| [`az`](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) | Azure CLI — resource queries and auth |
| [`tofu`](https://opentofu.org/docs/intro/install/) | OpenTofu — plan, apply, destroy |
| [`checkov`](https://www.checkov.io/2.Basics/Installing%20Checkov.html) | Infrastructure policy enforcement |
| [`jq`](https://jqlang.github.io/jq/) | JSON processing in `scripts/verify.sh` |

**Azure access**: credentials must be active before running any `az` or `tofu`
command. Login and/or verify your session before proceeding:

```bash
export AZURE_TENANT_ID=<GUID>
export AZURE_SUBSCRIPTION_ID=<GUID>

az login --tenant $AZURE_TENANT_ID
az account set --subscription $AZURE_SUBSCRIPTION_ID
```

### Step 1 — Bootstrap Terraform state (one-time per app/account)

> **State bootstrapping is a cross-cutting concern owned by the orchestrator, not by individual
> infrastructure templates.** The bootstrap script lives in the **workshop-platform-eng**
> repository and must be run from there. Each template is deliberately free of bootstrap logic —
> the orchestrator is the single place to update when storage naming conventions, retention
> policies, or cloud targets change.

Export shared variables first — these are reused in every subsequent command:

```bash
export AZURE_LOCATION=westeurope
export APP_NAME=myapp
export ENVIRONMENT=dev

export APP_SHORT=$(echo "$APP_NAME" | tr -d '-' | cut -c1-12)
export SUB_SHORT=$(echo "$AZURE_SUBSCRIPTION_ID" | tr -d '-' | cut -c1-8)
```

To be able to authorize the access to the Azure Storage Account for Terraform state, the logged-in
user must have **Storage Blob Data Contributor** role - **Owner** or **Contributor** is not enough:

```bash
az role assignment create \
  --assignee $(az ad signed-in-user show --query id -o tsv) \
  --role "Storage Blob Data Contributor" \
  --scope $(az storage account show -n sttf${APP_SHORT}${SUB_SHORT} --query id -o tsv)
```

From the **workshop-platform-eng** repository:

```bash
cd /path/to/workshop-platform-eng
./scripts/bootstrap-tfstate-azure.sh \
  --subscription-id $AZURE_SUBSCRIPTION_ID \
  --location $AZURE_LOCATION \
  --app-name $APP_NAME
```

Creates a dedicated Azure Storage Account for remote state (idempotent).

### Step 2 — Security scan (Checkov)

Run Checkov before `tofu plan` to catch policy violations before any state is touched.
Each environment is scanned with its own baseline: dev and staging use the
relaxed config, prod the strict one. Checkov resolves the shared modules with
the values each environment passes in, so module code is assessed three times —
once per environment, under its real configuration.

Do **not** scan `terraform/modules` on its own: with no caller, Checkov judges
the module *defaults*, which are deliberately non-prod-shaped, and the strict
baseline fails checks that every actual deployment satisfies.

```bash
# dev
checkov -d terraform/environments/dev --config-file .checkov.nonprod.yaml

# staging
checkov -d terraform/environments/staging --config-file .checkov.nonprod.yaml

# prod
checkov -d terraform/environments/prod --config-file .checkov.yaml
```

All three scans must pass (zero failures) before proceeding. Every skip in
both config files carries a stated reason.

### Step 3 — Init

```bash
tofu -chdir=terraform/environments/$ENVIRONMENT init \
  -backend-config="resource_group_name=rg-$APP_NAME-tfstate" \
  -backend-config="storage_account_name=sttf${APP_SHORT}${SUB_SHORT}" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=$ENVIRONMENT/terraform.tfstate"
```

### Step 4 — Plan

```bash
tofu -chdir=terraform/environments/$ENVIRONMENT plan \
  -var="subscription_id=$AZURE_SUBSCRIPTION_ID" \
  -var="location=$AZURE_LOCATION" \
  -var="app_name=$APP_NAME" \
  -var="container_image=mcr.microsoft.com/azuredocs/aci-helloworld:latest" \
  -var="container_registry_url=mcr.microsoft.com" \
  -var="health_check_path=/" \
  -out=tfplan
```

This plan for `dev` deploys a public placeholder image
(`mcr.microsoft.com/azuredocs/aci-helloworld`) with `health_check_path = "/"`,
so the template can be applied and verified end to end before a real application
image exists. Swap `container_image`, `container_registry_url`, and
`health_check_path` for your own app's values when moving past validation.

Review the plan output before applying — confirm the region for resources is the
one you intended, and that the resource count matches expectations for the
environment.

### Step 5 — Apply

```bash
tofu -chdir=terraform/environments/$ENVIRONMENT apply tfplan
```

### Step 6 — Verify

```bash
./scripts/verify.sh
```

Exits `0` if all assertions pass. A summary is written to
`/tmp/verify-summary.txt`.

The HTTPS probe runs only for `dev`; `staging` and `prod` are verified through
the control plane alone as they are not exposed to the Internet.

### Step 7 — Destroy (teardown)

```bash
tofu -chdir=terraform/environments/$ENVIRONMENT destroy \
  -var="subscription_id=$AZURE_SUBSCRIPTION_ID" \
  -var="location=$AZURE_LOCATION" \
  -var="app_name=$APP_NAME" \
  -var="container_image=mcr.microsoft.com/azuredocs/aci-helloworld:latest" \
  -var="container_registry_url=mcr.microsoft.com" \
  -var="health_check_path=/"
```

---

## License

[MIT](LICENSE) — see the license file for details.
