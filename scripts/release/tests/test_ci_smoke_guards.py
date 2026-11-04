"""Exercise the offline smoke assertion without ADB or any device access."""

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "tools/original-noodle-gallery/foto_offline_emulator_smoke.sh"
WORKFLOW = ROOT / ".github/workflows/original-noodle-gallery-compatibility.yml"


class DisposableBackendDiagnosticsTests(unittest.TestCase):
    def test_logging_preserves_build_startup_and_readiness_failure(self):
        steps = re.findall(
            r"      - name: Build and start disposable FOTO backend\n(.*?)(?=      - name:)",
            WORKFLOW.read_text(),
            re.S,
        )
        self.assertEqual(len(steps), 3)
        for step in steps:
            self.assertIn("id: disposable-backend", step)
            body = step.split("        run: |\n", 1)[1]
            body = "\n".join(line[10:] for line in body.splitlines())
            for failure, code in (("build", 23), ("start", 24), ("ping", 1), ("none", 0)):
                with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                    # No Docker, network, device or sleeping: execute the real
                    # workflow shell around controlled process results.
                    stubs = r'''
docker() {
  printf 'docker fixture: %s\n' "$*"
  case "$*" in
    *' build '*) test "$FIXTURE_FAILURE" != build || return 23 ;;
    *' up '*) test "$FIXTURE_FAILURE" != start || return 24 ;;
  esac
  return 0
}
curl() {
  printf 'readiness fixture\n'
  test "$FIXTURE_FAILURE" != ping
}
sleep() { :; }
'''
                    result = subprocess.run(
                        ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", stubs + body],
                        env={**os.environ, "RUNNER_TEMP": directory, "FIXTURE_FAILURE": failure},
                        capture_output=True,
                        text=True,
                        timeout=5,
                    )
                    self.assertEqual(result.returncode, code, result.stderr)
                    log = Path(directory, "disposable-backend.log").read_text()
                    self.assertIn("docker fixture", log)
                    self.assertEqual(result.stdout, log)
                    if failure == "build":
                        self.assertNotIn("readiness fixture", log)


class OfflineSmokeGuardTests(unittest.TestCase):
    def test_error_screen_and_unreadable_capture_fail_under_errexit(self):
        source = SCRIPT.read_text()
        function = re.search(
            r"^assert_no_offline_error\(\) \{\n.*?^\}", source, re.M | re.S
        ).group()
        # Extract only the assertion: running the full script would mutate a device.
        command = (
            "set -e\n" + function + '\nassert_no_offline_error "$1"\nprintf accepted'
        )
        with tempfile.TemporaryDirectory() as directory:
            capture = Path(directory) / "window.xml"
            for text, accepted in (
                ("<node text='November 2026'/>", True),
                ("<node text='Could not load value'/>", False),
                ("<node text='ENABLE BACKUP'/>", False),
                ("<node text='Something went wrong'/>", False),
                (None, False),
            ):
                with self.subTest(capture=text):
                    if text is None:
                        capture.unlink()
                    else:
                        capture.write_text(text)
                    result = subprocess.run(
                        ["bash", "-c", command, "offline-guard-test", str(capture)],
                        capture_output=True,
                        text=True,
                        timeout=5,
                    )
                    self.assertEqual(result.returncode == 0, accepted, result.stderr)
                    self.assertEqual("accepted" in result.stdout, accepted)


if __name__ == "__main__":
    unittest.main()
