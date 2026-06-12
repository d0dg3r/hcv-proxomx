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

echo "=== Setting up PKI Secrets Engine for .lan Domain ==="

# 1. Enable PKI secrets engine at path 'pki'
if ! vault secrets list -format=json | jq -e '."pki/"' >/dev/null; then
    echo "Enabling PKI secrets engine..."
    vault secrets enable pki
else
    echo "PKI secrets engine is already enabled."
fi

# 2. Tune PKI engine max lease TTL (20 years)
echo "Tuning PKI secrets engine lease TTL to 20 years..."
vault secrets tune -max-lease-ttl=175200h pki

# 3. Generate Root CA for .lan (20 years TTL, devopsgeek switzerland)
ROOT_CERT_FILE="$SECRETS_DIR/lan_root_ca.crt"
echo "Generating/Replacing Internal Root CA..."
vault write -field=certificate pki/root/generate/internal \
    common_name="lan Internal Root CA" \
    ttl=175200h \
    organization="devopsgeek" \
    ou="switzerland" \
    country="CH" > "$ROOT_CERT_FILE"
echo "Root CA certificate saved to $ROOT_CERT_FILE."

# Store Root CA in Vault KV engine
echo "Storing Root CA certificate in Vault KV engine..."
if ! vault secrets list -format=json | jq -e '."secret/"' >/dev/null; then
    vault secrets enable -path=secret kv-v2
fi
vault kv put secret/root-ca certificate=@"$ROOT_CERT_FILE"
echo "Root CA certificate successfully backed up in Vault at secret/root-ca."

# 4. Configure CA and CRL URLs
echo "Configuring PKI CA and CRL URLs..."
vault write pki/config/urls \
    issuing_certificates="https://vault.lan/v1/pki/ca" \
    crl_distribution_points="https://vault.lan/v1/pki/crl"

# 5. Create a role for issuing certificates for *.lan (10 years TTL, devopsgeek switzerland)
echo "Creating PKI role 'lan' with 10-year cert limit..."
vault write pki/roles/lan \
    allowed_domains="lan,vault-01,vault-02,vault-03,vault" \
    allow_subdomains=true \
    allow_bare_domains=true \
    max_ttl="87600h" \
    ttl="87600h" \
    key_type="rsa" \
    key_bits=2048 \
    client_flag=true \
    server_flag=true \
    basic_constraints_valid_for_non_ca=true \
    organization="devopsgeek" \
    ou="switzerland" \
    country="CH"

echo "----------------------------------------"
echo "PKI Secrets Engine successfully configured for '.lan'!"
echo "Role Name: lan"
echo "Root CA saved to: $ROOT_CERT_FILE"
echo "----------------------------------------"
echo "You can now issue 10-year certificates using the CLI:"
echo "  vault write -address=\"https://${PRIMARY_NODE}:8200\" pki/issue/lan common_name=\"myservice.lan\" ttl=\"87600h\""
