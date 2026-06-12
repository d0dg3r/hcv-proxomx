#!/usr/bin/env bash
set -euo pipefail

# Config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS_DIR="$WORKSPACE_DIR/secrets"

KEYS_FILE="$SECRETS_DIR/vault-keys.json"
CA_FILE="$SECRETS_DIR/ca.crt"
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
export VAULT_CACERT="$CA_FILE"
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
SSH_CA_PUB="$SECRETS_DIR/vault_ssh_ca.pub"
echo "Retrieving SSH CA public key..."
vault read -field=public_key ssh-client-signer/config/ca > "$SSH_CA_PUB"
echo "SSH CA public key saved to: $SSH_CA_PUB"

# Store SSH CA public key in Vault KV engine
echo "Storing SSH CA public key in Vault KV engine..."
if ! vault secrets list -format=json | jq -e '."secret/"' >/dev/null; then
    vault secrets enable -path=secret kv-v2
fi
vault kv put secret/ssh-ca public_key=@"$SSH_CA_PUB"
echo "SSH CA public key successfully backed up in Vault at secret/ssh-ca."

# 4. Create SSH roles for signing client keys
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

echo "Creating SSH role 'admin-role' (with agent forwarding) with 30-minute max TTL..."
vault write ssh-client-signer/roles/admin-role - <<EOF
{
  "key_type": "ca",
  "allow_user_certificates": true,
  "allowed_users": "root,admin",
  "default_extensions": {
    "permit-pty": "",
    "permit-port-forwarding": "",
    "permit-agent-forwarding": ""
  },
  "max_ttl": "30m",
  "ttl": "10m"
}
EOF

echo "----------------------------------------"
echo "SSH Secrets Engine successfully configured!"
echo "Role Names: client-role, admin-role"
echo "SSH CA Public Key: $SSH_CA_PUB"
echo "----------------------------------------"
echo "To sign a key using admin-role, run:"
echo "  vault write -field=signed_key ssh-client-signer/sign/admin-role public_key=@~/.ssh/id_ed25519.pub valid_principals=\"root\" > ~/.ssh/id_ed25519-cert.pub"
