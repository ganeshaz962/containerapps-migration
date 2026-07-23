# Migrating Azure Container Apps from Public Access to Cloudflare-Only Access

## Overview

By default, Azure Container Apps are publicly accessible to anyone on the internet via their Azure-assigned FQDN. This guide walks through restricting that access so **only Cloudflare can reach the Container App**, and all user traffic is routed through Cloudflare's CDN and WAF.

---

## Architecture Before vs After

```
BEFORE
User → Internet → Azure Container App (open to all IPs)

AFTER
User → Cloudflare (CDN / WAF / DDoS) → Azure Container App (Cloudflare IPs only)
```

---

## Why This Setup?

| Benefit | Detail |
|---|---|
| **DDoS protection** | Cloudflare absorbs volumetric attacks before they reach Azure |
| **WAF** | Cloudflare Web Application Firewall blocks OWASP Top 10 threats |
| **Hide origin** | Azure FQDN is never exposed in DNS; attackers cannot bypass Cloudflare |
| **Free TLS** | Cloudflare issues and renews the public-facing SSL certificate |
| **Performance** | Cloudflare caches static assets at edge nodes globally |

---

## Prerequisites

- An existing Azure Container App with **external ingress enabled**
- A domain managed in Cloudflare (DNS hosted on Cloudflare nameservers)
- Azure CLI installed and logged in
- Terraform installed (if managing infrastructure as code)

---

## Step 1 — Add Cloudflare IP Restrictions to the Container App

### Why?
Without this step, even after pointing your domain through Cloudflare, anyone can still find your Azure FQDN (`myapp.eastus.azurecontainerapps.io`) and hit it directly, bypassing all Cloudflare protections.

Adding Cloudflare's published IP ranges as the **only allowed source IPs** means Azure will reject any request that does not originate from Cloudflare's edge nodes.

### What to do

In Terraform, add `ip_security_restriction` blocks inside the `ingress` block of your Container App:

```hcl
ingress {
  external_enabled = true
  target_port      = 3000

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
```

Define the IP ranges as a local variable:

```hcl
locals {
  # Source: https://www.cloudflare.com/ips/
  # Azure Container Apps only supports IPv4 in IP restrictions.
  cloudflare_ip_ranges = [
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
}
```

> **Note:** Azure Container Apps does not support IPv6 in IP security restrictions. Cloudflare handles IPv6 clients at its edge — the Cloudflare → Azure connection is always IPv4, so no coverage is lost.

> **Note:** When any `Allow` rule is present, Azure automatically denies all IPs not in the list. No explicit `Deny all` rule is needed.

Apply the changes:

```bash
terraform apply
```

### Verify

Try accessing the Azure FQDN directly from your browser:
```
https://myapp-app.<env-id>.eastus.azurecontainerapps.io
```
You should receive **403 Access Denied** — this confirms the restriction is working.

---

## Step 2 — Add a CNAME DNS Record in Cloudflare

### Why?
Your users need a human-readable domain (e.g. `app.yourdomain.com`) to reach the application. The CNAME record points that domain to the Azure Container App FQDN. With Cloudflare **proxy enabled (orange cloud)**, Cloudflare sits between the user and Azure — DNS resolves to Cloudflare IPs, not the Azure IP.

### What to do

1. Go to **Cloudflare Dashboard → your domain → DNS → Records → Add record**

2. Add the following:

   | Field | Value |
   |---|---|
   | Type | `CNAME` |
   | Name | `app` (or whatever subdomain you want) |
   | Target | `myapp-app.<env-id>.eastus.azurecontainerapps.io` |
   | Proxy status | **Proxied (orange cloud)** |

   > Get the exact Target value from: `terraform output container_app_fqdn`

3. Save the record.

> **The orange cloud (proxy) is mandatory.** If it is grey (DNS only), Cloudflare resolves directly to the Azure IP, bypassing Cloudflare entirely. Your browser would then connect straight to Azure with your own IP, which is not a Cloudflare IP, and you would receive 403 Access Denied.

### Verify

```powershell
# Should return Cloudflare IPs (104.x / 172.x / 162.x), NOT an Azure IP (20.x / 52.x)
Resolve-DnsName app.yourdomain.com
```

---

## Step 3 — Add Domain Verification TXT Record

### Why?
Before Azure will bind a custom domain to a Container App, it requires proof that you own that domain. Azure generates a unique verification ID per Container App. You prove ownership by publishing that ID as a DNS TXT record.

### What to do

1. Get the verification ID:
   ```bash
   az containerapp show \
     --name myapp-app \
     --resource-group rg-container-apps \
     --query properties.customDomainVerificationId \
     -o tsv
   ```

2. In **Cloudflare DNS**, add a second record:

   | Field | Value |
   |---|---|
   | Type | `TXT` |
   | Name | `asuid.app` (prefix `asuid.` + your subdomain name) |
   | Content | The verification ID from step 1 |
   | Proxy status | **DNS only (grey cloud)** — TXT records cannot be proxied |

