#!/usr/bin/env bash
# Parameter file loader: lets *.params write long integers as <mantissa>e<exponent> (1e17, 3e15) or
# with underscore grouping (1_000_000); values are expanded to decimal on load and exported.
#
# Purely lexical, no key table: adding or removing a parameter needs no change here, so the "missed
# mapping entry" failure mode does not exist. Only comma-separated elements shaped exactly like
# <integer>e<integer> are expanded; everything else is passed through unchanged. A malformed value
# stays in the environment and makes vm.envUint fail before broadcast - the failure direction is
# loud, never a silently wrong value. Trailing comments (whitespace + #) are dropped before
# expansion; a fully quoted value is not comment-stripped. This function is not used for .account:
# passwords may contain "#". Each of the four repositories (core/action/group-chat/dex) keeps an
# identical copy: every repo must stay deployable on its own, so the file cannot be shared; changes
# must be applied to all four. `params_unset_all` reads the key set out of the same files, so
# clearing inherited values needs no table either.

# Expand a single value (comma-separated lists such as GROUP_ACTION_SPLITS are supported).
params_expand_value() {
    local value="$1" item out="" sep=""
    local -a items
    [ -n "$value" ] || return 0
    IFS=',' read -ra items <<<"$value" || true
    for item in "${items[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        if [[ "$item" =~ ^([0-9][0-9_]*)[eE]([0-9]+)$ ]]; then
            # Pad the mantissa with <exponent> zeros: pure string operation, no 64-bit limit (1e28 works).
            printf -v item '%s%*s' "${BASH_REMATCH[1]//_/}" "${BASH_REMATCH[2]}" ''
            item="${item// /0}"
        elif [[ "$item" =~ ^[0-9][0-9_]*$ ]]; then
            item="${item//_/}"
        fi
        # Join item by item, preserving the original order and separators.
        out="$out$sep$item"
        sep=","
    done
    printf '%s' "$out"
}

# Clear every key the given parameter files define. Callers run this before loading, so no value
# exported by the caller can override a file value. The sweep only knows what the files still
# define: a key the file has dropped is not covered, so keys whose ABSENCE changes behaviour are
# asserted with params_require_keys (presence) or params_require_values (presence and a non-empty
# value). The key set comes from the files themselves, so there is still no table to keep in sync.
params_unset_all() {
    local file line key
    for file in "$@"; do
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line#"${line%%[![:space:]]*}"}"
            case "$line" in
                '' | '#'*) continue ;;
            esac
            [[ "$line" == *=* ]] || continue
            key="${line%%=*}"
            [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
            unset "$key" 2>/dev/null || true
        done <"$file"
    done
}

# Assert that the given file defines every named key. The sweep above cannot cover a key the file has
# dropped, so a key whose ABSENCE carries meaning - a plugin slot, where the zero address means "not
# mounted" - is checked against the file itself, never against the variable, which an inherited value
# could satisfy. Leading whitespace is allowed, as in params_load and params_unset_all.
params_require_keys() {
    local file="$1" key
    shift
    for key in "$@"; do
        if ! grep -qE "^[[:space:]]*${key}=" "$file"; then
            echo "Error: $key must be set in $file" >&2
            return 1
        fi
    done
}

# Presence plus a non-empty value. A key where "missing" and "empty" both mean "not configured"
# cannot use params_require_keys, which accepts "KEY=": the empty value would pass the guard and
# only fail later inside vm.envAddress/vm.envUint with an unhelpful message.
params_require_values() {
    local file="$1" key
    shift
    for key in "$@"; do
        if ! grep -qE "^[[:space:]]*${key}=[^[:space:]]" "$file"; then
            echo "Error: $key must be set to a non-empty value in $file" >&2
            return 1
        fi
    done
}

# Load a parameter file and export its entries. Literals only: a value may be quoted as a whole, but
# no variable expansion or command substitution is performed - a "$" or backtick in the file stays
# literal instead of silently expanding to something else.
params_load() {
    local file="$1" line key value
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in
            '' | '#'*) continue ;;
        esac
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"
        value="${line#*=}"
        if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "Error: invalid key in $file: $key" >&2
            return 1
        fi
        if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then
            value="${value#?}"
            value="${value%?}"
        else
            value="${value%%[[:space:]]#*}"
            value="${value%"${value##*[![:space:]]}"}"
        fi
        printf -v "$key" '%s' "$(params_expand_value "$value")"
        export "$key"
    done <"$file"
}
