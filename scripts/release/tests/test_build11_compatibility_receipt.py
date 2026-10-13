"""Synthetic receipts test fail-closed bindings; actual image proof runs in CI."""
import copy
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build11_artifacts as artifacts
import build11_compatibility_receipt as m
from test_build11_artifacts import profile
from test_trash_image_identity import fixture

SOURCE = 'a' * 40
ROLLBACK = 'f' * 40
RUNS = dict(backend=1, android=2, ios=3, rollback=4)


def gh(endpoint):
    run = int(endpoint.split('/runs/')[1].split('/')[0])
    platform = next(key for key, value in RUNS.items() if value == run)
    if '/artifacts' in endpoint:
        return {'total_count': 1, 'artifacts': [dict(id=run + 100, name=m.ARTIFACTS[platform],
                                                  expired=False, size_in_bytes=200)]}
    workflow = 'gallery-build-mobile.yml' if platform in ('android', 'ios') else 'gallery-trash-server-build.yml'
    return dict(status='completed', conclusion='success', head_sha=ROLLBACK if platform == 'rollback' else SOURCE,
                path='.github/workflows/' + workflow, repository={'full_name': 'docice545/gallery'})


class RunInventory(unittest.TestCase):
    def test_exact_successful_same_source_runs_are_bound_to_four_real_artifact_ids(self):
        with patch.object(artifacts, 'gh', side_effect=gh):
            result = m.verify_runs(SOURCE, RUNS, ROLLBACK)
        self.assertEqual(result['backend']['artifactId'], 101)
        self.assertEqual(result['rollback']['sourceCommit'], ROLLBACK)

    def test_wrong_source_workflow_repository_and_failed_or_incomplete_run_are_rejected(self):
        for key, value in [('path', '.github/workflows/paid-release.yml'),
                           ('repository', {'full_name': 'foreign/gallery'}), ('status', 'in_progress'),
                           ('conclusion', 'failure')]:
            def changed(endpoint):
                row = gh(endpoint)
                if '/artifacts' not in endpoint and '/runs/1' in endpoint:
                    row[key] = value
                return row
            with self.subTest(field=key), patch.object(artifacts, 'gh', side_effect=changed), \
                    self.assertRaisesRegex(ValueError, 'EXACT_SUCCESSFUL'):
                m.verify_runs(SOURCE, RUNS, ROLLBACK)

    def test_missing_duplicate_expired_oversized_and_incomplete_artifact_inventory_is_rejected(self):
        for change in ('missing', 'duplicate', 'expired', 'oversized', 'incomplete'):
            def changed(endpoint):
                row = gh(endpoint)
                if '/artifacts' in endpoint and '/runs/1/' in endpoint:
                    if change == 'missing': row['artifacts'] = []; row['total_count'] = 0
                    if change == 'duplicate': row['artifacts'] *= 2; row['total_count'] = 2
                    if change == 'expired': row['artifacts'][0]['expired'] = True
                    if change == 'oversized': row['artifacts'][0]['size_in_bytes'] = 4 * 1024**3
                    if change == 'incomplete': row['total_count'] = 101
                return row
            with self.subTest(change=change), patch.object(artifacts, 'gh', side_effect=changed), self.assertRaises(ValueError):
                m.verify_runs(SOURCE, RUNS, ROLLBACK)

    def test_backend_harness_only_descendant_requires_real_ancestry_and_input_diff_checks(self):
        def changed(endpoint):
            row = gh(endpoint)
            if '/artifacts' not in endpoint and '/runs/1' in endpoint:
                row['head_sha'] = 'b' * 40
            return row
        with patch.object(artifacts, 'gh', side_effect=changed), \
                patch.object(artifacts.subprocess, 'run', return_value=SimpleNamespace(returncode=0)) as git:
            result = m.verify_runs(SOURCE, RUNS, ROLLBACK)
        self.assertEqual(result['backend']['sourceCommit'], SOURCE)
        self.assertEqual(result['backend']['toolingCommit'], 'b' * 40)
        self.assertEqual(git.call_count, 2)
        self.assertIn('merge-base', git.call_args_list[0].args[0])
        self.assertIn('server', git.call_args_list[1].args[0])
        self.assertIn('.pnpmfile.cjs', git.call_args_list[1].args[0])
        for codes in ([1], [0, 1]):
            with self.subTest(codes=codes), patch.object(artifacts, 'gh', side_effect=changed), \
                    patch.object(artifacts.subprocess, 'run', side_effect=[SimpleNamespace(returncode=code) for code in codes]), \
                    self.assertRaisesRegex(ValueError, 'IDENTICAL_APPLICATION_INPUTS'):
                m.verify_runs(SOURCE, RUNS, ROLLBACK)

    def test_mobile_source_cannot_be_substituted_by_a_tooling_descendant(self):
        def changed(endpoint):
            row = gh(endpoint)
            if '/artifacts' not in endpoint and '/runs/2' in endpoint: row['head_sha'] = 'b' * 40
            return row
        with patch.object(artifacts, 'gh', side_effect=changed), self.assertRaisesRegex(ValueError, 'EXACT_SUCCESSFUL'):
            m.verify_runs(SOURCE, RUNS, ROLLBACK)

    def test_historical_or_duplicated_run_defaults_cannot_be_used_as_build11(self):
        for source, runs, rollback in [(SOURCE, {**RUNS, 'android': 1}, ROLLBACK),
                                       (SOURCE, {**RUNS, 'ios': 0}, ROLLBACK),
                                       ('', RUNS, ROLLBACK), (SOURCE, RUNS, SOURCE)]:
            with self.subTest(runs=runs), self.assertRaises(ValueError): m.verify_runs(source, runs, rollback)


