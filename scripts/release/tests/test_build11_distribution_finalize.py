"""Synthetic finalization fixtures; real compiled installation executes only in CI."""
import json
import os
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build11_artifacts as artifacts
import build11_distribution_finalize as m
import build11_package as package
import gallery_entry as entry
from test_build11_package import Assembly


class Finalization(unittest.TestCase):
    def setUp(self):
        fixture = Assembly(); fixture.setUp(); self.addCleanup(fixture.doCleanups)
        self.fixture = fixture
        package.assemble(fixture.args)
        self.root = fixture.root; self.output = fixture.args.output
        self.input_sums = (self.output / 'SHA256SUMS').read_bytes()
        self.report = dict(schemaVersion=1, marker=m.MARKER, result='PASS', sourceCommit=fixture.profile['sourceCommit'],
                           packageSHA256=artifacts.digest(self.output / 'SHA256SUMS'), cleanupErrors=[],
                           syntheticMediaOnly=True, productionChanged=False, checks={key: True for key in m.CHECKS},
                           installationEngine='PACKAGED_GALLERY_INSTALL',
                           upgradeEngine='PACKAGED_IMAGE_RELEASE_WITH_REAL_READ_ONLY_LAB_QUEUE_GATE',
                           hpWrapper='NOT_TESTED_HP_RECOVERY_AND_OLD_SIX_REQUIRED',
                           **{gate: False for gate in m.GATES})
        self.upstream = dict(status='PASS', upstreamURL='https://github.com/open-noodle/gallery', upstreamBase=m.UPSTREAM,
                             api={'status': 'PASS'}, migrations={'status': 'PASS'}, workingTreeDirty=False,
                             candidateHead='b' * 40)
        self.report_path=self.root/'lab.json'; self.report_path.write_text(json.dumps(self.report))
        self.upstream_path=self.root/'upstream.json'; self.upstream_path.write_text(json.dumps(self.upstream))
        self.notes=self.root/'notes.md'; self.notes.write_text('Synthetic release notes fixture')
        self.args=SimpleNamespace(package=self.output,installation_report=self.report_path,
                                  upstream_report=self.upstream_path,release_notes=self.notes)
        self.env=patch.dict(os.environ, {'GITHUB_ACTIONS':'true','GALLERY_ISOLATED_CI':'1'})
        self.env.start(); self.addCleanup(self.env.stop)

    def test_complete_report_preserves_tested_input_and_unchanged_report_bytes(self):
        report_bytes=self.report_path.read_bytes(); m.finalize(self.args)
        config=entry.verify_package(self.output)
        self.assertEqual((self.output/'validation/installation-lab-input-SHA256SUMS').read_bytes(),self.input_sums)
        self.assertEqual((self.output/'validation/installation-lab.json').read_bytes(),report_bytes)
        self.assertEqual(config['installationValidation']['reportSHA256'],artifacts.digest(self.report_path))
        self.assertNotEqual(artifacts.digest(self.output/'SHA256SUMS'),self.report['packageSHA256'])

    def test_absent_false_and_non_boolean_check_blocks_publication(self):
        for value in (None,False,1):
            self.report['checks']['freshInstallRollbackWithPackagedWrapper']=value
            self.report_path.write_text(json.dumps(self.report))
            with self.subTest(value=value),self.assertRaisesRegex(ValueError,'ALL_REQUIRED'):m.finalize(self.args)
            self.assertFalse((self.output/'validation').exists())

    def test_wrong_source_initial_package_failure_and_cleanup_error_block_publication(self):
        for key,value in [('sourceCommit','c'*40),('packageSHA256','c'*64),('result','FAIL'),
                          ('cleanupErrors',['failed']),('productionChanged',True)]:
            previous=self.report[key];self.report[key]=value;self.report_path.write_text(json.dumps(self.report))
            with self.subTest(key=key),self.assertRaisesRegex(ValueError,'ALL_REQUIRED'):m.finalize(self.args)
            self.assertFalse((self.output/'validation').exists());self.report[key]=previous

    def test_no_production_or_device_pass_can_be_fabricated(self):
        for gate in m.GATES:
            self.report[gate]=True;self.report_path.write_text(json.dumps(self.report))
            with self.subTest(gate=gate),self.assertRaisesRegex(ValueError,'ALL_REQUIRED'):m.finalize(self.args)
            self.report[gate]=False

    def test_mocked_installation_engine_or_claimed_hp_execution_is_rejected(self):
        for key,value in [('installationEngine','MOCKED_INSTALLER'),('upgradeEngine','MOCKED_UPGRADE'),('hpWrapper','PASS')]:
            previous=self.report[key];self.report[key]=value;self.report_path.write_text(json.dumps(self.report))
            with self.subTest(key=key),self.assertRaisesRegex(ValueError,'EXACT_TESTED'):m.finalize(self.args)
            self.report[key]=previous

    def test_wrong_upstream_base_dirty_source_or_failed_wire_guard_is_rejected(self):
        for key,value in [('upstreamBase','c'*40),('workingTreeDirty',True),('api',{'status':'FAIL'}),('status','FAIL')]:
            previous=self.upstream[key];self.upstream[key]=value;self.upstream_path.write_text(json.dumps(self.upstream))
            with self.subTest(key=key),self.assertRaisesRegex(ValueError,'UPSTREAM_STRUCTURAL'):m.finalize(self.args)
            self.upstream[key]=previous

    def test_repeat_cannot_freshen_or_overwrite_previous_validation(self):
        m.finalize(self.args);original=(self.output/'validation/installation-lab.json').read_bytes()
        with self.assertRaises(ValueError):m.finalize(self.args)
        self.assertEqual((self.output/'validation/installation-lab.json').read_bytes(),original)

    def test_execution_outside_explicit_disposable_ci_fails_before_mutation(self):
        with patch.dict(os.environ,{'GALLERY_ISOLATED_CI':'0'}),self.assertRaisesRegex(ValueError,'DISPOSABLE'):
            m.finalize(self.args)
        self.assertFalse((self.output/'validation').exists())


if __name__=='__main__':unittest.main()
