"""Synthetic evidence and opt-in disposable PostgreSQL/Redis. Never HP access."""
from contextlib import contextmanager, redirect_stdout, redirect_stderr
from datetime import datetime, timedelta, timezone
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import secrets
import subprocess
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, file)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


p = module('predeploy_tests', ROOT / 'scripts/release/trash_predeploy.py')
release = module('pinned_predeploy_tests', ROOT / 'scripts/release/trash_release.py')


def summary():
    return {'assetCount': 3, 'libraryCount': 1, 'statusCounts': {'active': 2, 'trashed': 1},
            'migrationNames': ['synthetic'], 'orphans': 0}


def layer(entries):
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode='w') as tar:
        for name in entries:
            info = tarfile.TarInfo(name)
            info.size = 1
            tar.addfile(info, io.BytesIO(b'x'))
    return data.getvalue()


class Guards(unittest.TestCase):
    def test_pinned_helper_is_unchanged(self):
        self.assertEqual(p.sha(ROOT / 'scripts/release/trash_release.py'), p.PIN_FILE_SHA)

    def test_wrong_pin_rejected_before_docker_access(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(p.subprocess, 'run') as run:
            file = Path(directory) / 'helper'; file.write_text('wrong')
            with self.assertRaisesRegex(p.Stop, 'PINNED_TOOLING'): p.load_tool(file)
            run.assert_not_called()

    def test_deployment_and_rollback_need_two_approvals_before_loading_tool(self):
        for action in ('deploy', 'rollback'):
            for flag, env in ((False, 'YES'), (True, ''), (False, '')):
                with patch.object(p.pwd, 'getpwuid', return_value=SimpleNamespace(pw_name='doctoriceadm')), \
                     patch.dict(os.environ, {'GALLERY_DEPLOYMENT_APPROVED': env}), \
                     patch.object(p, 'load_tool') as load, redirect_stderr(io.StringIO()):
                    argv = [action, '--state', '/absent'] + (['--approve-deployment'] if flag else [])
                    self.assertEqual(p.main(argv), 1)
                    load.assert_not_called()

    def test_prepare_has_no_deployment_retention_or_signing_call(self):
        text = (ROOT / 'scripts/release/trash_predeploy.py').read_text()
        start = text[text.index('def prepare('):text.index('def recheck(')]
        for forbidden in ('tool.deploy', 'tool.enable', 'pause', 'resume', 'sign_existing', 'recreate'):
            self.assertNotIn(forbidden, start)

    def test_new_receipts_never_overwrite_or_follow_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / 'receipt'; p.save(file, {'existing': True})
            self.assertEqual(file.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError): p.save(file, {})
            link = Path(directory) / 'link'; link.symlink_to(file)
            with self.assertRaises(FileExistsError): p.save(link, {})

    def test_private_evidence_rejects_public_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / 'receipt'; file.write_text('{}'); file.chmod(0o644)
            with self.assertRaises(p.Stop): p.private_json(file)

    def test_age_requires_fresh_nonfuture_evidence(self):
        now = datetime.now(timezone.utc)
        p.age_ok(now.isoformat(), 3600, 'expired')
        for date in (now - timedelta(hours=2), now + timedelta(hours=1)):
            with self.assertRaisesRegex(p.Stop, 'expired'): p.age_ok(date.isoformat(), 3600, 'expired')

    def test_summary_checks_counts_migrations_and_foreign_keys(self):
        p.summary_valid(summary())
        for field, value in (('orphans', 1), ('assetCount', 4), ('assetCount', True),
                             ('migrationNames', []), ('migrationNames', ['b', 'a']),
                             ('statusCounts', {'active': -1})):
            row = summary(); row[field] = value
            with self.assertRaises(p.Stop): p.summary_valid(row)

    def test_old_pg_receipt_cannot_satisfy_new_backup(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(release, 'restore_check') as restore:
            state = Path(directory); p.save(state / 'backup-verified.json', {'old': True})
            with self.assertRaisesRegex(p.Stop, 'OLD_RESTORE_RECEIPT'):
                p.restore_exact(release, state / 'new.gz', state, summary())
            restore.assert_not_called()

    def test_missing_restore_validation_hook_cannot_pass(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(release, 'restore_check'):
            state = Path(directory)
            with self.assertRaisesRegex(p.Stop, 'HOOK_NOT_EXECUTED'):
                p.restore_exact(release, state / 'new.gz', state, summary())

    def test_snapshot_connection_is_local_readonly_no_secret_argument(self):
        cmd = p.psql_command(release, 'synthetic')
        self.assertIn('--user', cmd); self.assertIn('--host=/var/run/postgresql', cmd)
        self.assertIn('--no-password', cmd)
        self.assertEqual(cmd[cmd.index('-U') + 1], 'postgres')
        self.assertEqual(cmd[cmd.index('-d') + 1], 'immich')
        self.assertNotIn('password=', ' '.join(cmd))
        self.assertIn('pg_export_snapshot()', p.SNAPSHOT_SQL)

    def test_nas_pass_reused_unchanged_with_provenance_and_no_old_pg_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); nas = root / 'nas'; pg = root / 'pg'; state = root / 'new'
            for path in (nas, pg, state): path.mkdir(mode=0o700)
            point = 'synthetic-snapshot-provenance'
            hashes = ['a' * 64, 'b' * 64]
            receipt = {'mounts': {'/synthetic': {'sampleHashes': hashes,
                'snapshotReferenceSHA256': hashlib.sha256(point.encode()).hexdigest()}},
                'verifiedAt': datetime.now(timezone.utc).isoformat(),
                'validation': 'SAMPLE_BYTE_RECOVERY_PLUS_OPERATOR_SNAPSHOT_SCOPE_ATTESTATION'}
            p.save(nas / 'nas-verified.json', receipt)
            p.save(nas / 'nas-proof.json', {'mounts': {'/synthetic': {
                'operator_attests_snapshot_export': True, 'snapshot_reference': point,
                'samples': [{'kind': kind, 'sha256': digest} for kind, digest in zip(('photo', 'video'), hashes)]}},
                'provenance': {share: {'snapshotId': point, 'snapshotTimestamp': 'synthetic',
                    'metadataSource': 'DSM_SNAPSHOT_LIST'} for share in ('homes', 'Immich')}})
            p.save(nas / 'nas-recovery-report.txt', {'result': 'PASS',
                'checks': {'NAS_RECOVERY': 'PASS', 'PREVIOUS_EVIDENCE': 'PASS_UNCHANGED'}})
            p.save(pg / 'backup-verified.json', {'restore': 'PASS_ISOLATED_SQL_TRANSACTION', 'productionChanged': False})
            p.save(pg / 'recovery-report.txt', {'checks': {'POSTGRES_RESTORE': 'PASS'}})
            audit = {'containers': [{'role': release.SERVER, 'externalMounts': [{'containerMountpoint': '/synthetic'}]}]}
            before = p.sha(nas / 'nas-verified.json')
            values = p.reuse_nas(release, nas, pg, audit, state)
            self.assertEqual(p.private_json(state / 'nas-verified.json'), receipt)
            self.assertEqual(p.sha(nas / 'nas-verified.json'), before)
            self.assertEqual(len(values), 5)
            self.assertFalse((state / 'backup-verified.json').exists())

    def test_atomic_queue_contract_fail_closed(self):
        toolfile = ROOT / 'scripts/release/trash_release.py'
        with patch.object(p.subprocess, 'run', return_value=SimpleNamespace(returncode=0)):
            tool = p.load_tool(toolfile)
        row = {'counts': dict.fromkeys(tool.STATES, 0), 'before': dict.fromkeys(tool.STATES, 0),
               'paused': True, 'atomic': True, 'inventoryComplete': True, 'unresolvedDeletionHashes': 0}
        with patch.object(tool, 'docker', return_value=json.dumps(row)):
            self.assertEqual(tool.queue_empty(True)['counts'], row['counts'])
        for field, value in (('atomic', False), ('inventoryComplete', False), ('unresolvedDeletionHashes', 1),
                             ('before', {'active': 0})):
            changed = {**row, field: value}
            with patch.object(tool, 'docker', return_value=json.dumps(changed)):
                with self.assertRaises(p.Stop): tool.queue_empty()
        for state in tool.STATES:
            changed = {**row, 'counts': {**row['counts'], state: 1}}
            with patch.object(tool, 'docker', return_value=json.dumps(changed)):
                with self.assertRaises(tool.Stop): tool.queue_empty()

    def test_queue_lua_has_only_read_commands_and_no_scan_as_emptiness_test(self):
        for command in ('LLEN', 'ZCARD', 'HGET'): self.assertIn(command, p.COUNTS_LUA)
        for command in ('DEL', 'LPOP', 'ZREM', 'SET', 'SCAN'): self.assertNotIn(command, p.COUNTS_LUA)
        self.assertIn('before=await read()', p.QUEUE_BODY)
        self.assertIn('after=await read()', p.QUEUE_BODY)

    def test_archive_image_identity_and_whiteout_migration_overlay(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = json.dumps({'architecture': 'amd64', 'os': 'linux', 'config': {'Env': [
                'IMMICH_SOURCE_COMMIT=' + release.SOURCE, 'IMMICH_SOURCE_REF=v5.7.1']}}).encode()
            identity = 'sha256:' + hashlib.sha256(config).hexdigest()
            config_name = identity[7:] + '.json'
            prefix = 'usr/src/app/server/dist/schema/migrations/'
            blobs = {'one/layer.tar': layer([prefix + 'obsolete.js', prefix + 'keep.js']),
                     'two/layer.tar': layer([prefix + '.wh.obsolete.js', prefix + 'new.js'])}
            manifest = [{'Config': config_name, 'Layers': list(blobs), 'RepoTags': [release.TAG]}]
            blobs[config_name] = config; blobs['manifest.json'] = json.dumps(manifest).encode()
            with tarfile.open(root / 'gallery-server-linux-amd64.tar.gz', 'w:gz') as outer:
                for name, value in blobs.items():
                    info = tarfile.TarInfo(name); info.size = len(value); outer.addfile(info, io.BytesIO(value))
            with patch.object(release, 'verify_artifact'), patch.object(release, 'IMAGE', identity):
                self.assertEqual(p.archive_migrations(release, root), ['keep', 'new'])
            with patch.object(release, 'verify_artifact'):
                with self.assertRaisesRegex(p.Stop, 'CONFIG_DIGEST'): p.archive_migrations(release, root)

    def test_native_node_program_syntax(self):
        program = release.NODE_BASE + p.QUEUE_BODY.replace('__LUA__', json.dumps(p.COUNTS_LUA))
        result = subprocess.run(['node', '--input-type=module', '--check'], input=program,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def node_inventory(self, completed=False, limit=False, fail=False):
        # Test the exact shipped JS inventory without configuring real credentials.
        setup = '''const config={redis:{},bull:{config:{prefix:'synthetic'}}};
const completed=__COMPLETED__,limit=__LIMIT__,fail=__FAIL__;
class FakeRedis {
 on(){} async connect(){} disconnect(){}
 async eval(){if(fail)throw Error('synthetic-only');return [0,0,0,0,0,0,0,''];}
 async scan(){return ['0',limit?Array(5001).fill('synthetic:backgroundTask:job'):['synthetic:backgroundTask:job']];}
 async type(){return 'hash';} async hget(){return 'AssetDelete';}
 async zscore(){return completed?'0':null;}
}
const require=()=>FakeRedis;
'''.replace('__COMPLETED__', json.dumps(completed)).replace('__LIMIT__', json.dumps(limit)).replace('__FAIL__', json.dumps(fail))
        code = setup + p.QUEUE_BODY.replace('__LUA__', json.dumps(p.COUNTS_LUA))
        result = subprocess.run(['node', '--input-type=module'], input=code, capture_output=True, text=True, timeout=10)
        return result.returncode, json.loads(result.stdout)

    def test_actual_node_inventory_orphan_blocks_despite_zero_state_counts(self):
        code, row = self.node_inventory()
        self.assertEqual(code, 0)
        self.assertEqual(row['unresolvedDeletionHashes'], 1)
        self.assertEqual(row['deletionNames']['AssetDelete'], 1)
        self.assertTrue(row['atomic'])

    def test_actual_node_inventory_completed_history_does_not_block(self):
        code, row = self.node_inventory(completed=True)
        self.assertEqual(code, 0)
        self.assertEqual(row['unresolvedDeletionHashes'], 0)
        self.assertTrue(row['inventoryComplete'])

    def test_actual_node_inventory_truncation_or_read_error_never_pass(self):
        code, row = self.node_inventory(limit=True)
        self.assertEqual(code, 0)
        self.assertFalse(row['inventoryComplete'])
        code, row = self.node_inventory(fail=True)
        self.assertEqual(code, 1)
        self.assertEqual(row, {'error': 'QUEUE_READ_FAILED'})

    def test_mobile_mismatch_precedes_backend_or_production_mutation(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(p, 'archive_migrations') as read:
            root = Path(directory); (root / 'android').mkdir()
            (root / 'android/app-release.apk').write_bytes(b'synthetic-wrong-artifact')
            with self.assertRaisesRegex(p.Stop, 'FROZEN_MOBILE_ARTIFACT'):
                p.verify_artifacts(release, root)
            read.assert_not_called()

    def prepare_fixture(self, state, *, expired=False, moved=False):
        journal = []
        current = {'synthetic': {'id': 'unchanged', 'image': 'unchanged'}}
        def command(args):
            if args[0] == 'findmnt': return '{"filesystems":[{"fstype":"ext4"}]}'
            if 'rev-parse' in args: return p.BASE
            if 'branch' in args: return 'work'
            return ''
        def nas(*args):
            stamp = datetime.now(timezone.utc) - timedelta(hours=25 if expired else 0)
            p.save(state / 'nas-verified.json', {'verifiedAt': stamp.isoformat()})
            return {}
        def backup(*args):
            journal.append('dump')
            return state / 'synthetic.gz', summary()
        def restore(*args):
            journal.append('restore')
            p.save(state / 'backup-verified.json', {'backupModifiedAt': datetime.now(timezone.utc).isoformat()})
        def rollback(*args): journal.append('rollback-prerequisites'); return {}
        def queue(): journal.append('queue'); return {'atomic': True}
        def api(base, key, path):
            return {'res': 'pong'} if path.endswith('/ping') else {'major': 5, 'minor': 7, 'patch': 1, 'prerelease': None}
        tool = SimpleNamespace(SOURCE=release.SOURCE, run=command, api=api, queue_empty=queue)
        args = SimpleNamespace(artifacts=state, audit=state / 'audit', nas_state=state,
                               previous_pg_state=state, api='http://127.0.0.1:2283/api')
        p.save(args.audit, {})
        @contextmanager
        def fixture():
            with patch.object(p, 'topology', side_effect=[current, {} if moved else current]), \
                 patch.object(p, 'validate_audit', return_value={}), patch.object(p, 'reuse_nas', side_effect=nas), \
                 patch.object(p, 'verify_artifacts', return_value=['synthetic']), \
                 patch.object(p, 'fresh_backup', side_effect=backup), patch.object(p, 'restore_exact', side_effect=restore), \
                 patch.object(p, 'rollback_prerequisites', side_effect=rollback), redirect_stdout(io.StringIO()):
                yield tool, args, journal
        return fixture()

    def test_full_prepare_queue_probe_is_last_after_fresh_restore_and_rollback_reserves(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            with self.prepare_fixture(state) as (tool, args, journal): p.prepare(tool, args, state)
            self.assertEqual(journal, ['rollback-prerequisites', 'dump', 'restore', 'rollback-prerequisites', 'queue'])
            self.assertTrue((state / 'predeploy-context.json').is_file())

    def test_nas_expiry_during_restore_stops_before_queue_probe_or_pass_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            with self.prepare_fixture(state, expired=True) as (tool, args, journal):
                with self.assertRaisesRegex(p.Stop, 'NAS_PASS_OLDER'): p.prepare(tool, args, state)
            self.assertNotIn('queue', journal)
            self.assertFalse((state / 'predeploy-context.json').exists())

    def test_production_change_during_restore_stops_before_queue_probe_or_pass_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            with self.prepare_fixture(state, moved=True) as (tool, args, journal):
                with self.assertRaisesRegex(p.Stop, 'PRODUCTION_OR_RECOVERY'): p.prepare(tool, args, state)
            self.assertNotIn('queue', journal)
            self.assertFalse((state / 'predeploy-context.json').exists())


@unittest.skipUnless(os.environ.get('GALLERY_DISPOSABLE_RELEASE_TESTS') == '1', 'opt-in isolated cloud Docker fixtures')
class Disposable(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.command = ['docker', '--host=unix:///var/run/docker.sock']
        cls.pg = json.loads(cls.docker('image', 'inspect', 'e163bcdc41b9'))[0]['Id']

    @classmethod
    def docker(cls, *args, input=None, **kw):
        return subprocess.run([*cls.command, *args], input=input, text=True, capture_output=True,
                              check=True, timeout=120).stdout

    @contextmanager
    def source_db(self):
        name = 'gallery-predeploy-fixture-' + secrets.token_hex(8)
        try:
            self.docker('run', '-d', '--pull', 'never', '--network', 'none', '--name', name,
                        '--cpus', '1', '--memory', '512m', '-e', 'POSTGRES_DB=immich',
                        '-e', 'POSTGRES_PASSWORD=disposable-only', self.pg, 'postgres',
                        '-c', 'shared_preload_libraries=vchord.so',
                        '-c', 'config_file=/var/lib/postgresql/data/postgresql.conf')
            self.docker('exec', name, 'sh', '-c', 'for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do '
                        'pg_isready -h 127.0.0.1 >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1')
            self.docker('exec', name, 'psql', '-X', '-q', '-U', 'postgres', '-d', 'immich', '-v', 'ON_ERROR_STOP=on', '-c',
                'CREATE TABLE library(id bigint PRIMARY KEY); '
                'CREATE TABLE asset(id bigint PRIMARY KEY,"libraryId" bigint REFERENCES library(id),status text); '
                "CREATE TABLE kysely_migrations(name text PRIMARY KEY); INSERT INTO kysely_migrations VALUES('synthetic'); "
                "INSERT INTO library VALUES(1); INSERT INTO asset VALUES(1,1,'active'),(2,1,'active'),(3,1,'trashed');")
            yield name
        finally:
            self.docker('rm', '-f', '-v', name)

    @contextmanager
    def pinned_fixture(self, name):
        def inspect(container):
            return {'Id': 'synthetic-unchanged-' + container, 'Image': self.pg, 'Config': {'Env': []}}
        # Only topology and real HP resource-reserve probes are fixtures. Actual
        # pg_dump/snapshot/SQL restore/gzip/anonymous volume cleanup run locally.
        with patch.object(release, 'DOCKER', self.command), patch.object(release, 'POSTGRES', name), \
             patch.object(release, 'docker', side_effect=self.docker), patch.object(release, 'inspect', side_effect=inspect), \
             patch.object(release.shutil, 'disk_usage', return_value=SimpleNamespace(free=30 * 1024**3)):
            yield

    def test_real_fresh_snapshot_dump_restore_ignores_concurrent_later_insert(self):
        with self.source_db() as name, self.pinned_fixture(name), tempfile.TemporaryDirectory() as directory:
            state = Path(directory); original = p.exported_snapshot

            @contextmanager
            def with_concurrent_insert(tool, path):
                with original(tool, path) as row:
                    self.docker('exec', name, 'psql', '-X', '-q', '-U', 'postgres', '-d', 'immich', '-c',
                                "INSERT INTO asset VALUES(4,1,'active');")
                    yield row

            with patch.object(p, 'exported_snapshot', with_concurrent_insert), redirect_stdout(io.StringIO()):
                backup, expected = p.fresh_backup(release, state)
                p.restore_exact(release, backup, state, expected)
            self.assertEqual(expected, summary())
            self.assertEqual(json.loads(self.docker('exec', name, 'psql', '-X', '-A', '-t', '-U', 'postgres',
                '-d', 'immich', '-c', p.SUMMARY_SQL))['assetCount'], 4)
            receipt = p.private_json(state / 'fresh-restore-verified.json')
            self.assertEqual(receipt['summary'], summary())
            self.assertEqual(receipt['backupSHA256'], p.sha(backup))
            self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
            fixture = json.loads(self.docker('inspect', name))[0]
            self.assertEqual(fixture['HostConfig']['NetworkMode'], 'none')
            self.assertEqual(fixture['HostConfig']['PortBindings'], {})
        self.assertEqual(self.docker('ps', '-aq', '--filter', 'name=gallery-restore-check-').strip(), '')

    def test_real_restore_wrong_counts_fails_and_removes_only_disposable_fixture(self):
        with self.source_db() as name, self.pinned_fixture(name), tempfile.TemporaryDirectory() as directory:
            state = Path(directory); backup, expected = p.fresh_backup(release, state)
            expected = {**expected, 'libraryCount': 2}
            with self.assertRaisesRegex(p.Stop, 'DIFFER_FROM_DUMP_SNAPSHOT'):
                p.restore_exact(release, backup, state, expected)
            self.assertFalse((state / 'backup-verified.json').exists())
            self.assertFalse((state / 'fresh-restore-verified.json').exists())
            self.assertTrue(json.loads(self.docker('inspect', name))[0]['State']['Running'])
        self.assertEqual(self.docker('ps', '-aq', '--filter', 'name=gallery-restore-check-').strip(), '')

    def test_real_dump_failure_no_valid_backup_or_receipt(self):
        with self.source_db() as name, self.pinned_fixture(name), tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            original = p.exported_snapshot

            @contextmanager
            def invalid_snapshot(tool, path):
                with original(tool, path) as row:
                    yield {**row, 'snapshot': 'DEAD-BEEF-0'}

            with patch.object(p, 'exported_snapshot', invalid_snapshot):
                with self.assertRaisesRegex(p.Stop, 'DUMP_FAILED'): p.fresh_backup(release, state)
            self.assertFalse((state / 'fresh-immich.sql.gz').exists())
            self.assertFalse((state / 'backup-verified.json').exists())
            self.assertTrue((state / 'fresh-immich.sql.gz.partial').exists())

    def test_real_redis_atomic_counts_every_state_and_paused_flag(self):
        name = 'gallery-predeploy-redis-' + secrets.token_hex(8)
        try:
            self.docker('run', '-d', '--pull', 'never', '--network', 'none', '--name', name,
                        '--memory', '128m', 'redis:7-alpine')
            states = release.STATES; keys = ['synthetic:' + s for s in states] + ['synthetic:meta']
            def cli(*args): return self.docker('exec', name, 'redis-cli', '--json', *args)
            def read(): return json.loads(cli('EVAL', p.COUNTS_LUA, '8', *keys))
            self.assertEqual(read()[:7], [0] * 7)
            cli('HSET', keys[-1], 'paused', '1'); self.assertEqual(read()[-1], '1')
            for i, key in enumerate(keys[:7]):
                cli(*(['RPUSH', key, 'synthetic-job'] if i < 3 else ['ZADD', key, '1', 'synthetic-job']))
                self.assertEqual(read()[i], 1)
            self.assertEqual(read()[:7], [1] * 7)
        finally:
            self.docker('rm', '-f', '-v', name)


if __name__ == '__main__':
    unittest.main()
