#!/usr/bin/env python3
"""LOVE20Hub deployment regression checks.

`tools` keeps a suite like this because a shell-script bug is invisible to `forge test`; this
repository needs the same guard. The checks are structural and behavioural, no network and no
broadcast.

Regression this suite exists to catch: `11_deploy_hub.sh` counted the raw occurrences of
`"contractAddress"` in the broadcast artifact. forge 1.8.1 writes that address twice per
deployment (`transactions[]` and `receipts[]`), so the count was always 2, the script exited with
an error *after* a successful broadcast, and `addresses.hub.params` was never written — a deployed
contract with no recorded address. `require_broadcast_matches_hub` must therefore de-duplicate
before counting, and must still reject an artifact holding two distinct addresses.

Usage:
    python3 test/deploy_scripts_test.py
Exit code 0 when every check passes.
"""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

# params.sh is one byte-identical copy per deployable repository; the hash is the only thing
# stopping drift between them.
PARAMS_SH_SHA256 = "b3a8f64dc87d9e823a364de92e3bc79144d246f1c1a861cdcf95616042b8f840"

HUB_A = "0xAbCdEf0123456789AbCdEf0123456789AbCdEf01"
HUB_B = "0x1111111111111111111111111111111111111111"

ADDRESS_VALUE = re.compile(r"0x[0-9a-fA-F]{40}")
# A deployment record carries the address on a line `"contractAddress": "0x…"`. Anchoring on the key
# keeps an address that merely appears inside some other field from being counted as a deployment.
CONTRACT_ADDRESS = re.compile(r'"contractAddress"\s*:\s*"0x[0-9a-fA-F]{40}"')


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def code_lines(text: str) -> str:
    """Drop comment-only lines: a marker inside a comment must not satisfy an assertion."""
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


def extract_matches(text: str) -> list[str]:
    """Mirror the shell extraction: pull the address off each contract-address line, de-duplicate."""
    found = [ADDRESS_VALUE.search(line).group(0) for line in CONTRACT_ADDRESS.findall(text)]
    seen: list[str] = []
    for address in found:
        lowered = address.lower()
        if lowered not in [s.lower() for s in seen]:
            seen.append(lowered)
    return seen


def broadcast_lines(transactions: list[dict], receipts: list[dict]) -> str:
    entries = [{"contractAddress": tx["contractAddress"]} for tx in transactions]
    receipts_entries = [{"contractAddress": rc["contractAddress"]} for rc in receipts]
    return json.dumps({"transactions": entries, "receipts": receipts_entries}, indent=2)


def check_params_hash() -> str | None:
    path = repo_root() / "script" / "deploy" / "params.sh"
    if not path.is_file():
        return "script/deploy/params.sh is missing"
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != PARAMS_SH_SHA256:
        return f"params.sh drifted: {digest} != {PARAMS_SH_SHA256}"
    return None


def check_step_scripts() -> list[str]:
    problems: list[str] = []
    deploy_dir = repo_root() / "script" / "deploy"
    # No whole-repository one-click entry: the contract set is not frozen, so each module ships
    # its own `one_click_deploy_<module>.sh`.
    if (deploy_dir / "one_click_deploy.sh").exists():
        problems.append("a repository-wide one_click_deploy.sh must not exist (contract set is not frozen)")
    for name in ("one_click_deploy_hub.sh", "11_deploy_hub.sh", "21_check_hub.sh", "31_verify_hub.sh"):
        path = deploy_dir / name
        if not path.is_file():
            problems.append(f"missing deploy script: script/deploy/{name}")
        elif not path.stat().st_mode & 0o111:
            problems.append(f"deploy script is not executable: script/deploy/{name}")
    return problems


def check_broadcast_guard() -> list[str]:
    """The guard must de-duplicate, and must still reject zero / two distinct addresses."""
    problems: list[str] = []

    single = broadcast_lines([{"contractAddress": HUB_A}], [{"contractAddress": HUB_A}])
    matches = extract_matches(single)
    if len(matches) != 1:
        problems.append(f"one deployment recorded twice must collapse to 1 address, got {len(matches)}")
    elif matches[0].lower() != HUB_A.lower():
        problems.append(f"de-duplicated address is wrong: {matches[0]}")

    # The regression: counting raw occurrences yields 2 here and would reject a valid deployment.
    raw = len(CONTRACT_ADDRESS.findall(single))
    if raw != 2:
        problems.append(f"fixture no longer models forge's duplicated write (raw count {raw})")

    two = broadcast_lines(
        [{"contractAddress": HUB_A}, {"contractAddress": HUB_B}], [{"contractAddress": HUB_A}]
    )
    if len(extract_matches(two)) != 2:
        problems.append("two distinct deployments must stay 2 addresses so the guard can reject them")

    empty = broadcast_lines([], [])
    if extract_matches(empty):
        problems.append("an artifact without deployments must yield no addresses")

    # An address that is not a deployment record must not be extracted.
    decoy = json.dumps({"note": f"sender {HUB_A} is not a deployment"}, indent=2)
    if extract_matches(decoy):
        problems.append("a non-`contractAddress` occurrence must not be counted as a deployment")
    return problems


