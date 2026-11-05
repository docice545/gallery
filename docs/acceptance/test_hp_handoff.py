"""Exercise HP entrypoint guards in disposable Git fixtures; never access HP."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('foto-hp-check.sh')


class HandoffGuards(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.evidence = self.root / 'evidence'
        self.evidence.mkdir()
        self.git('init', '-q', '-b', 'candidate')
        self.git('config', 'user.name', 'Synthetic Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        scripts = self.repo / 'scripts/release'
        scripts.mkdir(parents=True)
        for name in ('android_release.py', 'server_artifact_smoke.py'):
            (scripts / name).write_text('# Synthetic fixture only\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture')
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        tool = self.bin / 'python3'
        tool.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$FOTO_EVIDENCE/invocation"\nexit "${FIXTURE_STATUS:-0}"\n')
        tool.chmod(0o700)
        self.env = {
            **os.environ, 'PATH': str(self.bin) + os.pathsep + os.environ['PATH'],
            'FOTO_REPO': str(self.repo), 'FOTO_EVIDENCE': str(self.evidence),
            'FOTO_SOURCE_SHA': self.git('rev-parse', 'HEAD').strip(),
            'FOTO_BRANCH': 'candidate', 'FOTO_INSTALLED': '38', 'FOTO_BUILD': '39',
        }

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.repo, text=True)

    def run_script(self, mode='preflight', **changes):
        return subprocess.run(['bash', str(SCRIPT), mode], env={**self.env, **changes},
                              text=True, capture_output=True, timeout=10)

    def assert_blocked(self, result):
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.evidence / 'invocation').exists())

    def test_preflight_dispatch_preserves_exact_identity(self):
        self.assertEqual(self.run_script().returncode, 0)
        args = (self.evidence / 'invocation').read_text().splitlines()
        self.assertEqual(args, ['scripts/release/android_release.py', 'preflight',
            '--expected-head', self.env['FOTO_SOURCE_SHA'], '--expected-branch', 'candidate',
            '--installed-build-number', '38', '--build-number', '39'])

    def test_helper_failure_is_not_reported_as_pass(self):
        result = self.run_script(FIXTURE_STATUS='31')
        self.assertEqual(result.returncode, 31)
        self.assertNotIn('PASS', result.stdout)

    def test_wrong_sha_blocks_before_tool_execution(self):
        self.assert_blocked(self.run_script(FOTO_SOURCE_SHA='a' * 40))

    def test_wrong_branch_blocks_before_tool_execution(self):
        self.assert_blocked(self.run_script(FOTO_BRANCH='other'))

    def test_dirty_checkout_is_preserved(self):
        p = self.repo / 'existing-work.txt'
        p.write_text('keep')
        self.assert_blocked(self.run_script())
        self.assertEqual(p.read_text(), 'keep')

    def test_non_upgrade_and_bad_input_are_blocked(self):
        for value in ('38', '37', 'not-a-number'):
            with self.subTest(value=value):
                self.assert_blocked(self.run_script(FOTO_BUILD=value))

    def test_backend_requires_an_explicit_existing_artifact(self):
        self.assert_blocked(self.run_script('backend-tests', FOTO_BACKEND_ARTIFACT=str(self.root / 'missing')))


if __name__ == '__main__':
    unittest.main()
