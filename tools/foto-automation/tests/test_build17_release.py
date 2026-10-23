"""Release orchestration tests. Real temporary Git/files; mocked GitHub/Docker/Android, never HP."""
import copy
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
                        patch.object(app, 'resources', return_value={
                            'memoryBytes': {'MemAvailable': 32 * 1024**3}, 'currentCgroup': {'memory.max': str(32 * 1024**3)}})]
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
