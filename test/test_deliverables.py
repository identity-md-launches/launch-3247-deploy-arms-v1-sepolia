"""Offline structural checks for the form, evidence and unsigned registration helper."""
import json
from pathlib import Path
import re
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "script"))
from prepare_control_map import form_spec  # noqa: E402


class DeliverablesTest(unittest.TestCase):
    def test_form_keys_and_sentinels(self):
        text = (ROOT / "forms/control-map-v1.txt").read_text()
        self.assertEqual(re.findall(r"^Key (\d+)\.", text, re.M), [str(x) for x in range(1, 14)])
        for marker in ("ARMS_UNKNOWN", "ARMS_NOT_APPLICABLE"):
            expected = subprocess.check_output(["cast", "keccak", marker], text=True).strip()
            self.assertIn(expected, text)
        for word in re.findall(r"0x[0-9a-f]{50,}", text):
            self.assertEqual(len(word), 66)
        self.assertIn("NO never substitutes", text)

    def test_every_evidence_key_matches_the_same_snapshot(self):
        root = ROOT / "docs/evidence"
        snapshot = json.loads((root / "sepolia-readback.json").read_text())
        answers = json.loads((root / "control-map-answers.json").read_text())
        self.assertEqual(len(answers["answers"]), 13)
        for key in range(1, 14):
            evidence = json.loads((root / f"key-{key:02}.json").read_text())
            self.assertEqual(evidence["humanKey"], key)
            self.assertEqual(evidence["armsIndex"], key - 1)
            self.assertEqual(evidence["target"], snapshot["target"])
            self.assertEqual(evidence["atBlock"], snapshot["block"])
            self.assertEqual(evidence["blockHash"], snapshot["blockHash"])
            self.assertRegex(evidence["bytes32"], r"^0x[0-9a-f]{64}$")
            self.assertEqual(evidence["bytes32"], answers["answers"][key - 1])
            for path in evidence["localEvidence"]:
                self.assertTrue((root / path).is_file())
        self.assertEqual(answers["intentionalChallenge"]["armsIndex"], 8)
        self.assertEqual(answers["intentionalChallenge"]["correctValue"], answers["answers"][8])
        self.assertTrue(all(x["runtime_matches_pinned_block"] for x in snapshot["verification"].values()))

    def test_registration_hash_includes_uri_keys_and_exact_file_bytes(self):
        # A computation fixture only. This test makes no claim this new file was in the base commit.
        commit = "6afdcba7c3e53da390012c2e54a9b03aa6fe0f79"
        content = (ROOT / "forms/control-map-v1.txt").read_bytes()
        spec = form_spec(commit, content)
        changed = form_spec(commit, content + b"\n")
        self.assertNotEqual(spec["textHash"], changed["textHash"])
        self.assertNotEqual(spec["formId"], changed["formId"])
        self.assertLessEqual(len(spec["uri"]), 200)
        self.assertEqual(spec["keyCount"], 13)
        self.assertIn("/" + commit + "/forms/control-map-v1.txt", spec["uri"])
        for invalid in ("main", "COMMIT", "", "0x" + commit, commit[:-1]):
            with self.assertRaises(ValueError):
                form_spec(invalid, content)


if __name__ == "__main__":
    unittest.main()
