locals {
  # Normalised prefix used across all resource names
  prefix = lower("${var.name}-${var.environment}")

  # Merge caller tags with mandatory platform tags
  base_tags = merge(var.tags, {
    environment = var.environment
    managed-by  = "terraform"
    platform    = "platform-engineering"
  })

  # Key Vault references for secrets: @Microsoft.KeyVault(SecretUri=…)
  kv_app_settings = {
    for setting_name, secret_name in var.key_vault_secrets :
    setting_name => "@Microsoft.KeyVault(VaultName=${local.kv_name};SecretName=${secret_name})"
    if var.key_vault_enabled
  }

  kv_name = var.key_vault_enabled ? reverse(split("/", var.key_vault_id))[0] : ""

  # Tag from the image reference: after "@" for digest pins; otherwise only the
  # last path segment may carry a tag (a ":" in an earlier segment is a
  # registry port, e.g. "registry:5000/img").
  image_last_segment = element(split("/", var.container_image), length(split("/", var.container_image)) - 1)
  image_tag = strcontains(var.container_image, "@") ? split("@", var.container_image)[1] : (
    strcontains(local.image_last_segment, ":") ? split(":", local.image_last_segment)[1] : "latest"
  )

  # Create a local Application Insights resource only when no external one is provided
  create_app_insights = var.application_insights_connection_string == ""

  appinsights_connection_string = local.create_app_insights ? (
    azurerm_application_insights.this[0].connection_string
  ) : var.application_insights_connection_string

  # Whether to provision a Private Endpoint. Driven by an explicit flag so the
  # value is known at plan time (subnet IDs are computed and would force the
  # count to "known after apply").
  create_private_endpoint = var.private_endpoint_enabled

  # App Service authentication reads its client secret from the vault, never
  # from a plaintext setting. Merged last so no caller setting can shadow it.
  auth_app_settings = var.auth_enabled ? {
    MICROSOFT_PROVIDER_AUTHENTICATION_SECRET = "@Microsoft.KeyVault(VaultName=${local.kv_name};SecretName=${azurerm_key_vault_secret.easyauth_client_secret[0].name})"
  } : {}

  auth_tenant_endpoint = "https://login.microsoftonline.com/${data.azuread_client_config.current.tenant_id}/v2.0"

  # The platform probe authenticates itself; excluding the health path serves
  # external monitors. "/" is never excluded, or the whole root would be open.
  auth_excluded_paths = distinct(concat(
    [for p in [var.health_check_path] : p if p != "/"],
    var.auth_excluded_paths,
  ))
}

# ──────────────────────────────────────────────────────────────────────────────
# Managed Identity
# ──────────────────────────────────────────────────────────────────────────────
resource "azurerm_user_assigned_identity" "this" {
  name                = "id-${local.prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.base_tags
}

# ──────────────────────────────────────────────────────────────────────────────
# Monitoring: Log Analytics + Application Insights
# ──────────────────────────────────────────────────────────────────────────────
resource "azurerm_application_insights" "this" {
  count = local.create_app_insights ? 1 : 0

  name                = "appi-${local.prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  workspace_id        = var.log_analytics_workspace_id
  application_type    = "web"
  tags                = local.base_tags

  # Keep client-IP masking on in telemetry (the azurerm v4 replacement for the
  # deprecated disable_ip_masking = false).
  ip_masking_enabled = true
}

# ──────────────────────────────────────────────────────────────────────────────
# Key Vault access policy: allow the managed identity to read secrets
# ──────────────────────────────────────────────────────────────────────────────
resource "azurerm_key_vault_access_policy" "webapp" {
  count = var.key_vault_enabled ? 1 : 0

  key_vault_id = var.key_vault_id
  tenant_id    = azurerm_user_assigned_identity.this.tenant_id
  object_id    = azurerm_user_assigned_identity.this.principal_id

  secret_permissions = ["Get", "List"]
}

