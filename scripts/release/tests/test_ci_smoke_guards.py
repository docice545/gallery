"""Exercise the offline smoke assertion without ADB or any device access."""

import re
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "tools/original-noodle-gallery/foto_offline_emulator_smoke.sh"


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
