#!/usr/bin/env python3
"""Fresh, isolated recovery gate over the unmodified 565ef38 release tooling.

prepare/recheck never deploy, pause/resume jobs, sign or modify production data.
deploy/rollback delegate to the pinned implementation only after two approvals.
"""
import argparse
from contextlib import contextmanager, redirect_stdout
from datetime import datetime, timezone
import fcntl
import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import pwd
import re
import selectors
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time

PIN = '565ef38c0c39f3ee896f5afd055d4d57a676d503'
PIN_FILE_SHA = '56c12526736e51abad3adf321c0b9665ec9b70f8472641af966feba4c45f7a2c'
BASE = '42790b06edc21438811e56e40c431eee37c24894'
HOME = Path('/home/doctoriceadm')
DEFAULT_TOOL = HOME / 'gallery-trash-release-tooling-565ef38/trash_release.py'
DEFAULT_AUDIT = HOME / 'gallery-trash-release-audit-20261009T155251367898Z-8d189795a83d.txt'
DEFAULT_NAS = HOME / 'gallery-nas-recovery-sau5r5go'
DEFAULT_PG = HOME / 'gallery-recovery-hum85h39'
MOBILE_HASHES = {
    'android/app-release.apk': 'ae3ed08bfe8794e1f12193e5d29733c22c22e7671672726e1a27b869483a4527',
    'ios/Photos-unsigned.ipa': '4abfdbd7007c5f72d85fbb2cc8b35c20891c7342d2c9e6cba85c23792278a6bd',
}
PG_TAG = 'ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0'
PG_DIGEST = 'sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23'
PG_PINNED_REF = PG_TAG + '@' + PG_DIGEST
PG_REPO_DIGEST = 'ghcr.io/immich-app/postgres@' + PG_DIGEST
SUMMARY_SQL = '''SELECT json_build_object(
 'assetCount',(SELECT count(*) FROM asset),
 'libraryCount',(SELECT count(*) FROM library),
 'statusCounts',(SELECT json_object_agg(status,n) FROM
     (SELECT status,count(*) n FROM asset GROUP BY status) s),
 'migrationNames',(SELECT json_agg(name ORDER BY name) FROM kysely_migrations),
 'orphans',(SELECT count(*) FROM asset a LEFT JOIN library l ON l.id=a."libraryId"
     WHERE a."libraryId" IS NOT NULL AND l.id IS NULL));'''
SNAPSHOT_SQL = SUMMARY_SQL.replace("'assetCount'", "'snapshot',pg_export_snapshot(),\n 'databaseSize',pg_database_size(current_database()),\n 'assetCount'", 1)
COUNTS_LUA = '''local result={}
for i=1,7 do
 if i<=3 then result[i]=redis.call('LLEN',KEYS[i])
 else result[i]=redis.call('ZCARD',KEYS[i]) end
end
result[8]=redis.call('HGET',KEYS[8],'paused') or ''
return result'''
QUEUE_BODY = r'''
const Redis=require('ioredis');
const r=new Redis({...config.redis,lazyConnect:true,maxRetriesPerRequest:0,
 retryStrategy:()=>null,commandTimeout:5000,enableReadyCheck:false});
r.on('error',()=>{});
try {
 await r.connect();const p=(config.bull.config.prefix??'immich_bull')+':backgroundTask:';
 const states=['active','wait','paused','delayed','prioritized','waiting-children','failed'];
 const read=async()=>{const row=await r.eval(__LUA__,8,...states.map(s=>p+s),p+'meta');
   return {counts:Object.fromEntries(states.map((s,i)=>[s,Number(row[i])])),
     paused:row[7]==='1'||row[7]==='true'};};
 const before=await read();let cursor='0',examined=0,orphans=0,complete=true;
 const names={'AssetDelete':0,'FileDelete':0};const started=Date.now();
 // SCAN is supplementary orphan inventory, NEVER the emptiness test.
 do {
   const [next,keys]=await r.scan(cursor,'MATCH',p+'*','COUNT',100);cursor=next;
   for(const key of keys){
     if(++examined>5000||Date.now()-started>20000){complete=false;break;}
     if(await r.type(key)!=='hash')continue;
     const name=await r.hget(key,'name');if(!Object.hasOwn(names,name))continue;
     const id=key.slice(p.length);
     if(await r.zscore(p+'completed',id)!==null)continue;
     names[name]++;orphans++;
   }
   if(!complete)break;
 }while(cursor!=='0');
 const after=await read();console.log(JSON.stringify({...after,atomic:true,before:before.counts,
   inventoryComplete:complete,unresolvedDeletionHashes:orphans,deletionNames:names,instantOnly:true}));
}catch{console.log(JSON.stringify({error:'QUEUE_READ_FAILED'}));process.exitCode=1;}
finally{r.disconnect();}
'''


class Stop(Exception):
    pass


def need(value, code):
    if not value:
        raise Stop(code)


def sha(path):
    with path.open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()


def private_dir(path):
    need(path.is_dir() and not path.is_symlink() and path.stat().st_mode & 0o077 == 0,
         'PRIVATE_DIRECTORY_REQUIRED')


def private_json(path):
    need(path.is_file() and not path.is_symlink() and path.stat().st_mode & 0o077 == 0,
         'PRIVATE_EVIDENCE_FILE_REQUIRED')
    return json.loads(path.read_text())


def save(path, value):
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), 'w') as file:
        json.dump(value, file, indent=2)
        file.write('\n')


