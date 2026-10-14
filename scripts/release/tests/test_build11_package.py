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
from test_trash_image_identity import fixture

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

    def test_packaged_compose_changes_only_redis_to_same_verified_amd64_child_without_editing_source(self):
        source=m.artifacts.ROOT/'docker/docker-compose.yml'
        original=source.read_bytes()
        m.assemble(self.args)
        self.assertEqual(source.read_bytes(),original)
        self.assertEqual((self.args.output/'config/docker-compose.yml').read_bytes(),
                         original.replace(m.installer.VALKEY_UPSTREAM_REFERENCE.encode(),
                                          m.installer.VALKEY_AMD64_REFERENCE.encode(),1))
        config=entry.verify_package(self.args.output)
        self.assertEqual(config['publicDependencyProvenance'],{'redis':{
            'upstreamReference':m.installer.VALKEY_UPSTREAM_REFERENCE,
            'selectedReference':m.installer.VALKEY_AMD64_REFERENCE,
            'indexDigest':m.installer.VALKEY_UPSTREAM_INDEX,
            'manifestDigest':m.installer.VALKEY_AMD64_MANIFEST,
            'configDigest':m.installer.VALKEY_AMD64_CONFIG,'platform':'linux/amd64'}})
        config['publicDependencyProvenance']['redis']['indexDigest']='sha256:'+'a'*64
        (self.args.output/'release-operator.json').write_text(json.dumps(config))
        with self.assertRaisesRegex(ValueError,'RELEASE_PACKAGE_FILE_CHANGED'):
            entry.verify_package(self.args.output)

    def test_missing_duplicate_commented_or_reassigned_upstream_redis_pin_is_rejected_before_output(self):
        original=(m.artifacts.ROOT/'docker/docker-compose.yml').read_bytes()
        old=m.installer.VALKEY_UPSTREAM_REFERENCE.encode()
        new=m.installer.VALKEY_AMD64_REFERENCE.encode()
        fixtures=[original.replace(old,b'valkey/valkey:9'),
                  original+b'\n# duplicate '+old+b'\n',
                  original.replace(b'    image: '+old,b'    # image: '+old),
                  original.replace(b'  redis:\n',b'  unreviewed-service:\n'),
                  original+b'\n    image: '+old+b'\n',
                  original+b'\n# already selected '+new+b'\n']
        fixture_root=self.root/'source-fixture'
        (fixture_root/'docker').mkdir(parents=True)
        source=fixture_root/'docker/docker-compose.yml'
        for index,data in enumerate(fixtures):
            source.write_bytes(data)
            with self.subTest(index=index),patch.object(m.artifacts,'ROOT',fixture_root),\
                 self.assertRaisesRegex(ValueError,'EXACT_UPSTREAM_REDIS_PIN'):
                m.assemble(self.args)
            self.assertEqual(source.read_bytes(),data)
            self.assertFalse(self.args.output.exists())

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

    def test_containerd_runtime_id_is_preserved_and_bound_to_actual_archive_graph(self):
        stream, config, loaded = fixture(oci=True, tag='gallery-test:identity')
        (self.rollback / 'gallery-server-linux-amd64.tar.gz').write_bytes(stream.getvalue())
        self.rollback_manifest.update(imageId=config, imageTag='gallery-test:identity',
                                      archiveSHA256=artifacts.digest(self.rollback / 'gallery-server-linux-amd64.tar.gz'))
        (self.rollback / 'manifest.json').write_text(json.dumps(self.rollback_manifest))
        self.runtime.update(rollbackImageId=loaded, rollbackArchiveSHA256=self.rollback_manifest['archiveSHA256'])
        self.runtime_path.write_text(json.dumps(self.runtime))
        self.compatibility.update(rollbackImage=config, testReportSHA256=artifacts.digest(self.runtime_path),
                                  rollbackRuntimeImageIdentity=dict(configDigest=config, loadedImageId=loaded,
                                                                    identityKind='MANIFEST_DIGEST'))
        self.compatibility_path.write_text(json.dumps(self.compatibility))
        self.args.compatibility_sha256=artifacts.digest(self.compatibility_path)
        m.assemble(self.args)
        self.assertEqual((self.args.output / 'backend/build11-rollback-runtime.json').read_bytes(),
                         self.runtime_path.read_bytes())

    def test_forged_containerd_alias_is_rejected_even_with_plausible_identity_fields(self):
        stream, config, loaded = fixture(oci=True, tag='gallery-test:identity')
        (self.rollback / 'gallery-server-linux-amd64.tar.gz').write_bytes(stream.getvalue())
        self.rollback_manifest.update(imageId=config, imageTag='gallery-test:identity',
                                      archiveSHA256=artifacts.digest(self.rollback / 'gallery-server-linux-amd64.tar.gz'))
        (self.rollback / 'manifest.json').write_text(json.dumps(self.rollback_manifest))
        foreign='sha256:'+'e'*64
        self.runtime.update(rollbackImageId=foreign, rollbackArchiveSHA256=self.rollback_manifest['archiveSHA256'])
        self.runtime_path.write_text(json.dumps(self.runtime))
        self.compatibility.update(rollbackImage=config, testReportSHA256=artifacts.digest(self.runtime_path),
                                  rollbackRuntimeImageIdentity=dict(configDigest=config, loadedImageId=foreign,
                                                                    identityKind='MANIFEST_DIGEST'))
        self.compatibility_path.write_text(json.dumps(self.compatibility))
        self.args.compatibility_sha256=artifacts.digest(self.compatibility_path)
        with self.assertRaisesRegex(artifacts.identity.IdentityError,'NOT_IN_VERIFIED_GRAPH'):m.assemble(self.args)
        self.assertFalse(self.args.output.exists())

if __name__=='__main__':unittest.main()