# ──────────────────────────────────────────────────────────────────────────────
# ACR pull role for the managed identity
# (only when using managed identity to pull from a private registry)
# ──────────────────────────────────────────────────────────────────────────────
data "azurerm_container_registry" "this" {
  count = var.container_registry_url != "" && var.container_registry_use_managed_identity ? 1 : 0

  # Derive the registry name from the URL: <name>.azurecr.io → <name>
  name = split(".", var.container_registry_url)[0]
  # A pre-existing ACR lives in its own resource group, not the one this
  # template creates — the caller names it; the app RG is only the fallback.
  resource_group_name = var.container_registry_resource_group_name != "" ? var.container_registry_resource_group_name : var.resource_group_name

  lifecycle {
    # Without this gate, a public registry URL (mcr.microsoft.com, ghcr.io,
    # docker.io) reaches the ACR lookup and fails opaquely on ACR resource-name
    # rules ("alpha numeric characters only", "cannot be less than 5
    # characters") — the first DNS label of the URL is not an ACR name.
    precondition {
      condition     = endswith(var.container_registry_url, ".azurecr.io")
      error_message = "container_registry_use_managed_identity requires an Azure Container Registry URL (*.azurecr.io). Public registries (mcr.microsoft.com, Docker Hub, GHCR) need no credentials — leave the flag off for them."
    }
  }
}

