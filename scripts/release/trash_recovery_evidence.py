#!/usr/bin/env python3
"""Create signed recovery evidence from existing private restore/export evidence.

No Docker, API, restore, snapshot, deployment, or server mutation is performed.
The operator signing key is read only after byte and provenance checks pass.
"""

import argparse
import base64
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys


ROOT_FIELDS = {
    'path', 'device', 'inode', 'mountId', 'mountNamespace', 'mountType',
    'mountSource', 'mountRoot', 'mountTarget',
}
PROVENANCE_FIELDS = {
    'version', 'root', 'hostRoot', 'snapshotReference', 'snapshotId',
    'snapshotCreatedAt', 'exportedAt', 'exportDirectory', 'metadataSource',
    'operationId', 'samples',
}
MAX_JSON_BYTES = 1024 * 1024
MAX_SAFE_INTEGER = 2**53 - 1
FRESHNESS = timedelta(hours=24)
EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)
NODE_SIGN = r'''
import {createPrivateKey, createPublicKey, sign, verify} from 'node:crypto';
let input = '';
for await (const part of process.stdin) input += part;
try {
  const {key, payload} = JSON.parse(input);
  const privateKey = createPrivateKey(key);
  if (privateKey.asymmetricKeyType !== 'ed25519') throw new Error();
  const bytes = Buffer.from(payload, 'base64');
  const signature = sign(null, bytes, privateKey);
  if (signature.length !== 64 || !verify(null, bytes, createPublicKey(privateKey), signature)) throw new Error();
  process.stdout.write(signature.toString('base64'));
} catch {
  process.exitCode = 1;
}
'''


class Stop(Exception):
    """Only fixed, non-private error codes may be displayed."""


def need(condition, code):
    if not condition:
        raise Stop(code)


def nonempty(value):
    if not isinstance(value, str) or not value.strip() or '\x00' in value:
        return False
    try:
        # Match the verifier's JavaScript string.length bound (UTF-16 code units).
        return len(value.encode('utf-16-le')) <= 8192
    except UnicodeError:
        return False


def absolute_path(value):
    need(nonempty(str(value)) if isinstance(value, Path) else nonempty(value), 'ABSOLUTE_PATH_REQUIRED')
    path = Path(value)
    need(path.is_absolute() and '..' not in path.parts, 'ABSOLUTE_PATH_REQUIRED')
    return path


@contextmanager
def directory_fd(value, *, private=False):
    """Walk via descriptors so neither parent nor leaf symlinks are followed."""
    path = absolute_path(value)
    descriptor = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[1:]:
            next_descriptor = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                      dir_fd=descriptor)
            os.close(descriptor)
            descriptor = next_descriptor
        if private:
            need(stat.S_IMODE(os.fstat(descriptor).st_mode) == 0o700, 'PRIVATE_OUTPUT_DIRECTORY_REQUIRED')
        yield descriptor
    finally:
        os.close(descriptor)


@contextmanager
def file_handle(value, *, private=False):
    path = absolute_path(value)
    with directory_fd(path.parent) as parent:
        descriptor = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    try:
        observed = os.fstat(descriptor)
        need(stat.S_ISREG(observed.st_mode), 'REGULAR_FILE_REQUIRED')
        if private:
            need(stat.S_IMODE(observed.st_mode) == 0o600, 'PRIVATE_0600_INPUT_REQUIRED')
        with os.fdopen(descriptor, 'rb', closefd=False) as handle:
            yield handle, observed
    finally:
        os.close(descriptor)


def identity(observed):
    return (observed.st_dev, observed.st_ino, observed.st_size,
            observed.st_mtime_ns, observed.st_ctime_ns)


def read_private(value, *, limit=MAX_JSON_BYTES):
    with file_handle(value, private=True) as (handle, before):
        need(0 < before.st_size <= limit, 'PRIVATE_INPUT_SIZE_INVALID')
        data = handle.read(limit + 1)
        need(len(data) == before.st_size and identity(before) == identity(os.fstat(handle.fileno())),
             'INPUT_CHANGED_DURING_READ')
        return data


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        need(key not in result, 'DUPLICATE_JSON_KEY')
        result[key] = value
    return result


def private_json(value):
    raw = read_private(value)
    try:
        result = json.loads(raw.decode('utf-8'), object_pairs_hook=unique_object,
                            parse_constant=lambda _: (_ for _ in ()).throw(Stop('INVALID_JSON')))
    except (UnicodeError, ValueError):
        raise Stop('INVALID_JSON') from None
    need(type(result) is dict, 'JSON_OBJECT_REQUIRED')
    return result, hashlib.sha256(raw).hexdigest()


