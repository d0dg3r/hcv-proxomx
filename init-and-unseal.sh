#!/usr/bin/env bash
set -euo pipefail

# Config
KEYS_FILE="vault-keys.json"
CA_FILE="ca.crt"
NODES=("10.1.3.221" "10.1.3.222" "10.1.3.223")
PRIMARY_NODE="10.1.3.221"

echo "=== Vault Cluster Initialization and Unseal Script ==="

# 1. Save CA cert from terraform output if not already present
if [ ! -f "$CA_FILE" ]; then
    echo "Saving CA Certificate from Terraform output..."
    terraform output -raw ca_certificate > "$CA_FILE"
fi

export VAULT_CACERT="$(pwd)/$CA_FILE"

# 2. Initialize Vault if keys file doesn't exist
if [ ! -f "$KEYS_FILE" ]; then
    echo "Initializing Vault cluster on $PRIMARY_NODE..."
    vault operator init \
        -address="https://${PRIMARY_NODE}:8200" \
        -key-shares=5 \
        -key-threshold=3 \
        -format=json > "$KEYS_FILE"
    
    chmod 600 "$KEYS_FILE"
    echo "Vault initialized. Keys stored in $KEYS_FILE."
else
    echo "Keys file $KEYS_FILE already exists. Skipping initialization."
fi

# Extract unseal keys and root token
UNSEAL_KEYS=$(jq -r '.unseal_keys_b64[]' "$KEYS_FILE")
ROOT_TOKEN=$(jq -r '.root_token' "$KEYS_FILE")

# Convert keys to bash array
KEYS=($UNSEAL_KEYS)

# 3. Unseal all nodes
for node in "${NODES[@]}"; do
    echo "----------------------------------------"
    echo "Checking seal status for $node..."
    
    # Wait for the node to be initialized (indicating it has successfully joined via retry_join)
    echo "Waiting for node $node to become initialized (joining Raft cluster)..."
    for i in {1..30}; do
        STATUS=$(curl -k -s "https://${node}:8200/v1/sys/seal-status" || echo '{"initialized":false}')
        IS_INIT=$(echo "$STATUS" | jq -r '.initialized')
        if [ "$IS_INIT" = "true" ]; then
            echo "Node $node is initialized."
            break
        fi
        echo -n "."
        sleep 1
    done
    echo ""
    
    # Check if node is sealed
    SEAL_STATUS=$(curl -k -s "https://${node}:8200/v1/sys/seal-status" || echo '{"sealed":true}')
    IS_SEALED=$(echo "$SEAL_STATUS" | jq -r '.sealed')
    
    if [ "$IS_SEALED" = "true" ]; then
        echo "Node $node is sealed. Unsealing..."
        vault operator unseal -address="https://${node}:8200" "${KEYS[0]}" > /dev/null
        vault operator unseal -address="https://${node}:8200" "${KEYS[1]}" > /dev/null
        vault operator unseal -address="https://${node}:8200" "${KEYS[2]}" > /dev/null
        
        # Verify
        SUCCESS=false
        for attempt in {1..10}; do
            NEW_STATUS=$(curl -k -s "https://${node}:8200/v1/sys/seal-status" || echo '{"sealed":true}')
            if [ "$(echo "$NEW_STATUS" | jq -r '.sealed')" = "false" ]; then
                SUCCESS=true
                break
            fi
            sleep 0.5
        done
        if [ "$SUCCESS" = "true" ]; then
            echo "Successfully unsealed $node!"
        else
            echo "Failed to unseal $node."
        fi
    else
        echo "Node $node is already unsealed."
    fi
done

echo "----------------------------------------"
echo "Waiting for Raft cluster to stabilize..."
sleep 5

# 4. Check Raft cluster status
echo "Checking Raft peers on $PRIMARY_NODE..."
VAULT_TOKEN="$ROOT_TOKEN" vault operator raft list-peers -address="https://${PRIMARY_NODE}:8200"

echo "=== Vault Cluster Setup Complete ==="
