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
| **Authentication** | Microsoft Entra ID sign-in enforced by App Service on the Web App and its slot; access by assignment, managed by the app's owners, plus a non-interactive end-to-end test client | All environments |
| **Key Vault** | Application secrets and the authentication credentials, referenced from app settings | Yes (purge protection in prod) |
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
| `rg-<app_name>-<env>` | All resources for one environment — VNet, App Service Plan, Web App, Private Endpoint, Key Vault, Log Analytics Workspace, Application Insights, metric alerts, NSGs, Private DNS Zone, and VNet Flow Log storage | Terraform, in this repo (per environment) |
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
    ├── keyvault/      # Key Vault for application secrets and authentication credentials
    ├── monitoring/    # Log Analytics Workspace, metric alerts
    ├── networking/    # VNet, Subnets, NSGs, Private DNS, Flow Logs
    └── webapp/        # App Service Plan, Web App, Identity, Authentication, Private Endpoint, Autoscale, Diagnostics

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
staging slot, Key Vault (soft delete, purge protection, the seeded
authentication secrets), authentication (enabled on the app and mirrored on
the slot, health check path excluded, assignment required, test client
assigned, assigned people listed), and public endpoint.

All but the last are control-plane assertions. The **public endpoint** group is
the one that sends real traffic against the default `*.azurewebsites.net`
hostname: an unauthenticated `GET /` must get `401` as an API client and a
`302` to sign-in as a browser, the health check path must answer `200` without
credentials (unless it is `/`, which stays behind sign-in), and a `GET /`
with a token obtained as the end-to-end test client (credentials read from the
Key Vault) must answer `200`. Because `curl` validates the certificate chain by
default, this doubles as a check that Azure's wildcard certificate is serving
correctly — a TLS failure surfaces as `000`, not a status code.

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
| **Key Vault purge protection** | Off — the vault can be purged after a teardown | Off | On — irreversible; a deleted vault stays recoverable, not recreatable, for 90 days |
| **Post-apply probe** | HTTPS on the default hostname: `401`/`302` unauthenticated (API/browser), `200` on the health path, `200` as the end-to-end client | Control plane only | Control plane only |
| **Checkov baseline** | `.checkov.nonprod.yaml` (relaxed) | `.checkov.nonprod.yaml` (relaxed) | `.checkov.yaml` (strict) |

---

## Security & Compliance

### Network Isolation

- **Egress**: App Service VNet integration + NSGs restrict outbound to Azure services (HTTPS 443, DNS 53) only
- **Inbound**: Private Endpoint + optional IP restrictions on public endpoint (dev only)
- **Flow Logs**: Network traffic diagnostics logged to dedicate storage for compliance audit trails

### Identity & Access

- **Authentication**: Microsoft Entra ID sign-in enforced by App Service on the Web App and its slot, in every environment. Only people assigned to the app's enterprise application sign in; its owners manage that list outside Terraform. A non-interactive client exists for end-to-end tests. See [Authentication](#authentication).
- **Secrets**: One Key Vault per environment holds the authentication credentials and the application's own secrets; the app reads them through Key Vault references with its managed identity, never from plaintext settings. See [Key Vault Integration](#key-vault-integration).
- **Managed Identity**: User-assigned identity per Web App for Azure service authentication (no secrets in config)
- **RBAC**: Role assignments (AcrPull for container registry) and Key Vault access policies for secrets
- **TLS**: 1.3 only, in every environment. The `webapp` module defaults `minimum_tls_version` to `"1.3"` and its validation block accepts no other value, so no caller can weaken the floor to 1.2. The floor covers the Web App, the deployment slot, and both SCM (Kudu) endpoints, whose provider default would otherwise be 1.2. Production passes the value explicitly as documentation of intent; dev and staging inherit the same default. `scripts/verify.sh` re-asserts `minTlsVersion` and `scmMinTlsVersion` = 1.3 against the deployed app in all three environments. One documented exception: the flow-log storage account sits at `TLS1_2` because Azure Storage's `minimumTlsVersion` offers no 1.3 value — its only client is Microsoft's own flow-log writer.

### Compliance

- **Checkov**: Infrastructure security policy enforcement with environment-specific baselines (prod strict, dev/staging relaxed)
- **Logging**: Comprehensive logging to Log Analytics (HTTP logs, console logs, audit logs, platform logs)
- **Encryption**: End-to-end TLS encryption (App Service end-to-end enabled via azapi provider)

---

## Customization

### Container Contract

The template is built around the archetype's container contract: **port 8080, health endpoint `/health`**. `health_check_path` defaults to `/health`. `container_port` defaults to `8080` and sets `WEBSITES_PORT` on both the Web App and the staging slot — this is how Azure App Service learns which port the container listens on.

Do not set `WEBSITES_PORT` directly in `app_settings` — `container_port` is the single source of truth and the template enforces this with a plan-time error if `WEBSITES_PORT` appears in `app_settings`.

### App Settings

