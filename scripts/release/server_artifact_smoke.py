#!/usr/bin/env python3
"""Fresh disposable CI database/storage only. Never accepts an HP/remote API URL."""
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import json
import os
import re
from pathlib import Path
import secrets
import struct
import shutil
import subprocess
import sys
import tempfile
import time
import traceback
import urllib.request
import urllib.error
import zlib
from types import SimpleNamespace

POSTGRES = 'ghcr.io/immich-app/postgres:14-vectorchord0.4.3@sha256:dbf18b3ffea4a81434c65b71e20d27203baf903a0275f4341e4c16dfd901fd67'
ROOT = Path(__file__).resolve().parents[2]
LAB_MARKER = 'SYNTHETIC_DISPOSABLE_CI_LAB_NOT_PRODUCTION_RECOVERY'
LAB_TRUST = '/run/gallery-smoke-lab-recovery'
EXTERNAL_LAB_ROOT = '/external/build11-external-ci'
ROLLBACK_SOURCE = '81867689be4d773473b6a3f417eee16c0329231e'
ROLLBACK_ARCHIVE_SHA = 'd0e9e46997df44e6fe5bcb614608672b7e3bec3a6ab8667f440583337f27a45a'
ROLLBACK_IMAGE = 'sha256:0f9e791e36ce747a02b53827122e514277b0195ef2ec43e64d2b7eaaa0238ab2'
NODE_LAB_KEYS = r'''
import {generateKeyPairSync} from 'node:crypto';
const {privateKey, publicKey} = generateKeyPairSync('ed25519');
process.stdout.write(JSON.stringify({
  privateKey: privateKey.export({type:'pkcs8',format:'pem'}),
  publicKey: publicKey.export({type:'spki',format:'pem'})
}));
'''
NODE_LAB_STORAGE = r'''
import {createRequire} from 'node:module';
const require=createRequire('/usr/src/app/server/package.json');
require('reflect-metadata');
const {ConfigRepository}=await import('file:///usr/src/app/server/dist/repositories/config.repository.js');
const {StorageRepository}=await import('file:///usr/src/app/server/dist/repositories/storage.repository.js');
const {LoggingRepository}=await import('file:///usr/src/app/server/dist/repositories/logging.repository.js');
const {StorageService}=await import('file:///usr/src/app/server/dist/services/storage.service.js');
const configRepository=new ConfigRepository(),config=configRepository.getEnv();
const storageRepository=new StorageRepository(LoggingRepository.create());
if(typeof StorageService.prototype.detectMediaLocation!=='function'||config.storage.backend!=='disk')
  throw new Error('DISPOSABLE_STORAGE_REQUIRED');
// Use the application's actual auto-detection; the official clean installer
// intentionally leaves IMMICH_MEDIA_LOCATION unset. Never overwrite its env.
const location=StorageService.prototype.detectMediaLocation.call({configRepository,storageRepository});
if(location!=='/data')throw new Error('DISPOSABLE_STORAGE_REQUIRED');
const {StorageCore} = await import('file:///usr/src/app/server/dist/cores/storage.core.js');
StorageCore.setMediaLocation(location);
'''
NODE_LAB_ROOTS = NODE_LAB_STORAGE + r'''
import fs from 'node:fs/promises';
const {StorageFolder} = await import('file:///usr/src/app/server/dist/enum.js');
const {collectRootIdentities} = await import('file:///usr/src/app/server/dist/utils/authorized-deletion.js');
let input = ''; for await (const part of process.stdin) input += part;
const user = JSON.parse(input);
const allowed = [StorageCore.getFolderLocation(StorageFolder.Upload, user.id), StorageCore.getLibraryFolder(user)];
const roots = [];
for(const root of new Set(allowed)) {
  try { await fs.lstat(root); roots.push(root); }
  catch(error) { if(error.code !== 'ENOENT') throw error; }
}
process.stdout.write(JSON.stringify(await collectRootIdentities(roots)));
'''


def require_lab():
    if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('GALLERY_ISOLATED_CI') != '1':
        raise RuntimeError('EXPLICIT_DISPOSABLE_CI_LAB_REQUIRED')


def committed_version(source):
    if not re.fullmatch('[0-9a-f]{40}', source):
        raise RuntimeError('FULL_COMMITTED_SOURCE_REQUIRED')
    result = subprocess.run(['git', '-C', str(ROOT), 'show', source + ':mobile/pubspec.yaml'],
                            text=True, capture_output=True, timeout=30)
    if result.returncode:
        raise RuntimeError('COMMITTED_PUBSPEC_UNAVAILABLE')
    entries = re.findall(r'^version:\s*([^\n]+)$', result.stdout, re.MULTILINE)
    match = re.fullmatch(r'((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))\+([1-9][0-9]*)\s*',
                         entries[0]) if len(entries) == 1 else None
    if not match or int(match.group(2)) > 2100000000:
        raise RuntimeError('COMMITTED_RELEASE_VERSION_INVALID')
    return match.group(1), int(match.group(2))


