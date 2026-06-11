# Download Rocky Linux 10 LXC template to templates storage
resource "proxmox_download_file" "rocky_template" {
  node_name          = "px01" # Perform the download through px01 node onto shared storage
  content_type       = "vztmpl"
  datastore_id       = var.template_storage
  file_name          = "rockylinux-10-default_20251001_amd64.tar.xz"
  url                = "http://download.proxmox.com/images/system/rockylinux-10-default_20251001_amd64.tar.xz"
  checksum           = "025d346a9aa9b27b90c28147cece917659cb320508cf248f59c776a00fd3a7009a9e1e0812217c990398588bb11b5a38abca82c0991a161ba3f27e1c6ee190ac"
  checksum_algorithm = "sha512"
}

# Create the 3 LXC containers for HashiCorp Vault
resource "proxmox_virtual_environment_container" "vault" {
  count = 3

  node_name = var.hosts[count.index]
  vm_id     = 201 + count.index # Assign 201, 202, 203 VMIDs

  tags = ["vault", "rocky10", "high-availability"]

  started       = true
  start_on_boot = true

  unprivileged = true

  features {
    nesting = true
  }

  initialization {
    hostname = var.vault_names[count.index]
    
    ip_config {
      ipv4 {
        address = var.vault_ips[count.index]
        gateway = var.gateway
      }
    }

    dns {
      servers = var.nameservers
    }

    user_account {
      keys = [trimspace(file(pathexpand(var.ssh_public_key_path)))]
    }
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
  }

  disk {
    datastore_id = var.container_disk_storage
    size         = var.container_disk_size
  }

  cpu {
    cores = var.container_cores
  }

  memory {
    dedicated = var.container_memory
    swap      = 512
  }

  operating_system {
    template_file_id = proxmox_download_file.rocky_template.id
    type             = "centos"
  }
}