def age_ok(value, seconds, code):
    age = (datetime.now(timezone.utc) - datetime.fromisoformat(value)).total_seconds()
    need(0 <= age < seconds, code)


def load_tool(path, candidate=None):
    need(path.is_file() and not path.is_symlink() and sha(path) == PIN_FILE_SHA, 'PINNED_TOOLING_MISMATCH')
    spec = importlib.util.spec_from_file_location('pinned_trash_release', path)
    tool = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(tool)
    # Force the existing local daemon; never use inherited remote Docker context.
    for prefix in (['docker'], ['sudo', '-n', 'docker']):
        command = [*prefix, '--host=unix:///var/run/docker.sock']
        try:
            if subprocess.run([*command, 'info'], capture_output=True, timeout=15).returncode == 0:
                tool.DOCKER = command
                break
        except (OSError, subprocess.TimeoutExpired):
            continue
    else:
        raise Stop('EXISTING_LOCAL_DOCKER_ACCESS_REQUIRED')
    tool.NODE_QUEUE = tool.NODE_BASE + QUEUE_BODY.replace('__LUA__', json.dumps(COUNTS_LUA))
    original_queue = tool.queue_empty

    def strict_queue(require_paused=False):
        row = original_queue(require_paused)
        need(row.get('atomic') is True and row.get('inventoryComplete') is True and
             row.get('unresolvedDeletionHashes') == 0 and
             set(row.get('before', {})) == set(tool.STATES) and
             all(type(n) is int and n == 0 for n in row['before'].values()) and
             all(type(n) is int and n == 0 for n in row['counts'].values()), 'QUEUE_INCOMPLETE_CHANGED_OR_LEGACY_HASH')
        return row

    tool.queue_empty = strict_queue
    if candidate is not None:
        import release_candidate
        release_candidate.configure(tool, candidate)
    install_image_adapter(tool)
    return tool


def install_image_adapter(tool):
    """Keep the immutable 565ef38 file intact; adapt only image-store semantics."""
    spec = importlib.util.spec_from_file_location('trash_image_identity', Path(__file__).with_name('trash_image_identity.py'))
    identity = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(identity)
    tool.image_identity = identity
    config_id, original_verify, original_override, original_save = tool.IMAGE, tool.verify_artifact, tool.override, tool.save
    tool.ARCHIVE_CONFIG_IMAGE = config_id

    def frozen_verify(directory):
        current = tool.IMAGE
        tool.IMAGE = config_id
        try:
            return original_verify(directory)
        finally:
            tool.IMAGE = current

    def prove(directory):
        current = tool.IMAGE
        tool.IMAGE = config_id
        try:
            return identity.verify_loaded(tool, directory)
        finally:
            tool.IMAGE = current

    def load(directory):
        archive = frozen_verify(directory)
        exists = subprocess.run([*tool.DOCKER, 'image', 'inspect', tool.TAG], capture_output=True, timeout=15)
        if exists.returncode:
            # Called only by explicitly approved deploy; verification never loads.
            tool.docker('load', '-i', str(archive), timeout=900)
        proof = prove(directory)
        tool.IMAGE = proof['loadedImageId']
        tool.loaded_image_proof = proof

    def override(state, image, normal=None, name='active-server.override.json'):
        # Eliminate tag races during recreate/enable. Rollback retains its
        # separately guarded previous tag/ID from the private journal.
        return original_override(state, tool.IMAGE if image == tool.TAG else image, normal, name)

    def journal_save(file, value):
        if file.name == 'deployment.json':
            need(hasattr(tool, 'loaded_image_proof'), 'VERIFIED_IMAGE_PROOF_REQUIRED_BEFORE_JOURNAL')
            value = {**value, 'candidateImage': tool.IMAGE, 'candidateImageProof': tool.loaded_image_proof,
                     'phase': 'PREPARED_BEFORE_QUEUE_PAUSE'}
        return original_save(file, value)

    tool.verify_artifact, tool.prove_loaded_image, tool.load_artifact = frozen_verify, prove, load
    tool.override, tool.save = override, journal_save


def journal_image(tool, state):
    journal = private_json(state / 'deployment.json')
    proof = journal.get('candidateImageProof', {})
    need(journal.get('source') == tool.SOURCE and proof.get('sourceCommit') == tool.SOURCE and
         proof.get('configDigest') == tool.ARCHIVE_CONFIG_IMAGE and proof.get('archiveSHA256') == tool.ARCHIVE_SHA and
         proof.get('loadedImageId') == journal.get('candidateImage') and
         proof.get('identityKind') in ('CONFIG_DIGEST', 'MANIFEST_DIGEST', 'INDEX_DIGEST') and
         re.fullmatch(r'sha256:[0-9a-f]{64}', journal.get('candidateImage', '')),
         'JOURNAL_IMAGE_PROOF_MISSING_OR_CHANGED')
    tool.IMAGE = journal['candidateImage']


