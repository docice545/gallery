"""Exercise the HP tmux-facing wrapper with local fake tools, no Docker."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
ZIP = b'synthetic zip download fixture, no release media'
SHA = hashlib.sha256(ZIP).hexdigest()
FAKE = r'''
import json, os, pathlib, sys
CI_ARTIFACT = 123
ZIP_SHA256 = 'ZIP_SHA_PLACEHOLDER'
class Stop(Exception): pass
def need(value, code):
    if not value: raise Stop(code)
if __name__ == '__main__':
    with open(os.environ['MOCK_CALLS'], 'a') as out:
        out.write(json.dumps({'args': sys.argv[1:], 'approval': os.environ.get('GALLERY_DEPLOYMENT_APPROVED')}) + '\n')
    if os.environ.get('MOCK_FAIL') == 'YES':
        print('STOP FAKE_VERIFICATION_FAILED'); raise SystemExit(7)
    root = pathlib.Path(sys.argv[sys.argv.index('--run-root') + 1])
    if sys.argv[1] == 'prepare':
        (root / 'hardened-rollback').mkdir(mode=0o700)
    print('PASS fake only')
'''.replace('ZIP_SHA_PLACEHOLDER', SHA)


class ShellTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='gallery-rollback-shell-')
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.home = self.root / 'operator'
        self.home.mkdir(mode=0o700)
        self.runroot = self.home / 'gallery-build10-release-existing'
        self.runroot.mkdir(mode=0o700)
        self.tools = self.root / 'tools'
        self.tools.mkdir(mode=0o700)
        self.script = self.tools / 'hp_build10_rollback.sh'
        self.script.write_bytes((ROOT / 'scripts/release/hp_build10_rollback.sh').read_bytes())
        self.driver = self.tools / 'hp_build10_rollback.py'
        self.driver.write_text(FAKE)
        (self.tools / 'build10-rollback-tooling.sha256').write_text(''.join(
            hashlib.sha256(file.read_bytes()).hexdigest() + '  ' + file.name + '\n' for file in (self.script, self.driver)))
        self.bin = self.root / 'bin'
        self.bin.mkdir(mode=0o700)
        (self.bin / 'id').write_text(f'#!/bin/sh\ncase "$1" in -un) echo "${{MOCK_USER:-doctoriceadm}}" ;; -u) echo {os.getuid()} ;; *) exit 2 ;; esac\n')
        (self.bin / 'getent').write_text(f'#!/bin/sh\necho "doctoriceadm:x:{os.getuid()}:{os.getgid()}::{self.home}:/bin/bash"\n')
        (self.bin / 'gh').write_text('#!/bin/sh\nif [ "${MOCK_DOWNLOAD_FAIL:-}" = YES ]; then\n'
                                    '  echo "must-not-log-signed-url" >&2; exit 1\nfi\n'
                                    'printf %s "synthetic zip download fixture, no release media"\n')
        for file in self.bin.iterdir():
            file.chmod(0o700)
        self.calls = self.root / 'calls.jsonl'
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'], MOCK_CALLS=str(self.calls))
        self.env.pop('GALLERY_DEPLOYMENT_APPROVED', None)

    def invoke(self, action, approval='', changes=None):
        return subprocess.run(['bash', str(self.script), action, str(self.runroot)], input=approval,
                              env={**self.env, **(changes or {})}, capture_output=True, text=True, timeout=20)

    def called(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def test_prepare_downloads_once_and_never_sets_execution_approval(self):
        result = self.invoke('prepare')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.called()
        self.assertEqual([item['args'][0] for item in calls], ['prepare'])
        self.assertTrue(all('--execute-approved' not in item['args'] and item['approval'] is None for item in calls))
        archive = self.runroot / 'hardened-rollback-123.zip'
        self.assertEqual(archive.read_bytes(), ZIP)
        self.assertEqual(archive.stat().st_mode & 0o777, 0o600)
        self.assertIn('RESULT exit=0', result.stdout)

    def test_continue_requires_approval_after_full_dry_run_then_reports_completion(self):
        result = self.invoke('continue', 'apply ea51a8ac\n')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.called()
        self.assertEqual([item['args'][0] for item in calls], ['prepare', 'apply', 'apply', 'status'])
        self.assertNotIn('--execute-approved', calls[1]['args'])
        self.assertIn('--execute-approved', calls[2]['args'])
        self.assertEqual(calls[2]['approval'], 'YES')
        self.assertTrue(all(item['approval'] is None for index, item in enumerate(calls) if index != 2))
        self.assertIn('cross-owner admin preparation is unavailable only on fallback', result.stdout)

    def test_wrong_approval_never_executes_or_silently_deploys(self):
        result = self.invoke('continue', 'yes\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('OPERATOR_DID_NOT_APPROVE', result.stdout)
        self.assertTrue(all('--execute-approved' not in item['args'] for item in self.called()))

    def test_failed_preflight_stops_chain_and_preserves_journal(self):
        result = self.invoke('continue', 'apply ea51a8ac\n', {'MOCK_FAIL': 'YES'})
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
        self.assertEqual(len(self.called()), 1)
        self.assertIn('RESULT exit=7', result.stdout)
        self.assertEqual(len(list(self.runroot.glob('rollback-continue-*.log'))), 1)

    def test_changed_downloaded_zip_stops_before_driver(self):
        archive = self.runroot / 'hardened-rollback-123.zip'
        archive.write_bytes(b'wrong archive')
        archive.chmod(0o600)
        result = self.invoke('prepare')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.called(), [])
        self.assertEqual(archive.read_bytes(), b'wrong archive')

    def test_failed_download_never_logs_a_signed_url_or_invokes_driver(self):
        result = self.invoke('continue', 'apply ea51a8ac\n', {'MOCK_DOWNLOAD_FAIL': 'YES'})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('PINNED_ARTIFACT_DOWNLOAD_FAILED', result.stdout)
        self.assertNotIn('must-not-log-signed-url', result.stdout + result.stderr)
        self.assertEqual(self.called(), [])
        self.assertFalse((self.runroot / 'hardened-rollback').exists())

    def test_changed_tooling_is_rejected_before_actions(self):
        self.driver.write_text(FAKE + '\n# changed\n')
        result = self.invoke('continue', 'apply ea51a8ac\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.called(), [])

    def test_existing_phase_is_checked_without_redownload_or_reinitialization(self):
        phase = self.runroot / 'hardened-rollback'
        phase.mkdir(mode=0o700)
        (phase / 'failure.txt').write_bytes(b'old evidence')
        result = self.invoke('continue', 'no\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([item['args'][0] for item in self.called()], ['check', 'apply'])
        self.assertEqual((phase / 'failure.txt').read_bytes(), b'old evidence')

    def test_rollback_is_separately_approved_and_never_calls_prepare(self):
        result = self.invoke('rollback', 'rollback ea51a8ac\n')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.called()
        self.assertEqual([item['args'][0] for item in calls], ['rollback', 'rollback', 'status'])
        self.assertNotIn('--execute-approved', calls[0]['args'])
        self.assertIn('--execute-approved', calls[1]['args'])
        self.assertEqual(calls[1]['approval'], 'YES')

    def test_wrong_operator_is_rejected_before_actions(self):
        result = self.invoke('prepare', changes={'MOCK_USER': 'other'})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.called(), [])


if __name__ == '__main__':
    unittest.main()
