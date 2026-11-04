"""Exercise CI log boundaries and exit status with fake tools, never a device."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "android_native_motion_test.sh"


class NativeMotionLauncherTests(unittest.TestCase):
    def launch(self, status):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            flutter = root / "flutter"
            flutter.write_text("""#!/usr/bin/env python3
import os, sys
from pathlib import Path
with Path(os.environ['RUNNER_TEMP'], 'calls').open('a') as file:
    file.write(' '.join(sys.argv[1:]) + '\\n')
if sys.argv[1] == 'test':
    print('build output ' * 2000)
    print('FINAL_NATIVE_FAILURE_MARKER\\n::error::untrusted output')
    if os.environ['FIXTURE_EXIT'] == '0':
        print('Native timeline smoke: synthetic successful wrapper fixture')
    sys.exit(int(os.environ['FIXTURE_EXIT']))
""")
            adb = root / "adb"
            adb.write_text("""#!/usr/bin/env python3
import sys
assert sys.argv[1:3] == ['-s', 'emulator-5554']
print('android fixture ' * 600)
print('FINAL_ANDROID_EXIT_MARKER')
""")
            flutter.chmod(0o700)
            adb.chmod(0o700)
            result = subprocess.run(
                ['bash', str(SCRIPT)], cwd=root,
                env={**os.environ, 'PATH': str(root) + os.pathsep + os.environ['PATH'],
                     'RUNNER_TEMP': str(root), 'FIXTURE_EXIT': str(status)},
                text=True, capture_output=True, timeout=10,
            )
            calls = (root / 'calls').read_text().splitlines()
            log = (root / 'gallery-native-motion-test.log').read_text()
            return result, calls, log

    def test_failure_keeps_status_and_final_native_and_android_evidence_within_annotation_limits(self):
        result, calls, log = self.launch(17)
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertEqual(len(calls), 2)
        self.assertTrue(calls[0].startswith('build apk --debug'))
        self.assertTrue(calls[1].startswith('test --no-pub integration_test/timeline_native_motion_test.dart'))
        self.assertIn('FINAL_NATIVE_FAILURE_MARKER', log)
        annotations = [line for line in result.stdout.splitlines() if line.startswith('::error title=')]
        self.assertLessEqual(len(annotations), 6)
        self.assertTrue(all(len(line) < 4096 for line in annotations))
        combined = '\n'.join(annotations)
        self.assertIn('FINAL_NATIVE_FAILURE_MARKER', combined)
        self.assertIn('FINAL_ANDROID_EXIT_MARKER', combined)
        self.assertIn('%0A::error::untrusted output', combined)
        self.assertNotIn('::notice title=Native decoded playback evidence', result.stdout)

    def test_success_still_requires_successful_test_and_retains_receipt(self):
        result, calls, _ = self.launch(0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 2)
        self.assertIn('::notice title=Native decoded playback evidence::Native timeline smoke:', result.stdout)
        self.assertNotIn('::error title=', result.stdout)


if __name__ == '__main__':
    unittest.main()
