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
rather than by site config), `CKV_AZURE_88` (Azure Files), `CKV_AZURE_13`
(Easy Auth — authentication is the application's concern) and `CKV_AZURE_17`
(client certificates — inbound traffic arrives through the Private Endpoint).
Each entry carries its rationale inline in the file.

If you add a skip, put it in both files with a comment explaining why and a
tracking reference.

### Checkov fails when scanning `terraform/modules` directly

Expected, and not a real finding. With no caller, Checkov evaluates the module
*defaults*, which are deliberately non-prod-shaped (single worker, no zone
redundancy), so the strict baseline fails checks that every actual deployment
satisfies. Always scan an environment directory — the modules are assessed
three times that way, each under its real configuration.
