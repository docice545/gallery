"""Installer repeat/resume safeguards; mocks only, not real clean-install acceptance."""
from contextlib import ExitStack, redirect_stdout
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
DB, REDIS = [row['config'] for row in m.PUBLIC_DEPENDENCIES.values()]


class PublicDependencies(unittest.TestCase):
    def metadata(self, reference, containerd=False):
        expected=m.PUBLIC_DEPENDENCIES[reference]
        digest=reference.split('@',1)[1]
        common={'RepoDigests':[expected['repositories'][0]+'@'+digest]}
        if containerd:
            original={**common,'Id':digest,'Descriptor':{'digest':digest},'Architecture':'amd64','Os':'linux'}
            selected={**common,'Id':expected['manifest'],'Architecture':'amd64','Os':'linux',
                      'Descriptor':{'digest':expected['manifest']}}
        else:
            original={**common,'Id':expected['config'],'Architecture':'amd64','Os':'linux'}
            selected=dict(original)
        return original,selected

    def resolve(self,reference,original,selected):
        def inspect(*args):
            if args==('image','inspect',reference):return json.dumps([original])
            if args==('image','inspect','--platform','linux/amd64',reference):return json.dumps([selected])
            self.fail('Unexpected dependency operation')
        with patch.object(m.core,'docker',side_effect=inspect),patch.object(m.core,'run') as run:
            value=m.pinned_public_dependency(reference)
            run.assert_not_called()
            return value

    def test_classic_verified_config_ids_for_both_pinned_dependencies(self):
        for reference,expected in m.PUBLIC_DEPENDENCIES.items():
            with self.subTest(reference=reference):
                self.assertEqual(self.resolve(reference,*self.metadata(reference)),expected['config'])

    def test_containerd_selects_actual_platform_but_keeps_container_index_identity(self):
        for reference in m.PUBLIC_DEPENDENCIES:
            with self.subTest(reference=reference):
                self.assertEqual(self.resolve(reference,*self.metadata(reference,True)),reference.split('@',1)[1])

    def test_wrong_or_absent_platform_never_accepted_from_index(self):
        reference=next(iter(m.PUBLIC_DEPENDENCIES))
        for field,value in [('Architecture','arm64'),('Architecture',None),('Os','windows'),('Os',None)]:
            original,selected=self.metadata(reference,True);selected[field]=value
            with self.subTest(field=field,value=value),self.assertRaisesRegex(m.core.Stop,'PUBLIC_DEPENDENCY_IDENTITY'):
                self.resolve(reference,original,selected)

    def test_unverified_config_manifest_index_or_descriptor_fails_closed(self):
        reference=next(iter(m.PUBLIC_DEPENDENCIES))
        for store in (False,True):
            for side in ('original','selected'):
                for field in ('Id','Descriptor'):
                    original,selected=self.metadata(reference,store)
                    target=original if side=='original' else selected
                    target[field]='sha256:'+'f'*64 if field=='Id' else {'digest':'sha256:'+'f'*64}
                    with self.subTest(store=store,side=side,field=field),self.assertRaisesRegex(m.core.Stop,'PUBLIC_DEPENDENCY_IDENTITY'):
                        self.resolve(reference,original,selected)
        original,selected=self.metadata(reference,True);del original['Descriptor']
        with self.assertRaisesRegex(m.core.Stop,'PUBLIC_DEPENDENCY_IDENTITY'):self.resolve(reference,original,selected)
        original,selected=self.metadata(reference,True);del selected['Descriptor']
        with self.assertRaisesRegex(m.core.Stop,'PUBLIC_DEPENDENCY_IDENTITY'):self.resolve(reference,original,selected)

    def test_missing_or_wrong_registry_digest_on_either_inspection_fails(self):
        reference=next(iter(m.PUBLIC_DEPENDENCIES))
        for side in ('original','selected'):
            for digests in (None,[],['ghcr.io/immich-app/postgres@sha256:'+'f'*64],
                            ['unrelated/postgres@'+reference.split('@',1)[1]]):
                original,selected=self.metadata(reference,True)
                (original if side=='original' else selected)['RepoDigests']=digests
                with self.subTest(side=side,digests=digests),self.assertRaisesRegex(m.core.Stop,'PUBLIC_DEPENDENCY_IDENTITY'):
                    self.resolve(reference,original,selected)

    def test_mutable_or_unreviewed_dependency_reference_cannot_inspect_or_pull(self):
        for reference in ('valkey/valkey:9',next(iter(m.PUBLIC_DEPENDENCIES)).split('@',1)[0]+'@sha256:'+'f'*64):
            with patch.object(m.core,'docker') as docker,patch.object(m.core,'run') as run,\
                 self.subTest(reference=reference),self.assertRaisesRegex(m.core.Stop,'DEPENDENCY_REFERENCE'):
                m.pinned_public_dependency(reference)
            docker.assert_not_called();run.assert_not_called()

    def test_missing_dependency_pulls_only_exact_reference_and_revalidates_platform(self):
        reference=next(iter(m.PUBLIC_DEPENDENCIES));original,selected=self.metadata(reference)
        with patch.object(m.core,'docker',side_effect=[m.core.Stop('absent'),json.dumps([original]),json.dumps([selected])]) as docker,\
             patch.object(m.core,'run') as run:
            self.assertEqual(m.pinned_public_dependency(reference),original['Id'])
            run.assert_called_once_with([*m.core.DOCKER,'image','pull','--platform','linux/amd64',reference],timeout=900)
            self.assertEqual(docker.call_args_list[-1].args,('image','inspect','--platform','linux/amd64',reference))

    def test_unsupported_platform_inspection_has_no_unqualified_fallback(self):
        reference=next(iter(m.PUBLIC_DEPENDENCIES));original,_=self.metadata(reference)
        with patch.object(m.core,'docker',side_effect=[json.dumps([original]),m.core.Stop('API_PLATFORM_UNSUPPORTED')]) as docker,\
             patch.object(m.core,'run') as run,self.assertRaisesRegex(m.core.Stop,'API_PLATFORM_UNSUPPORTED'):
            m.pinned_public_dependency(reference)
        self.assertEqual(docker.call_count,2);run.assert_not_called()

    def test_verified_empty_containerd_index_fetches_exact_platform_once_for_both_dependencies(self):
        for reference in m.PUBLIC_DEPENDENCIES:
            original,selected=self.metadata(reference,True)
            for empty in (None,''):
                incomplete={**original,'Architecture':empty,'Os':empty}
                with self.subTest(reference=reference,empty=empty),\
                     patch.object(m.core,'docker',side_effect=[json.dumps([incomplete]),json.dumps([original]),
                                                              json.dumps([selected])]) as docker,\
                     patch.object(m.core,'run') as run:
                    self.assertEqual(m.pinned_public_dependency(reference),original['Id'])
                    run.assert_called_once_with([*m.core.DOCKER,'image','pull','--platform','linux/amd64',reference],timeout=900)
                    self.assertEqual([call.args for call in docker.call_args_list],
                                     [('image','inspect',reference),('image','inspect',reference),
                                      ('image','inspect','--platform','linux/amd64',reference)])

    def test_untrusted_or_wrong_platform_parent_never_triggers_cache_repair(self):
        reference=next(iter(m.PUBLIC_DEPENDENCIES));original,_=self.metadata(reference,True)
        incomplete={**original,'Architecture':'','Os':''}
        changes=[('Id','sha256:'+'f'*64),('Descriptor',{'digest':'sha256:'+'f'*64}),
                 ('Descriptor',None),('RepoDigests',[]),('RepoDigests',None),
                 ('RepoDigests',['unrelated/postgres@'+reference.split('@',1)[1]]),
                 ('Architecture','arm64'),('Architecture','amd64'),('Os','windows'),('Os','linux')]
        for field,value in changes:
            with self.subTest(field=field,value=value),\
                 patch.object(m.core,'docker',return_value=json.dumps([{**incomplete,field:value}])) as docker,\
                 patch.object(m.core,'run') as run,self.assertRaisesRegex(m.core.Stop,'PUBLIC_DEPENDENCY_IDENTITY'):
                m.pinned_public_dependency(reference)
            self.assertEqual(docker.call_count,1);run.assert_not_called()
        classic,_=self.metadata(reference);classic.update(Architecture='',Os='')
        with patch.object(m.core,'docker',return_value=json.dumps([classic])) as docker,\
             patch.object(m.core,'run') as run,self.assertRaisesRegex(m.core.Stop,'PUBLIC_DEPENDENCY_IDENTITY'):
            m.pinned_public_dependency(reference)
        self.assertEqual(docker.call_count,1);run.assert_not_called()

    def test_incomplete_index_after_exact_pull_is_rejected_without_repeat_pull(self):
        reference=next(iter(m.PUBLIC_DEPENDENCIES));original,_=self.metadata(reference,True)
        original.update(Architecture='',Os='')
        for initially_missing in (False,True):
            initial=m.core.Stop('absent') if initially_missing else json.dumps([original])
            with self.subTest(initially_missing=initially_missing),\
                 patch.object(m.core,'docker',side_effect=[initial,json.dumps([original])]) as docker,\
                 patch.object(m.core,'run') as run,self.assertRaisesRegex(m.core.Stop,'PUBLIC_DEPENDENCY_PLATFORM_CONTENT'):
                m.pinned_public_dependency(reference)
            self.assertEqual(docker.call_count,2)
            run.assert_called_once_with([*m.core.DOCKER,'image','pull','--platform','linux/amd64',reference],timeout=900)

    def test_repaired_index_still_requires_selected_platform_inspection(self):
        reference=next(iter(m.PUBLIC_DEPENDENCIES));original,_=self.metadata(reference,True)
        incomplete={**original,'Architecture':'','Os':''}
        with patch.object(m.core,'docker',side_effect=[json.dumps([incomplete]),json.dumps([original]),
                                                       m.core.Stop('API_PLATFORM_UNSUPPORTED')]) as docker,\
             patch.object(m.core,'run') as run,self.assertRaisesRegex(m.core.Stop,'API_PLATFORM_UNSUPPORTED'):
            m.pinned_public_dependency(reference)
        self.assertEqual(docker.call_count,3)
        self.assertEqual(docker.call_args_list[-1].args,('image','inspect','--platform','linux/amd64',reference))
        run.assert_called_once_with([*m.core.DOCKER,'image','pull','--platform','linux/amd64',reference],timeout=900)

    def test_parent_and_selected_identity_are_revalidated_after_cache_repair(self):
        reference=next(iter(m.PUBLIC_DEPENDENCIES));original,selected=self.metadata(reference,True)
        incomplete={**original,'Architecture':'','Os':''}
        for side,field,value in [('parent','Id','sha256:'+'f'*64),
                                 ('parent','Descriptor',{'digest':'sha256:'+'f'*64}),
                                 ('parent','RepoDigests',[]),('parent','Architecture','arm64'),
                                 ('parent','Os','windows'),('selected','Id','sha256:'+'f'*64),
                                 ('selected','Descriptor',{'digest':'sha256:'+'f'*64}),
                                 ('selected','RepoDigests',[]),('selected','Architecture','arm64')]:
            parent=dict(original);platform=dict(selected)
            (parent if side=='parent' else platform)[field]=value
            responses=[json.dumps([incomplete]),json.dumps([parent]),json.dumps([platform])]
            with self.subTest(side=side,field=field),\
                 patch.object(m.core,'docker',side_effect=responses) as docker,\
                 patch.object(m.core,'run') as run,self.assertRaisesRegex(m.core.Stop,'PUBLIC_DEPENDENCY_IDENTITY'):
                m.pinned_public_dependency(reference)
            self.assertEqual(docker.call_count,2 if side=='parent' else 3)
            run.assert_called_once_with([*m.core.DOCKER,'image','pull','--platform','linux/amd64',reference],timeout=900)

    def test_exact_cache_repair_pull_failure_is_not_ignored(self):
        reference=next(iter(m.PUBLIC_DEPENDENCIES));original,_=self.metadata(reference,True)
        original.update(Architecture='',Os='')
        with patch.object(m.core,'docker',return_value=json.dumps([original])) as docker,\
             patch.object(m.core,'run',side_effect=m.core.Stop('EXACT_PULL_FAILED')) as run,\
             self.assertRaisesRegex(m.core.Stop,'EXACT_PULL_FAILED'):
            m.pinned_public_dependency(reference)
        self.assertEqual(docker.call_count,1)
        run.assert_called_once_with([*m.core.DOCKER,'image','pull','--platform','linux/amd64',reference],timeout=900)

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
        self.health = self.stack.enter_context(patch.object(m.core, 'health', return_value={'Id':'server-fixture',
                    'Config':{'Env':[],'Labels':{'com.docker.compose.config-hash':'a'*64}},
                    'Mounts':[],'NetworkSettings':{'Networks':{}}}))
        self.stack.enter_context(patch.object(m.core, 'config_hash', return_value='a'*64))
        self.stack.enter_context(patch.object(m.core, 'effective', return_value={'services': {
            m.core.SERVICE:{}, 'immich-machine-learning':{}, 'database':{}, 'redis':{}},'networks':{}}))
        self.stack.enter_context(patch.object(m.socket, 'socket'))

    def docker(self, *args):
        if args == ('version', '--format', '{{json .}}'):
            return json.dumps({'Client': {'ApiVersion': '1.51'}, 'Server': {'ApiVersion': '1.51'}})
        if args == ('image', 'inspect', '--help'):
            return '      --platform string   Inspect an actual image platform\n'
        if args[:2] == ('ps','-aq'):
            if 'label=com.docker.compose.project=immich' in args: return ' '.join(row['Id'] for row in self.rows)
            return ' '.join(row['Id'] for row in self.rows if row['Name']=='/'+args[-1][7:-1])
        if args[0]=='inspect': return json.dumps(self.rows)
        if args[:2]==('image','inspect'):
            reference=args[-1]
            expected=m.PUBLIC_DEPENDENCIES[reference]
            return json.dumps([{'Id':expected['config'],'Architecture':'amd64','Os':'linux',
                                'RepoDigests':[expected['repositories'][0]+'@'+reference.split('@',1)[1]]}])
        self.fail('Unexpected Docker action')

    def invoke(self):
        with redirect_stdout(io.StringIO()): m.install(self.args)

    def seed_containers(self):
        self.rows = [dict(Id='server-fixture', Name='/immich_server', Image=CANDIDATE,
                         Config={'Env':[],'Labels':{'com.docker.compose.project.working_dir':str(self.directory),
                                           'com.docker.compose.service':m.core.SERVICE,
                                           'com.docker.compose.config-hash':'a'*64}},
                         Mounts=[],NetworkSettings={'Networks':{}})]

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

    def test_interruption_before_plan_write_resumes_exact_initialized_configuration(self):
        original_save=m.core.save
        def interrupted(path,value):
            if path.name=='fresh-install-plan.json':
                raise OSError('synthetic interruption before plan publication')
            return original_save(path,value)
        with patch.object(m.core,'save',side_effect=interrupted),self.assertRaises(OSError):self.invoke()
        self.assertTrue((self.directory/m.INITIALIZATION).is_file())
        self.assertFalse((self.directory/'fresh-install-plan.json').exists())
        hashes={name:m.artifacts.digest(self.directory/name) for name in
                ('.env','docker-compose.yml','image-only.override.json',m.INITIALIZATION)}
        self.assertFalse(self.called)
        self.invoke()
        self.assertEqual({name:m.artifacts.digest(self.directory/name) for name in hashes},hashes)
        self.assertTrue((self.directory/'fresh-install-completed.json').is_file())

    def test_interruption_before_config_publication_reuses_only_exact_private_staging(self):
        original_link=m.os.link
        def interrupted(source,target):
            if Path(target).name=='.env':
                raise OSError('synthetic interruption before config publication')
            return original_link(source,target)
        with patch.object(m.os,'link',side_effect=interrupted),self.assertRaises(OSError):self.invoke()
        staged=self.directory/'.env.pending'
        expected=m.artifacts.digest(staged)
        self.assertEqual(staged.stat().st_mode&0o777,0o600)
        self.assertFalse((self.directory/'.env').exists());self.assertFalse(self.called)
        self.invoke()
        self.assertEqual(m.artifacts.digest(self.directory/'.env'),expected)
        self.assertFalse(staged.exists())

    def test_initialization_resume_rejects_unlisted_file_changed_config_or_symlink(self):
        original_save=m.core.save
        def interrupted(path,value):
            if path.name=='fresh-install-plan.json':raise OSError('synthetic interruption')
            return original_save(path,value)
        with patch.object(m.core,'save',side_effect=interrupted),self.assertRaises(OSError):self.invoke()
        extra=self.directory/'unreviewed';extra.write_text('foreign')
        with self.assertRaisesRegex(m.core.Stop,'UNREVIEWED_INSTALL_INITIALIZATION_ENTRY'):self.invoke()
        extra.unlink()
        env=self.directory/'.env';original=env.read_bytes();env.write_bytes(b'changed')
        with self.assertRaisesRegex(m.core.Stop,'INITIALIZATION_CHANGED'):self.invoke()
        env.write_bytes(original);env.unlink();env.symlink_to(self.env)
        with self.assertRaisesRegex(m.core.Stop,'INITIALIZATION_CHANGED'):self.invoke()
        self.assertFalse(self.called)

    def test_initialization_receipt_cannot_adopt_changed_context_or_nonempty_data(self):
        original_save=m.core.save
        def interrupted(path,value):
            if path.name=='fresh-install-plan.json':raise OSError('synthetic interruption')
            return original_save(path,value)
        with patch.object(m.core,'save',side_effect=interrupted),self.assertRaises(OSError):self.invoke()
        self.env.write_text('DB_PASSWORD=different-fixture-password\n')
        with self.assertRaisesRegex(m.core.Stop,'INITIALIZATION_CHANGED'):self.invoke()
        self.env.write_text('DB_PASSWORD=synthetic-fixture-password\n')
        (self.directory/'media/foreign').write_bytes(b'preserve')
        with self.assertRaisesRegex(m.core.Stop,'UNREVIEWED_INSTALL_INITIALIZATION_DIRECTORY'):self.invoke()
        self.assertEqual((self.directory/'media/foreign').read_bytes(),b'preserve')
        self.assertFalse(self.called)

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

    def test_same_image_drift_in_hash_environment_mount_or_network_stops_repeat_before_service_operation(self):
        self.invoke();self.seed_containers();self.called.clear()
        changes=[('hash',lambda row:row['Config']['Labels'].update({'com.docker.compose.config-hash':'f'*64})),
                 ('environment',lambda row:row['Config'].update({'Env':['UNREVIEWED=value']})),
                 ('mount',lambda row:row.update({'Mounts':[{'Type':'bind','Source':'/foreign','Destination':'/data','RW':True}]})),
                 ('network',lambda row:row.update({'NetworkSettings':{'Networks':{'unrelated':{}}}}))]
        for name,change in changes:
            self.seed_containers();change(self.rows[0])
            with self.subTest(name=name),self.assertRaisesRegex(m.core.Stop,'FRESH_INSTALL_.*CHANGED'):self.invoke()
            self.assertFalse(self.called)

    def test_same_image_recreated_server_with_same_configuration_requires_review(self):
        self.invoke();self.seed_containers();self.called.clear()
        self.rows[0]['Id']='foreign-container'
        self.health.return_value['Id']='foreign-container'
        with self.assertRaisesRegex(m.core.Stop,'FRESH_INSTALLED_CONTAINER_CHANGED_REVIEW_REQUIRED'):self.invoke()
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

    def rollback_setup(self):
        self.invoke()
        self.profile['backend']['imageId']=CANDIDATE
        fallback='sha256:'+'f'*64
        metadata={'sourceCommit':'f'*40,'serverVersion':'5.7.3','imageId':fallback}
        rollback=self.package/'rollback';rollback.mkdir();(rollback/'manifest.json').write_text(json.dumps(metadata))
        self.config['compatibilitySHA256']='a'*64
        compatibility={'candidateSource':SOURCE,'candidateImage':CANDIDATE,
                       'rollbackSource':metadata['sourceCommit'],'rollbackImage':fallback}
        self.stack.enter_context(patch.object(m.artifacts,'pinned_json',return_value=compatibility))
        self.stack.enter_context(patch.object(m,'artifact_image',side_effect=lambda backend,*a,**kw:
                                              fallback if backend.name=='rollback' else CANDIDATE))
        current=dict(Id='server-fixture',Name='/immich_server',Image=CANDIDATE,
                     State={'Running':True},Config={'Labels':{'com.docker.compose.project':'immich',
                     'com.docker.compose.project.working_dir':str(self.directory),
                     'com.docker.compose.service':m.core.SERVICE}})
        self.stack.enter_context(patch.object(m.core,'inspect',return_value=current))
        self.queue=self.stack.enter_context(patch.object(m,'fresh_deletion_queue_check'))
        self.plan=self.stack.enter_context(patch.object(m.core,'plan',side_effect=lambda args:
                         m.core.save(args.state/'image-plan.json',{'fixturePlan':True})))
        self.execute=self.stack.enter_context(patch.object(m.core,'execute',side_effect=lambda args,**kw:
                         m.core.save(args.state/'rolled-back.json',{'image':fallback})))
        self.stack.enter_context(patch.object(m.core,'prerequisites',return_value=(
            {'api':'http://127.0.0.1:2283/api','rollbackVersion':{'major':5,'minor':7,'patch':3,'prerelease':None}},current)))
        self.stack.enter_context(patch.dict(os.environ,{'GALLERY_DEPLOYMENT_APPROVED':'YES'}))

    def test_fresh_rollback_uses_exact_package_and_truthful_completed_install_without_hp_bridge(self):
        self.rollback_setup()
        with redirect_stdout(io.StringIO()):m.rollback_fresh(self.args)
        self.plan.assert_called_once()
        passed=self.plan.call_args.args[0]
        self.assertEqual(passed.completed_install_receipt_sha256,
                         m.artifacts.digest(self.directory/'fresh-install-completed.json'))
        self.execute.assert_called_once();self.assertTrue(self.execute.call_args.kwargs['rollback'])
        self.assertFalse((self.directory/'fresh-rollback-state/apply-attempt.json').exists())
        with redirect_stdout(io.StringIO()):m.rollback_fresh(self.args)
        self.execute.assert_called_once();self.plan.assert_called_once()

    def test_fresh_rollback_missing_approval_or_changed_configuration_cannot_call_deployment(self):
        self.rollback_setup()
        with patch.dict(os.environ,{'GALLERY_DEPLOYMENT_APPROVED':'NO'}),self.assertRaisesRegex(m.core.Stop,'APPROVAL'):
            m.rollback_fresh(self.args)
        (self.directory/'.env').write_text('changed')
        with self.assertRaisesRegex(m.core.Stop,'VERIFIED_FRESH_INSTALL_RECEIPT'):
            m.rollback_fresh(self.args)
        self.plan.assert_not_called();self.execute.assert_not_called()

    def test_fresh_rollback_interrupted_attempt_is_not_replayed(self):
        self.rollback_setup()
        state=self.directory/'fresh-rollback-state';state.mkdir(mode=0o700)
        m.core.save(state/'image-plan.json',{'fixturePlan':True})
        m.core.save(state/'rollback-attempt.json',{'fixtureAttempt':True})
        with self.assertRaisesRegex(m.core.Stop,'INTERRUPTED_FRESH_ROLLBACK'):
            m.rollback_fresh(self.args)
        self.execute.assert_not_called()

    def test_fresh_rollback_changed_installed_container_is_rejected(self):
        self.rollback_setup()
        m.core.inspect.return_value['Id']='foreign-container'
        with self.assertRaisesRegex(m.core.Stop,'FRESH_INSTALLED_CONTAINER_CHANGED'):
            m.rollback_fresh(self.args)
        self.execute.assert_not_called();self.plan.assert_not_called()


