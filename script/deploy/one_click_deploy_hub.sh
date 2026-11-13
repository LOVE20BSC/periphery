#!/usr/bin/env bash
set -euo pipefail

# Module entrypoint for the Hub. This repository's deployed-contract set is not frozen (every new
# periphery contract is a new module), so it deliberately has NO repo-wide `one_click_deploy.sh`:
# a single entrypoint would either redeploy what is already on chain or fail to cover the next module.
# Adding a module means adding `one_click_deploy_<x>.sh` plus its own step scripts, and leaving this
# file untouched.
#
# Orchestration only. It sources no environment file itself: each step loads its own inputs, every step
# is invoked the same way (`<step>.sh <network>`), and steps never call each other.
# Usage: script/deploy/one_click_deploy_hub.sh <network>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cd "$PROJECT_ROOT"

network="${1:?usage: script/deploy/one_click_deploy_hub.sh <network>}"

NETWORK_DIR="$PROJECT_ROOT/script/network/$network"
if [ ! -d "$NETWORK_DIR" ]; then
    echo "Error: Network directory not found: $NETWORK_DIR"
    exit 1
fi

# The keystore password is resolved once per run: reset first (never inherit a value left over in the
# caller's environment, which would silently reuse the previous run's password), then read the password
# line from .account; if neither exists, prompt once and export it so every step reuses it. A step run on
# its own still resolves it as environment -> .account -> prompt. Only the password line is read here;
# the config file is never sourced.
export KEYSTORE_PASSWORD=""
if [ ! -f "$NETWORK_DIR/.account" ]; then
    echo "Error: Missing required configuration: $NETWORK_DIR/.account"
    exit 1
fi
configured_password=$(grep -E '^KEYSTORE_PASSWORD=' "$NETWORK_DIR/.account" | tail -1 | cut -d= -f2- || true)
if [ -n "$configured_password" ]; then
    export KEYSTORE_PASSWORD="$configured_password"
fi
if [ -z "${KEYSTORE_PASSWORD:-}" ]; then
    if ! command -v osascript >/dev/null 2>&1; then
        echo "Error: KEYSTORE_PASSWORD is empty and osascript is unavailable; set it in $NETWORK_DIR/.account for non-interactive use." >&2
        exit 1
    fi
    KEYSTORE_PASSWORD="$(osascript <<APPLESCRIPT
text returned of (display dialog "Enter keystore password for deployment:" default answer "" with hidden answer buttons {"Cancel", "OK"} default button "OK")
APPLESCRIPT
)"
    export KEYSTORE_PASSWORD
fi

# Deployment and checking are separate steps: a failed check must not overwrite the previously saved
# addresses. Back them up first, drop the backup once the check passes, restore it on failure.
ADDRESS_FILE="$NETWORK_DIR/addresses.hub.params"
BACKUP_FILE="$(mktemp)"
RESTORE_TMP="$ADDRESS_FILE.restore.$$"
trap 'rm -f "$BACKUP_FILE" "$RESTORE_TMP"' EXIT
had_address_file=0
if [ -f "$ADDRESS_FILE" ]; then
    cp "$ADDRESS_FILE" "$BACKUP_FILE"
    had_address_file=1
fi

# Step 1: deploy the Hub (loads its own deployment inputs). The address file is written only after every
# check passes, but an already broadcast contract cannot be rolled back: after a post-broadcast failure,
# recover the record from the log and the broadcast artifact that 11_deploy_hub.sh prints.
bash "$SCRIPT_DIR/11_deploy_hub.sh" "$network"

# Step 2: verify the deployment (loads its own check inputs, restores the saved addresses on failure).
if ! bash "$SCRIPT_DIR/21_check_hub.sh" "$network"; then
    echo "Error: post-deployment check failed."
    if [ -f "$ADDRESS_FILE" ]; then
        echo "New deployment addresses (may already be on chain):"
        sed 's/^/  /' "$ADDRESS_FILE"
    fi
    echo "  Broadcast artifact: $PROJECT_ROOT/broadcast/DeployHub.s.sol/<chain-id>/run-latest.json"
    if [ "$had_address_file" = 1 ]; then
        if ! cp "$BACKUP_FILE" "$RESTORE_TMP"; then
            echo "Error: failed to stage the previous addresses; $ADDRESS_FILE still holds the new deployment." >&2
            exit 1
        fi
        mv "$RESTORE_TMP" "$ADDRESS_FILE"
        echo "The previously saved addresses were restored."
    else
        rm -f "$ADDRESS_FILE"
        echo "No previous address file existed; the new address file was removed."
    fi
    exit 1
fi

# Step 3: source verification (loads the address file itself). Skips itself when the chain has no source
# verification.
bash "$SCRIPT_DIR/31_verify_hub.sh" "$network"

echo "✓ Deployment completed: $network"