def postgres_identity(tool, pg):
    # Config.Image is a launch reference, not the immutable config/image ID.
    # Only these two exact references are allowed; a mutable tag alone proves nothing.
    need(pg['Config'].get('Image') in (PG_TAG, PG_PINNED_REF), 'POSTGRES_IMAGE_REFERENCE_CHANGED')
    image_id = pg.get('Image', '')
    need(re.fullmatch('sha256:[0-9a-f]{64}', image_id), 'POSTGRES_IMMUTABLE_IMAGE_ID_INVALID')
    # Local lookup only, no pull/tag/load. Resolve the expected manifest reference
    # and the running config ID independently; manifest digest != config ID.
    try:
        images = json.loads(tool.docker('image', 'inspect', image_id, PG_PINNED_REF))
    except Exception:
        raise Stop('POSTGRES_LOCAL_PINNED_IMAGE_LOOKUP_FAILED') from None
    need(isinstance(images, list) and len(images) == 2 and
         all(isinstance(row, dict) and row.get('Id') == image_id for row in images),
         'POSTGRES_PINNED_IMAGE_ID_MISMATCH')
    need(all(isinstance(row.get('RepoDigests'), list) and PG_REPO_DIGEST in row['RepoDigests'] and
             row.get('Architecture') == 'amd64' and row.get('Os') == 'linux' for row in images),
         'POSTGRES_EXPECTED_DIGEST_OR_PLATFORM_MISSING')


def topology(tool):
    result = {}
    pg = None
    for name in (tool.SERVER, *tool.OTHER):
        item = tool.inspect(name)
        need(item['State'].get('Running') and item['State'].get('Health', {}).get('Status') == 'healthy',
             'PRODUCTION_CONTAINER_UNHEALTHY')
        result[name] = {'id': item['Id'], 'image': item['Image']}
        if name == tool.POSTGRES:
            pg = item
    need(pg is not None, 'POSTGRES_CONTAINER_MISSING_FROM_TOPOLOGY')
    postgres_identity(tool, pg)
    env = dict(x.split('=', 1) for x in pg['Config'].get('Env', []) if '=' in x)
    need(env.get('POSTGRES_USER', 'postgres') == 'postgres' and env.get('POSTGRES_DB', 'immich') == 'immich',
         'POSTGRES_USER_OR_DATABASE_CHANGED')
    return result


def validate_audit(tool, audit, current):
    report = private_json(audit)
    summary = report['backendReadOnlyAudit']
    need(summary.get('errors') == [] and len(summary.get('sections', {})) == 10 and
         all(v == 'PASS' for v in summary['sections'].values()) and
         summary['deletionJobs'].get('inventoryComplete') is True, 'COMPLETED_PASS_AUDIT_REQUIRED')
    need(all(g['classification'] == 'OFFLINE_EXTERNAL_INDEX_TOMBSTONE_EXPECTED'
             for g in summary['activeWithDeletedAt']['groups']), 'UNEXPECTED_ACTIVE_DELETED_AT')
    rows = report['containers']
    need({r.get('role') for r in rows} == {tool.SERVER, *tool.OTHER} and len(rows) == 4,
         'UNREVIEWED_PRODUCTION_TOPOLOGY')
    for row in rows:
        now = current[row['role']]
        need(now['id'][:12] == row['containerId'] and now['image'] == row['imageId'], 'PRODUCTION_MOVED_SINCE_AUDIT')
    return report


def reuse_nas(tool, nas, old_pg, audit, state):
    private_dir(nas)
    private_dir(old_pg)
    report = private_json(nas / 'nas-recovery-report.txt')
    proof = private_json(nas / 'nas-proof.json')
    receipt = private_json(nas / 'nas-verified.json')
    old = private_json(old_pg / 'backup-verified.json')
    old_report = private_json(old_pg / 'recovery-report.txt')
    need(report.get('result') == 'PASS' and report['checks'].get('NAS_RECOVERY') == 'PASS' and
         report['checks'].get('PREVIOUS_EVIDENCE') == 'PASS_UNCHANGED', 'NAS_RECOVERY_PASS_REQUIRED')
    need(old.get('restore') == 'PASS_ISOLATED_SQL_TRANSACTION' and old.get('productionChanged') is False and
         str(old_report['checks']['POSTGRES_RESTORE']).startswith('PASS'), 'PREVIOUS_POSTGRES_PASS_REQUIRED')
    server = next(r for r in audit['containers'] if r['role'] == tool.SERVER)
    scope = {r['containerMountpoint'] for r in server['externalMounts']}
    need(scope and set(receipt.get('mounts', {})) == scope and set(proof.get('mounts', {})) == scope,
         'NAS_RECOVERY_SCOPE_CHANGED')
    need(receipt.get('validation') == 'SAMPLE_BYTE_RECOVERY_PLUS_OPERATOR_SNAPSHOT_SCOPE_ATTESTATION',
         'NAS_RECEIPT_CONTRACT_CHANGED')
    age_ok(receipt['verifiedAt'], 86400, 'NAS_PASS_OLDER_THAN_PINNED_24H_GATE')
    need(set(proof.get('provenance', {})) == {'homes', 'Immich'}, 'SNAPSHOT_PROVENANCE_REQUIRED')
    for point in proof['provenance'].values():
        need(point.get('snapshotId') and point.get('snapshotTimestamp') and
             point.get('metadataSource') in ('DSM_SNAPSHOT_LIST', 'NFS_DIRECTORY_ID_PLUS_DSM_OPERATOR_ATTESTATION'),
             'SNAPSHOT_PROVENANCE_REQUIRED')
    for root, entry in proof['mounts'].items():
        need(entry.get('operator_attests_snapshot_export') is True and
             {s['kind'] for s in entry['samples']} == {'photo', 'video'}, 'NAS_SAMPLE_SCOPE_INCOMPLETE')
        hashes = [s['sha256'] for s in entry['samples']]
        need(hashes == receipt['mounts'][root]['sampleHashes'] and
             all(re.fullmatch('[0-9a-f]{64}', h) for h in hashes) and
             hashlib.sha256(entry['snapshot_reference'].encode()).hexdigest() ==
             receipt['mounts'][root]['snapshotReferenceSHA256'], 'NAS_PROOF_RECEIPT_DISAGREES')
    # No sample reads/exports. Original verifiedAt is retained. NO old PG receipt copy.
    save(state / 'nas-verified.json', receipt)
    return {str(p): sha(p) for p in (nas / 'nas-recovery-report.txt', nas / 'nas-proof.json',
            nas / 'nas-verified.json', old_pg / 'backup-verified.json', old_pg / 'recovery-report.txt')}


