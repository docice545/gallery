"""HP shell handoff regressions with a fake Docker-free adjacent image helper."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
HELPER = r'''
import json, os, pathlib, sys
CONFIG_HASH_MODE = 'resolved-environment-compose-escaped-v1'
class Stop(Exception): pass
def need(value, code):
    if not value: raise Stop(code)
def private_json(path):
    need(path.is_file() and not path.is_symlink() and path.stat().st_mode & 0o777 == 0o600, 'PRIVATE_JSON_REQUIRED')
    return json.loads(path.read_text())
def save(path, value):
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), 'w') as out:
        json.dump(value, out)
if __name__ == '__main__':
    args = sys.argv[1:]
    with open(os.environ['MOCK_CALLS'], 'a') as out:
        out.write(json.dumps({'args': args, 'approval': os.environ.get('GALLERY_DEPLOYMENT_APPROVED')}) + '\n')
    if os.environ.get('MOCK_FAIL') == 'YES':
        print('STOP FAKE_TOOL_FAILED'); raise SystemExit(7)
    state = pathlib.Path(args[args.index('--state') + 1])
    if args[0] == 'plan':
        import hashlib
        source = pathlib.Path(os.environ['MOCK_COMPOSE'])
        save(state / 'image-plan.json', {
          'candidateImage': 'sha256:4d4f9d581a654713b6d305f9aa1341b302fd36fc4ef7fca832dcb94de4004e75',
          'previousImage': 'sha256:828523317c332cb312246c9b0ca43e0eef1eb724f7f9aadb58c61b7f87068f43',
          'sourceCommit': 'ea51a8acdc6f18ab5917c19b6f3833d740b4e9ba',
          'serverVersion': {'major': 5, 'minor': 7, 'patch': 3, 'prerelease': None},
          'configHashMode': CONFIG_HASH_MODE,
          'fileHashes': {str(source): hashlib.sha256(source.read_bytes()).hexdigest()},
          'migrationsAdded': ['unreviewed'] if os.environ.get('MOCK_MIGRATIONS') == 'YES' else []})
    print('PASS fake helper only; no Docker')
'''


class HPImageHandoff(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='gallery-hp-handoff-', dir='/tmp')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / 'operator'; self.home.mkdir(mode=0o700)
        self.runroot = self.home / 'gallery-build10-release-fixture'; self.runroot.mkdir(mode=0o700)
        self.tools = self.root / 'tools'; self.tools.mkdir(mode=0o700)
        self.script = self.tools / 'hp_build10_image_update.sh'
        self.script.write_bytes((ROOT / 'scripts/release/hp_build10_image_update.sh').read_bytes())
        (self.tools / 'image_release.py').write_text(HELPER)
        self.bin = self.root / 'bin'; self.bin.mkdir(mode=0o700)
        (self.bin / 'id').write_text(f'#!/bin/sh\ncase "$1" in -un) echo "${{MOCK_USER:-doctoriceadm}}" ;; -u) echo {os.getuid()} ;; *) exit 2 ;; esac\n')
        (self.bin / 'getent').write_text(f'#!/bin/sh\nprintf "%s\\n" "doctoriceadm:x:{os.getuid()}:{os.getgid()}::{self.home}:/bin/bash"\n')
        for file in self.bin.iterdir(): file.chmod(0o700)
        self.calls = self.root / 'calls.jsonl'
        self.compose = self.root / 'compose.json'; self.compose.write_text('synthetic-private-compose\n')
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'],
                        MOCK_CALLS=str(self.calls), MOCK_COMPOSE=str(self.compose))
        self.env.pop('GALLERY_DEPLOYMENT_APPROVED', None)

    def invoke(self, action, input='', changes=None):
        env = {**self.env, **(changes or {})}
        return subprocess.run(['bash', str(self.script), action, str(self.runroot)], input=input,
                              capture_output=True, text=True, env=env, timeout=20)

    def invocations(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def plan(self):
        result = self.invoke('plan')
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_plan_is_readonly_exact_release_bound_and_private_backups_are_identical(self):
        self.plan()
        calls = self.invocations()
        self.assertEqual([call['args'][0] for call in calls], ['plan', 'apply'])
        self.assertIn('ea51a8acdc6f18ab5917c19b6f3833d740b4e9ba', calls[0]['args'])
        self.assertTrue(all('--execute-approved' not in call['args'] for call in calls))
        self.assertTrue(all(call['approval'] is None for call in calls))
        self.assertEqual((self.runroot / 'compose-input-backups/input-0.backup').read_bytes(), self.compose.read_bytes())
        for file in self.runroot.rglob('*'):
            if file.is_file(): self.assertEqual(file.stat().st_mode & 0o777, 0o600)

    def test_operator_or_state_reuse_is_rejected_without_helper_execution(self):
        denied = self.invoke('plan', changes={'MOCK_USER': 'ordinary-user'})
        self.assertNotEqual(denied.returncode, 0)
        self.assertEqual(self.invocations(), [])
        self.plan()
        count = len(self.invocations())
        self.assertNotEqual(self.invoke('plan').returncode, 0)
        self.assertEqual(len(self.invocations()), count)

    def test_no_approval_or_wrong_phrase_never_executes_update(self):
        self.plan()
        for phrase in ('', 'yes\n'):
            result = self.invoke('apply', input=phrase)
            self.assertNotEqual(result.returncode, 0)
        self.assertTrue(all('--execute-approved' not in call['args'] for call in self.invocations()))

    def test_correct_phrase_separately_gates_apply_and_rollback_without_migration_override(self):
        self.plan()
        for action in ('apply', 'rollback'):
            result = self.invoke(action, input=action + ' ea51a8ac\n')
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            last = self.invocations()[-1]
            self.assertEqual(last['args'][0], action)
            self.assertEqual(last['approval'], 'YES')
            self.assertIn('--execute-approved', last['args'])
            self.assertNotIn('--approve-migration', last['args'])
            self.assertNotIn('--force-recreate', last['args'])

    def test_helper_failure_propagates_to_exit_status_and_private_log(self):
        result = self.invoke('plan', changes={'MOCK_FAIL': 'YES'})
        self.assertEqual(result.returncode, 7)
        logs = list(self.runroot.glob('plan-*.log'))
        self.assertEqual(len(logs), 1)
        self.assertIn('RESULT exit=7', logs[0].read_text())
        self.assertFalse((self.runroot / 'state/image-plan.json').exists())

    def test_pending_migration_or_changed_release_binding_stops_before_approval(self):
        self.plan()
        path = self.runroot / 'state/image-plan.json'
        original = json.loads(path.read_text())
        for field, value in (('migrationsAdded', ['unreviewed']), ('configHashMode', 'legacy'),
                             ('sourceCommit', 'a' * 40), ('candidateImage', 'sha256:' + 'a' * 64)):
            changed = {**original, field: value}; path.write_text(json.dumps(changed))
            count = len(self.invocations())
            result = self.invoke('apply', input='apply ea51a8ac\n')
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(len(self.invocations()), count)

    def test_status_reports_incomplete_attempt_as_stop_without_retry(self):
        self.plan()
        (self.runroot / 'state/apply-attempt.json').write_text('{}')
        count = len(self.invocations())
        result = self.invoke('status')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('UPDATE_ATTEMPT_INCOMPLETE_REVIEW_ROLLBACK', result.stderr)
        self.assertEqual(len(self.invocations()), count)


if __name__ == '__main__':
    unittest.main()
