#!/usr/bin/env python3
"""Capture read-only container roots and adapt actual Synology export receipts.

No backup, restore, policy change, signing, deployment or media write occurs here.
Only the existing local Docker daemon's inspect/exec and local evidence output are
used. publish copies signed envelopes into an operator-selected trust store;
it requires separate operator approval. No mounts or policies are changed.
"""

import argparse
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

import trash_recovery_evidence as evidence


Stop = evidence.Stop
need = evidence.need
DOCKER = ['docker', '--host=unix:///var/run/docker.sock']
SERVER = 'immich_server'
SHA256 = re.compile(r'[a-f0-9]{64}')
UUID = re.compile(r'[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}')
SHARES = {'homes': '/volume1/homes', 'Immich': '/volume1/Immich'}
COLLECT = r'''
import {collectRootIdentities} from '/usr/src/app/server/dist/utils/authorized-deletion.js';
let input=''; for await (const part of process.stdin) input+=part;
try { process.stdout.write(JSON.stringify(await collectRootIdentities(JSON.parse(input)))); }
catch { process.exitCode=1; }
'''
VERIFY = r'''
import {createPublicKey, verify} from 'node:crypto';
let input=''; for await (const part of process.stdin) input+=part;
try {
  const {key, envelope}=JSON.parse(input), publicKey=createPublicKey(key);
  if(publicKey.asymmetricKeyType!=='ed25519' || !verify(null,
    Buffer.from(envelope.payload,'base64'), publicKey, Buffer.from(envelope.signature,'base64'))) throw new Error();
} catch { process.exitCode=1; }
'''


def read_command(command, input=None):
    try:
        result = subprocess.run(command, input=input, capture_output=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        raise Stop('READ_ONLY_LOCAL_COMMAND_FAILED') from None
    need(result.returncode == 0 and len(result.stdout) <= evidence.MAX_JSON_BYTES,
         'READ_ONLY_LOCAL_COMMAND_FAILED')
    return result.stdout.decode('utf-8')


def save_at(directory, name, value):
    data = evidence.compact_json(value)
    need(len(data) <= evidence.MAX_JSON_BYTES, 'OUTPUT_TOO_LARGE')
    descriptor = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory)
    with os.fdopen(descriptor, 'wb') as file:
        os.fchmod(file.fileno(), 0o600)
        file.write(data)
        file.flush()
        os.fsync(file.fileno())
    os.fsync(directory)
    return hashlib.sha256(data).hexdigest()


def subject(owner, scope):
    need(isinstance(owner, str) and UUID.fullmatch(owner) and isinstance(scope, str) and
         (scope == 'managed' or UUID.fullmatch(scope)), 'OWNER_OR_SCOPE_UUID_REQUIRED')


def container():
    # Do not read Config.Env, labels, credentials or an inherited remote context.
    value = json.loads(read_command([*DOCKER, 'inspect', '--format', '{{json .Id}}', SERVER]))
    mounts = json.loads(read_command([*DOCKER, 'inspect', '--format', '{{json .Mounts}}', SERVER]))
    need(isinstance(value, str) and re.fullmatch(r'[a-f0-9]{64}', value) and type(mounts) is list,
         'RUNNING_SERVER_MOUNT_CAPTURE_INVALID')
    return value, mounts


def mount_snapshot(mounts):
    # Docker inspect may reorder Mounts. Compare every complete JSON record,
    # retaining duplicate multiplicity; never collapse by Destination/Source.
    return sorted(evidence.compact_json(mount) for mount in mounts)


def collect(paths):
    result = json.loads(read_command([*DOCKER, 'exec', '-i', SERVER, 'node', '--input-type=module', '-e', COLLECT],
                                     evidence.compact_json(paths)))
    need(type(result) is list and {item.get('path') for item in result} == set(paths) and len(result) == len(paths),
         'ROOT_COLLECTOR_INVALID')
    return sorted((evidence.root_identity(item) for item in result), key=lambda item: item['path'])


