#!/usr/bin/env python3
"""Prepare unsigned registration/post calldata after publication and network deployment.

No transaction is sent. Requires the actual published commit and Arms deployment;
refuses missing form bytes, a different chain, or absent contract code.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess

from read_sepolia import RPC, cast, get

ROOT = Path(__file__).resolve().parents[1]
REPO = "identity-md-launches/launch-3241-build-test-deploy-sepolia"


def form_spec(commit, content):
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Use the actual immutable 40-hex published commit, not a branch or placeholder")
    uri = f"https://raw.githubusercontent.com/{REPO}/{commit}/forms/control-map-v1.txt"
    assert len(uri.encode()) <= 200
    text_hash = cast("keccak", "0x" + content.hex())
    form_id = cast("keccak", cast("abi-encode", "f(bytes32,uint8,string)", text_hash, "13", uri))
    return {"uri": uri, "textHash": text_hash, "keyCount": 13, "formId": form_id}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--arms", required=True, help="The confirmed network deployment address")
    args = parser.parse_args()
    arms = args.arms.lower()
    if not re.fullmatch(r"0x[0-9a-f]{40}", arms) or int(arms, 16) == 0:
        parser.error("--arms must be the actual nonzero deployment address")
    spec = form_spec(args.commit, (ROOT / "forms/control-map-v1.txt").read_bytes())
    published = subprocess.check_output(["curl", "-fsSL", "--max-time", "30", spec["uri"]])
    if published != (ROOT / "forms/control-map-v1.txt").read_bytes():
        raise ValueError("Published form differs from this checkout; refusing to prepare registration")

    def rpc(method, params):
        response = get(RPC, {"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
        if "error" in response:
            raise ValueError(response["error"])
        return response["result"]

    if int(rpc("eth_chainId", []), 16) != 11155111:
        raise ValueError("RPC is not Sepolia")

    def view(to, signature, *values):
        return rpc("eth_call", [{"to": to, "data": cast("calldata", signature, *values)}, "latest"])

    def address(to, getter):
        return "0x" + view(to, getter)[-40:]

    contracts = {"Arms": arms}
    for label, getter in (("MockToken", "token()"), ("IMDCourt", "court()"),
                          ("ArmsForms", "formRegistry()"), ("ArmsResults", "resultCalculator()")):
        contracts[label] = address(arms, getter)
    for addr in contracts.values():
        if rpc("eth_getCode", [addr, "latest"]) == "0x":
            raise ValueError(f"No deployed code at {addr}")
    court = contracts["IMDCourt"]
    intake = address(court, "intake()")
    asset = address(court, "feeAsset()")
    price = int(view(court, "fee()"), 16)
    network = next(x for x in get("https://api.imd.fun/requests/capabilities")["onchain"]["chains"]
                   if x["chainId"] == 11155111)
    action = next(x for x in network["actions"] if x["action"] == "oracle.request")
    if (intake != network["intake"].lower() or asset != network["asset"].lower()
            or view(court, "action()") != action["actionId"]):
        raise ValueError("Court configuration differs from current Sepolia capabilities")
    published_signer = get("https://api.imd.fun/oracle/requests?limit=1")["attester"].lower()
    if address(court, "oracleSigner()") != published_signer:
        raise ValueError("Court signer differs from the live attester; owner migration is needed")
    snapshot = json.loads((ROOT / "docs/evidence/sepolia-readback.json").read_text())
    block = rpc("eth_getBlockByNumber", [hex(snapshot["block"]), False])
    if block["hash"] != snapshot["blockHash"]:
        raise ValueError("Evidence block was reorganized; collect evidence again")
    fee = int(view(contracts["ArmsForms"], "minFee()"), 16)
    registered = int(view(contracts["ArmsForms"], "info(bytes32)", spec["formId"])[2:66], 16) != 0
    def call(signature, *values):
        return {"to": arms, "value": "0", "data": cast("calldata", signature, *values)}
    result = {
        "status": "unsigned-not-sent", "chainId": 11155111, "commit": args.commit,
        **spec, "contracts": contracts, "alreadyRegistered": registered,
        "oracle": {"intake": intake, "asset": asset, "signer": published_signer,
                   "price": str(price), "callbackGasLimit": int(view(intake, "callbackGas()"), 16)},
        "registration": call("registerForm(bytes32,uint8,string)", spec["textHash"], "13", spec["uri"]),
        "serve": call("serve(bytes32,uint256)", spec["formId"], str(fee)),
        "post": call("post(bytes32,uint256,address,uint256,uint256)", spec["formId"], "11155111",
                     snapshot["target"], str(snapshot["block"]), str(fee)),
        "evidence": "docs/evidence/control-map-answers.json"}
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
