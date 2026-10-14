"""Recovery-generation guards using disposable files and mocked DB/Docker only."""
from contextlib import ExitStack, redirect_stdout
from datetime import datetime, timedelta, timezone
import fcntl
import io
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build11_operator as m
import gallery_entry as entry

SOURCE = 'a' * 40
CANDIDATE = 'sha256:' + 'b' * 64
ROLLBACK = 'sha256:' + 'c' * 64


def timestamp(hours=0):
    return (datetime.now(timezone.utc) + timedelta(hours=hours)).isoformat()


class RecoveryRefresh(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.state = self.root / 'state'
        self.state.mkdir(mode=0o700)
        self.nas = self.root / 'nas'
        self.nas.mkdir(mode=0o700)
        m.core.save(self.nas / 'nas-verified.json', {'verifiedAt': timestamp()})
        m.core.save(self.nas / 'nas-proof.json', {'fixture': 'mock-only synthetic provenance'})
        m.core.save(self.nas / 'nas-recovery-report.txt', {'fixture': 'not actual NAS verification'})
        (self.state / 'image-state').mkdir(mode=0o700)
        self.plan = {'sourceCommit': SOURCE, 'candidateImage': CANDIDATE, 'rollbackImage': ROLLBACK,
                     'rollbackSource': 'd' * 40, 'serverVersion': {'major': 5, 'minor': 7, 'patch': 3},
                     'rollbackVersion': {'major': 5, 'minor': 7, 'patch': 2}}
        m.core.save(self.state / 'image-state/image-plan.json', self.plan)
        self.write_evidence(self.state, fresh=False)
        self.current = {'Id': 'synthetic-server', 'Image': CANDIDATE}
        self.args = SimpleNamespace(state=self.state, nas_evidence=self.nas)

    def write_evidence(self, directory, fresh=True):
        backup = directory / 'fresh-immich.sql.gz'
        backup.write_bytes(b'synthetic backup fixture; no restoration claimed')
        backup.chmod(0o600)
        digest = m.artifacts.digest(backup)
        m.core.save(directory / 'fresh-backup.json', {'backupSHA256': digest, 'createdAt': timestamp(0 if fresh else -25)})
        m.core.save(directory / 'fresh-restore-verified.json', {'backupSHA256': digest, 'restore': 'PASS_EXACT_DUMP_SNAPSHOT'})
        m.core.save(directory / 'backup-verified.json', {'backupSHA256': digest, 'fixture': 'mocked restore receipt'})
        m.core.save(directory / 'build11-restored-database-verified.json', {
            'sourceCommit': SOURCE, 'imageId': CANDIDATE, 'rollbackImageId': ROLLBACK, 'backupSHA256': digest,
            'validation': 'PASS_ISOLATED_BUILD11_MIGRATION_AND_EXISTING_ROW_PRESERVATION',
            'policiesPreserved': True, 'rollbackMigrationsAccepted': True, 'productionChanged': False})
        m.core.save(directory / 'build11-preflight.json', {
            'sourceCommit': SOURCE, 'backupSHA256': digest, 'productionChanged': False,
            'recoveryEvidenceSHA256': {name: m.artifacts.digest(directory / name) for name in m.RECOVERY_RECEIPTS},
            'nasEvidenceHashes': {str(self.nas / name): m.artifacts.digest(self.nas / name) for name in
                                  ('nas-verified.json', 'nas-proof.json', 'nas-recovery-report.txt')}})

    def refresh(self, prepare=None, prerequisites=None):
        with patch.object(m.core, 'prerequisites', side_effect=prerequisites,
                          return_value=(self.plan, self.current)), \
             patch.object(m.core, 'queue_safety') as queues, \
             patch.object(m, 'prepare_backup', side_effect=prepare or
                          (lambda directory, *args: self.write_evidence(directory))) as backup, \
             redirect_stdout(io.StringIO()):
            m.refresh_recovery(self.args, SOURCE, CANDIDATE, ROLLBACK)
        return backup, queues

    def test_refresh_keeps_original_bytes_and_activates_only_new_tested_generation(self):
        before = {path.relative_to(self.state): path.read_bytes() for path in self.state.rglob('*') if path.is_file()}
        backup, queues = self.refresh()
        generation, count, _ = m.recovery_generation(self.state)
        self.assertEqual(count, 1)
        self.assertNotEqual(generation, self.state)
        self.assertEqual(generation.parent, self.state / 'recovery-generations')
        self.assertEqual(generation.stat().st_mode & 0o777, 0o700)
        self.assertEqual(m.recovered_backup(self.state)['recoveryFreshness'], 'FRESH_BACKUP_AND_NAS_WITHIN_24H')
        backup.assert_called_once_with(generation, SOURCE, CANDIDATE, ROLLBACK, self.nas)
        self.assertEqual(queues.call_count, 2)
        for path, original in before.items():
            self.assertEqual((self.state / path).read_bytes(), original)

    def test_repeated_refresh_appends_chain_without_overwriting_prior_generation(self):
        self.refresh()
        first, _, _ = m.recovery_generation(self.state)
        prior = {path: path.read_bytes() for path in first.rglob('*') if path.is_file()}
        marker = (self.state / 'recovery-generation-000001.json').read_bytes()
        self.refresh()
        second, count, _ = m.recovery_generation(self.state)
        self.assertEqual(count, 2)
        self.assertNotEqual(first, second)
        self.assertEqual((self.state / 'recovery-generation-000001.json').read_bytes(), marker)
        for path, original in prior.items():
            self.assertEqual(path.read_bytes(), original)

    def test_failed_restore_retains_inactive_generation_and_retry_creates_new_files(self):
        def fail(directory, *args):
            (directory / 'failed-fixture-backup').write_bytes(b'retained private failure')
            raise RuntimeError('fixture restore failure')
        with self.assertRaisesRegex(RuntimeError, 'fixture restore failure'):
            self.refresh(prepare=fail)
        self.assertFalse(list(self.state.glob('recovery-generation-*.json')))
        self.assertEqual(m.recovery_generation(self.state)[0], self.state)
        self.refresh()
        self.assertEqual(len(list((self.state / 'recovery-generations').iterdir())), 2)
        self.assertTrue(list((self.state / 'recovery-generations').glob('*/failed-fixture-backup')))

    def test_interrupted_activation_is_atomic_and_does_not_publish_partial_pointer(self):
        with patch.object(m.os, 'link', side_effect=OSError('fixture activation interruption')):
            with self.assertRaisesRegex(OSError, 'fixture activation interruption'):
                self.refresh()
        self.assertFalse(list(self.state.glob('recovery-generation-*.json')))
        self.assertTrue(list((self.state / 'recovery-generations').glob('*/activation-receipt.json')))
        self.refresh()
        self.assertEqual(m.recovery_generation(self.state)[1], 1)

    def test_refresh_rejects_wrong_plan_before_backup_or_queue_activity(self):
        changed = {**self.plan, 'candidateImage': 'sha256:' + 'd' * 64}
        with patch.object(m.core, 'prerequisites', return_value=(changed, self.current)), \
             patch.object(m, 'prepare_backup') as backup, patch.object(m.core, 'queue_safety') as queues, \
             self.assertRaisesRegex(m.core.Stop, 'REFRESH_PLAN_IMAGE_OR_SOURCE_CHANGED'):
            m.refresh_recovery(self.args, SOURCE, CANDIDATE, ROLLBACK)
        backup.assert_not_called()
        queues.assert_not_called()

    def test_changed_server_during_restore_never_activates_new_generation(self):
        changed = {**self.current, 'Id': 'externally-recreated-server'}
        with self.assertRaisesRegex(m.core.Stop, 'SERVER_CHANGED_DURING_RECOVERY_REFRESH'):
            self.refresh(prerequisites=[(self.plan, self.current), (self.plan, changed)])
        self.assertFalse(list(self.state.glob('recovery-generation-*.json')))

    def test_unverified_migration_receipt_cannot_activate_even_with_fresh_backup(self):
        def incomplete(directory, *args):
            self.write_evidence(directory)
            path = directory / 'build11-restored-database-verified.json'
            value = json.loads(path.read_text())
            value['policiesPreserved'] = False
            path.write_text(json.dumps(value))
            context_path = directory / 'build11-preflight.json'
            context = json.loads(context_path.read_text())
            context['recoveryEvidenceSHA256'][path.name] = m.artifacts.digest(path)
            context_path.write_text(json.dumps(context))
        with self.assertRaisesRegex(m.core.Stop, 'EXACT_REFRESH_MIGRATION_RESTORE_REQUIRED'):
            self.refresh(prepare=incomplete)
        self.assertFalse(list(self.state.glob('recovery-generation-*.json')))

    def test_source_identity_mismatch_and_path_traversal_are_rejected(self):
        self.refresh()
        path = self.state / 'recovery-generation-000001.json'
        original = path.read_text()
        for field, value, code in [('sourceCommit', 'f' * 40, 'IMAGE_OR_SOURCE_CHANGED'),
                                   ('candidateImage', 'sha256:' + 'f' * 64, 'IMAGE_OR_SOURCE_CHANGED'),
                                   ('rollbackImage', 'sha256:' + 'f' * 64, 'IMAGE_OR_SOURCE_CHANGED'),
                                   ('directory', '../outside', 'BINDING_CHANGED'),
                                   ('previousReceiptSHA256', 'f' * 64, 'BINDING_CHANGED'),
                                   ('productionChanged', True, 'BINDING_CHANGED')]:
            row = json.loads(original)
            row[field] = value
            path.write_text(json.dumps(row))
            with self.subTest(field=field), self.assertRaisesRegex(m.core.Stop, code):
                m.recovery_generation(self.state)
        path.write_text(original)

    def test_changed_generation_receipt_or_plan_cannot_be_reused(self):
        self.refresh()
        generation, _, _ = m.recovery_generation(self.state)
        path = generation / 'fresh-restore-verified.json'
        value = path.read_text()
        path.write_text(value + ' ')
        with self.assertRaisesRegex(m.core.Stop, 'EVIDENCE_CHANGED'):
            m.recovered_backup(self.state)
        path.write_text(value)
        plan = self.state / 'image-state/image-plan.json'
        plan.write_text(plan.read_text() + ' ')
        with self.assertRaisesRegex(m.core.Stop, 'BINDING_CHANGED'):
            m.recovered_backup(self.state)

    def test_missing_or_duplicate_sequence_cannot_select_newer_receipt(self):
        self.refresh()
        self.refresh()
        (self.state / 'recovery-generation-000001.json').unlink()
        with self.assertRaisesRegex(m.core.Stop, 'CHAIN_REQUIRED'):
            m.recovered_backup(self.state)

    def test_symlink_generation_cannot_escape_private_state(self):
        self.refresh()
        generation, _, _ = m.recovery_generation(self.state)
        retained = generation.with_name('retained-fixture')
        generation.rename(retained)
        generation.symlink_to(retained, target_is_directory=True)
        with self.assertRaisesRegex(m.core.Stop, 'OWNED_PRIVATE_RECOVERY_GENERATION_REQUIRED'):
            m.recovered_backup(self.state)

    def test_symlink_generation_parent_cannot_escape_private_state(self):
        self.refresh()
        parent = self.state / 'recovery-generations'
        retained = self.state / 'retained-fixture-generations'
        parent.rename(retained)
        parent.symlink_to(retained, target_is_directory=True)
        with self.assertRaisesRegex(m.core.Stop, 'OWNED_PRIVATE_RECOVERY_GENERATION_REQUIRED'):
            m.recovered_backup(self.state)

    def test_symlink_backup_or_metadata_is_rejected_before_following_outside_file(self):
        self.refresh()
        generation, _, _ = m.recovery_generation(self.state)
        for name in ('fresh-immich.sql.gz', 'fresh-backup.json'):
            path = generation / name
            retained = self.root / ('retained-' + name)
            path.rename(retained)
            path.symlink_to(retained)
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, 'REAL_ARTIFACT_REQUIRED'):
                m.recovered_backup(self.state)
            path.unlink()
            retained.rename(path)

    def test_concurrent_refresh_is_rejected_before_new_backup_or_queue_operations(self):
        descriptor = os.open(self.state / '.recovery-refresh.lock', os.O_RDWR | os.O_CREAT, 0o600)
        with os.fdopen(descriptor, 'w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with patch.object(m.core, 'prerequisites', return_value=(self.plan, self.current)), \
                 patch.object(m.core, 'queue_safety') as queues, patch.object(m, 'prepare_backup') as backup, \
                 self.assertRaisesRegex(m.core.Stop, 'RECOVERY_REFRESH_ALREADY_IN_PROGRESS'):
                m.refresh_recovery(self.args, SOURCE, CANDIDATE, ROLLBACK)
        queues.assert_not_called()
        backup.assert_not_called()

    def operate_fixture(self, action):
        rollback = self.root / 'rollback'
        rollback.mkdir(exist_ok=True)
        (rollback / 'manifest.json').write_text(json.dumps({'sourceCommit': 'd' * 40,
                                                         'imageId': ROLLBACK, 'serverVersion': '5.7.2'}))
        args = SimpleNamespace(action=action, profile=self.root / 'profile', profile_sha256='e' * 64,
                               state=self.state, complete_confirmed_cleanup=False,
                               compatibility_receipt=self.root / 'compatibility', compatibility_sha256='e' * 64,
                               artifacts=self.root / 'artifacts', rollback_artifacts=rollback,
                               previous_run_root=self.root / 'old', nas_evidence=self.nas,
                               execute_approved=True, approve_migration=True, api='http://synthetic.invalid/api')
        with ExitStack() as stack:
            stack.enter_context(patch('pwd.getpwuid', return_value=SimpleNamespace(pw_name='doctoriceadm')))
            stack.enter_context(patch.object(m.os, 'getuid', return_value=self.state.stat().st_uid))
            stack.enter_context(patch.object(m.core, 'DOCKER', []))
            stack.enter_context(patch.object(m.core, 'queue_safety', Mock()))
            stack.enter_context(patch.object(m.artifacts, 'load', return_value={
                'sourceCommit': SOURCE, 'backend': {'imageId': CANDIDATE}}))
            stack.enter_context(patch.object(m.artifacts, 'pinned_json', return_value={
                'candidateSource': SOURCE, 'candidateImage': CANDIDATE,
                'rollbackSource': 'd' * 40, 'rollbackImage': ROLLBACK}))
            stack.enter_context(patch.object(m, 'artifact_image', side_effect=[CANDIDATE, ROLLBACK]))
            stack.enter_context(patch.object(m.core, 'probe_image', return_value={}))
            stack.enter_context(patch.object(m.core, 'rollback_compatibility'))
            stack.enter_context(patch.object(m, 'cleanups', return_value=Mock()))
            stack.enter_context(patch.object(m.core, 'prerequisites', return_value=(self.plan, self.current)))
            health = stack.enter_context(patch.object(m.core, 'health'))
            execute = stack.enter_context(patch.object(m.core, 'execute'))
            output = stack.enter_context(redirect_stdout(io.StringIO()))
            if action == 'status':
                m.operate(args)
                health.assert_called_once()
                self.assertIn('PASS exact running image/source', output.getvalue())
                self.assertIn('FRESH_RESTORED_BACKUP_EXPIRED', output.getvalue())
                self.assertIn('run refresh-recovery before changes', output.getvalue())
            else:
                with self.assertRaisesRegex(m.pre.Stop, 'FRESH_RESTORED_BACKUP_EXPIRED'):
                    m.operate(args)
                health.assert_not_called()
            execute.assert_not_called()

    def test_status_reports_healthy_runtime_with_expired_recovery_without_mutation(self):
        self.operate_fixture('status')

    def test_check_apply_rollback_all_reject_expired_recovery_before_execution(self):
        for action in ('check', 'apply', 'rollback'):
            with self.subTest(action=action):
                self.operate_fixture(action)

    def test_status_may_read_expired_recovery_but_mutating_gates_remain_fail_closed(self):
        context = m.recovered_backup(self.state, require_fresh=False)
        self.assertEqual(context['recoveryFreshness'], 'FRESH_RESTORED_BACKUP_EXPIRED')
        with self.assertRaisesRegex(m.pre.Stop, 'FRESH_RESTORED_BACKUP_EXPIRED'):
            m.recovered_backup(self.state)
        (self.state / 'fresh-immich.sql.gz').write_bytes(b'tampered synthetic backup')
        with self.assertRaisesRegex(m.core.Stop, 'FRESH_BACKUP_AND_EXACT_RESTORE_REQUIRED'):
            m.recovered_backup(self.state, require_fresh=False)

    def test_stale_nas_and_future_backup_remain_blocked_after_generation_activation(self):
        self.refresh()
        generation, _, _ = m.recovery_generation(self.state)
        # Change fixture timestamp and rebind its local mock evidence to model
        # a genuinely expired unchanged receipt, not production proof issuance.
        path = self.nas / 'nas-verified.json'
        path.write_text(json.dumps({'verifiedAt': timestamp(-25)}))
        context_path = generation / 'build11-preflight.json'
        context = json.loads(context_path.read_text())
        context['nasEvidenceHashes'][str(path)] = m.artifacts.digest(path)
        context_path.write_text(json.dumps(context))
        marker = self.state / 'recovery-generation-000001.json'
        receipt = json.loads(marker.read_text())
        receipt['evidenceSHA256']['build11-preflight.json'] = m.artifacts.digest(context_path)
        marker.write_text(json.dumps(receipt))
        with self.assertRaisesRegex(m.pre.Stop, 'NAS_RECOVERY_VERIFICATION_EXPIRED'):
            m.recovered_backup(self.state)
        self.assertEqual(m.recovered_backup(self.state, require_fresh=False)['recoveryFreshness'],
                         'NAS_RECOVERY_VERIFICATION_EXPIRED_NO_TIMESTAMP_REFRESH')
        backup_path = generation / 'fresh-backup.json'
        backup = json.loads(backup_path.read_text())
        backup['createdAt'] = timestamp(1)
        backup_path.write_text(json.dumps(backup))
        context['recoveryEvidenceSHA256']['fresh-backup.json'] = m.artifacts.digest(backup_path)
        context_path.write_text(json.dumps(context))
        receipt['evidenceSHA256']['build11-preflight.json'] = m.artifacts.digest(context_path)
        receipt['evidenceSHA256']['fresh-backup.json'] = m.artifacts.digest(backup_path)
        marker.write_text(json.dumps(receipt))
        with self.assertRaisesRegex(m.pre.Stop, 'FRESH_RESTORED_BACKUP_EXPIRED'):
            m.recovered_backup(self.state)

    def test_initial_generation_timestamp_rewrite_cannot_fabricate_fresh_restore(self):
        path = self.state / 'fresh-backup.json'
        row = json.loads(path.read_text())
        row['createdAt'] = timestamp()
        path.write_text(json.dumps(row))
        for require_fresh in (True, False):
            with self.subTest(require_fresh=require_fresh), self.assertRaisesRegex(m.core.Stop, 'METADATA_CHANGED_RUN_REFRESH'):
                m.recovered_backup(self.state, require_fresh=require_fresh)

    def test_old_unpinned_state_is_readable_but_can_only_become_ready_through_fresh_restore(self):
        path = self.state / 'build11-preflight.json'
        row = json.loads(path.read_text())
        del row['recoveryEvidenceSHA256']
        path.write_text(json.dumps(row))
        self.assertEqual(m.recovered_backup(self.state, require_fresh=False)['recoveryFreshness'],
                         'HISTORIC_RECOVERY_METADATA_UNPINNED_RUN_REFRESH')
        with self.assertRaisesRegex(m.core.Stop, 'METADATA_CHANGED_RUN_REFRESH'):
            m.recovered_backup(self.state)
        self.refresh()
        self.assertEqual(m.recovered_backup(self.state)['recoveryFreshness'], 'FRESH_BACKUP_AND_NAS_WITHIN_24H')


class RecoveryEntryPoint(unittest.TestCase):
    def test_verified_wrapper_dispatches_refresh_without_deployment_approval(self):
        args = ['gallery_entry.py', 'refresh-recovery', '/fixture/package', '/fixture/state',
                '/fixture/old', '/fixture/nas']
        config = {'profileSHA256': 'a' * 64, 'compatibilitySHA256': 'b' * 64}
        with patch.object(sys, 'argv', args), patch.object(entry, 'verify_package', return_value=config), \
             patch.object(entry.subprocess, 'run', return_value=SimpleNamespace(returncode=0)) as run:
            self.assertEqual(entry.main(), 0)
        command = run.call_args.args[0]
        self.assertEqual(command[3], 'refresh-recovery')
        self.assertNotIn('--execute-approved', command)
        self.assertNotIn('--complete-confirmed-cleanup', command)


if __name__ == '__main__':
    unittest.main()