def host_mapping(root, mounts):
    path = Path(root['path'])
    candidates = [mount for mount in mounts if path.is_relative_to(Path(mount['Destination']))]
    need(bool(candidates), 'ROOT_NOT_IN_EXISTING_BIND_MOUNT')
    depth = max(len(Path(mount['Destination']).parts) for mount in candidates)
    candidates = [mount for mount in candidates if len(Path(mount['Destination']).parts) == depth]
    need(len(candidates) == 1 and candidates[0].get('Type') == 'bind', 'ROOT_BIND_MOUNT_AMBIGUOUS')
    mount = candidates[0]
    source = evidence.absolute_path(mount['Source'])
    host = source / path.relative_to(Path(mount['Destination']))
    with evidence.directory_fd(host) as fd:
        observed = os.fstat(fd)
        need((str(observed.st_dev), str(observed.st_ino)) == (root['device'], root['inode']),
             'HOST_CONTAINER_ROOT_IDENTITY_MISMATCH')
    return str(host)


def capture(request, output_dir, now=None, *, library=None):
    fixed_clock = now is not None
    now = now or datetime.now(timezone.utc)
    if library is None:
        value, _ = evidence.private_json(request)
    else:
        need(request is None, 'REQUEST_OR_LIBRARY_REQUIRED')
        actual, _ = evidence.private_json(library)
        # Read-only GET /libraries/{UUID} from existing administrator credentials.
        # The backend still independently checks this owner/import-path mapping.
        value = {'version': 1, 'ownerId': actual.get('ownerId'), 'scope': actual.get('id'),
                 'roots': actual.get('importPaths')}
    need(set(value) == {'version', 'ownerId', 'scope', 'roots'} and type(value['version']) is int and
         value['version'] == 1 and type(value['roots']) is list and 1 <= len(value['roots']) <= 128 and
         all(isinstance(path, str) and str(evidence.absolute_path(path)) == path and path != '/'
             for path in value['roots']) and len(set(value['roots'])) == len(value['roots']), 'ROOT_REQUEST_INVALID')
    subject(value['ownerId'], value['scope'])
    before, mounts = container()
    roots = collect(value['roots'])
    hosts = {root['path']: host_mapping(root, mounts) for root in roots}
    after, current_mounts = container()
    need(before == after and mount_snapshot(mounts) == mount_snapshot(current_mounts) and
         roots == collect(value['roots']), 'ROOT_CHANGED_DURING_CAPTURE')
    if not fixed_clock:
        now = datetime.now(timezone.utc)
    with evidence.directory_fd(output_dir, private=True) as out:
        need(not os.listdir(out), 'EMPTY_PRIVATE_OUTPUT_REQUIRED')
        digest = save_at(out, 'roots.json', {'version': 1, 'roots': roots, 'hostRoots': hosts})
        save_at(out, 'capture.json', {'version': 1, 'ownerId': value['ownerId'], 'scope': value['scope'],
                                    'rootsSHA256': digest, 'containerId': before, 'capturedAt': evidence.iso(now)})
    return {'result': 'PASS', 'roots': len(roots), 'consentGranted': False}


def load_capture(directory, *, current=True):
    directory = evidence.absolute_path(directory)
    with evidence.directory_fd(directory, private=True):
        pass
    value, _ = evidence.private_json(directory / 'capture.json')
    need(set(value) == {'version', 'ownerId', 'scope', 'rootsSHA256', 'containerId', 'capturedAt'} and
         type(value['version']) is int and value['version'] == 1 and
         isinstance(value['rootsSHA256'], str) and SHA256.fullmatch(value['rootsSHA256']), 'ROOT_CAPTURE_INVALID')
    subject(value['ownerId'], value['scope'])
    evidence.timestamp(value['capturedAt'])
    _, digest = evidence.private_json(directory / 'roots.json')
    need(digest == value['rootsSHA256'], 'ROOT_MANIFEST_CHANGED')
    roots, hosts = evidence.read_roots(directory / 'roots.json')
    if current:
        identifier, mounts = container()
        need(identifier == value['containerId'] and collect([root['path'] for root in roots]) == roots,
             'CONTAINER_OR_ROOT_CHANGED')
        need({root['path']: host_mapping(root, mounts) for root in roots} ==
             {path: str(host) for path, host in hosts.items()}, 'HOST_MAPPING_CHANGED')
    return value, roots, hosts