def timestamp(value):
    need(isinstance(value, str) and re.fullmatch(
        r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|\+00:00)', value),
        'UTC_TIMESTAMP_REQUIRED')
    try:
        return datetime.fromisoformat(value.replace('Z', '+00:00'))
    except ValueError:
        raise Stop('UTC_TIMESTAMP_REQUIRED') from None


def fresh(value, now):
    observed = timestamp(value)
    need(now - FRESHNESS <= observed <= now, 'EVIDENCE_STALE_OR_FUTURE')
    return observed


def iso(value):
    return value.isoformat(timespec='microseconds').replace('+00:00', 'Z')


def root_identity(value):
    need(type(value) is dict and set(value) == ROOT_FIELDS and
         all(nonempty(value[field]) for field in ROOT_FIELDS), 'ROOT_IDENTITY_INVALID')
    path = absolute_path(value['path'])
    need(value['path'] != '/' and not value['path'].startswith('//') and
         str(path) == value['path'], 'ROOT_IDENTITY_INVALID')
    return dict(value)


def read_roots(value):
    manifest, _ = private_json(value)
    need(set(manifest) == {'version', 'roots', 'hostRoots'} and type(manifest['version']) is int and
         manifest['version'] == 1 and type(manifest['roots']) is list and 1 <= len(manifest['roots']) <= 128 and
         type(manifest['hostRoots']) is dict, 'ROOT_MANIFEST_INVALID')
    roots = sorted((root_identity(item) for item in manifest['roots']), key=lambda item: item['path'])
    paths = {item['path'] for item in roots}
    need(len(paths) == len(roots) and set(manifest['hostRoots']) == paths, 'ROOT_COVERAGE_INVALID')
    host_roots = {path: absolute_path(host) for path, host in manifest['hostRoots'].items()}
    for host in host_roots.values():
        with directory_fd(host):
            pass
    return roots, host_roots


def digest_file(value, *, private=False):
    with file_handle(value, private=private) as (handle, before):
        need(0 < before.st_size <= MAX_SAFE_INTEGER, 'FILE_SIZE_INVALID')
        digest = hashlib.file_digest(handle, 'sha256').hexdigest()
        need(identity(before) == identity(os.fstat(handle.fileno())), 'INPUT_CHANGED_DURING_READ')
        return digest, before


def postgres_evidence(backup, receipt_path, now):
    backup = absolute_path(backup)
    need(absolute_path(receipt_path).name == 'backup-verified.json', 'EXISTING_RESTORE_RECEIPT_REQUIRED')
    receipt, receipt_hash = private_json(receipt_path)
    checked = fresh(receipt.get('checkedAt'), now)
    need(receipt.get('restore') == 'PASS_ISOLATED_SQL_TRANSACTION' and
         receipt.get('productionChanged') is False and
         isinstance(receipt.get('postgresImage'), str) and
         re.fullmatch(r'sha256:[0-9a-f]{64}', receipt['postgresImage']) and
         all(type(receipt.get(key)) is int and 0 < receipt[key] <= MAX_SAFE_INTEGER
             for key in ('assetCount', 'migrationCount')), 'RESTORE_RECEIPT_INVALID')
    source = absolute_path(receipt.get('backupPath'))
    backup_hash, _ = digest_file(backup, private=True)
    need(receipt.get('backupSHA256') == backup_hash, 'BACKUP_BYTES_DO_NOT_MATCH_RECEIPT')
    if source != backup:
        # A root-owned 0644 restore source may need a separate 0600 signing copy.
        # Verify both byte identities without rewriting the restore receipt or
        # following source symlinks; the submitted copy stays strictly private.
        source_hash, _ = digest_file(source)
        need(source_hash == backup_hash, 'SOURCE_BACKUP_BYTES_DO_NOT_MATCH_RECEIPT')
    _, current_receipt_hash = private_json(receipt_path)
    need(current_receipt_hash == receipt_hash, 'RESTORE_RECEIPT_CHANGED_DURING_VERIFICATION')
    return {
        'backupSHA256': backup_hash, 'receiptSHA256': receipt_hash,
        'checkedAt': receipt['checkedAt'], 'restore': receipt['restore'],
        'productionChanged': False, 'assetCount': receipt['assetCount'],
        'migrationCount': receipt['migrationCount'], 'postgresImage': receipt['postgresImage'],
    }, checked