def verify_artifact(directory, source):
    version, build = committed_version(source)
    manifest = json.loads((directory / 'manifest.json').read_text())
    if type(manifest.get('mobileBuild')) is not int or (manifest.get('sourceCommit'), manifest.get('serverVersion'), manifest.get('mobileVersion'),
            manifest.get('mobileBuild')) != (source, version, version, build):
        raise RuntimeError('ARTIFACT_COMMITTED_VERSION_OR_SOURCE_MISMATCH')
    if (manifest.get('imageTag') != 'gallery-server:trash-' + source[:12] or
            not re.fullmatch(r'sha256:[0-9a-f]{64}', manifest.get('imageId', '')) or
            not re.fullmatch('[0-9a-f]{64}', manifest.get('archiveSHA256', ''))):
        raise RuntimeError('ARTIFACT_IMMUTABLE_IDENTITY_REQUIRED')
    archive = directory / 'gallery-server-linux-amd64.tar.gz'
    if not archive.is_file() or archive.is_symlink():
        raise RuntimeError('ARTIFACT_ARCHIVE_UNAVAILABLE')
    with archive.open('rb') as handle:
        if hashlib.file_digest(handle, 'sha256').hexdigest() != manifest['archiveSHA256']:
            raise RuntimeError('ARTIFACT_ARCHIVE_CHANGED')
    rows = json.loads(docker('image', 'inspect', manifest['imageId'], manifest['imageTag']))
    for image in rows:
        env = dict(value.split('=', 1) for value in image.get('Config', {}).get('Env', []) if '=' in value)
        if (image.get('Id') != manifest['imageId'] or image.get('Architecture') != 'amd64' or
                image.get('Os') != 'linux' or env.get('IMMICH_SOURCE_COMMIT') != source or
                env.get('IMMICH_SOURCE_REF') != 'v' + version or env.get('IMMICH_REPOSITORY') != 'docice545/gallery'):
            raise RuntimeError('LOCAL_ARTIFACT_IMAGE_OR_SOURCE_MISMATCH')
    if len(rows) != 2:
        raise RuntimeError('LOCAL_ARTIFACT_IMAGE_INSPECTION_INCOMPLETE')
    parts = tuple(map(int, version.split('.')))
    return manifest, {'major': parts[0], 'minor': parts[1], 'patch': parts[2], 'prerelease': None}


def lab_keys():
    require_lab()
    result = subprocess.run(['node', '--input-type=module', '-e', NODE_LAB_KEYS],
                            text=True, capture_output=True, timeout=30)
    if result.returncode:
        raise RuntimeError('DISPOSABLE_LAB_KEY_GENERATION_FAILED')
    keys = json.loads(result.stdout)
    if (set(keys) != {'publicKey', 'privateKey'} or not keys['publicKey'].startswith('-----BEGIN PUBLIC KEY-----') or
            not keys['privateKey'].startswith('-----BEGIN PRIVATE KEY-----')):
        raise RuntimeError('DISPOSABLE_LAB_KEY_GENERATION_FAILED')
    return keys


def prepare_lab_store(directory, public_key):
    require_lab()
    if ',' in str(directory) or directory.is_symlink() or not directory.is_dir():
        raise RuntimeError('DISPOSABLE_LAB_STORE_INVALID')
    evidence = directory / 'evidence'
    evidence.mkdir(mode=0o555)
    evidence.chmod(0o555)
    with (directory / 'public.pem').open('x') as file:
        file.write(public_key)
    (directory / 'public.pem').chmod(0o444)
    directory.chmod(0o555)
    return ['--mount', f'type=bind,source={directory},target={LAB_TRUST},readonly',
            '-e', f'GALLERY_DELETION_RECOVERY_DIR={LAB_TRUST}/evidence',
            '-e', f'GALLERY_DELETION_RECOVERY_PUBLIC_KEY={LAB_TRUST}/public.pem']


def lab_payload(owner, roots, postgres_image, now=None):
    require_lab()
    fields = {'path', 'device', 'inode', 'mountId', 'mountNamespace', 'mountType',
              'mountSource', 'mountRoot', 'mountTarget'}
    allowed = {'/data/upload/' + owner, '/data/library/' + owner}
    if (not re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', owner) or
            not re.fullmatch(r'sha256:[0-9a-f]{64}', postgres_image) or not roots or len(roots) > 2 or
            len({root.get('path') for root in roots}) != len(roots) or any(
                set(root) != fields or root['path'] not in allowed or
                any(not isinstance(root[field], str) or not root[field] for field in fields) or
                not re.fullmatch(r'mnt:\[[0-9]+\]', root['mountNamespace']) for root in roots)):
        raise RuntimeError('ACTUAL_DISPOSABLE_LAB_ROOT_IDENTITIES_REQUIRED')
    now = now or datetime.now(timezone.utc)
    timestamp = now.isoformat(timespec='milliseconds').replace('+00:00', 'Z')
    expiry = (now + timedelta(hours=1)).isoformat(timespec='milliseconds').replace('+00:00', 'Z')
    def digest(value):
        return hashlib.sha256((LAB_MARKER + ':' + value).encode()).hexdigest()
    # Deliberately synthetic verifier-contract receipts. They certify no real
    # PostgreSQL restore or NAS export, and the lab key is never a production key.
    return {'version': 1, 'ownerId': owner, 'scope': 'managed', 'roots': roots,
            'verifiedAt': timestamp, 'expiresAt': expiry,
            'postgres': {'backupSHA256': digest('synthetic-sql'), 'receiptSHA256': digest('synthetic-restore-receipt'),
                         'checkedAt': timestamp, 'restore': 'PASS_ISOLATED_SQL_TRANSACTION',
                         'productionChanged': False, 'assetCount': 1, 'migrationCount': 1,
                         'postgresImage': postgres_image},
            'mounts': {root['path']: {'snapshotReferenceSHA256': digest('synthetic-export:' + root['path']),
                                    'snapshotProvenanceSHA256': digest('synthetic-provenance:' + root['path']),
                                    'verifiedAt': timestamp, 'samples': [
                                        {'kind': kind, 'sha256': digest('synthetic-' + kind), 'size': 1}
                                        for kind in ('photo', 'video')]} for root in roots}}


