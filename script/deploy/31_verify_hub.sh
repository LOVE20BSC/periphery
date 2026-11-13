#!/usr/bin/env bash
set -euo pipefail

# Step 3: source verification. Self-contained: loads network.params, verifier.params, addresses.core.params
# (the Hub's single constructor argument) and the addresses.hub.params written by the last deployment,
# without relying on the entrypoint to refresh addresses afterwards.
# Usage: script/deploy/31_verify_hub.sh <network>

network="${1:?usage: script/deploy/31_verify_hub.sh <network>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NETWORK_DIR="$PROJECT_ROOT/script/network/$network"
VERIFIER_PARAMS="$PROJECT_ROOT/script/network/verifier.params"

# Parameter file loader: 1e17 / 1_000_000 style literals are expanded to decimal on load (params.sh).
source "$SCRIPT_DIR/params.sh"

if [ ! -d "$NETWORK_DIR" ]; then
    echo "Error: Network directory not found: $NETWORK_DIR"
    exit 1
fi

for config in network.params addresses.core.params hub.params addresses.hub.params; do
    if [ ! -f "$NETWORK_DIR/$config" ]; then
        echo "Error: Missing required configuration: $NETWORK_DIR/$config"
        exit 1
    fi
done
if [ ! -f "$VERIFIER_PARAMS" ]; then
    echo "Error: Missing required configuration: $VERIFIER_PARAMS"
    exit 1
fi

params_unset_all "$NETWORK_DIR/network.params" "$VERIFIER_PARAMS" \
    "$NETWORK_DIR/addresses.core.params" "$NETWORK_DIR/addresses.hub.params"

params_load "$NETWORK_DIR/network.params"
params_load "$VERIFIER_PARAMS"
params_load "$NETWORK_DIR/addresses.core.params"
params_load "$NETWORK_DIR/hub.params"
params_load "$NETWORK_DIR/addresses.hub.params"

cd "$PROJECT_ROOT"

# The opt-out list is mandatory as a key but may be empty: "verify every chain" is a legal answer.
params_require_keys "$VERIFIER_PARAMS" VERIFY_SKIP_CHAIN_IDS || exit 1

# Verification is attempted by default: only the chains listed here skip it, so a new production chain
# fails loudly instead of passing unverified.
skip_chains=",${VERIFY_SKIP_CHAIN_IDS:-},"
if [ -n "${CHAIN_ID:-}" ] && [[ "$skip_chains" == *",$CHAIN_ID,"* ]]; then
    echo "Skip: source verification is disabled for chain $CHAIN_ID in $VERIFIER_PARAMS"
    exit 0
fi

# The endpoint is a mandatory key: an empty URL would be passed straight to forge.
params_require_values "$VERIFIER_PARAMS" ETHERSCAN_VERIFIER_URL || exit 1
: "${ETHERSCAN_API_KEY:?Set an Etherscan API key; source verification has not run.}"

for field in RPC_URL HUB_ADDRESS STAKE_ADDRESS; do
    if [[ -z "${!field:-}" ]]; then
        echo "Error: Missing required value: $field"
        exit 1
    fi
done

# The Hub's constructor takes the injected Stake address plus the two fee ratios, so the verification input
# is all three encoded in order.
CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,uint256,uint256)" \
    "$STAKE_ADDRESS" "$SWAP_FEE_FOR_LP_RATIO" "$SWAP_FEE_FOR_PROTOCOL_RATIO")

echo ""
echo "=== Verifying LOVE20Hub source on chain $CHAIN_ID ==="
echo ""

forge verify-contract "$HUB_ADDRESS" src/LOVE20Hub.sol:LOVE20Hub \
    --chain-id "$CHAIN_ID" \
    --rpc-url "$RPC_URL" \
    --verifier-url "$ETHERSCAN_VERIFIER_URL" \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --constructor-args "$CONSTRUCTOR_ARGS" \
    --watch

echo ""
echo "✓ Source verification completed"
