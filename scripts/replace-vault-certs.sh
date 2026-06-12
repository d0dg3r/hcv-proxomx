#!/usr/bin/env bash
set -euo pipefail

# Config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS_DIR="$WORKSPACE_DIR/secrets"

KEYS_FILE="$SECRETS_DIR/vault-keys.json"
BOOTSTRAP_CA="$SECRETS_DIR/ca.crt"
PKI_CA="$SECRETS_DIR/lan_root_ca.crt"
PRIMARY_NODE="10.1.3.221"

if [ ! -f "$KEYS_FILE" ]; then
    echo "Error: $KEYS_FILE not found!"
    exit 1
fi

if [ ! -f "$BOOTSTRAP_CA" ]; then
    echo "Error: $BOOTSTRAP_CA not found!"
    exit 1
fi

if [ ! -f "$PKI_CA" ]; then
    echo "Error: $PKI_CA not found! Run setup-pki.sh first."
    exit 1
fi

# Load root token and configure environment
ROOT_TOKEN=$(jq -r '.root_token' "$KEYS_FILE")
export VAULT_ADDR="https://${PRIMARY_NODE}:8200"
export VAULT_TOKEN="$ROOT_TOKEN"

# Temporarily skip TLS verification during cert replacement to avoid chicken-and-egg trust issues
export VAULT_SKIP_VERIFY="true"

echo "=== Pre-generating Certificates for all Nodes ==="

NODES=(
    "vault-01:10.1.3.221:vault-01.lan"
    "vault-02:10.1.3.222:vault-02.lan"
    "vault-03:10.1.3.223:vault-03.lan"
)

# Extract unseal keys
UNSEAL_KEYS=$(jq -r '.unseal_keys_b64[]' "$KEYS_FILE")
KEYS=($UNSEAL_KEYS)

# 1. Pre-generate certs for all nodes locally to prevent connection issues mid-restart
for item in "${NODES[@]}"; do
    IFS=":" read -r name ip dns_name <<< "$item"
    echo "Generating certificate for $name ($dns_name) locally..."
    
    JSON_FILE="/tmp/cert-${name}.json"
    
    # Request certificate from Vault PKI
    vault write -format=json pki/issue/lan \
        common_name="${dns_name}" \
        alt_names="${name},vault.lan,localhost" \
        ip_sans="127.0.0.1,${ip}" \
        ttl="87600h" > "$JSON_FILE"
    
    # Extract keys and certificates
    jq -r '.data.certificate' "$JSON_FILE" > "/tmp/${name}.crt"
    jq -r '.data.private_key' "$JSON_FILE" > "/tmp/${name}.key"
    rm -f "$JSON_FILE"
done

# 2. Pre-generate certificate for the Reverse Proxy
echo "Generating certificate for the Reverse Proxy (vault.lan) locally..."
REV_PROXY_JSON="/tmp/cert-revproxy.json"
vault write -format=json pki/issue/lan \
    common_name="vault.lan" \
    alt_names="vault.lan,localhost" \
    ttl="87600h" > "$REV_PROXY_JSON"

jq -r '.data.certificate' "$REV_PROXY_JSON" > "$SECRETS_DIR/reverse_proxy_vault.lan.crt"
jq -r '.data.private_key' "$REV_PROXY_JSON" > "$SECRETS_DIR/reverse_proxy_vault.lan.key"
rm -f "$REV_PROXY_JSON"

# Create combined PEM bundle (Cert + Key + Root CA)
cat "$SECRETS_DIR/reverse_proxy_vault.lan.crt" "$SECRETS_DIR/reverse_proxy_vault.lan.key" "$PKI_CA" > "$SECRETS_DIR/reverse_proxy_vault.lan.pem"

# Store Reverse Proxy certs in Vault KV engine
echo "Storing Reverse Proxy certs in Vault KV engine..."
if ! vault secrets list -format=json | jq -e '."secret/"' >/dev/null; then
    vault secrets enable -path=secret kv-v2
fi
vault kv put secret/reverse-proxy-certs \
    certificate=@"$SECRETS_DIR/reverse_proxy_vault.lan.crt" \
    private_key=@"$SECRETS_DIR/reverse_proxy_vault.lan.key" \
    combined_pem=@"$SECRETS_DIR/reverse_proxy_vault.lan.pem"
echo "Reverse Proxy certificates successfully backed up in Vault at secret/reverse-proxy-certs."

echo "=== Distributing Certificates and Restarting Vault ==="

# 3. Upload and apply certificates to each Vault node
for item in "${NODES[@]}"; do
    IFS=":" read -r name ip dns_name <<< "$item"
    echo "----------------------------------------"
    echo "Processing $name ($ip)..."
    
    CRT_FILE="/tmp/${name}.crt"
    KEY_FILE="/tmp/${name}.key"
    
    echo "Uploading certificates to $ip..."
    # Upload via SCP
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$CRT_FILE" "root@${ip}:/tmp/vault.crt"
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$KEY_FILE" "root@${ip}:/tmp/vault.key"
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$PKI_CA" "root@${ip}:/tmp/ca.crt"
    
    echo "Moving certificates and restarting Vault on $name..."
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@${ip}" "
        mv /tmp/ca.crt /etc/vault.d/ca.crt
        mv /tmp/vault.crt /etc/vault.d/vault.crt
        mv /tmp/vault.key /etc/vault.d/vault.key
        chown vault:vault /etc/vault.d/*
        chmod 644 /etc/vault.d/ca.crt
        chmod 644 /etc/vault.d/vault.crt
        chmod 600 /etc/vault.d/vault.key
        systemctl restart vault
    "
    
    # Clean up local temp files for this node
    rm -f "$CRT_FILE" "$KEY_FILE"
    
    # Wait for service to restart and unseal it
    echo "Waiting for Vault on $name to restart..."
    sleep 3
    
    echo "Unsealing $name..."
    vault operator unseal -address="https://${ip}:8200" -ca-cert="$PKI_CA" "${KEYS[0]}" > /dev/null
    vault operator unseal -address="https://${ip}:8200" -ca-cert="$PKI_CA" "${KEYS[1]}" > /dev/null
    vault operator unseal -address="https://${ip}:8200" -ca-cert="$PKI_CA" "${KEYS[2]}" > /dev/null
    
    # Verify unseal status
    STATUS=$(curl -k -s "https://${ip}:8200/v1/sys/seal-status" || echo '{"sealed":true}')
    if [ "$(echo "$STATUS" | jq -r '.sealed')" = "false" ]; then
        echo "Successfully unsealed $name!"
    else
        echo "Failed to unseal $name automatically."
    fi
done

# 4. Replace local ca.crt with the PKI CA so future CLI commands trust the new CA
echo "----------------------------------------"
echo "Replacing local bootstrap ca.crt with lan_root_ca.crt..."
cp "$PKI_CA" "$BOOTSTRAP_CA"

echo "----------------------------------------"
echo "Vault Certificates Replaced and Service Restarted!"
echo "=== Setup Complete ==="
