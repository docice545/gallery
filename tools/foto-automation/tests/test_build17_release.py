"""Release orchestration tests. Real temporary Git/files; mocked GitHub/Docker/Android, never HP."""
import copy
import ast
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import MagicMock, Mock, patch
import zipfile

SCRIPT = Path(__file__).resolve().parents[1] / 'foto-build17-release'
loader = importlib.machinery.SourceFileLoader('foto_build17_release', str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
app = importlib.util.module_from_spec(spec)
loader.exec_module(app)
REAL_GIT = app.git
REAL_REQUIRED_CHECKS = copy.deepcopy(app.REQUIRED_CHECKS)
# Representative output of the v0.35.0 commands/inspect.go tabwriter, not an HP capture.
BUILDX035_INSPECT = '''Name:          foto17-limited
Driver:        docker-container
Last Activity: 2026-10-23 09:00:00 +0000 UTC

Nodes:
Name:             foto17-limited0
Endpoint:         rootless
Driver Options:   memory="10g" memory-swap="12g"
Status:           running
BuildKit version: v0.28.0
Platforms:        linux/amd64, linux/386
Labels:
 org.mobyproject.buildkit.worker.executor: oci
Devices:
 Name: synthetic-nested-device-not-a-node
GC Policy rule#0:
 All:           false
 Keep Duration: 48h0m0s
'''
# Exact v0.35.0 lsContext.MarshalJSON field names, synthetic refs/timestamps.
# The Completed/Completed/Error sequence was confirmed by the HP operator;
# this fixture is not a captured production history or a real-daemon test.
BUILDX035_HISTORY = '\n'.join(json.dumps({
    'ref': f'foto17-limited/foto17-limited0/synthetic-{i}', 'name': 'synthetic build',
    'status': status, 'created_at': '2026-10-23T00:00:00Z', 'completed_at': '2026-10-23T00:00:01Z',
    'total_steps': 3, 'completed_steps': 3, 'cached_steps': 0,
}) for i, status in enumerate(('Completed', 'Completed', 'Error')))


@contextlib.contextmanager
def fake_buildx035(**changes):
    """A subprocess CLI fixture, no real Docker daemon or host connection."""
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        data = {'inspect': BUILDX035_INSPECT, 'memory': 10 * 1024**3, 'swap': 12 * 1024**3,
                'parallelism': 1, 'running': True, 'oom': False, 'history': 'Completed',
                'endpoint': f'unix:///run/user/{os.getuid()}/docker.sock'}
        data.update(changes)
        (root / 'data.json').write_text(json.dumps(data))
        executable = root / 'docker'
        executable.write_text('#!' + sys.executable + '\n' + '''
import io, json, os, pathlib, sys, tarfile
root = pathlib.Path(os.environ['FOTO_BUILDX_TEST_FIXTURE'])
data = json.loads((root / 'data.json').read_text())
argv = sys.argv[1:]
with (root / 'calls.jsonl').open('a') as log:
    log.write(json.dumps(argv) + '\\n')
if argv == ['context', 'inspect', 'rootless']:
    print(json.dumps([{'Endpoints': {'docker': {'Host': data['endpoint']}}}]))
elif argv == ['--context', 'rootless', 'info', '--format', '{{json .}}']:
    print(json.dumps({'SecurityOptions': ['name=rootless']}))
elif argv[:5] == ['--context', 'rootless', 'buildx', 'inspect', 'foto17-limited']:
    if len(argv) != 5:
        print('unknown flag: --format', file=sys.stderr)
        sys.exit(125)
    print(data['inspect'])
elif argv == ['--context', 'rootless', 'inspect', 'buildx_buildkit_foto17-limited0']:
    print(json.dumps([{'HostConfig': {'Memory': data['memory'], 'MemorySwap': data['swap']},
                      'State': {'Running': data['running'], 'OOMKilled': data['oom']}}]))
elif argv == ['--context', 'rootless', 'cp', 'buildx_buildkit_foto17-limited0:/etc/buildkit/buildkitd.toml', '-']:
    content = ('[worker.oci]\\nmax-parallelism = ' + str(data['parallelism']) + '\\n').encode()
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w') as tar:
        item = tarfile.TarInfo('buildkitd.toml')
        item.size = len(content)
        tar.addfile(item, io.BytesIO(content))
    sys.stdout.buffer.write(buffer.getvalue())
elif argv == ['--context', 'rootless', 'buildx', 'history', 'ls', '--builder', 'foto17-limited', '--format', '{{json .}}']:
    if data['history'] is None:
        sys.exit(1)
    if 'history_raw' in data:
        sys.stdout.write(data['history_raw'])
    else:
        print(json.dumps({'status': data['history']}))
else:
    print('unsupported fixture command', file=sys.stderr)
    sys.exit(99)
''')
        executable.chmod(0o700)
        with patch.dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'],
                        FOTO_BUILDX_TEST_FIXTURE=str(root)):
            yield root


class Buildx035Test(unittest.TestCase):
    def test_text_accepts_real_field_layout_and_nested_device_name(self):
        for data in (BUILDX035_INSPECT, BUILDX035_INSPECT.replace('        ', '\t')):
            with self.subTest(data=data):
                app.validate_builder_inspect(data)

    def test_text_rejects_missing_duplicate_wrong_or_extra_critical_fields(self):
        replacements = (
            ('docker-container', 'docker'), ('foto17-limited\n', 'other-builder\n'),
            ('foto17-limited0', 'foto17-limited1'), ('rootless', 'default'),
            ('rootless', f'unix:///run/user/{os.getuid()}/docker.sock'),
            ('running', 'stopped'), ('running', 'inactive'),
            ('Status:           running\n', ''), ('Endpoint:         rootless\n', ''),
            ('Name:             foto17-limited0\n', ''), ('Nodes:\n', ''),
            ('Driver:        docker-container\n', ''),
            ('Driver:        docker-container', 'Driver: docker-container\nDriver: docker-container'),
            ('Endpoint:         rootless', 'Endpoint: rootless\nEndpoint: rootless'),
            ('Status:           running', 'Status: running\nStatus: running'),
            ('Nodes:', 'Nodes:\nNodes:'),
            ('Endpoint:         rootless', ' Endpoint: rootless'),
            ('Status:           running', ' Status: running'),
            ('Status:           running', 'Status: running\nError: unavailable'),
        )
        bad = [BUILDX035_INSPECT.replace(old, new) for old, new in replacements]
        bad += ['', '{}', 'unknown flag: --format',
                BUILDX035_INSPECT + '\n Name: foto17-limited1\n Endpoint: rootless\n Status: running\n',
                BUILDX035_INSPECT + '\nName: foto17-limited0\nEndpoint: rootless\nStatus: running\n',
                BUILDX035_INSPECT.split('Nodes:', 1)[0] + 'Nodes:\n',
                BUILDX035_INSPECT.replace('Name:             foto17-limited0\n', 'Endpoint: rootless\nName: foto17-limited0\n')]
        for data in bad:
            with self.subTest(data=data), self.assertRaises(app.Stop):
                app.validate_builder_inspect(data)

    def test_v035_cli_rejects_original_flag_and_accepts_corrected_read_only_guard(self):
        with fake_buildx035() as root:
            legacy = subprocess.run(['docker', '--context', 'rootless', 'buildx', 'inspect',
                                     'foto17-limited', '--format', '{{json .}}'], capture_output=True)
            self.assertNotEqual(legacy.returncode, 0)
            self.assertIn(b'unknown flag: --format', legacy.stderr)
            (root / 'calls.jsonl').write_text('')
            app.builder_idle()
            calls = [json.loads(line) for line in (root / 'calls.jsonl').read_text().splitlines()]
        self.assertEqual(len(calls), 6)
        self.assertEqual(calls[2], ['--context', 'rootless', 'buildx', 'inspect', 'foto17-limited'])
        self.assertEqual(calls[3], ['--context', 'rootless', 'inspect', 'buildx_buildkit_foto17-limited0'])
        self.assertEqual(calls[-1][2:5], ['buildx', 'history', 'ls'])

    def test_v035_cli_retains_all_daemon_resource_and_idle_guards(self):
        cases = (
            ({'endpoint': 'tcp://production:2375'}, 'LOCAL_ROOTLESS_SOCKET_REQUIRED'),
            ({'memory': 9 * 1024**3}, 'BUILDER_MEMORY_LIMITS_CHANGED'),
            ({'swap': 13 * 1024**3}, 'BUILDER_MEMORY_LIMITS_CHANGED'),
            ({'oom': True}, 'BUILDER_UNHEALTHY_OR_OOM'),
            ({'running': False}, 'BUILDER_UNHEALTHY_OR_OOM'),
            ({'parallelism': 2}, 'BUILDKIT_PARALLELISM_NOT_ONE'),
            ({'history': 'running'}, 'BUILDKIT_ACTIVE_OR_UNKNOWN_HISTORY'),
            ({'history': 'unknown'}, 'BUILDKIT_ACTIVE_OR_UNKNOWN_HISTORY'),
            ({'history': None}, 'BUILDX_HISTORY_UNAVAILABLE'),
        )
        for changes, reason in cases:
            with self.subTest(changes=changes), fake_buildx035(**changes), self.assertRaisesRegex(app.Stop, reason):
                app.builder_idle()


class BuildxHistory035Test(unittest.TestCase):
    def test_actual_previous_runner_rejects_lowercase_fixture_corrected_runner_accepts(self):
        source = subprocess.check_output(['git', '-C', str(SCRIPT.parents[2]), 'show',
            'e603d937ef9f73da33abf85482bf2fd3f5f83395:tools/foto-automation/foto-build17-release'])
        self.assertEqual(app.runner.digest(source), '63aa0d934eac3229469ebaee863c5a46238c72107c822e5eea9d05859b85b014')
        with tempfile.TemporaryDirectory() as directory:
            old = Path(directory) / 'old-release'
            old.write_bytes(source)
            (old.parent / 'foto-stage-runner.py').write_bytes(SCRIPT.with_name('foto-stage-runner.py').read_bytes())
            loader = importlib.machinery.SourceFileLoader('foto17_legacy_buildx_history', str(old))
            module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
            loader.exec_module(module)
            with fake_buildx035(history_raw=BUILDX035_HISTORY):
                with self.assertRaisesRegex(module.Stop, 'BUILDKIT_ACTIVE_OR_UNKNOWN_HISTORY'):
                    module.builder_idle()
                app.builder_idle()

    def test_lowercase_json_records_accept_operator_confirmed_terminal_sequence(self):
        app.validate_builder_history(BUILDX035_HISTORY)
        with fake_buildx035(history_raw=BUILDX035_HISTORY):
            app.builder_idle()

    def test_running_in_any_position_blocks_even_among_completed_and_error_rows(self):
        rows = BUILDX035_HISTORY.splitlines()
        for i in range(len(rows) + 1):
            history = '\n'.join([*rows[:i], '{"status":"Running"}', *rows[i:]])
            with self.subTest(position=i), fake_buildx035(history_raw=history), \
                    self.assertRaisesRegex(app.Stop, 'BUILDKIT_ACTIVE_OR_UNKNOWN_HISTORY'):
                app.builder_idle()

    def test_missing_uppercase_ambiguous_unknown_or_wrong_type_status_fails_closed(self):
        bad = [{}, {'Status': 'Completed'}, {'status': 'Completed', 'Status': 'Running'}]
        bad += [{'status': x} for x in ('Running', 'running', 'RUNNING', 'Pending', 'Unknown', '',
                                      ' Completed ', None, False, 1, ['Completed'], {})]
        for item in bad:
            with self.subTest(item=item), self.assertRaisesRegex(app.Stop, 'BUILDKIT_ACTIVE_OR_UNKNOWN_HISTORY'):
                app.validate_builder_history(json.dumps(item))

    def test_unavailable_empty_or_whitespace_history_is_never_proof_of_idle(self):
        for history in (None, '', ' \n\t'):
            with self.subTest(history=history), self.assertRaisesRegex(app.Stop, 'BUILDX_HISTORY_UNAVAILABLE'):
                app.validate_builder_history(history)
        for history in ('', ' \n\t'):
            with fake_buildx035(history_raw=history), self.assertRaisesRegex(app.Stop, 'BUILDX_HISTORY_UNAVAILABLE'):
                app.builder_idle()

    def test_corrupt_non_object_or_duplicate_status_json_fails_closed(self):
        bad = ['null', '[]', '[{"status":"Completed"}]', '1', '"Completed"',
               '{"status":', '{"status":"Completed"} trailing',
               '{"status":"Running","status":"Completed"}',
               '{"status":"Completed","status":"Running"}',
               '{"status":"Completed"}\n\n{"status":"Error"}']
        for history in bad:
            with self.subTest(history=history), self.assertRaisesRegex(app.Stop, 'BUILDKIT_ACTIVE_OR_UNKNOWN_HISTORY'):
                app.validate_builder_history(history)

    def test_previously_allowed_terminal_cancellation_states_remain_allowed(self):
        for status in ('Completed', 'Error', 'Canceled', 'Cancelled'):
            with self.subTest(status=status):
                app.validate_builder_history(json.dumps({'status': status}))


