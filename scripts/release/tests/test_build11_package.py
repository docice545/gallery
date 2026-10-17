"""Compiled binary package assembly; synthetic payloads only, no build/deploy."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import build11_artifacts as artifacts
import build11_package as m
import gallery_entry as entry
from test_build11_artifacts import profile

class Assembly(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name); self.input=self.root/'input'; self.rollback=self.root/'rollback'
        self.rollback.mkdir()
        self.profile=profile()
        for name in ('backend/gallery-server-linux-amd64.tar.gz','android/app-release.apk','ios/Photos-unsigned.ipa'):
            file=self.input/name;file.parent.mkdir(parents=True,exist_ok=True);file.write_bytes(b'synthetic-'+name.encode())
        self.profile['backend']['archiveSHA256']=artifacts.digest(self.input/'backend/gallery-server-linux-amd64.tar.gz')
        self.profile['android']['sha256']=artifacts.digest(self.input/'android/app-release.apk')
        self.profile['ios']['sha256']=artifacts.digest(self.input/'ios/Photos-unsigned.ipa')
        (self.input/'backend/manifest.json').write_text(json.dumps(self.profile['backend']))
        (self.rollback/'gallery-server-linux-amd64.tar.gz').write_bytes(b'synthetic rollback')
        self.rollback_manifest={'imageId':'sha256:'+'f'*64,'sourceCommit':'f'*40,
                                 'archiveSHA256':artifacts.digest(self.rollback/'gallery-server-linux-amd64.tar.gz')}
        (self.rollback/'manifest.json').write_text(json.dumps(self.rollback_manifest))
        self.checks=dict(isolatedDatabase=True,oldRuntimeStartsOnUpgradedSchema=True,storagePoliciesRejectedByRollback=True,
                         trashRestoreAfterRollback=True,syntheticMediaOnly=True,productionChanged=False)
        self.runtime=dict(self.checks,sourceCommit=self.profile['sourceCommit'],candidateImageId=self.profile['backend']['imageId'],
                          rollbackSourceCommit=self.rollback_manifest['sourceCommit'],rollbackImageId=self.rollback_manifest['imageId'],
                          rollbackArchiveSHA256=self.rollback_manifest['archiveSHA256'])
        self.runtime_path=self.input/'backend/build11-rollback-runtime.json';self.runtime_path.write_text(json.dumps(self.runtime))
        self.compatibility=dict(candidateSource=self.profile['sourceCommit'],candidateImage=self.profile['backend']['imageId'],
                                rollbackSource=self.rollback_manifest['sourceCommit'],rollbackImage=self.rollback_manifest['imageId'],
                                testReportSHA256=artifacts.digest(self.runtime_path),rollbackTest=self.checks)
        self.profile_path=self.root/'profile.json';self.profile_path.write_text(json.dumps(self.profile))
        self.compatibility_path=self.root/'compatibility.json';self.compatibility_path.write_text(json.dumps(self.compatibility))
        self.args=SimpleNamespace(profile=self.profile_path,profile_sha256=artifacts.digest(self.profile_path),
                                  compatibility=self.compatibility_path,compatibility_sha256=artifacts.digest(self.compatibility_path),
                                  artifacts=self.input,rollback_artifacts=self.rollback,output=self.root/'package',
                                  machine_learning_image='sha256:'+'e'*64,machine_learning_reference=None)

    def test_complete_package_can_be_checked_and_all_tool_entrypoints_import_without_source_checkout(self):
        m.assemble(self.args);entry.verify_package(self.args.output)
        for name in ('build11_operator.py','gallery_install.py','android_sign_package.py'):
            result=subprocess.run([sys.executable,'-B',str(self.args.output/'tools'/name),'--help'],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,name+' dependency missing')

    def test_changed_or_synthetic_acceptance_flags_cannot_create_package(self):
        for field,value in [('productionChanged',True),('oldRuntimeStartsOnUpgradedSchema',False),
                            ('sourceCommit','b'*40),('rollbackImageId','sha256:'+'a'*64)]:
            runtime=dict(self.runtime);runtime[field]=value;self.runtime_path.write_text(json.dumps(runtime))
            compatibility=dict(self.compatibility,testReportSHA256=artifacts.digest(self.runtime_path))
            self.compatibility_path.write_text(json.dumps(compatibility));self.args.compatibility_sha256=artifacts.digest(self.compatibility_path)
            with self.subTest(field=field),self.assertRaisesRegex(ValueError,'ROLLBACK_RUNTIME'):
                m.assemble(self.args)
            self.assertFalse(self.args.output.exists())

    def test_different_report_bytes_are_rejected_even_if_outcome_is_identical(self):
        self.runtime_path.write_text(json.dumps(self.runtime,indent=2))
        with self.assertRaisesRegex(ValueError,'REAL_ROLLBACK_RUNTIME_REPORT'):m.assemble(self.args)
        self.assertFalse(self.args.output.exists())

if __name__=='__main__':unittest.main()
