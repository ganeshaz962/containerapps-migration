output "resource_group_name" {
  description = "Name of the deployed resource group."
  value       = azurerm_resource_group.rg.name
}

output "acr_login_server" {
  description = "ACR login server URL. Use this when tagging and pushing images: docker push <acr_login_server>/<image>:<tag>"
  value       = azurerm_container_registry.acr.login_server
}

output "acr_name" {
  description = "Name of the Azure Container Registry."
  value       = azurerm_container_registry.acr.name
}

output "container_app_name" {
  description = "Name of the deployed Container App."
  value       = azurerm_container_app.app.name
}

output "container_app_environment_name" {
  description = "Name of the Container Apps Environment."
  value       = azurerm_container_app_environment.env.name
}

output "acr_pull_identity_client_id" {
  description = "Client ID of the user-assigned managed identity used for ACR pulls. Required when configuring the identity in CI/CD pipelines."
  value       = azurerm_user_assigned_identity.acr_pull.client_id
}

output "container_app_fqdn" {
  description = "Public FQDN of the Container App. Use this as the CNAME value in your Cloudflare DNS zone."
  value       = azurerm_container_app.app.latest_revision_fqdn
}

output "cloudflare_dns_setup" {
  description = "Cloudflare DNS configuration instructions."
  value       = <<-EOT
    Add a CNAME record in your Cloudflare zone:
      Type  : CNAME
      Name  : <your-hostname>  (e.g. api or app)
      Value : ${azurerm_container_app.app.latest_revision_fqdn}
      Proxy : Enabled (orange cloud)  ← required to enforce the IP allowlist
  EOT
}

output "push_image_commands" {
  description = "Shell commands to authenticate to ACR and push your first image."
  value       = <<-EOT
    # 1. Log in to ACR
    az acr login --name ${azurerm_container_registry.acr.name}

    # 2. Build and tag your image
    docker build -t ${azurerm_container_registry.acr.login_server}/${var.app_image_name}:${var.app_image_tag} .

    # 3. Push to ACR
    docker push ${azurerm_container_registry.acr.login_server}/${var.app_image_name}:${var.app_image_tag}
  EOT
}