def sample_paths(samples):
    need(type(samples) is list and 2 <= len(samples) <= 128, 'PHOTO_VIDEO_SAMPLES_REQUIRED')
    normalized = []
    for sample in samples:
        need(type(sample) is dict and sample.get('kind') in ('photo', 'video') and
             {'kind', 'original', 'recovered'} <= set(sample), 'SAMPLE_INVALID')
        normalized.append({'kind': sample['kind'], 'original': str(absolute_path(sample['original'])),
                           'recovered': str(absolute_path(sample['recovered']))})
    need({sample['kind'] for sample in normalized} == {'photo', 'video'}, 'PHOTO_VIDEO_SAMPLES_REQUIRED')
    result = sorted(normalized, key=lambda item: (item['kind'], item['original'], item['recovered']))
    need(len({(item['kind'], item['original'], item['recovered']) for item in result}) == len(result),
         'DUPLICATE_SAMPLE')
    return result


def mount_evidence(proof_path, roots, host_roots, now):
    proof, _ = private_json(proof_path)
    mounts = proof.get('mounts')
    need(type(mounts) is dict and set(mounts) == set(host_roots), 'ROOT_COVERAGE_INVALID')
    results, export_times = {}, []
    for root in roots:
        path, host = root['path'], host_roots[root['path']]
        evidence = mounts[path]
        need(type(evidence) is dict and evidence.get('operator_attests_snapshot_export') is True and
             nonempty(evidence.get('snapshot_reference')), 'SNAPSHOT_EXPORT_ATTESTATION_REQUIRED')
        samples = sample_paths(evidence.get('samples'))
        provenance, provenance_hash = private_json(absolute_path(evidence.get('snapshot_provenance')))
        need(set(provenance) == PROVENANCE_FIELDS and type(provenance['version']) is int and
             provenance['version'] == 1 and root_identity(provenance['root']) == root and
             provenance['hostRoot'] == str(host) and
             provenance['snapshotReference'] == evidence['snapshot_reference'] and
             nonempty(provenance['snapshotId']) and nonempty(provenance['operationId']) and
             provenance['metadataSource'] == 'SNAPSHOT_EXPORT_OPERATION' and
             sample_paths(provenance['samples']) == samples, 'SNAPSHOT_PROVENANCE_BINDING_INVALID')
        exported = fresh(provenance['exportedAt'], now)
        need(timestamp(provenance['snapshotCreatedAt']) <= exported, 'SNAPSHOT_TIMESTAMP_INVALID')
        export = absolute_path(provenance['exportDirectory'])
        with directory_fd(export):
            pass
        need(not any(export.is_relative_to(point) or point.is_relative_to(export)
                     for point in host_roots.values()), 'EXPORT_OVERLAPS_DELETION_ROOT')
        recovered_samples = []
        for sample in samples:
            original, recovered = Path(sample['original']), Path(sample['recovered'])
            need(original.is_relative_to(host), 'ORIGINAL_OUTSIDE_APPROPRIATE_ROOT')
            need(recovered.is_relative_to(export) and
                 not any(recovered.is_relative_to(point) for point in host_roots.values()),
                 'RECOVERED_OUTSIDE_EXPORT_OR_INSIDE_DELETION_ROOT')
            original_hash, original_stat = digest_file(original)
            recovered_hash, recovered_stat = digest_file(recovered)
            need((original_stat.st_dev, original_stat.st_ino) !=
                 (recovered_stat.st_dev, recovered_stat.st_ino), 'SEPARATE_RECOVERED_INODE_REQUIRED')
            need(original_hash == recovered_hash and original_stat.st_size == recovered_stat.st_size,
                 'RECOVERED_BYTES_DIFFER')
            recovered_samples.append({'kind': sample['kind'], 'sha256': original_hash,
                                      'size': original_stat.st_size})
        results[path] = {
            'snapshotReferenceSHA256': hashlib.sha256(evidence['snapshot_reference'].encode('utf-8')).hexdigest(),
            'snapshotProvenanceSHA256': provenance_hash,
            'verifiedAt': provenance['exportedAt'], 'samples': recovered_samples,
        }
        export_times.append(exported)
    return results, export_times