def archive_migrations(tool, backend):
    tool.verify_artifact(backend)
    archive = backend / 'gallery-server-linux-amd64.tar.gz'
    with tarfile.open(archive, 'r|gz') as outer:
        manifest = next(json.load(outer.extractfile(m)) for m in outer if m.name == 'manifest.json')
    row = manifest[0]
    config_name, layers = row['Config'], row['Layers']
    need(len(layers) == len(set(layers)), 'DUPLICATE_IMAGE_LAYERS')
    effects, config = {}, None
    roots = ('usr/src/app/server/dist/schema/migrations', 'usr/src/app/server/dist/schema/migrations-gallery')
    with tarfile.open(archive, 'r|gz') as outer:
        for member in outer:
            if member.name == config_name:
                need(member.isfile() and member.size < 1024 * 1024, 'INVALID_IMAGE_CONFIG')
                raw = outer.extractfile(member).read()
                need('sha256:' + hashlib.sha256(raw).hexdigest() == getattr(tool, 'ARCHIVE_CONFIG_IMAGE', tool.IMAGE), 'IMAGE_CONFIG_DIGEST_MISMATCH')
                config = json.loads(raw)
            elif member.name in layers:
                need(member.isfile(), 'INVALID_IMAGE_LAYER')
                deletes, adds = [], []
                with tarfile.open(fileobj=outer.extractfile(member), mode='r|*') as layer:
                    for item in layer:
                        path = PurePosixPath(item.name)
                        need(not path.is_absolute() and '..' not in path.parts, 'INVALID_IMAGE_LAYER_PATH')
                        name = str(path)
                        if path.name.startswith('.wh.'):
                            target = str(path.parent if path.name == '.wh..wh..opq' else path.parent / path.name[4:])
                            deletes.append(target)
                        elif item.isfile() and any(str(path.parent) == root for root in roots) and name.endswith('.js'):
                            adds.append(name)
                effects[member.name] = (deletes, adds)
    need(config and set(effects) == set(layers), 'IMAGE_CONFIG_OR_LAYER_MISSING')
    env = dict(x.split('=', 1) for x in config.get('config', {}).get('Env', []) if '=' in x)
    need(config.get('architecture') == 'amd64' and config.get('os') == 'linux' and
         env.get('IMMICH_SOURCE_COMMIT') == tool.SOURCE and env.get('IMMICH_SOURCE_REF') == getattr(tool, 'SOURCE_REF', 'v5.7.1'),
         'IMAGE_SOURCE_OR_PLATFORM_MISMATCH')
    files = set()
    for layer in layers:
        deletes, adds = effects[layer]
        for target in deletes:
            files = {p for p in files if not (p == target or p.startswith(target + '/') or target == '.')}
        files.update(adds)
    names = sorted({PurePosixPath(p).stem for p in files})
    need(names, 'COMPILED_MIGRATIONS_MISSING')
    return names


def verify_artifacts(tool, root):
    hashes = MOBILE_HASHES if not hasattr(tool, 'CANDIDATE_PROFILE') else {
        'android/app-release.apk': tool.CANDIDATE_PROFILE['android']['sha256'],
        'ios/Photos-unsigned.ipa': tool.CANDIDATE_PROFILE['ios']['sha256'],
    }
    for relative, expected in hashes.items():
        file = root / relative
        need(file.is_file() and not file.is_symlink() and sha(file) == expected, 'FROZEN_MOBILE_ARTIFACT_MISMATCH')
    return archive_migrations(tool, root / 'backend')


def psql_command(tool, container):
    return [*tool.DOCKER, 'exec', '-i', '--user', 'postgres', container,
            'psql', '-X', '-q', '-A', '-t', '--no-password', '--host=/var/run/postgresql',
            '-U', 'postgres', '-d', 'immich', '-v', 'ON_ERROR_STOP=on']


def summary_valid(row):
    need(type(row.get('assetCount')) is int and row['assetCount'] > 0 and
         type(row.get('libraryCount')) is int and row['libraryCount'] >= 0 and row.get('orphans') == 0 and
         isinstance(row.get('migrationNames'), list) and row['migrationNames'] and
         row['migrationNames'] == sorted(set(row['migrationNames'])) and
         isinstance(row.get('statusCounts'), dict) and
         all(type(v) is int and v >= 0 for v in row['statusCounts'].values()) and
         sum(row['statusCounts'].values()) == row['assetCount'], 'DATABASE_SUMMARY_INVALID')


def comparable(row):
    return {key: row[key] for key in ('assetCount', 'libraryCount', 'statusCounts', 'migrationNames', 'orphans')}


