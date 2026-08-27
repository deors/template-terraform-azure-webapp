# template-terraform-azure-webapp

A **GitHub template repository** — the infrastructure-as-code archetype for provisioning secure, observable Azure infrastructure for containerised web applications.

When used with the **workshop-platform-eng** provisioning workflow:

1. The platform creates a new repository from this template, named `{app-name}-infra`.
2. The platform runs `terraform plan` and `terraform apply` against this infrastructure code.
3. The provisioned infrastructure (App Service, VNet, Private Endpoint, Load Monitoring, autoscale, etc.) is deployed across `dev`, `staging`, `prod` environments.

---

## Infrastructure Architecture

| Component | Description | Environment-Specific |
|-----------|-------------|----------------------|
| **Resource Group** | Logical container for all Azure resources | Yes (rg-{app}-{env}) |
| **Virtual Network** | Private network with segregated subnets (Web App integration, Private Endpoints) | Yes (unique CIDR ranges per env) |
| **App Service Plan** | Compute hosting the container | Yes (P0v3/dev, P1v3/staging, P2v3/prod with zone redundancy) |
| **Web App** | Container runtime with managed identity, HTTPS-only, health checks | Yes (per env with env-specific settings) |
| **Deployment Slot** | Staging slot for zero-downtime blue/green swaps | Staging & Prod only |
| **Private Endpoint** | Private inbound access to Web App | All environments |
| **Application Insights** | Observability & diagnostics | Yes (created or linked per env) |
| **Log Analytics** | Centralized log aggregates | Yes (retention: 30/60/90 days per env) |
| **Metric Alerts** | CPU high, memory high, no healthy instance | All environments |
| **Network Security Groups** | Firewall rules (app egress, PE inbound) | All environments |
| **Private DNS Zone** | DNS resolution for private endpoints | All environments |
| **Autoscale Rules** | Dynamic instance scaling (CPU, memory) | Staging & Prod only |
| **VNet Flow Logs** | Network traffic diagnostics to storage | All environments |

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

---

## Verification

This template owns its own post-apply verification at the canonical path
`scripts/verify.sh`. After `tofu apply`, the **workshop-platform-eng**
orchestrator checks out the generated `{app-name}-infra` repository and runs
this script, then surfaces the pass/fail counts. Because the assertions live
next to the Terraform that defines the expectations (SKU, zone redundancy,
worker count, TLS, staging slot, …), the orchestrator stays template-agnostic:
any infra template that exposes `scripts/verify.sh` plugs in without changing
the platform.

### Interface

| Variable | Required | Purpose |
|---|---|---|
| `APP_NAME` | Yes | Application name; used as the resource-name prefix |
| `ENVIRONMENT` | Yes | One of `dev`, `staging`, `prod` |
| `GITHUB_STEP_SUMMARY` | No | Path appended with a Markdown summary (set automatically by GitHub Actions) |
| `VERIFY_SUMMARY_FILE` | No | Machine-readable `key=value` summary path. Defaults to `/tmp/verify-summary.txt`. |

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Every check passed |
| `1` | Checks ran; at least one failed |
| `2` | Invalid invocation — a required variable is missing or `ENVIRONMENT` is not recognised. No checks ran. |

All three exit paths write the summary file. A caller can always parse it and never has to special-case "the script died before producing output".

### What it checks

Twelve groups: resource group, App Service Plan (SKU, zone redundancy, worker count), Web App (state, HTTPS-only, managed identity, TLS, FTPS, HTTP/2), Private Endpoint, diagnostic settings, Log Analytics (including per-environment retention: 30/60/90 days), Application Insights, metric alerts (CPU, memory, health — existence and enablement, since evaluation state needs metric history a fresh apply lacks), autoscale, networking (VNet, subnets, flow-log storage), staging slot, and public endpoint.