def build_payload(*, owner_id, scope, roots_path, backup, postgres_receipt, nas_proof,
                  valid_for_hours=24, now=None):
    fixed_clock = now is not None
    now = now or datetime.now(timezone.utc)
    need(nonempty(owner_id) and nonempty(scope), 'OWNER_AND_SCOPE_REQUIRED')
    need(type(valid_for_hours) is int and 1 <= valid_for_hours <= 24, 'VALIDITY_MUST_BE_1_TO_24_HOURS')
    roots, hosts = read_roots(roots_path)
    proof, proof_hash = private_json(nas_proof)
    if 'authorization' in proof:
        binding = proof['authorization']
        _, roots_hash = private_json(roots_path)
        need(type(binding) is dict and set(binding) == {'version', 'ownerId', 'scope', 'rootsSHA256', 'inputReceipt'} and
             type(binding['version']) is int and binding['version'] == 1 and
             binding['ownerId'] == owner_id and binding['scope'] == scope and binding['rootsSHA256'] == roots_hash,
             'PREPARED_OWNER_SCOPE_OR_ROOTS_MISMATCH')
        receipt, _ = private_json(absolute_path(binding['inputReceipt']))
        need(type(receipt.get('version')) is int and receipt['version'] == 1 and receipt.get('consentGranted') is False and
             receipt.get('ownerId') == owner_id and receipt.get('scope') == scope and
             receipt.get('rootsSHA256') == roots_hash and receipt.get('proofSHA256') == proof_hash,
             'PREPARED_INPUT_RECEIPT_INVALID')
    postgres, checked = postgres_evidence(backup, postgres_receipt, now)
    mounts, exported = mount_evidence(nas_proof, roots, hosts, now)
    if not fixed_clock:
        # Hashing a real backup can take minutes. Issuance is completion time,
        # and every original recovery timestamp must still be fresh then.
        now = datetime.now(timezone.utc)
        checked = fresh(postgres['checkedAt'], now)
        exported = [fresh(mount['verifiedAt'], now) for mount in mounts.values()]
    expiry = min(now + timedelta(hours=valid_for_hours), checked + FRESHNESS,
                 *(point + FRESHNESS for point in exported))
    # JavaScript Date.parse keeps millisecond precision; do not emit evidence
    # whose tiny remaining lifetime disappears when the server parses it.
    def milliseconds(point):
        elapsed = point - EPOCH
        return (elapsed.days * 86400 + elapsed.seconds) * 1000 + elapsed.microseconds // 1000
    need(milliseconds(expiry) > milliseconds(now), 'EVIDENCE_EXPIRES_NOW')
    return {'version': 1, 'ownerId': owner_id, 'scope': scope, 'roots': roots,
            'verifiedAt': iso(now), 'expiresAt': iso(expiry), 'postgres': postgres, 'mounts': mounts}


def compact_json(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode('utf-8')


def sign_payload(payload, key_path):
    # All source/receipt/sample validation is complete before this function runs.
    key = read_private(key_path, limit=16384)
    try:
        request = compact_json({'key': key.decode('utf-8'), 'payload': base64.b64encode(payload).decode('ascii')})
        result = subprocess.run(['node', '--input-type=module', '-e', NODE_SIGN], input=request,
                                capture_output=True, timeout=30, check=False)
        need(result.returncode == 0, 'ED25519_SIGNING_FAILED')
        signature = base64.b64decode(result.stdout, validate=True)
    except (UnicodeError, ValueError, subprocess.SubprocessError):
        raise Stop('ED25519_SIGNING_FAILED') from None
    need(len(signature) == 64, 'ED25519_SIGNING_FAILED')
    return base64.b64encode(signature).decode('ascii')


def generate(*, signing_key, output_dir, **arguments):
    payload = compact_json(build_payload(**arguments))
    # Check the output directory before reading the signing key as well.
    with directory_fd(output_dir, private=True) as destination:
        signature = sign_payload(payload, signing_key)
        envelope = compact_json({'version': 1, 'algorithm': 'Ed25519',
                                 'payload': base64.b64encode(payload).decode('ascii'), 'signature': signature})
        need(len(envelope) <= MAX_JSON_BYTES, 'ENVELOPE_TOO_LARGE')
        digest = hashlib.sha256(envelope).hexdigest()
        descriptor = os.open(digest + '.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=destination)
        with os.fdopen(descriptor, 'wb') as handle:
            # Preserve 0600 even when the operator's umask removes owner permissions.
            os.fchmod(handle.fileno(), 0o600)
            handle.write(envelope)
            handle.flush()
            os.fsync(handle.fileno())
        os.fsync(destination)
    return {'version': 1, 'evidenceSHA256': digest, 'bytes': len(envelope)}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--owner-id', required=True)
    parser.add_argument('--scope', required=True, help='managed (lowercase) or the exact library UUID')
    parser.add_argument('--roots', required=True, type=Path, dest='roots_path')
    parser.add_argument('--backup', required=True, type=Path)
    parser.add_argument('--postgres-receipt', required=True, type=Path)
    parser.add_argument('--nas-proof', required=True, type=Path)
    parser.add_argument('--signing-key', required=True, type=Path)
    parser.add_argument('--output-dir', required=True, type=Path)
    parser.add_argument('--valid-for-hours', type=int, default=24)
    try:
        result = generate(**vars(parser.parse_args(argv)))
    except Stop as error:
        print('FAIL ' + str(error), file=sys.stderr)
        return 1
    except (OSError, ValueError, TypeError, KeyError, OverflowError):
        # Paths, media names, PEMs, subprocess stderr and receipt contents are private.
        print('FAIL PRIVATE_INPUT_OR_OUTPUT_INVALID', file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True, separators=(',', ':')))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
