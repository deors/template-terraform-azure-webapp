## Troubleshooting

Issues with the Azure resources this template creates. Problems with the
provisioning pipeline itself — GitHub Actions, Terraform remote state, or
OIDC/Entra login to Azure — are documented by the platform:
[workshop-platform-eng troubleshooting](https://deors.github.io/workshop-platform-eng/troubleshooting/).

### Checkov fails on `prod` but passed on `dev`/`staging`

Intended. `prod` is scanned against `.checkov.yaml`; `dev` and `staging` use
`.checkov.nonprod.yaml`, which additionally skips three prod-only baselines:

| Check | Why it's skipped for non-prod |
|-------|-------------------------------|
| `CKV_AZURE_212` | Minimum instances for failover — dev/staging start at 1 worker |
| `CKV_AZURE_222` | Public network access disabled — dev keeps the public endpoint open for runner smoke tests |
| `CKV_AZURE_225` | App Service Plan zone redundancy — only prod is zone-redundant |

Both configs skip a further set in every environment: the runtime-version
checks (`CKV_AZURE_80`/`81`/`82`/`84`, all managed by the container image
rather than by site config), `CKV_AZURE_88` (Azure Files) and `CKV_AZURE_17`
(client certificates — inbound traffic arrives through the Private Endpoint).
The non-prod file also skips `CKV_AZURE_42`/`CKV_AZURE_110` (Key Vault purge
protection, enabled in prod only). Each entry carries its rationale inline in
the file.

If you add a skip, put it in both files with a comment explaining why and a
tracking reference.

### Checkov fails when scanning `terraform/modules` directly

Expected, and not a real finding. With no caller, Checkov evaluates the module
*defaults*, which are deliberately non-prod-shaped (single worker, no zone
redundancy), so the strict baseline fails checks that every actual deployment
satisfies. Always scan an environment directory — the modules are assessed
three times that way, each under its real configuration.

### `tofu apply` fails with `Insufficient privileges to complete the operation` on `azuread_app_role_assignment`

The end-to-end test client is assigned to the API's `E2E.Access` role, and
that Graph call needs `AppRoleAssignment.ReadWrite.All` plus
`Application.Read.All` on the identity running Terraform, with admin consent.
`Application.ReadWrite.OwnedBy` alone covers the registrations, secrets and
redirect URIs but not assignments. Grant the two permissions with admin
consent and re-run the apply; every other resource is already in place.

### Users see `AADSTS50105: The signed in user is not assigned to a role for the application`

Intended: the enterprise application requires assignment. An owner of
`app-<app>-<env>` (or a directory administrator) assigns the person under
Entra ID → Enterprise applications → `app-<app>-<env>` → Users and groups, or
with `manage-app-access.sh <app> <env> add <user>`. No Terraform change is
involved.

### An unassigned user can still sign in

Check the role, not the gate: Entra exempts **Global Administrators** from the
assignment requirement by design, so an administrator gets in whether assigned
or not. Test refusal with an account that holds no directory role. Also check
`appRoleAssignmentRequired` is `true` on the enterprise application and that
no group the user belongs to is assigned; `manage-app-access.sh <app> <env>
list` shows every assignment.

### The enterprise application does not appear in the portal

The Enterprise applications list filters on "Application type: Enterprise
Applications" by default, which only shows service principals carrying a
specific tag. The template sets that tag; for a stack provisioned before it
did, switch the filter to "All applications", and make sure you are looking at
the tenant that hosts the application, not your home tenant.

### A user from outside the tenant cannot sign in (`AADSTS50020` or `AADSTS700016`)

Intended: the app registration is single-tenant. External people need a guest
invitation to the tenant first (Entra ID → Users → New user → Invite external
user), and an assignment afterwards like anyone else.

### Sign-in fails with `AADSTS7000215: Invalid client secret` or the app returns `401` for every request

App Service reads the client secret through the Key Vault reference in
`MICROSOFT_PROVIDER_AUTHENTICATION_SECRET`. Check, in this order:

1. The secret `easyauth-client-secret` exists in `kv-<app>-<env>`.
2. The Web App's user-assigned identity has an access policy with `Get` on
   secrets (the `webapp` module creates it from `key_vault_id`).
3. `az webapp config appsettings list` shows the reference resolved — an
   unresolved reference is reported under *Configuration* in the portal with
   the reason.

### Re-provisioning fails because the Key Vault name is taken

A deleted vault stays soft-deleted for the retention period with its name
reserved. The `azurerm` provider runs with
`recover_soft_deleted_key_vaults = true`, so the normal path recovers it
transparently. If the vault was deleted from another subscription or tenant,
or the soft-deleted entry is corrupt, list and purge it (not possible in prod,
where purge protection is on — wait out the retention period or pick another
`app_name`):

```bash
az keyvault list-deleted --query "[].{name:name,location:properties.location}" -o table
az keyvault purge --name kv-<app>-<env> --location <location>
```

### Entra app registrations linger after a teardown

Deleting the resource group removes the Web App and the vault, but the
registrations `app-<app>-<env>` and `app-<app>-<env>-e2e` live in the tenant
and are not part of any resource group. They are harmless but accumulate.
Remove them when the environment is gone for good:

```bash
az ad app list --display-name app-<app>-<env> --query "[].{name:displayName,appId:appId}" -o table
az ad app delete --id <appId>
```
