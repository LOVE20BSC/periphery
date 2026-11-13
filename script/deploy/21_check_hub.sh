#!/usr/bin/env bash
set -euo pipefail

# Deployment check: read-only over config and chain state (never writes an address file). Loads its own
# check inputs instead of relying on a preloaded environment: network.params provides RPC and chain ID,
# addresses.core.params the expected dependency bindings, addresses.uniswapv2.params the expected router
# and wrapped native token, and addresses.hub.params the deployed address to verify.
# Usage: script/deploy/21_check_hub.sh <network>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# forge inspect locates foundry.toml through the current directory, unlike cast: without switching to the
# project root the runtime comparison gets an empty artifact and falsely reports "runtime unavailable".
cd "$PROJECT_ROOT"

network="${1:?usage: script/deploy/21_check_hub.sh <network>}"
NETWORK_DIR="$PROJECT_ROOT/script/network/$network"

# Parameter file loader: 1e17 / 1_000_000 style literals are expanded to decimal on load (params.sh).
source "$SCRIPT_DIR/params.sh"

if [ ! -d "$NETWORK_DIR" ]; then
    echo "Error: Network directory not found: $NETWORK_DIR"
    exit 1
fi

for config in network.params addresses.core.params addresses.uniswapv2.params addresses.hub.params; do
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
    "$NETWORK_DIR/addresses.hub.params"

params_load "$NETWORK_DIR/network.params"
params_load "$NETWORK_DIR/addresses.core.params"
params_load "$NETWORK_DIR/addresses.uniswapv2.params"
params_load "$NETWORK_DIR/addresses.hub.params"

# The address file's key set must equal the expected contract set: a renamed key would leave later
# variables silently empty and fail much later with an unhelpful message, so assert it here.
address_file="$NETWORK_DIR/addresses.hub.params"
expected_keys="HUB_ADDRESS"
actual_keys=$(grep -oE '^[A-Z0-9_]+=' "$address_file" | sed 's/=$//' | sort | tr '\n' ' ' || true)
if [ "$actual_keys" != "$(printf '%s\n' $expected_keys | sort | tr '\n' ' ')" ]; then
    echo "Error: $address_file key set mismatch"
    echo "  expected: $(printf '%s\n' $expected_keys | sort | tr '\n' ' ')"
    echo "  actual:   $actual_keys"
    exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

echo ""
echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
echo -e "${CYAN}║    Verifying LOVE20Hub Deployment    ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
echo ""

for field in $expected_keys; do
    if [[ ! ${!field:-} =~ ^0x[0-9a-fA-F]{40}$ ]] || [[ ${!field:-} = 0x0000000000000000000000000000000000000000 ]]; then
        echo -e "${RED}✗ Error: $field is missing or invalid in $address_file${NC}"
        exit 1
    fi
done

normalize_output() {
    local value="$1"
    value="${value%\"}"
    value="${value#\"}"
    value="${value% \[*\]}"
    echo "$value"
}

failures=0

