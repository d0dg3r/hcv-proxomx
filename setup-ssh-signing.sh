#!/usr/bin/env bash
set -euo pipefail

KEYS_FILE="vault-keys.json"
CA_FILE="ca.crt"
PRIMARY_NODE="10.1.3.221"

if [ ! -f "$KEYS_FILE" ]; then
    echo "Error: $KEYS_FILE not found! Has the cluster been initialized?"
    exit 1
fi

if [ ! -f "$CA_FILE" ]; then
    echo "Error: $CA_FILE not found!"
    exit 1
fi

# Load root token and configure environment
ROOT_TOKEN=$(jq -r '.root_token' "$KEYS_FILE")
export VAULT_CACERT="$(pwd)/$CA_FILE"
export VAULT_ADDR="https://${PRIMARY_NODE}:8200"
export VAULT_TOKEN="$ROOT_TOKEN"

echo "=== Setting up SSH Client Key Signing Secrets Engine ==="

# 1. Enable SSH secrets engine at path 'ssh-client-signer'
if ! vault secrets list -format=json | jq -e '."ssh-client-signer/"' >/dev/null; then
    echo "Enabling SSH secrets engine..."
    vault secrets enable -path=ssh-client-signer ssh
else
    echo "SSH secrets engine is already enabled."
fi

# 2. Configure Vault CA key pair for SSH signing if not already configured
echo "Checking SSH CA configuration..."
if ! vault read -format=json ssh-client-signer/config/ca >/dev/null 2>&1; then
    echo "Configuring new SSH CA key pair..."
    vault write -f ssh-client-signer/config/ca
else
    echo "SSH CA is already configured."
fi

# 3. Retrieve and save the SSH CA public key locally
SSH_CA_PUB="vault_ssh_ca.pub"
echo "Retrieving SSH CA public key..."
vault read -field=public_key ssh-client-signer/config/ca > "$SSH_CA_PUB"
echo "SSH CA public key saved to: $(pwd)/$SSH_CA_PUB"

# 4. Create an SSH role for signing client keys
echo "Creating SSH role 'client-role' with 30-minute max TTL..."
vault write ssh-client-signer/roles/client-role - <<EOF
{
  "key_type": "ca",
  "allow_user_certificates": true,
  "allowed_users": "*",
  "default_extensions": {
    "permit-pty": "",
    "permit-port-forwarding": ""
  },
  "max_ttl": "30m",
  "ttl": "10m"
}
EOF


echo "----------------------------------------"
echo "SSH Secrets Engine successfully configured!"
echo "Role Name: client-role"
echo "SSH CA Public Key: $(pwd)/$SSH_CA_PUB"
echo "----------------------------------------"
echo "To sign a client key, use the CLI:"
echo "  vault write -field=signed_key ssh-client-signer/sign/client-role public_key=@~/.ssh/id_ed25519.pub > ~/.ssh/id_ed25519-cert.pub"