All but the last are control-plane assertions. The **public endpoint** group is the one that sends real traffic: it issues an HTTPS `GET` against the default `*.azurewebsites.net` hostname and expects `200`. Because `curl` validates the certificate chain by default, this doubles as a check that Azure's wildcard certificate is serving correctly — a TLS failure surfaces as `000`, not a status code.

That probe runs for **dev only**, which keeps its public endpoint open for exactly this purpose. Staging and prod are reachable only through the Private Endpoint, so a request from a runner outside the VNet would fail on a perfectly healthy deployment; those environments are verified through the control plane alone and the group reports a pass explaining the skip.

Groups that don't apply to an environment always report a passing check saying so — a skipped group never disappears silently from the output.

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
- **TLS**: 1.3 only, in every environment. The `webapp` module defaults `minimum_tls_version` to `"1.3"` and its validation block accepts no other value, so no caller can weaken the floor to 1.2 — the same allow-list approach the AWS template applies to its ALB `ssl_policy`. The floor covers the Web App, the deployment slot, and both SCM (Kudu) endpoints, whose provider default would otherwise be 1.2. Production passes the value explicitly as documentation of intent; dev and staging inherit the same default. `scripts/verify.sh` re-asserts `minTlsVersion` and `scmMinTlsVersion` = 1.3 against the deployed app in all three environments. One documented exception: the flow-log storage account sits at `TLS1_2` because Azure Storage's `minimumTlsVersion` offers no 1.3 value — its only client is Microsoft's own flow-log writer.

### Compliance

- **Checkov**: Infrastructure security policy enforcement with environment-specific baselines (prod strict, dev/staging relaxed)
- **Diagnostics**: Comprehensive logging to Log Analytics (HTTP logs, console logs, audit logs, platform logs)
- **Encryption**: End-to-end TLS encryption (App Service end-to-end enabled via azapi provider)

---

## Resource Group

Each environment gets its own resource group named `rg-<app_name>-<env>` (for example `rg-myapp-dev`). The resource group is the containment boundary for every resource this template creates — the VNet, App Service Plan, Web App, Private Endpoint, Log Analytics Workspace, Application Insights, metric alerts, NSGs, Private DNS Zone, and VNet Flow Log storage.

Practical implications:

- **Deletion protection**: the `azurerm` provider is configured with `prevent_deletion_if_contains_resources = true`. Attempting to delete the resource group while it still contains resources will fail, preventing accidental teardown. Use `tofu destroy` to remove resources in dependency order first.
- **Cost visibility**: because every resource lands in the same group, Azure Cost Management can show per-environment spend by filtering on the resource group name.
- **RBAC scope**: assigning a role at the resource group level grants it to all resources inside. This is the recommended scope for environment-level access (for example giving a team read access to `rg-myapp-staging`).

The resource group is a containment boundary, so it answers "what is in this environment?" but not "what does this application own across environments?" — those live in three separate groups. Every resource also carries the `application`, `environment`, `managed-by`, and `platform` tags, so use a tag query to span them:

```bash
az resource list --tag application=$APP_NAME -o table
```

State storage is deliberately outside these groups: the bootstrap script creates `rg-tfstate-<app>`, which must survive a `tofu destroy` of any environment.

---

## Customization

### App Settings

App-specific environment variables are passed via `app_settings` map in each environment's `.tfvars`. Example:

```hcl
app_settings = {
  DATABASE_URL = "postgresql://..."
  API_KEY      = "..."
}
```

### Hostnames and TLS

Every environment serves on its Azure-assigned hostname, `app-<app>-<env>.azurewebsites.net`, which Azure covers with a platform-managed wildcard certificate for `*.azurewebsites.net`. **There is no certificate for this template to provision, bind, or renew** — TLS works out of the box in all three environments, and nothing expires under your ownership. This is the configuration the template is built and verified against.

Production optionally accepts a `custom_domain` for a vanity hostname. It is left off by default; the wildcard-covered default hostname is the expected path.

### Container Registry

Pull images from private container registry (GHCR, ACR, Docker Hub):