def snapshot_location(root):
    """Match the collector's actual NFS backing coordinate, not a UI label."""
    need(root['mountType'] in ('nfs', 'nfs4'), 'ACTUAL_SYNOLOGY_NFS_REQUIRED')
    mount_root = evidence.absolute_path(root['mountRoot'])
    mount_target = evidence.absolute_path(root['mountTarget'])
    path = evidence.absolute_path(root['path'])
    need(path.is_relative_to(mount_target), 'NFS_COORDINATE_INVALID')
    source = root['mountSource']
    need(source.startswith('10.10.10.95:'), 'EXPECTED_SYNOLOGY_SOURCE_REQUIRED')
    export = evidence.absolute_path(source.removeprefix('10.10.10.95:'))
    coordinate = export / mount_root.relative_to('/') / path.relative_to(mount_target)
    matches = [(share, coordinate.relative_to(base)) for share, base in SHARES.items()
               if coordinate.is_relative_to(base)]
    need(len(matches) == 1, 'NFS_SHARE_BOUNDARY_INVALID')
    return matches[0]


def load_requests(path):
    value, _ = evidence.private_json(evidence.absolute_path(path))
    need(set(value) == {'version', 'captures'} and type(value['version']) is int and value['version'] == 1 and
         type(value['captures']) is list and 1 <= len(value['captures']) <= 32, 'CAPTURE_INDEX_INVALID')
    result, subjects = [], set()
    for directory in value['captures']:
        capture, roots, hosts = load_capture(directory)
        key = (capture['ownerId'], capture['scope'])
        need(key not in subjects, 'DUPLICATE_OWNER_SCOPE')
        subjects.add(key)
        for root in roots:
            share, suffix = snapshot_location(root)
            result.append({'ownerId': key[0], 'scope': key[1], 'root': root, 'hostRoot': str(hosts[root['path']]),
                           'manifestSHA256': capture['rootsSHA256'], 'share': share, 'snapshotSuffix': str(suffix)})
    need(len(result) <= 128, 'ROOT_REQUEST_LIMIT')
    return result


def snapshot_metadata(proof, share):
    points = proof.get('provenance')
    need(type(points) is dict and type(points.get(share)) is dict, 'SNAPSHOT_METADATA_REQUIRED')
    point = points[share]
    name = point.get('snapshotId')
    parts = re.fullmatch(r'GMT([+-])(\d{2})(?::?(\d{2}))?-(\d{4}\.\d{2}\.\d{2})-(\d{2}\.\d{2}\.\d{2})',
                         name) if isinstance(name, str) else None
    need(parts and int(parts[2]) < 24 and int(parts[3] or 0) < 60, 'ACTUAL_SYNOLOGY_SNAPSHOT_ID_REQUIRED')
    # This is timezone normalization of the observed ID, never a new verification time.
    offset = timedelta(hours=int(parts[2]), minutes=int(parts[3] or 0)) * (1 if parts[1] == '+' else -1)
    created = datetime.strptime(parts[4] + ' ' + parts[5], '%Y.%m.%d %H.%M.%S').replace(tzinfo=timezone(offset))
    need(datetime.fromisoformat(point['snapshotTimestamp']) == created, 'SNAPSHOT_TIMESTAMP_MISMATCH')
    metadata = point.get('dsmSnapshotMetadata')
    need(type(metadata) is dict and metadata.get('time') == name, 'SNAPSHOT_NOT_CONFIRMED')
    need(point.get('metadataSource') in ('DSM_SNAPSHOT_LIST', 'NFS_DIRECTORY_ID_PLUS_DSM_OPERATOR_ATTESTATION') and
         proof.get('recoveryOperation', {}).get('snapshotOriginConfirmed') is True, 'SNAPSHOT_NOT_CONFIRMED')
    need(type(point.get('nfsSnapshotAccessible')) is bool and
         (point['metadataSource'] != 'NFS_DIRECTORY_ID_PLUS_DSM_OPERATOR_ATTESTATION' or
          point['nfsSnapshotAccessible']), 'SNAPSHOT_NOT_CONFIRMED')
    if point['metadataSource'] == 'DSM_SNAPSHOT_LIST' and share == 'Immich':
        need(metadata.get('lock') is True, 'SNAPSHOT_LOCK_NOT_CONFIRMED')
    base = PurePosixPath(point.get('snapshotRoot', ''))
    need(base.is_absolute() and '..' not in base.parts and name in base.parts and
         base.name == name and ('#snapshot' in base.parts or '.snapshot' in base.parts), 'SNAPSHOT_EXPORT_ORIGIN_INVALID')
    if not point.get('nfsSnapshotAccessible'):
        row = point.get('fileStationRootMetadata')
        need(type(row) is dict and row.get('isdir') is True and row.get('path') == str(base),
             'DSM_EXPORT_DIRECTORY_NOT_CONFIRMED')
        real = row.get('additional', {}).get('real_path')
        need(not real or name in PurePosixPath(real).parts, 'DSM_EXPORT_DIRECTORY_NOT_CONFIRMED')
    return point, created.astimezone(timezone.utc), base


