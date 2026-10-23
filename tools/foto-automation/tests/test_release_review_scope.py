"""No signing/self-hosted runner or registry writes during source review; retain E2E."""
import unittest
from pathlib import Path
from test_dedup_source_scope import allows


class ReleaseReviewScopeTests(unittest.TestCase):
    def test_release_reviews_cannot_start_mutating_artifact_workflows(self):
        for branch in ('codex/foto-build17-client-compat', 'codex/foto-build17-release',
                       'codex/foto-build17-release-reviewed-overlap'):
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
        for branch in ('codex/foto-build17-client-compat', 'codex/foto-build17-release',
                       'codex/foto-build17-release-reviewed-overlap'):
            for job in ('e2e-tests-server-cli', 'e2e-tests-web'):
                with self.subTest(branch=branch, job=job):
                    self.assertTrue(allows('test.yml', job, branch))

    def test_tools_followup_uses_path_gates_instead_of_forcing_unchanged_suites(self):
        root = Path(__file__).resolve().parents[3]
        text = (root / '.github/workflows/test.yml').read_text()
        force = next(line for line in text.splitlines() if 'force-filters:' in line)
        self.assertIn("github.head_ref != 'codex/foto-build17-release-reviewed-overlap'", force)
        # Relevant source changes still select the ordinary jobs; no branch skip
        # was added to those jobs (covered by allows() with all path gates true).
        for path in ('server/**', 'mobile/**', 'e2e/**', 'open-api/**'):
            self.assertIn(path, text)

    def test_combined_validation_is_serial_and_never_builds_or_signs_apk(self):
        root = Path(__file__).resolve().parents[3]
        text = (root / '.github/workflows/foto-build17-release.yml').read_text().split('  combined-mobile:', 1)[1]
        for required in ('needs: fixtures', "MISE_JOBS: '1'", '--concurrency=1', 'flutter analyze --no-pub',
                         '09e791c093d10927c434c85787328ebabcace5bd'):
            self.assertIn(required, text)
        for forbidden in ('flutter build', 'apksigner sign', 'docker ', 'secrets.'):
            self.assertNotIn(forbidden, text)