IDLE_PSI = 'some avg10=0.00 avg60=0.00 avg300=0.00 total=123\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=45\n'
HP_LOW_PSI = 'some avg10=0.00 avg60=0.03 avg300=0.02 total=123\nfull avg10=0.00 avg60=0.01 avg300=0.00 total=45\n'


class MemoryAdmissionTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.proc, self.cg = self.root / 'proc', self.root / 'cgroup'
        (self.proc / 'pressure').mkdir(parents=True)
        (self.proc / 'self').mkdir()
        (self.proc / 'pressure/memory').write_text(IDLE_PSI)
        (self.proc / 'self/cgroup').write_text('0::/session\n')
        for path in (self.cg, self.cg / 'session'):
            path.mkdir(parents=True, exist_ok=True)
            for key, value in {'memory.max': 'max', 'memory.high': 'max',
                               'memory.current': str(1024**3), 'memory.pressure': IDLE_PSI}.items():
                (path / key).write_text(value)
        actual = app.backend_memory_reserve
        observer = patch.object(app, 'backend_memory_reserve', side_effect=lambda: actual(self.proc, self.cg))
        self.observer = observer.start()
        self.addCleanup(observer.stop)

    def admit(self, available=10 * 1024**3, total=15 * 1024**3, name='backend-image', limit='max'):
        app.check_stage_memory(name, {'memoryBytes': {'MemAvailable': available, 'MemTotal': total},
                                     'currentCgroup': {'memory.max': limit}})

    def test_memory_backend_boundary_and_confirmed_hp_values(self):
        for value in (10 * 1024**3, int(11.4 * 1024**3), 12 * 1024**3):
            with self.subTest(available=value):
                self.admit(value)
        with self.assertRaisesRegex(app.Stop, 'AVAILABLE_MEMORY'):
            self.admit(10 * 1024**3 - 1)

    def test_memory_host_reserve_boundary_swap_not_credited(self):
        self.admit(total=14 * 1024**3)
        with self.assertRaisesRegex(app.Stop, 'HOST_MEMORY_RESERVE'):
            self.admit(total=14 * 1024**3 - 1)
        with self.assertRaisesRegex(app.Stop, 'HOST_MEMORY_RESERVE'):
            self.admit(total=0)
        with self.assertRaisesRegex(app.Stop, 'AVAILABLE_MEMORY'):
            app.check_stage_memory('backend-image', {'memoryBytes': {
                'MemAvailable': 10 * 1024**3 - 1, 'MemTotal': 15 * 1024**3, 'SwapFree': 1024**4},
                'currentCgroup': {'memory.max': 'max'}})

    def test_memory_other_stages_keep_five_gib_and_six_gib_cgroup_floor(self):
        for name in ('unit-0', 'types', 'android-apk', 'flutter-0'):
            with self.subTest(name=name):
                self.admit(5 * 1024**3, name=name, limit=str(6 * 1024**3))
                with self.assertRaisesRegex(app.Stop, 'AVAILABLE_MEMORY'):
                    self.admit(5 * 1024**3 - 1, name=name)
                with self.assertRaisesRegex(app.Stop, 'CGROUP_TOO_SMALL'):
                    self.admit(name=name, limit=str(6 * 1024**3 - 1))
        self.observer.assert_not_called()

    def test_memory_psi_all_windows_and_both_kinds_reject_pressure(self):
        excessive = {'some': ('1.01', '0.51', '0.26'), 'full': ('0.11', '0.06', '0.03')}
        for kind in ('some', 'full'):
            for window, value in zip(('avg10', 'avg60', 'avg300'), excessive[kind]):
                for path in (self.proc / 'pressure/memory', self.cg / 'memory.pressure', self.cg / 'session/memory.pressure'):
                    lines = IDLE_PSI.splitlines()
                    index = 0 if kind == 'some' else 1
                    lines[index] = lines[index].replace(window + '=0.00', window + '=' + value)
                    path.write_text('\n'.join(lines) + '\n')
                    with self.subTest(path=path, kind=kind, window=window), self.assertRaisesRegex(app.Stop, 'MEMORY_PRESSURE'):
                        self.admit()
                    path.write_text(IDLE_PSI)

    def test_memory_missing_malformed_or_nonfinite_psi_is_not_idle(self):
        for text in ('', IDLE_PSI.splitlines()[0], IDLE_PSI + IDLE_PSI,
                     IDLE_PSI.replace('avg10=0.00', 'avg10=nan'), IDLE_PSI.replace('avg60=0.00', 'avg60=inf'),
                     IDLE_PSI.replace('avg300=0.00', 'avg300=-1'), IDLE_PSI.replace('total=123', 'total=x')):
            with self.subTest(text=text), self.assertRaises(app.Stop):
                app.check_memory_pressure(text)
        (self.proc / 'pressure/memory').unlink()
        with self.assertRaisesRegex(app.Stop, 'MEMORY_OBSERVATIONS_UNAVAILABLE'):
            self.admit()

    def test_memory_psi_confirmed_low_hp_pressure_is_admitted_without_writes(self):
        paths = (self.proc / 'pressure/memory', self.cg / 'memory.pressure', self.cg / 'session/memory.pressure')
        for path in paths:
            path.write_text(HP_LOW_PSI)
        before = {p: p.read_bytes() for directory in (self.proc, self.cg) for p in directory.rglob('*') if p.is_file()}
        self.admit(int(11.11 * 1024**3))
        for path, raw in before.items():
            self.assertEqual(path.read_bytes(), raw)

    def test_memory_psi_percentage_boundaries_and_distinct_some_full_budgets(self):
        bounds = {'some': ('1.00', '0.50', '0.25'), 'full': ('0.10', '0.05', '0.02')}
        lines = [kind + ' ' + ' '.join(key + '=' + value for key, value in zip(('avg10', 'avg60', 'avg300'), values))
                 + ' total=987654321' for kind, values in bounds.items()]
        app.check_memory_pressure('\n'.join(lines))  # Inclusive ceilings; total is historical, not recent PSI.
        for index, kind in enumerate(('some', 'full')):
            for key, bound in zip(('avg10', 'avg60', 'avg300'), bounds[kind]):
                changed = lines.copy()
                changed[index] = changed[index].replace(key + '=' + bound, key + '=' + str(float(bound) + 0.000001))
                with self.subTest(kind=kind, key=key), self.assertRaisesRegex(app.Stop, 'MEMORY_PRESSURE'):
                    app.check_memory_pressure('\n'.join(changed))
        app.check_memory_pressure(IDLE_PSI.replace('some avg10=0.00', 'some avg10=0.20'))
        with self.assertRaisesRegex(app.Stop, 'MEMORY_PRESSURE'):
            app.check_memory_pressure(IDLE_PSI.replace('full avg10=0.00', 'full avg10=0.20'))

    def test_memory_psi_observations_are_reloaded_between_gate_calls(self):
        for path in (self.proc / 'pressure/memory', self.cg / 'memory.pressure', self.cg / 'session/memory.pressure'):
            path.write_text(HP_LOW_PSI)
        self.admit(int(11.11 * 1024**3))
        (self.cg / 'session/memory.pressure').write_text(IDLE_PSI.replace('full avg10=0.00', 'full avg10=0.11'))
        with self.assertRaisesRegex(app.Stop, 'MEMORY_PRESSURE'):
            self.admit(int(11.11 * 1024**3))

    def test_memory_cgroup_max_high_current_and_ancestor_reserve(self):
        for directory in (self.cg, self.cg / 'session'):
            for key in ('memory.max', 'memory.high'):
                path = directory / key
                path.write_text(str(11 * 1024**3))  # current=1 GiB; exact 10 GiB headroom
                self.admit()
                path.write_text(str(11 * 1024**3 - 1))
                with self.subTest(directory=directory, key=key), self.assertRaisesRegex(app.Stop, 'CGROUP_MEMORY_RESERVE'):
                    self.admit()
                path.write_text('max')
        (self.cg / 'session/memory.current').write_text('unknown')
        with self.assertRaisesRegex(app.Stop, 'CGROUP_MEMORY_UNKNOWN'):
            self.admit()

    def test_memory_unknown_cgroup_or_path_escape_fails_closed(self):
        for membership in ('', '0::/../../host\n', '0::relative\n', '0::/session\n0::/other\n'):
            (self.proc / 'self/cgroup').write_text(membership)
            with self.subTest(membership=membership), self.assertRaisesRegex(app.Stop, 'CGROUP_MEMORY_UNKNOWN'):
                self.admit()
        (self.proc / 'self/cgroup').write_text('0::/session\n')
        (self.cg / 'session/memory.max').write_text('unknown')
        with self.assertRaisesRegex(app.Stop, 'CGROUP_MEMORY_UNKNOWN'):
            self.admit()

    def test_memory_hp_launcher_embedded_syntax_pins_and_build_only(self):
        raw = SCRIPT.with_name('foto-build17-release-hp.sh').read_bytes()
        self.assertTrue(raw.startswith(b'#!/usr/bin/env bash\n'))
        self.assertNotIn(b'\r', raw)
        text = raw.decode()
        inner = self.root / 'launch.sh'
        inner.write_text(text)
        subprocess.run(['bash', '-n', str(inner)], check=True)
        for name in app.re.findall(r"<<'(PY_[A-Z_]+)'", text):
            code = text.split("<<'" + name + "'\n", 1)[1].split('\n' + name, 1)[0]
            compile(code, name, 'exec')
        build = text.split("<<'BUILD_ONLY'\n", 1)[1].split('\nBUILD_ONLY', 1)[0]
        inner.write_text(build)
        subprocess.run(['bash', '-n', str(inner)], check=True)
        self.assertNotRegex(text, r'(?<![\w-])--(?:prepare|test|finalize)(?![\w-])')
        self.assertLess(build.index(' --build'), build.index(' --verify'))
        self.assertIn('testReceiptsSHA256', build)
        pin = app.re.search(r'FOTO_TOOLS_SHA=([a-f0-9]{40})', text)[1]
        hashes = text.split("<<'SHA256SUMS'\n", 1)[1].split('\nSHA256SUMS', 1)[0]
        for line in hashes.splitlines():
            digest, name = line.split()
            raw = subprocess.check_output(['git', 'show', pin + ':tools/foto-automation/' + name], cwd=SCRIPT.parents[2])
            self.assertEqual(app.runner.digest(raw), digest, name)
            self.assertEqual(SCRIPT.with_name(name).read_bytes(), raw, name)

    def test_memory_hp_launcher_checkpoint_guard_preserves_and_rejects_incomplete_state(self):
        text = SCRIPT.with_name('foto-build17-release-hp.sh').read_text()
        code = text.split("<<'PY_CHECKPOINT'\n", 1)[1].split('\nPY_CHECKPOINT', 1)[0]
        cfg = self.root / 'config.json'
        state_dir = self.root / 'state'
        state_dir.mkdir()
        cfg.write_text(json.dumps({'state': str(state_dir)}))
        path = state_dir / 'manifest.json'
        head = 'e5883358c48a76a82fe7db29b5cd5ac0b1fc76e2'
        names = [f'synthetic-{i}' for i in range(50)]
        original = {'prepared': True, 'mode': 'build', 'head': head, 'worktree': str(self.root / 'source'),
                    'testsComplete': names, 'history': [{'event': 'BUILD_REQUESTED'}],
                    'stages': {n: {'status': 'PASS', 'exitCode': 0, 'inputs': {'pipeline': app.REVIEWED_TEST_RUNTIME}} for n in names}}
        cases = [original]
        for key, value in (('mode', 'prepare'), ('prepared', False), ('testsComplete', names[:-1])):
            changed = copy.deepcopy(original); changed[key] = value; cases.append(changed)
        for key, value in (('status', 'FAIL'), ('exitCode', 137), ('inputs', {'pipeline': 'f' * 64})):
            changed = copy.deepcopy(original); changed['stages'][names[0]][key] = value; cases.append(changed)
        changed = copy.deepcopy(original); changed['stages']['backend-image'] = {}; cases.append(changed)
        for i, state in enumerate(cases):
            path.write_text(json.dumps(state))
            before = path.read_bytes()
            with self.subTest(case=i), patch.object(sys, 'argv', ['guard', str(cfg)]), \
                    patch.object(subprocess, 'check_output', return_value=head), patch('sys.stdout', new=io.StringIO()):
                if i == 0:
                    exec(compile(code, 'HP_CHECKPOINT_GUARD', 'exec'), {})
                else:
                    with self.assertRaises(SystemExit):
                        exec(compile(code, 'HP_CHECKPOINT_GUARD', 'exec'), {})
            self.assertEqual(path.read_bytes(), before)


class ReleaseTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.run_git('init', '-b', app.BASE_BRANCH)
        self.run_git('config', 'user.name', 'Synthetic test')
        self.run_git('config', 'user.email', 'test@localhost')
        (self.repo / 'shared.txt').write_text('base\n')
        (self.repo / '.gitignore').write_text('.ignored/\n')
        self.run_git('add', '.')
        self.run_git('commit', '-m', 'synthetic baseline')
        self.base = self.run_git('rev-parse', 'HEAD')
        self.run_git('remote', 'add', 'origin', 'https://github.com/docice545/gallery.git')
        self.heads = {}
        for role, branch in app.ROLES.items():
            self.run_git('switch', '-c', branch, self.base)
            (self.repo / (role + '.txt')).write_text(role)
            self.run_git('add', '.')
            self.run_git('commit', '-m', role)
            self.heads[role] = self.run_git('rev-parse', 'HEAD')
        self.run_git('switch', app.BASE_BRANCH)
        self.c = json.loads(SCRIPT.with_name('foto-build17-release.example.json').read_text())
        for key, value in {'repo': self.repo, 'state': self.root / 'state',
                           'automation_state': self.root / 'common', 'legacy_lock': self.root / 'legacy/auto.lock',
                           'export_dir': self.root / 'export'}.items():
            self.c[key] = str(value)
        self.c['expected_head'] = self.base
        self.c['required_checks'] = {role: ['Contract'] for role in app.ROLES}
        for i, role in enumerate(app.ROLES, 1):
            self.c['prs'][role] = {'number': i, 'sha': self.heads[role], 'approved': True, 'approval_note': 'synthetic review'}
        for path in ('state', 'common', 'legacy'):
            (self.root / path).mkdir(mode=0o700)
        self.p = app.Pipeline(self.c)
        self.calls = []
        self.patches = [patch.object(app, 'api', side_effect=self.api),
                        patch.object(app, 'git', side_effect=self.git), patch.object(app, 'processes', return_value=[]),
                        patch.object(app, 'WORK_ROOT', self.root),
                        patch.object(app, 'REQUIRED_CHECKS', {role: {'Contract'} for role in app.ROLES}),
                        patch.object(app, 'backend_memory_reserve'),
                        patch.object(app, 'resources', return_value={
                            'memoryBytes': {'MemAvailable': 32 * 1024**3, 'MemTotal': 64 * 1024**3},
                            'currentCgroup': {'memory.max': str(32 * 1024**3)}})]
        for p in self.patches:
            p.start()
        self.fd = None

    def tearDown(self):
        if self.fd is not None:
            os.close(self.fd)
        for p in reversed(self.patches):
            p.stop()
        self.temp.cleanup()

    def run_git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], stderr=subprocess.DEVNULL).decode().strip()

    def git(self, repo, *args, optional=False):
        self.calls.append(args)
        if args[0] == 'ls-remote':
            return self.c['expected_head'] + '\trefs/heads/' + app.BASE_BRANCH
        if args[0] == 'fetch':
            ref = args[-1].split(':', 1)[1]
            role = ref.split('/')[-1]
            return REAL_GIT(repo, 'update-ref', ref, self.c['prs'][role]['sha'])
        return REAL_GIT(repo, *args, optional=optional)

    def api(self, path):
        if path.endswith('/status'):
            return {'state': 'pending', 'total_count': 0}
        if 'check-runs' in path:
            return {'total_count': 1, 'check_runs': [{'name': 'Contract', 'status': 'completed', 'conclusion': 'success'}]}
        role = list(app.ROLES)[int(path.split('/')[1]) - 1]
        return {'head': {'sha': self.c['prs'][role]['sha'], 'ref': app.ROLES[role], 'repo': {'full_name': app.REPOSITORY}},
                'base': {'ref': app.BASE_BRANCH, 'sha': self.c['expected_head'], 'repo': {'full_name': app.REPOSITORY}},
                'state': 'open', 'draft': False, 'mergeable': True}

    def prepare(self):
        self.p.prepare()
        self.p.manifest['toolchain'] = 'synthetic-tool-fingerprint'
        self.p.save('SYNTHETIC_TOOLCHAIN')
        self.fd = os.open(self.root / 'test.lock', os.O_CREAT | os.O_RDWR, 0o600)
        self.p.fds = [self.fd]
        return self.p.source()

    def fake_stage(self, rc=0):
        def execute(argv, cwd, log, *args, **kwargs):
            log.write(b'synthetic subprocess result\n')
            if rc == 0:
                (cwd / '.ignored').mkdir(exist_ok=True)
                (cwd / '.ignored/output').write_text('synthetic artifact')
            return rc
        return patch.object(app.runner, 'supervise', side_effect=execute)

    def stage(self):
        with patch.object(self.p, 'environment', return_value={}):
            self.p.stage('unit-0', self.p.source(), ['/synthetic/check'], ['.ignored/output'])

    def test_real_git_isolated_merge_keeps_base(self):
        source = self.prepare()
        self.assertTrue((source / 'editor.txt').exists())
        self.assertTrue((source / 'compatibility.txt').exists())
        self.assertEqual(self.run_git('rev-parse', 'HEAD'), self.base)
        self.assertEqual(self.run_git('status', '--porcelain'), '')
        self.assertNotEqual(self.p.manifest['head'], self.base)

    def test_dirty_and_untracked_are_preserved(self):
        for name in ('shared.txt', 'unpublished.log'):
            p = self.repo / name
            p.write_text('must survive')
        with self.assertRaisesRegex(app.Stop, 'DIRTY'):
            self.p.prepare()
        self.assertEqual((self.repo / 'unpublished.log').read_text(), 'must survive')
        self.assertEqual((self.repo / 'shared.txt').read_text(), 'must survive')

    def test_unapproved_pr_blocked(self):
        self.c['prs']['editor']['approved'] = False
        with self.assertRaisesRegex(app.Stop, 'APPROVED'):
            self.p.prepare()
        self.assertFalse(any(c[0] == 'fetch' for c in self.calls))

    def test_missing_pr_stops_before_fetch(self):
        with patch.object(app, 'api', side_effect=app.Stop('QUERY_FAILED_GH')):
            with self.assertRaises(app.Stop):
                self.p.prepare()
        self.assertFalse(any(c[0] == 'fetch' for c in self.calls))

    def test_pr_rejections(self):
        for change, message in [({'draft': True}, 'INCOMPLETE'), ({'mergeable': None}, 'INCOMPLETE'),
                                ({'mergeable': False}, 'INCOMPLETE'), ({'state': 'closed'}, 'INCOMPLETE')]:
            original = self.api('pulls/1')
            original.update(change)
            with patch.object(app, 'api', return_value=original), self.assertRaisesRegex(app.Stop, message):
                self.p.prepare()

    def test_wrong_head_base_foreign_repo(self):
        for field, key, value, reason in [('head', 'sha', 'f' * 40, 'HEAD_CHANGED'),
                                         ('base', 'ref', 'main', 'WRONG_PR_BASE'),
                                         ('head', 'repo', {'full_name': 'other/gallery'}, 'FOREIGN')]:
            pr = self.api('pulls/1')
            pr[field][key] = value
            with patch.object(app, 'api', return_value=pr), self.assertRaisesRegex(app.Stop, reason):
                self.p.prepare()

    def test_red_pending_empty_and_missing_checks(self):
        for checks in ([], [{'name': 'Other', 'status': 'completed', 'conclusion': 'success'}],
                       [{'name': 'Contract', 'status': 'in_progress', 'conclusion': None}],
                       [{'name': 'Contract', 'status': 'completed', 'conclusion': 'failure'}]):
            with self.assertRaises(app.Stop):
                app.checks_green(checks, ['Contract'])
        with self.assertRaises(app.Stop):
            app.checks_green([{'name': 'Contract', 'status': 'completed', 'conclusion': 'success'},
                              {'name': 'Unknown', 'status': 'completed', 'conclusion': 'cancelled'}], ['Contract'])

    def test_green_checks_accept_optional_skip_not_as_test(self):
        app.checks_green([{'name': 'Contract', 'status': 'completed', 'conclusion': 'success'},
                          {'name': 'Docs', 'status': 'completed', 'conclusion': 'skipped'}], ['Contract'])

    def test_required_check_duplicates_cannot_hide_a_skipped_attempt(self):
        success = {'name': 'Contract', 'status': 'completed', 'conclusion': 'success'}
        skipped = {**success, 'conclusion': 'skipped'}
        for checks in ([skipped, success], [success, skipped], [success, success]):
            with self.subTest(checks=checks), self.assertRaisesRegex(app.Stop, 'CI_REQUIRED_CHECK_AMBIGUOUS'):
                app.checks_green(checks, ['Contract'])

    def test_cli_startup_does_not_write_beside_versioned_install(self):
        installed = self.root / 'installed'
        installed.mkdir()
        for name in ('foto-build17-release', 'foto-stage-runner.py'):
            (installed / name).write_bytes(SCRIPT.with_name(name).read_bytes())
        env = {k: v for k, v in os.environ.items() if k not in ('PYTHONDONTWRITEBYTECODE', 'PYTHONPYCACHEPREFIX')}
        result = subprocess.run([sys.executable, str(installed / SCRIPT.name), '--help'], env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(result.returncode, 0)
        self.assertEqual({p.name for p in installed.iterdir()}, {'foto-build17-release', 'foto-stage-runner.py'})

    def test_editor_gate_does_not_require_unchanged_server_job(self):
        self.c['required_checks']['editor'] = ['Mobile']
        original = self.api
        def scoped(path):
            if self.heads['editor'] in path and 'check-runs' in path:
                return {'total_count': 1, 'check_runs': [{'name': 'Mobile', 'status': 'completed', 'conclusion': 'success'}]}
            return original(path)
        with patch.object(app, 'api', side_effect=scoped):
            self.p.prepare()
        self.assertTrue(self.p.manifest['prepared'])

    def test_changed_hp_sha_preserved(self):
        self.c['expected_head'] = 'f' * 40
        with self.assertRaisesRegex(app.Stop, 'SHA_CHANGED'):
            self.p.prepare()
        self.assertEqual(self.run_git('rev-parse', 'HEAD'), self.base)

    def test_remote_base_drift(self):
        original = self.git
        def change(repo, *args, **kwargs):
            return 'f' * 40 if args[0] == 'ls-remote' else original(repo, *args, **kwargs)
        with patch.object(app, 'git', side_effect=change), self.assertRaisesRegex(app.Stop, 'REMOTE_BASE'):
            self.p.prepare()

    def test_fetch_sha_revalidated(self):
        original = self.git
        def change(repo, *args, **kwargs):
            if args[0] == 'fetch':
                return REAL_GIT(repo, 'update-ref', args[-1].split(':', 1)[1], self.base)
            return original(repo, *args, **kwargs)
        with patch.object(app, 'git', side_effect=change), self.assertRaisesRegex(app.Stop, 'FETCHED_PR_SHA'):
            self.p.prepare()

    def test_prepare_repeated_does_not_merge_again(self):
        self.p.prepare()
        head, count = self.p.manifest['head'], len([x for x in self.calls if 'merge' in x])
        self.p.prepare()
        self.assertEqual(self.p.manifest['head'], head)
        self.assertEqual(len([x for x in self.calls if 'merge' in x]), count)

    def test_patch_equivalent_pr_not_merged_twice(self):
        self.run_git('cherry-pick', '-x', self.heads['editor'])
        self.c['expected_head'] = self.run_git('rev-parse', 'HEAD')
        self.p.prepare()
        events = [x['event'] for x in self.p.manifest['history']]
        self.assertIn('PATCH_EQUIVALENT_editor', events)
        self.assertNotIn('MERGED_editor', events)
        self.assertTrue((self.p.source() / 'compatibility.txt').exists())

    def overlapping_prs(self):
        """Real temporary Git; only the review pins differ from the production review."""
        self.run_git('switch', app.ROLES['editor'])
        (self.repo / 'shared-fix.txt').write_text('one shared fix\n')
        self.run_git('add', '.')
        self.run_git('commit', '-m', 'shared synthetic fix')
        shared = self.run_git('rev-parse', 'HEAD')
        self.heads['editor'] = shared
        self.run_git('switch', app.ROLES['compatibility'])
        self.run_git('cherry-pick', shared)
        (self.repo / 'compat-extra.txt').write_text('new compatibility work\n')
        self.run_git('add', '.')
        self.run_git('commit', '-m', 'additional compatibility work')
        self.heads['compatibility'] = self.run_git('rev-parse', 'HEAD')
        self.run_git('switch', app.BASE_BRANCH)
        for role, head in self.heads.items():
            self.c['prs'][role]['sha'] = head
        return {'base': self.base, **self.heads,
                'inputTree': self.run_git('rev-parse', shared + '^{tree}'),
                'outputTree': self.run_git('merge-tree', '--write-tree', shared, self.heads['compatibility']),
                'equivalentCount': 1, 'newCount': 2}

    def test_unknown_partial_application_still_stops_and_preserves_work(self):
        self.overlapping_prs()
        with self.assertRaisesRegex(app.Stop, 'PARTIALLY_APPLIED_PR_REVIEW_REQUIRED'):
            self.p.prepare()
        self.assertFalse(self.p.manifest['prepared'])
        self.assertNotIn('mergeInFlight', self.p.manifest)
        self.assertTrue((self.p.source() / 'editor.txt').is_file())
        self.assertFalse((self.p.source() / 'compatibility.txt').exists())
        self.assertEqual(self.run_git('rev-parse', 'HEAD'), self.base)

    def test_reviewed_overlap_merges_full_history_and_exact_tree_once(self):
        review = self.overlapping_prs()
        with patch.object(app, 'REVIEWED_OVERLAP', review):
            self.p.prepare()
            head = self.p.manifest['head']
            self.p.prepare()
        source = self.p.source()
        self.assertEqual(REAL_GIT(source, 'rev-parse', 'HEAD^{tree}'), review['outputTree'])
        for role, sha in self.heads.items():
            self.assertIsNotNone(REAL_GIT(source, 'merge-base', '--is-ancestor', sha, 'HEAD', optional=True))
            self.assertEqual(sum(x['event'] == 'MERGED_' + role for x in self.p.manifest['history']), 1)
        self.assertEqual(self.p.manifest['head'], head)
        self.assertEqual((source / 'shared-fix.txt').read_text(), 'one shared fix\n')
        self.assertTrue((source / 'compat-extra.txt').is_file())
        self.assertEqual(len(self.p.manifest['overlapReview']['equivalentCommits']), 1)
        self.assertEqual(self.run_git('rev-parse', 'HEAD'), self.base)

    def test_old_partial_stop_resumes_same_state_without_erasing_history(self):
        review = self.overlapping_prs()
        with self.assertRaisesRegex(app.Stop, 'PARTIALLY_APPLIED'):
            self.p.prepare()
        before = {p.name: p.read_bytes() for p in self.p.state.glob('manifest-*.json')}
        source, old_head = self.p.source(), self.p.manifest['head']
        resumed = app.Pipeline(self.c)
        with patch.object(app, 'REVIEWED_OVERLAP', review), resumed.locked():
            resumed.prepare()
        self.assertEqual(resumed.source(), source)
        self.assertEqual(resumed.manifest['overlapReview']['previousHead'], old_head)
        self.assertTrue(resumed.manifest['prepared'])
        for name, data in before.items():
            self.assertEqual((self.p.state / name).read_bytes(), data)
        self.assertEqual(sum(x['event'] == 'MERGED_editor' for x in resumed.manifest['history']), 1)

    def test_extra_or_reverted_commit_does_not_match_reviewed_frontier(self):
        review = self.overlapping_prs()
        with self.assertRaisesRegex(app.Stop, 'PARTIALLY_APPLIED'):
            self.p.prepare()
        source = self.p.source()
        (source / 'shared-fix.txt').write_text('local reviewed change must survive\n')
        REAL_GIT(source, 'add', 'shared-fix.txt')
        REAL_GIT(source, '-c', 'user.name=Test', '-c', 'user.email=test@localhost',
                 'commit', '-m', 'extra synthetic local commit')
        self.p.manifest['head'] = REAL_GIT(source, 'rev-parse', 'HEAD')
        with patch.object(app, 'REVIEWED_OVERLAP', review), self.assertRaisesRegex(app.Stop, 'PARTIALLY_APPLIED'):
            self.p.prepare()
        self.assertEqual((source / 'shared-fix.txt').read_text(), 'local reviewed change must survive\n')
        self.assertNotIn('mergeInFlight', self.p.manifest)

    def test_reviewed_tree_mismatch_stops_before_mutating_worktree(self):
        review = self.overlapping_prs()
        review['outputTree'] = 'f' * 40
        with patch.object(app, 'REVIEWED_OVERLAP', review), self.assertRaisesRegex(app.Stop, 'OVERLAP_TREE_DIFFERS'):
            self.p.prepare()
        self.assertFalse((self.p.source() / 'compat-extra.txt').exists())
        self.assertEqual(REAL_GIT(self.p.source(), 'status', '--porcelain'), '')
        self.assertNotIn('mergeInFlight', self.p.manifest)

    def test_reviewed_preview_conflict_does_not_start_merge(self):
        review = self.overlapping_prs()
        original = self.git
        def conflict(repo, *args, **kwargs):
            return None if args[0] == 'merge-tree' else original(repo, *args, **kwargs)
        with patch.object(app, 'REVIEWED_OVERLAP', review), patch.object(app, 'git', side_effect=conflict):
            with self.assertRaisesRegex(app.Stop, 'OVERLAP_TREE_DIFFERS'):
                self.p.prepare()
        self.assertNotIn('mergeInFlight', self.p.manifest)
        self.assertFalse((self.p.source() / 'compatibility.txt').exists())

    def test_reviewed_actual_result_mismatch_keeps_inflight_evidence(self):
        review = self.overlapping_prs()
        original = self.git
        def mismatch(repo, *args, **kwargs):
            if args == ('rev-parse', 'HEAD^{tree}') and REAL_GIT(
                    repo, 'merge-base', '--is-ancestor', self.heads['compatibility'], 'HEAD', optional=True) is not None:
                return 'f' * 40
            return original(repo, *args, **kwargs)
        with patch.object(app, 'REVIEWED_OVERLAP', review), patch.object(app, 'git', side_effect=mismatch):
            with self.assertRaisesRegex(app.Stop, 'MERGE_RESULT_DIFFERS'):
                self.p.prepare()
        self.assertEqual(self.p.manifest['mergeInFlight'], self.heads['compatibility'])
        self.assertFalse(self.p.manifest['prepared'])
        self.assertIn('rejectedMerge', self.p.manifest)
        with self.assertRaisesRegex(app.Stop, 'MERGE_INTERRUPTED'):
            self.p.prepare()

    def test_crash_after_overlap_review_recomputes_proof_on_resume(self):
        review = self.overlapping_prs()
        original = self.p.save
        def crash(event):
            original(event)
            if event == 'REVIEWED_OVERLAP_compatibility':
                raise RuntimeError('synthetic process crash before merge intent')
        with patch.object(app, 'REVIEWED_OVERLAP', review), patch.object(self.p, 'save', side_effect=crash):
            with self.assertRaisesRegex(RuntimeError, 'synthetic process crash'):
                self.p.prepare()
        resumed = app.Pipeline(self.c)
        with patch.object(app, 'REVIEWED_OVERLAP', review), resumed.locked():
            resumed.prepare()
        self.assertTrue(resumed.manifest['prepared'])
        self.assertEqual(REAL_GIT(resumed.source(), 'rev-parse', 'HEAD^{tree}'), review['outputTree'])

    def test_merged_pr_requires_verified_local_ancestry(self):
        self.run_git('merge', '--no-ff', '--no-edit', self.heads['editor'])
        self.c['expected_head'] = self.run_git('rev-parse', 'HEAD')
        original = self.api
        def merged(path):
            value = original(path)
            if path == 'pulls/1':
                value.update(state='closed', merged=True, mergeable=None)
                value['base']['sha'] = self.base
            return value
        with patch.object(app, 'api', side_effect=merged):
            self.p.prepare()
        self.assertNotIn('MERGED_editor', [x['event'] for x in self.p.manifest['history']])

    def test_conflict_preserved_no_auto_resolution(self):
        for role in app.ROLES:
            self.run_git('switch', app.ROLES[role])
            (self.repo / 'shared.txt').write_text(role)
            self.run_git('add', '.')
            self.run_git('commit', '-m', 'conflicting synthetic ' + role)
            self.c['prs'][role]['sha'] = self.run_git('rev-parse', 'HEAD')
        self.run_git('switch', app.BASE_BRANCH)
        with self.assertRaises(app.Stop):
            self.p.prepare()
        self.assertIn('UU shared.txt', REAL_GIT(self.p.source(), 'status', '--porcelain'))
        self.assertTrue(self.p.manifest['mergeInFlight'])
        with self.assertRaisesRegex(app.Stop, 'MERGE_INTERRUPTED'):
            self.p.prepare()
        self.assertEqual(self.run_git('rev-parse', 'HEAD'), self.base)

    def test_parallel_release_and_common_lock(self):
        self.p.fds = []
        with self.p.locked():
            second = app.Pipeline(self.c)
            with self.assertRaisesRegex(app.Stop, 'BUSY'), second.locked():
                self.fail('parallel release entered')
            with self.assertRaisesRegex(app.Stop, 'BUSY'):
                app.runner.lock(Path(self.c['automation_state']) / 'heavy-stage.lock')

    def test_existing_codex_process_blocks(self):
        with patch.object(app, 'processes', return_value=[{'pid': 1, 'executable': 'codex'}]):
            with self.assertRaisesRegex(app.Stop, 'EXISTING_CODEX'), self.p.locked():
                self.fail('entered')

    def test_corrupt_checkpoint_not_repaired(self):
        self.p.path.write_text('{')
        self.p.path.chmod(0o600)
        with self.assertRaises(ValueError), self.p.locked():
            self.fail('entered')
        self.assertEqual(self.p.path.read_text(), '{')

    def test_history_preserved_and_config_change_rejected(self):
        self.p.prepare()
        snapshots = {p.name: p.read_bytes() for p in self.p.state.glob('manifest-*.json')}
        self.p.save('ANOTHER_EVENT')
        for name, data in snapshots.items():
            self.assertEqual((self.p.state / name).read_bytes(), data)
        changed = copy.deepcopy(self.c)
        changed['min_free_gib'] += 1
        with self.assertRaisesRegex(app.Stop, 'CONFIG_CHANGED'), app.Pipeline(changed).locked():
            self.fail('entered')

    def pin_format_fixture(self, old_pin=None):
        normalized = '0123456789abcdef' * 4
        self.c['signing']['certificate_sha256'] = old_pin if old_pin is not None else ':'.join(
            normalized[i:i + 2] for i in range(0, 64, 2)).upper()
        self.prepare()
        self.p.manifest.pop('toolchain')
        # Construct the exact synthetic legacy identity, including malformed
        # original pins in the negative cases; do not fail those on a stale hash.
        self.p.manifest['configSHA256'] = self.p.config_sha()
        self.p.save('PREPARED')
        backup = self.root / 'config.json.before-pin-normalization'
        backup.write_text(json.dumps(self.c))
        backup.chmod(0o600)
        self.c['signing']['certificate_sha256'] = normalized
        cfg = self.root / 'config.json'
        cfg.write_text(json.dumps(self.c))
        cfg.chmod(0o600)
        return backup, cfg

    def test_pin_format_proof_keeps_original_identity_files_and_prepared_merge(self):
        backup, cfg = self.pin_format_fixture()
        files = {p: p.read_bytes() for p in (backup, cfg, self.p.path, *self.p.state.glob('manifest-*.json'))}
        head = self.p.manifest['head']
        anchor = self.p.manifest['configSHA256']
        self.calls.clear()
        resumed = app.Pipeline(self.c, pin_format_proof=backup)
        with resumed.locked():
            self.assertEqual(resumed.config_sha(), anchor)
            resumed.prepare()
        self.assertEqual(resumed.manifest['head'], head)
        self.assertFalse(any(c[0] in ('fetch', 'merge') for c in self.calls))
        for p, data in files.items():
            self.assertEqual(p.read_bytes(), data)

    def test_pin_format_proof_accepts_lowercase_colon_original(self):
        normalized = '0123456789abcdef' * 4
        backup, cfg = self.pin_format_fixture(':'.join(normalized[i:i + 2] for i in range(0, 64, 2)))
        resumed = app.Pipeline(self.c, pin_format_proof=backup)
        with resumed.locked():
            self.assertEqual(resumed.config_sha(), self.p.manifest['configSHA256'])

    def test_pin_format_change_without_explicit_proof_still_fails(self):
        self.pin_format_fixture()
        with self.assertRaisesRegex(app.Stop, 'CONFIG_CHANGED'), app.Pipeline(self.c).locked():
            self.fail('entered')

    def test_pin_format_proof_cannot_admit_any_other_config_change(self):
        backup, cfg = self.pin_format_fixture()
        cases = []
        for name in ('repo', 'state', 'automation_state', 'legacy_lock', 'export_dir'):
            c = copy.deepcopy(self.c)
            c[name] += '-changed'
            cases.append((name, c))
        for name in ('expected_head', 'min_free_gib'):
            c = copy.deepcopy(self.c)
            c[name] = 'f' * 40 if name == 'expected_head' else c[name] + 1
            cases.append((name, c))
        for name in ('keystore', 'properties'):
            c = copy.deepcopy(self.c)
            c['signing'][name] += '-changed'
            cases.append((name, c))
        for role in app.ROLES:
            for name, value in (('sha', 'f' * 40), ('number', 999), ('approved', 1), ('approval_note', 'changed')):
                c = copy.deepcopy(self.c)
                c['prs'][role][name] = value
                cases.append((role + '-' + name, c))
            c = copy.deepcopy(self.c)
            c['required_checks'][role].append('Another gate')
            cases.append((role + '-checks', c))
        before = self.p.path.read_bytes()
        for name, c in cases:
            with self.subTest(field=name), self.assertRaises(app.Stop), app.Pipeline(c, pin_format_proof=backup).locked():
                self.fail('entered')
        self.assertEqual(self.p.path.read_bytes(), before)

    def test_pin_format_proof_rejects_changed_certificate_and_noncanonical_target(self):
        backup, cfg = self.pin_format_fixture()
        for pin in ('ff' + self.c['signing']['certificate_sha256'][2:],
                    self.c['signing']['certificate_sha256'].upper(), 'bad', None):
            c = copy.deepcopy(self.c)
            c['signing']['certificate_sha256'] = pin
            with self.subTest(pin=pin), self.assertRaisesRegex(app.Stop, 'CONFIG_CHANGED'), \
                    app.Pipeline(c, pin_format_proof=backup).locked():
                self.fail('entered')

    def test_pin_format_proof_requires_the_original_checkpoint_hash(self):
        backup, cfg = self.pin_format_fixture()
        original = json.loads(backup.read_text())
        original['min_free_gib'] += 1
        backup.write_text(json.dumps(original))
        with self.assertRaisesRegex(app.Stop, 'CONFIG_CHANGED'), app.Pipeline(self.c, pin_format_proof=backup).locked():
            self.fail('entered')

    def test_pin_format_proof_rejects_unreviewed_original_fingerprint_formats(self):
        for pin in ('01:23', 'SHA256:' + ':'.join(['ab'] * 32), 'ab' * 32, ':'.join(['zz'] * 32)):
            with self.subTest(pin=pin):
                backup, cfg = self.pin_format_fixture(pin)
                with self.assertRaisesRegex(app.Stop, 'CONFIG_CHANGED'), app.Pipeline(self.c, pin_format_proof=backup).locked():
                    self.fail('entered')

    def test_pin_format_proof_rejects_missing_public_symlink_or_relative_backup(self):
        backup, cfg = self.pin_format_fixture()
        with self.assertRaises(OSError), app.Pipeline(self.c, pin_format_proof=backup.with_name('missing')).locked():
            self.fail('entered')
        backup.chmod(0o644)
        with self.assertRaisesRegex(app.Stop, 'PRIVATE'), app.Pipeline(self.c, pin_format_proof=backup).locked():
            self.fail('entered')
        backup.chmod(0o600)
        real_lstat = Path.lstat
        def foreign_owner(path, *args, **kwargs):
            s = real_lstat(path, *args, **kwargs)
            if path == backup:
                fields = list(s)
                fields[app.stat.ST_UID] = s.st_uid + 1
                return os.stat_result(fields)
            return s
        with patch.object(Path, 'lstat', foreign_owner), self.assertRaisesRegex(app.Stop, 'PRIVATE'), \
                app.Pipeline(self.c, pin_format_proof=backup).locked():
            self.fail('entered')
        link = self.root / 'proof-link'
        link.symlink_to(backup)
        with self.assertRaisesRegex(app.Stop, 'PRIVATE'), app.Pipeline(self.c, pin_format_proof=link).locked():
            self.fail('entered')
        with self.assertRaisesRegex(app.Stop, 'ABSOLUTE'), app.Pipeline(self.c, pin_format_proof=Path('relative')).locked():
            self.fail('entered')

    def test_pin_format_proof_requires_existing_prepared_checkpoint(self):
        with self.assertRaisesRegex(app.Stop, 'PREPARED_CHECKPOINT'), \
                app.Pipeline(self.c, pin_format_proof=self.root / 'missing').locked():
            self.fail('entered')
        backup, cfg = self.pin_format_fixture()
        for key, value in (('prepared', False), ('mergeInFlight', 'f' * 40)):
            self.p.manifest[key] = value
            self.p.save('SYNTHETIC_INVALID_STATE')
            with self.assertRaisesRegex(app.Stop, 'PREPARED_CHECKPOINT'), app.Pipeline(self.c, pin_format_proof=backup).locked():
                self.fail('entered')
            self.p.manifest[key] = True if key == 'prepared' else None

    def test_pin_format_proof_is_revalidated_before_stage_identity(self):
        backup, cfg = self.pin_format_fixture()
        resumed = app.Pipeline(self.c, pin_format_proof=backup)
        with resumed.locked():
            original = json.loads(backup.read_text())
            original['min_free_gib'] += 1
            backup.write_text(json.dumps(original))
            with self.assertRaisesRegex(app.Stop, 'CONFIG_CHANGED'):
                resumed.config_sha()

    def test_pin_format_proof_allows_later_valid_stage_resume_without_rewriting_receipts(self):
        backup, cfg = self.pin_format_fixture()
        initial = {p: p.read_bytes() for p in (backup, cfg, *self.p.state.glob('manifest-*.json'))}
        anchor = self.p.manifest['configSHA256']
        resumed = app.Pipeline(self.c, pin_format_proof=backup)
        with resumed.locked(), patch.object(resumed, 'environment', return_value={}), self.fake_stage() as execute:
            resumed.manifest['toolchain'] = 'synthetic-tool-fingerprint'
            resumed.manifest['mode'] = 'test'
            resumed.save('TEST_REQUESTED')
            resumed.stage('unit-0', resumed.source(), ['/synthetic/check'], ['.ignored/output'])
            self.assertEqual(execute.call_count, 1)
        receipt = copy.deepcopy(resumed.manifest['stages']['unit-0'])
        again = app.Pipeline(self.c, pin_format_proof=backup)
        with again.locked(), patch.object(again, 'environment', return_value={}), self.fake_stage() as execute:
            again.stage('unit-0', again.source(), ['/synthetic/check'], ['.ignored/output'])
            execute.assert_not_called()
            self.assertEqual(again.manifest['stages']['unit-0'], receipt)
            self.assertEqual(again.manifest['configSHA256'], anchor)
        for p, data in initial.items():
            self.assertEqual(p.read_bytes(), data)

    def test_pin_format_proof_check_is_read_only_and_requires_both_validations(self):
        backup, cfg = self.pin_format_fixture()
        before = {p: p.read_bytes() for p in (backup, cfg, self.p.path, *self.p.state.glob('manifest-*.json'))}
        self.calls.clear()
        with fake_buildx035(history_raw=BUILDX035_HISTORY), \
                patch.object(app.pwd, 'getpwuid', return_value=Mock(pw_name='codex-gallery')), \
                patch('sys.stdout', new=io.StringIO()) as stdout, \
                patch.object(sys, 'argv', [str(SCRIPT), '--config', str(cfg),
                    '--certificate-pin-format-proof', str(backup), '--check']):
            app.main()
        result = json.loads(stdout.getvalue())
        self.assertEqual(result['checkpointConfigValidation'], 'PASS_CERTIFICATE_PIN_FORMAT_EQUIVALENT')
        self.assertEqual(result['docker']['builderValidation'], 'PASS_READ_ONLY_LIMITS_AND_IDLE')
        self.assertFalse(any(c[0] in ('merge', 'fetch') for c in self.calls))
        for p, data in before.items():
            self.assertEqual(p.read_bytes(), data)

    def test_pin_format_proof_failed_check_preserves_files_and_does_not_probe_docker(self):
        backup, cfg = self.pin_format_fixture()
        original = json.loads(backup.read_text())
        original['min_free_gib'] += 1
        backup.write_text(json.dumps(original))
        before = {p: p.read_bytes() for p in (backup, cfg, self.p.path, *self.p.state.glob('manifest-*.json'))}
        with patch.object(app.pwd, 'getpwuid', return_value=Mock(pw_name='codex-gallery')), \
                patch.object(app, 'inventory') as inventory, \
                patch.object(sys, 'argv', [str(SCRIPT), '--config', str(cfg),
                    '--certificate-pin-format-proof', str(backup), '--check']), \
                self.assertRaisesRegex(app.Stop, 'CONFIG_CHANGED'):
            app.main()
        inventory.assert_not_called()
        for p, data in before.items():
            self.assertEqual(p.read_bytes(), data)

    def test_pin_format_proof_does_not_authorize_another_apk_certificate(self):
        backup, cfg = self.pin_format_fixture()
        (self.root / 'sdk/build-tools/36.0.0').mkdir(parents=True)
        apk = self.root / 'synthetic.apk'
        with zipfile.ZipFile(apk, 'w') as z:
            z.writestr('AndroidManifest.xml', b'synthetic')
        resumed = app.Pipeline(self.c, pin_format_proof=backup)
        with resumed.locked(), patch.dict(os.environ, ANDROID_HOME=str(self.root / 'sdk')), \
                patch.object(app, 'query', return_value='Signer #1 certificate SHA-256 digest: ' + 'b' * 64), \
                self.assertRaisesRegex(app.Stop, 'CERTIFICATE_MISMATCH'):
            resumed.apk_metadata(apk)

    def test_stage_reuse_requires_log_and_output_hashes(self):
        source = self.prepare()
        with self.fake_stage() as execute:
            self.stage()
            self.stage()
            self.assertEqual(execute.call_count, 1)
        (source / '.ignored/output').write_text('tampered')
        with self.assertRaisesRegex(app.Stop, 'OUTPUT_CHANGED'):
            self.stage()

    def test_changed_request_not_reused(self):
        self.prepare()
        with self.fake_stage():
            self.stage()
        self.c['min_free_gib'] += 1
        with self.assertRaisesRegex(app.Stop, 'INPUT_CHANGED'):
            self.stage()

    def test_false_pass_flag_rejected(self):
        self.prepare()
        with self.fake_stage():
            self.stage()
        self.p.manifest['stages']['unit-0']['exitCode'] = 137
        with self.assertRaisesRegex(app.Stop, 'CORRUPT_STAGE'):
            self.stage()

    def test_low_memory_stops_without_execution(self):
        self.prepare()
        with patch.object(app, 'resources', return_value={'memoryBytes': {'MemAvailable': 1024}, 'currentCgroup': {}}):
            with self.fake_stage() as child, self.assertRaisesRegex(app.Stop, 'AVAILABLE_MEMORY'):
                self.stage()
            child.assert_not_called()

    def test_memory_backend_stop_keeps_all_receipts_and_has_no_build_intent(self):
        self.prepare()
        before = self.p.path.read_bytes()
        with patch.object(app, 'resources', return_value={
                'memoryBytes': {'MemAvailable': 10 * 1024**3 - 1}, 'currentCgroup': {}}), \
                self.fake_stage() as child, self.assertRaisesRegex(app.Stop, 'AVAILABLE_MEMORY'):
            self.p.stage('backend-image', self.p.source(), ['docker', 'synthetic-build'])
        child.assert_not_called()
        self.assertNotIn('backend-image', self.p.manifest['stages'])
        self.assertEqual(self.p.path.read_bytes(), before)

    def test_psi_pressure_after_preflight_stops_backend_before_child_or_intent(self):
        self.prepare()
        pressure = [HP_LOW_PSI]
        before = self.p.path.read_bytes()
        with patch.object(app, 'backend_memory_reserve', side_effect=lambda: app.check_memory_pressure(pressure[0])):
            app.check_stage_memory('backend-image', app.resources())
            pressure[0] = IDLE_PSI.replace('full avg10=0.00', 'full avg10=0.11')
            with self.fake_stage() as child, self.assertRaisesRegex(app.Stop, 'MEMORY_PRESSURE'):
                self.p.stage('backend-image', self.p.source(), ['docker', 'synthetic-build'])
            child.assert_not_called()
        self.assertNotIn('backend-image', self.p.manifest['stages'])
        self.assertEqual(self.p.path.read_bytes(), before)

    def reviewed_test_receipts(self):
        source = self.prepare()
        # Only construct the actual recipe definitions, not run their tools.
        with patch.object(app, 'need'):
            recipes = app.recipes_for(source)
        self.assertEqual(len(recipes), 50)
        ignored = REAL_GIT(source, 'rev-parse', '--git-path', 'info/exclude')
        with Path(ignored).open('a') as f:
            for _, _, _, outputs in recipes:
                f.writelines('/' + name + '\n' for name in outputs)
        for name, folder, argv, outputs in recipes:
            (source / folder).mkdir(parents=True, exist_ok=True)
            def child(command, cwd, log, *args, **kwargs):
                log.write(b'synthetic passing stage, no real tool execution\n')
                for path in outputs:
                    p = source / path
                    p.parent.mkdir(parents=True, exist_ok=True)
                    p.write_text('synthetic output for ' + path)
                return 0
            with patch.object(self.p, 'environment', return_value={}), patch.object(app.runner, 'supervise', side_effect=child):
                self.p.stage(name, source / folder, argv, outputs)
            self.p.manifest['stages'][name]['inputs']['pipeline'] = app.REVIEWED_TEST_RUNTIME
        helper = self.root / 'old-tools/foto-mobile-codegen.sh'
        helper.parent.mkdir()
        helper.write_bytes(SCRIPT.with_name(helper.name).read_bytes())
        self.p.manifest['stages']['flutter-codegen']['inputs']['argv'][1] = str(helper)
        self.p.manifest['testsComplete'] = [x[0] for x in recipes]
        self.p.manifest['mode'] = 'build'
        self.p.save('SYNTHETIC_ALL_TESTS_PASSED_BUILD_ADMISSION_STOP')
        review = {'base': self.base, **self.heads, 'outputTree': REAL_GIT(source, 'rev-parse', 'HEAD^{tree}')}
        return recipes, review, helper

    def test_reviewed_memory_update_reuses_all_test_receipts_without_execution_or_rewriting(self):
        recipes, review, helper = self.reviewed_test_receipts()
        snapshots = {p: p.read_bytes() for p in (self.p.path, *self.p.state.glob('manifest-*.json'))}
        receipts = copy.deepcopy(self.p.manifest['stages'])
        with patch.object(app, 'recipes_for', return_value=recipes), patch.object(app, 'REVIEWED_OVERLAP', review), \
                self.fake_stage() as child, patch('sys.stdout', new=io.StringIO()) as stdout:
            for name, folder, argv, outputs in recipes:
                self.p.stage(name, self.p.source() / folder, argv, outputs)
        child.assert_not_called()
        self.assertEqual(stdout.getvalue().count('PASS_REUSED '), len(recipes))
        self.assertEqual(self.p.manifest['stages'], receipts)
        for path, raw in snapshots.items():
            self.assertEqual(path.read_bytes(), raw)

    def test_reviewed_memory_update_still_rejects_recipe_runtime_log_output_and_dependency_tamper(self):
        recipes, review, helper = self.reviewed_test_receipts()
        source = self.p.source()
        recipe = next(x for x in recipes if x[0] == 'unit-0')
        with patch.object(app, 'recipes_for', return_value=recipes), patch.object(app, 'REVIEWED_OVERLAP', review):
            compiled = self.p.manifest['stages']['compile']
            outputs = compiled['outputs']
            compiled['outputs'] = {}
            with self.assertRaisesRegex(app.Stop, 'CORRUPT_STAGE_RECEIPT'):
                self.p.stage('compile', source / 'server', ['pnpm', 'run', 'build'])
            compiled['outputs'] = outputs
            for field, value in (('argv', ['fake-test']), ('cwd', str(source / 'other')),
                                 ('config', 'f' * 64), ('toolchain', 'changed'), ('head', 'f' * 40),
                                 ('runner', 'f' * 64), ('pipeline', 'f' * 64)):
                previous = self.p.manifest['stages']['unit-0']['inputs']
                before = copy.deepcopy(previous)
                previous[field] = value
                with self.subTest(field=field), self.assertRaisesRegex(app.Stop, 'INPUT_CHANGED'):
                    self.p.stage('unit-0', source / 'server', recipe[2])
                previous.clear(); previous.update(before)
            for path, code in ((self.p.state / self.p.manifest['stages']['unit-0']['log'], 'LOG_CHANGED'),
                               (source / 'server/node_modules/vitest/package.json', 'INPUT_CHANGED'),
                               (source / 'server/dist/main.js', 'OUTPUT_CHANGED'),
                               (helper, 'INPUT_CHANGED')):
                raw = path.read_bytes()
                path.write_bytes(b'tampered')
                target = 'compile' if code == 'OUTPUT_CHANGED' else 'flutter-codegen' if path == helper else recipe[0]
                item = next(x for x in recipes if x[0] == target)
                with self.subTest(path=path), self.assertRaisesRegex(app.Stop, code):
                    self.p.stage(item[0], source / item[1], item[2], item[3])
                path.write_bytes(raw)

    def test_reviewed_memory_update_never_accepts_old_build_failed_or_unreviewed_application(self):
        recipes, review, helper = self.reviewed_test_receipts()
        source = self.p.source()
        with patch.object(app, 'recipes_for', return_value=recipes), patch.object(app, 'REVIEWED_OVERLAP', review):
            self.p.manifest['stages']['backend-image'] = copy.deepcopy(self.p.manifest['stages']['unit-0'])
            with self.assertRaisesRegex(app.Stop, 'PREDECESSOR_TEST_PASS_REQUIRED'):
                self.p.stage('backend-image', source, ['docker', 'synthetic-build'])
            self.p.manifest['stages']['unit-0']['status'] = 'FAIL'
            with self.assertRaisesRegex(app.Stop, 'PREDECESSOR_TEST_PASS_REQUIRED'):
                self.p.stage('unit-0', source / 'server', ['synthetic'])
            self.p.manifest['stages']['unit-0']['status'] = 'PASS'
            review['outputTree'] = 'f' * 40
            with self.assertRaisesRegex(app.Stop, 'PREDECESSOR_APPLICATION_DIFFERS'):
                self.p.stage('unit-0', source / 'server', ['synthetic'])

    def test_reviewed_memory_update_missing_or_failed_test_receipt_never_reexecutes_tests(self):
        recipes, review, helper = self.reviewed_test_receipts()
        for value in (None, {'status': 'FAIL'}):
            if value is None:
                self.p.manifest['stages'].pop('plugin-sdk')
            else:
                self.p.manifest['stages']['plugin-sdk'] = value
            with self.subTest(receipt=value), patch.object(app, 'recipes_for', return_value=recipes), \
                    patch.object(self.p, 'stage') as stage, patch.object(app, 'builder_idle') as builder, \
                    self.assertRaisesRegex(app.Stop, 'MANDATORY_CHECKS_INCOMPLETE'):
                self.p.build()
            stage.assert_not_called()
            builder.assert_not_called()

    def test_reviewed_memory_update_pin_proof_restart_and_verify_old_tests_new_builds(self):
        backup, cfg = self.pin_format_fixture()
        self.p = app.Pipeline(self.c, pin_format_proof=backup)
        self.p.read_checkpoint()
        os.close(self.fd)
        self.fd = None
        recipes, review, helper = self.reviewed_test_receipts()
        original_files = {p: p.read_bytes() for p in (backup, cfg, *self.p.state.glob('manifest-*.json'))}
        source = self.p.source()
        apk = 'mobile/build/app/outputs/flutter-apk/app-release.apk'
        with Path(REAL_GIT(source, 'rev-parse', '--git-path', 'info/exclude')).open('a') as f:
            f.write('/' + apk + '\n')
        (source / apk).parent.mkdir(parents=True)
        with zipfile.ZipFile(source / apk, 'w') as z:
            z.writestr('AndroidManifest.xml', b'synthetic')
        with self.fake_stage(), patch.object(self.p, 'environment', return_value={}):
            self.p.stage('backend-image', source, ['docker', 'synthetic-build'])
            self.p.stage('android-apk', source / 'mobile', ['synthetic-apk-build'], [apk])
        for name in ('backend-image', 'android-apk'):
            self.assertEqual(self.p.manifest['stages'][name]['inputs']['pipeline'], app.sha(SCRIPT))
        self.p.manifest.update(image={'tag': 'synthetic', 'id': 'sha256:' + 'a' * 64},
                               apk={'sha256': app.sha(source / apk), 'bytes': (source / apk).stat().st_size})
        self.p.save('SYNTHETIC_BUILD_COMPLETE')
        stages = copy.deepcopy(self.p.manifest['stages'])
        resumed = app.Pipeline(self.c, pin_format_proof=backup)
        resumed.read_checkpoint()
        with patch.object(app, 'recipes_for', return_value=recipes), patch.object(app, 'REVIEWED_OVERLAP', review), \
                patch.object(app, 'rootless', return_value='synthetic'), \
                patch.object(resumed, 'tools', return_value=resumed.manifest['toolchain']), \
                patch.object(resumed, 'image', return_value=resumed.manifest['image']), \
                patch.object(resumed, 'apk_metadata', return_value=resumed.manifest['apk']), \
                patch('sys.stdout', new=io.StringIO()):
            resumed.verify()
        self.assertEqual(resumed.manifest['stages'], stages)
        self.assertEqual(resumed.manifest['configSHA256'], self.p.manifest['configSHA256'])
        self.assertTrue(Path(resumed.manifest['exportReceipt']).is_file())
        for p, data in original_files.items():
            self.assertEqual(p.read_bytes(), data)

    def test_reviewed_memory_update_definitions_match_the_exact_published_predecessor(self):
        old = subprocess.check_output(['git', 'show', 'c035601cf131ac4e3dfcf304581314e66d2180c0:tools/foto-automation/foto-build17-release'], cwd=SCRIPT.parents[2])
        self.assertEqual(app.runner.digest(old), app.REVIEWED_TEST_RUNTIME)
        def definitions(raw):
            tree = ast.parse(raw)
            result = {node.name: ast.dump(node) for node in tree.body if isinstance(node, ast.FunctionDef)}
            result.update({node.name: ast.dump(node) for cls in tree.body if isinstance(cls, ast.ClassDef)
                           and cls.name == 'Pipeline' for node in cls.body if isinstance(node, ast.FunctionDef)})
            return result
        before, after = definitions(old), definitions(SCRIPT.read_bytes())
        for name in ('recipes_for', 'config', 'config_sha', 'signing', 'apk_metadata', 'finalize',
                     'gate', 'clean', 'save', 'environment', 'rootless', 'builder_idle', 'main'):
            self.assertEqual(before[name], after[name], name)
        def method(raw, name):
            return next(node for cls in ast.parse(raw).body if isinstance(cls, ast.ClassDef) and cls.name == 'Pipeline'
                        for node in cls.body if isinstance(node, ast.FunctionDef) and node.name == name)
        old_build, new_build = method(old, 'build').body, method(SCRIPT.read_bytes(), 'build').body
        self.assertEqual([ast.dump(x) for x in old_build[:2] + old_build[3:]],
                         [ast.dump(x) for x in new_build[:2] + new_build[4:]])
        def execution_tail(raw):
            body = method(raw, 'stage').body
            index = next(i for i, node in enumerate(body) if isinstance(node, ast.Assign)
                         and any(isinstance(t, ast.Name) and t.id == 'logname' for t in node.targets))
            return [ast.dump(x) for x in body[index:]]
        self.assertEqual(execution_tail(old), execution_tail(SCRIPT.read_bytes()))

    def test_log_tamper_blocks(self):
        self.prepare()
        with self.fake_stage():
            self.stage()
        (self.p.state / self.p.manifest['stages']['unit-0']['log']).write_text('tampered')
        with self.assertRaisesRegex(app.Stop, 'LOG_CHANGED'):
            self.stage()

    def test_heap_failure_no_automatic_retry(self):
        self.prepare()
        with self.fake_stage(137) as execute:
            with self.assertRaisesRegex(app.Stop, 'EXIT_137'):
                self.stage()
            with self.assertRaisesRegex(app.Stop, 'EXPLICIT_RETRY'):
                self.stage()
            self.assertEqual(execute.call_count, 1)
        self.p.retry, self.p.diagnosis = True, 'synthetic OOM diagnosis; no real HP OOM simulated'
        with self.fake_stage():
            self.stage()
        self.assertEqual(self.p.manifest['stages']['unit-0']['status'], 'PASS')

    def test_interrupted_stage_requires_explicit_retry(self):
        self.prepare()
        with patch.object(app.runner, 'supervise', side_effect=app.Stop('simulated interruption')):
            with self.assertRaises(app.Stop):
                self.stage()
        self.assertEqual(self.p.manifest['stages']['unit-0']['status'], 'RUNNING')
        with self.assertRaisesRegex(app.Stop, 'EXPLICIT_RETRY'):
            self.stage()

    def test_real_child_signal_is_recorded_not_success(self):
        self.prepare()
        with patch.object(self.p, 'environment', return_value=dict(os.environ)):
            with self.assertRaisesRegex(app.Stop, 'EXIT_143'):
                self.p.stage('signal-child', self.p.source(), [sys.executable, '-c',
                    'import os,signal,time; os.kill(os.getppid(),signal.SIGTERM); time.sleep(10)'])
        self.assertEqual(self.p.manifest['stages']['signal-child']['status'], 'FAIL')

    def test_changed_source_sha_not_reused(self):
        source = self.prepare()
        (source / 'editor.txt').write_text('changed')
        with self.assertRaisesRegex(app.Stop, 'DIRTY'):
            self.stage()

    def test_prepared_flag_does_not_authorize_another_worktree(self):
        self.prepare()
        self.p.manifest['worktree'] = str(self.repo)
        self.p.manifest['head'] = self.base
        self.p.manifest['branch'] = app.BASE_BRANCH
        with self.assertRaisesRegex(app.Stop, 'OUTSIDE_PRIVATE_STATE'):
            self.p.clean()

    def test_missing_signing_key_never_generated(self):
        with self.assertRaises(OSError):
            self.p.signing()
        self.assertFalse(Path(self.c['signing']['keystore']).exists())

    def test_no_debug_signature_accepted(self):
        self.c['signing']['certificate_sha256'] = 'a' * 64
        sdk = self.root / 'sdk/build-tools/36.0.0'
        sdk.mkdir(parents=True)
        apk = self.root / 'synthetic.apk'
        with zipfile.ZipFile(apk, 'w') as z:
            z.writestr('AndroidManifest.xml', b'synthetic')
        with patch.dict(os.environ, ANDROID_HOME=str(self.root / 'sdk')):
            with patch.object(app, 'query', return_value='Signer #1 certificate SHA-256 digest: ' + 'b' * 64):
                with self.assertRaisesRegex(app.Stop, 'CERTIFICATE_MISMATCH'):
                    self.p.apk_metadata(apk)

    def test_mock_apk_metadata_valid_and_wrong_package(self):
        self.c['signing']['certificate_sha256'] = 'a' * 64
        (self.root / 'sdk/build-tools/36.0.0').mkdir(parents=True)
        apk = self.root / 'synthetic.apk'
        with zipfile.ZipFile(apk, 'w') as z:
            z.writestr('AndroidManifest.xml', b'synthetic')
        cert = 'Signer #1 certificate SHA-256 digest: ' + 'a' * 64
        for package in ('de.opennoodle.gallery', 'de.opennoodle.gallery.debug'):
            badging = f"package: name='{package}' versionCode='17' versionName='5.7.3'"
            with patch.dict(os.environ, ANDROID_HOME=str(self.root / 'sdk')):
                with patch.object(app, 'query', side_effect=[cert, badging]):
                    if package.endswith('.debug'):
                        with self.assertRaisesRegex(app.Stop, 'PACKAGE_OR_VERSION'):
                            self.p.apk_metadata(apk)
                    else:
                        self.assertEqual(self.p.apk_metadata(apk)['sha256'], app.sha(apk))

    def test_bad_image_source_rejected(self):
        self.prepare()
        value = {'Config': {'Labels': {'org.opencontainers.image.revision': 'f' * 40}, 'Env': []},
                 'Id': 'sha256:' + 'a' * 64, 'Os': 'linux', 'Architecture': 'amd64'}
        with patch.object(app, 'rootless', return_value='synthetic-own-socket'), \
                patch.object(app, 'query', return_value=json.dumps([value])), self.assertRaisesRegex(app.Stop, 'SOURCE_MISMATCH'):
            self.p.image()

    def test_artifact_helpers_recheck_rootless_before_contacting_daemon(self):
        for operation in (app.builder_idle, self.p.image):
            with patch.object(app, 'query', return_value=json.dumps([
                {'Endpoints': {'docker': {'Host': 'tcp://production:2375'}}}
            ])) as q:
                with self.assertRaisesRegex(app.Stop, 'LOCAL_ROOTLESS'):
                    operation()
                self.assertEqual(q.call_count, 1)
                self.assertEqual(q.call_args.args[0][:3], ['docker', 'context', 'inspect'])

    def test_foreign_docker_context_never_contacted(self):
        with patch.object(app, 'query', return_value=json.dumps([{'Endpoints': {'docker': {'Host': 'tcp://production:2375'}}}])) as q:
            with self.assertRaisesRegex(app.Stop, 'LOCAL_ROOTLESS'):
                app.rootless()
            self.assertEqual(q.call_count, 1)

    def test_child_environment_has_no_production_or_signing_secrets(self):
        with patch.dict(os.environ, DB_URL='not-a-real-secret', IMMICH_TEST_POSTGRES_URL='not-a-test-db',
                        ANDROID_STORE_PASSWORD='not-a-real-password', PR_NUMBER='99', DOCKER_CONTEXT='production'):
            with patch.object(app, 'rootless', return_value='unix:///run/user/synthetic/docker.sock'):
                env = self.p.environment()
        for key in ('DB_URL', 'IMMICH_TEST_POSTGRES_URL', 'ANDROID_STORE_PASSWORD', 'PR_NUMBER', 'DOCKER_CONTEXT'):
            self.assertNotIn(key, env)
        self.assertEqual(env['npm_config_child_concurrency'], '1')
        self.assertEqual(env['npm_config_workspace_concurrency'], '1')
        self.assertIn('org.gradle.workers.max=1', env['GRADLE_OPTS'])
        self.assertIn('org.gradle.daemon=false', env['GRADLE_OPTS'])

    def test_builder_limits_and_running_history(self):
        record = {'HostConfig': {'Memory': 10 * 1024**3, 'MemorySwap': 12 * 1024**3},
                  'State': {'Running': True, 'OOMKilled': False}}
        def archive(parallelism):
            b = io.BytesIO()
            with tarfile.open(fileobj=b, mode='w') as tar:
                data = f'[worker.oci]\nmax-parallelism = {parallelism}\n'.encode()
                item = tarfile.TarInfo('buildkitd.toml')
                item.size = len(data)
                tar.addfile(item, io.BytesIO(data))
            return subprocess.CompletedProcess([], 0, stdout=b.getvalue())
        for parallelism, status in ((1, 'completed'), (2, 'completed'), (1, 'running')):
            with patch.object(app, 'rootless', return_value='synthetic-own-socket'), \
                    patch.object(app, 'query', side_effect=[BUILDX035_INSPECT, json.dumps([record]), json.dumps({'status': status})]):
                with patch.object(app.subprocess, 'run', return_value=archive(parallelism)):
                    if parallelism == 1 and status == 'completed':
                        app.builder_idle()
                    else:
                        with self.assertRaises(app.Stop):
                            app.builder_idle()
        record['HostConfig']['Memory'] = 9 * 1024**3
        with patch.object(app, 'rootless', return_value='synthetic-own-socket'), \
                patch.object(app, 'query', side_effect=[BUILDX035_INSPECT, json.dumps([record])]):
            with self.assertRaisesRegex(app.Stop, 'MEMORY_LIMITS'):
                app.builder_idle()

    def test_prepared_checkpoint_survives_runner_upgrade_without_merge_or_fetch(self):
        self.prepare()
        self.p.manifest.pop('toolchain')  # HP stopped at PREPARED, before any tests.
        self.p.save('PREPARED')
        original = self.p.path.read_bytes()
        snapshots = {p.name: p.read_bytes() for p in self.p.state.glob('manifest-*.json')}
        head = REAL_GIT(self.p.source(), 'rev-parse', 'HEAD')
        self.calls.clear()
        # The recorded runner digest is deliberately absent at PREPARED. A new
        # install is allowed without changing config, state, receipts or Git.
        reloaded = app.Pipeline(self.c)
        with reloaded.locked():
            reloaded.prepare()
        self.assertEqual(reloaded.manifest['head'], head)
        self.assertEqual(reloaded.manifest['stages'], {})
        self.assertEqual(self.p.path.read_bytes(), original)
        self.assertFalse(any(c[0] in ('merge', 'fetch', 'worktree') for c in self.calls))
        for name, data in snapshots.items():
            self.assertEqual((self.p.state / name).read_bytes(), data)

    def test_copy_versioned_no_overwrite(self):
        source, target = self.root / 'source.apk', self.root / 'target.apk'
        source.write_bytes(b'synthetic APK')
        app.copy_verified(source, target, app.sha(source))
        app.copy_verified(source, target, app.sha(source))
        self.assertEqual(target.stat().st_mode & 0o777, 0o644)
        source.write_bytes(b'other APK')
        with self.assertRaisesRegex(app.Stop, 'NOT_OVERWRITTEN'):
            app.copy_verified(source, target, app.sha(source))

    def test_wrong_delivery_user_no_escalation(self):
        with patch.object(app.pwd, 'getpwuid', return_value=Mock(pw_name='codex-gallery')):
            with self.assertRaisesRegex(app.Stop, 'NO_AUTO_SUDO'):
                app.receive(self.root / 'missing.json')

    def test_read_only_check_does_not_write_state(self):
        cfg = self.root / 'config.json'
        cfg.write_text(json.dumps(self.c))
        cfg.chmod(0o600)
        before = list(self.p.state.iterdir())
        with patch.object(app.pwd, 'getpwuid', return_value=Mock(pw_name='codex-gallery')):
            with patch.object(app, 'inventory', return_value={'synthetic': 'read only'}), patch('sys.stdout', new=io.StringIO()):
                with patch.object(sys, 'argv', [str(SCRIPT), '--config', str(cfg), '--check']):
                    app.main()
        self.assertEqual(list(self.p.state.iterdir()), before)

    def test_actual_inventory_is_read_only_with_mocked_remote_services(self):
        before = self.run_git('status', '--porcelain'), list(self.p.state.iterdir())
        original = app.query
        def q(argv, *args, **kwargs):
            return None if argv[0] == 'docker' else original(argv, *args, **kwargs)
        with patch.object(app, 'query', side_effect=q), patch.object(app, 'rootless', side_effect=app.Stop('UNAVAILABLE')):
            result = app.inventory(self.c)
        self.assertEqual((self.run_git('status', '--porcelain'), list(self.p.state.iterdir())), before)
        self.assertFalse(any(c[0] == 'fetch' for c in self.calls))
        self.assertEqual(result['worktrees'][0]['head'], self.base)

    def test_check_with_v035_cli_preserves_prepared_state_and_reports_builder_validation(self):
        self.prepare()
        self.p.manifest.pop('toolchain')
        self.p.save('PREPARED')
        cfg = self.root / 'config.json'
        cfg.write_text(json.dumps(self.c))
        cfg.chmod(0o600)
        before = {p.name: p.read_bytes() for p in self.p.state.glob('*.json')}
        head = REAL_GIT(self.p.source(), 'rev-parse', 'HEAD')
        self.calls.clear()
        with fake_buildx035(history_raw=BUILDX035_HISTORY), patch.object(app.pwd, 'getpwuid', return_value=Mock(pw_name='codex-gallery')), \
                patch('sys.stdout', new=io.StringIO()) as stdout, \
                patch.object(sys, 'argv', [str(SCRIPT), '--config', str(cfg), '--check']):
            app.main()
        self.assertEqual(json.loads(stdout.getvalue())['docker']['builderValidation'], 'PASS_READ_ONLY_LIMITS_AND_IDLE')
        self.assertEqual({p.name: p.read_bytes() for p in self.p.state.glob('*.json')}, before)
        self.assertEqual(REAL_GIT(self.p.source(), 'rev-parse', 'HEAD'), head)
        self.assertFalse(any(c[0] in ('fetch', 'merge') for c in self.calls))

    def test_resume_prepared_v035_checkpoint_never_repeats_integration(self):
        self.prepare()
        self.p.manifest.pop('toolchain')
        self.p.save('PREPARED')
        cfg = self.root / 'config.json'
        cfg.write_text(json.dumps(self.c))
        cfg.chmod(0o600)
        snapshots = {p.name: p.read_bytes() for p in self.p.state.glob('manifest-*.json')}
        head = self.p.manifest['head']
        self.calls.clear()
        with fake_buildx035(history_raw=BUILDX035_HISTORY), patch.object(app.pwd, 'getpwuid', return_value=Mock(pw_name='codex-gallery')), \
                patch.object(sys, 'argv', [str(SCRIPT), '--config', str(cfg), '--resume']):
            app.main()
        saved = json.loads(self.p.path.read_text())
        self.assertEqual(saved['head'], head)
        self.assertTrue(saved['prepared'])
        self.assertEqual(saved['stages'], {})
        self.assertFalse(any(c[0] in ('fetch', 'merge') for c in self.calls))
        for name, data in snapshots.items():
            self.assertEqual((self.p.state / name).read_bytes(), data)

    def test_resume_only_last_selected_mode(self):
        cfg = self.root / 'config.json'
        cfg.write_text(json.dumps(self.c))
        cfg.chmod(0o600)
        fake = MagicMock()
        fake.state = self.p.state
        fake.manifest = {'mode': 'build', 'prepared': True}
        with patch.object(app.pwd, 'getpwuid', return_value=Mock(pw_name='codex-gallery')):
            with patch.object(app, 'inventory', return_value={}), patch.object(app, 'Pipeline', return_value=fake):
                with patch.object(sys, 'argv', [str(SCRIPT), '--config', str(cfg), '--resume']):
                    app.main()
        fake.build.assert_called_once_with()
        fake.test.assert_not_called()
        fake.prepare.assert_not_called()
        fake.verify.assert_not_called()

    def test_canonical_state_cannot_be_overwritten(self):
        self.c['state'] = self.c['automation_state']
        cfg = self.root / 'config.json'
        cfg.write_text(json.dumps(self.c))
        cfg.chmod(0o600)
        with self.assertRaisesRegex(app.Stop, 'MUST_NOT_OVERLAP'):
            app.config(cfg)

    def test_required_ci_cannot_be_removed_from_config(self):
        cfg = self.root / 'config.json'
        self.c['required_checks']['compatibility'] = ['Optional']
        cfg.write_text(json.dumps(self.c))
        cfg.chmod(0o600)
        with self.assertRaisesRegex(app.Stop, 'REQUIRED_CI_CANNOT_BE_REMOVED'):
            app.config(cfg)

    def test_protocol_web_and_e2e_gates_cannot_be_removed(self):
        required = {'check-openapi', 'check-mobile-patches', 'Test Web', 'Lint Web', 'End-to-End Tests Success'}
        self.assertTrue(required <= REAL_REQUIRED_CHECKS['compatibility'])
        self.c['required_checks'] = {role: sorted(checks) for role, checks in REAL_REQUIRED_CHECKS.items()}
        cfg = self.root / 'strict-config.json'
        with patch.object(app, 'REQUIRED_CHECKS', REAL_REQUIRED_CHECKS):
            for name in required:
                candidate = copy.deepcopy(self.c)
                candidate['required_checks']['compatibility'].remove(name)
                cfg.write_text(json.dumps(candidate))
                cfg.chmod(0o600)
                with self.subTest(name=name), self.assertRaisesRegex(app.Stop, 'REQUIRED_CI_CANNOT_BE_REMOVED'):
                    app.config(cfg)

    def test_no_mode_and_mutually_exclusive_modes(self):
        for args in ([], ['--test', '--build'], ['--finalize', '--build']):
            result = subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True)
            self.assertEqual(result.returncode, 2)

    def test_finalize_missing_existing_key_stops_before_integration_or_build(self):
        with patch.object(self.p, 'prepare') as prepare, patch.object(self.p, 'build') as build:
            with self.assertRaises(OSError):
                self.p.finalize()
        prepare.assert_not_called()
        build.assert_not_called()

    def test_finalize_failure_never_advances_to_later_phases_or_retries(self):
        phases = ['signing', 'prepare', 'test', 'build', 'verify']
        for failure in phases:
            with self.subTest(failure=failure), contextlib.ExitStack() as stack:
                self.p.manifest = {}
                calls = []
                for name in phases:
                    def phase(name=name):
                        calls.append(name)
                        if name == failure:
                            raise app.Stop('synthetic phase failure')
                    stack.enter_context(patch.object(self.p, name, side_effect=phase))
                stack.enter_context(patch.object(self.p, 'save'))
                with self.assertRaisesRegex(app.Stop, 'synthetic phase failure'):
                    self.p.finalize()
                self.assertEqual(calls, phases[:phases.index(failure) + 1])
                if failure == 'verify':
                    self.assertEqual(self.p.manifest['mode'], 'verify')

    def test_finalize_cli_requires_tmux_before_inventory_or_state_writes(self):
        with patch.object(sys, 'argv', [str(SCRIPT), '--config', 'synthetic.json', '--finalize']), \
             patch.object(app, 'config', return_value=self.c), patch.object(app.os, 'getuid', return_value=12345), \
             patch.object(app.pwd, 'getpwuid', return_value=Mock(pw_name='codex-gallery')), \
             patch.dict(os.environ, {'TMUX': ''}), patch.object(app, 'inventory') as inventory:
            with self.assertRaisesRegex(app.Stop, 'FINALIZE_REQUIRES_TMUX'):
                app.main()
        inventory.assert_not_called()

    def test_mandatory_recipes_are_serial_and_include_compact_layout(self):
        with patch.object(Path, 'is_file', return_value=True):
            recipes = app.recipes_for(self.repo)
        commands = [cmd for _, _, cmd, _ in recipes]
        self.assertTrue(any('test/pages/edit/editor_compact_layout_test.dart' in cmd for cmd in commands))
        self.assertTrue(any('test/infrastructure/repositories/memory_v2_journal_test.dart' in cmd for cmd in commands))
        for name, _, cmd, _ in recipes:
            if name.startswith(('unit-', 'medium-')):
                self.assertIn('--maxWorkers=1', cmd)
                self.assertIn('--no-file-parallelism', cmd)
                self.assertIn('--maxConcurrency=1', cmd)
            if cmd[:2] == ['flutter', 'test']:
                self.assertIn('--concurrency=1', cmd)
            if name in ('sdk-initial', 'plugin-sdk', 'plugin-core', 'plugin-gallery'):
                self.assertEqual(cmd.count('--filter'), 1)