def prepare(capture_dir, nas_state, output_dir, now=None):
    fixed_clock = now is not None
    now = now or datetime.now(timezone.utc)
    output_dir = evidence.absolute_path(output_dir)
    value, roots, hosts = load_capture(capture_dir)
    nas_state = evidence.absolute_path(nas_state)
    with evidence.directory_fd(nas_state, private=True):
        pass
    report, report_sha = evidence.private_json(nas_state / 'nas-recovery-report.txt')
    proof, proof_sha = evidence.private_json(nas_state / 'nas-proof.json')
    need(report.get('result') == 'PASS' and report.get('checks', {}).get('NAS_RECOVERY') == 'PASS' and
         report.get('blockers') == [] and report.get('deploymentAuthorized') is False, 'SUCCESSFUL_NAS_RECOVERY_REQUIRED')
    operation = proof.get('recoveryOperation')
    need(type(operation) is dict and type(operation.get('version')) is int and operation['version'] == 1 and
         isinstance(operation.get('operationId'), str) and UUID.fullmatch(operation['operationId']) and
         operation.get('exportDirectory') == str(nas_state) and type(proof.get('rootExports')) is list,
         'NAS_EXPORT_RECEIPT_REQUIRED_RUN_DIAGNOSTIC')
    evidence.fresh(operation.get('startedAt'), now)
    finished = evidence.fresh(operation.get('completedAt'), now)
    need(evidence.timestamp(operation['startedAt']) <= finished, 'EXPORT_OPERATION_TIME_INVALID')
    entries, normalized = [], {'mounts': {}, 'authorization': {
        'version': 1, 'ownerId': value['ownerId'], 'scope': value['scope'], 'rootsSHA256': value['rootsSHA256'],
        'inputReceipt': str(output_dir / 'input-receipt.json')}}
    for index, root in enumerate(roots):
        matches = [entry for entry in proof['rootExports'] if entry.get('ownerId') == value['ownerId'] and
                   entry.get('scope') == value['scope'] and entry.get('root', {}).get('path') == root['path']]
        need(len(matches) == 1, 'EXACT_OWNER_SCOPE_EXPORT_REQUIRED')
        entry = matches[0]
        share, suffix = snapshot_location(root)
        point, created, source_root = snapshot_metadata(proof, share)
        need(entry.get('manifestSHA256') == value['rootsSHA256'] and entry.get('root') == root and
             entry.get('hostRoot') == str(hosts[root['path']]) and entry.get('share') == share and
             entry.get('snapshotRoot') == str(source_root / suffix) and entry.get('result') == 'PASS',
             'ROOT_EXPORT_BINDING_INVALID')
        samples = evidence.sample_paths(entry.get('samples'))
        times = []
        for sample in entry['samples']:
            original = evidence.absolute_path(sample['original'])
            recovered = evidence.absolute_path(sample['recovered'])
            need(original.is_relative_to(hosts[root['path']]) and recovered.parent == nas_state,
                 'SAMPLE_ROOT_OR_EXPORT_MISMATCH')
            relative = original.relative_to(hosts[root['path']])
            need(str(relative) == sample.get('relativeSnapshotPath') and
                 sample.get('snapshotSource') == str(source_root / suffix / relative), 'SNAPSHOT_SAMPLE_ORIGIN_MISMATCH')
            digest, observed = evidence.digest_file(recovered)
            need(sample.get('sha256') == digest and type(sample.get('size')) is int and
                 sample['size'] == observed.st_size, 'EXPORTED_BYTES_CHANGED')
            exported = evidence.fresh(sample.get('exportedAt'), now)
            need(created <= exported <= finished and evidence.timestamp(operation['startedAt']) <= exported,
                 'EXPORT_OPERATION_TIME_INVALID')
            times.append(exported)
        # Use the earliest ACTUAL export completion, never a rehash/adapter timestamp.
        reference = share + ' ' + point['snapshotId'] + ' ' + point['snapshotTimestamp']
        provenance = {'version': 1, 'root': root, 'hostRoot': str(hosts[root['path']]),
                      'snapshotReference': reference, 'snapshotId': point['snapshotId'],
                      'snapshotCreatedAt': evidence.iso(created), 'exportedAt': evidence.iso(min(times)),
                      'exportDirectory': str(nas_state), 'metadataSource': 'SNAPSHOT_EXPORT_OPERATION',
                      'operationId': operation['operationId'], 'samples': samples}
        name = 'snapshot-provenance-' + str(index) + '.json'
        entries.append((name, provenance))
        normalized['mounts'][root['path']] = {'operator_attests_snapshot_export': True,
            'snapshot_reference': reference, 'snapshot_provenance': str(output_dir / name), 'samples': samples}
    with evidence.directory_fd(output_dir, private=True) as out:
        need(not os.listdir(out), 'EMPTY_PRIVATE_OUTPUT_REQUIRED')
        for name, provenance in entries:
            save_at(out, name, provenance)
        roots_value, _ = evidence.private_json(evidence.absolute_path(capture_dir) / 'roots.json')
        need(save_at(out, 'roots.json', roots_value) == value['rootsSHA256'], 'ROOT_MANIFEST_CHANGED')
        prepared_sha = save_at(out, 'nas-proof.json', normalized)
        # Reuse all generator checks (no signature) instead of implementing another byte/expiry validator.
        evidence.mount_evidence(output_dir / 'nas-proof.json', roots, hosts, now)
        load_capture(capture_dir)  # Namespace/mount/root may have changed during hashing.
        if not fixed_clock:
            completed = datetime.now(timezone.utc)
            evidence.fresh(operation['startedAt'], completed)
            for _, provenance in entries:
                evidence.fresh(provenance['exportedAt'], completed)
        need(evidence.private_json(nas_state / 'nas-proof.json')[1] == proof_sha and
             evidence.private_json(nas_state / 'nas-recovery-report.txt')[1] == report_sha, 'SOURCE_RECEIPT_CHANGED')
        save_at(out, 'input-receipt.json', {'version': 1, 'ownerId': value['ownerId'], 'scope': value['scope'],
            'sourceProofSHA256': proof_sha, 'sourceReportSHA256': report_sha, 'operationId': operation['operationId'],
            'rootsSHA256': value['rootsSHA256'], 'proofSHA256': prepared_sha, 'consentGranted': False})
    return {'result': 'PASS', 'roots': len(roots), 'consentGranted': False}