App-specific environment variables are passed via `app_settings` map in each
environment's `.tfvars`; they become plain environment variables on the
container. Do not put secrets here — use
[Key Vault Integration](#key-vault-integration) instead.

The template always injects the archetype's environment-variable contract:
`PORT` (via `WEBSITES_PORT`, from `container_port`), `APP_NAME`, `APP_ENV`
(the environment name), and `IMAGE_TAG` (parsed from the image reference).
Applications should read these rather than invent their own names; a key
redefined in `app_settings` overrides the injected value. Example:

```hcl
app_settings = {
  DATABASE_URL = "postgresql://..."
  API_KEY      = "..."
}
```

Terraform owns these settings only at creation: it seeds the initial set and
then ignores drift on them. From the first deployment onwards the pipeline
owns them — it restamps the identity variables on each deploy and adds new
settings as the application evolves, and a re-apply never strips them. The
flip side: changing these inputs in Terraform affects only newly created
stacks; on a running app, settings are applied through the deployment
pipeline.

### Key Vault Integration

Each environment owns a Key Vault, `kv-<app_name>-<env>`, created by the
`keyvault` module. The template seeds the authentication credentials into it;
application secrets go into the same vault and reach the container as
environment variables through `key_vault_secrets`, which maps a setting name
to a secret name:

```hcl
key_vault_secrets = {
  DB_PASSWORD = "db-password-secret-name"
  API_TOKEN   = "api-token-secret-name"
}
```

The secrets themselves are created outside Terraform (portal, `az keyvault
secret set`, or the deployment pipeline); the Web App resolves the references
with its user-assigned identity, which the template grants `Get`/`List` on the
vault through an access policy. The vault uses access policies rather than
Azure RBAC and keeps its data plane on the public endpoint, because Terraform
seeds secrets from GitHub-hosted runners outside the VNet; authorisation is
the control. Purge protection is enabled in prod only (see
[Environment-Specific Baselines](#environment-specific-baselines)).

### Container Registry

The pull happens at runtime, by the Web App's managed identity or stored
registry credentials — never by the identity running Terraform. The auth path
is selected by what you provide:

| Registry | Configure | Pull authenticates as |
|---|---|---|
| Public (`mcr.microsoft.com`, public Docker Hub/GHCR) | `container_registry_url` only | Anonymous — no credentials involved |
| Private ACR (`*.azurecr.io`) | `container_registry_url` + `container_registry_resource_group_name` | The Web App's managed identity; the template grants it `AcrPull` |
| Private GHCR / Docker Hub | `container_registry_url` + `container_registry_username` + `container_registry_password` | The provided username + token, stored in the app's registry settings |

```hcl
container_registry_url                 = "myregistry.azurecr.io"
container_registry_resource_group_name = "rg-shared-registries"
container_image                        = "myapp:v1.2.3"
```

`container_image` is the repository path and tag **without the registry host**;
the template prepends `container_registry_url` when composing the image
reference. Passing `myregistry.azurecr.io/myapp:v1.2.3` here produces
`myregistry.azurecr.io/myregistry.azurecr.io/myapp:v1.2.3`, which no registry
serves.

Granting `AcrPull` requires locating the registry, so
`container_registry_resource_group_name` names the resource group the ACR
lives in. It defaults to the environment's own group when unset — only
correct for an ACR created inside this environment, which a pre-existing
registry never is.

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

### Authentication

Every environment enforces Microsoft Entra ID sign-in through App Service
authentication, on the Web App and on its deployment slot. Unauthenticated
browsers are redirected to sign in; the health check path stays open for
external monitors (the platform probe authenticates itself). Access is by
assignment: the enterprise application `app-<app_name>-<env>` requires it,
and only people assigned to its `User` role get in. Terraform sets that gate
and never manages the people; the app's owners (`auth_admins`, plus the
deployer) assign and remove users in the portal or with the
`manage-app-access.sh` helper, so onboarding is never an apply. External
people are invited to the tenant as guests first. Self-registration is
deliberately not offered. One exemption is Entra's own: Global Administrators
are never subject to the assignment requirement.

For non-interactive callers the template creates one confidential client per
environment, `app-<app_name>-<env>-e2e`, and stores its tenant, client ID,
client secret and scope in the environment's Key Vault as `e2e-*` secrets. An
end-to-end test obtains a token with the client-credentials grant and sends it
as a bearer token; `scripts/verify.sh` does exactly that against dev.

Inputs: `auth_enabled` (default `true`) switches the whole feature and
`auth_admins` names the owners; the module also accepts
`auth_unauthenticated_action` (`Return401` for pure APIs) and
`auth_excluded_paths`. The identity running Terraform needs Microsoft
Graph application permissions, with admin consent, to create the
registrations and the test client's role assignment:
`Application.ReadWrite.OwnedBy`, `AppRoleAssignment.ReadWrite.All` and
`Application.Read.All` (plus `User.Read.All` only when `auth_admins` carries
user principal names). The token flow the end-to-end client uses is the one
`scripts/verify.sh` runs against dev after every apply.

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
  -var="container_image=azuredocs/aci-helloworld:latest" \
  -var="container_registry_url=mcr.microsoft.com" \
  -var="health_check_path=/" \
  -var="container_port=80" \
  -out=tfplan
```

This plan for `dev` deploys a public placeholder image
(`azuredocs/aci-helloworld` from `mcr.microsoft.com`) with `health_check_path = "/"` and
`container_port = 80`, so the template can be applied and verified end to end before
a real application image exists. Swap `container_image`, `container_registry_url`,
`health_check_path`, and `container_port` for your own app's values when moving past
validation — real apps follow the contract: port 8080, health endpoint `/health`.

With authentication on (the default), opening the placeholder in a browser
redirects to Microsoft Entra sign-in; only a user assigned to the enterprise
application `app-<app_name>-<env>` gets through, so assign yourself first
(see [Authentication](#authentication)).

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
  -var="container_image=azuredocs/aci-helloworld:latest" \
  -var="container_registry_url=mcr.microsoft.com" \
  -var="health_check_path=/" \
  -var="container_port=80"
```

---

## License

[MIT](LICENSE) — see the license file for details.