def publish_lab_evidence(directory, keys, payload):
    require_lab()
    spec = importlib.util.spec_from_file_location('smoke_recovery_evidence', Path(__file__).with_name('trash_recovery_evidence.py'))
    recovery = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(recovery)
    signed_bytes = recovery.compact_json(payload)
    result = subprocess.run(['node', '--input-type=module', '-e', recovery.NODE_SIGN],
                            input=recovery.compact_json({'key': keys['privateKey'],
                                'payload': base64.b64encode(signed_bytes).decode('ascii')}),
                            capture_output=True, timeout=30)
    try:
        signature = base64.b64decode(result.stdout, validate=True)
    except ValueError:
        raise RuntimeError('DISPOSABLE_LAB_SIGNING_FAILED') from None
    if result.returncode or len(signature) != 64:
        raise RuntimeError('DISPOSABLE_LAB_SIGNING_FAILED')
    envelope = recovery.compact_json({'version': 1, 'algorithm': 'Ed25519',
                                     'payload': base64.b64encode(signed_bytes).decode('ascii'),
                                     'signature': base64.b64encode(signature).decode('ascii')})
    digest = hashlib.sha256(envelope).hexdigest()
    evidence = directory / 'evidence'
    evidence.chmod(0o700)
    try:
        with (evidence / (digest + '.json')).open('xb') as file:
            file.write(envelope)
        (evidence / (digest + '.json')).chmod(0o444)
    finally:
        evidence.chmod(0o555)
    directory.chmod(0o700)
    try:
        with (directory / 'lab-only.json').open('x') as file:
            json.dump({'testOnly': True, 'marker': LAB_MARKER, 'evidenceSHA256': digest,
                       'productionRecoveryVerified': False, 'productionAuthorization': False}, file)
        (directory / 'lab-only.json').chmod(0o444)
    finally:
        directory.chmod(0o555)
    return digest


def authorize_lab_fixture(request, server, owner, postgres_image, directory, keys):
    require_lab()
    roots = json.loads(docker('exec', '-i', server, 'node', '--input-type=module', '-e', NODE_LAB_ROOTS,
                              input=json.dumps({'id': owner, 'storageLabel': None})))
    digest = publish_lab_evidence(directory, keys, lab_payload(owner, roots, postgres_image))
    request('/assets/managed-deletion-preparation', 'PUT', {'recoveryProof': digest, 'verifiedExclusiveRoots': True})
    if request('/assets/managed-deletion-policy') != {'enabled': False, 'prepared': True, 'canPrepare': True}:
        raise RuntimeError('DISPOSABLE_MANAGED_PREPARATION_FAILED')
    request('/assets/managed-deletion-consent', 'PUT', {'enabled': True, 'confirmed': True})
    if request('/assets/managed-deletion-policy') != {'enabled': True, 'prepared': True, 'canPrepare': True}:
        raise RuntimeError('DISPOSABLE_OWNER_CONSENT_FAILED')
    return digest


def http_failure(method, path, error):
    """Only fixed route/status/schema diagnostics, never request data or tokens."""
    route = re.sub(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', ':id', path)
    codes = {
        'Root is not an existing owner library root': 'OWNER_ROOT_MISMATCH',
        'Unknown owner/library scope': 'OWNER_LIBRARY_MISMATCH',
        'Unknown owner': 'OWNER_MISSING',
    }
    try:
        body = json.loads(error.read(65536))
        detail = codes.get(body.get('message'), 'API_REJECTION')
    except (ValueError, AttributeError, TypeError):
        detail = 'API_REJECTION'
    return RuntimeError(f'HTTP {method} {route}: status {error.code}; category {detail}')


def assert_removed_asset_not_restorable(request, asset_id):
    # The established Restore API checks ownership of existing asset rows first.
    # A permanently removed row is rejected; it is not a successful count=0 restore.
    try:
        request('/trash/restore/assets', 'POST', {'ids': [asset_id]})
    except urllib.error.HTTPError as error:
        assert error.code in (400, 404)
        return
    raise AssertionError('Restore unexpectedly accepted a permanently removed asset')


def synthetic_png(color=0):
    """Valid small synthetic PNG for actual thumbnail/preview processing."""
    def chunk(kind, data):
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data))
    width, height = 64, 64
    pixels = b''.join(b'\x00' + bytes((color, 127, 255)) * width for _ in range(height))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!IIBBBBB', width, height, 8, 2, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b''))