resource "azurerm_role_assignment" "acr_pull" {
  count = var.container_registry_url != "" && var.container_registry_use_managed_identity ? 1 : 0

  scope                = data.azurerm_container_registry.this[0].id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

# ──────────────────────────────────────────────────────────────────────────────
# App Service Plan
# ──────────────────────────────────────────────────────────────────────────────
resource "azurerm_service_plan" "this" {
  name                   = "asp-${local.prefix}"
  resource_group_name    = var.resource_group_name
  location               = var.location
  os_type                = var.os_type
  sku_name               = var.sku_name
  worker_count           = var.worker_count
  zone_balancing_enabled = var.zone_balancing_enabled
  tags                   = local.base_tags

  # Autoscale manages dynamic count after creation; ignore drift on worker_count
  # so terraform plans stay clean once the autoscale rules take over.
  lifecycle {
    ignore_changes = [worker_count]
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Web App
# ──────────────────────────────────────────────────────────────────────────────
resource "azurerm_linux_web_app" "this" {
  name                = "app-${local.prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  service_plan_id     = azurerm_service_plan.this.id
  tags                = local.base_tags

  # ── Security ──────────────────────────────────────────────────────────────
  https_only                    = true
  public_network_access_enabled = var.public_network_access_enabled
  client_affinity_enabled       = false # stateless; sticky sessions via load balancer if needed

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.this.id]
  }

  # Key Vault references resolve with this identity; the default would be the
  # system-assigned one, which this app does not have.
  key_vault_reference_identity_id = var.key_vault_enabled ? azurerm_user_assigned_identity.this.id : null

  # ── Site configuration ────────────────────────────────────────────────────
  site_config {
    always_on           = true
    http2_enabled       = true
    minimum_tls_version = var.minimum_tls_version
    # The SCM (Kudu) site is a separate endpoint with its own TLS floor, which
    # the provider defaults to 1.2 — pin it to the same baseline as the app.
    scm_minimum_tls_version           = var.minimum_tls_version
    ftps_state                        = "Disabled"
    use_32_bit_worker                 = false
    worker_count                      = 1
    health_check_path                 = var.health_check_path
    health_check_eviction_time_in_min = var.health_check_eviction_time_in_min

    # IP restrictions apply only to the public endpoint. When the public
    # endpoint is closed, the rules are moot (no traffic arrives via that
    # path); when it's open, allowed_ip_ranges tightens which sources reach it.
    dynamic "ip_restriction" {
      for_each = var.public_network_access_enabled ? var.allowed_ip_ranges : []
      content {
        ip_address = ip_restriction.value
        action     = "Allow"
        priority   = 100
        name       = "allow-${ip_restriction.key}"
      }
    }

    # Deny all other inbound traffic when IP restrictions are configured
    dynamic "ip_restriction" {
      for_each = var.public_network_access_enabled && length(var.allowed_ip_ranges) > 0 ? [1] : []
      content {
        ip_address = "Any"
        action     = "Deny"
        priority   = 2147483647
        name       = "deny-all"
      }
    }

    # Container image
    application_stack {
      docker_image_name        = var.container_image
      docker_registry_url      = var.container_registry_url != "" ? "https://${var.container_registry_url}" : "https://index.docker.io"
      docker_registry_username = var.container_registry_username != "" ? var.container_registry_username : null
      docker_registry_password = var.container_registry_password != "" ? var.container_registry_password : null
    }

    # Managed identity for ACR pull
    container_registry_use_managed_identity       = var.container_registry_use_managed_identity && var.container_registry_url != ""
    container_registry_managed_identity_client_id = var.container_registry_use_managed_identity && var.container_registry_url != "" ? azurerm_user_assigned_identity.this.client_id : null
  }

  # ── Application settings ──────────────────────────────────────────────────
  app_settings = merge(
    {
      # Observability
      APPLICATIONINSIGHTS_CONNECTION_STRING      = local.appinsights_connection_string
      ApplicationInsightsAgent_EXTENSION_VERSION = "~3"
      APPLICATIONINSIGHTS_ROLE_NAME              = "${local.prefix}"

      # Avoid credential-based deployments
      WEBSITES_ENABLE_APP_SERVICE_STORAGE = "false"
      DOCKER_ENABLE_CI                    = "false"

      # Container port contract: App Service routes to this port inside the container
      WEBSITES_PORT = tostring(var.container_port)

      # App identity contract; the pipeline restamps these on each deploy
      APP_NAME  = var.name
      APP_ENV   = var.environment
      IMAGE_TAG = local.image_tag
    },
    var.app_settings,
    local.kv_app_settings,
    local.auth_app_settings,
  )

  # ── Authentication ────────────────────────────────────────────────────────
  dynamic "auth_settings_v2" {
    for_each = var.auth_enabled ? [1] : []
    content {
      auth_enabled           = true
      require_authentication = true
      require_https          = true
      unauthenticated_action = var.auth_unauthenticated_action
      default_provider       = "azureactivedirectory"
      excluded_paths         = local.auth_excluded_paths

      active_directory_v2 {
        client_id                  = azuread_application_registration.auth[0].client_id
        tenant_auth_endpoint       = local.auth_tenant_endpoint
        client_secret_setting_name = "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET"
        allowed_audiences          = local.auth_allowed_audiences
        allowed_applications       = local.auth_allowed_applications
      }

      # No downstream calls on the user's behalf, so nothing to store; the
      # token store would also need persistent storage the container disables.
      login {
        token_store_enabled = false
      }
    }
  }

  # Settings pinned to each slot during a swap. The role name labels the
  # slot, not the deployed container, so it must not travel with a swap;
  # everything else (IMAGE_TAG included) follows the container.
  sticky_settings {
    app_setting_names = ["APPLICATIONINSIGHTS_ROLE_NAME"]
  }

  # ── Logging ───────────────────────────────────────────────────────────────
  logs {
    detailed_error_messages = true
    failed_request_tracing  = true

    http_logs {
      file_system {
        retention_in_days = 7
        retention_in_mb   = 35
      }
    }
  }

  # ── VNet integration ──────────────────────────────────────────────────────
  virtual_network_subnet_id = var.virtual_network_subnet_id != "" ? var.virtual_network_subnet_id : null

  lifecycle {
    # CI/CD owns the running application after first apply. Two attributes
    # are therefore ignored once the app exists:
    #
    # - `application_stack` — image, registry URL, and any registry
    #   credentials. Ignoring only `docker_image_name` left
    #   `docker_registry_url` exposed: when CI deploys to a different
    #   registry than var.container_registry_url, the plan recomposes the
    #   whole block and reverts the image to the var. Ignoring the whole
    #   nested block avoids that.
    # - `app_settings` — Terraform seeds the initial settings at creation
    #   (observability wiring, the port contract, Key Vault references, the
    #   caller's app_settings) and then hands ownership to the deployment
    #   pipeline, which stamps the app identity (e.g. APP_ENV, IMAGE_TAG)
    #   and whatever settings the application grows to need. Without this,
    #   any re-provision would strip the pipeline-managed settings and
    #   restart the app with stale configuration. Trade-off: post-creation
    #   changes to var.app_settings, key_vault_secrets, container_port, or
    #   the Application Insights wiring no longer reconcile onto an
    #   existing app — apply them through the pipeline
    #   (az webapp config appsettings set) or recreate the app.
    #
    # Re-runs still reconcile everything else (TLS, health check,
    # networking, identity) without disturbing the deployed app.
    ignore_changes = [
      site_config[0].application_stack,
      app_settings,
    ]

    precondition {
      condition     = !(var.container_registry_use_managed_identity && var.container_registry_username != "")
      error_message = "container_registry_use_managed_identity and container_registry_username are mutually exclusive — managed identity is the ACR path, username/password the GHCR/Docker Hub path."
    }

    precondition {
      condition     = !contains(keys(var.app_settings), "WEBSITES_PORT")
      error_message = "Do not set WEBSITES_PORT in app_settings — use container_port to declare the container's listening port. container_port is the single source of truth and sets WEBSITES_PORT automatically."
    }

    precondition {
      condition     = !var.auth_enabled || var.key_vault_enabled
      error_message = "auth_enabled requires key_vault_enabled and key_vault_id — the authentication client secret and the end-to-end test credentials are stored in that vault."
    }
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Deployment slot (staging) for zero-downtime swap
# ──────────────────────────────────────────────────────────────────────────────
resource "azurerm_linux_web_app_slot" "staging" {
  count          = var.deployment_slot_enabled ? 1 : 0
  name           = "staging"
  app_service_id = azurerm_linux_web_app.this.id
  tags           = local.base_tags

  https_only                    = true
  public_network_access_enabled = false
  client_affinity_enabled       = false

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.this.id]
  }

  key_vault_reference_identity_id = var.key_vault_enabled ? azurerm_user_assigned_identity.this.id : null

  site_config {
    always_on           = false # staging slot does not need to stay warm
    http2_enabled       = true
    minimum_tls_version = var.minimum_tls_version
    # Same rationale as the main app: the slot's SCM endpoint defaults to 1.2.
    scm_minimum_tls_version = var.minimum_tls_version
    ftps_state              = "Disabled"

    # Health check swaps with the general site config, so the slot must
    # mirror the app or a swap would strip it from production; it also gives
    # the platform a warmup probe before the swap completes.
    health_check_path                 = var.health_check_path
    health_check_eviction_time_in_min = var.health_check_eviction_time_in_min

    application_stack {
      docker_image_name        = var.container_image
      docker_registry_url      = var.container_registry_url != "" ? "https://${var.container_registry_url}" : "https://index.docker.io"
      docker_registry_username = var.container_registry_username != "" ? var.container_registry_username : null
      docker_registry_password = var.container_registry_password != "" ? var.container_registry_password : null
    }

    container_registry_use_managed_identity       = var.container_registry_use_managed_identity && var.container_registry_url != ""
    container_registry_managed_identity_client_id = var.container_registry_use_managed_identity && var.container_registry_url != "" ? azurerm_user_assigned_identity.this.client_id : null
  }

  app_settings = merge(
    {
      APPLICATIONINSIGHTS_CONNECTION_STRING      = local.appinsights_connection_string
      ApplicationInsightsAgent_EXTENSION_VERSION = "~3"
      APPLICATIONINSIGHTS_ROLE_NAME              = "${local.prefix}-staging"
      WEBSITES_ENABLE_APP_SERVICE_STORAGE        = "false"
      WEBSITES_PORT                              = tostring(var.container_port)
      APP_NAME                                   = var.name
      APP_ENV                                    = var.environment
      IMAGE_TAG                                  = local.image_tag
    },
    var.app_settings,
    local.kv_app_settings,
    local.auth_app_settings,
  )

  # Authentication swaps with the site config, so the slot mirrors the app.
  dynamic "auth_settings_v2" {
    for_each = var.auth_enabled ? [1] : []
    content {
      auth_enabled           = true
      require_authentication = true
      require_https          = true
      unauthenticated_action = var.auth_unauthenticated_action
      default_provider       = "azureactivedirectory"
      excluded_paths         = local.auth_excluded_paths

      active_directory_v2 {
        client_id                  = azuread_application_registration.auth[0].client_id
        tenant_auth_endpoint       = local.auth_tenant_endpoint
        client_secret_setting_name = "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET"
        allowed_audiences          = local.auth_allowed_audiences
        allowed_applications       = local.auth_allowed_applications
      }

      login {
        token_store_enabled = false
      }
    }
  }

  lifecycle {
    # Same rationale as the main app: post-create the slot's container and
    # app settings are owned by CI/CD (slot swaps, manual deploys), so
    # ignore the whole application_stack block and app_settings.
    ignore_changes = [
      site_config[0].application_stack,
      app_settings,
    ]
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# End-to-end TLS encryption (front-end ↔ worker hop inside App Service).
# Patches siteConfig.endToEndEncryptionEnabled = true on the Web App and the
# staging slot. The hashicorp/azurerm provider does not yet expose this
# attribute (see provider issue #25126), so we use azapi to PATCH it.
#
# azapi_resource_action (not azapi_update_resource) is used here because
# azurerm_linux_web_app resets endToEndEncryptionEnabled on every PUT it
# issues. azapi_update_resource only re-applies when its own body changes,
# so it would not recover from that reset. azapi_resource_action runs the
# PATCH on every terraform apply, ensuring the setting is always enforced.
# ──────────────────────────────────────────────────────────────────────────────
resource "azapi_resource_action" "end_to_end_encryption" {
  type        = "Microsoft.Web/sites@2024-04-01"
  resource_id = azurerm_linux_web_app.this.id
  method      = "PATCH"

  body = {
    properties = {
      siteConfig = {
        endToEndEncryptionEnabled = true
      }
    }
  }
}

resource "azapi_resource_action" "end_to_end_encryption_slot" {
  count       = var.deployment_slot_enabled ? 1 : 0
  type        = "Microsoft.Web/sites/slots@2024-04-01"
  resource_id = azurerm_linux_web_app_slot.staging[0].id
  method      = "PATCH"

  body = {
    properties = {
      siteConfig = {
        endToEndEncryptionEnabled = true
      }
    }
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Authentication (Microsoft Entra ID via App Service authentication)
#
# Two app registrations: the API itself (what browsers sign in to and what
# tokens are issued for) and a confidential client for non-interactive
# end-to-end tests, which obtains tokens with the client-credentials grant.
# Sign-in is by assignment: the enterprise application requires it, people are
# assigned to the User role by the app's owners outside Terraform, and the
# test client is assigned to E2E.Access here.
# ──────────────────────────────────────────────────────────────────────────────
data "azuread_client_config" "current" {}

locals {
  auth_client_id = var.auth_enabled ? azuread_application_registration.auth[0].client_id : ""
  e2e_client_id  = var.auth_enabled ? azuread_application_registration.e2e[0].client_id : ""

  # v2 tokens carry the client ID as audience; the identifier URI form is what
  # clients request (scope api://<id>/.default), so accept both.
  auth_allowed_audiences    = var.auth_enabled ? [local.auth_client_id, "api://${local.auth_client_id}"] : []
  auth_allowed_applications = var.auth_enabled ? [local.auth_client_id, local.e2e_client_id] : []

  # Owners manage assignments. The deployer stays an owner so it can keep
  # managing the enterprise application on later applies.
  auth_admin_object_ids = [for a in var.auth_admins : a if can(regex("^[0-9a-fA-F-]{36}$", a))]
  auth_admin_upns       = [for a in var.auth_admins : a if !can(regex("^[0-9a-fA-F-]{36}$", a))]
  auth_owner_ids = distinct(concat(
    [data.azuread_client_config.current.object_id],
    local.auth_admin_object_ids,
    length(local.auth_admin_upns) > 0 && var.auth_enabled ? data.azuread_users.auth_admins[0].object_ids : [],
  ))
}

data "azuread_users" "auth_admins" {
  count = var.auth_enabled && length(local.auth_admin_upns) > 0 ? 1 : 0

  user_principal_names = local.auth_admin_upns
}

resource "azuread_application_registration" "auth" {
  count = var.auth_enabled ? 1 : 0

  display_name     = "app-${local.prefix}"
  description      = "App Service authentication for ${local.prefix}"
  sign_in_audience = "AzureADMyOrg"

  # The sign-in flow requests an ID token alongside the code.
  implicit_id_token_issuance_enabled = true
  requested_access_token_version     = 2
}

resource "azuread_application_identifier_uri" "auth" {
  count = var.auth_enabled ? 1 : 0

  application_id = azuread_application_registration.auth[0].id
  identifier_uri = "api://${azuread_application_registration.auth[0].client_id}"
}

resource "azuread_application_app_role" "user" {
  count = var.auth_enabled ? 1 : 0

  application_id       = azuread_application_registration.auth[0].id
  role_id              = uuidv5("url", "https://${local.prefix}/roles/user")
  allowed_member_types = ["User"]
  display_name         = "User"
  description          = "Interactive access, granted by the application's owners"
  value                = "User"
}

# Role the test client is assigned to.
resource "azuread_application_app_role" "e2e" {
  count = var.auth_enabled ? 1 : 0

  application_id       = azuread_application_registration.auth[0].id
  role_id              = uuidv5("url", "https://${local.prefix}/roles/e2e-access")
  allowed_member_types = ["Application"]
  display_name         = "End-to-end tests"
  description          = "Non-interactive access for the end-to-end test client"
  value                = "E2E.Access"
}

resource "azuread_service_principal" "auth" {
  count = var.auth_enabled ? 1 : 0

  client_id                    = azuread_application_registration.auth[0].client_id
  app_role_assignment_required = true
  owners                       = local.auth_owner_ids
  description                  = "Sign-in for ${local.prefix}; only assigned users and clients"

  # Without this tag the portal's Enterprise applications list hides the app
  # behind its default filter.
  feature_tags {
    enterprise = true
  }
}

# Secrets are valid for two years from creation; the expiry is fixed at create
# time (ignore_changes), so rotation is an explicit replace of this resource.
resource "azuread_application_password" "auth" {
  count = var.auth_enabled ? 1 : 0

  application_id = azuread_application_registration.auth[0].id
  display_name   = "app-service-authentication"
  end_date       = timeadd(timestamp(), "17520h")

  lifecycle {
    ignore_changes = [end_date]
  }
}

# Callback URLs need the hostnames, which exist only after the app is created;
# a separate resource avoids a cycle between the registration and the app.
resource "azuread_application_redirect_uris" "auth" {
  count = var.auth_enabled ? 1 : 0

  application_id = azuread_application_registration.auth[0].id
  type           = "Web"
  redirect_uris = concat(
    ["https://${azurerm_linux_web_app.this.default_hostname}/.auth/login/aad/callback"],
    var.deployment_slot_enabled ? ["https://${azurerm_linux_web_app_slot.staging[0].default_hostname}/.auth/login/aad/callback"] : [],
  )
}

resource "azuread_application_registration" "e2e" {
  count = var.auth_enabled ? 1 : 0

  display_name     = "app-${local.prefix}-e2e"
  description      = "End-to-end test client for ${local.prefix}"
  sign_in_audience = "AzureADMyOrg"

  requested_access_token_version = 2
}

resource "azuread_service_principal" "e2e" {
  count = var.auth_enabled ? 1 : 0

  client_id = azuread_application_registration.e2e[0].client_id
}

resource "azuread_application_password" "e2e" {
  count = var.auth_enabled ? 1 : 0

  application_id = azuread_application_registration.e2e[0].id
  display_name   = "end-to-end-tests"
  end_date       = timeadd(timestamp(), "17520h")

  lifecycle {
    ignore_changes = [end_date]
  }
}

resource "azuread_app_role_assignment" "e2e" {
  count = var.auth_enabled ? 1 : 0

  app_role_id         = azuread_application_app_role.e2e[0].role_id
  principal_object_id = azuread_service_principal.e2e[0].object_id
  resource_object_id  = azuread_service_principal.auth[0].object_id
}

# Secrets land in the vault: the sign-in client secret is read by App Service
# through a Key Vault reference; the test credentials are read by the tests.
resource "azurerm_key_vault_secret" "easyauth_client_secret" {
  count = var.auth_enabled ? 1 : 0

  name            = "easyauth-client-secret"
  value           = azuread_application_password.auth[0].value
  key_vault_id    = var.key_vault_id
  content_type    = "text/plain"
  expiration_date = azuread_application_password.auth[0].end_date
  tags            = local.base_tags
}

locals {
  e2e_secrets = var.auth_enabled ? {
    "e2e-tenant-id" = data.azuread_client_config.current.tenant_id
    "e2e-client-id" = azuread_application_registration.e2e[0].client_id
    "e2e-scope"     = "api://${azuread_application_registration.auth[0].client_id}/.default"
  } : {}
}

# Non-secret coordinates of the test client, kept next to its secret so tests
# read everything from one place.
resource "azurerm_key_vault_secret" "e2e" {
  for_each = local.e2e_secrets

  name            = each.key
  value           = each.value
  key_vault_id    = var.key_vault_id
  content_type    = "text/plain"
  expiration_date = azuread_application_password.e2e[0].end_date
  tags            = local.base_tags
}

resource "azurerm_key_vault_secret" "e2e_client_secret" {
  count = var.auth_enabled ? 1 : 0

  name            = "e2e-client-secret"
  value           = azuread_application_password.e2e[0].value
  key_vault_id    = var.key_vault_id
  content_type    = "text/plain"
  expiration_date = azuread_application_password.e2e[0].end_date
  tags            = local.base_tags
}

# ──────────────────────────────────────────────────────────────────────────────
# Private endpoint (inbound)
# ──────────────────────────────────────────────────────────────────────────────
resource "azurerm_private_endpoint" "this" {
  count               = local.create_private_endpoint ? 1 : 0
  name                = "pe-${local.prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id
  tags                = local.base_tags

  private_service_connection {
    name                           = "psc-${local.prefix}"
    private_connection_resource_id = azurerm_linux_web_app.this.id
    subresource_names              = ["sites"]
    is_manual_connection           = false
  }

  dynamic "private_dns_zone_group" {
    for_each = var.private_dns_zone_id != "" ? [1] : []
    content {
      name                 = "dns-${local.prefix}"
      private_dns_zone_ids = [var.private_dns_zone_id]
    }
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Autoscale settings
# ──────────────────────────────────────────────────────────────────────────────
resource "azurerm_monitor_autoscale_setting" "this" {
  count               = var.autoscale_enabled ? 1 : 0
  name                = "autoscale-${local.prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  target_resource_id  = azurerm_service_plan.this.id
  tags                = local.base_tags

  profile {
    name = "default"

    capacity {
      default = var.autoscale_default_count
      minimum = var.autoscale_min_count
      maximum = var.autoscale_max_count
    }

    # Scale-out rules are OR-ed: either CPU or memory above its high threshold
    # adds an instance. Scale-in rules are AND-ed by Azure autoscale: an
    # instance is removed only when CPU *and* memory are both below their low
    # thresholds, so a memory-bound plan is never scaled in on idle CPU alone.
    rule {
      metric_trigger {
        metric_name        = "CpuPercentage"
        metric_resource_id = azurerm_service_plan.this.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = var.autoscale_cpu_high_threshold
      }
      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }

    rule {
      metric_trigger {
        metric_name        = "CpuPercentage"
        metric_resource_id = azurerm_service_plan.this.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT10M"
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = var.autoscale_cpu_low_threshold
      }
      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT10M"
      }
    }

    rule {
      metric_trigger {
        metric_name        = "MemoryPercentage"
        metric_resource_id = azurerm_service_plan.this.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = var.autoscale_memory_high_threshold
      }
      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }

    rule {
      metric_trigger {
        metric_name        = "MemoryPercentage"
        metric_resource_id = azurerm_service_plan.this.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT10M"
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = var.autoscale_memory_low_threshold
      }
      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT10M"
      }
    }
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Diagnostic settings → Log Analytics
# ──────────────────────────────────────────────────────────────────────────────
resource "azurerm_monitor_diagnostic_setting" "webapp" {
  name                       = "diag-${local.prefix}"
  target_resource_id         = azurerm_linux_web_app.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "AppServiceHTTPLogs"
  }
  enabled_log {
    category = "AppServiceConsoleLogs"
  }
  enabled_log {
    category = "AppServiceAppLogs"
  }
  enabled_log {
    category = "AppServiceAuditLogs"
  }
  enabled_log {
    category = "AppServiceIPSecAuditLogs"
  }
  enabled_log {
    category = "AppServicePlatformLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "plan" {
  name                       = "diag-plan-${local.prefix}"
  target_resource_id         = azurerm_service_plan.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_metric {
    category = "AllMetrics"
  }
}