class FreshDeletionQueue(unittest.TestCase):
    def inventory(self):
        from trash_release import STATES
        return dict(atomic=True,inventoryComplete=True,unresolvedDeletionHashes=0,
                    deletionNames={'AssetDelete':0,'FileDelete':0},
                    before={name:21 if name=='paused' else 0 for name in STATES},
                    counts={name:21 if name=='paused' else 0 for name in STATES})

    def test_other_paused_jobs_are_not_required_to_be_deleted_or_resumed(self):
        with patch.object(m.core,'run',return_value=json.dumps(self.inventory())) as run,redirect_stdout(io.StringIO()):
            m.fresh_deletion_queue_check()
        self.assertEqual(run.call_count,1)
        self.assertNotIn('resume',run.call_args.kwargs['input'])

    def test_pending_deletion_incomplete_inventory_or_nonatomic_report_is_rejected(self):
        for field,value in [('atomic',False),('inventoryComplete',False),('unresolvedDeletionHashes',1),
                            ('deletionNames',{'AssetDelete':0,'FileDelete':1}),
                            ('deletionNames',{'AssetDelete':False,'FileDelete':False})]:
            row=self.inventory();row[field]=value
            with self.subTest(field=field,value=value),patch.object(m.core,'run',return_value=json.dumps(row)),\
                 self.assertRaisesRegex(m.core.Stop,'DELETION_JOBS_PENDING_OR_INCOMPLETE'):
                m.fresh_deletion_queue_check()

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
