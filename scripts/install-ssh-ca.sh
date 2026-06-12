#!/usr/bin/env bash
#
# Script to install Vault SSH CA public key on a target server
# Supports Debian/Ubuntu, RHEL/CentOS/Rocky Linux, and Arch Linux
#

set -euo pipefail

# Define target paths
CA_PATH="/etc/ssh/trusted-user-ca-keys.pem"
SSHD_CONFIG="/etc/ssh/sshd_config"

# Get Vault address from argument or environment variable, default to https://vault.lan
VAULT_ADDR="${1:-${VAULT_ADDR:-https://vault.lan}}"

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root. Please use sudo or run as root user." >&2
    exit 1
fi

echo "=== Starting Vault SSH CA Installation ==="
echo "Vault Address: $VAULT_ADDR"

# 1. Fetch the SSH CA public key from Vault
echo "Fetching SSH CA public key from Vault..."
if ! SSH_CA_KEY=$(curl -k -s -f "${VAULT_ADDR}/v1/ssh-client-signer/public_key"); then
    echo "Error: Failed to fetch SSH CA public key from Vault at ${VAULT_ADDR}/v1/ssh-client-signer/public_key" >&2
    echo "Please check if Vault is running and accessible." >&2
    exit 1
fi

# Verify the response is a valid SSH key
if [[ ! "$SSH_CA_KEY" =~ ^ssh- ]]; then
    echo "Error: Retrieved key content does not look like a valid SSH public key." >&2
    echo "Content received: $SSH_CA_KEY" >&2
    exit 1
fi

echo "Writing Vault SSH CA key to $CA_PATH..."
echo "$SSH_CA_KEY" > "$CA_PATH"

# Set secure permissions
chown root:root "$CA_PATH"
chmod 644 "$CA_PATH"
echo "Permissions for CA key file set successfully."

# 2. Update sshd_config
echo "Configuring $SSHD_CONFIG..."
if [ ! -f "$SSHD_CONFIG" ]; then
    echo "Error: $SSHD_CONFIG not found on this system!" >&2
    exit 1
fi

# Check if TrustedUserCAKeys directive is already configured
if grep -q "^TrustedUserCAKeys" "$SSHD_CONFIG"; then
    CURRENT_VALUE=$(grep "^TrustedUserCAKeys" "$SSHD_CONFIG")
    echo "TrustedUserCAKeys is already configured: $CURRENT_VALUE"
    
    if [[ "$CURRENT_VALUE" != *"$CA_PATH"* ]]; then
        echo "Warning: TrustedUserCAKeys points to a different path. You might want to review this manually."
    fi
else
    # Append the configuration directive
    echo "" >> "$SSHD_CONFIG"
    echo "# Trusted SSH CA keys from Vault" >> "$SSHD_CONFIG"
    echo "TrustedUserCAKeys $CA_PATH" >> "$SSHD_CONFIG"
    echo "Added TrustedUserCAKeys directive to $SSHD_CONFIG."
fi

# 3. Detect and restart the correct SSH systemd service
echo "Detecting SSH systemd service..."

if systemctl list-units --type=service --state=active,loaded | grep -q "sshd.service"; then
    echo "sshd.service found. Restarting..."
    systemctl restart sshd
    echo "sshd service restarted."
elif systemctl list-units --type=service --state=active,loaded | grep -q "ssh.service"; then
    echo "ssh.service found. Restarting..."
    systemctl restart ssh
    echo "ssh service restarted."
else
    echo "Warning: Could not detect active ssh or sshd systemd service."
    echo "Please restart your SSH daemon manually (e.g. systemctl restart sshd or systemctl restart ssh)."
fi

echo "=== Vault SSH CA Installation Complete! ==="
echo "This server now trusts SSH certificates signed by the Vault CA."
