"""Release guards and opt-in LOCAL disposable restore/Compose rollback tests.

No production key, media, queue or API is used. Enable Docker fixtures with
GALLERY_DISPOSABLE_RELEASE_TESTS=1; all names are unique and images cached.
"""
import gzip
import importlib.util
import io
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from contextlib import redirect_stdout, redirect_stderr
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[3]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


release = module('trash_execution', ROOT/'scripts/release/trash_release.py')
android = module('android_execution', ROOT/'scripts/release/android_release.py')


class ExecutionGuards(unittest.TestCase):
    def test_approval_refusal_before_production_probe(self):
        with patch('sys.argv',['release','deploy','--state','/absent']), \
             patch.object(release.pwd,'getpwuid',return_value=SimpleNamespace(pw_name='doctoriceadm')), \
             patch.object(release,'docker') as docker, redirect_stderr(io.StringIO()):
            self.assertEqual(release.main(),1)
            docker.assert_not_called()

    def test_receipt_never_overwrites_or_follows_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            file=Path(directory)/'receipt'
            release.save(file,{'previous':True})
            self.assertEqual(file.stat().st_mode & 0o777,0o600)
            with self.assertRaises(FileExistsError): release.save(file,{})
            link=Path(directory)/'link';link.symlink_to(file)
            with self.assertRaises(FileExistsError): release.save(link,{})
            self.assertEqual(json.loads(file.read_text()),{'previous':True})

    def test_partial_nonempty_queue_never_paused_or_cleared_by_probe(self):
        for state in release.STATES:
            values={value:0 for value in release.STATES};values[state]=1
            with patch.object(release,'docker',return_value=json.dumps({'paused':True,'counts':values})) as docker:
                with self.assertRaisesRegex(release.Stop,'nonempty'): release.queue_empty(True)
                self.assertEqual(docker.call_count,1)
                self.assertIn('llen',docker.call_args.kwargs['input'])
                self.assertNotIn('.eval(',docker.call_args.kwargs['input'])

    def test_unknown_and_unpaused_queue_block(self):
        for value in ({'error':'unknown'},{'counts':{}},{'counts':dict.fromkeys(release.STATES,0),'paused':False}):
            with patch.object(release,'docker',return_value=json.dumps(value)):
                with self.assertRaises(release.Stop): release.queue_empty(True)

    def test_artifact_manifest_mismatch_precedes_large_archive_read(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'manifest.json').write_text('{}')
            with self.assertRaisesRegex(release.Stop,'manifest differs'): release.verify_artifact(root)

    def test_overrides_are_private_idempotent_and_reject_interference(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);file=release.override(root,'expected')
            self.assertEqual(release.override(root,'expected'),file)
            with self.assertRaisesRegex(release.Stop,'differs'): release.override(root,'other')

    def test_migrations_unknown_or_pending_block(self):
        with patch.object(release,'docker',side_effect=['["existing"]','["existing","pending"]']):
            with self.assertRaisesRegex(release.Stop,'migration sets differ'): release.migrations_match('fixture')

    def test_compose_validation_blocks_unrelated_service_before_up(self):
        old={'services':{'immich-server':{'image':'old'},'redis':{'image':'old'}}}
        new={'services':{'immich-server':{'image':'new'},'redis':{'image':'other'}}}
        with patch.object(release,'run',side_effect=[json.dumps(old),json.dumps(new)]) as run:
            with self.assertRaisesRegex(release.Stop,'unrelated'): release.recreate(['docker','compose'],Path('override'))
            self.assertEqual(run.call_count,2)

    def test_rollback_external_config_change_blocks_before_queue_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);config=root/'compose';config.write_text('changed')
            release.save(root/'deployment.json',{'previousImage':'previous','configHashes':{str(config):'expected'}})
            with patch.object(release,'inspect',return_value={'Image':release.IMAGE}),patch.object(release,'api') as api:
                with self.assertRaisesRegex(release.Stop,'changed externally'): release.rollback(SimpleNamespace(state=root,key=None,api='unused'))
                api.assert_not_called()

    def test_enable_requires_separate_retention_approval(self):
        with patch.object(release,'private_json') as read:
            with self.assertRaisesRegex(release.Stop,'separate approval'): release.enable(SimpleNamespace(retention_approved=False))
            read.assert_not_called()

    def test_nas_scope_and_samples(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);nas=root/'nas';local=root/'recovered';nas.mkdir();local.mkdir()
            proof=root/'proof';audit=root/'audit';state=root/'state';state.mkdir()
            samples=[]
            for kind in ('photo','video'):
                original=nas/kind;recovered=local/kind
                original.write_bytes(b'synthetic-'+kind.encode());recovered.write_bytes(original.read_bytes())
                samples.append({'kind':kind,'original':str(original),'recovered':str(recovered)})
            content={'mounts':{'/external':{'operator_attests_snapshot_export':True,
                'snapshot_reference':'synthetic-example-only','samples':samples}}}
            release.save(proof,content)
            audit.write_text(json.dumps({'containers':[{'role':release.SERVER,'externalMounts':[
                {'containerMountpoint':'/external','hostMountpoint':str(nas)}]}]}))
            with redirect_stdout(io.StringIO()): release.nas_check(proof,audit,state)
            with redirect_stdout(io.StringIO()): release.nas_check(proof,audit,state) # Same receipt, no overwrite.
            receipt=json.loads((state/'nas-verified.json').read_text())
            self.assertNotIn('synthetic-example-only',json.dumps(receipt))
            self.assertNotIn(str(nas),json.dumps(receipt))
            (local/'video').write_bytes(b'changed')
            with self.assertRaisesRegex(release.Stop,'bytes differ'): release.nas_check(proof,audit,state)

    def test_duplicate_upload_never_trashes_preexisting_asset(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(release,'inspect',return_value={'Image':release.IMAGE}), \
                 patch.object(release,'api',return_value={'id':'not-a-fixture','status':'duplicate'}) as api:
                with self.assertRaisesRegex(release.Stop,'did not create'): release.acceptance(SimpleNamespace(state=Path(directory),api='unused',key=None))
                self.assertEqual(api.call_count,1)

    def test_sign_existing_requires_explicit_approval_before_key_access(self):
        with patch('sys.argv',['release','sign-existing','--expected-head',android.CI_SOURCE_SHA]), \
             patch.object(android,'sign_existing') as signer, redirect_stderr(io.StringIO()):
            self.assertEqual(android.main(),1);signer.assert_not_called()

    def test_sign_existing_wrong_hash_does_not_access_key(self):
        with patch.object(android,'repository_check'),patch.object(android,'version_name',return_value='5.7.2'), \
             patch.object(android,'digest',return_value='wrong'),patch.object(android,'check_key_files') as key:
            with self.assertRaisesRegex(android.ReleaseError,'differs from run'): android.sign_existing(Path('/unused'),android.CI_SOURCE_SHA,8,Path('/unused.apk'),{})
            key.assert_not_called()

    def test_apk_payload_ignores_signatures_but_detects_application_change(self):
        with tempfile.TemporaryDirectory() as directory:
            files={name:b'synthetic' for name in ('classes.dex','lib/arm64-v8a/libapp.so','lib/arm64-v8a/libflutter.so')}
            def apk(name,signature,change=False):
                path=Path(directory)/name
                with zipfile.ZipFile(path,'w') as archive:
                    for key,value in files.items(): archive.writestr(key,value+(b'changed' if change else b''))
                    archive.writestr('META-INF/CERT.RSA',signature)
                    archive.writestr('META-INF/application-resource',b'must-survive')
                return android.apk_payload(path)
            self.assertEqual(apk('ci.apk',b'ci'),apk('hp.apk',b'hp'))
            self.assertNotEqual(apk('changed.apk',b'hp',True),apk('other.apk',b'ci'))
            self.assertIn('META-INF/application-resource',apk('resource.apk',b'ci'))

    def test_java_helper_uses_existing_alias_stdin_and_no_key_creation(self):
        text=(ROOT/'scripts/release/SignExistingApk.java').read_text()
        for value in ('properties.load(input)','"foto"','"--ks-pass", "stdin"','"--key-pass", "stdin"'):
            self.assertIn(value,text)
        self.assertNotIn('keytool',text)

    @unittest.skipUnless(os.environ.get('GALLERY_RELEASE_TEST_JAVA'),'needs explicit existing JDK 17')
    def test_actual_java17_source_launcher_and_properties_stdin_without_real_key(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);android=root/'android';android.mkdir()
            (android/'key.jks').write_bytes(b'NOT_A_REAL_KEY')
            (android/'key.properties').write_text('storeFile=key.jks\nkeyAlias=foto\nstorePassword=synthetic\\u0020store\nkeyPassword=synthetic-key\n')
            signer=root/'fake-apksigner'
            signer.write_text('#!/usr/bin/env python3\nimport sys\nfrom pathlib import Path\n'
                'assert sys.argv[1]=="sign"\nassert sys.argv[sys.argv.index("--ks-key-alias")+1]=="foto"\n'
                'assert sys.argv[sys.argv.index("--ks-pass")+1]=="stdin"\n'
                'assert sys.stdin.readline()=="synthetic store\\n"\n'
                'assert sys.stdin.readline()=="synthetic-key\\n"\n'
                'Path(sys.argv[sys.argv.index("--out")+1]).write_text("synthetic-success")\n')
            signer.chmod(0o700)
            result=subprocess.run([os.environ['GALLERY_RELEASE_TEST_JAVA'],str(ROOT/'scripts/release/SignExistingApk.java'),
                str(android),str(signer),'synthetic-input',str(root/'output')],text=True,capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual((root/'output').read_text(),'synthetic-success')
            self.assertNotIn('synthetic store',result.stdout+result.stderr)


@unittest.skipUnless(os.environ.get('GALLERY_DISPOSABLE_RELEASE_TESTS')=='1','opt-in local Docker fixtures')
class DisposableReleaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.env=os.environ.copy()
        for name in ('DOCKER_HOST','DOCKER_CONTEXT','DOCKER_TLS','DOCKER_TLS_VERIFY','DOCKER_CERT_PATH'):
            cls.env.pop(name,None)

    @classmethod
    def docker(cls,*args,input=None,**kwargs):
        return subprocess.run(['docker','--host=unix:///var/run/docker.sock',*args],input=input,
            text=True,capture_output=True,check=True,timeout=120,env=cls.env).stdout

    def test_actual_isolated_sql_gzip_restore_and_cleanup(self):
        pg=json.loads(self.docker('image','inspect','e163bcdc41b9'))[0]
        # Only production topology reads are fixtures; actual restore image,
        # anonymous volume, gzip stream, psql transaction and cleanup run for real.
        def fixture_inspect(name):
            return {'Id':'unchanged-fixture-'+name,'Image':pg['Id'],'Config':{'Env':[]}}
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);backup=root/'fixture.sql.gz'
            with gzip.open(backup,'wb') as file:
                file.write(b'CREATE TABLE library(id integer PRIMARY KEY); CREATE TABLE asset("libraryId" integer);'
                           b'INSERT INTO library VALUES(1); INSERT INTO asset VALUES(1);'
                           b'CREATE TABLE kysely_migrations(name text); INSERT INTO kysely_migrations VALUES(\'fixture\');')
            # This tiny synthetic DB needs <1 MiB; exercise restoration even
            # when the cloud disk cannot meet the real HP 8 GiB safety gate.
            with patch.object(release.shutil,'disk_usage',return_value=SimpleNamespace(free=9*1024**3)), \
                 patch.object(release,'docker',side_effect=self.docker),patch.object(release,'inspect',side_effect=fixture_inspect),redirect_stdout(io.StringIO()):
                release.restore_check(backup,root)
                release.restore_check(backup,root) # Receipt reuse, no second PG.
            receipt=json.loads((root/'backup-verified.json').read_text())
            self.assertEqual(receipt['restore'],'PASS_ISOLATED_SQL_TRANSACTION')
            self.assertEqual(receipt['assetCount'],1)
        self.assertEqual(self.docker('ps','-aq','--filter','name=gallery-restore-check-').strip(),'')

    def test_real_compose_server_recreate_and_api_only_rollback_preserve_other_service(self):
        project='gallery-rollback-fixture-'+secrets.token_hex(6)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);basefile=root/'compose.json'
            basefile.write_text(json.dumps({'services':{
                'immich-server':{'image':'postgres:16-alpine','entrypoint':['sh','-c','exec sleep 600']},
                'unrelated':{'image':'redis:7-alpine','entrypoint':['sh','-c','exec sleep 600']}}}))
            base=['docker','--host=unix:///var/run/docker.sock','compose','-p',project,'-f',str(basefile)]
            def command(args,**kwargs):
                return subprocess.run(args,text=True,capture_output=True,check=True,timeout=120,env=self.env).stdout
            def fixture_inspect(name):
                return json.loads(command([*base,'ps','-q',name]) and self.docker('inspect',command([*base,'ps','-q',name]).strip()))[0]
            with patch.object(release,'run',side_effect=command),patch.object(release,'docker',side_effect=self.docker):
                try:
                    command([*base,'up','-d','--pull','never'])
                    previous=fixture_inspect('immich-server');other=fixture_inspect('unrelated')['Id']
                    release.recreate(base,release.override(root,'redis:7-alpine'))
                    self.assertTrue(release.api_only(fixture_inspect('immich-server')))
                    release.save(root/'deployment.json',{'previousTag':'postgres:16-alpine','previousImage':previous['Image'],
                        'configHashes':{str(basefile):release.digest(basefile)},'base':base,'otherContainers':{'unrelated':other}})
                    with patch.object(release,'inspect',side_effect=fixture_inspect), \
                         patch.object(release,'IMAGE',fixture_inspect('immich-server')['Image']), \
                         patch.object(release,'SERVER','immich-server'),patch.object(release,'health'), \
                         patch.object(release,'queue_empty',return_value={'paused':True}),redirect_stdout(io.StringIO()):
                        release.rollback(SimpleNamespace(state=root,api='fixture',key=None))
                        release.rollback(SimpleNamespace(state=root,api='fixture',key=None))
                    self.assertEqual(fixture_inspect('immich-server')['Image'],previous['Image'])
                    self.assertTrue(release.api_only(fixture_inspect('immich-server')))
                    self.assertEqual(fixture_inspect('unrelated')['Id'],other)
                finally:
                    command([*base,'down','--volumes']) # Only unique disposable project.

    def test_failed_sql_restore_cleans_own_fixture_and_cannot_issue_receipt(self):
        pg=json.loads(self.docker('image','inspect','e163bcdc41b9'))[0]
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);backup=root/'bad.sql.gz'
            with gzip.open(backup,'wb') as file: file.write(b'INVALID SQL;')
            with patch.object(release.shutil,'disk_usage',return_value=SimpleNamespace(free=9*1024**3)), \
                 patch.object(release,'docker',side_effect=self.docker), \
                 patch.object(release,'inspect',return_value={'Id':'fixture','Image':pg['Id'],'Config':{'Env':[]}}):
                with self.assertRaisesRegex(release.Stop,'SQL restore failed'): release.restore_check(backup,root)
            self.assertFalse((root/'backup-verified.json').exists())
            self.assertTrue((root/'restore-private.log').is_file())
        self.assertEqual(self.docker('ps','-aq','--filter','name=gallery-restore-check-').strip(),'')


if __name__=='__main__': unittest.main()