def upload_synthetic(request, media):
    boundary = 'gallery-ci-boundary'
    parts = []
    for key in ('fileCreatedAt', 'fileModifiedAt'):
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"\r\n\r\n2024-05-06T10:20:30.000Z\r\n'.encode())
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="assetData"; filename="fixture.png"\r\nContent-Type: image/png\r\n\r\n'.encode() + media + b'\r\n')
    parts.append(f'--{boundary}--\r\n'.encode())
    return request('/assets', 'POST', b''.join(parts), 'multipart/form-data; boundary=' + boundary)['id']


def ordinary_managed_smoke(request, asset_id, media):
    require_lab()
    request('/assets/managed-deletion-consent', 'PUT', {'enabled': False, 'confirmed': True})
    blocked = request('/assets/permanent-deletion', 'POST', {'ids': [asset_id], 'confirmed': True})
    assert blocked == [{'id': asset_id, 'scope': 'managed', 'state': 'blocked', 'code': 'LIBRARY_DELETION_NOT_AUTHORIZED'}]
    assert request(f'/assets/{asset_id}/original', raw=True) == media
    request('/assets/managed-deletion-consent', 'PUT', {'enabled': True, 'confirmed': True})
    assert request('/assets/managed-deletion-policy') == {'enabled': True, 'prepared': True, 'canPrepare': False}
    result = request('/assets/permanent-deletion', 'POST', {'ids': [asset_id], 'confirmed': True})
    assert result == [{'id': asset_id, 'scope': 'managed', 'state': 'complete'}]
    assert request('/assets/' + asset_id + '/deletion-status') == {'id': asset_id, 'state': 'complete'}
    return result


def rollback_identity():
    """Reviewed CI pins only; never resolve a mutable image or fabricate source."""
    fields = ('GALLERY_SMOKE_ROLLBACK_SOURCE', 'GALLERY_SMOKE_ROLLBACK_IMAGE',
              'GALLERY_SMOKE_ROLLBACK_ARCHIVE_SHA256')
    values = [os.environ.get(name) for name in fields]
    if not any(values):
        return ROLLBACK_SOURCE, ROLLBACK_IMAGE, ROLLBACK_ARCHIVE_SHA
    if (not all(values) or not re.fullmatch('[0-9a-f]{40}', values[0]) or
            not re.fullmatch('sha256:[0-9a-f]{64}', values[1]) or
            not re.fullmatch('[0-9a-f]{64}', values[2])):
        raise RuntimeError('COMPLETE_IMMUTABLE_REVIEWED_ROLLBACK_PINS_REQUIRED')
    return tuple(values)


NODE_ADDITIVE_MIGRATION = r'''
import fs from 'node:fs/promises';
import {createHash} from 'node:crypto';
const roots=['migrations','migrations-gallery'];
const hashes=[];
for(const root of roots) {
  const bytes=await fs.readFile('/usr/src/app/server/dist/schema/'+root+'/1794050000000-OwnerStorageDeletion.js');
  hashes.push(createHash('sha256').update(bytes).digest('hex'));
}
process.stdout.write(JSON.stringify(hashes));
'''


def additive_migration_hash(image):
    """Read compiled migration bytes without a database, media or worker startup."""
    if not re.fullmatch('sha256:[0-9a-f]{64}', image):
        raise RuntimeError('IMMUTABLE_MIGRATION_IMAGE_REQUIRED')
    hashes = json.loads(docker('run', '--rm', '--pull', 'never', '--network', 'none', '--read-only',
                               '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
                               '--memory', '256m', '--pids-limit', '32', '--entrypoint', 'node',
                               image, '--input-type=module', '-e', NODE_ADDITIVE_MIGRATION))
    if (not isinstance(hashes, list) or len(hashes) != 2 or hashes[0] != hashes[1] or
            not re.fullmatch('[0-9a-f]{64}', hashes[0])):
        raise RuntimeError('EXACT_COMPILED_ADDITIVE_MIGRATION_REQUIRED')
    return hashes[0]


def verify_rollback_migration(rollback, candidate):
    digest = additive_migration_hash(rollback)
    if digest != additive_migration_hash(candidate):
        raise RuntimeError('PINNED_ROLLBACK_ADDITIVE_MIGRATION_MISMATCH')
    return digest


