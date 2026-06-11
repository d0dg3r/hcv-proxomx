output "vault_nodes" {
  description = "The names and resolved IPs of the Vault containers"
  value = {
    for idx, name in var.vault_names : name => {
      node_name  = var.hosts[idx]
      ip_address = split("/", var.vault_ips[idx])[0]
      api_url    = "https://${split("/", var.vault_ips[idx])[0]}:8200"
    }
  }
}

output "ca_certificate" {
  description = "The generated self-signed Root CA certificate. Save this as ca.crt to verify TLS."
  value       = tls_self_signed_cert.ca.cert_pem
}

output "initialization_instructions" {
  description = "Steps to initialize and unseal the Vault cluster"
  value       = <<EOT
1. Save the CA Certificate to a local file:
   terraform output -raw ca_certificate > ca.crt

2. Initialize the Vault cluster on the first node:
   export VAULT_ADDR="https://${split("/", var.vault_ips[0])[0]}:8200"
   export VAULT_CACERT="$(pwd)/ca.crt"
   vault operator init -key-shares=5 -key-threshold=3

3. Unseal the first node:
   vault operator unseal <unseal-key-1>
   vault operator unseal <unseal-key-2>
   vault operator unseal <unseal-key-3>

4. Unseal the second and third nodes (they will automatically join the Raft cluster):
   # For Node 2 (vault02):
   export VAULT_ADDR="https://${split("/", var.vault_ips[1])[0]}:8200"
   vault operator unseal <unseal-key-1>
   vault operator unseal <unseal-key-2>
   vault operator unseal <unseal-key-3>

   # For Node 3 (vault03):
   export VAULT_ADDR="https://${split("/", var.vault_ips[2])[0]}:8200"
   vault operator unseal <unseal-key-1>
   vault operator unseal <unseal-key-2>
   vault operator unseal <unseal-key-3>

5. Check Raft cluster status (back on Node 1):
   export VAULT_ADDR="https://${split("/", var.vault_ips[0])[0]}:8200"
   vault operator raft list-peers
EOT
}