class ActualReceiptBindings(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.input = self.root / 'input'; self.rollback = self.root / 'rollback'
        (self.input / 'backend').mkdir(parents=True); self.rollback.mkdir()
        self.profile = profile()
        self.profile['backend']['toolingCommit'] = SOURCE
        self.profile['backendRun'] = RUNS['backend']; self.profile['backendArtifactId'] = 101
        for platform in ('android', 'ios'):
            self.profile[platform]['run'] = RUNS[platform]; self.profile[platform]['artifactId'] = RUNS[platform] + 100
        self.rollback_manifest = dict(sourceCommit=ROLLBACK, serverVersion='5.7.3', imageId='sha256:' + 'f' * 64,
                                      archiveSHA256='d' * 64, imageTag='gallery-server:trash-' + ROLLBACK[:12])
        (self.rollback / 'manifest.json').write_text(json.dumps(self.rollback_manifest))
        self.runtime = dict(m.CHECKS, schemaVersion=1, sourceCommit=SOURCE,
                            candidateImageId=self.profile['backend']['imageId'], rollbackSourceCommit=ROLLBACK,
                            rollbackImageId=self.rollback_manifest['imageId'], rollbackArchiveSHA256='d' * 64)
        self.runtime_path = self.input / 'backend/build11-rollback-runtime.json'; self.write_runtime()
        self.profile_path = self.root / 'profile.json'
        self.profile_path.write_text(json.dumps(self.profile))
        self.args = SimpleNamespace(artifacts=self.input, rollback_artifacts=self.rollback, profile=self.profile_path,
                                    profile_sha256=artifacts.digest(self.profile_path), output=self.root / 'compatibility.json',
                                    rollback_source=ROLLBACK, rollback_run=RUNS['rollback'])
        guards = {path: 'a' * 64 for path in ('utils/authorized-deletion.js', 'utils/deletion-recovery.js',
                                            'repositories/asset.repository.js', 'repositories/storage.repository.js',
                                            'services/asset.service.js', 'services/library.service.js')}
        migrations = [dict(name=m.core.BOUND_MIGRATION, sha256='a' * 64), dict(name=m.MIGRATION, sha256='b' * 64)]
        self.candidate_proof = dict(sourceCommit=SOURCE, serverVersion='5.7.3', capability=m.core.OWNER_STORAGE_CAPABILITY,
                                    guardFiles=guards, migrations=migrations)
        self.rollback_proof = dict(sourceCommit=ROLLBACK, serverVersion='5.7.3', capability=m.core.CAPABILITY,
                                   guardFiles=copy.deepcopy(guards), migrations=copy.deepcopy(migrations))
        self.env = patch.dict(os.environ, {'GITHUB_ACTIONS': 'true', 'GALLERY_DISPOSABLE_RELEASE_TESTS': '1'})
        self.env.start(); self.addCleanup(self.env.stop)

    def write_runtime(self):
        self.runtime_path.write_text(json.dumps(self.runtime))
        self.profile['backend'].update(rollbackRuntimeReceiptSHA256=artifacts.digest(self.runtime_path),
                                      rollbackVerification='PASS_ACTUAL_PINNED_OLD_RUNTIME_HTTP_ON_BUILD11_SCHEMA',
                                      isolatedWorkerConfiguration='API_AND_MICROSERVICES',
                                      thumbnailPreviewVerification='PASS_SYNTHETIC_FILES_AND_HTTP')
        (self.input / 'backend/manifest.json').write_text(json.dumps(self.profile['backend']))

    def build(self, candidate=None, rollback=None):
        with patch.object(artifacts, 'gh', side_effect=gh), \
                patch.object(m.operator, 'artifact_image', side_effect=[self.profile['backend']['imageId'],
                                                                      self.rollback_manifest['imageId']]) as images, \
                patch.object(m.core, 'probe_image', side_effect=[candidate or self.candidate_proof,
                                                                rollback or self.rollback_proof]) as probe:
            result = m.build(self.args)
            self.assertEqual(images.call_count, 2); self.assertEqual(probe.call_count, 2)
            self.assertTrue(all(call.kwargs['allow_load'] is True for call in images.call_args_list))
            return result

    def test_receipt_binds_actual_probes_report_bytes_source_and_existing_migration(self):
        receipt = self.build()
        self.assertEqual(receipt['candidateProof'], self.candidate_proof)
        self.assertEqual(receipt['testReportSHA256'], artifacts.digest(self.runtime_path))
        self.assertTrue(receipt['rollbackContainsAdditiveMigration'])
        self.assertEqual(receipt['rollbackTest'], m.CHECKS)

    def test_no_hp_execution_gate(self):
        with patch.dict(os.environ, {'GITHUB_ACTIONS': 'false'}), self.assertRaisesRegex(ValueError, 'DISPOSABLE'):
            self.build()
        self.assertFalse(self.args.output.exists())

    def test_changed_receipt_bytes_fail_even_if_the_booleans_are_identical(self):
        self.runtime_path.write_text(json.dumps(self.runtime, indent=2))
        with self.assertRaisesRegex(ValueError, 'ACTUAL_RUNTIME'): self.build()
        self.assertFalse(self.args.output.exists())

    def test_wrong_owner_source_image_and_missing_acceptance_fail_closed(self):
        for key, value in [('sourceCommit', 'b' * 40), ('rollbackSourceCommit', 'b' * 40),
                           ('candidateImageId', 'sha256:' + 'e' * 64),
                           ('rollbackArchiveSHA256', 'e' * 64), ('oldRuntimeStartsOnUpgradedSchema', False),
                           ('syntheticMediaOnly', 1), ('productionChanged', True)]:
            original = self.runtime[key]; self.runtime[key] = value; self.write_runtime()
            self.profile_path.write_text(json.dumps(self.profile)); self.args.profile_sha256 = artifacts.digest(self.profile_path)
            with self.subTest(field=key), self.assertRaisesRegex(ValueError, 'EXACT_REAL'): self.build()
            self.assertFalse(self.args.output.exists()); self.runtime[key] = original

    def test_altered_applied_migration_or_new_unreviewed_migration_blocks_output(self):
        for change in ('modified', 'extra', 'missing'):
            candidate = copy.deepcopy(self.candidate_proof)
            if change == 'modified': candidate['migrations'][0]['sha256'] = 'c' * 64
            if change == 'extra': candidate['migrations'].append(dict(name='1794060000000-Unreviewed', sha256='c' * 64))
            if change == 'missing': candidate['migrations'].pop()
            with self.subTest(change=change), self.assertRaises((ValueError, m.core.Stop)):
                self.build(candidate=candidate)
            self.assertFalse(self.args.output.exists())

    def test_unsafe_worker_receipt_or_sealed_artifact_id_changes_are_rejected(self):
        self.profile['backend']['isolatedWorkerConfiguration'] = 'API_ONLY'
        self.profile_path.write_text(json.dumps(self.profile)); self.args.profile_sha256 = artifacts.digest(self.profile_path)
        (self.input / 'backend/manifest.json').write_text(json.dumps(self.profile['backend']))
        with self.assertRaisesRegex(ValueError, 'ACTUAL_RUNTIME'): self.build()
        self.profile['backendArtifactId'] = 999
        self.profile_path.write_text(json.dumps(self.profile)); self.args.profile_sha256 = artifacts.digest(self.profile_path)
        with self.assertRaisesRegex(ValueError, 'ARTIFACT_ID'): self.build()

    def test_receipt_is_reproducible_without_freshening_recovery_or_report_timestamps(self):
        first = self.build(); original = self.args.output.read_bytes(); self.args.output.unlink()
        second = self.build()
        self.assertEqual(first, second); self.assertEqual(original, self.args.output.read_bytes())

    def test_existing_output_is_never_overwritten(self):
        self.args.output.write_text('preserve previous result')
        with self.assertRaisesRegex(ValueError, 'NEW_COMPATIBILITY'): self.build()
        self.assertEqual(self.args.output.read_text(), 'preserve previous result')


class RuntimeDockerIdentity(unittest.TestCase):
    def test_containerd_manifest_receipt_is_accepted_only_via_exact_archive_graph(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stream, config, loaded = fixture(oci=True, tag='gallery-test:identity')
            archive = root / 'gallery-server-linux-amd64.tar.gz'; archive.write_bytes(stream.getvalue())
            manifest = dict(imageId=config, imageTag='gallery-test:identity', archiveSHA256=artifacts.digest(archive))
            result = m.runtime_image_binding(root, manifest, {'rollbackImageId': loaded})
            self.assertEqual(result, dict(configDigest=config, loadedImageId=loaded, identityKind='MANIFEST_DIGEST'))
            with self.assertRaises(artifacts.identity.IdentityError):
                m.runtime_image_binding(root, manifest, {'rollbackImageId': 'sha256:' + 'f' * 64})

    def test_missing_graph_and_archive_tampering_cannot_be_normalized(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stream, config, unused = fixture(tag='gallery-test:identity')
            archive = root / 'gallery-server-linux-amd64.tar.gz'; archive.write_bytes(stream.getvalue())
            manifest = dict(imageId=config, imageTag='gallery-test:identity', archiveSHA256=artifacts.digest(archive))
            with self.assertRaisesRegex(artifacts.identity.IdentityError, 'GRAPH_MISSING'):
                m.runtime_image_binding(root, manifest, {'rollbackImageId': 'sha256:' + 'f' * 64})
            archive.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'ARCHIVE_CHANGED'):
                m.runtime_image_binding(root, manifest, {'rollbackImageId': 'sha256:' + 'f' * 64})


if __name__ == '__main__':
    unittest.main()
