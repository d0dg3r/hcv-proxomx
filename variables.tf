variable "proxmox_api_url" {
  type        = string
  description = "The Proxmox API URL"
  default     = "https://px01.lan:8006/"
}

variable "proxmox_token_name" {
  type        = string
  description = "The Proxmox API Token Name (e.g. root@pam!automation)"
  sensitive   = true
}

variable "proxmox_token" {
  type        = string
  description = "The Proxmox API Token secret"
  sensitive   = true
}

variable "hosts" {
  type        = list(string)
  description = "List of Proxmox node names where Vault nodes will be deployed"
  default     = ["px01", "px02", "px03"]
}

variable "vault_names" {
  type        = list(string)
  description = "Hostnames for the Vault LXC containers"
  default     = ["vault-01", "vault-02", "vault-03"]
}

variable "vault_dns_names" {
  type        = list(string)
  description = "DNS domains for the Vault nodes"
  default     = ["vault-01.lan", "vault-02.lan", "vault-03.lan"]
}

variable "load_balancer_dns" {
  type        = string
  description = "Load balancer DNS name for the cluster"
  default     = "vault.lan"
}

variable "ssh_public_key_path" {
  type        = string
  description = "Path to the SSH public key for injecting into LXC containers"
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_private_key_path" {
  type        = string
  description = "Path to the SSH private key used by provisioners"
  default     = "~/.ssh/id_ed25519"
}

variable "container_cores" {
  type        = number
  description = "Number of CPU cores per container"
  default     = 2
}

variable "container_memory" {
  type        = number
  description = "Amount of dedicated RAM in MB per container"
  default     = 2048
}

variable "container_disk_size" {
  type        = number
  description = "Disk size in GB for the container rootfs"
  default     = 16
}

variable "container_disk_storage" {
  type        = string
  description = "The Proxmox storage pool for the container rootfs"
  default     = "vm-storage-1"
}

variable "template_storage" {
  type        = string
  description = "The Proxmox storage pool where container templates are stored"
  default     = "proxmox-templates"
}

variable "vault_ips" {
  type        = list(string)
  description = "Static IP addresses in CIDR format for the Vault containers"
  default     = ["10.1.3.221/24", "10.1.3.222/24", "10.1.3.223/24"]
}

variable "gateway" {
  type        = string
  description = "Gateway IP address for the containers"
  default     = "10.1.3.11"
}

variable "nameservers" {
  type        = list(string)
  description = "DNS servers for the containers"
  default     = ["10.1.3.11"]
}
