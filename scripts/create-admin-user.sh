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

echo "=== Creating Vault Admin User ==="

# 1. Enable userpass auth method if not already enabled
if ! vault auth list -format=json | jq -e '."userpass/"' >/dev/null; then
    echo "Enabling userpass auth method..."
    vault auth enable userpass
else
    echo "Userpass auth method is already enabled."
fi

# 2. Define the admin policy
POLICY_NAME="admin"
POLICY_FILE="admin-policy.hcl"

echo "Writing admin policy..."
cat <<EOF > "$POLICY_FILE"
# Grant full access to all paths
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF

vault policy write "$POLICY_NAME" "$POLICY_FILE"
rm -f "$POLICY_FILE"

# 3. Define admin username and password
USERNAME="admin"

# Read password from argument or prompt the user, or generate a random one
if [ "${1:-}" != "" ]; then
    PASSWORD="$1"
else
    # Generate a secure random password if none provided
    PASSWORD=$(openssl rand -base64 18)
fi

echo "Creating user '$USERNAME' with admin policy..."
vault write "auth/userpass/users/$USERNAME" \
    password="$PASSWORD" \
    policies="$POLICY_NAME"

# 4. Store admin credentials in Vault KV engine
echo "Storing admin credentials in Vault KV engine..."
if ! vault secrets list -format=json | jq -e '."secret/"' >/dev/null; then
    echo "Enabling KV v2 secrets engine at secret/..."
    vault secrets enable -path=secret kv-v2
fi

vault kv put secret/admin-user username="$USERNAME" password="$PASSWORD"
echo "Admin credentials successfully backed up in Vault at secret/admin-user."

echo "----------------------------------------"
echo "Admin user successfully created!"
echo "Username: $USERNAME"
echo "Password: $PASSWORD"
echo "----------------------------------------"
echo "You can now log in via CLI:"
echo "  vault login -method=userpass username=$USERNAME"
echo "Or via the Vault UI at: https://${PRIMARY_NODE}:8200"