---

## Step 4 — Generate a Cloudflare Origin Certificate

### Why?
When Cloudflare (proxy mode) forwards a request to Azure, it opens a new HTTPS connection to the origin. In this TLS handshake, Cloudflare presents the **custom domain hostname** (`app.yourdomain.com`) as the SNI (Server Name Indication).

Azure Container Apps only has a certificate for `*.azurecontainerapps.io` — it does not recognise your custom domain. The TLS handshake fails, causing **Error 525 (SSL Handshake Failed)**.

A **Cloudflare Origin Certificate** is a certificate issued by Cloudflare's own CA, specifically for the Cloudflare → origin (Azure) leg. By uploading it to Azure Container Apps, Azure can present a certificate that matches the SNI sent by Cloudflare, and the handshake succeeds.

> The Cloudflare Origin Certificate is trusted **only by Cloudflare** — it is not trusted by regular browsers. This is intentional: end users never connect directly to Azure, only Cloudflare does.

### What to do

1. In **Cloudflare Dashboard → SSL/TLS → Origin Server → Create Certificate**
   - Key type: RSA (2048)
   - Hostnames: `app.yourdomain.com`
   - Certificate validity: 15 years
   - Format: **PEM**

2. Save both files locally:
   - `origin.pem` — the certificate
   - `origin-key.pem` — the private key

3. Convert to PFX format (required by Azure):
   ```powershell
   openssl pkcs12 -export `
     -in origin.pem `
     -inkey origin-key.pem `
     -out origin.pfx `
     -passout pass:YourPassword123

   # Encode to base64 for Terraform
   [Convert]::ToBase64String([IO.File]::ReadAllBytes("origin.pfx")) | Out-File origin-pfx.txt
   ```

---

## Step 5 — Bind the Custom Domain and Certificate to the Container App

### Why?
Uploading the certificate and binding the custom domain tells Azure to:
- Accept incoming connections presenting SNI for `app.yourdomain.com`
- Respond with the Cloudflare Origin Certificate
- Route requests to the correct Container App

Without this binding, Azure does not associate the custom domain with your app and the TLS handshake fails.

### What to do

In Terraform, add to `terraform.tfvars`:

```hcl
custom_domain                     = "app.yourdomain.com"
cloudflare_origin_cert_pfx_base64 = "<content of origin-pfx.txt>"
cloudflare_origin_cert_password   = "YourPassword123"
```

Add to `main.tf` — upload the certificate to the Container Apps Environment:

```hcl
resource "azurerm_container_app_environment_certificate" "cloudflare_origin" {
  name                         = "cloudflare-origin-cert"
  container_app_environment_id = azurerm_container_app_environment.env.id
  certificate_blob_base64      = var.cloudflare_origin_cert_pfx_base64
  certificate_password         = var.cloudflare_origin_cert_password
}
```

Bind the custom domain inside the `ingress` block of the Container App:

```hcl
dynamic "custom_domain" {
  for_each = var.custom_domain != "" ? [var.custom_domain] : []
  content {
    name                     = custom_domain.value
    certificate_id           = azurerm_container_app_environment_certificate.cloudflare_origin.id
    certificate_binding_type = "SniEnabled"
  }
}
```

Apply:
```bash
terraform apply
```

---

## Step 6 — Set Cloudflare SSL Mode to Full

### Why?
Cloudflare has four SSL modes. After uploading the Origin Certificate, the correct mode is **Full**:

| Mode | Cloudflare → Origin | Certificate verified | Use when |
|---|---|---|---|
| Off | HTTP | — | Never |
| Flexible | HTTP | — | Origin has no HTTPS support |
| **Full** | **HTTPS** | **Not strict** | **Cloudflare Origin Cert (our setup)** |
| Full (Strict) | HTTPS | Must match domain | Public CA cert on origin |

**Full** encrypts the Cloudflare → Azure leg without requiring a publicly trusted certificate. **Full (Strict)** would reject the Cloudflare Origin Certificate because it is not signed by a public CA.

### What to do

1. **Cloudflare Dashboard → SSL/TLS → Overview**
2. Select **Full**

---

## Verification Checklist

```
[ ] Direct Azure URL returns 403              → IP restrictions working
[ ] DNS resolves to Cloudflare IPs            → Orange cloud enabled
[ ] https://app.yourdomain.com loads the app  → Full path working
[ ] Response headers include cf-ray           → Cloudflare is proxying
[ ] SSL certificate shown is from Cloudflare  → TLS working end-to-end
```

---

## Ongoing Maintenance

**Cloudflare IP ranges change occasionally.** Cloudflare announces changes at least 30 days in advance at:
- https://www.cloudflare.com/ips-v4

When ranges change, update the `cloudflare_ipv4_ranges` local in `main.tf` and run `terraform apply`.

**Origin Certificate expiry:** The Cloudflare Origin Certificate is valid for 15 years if selected during creation. Set a calendar reminder before expiry to regenerate and re-upload.
