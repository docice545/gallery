"""Build11 additive image review; disposable JSON only, no production access."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
import sys

sys.path.insert(0, str(Path(__file__).parent))
from test_image_release import OperatorFixture, FOREIGN, PREVIOUS_SOURCE

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('build11_image_test', ROOT / 'scripts/release/image_release.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)


class ReviewedRollback(unittest.TestCase):
    def setUp(self):
        self.old = {'capability': m.CAPABILITY, 'guardFiles': {'guard': 'a' * 64},
                    'migrations': [{'name': m.BOUND_MIGRATION, 'sha256': 'a' * 64}]}
        self.new = copy.deepcopy(self.old)
        self.new['capability'] = m.OWNER_STORAGE_CAPABILITY
        self.new['guardFiles']['guard'] = 'b' * 64
        self.new['migrations'].append({'name': '1794050000000-OwnerStorageDeletion', 'sha256': 'b' * 64})
        self.review = {'schemaVersion': 1, 'contract': 'build11-reviewed-additive-upgrade-v1',
                       'candidateProofSHA256': m.proof_digest(self.new), 'rollbackProofSHA256': m.proof_digest(self.old),
                       'migrationsAdded': self.new['migrations'][1:], 'testReportSHA256': 'c' * 64,
                       'rollbackTest': {'isolatedDatabase': True, 'oldRuntimeStartsOnUpgradedSchema': True,
                                        'storagePoliciesRejectedByRollback': True, 'trashRestoreAfterRollback': True,
                                        'syntheticMediaOnly': True, 'productionChanged': False}}

    def test_default_strict_guard_and_migration_checks_remain(self):
        with self.assertRaisesRegex(m.Stop, 'MIGRATIONS_MUST_MATCH'):
            m.rollback_compatibility(self.new, self.old)
        same_schema = copy.deepcopy(self.new); same_schema['migrations'] = self.old['migrations']
        with self.assertRaisesRegex(m.Stop, 'GUARD_FILES_MUST_MATCH'):
            m.rollback_compatibility(same_schema, self.old)

    def test_exact_reviewed_additive_mode_with_tested_rollback_is_accepted(self):
        m.rollback_compatibility(self.new, self.old, self.review)

    def test_separately_built_fallback_with_exact_forward_migration_is_allowed(self):
        old = copy.deepcopy(self.old); old['migrations'] = copy.deepcopy(self.new['migrations'])
        review = copy.deepcopy(self.review)
        review['rollbackProofSHA256'] = m.proof_digest(old)
        with self.assertRaisesRegex(m.Stop, 'FORWARD_MIGRATION_IN_ROLLBACK'):
            m.rollback_compatibility(self.new, old, review)
        review['rollbackContainsAdditiveMigration'] = True
        m.rollback_compatibility(self.new, old, review)

    def test_changed_probe_guard_migration_or_source_cannot_reuse_review(self):
        for field in ('guardFiles', 'migrations', 'capability'):
            changed = copy.deepcopy(self.new)
            if field == 'guardFiles': changed[field]['guard'] = 'd' * 64
            elif field == 'migrations': changed[field][0]['sha256'] = 'd' * 64
            else: changed[field] = m.CAPABILITY
            with self.subTest(field=field), self.assertRaisesRegex(m.Stop, 'PROOF_MISMATCH'):
                m.rollback_compatibility(changed, self.old, self.review)

    def test_review_cannot_authorize_modifying_or_removing_old_migration(self):
        for change in ('remove', 'modify'):
            new = copy.deepcopy(self.new)
            if change == 'remove': new['migrations'].pop(0)
            else: new['migrations'][0]['sha256'] = 'd' * 64
            review = copy.deepcopy(self.review); review['candidateProofSHA256'] = m.proof_digest(new)
            with self.subTest(change=change), self.assertRaisesRegex(m.Stop, 'MIGRATIONS_REMOVED_OR_CHANGED'):
                m.rollback_compatibility(new, self.old, review)

    def test_arbitrary_new_migration_not_allowed_even_in_pinned_review(self):
        new = copy.deepcopy(self.new); new['migrations'][1]['name'] = '1794000000000-Other'
        review = copy.deepcopy(self.review); review['candidateProofSHA256'] = m.proof_digest(new)
        review['migrationsAdded'] = new['migrations'][1:]
        with self.assertRaisesRegex(m.Stop, 'ONLY_REVIEWED_ADDITIVE'):
            m.rollback_compatibility(new, self.old, review)

    def test_every_real_rollback_test_gate_is_mandatory(self):
        for field, value in self.review['rollbackTest'].items():
            review = copy.deepcopy(self.review); review['rollbackTest'][field] = not value
            with self.subTest(field=field), self.assertRaisesRegex(m.Stop, 'ROLLBACK_TEST_REPORT'):
                m.rollback_compatibility(self.new, self.old, review)

    def test_exact_external_checksum_and_both_image_sources_required(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'public-review.json'
            review = {**self.review, 'candidateImage': 'sha256:' + 'a' * 64, 'candidateSource': 'a' * 40,
                      'rollbackImage': 'sha256:' + 'b' * 64, 'rollbackSource': 'b' * 40}
            path.write_text(json.dumps(review))
            args = SimpleNamespace(compatibility_receipt=path, compatibility_sha256=m.sha(path),
                                   image=review['candidateImage'], source_commit=review['candidateSource'],
                                   rollback_image=review['rollbackImage'], rollback_source_commit=review['rollbackSource'])
            self.assertEqual(m.reviewed_compatibility(args), review)
            args.image = 'sha256:' + 'c' * 64
            with self.assertRaisesRegex(m.Stop, 'IMAGE_SOURCE_MISMATCH'): m.reviewed_compatibility(args)
            args.image = review['candidateImage']; args.compatibility_sha256 = 'd' * 64
            with self.assertRaisesRegex(m.Stop, 'PINNED_REVIEWED'): m.reviewed_compatibility(args)


class RecordedHardenedRollback(OperatorFixture):
    def test_distinct_recorded_fallback_remains_verifiable_after_rollback(self):
        import test_image_release as fixture
        self.seed_plan(); self.receipt['rollbackImage'] = FOREIGN
        (self.state / 'image-plan.json').write_text(json.dumps(self.receipt))
        fixture.release.save(self.state / 'rollback-image-only.override.json',
                             {'services': {fixture.release.SERVICE: {'image': FOREIGN}}})
        fixture.release.save(self.state / 'rolled-back.json', {'image': FOREIGN, 'container': 'fallback-container'})
        current = self.container(FOREIGN, 'fallback-container', fixture.PREVIOUS_HASH, PREVIOUS_SOURCE)
        with self.runtime(current) as mocks:
            original_image = mocks['image'].side_effect
            fallback = copy.deepcopy(self.previous_image); fallback['Id'] = FOREIGN
            mocks['image'].side_effect = lambda selected: fallback if selected == FOREIGN else original_image(selected)
            self.assertEqual(fixture.release.prerequisites(self.state, rollback=True)[1]['Image'], FOREIGN)

    def test_unrecorded_or_replaced_fallback_still_rejected(self):
        import test_image_release as fixture
        self.seed_plan(); self.receipt['rollbackImage'] = FOREIGN
        (self.state / 'image-plan.json').write_text(json.dumps(self.receipt))
        current = self.container(FOREIGN, 'fallback-container', fixture.PREVIOUS_HASH, PREVIOUS_SOURCE)
        with self.runtime(current), self.assertRaisesRegex(fixture.release.Stop, 'LIVE_IMAGE_CHANGED_EXTERNALLY'):
            fixture.release.prerequisites(self.state, rollback=True)
        fixture.release.save(self.state / 'rolled-back.json', {'image': FOREIGN, 'container': 'different-container'})
        with self.runtime(current), self.assertRaisesRegex(fixture.release.Stop, 'RECORDED_ROLLBACK_CONTAINER_CHANGED'):
            fixture.release.prerequisites(self.state, rollback=True)


if __name__ == '__main__': unittest.main()