def load_rollback(directory, candidate_image=None):
    """Reuse one previously published immutable rollback; no image rebuild or pull."""
    require_lab()
    source, image_id, archive_sha = rollback_identity()
    manifest = json.loads((directory / 'manifest.json').read_text())
    archive = directory / 'gallery-server-linux-amd64.tar.gz'
    if (manifest.get('sourceCommit') != source or manifest.get('archiveSHA256') != archive_sha or
            manifest.get('imageId') != image_id or not archive.is_file() or archive.is_symlink()):
        raise RuntimeError('PINNED_ROLLBACK_ARTIFACT_REQUIRED')
    with archive.open('rb') as file:
        if hashlib.file_digest(file, 'sha256').hexdigest() != archive_sha:
            raise RuntimeError('PINNED_ROLLBACK_ARCHIVE_CHANGED')
    docker('load', '-i', str(archive))
    spec = importlib.util.spec_from_file_location('smoke_image_identity', Path(__file__).with_name('trash_image_identity.py'))
    identity = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(identity)
    # Existing streaming verifier checks config, ordered layers, source and
    # Docker manifest digest across classic/containerd stores.
    tool = SimpleNamespace(IMAGE=image_id, TAG=manifest['imageTag'], SOURCE=source,
                           SOURCE_REF='v' + manifest['serverVersion'], ARCHIVE_SHA=archive_sha,
                           docker=docker, verify_artifact=lambda _: archive,
                           DOCKER=['docker', '--host=unix:///var/run/docker.sock'])
    proof = identity.verify_loaded(tool, directory)
    if candidate_image is not None:
        verify_rollback_migration(proof['loadedImageId'], candidate_image)
    return proof['loadedImageId'], manifest


NODE_STORAGE_FIXTURE = NODE_LAB_STORAGE + r'''
import fs from 'node:fs/promises';
const {Kysely,sql}=require('kysely');
const {getKyselyConfig}=await import('file:///usr/src/app/server/dist/utils/database.js');
let input='';for await(const part of process.stdin)input+=part;
const data=JSON.parse(input);
// Upstream intentionally rejects external libraries nested inside /data.
// This separate anonymous fixture volume never binds any host/NAS originals.
const root='/external/build11-external-ci',file=root+'/synthetic.png';
if(data.action==='writeExternal'){
  await fs.mkdir(root,{recursive:true,mode:0o700});
  await fs.writeFile(file,Buffer.from(data.media,'base64'),{flag:'wx',mode:0o600});
  console.log(JSON.stringify({root}));
}else if(data.action==='fileGone'){
  try{await fs.lstat(file);console.log('false');}catch(error){if(error.code!=='ENOENT')throw error;console.log('true');}
}else{
  const db=new Kysely(getKyselyConfig(config.database.config));
  try{
    if(data.action==='externalIds'){
      const rows=await db.selectFrom('asset').select('id').where('libraryId','=',data.scope).execute();
      console.log(JSON.stringify(rows.map(row=>row.id)));
    }else if(data.action==='mediaTypes'){
      const rows=await db.selectFrom('asset_file').select('type').where('assetId','=',data.id).execute();
      console.log(JSON.stringify(rows.map(row=>row.type)));
    }else if(data.action==='rescanGate'){
      const {AssetRepository}=await import('file:///usr/src/app/server/dist/repositories/asset.repository.js');
      console.log(JSON.stringify(await new AssetRepository(db).filterNewExternalAssetPaths(data.scope,[file])));
    }else throw new Error('UNKNOWN_FIXED_LAB_ACTION');
  }finally{await db.destroy();}
}
'''


def storage_fixture(server, action, **values):
    require_lab()
    if not re.fullmatch(r'gallery-trash-ci-[0-9a-f]{12}-server', server):
        raise RuntimeError('OWNED_DISPOSABLE_SERVER_REQUIRED')
    return json.loads(docker('exec', '-i', server, 'node', '--input-type=module', '-e', NODE_STORAGE_FIXTURE,
                            input=json.dumps({'action': action, **values})))


def thumbnail_smoke(request, server, asset_id):
    deadline = time.monotonic() + 120
    while True:
        types = storage_fixture(server, 'mediaTypes', id=asset_id)
        if {'thumbnail', 'preview'}.issubset(types):
            break
        if time.monotonic() > deadline:
            raise RuntimeError('SYNTHETIC_THUMBNAIL_AND_PREVIEW_NOT_PROCESSED')
        time.sleep(2)
    assert request(f'/assets/{asset_id}/thumbnail?size=thumbnail', raw=True)
    assert request(f'/assets/{asset_id}/thumbnail?size=preview', raw=True)