@unittest.skipUnless(os.environ.get('FOTO17_PINNED_GIT_REPLAY_REPO'), 'requires the published pinned Git objects')
class PinnedGitReplayTest(unittest.TestCase):
    def test_original_stop_and_same_state_resume_on_published_heads(self):
        objects = Path(os.environ['FOTO17_PINNED_GIT_REPLAY_REPO']).resolve()
        review = app.REVIEWED_OVERLAP
        def git(repo, *args):
            return REAL_GIT(repo, *args)
        original_head = git(objects, 'rev-parse', 'HEAD')
        original_status = git(objects, 'status', '--porcelain=v1')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo = root / 'repo'
            subprocess.run(['git', 'clone', '--shared', '--no-checkout', str(objects), str(repo)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
            git(repo, 'switch', '-c', app.BASE_BRANCH, review['base'])
            git(repo, 'remote', 'set-url', 'origin', 'https://github.com/docice545/gallery.git')
            c = json.loads(SCRIPT.with_name('foto-build17-release.example.json').read_text())
            for name, value in {'repo': repo, 'state': root / 'state', 'automation_state': root / 'common',
                                'legacy_lock': root / 'legacy/auto.lock'}.items():
                c[name] = str(value)
            for name in ('state', 'common', 'legacy'):
                (root / name).mkdir(mode=0o700)
            for role in app.ROLES:
                self.assertEqual(c['prs'][role]['sha'], review[role])
                c['prs'][role].update(approved=True, approval_note='isolated Git replay, not HP approval')
            admitted = [{'role': role, **c['prs'][role]} for role in app.ROLES]
            def local_fetch(repo, *args, **kwargs):
                if args[0] == 'fetch':
                    ref = args[-1].split(':', 1)[1]
                    return REAL_GIT(repo, 'update-ref', ref, review[ref.split('/')[-1]])
                return REAL_GIT(repo, *args, **kwargs)

            # Execute the actual previous script, not a mock of its partial guard.
            old = root / 'old'
            old.mkdir()
            previous = subprocess.check_output(['git', '-C', str(objects), 'show',
                '4255a4c826fe61f563fb866a139c8044a41eff18:tools/foto-automation/foto-build17-release'])
            (old / SCRIPT.name).write_bytes(previous)
            (old / 'foto-stage-runner.py').write_bytes(SCRIPT.with_name('foto-stage-runner.py').read_bytes())
            loader = importlib.machinery.SourceFileLoader('foto_release_old_overlap', str(old / SCRIPT.name))
            spec = importlib.util.spec_from_loader(loader.name, loader)
            legacy = importlib.util.module_from_spec(spec)
            loader.exec_module(legacy)
            stopped = legacy.Pipeline(c)
            with patch.object(stopped, 'gate', return_value=admitted), patch.object(legacy, 'git', side_effect=local_fetch):
                with self.assertRaisesRegex(legacy.Stop, 'PARTIALLY_APPLIED_PR_REVIEW_REQUIRED'):
                    stopped.prepare()
            before = {p.name: p.read_bytes() for p in stopped.state.glob('manifest-*.json')}
            resumed = app.Pipeline(c)
            with patch.object(resumed, 'gate', return_value=admitted), patch.object(app, 'git', side_effect=local_fetch), \
                 patch.object(app, 'processes', return_value=[]), resumed.locked():
                resumed.prepare()
                head = resumed.manifest['head']
                resumed.prepare()
            source = resumed.source()
            self.assertEqual(source, stopped.source())
            self.assertEqual(git(source, 'rev-parse', 'HEAD^{tree}'), review['outputTree'])
            self.assertEqual(resumed.manifest['head'], head)
            self.assertEqual(len(resumed.manifest['overlapReview']['equivalentCommits']), 11)
            for sha in (review['base'], review['editor'], review['compatibility'],
                        '2364b82e9246a08174ad6d5278bc7227388e8e31'):
                self.assertIsNotNone(REAL_GIT(source, 'merge-base', '--is-ancestor', sha, 'HEAD', optional=True))
            self.assertEqual(git(source, 'diff', '--exit-code', review['compatibility'], 'HEAD', '--',
                                 'server', 'web', 'open-api', 'packages/sdk', 'pnpm-lock.yaml', 'package.json',
                                 'mobile/pubspec.yaml', 'mobile/pubspec.lock'), '')
            self.assertEqual(git(source, 'diff', '--exit-code', review['editor'], 'HEAD', '--',
                                 'mobile/lib/presentation/pages/edit', 'mobile/test/pages/edit',
                                 'mobile/lib/repositories/magic_eraser.repository.dart'), '')
            self.assertEqual(git(repo, 'rev-parse', 'HEAD'), review['base'])
            self.assertEqual(git(repo, 'status', '--porcelain=v1'), '')
            for name, data in before.items():
                self.assertEqual((resumed.state / name).read_bytes(), data)
        self.assertEqual(git(objects, 'rev-parse', 'HEAD'), original_head)
        self.assertEqual(git(objects, 'status', '--porcelain=v1'), original_status)


if __name__ == '__main__':
    unittest.main()
