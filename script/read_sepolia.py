#!/usr/bin/env python3
"""Public read-only evidence capture; no signing, accounts, environment reads or dependencies.

Run manually with network access. Forge tests do not execute this script.
"""
import datetime
import json
from pathlib import Path
import subprocess

OUTPUT = Path(__file__).resolve().parents[1] / "docs/evidence"
RPC = "https://ethereum-sepolia-rpc.publicnode.com"


def get(url, body=None):
    cmd = ["curl", "-sS", "--fail-with-body", "--max-time", "40", url]
    if body is not None:
        cmd += ["-H", "content-type: application/json", "--data-binary", "@-"]
    p = subprocess.run(cmd, input=json.dumps(body) if body is not None else None,
                       capture_output=True, text=True, check=False)
    if p.returncode:
        raise RuntimeError(p.stdout[:400] or p.stderr[:400])
    return json.loads(p.stdout)


def cast(*args):
    return subprocess.check_output(["cast", *args], text=True).strip()


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    reads = []

    def read(method, params):
        response = get(RPC, {"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
        if "error" in response:
            raise RuntimeError(str(response["error"]))
        reads.append({"method": method, "params": params, "result": response["result"]})
        return response["result"]

    capabilities = get("https://api.imd.fun/requests/capabilities")
    network = next(x for x in capabilities["onchain"]["chains"] if x["chainId"] == 11155111)
    attester = get("https://api.imd.fun/oracle/requests?limit=1")["attester"]
    assert int(read("eth_chainId", []), 16) == 11155111
    head = int(read("eth_blockNumber", []), 16)
    block = head - 8
    tag = hex(block)
    header = read("eth_getBlockByNumber", [tag, False])
    intake, target = network["intake"], network["asset"]
    action = next(x for x in network["actions"] if x["action"] == "oracle.request")
    target_code = read("eth_getCode", [target, tag])
    intake_code = read("eth_getCode", [intake, tag])

    def view(addr, sig, *args, sender=None):
        tx = {"to": addr, "data": cast("calldata", sig, *args)}
        if sender:
            tx["from"] = sender
        return read("eth_call", [tx, tag])

    price = int(view(intake, "priceOf(bytes32,address)", action["actionId"], target), 16)
    gas = int(view(intake, "callbackGas()"), 16)
    owner = "0x" + view(target, "owner()")[-40:]
    owner_code = read("eth_getCode", [owner, tag])
    view(target, "symbol()")
    view(target, "decimals()")
    for label in ("eip1967.proxy.implementation", "eip1967.proxy.admin", "eip1967.proxy.beacon"):
        slot = "0x" + format(int(cast("keccak", label), 16) - 1, "064x")
        read("eth_getStorageAt", [target, slot, tag])
    # Simulation only: no transaction or balance change, including approve.
    approve = view(target, "approve(address,uint256)", intake, "0", sender=owner)
    transfer = view(target, "transferFrom(address,address,uint256)", owner, intake, "0", sender=owner)
    assert int(approve, 16) == int(transfer, 16) == 1
    verified = {}
    for name, addr, code in (("ImdTest", target, target_code), ("Intake", intake, intake_code)):
        url = f"https://eth-sepolia.blockscout.com/api/v2/smart-contracts/{addr}"
        data = get(url)
        (OUTPUT / f"{name}-verified-source.json").write_text(json.dumps(data, indent=2) + "\n")
        verified[name] = {"url": url, **{k: data.get(k) for k in (
            "name", "is_verified", "is_fully_verified", "is_partially_verified", "verified_at")},
            "runtime_matches_pinned_block": data.get("deployed_bytecode", "").lower() == code.lower(),
            "runtime_hash": cast("keccak", code)}
        assert verified[name]["is_verified"] and verified[name]["runtime_matches_pinned_block"]
    # Confirm the pinned block did not change during capture.
    assert read("eth_getBlockByNumber", [tag, False])["hash"] == header["hash"]
    result = {
        "observedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "sources": {
            "docs": "https://imd.fun/skill/onchain.md", "oracleDocs": "https://imd.fun/skill/oracle.md",
            "capabilities": "https://api.imd.fun/requests/capabilities",
            "attester": "https://api.imd.fun/oracle/requests?limit=1",
            "rpc": RPC, "rpcDocumentation": "https://ethereum.publicnode.com/?sepolia"},
        "chainId": 11155111, "head": head, "block": block, "blockHash": header["hash"],
        "blockTimestamp": int(header["timestamp"], 16), "network": network, "attester": attester,
        "oraclePrice": str(price), "callbackGas": gas, "target": target,
        "ownerRoot": owner, "ownerCode": owner_code, "verification": verified, "reads": reads}
    (OUTPUT / "sepolia-readback.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: result[k] for k in (
        "block", "blockHash", "target", "ownerRoot", "ownerCode", "attester", "oraclePrice", "callbackGas")}, indent=2))


if __name__ == "__main__":
    main()
