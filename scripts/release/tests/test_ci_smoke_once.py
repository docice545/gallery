"""A boot retry must not turn a failed or interrupted product test green."""

import importlib.util
import io
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from contextlib import redirect_stdout
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / ".github/scripts/run-ci-smoke-once.py"
SPEC = importlib.util.spec_from_file_location("ci_smoke_once", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SmokeOnceTests(unittest.TestCase):
    def setUp(self):
        # Expected failure annotations belong to the fixture, not this CI job.
        self.enterContext(redirect_stdout(io.StringIO()))

    def test_failed_first_attempt_cannot_be_replaced_by_a_successful_second(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory, "smoke-state")
            counter = Path(directory, "invocations")
            command = [sys.executable, "-c", "from pathlib import Path; import sys; Path(sys.argv[1]).write_text('first'); sys.exit(7)", str(counter)]
            result = subprocess.run([sys.executable, str(SCRIPT), str(marker), "--", *command], check=False)
            self.assertEqual(result.returncode, 7)
            second = [sys.executable, "-c", "from pathlib import Path; import sys; Path(sys.argv[1]).write_text('second')", str(counter)]
            result = subprocess.run([sys.executable, str(SCRIPT), str(marker), "--", *second], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("Smoke retry refused", result.stdout)
            self.assertEqual(counter.read_text(), "first")
            self.assertEqual(marker.read_text(), "completed exit=7\n")

    def test_success_returns_zero_but_does_not_allow_another_product_attempt(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory, "smoke-state")
            with patch.object(MODULE.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run:
                self.assertEqual(MODULE.run_once(marker, ["test-command"]), 0)
                self.assertEqual(MODULE.run_once(marker, ["test-command"]), 1)
                run.assert_called_once()

    def test_interrupted_attempt_and_launch_failure_remain_blocked(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory, "smoke-state")
            marker.write_text("started\n")
            with patch.object(MODULE.subprocess, "run") as run:
                self.assertEqual(MODULE.run_once(marker, ["test-command"]), 1)
                run.assert_not_called()
            marker.unlink()
            with patch.object(MODULE.subprocess, "run", side_effect=FileNotFoundError) as run:
                self.assertEqual(MODULE.run_once(marker, ["test-command"]), 127)
                self.assertEqual(MODULE.run_once(marker, ["test-command"]), 1)
                run.assert_called_once()

    def test_official_and_offline_workflows_apply_guard_before_the_product_script(self):
        source = (ROOT / ".github/workflows/original-noodle-gallery-compatibility.yml").read_text()
        self.assertEqual(source.count('python3 .github/scripts/run-ci-smoke-once.py "$RUNNER_TEMP/'), 2)
        for script in ("android_emulator_smoke.sh", "foto_offline_emulator_smoke.sh"):
            lines = [line for line in source.splitlines() if f"bash tools/original-noodle-gallery/{script}" in line]
            self.assertEqual(len(lines), 1)
            self.assertIn("run-ci-smoke-once.py", lines[0])


if __name__ == "__main__":
    unittest.main()
