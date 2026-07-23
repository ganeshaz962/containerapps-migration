# ─────────────────────────────────────────────────────────────────────────────
# Random suffix – keeps ACR name globally unique
# ─────────────────────────────────────────────────────────────────────────────
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
  numeric = true
}

# ─────────────────────────────────────────────────────────────────────────────
# Resource Group
# ─────────────────────────────────────────────────────────────────────────────
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location

  tags = local.common_tags
}

# ─────────────────────────────────────────────────────────────────────────────
# Log Analytics Workspace (required by Container Apps Environment)
# ─────────────────────────────────────────────────────────────────────────────
resource "azurerm_log_analytics_workspace" "law" {
  name                = "${var.prefix}-law-${random_string.suffix.result}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = local.common_tags
}

# ─────────────────────────────────────────────────────────────────────────────
# Azure Container Registry
# ─────────────────────────────────────────────────────────────────────────────
resource "azurerm_container_registry" "acr" {
  # ACR name: 5-50 chars, alphanumeric only, globally unique
  name                = "${replace(var.prefix, "-", "")}${random_string.suffix.result}acr"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = var.acr_sku

  # Disable admin credentials – the Container App pulls via Managed Identity
  admin_enabled = false

  tags = local.common_tags
}

# ─────────────────────────────────────────────────────────────────────────────
# User-Assigned Managed Identity for ACR pull
# Using a user-assigned identity lets you pre-assign RBAC before the Container
# App exists, avoiding a circular dependency.
# ─────────────────────────────────────────────────────────────────────────────
resource "azurerm_user_assigned_identity" "acr_pull" {
  name                = "${var.prefix}-acr-pull-id"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  tags = local.common_tags
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.acr_pull.principal_id

  # Needed because Entra ID propagation can lag behind the role assignment
  skip_service_principal_aad_check = false
}

# ─────────────────────────────────────────────────────────────────────────────
# Container Apps Environment
# ─────────────────────────────────────────────────────────────────────────────
resource "azurerm_container_app_environment" "env" {
  name                       = "${var.prefix}-cae-${random_string.suffix.result}"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id

  tags = local.common_tags
}

# ─────────────────────────────────────────────────────────────────────────────
# Cloudflare Origin Certificate (uploaded to the Container Apps Environment)
# Required to fix SSL 525 errors when Cloudflare proxies to the Container App.
# ─────────────────────────────────────────────────────────────────────────────
resource "azurerm_container_app_environment_certificate" "cloudflare_origin" {
  count = var.custom_domain != "" ? 1 : 0

  name                         = "cloudflare-origin-cert"
  container_app_environment_id = azurerm_container_app_environment.env.id
  certificate_blob_base64      = var.cloudflare_origin_cert_pfx_base64
  certificate_password         = var.cloudflare_origin_cert_password
}

# ─────────────────────────────────────────────────────────────────────────────
# Container App
#
# Security model:
#   • External ingress enabled on port 3000.
#   • Cloudflare sits in front: add a CNAME in your Cloudflare DNS zone pointing
#     to the container_app_fqdn output value, then enable the Cloudflare proxy
#     (orange cloud) so all traffic is routed through Cloudflare's edge.
#   • IP security restrictions allow ONLY Cloudflare's published IP ranges;
#     any direct request that bypasses Cloudflare is rejected by Azure.
# ─────────────────────────────────────────────────────────────────────────────
resource "azurerm_container_app" "app" {
  name                         = "${var.prefix}-app"
  container_app_environment_id = azurerm_container_app_environment.env.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"

  # Managed Identity used to pull images from ACR
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.acr_pull.id]
  }

  # ACR registry authentication via Managed Identity (no username/password)
  registry {
    server   = azurerm_container_registry.acr.login_server
    identity = azurerm_user_assigned_identity.acr_pull.id
  }

  # ── External ingress – Cloudflare IPs only ────────────────────────────────
  # Port 3000 is publicly reachable, but Azure rejects any request whose
  # source IP does not belong to Cloudflare's published ranges.
  #
  # After deploy, create a CNAME record in Cloudflare DNS:
  #   Type  : CNAME
  #   Name  : <your-hostname>  (e.g. api)
  #   Value : <container_app_fqdn output>
  #   Proxy : Enabled (orange cloud) ← required to enforce IP restrictions
  ingress {
    external_enabled = true
    target_port      = 3000
    transport        = "auto"

    traffic_weight {
      percentage      = 100
      latest_revision = true
    }

    # Allow only Cloudflare edge nodes. All other source IPs are denied.
    # IP list source: https://www.cloudflare.com/ips/
    dynamic "ip_security_restriction" {
      for_each = { for idx, cidr in local.cloudflare_ip_ranges : "cloudflare-${idx}" => cidr }
      content {
        action           = "Allow"
        ip_address_range = ip_security_restriction.value
        name             = ip_security_restriction.key
        description      = "Allow Cloudflare edge IP range"
      }
    }

    # Bind the custom domain + Cloudflare Origin Certificate when provided
    dynamic "custom_domain" {
      for_each = var.custom_domain != "" ? [var.custom_domain] : []
      content {
        name                     = custom_domain.value
        certificate_id           = azurerm_container_app_environment_certificate.cloudflare_origin[0].id
        certificate_binding_type = "SniEnabled"
      }
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    # ── Application Container ───────────────────────────────────────────────
    container {
      name   = "app"
      image  = "${azurerm_container_registry.acr.login_server}/${var.app_image_name}:${var.app_image_tag}"
      cpu    = var.app_cpu
      memory = var.app_memory

      # Tell the application which port to bind
      env {
        name  = "PORT"
        value = "3000"
      }
    }

  }

  tags = local.common_tags

  depends_on = [
    azurerm_role_assignment.acr_pull,
  ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Local values
# ─────────────────────────────────────────────────────────────────────────────
locals {
  common_tags = {
    project     = var.prefix
    managed_by  = "terraform"
    environment = "production"
  }

  # Cloudflare published IP ranges – https://www.cloudflare.com/ips/
  # Review periodically; Cloudflare announces changes at least 30 days in advance.
  cloudflare_ipv4_ranges = [
    "173.245.48.0/20",
    "103.21.244.0/22",
    "103.22.200.0/22",
    "103.31.4.0/22",
    "141.101.64.0/18",
    "108.162.192.0/18",
    "190.93.240.0/20",
    "188.114.96.0/20",
    "197.234.240.0/22",
    "198.41.128.0/17",
    "162.158.0.0/15",
    "104.16.0.0/13",
    "104.24.0.0/14",
    "172.64.0.0/13",
    "131.0.72.0/22",
  ]

  # Note: Azure Container Apps IP security restrictions do not support IPv6.
  # Only Cloudflare IPv4 ranges are used here.
  cloudflare_ip_ranges = local.cloudflare_ipv4_ranges
}
