"""No signing/self-hosted runner or registry writes during source review; retain E2E."""
import unittest
from test_dedup_source_scope import allows


class ReleaseReviewScopeTests(unittest.TestCase):
    def test_release_reviews_cannot_start_mutating_artifact_workflows(self):
        for branch in ('codex/foto-build17-client-compat', 'codex/foto-build17-release'):
            for workflow, job in (
                ('docker.yml', 'pre-job'),
                ('build-mobile.yml', 'build-sign-android'),
                ('build-mobile.yml', 'build-sign-ios'),
                ('gallery-build-mobile.yml', 'build-sign-android'),
                ('gallery-build-mobile.yml', 'build-sign-ios'),
            ):
                with self.subTest(branch=branch, workflow=workflow, job=job):
                    self.assertFalse(allows(workflow, job, branch))
                    self.assertTrue(allows(workflow, job, '', 'workflow_dispatch'))

    def test_normal_e2e_checks_remain_enabled_for_compatibility_and_release(self):
        for branch in ('codex/foto-build17-client-compat', 'codex/foto-build17-release'):
            for job in ('e2e-tests-server-cli', 'e2e-tests-web'):
                with self.subTest(branch=branch, job=job):
                    self.assertTrue(allows('test.yml', job, branch))
