#!/usr/bin/env bash
set -euo pipefail

# Step 1: deploy the Hub. Self-contained: loads and validates every file it needs, without relying on a
# preloaded caller environment.
# Usage: script/deploy/11_deploy_hub.sh <network>
# This step writes addresses.hub.params, which 21_check_hub.sh and 31_verify_hub.sh load on their own.

network="${1:?usage: script/deploy/11_deploy_hub.sh <network>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NETWORK_DIR="$PROJECT_ROOT/script/network/$network"

# Parameter file loader: 1e17 / 1_000_000 style literals are expanded to decimal on load (params.sh).
source "$SCRIPT_DIR/params.sh"

if [ ! -d "$NETWORK_DIR" ]; then
    echo "Error: Network directory not found: $NETWORK_DIR"
    exit 1
fi

# An abnormal previous exit may leave a hidden address temp file behind; only this module's temp pattern
# is removed, never the real address file.
rm -f "$NETWORK_DIR/.addresses.hub.params."*

# Required configuration. addresses.core.params is the dependency's address book, copied over after that
# deployment; .account provides the keystore account and password and is mandatory (local chains also
# sign through the keystore, never --unlocked).
for config in network.params addresses.core.params addresses.uniswapv2.params hub.params .account; do
    if [ ! -f "$NETWORK_DIR/$config" ]; then
        echo "Error: Missing required configuration: $NETWORK_DIR/$config"
        exit 1
    fi
done

# Parameters come from files only: clear every key the files define, so a value exported by the caller
# cannot override a file value.
params_unset_all \
    "$NETWORK_DIR/network.params" \
    "$NETWORK_DIR/addresses.core.params" \
    "$NETWORK_DIR/addresses.uniswapv2.params" \
    "$NETWORK_DIR/hub.params"

env_password="${KEYSTORE_PASSWORD:-}"
params_load "$NETWORK_DIR/network.params"
params_load "$NETWORK_DIR/addresses.core.params"
params_load "$NETWORK_DIR/addresses.uniswapv2.params"
params_load "$NETWORK_DIR/hub.params"
# .account is plain-sourced: the password may contain "#" and must not go through parameter expansion.
set -a
source "$NETWORK_DIR/.account"
set +a

# An empty KEYSTORE_PASSWORD line in .account must not clear a password exported by the entrypoint (that
# would prompt a second time).
[ -n "${KEYSTORE_PASSWORD:-}" ] || KEYSTORE_PASSWORD="$env_password"

[ -n "${KEYSTORE_ACCOUNT:-}" ] && [ -n "${ACCOUNT_ADDRESS:-}" ] \
    || { echo "Error: KEYSTORE_ACCOUNT / ACCOUNT_ADDRESS is not set in $NETWORK_DIR/.account" >&2; exit 1; }

# Verify the actual chain; being able to reach the RPC is not enough.
ACTUAL_CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL") || exit 1
if [ "$ACTUAL_CHAIN_ID" != "$CHAIN_ID" ]; then
    echo "Error: RPC chain ID $ACTUAL_CHAIN_ID does not match configured CHAIN_ID $CHAIN_ID"
    exit 1
fi

# Keystore password: no prompt when already set (non-interactive use), otherwise the macOS dialog.
if [ -z "${KEYSTORE_PASSWORD:-}" ]; then
    if ! command -v osascript >/dev/null 2>&1; then
        echo "Error: KEYSTORE_PASSWORD is empty and osascript is unavailable; set it in $NETWORK_DIR/.account for non-interactive use." >&2
        exit 1
    fi
    KEYSTORE_PASSWORD="$(osascript <<APPLESCRIPT
text returned of (display dialog "Enter keystore password for $KEYSTORE_ACCOUNT:" default answer "" with hidden answer buttons {"Cancel", "OK"} default button "OK")
APPLESCRIPT
)"
fi

echo "=== Deploying LOVE20Hub to $network ==="
echo "  RPC_URL: $RPC_URL"
echo "  CHAIN_ID: $CHAIN_ID"

require_address() {
    local field=$1
    local source=$2
    if [[ ! ${!field:-} =~ ^0x[0-9a-fA-F]{40}$ ]] || [[ ${!field:-} = 0x0000000000000000000000000000000000000000 ]]; then
        echo "Error: Missing or invalid $field in $source"
        exit 1
    fi
}

# Prepare the deployment log and the password file. Once broadcast, any later validation failure means
# "the contract is on chain but the address was not recorded": the log and the artifact path must survive
# for manual recovery; a pre-broadcast failure only removes this run's temp files and never claims
# anything reached the chain. The password goes to forge through a temp file because --password would put
# the plaintext into the process arguments, readable by every local user. The trap is installed before the
# password is written, so a failing chmod/printf leaks nothing.
DEPLOY_LOG=$(mktemp)
PASSWORD_FILE=$(mktemp)
ADDRESS_TMP="$NETWORK_DIR/.addresses.hub.params.$$"
DEPLOY_SAVED=0
DEPLOY_ATTEMPTED=0
trap 'rm -f "$ADDRESS_TMP" "$PASSWORD_FILE"
if [ "$DEPLOY_SAVED" = 1 ] || [ "$DEPLOY_ATTEMPTED" = 0 ]; then
    rm -f "$DEPLOY_LOG"
