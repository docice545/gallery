import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('checks',ROOT/'android-preflight.py')
checks=importlib.util.module_from_spec(spec);spec.loader.exec_module(checks)

class Checks(unittest.TestCase):
    def test_next_code_uses_measured_versions_not_build_name(self):
        self.assertEqual(checks.next_version_code(38, 38), 39)
        self.assertEqual(checks.next_version_code(39, 39), 40)
        self.assertEqual(checks.next_version_code(38, 108), 109)
        self.assertEqual(checks.next_version_code(108, 38), 109)
    def test_next_code_rejects_invalid_or_exhausted_counter(self):
        for baseline, installed in [(0, 39), (39, -1), (39, 2100000000)]:
            with self.assertRaises(ValueError):
                checks.next_version_code(baseline, installed)
    def test_sdk_absolute_paths_and_pinned_tools(self):
        with tempfile.TemporaryDirectory(prefix='foto sdk ') as tmp:
            root=Path(tmp)
            for version in ['35.0.0','36.0.0','37.0.0']:
                folder=root/'build-tools'/version;folder.mkdir(parents=True)
                for name in ['aapt','apksigner']:
                    p=folder/name;p.write_text('#!/bin/sh\nexit 0\n');p.chmod(0o700)
            result=checks.sdk_tools(root,root)
            self.assertEqual(result['build_tools'],'36.0.0')
            self.assertTrue(Path(result['aapt']).is_absolute())
            self.assertTrue(result['release_helper_tools_36_0_0_present'])
    def test_sdk_missing_pair_stops_without_install(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError):checks.sdk_tools(Path(tmp),tmp)
            self.assertEqual(list(Path(tmp).iterdir()),[])
    def test_apk_metadata_uses_binary_tools_and_correct_ids(self):
        with tempfile.TemporaryDirectory() as tmp:
            apk=Path(tmp)/'fixture.apk';apk.write_bytes(b'synthetic-fixture-only')
            with patch.object(checks,'run',side_effect=["package: name='de.opennoodle.gallery' versionCode='39' versionName='5.7.3'\n",'Signer #1 certificate SHA-256 digest: '+checks.HISTORICAL_CERT+'\n']) as cmd:
                result=checks.apk_metadata(apk,{'aapt':'/SDK/aapt','apksigner':'/SDK/apksigner'})
            self.assertEqual(result['versionCode'],39)
            self.assertEqual(cmd.call_args_list[1].args[0][1],'verify')
    def test_wrong_apk_package_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            apk=Path(tmp)/'fixture.apk';apk.write_bytes(b'x')
            with patch.object(checks,'run',return_value="package: name='de.opennoodle.gallery.debug' versionCode='39'\n"):
                with self.assertRaises(ValueError):checks.apk_metadata(apk,{'aapt':'aapt','apksigner':'apksigner'})
    def check_key_fixture(self, mismatch):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); android=root/'mobile/android';android.mkdir(parents=True)
            (android/'key.jks').write_bytes(b'SYNTHETIC-NOT-A-KEY')
            (android/'key.properties').write_text('keyAlias=foto\nstorePassword=never-print-this\n')
            password='test-only-private-input'
            cert=('0'*64 if mismatch else checks.HISTORICAL_CERT)
            response=subprocess.CompletedProcess([],0,'Entry type: PrivateKeyEntry\n SHA256: '+cert+'\n','')
            with patch.object(checks,'run',side_effect=['','mobile/android/key.jks\nmobile/android/key.properties\n']), patch.object(checks.shutil,'which',return_value='/jdk/keytool'), patch.object(checks.sys.stdin,'isatty',return_value=True), patch.object(checks.getpass,'getpass',return_value=password), patch.object(checks.subprocess,'run',return_value=response) as child:
                if mismatch:
                    with self.assertRaisesRegex(ValueError,'MISMATCH'): checks.keys_match(root,{'certificateSHA256':checks.HISTORICAL_CERT})
                else:
                    result=checks.keys_match(root,{'certificateSHA256':checks.HISTORICAL_CERT})
                    self.assertTrue(result['files_unchanged'])
                    self.assertFalse(result['actual_signing_performed'])
                    self.assertNotIn(password,json.dumps(result))
                self.assertNotIn(password,' '.join(child.call_args.args[0]))
                self.assertEqual(child.call_args.kwargs['input'],password+'\n')
                self.assertNotIn('env',child.call_args.kwargs)
    def test_key_certificate_match_without_signing(self):self.check_key_fixture(False)
    def test_key_certificate_mismatch_stops(self):self.check_key_fixture(True)
    def test_isolated_worktree_preserves_dirty_hp_fixture_and_ignored_keys(self):
        with tempfile.TemporaryDirectory(prefix='foto-git-fixture-') as tmp:
            parent=Path(tmp);repo=parent/'source';repo.mkdir()
            def git(*args,**kwargs):return subprocess.check_output(['git',*args],cwd=repo,stderr=subprocess.PIPE,**kwargs).decode().strip()
            git('init','-b','fixture-hp');git('config','user.name','Fixture');git('config','user.email','fixture@example.invalid')
            (repo/'app.txt').write_text('original\n')
            (repo/'.gitignore').write_text('mobile/android/key.jks\nmobile/android/key.properties\n')
            git('add','.');git('commit','-m','fixture base');base=git('rev-parse','HEAD')
            (repo/'app.txt').write_text('hotfix\n');git('add','app.txt')
            target=git('commit-tree',git('write-tree'),'-p',base,'-m','fixture hotfix')
            git('update-ref','refs/heads/codex/foto-build38-unified-16',target);git('remote','add','origin','.')
            (repo/'app.txt').write_text('uncommitted owner edit\n');(repo/'owner-note').write_text('retain me\n')
            android=repo/'mobile/android';android.mkdir(parents=True)
            for name in ['key.jks','key.properties']:(android/name).write_text('synthetic ignored '+name)
            before={str(p.relative_to(repo)):p.read_bytes() for p in [repo/'app.txt',repo/'owner-note',android/'key.jks',android/'key.properties']}
            before_index=git('diff','--cached','--binary')
            hook=repo/'.git/hooks/post-checkout';hook.write_text('#!/bin/sh\ntouch "'+str(parent/'hook-executed')+'"\n');hook.chmod(0o700)
            script=(ROOT/'stage-hotfix-worktree.sh').read_text().replace('/mnt/hp-data/foto-build38/source',str(repo)).replace('/mnt/hp-data/foto-build38/hotfix-fc1126dd4-XXXXXX',str(parent/'candidate-XXXXXX')).replace(checks.HP_SHA,base).replace(checks.HOTFIX,target).replace('foto-build39-hp-serial-tests','fixture-hp')
            result=subprocess.run(['bash','-c',script],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            candidate=Path(next(s.split('=',1)[1] for s in result.stdout.splitlines() if s.startswith('CANDIDATE=')))
            self.assertEqual((candidate/'app.txt').read_text(),'hotfix\n')
            self.assertEqual(git('rev-parse','HEAD'),base)
            self.assertEqual(git('branch','--show-current'),'fixture-hp')
            self.assertEqual(git('diff','--cached','--binary'),before_index)
            for name,data in before.items():self.assertEqual((repo/name).read_bytes(),data)
            self.assertFalse((candidate/'mobile/android/key.jks').exists())
            self.assertFalse((parent/'hook-executed').exists())
            self.assertEqual(subprocess.check_output(['git','branch','--show-current'],cwd=candidate).strip(),b'')

if __name__=='__main__':unittest.main(verbosity=2)
