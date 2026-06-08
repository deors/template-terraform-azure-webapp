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
    ├── monitoring/    # Log Analytics Workspace
    ├── networking/    # VNet, Subnets, NSGs, Private DNS, Flow Logs
    └── webapp/        # App Service Plan, Web App, Identity, ACI, Private Endpoint, Autoscale, Diagnostics

scripts/
└── verify.sh          # Post-apply control-plane verification (see below)
```

---

## Verification

This template owns its own post-apply verification at the canonical path
`scripts/verify.sh`. After `terraform apply`, the **workshop-platform-eng**
orchestrator checks out the generated `{app-name}-infra` repository and runs
this script, then surfaces the pass/fail counts. Because the assertions live
next to the Terraform that defines the expectations (SKU, zone redundancy,
worker count, TLS, staging slot, …), the orchestrator stays template-agnostic:
any infra template that exposes `scripts/verify.sh` plugs in without changing
the platform.

The script reads `APP_NAME` and `ENVIRONMENT`, queries Azure with `az`, and
exits non-zero if any check fails. To run it locally against a deployed
environment (an `az login` session must be active):

```bash
APP_NAME=<app> ENVIRONMENT=<env> bash scripts/verify.sh
```

---

## Environment-Specific Baselines

### Development (`dev/`)

- **Compute**: P0v3 (smallest Premium v3 SKU, supports VNet integration)
- **Instances**: 1 (no autoscale, no failover)
- **Availability**: Single region, no zone redundancy
- **Networking**: Public endpoint open (for GitHub Actions smoke tests) + Private Endpoint
- **Log Retention**: 30 days
- **Staging Slot**: Disabled
- **Deployment Slot**: N/A
- **Checkov Baseline**: Relaxed (non-prod config skips failover/zone-redundancy checks)

### Staging (`staging/`)

- **Compute**: P1v3 (standard production SKU)
- **Instances**: 1–3 (autoscale on CPU/memory)
- **Availability**: Single region, no zone redundancy
- **Networking**: Private Endpoint only (no public access)
- **Log Retention**: 60 days
- **Staging Slot**: Enabled (for pre-swap validation)
- **Deployment Slot**: N/A
- **Checkov Baseline**: Relaxed (non-prod config skips failover/zone-redundancy checks)

### Production (`prod/`)

- **Compute**: P2v3 (larger SKU)
- **Instances**: 3–10 (autoscale on CPU/memory, minimum 3 for zone redundancy)
- **Availability**: Zone redundant (Azure Availability Zones)
- **Networking**: Private Endpoint only (public access disabled)
- **Log Retention**: 90 days
- **Staging Slot**: Enabled (mandatory for blue/green deployments)
- **Deployment Slot**: Enabled for zero-downtime swaps
- **Checkov Baseline**: Strict (prod config enforces failover instances, zone redundancy, PE-only access)

---

## Security & Compliance

### Network Isolation

- **Egress**: App Service VNet integration + NSGs restrict outbound to Azure services (HTTPS 443, DNS 53) only
- **Inbound**: Private Endpoint + optional IP restrictions on public endpoint (dev only)
- **Flow Logs**: Network traffic diagnostics logged to dedicate storage for compliance audit trails

### Identity & Access

- **Managed Identity**: User-assigned identity per Web App for Azure service authentication (no secrets in config)
- **RBAC**: Role assignments (AcrPull for container registry, Key Vault access for secrets)
- **TLS**: Minimum 1.3 enforced on production; 1.2 or 1.3 in dev/staging

### Compliance

- **Checkov**: Infrastructure security policy enforcement with environment-specific baselines (prod strict, dev/staging relaxed)
- **Diagnostics**: Comprehensive logging to Log Analytics (HTTP logs, console logs, audit logs, platform logs)
- **Encryption**: End-to-end TLS encryption (App Service end-to-end enabled via azapi provider)

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

### Custom Domain

Production supports custom domain binding with managed certificate:

```hcl
custom_domain = "myapp.example.com"
managed_certificate = true
```

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

### 1. Bootstrap Terraform State (one-time)

```bash
./scripts/bootstrap-tfstate.sh \
  --app-name myapp \
  --subscription-id <GUID> \
  --location westeurope
```

Creates a dedicated Azure Storage Account for remote state (idempotent).

### 2. Plan

```bash
cd terraform/environments/dev
terraform init \
  -backend-config="resource_group_name=rg-tfstate-myapp" \
  -backend-config="storage_account_name=sttfmyapp<sub-short>" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=dev/terraform.tfstate"
terraform plan -var-file="terraform.tfvars"
```

### 3. Apply

```bash
terraform apply tfplan
```

---

## License

[MIT](LICENSE) — see the license file for details.
