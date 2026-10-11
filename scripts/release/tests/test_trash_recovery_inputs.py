"""Disposable Linux files plus mocked read-only Docker/NFS metadata; no production."""

import copy
import base64
from datetime import datetime, timedelta, timezone
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import trash_recovery_inputs as inputs
import trash_recovery_evidence as evidence

NAS_SCRIPT = SCRIPTS.parent / 'diagnostics/gallery-nas-recovery-565ef38.sh'
spec = importlib.util.spec_from_file_location('evidence_fixture', SCRIPTS / 'tests/test_trash_recovery_evidence.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
NOW = datetime(2026, 10, 11, 13, 0, tzinfo=timezone.utc)
OWNER = '00000000-0000-4000-8000-000000000001'
SCOPE = '00000000-0000-4000-8000-000000000011'


class RecoveryInputs(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        fixture.RecoveryEvidence.setUpClass()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.capture = self.base / 'capture'; self.capture.mkdir(mode=0o700)
        self.host = self.base / 'host'; self.host.mkdir()
        self.nas = self.base / 'nas'; self.nas.mkdir(mode=0o700)
        self.out = self.base / 'prepared'; self.out.mkdir(mode=0o700)
        self.signed = self.base / 'signed'; self.signed.mkdir(mode=0o700)
        self.root = {'path': '/external/owner', 'device': str(self.host.stat().st_dev),
            'inode': str(self.host.stat().st_ino), 'mountId': '31', 'mountNamespace': 'mnt:[synthetic]',
            'mountType': 'nfs', 'mountSource': '10.10.10.95:/volume1/homes/docice/Photos',
            'mountRoot': '/', 'mountTarget': '/external/owner'}
        self.request = self.base / 'request.json'
        fixture.save(self.request, {'version': 1, 'ownerId': OWNER, 'scope': SCOPE, 'roots': [self.root['path']]})
        self.mounts = [{'Destination': self.root['path'], 'Source': str(self.host), 'Type': 'bind', 'RW': True}]
        with self.current():
            inputs.capture(self.request, self.capture, NOW)
        self.manifest_sha = hashlib.sha256((self.capture / 'roots.json').read_bytes()).hexdigest()
        snapshot = 'GMT+03:00-2026.10.09-03.00.02'
        origin = '/homes/#snapshot/' + snapshot
        samples = []
        for kind in ('photo', 'video'):
            original, recovered = self.host / (kind + '.synthetic'), self.nas / (kind + '.bin')
            data = ('synthetic ' + kind).encode()
            original.write_bytes(data); recovered.write_bytes(data); recovered.chmod(0o600)
            samples.append({'kind': kind, 'original': str(original), 'recovered': str(recovered), 'size': len(data),
                'sha256': hashlib.sha256(data).hexdigest(), 'relativeSnapshotPath': original.name,
                'snapshotSource': origin + '/docice/Photos/' + original.name,
                'exportedAt': evidence.iso(NOW - timedelta(hours=1))})
        self.proof = {'mounts': {}, 'provenance': {'homes': {'snapshotId': snapshot,
            'snapshotTimestamp': '2026-10-09T03:00:02+03:00', 'snapshotRoot': origin,
            'metadataSource': 'DSM_SNAPSHOT_LIST', 'dsmSnapshotMetadata': {'time': snapshot},
            'nfsSnapshotAccessible': False, 'fileStationRootMetadata': {'path': origin, 'isdir': True}}},
            'recoveryOperation': {'version': 1, 'operationId': '00000000-0000-4000-8000-000000000099',
                'startedAt': evidence.iso(NOW - timedelta(hours=2)), 'completedAt': evidence.iso(NOW - timedelta(minutes=50)),
                'exportDirectory': str(self.nas), 'snapshotOriginConfirmed': True},
            'rootExports': [{'ownerId': OWNER, 'scope': SCOPE, 'root': self.root,
                'hostRoot': str(self.host), 'manifestSHA256': self.manifest_sha, 'share': 'homes',
                'snapshotRoot': origin + '/docice/Photos', 'samples': samples, 'result': 'PASS'}]}
        self.report = {'result': 'PASS', 'checks': {'NAS_RECOVERY': 'PASS'}, 'blockers': [], 'deploymentAuthorized': False}
        self.sync()

    def current(self):
        from contextlib import ExitStack
        stack = ExitStack()
        stack.enter_context(patch.object(inputs, 'container', return_value=('a' * 64, self.mounts)))
        stack.enter_context(patch.object(inputs, 'collect', return_value=[copy.deepcopy(self.root)]))
        return stack

    def sync(self):
        fixture.save(self.nas / 'nas-proof.json', self.proof)
        fixture.save(self.nas / 'nas-recovery-report.txt', self.report)

    def prepare(self):
        with self.current():
            return inputs.prepare(self.capture, self.nas, self.out, NOW)

    def test_actual_export_adapts_and_signs_with_existing_generator(self):
        before = {file: file.read_bytes() for folder in (self.nas, self.capture) for file in folder.iterdir()}
        self.assertEqual(self.prepare(), {'result': 'PASS', 'roots': 1, 'consentGranted': False})
        pg_backup = self.base / 'synthetic-backup.sql.gz'
        pg_backup.write_bytes(gzip.compress(b'synthetic sql restore')); pg_backup.chmod(0o600)
        pg_receipt = self.base / 'backup-verified.json'
        fixture.save(pg_receipt, {'restore': 'PASS_ISOLATED_SQL_TRANSACTION', 'productionChanged': False,
            'assetCount': 1, 'migrationCount': 1, 'checkedAt': evidence.iso(NOW - timedelta(minutes=30)),
            'postgresImage': 'sha256:' + 'a' * 64, 'backupPath': str(pg_backup),
            'backupSHA256': hashlib.sha256(pg_backup.read_bytes()).hexdigest()})
        key = self.base / 'synthetic-key.pem'
        key.write_text(fixture.RecoveryEvidence.private_key); key.chmod(0o600)
        args = {'owner_id': OWNER, 'scope': SCOPE, 'roots_path': self.out / 'roots.json', 'backup': pg_backup,
            'postgres_receipt': pg_receipt, 'nas_proof': self.out / 'nas-proof.json', 'now': NOW}
        result = evidence.generate(signing_key=key, output_dir=self.signed, **args)
        envelope = json.loads((self.signed / (result['evidenceSHA256'] + '.json')).read_bytes())
        self.assertTrue(fixture.verify(envelope, fixture.RecoveryEvidence.public_key))
        import base64
        payload = json.loads(base64.b64decode(envelope['payload']))
        self.assertEqual(payload['ownerId'], OWNER); self.assertEqual(payload['scope'], SCOPE)
        self.assertEqual(payload['expiresAt'], evidence.iso(NOW + timedelta(hours=23)))
        self.assertEqual(payload['mounts'][self.root['path']]['verifiedAt'], evidence.iso(NOW - timedelta(hours=1)))
        for file, data in before.items(): self.assertEqual(file.read_bytes(), data)
        self.assertTrue(all(stat.st_mode & 0o777 == 0o600 for stat in (file.stat() for file in self.out.iterdir())))
        for field, value in (('owner_id', '00000000-0000-4000-8000-000000000002'), ('scope', 'managed')):
            with self.subTest(field=field), patch.object(evidence, 'sign_payload') as signer:
                with self.assertRaisesRegex(evidence.Stop, 'PREPARED_OWNER_SCOPE_OR_ROOTS_MISMATCH'):
                    evidence.generate(signing_key=key, output_dir=self.signed, **{**args, field: value})
                signer.assert_not_called()

    def test_export_renewal_keeps_old_time_and_rejects_stale_samples(self):
        for sample in self.proof['rootExports'][0]['samples']:
            sample['exportedAt'] = evidence.iso(NOW - timedelta(hours=25))
        self.sync()
        with self.assertRaisesRegex(evidence.Stop, 'EVIDENCE_STALE_OR_FUTURE'): self.prepare()
        self.assertEqual(list(self.out.iterdir()), [])

    def test_legacy_report_is_not_upgraded_with_a_made_up_current_time(self):
        del self.proof['recoveryOperation']; self.sync()
        with self.assertRaisesRegex(evidence.Stop, 'NAS_EXPORT_RECEIPT_REQUIRED_RUN_DIAGNOSTIC'): self.prepare()

    def test_unconfirmed_snapshot_and_metadata_timestamp_fail(self):
        original = copy.deepcopy(self.proof)
        for change, message in (
            (lambda p: p['recoveryOperation'].update(snapshotOriginConfirmed=False), 'SNAPSHOT_NOT_CONFIRMED'),
            (lambda p: p['provenance']['homes']['dsmSnapshotMetadata'].update(time='other'), 'SNAPSHOT_NOT_CONFIRMED'),
            (lambda p: p['provenance']['homes'].update(snapshotTimestamp='2026-10-08T03:00:02+03:00'), 'SNAPSHOT_TIMESTAMP_MISMATCH'),
            (lambda p: p['rootExports'][0]['samples'][0].update(snapshotSource='/homes/live/photo'), 'SNAPSHOT_SAMPLE_ORIGIN_MISMATCH')):
            with self.subTest(message=message):
                self.proof = copy.deepcopy(original); change(self.proof); self.sync()
                with self.assertRaisesRegex(evidence.Stop, message): self.prepare()

    def test_mismatched_recovered_or_original_bytes_fail(self):
        recovered = Path(self.proof['rootExports'][0]['samples'][0]['recovered'])
        recovered.write_bytes(b'altered')
        with self.assertRaisesRegex(evidence.Stop, 'EXPORTED_BYTES_CHANGED'): self.prepare()
        self.assertEqual(list(self.out.iterdir()), [])
        original = Path(self.proof['rootExports'][0]['samples'][0]['original'])
        recovered.write_bytes(original.read_bytes())
        original.write_bytes(b'altered original')
        with self.assertRaisesRegex(evidence.Stop, 'RECOVERED_BYTES_DIFFER'): self.prepare()
        self.assertFalse((self.out / 'input-receipt.json').exists())

    def test_changed_nfs_root_or_namespace_and_wrong_owner_are_rejected(self):
        with self.current(), patch.object(inputs, 'collect', return_value=[{**self.root, 'mountId': '32'}]):
            with self.assertRaisesRegex(evidence.Stop, 'CONTAINER_OR_ROOT_CHANGED'):
                inputs.prepare(self.capture, self.nas, self.out, NOW)
        self.proof['rootExports'][0]['ownerId'] = '00000000-0000-4000-8000-000000000002'; self.sync()
        with self.assertRaisesRegex(evidence.Stop, 'EXACT_OWNER_SCOPE_EXPORT_REQUIRED'): self.prepare()

    def test_mismatched_host_inode_and_changed_container_rejected_in_capture(self):
        output = self.base / 'new'; output.mkdir(mode=0o700)
        with self.current(), patch.object(inputs, 'collect', return_value=[{**self.root, 'inode': '1'}]):
            with self.assertRaisesRegex(evidence.Stop, 'HOST_CONTAINER_ROOT_IDENTITY_MISMATCH'):
                inputs.capture(self.request, output, NOW)
        with self.current(), patch.object(inputs, 'container', side_effect=[('a' * 64, self.mounts), ('b' * 64, self.mounts)]):
            with self.assertRaisesRegex(evidence.Stop, 'ROOT_CHANGED_DURING_CAPTURE'):
                inputs.capture(self.request, output, NOW)
        self.assertEqual(list(output.iterdir()), [])

    def docker_mounts(self):
        # Eight complete records, including mounts unrelated to the protected root.
        return [
            {**mount, 'Name': '', 'Driver': '', 'Mode': 'rw', 'Propagation': 'rprivate',
             'Metadata': {'labels': {'first': 'one', 'second': 'two'}, 'options': ['one', 'two']}}
            for mount in [self.mounts[0], *[
                {'Destination': f'/unrelated/{number}', 'Source': str(self.base / f'other-{number}'),
                 'Type': 'bind', 'RW': True} for number in range(7)]]
        ]

    def capture_mounts(self, before, after, output):
        with self.current(), patch.object(inputs, 'container',
                side_effect=[('a' * 64, before), ('a' * 64, after)]):
            return inputs.capture(self.request, output, NOW)

    def test_capture_accepts_mount_permutations_without_dropping_duplicate_records(self):
        mounts = self.docker_mounts()
        for number, before in enumerate((mounts, [*mounts, copy.deepcopy(mounts[-1])])):
            with self.subTest(duplicate=bool(number)):
                output = self.base / f'permuted-{number}'; output.mkdir(mode=0o700)
                after = [dict(reversed(list(mount.items()))) for mount in reversed(copy.deepcopy(before))]
                for mount in after:
                    labels = mount['Metadata']['labels']
                    mount['Metadata']['labels'] = dict(reversed(list(labels.items())))
                original = copy.deepcopy(before)
                self.assertEqual(self.capture_mounts(before, after, output),
                                 {'result': 'PASS', 'roots': 1, 'consentGranted': False})
                self.assertEqual(before, original)
                manifest = json.loads((output / 'roots.json').read_bytes())
                self.assertEqual(manifest['roots'], [self.root])
                self.assertEqual(manifest['hostRoots'], {self.root['path']: str(self.host)})

    def test_capture_rejects_changes_to_every_mount_field_including_unrelated_mounts(self):
        before = self.docker_mounts()
        changes = {'Destination': '/other', 'Source': str(self.base / 'changed'), 'Type': 'volume',
                   'RW': False, 'Name': 'changed', 'Driver': 'local', 'Mode': 'ro', 'Propagation': 'shared',
                   'Metadata': {'labels': {'first': 'changed', 'second': 'two'}, 'options': ['one', 'two']}}
        for field, value in changes.items():
            with self.subTest(field=field):
                output = self.base / f'field-{field}'; output.mkdir(mode=0o700)
                after = copy.deepcopy(before); after[-1][field] = value
                with self.assertRaisesRegex(evidence.Stop, '^ROOT_CHANGED_DURING_CAPTURE$'):
                    self.capture_mounts(before, list(reversed(after)), output)
                self.assertEqual(list(output.iterdir()), [])

    def test_capture_rejects_added_removed_or_type_changed_mount_fields(self):
        before = self.docker_mounts()
        cases = []
        for field in before[-1]:
            after = copy.deepcopy(before); del after[-1][field]
            cases.append((f'removed-{field}', after))
        after = copy.deepcopy(before); after[-1]['UnknownField'] = 'new'
        cases.append(('added-field', after))
        after = copy.deepcopy(before); after[-1]['RW'] = 1
        cases.append(('boolean-to-integer', after))
        after = copy.deepcopy(before); after[-1]['Metadata']['options'].reverse()
        cases.append(('nested-list-order', after))
        for name, after in cases:
            with self.subTest(change=name):
                output = self.base / name; output.mkdir(mode=0o700)
                with self.assertRaisesRegex(evidence.Stop, '^ROOT_CHANGED_DURING_CAPTURE$'):
                    self.capture_mounts(before, after, output)
                self.assertEqual(list(output.iterdir()), [])

    def test_capture_rejects_added_removed_or_duplicated_mounts(self):
        before = self.docker_mounts()
        extra = {**before[-1], 'Destination': '/extra', 'Source': str(self.base / 'extra')}
        cases = {'added': [*before, extra], 'removed': before[:-1],
                 'duplicated': [*before, copy.deepcopy(before[-1])],
                 'duplicate-replaced-other': [*before[:-1], copy.deepcopy(before[-2])],
                 'equal-count-and-set-different-multiplicity': (
                     [*before, copy.deepcopy(before[-2])], [*before, copy.deepcopy(before[-1])])}
        for name, mounts in cases.items():
            with self.subTest(change=name):
                previous, after = mounts if isinstance(mounts, tuple) else (before, mounts)
                output = self.base / name; output.mkdir(mode=0o700)
                with self.assertRaisesRegex(evidence.Stop, '^ROOT_CHANGED_DURING_CAPTURE$'):
                    self.capture_mounts(previous, list(reversed(after)), output)
                self.assertEqual(list(output.iterdir()), [])

    def test_permuted_mounts_do_not_allow_changed_root_identity(self):
        output = self.base / 'changed-root'; output.mkdir(mode=0o700)
        mounts = self.docker_mounts()
        with self.current(), patch.object(inputs, 'collect',
                side_effect=[[self.root], [{**self.root, 'mountId': '32'}]]), \
                patch.object(inputs, 'container', side_effect=[('a' * 64, mounts), ('a' * 64, list(reversed(mounts)))]):
            with self.assertRaisesRegex(evidence.Stop, '^ROOT_CHANGED_DURING_CAPTURE$'):
                inputs.capture(self.request, output, NOW)
        self.assertEqual(list(output.iterdir()), [])

    def test_library_capture_reuses_actual_api_owner_uuid_and_import_paths(self):
        library = self.base / 'library.json'
        fixture.save(library, {'id': SCOPE, 'ownerId': OWNER, 'importPaths': [self.root['path']],
                              'name': 'Synthetic disposable library'})
        out = self.base / 'from-api'; out.mkdir(mode=0o700)
        with self.current(): inputs.capture(None, out, NOW, library=library)
        result = json.loads((out / 'capture.json').read_text())
        self.assertEqual((result['ownerId'], result['scope']), (OWNER, SCOPE))
        self.assertNotIn('name', result)

    def test_bind_selection_is_exact_and_never_reads_docker_environment(self):
        calls = []
        def run(command, input=None):
            calls.append(command)
            return json.dumps('a' * 64 if command[-2:] == ['{{json .Id}}', 'immich_server'] else self.mounts)
        with patch.object(inputs, 'read_command', side_effect=run):
            self.assertEqual(inputs.container(), ('a' * 64, self.mounts))
        self.assertTrue(all(command[:2] == inputs.DOCKER for command in calls))
        self.assertTrue(all('exec' not in command and '{{json .}}' not in command for command in calls))
        with self.assertRaisesRegex(evidence.Stop, 'ROOT_BIND_MOUNT_AMBIGUOUS'):
            inputs.host_mapping(self.root, self.mounts * 2)
        with self.assertRaisesRegex(evidence.Stop, 'ROOT_BIND_MOUNT_AMBIGUOUS'):
            inputs.host_mapping(self.root, [{**self.mounts[0], 'Type': 'volume'}])

    def test_read_only_command_errors_do_not_expose_private_stderr(self):
        from types import SimpleNamespace
        with patch.object(inputs.subprocess, 'run', return_value=SimpleNamespace(returncode=1, stdout=b'', stderr=b'private-secret')):
            with self.assertRaisesRegex(evidence.Stop, '^READ_ONLY_LOCAL_COMMAND_FAILED$'):
                inputs.read_command(['docker', 'inspect'])

    def test_no_snapshot_lock_for_managed_share_is_rejected(self):
        point = copy.deepcopy(self.proof['provenance']['homes'])
        self.proof['provenance']['Immich'] = point
        with self.assertRaisesRegex(evidence.Stop, 'SNAPSHOT_LOCK_NOT_CONFIRMED'):
            inputs.snapshot_metadata(self.proof, 'Immich')

    def test_real_synology_hour_only_snapshot_id_and_nfs_attestation(self):
        snapshot = 'GMT+03-2026.10.09-20.15.17'
        root = '/mnt/synology-immich-managed/#snapshot/' + snapshot
        self.proof['provenance']['Immich'] = {'snapshotId': snapshot, 'snapshotTimestamp': '2026-10-09T20:15:17+03:00',
            'snapshotRoot': root, 'metadataSource': 'NFS_DIRECTORY_ID_PLUS_DSM_OPERATOR_ATTESTATION',
            'dsmSnapshotMetadata': {'time': snapshot}, 'nfsSnapshotAccessible': True, 'fileStationRootMetadata': None}
        _, created, point = inputs.snapshot_metadata(self.proof, 'Immich')
        self.assertEqual(created, datetime(2026, 10, 9, 17, 15, 17, tzinfo=timezone.utc))
        self.assertEqual(str(point), root)
        self.proof['recoveryOperation']['snapshotOriginConfirmed'] = False
        with self.assertRaisesRegex(evidence.Stop, 'SNAPSHOT_NOT_CONFIRMED'):
            inputs.snapshot_metadata(self.proof, 'Immich')

    def test_nfs_coordinate_and_other_server_fail_closed(self):
        self.assertEqual(inputs.snapshot_location(self.root), ('homes', Path('docice/Photos')))
        aliased = {**self.root, 'mountSource': '10.10.10.95:/volume1/homes', 'mountRoot': '/docice',
                   'path': '/external/owner/Photos'}
        self.assertEqual(inputs.snapshot_location(aliased), ('homes', Path('docice/Photos')))
        for change in ({'mountType': 'ext4'}, {'mountSource': 'other-nas:/volume1/homes'},
                       {'mountSource': '10.10.10.95:/volume1/other'}, {'mountRoot': '/../'}):
            with self.subTest(change=change), self.assertRaises(evidence.Stop):
                inputs.snapshot_location({**self.root, **change})

    def test_index_uses_exact_owner_scope_and_preserves_root_bindings(self):
        index = self.base / 'index.json'; fixture.save(index, {'version': 1, 'captures': [str(self.capture)]})
        with self.current(): requests = inputs.load_requests(index)
        self.assertEqual(requests[0]['ownerId'], OWNER)
        self.assertEqual(requests[0]['snapshotSuffix'], 'docice/Photos')
        fixture.save(index, {'version': 1, 'captures': [str(self.capture)] * 2})
        with self.current(), self.assertRaisesRegex(evidence.Stop, 'DUPLICATE_OWNER_SCOPE'):
            inputs.load_requests(index)

    def test_three_distinct_owner_library_exports_are_never_interchanged(self):
        original = copy.deepcopy(self.proof['rootExports'][0])
        for number, name in enumerate(('docice', 'chudo_anna', 'Lenia'), 1):
            with self.subTest(owner=name):
                owner = f'00000000-0000-4000-8000-00000000000{number}'
                scope = f'00000000-0000-4000-8000-00000000001{number}'
                host = self.base / ('host-' + str(number)); host.mkdir()
                self.host = host
                self.root = {**self.root, 'path': '/external/' + name, 'mountTarget': '/external/' + name,
                             'inode': str(host.stat().st_ino), 'mountSource': '10.10.10.95:/volume1/homes/' + name + '/Photos'}
                self.mounts = [{'Destination': self.root['path'], 'Source': str(host), 'Type': 'bind'}]
                capture = self.base / ('capture-' + str(number)); capture.mkdir(mode=0o700)
                fixture.save(self.request, {'version': 1, 'ownerId': owner, 'scope': scope, 'roots': [self.root['path']]})
                with self.current(): inputs.capture(self.request, capture, NOW)
                digest = hashlib.sha256((capture / 'roots.json').read_bytes()).hexdigest()
                entry = copy.deepcopy(original)
                entry.update(ownerId=owner, scope=scope, root=self.root, hostRoot=str(host), manifestSHA256=digest,
                             snapshotRoot=self.proof['provenance']['homes']['snapshotRoot'] + '/' + name + '/Photos')
                for sample in entry['samples']:
                    basename = Path(sample['original']).name
                    original_file, exported = host / basename, self.nas / (name + '-' + sample['kind'] + '.bin')
                    data = ('synthetic ' + name + ' ' + sample['kind']).encode()
                    original_file.write_bytes(data); exported.write_bytes(data); exported.chmod(0o600)
                    sample.update(original=str(original_file), recovered=str(exported), size=len(data),
                                  sha256=hashlib.sha256(data).hexdigest(), snapshotSource=entry['snapshotRoot'] + '/' + basename)
                self.proof['rootExports'] = [entry]; self.sync()
                out = self.base / ('prepared-' + str(number)); out.mkdir(mode=0o700)
                with self.current(): inputs.prepare(capture, self.nas, out, NOW)
                context = json.loads((out / 'nas-proof.json').read_text())['authorization']
                self.assertEqual((context['ownerId'], context['scope']), (owner, scope))
                entry['ownerId'] = OWNER if owner != OWNER else '00000000-0000-4000-8000-000000000004'
                self.sync()
                other = self.base / ('reject-' + str(number)); other.mkdir(mode=0o700)
                with self.current(), self.assertRaisesRegex(evidence.Stop, 'EXACT_OWNER_SCOPE_EXPORT_REQUIRED'):
                    inputs.prepare(capture, self.nas, other, NOW)

    def test_interrupted_preparation_cannot_be_signed_without_completion_receipt(self):
        self.prepare()
        (self.out / 'input-receipt.json').unlink()
        with patch.object(evidence, 'sign_payload') as signer, self.assertRaises(FileNotFoundError):
            evidence.build_payload(owner_id=OWNER, scope=SCOPE, roots_path=self.out / 'roots.json',
                                   nas_proof=self.out / 'nas-proof.json', backup=self.base / 'absent.sql.gz',
                                   postgres_receipt=self.base / 'backup-verified.json', now=NOW)
        signer.assert_not_called()

    def test_output_is_never_overwritten(self):
        self.prepare()
        before = {file: file.read_bytes() for file in self.out.iterdir()}
        with self.assertRaisesRegex(evidence.Stop, 'EMPTY_PRIVATE_OUTPUT_REQUIRED'): self.prepare()
        for file, data in before.items(): self.assertEqual(file.read_bytes(), data)

    def trust_fixture(self, *, unsigned=False):
        store = self.base / 'trust'; store.mkdir()
        (store / 'evidence').mkdir()
        public = self.base / 'operator-public.pem'
        public.write_text(fixture.RecoveryEvidence.public_key); public.chmod(0o600)
        (store / 'public.pem').write_bytes(public.read_bytes()); (store / 'public.pem').chmod(0o444)
        key = self.base / 'operator-private.pem'
        key.write_text(fixture.RecoveryEvidence.private_key); key.chmod(0o600)
        payload = evidence.compact_json({'synthetic': 'signature/publication fixture only'})
        envelope = {'version': 1, 'algorithm': 'Ed25519', 'payload': base64.b64encode(payload).decode(),
                    'signature': evidence.sign_payload(payload, key)}
        if unsigned: del envelope['signature']
        raw = evidence.compact_json(envelope)
        file = self.signed / (hashlib.sha256(raw).hexdigest() + '.json')
        file.write_bytes(raw); file.chmod(0o600)
        (store / 'evidence').chmod(0o555); store.chmod(0o555)
        return store, public, file

    @unittest.skipUnless(os.geteuid() == 0, 'new publication into 0555 host store needs operator/root capability')
    def test_publish_real_signed_bytes_is_immutable_and_idempotent(self):
        store, public, file = self.trust_fixture()
        result = inputs.publish(public, [file], store)
        self.assertEqual(result, {'result': 'PASS', 'envelopes': 1, 'consentGranted': False})
        target = store / 'evidence' / file.name
        self.assertEqual(target.read_bytes(), file.read_bytes())
        self.assertEqual(target.stat().st_mode & 0o777, 0o444); self.assertEqual(target.stat().st_nlink, 1)
        self.assertEqual(inputs.publish(public, [file], store), result)
        before = target.read_bytes()
        target.chmod(0o600); target.write_bytes(b'unexpected existing bytes'); target.chmod(0o444)
        with self.assertRaisesRegex(evidence.Stop, 'EXISTING_ENVELOPE_CONFLICT'):
            inputs.publish(public, [file], store)
        self.assertEqual(target.read_bytes(), b'unexpected existing bytes')
        self.assertNotEqual(target.read_bytes(), before)

    def test_publish_unsigned_proof_is_rejected_before_store_copy(self):
        store, public, file = self.trust_fixture(unsigned=True)
        with self.assertRaisesRegex(evidence.Stop, 'SIGNED_ENVELOPE_REQUIRED'):
            inputs.publish(public, [file], store)
        self.assertEqual(list((store / 'evidence').iterdir()), [])

    def test_publish_refuses_replacing_installed_public_key_or_bad_signature(self):
        store, public, file = self.trust_fixture()
        valid = public.read_bytes()
        public.write_bytes(b'other key')
        with self.assertRaisesRegex(evidence.Stop, 'INSTALLED_PUBLIC_KEY_MISMATCH'):
            inputs.publish(public, [file], store)
        public.write_bytes(valid)
        envelope = json.loads(file.read_bytes()); envelope['signature'] = base64.b64encode(bytes(64)).decode()
        raw = evidence.compact_json(envelope)
        altered = self.signed / (hashlib.sha256(raw).hexdigest() + '.json')
        altered.write_bytes(raw); altered.chmod(0o600)
        with self.assertRaises(evidence.Stop): inputs.publish(public, [altered], store)
        self.assertEqual(list((store / 'evidence').iterdir()), [])

    def test_cli_does_not_print_private_paths_or_grant_consent(self):
        from contextlib import redirect_stderr, redirect_stdout
        self.proof['recoveryOperation']['startedAt'] = evidence.iso(NOW - timedelta(days=30))
        self.sync()
        with self.current(), redirect_stdout(io.StringIO()) as out, redirect_stderr(io.StringIO()) as err:
            self.assertEqual(inputs.main(['prepare', '--capture-dir', str(self.capture), '--nas-state', str(self.nas),
                                        '--output-dir', str(self.out)]), 1)
        self.assertEqual(out.getvalue(), '')
        self.assertNotIn(str(self.base), err.getvalue())


class ExportReceiptCapture(unittest.TestCase):
    """Execute the actual diagnostic's streaming export on disposable source files."""
    def test_export_records_real_completion_not_file_mtime(self):
        import types
        module = types.ModuleType('diagnostic_fixture')
        source = NAS_SCRIPT.read_text().split("python3 - <<'PY'\n", 1)[1].rsplit('\nPY\n', 1)[0]
        exec(compile(source, str(NAS_SCRIPT), 'exec'), module.__dict__)
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            snapshot, live, out = base / 'snapshot', base / 'live', base / 'private'
            snapshot.mkdir(); live.mkdir(); out.mkdir(mode=0o700)
            file = snapshot / 'photo.heic'; original = live / 'photo.heic'
            file.write_bytes(b'synthetic photo bytes'); original.write_bytes(file.read_bytes())
            start = datetime.now(timezone.utc)
            result = module.recover(file, original, out / 'photo.bin', None, {'written': 0, 'snapshotRoot': snapshot})
            self.assertTrue(start <= evidence.timestamp(result['exportedAt']) <= datetime.now(timezone.utc))
            self.assertEqual(result['snapshotSource'], str(file))
            self.assertEqual(result['sha256'], hashlib.sha256(original.read_bytes()).hexdigest())
            self.assertEqual(file.read_bytes(), original.read_bytes())

    def test_real_diagnostic_main_emits_compatible_per_root_export_receipts(self):
        from contextlib import redirect_stdout
        import trash_release
        module = types.ModuleType('diagnostic_end_to_end_fixture')
        source = NAS_SCRIPT.read_text().split("python3 - <<'PY'\n", 1)[1].rsplit('\nPY\n', 1)[0]
        exec(compile(source, str(NAS_SCRIPT), 'exec'), module.__dict__)
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            state, old, homes, managed = (base / label for label in ('new-nas', 'old', 'homes', 'Immich'))
            for point in (state, old, homes, managed): point.mkdir(mode=0o700)
            points = {'homes': homes / '#snapshot/GMT+03-2026.10.09-03.00.02',
                      'Immich': managed / ('#snapshot/' + module.IMMICH_POINT)}
            for point in points.values(): point.mkdir(parents=True)
            roots = {'homes': (str(homes), '/volume1/homes'), 'managed': (str(managed), '/volume1/Immich')}
            samples = {'photo.png': b'\x89PNG\r\n\x1a\nsynthetic-header-fixture',
                       'video.mp4': b'\x00\x00\x00\x18ftypisom\x00\x00\x00\x00synthetic-header-fixture'}
            for owner in ('docice', 'chudo_anna', 'Lenia'):
                live = homes / owner / 'Photos'; live.mkdir(parents=True)
                snapshot = points['homes'] / owner / 'Photos'; snapshot.mkdir(parents=True)
                roots[owner] = (str(live), '/volume1/homes/' + owner + '/Photos')
                for name, data in samples.items():
                    (live / name).write_bytes(data); (snapshot / name).write_bytes(data)
            for point in (managed, points['Immich']):
                (point / 'upload/synthetic-owner').mkdir(parents=True)
                for name, data in samples.items(): (point / 'upload/synthetic-owner' / name).write_bytes(data)
            fixture.save(old / 'recovery-report.txt', {'checks': {'POSTGRES_RESTORE': 'PASS'}})
            fixture.save(old / 'backup-verified.json', {'restore': 'PASS_ISOLATED_SQL_TRANSACTION', 'productionChanged': False})
            audit = base / 'audit.json'
            fixture.save(audit, {'backendReadOnlyAudit': {'errors': [], 'sections': {str(i): 'PASS' for i in range(10)}},
                'containers': [{'role': 'immich_server', 'externalMounts': [
                    {'containerMountpoint': '/external/' + label, 'hostMountpoint': value[0]}
                    for label, value in roots.items()]}]})
            original_receipt = (old / 'backup-verified.json').read_bytes()
            host = Path(roots['docice'][0])
            root = {'path': '/external/docice', 'device': str(host.stat().st_dev), 'inode': str(host.stat().st_ino),
                'mountId': '31', 'mountNamespace': 'mnt:[synthetic]', 'mountType': 'nfs',
                'mountSource': '10.10.10.95:/volume1/homes/docice/Photos', 'mountRoot': '/', 'mountTarget': '/external/docice'}
            mounts = [{'Type': 'bind', 'Source': str(host), 'Destination': root['path']}]
            capture = base / 'capture'; capture.mkdir(mode=0o700)
            request = base / 'request.json'; fixture.save(request, {'version': 1, 'ownerId': OWNER, 'scope': SCOPE, 'roots': [root['path']]})
            index = base / 'captures.json'; fixture.save(index, {'version': 1, 'captures': [str(capture)]})
            answers = iter([str(old), str(audit), 'YES'])
            def mount(path):
                if path == state: return {'fstype': 'ext4'}
                _, export = next(value for value in roots.values() if value[0] == str(path))
                return {'target': str(path), 'source': '10.10.10.95:' + export, 'fstype': 'nfs',
                        'options': 'ro' if path == homes else 'rw'}
            helper = types.SimpleNamespace(nas_check=trash_release.nas_check, Stop=trash_release.Stop)
            with patch.object(inputs, 'container', return_value=('a' * 64, mounts)), \
                 patch.object(inputs, 'collect', return_value=[root]):
                inputs.capture(request, capture)
                with patch.object(module, 'ROOTS', roots), patch.object(module, 'mount', side_effect=mount), \
                     patch.object(module, 'get_tool', return_value=helper), \
                     patch.object(module.pwd, 'getpwuid', return_value=types.SimpleNamespace(pw_name='doctoriceadm')), \
                     patch.object(module.tempfile, 'mkdtemp', return_value=str(state)), \
                     patch.object(module, 'ask', side_effect=lambda _: next(answers)), \
                     patch.dict(os.environ, {'GALLERY_NAS_RECOVERY_CAPTURES': str(index),
                         'GALLERY_RECOVERY_SCRIPT_DIR': str(NAS_SCRIPT.parent)}), redirect_stdout(io.StringIO()) as output:
                    self.assertEqual(module.main(), 0, output.getvalue())
                prepared = base / 'prepared'; prepared.mkdir(mode=0o700)
                self.assertEqual(inputs.prepare(capture, state, prepared)['result'], 'PASS')
            proof = json.loads((state / 'nas-proof.json').read_text())
            self.assertEqual(len(proof['rootExports']), 1)
            self.assertEqual(proof['rootExports'][0]['result'], 'PASS')
            self.assertEqual((old / 'backup-verified.json').read_bytes(), original_receipt)
            report = json.loads((state / 'nas-recovery-report.txt').read_text())
            self.assertEqual(report['checks']['POSTGRES_RESTORE'], 'PASS_REUSED_NO_RESTORE')
            self.assertEqual(report['checks']['PREVIOUS_EVIDENCE'], 'PASS_UNCHANGED')

    def test_snapshot_override_is_selection_not_fabricated_provenance(self):
        module = types.ModuleType('diagnostic_snapshot_selection_fixture')
        source = NAS_SCRIPT.read_text().split("python3 - <<'PY'\n", 1)[1].rsplit('\nPY\n', 1)[0]
        exec(compile(source, str(NAS_SCRIPT), 'exec'), module.__dict__)
        actual = 'GMT+03-2026.10.11-03.00.02'
        with patch.object(module, 'SNAPSHOT_IDS', {'homes': actual}):
            self.assertTrue(module.wanted('homes', actual))
            self.assertFalse(module.wanted('homes', 'GMT+03-2026.10.09-03.00.02'))
        with patch.object(module, 'SNAPSHOT_IDS', {'homes': 'made-up-proof'}):
            with self.assertRaisesRegex(module.Stop, 'ACTUAL_SNAPSHOT_ID_REQUIRED'):
                module.wanted('homes', actual)


if __name__ == '__main__':
    unittest.main()
