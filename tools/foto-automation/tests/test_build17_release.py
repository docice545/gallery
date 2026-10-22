"""Release orchestration tests. Real temporary Git/files; mocked GitHub/Docker/Android, never HP."""
import copy
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
        self.c['required_checks'] = ['Contract']
        for i, role in enumerate(app.ROLES, 1):
            self.c['prs'][role] = {'number': i, 'sha': self.heads[role], 'approved': True, 'approval_note': 'synthetic review'}
        for path in ('state', 'common', 'legacy'):
            (self.root / path).mkdir(mode=0o700)
        self.p = app.Pipeline(self.c)
        self.calls = []
        self.patches = [patch.object(app, 'api', side_effect=self.api),
                        patch.object(app, 'git', side_effect=self.git), patch.object(app, 'processes', return_value=[]),
                        patch.object(app, 'WORK_ROOT', self.root),
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
        with patch.object(app, 'query', return_value=json.dumps([value])), self.assertRaisesRegex(app.Stop, 'SOURCE_MISMATCH'):
            self.p.image()

    def test_foreign_docker_context_never_contacted(self):
        with patch.object(app, 'query', return_value=json.dumps([{'Endpoints': {'docker': {'Host': 'tcp://production:2375'}}}])) as q:
            with self.assertRaisesRegex(app.Stop, 'LOCAL_ROOTLESS'):
                app.rootless()
            self.assertEqual(q.call_count, 1)

    def test_builder_limits_and_running_history(self):
        node = {'Driver': 'docker-container', 'Nodes': [{'Endpoint': 'rootless', 'Name': 'foto17-limited0'}]}
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
            with patch.object(app, 'query', side_effect=[json.dumps(node), json.dumps([record]), json.dumps({'Status': status})]):
                with patch.object(app.subprocess, 'run', return_value=archive(parallelism)):
                    if parallelism == 1 and status == 'completed':
                        app.builder_idle()
                    else:
                        with self.assertRaises(app.Stop):
                            app.builder_idle()
        record['HostConfig']['Memory'] = 9 * 1024**3
        with patch.object(app, 'query', side_effect=[json.dumps(node), json.dumps([record])]):
            with self.assertRaisesRegex(app.Stop, 'MEMORY_LIMITS'):
                app.builder_idle()

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

    def test_no_mode_and_mutually_exclusive_modes(self):
        for args in ([], ['--test', '--build']):
            result = subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True)
            self.assertEqual(result.returncode, 2)


if __name__ == '__main__':
    unittest.main()
