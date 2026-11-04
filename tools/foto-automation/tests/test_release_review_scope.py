"""No signing/self-hosted runner or registry writes during source review; retain E2E."""
import unittest
import re
from pathlib import Path
import yaml
from test_dedup_source_scope import allows

ROOT = Path(__file__).resolve().parents[3]


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

    def test_all_pr_branches_are_denied_signing_and_registry_jobs(self):
        for branch in ('normal-feature', 'main', 'codex/issue18-cross-platform-audit', 'codex/foto-build37-android-ui'):
            for workflow, job in (
                ('docker.yml', 'pre-job'),
                ('build-mobile.yml', 'build-sign-android'),
                ('gallery-build-mobile.yml', 'build-sign-android'),
            ):
                with self.subTest(branch=branch, workflow=workflow, job=job):
                    self.assertFalse(allows(workflow, job, branch))

    def test_unsigned_compile_is_independent_but_cannot_disable_required_test_gates(self):
        source = (ROOT / '.github/workflows/build-mobile.yml').read_text()
        blocks = dict(re.findall(r'^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\Z)', source, re.M | re.S))
        job = blocks['build-unsigned-android']
        self.assertTrue(allows('build-mobile.yml', 'build-unsigned-android', 'normal-feature'))
        self.assertFalse(allows('build-mobile.yml', 'build-unsigned-android', '', 'push'))
        parsed = yaml.safe_load(source)['jobs']
        self.assertEqual(parsed['build-unsigned-android']['needs'], 'pre-job')
        for name in ('flutter-tests', 'release-tooling-checks', 'live-photo-timeline', 'live-photo-native'):
            self.assertIn(name, parsed)
            self.assertFalse(parsed[name].get('continue-on-error', False))
        self.assertNotIn('continue-on-error:', job)
        self.assertIn('runs-on: ubuntu-24.04', job)
        self.assertIn('contents: read', job)
        self.assertNotIn('secrets.', job)
        self.assertNotIn('environment:', job)
        self.assertNotIn('signingConfig', job)
        self.assertIn('verify_unsigned_android.py', job)
        self.assertIn('--expected-commit "$GITHUB_SHA"', job)
        self.assertIn('test ! -e android/key.jks', job)
        self.assertIn('test ! -e android/key.properties', job)
        self.assertIn('--target-platform android-arm,android-arm64,android-x64', job)
        self.assertIn('build_number: ${{ steps.source.outputs.build }}', job)
        self.assertNotIn('date +%s', job)

    def test_pr_docker_compiles_without_registry_credentials_or_push(self):
        source = (ROOT / '.github/workflows/pr-docker.yml').read_text()
        self.assertIn('  pull_request:', source)
        self.assertIn('contents: read', source)
        self.assertIn('push: false', source)
        self.assertIn('load: true', source)
        self.assertIn('context: machine-learning', source)
        for forbidden in ('secrets.', 'packages: write', 'docker/login-action', 'cache-to:', 'push: true', '--push'):
            self.assertNotIn(forbidden, source)

    def test_existing_build_only_ios_retains_ipa_without_signed_step(self):
        source = (ROOT / '.github/workflows/build-mobile.yml').read_text()
        step = source.split('      - name: Upload unsigned IPA for user-side signing\n', 1)[1].split('\n      - name:', 1)[0]
        self.assertIn('if: inputs.ios_release != true', step)
        self.assertIn('path: mobile/build/ios/ipa/Photos-unsigned.ipa', step)
        self.assertIn('if-no-files-found: error', step)
        job = yaml.safe_load(source)['jobs']['build-sign-ios']
        branding = next(step for step in job['steps'] if step.get('uses') == './.github/actions/apply-branding')
        self.assertEqual(branding['with']['version'], '${{ steps.ios-source-meta.outputs.version }}')
        self.assertEqual(branding['with']['build_number'], '${{ steps.ios-source-meta.outputs.build }}')

    def test_audit_source_can_collect_all_release_evidence_without_merge(self):
        for workflow in ('build-mobile.yml', 'test.yml', 'static_analysis.yml'):
            source = yaml.safe_load((ROOT / '.github/workflows' / workflow).read_text())
            self.assertIn('codex/issue18-cross-platform-audit', source[True]['push']['branches'])
            action = source['jobs']['pre-job']['steps'][0]['with']
            self.assertIn('push', action['force-events'].split(','))
        source = (ROOT / '.github/workflows/build-mobile.yml').read_text()
        self.assertIn('python3 -m unittest discover -s scripts/release/tests -v', source)

    def test_live_photo_gate_cannot_be_skipped_by_path_filters_or_artifact_jobs(self):
        source = (ROOT / '.github/workflows/build-mobile.yml').read_text()
        blocks = dict(re.findall(r'^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\Z)', source, re.M | re.S))
        gate = blocks['live-photo-timeline']
        self.assertIn('name: Live Photo timeline non-regression', gate)
        self.assertNotRegex(gate, r'(?m)^    (if|needs):')
        self.assertNotIn('continue-on-error:', gate)
        self.assertIn('set -o pipefail', gate)
        self.assertIn('bash mobile/scripts/live_photo_regressions.sh', gate)
        for job in ('build-sign-android', 'build-sign-ios'):
            needs = yaml.safe_load(source)['jobs'][job]['needs']
            self.assertIn('live-photo-timeline', needs)
            self.assertIn('live-photo-native', needs)
        native = blocks['live-photo-native']
        for job_name in ('live-photo-timeline', 'live-photo-native'):
            checkout = yaml.safe_load(source)['jobs'][job_name]['steps'][0]
            self.assertEqual(checkout['with']['ref'], '${{ inputs.ref || github.sha }}')
        self.assertIn('script: bash scripts/android_native_motion_test.sh', native)
        self.assertIn('disable-animations: false', native)
        self.assertNotIn('continue-on-error:', native)
        suite = (ROOT / 'mobile/scripts/live_photo_regressions.sh').read_text()
        for name in ('live_photo_scope_test.dart', 'live_photo_autoplay_test.dart',
                     'live_photo_presentation_test.dart', 'thumbnail_live_photo_test.dart',
                     'timeline_preview_video_viewer_test.dart'):
            self.assertIn(name, suite)
        self.assertNotIn('--exclude-tags', suite)

    def test_store_signing_requires_exact_source_gate_before_credentials(self):
        for workflow in ('build-mobile.yml', 'gallery-build-mobile.yml'):
            source = (ROOT / '.github/workflows' / workflow).read_text()
            blocks = dict(re.findall(r'^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\Z)', source, re.M | re.S))
            for job, credential_step in (('build-sign-android', 'Create the Keystore'), ('build-sign-ios', 'Create API Key')):
                with self.subTest(workflow=workflow, job=job):
                    block = blocks[job]
                    self.assertLess(block.index('require_live_photo_ci.py'), block.index(credential_step))
                    self.assertIn('actions: read', block)
        self.assertFalse(allows('gallery-build-mobile.yml', 'build-sign-android', '', 'push'))