@contextmanager
def exported_snapshot(tool, state):
    fd = os.open(state / 'snapshot-private.log', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as errors:
        process = subprocess.Popen(psql_command(tool, tool.POSTGRES), stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=errors)
        try:
            process.stdin.write(('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;\n'
                "SET LOCAL idle_in_transaction_session_timeout='900s';\n"
                "SET LOCAL statement_timeout='60s';\n" + SNAPSHOT_SQL + '\n').encode())
            process.stdin.flush()
            with selectors.DefaultSelector() as ready:
                ready.register(process.stdout, selectors.EVENT_READ)
                need(ready.select(70), 'POSTGRES_READ_ONLY_SNAPSHOT_TIMEOUT')
            line = process.stdout.readline(1024 * 1024)
            need(line.startswith(b'{') and line.endswith(b'\n'),
                 'POSTGRES_READ_ONLY_CONNECTION_OR_QUERY_FAILED_PRIVATE_LOG_RETAINED')
            row = json.loads(line)
            summary_valid(row)
            need(re.fullmatch('[0-9A-Fa-f]+-[0-9A-Fa-f]+-[0-9]+', row.get('snapshot', '')),
                 'INVALID_EXPORTED_SNAPSHOT')
            yield row
            process.stdin.write(b'COMMIT;\n')
            process.stdin.close()
            need(process.wait(timeout=15) == 0, 'POSTGRES_SNAPSHOT_TRANSACTION_FAILED')
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdout.close()
            if not process.stdin.closed:
                process.stdin.close()


def fresh_backup(tool, state):
    target = state / 'fresh-immich.sql.gz'
    partial = state / 'fresh-immich.sql.gz.partial'
    with exported_snapshot(tool, state) as snapshot:
        need(shutil.disk_usage(state).free > max(2 * snapshot['databaseSize'], 2 * 1024**3),
             'LOCAL_BACKUP_DISK_RESERVE_INSUFFICIENT')
        fd = os.open(partial, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        logfd = os.open(state / 'dump-private.log', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'wb') as file, os.fdopen(logfd, 'wb') as errors:
            command = [*tool.DOCKER, 'exec', '--user', 'postgres',
                       '-e', 'PGOPTIONS=-c default_transaction_read_only=on -c statement_timeout=600000',
                       tool.POSTGRES, 'pg_dump', '--format=p', '--encoding=UTF8', '--no-password',
                       '--host=/var/run/postgresql', '-U', 'postgres', '-d', 'immich',
                       '--snapshot=' + snapshot['snapshot']]
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=errors)
            deadline = time.monotonic() + 600
            total = 0
            try:
                with gzip.GzipFile(filename='', mode='wb', fileobj=file, mtime=0) as compressed:
                    with selectors.DefaultSelector() as ready:
                        ready.register(process.stdout, selectors.EVENT_READ)
                        while True:
                            need(time.monotonic() < deadline, 'BACKUP_STREAM_TIMEOUT')
                            if not ready.select(min(15, max(0, deadline - time.monotonic()))):
                                continue
                            chunk = os.read(process.stdout.fileno(), 1024 * 1024)
                            if not chunk:
                                break
                            compressed.write(chunk)
                            total += len(chunk)
                            need(shutil.disk_usage(state).free > 1024**3, 'BACKUP_DISK_RESERVE_EXHAUSTED')
                need(process.wait(timeout=15) == 0 and total > 0, 'POSTGRES_DUMP_FAILED_NO_VALID_BACKUP')
                file.flush()
                os.fsync(file.fileno())
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                process.stdout.close()
    # Hard link publication fails rather than replacing an existing final name.
    os.link(partial, target, follow_symlinks=False)
    partial.unlink()  # Only our own newly created local partial file.
    with gzip.open(target, 'rb') as file:
        prefix = file.read(64)
        need(prefix.startswith(b'--') and b'PostgreSQL database dump' in prefix, 'NOT_SQL_GZIP_BACKUP')
        while file.read(1024 * 1024):
            pass  # Full gzip CRC/truncation verification, bounded RAM.
    metadata = {'backupSHA256': sha(target), 'backupSize': target.stat().st_size,
                'createdAt': datetime.now(timezone.utc).isoformat(), 'snapshotSummary': comparable(snapshot),
                'source': tool.SOURCE, 'database': 'immich', 'user': 'postgres'}
    save(state / 'fresh-backup.json', metadata)
    return target, comparable(snapshot)


def restore_exact(tool, backup, state, expected):
    need(not (state / 'backup-verified.json').exists(), 'OLD_RESTORE_RECEIPT_CANNOT_VERIFY_FRESH_BACKUP')
    original = tool.docker
    observed = []

    def checked_docker(*args, **kwargs):
        result = original(*args, **kwargs)
        if (len(args) > 3 and args[0] == 'exec' and args[1].startswith('gallery-restore-check-') and
                args[2] == 'psql' and '-c' in args and 'SELECT json_build_array' in args[-1]):
            # Inspect the SAME disposable DB before pinned restore_check removes it.
            query = [*args[:-2], '-q', '-c', 'BEGIN READ ONLY', '-c', "SET LOCAL statement_timeout='60s'",
                     '-c', SUMMARY_SQL, '-c', 'COMMIT']
            restored = json.loads(original(*query))
            summary_valid(restored)
            need(comparable(restored) == expected, 'FRESH_RESTORE_COUNTS_OR_MIGRATIONS_DIFFER_FROM_DUMP_SNAPSHOT')
            observed.append(restored)
            if hasattr(tool, 'CANDIDATE_PROFILE'):
                import candidate_restore
                candidate_restore.transition(tool, original, args[1], query, restored, state, backup)
        return result

    tool.docker = checked_docker
    try:
        tool.restore_check(backup, state)
    finally:
        tool.docker = original
    need(len(observed) == 1, 'PINNED_RESTORE_VALIDATION_HOOK_NOT_EXECUTED')
    receipt = private_json(state / 'backup-verified.json')
    need(receipt['backupSHA256'] == sha(backup) and receipt['backupPath'] == str(backup.resolve()) and
         receipt['productionChanged'] is False and receipt['assetCount'] == expected['assetCount'] and
         receipt['migrationCount'] == len(expected['migrationNames']), 'FRESH_RESTORE_RECEIPT_INVALID')
    save(state / 'fresh-restore-verified.json', {'backupSHA256': receipt['backupSHA256'],
         'summary': comparable(observed[0]), 'checkedAt': receipt['checkedAt'], 'restore': 'PASS_EXACT_DUMP_SNAPSHOT'})


def rollback_prerequisites(tool, state):
    server = tool.inspect(tool.SERVER)
    base, files = tool.compose_base(server)
    env = files[0].parent / '.env'
    files = [*files, *([env] if env.is_file() else [])]
    need(all(not f.is_symlink() and os.access(f, os.R_OK) for f in files), 'COMPOSE_BACKUP_ACCESS_REQUIRED')
    image = json.loads(tool.docker('image', 'inspect', server['Image']))[0]
    need(image['Id'] == server['Image'] and shutil.disk_usage(state).free > image['Size'] * 1.2 + 1024**3,
         'PREVIOUS_IMAGE_OR_ROLLBACK_DISK_RESERVE_MISSING')
    return {str(f): sha(f) for f in files}


def prepare(tool, args, state):
    need(tool.run(['git', '-C', '/opt/gallery-fork', 'rev-parse', 'HEAD']).strip() == BASE and
         tool.run(['git', '-C', '/opt/gallery-fork', 'branch', '--show-current']).strip() == 'work' and
         not tool.run(['git', '-C', '/opt/gallery-fork', 'status', '--porcelain']).strip(), 'PRODUCTION_CHECKOUT_MOVED_OR_DIRTY')
    filesystem = json.loads(tool.run(['findmnt', '-T', str(state), '-J', '-o', 'FSTYPE']))['filesystems']
    need(len(filesystem) == 1 and filesystem[0]['fstype'] in ('ext4', 'xfs', 'btrfs'), 'BACKUP_MUST_USE_LOCAL_HP_STORAGE')
    need(int(Path('/proc/meminfo').read_text().split('MemAvailable:')[1].split()[0]) * 1024 > 3 * 1024**3,
         'ISOLATED_RESTORE_RAM_RESERVE_REQUIRED')
    before = topology(tool)
    audit = validate_audit(tool, args.audit, before)
    evidence = reuse_nas(tool, args.nas_state, args.previous_pg_state, audit, state)
    evidence[str(args.audit)] = sha(args.audit)
    migrations = verify_artifacts(tool, args.artifacts)
    if hasattr(tool, 'CANDIDATE_PROFILE'):
        proof = tool.prove_loaded_image(args.artifacts / 'backend')
        tool.IMAGE, tool.loaded_image_proof = proof['loadedImageId'], proof
        save(state / 'loaded-image-proof.json', proof)
    config = rollback_prerequisites(tool, state)
    if hasattr(tool, 'CANDIDATE_PROFILE'):
        import rollback_bridge
        rollback_bridge.prepare(tool, state, args.artifacts / 'backend')
    need(tool.api(args.api, None, '/server/ping') == {'res': 'pong'} and
         tool.api(args.api, None, '/server/version') == {'major': 5, 'minor': 7, 'patch': 1, 'prerelease': None},
         'CURRENT_GALLERY_API_OR_VERSION_CHANGED')
    print('PASS pinned artifacts, unchanged production, reusable NAS proof and rollback prerequisites')
    backup, summary = fresh_backup(tool, state)
    expected = summary['migrationNames']
    if hasattr(tool, 'CANDIDATE_PROFILE'):
        from release_candidate import MIGRATION
        need(MIGRATION not in expected and migrations == sorted([*expected, MIGRATION]),
             'ONLY_EXACT_ADDITIVE_MIGRATION_ALLOWED')
    else:
        need(expected == migrations, 'ARTIFACT_MIGRATIONS_DIFFER_NO_SCHEMA_CHANGE_AUTHORIZED')
    print('PASS new SQL/gzip backup: CRC, SHA-256, private local storage, consistent read-only snapshot')
    restore_exact(tool, backup, state, summary)
    need(topology(tool) == before and all(sha(Path(p)) == h for p, h in evidence.items()) and
         all(sha(Path(p)) == h for p, h in config.items()), 'PRODUCTION_OR_RECOVERY_EVIDENCE_CHANGED')
    need(rollback_prerequisites(tool, state) == config, 'ROLLBACK_CONFIG_OR_DISK_CHANGED')
    age_ok(private_json(state / 'nas-verified.json')['verifiedAt'], 86400, 'NAS_PASS_OLDER_THAN_PINNED_24H_GATE')
    # The last production probe: atomic state counts plus bounded legacy-hash inventory.
    queues = tool.queue_empty()
    checked = datetime.now(timezone.utc).isoformat()
    age_ok(private_json(state / 'backup-verified.json')['backupModifiedAt'], 3600, 'FRESH_BACKUP_EXPIRED')
    save(state / 'predeploy-context.json', {'source': tool.SOURCE, 'toolingCommit': PIN,
         'artifactRoot': str(args.artifacts), 'audit': str(args.audit), 'backup': str(backup),
         'topology': before, 'evidenceHashes': evidence, 'configHashes': config, 'queues': queues,
         'checkedAt': checked, 'migrations': migrations, 'baseMigrations': summary['migrationNames'],
         'candidateProfile': getattr(tool, 'CANDIDATE_PROFILE', None)})
    print('PASS exact fresh-backup restore, unchanged counts/migrations, atomic empty queues')


def recheck(tool, state):
    context = private_json(state / 'predeploy-context.json')
    need(context['source'] == tool.SOURCE and context['toolingCommit'] == PIN, 'PREDEPLOY_SOURCE_CHANGED')
    need(topology(tool) == context['topology'], 'PRODUCTION_MOVED_SINCE_PREDEPLOY')
    need(all(sha(Path(p)) == h for p, h in {**context['evidenceHashes'], **context['configHashes']}.items()),
         'PREDEPLOY_EVIDENCE_OR_CONFIG_CHANGED')
    nas = private_json(state / 'nas-verified.json')
    original_nas = next(Path(p) for p in context['evidenceHashes'] if p.endswith('/nas-verified.json'))
    need(nas == private_json(original_nas), 'COPIED_NAS_RECEIPT_CHANGED')
    age_ok(nas['verifiedAt'], 86400, 'NAS_PASS_OLDER_THAN_PINNED_24H_GATE')
    backup = private_json(state / 'backup-verified.json')
    fresh = private_json(state / 'fresh-backup.json')
    restore = private_json(state / 'fresh-restore-verified.json')
    age_ok(backup['backupModifiedAt'], 3600, 'FRESH_BACKUP_EXPIRED')
    need(backup['restore'] == 'PASS_ISOLATED_SQL_TRANSACTION' and backup['productionChanged'] is False and
         backup['postgresImage'] == context['topology'][tool.POSTGRES]['image'] and
         backup['backupPath'] == context['backup'] and
         backup['backupSHA256'] == fresh['backupSHA256'] == restore['backupSHA256'] == sha(Path(context['backup'])) and
         restore['summary'] == fresh['snapshotSummary'] and restore['restore'] == 'PASS_EXACT_DUMP_SNAPSHOT',
         'FRESH_BACKUP_OR_RESTORE_RECEIPT_CHANGED')
    need(context.get('candidateProfile') == getattr(tool, 'CANDIDATE_PROFILE', None), 'CANDIDATE_PROFILE_CHANGED')
    if hasattr(tool, 'CANDIDATE_PROFILE'):
        proof = tool.prove_loaded_image(Path(context['artifactRoot']) / 'backend')
        need(proof == private_json(state / 'loaded-image-proof.json'), 'PREDEPLOY_LOADED_IMAGE_CHANGED')
        tool.IMAGE, tool.loaded_image_proof = proof['loadedImageId'], proof
        migration = private_json(state / 'candidate-migration-verified.json')
        bridge = private_json(state / 'rollback-bridge.json')
        need(migration == {'backupSHA256': fresh['backupSHA256'], 'sourceCommit': tool.SOURCE,
             'imageId': tool.IMAGE, 'rollbackImageId': bridge['imageId'],
             'baseMigrations': context['baseMigrations'], 'targetMigrations': context['migrations'],
             'validation': 'PASS_ISOLATED_ADDITIVE_UPGRADE_AND_ROLLBACK_STARTUP', 'productionChanged': False},
             'CANDIDATE_MIGRATION_RECEIPT_CHANGED')
    need(verify_artifacts(tool, Path(context['artifactRoot'])) == context['migrations'] and
         restore['summary']['migrationNames'] == context.get('baseMigrations', context['migrations']),
         'FROZEN_ARTIFACT_OR_MIGRATIONS_CHANGED')
    live = json.loads(tool.docker('exec', '-i', tool.SERVER, 'node', '--input-type=module', input=tool.NODE_MIGRATIONS))
    need(sorted(live) == context.get('baseMigrations', context['migrations']), 'LIVE_MIGRATIONS_CHANGED')
    rollback_prerequisites(tool, state)
    tool.queue_empty()  # Last check; no pause/resume/retry/clear during recheck.
    print('PASS immediate pre-deployment recheck; empty at this instant only')
    return context


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('verify-image', 'prepare', 'recheck', 'deploy', 'rollback', 'acceptance', 'enable-workers'))
    parser.add_argument('--candidate-profile', type=Path)
    parser.add_argument('--candidate-profile-sha256')
    parser.add_argument('--approve-migration', action='store_true')
    parser.add_argument('--pinned-tool', type=Path, default=DEFAULT_TOOL)
    parser.add_argument('--artifacts', type=Path)
    parser.add_argument('--audit', type=Path, default=DEFAULT_AUDIT)
    parser.add_argument('--nas-state', type=Path, default=DEFAULT_NAS)
    parser.add_argument('--previous-pg-state', type=Path, default=DEFAULT_PG)
    parser.add_argument('--state', type=Path)
    parser.add_argument('--approve-deployment', action='store_true')
    parser.add_argument('--approve-retention', action='store_true')
    parser.add_argument('--key', type=Path)
    parser.add_argument('--api', default='http://127.0.0.1:2283/api')
    args = parser.parse_args(argv)
    # Absolute paths keep receipts valid across the operator's working directory.
    for field in ('pinned_tool', 'artifacts', 'audit', 'nas_state', 'previous_pg_state', 'state', 'key'):
        value = getattr(args, field)
        if value is not None:
            setattr(args, field, value.absolute())
    state, report = None, {'result': 'STOP', 'deploymentAuthorized': False, 'source': None}
    try:
        need(pwd.getpwuid(os.getuid()).pw_name == 'doctoriceadm', 'RUN_AS_DOCTORICEADM')
        need(sys.version_info >= (3, 11), 'PYTHON_3_11_REQUIRED')
        os.umask(0o077)
        if args.action in ('deploy', 'rollback', 'acceptance', 'enable-workers'):
            need(args.approve_deployment and os.environ.get('GALLERY_DEPLOYMENT_APPROVED') == 'YES',
                 'SEPARATE_EXPLICIT_DEPLOYMENT_APPROVAL_REQUIRED')
            need(args.key and args.key.is_file() and not args.key.is_symlink() and
                 args.key.stat().st_mode & 0o077 == 0, 'PRIVATE_EXISTING_ADMIN_KEY_FILE_REQUIRED')
        if args.action == 'enable-workers':
            need(args.approve_retention and os.environ.get('GALLERY_RETENTION_RESUME_APPROVED') == 'YES',
                 'SEPARATE_EXPLICIT_RETENTION_APPROVAL_REQUIRED')
        if args.action == 'verify-image':
            need(args.artifacts and args.artifacts.is_dir() and not args.state, 'ARTIFACT_ROOT_REQUIRED_NEW_STATE_AUTOMATIC')
            state = Path(tempfile.mkdtemp(prefix='gallery-image-proof-', dir=HOME))
            print('Private image proof: ' + str(state))
        elif args.action == 'prepare':
            need(args.artifacts and args.artifacts.is_dir() and not args.state, 'ARTIFACT_ROOT_REQUIRED_NEW_STATE_AUTOMATIC')
            state = Path(tempfile.mkdtemp(prefix='gallery-predeploy-', dir=HOME))
            print('Private state: ' + str(state))
        else:
            need(args.state is not None, 'EXISTING_PRIVATE_STATE_REQUIRED')
            state = args.state
            private_dir(state)
        fd = os.open(state / '.execution.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'w') as lock, redirect_stdout(sys.stdout):
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            candidate = None
            if args.candidate_profile is not None or args.candidate_profile_sha256 is not None:
                import release_candidate
                candidate = release_candidate.load(args.candidate_profile, args.candidate_profile_sha256)
            tool = load_tool(args.pinned_tool, candidate)
            report['source'] = tool.SOURCE
            if args.action == 'verify-image':
                verify_artifacts(tool, args.artifacts)
                save(state / 'loaded-image-proof.json', tool.prove_loaded_image(args.artifacts / 'backend'))
            elif args.action == 'prepare':
                prepare(tool, args, state)
                report.update(result='PASS', queues='EMPTY_AT_CHECK_NOT_RESERVED', freshRestore='PASS',
                              nas='PASS_REUSED_ORIGINAL_TIMESTAMP', deploymentAuthorized=False,
                              signingAuthorized=False, retentionActivationAuthorized=False)
                save(state / 'predeploy-report.json', report)
            elif args.action == 'recheck':
                recheck(tool, state)
            else:
                if args.action == 'deploy':
                    context = recheck(tool, state)
                    args.artifact = Path(context['artifactRoot']) / 'backend'
                    args.audit = Path(context['audit'])
                    if candidate is not None:
                        need(args.approve_migration and os.environ.get('GALLERY_ADDITIVE_MIGRATION_APPROVED') == 'YES',
                             'SEPARATE_ADDITIVE_MIGRATION_APPROVAL_REQUIRED')
                        import rollback_bridge
                        rollback_bridge.prepare(tool, args.state, args.artifact)
                    tool.deploy(args)
                else:
                    journal_image(tool, state)
                    if args.action == 'rollback':
                        tool.queue_empty(require_paused=tool.api_only(tool.inspect(tool.SERVER)))
                        if candidate is not None:
                            import rollback_bridge
                            rollback_bridge.rollback(tool, args)
                        else:
                            tool.rollback(args)
                    elif args.action == 'acceptance':
                        tool.acceptance(args)
                    else:
                        args.retention_approved = True
                        tool.enable(args)
        print('PASS ' + args.action + '; deployment/signing/retention require their separate approvals')
        return 0
    except Exception as error:
        # Never emit SQL, Docker stderr, credentials, snapshot IDs or media paths.
        pin_codes = {'queue changed/nonempty; no jobs altered': 'DELETION_QUEUE_NOT_EMPTY',
                     'queue state unknown': 'DELETION_QUEUE_READ_UNKNOWN',
                     'deletion queue is not paused': 'DELETION_QUEUE_NOT_PAUSED',
                     'isolated SQL restore failed; inspect private log locally': 'ISOLATED_SQL_RESTORE_FAILED',
                     'isolated restore fixture cleanup failed; no recovery receipt issued': 'ISOLATED_FIXTURE_CLEANUP_FAILED'}
        safe_identity_error = type(error).__name__ in ('IdentityError', 'ValueError') and re.fullmatch('[A-Z0-9_]+', str(error))
        code = str(error) if isinstance(error, Stop) or safe_identity_error else pin_codes.get(str(error),
               'PREDEPLOY_OPERATION_FAILED_' + type(error).__name__)
        print('STOP ' + code, file=sys.stderr)
        if state and (state / 'deployment.json').is_file():
            print('DEPLOYMENT_JOURNAL_EXISTS: do not retry deploy; use approved guarded rollback with this same state.', file=sys.stderr)
        if state and args.action == 'prepare':
            report['blocker'] = code
            try:
                save(state / 'predeploy-stop.json', report)
            except Exception:
                pass
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
