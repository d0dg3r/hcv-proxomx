#!/usr/bin/env bash
#
# Script to install Vault SSH CA public key on a target server
# Supports Debian/Ubuntu, RHEL/CentOS/Rocky Linux, and Arch Linux
#

set -euo pipefail

# Define target paths
CA_PATH="/etc/ssh/trusted-user-ca-keys.pem"
SSHD_CONFIG="/etc/ssh/sshd_config"

# Embedded Vault SSH CA Public Key (vault_ssh_ca.pub)
SSH_CA_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDkoN1/FfSryALDKzNWwU0eE6l1x0Ptx6Mclc8bUIYqrJckH4kNKMN0m0D3odBok/VIv0zujA+1seaz14e81/yJ5LSIff3VU4+glRvyqRoP0qdkn0vn4JfpehzJbIbtj2Gr7y+JMSrutFozisn0hA3lwTc2gLr25kOUOZrV7kjrbU+abvo6wBuvjeIIl1B8V2Usoyq3q299/DsnmV80asqzrxqBpk9P/jMsF/lIY+Ex7Tit/POfzlzOYghmtR1AiJa6PJ624xp/WfVmIhGlDE5nE8zDIxaOptqo+E12oxBC+E1QIZQyhIPLTY4Yq58fN12NXY6/4x8XfQJDFRo4Qki0ChCtAmcnR7A2OHmZLCOvkcKyWFVuqhV07c7rij5OVsxqespkeJtHF6a/6TuATNdEQaW6nw/EMX7qnOlSl0YwOFaOaZlWyKsIni4arMokNKCf50O5lb+nN2fp4mmb83SJjyO5SM9d10E2XUCbfiokXVrhbIfCYQQDoAcPmAXZFO1pTN23NiaS6DcXE3gdq6LhSgKq3phC1OIkQ00hOetp92vowVyLRIiULAQ6vJXppxM8Zj1kSv1AQsMwpddP3ScLEzM+dOlhyXMc04gOjaebuhfYFb9iUaFlLTURx21kCF4G51mMA/KunF4dT7YJYNUemJuPa6IAPmvZLP8HofKQcw=="

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root. Please use sudo or run as root user." >&2
    exit 1
fi

echo "=== Starting Vault SSH CA Installation ==="

# 1. Write the CA public key to the target path
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
