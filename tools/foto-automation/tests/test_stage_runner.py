"""Disposable subprocess/OS lock tests; no Codex/systemd/HP or real OOM is invoked."""
import importlib.util
import fcntl
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
    f.write(json.dumps({'argv':sys.argv[1:], 'cpus':len(os.sched_getaffinity(0)), 'env':{k:os.environ.get(k) for k in ['NODE_OPTIONS','GRADLE_OPTS','CI','MAKEFLAGS']}})+'\\n')
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
if mode == 'build':
    from pathlib import Path
    for name in ['dist/main.js','dist/bin/sync-open-api.js']:
        p=Path(name); p.parent.mkdir(parents=True,exist_ok=True); p.write_text('synthetic compiled output')
if mode == 'slow': time.sleep(1)
print('synthetic check completed')
''')
        self.node.chmod(0o700)
        (self.repo / '.gitignore').write_text('server/dist/\n')
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
            CALLS=str(self.calls), CHILD_PID=str(self.pid_file))
        for cmd in (['init', '-q'], ['config', 'user.email', 'fixture@example.invalid'],
                    ['config', 'user.name', 'Fixture'], ['add', '.'], ['commit', '-qm', 'fixture']):
            subprocess.run(['git', '-C', str(self.repo), *cmd], check=True, capture_output=True)

    def argv(self, *args):
        return [sys.executable, str(RUNNER), '--repo', str(self.repo), '--state', str(self.state),
            '--legacy-lock', str(self.base / 'legacy.lock'), *args]

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
        self.assertLessEqual(call['cpus'], 2)

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

    def test_existing_proxy_is_forwarded_without_credentials(self):
        self.env['HTTPS_PROXY'] = 'http://fixture-user:fixture-password@proxy.example:8080'
        self.assertEqual(self.run_stage().returncode, 0)
        opts = json.loads(self.calls.read_text())['env']['GRADLE_OPTS']
        self.assertIn('-Dhttps.proxyHost=proxy.example', opts)
        self.assertNotIn('fixture-password', opts)

    def test_proxy_hostname_cannot_inject_gradle_arguments(self):
        self.env['HTTPS_PROXY'] = 'http://proxy%20-Dorg.gradle.workers.max=8:8080'
        r = self.run_stage()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('UNSUPPORTED_PROXY_HOST', r.stderr)
        self.assertFalse(self.calls.exists())

    def test_exact_success_can_be_reused(self):
        self.assertEqual(self.run_stage().returncode, 0)
        r = self.run_stage('--resume')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('PASS_REUSED', r.stdout)
        self.assertEqual(len(self.calls.read_text().splitlines()), 1)

    def test_modified_build_output_cannot_reuse_success(self):
        pnpm = self.bin / 'pnpm'
        pnpm.write_bytes(self.node.read_bytes())
        pnpm.chmod(0o700)
        r = subprocess.run(self.argv('backend-build'), env=dict(self.env, MODE='build'), capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        (self.repo / 'server/dist/main.js').write_text('tampered output')
        r = subprocess.run(self.argv('--resume', 'backend-build'), env=self.env, capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('CHECKPOINT_OUTPUT_MISMATCH', r.stderr)

    def test_android_jre_fails_before_starting_a_build(self):
        flutter = self.bin / 'flutter'
        flutter.write_bytes(self.node.read_bytes())
        flutter.chmod(0o700)
        r = subprocess.run(self.argv('android-apk'), env=dict(self.env, JAVA_HOME=str(self.base / 'missing-jdk')),
            capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('FULL_JDK_REQUIRED', r.stderr)
        self.assertFalse(self.calls.exists())

    def android_fixture(self):
        (self.repo / 'mobile').mkdir()
        (self.repo / '.gitignore').write_text('server/dist/\nmobile/build/\n')
        subprocess.run(['git', '-C', str(self.repo), 'add', '.gitignore'], check=True, capture_output=True)
        subprocess.run(['git', '-C', str(self.repo), 'commit', '-qm', 'synthetic Android build output ignore'],
            check=True, capture_output=True)
        compiler = self.base / 'jdk/bin/javac'
        compiler.parent.mkdir(parents=True)
        compiler.touch(mode=0o700)
        flutter = self.bin / 'flutter'
        flutter.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
with open(os.environ['CALLS'], 'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')
if sys.argv[1:3] == ['pub','get'] and os.environ.get('MODE') == 'error': sys.exit(23)
if sys.argv[1:3] == ['build','apk']:
    assert '--no-pub' not in sys.argv
    out=Path('build/app/outputs/flutter-apk/app-release.apk')
    out.parent.mkdir(parents=True,exist_ok=True); out.write_bytes(b'synthetic output, not a real APK')
''')
        flutter.chmod(0o700)
        return dict(self.env, JAVA_HOME=str(compiler.parents[1]))

    def test_android_frozen_dependencies_precede_release_plugin_generation(self):
        env = self.android_fixture()
        r = subprocess.run(self.argv('android-apk'), env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual([json.loads(line) for line in self.calls.read_text().splitlines()],
            [['pub', 'get', '--enforce-lockfile'], ['build', 'apk', '--release']])

    def test_android_lockfile_failure_never_starts_gradle_build(self):
        env = dict(self.android_fixture(), MODE='error')
        r = subprocess.run(self.argv('android-apk'), env=env, capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual([json.loads(line) for line in self.calls.read_text().splitlines()],
            [['pub', 'get', '--enforce-lockfile']])

    def test_host_wrapper_term_is_not_deferred_until_unit_finishes(self):
        unit_pid = self.base / 'unit-pid'
        stopped = self.base / 'unit-stopped'
        systemd = self.bin / 'systemd-run'
        systemd.write_text('#!/usr/bin/env python3\nimport os,time\n'
            'open(os.environ["UNIT_PID"],"w").write(str(os.getpid()))\ntime.sleep(60)\n')
        systemctl = self.bin / 'systemctl'
        systemctl.write_text('#!/usr/bin/env python3\nimport os,signal\n'
            'open(os.environ["UNIT_STOPPED"],"a").write("stop\\n")\n'
            'try:\n fd=os.pidfd_open(int(open(os.environ["UNIT_PID"]).read())); '
            'signal.pidfd_send_signal(fd,signal.SIGTERM); os.close(fd)\n'
            'except ProcessLookupError: pass\n')
        systemd.chmod(0o700)
        systemctl.chmod(0o700)
        for name in ('codex-gallery-safe', 'codex-foto-continue'):
            with self.subTest(wrapper=name):
                if unit_pid.exists():
                    unit_pid.unlink()  # this test's private fixture, never a real lock or checkpoint
                p = subprocess.Popen(['bash', str(ROOT / name)], start_new_session=True,
                    env=dict(self.env, UNIT_PID=str(unit_pid), UNIT_STOPPED=str(stopped)),
                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                try:
                    self.wait_file(unit_pid)
                    p.send_signal(signal.SIGTERM)
                    p.communicate(timeout=5)
                    self.assertEqual(p.returncode, 130)
                    self.assertTrue(stopped.exists())
                finally:
                    if p.poll() is None:
                        os.killpg(p.pid, signal.SIGKILL)
                        p.communicate()

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

    def test_legacy_launcher_blocks_new_codex_session(self):
        legacy = self.base / 'legacy.lock'
        legacy.touch(mode=0o600)
        with legacy.open('r+') as f:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            r = subprocess.run(self.argv('session', str(self.node)), env=self.env, capture_output=True, text=True)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn('BUSY', r.stderr)
            self.assertFalse(self.calls.exists())

    def test_new_session_blocks_existing_legacy_lock_for_its_entire_lifetime(self):
        legacy = self.base / 'legacy.lock'
        legacy.touch(mode=0o644)  # safely allow old read-only-to-others lock modes; never chmod it
        before = legacy.stat()
        p = subprocess.Popen(self.argv('session', str(self.node)), env=dict(self.env, MODE='slow'),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.wait_file(self.calls)
            with legacy.open('r+') as f:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            p.communicate(timeout=10)
        self.assertEqual(p.returncode, 0)
        after = legacy.stat()
        self.assertEqual((before.st_ino, before.st_mode), (after.st_ino, after.st_mode))

    def test_missing_legacy_lock_is_initialized_without_any_checkpoint_history(self):
        r = subprocess.run(self.argv('session', str(self.node)), env=self.env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue((self.base / 'legacy.lock').is_file())
        self.assertFalse((self.state / 'manifest.json').exists())

    def test_nested_continuation_cannot_reuse_parent_session_marker(self):
        self.state.mkdir(mode=0o700)
        (self.state / 'foto-stage-runner.py').write_bytes(RUNNER.read_bytes())
        script = self.base / 'continuation.sh'
        text = (ROOT / 'foto-integration-continue-v2').read_text()
        text = text.replace('STATE_DIR=/mnt/hp-data/codex-work/foto-integration-state', 'STATE_DIR=' + str(self.state))
        text = text.replace('REPO=/mnt/hp-data/codex-work/foto-integration', 'REPO=' + str(self.repo))
        script.write_text(text)
        script.chmod(0o700)
        # A following command prevents Bash's last-command exec optimization:
        # this must really create a nested shell, not become the allowed entry PID.
        r = subprocess.run(self.argv('session', '/bin/bash', '-c', '"$1" --resume; result=$?; exit "$result"', 'fixture', str(script)),
            env=self.env, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('BUSY', r.stdout + r.stderr)
        self.assertFalse(self.calls.exists())

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