def external_smoke(request, server, owner):
    require_lab()
    media = synthetic_png(22)
    fixture = storage_fixture(server, 'writeExternal', media=base64.b64encode(media).decode())
    if fixture.get('root') != EXTERNAL_LAB_ROOT:
        raise RuntimeError('EXACT_DISPOSABLE_EXTERNAL_ROOT_REQUIRED')
    scope = request('/libraries', 'POST', {'ownerId': owner, 'name': 'Disposable CI external', 'importPaths': [fixture['root']]})['id']
    validation = request('/libraries/' + scope + '/validate', 'POST', {'importPaths': [fixture['root']]})
    paths = validation.get('importPaths', [])
    if (len(paths) != 1 or paths[0].get('importPath') != fixture['root'] or paths[0].get('isValid') is not True):
        raise RuntimeError('SYNTHETIC_EXTERNAL_IMPORT_ROOT_INVALID')
    request('/libraries/' + scope + '/scan', 'POST')
    deadline = time.monotonic() + 120
    while True:
        ids = storage_fixture(server, 'externalIds', scope=scope)
        if len(ids) == 1:
            break
        if len(ids) > 1 or time.monotonic() > deadline:
            raise RuntimeError('SYNTHETIC_EXTERNAL_SCAN_INCOMPLETE_OR_DUPLICATED')
        time.sleep(2)
    asset_id = ids[0]
    request('/assets', 'DELETE', {'ids': [asset_id], 'force': False})
    assert request('/assets/' + asset_id)['isTrashed'] is True
    assert request('/assets/' + asset_id + '/original', raw=True) == media
    denied = request('/assets/permanent-deletion', 'POST', {'ids': [asset_id], 'confirmed': True})
    assert denied == [{'id': asset_id, 'scope': scope, 'state': 'blocked', 'code': 'LIBRARY_DELETION_NOT_AUTHORIZED'}]
    request('/assets/library-deletion-consent/' + scope, 'PUT', {'enabled': True, 'confirmed': True})
    result = request('/assets/permanent-deletion', 'POST', {'ids': [asset_id], 'confirmed': True})
    assert result == [{'id': asset_id, 'scope': scope, 'state': 'complete'}]
    assert storage_fixture(server, 'fileGone') is True
    assert storage_fixture(server, 'externalIds', scope=scope) == []
    # Exercise the actual compiled external-scan admission query, rather than
    # claiming an asynchronously queued rescan completed merely from count=0.
    assert storage_fixture(server, 'rescanGate', scope=scope) == []
    return {'externalScopeDefaultReadOnly': True, 'ownerWritablePhysicalDeletion': True,
            'externalScanSuppression': True, 'syntheticMediaOnly': True, 'productionNFSVerified': False}


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
    env = os.environ.copy()
    for name in ('DOCKER_HOST', 'DOCKER_CONTEXT', 'DOCKER_TLS', 'DOCKER_TLS_VERIFY', 'DOCKER_CERT_PATH'):
        env.pop(name, None)
    result = subprocess.run(['docker', '--host=unix:///var/run/docker.sock', *args], input=input,
                            text=True, capture_output=True, timeout=180, env=env)
    if result.returncode:
        raise RuntimeError(f'Docker {args[0]} failed: {docker_failure_reason(result.stderr)} (exit {result.returncode}); private details omitted')
    return result.stdout.strip()


