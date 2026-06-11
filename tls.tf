# Generate Private Key for Root CA
resource "tls_private_key" "ca" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Generate Self-Signed Root CA Certificate
resource "tls_self_signed_cert" "ca" {
  private_key_pem = tls_private_key.ca.private_key_pem

  is_ca_certificate = true

  subject {
    common_name  = "Vault Internal Root CA"
    organization = "DevOps"
  }

  validity_period_hours = 87600 # 10 years

  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "key_encipherment",
  ]
}

# Generate Private Key for each Vault Node
resource "tls_private_key" "vault" {
  count     = 3
  algorithm = "RSA"
  rsa_bits  = 2048
}

# Generate Certificate Request (CSR) for each Vault Node
resource "tls_cert_request" "vault" {
  count           = 3
  private_key_pem = tls_private_key.vault[count.index].private_key_pem

  subject {
    common_name  = var.vault_dns_names[count.index]
    organization = "DevOps"
  }

  # SANs: Hostnames, DNS names, Load Balancer name, and localhost
  dns_names = [
    var.vault_names[count.index],
    var.vault_dns_names[count.index],
    var.load_balancer_dns,
    "localhost"
  ]

  # IP SANs: localhost and container static IP
  ip_addresses = [
    "127.0.0.1",
    split("/", var.vault_ips[count.index])[0]
  ]
}

# Sign Vault Node Certificates with our CA
resource "tls_locally_signed_cert" "vault" {
  count                 = 3
  cert_request_pem      = tls_cert_request.vault[count.index].cert_request_pem
  ca_private_key_pem    = tls_private_key.ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca.cert_pem
  validity_period_hours = 17520 # 2 years

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
    "client_auth",
  ]
}