def check_script_source() -> list[str]:
    """The guard in the shipped script must keep the de-duplication; a revert re-opens the bug."""
    problems: list[str] = []
    path = repo_root() / "script" / "deploy" / "11_deploy_hub.sh"
    if not path.is_file():
        return ["script/deploy/11_deploy_hub.sh is missing"]
    body = code_lines(path.read_text())
    if "sort -u" not in body:
        problems.append("11_deploy_hub.sh must de-duplicate contract addresses before counting (sort -u)")
    if "require_broadcast_matches_hub" not in body:
        problems.append("11_deploy_hub.sh must call require_broadcast_matches_hub")
    if "python3" in body:
        problems.append("11_deploy_hub.sh must not depend on python3 (foundry + coreutils only)")
    # A hardcoded address in a deploy script is a configuration leak. Lines that *validate* an
    # address spell the pattern `0x[0-9a-fA-F]{40}`, so ignore the regex-quantifier form and the
    # zero-address sentinel; anything else with 40 hex digits is a literal deployment address.
    for number, line in enumerate(body.splitlines(), start=1):
        if "{40}" in line or "0x0000000000000000000000000000000000000000" in line:
            continue
        if ADDRESS_VALUE.search(line):
            problems.append(f"11_deploy_hub.sh:{number} hardcodes an address")
    return problems


def check_network_profiles() -> list[str]:
    problems: list[str] = []
    network_dir = repo_root() / "script" / "network"
    profiles = [p for p in network_dir.iterdir() if p.is_dir()] if network_dir.is_dir() else []
    if not profiles:
        problems.append("script/network holds no profile directory")
    for profile in profiles:
        required = {"network.params", "hub.params"}
        present = {p.name for p in profile.glob("*.params")}
        missing = required - present
        if missing:
            problems.append(f"{profile.name} is missing {sorted(missing)}")
        if not (profile / ".account.example").exists():
            problems.append(f"{profile.name} is missing .account.example")
        # The real key file must never be committed.
        if (profile / ".account").exists():
            problems.append(f"{profile.name}/.account must not be committed")
    return problems


def check_events_tables() -> list[str]:
    problems: list[str] = []
    events = repo_root() / "script" / "events"
    for name in ("events-baseline.txt", "event-families.txt", "check-events.py"):
        if not (events / name).is_file():
            problems.append(f"missing event table: script/events/{name}")
    families = events / "event-families.txt"
    if families.is_file() and "periphery.hub" not in families.read_text():
        problems.append("event-families.txt must register the periphery.hub family")
    return problems


def check_ci_workflow() -> list[str]:
    problems: list[str] = []
    workflow = repo_root() / ".github" / "workflows" / "ci.yml"
    if not workflow.is_file():
        return ["missing .github/workflows/ci.yml"]
    text = workflow.read_text()
    for needle in ("forge test", "forge lint", "check-events.py", "deploy_scripts_test.py"):
        if needle not in text:
            problems.append(f"ci.yml does not run `{needle}`")
    return problems


def check_shell_syntax() -> list[str]:
    problems: list[str] = []
    for path in sorted((repo_root() / "script").rglob("*.sh")):
        result = subprocess.run(["bash", "-n", str(path)], capture_output=True, text=True)
        if result.returncode != 0:
            problems.append(f"{path.relative_to(repo_root())}: {result.stderr.strip()}")
    return problems


def main() -> int:
    checks = {
        "params.sh hash": check_params_hash(),
        "deploy scripts": check_step_scripts(),
        "broadcast guard": check_broadcast_guard(),
        "script source": check_script_source(),
        "network profiles": check_network_profiles(),
        "event tables": check_events_tables(),
        "ci workflow": check_ci_workflow(),
        "shell syntax": check_shell_syntax(),
    }
    failures = 0
    for name, result in checks.items():
        problems = [] if result is None else (result if isinstance(result, list) else [result])
        if problems:
            failures += len(problems)
            for problem in problems:
                print(f"FAIL [{name}] {problem}")
        else:
            print(f"ok   [{name}]")
    if failures:
        print(f"\n{failures} deployment check(s) failed.")
        return 1
    print(f"\nPassed {len(checks)} deployment checks (no network calls or broadcasts).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