verify_value() {
    local field_name=$1
    local expected=$2
    local actual=$3

    expected=$(normalize_output "$expected")
    actual=$(normalize_output "$actual")

    if [[ "$expected" =~ ^0x[0-9a-fA-F]{40}$ && "$actual" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
        expected=$(echo "$expected" | tr '[:upper:]' '[:lower:]')
        actual=$(echo "$actual" | tr '[:upper:]' '[:lower:]')
    fi

    if [ "$expected" = "$actual" ]; then
        echo -e "  ${GREEN}✓${NC} ${field_name}"
        echo -e "    ${GRAY}Expected: ${expected}${NC}"
        echo -e "    ${GRAY}Actual:   ${actual}${NC}"
        return 0
    fi

    echo -e "  ${RED}✗${NC} ${field_name}"
    echo -e "    ${GRAY}Expected: ${expected}${NC}"
    echo -e "    ${YELLOW}Actual:   ${actual}${NC}"
    failures=$((failures + 1))
    return 0
}

verify_deployed() {
    local name=$1
    local address=$2
    local code
    code=$(cast code "$address" --rpc-url "$RPC_URL" 2>/dev/null) || {
        echo -e "${RED}✗ $name: unable to read code at $address${NC}"
        failures=$((failures + 1))
        return 0
    }
    if [[ ! "$code" =~ ^0x[0-9a-fA-F]+$ ]] || [ "$code" = "0x" ]; then
        echo -e "${RED}✗ $name: no code at $address${NC}"
        failures=$((failures + 1))
        return 0
    fi
    echo -e "  ${GREEN}✓${NC} ${name} has code"
}

# Every value the Hub derives must match the dependency address book. The Hub's derived values are
# immutables baked into the runtime bytecode, so they are read back through the deployed getters.
verify_binding() {
    local getter=$1
    local expected=$2
    local actual
    actual=$(cast call "$HUB_ADDRESS" "$getter" --rpc-url "$RPC_URL" 2>/dev/null) || {
        echo -e "${RED}✗ $getter: call failed${NC}"
        failures=$((failures + 1))
        return 0
    }
    verify_value "$getter" "$expected" "$actual"
}

verify_deployed "LOVE20Hub" "$HUB_ADDRESS"

verify_binding "STAKE_ADDRESS()(address)" "$STAKE_ADDRESS"
verify_binding "ROUTER_ADDRESS()(address)" "$ROUTER_ADDRESS"
verify_binding "PAIR_FACTORY_ADDRESS()(address)" "$PAIR_FACTORY_ADDRESS"
verify_binding "LAUNCH_ADDRESS()(address)" "$LAUNCH_ADDRESS"
verify_binding "MEMBER_NFT_ADDRESS()(address)" "$MEMBER_NFT_ADDRESS"
verify_binding "WRAPPED_NATIVE_ADDRESS()(address)" "$WRAPPED_NATIVE_ADDRESS"

# The stored dependency graph must itself be self-consistent: Stake is the only injected value, so every
# derived address has to agree with what Stake reports, and the router must still answer with the same
# wrapped native token.
stake_router=$(cast call "$STAKE_ADDRESS" "ROUTER_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || true)
verify_value "Stake.ROUTER_ADDRESS" "$ROUTER_ADDRESS" "$stake_router"
stake_factory=$(cast call "$STAKE_ADDRESS" "PAIR_FACTORY_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || true)
verify_value "Stake.PAIR_FACTORY_ADDRESS" "$PAIR_FACTORY_ADDRESS" "$stake_factory"
stake_launch=$(cast call "$STAKE_ADDRESS" "LAUNCH_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || true)
verify_value "Stake.LAUNCH_ADDRESS" "$LAUNCH_ADDRESS" "$stake_launch"
stake_member_nft=$(cast call "$STAKE_ADDRESS" "MEMBER_NFT_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || true)
verify_value "Stake.MEMBER_NFT_ADDRESS" "$MEMBER_NFT_ADDRESS" "$stake_member_nft"
router_weth=$(cast call "$ROUTER_ADDRESS" "WETH()(address)" --rpc-url "$RPC_URL" 2>/dev/null || true)
verify_value "Router.WETH" "$WRAPPED_NATIVE_ADDRESS" "$router_weth"

# The runtime bytecode must be the artifact's, with the immutables the constructor wrote. A Hub deployed
# from different source at the same address is the failure this rules out.
runtime=$(cast code "$HUB_ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null) || {
    echo -e "${RED}✗ Unable to read Hub runtime code${NC}"
    exit 1
}
expected_runtime=$(forge inspect LOVE20Hub deployedBytecode 2>/dev/null) || {
    echo -e "${RED}✗ Unable to read the LOVE20Hub artifact${NC}"
    exit 1
}
compare_runtime() {
    local artifact=$1
    local chain=$2
    local starts
    starts=$(forge inspect LOVE20Hub artifact 2>/dev/null | python3 -c '
import json
import sys

artifact = json.load(sys.stdin)
references = (artifact.get("deployedBytecode") or {}).get("immutableReferences") or {}
for entries in references.values():
    for entry in entries:
        if entry.get("length") != 32:
            raise SystemExit("immutable slot length is not 32")
        print(entry["start"])
' 2>/dev/null) || return 1

    local offset begin
    while IFS= read -r offset; do
        [ -z "$offset" ] && continue
        begin=$((offset * 2 + 2))
        artifact="${artifact:0:$begin}${chain:$begin:64}${artifact:$((begin + 64))}"
    done <<< "$starts"
    [ "$(printf '%s' "$artifact" | tr 'A-F' 'a-f')" = "$(printf '%s' "$chain" | tr 'A-F' 'a-f')" ]
}
if compare_runtime "$expected_runtime" "$runtime"; then
    echo -e "  ${GREEN}✓${NC} runtime bytecode matches the artifact (immutables excepted)"
else
    echo -e "${RED}✗ runtime bytecode does not match the artifact${NC}"
    failures=$((failures + 1))
fi

echo ""
if [ "$failures" -ne 0 ]; then
    echo -e "${RED}✗ Verification failed: $failures check(s) did not pass${NC}"
    exit 1
fi
echo -e "${GREEN}✓ All LOVE20Hub checks passed${NC}"
