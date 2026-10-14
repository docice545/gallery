"""Opt-in PostgreSQL 14 query regression on synthetic tables only.

Requires a verified disposable local Docker daemon and the cached immutable PG
image. No production connections, host mounts, public ports or image pulls.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build11_installation_smoke as lab

DOCKER = ['docker', '--host=unix:///var/run/docker.sock']
IMAGE = 'sha256:178719aeb38df6f0ce8edc1d8320008379fcf04eb3444e76419cc98d9861e331'
OWNER = '11111111-2222-3333-4444-555555555555'
OTHER = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
ALBUM = '22222222-2222-3333-4444-555555555555'
ASSET = '33333333-2222-3333-4444-555555555555'


@unittest.skipUnless(os.environ.get('GALLERY_TEST_LOCAL_DOCKER') == 'YES',
                     'explicit disposable Docker opt-in required')
class UpstreamAlbumSnapshot(unittest.TestCase):
    @classmethod
    def command(cls, args, *, input=None, check=True):
        env = {key: value for key, value in os.environ.items() if key not in (
            'DOCKER_HOST', 'DOCKER_CONTEXT', 'DOCKER_TLS', 'DOCKER_TLS_VERIFY', 'DOCKER_CERT_PATH', 'DOCKER_API_VERSION')}
        result = subprocess.run(args, input=input, capture_output=True, text=True, env=env, timeout=60)
        if check and result.returncode:
            raise AssertionError('Synthetic PostgreSQL fixture command failed; private output omitted')
        return result

    @classmethod
    def setUpClass(cls):
        expected = os.environ.get('GALLERY_TEST_DOCKER_NAME')
        if not expected or expected.lower() in ('hp', 'production'):
            raise AssertionError('An explicitly verified disposable Docker name is required')
        if cls.command([*DOCKER, 'info', '--format', '{{.Name}}']).stdout.strip() != expected:
            raise AssertionError('Disposable Docker identity mismatch')
        image = json.loads(cls.command([*DOCKER, 'image', 'inspect', IMAGE]).stdout)
        if len(image) != 1 or image[0].get('Id') != IMAGE or image[0].get('Os') != 'linux' or \
                image[0].get('Architecture') != 'amd64':
            raise AssertionError('Exact cached PostgreSQL fixture image required')
        cls.marker = 'gallery-build11-snapshot-test-' + uuid.uuid4().hex
        cls.container = cls.command([*DOCKER, 'run', '-d', '--name', cls.marker,
            '--label', 'gallery.build11.disposable-snapshot=' + cls.marker, '--network', 'none',
            '--memory', '512m', '--cpus', '1', '--pids-limit', '128', '--shm-size', '128m',
            '--security-opt', 'no-new-privileges', '-e', 'POSTGRES_PASSWORD=synthetic-test-only', IMAGE]).stdout.strip()
        cls.addClassCleanup(cls.cleanup)
        for attempt in range(30):
            process = cls.command([*DOCKER, 'exec', cls.container, 'cat', '/proc/1/comm'], check=False)
            ready = cls.command([*DOCKER, 'exec', cls.container, 'pg_isready', '-U', 'postgres'], check=False)
            if process.returncode == 0 and process.stdout.strip() == 'postgres' and ready.returncode == 0:
                break
            time.sleep(0.5)
        else:
            raise AssertionError('Disposable PostgreSQL did not become ready within bounded startup')
        cls.query('''CREATE TABLE public."user" (id uuid PRIMARY KEY,email text,status text);
          CREATE TABLE asset (id uuid PRIMARY KEY,"ownerId" uuid,"libraryId" uuid,status text,
            "deletedAt" timestamptz,"isOffline" boolean,"fileCreatedAt" timestamptz,"localDateTime" timestamptz);
          CREATE TABLE album (id uuid PRIMARY KEY,"albumName" text);
          CREATE TABLE album_user ("albumId" uuid,"userId" uuid,role text,PRIMARY KEY("albumId","userId"));
          CREATE UNIQUE INDEX album_user_unique_owner ON album_user("albumId") WHERE role='owner';
          CREATE TABLE album_asset ("albumId" uuid,"assetId" uuid,PRIMARY KEY("albumId","assetId"));''')

    @classmethod
    def cleanup(cls):
        rows = json.loads(cls.command([*DOCKER, 'inspect', cls.container]).stdout)
        if len(rows) != 1 or rows[0].get('Name') != '/' + cls.marker or \
                rows[0].get('Config', {}).get('Labels', {}).get('gallery.build11.disposable-snapshot') != cls.marker:
            raise AssertionError('Refusing cleanup of unverified fixture')
        cls.command([*DOCKER, 'rm', '-f', '--volumes', cls.container])

    @classmethod
    def query(cls, query, *, check=True):
        return cls.command([*DOCKER, 'exec', '-i', cls.container, 'psql', '-X', '--quiet', '-A', '-t',
            '--set', 'ON_ERROR_STOP=1', '--set', 'VERBOSITY=sqlstate', '-h', '/var/run/postgresql',
            '-U', 'postgres', '-d', 'postgres'], input=query, check=check)

    def setUp(self):
        self.query('TRUNCATE album_asset,album_user,album,asset,public."user";'
            f'''INSERT INTO public."user" VALUES ('{OWNER}','owner@example.invalid','active'),
              ('{OTHER}','other@example.invalid','active');
            INSERT INTO album VALUES ('{ALBUM}','Synthetic preserved album');
            INSERT INTO album_user VALUES ('{ALBUM}','{OWNER}','owner'),('{ALBUM}','{OTHER}','viewer');
            INSERT INTO asset VALUES ('{ASSET}','{OWNER}',NULL,'active',NULL,false,
              '2024-01-02T03:04:05Z','2024-01-02T03:04:05Z');
            INSERT INTO album_asset VALUES ('{ALBUM}','{ASSET}');''')

    def snapshot(self):
        return json.loads(self.query(lab.DATABASE_SNAPSHOT_SQL).stdout)

    def test_current_upstream_schema_without_album_owner_column_is_queryable(self):
        result = self.snapshot()
        self.assertEqual(result['albums'], [{'id': ALBUM, 'owner': OWNER, 'name': 'Synthetic preserved album'}])
        self.assertEqual(result['membership'], [{'album': ALBUM, 'asset': ASSET}])
        self.assertEqual(result['assets'][0]['owner'], OWNER)

    def test_all_owner_and_shared_roles_are_preserved_in_snapshot(self):
        self.assertEqual(self.snapshot()['albumUsers'], [
            {'album': ALBUM, 'user': OWNER, 'role': 'owner'},
            {'album': ALBUM, 'user': OTHER, 'role': 'viewer'}])

    def test_changed_sharing_role_is_detected_without_changing_owner(self):
        before = self.snapshot()
        self.query(f'''UPDATE album_user SET role='editor' WHERE "albumId"='{ALBUM}' AND "userId"='{OTHER}';''')
        after = self.snapshot()
        self.assertNotEqual(before, after)
        self.assertEqual(before['albums'], after['albums'])
        self.assertEqual(after['albumUsers'][1]['role'], 'editor')

    def test_original_broken_album_query_is_reproduced_as_undefined_column(self):
        failure = self.query('SELECT "ownerId" FROM album;', check=False)
        self.assertNotEqual(failure.returncode, 0)
        self.assertIn('42703', failure.stderr)


if __name__ == '__main__':
    unittest.main()
