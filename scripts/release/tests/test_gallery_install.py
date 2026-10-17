"""Installer repeat/resume safeguards; mocks only, not real clean-install acceptance."""
from contextlib import ExitStack, redirect_stdout
import hashlib
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
import gallery_install as m
import build11_operator as operator

SOURCE = 'a'*40
CANDIDATE = 'sha256:'+'b'*64
ML = 'sha256:'+'c'*64
DB = 'sha256:'+'d'*64
REDIS = 'sha256:'+'e'*64

class FreshInstall(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.directory = root/'fresh'; self.directory.mkdir(mode=0o700)
        self.package = root/'package'; (self.package/'config').mkdir(parents=True)
        (self.package/'config/docker-compose.yml').write_text('fixture official Compose')
        (self.package/'SHA256SUMS').write_text('fixture sums')
        self.env = root/'private.env'; self.env.write_text('DB_PASSWORD=synthetic-fixture-password\n'); self.env.chmod(0o600)
        self.args = SimpleNamespace(package=self.package, directory=self.directory, environment=self.env,
                                    machine_learning_image=ML, execute_approved=True)
        self.config = {'profileSHA256':'a'*64, 'machineLearningImage':ML}
        self.profile = {'sourceCommit':SOURCE, 'backend':{}}
        self.rows = []
        self.called = []
        self.stack = ExitStack(); self.addCleanup(self.stack.close)
        self.stack.enter_context(patch.dict(os.environ, {'GALLERY_FRESH_INSTALL_APPROVED':'YES'}))
        for name, value in [('verify_package', self.config), ('artifact_image', CANDIDATE)]:
            self.stack.enter_context(patch.object(m, name, return_value=value))
        self.stack.enter_context(patch.object(m.artifacts, 'load', return_value=self.profile))
        self.stack.enter_context(patch.object(m.core, 'docker', side_effect=self.docker))
        self.stack.enter_context(patch.object(m.core, 'image', return_value={'Config':{'Env':[]}}))
        self.run = self.stack.enter_context(patch.object(m.core, 'run', side_effect=lambda command, **kw:self.called.append(command) or ''))
        self.health = self.stack.enter_context(patch.object(m.core, 'health', return_value={}))
        self.stack.enter_context(patch.object(m.core, 'effective', return_value={'services': {
            m.core.SERVICE:{}, 'immich-machine-learning':{}, 'database':{}, 'redis':{}}}))
        self.stack.enter_context(patch.object(m.socket, 'socket'))

    def docker(self, *args):
        if args[:2] == ('ps','-aq'):
            if 'label=com.docker.compose.project=immich' in args: return ' '.join(row['Id'] for row in self.rows)
            return ' '.join(row['Id'] for row in self.rows if row['Name']=='/'+args[-1][7:-1])
        if args[0]=='inspect': return json.dumps(self.rows)
        if args[:2]==('image','inspect'):
            identifier=DB if 'postgres:' in args[2] else REDIS
            return json.dumps([{'Id':identifier,'Architecture':'amd64','Os':'linux'}])
        self.fail('Unexpected Docker action')

    def invoke(self):
        with redirect_stdout(io.StringIO()): m.install(self.args)

    def seed_containers(self):
        self.rows = [dict(Id='server-fixture', Name='/immich_server', Image=CANDIDATE,
                         Config={'Labels':{'com.docker.compose.project.working_dir':str(self.directory),
                                           'com.docker.compose.service':m.core.SERVICE}})]

    def test_clean_install_initializes_db_defaults_and_completed_repeat_does_not_start_services(self):
        self.invoke()
        text=(self.directory/'.env').read_text()
        self.assertIn('DB_USERNAME=postgres\n', text); self.assertIn('DB_DATABASE_NAME=immich\n', text)
        self.assertEqual((self.directory/'.env').stat().st_mode&0o777,0o600)
        self.seed_containers(); self.called.clear(); self.invoke()
        self.assertFalse(self.called); self.assertEqual(self.health.call_count,2)

    def test_interrupted_service_start_resumes_same_configuration_and_retains_data(self):
        self.health.side_effect=m.core.Stop('SERVER_HEALTH_FAILED_REVIEW_PLAN_FOR_ROLLBACK')
        with self.assertRaises(m.core.Stop): self.invoke()
        self.assertFalse((self.directory/'fresh-install-completed.json').exists())
        (self.directory/'media/synthetic-photo').write_bytes(b'must survive')
        self.seed_containers(); self.health.side_effect=None; self.invoke()
        self.assertEqual((self.directory/'media/synthetic-photo').read_bytes(),b'must survive')
        self.assertTrue((self.directory/'fresh-install-completed.json').exists())

    def test_changed_private_environment_or_compose_fails_before_service_operation(self):
        self.invoke(); self.seed_containers(); self.called.clear()
        self.env.write_text('DB_PASSWORD=different-fixture-password\n')
        with self.assertRaisesRegex(m.core.Stop,'CONTEXT_CHANGED'): self.invoke()
        self.env.write_text('DB_PASSWORD=synthetic-fixture-password\n')
        (self.directory/'docker-compose.yml').write_text('changed')
        with self.assertRaisesRegex(m.core.Stop,'CONFIGURATION_CHANGED'): self.invoke()
        self.assertFalse(self.called)

    def test_existing_foreign_project_or_image_rejected(self):
        self.rows=[dict(Id='foreign',Name='/immich_server',Image=CANDIDATE,Config={'Labels':{}})]
        with self.assertRaisesRegex(m.core.Stop,'USE_UPGRADE'): self.invoke()
        self.rows=[]; self.invoke(); self.seed_containers(); self.rows[0]['Image']=DB; self.called.clear()
        with self.assertRaisesRegex(m.core.Stop,'UNREVIEWED_EXISTING'): self.invoke()
        self.assertFalse(self.called)

    def test_duplicate_env_keys_and_worker_options_fail_without_changes(self):
        for text in ('DB_PASSWORD=first\nDB_PASSWORD=second\n','DB_PASSWORD=synthetic\nIMMICH_WORKERS_INCLUDE=api\n'):
            self.env.write_text(text)
            with self.subTest(text=text),self.assertRaises(m.core.Stop): self.invoke()
            self.assertFalse(any(self.directory.iterdir()))

    def test_missing_ml_image_without_registry_digest_cannot_pull_mutable_tag(self):
        self.stack.enter_context(patch.object(m.core,'image',side_effect=m.core.Stop('not cached')))
        with self.assertRaisesRegex(m.core.Stop,'PINNED_MACHINE_LEARNING'): self.invoke()
        self.assertFalse(self.called)

class NasConfiguration(unittest.TestCase):
    """Mock NFS inventory only; does not claim real NFS execution."""
    def setUp(self):
        temporary=tempfile.TemporaryDirectory();self.addCleanup(temporary.cleanup)
        self.root=Path(temporary.name);self.export=self.root/'export';self.export.mkdir()
        self.file=self.root/'nas.json'
        self.row={'source':str(self.export),'destination':'/external/fixture',
                  'nfsSource':'nas.example:/volume1/fixture','readOnly':True}
        self.mount={'source':self.row['nfsSource'],'target':str(self.export),'fstype':'nfs','options':'rw,nosuid,nodev'}
        self.write()

    def write(self):
        self.file.write_text(json.dumps({'schemaVersion':1,'mounts':[self.row]}));self.file.chmod(0o600)

    def verify(self, rows=None):
        with patch.object(m.core,'run',return_value=json.dumps({'filesystems':rows if rows is not None else [self.mount]})):
            return m.nas_storage(self.file)

    def test_stacked_autofs_and_nfs_are_verified_without_modifying_permissions(self):
        before=self.export.stat()
        data=self.verify([{'source':'systemd-1','target':str(self.export),'fstype':'autofs'},self.mount])
        self.assertTrue(data['mounts'][0]['readOnly']);self.assertEqual(data['mounts'][0]['inode'],before.st_ino)
        self.assertEqual(self.export.stat().st_mode,before.st_mode)

    def test_missing_actual_mount_changed_source_target_duplicate_or_filesystem_fails(self):
        cases=[[],[dict(self.mount,source='nas.example:/different')],[dict(self.mount,target='/mnt/different')],
               [self.mount,self.mount],[dict(self.mount,fstype='ext4')]]
        for rows in cases:
            with self.subTest(rows=rows),self.assertRaisesRegex(m.core.Stop,'NFS_SOURCE_AND_TARGET'):self.verify(rows)

    def test_writable_mapping_cannot_turn_readonly_mount_into_rw(self):
        self.row['readOnly']=False;self.write()
        with self.assertRaisesRegex(m.core.Stop,'WRITE_MODE'):
            self.verify([dict(self.mount,options='ro,nosuid,nodev')])

    def test_host_root_container_escape_and_symlink_mapping_are_rejected(self):
        for destination in ('/','/usr/src/app','/external/../data'):
            self.row['destination']=destination;self.write()
            with self.subTest(destination=destination),self.assertRaisesRegex(m.core.Stop,'NARROW_REAL_NAS_ROOT'):self.verify()
        alias=self.root/'alias';alias.symlink_to(self.export,target_is_directory=True)
        self.row['destination']='/external/fixture';self.row['source']=str(alias);self.write()
        with self.assertRaisesRegex(m.core.Stop,'NARROW_REAL_NAS_ROOT'):self.verify()

class Bridge(unittest.TestCase):
    def test_old_current_deployment_resumes_existing_state_machine_instead_of_replaying_files(self):
        runner=Mock(); runner.hp.CURRENT='old'; runner.core.inspect.return_value={'Image':'old'}
        with patch.object(operator,'Runner',return_value=runner): operator.complete_bridge(Path('/synthetic'))
        runner.run.assert_called_once_with(True); runner.gate.assert_not_called()

    def test_already_updated_server_requires_real_completion_receipt_and_only_checks_gate(self):
        runner=Mock(); runner.hp.CURRENT='old'; runner.core.inspect.return_value={'Image':'new'}
        with patch.object(operator,'Runner',return_value=runner),patch.object(operator,'cleanup_completed',return_value=True):
            operator.complete_bridge(Path('/synthetic'))
        runner.run.assert_not_called(); runner.gate.assert_called_once_with()


class SealedIntentGate(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.phase = self.root / 'queued-user-deletions'; self.phase.mkdir(mode=0o700)
        self.files = [{'jobId': job, 'file': '/data/file-' + job, 'path': '/data/file-' + job,
                       'root': '/data', 'jobHash': 'hash-' + job, 'kind': 'temporary-upload',
                       'ownerId': 'owner'} for job in operator.IDS]
        intent = {'contract': 'confirmed-native-cleanup-v1', 'files': self.files}
        seal = hashlib.sha256(json.dumps(intent, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()
        rows = {'cleanup-intent-v1.json': intent,
                'cleanup-intent-seal-v1.json': {'sha256': seal},
                'file-proofs.json': {'intentSeal': seal, 'proofs': self.files}}
        for name, value in rows.items():
            path = self.phase / name; path.write_text(json.dumps(value)); path.chmod(0o600)

    def test_requires_all_six_scoped_jobs_and_checks_current_image_queue_read_only(self):
        with patch.object(operator.core, 'inspect', return_value={'Image': operator.EXPECTED_PRODUCTION_IMAGE}), \
             patch.object(operator.core, 'identity'), \
             patch.object(operator.core, 'queue_safety', return_value={'inventoryComplete': True,
                                                                        'unresolvedDeletionHashes': 0}) as queue:
            result = operator.sealed_intent_queue_gate(self.root, 'candidate', 'rollback')
        self.assertTrue(result['inventoryComplete']); queue.assert_called_once_with()

    def test_partial_intent_scope_is_rejected_before_queue_probe(self):
        path = self.phase / 'cleanup-intent-v1.json'; intent = json.loads(path.read_text())
        intent['files'] = intent['files'][:-1]; path.write_text(json.dumps(intent)); path.chmod(0o600)
        with patch.object(operator.core, 'queue_safety') as queue, self.assertRaisesRegex(
                operator.core.Stop, 'SEALED_CLEANUP_INTENT_SCOPE_CHANGED'):
            operator.sealed_intent_queue_gate(self.root, 'candidate', 'rollback')
        queue.assert_not_called()

if __name__=='__main__': unittest.main()

class OneCommandUpgrade(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.state=Path(self.temp.name)
        self.argv=['build11_operator.py','upgrade','--profile','/synthetic/profile','--profile-sha256','a'*64,
                   '--artifacts','/synthetic/artifacts','--rollback-artifacts','/synthetic/rollback',
                   '--compatibility-receipt','/synthetic/receipt','--compatibility-sha256','b'*64,
                   '--state',str(self.state),'--previous-run-root','/synthetic/old','--nas-evidence','/synthetic/nas',
                   '--execute-approved','--approve-migration','--complete-confirmed-cleanup']
        self.env={'GALLERY_DEPLOYMENT_APPROVED':'YES','GALLERY_ADDITIVE_MIGRATION_APPROVED':'YES'}

    def run_main(self):
        with patch.object(sys,'argv',self.argv),patch.dict(os.environ,self.env),patch.object(operator,'operate') as run,redirect_stdout(io.StringIO()):
            result=operator.main()
            return result,[call.args[0] for call in run.call_args_list]

    def test_approved_new_upgrade_runs_existing_gates_in_order_and_cleanup_only_in_prepare(self):
        result,calls=self.run_main();self.assertEqual(result,0)
        self.assertEqual([row.action for row in calls],['prepare','check','apply','status'])
        self.assertEqual([row.complete_confirmed_cleanup for row in calls],[True,False,False,False])

    def test_completed_preparation_is_reused_without_new_backup_or_cleanup(self):
        directory=self.state/'image-state';directory.mkdir();(directory/'image-plan.json').write_text('{}')
        result,calls=self.run_main();self.assertEqual(result,0)
        self.assertEqual([row.action for row in calls],['check','apply','status'])

    def test_completed_deployment_is_verified_without_reapplying(self):
        directory=self.state/'image-state';directory.mkdir()
        for name in ('image-plan.json','applied.json'):(directory/name).write_text('{}')
        result,calls=self.run_main();self.assertEqual(result,0)
        self.assertEqual([row.action for row in calls],['status'])

    def test_missing_approval_stops_before_any_prepare_backup_or_service_operation(self):
        self.env['GALLERY_DEPLOYMENT_APPROVED']='NO'
        result,calls=self.run_main();self.assertEqual(result,1);self.assertFalse(calls)
