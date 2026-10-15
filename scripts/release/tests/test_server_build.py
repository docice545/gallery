"""Committed-source build metadata checks; no Docker, signing or artifacts."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / 'scripts/release/server_build.sh'
SPEC = importlib.util.spec_from_file_location('server_build_candidate_tests', ROOT / 'scripts/release/release_candidate.py')
candidate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(candidate)
BASE_MIGRATION = '1710000000000-ExistingMigration'
AUTHORIZED_MIGRATION = '1793600000000-AddAuthorizedAssetDeletion'
RECOVERY_MIGRATION = '1793700000000-BindDeletionRecovery'
LEGACY_CHECKSUM_PATH = 'server/src/schema/migrations/1774548649115-AddChecksumAlgorithm.ts.ts'
LEGACY_CHECKSUM_SHA = '64f3e4c147deb4d57d92dbc5e556ef081110923f08953865bb0bba36312944af'


class CommittedBuildMetadata(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.output = self.root / 'must-not-create-artifacts'
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.docker_marker = self.root / 'docker-was-called'
        (self.bin / 'docker').write_text('#!/usr/bin/env bash\nprintf called > "$DOCKER_CALL_MARKER"\nexit 90\n')
        (self.bin / 'docker').chmod(0o700)
        self.git('init', '--quiet')
        self.git('remote', 'add', 'origin', 'https://github.com/docice545/gallery.git')
        self.write('mobile/pubspec.yaml', 'name: fixture\nversion: 5.7.1+7\n')
        self.write('server/src/repositories/asset.repository.ts', 'export class AssetRepository {}\n')
        self.write('server/src/schema/migrations/' + BASE_MIGRATION + '.ts', 'export const existing = true;\n')
        self.baseline = self.commit()

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], text=True, stderr=subprocess.PIPE).strip()

    def write(self, relative, content):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def commit(self):
        self.git('add', '--all')
        self.git('-c', 'user.name=Release test fixture', '-c', 'user.email=fixture@example.invalid',
                 'commit', '--quiet', '-m', 'Synthetic committed source')
        return self.git('rev-parse', 'HEAD')

    def next_release(self, version='5.7.3+10'):
        self.write('mobile/pubspec.yaml', 'name: fixture\nversion: ' + version + '\n')
        self.write('server/src/schema/migrations-gallery/' + AUTHORIZED_MIGRATION + '.ts',
                   'export const authorizedDeletionFixture = true;\n')
        self.write('server/src/schema/migrations-gallery/' + RECOVERY_MIGRATION + '.ts',
                   'export const boundRecoveryFixture = true;\n')
        return self.commit()

    def check(self, source, baseline=None, extra_env=None, option='--check'):
        env = os.environ.copy()
        env.update({'MIGRATION_BASE_SHA': baseline or self.baseline,
                    'PATH': str(self.bin) + os.pathsep + env['PATH'],
                    'DOCKER_CALL_MARKER': str(self.docker_marker)})
        env.update(extra_env or {})
        result = subprocess.run(['bash', str(SCRIPT), source, str(self.output), option], cwd=self.repo,
                                env=env, text=True, capture_output=True, timeout=30)
        self.assertFalse(self.docker_marker.exists(), 'metadata check invoked Docker')
        self.assertFalse(self.output.exists(), 'metadata check created artifact output')
        return result

    def test_new_committed_version_and_all_added_migrations_are_bound_to_exact_source(self):
        source = self.next_release()
        result = self.check(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        metadata = json.loads(result.stdout)
        self.assertEqual(metadata['sourceCommit'], source)
        self.assertEqual(metadata['migrationBase'], self.baseline)
        self.assertEqual((metadata['serverVersion'], metadata['mobileVersion'], metadata['mobileBuild']),
                         ('5.7.3', '5.7.3', 10))
        self.assertEqual(metadata['schemaDelta'], 'MIGRATION_FILES_ADDED')
        self.assertEqual(metadata['migrationsAdded'], [AUTHORIZED_MIGRATION, RECOVERY_MIGRATION])
        for migration in metadata['migrationFilesAdded']:
            contents = (self.repo / migration['path']).read_bytes()
            self.assertEqual(migration['sha256'], hashlib.sha256(contents).hexdigest())
            self.assertEqual(Path(migration['path']).stem, migration['name'])

    def test_version_override_environment_cannot_relabel_an_old_committed_release(self):
        source = self.next_release('5.7.2+9')
        result = self.check(source, extra_env={'FORK_VERSION': '5.7.3', 'BUILD_NUMBER': '10'})
        self.assertEqual(result.returncode, 0, result.stderr)
        metadata = json.loads(result.stdout)
        self.assertEqual((metadata['serverVersion'], metadata['mobileBuild']), ('5.7.2', 9))

    def test_no_migration_additions_are_reported_without_schema_claims(self):
        result = self.check(self.baseline)
        self.assertEqual(result.returncode, 0, result.stderr)
        metadata = json.loads(result.stdout)
        self.assertEqual(metadata['migrationsAdded'], [])
        self.assertEqual(metadata['migrationFilesAdded'], [])
        self.assertEqual(metadata['schemaDelta'], 'NONE_FROM_MIGRATION_BASE')
        self.assertFalse(metadata['livePhotoDynamicDeletionRoots'])

    def test_dynamic_root_requirement_is_derived_from_exact_committed_repository(self):
        self.write('server/src/repositories/asset.repository.ts', '''export class AssetRepository {
  async preparePermanentDeletion(snapshot) {
    const roots = await this.deletionRootsForTarget();
    return snapshot(path, roots);
  }
  async removeAuthorizedOriginals() {}
  private async deletionRootsForTarget() {}
}
''')
        source = self.commit()
        result = self.check(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout)['livePhotoDynamicDeletionRoots'])

    def test_partial_dynamic_root_source_is_rejected_without_docker(self):
        for helper, call, snapshot in (
                ('private async deletionRootsForTarget() {}', '', 'snapshot(path, roots)'),
                ('', 'this.deletionRootsForTarget()', 'snapshot(path, roots)'),
                ('private async deletionRootsForTarget() {}', 'this.deletionRootsForTarget()',
                 'snapshot(path, policy.rootIdentities)')):
            with self.subTest(helper=bool(helper), call=bool(call), snapshot=snapshot):
                self.write('server/src/repositories/asset.repository.ts', f'''export class AssetRepository {{
  async preparePermanentDeletion(snapshot) {{
    const roots = {call or '[]'};
    return {snapshot};
  }}
  async removeAuthorizedOriginals() {{}}
  {helper}
}}
''')
                source = self.commit()
                result = self.check(source)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('SOURCE_INCOMPLETE', result.stderr)

    def test_tooling_only_descendant_keeps_selected_application_source_metadata(self):
        source = self.next_release()
        self.write('scripts/release/tooling-fixture.txt', 'tooling-only change\n')
        tooling = self.commit()
        self.assertNotEqual(source, tooling)
        result = self.check(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['sourceCommit'], source)

    def test_older_source_with_different_application_inputs_is_rejected(self):
        self.next_release()
        result = self.check(self.baseline)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('application/build inputs differ from source', result.stdout + result.stderr)

    def test_uncommitted_pubspec_cannot_be_used_or_mislabeled_as_selected_source(self):
        source = self.next_release('5.7.2+9')
        self.write('mobile/pubspec.yaml', 'name: fixture\nversion: 5.7.3+10\n')
        result = self.check(source)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('checkout is not clean', result.stdout + result.stderr)

    def test_changed_existing_migration_is_rejected_without_docker(self):
        self.write('server/src/schema/migrations/' + BASE_MIGRATION + '.ts', 'export const changed = true;\n')
        source = self.commit()
        result = self.check(source)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('existing migration modified', result.stderr)

    def test_removed_existing_migration_is_rejected_without_docker(self):
        (self.repo / 'server/src/schema/migrations' / (BASE_MIGRATION + '.ts')).unlink()
        source = self.commit()
        result = self.check(source)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('existing migration removed', result.stderr)

    def test_both_upstream_and_gallery_migration_directories_are_inventoried(self):
        upstream_name = '1800000000000-UpstreamFixture'
        self.write('server/src/schema/migrations/' + upstream_name + '.ts', 'export const upstream = true;\n')
        source = self.next_release()
        result = self.check(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['migrationsAdded'],
                         [AUTHORIZED_MIGRATION, RECOVERY_MIGRATION, upstream_name])

    def test_pinned_upstream_double_extension_retains_existing_ledger_identity(self):
        contents = (ROOT / LEGACY_CHECKSUM_PATH).read_text()
        self.assertEqual(hashlib.sha256(contents.encode()).hexdigest(), LEGACY_CHECKSUM_SHA)
        self.write(LEGACY_CHECKSUM_PATH, contents)
        self.baseline = self.commit()
        source = self.next_release()
        result = self.check(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        # It is a pre-existing migration, not a new schema change or renamed ID.
        self.assertEqual(json.loads(result.stdout)['migrationsAdded'],
                         [AUTHORIZED_MIGRATION, RECOVERY_MIGRATION])

    def test_changed_upstream_double_extension_bytes_are_rejected(self):
        self.write(LEGACY_CHECKSUM_PATH, (ROOT / LEGACY_CHECKSUM_PATH).read_text())
        self.baseline = self.commit()
        self.write(LEGACY_CHECKSUM_PATH, 'export const changed = true;\n')
        source = self.commit()
        result = self.check(source)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('regular named migration source required', result.stderr)

    def test_arbitrary_double_extensions_are_not_accepted(self):
        for name in ('1774548649115-Other.ts.ts', '1800000000000-Other.ts.ts'):
            with self.subTest(name=name):
                self.write('server/src/schema/migrations/' + name, 'export const unexpected = true;\n')
                source = self.commit()
                result = self.check(source)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('regular named migration source required', result.stderr)

    def test_symlinked_migration_source_is_rejected(self):
        path = self.repo / 'server/src/schema/migrations-gallery' / (RECOVERY_MIGRATION + '.ts')
        path.parent.mkdir(parents=True)
        path.symlink_to('../migrations/' + BASE_MIGRATION + '.ts')
        source = self.commit()
        result = self.check(source)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('regular named migration source required', result.stderr)

    def test_duplicate_migration_name_with_different_bytes_is_rejected(self):
        self.write('server/src/schema/migrations-gallery/' + BASE_MIGRATION + '.ts', 'export const conflicting = true;\n')
        source = self.commit()
        result = self.check(source)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('conflicting duplicate migration source', result.stderr)

    def test_new_metadata_cannot_be_accepted_as_frozen_build_nine_profile(self):
        source = self.next_release()
        result = self.check(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        metadata = json.loads(result.stdout)
        frozen_profile = {'schemaVersion': 2, 'productionBase': candidate.BASE, 'sourceCommit': source,
                          'serverVersion': metadata['serverVersion'], 'mobileVersion': metadata['mobileVersion'],
                          'mobileBuild': metadata['mobileBuild']}
        with self.assertRaisesRegex(ValueError, 'CANDIDATE_VERSION'):
            candidate.validate(frozen_profile)

    def test_invalid_committed_release_version_refused(self):
        for version in ('5.7.3+0', '5.7.3+-1', '5.7.3-rc.1+10', '5.7.03+10', '5.7.3+2100000001'):
            with self.subTest(version=version):
                self.write('mobile/pubspec.yaml', 'name: fixture\nversion: ' + version + '\n')
                source = self.commit()
                result = self.check(source)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('committed mobile', result.stderr)

    def test_duplicate_committed_pubspec_version_is_refused(self):
        self.write('mobile/pubspec.yaml', 'name: fixture\nversion: 5.7.3+10\nversion: 5.7.2+9\n')
        source = self.commit()
        result = self.check(source)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('one committed mobile release version required', result.stderr)

    def test_malformed_source_baseline_and_unknown_cli_option_are_refused(self):
        for source, baseline, option, code in (
                ('HEAD', self.baseline, '--check', 'full lowercase SHA required'),
                (self.baseline, 'HEAD', '--check', 'full migration baseline SHA required'),
                (self.baseline, self.baseline, '--build-something', 'Usage:')):
            with self.subTest(source=source, baseline=baseline, option=option):
                result = self.check(source, baseline=baseline, option=option)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(code, result.stdout + result.stderr)

    def test_schema_baseline_must_be_ancestor_of_selected_source(self):
        newer = self.next_release()
        result = self.check(self.baseline, baseline=newer)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('migration baseline is not an ancestor of source', result.stdout + result.stderr)

    def test_build_commands_consume_source_metadata_and_compile_added_migrations(self):
        script = SCRIPT.read_text()
        for old in ('FORK_VERSION=5.7.2', 'BUILD_NUMBER=9', 'BUILD_VERSION=5.7.2',
                    'BUILD_SOURCE_REF=v5.7.2', "serverVersion='5.7.2'", 'mobileBuild=9',
                    "migrationsAdded=['1793600000000-AddAuthorizedAssetDeletion']"):
            self.assertNotIn(old, script)
        self.assertIn('FORK_VERSION="$release_version" BUILD_NUMBER="$release_build"', script)
        self.assertIn('"BUILD_VERSION=$release_version"', script)
        self.assertIn('"BUILD_SOURCE_REF=v$release_version"', script)
        self.assertIn('JSON.parse(metadata).migrationFilesAdded', script)
        self.assertIn('if(!fs.existsSync(compiled)) process.exit(1)', script)
        subprocess.run(['bash', '-n', str(SCRIPT)], check=True, capture_output=True)


class PackagedLivePhotoAdmission(unittest.TestCase):
    """Execute the actual embedded packaged check with synthetic ESM, no Docker."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.write('server/package.json', json.dumps({'type': 'module', 'version': '5.7.3'}))
        self.write('server/dist/main.js', '')
        match = re.search(r'docker run[^\n]+ -e \'([\s\S]*?)\' "\$release_version" "\$source_metadata"',
                          SCRIPT.read_text())
        self.assertIsNotNone(match, 'packaged verification script missing')
        self.check_code = match.group(1)
        self.repository = '''export class AssetRepository {
  async preparePermanentDeletion(snapshot) {
    const roots = await this.deletionRootsForTarget();
    return snapshot(path, roots);
  }
  async deletionRootsForTarget() { throw new Error("must not invoke filesystem admission"); }
}
'''
        self.service = '''export class AssetService {
  async permanentlyDelete(path, roots) { return this.storageRepository.snapshotOriginal(path, roots); }
  async handleAssetDeletion(path, roots) { return this.storageRepository.snapshotOriginal(path, roots); }
}
'''

    def write(self, path, content):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)

    def check(self, repository=None, service=None, expected=True):
        self.write('server/dist/repositories/asset.repository.js', repository or self.repository)
        self.write('server/dist/services/asset.service.js', service or self.service)
        metadata = {'migrationFilesAdded': [], 'livePhotoDynamicDeletionRoots': expected}
        env = os.environ.copy()
        # A correctly labelled image can still contain the wrong compiled code.
        env['IMMICH_SOURCE_COMMIT'] = '4e554f355755382990e12586b339d262d679bbf1'
        return subprocess.run(['node', '-e', self.check_code, '5.7.3', json.dumps(metadata)], cwd=self.root,
                              env=env, text=True, capture_output=True, timeout=30)

    def test_current_compiled_classes_pass_without_invoking_methods(self):
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('PASS packaged Live Photo dynamic roots and API/worker forwarding', result.stdout)

    def test_old_compiled_prepare_fails_even_with_correct_source_environment(self):
        old = '''export class AssetRepository {
  async preparePermanentDeletion(snapshot) { return snapshot(path, policy.rootIdentities); }
}
'''
        result = self.check(repository=old)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('PACKAGED_LIVEPHOTO_ROOT_ADMISSION_MISMATCH', result.stderr)

    def test_helper_presence_alone_cannot_hide_policy_only_snapshot(self):
        result = self.check(repository=self.repository.replace('snapshot(path, roots)',
                                                              'snapshot(path, policy.rootIdentities)'))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('PACKAGED_LIVEPHOTO_ROOT_ADMISSION_MISMATCH', result.stderr)

    def test_each_api_and_worker_callback_must_forward_dynamic_roots(self):
        for method in ('permanentlyDelete', 'handleAssetDeletion'):
            with self.subTest(method=method):
                broken = self.service.replace(
                    f'async {method}(path, roots) {{ return this.storageRepository.snapshotOriginal(path, roots); }}',
                    f'async {method}(path, roots) {{ return this.storageRepository.snapshotOriginal(path, []); }}')
                result = self.check(service=broken)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('PACKAGED_LIVEPHOTO_ROOT_ADMISSION_MISMATCH', result.stderr)

    def test_reviewed_source_without_feature_does_not_require_new_runtime_methods(self):
        result = self.check(repository='export class AssetRepository {}', service='export class AssetService {}',
                            expected=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('PASS packaged Live Photo dynamic roots', result.stdout)


if __name__ == '__main__':
    unittest.main()
