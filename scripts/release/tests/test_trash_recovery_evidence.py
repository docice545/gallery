"""Recovery evidence signing with synthetic SQL, mount identities and media only."""

from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timedelta, timezone
import base64
import copy
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location('trash_recovery_evidence', ROOT / 'scripts/release/trash_recovery_evidence.py')
evidence = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(evidence)
NOW = datetime(2026, 10, 10, 12, 0, 0, tzinfo=timezone.utc)


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    path.chmod(0o600)


def verify(envelope, public):
    program = """
import {verify} from 'node:crypto';
let input=''; for await(const part of process.stdin) input+=part;
const {envelope,publicKey}=JSON.parse(input);
process.exitCode=verify(null,Buffer.from(envelope.payload,'base64'),publicKey,
                       Buffer.from(envelope.signature,'base64')) ? 0 : 1;
"""
    result = subprocess.run(['node', '--input-type=module', '-e', program],
                            input=json.dumps({'envelope': envelope, 'publicKey': public}).encode(),
                            capture_output=True, timeout=30)
    return result.returncode == 0


class RecoveryEvidence(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        program = """
const {generateKeyPairSync}=require('node:crypto');
const pair=generateKeyPairSync('ed25519');
process.stdout.write(JSON.stringify({
  private:pair.privateKey.export({format:'pem',type:'pkcs8'}),
  public:pair.publicKey.export({format:'pem',type:'spki'})}));
"""
        result = subprocess.run(['node', '-e', program], capture_output=True, check=True, timeout=30)
        keys = json.loads(result.stdout)
        cls.private_key, cls.public_key = keys['private'], keys['public']

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.output = self.base / 'operator-output'; self.output.mkdir(mode=0o700)
        self.backup = self.base / 'synthetic-backup.sql.gz'
        self.backup.write_bytes(gzip.compress(b'-- synthetic restore already checked\nSELECT 1;\n'))
        self.backup.chmod(0o600)
        self.key = self.base / 'synthetic-ed25519.pem'
        self.key.write_text(self.private_key); self.key.chmod(0o600)
        self.receipt_path = self.base / 'backup-verified.json'
        self.receipt = {
            'backupSHA256': hashlib.sha256(self.backup.read_bytes()).hexdigest(),
            'backupPath': str(self.backup), 'backupModifiedAt': evidence.iso(NOW - timedelta(hours=3)),
            'checkedAt': evidence.iso(NOW - timedelta(hours=2)), 'assetCount': 7, 'migrationCount': 3,
            'restore': 'PASS_ISOLATED_SQL_TRANSACTION', 'productionChanged': False,
            'postgresImage': 'sha256:' + 'a' * 64,
        }
        save(self.receipt_path, self.receipt)
        self.roots_path = self.base / 'roots.json'
        self.proof_path = self.base / 'nas-proof.json'
        self.manifest = {'version': 1, 'roots': [], 'hostRoots': {}}
        self.proof = {'mounts': {}}
        self.provenance = {}
        self.provenance_paths = {}
        for index, path in enumerate(('/data/photos', '/external/nas')):
            host = self.base / ('host-' + str(index)); host.mkdir()
            export = self.base / ('export-' + str(index)); export.mkdir()
            root = {'path': path, 'device': str(host.stat().st_dev), 'inode': str(host.stat().st_ino),
                    'mountId': str(index + 31), 'mountNamespace': 'mnt:[synthetic]',
                    'mountType': 'ext4' if index == 0 else 'nfs4',
                    'mountSource': 'synthetic:/volume' + str(index), 'mountRoot': '/', 'mountTarget': path}
            self.manifest['roots'].append(root)
            self.manifest['hostRoots'][path] = str(host)
            samples = []
            for kind in ('photo', 'video'):
                original, recovered = host / (kind + '.synthetic'), export / (kind + '.synthetic')
                content = ('synthetic-' + kind + '-' + str(index)).encode()
                original.write_bytes(content); recovered.write_bytes(content)
                samples.append({'kind': kind, 'original': str(original), 'recovered': str(recovered)})
            provenance_path = self.base / ('snapshot-export-' + str(index) + '.json')
            provenance = {
                'version': 1, 'root': root, 'hostRoot': str(host), 'snapshotReference': 'synthetic-reference-' + str(index),
                'snapshotId': 'synthetic-snapshot-' + str(index),
                'snapshotCreatedAt': evidence.iso(NOW - timedelta(days=2)),
                'exportedAt': evidence.iso(NOW - timedelta(hours=index + 1)),
                'exportDirectory': str(export), 'metadataSource': 'SNAPSHOT_EXPORT_OPERATION',
                'operationId': 'synthetic-export-' + str(index), 'samples': copy.deepcopy(samples),
            }
            self.provenance[path], self.provenance_paths[path] = provenance, provenance_path
            save(provenance_path, provenance)
            self.proof['mounts'][path] = {
                'operator_attests_snapshot_export': True,
                'snapshot_reference': provenance['snapshotReference'],
                'snapshot_provenance': str(provenance_path), 'samples': samples,
            }
        save(self.roots_path, self.manifest); save(self.proof_path, self.proof)
        self.arguments = {'owner_id': 'synthetic-owner', 'scope': 'synthetic-library',
                          'roots_path': self.roots_path, 'backup': self.backup,
                          'postgres_receipt': self.receipt_path, 'nas_proof': self.proof_path, 'now': NOW}

    def sync(self):
        save(self.roots_path, self.manifest); save(self.proof_path, self.proof)
        save(self.receipt_path, self.receipt)
        for path, value in self.provenance.items():
            save(self.provenance_paths[path], value)

    def generate(self, **changes):
        return evidence.generate(signing_key=self.key, output_dir=self.output, **{**self.arguments, **changes})

    def assert_rejected_before_key(self, expected=None, **changes):
        with patch.object(evidence, 'sign_payload') as signing:
            if expected:
                with self.assertRaisesRegex(evidence.Stop, expected):
                    self.generate(**changes)
            else:
                with self.assertRaises((evidence.Stop, OSError)):
                    self.generate(**changes)
            signing.assert_not_called()
        self.assertEqual(list(self.output.iterdir()), [])

    def test_real_ed25519_signature_exact_envelope_digest_private_output(self):
        receipt_bytes = self.receipt_path.read_bytes()
        result = self.generate()
        file = self.output / (result['evidenceSHA256'] + '.json')
        raw = file.read_bytes(); envelope = json.loads(raw)
        self.assertEqual(set(envelope), {'version', 'algorithm', 'payload', 'signature'})
        self.assertEqual(envelope['version'], 1); self.assertEqual(envelope['algorithm'], 'Ed25519')
        self.assertEqual(hashlib.sha256(raw).hexdigest(), result['evidenceSHA256'])
        self.assertEqual(file.stat().st_mode & 0o777, 0o600)
        self.assertEqual(len(base64.b64decode(envelope['signature'], validate=True)), 64)
        self.assertTrue(verify(envelope, self.public_key))
        payload_bytes = base64.b64decode(envelope['payload'], validate=True)
        payload = json.loads(payload_bytes)
        self.assertEqual(payload_bytes, evidence.compact_json(payload))
        self.assertEqual(payload['roots'], self.manifest['roots'])
        self.assertEqual(payload['verifiedAt'], evidence.iso(NOW))
        self.assertEqual(payload['expiresAt'], evidence.iso(NOW + timedelta(hours=22)))
        self.assertEqual(payload['postgres']['receiptSHA256'], hashlib.sha256(receipt_bytes).hexdigest())
        self.assertEqual(self.receipt_path.read_bytes(), receipt_bytes)
        for path, mount in payload['mounts'].items():
            self.assertEqual(mount['snapshotProvenanceSHA256'],
                             hashlib.sha256(self.provenance_paths[path].read_bytes()).hexdigest())
            self.assertEqual(mount['verifiedAt'], self.provenance[path]['exportedAt'])
            self.assertEqual({sample['kind'] for sample in mount['samples']}, {'photo', 'video'})
            for sample, original in zip(mount['samples'], self.proof['mounts'][path]['samples']):
                media = Path(original['original']).read_bytes()
                self.assertEqual(sample, {'kind': original['kind'], 'sha256': hashlib.sha256(media).hexdigest(), 'size': len(media)})
        self.assertNotIn(str(self.base), payload_bytes.decode())
        self.assertNotIn('snapshotId', payload_bytes.decode())
        altered = dict(envelope); altered['payload'] = base64.b64encode(payload_bytes + b' ').decode()
        self.assertFalse(verify(altered, self.public_key))

    def test_managed_scope_requires_and_covers_every_supplied_root(self):
        payload = evidence.build_payload(**{**self.arguments, 'scope': 'managed'})
        self.assertEqual(payload['scope'], 'managed')
        self.assertEqual(set(payload['mounts']), set(self.manifest['hostRoots']))
        del self.proof['mounts']['/data/photos']; self.sync()
        self.assert_rejected_before_key('ROOT_COVERAGE_INVALID', scope='managed')

    def test_root_order_is_irrelevant(self):
        first = evidence.build_payload(**self.arguments)
        self.manifest['roots'].reverse(); self.sync()
        self.assertEqual(evidence.build_payload(**self.arguments), first)

    def test_extra_photo_samples_are_retained_and_verified(self):
        path = '/data/photos'
        original = Path(self.manifest['hostRoots'][path]) / 'extra-photo.synthetic'
        recovered = Path(self.provenance[path]['exportDirectory']) / original.name
        original.write_bytes(b'synthetic-extra-photo'); recovered.write_bytes(original.read_bytes())
        sample = {'kind': 'photo', 'original': str(original), 'recovered': str(recovered)}
        self.proof['mounts'][path]['samples'].append(sample)
        self.provenance[path]['samples'].append(copy.deepcopy(sample)); self.sync()
        payload = evidence.build_payload(**self.arguments)
        self.assertEqual(len(payload['mounts'][path]['samples']), 3)
        self.assertIn({'kind': 'photo', 'sha256': hashlib.sha256(original.read_bytes()).hexdigest(),
                       'size': original.stat().st_size}, payload['mounts'][path]['samples'])
        recovered.write_bytes(b'synthetic-corrupted-extra-photo')
        self.assert_rejected_before_key('RECOVERED_BYTES_DIFFER')

    def test_root_and_sample_count_limits_reject_before_signing(self):
        original = copy.deepcopy(self.manifest)
        self.manifest['roots'] = self.manifest['roots'] * 65; self.sync()
        self.assert_rejected_before_key('ROOT_MANIFEST_INVALID')
        self.manifest = original
        self.proof['mounts']['/data/photos']['samples'] *= 65; self.sync()
        self.assert_rejected_before_key('PHOTO_VIDEO_SAMPLES_REQUIRED')

    def test_noncanonical_root_paths_and_oversized_identity_strings_reject_before_signing(self):
        original = copy.deepcopy(self.manifest)
        for path in ('/', '/data//photos', '/data/photos/', '/data/./photos',
                     '/data/../photos', '//data/photos'):
            with self.subTest(path=path):
                self.manifest = copy.deepcopy(original); self.manifest['roots'][0]['path'] = path; self.sync()
                self.assert_rejected_before_key()
        self.manifest = original
        self.manifest['roots'][0]['mountSource'] = 'x' * 4097; self.sync()
        self.assert_rejected_before_key('ROOT_IDENTITY_INVALID')
        self.manifest['roots'][0]['mountSource'] = '\U0001f600' * 2049; self.sync()
        self.assert_rejected_before_key('ROOT_IDENTITY_INVALID')
        for fields in ({'owner_id': 'x' * 4097}, {'scope': 'x' * 4097}):
            self.assert_rejected_before_key('OWNER_AND_SCOPE_REQUIRED', **fields)

    def test_submillisecond_remaining_lifetime_rejects_before_signing(self):
        self.receipt['checkedAt'] = evidence.iso(NOW - timedelta(hours=24) + timedelta(microseconds=500))
        self.sync(); self.assert_rejected_before_key('EVIDENCE_EXPIRES_NOW')

    def test_actual_clock_issuance_uses_verification_completion_time(self):
        completed = NOW + timedelta(minutes=1)
        with patch.object(evidence, 'datetime') as clock:
            clock.now.side_effect = [NOW, completed]
            clock.fromisoformat.side_effect = datetime.fromisoformat
            payload = evidence.build_payload(**{**self.arguments, 'now': None})
        self.assertEqual(payload['verifiedAt'], evidence.iso(completed))
        self.assertEqual(payload['expiresAt'], evidence.iso(NOW + timedelta(hours=22)))
        self.assertEqual(clock.now.call_count, 2)

    def test_backup_hashing_crossing_freshness_boundary_rejects_before_key(self):
        self.receipt['checkedAt'] = evidence.iso(NOW - timedelta(hours=23, minutes=59)); self.sync()
        with patch.object(evidence, 'datetime') as clock, patch.object(
                evidence, 'digest_file', wraps=evidence.digest_file) as digests:
            # Model a slow backup/media verification without sleeping or real data.
            clock.now.side_effect = [NOW, NOW + timedelta(minutes=2)]
            clock.fromisoformat.side_effect = datetime.fromisoformat
            self.assert_rejected_before_key('EVIDENCE_STALE_OR_FUTURE', now=None)
        self.assertEqual(digests.call_count, 9)  # Backup plus both copies of four samples.
        self.assertEqual(clock.now.call_count, 2)

    def test_export_hashing_crossing_freshness_boundary_rejects_before_key(self):
        self.provenance['/data/photos']['exportedAt'] = evidence.iso(NOW - timedelta(hours=23, minutes=59))
        self.sync()
        with patch.object(evidence, 'datetime') as clock:
            clock.now.side_effect = [NOW, NOW + timedelta(minutes=2)]
            clock.fromisoformat.side_effect = datetime.fromisoformat
            self.assert_rejected_before_key('EVIDENCE_STALE_OR_FUTURE', now=None)

    def test_requested_validity_can_shorten_but_never_extend_receipt_freshness(self):
        payload = evidence.build_payload(**{**self.arguments, 'valid_for_hours': 1})
        self.assertEqual(payload['expiresAt'], evidence.iso(NOW + timedelta(hours=1)))
        self.receipt['checkedAt'] = evidence.iso(NOW - timedelta(hours=23, minutes=59)); self.sync()
        payload = evidence.build_payload(**self.arguments)
        self.assertEqual(payload['expiresAt'], evidence.iso(NOW + timedelta(minutes=1)))
        for validity in (0, 25, True, '24'):
            with self.subTest(validity=validity):
                self.assert_rejected_before_key('VALIDITY_MUST_BE_1_TO_24_HOURS', valid_for_hours=validity)

    def test_existing_file_is_never_overwritten(self):
        result = self.generate()
        file = self.output / (result['evidenceSHA256'] + '.json'); before = file.read_bytes()
        with self.assertRaises(FileExistsError): self.generate()
        self.assertEqual(file.read_bytes(), before)
        self.assertEqual(len(list(self.output.iterdir())), 1)

    def test_backup_byte_mismatch_and_fabricated_receipt_status_fail_before_key(self):
        for field, value in (('backupSHA256', 'b' * 64), ('productionChanged', True),
                             ('restore', 'PASS'), ('backupPath', '/synthetic/wrong'),
                             ('postgresImage', 'postgres:latest'), ('assetCount', 0),
                             ('migrationCount', True), ('assetCount', 2**53)):
            with self.subTest(field=field, value=value):
                old = self.receipt[field]; self.receipt[field] = value; self.sync()
                self.assert_rejected_before_key()
                self.receipt[field] = old
        self.sync()
        self.backup.write_bytes(b'changed bytes')
        self.assert_rejected_before_key('BACKUP_BYTES_DO_NOT_MATCH_RECEIPT')

    def private_backup_copy(self):
        copied = self.base / 'private-copy.sql.gz'
        copied.write_bytes(self.backup.read_bytes()); copied.chmod(0o600)
        self.backup.chmod(0o644)
        return copied

    def test_identical_private_backup_copy_keeps_original_receipt_and_signed_contract(self):
        copied = self.private_backup_copy()
        receipt_bytes = self.receipt_path.read_bytes()
        original_bytes = self.backup.read_bytes()
        original_stat = self.backup.stat()
        result = self.generate(backup=copied)
        envelope = json.loads((self.output / (result['evidenceSHA256'] + '.json')).read_bytes())
        self.assertTrue(verify(envelope, self.public_key))
        postgres = json.loads(base64.b64decode(envelope['payload']))['postgres']
        self.assertEqual(set(postgres), {'backupSHA256', 'receiptSHA256', 'checkedAt', 'restore',
                                        'productionChanged', 'assetCount', 'migrationCount', 'postgresImage'})
        self.assertEqual(postgres['backupSHA256'], hashlib.sha256(copied.read_bytes()).hexdigest())
        self.assertEqual(postgres['receiptSHA256'], hashlib.sha256(receipt_bytes).hexdigest())
        self.assertEqual(postgres['checkedAt'], self.receipt['checkedAt'])
        self.assertEqual(postgres['postgresImage'], self.receipt['postgresImage'])
        self.assertEqual(self.receipt_path.read_bytes(), receipt_bytes)
        self.assertEqual(json.loads(receipt_bytes)['backupPath'], str(self.backup))
        self.assertEqual(self.backup.read_bytes(), original_bytes)
        self.assertEqual((self.backup.stat().st_mode, self.backup.stat().st_mtime_ns),
                         (original_stat.st_mode, original_stat.st_mtime_ns))
        self.assertEqual(copied.stat().st_mode & 0o777, 0o600)

    def test_private_backup_copy_with_wrong_bytes_is_rejected_before_key(self):
        copied = self.private_backup_copy(); copied.write_bytes(b'not the restored backup')
        self.assert_rejected_before_key('BACKUP_BYTES_DO_NOT_MATCH_RECEIPT', backup=copied)

    def test_private_backup_copy_does_not_refresh_a_stale_or_future_restore_receipt(self):
        copied = self.private_backup_copy()
        for offset in (timedelta(hours=-25), timedelta(seconds=1)):
            with self.subTest(offset=offset):
                self.receipt['checkedAt'] = evidence.iso(NOW + offset); self.sync()
                self.assert_rejected_before_key('EVIDENCE_STALE_OR_FUTURE', backup=copied)

    def test_private_backup_copy_rejects_replaced_source_bytes_and_wrong_receipt_source(self):
        copied = self.private_backup_copy()
        original = self.backup.read_bytes(); self.backup.write_bytes(b'replaced original')
        self.assert_rejected_before_key('SOURCE_BACKUP_BYTES_DO_NOT_MATCH_RECEIPT', backup=copied)
        self.backup.write_bytes(original)
        other = self.base / 'not-the-restored-source.sql.gz'; other.write_bytes(b'other backup')
        self.receipt['backupPath'] = str(other); self.sync()
        self.assert_rejected_before_key('SOURCE_BACKUP_BYTES_DO_NOT_MATCH_RECEIPT', backup=copied)

    def test_private_copy_still_requires_0600_and_no_symlinks_or_traversal(self):
        copied = self.private_backup_copy(); copied.chmod(0o644)
        self.assert_rejected_before_key('PRIVATE_0600_INPUT_REQUIRED', backup=copied)
        copied.chmod(0o600)
        link = self.base / 'copy-link'; link.symlink_to(copied)
        self.assert_rejected_before_key(backup=link)
        directory = self.base / 'copy-parent'; directory.mkdir()
        parent_link = self.base / 'copy-parent-link'; parent_link.symlink_to(self.base, target_is_directory=True)
        self.assert_rejected_before_key(backup=parent_link / copied.name)
        self.assert_rejected_before_key('ABSOLUTE_PATH_REQUIRED', backup=directory / '..' / copied.name)

    def test_private_copy_rejects_symlink_or_invalid_source_paths(self):
        copied = self.private_backup_copy()
        original = self.base / 'saved-original'; self.backup.rename(original)
        self.backup.symlink_to(original)
        self.assert_rejected_before_key(backup=copied)
        self.backup.unlink(); original.rename(self.backup)
        for path in (None, '', 'relative.sql.gz', str(self.base / '..' / self.base.name / self.backup.name)):
            with self.subTest(source=path):
                self.receipt['backupPath'] = path; self.sync()
                self.assert_rejected_before_key('ABSOLUTE_PATH_REQUIRED', backup=copied)
        directory = self.base / 'source-parent'; directory.mkdir()
        source = directory / self.backup.name; self.backup.rename(source)
        self.receipt['backupPath'] = str(source); self.sync()
        directory.rename(self.base / 'relocated-source'); directory.symlink_to(self.base / 'relocated-source')
        self.assert_rejected_before_key(backup=copied)

    def test_restore_receipt_changed_during_copy_hashing_is_never_signed(self):
        copied = self.private_backup_copy()
        digest = evidence.digest_file
        def hash_then_change_receipt(path, **kwargs):
            result = digest(path, **kwargs)
            if path == copied:
                self.receipt['backupPath'] = str(copied)
                save(self.receipt_path, self.receipt)
            return result
        with patch.object(evidence, 'digest_file', side_effect=hash_then_change_receipt):
            self.assert_rejected_before_key('RESTORE_RECEIPT_CHANGED_DURING_VERIFICATION', backup=copied)

    def test_existing_receipt_named_contract_is_required(self):
        alias = self.base / 'operator-claim.json'; save(alias, self.receipt)
        self.assert_rejected_before_key('EXISTING_RESTORE_RECEIPT_REQUIRED', postgres_receipt=alias)

    def test_receipt_export_freshness_future_and_expiry_boundaries(self):
        for offset in (timedelta(hours=-24, seconds=-1), timedelta(seconds=1)):
            with self.subTest(source='postgres', offset=offset):
                self.receipt['checkedAt'] = evidence.iso(NOW + offset); self.sync()
                self.assert_rejected_before_key('EVIDENCE_STALE_OR_FUTURE')
        self.receipt['checkedAt'] = evidence.iso(NOW - timedelta(hours=2))
        for offset in (timedelta(hours=-24, seconds=-1), timedelta(seconds=1)):
            with self.subTest(source='snapshot-export', offset=offset):
                self.provenance['/data/photos']['exportedAt'] = evidence.iso(NOW + offset); self.sync()
                self.assert_rejected_before_key('EVIDENCE_STALE_OR_FUTURE')
        self.provenance['/data/photos']['exportedAt'] = evidence.iso(NOW - timedelta(hours=24)); self.sync()
        self.assert_rejected_before_key('EVIDENCE_EXPIRES_NOW')

    def test_future_snapshot_timestamp_is_rejected_without_signing(self):
        self.provenance['/data/photos']['snapshotCreatedAt'] = evidence.iso(NOW + timedelta(seconds=1)); self.sync()
        self.assert_rejected_before_key('SNAPSHOT_TIMESTAMP_INVALID')

    def test_naive_non_utc_and_invalid_timestamps_rejected(self):
        for value in ('2026-10-10T10:00:00', '2026-10-10T10:00:00+01:00',
                      '2026-13-10T10:00:00Z', '2026-10-10', None):
            with self.subTest(value=value):
                self.receipt['checkedAt'] = value; self.sync()
                self.assert_rejected_before_key('UTC_TIMESTAMP_REQUIRED')

    def test_private_source_files_required_and_no_key_read_on_source_failure(self):
        for path in (self.backup, self.receipt_path, self.roots_path, self.proof_path,
                     *self.provenance_paths.values()):
            with self.subTest(path=path.name):
                path.chmod(0o644)
                with patch.object(evidence, 'read_private', wraps=evidence.read_private) as read:
                    self.assert_rejected_before_key('PRIVATE_0600_INPUT_REQUIRED')
                    self.assertNotIn(self.key, [call.args[0] for call in read.call_args_list])
                path.chmod(0o600)

    def test_key_mode_and_wrong_key_type_are_rejected_with_no_output(self):
        self.key.chmod(0o644)
        with self.assertRaisesRegex(evidence.Stop, 'PRIVATE_0600_INPUT_REQUIRED'): self.generate()
        self.key.chmod(0o600); self.key.write_text('synthetic invalid private PEM')
        with self.assertRaisesRegex(evidence.Stop, 'ED25519_SIGNING_FAILED'): self.generate()
        result = subprocess.run(['node', '-e', "const{generateKeyPairSync}=require('crypto');process.stdout.write(generateKeyPairSync('ec',{namedCurve:'prime256v1'}).privateKey.export({format:'pem',type:'pkcs8'}));"],
                                capture_output=True, check=True)
        self.key.write_bytes(result.stdout)
        with self.assertRaisesRegex(evidence.Stop, 'ED25519_SIGNING_FAILED'): self.generate()
        self.assertEqual(list(self.output.iterdir()), [])

    def test_output_directory_is_private_and_symlink_free(self):
        self.output.chmod(0o755)
        self.assert_rejected_before_key('PRIVATE_OUTPUT_DIRECTORY_REQUIRED')
        self.output.chmod(0o700)
        link = self.base / 'output-link'; link.symlink_to(self.output, target_is_directory=True)
        with patch.object(evidence, 'sign_payload') as signing:
            with self.assertRaises(OSError):
                evidence.generate(signing_key=self.key, output_dir=link, **self.arguments)
            signing.assert_not_called()

    def test_symlink_input_leaf_and_parent_are_rejected(self):
        link = self.base / 'backup-link'; link.symlink_to(self.backup)
        self.assert_rejected_before_key(backup=link)
        leaf = Path(self.proof['mounts']['/data/photos']['samples'][0]['original'])
        content = leaf.read_bytes(); leaf.unlink(); leaf.symlink_to(Path(self.proof['mounts']['/external/nas']['samples'][0]['original']))
        self.assert_rejected_before_key()
        leaf.unlink(); leaf.write_bytes(content)
        host = Path(self.manifest['hostRoots']['/data/photos'])
        actual = self.base / 'relocated-host'; host.rename(actual); host.symlink_to(actual, target_is_directory=True)
        self.assert_rejected_before_key()

    def test_hardlinked_recovery_is_rejected_even_when_hashes_match(self):
        sample = self.proof['mounts']['/data/photos']['samples'][0]
        recovered = Path(sample['recovered']); recovered.unlink(); os.link(sample['original'], recovered)
        self.assert_rejected_before_key('SEPARATE_RECOVERED_INODE_REQUIRED')

    def test_different_restored_bytes_and_empty_samples_are_rejected(self):
        sample = self.proof['mounts']['/data/photos']['samples'][0]
        recovered = Path(sample['recovered']); before = recovered.read_bytes()
        recovered.write_bytes(b'x' * len(before))
        self.assert_rejected_before_key('RECOVERED_BYTES_DIFFER')
        recovered.write_bytes(b'')
        self.assert_rejected_before_key('FILE_SIZE_INVALID')

    def test_each_root_needs_photo_and_video_attestation_and_provenance(self):
        mount = self.proof['mounts']['/data/photos']
        old = copy.deepcopy(mount)
        for field, value in (('operator_attests_snapshot_export', False), ('snapshot_reference', ''),
                             ('snapshot_provenance', None), ('samples', old['samples'][:1])):
            with self.subTest(field=field):
                self.proof['mounts']['/data/photos'] = {**old, field: value}; self.sync()
                self.assert_rejected_before_key()

    def test_provenance_must_bind_identity_reference_operation_paths_and_samples(self):
        path = '/data/photos'; original = copy.deepcopy(self.provenance[path])
        for field, value in (('root', {**original['root'], 'mountNamespace': 'mnt:[other]'}),
                             ('snapshotReference', 'synthetic-other'), ('hostRoot', str(self.base)),
                             ('snapshotId', ''), ('operationId', ''),
                             ('metadataSource', 'MANUALLY_RECONSTRUCTED'), ('samples', [])):
            with self.subTest(field=field):
                self.provenance[path] = {**original, field: value}; self.sync()
                self.assert_rejected_before_key()

    def test_original_must_be_under_appropriate_host_root(self):
        sample = self.proof['mounts']['/data/photos']['samples'][0]
        sample['original'] = self.proof['mounts']['/external/nas']['samples'][0]['original']
        self.provenance['/data/photos']['samples'] = copy.deepcopy(self.proof['mounts']['/data/photos']['samples'])
        self.sync(); self.assert_rejected_before_key('ORIGINAL_OUTSIDE_APPROPRIATE_ROOT')

    def test_recovery_must_be_under_export_and_outside_all_deletion_roots(self):
        sample = self.proof['mounts']['/data/photos']['samples'][0]
        sample['recovered'] = self.proof['mounts']['/external/nas']['samples'][0]['original']
        self.provenance['/data/photos']['samples'] = copy.deepcopy(self.proof['mounts']['/data/photos']['samples'])
        self.sync(); self.assert_rejected_before_key('RECOVERED_OUTSIDE_EXPORT_OR_INSIDE_DELETION_ROOT')

    def test_export_directory_cannot_contain_or_be_inside_any_host_root(self):
        for export in (str(self.base), self.manifest['hostRoots']['/external/nas']):
            with self.subTest(export=export):
                self.provenance['/data/photos']['exportDirectory'] = export; self.sync()
                self.assert_rejected_before_key('EXPORT_OVERLAPS_DELETION_ROOT')

    def test_root_manifest_duplicate_incomplete_extra_and_changed_identity_fail(self):
        original = copy.deepcopy(self.manifest)
        cases = [copy.deepcopy(original) for _ in range(4)]
        cases[0]['roots'].append(cases[0]['roots'][0])
        cases[1]['hostRoots'].pop('/data/photos')
        cases[2]['hostRoots']['/synthetic/extra'] = str(self.base)
        cases[3]['roots'][0]['inode'] = 'changed'
        for manifest in cases:
            with self.subTest(manifest=manifest):
                self.manifest = manifest; self.sync(); self.assert_rejected_before_key()

    def test_duplicate_json_keys_are_rejected(self):
        self.roots_path.write_text('{"version":1,"version":1}')
        self.assert_rejected_before_key('DUPLICATE_JSON_KEY')

    def test_backup_changed_during_hash_rejects_before_key(self):
        actual_digest = evidence.hashlib.file_digest
        def digest_then_modify(handle, algorithm):
            result = actual_digest(handle, algorithm)
            self.backup.write_bytes(b'synthetic-concurrent-backup-change')
            return result
        with patch.object(evidence.hashlib, 'file_digest', side_effect=digest_then_modify):
            self.assert_rejected_before_key('INPUT_CHANGED_DURING_READ')

    def test_main_stdout_has_only_digest_metadata_and_failure_hides_private_paths(self):
        argv = ['--owner-id', 'synthetic-owner', '--scope', 'managed', '--roots', str(self.roots_path),
                '--backup', str(self.backup), '--postgres-receipt', str(self.receipt_path),
                '--nas-proof', str(self.proof_path), '--signing-key', str(self.key), '--output-dir', str(self.output)]
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(evidence, 'datetime') as clock, redirect_stdout(stdout), redirect_stderr(stderr):
            clock.now.return_value = NOW; clock.fromisoformat.side_effect = datetime.fromisoformat
            self.assertEqual(evidence.main(argv), 0)
        self.assertEqual(set(json.loads(stdout.getvalue())), {'version', 'evidenceSHA256', 'bytes'})
        self.assertEqual(stderr.getvalue(), '')
        self.assertNotIn(str(self.base), stdout.getvalue())
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(evidence, 'generate', side_effect=OSError('PRIVATE_SECRET ' + str(self.base))), redirect_stdout(stdout), redirect_stderr(stderr):
            self.assertEqual(evidence.main(argv), 1)
        self.assertEqual(stdout.getvalue(), '')
        self.assertEqual(stderr.getvalue(), 'FAIL PRIVATE_INPUT_OR_OUTPUT_INVALID\n')


if __name__ == '__main__':
    unittest.main()
