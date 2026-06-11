locals {
  all_ips = [for i in range(3) : split("/", var.vault_ips[i])[0]]
}

# Bootstraps SSH access inside unprivileged Rocky Linux containers via Proxmox hosts
resource "terraform_data" "lxc_bootstrap" {
  count = 3

  triggers_replace = [
    proxmox_virtual_environment_container.vault[count.index].id
  ]

  connection {
    type        = "ssh"
    user        = "root"
    private_key = file(pathexpand(var.ssh_private_key_path))
    host        = var.hosts[count.index]
  }

  provisioner "remote-exec" {
    inline = [
      "sleep 5",
      # Install OpenSSH server inside Rocky Linux LXC container
      "pct exec ${proxmox_virtual_environment_container.vault[count.index].vm_id} -- dnf install -y openssh-server",
      # Enable and start sshd service
      "pct exec ${proxmox_virtual_environment_container.vault[count.index].vm_id} -- systemctl enable --now sshd"
    ]
  }
}

resource "terraform_data" "provision" {
  count = 3

  # Force provisioning to run after the containers are created or certificates change
  triggers_replace = [
    proxmox_virtual_environment_container.vault[count.index].id,
    var.vault_ips[count.index],
    tls_locally_signed_cert.vault[count.index].cert_pem,
    tls_self_signed_cert.ca.cert_pem
  ]

  depends_on = [terraform_data.lxc_bootstrap]

  connection {
    type        = "ssh"
    user        = "root"
    private_key = file(pathexpand(var.ssh_private_key_path))
    host        = split("/", var.vault_ips[count.index])[0]
  }

  # 1. Upload TLS CA Certificate
  provisioner "file" {
    content     = tls_self_signed_cert.ca.cert_pem
    destination = "/tmp/ca.crt"
  }

  # 2. Upload Node TLS Certificate
  provisioner "file" {
    content     = tls_locally_signed_cert.vault[count.index].cert_pem
    destination = "/tmp/vault.crt"
  }

  # 3. Upload Node Private Key
  provisioner "file" {
    content     = tls_private_key.vault[count.index].private_key_pem
    destination = "/tmp/vault.key"
  }

  # 4. Upload Vault Configuration
  provisioner "file" {
    content = templatefile("${path.module}/templates/vault.hcl.tftpl", {
      node_id  = var.vault_names[count.index]
      node_ip  = split("/", var.vault_ips[count.index])[0]
      peer_ips = local.all_ips
    })
    destination = "/tmp/vault.hcl"
  }

  # 5. Upload Installation Script
  provisioner "file" {
    source      = "${path.module}/scripts/install-vault.sh"
    destination = "/tmp/install-vault.sh"
  }

  # 6. Run Installation Script & move files
  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/install-vault.sh",
      "/tmp/install-vault.sh",
      # Move files from /tmp to /etc/vault.d/ (creates the folder if needed)
      "mkdir -p /etc/vault.d",
      "mv /tmp/ca.crt /etc/vault.d/ca.crt",
      "mv /tmp/vault.crt /etc/vault.d/vault.crt",
      "mv /tmp/vault.key /etc/vault.d/vault.key",
      "mv /tmp/vault.hcl /etc/vault.d/vault.hcl",
      # Apply strict permissions and ownership to Vault config files
      "chown -R vault:vault /etc/vault.d",
      "chmod 750 /etc/vault.d",
      "chmod 640 /etc/vault.d/vault.hcl",
      "chmod 644 /etc/vault.d/vault.crt",
      "chmod 600 /etc/vault.d/vault.key",
      "chmod 644 /etc/vault.d/ca.crt",
      # Restart service to apply the configuration
      "systemctl restart vault.service"
    ]
  }
}
