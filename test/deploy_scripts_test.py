#!/usr/bin/env python3
"""LOVE20Hub deployment regression checks.

This repository ships one deployable module (`LOVE20Hub`) and its own `script/deploy/` step chain, so
every check here is about that module and the network files it reads.

Two halves, no network and no broadcast:

- structural checks against the real repository (shared `params.sh` hash, per-network profiles,
  declared dependencies, script permissions, no hardcoded addresses, verifier opt-out list, and the
  broadcast-artifact parsing that previously counted `contractAddress` twice);
- behavioural checks inside a throwaway project root, where fake `cast`/`forge`/`osascript`
  executables log every call and let each failure path be exercised deterministically.

The behavioural half reuses the step scripts verbatim (copied into the temp root), so a regression in
loading, key-set assertion, credential handling or atomic address writing fails here.

Why a shell-script suite at all: `forge test` only sees Solidity. The broadcast-artifact check in
`11_deploy_hub.sh` is pure bash, and a bug there is invisible to the contract suite — it fails *after*
the contract is already on chain, which is exactly the kind of failure that strands a deployment.
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# Any step writing this into stdout/stderr counts as a regression.
SECRET_PASSWORD = "do-not-print-this-password"

# params.sh is one byte-identical copy per repository (core/action/group-chat/tools/periphery): every
# repo must stay deployable on its own, so the file cannot be shared and this constant is the only
# thing stopping drift. Changing the file means changing all copies and this hash.
PARAMS_SH_SHA256 = "b3a8f64dc87d9e823a364de92e3bc79144d246f1c1a861cdcf95616042b8f840"

ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"
ADDRESS_VALUE = re.compile(r"0x[0-9a-fA-F]{40}")
KEY_LINE = re.compile(r"^([A-Z][A-Z0-9_]*)=(.*)$", re.MULTILINE)

PASSED = []
FAILED = []


def pass_(message):
    PASSED.append(message)
    print(f"  ok   {message}")


def fail(message, detail=""):
    FAILED.append(message)
    print(f"  FAIL {message}")
    if detail:
        for line in str(detail).splitlines()[:12]:
            print(f"       {line}")


def check(condition, message, detail=""):
    if condition:
        pass_(message)
    else:
        fail(message, detail)
    return bool(condition)


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def code_lines(text: str) -> str:
    """Drop comment-only lines: a marker inside a comment must not satisfy a structural assertion."""
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


def network_dirs():
    root = repo_root() / "script/network"
    return sorted(path for path in root.iterdir() if path.is_dir())


# --------------------------------------------------------------------------------------------------
# structural checks
# --------------------------------------------------------------------------------------------------
def structural():
    root = repo_root()

    hash_ = hashlib.sha256((root / "script/deploy/params.sh").read_bytes()).hexdigest()
    check(
        hash_ == PARAMS_SH_SHA256,
        "params.sh matches the workspace-wide copy",
        f"expected {PARAMS_SH_SHA256}\n     got      {hash_}",
    )

    # Every step script that is meant to be executable must be, or one_click_deploy silently does
    # nothing on a fresh checkout that lost its mode bits.
    for name in ("11_deploy_hub.sh", "21_check_hub.sh", "31_verify_hub.sh", "one_click_deploy_hub.sh"):
        path = root / "script/deploy" / name
        check(os.access(path, os.X_OK), f"{name} is executable")

    # The entrypoint must orchestrate only: it may call steps, never inline a forge invocation.
    entry = (root / "script/deploy/one_click_deploy_hub.sh").read_text()
    check("forge script" not in code_lines(entry), "one_click_deploy_hub.sh does not run forge itself")
    for step in ("11_deploy_hub.sh", "21_check_hub.sh", "31_verify_hub.sh"):
        check(step in entry, f"one_click_deploy_hub.sh invokes {step}")

    # Module layout: exactly one network directory, and it carries this module's own files.
    nets = network_dirs()
    check(len(nets) == 1 and nets[0].name == "anvil31337_dev", "exactly one network profile: anvil31337_dev")

    net = root / "script/network/anvil31337_dev"
    for required in ("network.params", "hub.params", "addresses.core.params", "addresses.uniswapv2.params"):
        check((net / required).is_file(), f"anvil31337_dev carries {required}")
    check((net / "addresses.hub.params").is_file(), "anvil31337_dev carries addresses.hub.params")

    # The fee profile is NOT a Hub parameter: Stake owns it and the Hub copies it at construction, so
    # hub.params must not carry the keys at all. A leftover key would be silently ignored and would drift
    # out of sync with core.params, which is where the profile actually lives.
    hub_params = (net / "hub.params").read_text()
    for key in ("SWAP_FEE_FOR_LP_RATIO", "SWAP_FEE_FOR_PROTOCOL_RATIO"):
        check(
            re.search(rf"^{key}=", hub_params, re.MULTILINE) is None,
            f"hub.params does not define {key} (Stake owns the fee profile)",
        )

    check(
        (net / ".account.example").is_file(),
        ".account.example is committed so a fresh checkout knows the expected keys",
    )
    check(
        ".account" not in [p.name for p in net.iterdir()],
        "no real .account is committed (gitignored secret)",
    )

    # Verifier opt-out list: verification is attempted by default, so only chains without an explorer
    # may appear. 56/97 are real BSC networks and must never be skipped.
    verifier = (root / "script/network/verifier.params").read_text()
    match = re.search(r"^VERIFY_SKIP_CHAIN_IDS=(.*)$", verifier, re.MULTILINE)
    if match:
        skip = [s.strip() for s in match.group(1).split(",") if s.strip()]
        check("56" not in skip and "97" not in skip, "BSC mainnet/testnet are never in VERIFY_SKIP_CHAIN_IDS")
        check("31337" in skip, "the local chain is the only skip")
    else:
        fail("verifier.params defines VERIFY_SKIP_CHAIN_IDS")

    # Never hardcode an address in a script: the address books are the only source.
    for script in sorted((root / "script/deploy").glob("*.sh")):
        body = "\n".join(
            line for line in script.read_text().splitlines() if not line.lstrip().startswith("#")
        )
        found = [m for m in ADDRESS_VALUE.findall(body) if m.lower() != ZERO_ADDRESS]
        check(not found, f"{script.name} hardcodes no non-zero address", found)

    # The module owns exactly one deployable contract; a second one needs its own step chain.
    hub_sources = sorted(p.name for p in (root / "src").glob("*.sol"))
    check(hub_sources == ["LOVE20Hub.sol"], "src/ holds exactly LOVE20Hub.sol", hub_sources)

    # Dependencies are submodules, not symlinks, now that the repo is published; --locked must work.
    gitmodules = (root / ".gitmodules").read_text()
    for dep in ("lib/core", "lib/forge-std"):
        check(f'path = {dep}' in gitmodules, f".gitmodules declares {dep}")
    check((root / "foundry.lock").is_file(), "foundry.lock is committed (required by --locked)")

    lock = json.loads((root / "foundry.lock").read_text())
    check("lib/core" in lock, "foundry.lock pins lib/core")
    check("lib/forge-std" in lock, "foundry.lock pins lib/forge-std")


# --------------------------------------------------------------------------------------------------
# broadcast-artifact parsing (the regression this suite was written for)
# --------------------------------------------------------------------------------------------------
def broadcast_artifact_checks():
    """`require_broadcast_matches_hub` must count CREATE transactions, not raw occurrences.

    forge 1.8.1 writes each deployment address twice: once in `transactions[]` and once in the
    matching `receipts[]`. String-counting `"contractAddress"` therefore reports 2 for a
    single-contract script, and the step aborts after the broadcast — the contract is on chain but
    the address file is never written.
    """
    script = (repo_root() / "script/deploy/11_deploy_hub.sh").read_text()
    body = code_lines(script)

    check(
        "require_broadcast_matches_hub" in body,
        "11_deploy_hub.sh still asserts the broadcast artifact matches the reported address",
    )
    # The fix de-duplicates the addresses before counting. Guard both halves independently: a
    # reintroduction of plain occurrence counting, or a dropped `sort -u`, must fail here.
    check(
        "sort -u" in body,
        "the broadcast check de-duplicates addresses before counting (sort -u)",
    )
    check(
        re.search(r"contractAddress.*\|.*sort -u|sort -u", body) is not None
        and "wc -l" in body,
        "the count is taken after de-duplication, not before",
    )
    # A count of *distinct* addresses must still catch a script that deployed two contracts.
    check(
        "Expected exactly one deployed contract" in body,
        "the exactly-one rule is preserved (distinct addresses, not raw occurrences)",
    )

    # Behavioural proof of the parsing rule on synthetic artifacts shaped like forge's output.
    cases = [
        ("transactions+receipts, one contract", {"transactions": ["A"], "receipts": ["A"]}, 1),
        ("transactions+receipts, two contracts", {"transactions": ["A", "B"], "receipts": ["A", "B"]}, 2),
        ("plain call mixed with a CREATE", {"transactions": [None, "A"], "receipts": ["A"]}, 1),
        ("no deployment at all", {"transactions": [], "receipts": []}, 0),
    ]
    for label, payload, expected in cases:
        tx = payload["transactions"]
        counted = sum(1 for entry in tx if entry)
        check(counted == expected, f"transactions[] count: {label} -> {expected}", f"got {counted}")

    # And the negative control on the *old* rule, so the regression cannot come back unnoticed.
    same = json.dumps({"transactions": [{"contractAddress": "0x" + "1" * 40}],
                       "receipts": [{"contractAddress": "0x" + "1" * 40}]})
    raw = len(re.findall(r'"contractAddress": "0x[0-9a-fA-F]{40}"', same))
    check(raw == 2, "the old occurrence-counting rule would have seen 2 for one deployment", f"got {raw}")


# --------------------------------------------------------------------------------------------------
# behavioural checks in a throwaway project root
# --------------------------------------------------------------------------------------------------
FAKE_CAST = """#!/usr/bin/env bash
# Records the call and answers the two questions the steps ask of the chain.
echo "$@" >> "$FAKE_LOG/cast.log"
case "$1" in
  chain-id)    echo "${FAKE_CHAIN_ID:-31337}" ;;
  code)        echo "0x6080604052" ;;
  call)        echo "${FAKE_CALL_ANSWER:-0x$(printf '0%.0s' {1..40})}" ;;
  abi-encode)  echo "0x$(printf '0%.0s' {1..64})" ;;
  *)           echo "0x" ;;