```hcl
container_registry_url = "myregistry.azurecr.io"
container_image        = "myregistry.azurecr.io/myapp:v1.2.3"
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

---

## Terraform Workflow

### Prerequisites

The following tools must be installed and on `$PATH`:

| Tool | Purpose |
|---|---|
| [`az`](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) | Azure CLI — resource queries and auth |
| [`tofu`](https://opentofu.org/docs/intro/install/) | OpenTofu — plan, apply, destroy |
| [`checkov`](https://www.checkov.io/2.Basics/Installing%20Checkov.html) | Infrastructure policy enforcement |
| [`jq`](https://jqlang.github.io/jq/) | JSON processing in `scripts/verify.sh` |

Authenticate before running any command:

```bash
az login
az account set --subscription $SUBSCRIPTION_ID
```

### 1. Bootstrap Terraform State (one-time)

> **State bootstrapping is a cross-cutting concern owned by the orchestrator, not by individual
> infrastructure templates.** The bootstrap script lives in the **workshop-platform-eng**
> repository and must be run from there. Each template is deliberately free of bootstrap logic —
> the orchestrator is the single place to update when storage naming conventions, retention
> policies, or cloud targets change.

Export shared variables first — these are reused in every subsequent command:

```bash
export APP_NAME=myapp
export SUBSCRIPTION_ID=<GUID>
export LOCATION=westeurope   # set your target Azure region explicitly
```

> **`location` is required by design and has no default.** Azure resource groups are regional and every resource in them inherits that placement, so a forgotten region would not fail — it would deploy the whole stack to whichever region the template happened to default to, and `tofu plan` would report no problem. Removing the default converts a silent misdeployment into an upfront error. Pass it explicitly on every `plan`, `apply`, and `destroy`.

From the **workshop-platform-eng** repository:

```bash
cd /path/to/workshop-platform-eng
./scripts/bootstrap-tfstate.sh \
  --app-name $APP_NAME \
  --subscription-id $SUBSCRIPTION_ID \
  --location $LOCATION
```

Creates a dedicated Azure Storage Account for remote state (idempotent).

### 2. Security scan (Checkov)

Run before `tofu plan` to catch policy violations before any state is touched.
Each environment is scanned with its own baseline: dev and staging use the
relaxed config, prod the strict one. Checkov resolves the shared modules with
the values each environment passes in, so module code is assessed three times —
once per environment, under its real configuration.

Do **not** scan `terraform/modules` on its own: with no caller, Checkov judges
the module *defaults*, which are deliberately non-prod-shaped (single worker,
no zone redundancy), and the strict baseline fails checks that every actual
deployment satisfies.

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

### 3. Init

```bash
cd terraform/environments/dev
tofu init \
  -backend-config="resource_group_name=rg-tfstate-$APP_NAME" \
  -backend-config="storage_account_name=sttf${APP_NAME}<sub-short>" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=dev/terraform.tfstate"
```

### 4. Plan

```bash
tofu plan -var-file="terraform.tfvars" -var="location=$LOCATION" -out=tfplan
```

Review the plan output before applying — confirm the region on the resource
group is the one you intended, and that the resource count matches expectations
for the environment.

The committed `terraform.tfvars.example` for `dev` deploys a public placeholder
image (`mcr.microsoft.com/azuredocs/aci-helloworld`) with `health_check_path = "/"`,
so the template can be applied and verified end to end before a real application
image exists. Swap `container_image`, `container_registry_url`, and
`health_check_path` for your own app's values when moving past validation.

### 5. Apply

```bash
tofu apply tfplan
```

### 6. Verify

```bash
APP_NAME=$APP_NAME ENVIRONMENT=dev bash scripts/verify.sh
```

### 7. Destroy (teardown)

```bash
tofu destroy -var-file="terraform.tfvars" -var="location=$LOCATION"
```

---

## License

[MIT](LICENSE) — see the license file for details.