else
    echo "  Address was not saved; the contract may already be on chain." >&2
    echo "  Deployment log: $DEPLOY_LOG" >&2
    echo "  Broadcast artifact: $PROJECT_ROOT/broadcast/DeployHub.s.sol/${CHAIN_ID:-unknown}/run-latest.json" >&2
fi' EXIT
chmod 600 "$PASSWORD_FILE"
printf '%s' "$KEYSTORE_PASSWORD" > "$PASSWORD_FILE"

# Build the forge script command: keystore signing (same on local chains, never --unlocked).
FORGE_CMD=(forge script script/deploy/DeployHub.s.sol:DeployHub --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" --account "$KEYSTORE_ACCOUNT" --sender "$ACCOUNT_ADDRESS" --password-file "$PASSWORD_FILE" --broadcast --slow -vvv)

# Run the deployment.
cd "$PROJECT_ROOT"
DEPLOY_START_EPOCH_SECONDS=$(date +%s)
DEPLOY_ATTEMPTED=1
if ! { "${FORGE_CMD[@]}" 2>&1 | tee "$DEPLOY_LOG"; }; then
    echo "Error: Deployment failed."
    exit 1
fi
# The password is only needed for this forge call; delete it right after broadcast to shorten the exposure
# window.
rm -f "$PASSWORD_FILE"

# Extract the address from the deployment output (_logDeploymentSummary in DeployHub.s.sol). A
# non-matching grep would silently abort the pipeline under set -e, so the lookup tolerates failure and a
# missing entry is reported by require_address.
HUB_ADDRESS=$(grep "HUB_ADDRESS=" "$DEPLOY_LOG" | tail -1 | sed 's/.*HUB_ADDRESS= *//' | xargs || true)
require_address HUB_ADDRESS "deployment log"

BROADCAST_FILE="$PROJECT_ROOT/broadcast/DeployHub.s.sol/$CHAIN_ID/run-latest.json"
if [ ! -f "$BROADCAST_FILE" ]; then
    echo "Error: Missing broadcast artifact: $BROADCAST_FILE"
    exit 1
fi
BROADCAST_TIMESTAMP_MS=$(sed -nE 's/.*"timestamp":[[:space:]]*([0-9]+).*/\1/p' "$BROADCAST_FILE" | tail -1)
if [ -z "$BROADCAST_TIMESTAMP_MS" ] || [ "$BROADCAST_TIMESTAMP_MS" -lt "$((DEPLOY_START_EPOCH_SECONDS * 1000))" ]; then
    echo "Error: Broadcast artifact was not updated by this deployment: $BROADCAST_FILE"
    exit 1
fi

# The broadcast artifact must record the deployment of exactly the address the log reported.
#
# De-duplicate before counting. forge 1.8.1 writes the same address twice per deployment — once under
# `transactions[]` and once in the matching `receipts[]` entry — so counting raw occurrences reports 2
# for a single-contract script and fails every run after a successful broadcast. Distinct addresses
# still expose a script that deployed more than one contract, which is what the count is guarding.
require_broadcast_matches_hub() {
    local matches count actual
    matches=$(grep -oE '"contractAddress"[[:space:]]*:[[:space:]]*"0x[0-9a-fA-F]{40}"' "$BROADCAST_FILE" \
        | grep -oE '0x[0-9a-fA-F]{40}' | sort -u)
    if [ -z "$matches" ]; then
        echo "Error: Missing contract address in broadcast artifact"
        exit 1
    fi
    count=$(printf '%s\n' "$matches" | wc -l | tr -d ' ')
    if [ "$count" -ne 1 ]; then
        echo "Error: Expected exactly one deployed contract in broadcast artifact, found $count"
        exit 1
    fi
    actual=$(printf '%s' "$matches" | tr 'A-F' 'a-f')
    if [ "$actual" != "$(printf '%s' "$HUB_ADDRESS" | tr 'A-F' 'a-f')" ]; then
        echo "Error: Broadcast artifact does not match the deployed Hub"
        echo "  expected: $HUB_ADDRESS"
        echo "  actual:   $actual"
        exit 1
    fi
}
require_broadcast_matches_hub

# Write the address file.
{
    printf 'HUB_ADDRESS=%s\n' "$HUB_ADDRESS"
} > "$ADDRESS_TMP"
mv "$ADDRESS_TMP" "$NETWORK_DIR/addresses.hub.params"

DEPLOY_SAVED=1
echo "✓ Deployment completed and addresses saved"
