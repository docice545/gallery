#!/usr/bin/env python3
"""Explicit build-9 profile for existing tooling. No credentials or production access."""
import hashlib
import json
from pathlib import Path
import re
import time

MIGRATION = '1793600000000-AddAuthorizedAssetDeletion'
BASE = '42790b06edc21438811e56e40c431eee37c24894'


def need(value, code):
    if not value:
        raise ValueError(code)


def digest(path):
    with path.open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()


def validate(profile):
    need(profile.get('schemaVersion') == 2 and profile.get('productionBase') == BASE,
         'CANDIDATE_PROFILE_VERSION_OR_BASE')
    need(re.fullmatch('[0-9a-f]{40}', profile.get('sourceCommit', '')), 'CANDIDATE_SOURCE_SHA')
    need((profile.get('serverVersion'), profile.get('mobileVersion'), profile.get('mobileBuild')) ==
         ('5.7.2', '5.7.2', 9), 'CANDIDATE_VERSION')
    backend = profile.get('backend', {})
    need(backend.get('sourceCommit') == profile['sourceCommit'] and backend.get('serverVersion') == '5.7.2' and
         backend.get('mobileVersion') == '5.7.2' and backend.get('mobileBuild') == 9 and
         backend.get('schemaDelta') == 'ADDITIVE_AUTHORIZED_DELETION' and
         backend.get('migrationsAdded') == [MIGRATION] and backend.get('platform') == 'linux/amd64' and
         backend.get('imageTag') == 'gallery-server:trash-' + profile['sourceCommit'][:12] and
         backend.get('isolatedSmoke') == 'PASS: fresh PG migrations + HTTP Trash/Restore/permanent deletion + read-only audit',
         'CANDIDATE_BACKEND_CONTRACT')
    need(re.fullmatch('sha256:[0-9a-f]{64}', backend.get('imageId', '')) and
         re.fullmatch('[0-9a-f]{64}', backend.get('archiveSHA256', '')), 'CANDIDATE_IMAGE_DIGEST')
    for platform in ('android', 'ios'):
        item = profile.get(platform, {})
        need(item.get('sourceCommit') == profile['sourceCommit'] and type(item.get('run')) is int and
             item['run'] > 0 and type(item.get('artifactId')) is int and item['artifactId'] > 0 and
             re.fullmatch('[0-9a-f]{64}', item.get('sha256', '')),
             'CANDIDATE_MOBILE_PROVENANCE')
    need(re.fullmatch('[0-9a-f]{64}', profile['android'].get('certificateSHA256', '')),
         'CANDIDATE_ANDROID_CERTIFICATE')
    need(type(profile.get('backendRun')) is int and profile['backendRun'] > 0, 'CANDIDATE_BACKEND_RUN')
    need(type(profile.get('backendArtifactId')) is int and profile['backendArtifactId'] > 0,
         'CANDIDATE_BACKEND_ARTIFACT')
    return profile


def load(path, expected):
    need(path is not None and expected is not None and re.fullmatch('[0-9a-f]{64}', expected),
         'EXPLICIT_CANDIDATE_PROFILE_AND_SHA256_REQUIRED')
    path = Path(path)
    need(path.is_file() and not path.is_symlink() and digest(path) == expected, 'CANDIDATE_PROFILE_CHANGED')
    need(path.stat().st_size <= 1024 * 1024, 'CANDIDATE_PROFILE_SIZE')
    return validate(json.loads(path.read_text()))


def configure(tool, profile):
    """Bind explicit immutable artifacts; frozen build-8 defaults remain untouched."""
    validate(profile)
    tool.CANDIDATE_PROFILE = profile
    tool.SOURCE = profile['sourceCommit']
    tool.SOURCE_REF = 'v5.7.2'
    tool.IMAGE = profile['backend']['imageId']
    tool.TAG = profile['backend']['imageTag']
    tool.ARCHIVE_SHA = profile['backend']['archiveSHA256']

    def verify_artifact(directory):
        manifest = json.loads((directory / 'manifest.json').read_text())
        need(manifest == profile['backend'], 'CANDIDATE_MANIFEST_CHANGED')
        archive = directory / 'gallery-server-linux-amd64.tar.gz'
        need(archive.is_file() and not archive.is_symlink() and digest(archive) == tool.ARCHIVE_SHA,
             'CANDIDATE_ARCHIVE_CHANGED')
        return archive

    tool.verify_artifact = verify_artifact

    def migration_match(image):
        need(image == tool.IMAGE, 'CANDIDATE_MIGRATION_IMAGE_CHANGED')
        live = sorted(json.loads(tool.docker('exec', '-i', tool.SERVER, 'node', '--input-type=module',
                                            input=tool.NODE_MIGRATIONS)))
        program = "const fs=require('fs');console.log(JSON.stringify([...new Set(['migrations','migrations-gallery'].flatMap(d=>fs.readdirSync('/usr/src/app/server/dist/schema/'+d).filter(f=>f.endsWith('.js')).map(f=>f.slice(0,-3))))].sort()));"
        built = sorted(json.loads(tool.docker('run', '--rm', '--network', 'none', '--read-only',
                                             '--entrypoint', 'node', image, '-e', program)))
        need(live and built and (built == live or built == sorted([*live, MIGRATION])),
             'ONLY_EXACT_ADDITIVE_MIGRATION_ALLOWED')
        # Existing deployment compares this value again after startup. Returning
        # the compiled target on both sides permits exactly the approved addition.
        return built

    tool.migrations_match = migration_match
    previous_health = tool.health

    def health(base, source=None, timeout=90):
        if source is None:
            return previous_health(base, None, timeout)
        need(source == tool.SOURCE, 'CANDIDATE_HEALTH_SOURCE')
        deadline = time.monotonic() + timeout
        while True:
            item = tool.inspect(tool.SERVER)
            env = dict(v.split('=', 1) for v in item['Config'].get('Env', []) if '=' in v)
            healthy = (item['Image'] == tool.IMAGE and item['State'].get('Health', {}).get('Status') == 'healthy' and
                       env.get('IMMICH_SOURCE_COMMIT') == tool.SOURCE)
            if healthy:
                need(tool.api(base, None, '/server/ping') == {'res': 'pong'} and
                     tool.api(base, None, '/server/version') == {'major': 5, 'minor': 7, 'patch': 2, 'prerelease': None},
                     'CANDIDATE_API_HEALTH_OR_VERSION')
                print('PASS exact candidate image/source/version/API health')
                return
            need(time.monotonic() < deadline, 'CANDIDATE_HEALTH_TIMEOUT')
            time.sleep(2)
    tool.health = health
