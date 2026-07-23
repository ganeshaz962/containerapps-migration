# ─── General ──────────────────────────────────────────────────────────────────

variable "prefix" {
  description = "Short prefix applied to every resource name (lowercase, no spaces)."
  type        = string
  default     = "myapp"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,14}$", var.prefix))
    error_message = "prefix must be 2-15 lowercase alphanumeric characters or hyphens and start with a letter."
  }
}

variable "location" {
  description = "Azure region where all resources are deployed."
  type        = string
  default     = "eastus"
}

variable "resource_group_name" {
  description = "Name of the Azure resource group to create."
  type        = string
  default     = "rg-container-apps"
}

# ─── Container Registry ───────────────────────────────────────────────────────

variable "acr_sku" {
  description = "SKU for Azure Container Registry (Basic | Standard | Premium)."
  type        = string
  default     = "Basic"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.acr_sku)
    error_message = "acr_sku must be Basic, Standard, or Premium."
  }
}

# ─── Application Image ────────────────────────────────────────────────────────

variable "app_image_name" {
  description = "Repository name of the application image in ACR (e.g. 'api' results in <acr>.azurecr.io/api:<tag>)."
  type        = string
  default     = "api"
}

variable "app_image_tag" {
  description = "Image tag to deploy."
  type        = string
  default     = "latest"
}

# ─── Container App Resources ──────────────────────────────────────────────────

variable "app_cpu" {
  description = "vCPU allocated to the application container."
  type        = number
  default     = 0.5
}

variable "app_memory" {
  description = "Memory allocated to the application container (must match a valid Azure Container Apps CPU/memory pairing)."
  type        = string
  default     = "1Gi"
}

variable "min_replicas" {
  description = "Minimum number of running replicas (0 enables scale-to-zero)."
  type        = number
  default     = 1
}

variable "max_replicas" {
  description = "Maximum number of replicas for horizontal scale-out."
  type        = number
  default     = 3
}


