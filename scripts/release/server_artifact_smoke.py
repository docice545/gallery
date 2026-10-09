#!/usr/bin/env python3
"""Fresh disposable CI database/storage only. Never accepts an HP/remote API URL."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import time
import urllib.request

POSTGRES = 'ghcr.io/immich-app/postgres:14-vectorchord0.4.3@sha256:dbf18b3ffea4a81434c65b71e20d27203baf903a0275f4341e4c16dfd901fd67'


def docker(*args, input=None):
    result = subprocess.run(['docker', *args], input=input, text=True, capture_output=True, timeout=180)
    if result.returncode:
        raise RuntimeError('Docker fixture operation failed; no credentials printed')
    return result.stdout.strip()


def main():
    if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('GALLERY_ISOLATED_CI') != '1':
        print('FAIL only runs on an explicitly isolated GitHub runner; no containers touched')
        return 1
    sha, output = sys.argv[1:]
    directory = Path(output)
    manifest = json.loads((directory / 'manifest.json').read_text())
    if manifest['sourceCommit'] != sha:
        raise ValueError('Artifact revision differs')
    names = []
    network = None
    stage = 'create isolated fixtures'
    try:
        prefix = 'gallery-trash-ci-' + secrets.token_hex(6)
        network = docker('network', 'create', prefix)
        db, redis, server = (prefix + '-' + name for name in ('pg', 'redis', 'server'))
        for name, image, extra in [
            (db, POSTGRES, ['-e', 'POSTGRES_PASSWORD=disposable-ci-password', '-e', 'POSTGRES_DB=immich']),
            (redis, 'redis:7.4.6', []),
            (server, manifest['imageTag'], ['-e', f'DB_HOSTNAME={db}', '-e', 'DB_PASSWORD=disposable-ci-password',
                '-e', f'REDIS_HOSTNAME={redis}', '-e', 'IMMICH_WORKERS_EXCLUDE=microservices',
                '-p', '127.0.0.1::2283']),
        ]:
            # -v cleanup affects anonymous volumes created by THIS invocation only.
            names.append(name)
            postgres_command = ['postgres', '-c', 'shared_preload_libraries=vchord.so',
                '-c', 'config_file=/var/lib/postgresql/data/postgresql.conf'] if name == db else []
            docker('run', '-d', '--name', name, '--network', network, *extra, image, *postgres_command)
        mapping = json.loads(docker('inspect', server))[0]['NetworkSettings']['Ports']['2283/tcp'][0]
        base = 'http://127.0.0.1:' + mapping['HostPort'] + '/api'
        token = None

        def request(path, method='GET', data=None, content_type='application/json', raw=False):
            headers = {'Content-Type': content_type}
            if token:
                headers['Authorization'] = 'Bearer ' + token
            body = data if isinstance(data, bytes) else None if data is None else json.dumps(data).encode()
            with urllib.request.urlopen(urllib.request.Request(base + path, body, headers, method=method), timeout=10) as response:
                body = response.read()
                return body if raw else json.loads(body) if body else None

        stage = 'fresh database migrations/API startup'
        deadline = time.monotonic() + 180
        while True:
            try:
                assert request('/server/ping') == {'res': 'pong'}
                break
            except Exception:
                if time.monotonic() > deadline:
                    raise RuntimeError('API did not become healthy') from None
                time.sleep(2)
        assert request('/server/version') == {'major': 5, 'minor': 7, 'patch': 1}
        print('PASS compiled image/fresh PostgreSQL migrations/API version 5.7.1')
        stage = 'synthetic upload/Trash/Restore'
        credentials = {'email': 'trash-ci@example.invalid', 'password': secrets.token_urlsafe(24)}
        request('/auth/admin-sign-up', 'POST', {**credentials, 'name': 'Disposable CI'})
        token = request('/auth/login', 'POST', credentials)['accessToken']
        # Synthetic 1x1 PNG, never real media. No image processing workers required.
        media = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j/1cAAAAASUVORK5CYII=')
        boundary = 'gallery-ci-boundary'
        parts = []
        for key in ('fileCreatedAt', 'fileModifiedAt'):
            parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"\r\n\r\n2024-05-06T10:20:30.000Z\r\n'.encode())
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="assetData"; filename="fixture.png"\r\nContent-Type: image/png\r\n\r\n'.encode() + media + b'\r\n')
        parts.append(f'--{boundary}--\r\n'.encode())
        asset_id = request('/assets', 'POST', b''.join(parts), 'multipart/form-data; boundary=' + boundary)['id']
        original = request(f'/assets/{asset_id}/original', raw=True)
        assert original == media
        before = request('/assets/' + asset_id)
        request('/assets', 'DELETE', {'ids': [asset_id], 'force': False})
        assert request('/assets/' + asset_id)['isTrashed'] is True
        assert request(f'/assets/{asset_id}/original', raw=True) == original
        assert request('/trash/restore/assets', 'POST', {'ids': [asset_id]})['count'] == 1
        restored = request('/assets/' + asset_id)
        assert restored['isTrashed'] is False
        assert restored['fileCreatedAt'] == before['fileCreatedAt']
        assert restored['localDateTime'] == before['localDateTime']
        assert request('/trash/restore/assets', 'POST', {'ids': [asset_id]})['count'] == 0
        assert request(f'/assets/{asset_id}/original', raw=True) == original
        print('PASS real HTTP upload/Trash/Restore/idempotency/date/original-byte preservation')
        stage = 'read-only diagnostic runtime'
        spec = importlib.util.spec_from_file_location('audit', Path(__file__).parents[1] / 'diagnostics/hp_trash_release_audit.py')
        audit = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(audit)
        result = json.loads(docker('exec', '-i', server, 'node', '--input-type=module', input=audit.NODE_AUDIT.replace('__MOUNT_ROOTS__', '[]')))
        assert not result['errors'], result['errors']
        assert result['postgres']['readOnly'] == 'on'
        assert result['runningVersion'] == '5.7.1'
        print('PASS diagnostic SELECT/read-only Redis path on the compiled image')
        manifest['isolatedSmoke'] = 'PASS: fresh PG migrations + HTTP Trash/Restore + read-only audit'
        (directory / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        return 0
    except Exception as error:
        print('FAIL isolated smoke stage:', stage, '; category:', type(error).__name__)
        # Runner contains only synthetic data. Keep bounded bootstrap logs for diagnosis.
        if names:
            (directory / 'isolated-smoke.log').write_text(docker('logs', '--tail', '100', names[-1]))
        return 1
    finally:
        for name in reversed(names):
            try:
                docker('rm', '-f', '-v', name)
            except Exception:
                pass
        if network:
            docker('network', 'rm', network)


if __name__ == '__main__':
    raise SystemExit(main())
