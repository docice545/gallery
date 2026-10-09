"""Private report guards and opt-in disposable PostgreSQL/Redis runtime tests.

GALLERY_DISPOSABLE_AUDIT_TESTS=1 starts only uniquely named local fixtures,
using already cached images. No remote Docker selector or production API.
"""
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid
from contextlib import redirect_stdout
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('audit', ROOT / 'scripts/diagnostics/hp_trash_release_audit.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class PrivateReportTests(unittest.TestCase):
    def test_unique_reports_preserve_previous_report(self):
        with tempfile.TemporaryDirectory() as directory:
            old = Path(directory) / 'gallery-trash-release-audit.txt'
            old.write_text('previous private report')
            with patch.object(audit, 'REPORT_DIRECTORY', Path(directory)), patch.object(audit, 'REPORT', None), \
                 patch.object(audit.pwd, 'getpwuid', return_value=SimpleNamespace(pw_name='doctoriceadm')), \
                 patch.object(audit, 'command', return_value='24.0'), \
                 patch.object(audit, 'collect', return_value={'deploymentReady': False}), redirect_stdout(io.StringIO()):
                self.assertEqual(audit.main(), 0)
                self.assertEqual(audit.main(), 0)
            reports = list(Path(directory).glob('gallery-trash-release-audit-*.txt'))
            self.assertEqual(len(reports), 2)
            self.assertEqual(old.read_text(), 'previous private report')
            for report in reports:
                self.assertEqual(report.stat().st_mode & 0o777, 0o600)

    def test_snapshot_inventory_exposes_no_names_and_no_recovery_claim(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '#snapshot' / 'PRIVATE_SNAPSHOT_NAME').mkdir(parents=True)
            evidence = audit.snapshot_evidence(root)
            self.assertNotIn('PRIVATE_SNAPSHOT_NAME', json.dumps(evidence))
            self.assertEqual(evidence[0]['visibleDirectories'], 1)
            self.assertEqual(evidence[0]['recoverability'], 'NOT_VERIFIED')
            self.assertEqual(evidence[1]['status'], 'NOT_VISIBLE_NOT_PROOF_OF_ABSENCE')


@unittest.skipUnless(os.environ.get('GALLERY_DISPOSABLE_AUDIT_TESTS') == '1', 'requires explicit disposable local Docker fixtures')
class DisposableRuntimeTests(unittest.TestCase):
    @classmethod
    def docker(cls, *args, input=None):
        env = os.environ.copy()
        for name in ('DOCKER_HOST', 'DOCKER_CONTEXT', 'DOCKER_TLS', 'DOCKER_TLS_VERIFY', 'DOCKER_CERT_PATH'):
            env.pop(name, None)
        return subprocess.run(['docker', '--host=unix:///var/run/docker.sock', *args], input=input,
                              text=True, capture_output=True, check=True, timeout=45, env=env).stdout

    @classmethod
    def setUpClass(cls):
        cls.names = []
        cls.files = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.files.cleanup)
        cls.addClassCleanup(cls.cleanup_containers)
        prefix = 'gallery-audit-test-' + uuid.uuid4().hex[:12]
        for suffix, image, port, args in (
            ('pg', 'postgres:16-alpine', 5432, ['-e', 'POSTGRES_PASSWORD=disposable-audit-only']),
            ('redis', 'redis:7-alpine', 6379, []),
        ):
            name = prefix + '-' + suffix
            cls.docker('run', '--pull=never', '-d', '--name', name, '-p', '127.0.0.1::' + str(port), *args, image)
            cls.names.append(name)
            mapping = json.loads(cls.docker('inspect', name))[0]['NetworkSettings']['Ports'][str(port)+'/tcp'][0]
            setattr(cls, suffix + '_port', mapping['HostPort'])
        # Bounded startup readiness inside our own disposable PG, not CI polling
        # or any production queue/API. Initdb's temporary server has no TCP port.
        cls.docker('exec', cls.names[0], 'sh', '-c',
                   'for attempt in 1 2 3 4 5 6 7 8 9 10; do '
                   'pg_isready -h 127.0.0.1 -U postgres -d postgres >/dev/null 2>&1 && exit 0; '
                   'sleep 1; done; exit 1')
        cls.base_env = {**os.environ, 'DB_HOSTNAME':'127.0.0.1', 'DB_PORT':cls.pg_port,
                        'DB_USERNAME':'postgres', 'DB_PASSWORD':'disposable-audit-only', 'DB_DATABASE_NAME':'postgres',
                        'REDIS_HOSTNAME':'127.0.0.1', 'REDIS_PORT':cls.redis_port,
                        'IMMICH_MEDIA_LOCATION':cls.files.name}
        for key in ('DB_URL','REDIS_URL','REDIS_SOCKET','REDIS_PASSWORD','REDIS_USERNAME','IMMICH_CONFIG_FILE'):
            cls.base_env.pop(key, None)
        backup = Path(cls.files.name) / 'backups'
        backup.mkdir()
        (backup / 'immich-db-backup-fixture.sql.gz').write_bytes(b'not a recoverability test')
        (backup / 'immich-db-backup-failed.sql.gz.tmp').write_bytes(b'incomplete')
        # Only fixture preparation writes SQL/Redis; the actual audit is SELECT-only.
        cls.node(r'''
const sql=require('postgres')({host:'127.0.0.1',port:Number(process.env.DB_PORT),username:'postgres',
  password:'disposable-audit-only',database:'postgres',connect_timeout:5});
const Redis=require('ioredis');const redis=new Redis({host:'127.0.0.1',port:Number(process.env.REDIS_PORT)});
try {
  await sql`CREATE TABLE system_metadata(key text,value jsonb)`;
  await sql`CREATE TABLE kysely_migrations(name text)`;
  await sql`INSERT INTO kysely_migrations VALUES ('fixture-migration')`;
  await sql`CREATE TABLE library(id uuid,"deletedAt" timestamptz)`;
  await sql`CREATE TABLE asset(id uuid,status text,"libraryId" uuid,"isOffline" boolean,
    "deletedAt" timestamptz,"originalPath" text)`;
  await sql`CREATE TABLE asset_file("assetId" uuid,path text)`;
  const live='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',gone='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
  await sql`INSERT INTO library VALUES (${live},NULL),(${gone},CURRENT_TIMESTAMP)`;
  const id=n=>'00000000-0000-0000-0000-'+String(n).padStart(12,'0');
  for(const [n,status,lib,offline,marked] of [[1,'active',live,true,true],
    [2,'active',gone,false,true],[3,'active',live,false,true],[4,'active',null,false,true],
    [5,'trashed',live,false,true],[6,'active',null,false,false]]) {
    await sql`INSERT INTO asset VALUES (${id(n)},${status},${lib},${offline},
      ${marked?new Date(Date.now()-40*86400000):null},${'/fixture-nas/PRIVATE_MEDIA_'+n})`;
  }
  await sql`INSERT INTO asset_file VALUES (${id(5)},'/fixture-nas/PRIVATE_DERIVED')`;
  const prefix='immich_bull:backgroundTask:';
  const jobs=[['AssetDelete',{id:id(1),deleteOnDisk:true},'wait'],
    ['AssetDelete',{id:id(3),deleteOnDisk:true},'active'],
    ['AssetDelete',{id:id(5),deleteOnDisk:true},'delayed'],
    ['AssetDelete',{id:id(6),deleteOnDisk:true,trashedBefore:new Date().toISOString()},'wait'],
    ['FileDelete',{files:['/fixture-nas/PRIVATE_MEDIA_3']},'wait'],
    ['FileDelete',{files:['/fixture-nas/PRIVATE_DERIVED']},'failed'],
    ['FileDelete',{files:['/fixture-nas/PRIVATE_ORPHAN']},'prioritized']];
  for(const [index,[name,payload,state]] of jobs.entries()) {
    const jobId='PRIVATE_JOB_'+index;
    await redis.hset(prefix+jobId,{name,data:JSON.stringify(payload),timestamp:Date.now()-100*86400000});
    if(['wait','active'].includes(state)) await redis.rpush(prefix+state,jobId);
    else await redis.zadd(prefix+state,index,jobId);
  }
  console.log('fixture ready');
} finally {redis.disconnect();await sql.end();}
''')

    @classmethod
    def cleanup_containers(cls):
        for name in reversed(cls.names):
            cls.docker('rm', '-f', '-v', name)

    @classmethod
    def node(cls, program, env=None):
        prelude = "import {createRequire} from 'node:module';const require=createRequire(" + json.dumps(str(ROOT/'server/package.json')) + ');\n'
        result = subprocess.run(['node', '--input-type=module'], input=prelude+program,
                                text=True, capture_output=True, timeout=60, env=env or cls.base_env)
        if result.returncode:
            (Path(cls.files.name)/'fixture-stderr.txt').write_text(result.stderr)
            # Synthetic fixture only; classify without printing even its password.
            codes = [code for code in ('ECONNREFUSED','ERR_MODULE_NOT_FOUND','MODULE_NOT_FOUND','SyntaxError','PostgresError') if code in result.stderr]
            raise AssertionError('Isolated fixture failure: ' + ','.join(codes or ['unclassified']))
        return result.stdout

    @classmethod
    def run_audit(cls, program=None, env=None):
        code=(program or audit.NODE_AUDIT).replace('__MOUNT_ROOTS__', '["/fixture-nas"]')
        code=code.replace('/usr/src/app/server', str(ROOT/'server'))
        # Actual installed ConfigRepository/postgres/ioredis, not emulated clients.
        result=subprocess.run(['node','--input-type=module'],input=code,text=True,capture_output=True,
                              timeout=60,env=env or cls.base_env)
        if result.returncode:
            raise AssertionError('Isolated audit runtime failed; no production diagnostic executed')
        return json.loads(result.stdout)

    def test_actual_plural_migrations_and_full_inventory(self):
        result=self.run_audit()
        self.assertEqual(result['errors'], [])
        self.assertEqual(result['postgres']['readOnly'], 'on')
        self.assertEqual(result['migrations'][0]['count'], '1')
        self.assertEqual(result['activeWithDeletedAt']['total'], 4)
        groups=result['activeWithDeletedAt']['groups']
        self.assertEqual(sum(int(g['count']) for g in groups if g['classification'].endswith('REVIEW_STOP')), 2)
        jobs=result['deletionJobs']
        self.assertTrue(jobs['inventoryComplete'])
        self.assertEqual(jobs['legacyAssetDelete'], 3)
        self.assertEqual(jobs['fileDelete'], 3)
        self.assertEqual(jobs['fileReferences'], {'original:active':1,'asset_file:trashed':1})
        self.assertEqual(result['backupFiles']['count'], 1)
        self.assertEqual(result['backupFiles']['incompleteTempFiles'], 1)
        self.assertEqual(result['backupFiles']['restoreValidated'], 'UNKNOWN')
        for private in ('PRIVATE_MEDIA','PRIVATE_JOB','PRIVATE_DERIVED',self.files.name,'disposable-audit-only'):
            self.assertNotIn(private, json.dumps(result))

    def test_old_table_typo_is_sqlstate_42p01_without_hiding_other_sections(self):
        result=self.run_audit(audit.NODE_AUDIT.replace('FROM kysely_migrations', 'FROM kysely_migration'))
        self.assertIn('MIGRATIONS:42P01', result['errors'])
        self.assertEqual(result['deletionJobs']['fileDelete'], 3)
        self.assertEqual(result['sections']['BACKUP_INVENTORY'], 'PASS')

    def test_file_reference_failure_does_not_claim_files_unreferenced(self):
        result=self.run_audit(audit.NODE_AUDIT.replace('FROM asset_file f', 'FROM PRIVATE_MISSING_TABLE f'))
        self.assertIn('FILE_JOB_REFERENCES:42P01', result['errors'])
        self.assertFalse(result['deletionJobs']['inventoryComplete'])
        self.assertTrue(all(x['risk']=='FILE_REFERENCES_UNKNOWN_STOP' for x in result['deletionJobs']['fileDeleteExamples']))
        self.assertNotIn('PRIVATE_MISSING_TABLE', json.dumps(result))
        self.assertEqual(result['sections']['BACKUP_INVENTORY'], 'PASS')

    def test_redis_failure_preserves_backup_and_asset_classification(self):
        result=self.run_audit(env={**self.base_env,'REDIS_PORT':'1'})
        self.assertTrue(any(x.startswith('DELETION_QUEUES:') for x in result['errors']))
        self.assertNotIn('deletionJobs', result)
        self.assertEqual(result['activeWithDeletedAt']['total'], 4)
        self.assertEqual(result['backupFiles']['count'], 1)

    def test_missing_backup_directory_does_not_claim_a_verified_empty_inventory(self):
        result=self.run_audit(env={**self.base_env,'IMMICH_MEDIA_LOCATION':self.files.name+'/absent'})
        self.assertIn('BACKUP_INVENTORY:ENOENT',result['errors'])
        self.assertEqual(result['backupFiles']['status'],'UNKNOWN_NOT_INVENTORIED')
        self.assertTrue(result['deletionJobs']['inventoryComplete'])

    def test_audit_leaves_database_rows_and_redis_jobs_unchanged(self):
        snapshot=r'''
const sql=require('postgres')({host:'127.0.0.1',port:Number(process.env.DB_PORT),username:'postgres',
 password:'disposable-audit-only',database:'postgres'});
const Redis=require('ioredis');const r=new Redis({host:'127.0.0.1',port:Number(process.env.REDIS_PORT)});
try {const keys=(await r.keys('immich_bull:backgroundTask:*')).sort(), values=[];
 for(const key of keys) values.push([key,(await r.dumpBuffer(key)).toString('hex')]);
 console.log(JSON.stringify({assets:await sql`SELECT * FROM asset ORDER BY id`,values}));
} finally {r.disconnect();await sql.end();}
'''
        before=self.node(snapshot)
        self.run_audit()
        self.assertEqual(self.node(snapshot), before)


if __name__ == '__main__':
    unittest.main()
