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

      # Liveness probe – restarts the container if the app becomes unresponsive
      liveness_probe {
        transport = "HTTP"
        port      = 3000
        path      = "/healthz"

        initial_delay           = 10
        interval_seconds        = 15
        failure_count_threshold = 3
      }

      # Readiness probe – gates traffic until the app is ready
      readiness_probe {
        transport = "HTTP"
        port      = 3000
        path      = "/healthz"

        interval_seconds        = 5
        failure_count_threshold = 3
        success_count_threshold = 1
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

  cloudflare_ipv6_ranges = [
    "2400:cb00::/32",
    "2606:4700::/32",
    "2803:f800::/32",
    "2405:b500::/32",
    "2405:8100::/32",
    "2a06:98c0::/29",
    "2c0f:f248::/32",
  ]

  cloudflare_ip_ranges = concat(local.cloudflare_ipv4_ranges, local.cloudflare_ipv6_ranges)
}
