"""Disposable subprocess/OS lock tests; no Codex/systemd/HP or real OOM is invoked."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / 'foto-stage-runner.py'


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.repo = self.base / 'repo'
        self.repo.mkdir()
        self.state = self.base / 'state'
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.calls = self.base / 'calls'
        self.pid_file = self.base / 'child-pid'
        self.spec = 'src/example.spec.ts'
        (self.repo / 'server/src').mkdir(parents=True)
        (self.repo / 'server' / self.spec).write_text('// synthetic fixture\n')
        self.node = self.bin / 'node'
        self.node.write_text('''#!/usr/bin/env python3
import json, os, signal, subprocess, sys, time
with open(os.environ['CALLS'], 'a') as f:
    f.write(json.dumps({'argv':sys.argv[1:], 'env':{k:os.environ.get(k) for k in ['NODE_OPTIONS','GRADLE_OPTS','CI','MAKEFLAGS']}})+'\\n')
mode=os.environ.get('MODE','ok')
if mode == 'oom': os.kill(os.getpid(),signal.SIGKILL)  # exit simulation, NOT a real memory exhaustion test
if mode == 'error': sys.exit(23)
if mode == 'tree':
    child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'])
    open(os.environ['CHILD_PID'],'w').write(str(child.pid))
    time.sleep(60)
if mode == 'escaped':
    child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'],start_new_session=True)
    open(os.environ['CHILD_PID'],'w').write(str(child.pid))
if mode == 'slow': time.sleep(1)
print('synthetic check completed')
''')
        self.node.chmod(0o700)
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
            CALLS=str(self.calls), CHILD_PID=str(self.pid_file))
        for cmd in (['init', '-q'], ['config', 'user.email', 'fixture@example.invalid'],
                    ['config', 'user.name', 'Fixture'], ['add', '.'], ['commit', '-qm', 'fixture']):
            subprocess.run(['git', '-C', str(self.repo), *cmd], check=True, capture_output=True)

    def argv(self, *args):
        return [sys.executable, str(RUNNER), '--repo', str(self.repo), '--state', str(self.state), *args]

    def run_stage(self, *options, mode='ok'):
        return subprocess.run(self.argv(*options, 'unit', self.spec), env=dict(self.env, MODE=mode),
            capture_output=True, text=True, timeout=15)

    def receipts(self):
        return [json.loads(p.read_text()) for p in (self.state / 'stages').glob('*.json')]

    def wait_file(self, path):
        deadline = time.monotonic() + 5
        while not path.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(path.exists(), str(path))

    def test_one_worker_and_memory_flags_are_enforced(self):
        self.assertEqual(self.run_stage().returncode, 0)
        call = json.loads(self.calls.read_text())
        self.assertIn('--maxWorkers=1', call['argv'])
        self.assertIn('--no-file-parallelism', call['argv'])
        self.assertIn('--maxConcurrency=1', call['argv'])
        self.assertEqual(call['env']['NODE_OPTIONS'], '--max-old-space-size=3072')
        self.assertIn('org.gradle.parallel=false', call['env']['GRADLE_OPTS'])

    def test_parallel_request_is_rejected_not_queued(self):
        p = subprocess.Popen(self.argv('unit', self.spec), env=dict(self.env, MODE='slow'),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.wait_file(self.calls)
            r = self.run_stage()
            self.assertNotEqual(r.returncode, 0)
            self.assertIn('BUSY', r.stderr)
        finally:
            p.communicate(timeout=10)
        self.assertEqual(len(self.calls.read_text().splitlines()), 1)

    def test_exact_success_can_be_reused(self):
        self.assertEqual(self.run_stage().returncode, 0)
        r = self.run_stage('--resume')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('PASS_REUSED', r.stdout)
        self.assertEqual(len(self.calls.read_text().splitlines()), 1)

    def test_changed_source_cannot_reuse_success(self):
        self.assertEqual(self.run_stage().returncode, 0)
        (self.repo / 'server' / self.spec).write_text('// changed\n')
        self.assertEqual(self.run_stage('--resume').returncode, 0)
        self.assertEqual(len(self.calls.read_text().splitlines()), 2)

    def test_changed_tool_invalidates_success(self):
        self.assertEqual(self.run_stage().returncode, 0)
        self.node.write_text(self.node.read_text() + '# updated tool\n')
        self.assertEqual(self.run_stage('--resume').returncode, 0)
        self.assertEqual(len(self.calls.read_text().splitlines()), 2)

    def test_tampered_log_is_not_a_success(self):
        self.assertEqual(self.run_stage().returncode, 0)
        next((self.state / 'stages').glob('*.log')).write_text('forged')
        r = self.run_stage('--resume')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('CHECKPOINT_LOG_MISMATCH', r.stderr)

    def test_failure_is_recorded_and_not_automatically_retried(self):
        r = self.run_stage(mode='error')
        self.assertEqual(r.returncode, 23)
        self.assertTrue(all(r['status'] == 'FAIL' for r in self.receipts()))
        self.assertNotEqual(self.run_stage('--resume').returncode, 0)
        self.assertEqual(len(self.calls.read_text().splitlines()), 1)
        self.assertEqual(self.run_stage('--retry-failed').returncode, 0)
        self.assertTrue(any(r['status'] == 'FAIL' for r in self.receipts()))
        self.assertTrue(any(r['status'] == 'PASS' for r in self.receipts()))

    def test_simulated_oom_is_failure_without_retry(self):
        self.assertNotEqual(self.run_stage(mode='oom').returncode, 0)
        self.assertNotEqual(self.run_stage('--resume').returncode, 0)
        self.assertEqual(len(self.calls.read_text().splitlines()), 1)
        self.assertFalse(any(r['status'] == 'PASS' for r in self.receipts()))

    def test_term_kills_and_reaps_grandchild(self):
        p = subprocess.Popen(self.argv('unit', self.spec), env=dict(self.env, MODE='tree'),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.wait_file(self.pid_file)
            child = int(self.pid_file.read_text())
            p.send_signal(signal.SIGTERM)
            p.communicate(timeout=12)
            self.assertEqual(p.returncode, 143)
            with self.assertRaises(ProcessLookupError):
                os.kill(child, 0)
            self.assertNotEqual(self.run_stage('--resume').returncode, 0)
            self.assertEqual(self.run_stage('--retry-failed').returncode, 0)
        finally:
            if p.poll() is None:
                p.kill()
                p.communicate()

    def test_corrupt_receipt_is_preserved_not_overwritten(self):
        self.assertEqual(self.run_stage().returncode, 0)
        for p in (self.state / 'stages').glob('*.json'):
            p.write_text('{interrupted write')
        self.assertNotEqual(self.run_stage('--resume').returncode, 0)
        self.assertTrue(all(p.read_text() == '{interrupted write' for p in (self.state / 'stages').glob('*.json')))

    def test_escaped_daemon_is_terminated_before_next_stage(self):
        self.assertEqual(self.run_stage(mode='escaped').returncode, 0)
        child = int(self.pid_file.read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(child, 0)

    def test_session_stop_cleans_up_its_process_tree(self):
        p = subprocess.Popen(self.argv('session', str(self.node)), env=dict(self.env, MODE='tree'),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.wait_file(self.pid_file)
            child = int(self.pid_file.read_text())
            p.send_signal(signal.SIGTERM)
            p.communicate(timeout=12)
            self.assertEqual(p.returncode, 143)
            with self.assertRaises(ProcessLookupError):
                os.kill(child, 0)
        finally:
            if p.poll() is None:
                p.kill()
                p.communicate()

    def test_running_receipt_requires_explicit_recovery(self):
        self.assertEqual(self.run_stage().returncode, 0)
        for p in (self.state / 'stages').glob('*.json'):
            d = json.loads(p.read_text())
            d['status'] = 'RUNNING'
            p.write_text(json.dumps(d))
        self.assertNotEqual(self.run_stage('--resume').returncode, 0)
        self.assertEqual(self.run_stage('--retry-failed').returncode, 0)

    def test_state_symlink_is_rejected(self):
        other = self.base / 'other'
        other.mkdir(mode=0o700)
        self.state.symlink_to(other)
        self.assertNotEqual(self.run_stage().returncode, 0)
        self.assertFalse(self.calls.exists())

    def test_checkpoint_symlink_is_rejected(self):
        self.assertEqual(self.run_stage().returncode, 0)
        receipt = next(p for p in (self.state / 'stages').glob('*.json') if len(p.stem) == 64)
        receipt.unlink()
        receipt.symlink_to(self.base / 'untouched')
        self.assertNotEqual(self.run_stage('--resume').returncode, 0)
        self.assertFalse((self.base / 'untouched').exists())

    def test_arbitrary_options_and_outside_files_are_rejected(self):
        for arg in ('--maxWorkers=8', '../outside.spec.ts'):
            r = subprocess.run(self.argv('unit', arg), env=self.env, capture_output=True)
            self.assertNotEqual(r.returncode, 0)
        self.assertFalse(self.calls.exists())

    def test_session_lock_is_shared_between_launchers(self):
        p = subprocess.Popen(self.argv('session', str(self.node)), env=dict(self.env, MODE='slow'),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.wait_file(self.calls)
            r = subprocess.run(self.argv('session', str(self.node)), env=self.env, capture_output=True, text=True)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn('BUSY', r.stderr)
        finally:
            p.communicate(timeout=10)
        self.assertEqual(len(self.calls.read_text().splitlines()), 1)

    def test_manifest_history_is_not_modified(self):
        self.state.mkdir(mode=0o700)
        manifest = self.state / 'manifest.json'
        original = b'{"history":[{"legacy":"preserve"}],"expected_head":"not-fabricated"}\n'
        manifest.write_bytes(original)
        self.assertEqual(self.run_stage().returncode, 0)
        self.assertEqual(manifest.read_bytes(), original)


class SandboxTests(unittest.TestCase):
    def test_both_sandboxes_stop_entire_cgroup_without_restart(self):
        for name in ('codex-gallery-safe', 'codex-foto-continue'):
            text = (ROOT / name).read_text()
            for prop in ('MemoryMax=8G', 'MemorySwapMax=1G', 'CPUQuota=200%', 'KillMode=control-group',
                         'OOMPolicy=stop', 'Restart=no', 'TimeoutStopSec=15s', 'SendSIGKILL=yes',
                         'NoNewPrivileges=yes', 'ProtectSystem=strict', '/run/docker.sock', '/mnt/synology-homes'):
                self.assertIn(prop, text, (name, prop))
            subprocess.run(['bash', '-n', str(ROOT / name)], check=True)

    def test_continuation_has_no_oom_retry_path(self):
        text = (ROOT / 'foto-integration-continue-v2').read_text()
        self.assertIn('rc == 137', text)
        self.assertLess(text.index('RESOURCE_FAILURE'), text.index('CONTEXT_RESTART'))
        self.assertIn('foto-stage-runner.py --resume', text)
        subprocess.run(['bash', '-n', str(ROOT / 'foto-integration-continue-v2')], check=True)


if __name__ == '__main__':
    unittest.main()