def main():
    if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('GALLERY_ISOLATED_CI') != '1':
        print('FAIL only runs on an explicitly isolated GitHub runner; no containers touched')
        return 1
    if len(sys.argv) not in (3, 4):
        print('FAIL exact source SHA and existing artifact directory, optional pinned rollback directory required')
        return 1
    sha, output = sys.argv[1:3]
    rollback_directory = Path(sys.argv[3]) if len(sys.argv) == 4 else None
    directory = Path(output)
    names = []
    network = None
    lab = None
    stage = 'verify committed artifact identity'
    try:
        manifest, expected_version = verify_artifact(directory, sha)
        keys = lab_keys()
        lab = tempfile.TemporaryDirectory(prefix='gallery-smoke-lab-')
        trust = Path(lab.name)
        trust_arguments = prepare_lab_store(trust, keys['publicKey'])
        print('CI free runner disk bytes:', shutil.disk_usage(directory).free, flush=True)
        prefix = 'gallery-trash-ci-' + secrets.token_hex(6)
        network = docker('network', 'create', prefix)
        db, redis, server = (prefix + '-' + name for name in ('pg', 'redis', 'server'))
        for name, image, extra in [
            (db, POSTGRES, ['-e', 'POSTGRES_PASSWORD=disposable-ci-password', '-e', 'POSTGRES_DB=immich']),
            (redis, 'redis:7.4.6', []),
            (server, manifest['imageId'], ['-e', f'DB_HOSTNAME={db}', '-e', 'DB_PASSWORD=disposable-ci-password',
                '-e', f'REDIS_HOSTNAME={redis}', '-e', 'IMMICH_WORKERS_INCLUDE=api,microservices',
                '-e', 'IMMICH_WORKERS_EXCLUDE=',
                '-e', 'IMMICH_MEDIA_LOCATION=/data', '--mount', 'type=volume,destination=/external',
                *trust_arguments, '-p', '127.0.0.1::2283']),
        ]:
            stage = 'create isolated fixture ' + ('postgres' if name == db else 'redis' if name == redis else 'server')
            postgres_command = ['postgres', '-c', 'shared_preload_libraries=vchord.so',
                '-c', 'config_file=/var/lib/postgresql/data/postgresql.conf'] if name == db else []
            docker('run', '-d', '--name', name, '--network', network, *extra, image, *postgres_command)
            # Only a successfully created fixture is ours to remove/read logs.
            names.append(name)
        server_info = json.loads(docker('inspect', server))[0]
        if not any(mount.get('Type') == 'bind' and mount.get('Source') == str(trust) and
                   mount.get('Destination') == LAB_TRUST and mount.get('RW') is False
                   for mount in server_info.get('Mounts', [])):
            raise RuntimeError('READ_ONLY_DISPOSABLE_LAB_TRUST_MOUNT_REQUIRED')
        external_mounts = [mount for mount in server_info.get('Mounts', []) if mount.get('Destination') == '/external']
        if len(external_mounts) != 1 or external_mounts[0].get('Type') != 'volume' or external_mounts[0].get('RW') is not True:
            raise RuntimeError('SEPARATE_DISPOSABLE_EXTERNAL_VOLUME_REQUIRED')
        mapping = server_info['NetworkSettings']['Ports']['2283/tcp'][0]
        if not re.fullmatch('[0-9]+', mapping.get('HostPort', '')) or not 0 < int(mapping['HostPort']) < 65536:
            raise RuntimeError('DISPOSABLE_LOOPBACK_PORT_REQUIRED')
        base = 'http://127.0.0.1:' + mapping['HostPort'] + '/api'
        token = None
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args, **kwargs):
                raise RuntimeError('DISPOSABLE_API_REDIRECT_REJECTED')
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

        def request(path, method='GET', data=None, content_type='application/json', raw=False):
            headers = {'Content-Type': content_type}
            if token:
                headers['Authorization'] = 'Bearer ' + token
            body = data if isinstance(data, bytes) else None if data is None else json.dumps(data).encode()
            with opener.open(urllib.request.Request(base + path, body, headers, method=method), timeout=10) as response:
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
        assert request('/server/version') == expected_version
        print('PASS compiled image/fresh PostgreSQL migrations/API version ' + manifest['serverVersion'])
        stage = 'synthetic upload/Trash/Restore'
        credentials = {'email': 'trash-ci@example.invalid', 'password': secrets.token_urlsafe(24)}
        request('/auth/admin-sign-up', 'POST', {**credentials, 'name': 'Disposable CI'})
        token = request('/auth/login', 'POST', credentials)['accessToken']
        media = synthetic_png()
        asset_id = upload_synthetic(request, media)
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
        stage = 'synthetic thumbnail and preview jobs'
        thumbnail_smoke(request, server, asset_id)
        print('PASS actual microservices thumbnail/preview files and HTTP photo viewing')
        stage = 'ordinary owner consent/permanent deletion/durable receipt'
        def required(path, method='GET', data=None, **kwargs):
            try:
                return request(path, method, data, **kwargs)
            except urllib.error.HTTPError as error:
                raise http_failure(method, path, error) from None

        required('/assets', 'DELETE', {'ids': [asset_id], 'force': False})
        owner = required('/users/me')['id']
        ordinary_managed_smoke(required, asset_id, media)
        assert_removed_asset_not_restorable(request, asset_id)
        try:
            request(f'/assets/{asset_id}/original', raw=True)
            raise AssertionError('Deleted fixture still accessible')
        except urllib.error.HTTPError as error:
            assert error.code in (400, 404)
        try:
            upload_synthetic(request, media)
            raise AssertionError('Permanent identity was reimported')
        except urllib.error.HTTPError as error:
            assert error.code == 410
        print('PASS real HTTP owner revocation/ordinary consent/permanent receipt/reimport suppression; no recovery proof')
        stage = 'ordinary owner external writable scope and physical deletion'
        external_result = external_smoke(required, server, owner)
        print('PASS actual external scan/default read-only/owner writable physical deletion/reimport gate')
        stage = 'read-only diagnostic runtime'
        spec = importlib.util.spec_from_file_location('audit', Path(__file__).parents[1] / 'diagnostics/hp_trash_release_audit.py')
        audit = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(audit)
        result = json.loads(docker('exec', '-i', server, 'node', '--input-type=module', input=audit.NODE_AUDIT.replace('__MOUNT_ROOTS__', '[]')))
        if result['errors']:
            # The audit emits only fixed stage names and allowlisted error codes.
            raise RuntimeError('Read-only diagnostic incomplete: ' + ', '.join(result['errors']))
        assert result['postgres']['readOnly'] == 'on'
        assert result['runningVersion'] == manifest['serverVersion']
        print('PASS diagnostic SELECT/read-only Redis path on the compiled image')
        manifest['isolatedSmoke'] = 'PASS: disposable lab migrations + HTTP Trash/Restore/ordinary owner consent/permanent deletion + read-only audit'
        manifest['isolatedRecoveryEvidence'] = {'testOnly': True, 'marker': LAB_MARKER,
                                               'productionRecoveryVerified': False, 'productionAuthorization': False}
        manifest['isolatedWorkerConfiguration'] = 'API_AND_MICROSERVICES'
        manifest['thumbnailPreviewVerification'] = 'PASS_SYNTHETIC_FILES_AND_HTTP'
        manifest['isolatedExternalDeletion'] = external_result
        manifest['rollbackVerification'] = 'NOT_TESTED_NO_PINNED_ROLLBACK_ARTIFACT'
        if rollback_directory:
            stage = 'pinned existing rollback archive integrity'
            rollback_image, rollback_manifest = load_rollback(rollback_directory, manifest['imageId'])
            rollback_media = synthetic_png(33)
            rollback_asset = upload_synthetic(request, rollback_media)
            request('/assets', 'DELETE', {'ids': [rollback_asset], 'force': False})
            assert request('/assets/' + rollback_asset)['isTrashed'] is True
            # Stop ONLY our candidate fixture; production never participates.
            stage = 'actual old runtime on upgraded isolated database'
            docker('stop', server)
            old_server = prefix + '-rollback-server'
            docker('run', '-d', '--name', old_server, '--network', network, '--volumes-from', server,
                   '-e', f'DB_HOSTNAME={db}', '-e', 'DB_PASSWORD=disposable-ci-password',
                   '-e', f'REDIS_HOSTNAME={redis}', '-e', 'IMMICH_WORKERS_INCLUDE=api,microservices',
                   '-e', 'IMMICH_WORKERS_EXCLUDE=', '-e', 'IMMICH_MEDIA_LOCATION=/data',
                   '-p', '127.0.0.1::2283', rollback_image)
            names.append(old_server)
            old_info = json.loads(docker('inspect', old_server))[0]
            mapping = old_info['NetworkSettings']['Ports']['2283/tcp'][0]
            if not re.fullmatch('[0-9]+', mapping.get('HostPort', '')) or not 0 < int(mapping['HostPort']) < 65536:
                raise RuntimeError('DISPOSABLE_ROLLBACK_LOOPBACK_PORT_REQUIRED')
            base = 'http://127.0.0.1:' + mapping['HostPort'] + '/api'
            token = None
            deadline = time.monotonic() + 180
            while True:
                try:
                    assert request('/server/ping') == {'res': 'pong'}
                    break
                except Exception:
                    if time.monotonic() > deadline:
                        raise RuntimeError('PINNED_OLD_RUNTIME_DID_NOT_START_ON_BUILD11_DATABASE') from None
                    time.sleep(2)
            expected_old = tuple(map(int, rollback_manifest['serverVersion'].split('.')))
            assert request('/server/version') == dict(zip(('major', 'minor', 'patch', 'prerelease'), (*expected_old, None)))
            token = request('/auth/login', 'POST', credentials)['accessToken']
            assert request('/assets/' + rollback_asset)['isTrashed'] is True
            assert request('/assets/' + rollback_asset + '/original', raw=True) == rollback_media
            denied = request('/assets/permanent-deletion', 'POST', {'ids': [rollback_asset], 'confirmed': True})
            assert len(denied) == 1 and denied[0]['state'] == 'blocked' and denied[0]['code'] == 'MANAGED_DELETION_PREPARATION_REQUIRED'
            assert request('/assets/' + rollback_asset + '/original', raw=True) == rollback_media
            assert request('/trash/restore/assets', 'POST', {'ids': [rollback_asset]}) == {'count': 1}
            assert request('/assets/' + rollback_asset)['isTrashed'] is False
            assert request('/assets/' + rollback_asset + '/original', raw=True) == rollback_media
            receipt = {'schemaVersion': 1, 'sourceCommit': sha, 'candidateImageId': manifest['imageId'],
                       'rollbackSourceCommit': rollback_manifest['sourceCommit'], 'rollbackImageId': rollback_image,
                       'rollbackArchiveSHA256': rollback_manifest['archiveSHA256'],
                       'isolatedDatabase': True, 'oldRuntimeStartsOnUpgradedSchema': True,
                       'storagePoliciesRejectedByRollback': True, 'trashRestoreAfterRollback': True,
                       'syntheticMediaOnly': True, 'productionChanged': False,
                       'testedAt': datetime.now(timezone.utc).isoformat()}
            receipt_path = directory / 'build11-rollback-runtime.json'
            with receipt_path.open('x') as file:
                json.dump(receipt, file, indent=2)
                file.write('\n')
            manifest['rollbackVerification'] = 'PASS_ACTUAL_PINNED_OLD_RUNTIME_HTTP_ON_BUILD11_SCHEMA'
            manifest['rollbackRuntimeReceiptSHA256'] = hashlib.sha256(receipt_path.read_bytes()).hexdigest()
            print('PASS actual old image/API/auth/Trash/Restore on upgraded isolated DB; storage-mode deletion remains rejected')
        (directory / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        # Public receipt allows verification without downloading the large image.
        print('PASS backend receipt:', json.dumps({key: manifest[key] for key in (
            'sourceCommit', 'toolingCommit', 'serverVersion', 'mobileVersion', 'mobileBuild',
            'imageTag', 'imageId', 'archiveSHA256', 'isolatedSmoke')}, sort_keys=True))
        return 0
    except Exception as error:
        print('FAIL isolated smoke stage:', stage, '; category:', type(error).__name__)
        # Readable through the normal Checks API even when the log-storage host
        # is not in a cloud environment allowlist. Fixed stage/type/line only.
        line = traceback.extract_tb(error.__traceback__)[-1].lineno
        detail = str(error) if isinstance(error, RuntimeError) else ''
        annotation = f'{stage}; {type(error).__name__}; harness line {line}; {detail}'
        annotation = annotation.replace('%','%25').replace('\r','%0D').replace('\n','%0A')
        print('::error title=Backend isolated smoke::' + annotation)
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
        if lab:
            lab.cleanup()


if __name__ == '__main__':
    raise SystemExit(main())
