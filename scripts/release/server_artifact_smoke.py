#!/usr/bin/env python3
"""Fresh disposable CI database/storage only. Never accepts an HP/remote API URL."""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import time
import urllib.request
import urllib.error

POSTGRES = 'ghcr.io/immich-app/postgres:14-vectorchord0.4.3@sha256:dbf18b3ffea4a81434c65b71e20d27203baf903a0275f4341e4c16dfd901fd67'


def docker_failure_reason(stderr):
    """Classify CLI failures without emitting arbitrary credential/path text."""
    value = stderr.lower()
    for category, phrases in (
        ('NO_SPACE', ('no space left on device', 'disk quota exceeded')),
        ('REGISTRY_RATE_LIMIT', ('toomanyrequests', 'pull rate limit')),
        ('IMAGE_UNAVAILABLE', ('manifest unknown', 'manifest not found', 'not found: manifest')),
        ('REGISTRY_ACCESS_DENIED', ('pull access denied', 'unauthorized', 'denied:')),
        ('REGISTRY_NETWORK', ('tls handshake timeout', 'i/o timeout', 'context deadline exceeded', 'connection refused')),
        ('CONTAINER_NAME_CONFLICT', ('container name', 'already in use')),
        ('PORT_BIND_FAILED', ('port is already allocated', 'address already in use')),
        ('INVALID_IMAGE_REFERENCE', ('invalid reference format',)),
        ('DAEMON_UNAVAILABLE', ('cannot connect to the docker daemon',)),
    ):
        if any(phrase in value for phrase in phrases):
            return category
    return 'UNCLASSIFIED_CLI_FAILURE'


def docker(*args, input=None):
    result = subprocess.run(['docker', *args], input=input, text=True, capture_output=True, timeout=180)
    if result.returncode:
        raise RuntimeError(f'Docker {args[0]} failed: {docker_failure_reason(result.stderr)} (exit {result.returncode}); private details omitted')
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
        print('CI free runner disk bytes:', shutil.disk_usage(directory).free, flush=True)
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
            stage = 'create isolated fixture ' + ('postgres' if name == db else 'redis' if name == redis else 'server')
            postgres_command = ['postgres', '-c', 'shared_preload_libraries=vchord.so',
                '-c', 'config_file=/var/lib/postgresql/data/postgresql.conf'] if name == db else []
            docker('run', '-d', '--name', name, '--network', network, *extra, image, *postgres_command)
            # Only a successfully created fixture is ours to remove/read logs.
            names.append(name)
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
        assert request('/server/version') == {'major': 5, 'minor': 7, 'patch': 2, 'prerelease': None}
        print('PASS compiled image/fresh PostgreSQL migrations/API version 5.7.2')
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
        stage = 'explicit library authorization/permanent deletion/durable receipt'
        request('/assets', 'DELETE', {'ids': [asset_id], 'force': False})
        blocked = request('/assets/permanent-deletion', 'POST', {'ids': [asset_id], 'confirmed': True})
        assert blocked == [{'id': asset_id, 'state': 'blocked', 'code': 'LIBRARY_DELETION_NOT_AUTHORIZED'}]
        assert request(f'/assets/{asset_id}/original', raw=True) == media
        owner = request('/users/me')['id']
        request('/assets/deletion-policy', 'PUT', {'ownerId': owner, 'scope': 'managed', 'enabled': True,
            'roots': ['/data/upload/' + owner], 'recoveryProof': hashlib.sha256(media).hexdigest(),
            'verifiedExclusiveRoots': True})
        result = request('/assets/permanent-deletion', 'POST', {'ids': [asset_id], 'confirmed': True})
        assert result == [{'id': asset_id, 'state': 'complete'}]
        assert request('/assets/' + asset_id + '/deletion-status') == result[0]
        assert request('/trash/restore/assets', 'POST', {'ids': [asset_id]})['count'] == 0
        try:
            request(f'/assets/{asset_id}/original', raw=True)
            raise AssertionError('Deleted fixture still accessible')
        except urllib.error.HTTPError as error:
            assert error.code in (400, 404)
        try:
            request('/assets', 'POST', b''.join(parts), 'multipart/form-data; boundary=' + boundary)
            raise AssertionError('Permanent identity was reimported')
        except urllib.error.HTTPError as error:
            assert error.code == 410
        print('PASS real HTTP default-deny/explicit library opt-in/permanent receipt/reimport suppression')
        stage = 'read-only diagnostic runtime'
        spec = importlib.util.spec_from_file_location('audit', Path(__file__).parents[1] / 'diagnostics/hp_trash_release_audit.py')
        audit = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(audit)
        result = json.loads(docker('exec', '-i', server, 'node', '--input-type=module', input=audit.NODE_AUDIT.replace('__MOUNT_ROOTS__', '[]')))
        if result['errors']:
            # The audit emits only fixed stage names and allowlisted error codes.
            raise RuntimeError('Read-only diagnostic incomplete: ' + ', '.join(result['errors']))
        assert result['postgres']['readOnly'] == 'on'
        assert result['runningVersion'] == '5.7.2'
        print('PASS diagnostic SELECT/read-only Redis path on the compiled image')
        manifest['isolatedSmoke'] = 'PASS: fresh PG migrations + HTTP Trash/Restore/permanent deletion + read-only audit'
        (directory / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        # Public receipt allows verification without downloading the large image.
        print('PASS backend receipt:', json.dumps({key: manifest[key] for key in (
            'sourceCommit', 'toolingCommit', 'serverVersion', 'mobileVersion', 'mobileBuild',
            'imageTag', 'imageId', 'archiveSHA256', 'isolatedSmoke')}, sort_keys=True))
        return 0
    except Exception as error:
        print('FAIL isolated smoke stage:', stage, '; category:', type(error).__name__)
        if isinstance(error, RuntimeError):
            print(str(error))  # This harness creates only sanitized RuntimeErrors.
        # Runner contains only synthetic data. Keep bounded bootstrap logs for diagnosis.
        if names:
            try:
                (directory / 'isolated-smoke.log').write_text(docker('logs', '--tail', '100', names[-1]))
            except RuntimeError:
                print('Diagnostic fixture logs unavailable; primary failure preserved')
        return 1
    finally:
        for name in reversed(names):
            try:
                docker('rm', '-f', '-v', name)
            except Exception:
                pass
        if network:
            try:
                docker('network', 'rm', network)
            except RuntimeError:
                print('WARNING owned CI network cleanup failed; no unrelated network touched')


if __name__ == '__main__':
    raise SystemExit(main())
