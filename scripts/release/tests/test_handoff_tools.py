from __future__ import annotations

import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import importlib.util

ROOT = Path(__file__).resolve().parents[3]
_AUDIT_SPEC = importlib.util.spec_from_file_location("hp_readonly_audit", ROOT / "scripts/diagnostics/hp-readonly-audit.py")
assert _AUDIT_SPEC and _AUDIT_SPEC.loader
audit = importlib.util.module_from_spec(_AUDIT_SPEC)
_AUDIT_SPEC.loader.exec_module(audit)
PREFLIGHT = ROOT / "scripts/release/hp-preflight.sh"
MANIFEST = ROOT / "release-manifest-20261028.json"


class ReadonlyAuditSqlTests(unittest.TestCase):
    def test_owner_queries_use_psql_literal_variable_and_read_only_transaction(self) -> None:
        with patch.object(audit, "subprocess") as mocked:
            mocked.run.return_value = type("Result", (), {"returncode": 0, "stdout": "{}\n", "stderr": ""})()
            audit.read_only_query("dsn", "SELECT :'owner'::uuid;", "00000000-0000-4000-8000-000000000001")
            args, kwargs = mocked.run.call_args
            self.assertIn("--set", args[0])
            self.assertIn("owner=00000000-0000-4000-8000-000000000001", args[0])
            self.assertIn("SET TRANSACTION READ ONLY", kwargs["input"])
            self.assertIn("ROLLBACK", kwargs["input"])
            self.assertIn(":'owner'", kwargs["input"])
            self.assertNotIn("--command", args[0])

    def test_manifest_is_not_ready_and_has_build22_contract(self) -> None:
        data = json.loads(MANIFEST.read_text())
        self.assertEqual(data["mobile"]["packageId"], "de.opennoodle.gallery")
        self.assertEqual(data["mobile"]["versionCode"], 22)
        self.assertEqual(len(data["mobile"]["productionCertificateSha256"]), 64)
        self.assertEqual(data["releaseGates"]["overall"], "NOT_RELEASE_READY")


class HpPreflightTests(unittest.TestCase):
    def test_linked_worktree_with_git_file_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "source"
            linked = root / "linked"
            source.mkdir()
            subprocess.run(["git", "init", "-q", str(source)], check=True)
            subprocess.run(["git", "-C", str(source), "config", "user.email", "test@example.test"], check=True)
            subprocess.run(["git", "-C", str(source), "config", "user.name", "Test"], check=True)
            (source / "README").write_text("fixture\n")
            subprocess.run(["git", "-C", str(source), "add", "README"], check=True)
            subprocess.run(["git", "-C", str(source), "commit", "-qm", "fixture"], check=True)
            sha = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
            subprocess.run(["git", "-C", str(source), "remote", "add", "origin", "https://github.com/docice545/gallery.git"], check=True)
            subprocess.run(["git", "-C", str(source), "worktree", "add", "-q", str(linked), "HEAD"], check=True)
            self.assertTrue((linked / ".git").is_file())
            result = subprocess.run(
                [str(PREFLIGHT), "--repo", str(linked), "--expected-sha", sha],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("PASS read-only HP preflight", result.stdout)


if __name__ == "__main__":
    unittest.main()