def publish(public_key, envelopes, store):
    """Local immutable copy only; never create mounts, change trust keys or consent."""
    need(1 <= len(envelopes) <= 32, 'ENVELOPE_COUNT_INVALID')
    key = evidence.read_private(public_key, limit=16384)
    store = evidence.absolute_path(store)
    with evidence.directory_fd(store) as base, evidence.directory_fd(store / 'evidence') as destination:
        need(all(os.fstat(fd).st_mode & 0o777 == 0o555 for fd in (base, destination)), 'PROTECTED_STORE_MODE_REQUIRED')
        with evidence.file_handle(store / 'public.pem') as (file, before):
            need(before.st_mode & 0o777 == 0o444 and before.st_nlink == 1 and file.read(16385) == key,
                 'INSTALLED_PUBLIC_KEY_MISMATCH')
        copies = {}
        for path in envelopes:
            path = evidence.absolute_path(path)
            raw = evidence.read_private(path)
            digest = hashlib.sha256(raw).hexdigest()
            need(path.name == digest + '.json' and path.name not in copies, 'ENVELOPE_DIGEST_OR_DUPLICATE_INVALID')
            envelope = json.loads(raw, object_pairs_hook=evidence.unique_object)
            need(type(envelope) is dict and set(envelope) == {'version', 'algorithm', 'payload', 'signature'} and
                 type(envelope['version']) is int and envelope['version'] == 1 and envelope['algorithm'] == 'Ed25519' and
                 type(envelope['payload']) is str and type(envelope['signature']) is str,
                 'SIGNED_ENVELOPE_REQUIRED')
            need(len(base64.b64decode(envelope['signature'], validate=True)) == 64 and
                 len(base64.b64decode(envelope['payload'], validate=True)) > 0, 'SIGNED_ENVELOPE_REQUIRED')
            read_command(['node', '--input-type=module', '-e', VERIFY],
                         evidence.compact_json({'key': key.decode('utf-8'), 'envelope': envelope}))
            copies[path.name] = raw
        # Verify every incoming envelope before copying any; existing files are never overwritten.
        for name, raw in copies.items():
            try:
                descriptor = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o444, dir_fd=destination)
            except FileExistsError:
                with evidence.file_handle(store / 'evidence' / name) as (file, observed):
                    need(observed.st_mode & 0o777 == 0o444 and observed.st_nlink == 1 and
                         observed.st_size == len(raw) and file.read(len(raw) + 1) == raw, 'EXISTING_ENVELOPE_CONFLICT')
                continue
            with os.fdopen(descriptor, 'wb') as file:
                os.fchmod(file.fileno(), 0o444)
                file.write(raw)
                file.flush()
                os.fsync(file.fileno())
            os.fsync(destination)
            with evidence.file_handle(store / 'evidence' / name) as (file, observed):
                need(observed.st_mode & 0o777 == 0o444 and observed.st_nlink == 1 and
                     file.read(len(raw) + 1) == raw, 'PUBLISHED_ENVELOPE_INVALID')
    return {'result': 'PASS', 'envelopes': len(copies), 'consentGranted': False}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    capture_parser = commands.add_parser('capture', help='read-only root collector in the existing server namespace')
    source = capture_parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--request', type=Path)
    source.add_argument('--library', type=Path, help='private JSON from read-only GET /api/libraries/{UUID}')
    prepare_parser = commands.add_parser('prepare', help='adapt a genuine completed NAS export, without signing')
    prepare_parser.add_argument('--capture-dir', type=Path, required=True)
    prepare_parser.add_argument('--nas-state', type=Path, required=True)
    for command in (capture_parser, prepare_parser):
        command.add_argument('--output-dir', type=Path, required=True)
    publish_parser = commands.add_parser('publish', help='local trust-store copy after separate operator approval; no mounts/consent')
    publish_parser.add_argument('--public-key', type=Path, required=True, help='operator SPKI PEM, 0600')
    publish_parser.add_argument('--envelope', type=Path, action='append', dest='envelopes', required=True)
    publish_parser.add_argument('--store', type=Path, required=True, help='existing operator directory, 0555')
    args = vars(parser.parse_args(argv))
    command = args.pop('command')
    if command == 'capture':
        args.setdefault('request', None)
    try:
        result = {'capture': capture, 'prepare': prepare, 'publish': publish}[command](**args)
    except Stop as error:
        print('FAIL ' + str(error), file=sys.stderr)
        return 1
    except (OSError, ValueError, TypeError, KeyError, OverflowError):
        print('FAIL PRIVATE_INPUT_OR_OUTPUT_INVALID', file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True, separators=(',', ':')))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
