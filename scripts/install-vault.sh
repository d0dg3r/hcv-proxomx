#!/usr/bin/env bash
set -euo pipefail

echo "=== Starting Vault Installation on Rocky Linux ==="

# Wait for any background package manager processes to finish
if command -v systemctl &> /dev/null; then
    echo "Waiting for systemd-dpkg-lock / dnf transactions if any..."
    sleep 5
fi

# Add HashiCorp RPM Repository
echo "Adding HashiCorp repository..."
curl -L https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo -o /etc/yum.repos.d/hashicorp.repo

# Install Vault package
echo "Installing Vault..."
dnf install -y vault

# Create persistent storage directory for Raft
echo "Creating Raft data directory..."
mkdir -p /opt/vault/data
chown -R vault:vault /opt/vault/data
chmod 750 /opt/vault/data

# Ensure permissions on configuration and TLS certificates
echo "Setting configuration and certificate permissions..."
chown -R vault:vault /etc/vault.d
chmod 750 /etc/vault.d
chmod 640 /etc/vault.d/vault.hcl
chmod 644 /etc/vault.d/vault.crt
chmod 600 /etc/vault.d/vault.key
chmod 644 /etc/vault.d/ca.crt

# Enable and start Vault service
echo "Starting Vault service..."
systemctl daemon-reload
systemctl enable vault.service
systemctl restart vault.service

echo "=== Vault Installation Complete ==="
