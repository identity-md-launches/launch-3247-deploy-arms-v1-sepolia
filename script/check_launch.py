#!/usr/bin/env python3
"""Validate the manifest against the supplied evm_contracts reference and built ABIs offline."""
import json
from pathlib import Path
import re

CONTRACTS = ("Arms", "ArmsForms", "ArmsResults", "IMDCourt", "MockCourt", "MockToken", "MockIntake")
ROOT = Path(__file__).resolve().parents[1]
manifest = json.loads((ROOT / "launch.json").read_text())
assert set(manifest) == {"kind", "contracts", "notes"}
assert manifest["kind"] == "evm_contracts"
assert isinstance(manifest["notes"], str) and manifest["notes"]
assert 1 <= len(manifest["contracts"]) <= 8
seen = set()
for entry in manifest["contracts"]:
    assert set(entry) == {"contract", "constructorArgs"}
    name = entry["contract"]
    assert re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,31}", name)
    assert name not in seen and name != "MerkleDistributor"
    artifact = json.loads((ROOT / "out" / f"{name}.sol" / f"{name}.json").read_text())
    constructor = next(x for x in artifact["abi"] if x["type"] == "constructor")
    assert len(entry["constructorArgs"]) == len(constructor["inputs"])
    for value, abi in zip(entry["constructorArgs"], constructor["inputs"]):
        assert isinstance(value, str)
        kind = abi["type"]
        if value == "$owner":
            assert kind == "address"
        elif value.startswith("$contract:"):
            assert kind == "address" and value.split(":", 1)[1] in seen
        elif kind == "address":
            assert re.fullmatch(r"0x[0-9a-f]{40}", value) and int(value, 16) != 0
        elif kind == "bytes32":
            assert re.fullmatch(r"0x[0-9a-f]{64}", value)
        else:
            assert kind.startswith("uint") and re.fullmatch(r"0|[1-9][0-9]*", value)
            assert int(value) < 2 ** int(kind[4:])
    seen.add(name)
assert [x["contract"] for x in manifest["contracts"]] == ["MockToken", "IMDCourt", "Arms"]
snapshot = json.loads((ROOT / "docs/evidence/sepolia-readback.json").read_text())
assert manifest["contracts"][1]["constructorArgs"] == [
    "$owner", snapshot["network"]["intake"], snapshot["network"]["asset"],
    next(a["actionId"] for a in snapshot["network"]["actions"] if a["action"] == "oracle.request"),
    snapshot["attester"]]
assert manifest["contracts"][2]["constructorArgs"] == [
    "$contract:MockToken", "$contract:IMDCourt", "1000000000000000000", "1000000000000000000000",
    "100000000000000000000000", "10", "1000", "3000", "21600", "7200", "604800", "604800", "1209600"]
print("Manifest: exact fields, deploy order, backward address references, live-source parameters and ABI words passed")
for name in CONTRACTS:
    artifact = json.loads((ROOT / "out" / f"{name}.sol" / f"{name}.json").read_text())
    constructors = [entry for entry in artifact["abi"] if entry["type"] == "constructor"]
    constructor = constructors[0] if constructors else {"inputs": [], "stateMutability": "nonpayable"}
    args = constructor["inputs"]
    assert len(args) <= 16, f"{name}: constructor exceeds 16 entries"
    assert constructor["stateMutability"] == "nonpayable", f"{name}: constructor takes ETH"
    for arg in args:
        assert re.fullmatch(r"address|bool|bytes32|uint(?:8|16|24|32|40|48|56|64|72|80|88|96|104|112|120|128|136|144|152|160|168|176|184|192|200|208|216|224|232|240|248|256)", arg["type"]), f"{name}: non-static argument {arg}"
    for part in ("bytecode", "deployedBytecode"):
        assert not artifact[part].get("linkReferences"), f"{name}: unlinked {part}"
    runtime = len(bytes.fromhex(artifact["deployedBytecode"]["object"].removeprefix("0x")))
    initcode = len(bytes.fromhex(artifact["bytecode"]["object"].removeprefix("0x"))) + 32 * len(args)
    assert runtime <= 24_576, f"{name}: runtime {runtime} exceeds EIP-170"
    assert initcode <= 49_152, f"{name}: initcode plus arguments {initcode} exceeds EIP-3860"
    if name == "Arms":
        assert len(args) == 13
        assert [a["name"] for a in args] == [x + "_" for x in (
            "token", "court", "minFeePerArm", "maxBondPerArm", "maxTotalBonded", "trancheMultiple",
            "burnBps", "challengerRewardBps", "commitWindow", "revealWindow", "challengeWindow", "courtDeadline", "exitDelay"
        )]
    print(f"{name}: {len(args)} static constructor entries; runtime {runtime}; initcode including arguments {initcode}; no links")