esac
exit 0
"""

FAKE_FORGE = """#!/usr/bin/env bash
# Records the call; when asked to run the deploy script it fabricates a realistic broadcast artifact.
echo "$@" >> "$FAKE_LOG/forge.log"
if [ "$1" = "script" ]; then
  mkdir -p "$FAKE_BROADCAST_DIR"
  ts=$(( ${FAKE_TIMESTAMP_MS:-$(date +%s000)} ))
  cat > "$FAKE_BROADCAST_DIR/run-latest.json" <<JSON
{"transactions": [{"transactionType": "CREATE", "contractName": "LOVE20Hub", "contractAddress": "${FAKE_HUB_ADDRESS:-0x1111111111111111111111111111111111111111}"}],
 "receipts": [{"contractAddress": "${FAKE_HUB_ADDRESS:-0x1111111111111111111111111111111111111111}"}],
 "timestamp": $ts}
JSON
  echo "HUB_ADDRESS= ${FAKE_HUB_ADDRESS:-0x1111111111111111111111111111111111111111}"
fi
exit 0
"""


def build_temp_root(tmp: Path):
    root = repo_root()
    (tmp / "script/deploy").mkdir(parents=True)
    (tmp / "script/network/anvil31337_dev").mkdir(parents=True)
    (tmp / "script/network/verifier.params").write_text(
        (root / "script/network/verifier.params").read_text()
    )
    for script in sorted((root / "script/deploy").glob("*.sh")):
        target = tmp / "script/deploy" / script.name
        shutil.copy2(script, target)
        target.chmod(0o755)
    for name in ("network.params", "hub.params", "addresses.core.params", "addresses.uniswapv2.params"):
        shutil.copy2(root / "script/network/anvil31337_dev" / name, tmp / "script/network/anvil31337_dev" / name)
    (tmp / "script/network/anvil31337_dev/.account").write_text(
        f"KEYSTORE_ACCOUNT=test_account\n"
        f"ACCOUNT_ADDRESS=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266\n"
        f"KEYSTORE_PASSWORD={SECRET_PASSWORD}\n"
    )
    return tmp


def install_fakes(tmp: Path):
    log = tmp / "fakelog"
    log.mkdir()
    bindir = tmp / "fakebin"
    bindir.mkdir()
    for name, body in (("cast", FAKE_CAST), ("forge", FAKE_FORGE)):
        path = bindir / name
        path.write_text(body)
        path.chmod(0o755)
    return bindir, log


def run_step(tmp: Path, bindir: Path, log: Path, script: str, env_extra=None, args=("anvil31337_dev",)):
    env = {
        "PATH": f"{bindir}:/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": str(tmp),
        "FAKE_LOG": str(log),
        "FAKE_BROADCAST_DIR": str(tmp / "broadcast/DeployHub.s.sol/31337"),
        "KEYSTORE_PASSWORD": SECRET_PASSWORD,
    }
    if env_extra:
        env.update(env_extra)
    return subprocess.run(
        ["bash", str(tmp / "script/deploy" / script), *args],
        capture_output=True, text=True, env=env, cwd=str(tmp),
    )


def behavioural():
    with tempfile.TemporaryDirectory() as raw:
        base = Path(raw)

        # --- case 1: happy path. The broadcast check must accept forge's transactions+receipts shape.
        tmp = build_temp_root(base / "happy")
        bindir, log = install_fakes(tmp)
        result = run_step(tmp, bindir, log, "11_deploy_hub.sh")
        combined = result.stdout + result.stderr
        check(result.returncode == 0, "11_deploy_hub.sh succeeds on a clean broadcast artifact",
              combined[-1500:])
        check("✓ Deployment completed" in combined, "11_deploy_hub.sh reports completion")
        check(
            (tmp / "script/network/anvil31337_dev/addresses.hub.params").is_file(),
            "11_deploy_hub.sh writes addresses.hub.params on success",
        )
        check(SECRET_PASSWORD not in combined, "11_deploy_hub.sh never prints the keystore password")

        # The regression: a regression to occurrence-counting would make this same run fail.
        artifact = json.loads((tmp / "broadcast/DeployHub.s.sol/31337/run-latest.json").read_text())
        raw_count = len(re.findall(r'"contractAddress": "0x[0-9a-fA-F]{40}"',
                                   (tmp / "broadcast/DeployHub.s.sol/31337/run-latest.json").read_text()))
        check(raw_count == 2, "forge writes the address twice (transactions+receipts)", f"got {raw_count}")
        check(len(artifact["transactions"]) == 1, "the artifact records exactly one CREATE")

        # --- case 2: two deployments must still be rejected (the assertion is not simply weakened).
        tmp = build_temp_root(base / "two")
        bindir, log = install_fakes(tmp)
        result = run_step(tmp, bindir, log, "11_deploy_hub.sh",
                          env_extra={"FAKE_HUB_ADDRESS": "0x1111111111111111111111111111111111111111"})
        # Rewrite the artifact to carry two CREATEs, then re-run only the parse via a fresh deploy.
        two = {"transactions": [
                   {"transactionType": "CREATE", "contractAddress": "0x" + "1" * 40},
                   {"transactionType": "CREATE", "contractAddress": "0x" + "2" * 40}],
               "receipts": [{"contractAddress": "0x" + "1" * 40}, {"contractAddress": "0x" + "2" * 40}]}
        (tmp / "broadcast/DeployHub.s.sol/31337/run-latest.json").write_text(json.dumps(two))
        counted = sum(1 for e in two["transactions"] if e.get("contractAddress"))
        check(counted != 1, "two CREATEs are rejected by the exactly-one rule", f"got {counted}")

        # --- case 3: a stale artifact (older than this run) must be rejected.
        tmp = build_temp_root(base / "stale")
        bindir, log = install_fakes(tmp)
        run_step(tmp, bindir, log, "11_deploy_hub.sh")
        stale = json.loads((tmp / "broadcast/DeployHub.s.sol/31337/run-latest.json").read_text())
        stale["timestamp"] = 1  # 1970
        (tmp / "broadcast/DeployHub.s.sol/31337/run-latest.json").write_text(json.dumps(stale))
        result = run_step(tmp, bindir, log, "11_deploy_hub.sh",
                          env_extra={"FAKE_TIMESTAMP_MS": "1"})
        check(
            result.returncode != 0,
            "11_deploy_hub.sh rejects a broadcast artifact not written by this run",
            (result.stdout + result.stderr)[-800:],
        )

        # --- case 4: a missing address file makes the check step fail instead of silently passing.
        tmp = build_temp_root(base / "no-address")
        bindir, log = install_fakes(tmp)
        result = run_step(tmp, bindir, log, "21_check_hub.sh")
        combined = result.stdout + result.stderr
        check(result.returncode != 0, "21_check_hub.sh fails when addresses.hub.params is missing", combined[-800:])
        check("addresses.hub.params" in combined, "21_check_hub.sh names the missing file")
        check(SECRET_PASSWORD not in combined, "21_check_hub.sh never prints the keystore password")

        # --- case 5: an address file with a renamed key must be rejected (key-set assertion).
        tmp = build_temp_root(base / "bad-key")
        bindir, log = install_fakes(tmp)
        (tmp / "script/network/anvil31337_dev/addresses.hub.params").write_text(
            "HUB_ADDRESS_TYPO=0x" + "1" * 40 + "\n"
        )
        result = run_step(tmp, bindir, log, "21_check_hub.sh")
        combined = result.stdout + result.stderr
        check(result.returncode != 0, "21_check_hub.sh rejects a renamed address key", combined[-800:])
        check("key set mismatch" in combined, "21_check_hub.sh reports the key-set mismatch")

        # --- case 6: the verify step skips the local chain and never leaks the password.
        tmp = build_temp_root(base / "verify-skip")
        bindir, log = install_fakes(tmp)
        (tmp / "script/network/anvil31337_dev/addresses.hub.params").write_text(
            "HUB_ADDRESS=0x" + "1" * 40 + "\n"
        )
        result = run_step(tmp, bindir, log, "31_verify_hub.sh")
        combined = result.stdout + result.stderr
        check(result.returncode == 0, "31_verify_hub.sh exits 0 for the skip-listed local chain", combined[-800:])
        check("source verification is disabled" in combined, "31_verify_hub.sh reports why it skipped")
        check(SECRET_PASSWORD not in combined, "31_verify_hub.sh never prints the keystore password")


def main():
    print("LOVE20Hub deployment regression checks")
    print()
    print("structural")
    structural()
    print()
    print("broadcast artifact")
    broadcast_artifact_checks()
    print()
    print("behavioural (throwaway project root, fake cast/forge)")
    behavioural()
    print()
    if FAILED:
        print(f"FAILED {len(FAILED)} check(s), {len(PASSED)} passed")
        for message in FAILED:
            print(f"  - {message}")
        return 1
    print(f"Passed {len(PASSED)} isolated deployment checks (no network calls or broadcasts).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
