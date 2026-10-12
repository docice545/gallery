"""Pinned rollback preparation tests; synthetic archives, no production access."""
from contextlib import ExitStack, redirect_stdout, redirect_stderr
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[3]


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts/release' / (name + '.py'))
    item = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(item)
    return item


hp, core, identity = (module(name) for name in ('hp_build10_rollback', 'image_release', 'trash_image_identity'))


def image_fixture(oci=False, source=hp.ROLLBACK_SOURCE, corrupt_layer=False):
    raw = b'synthetic disposable layer bytes'
    digest = 'sha256:' + hashlib.sha256(raw).hexdigest()
    config = json.dumps({'architecture': 'amd64', 'os': 'linux',
                         'config': {'Env': ['IMMICH_SOURCE_COMMIT=' + source, 'IMMICH_SOURCE_REF=v5.7.3',
                                            'IMMICH_REPOSITORY=docice545/gallery']},
                         'rootfs': {'type': 'layers', 'diff_ids': [digest]}}).encode()
    config_id = 'sha256:' + hashlib.sha256(config).hexdigest()
    config_name, layer_name = config_id[7:] + '.json', 'layer/layer.tar'
    loaded_id = config_id
    blobs = {config_name: config, layer_name: b'tampered' if corrupt_layer else raw}
    tag = 'gallery-server:trash-' + hp.ROLLBACK_SOURCE[:12]
    if oci:
        doc = json.dumps({'schemaVersion': 2, 'config': {'digest': config_id, 'size': len(config)},
                          'layers': [{'digest': digest, 'size': len(raw)}]}, separators=(',', ':')).encode()
        loaded_id = 'sha256:' + hashlib.sha256(doc).hexdigest()
        blobs['blobs/sha256/' + loaded_id[7:]] = doc
        blobs['index.json'] = json.dumps({'schemaVersion': 2, 'manifests': [
            {'digest': loaded_id, 'size': len(doc)}]}).encode()
    blobs['manifest.json'] = json.dumps([{'Config': config_name, 'Layers': [layer_name], 'RepoTags': [tag]}]).encode()
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode='w') as tar:
        for name, data in blobs.items():
            entry = tarfile.TarInfo(name)
            entry.size = len(data)
            tar.addfile(entry, io.BytesIO(data))
    return gzip.compress(stream.getvalue(), mtime=0), config_id, loaded_id, [digest]


class Fixture(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='gallery-rollback-fixture-')
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.zip = self.root / 'rollback.zip'
        self.out = self.root / 'artifact'
        self.out.mkdir(mode=0o700)
        self.archive, self.config, self.loaded, self.layers = image_fixture()
        self.manifest = {'sourceCommit': hp.ROLLBACK_SOURCE, 'serverVersion': '5.7.3', 'mobileVersion': '5.7.3',
                         'mobileBuild': 10, 'platform': 'linux/amd64',
                         'imageTag': 'gallery-server:trash-' + hp.ROLLBACK_SOURCE[:12], 'imageId': self.loaded,
                         'archiveSHA256': hashlib.sha256(self.archive).hexdigest(),
                         'isolatedSmoke': 'PASS: disposable lab migrations + HTTP Trash/Restore/consent/permanent deletion',
                         'isolatedWorkerConfiguration': 'API_AND_MICROSERVICES'}
        self.write_zip()
        pinned = patch.multiple(hp, CI_ARTIFACT=123, ZIP_SHA256=hp.sha(self.zip), CI_IMAGE=self.loaded,
                                ARCHIVE_SHA256=self.manifest['archiveSHA256'])
        pinned.start()
        self.addCleanup(pinned.stop)

    def write_zip(self, extras=()):
        with zipfile.ZipFile(self.zip, 'w') as archive:
            archive.writestr('manifest.json', json.dumps(self.manifest))
            archive.writestr('image-inspect.json', json.dumps([{'Id': self.manifest['imageId'],
                                                               'Architecture': 'amd64', 'Os': 'linux'}]))
            archive.writestr('SHA256SUMS', self.manifest['archiveSHA256'] + '  gallery-server-linux-amd64.tar.gz\n')
            archive.writestr('gallery-server-linux-amd64.tar.gz', self.archive)
            for name, value in extras:
                archive.writestr(name, value)
        self.zip.chmod(0o600)

    def extract(self):
        hp.extract_zip(self.zip, self.out)
        return hp.artifact(self.out)

    def changed_json(self, file, mutate):
        row = json.loads(file.read_text())
        mutate(row)
        file.write_text(json.dumps(row))


class ArchiveTests(Fixture):
    def test_exact_ci_zip_and_manifest_pass_with_private_extraction(self):
        manifest, archive = self.extract()
        self.assertEqual(manifest, self.manifest)
        self.assertEqual(archive.read_bytes(), self.archive)
        self.assertEqual({path.name for path in self.out.iterdir()}, set(hp.FILES))
        for path in self.out.iterdir():
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def test_changed_zip_is_rejected_before_extraction(self):
        self.zip.write_bytes(self.zip.read_bytes() + b'altered')
        with self.assertRaisesRegex(hp.Stop, 'PINNED_ROLLBACK_ZIP_MISMATCH'):
            hp.extract_zip(self.zip, self.out)
        self.assertEqual(list(self.out.iterdir()), [])

    def test_unpinned_ci_artifact_is_not_operator_authorization(self):
        with patch.object(hp, 'CI_ARTIFACT', None), self.assertRaisesRegex(hp.Stop, 'COMPLETED_PINNED_CI_ARTIFACT_REQUIRED'):
            hp.extract_zip(self.zip, self.out)

    def test_insecure_zip_and_leaf_symlink_are_rejected(self):
        self.zip.chmod(0o644)
        with self.assertRaises(hp.Stop):
            hp.extract_zip(self.zip, self.out)
        self.zip.chmod(0o600)
        link = self.root / 'link.zip'
        link.symlink_to(self.zip)
        with self.assertRaises(hp.Stop):
            hp.extract_zip(link, self.out)

    def test_traversal_and_special_members_are_rejected(self):
        for name in ('../outside', '/outside'):
            with self.subTest(name=name):
                self.write_zip([(name, 'unsafe')])
                with patch.object(hp, 'ZIP_SHA256', hp.sha(self.zip)), self.assertRaisesRegex(hp.Stop, 'ZIP_UNSAFE_PATH'):
                    hp.extract_zip(self.zip, self.out)
        for mode in (stat.S_IFLNK, stat.S_IFIFO, stat.S_IFCHR):
            entry = zipfile.ZipInfo('unsafe')
            entry.external_attr = (mode | 0o600) << 16
            with self.subTest(mode=mode):
                self.write_zip([(entry, 'unsafe')])
                with patch.object(hp, 'ZIP_SHA256', hp.sha(self.zip)), self.assertRaisesRegex(hp.Stop, 'ZIP_UNSAFE_PATH'):
                    hp.extract_zip(self.zip, self.out)

    def test_duplicate_members_are_rejected(self):
        import warnings
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            self.write_zip([('manifest.json', '{}')])
        with patch.object(hp, 'ZIP_SHA256', hp.sha(self.zip)), self.assertRaisesRegex(hp.Stop, 'ZIP_DUPLICATE'):
            hp.extract_zip(self.zip, self.out)

    def test_wrong_manifest_source_build_platform_or_missing_smoke_is_rejected(self):
        self.extract()
        for field, value in (('sourceCommit', hp.SOURCE), ('mobileBuild', 9), ('platform', 'linux/arm64'),
                             ('isolatedSmoke', 'NOT_TESTED'), ('isolatedWorkerConfiguration', 'API_ONLY')):
            with self.subTest(field=field):
                (self.out / 'manifest.json').write_text(json.dumps({**self.manifest, field: value}))
                with self.assertRaises(hp.Stop):
                    hp.artifact(self.out)

    def test_archive_or_sums_tampering_is_rejected(self):
        self.extract()
        archive = self.out / 'gallery-server-linux-amd64.tar.gz'
        archive.write_bytes(self.archive + b'tampered')
        with self.assertRaisesRegex(hp.Stop, 'ROLLBACK_ARCHIVE_OR_CHECKSUM_MISMATCH'):
            hp.artifact(self.out)
        archive.write_bytes(self.archive)
        (self.out / 'SHA256SUMS').write_text('fake\n')
        with self.assertRaisesRegex(hp.Stop, 'ROLLBACK_ARCHIVE_OR_CHECKSUM_MISMATCH'):
            hp.artifact(self.out)

    def test_classic_and_containerd_archive_provenance_are_bound_to_actual_bytes(self):
        manifest, archive = self.extract()
        for oci in (False, True):
            with self.subTest(oci=oci):
                data, config, loaded, layers = image_fixture(oci=oci)
                archive.write_bytes(data)
                self.manifest['imageId'] = loaded
                found, proof = hp.archive_proof(identity, archive, self.manifest)
                self.assertEqual(found, config)
                self.assertEqual(proof['layerDiffIds'], layers)
                self.assertEqual(proof['identityKind'], 'MANIFEST_DIGEST' if oci else 'CONFIG_DIGEST')

    def test_fabricated_source_and_changed_layer_never_prove_rollback(self):
        _, archive = self.extract()
        for kwargs in ({'source': hp.SOURCE}, {'source': ''}, {'corrupt_layer': True}):
            data, _, loaded, _ = image_fixture(**kwargs)
            archive.write_bytes(data)
            with self.subTest(kwargs=kwargs), self.assertRaises((hp.Stop, identity.IdentityError)):
                hp.archive_proof(identity, archive, {**self.manifest, 'imageId': loaded})


class PrepareTests(Fixture):
    def setUp(self):
        super().setUp()
        self.runroot = self.root / 'gallery-build10-release-existing'
        self.runroot.mkdir(mode=0o700)
        # Preserve the already failed old plan exactly.
        self.oldstate = self.runroot / 'state'
        self.oldstate.mkdir(mode=0o700)
        self.oldreceipt = self.oldstate / 'image-plan.json'
        self.oldreceipt.write_bytes(b'old failed plan, must not be overwritten')
        self.compose = self.root / 'compose.json'
        self.compose.write_bytes(b'private synthetic compose input')
        self.args = SimpleNamespace(run_root=self.runroot, artifact_zip=self.zip, api='http://127.0.0.1:2283/api')
        self.old = {'Image': hp.CURRENT, 'Config': {'Env': ['IMMICH_SOURCE_COMMIT=']},
                    'State': {'Health': {'Status': 'healthy'}}}
        self.loaded_proof = {'loadedImageId': self.loaded, 'sourceCommit': hp.ROLLBACK_SOURCE,
                             'archiveSHA256': self.manifest['archiveSHA256']}

    def plan(self, args):
        self.assertEqual((args.image, args.expected_current_image, args.source_commit),
                         (hp.TARGET, hp.CURRENT, hp.SOURCE))
        self.assertEqual((args.rollback_image, args.rollback_source_commit, args.rollback_server_version),
                         (self.loaded, hp.ROLLBACK_SOURCE, hp.VERSION))
        core.save(args.state / 'image-plan.json', {
            'candidateImage': args.image, 'previousImage': args.expected_current_image,
            'sourceCommit': args.source_commit, 'rollbackSource': args.rollback_source_commit,
            'rollbackImage': args.rollback_image, 'migrationsAdded': [],
            'serverVersion': {'major': 5, 'minor': 7, 'patch': 3, 'prerelease': None},
            'rollbackVersion': {'major': 5, 'minor': 7, 'patch': 3, 'prerelease': None},
            'configHashMode': core.CONFIG_HASH_MODE, 'fileHashes': {str(self.compose): hp.sha(self.compose)}})

    def patched(self):
        stack = ExitStack()
        stack.enter_context(patch.object(core, 'inspect', return_value=self.old))
        stack.enter_context(patch.object(core, 'identity', return_value={'com.docker.compose.config-hash': 'resolved'}))
        stack.enter_context(patch.object(core, 'probe_image'))
        stack.enter_context(patch.object(core, 'compose_base', return_value=(['synthetic'], [])))
        stack.enter_context(patch.object(core, 'config_hash', return_value='resolved'))
        self.docker = stack.enter_context(patch.object(core, 'docker', return_value=''))
        self.run = stack.enter_context(patch.object(core, 'run'))
        self.planner = stack.enter_context(patch.object(core, 'plan', side_effect=self.plan))
        self.execute = stack.enter_context(patch.object(core, 'execute'))
        stack.enter_context(patch.object(hp, 'load_module', return_value=identity))
        self.verify = stack.enter_context(patch.object(identity, 'verify_loaded', return_value=self.loaded_proof))
        stack.enter_context(redirect_stdout(io.StringIO()))
        return stack

    def prepare(self):
        with self.patched():
            hp.prepare(self.args, core)

    def test_empty_old_source_is_not_guessed_and_new_plan_is_separate(self):
        self.prepare()
        self.assertEqual(self.oldreceipt.read_bytes(), b'old failed plan, must not be overwritten')
        phase = self.runroot / 'hardened-rollback'
        backup = phase / 'compose-input-backups/input-0.backup'
        self.assertEqual(backup.read_bytes(), self.compose.read_bytes())
        self.assertEqual(stat.S_IMODE(backup.stat().st_mode), 0o600)
        self.execute.assert_called_once()
        self.assertFalse(self.execute.call_args.args[0].execute_approved)
        self.assertFalse(self.execute.call_args.kwargs['rollback'])
        self.assertEqual(self.run.call_args.args[0][len(core.DOCKER):3+len(core.DOCKER)], ['image', 'load', '-i'])
        self.assertNotIn('up', self.run.call_args.args[0])
        self.assertEqual(hp.binding(self.runroot, core), phase / 'image-state')

    def test_full_guard_or_migration_check_failure_never_executes_update(self):
        for code in ('HARDENED_ROLLBACK_GUARD_FILES_MUST_MATCH', 'HARDENED_ROLLBACK_MIGRATIONS_MUST_MATCH'):
            with self.subTest(code=code), self.patched():
                self.planner.side_effect = core.Stop(code)
                with self.assertRaisesRegex(core.Stop, code):
                    hp.prepare(self.args, core)
                self.execute.assert_not_called()
            # Separate fixture phase for the next simulated independent failure.
            if (self.runroot / 'hardened-rollback').exists():
                (self.runroot / 'hardened-rollback').rename(self.runroot / code)

    def test_changed_live_image_stops_before_zip_or_load(self):
        self.old['Image'] = hp.TARGET
        with self.patched(), self.assertRaisesRegex(hp.Stop, 'EXPECTED_HEALTHY_PRODUCTION_IMAGE_REQUIRED'):
            hp.prepare(self.args, core)
        self.run.assert_not_called()
        self.assertFalse((self.runroot / 'hardened-rollback').exists())

    def test_existing_artifact_alias_is_never_overwritten_if_foreign(self):
        with self.patched():
            self.docker.side_effect = [self.loaded, json.dumps([{'RootFS': {'Layers': ['foreign']}, 'Config': {'Env': []}}])]
            with self.assertRaisesRegex(hp.Stop, 'EXISTING_ALIAS_NOT_OUR_ROLLBACK'):
                hp.prepare(self.args, core)
            self.run.assert_not_called()
            self.planner.assert_not_called()

    def test_pending_migrations_stop_before_approval_or_dry_run(self):
        with self.patched():
            def pending(args):
                self.plan(args)
                path = args.state / 'image-plan.json'
                self.changed_json(path, lambda row: row.update(migrationsAdded=['unreviewed']))
            self.planner.side_effect = pending
            with self.assertRaisesRegex(hp.Stop, 'MIGRATIONS_REQUIRE_SEPARATE'):
                hp.prepare(self.args, core)
            self.execute.assert_not_called()

    def test_failed_existing_phase_is_retained_never_automatically_reused(self):
        phase = self.runroot / 'hardened-rollback'
        phase.mkdir(mode=0o700)
        marker = phase / 'failure.txt'
        marker.write_bytes(b'preserve failure')
        with self.patched(), self.assertRaisesRegex(hp.Stop, 'KEEP_EXISTING_PHASE'):
            hp.prepare(self.args, core)
        self.assertEqual(marker.read_bytes(), b'preserve failure')
        self.run.assert_not_called()

    def test_tampered_plan_or_artifact_receipt_is_rejected(self):
        self.prepare()
        path = self.runroot / 'hardened-rollback/image-state/image-plan.json'
        original = path.read_bytes()
        for field, value in (('rollbackSource', hp.SOURCE), ('candidateImage', self.loaded),
                             ('migrationsAdded', ['unreviewed']), ('configHashMode', 'legacy')):
            path.write_bytes(original)
            self.changed_json(path, lambda row: row.update({field: value}))
            with self.subTest(field=field), self.assertRaisesRegex(hp.Stop, 'PINNED_ROLLBACK_PLAN'):
                hp.binding(self.runroot, core)

    def test_main_preserves_explicit_approval_and_only_local_docker_selector(self):
        self.prepare()
        actor = SimpleNamespace(pw_name='doctoriceadm', pw_dir=str(self.root))
        variables = {'DOCKER_HOST': 'ssh://not-allowed', 'DOCKER_CONTEXT': 'foreign', 'DOCKER_TLS_VERIFY': '1'}
        with patch('sys.argv', ['hp', 'apply', '--run-root', str(self.runroot)]), \
                patch.object(hp.pwd, 'getpwuid', return_value=actor), patch.object(hp, 'load_module', return_value=core), \
                patch.object(core, 'execute') as execute, patch.dict(os.environ, variables), redirect_stdout(io.StringIO()):
            self.assertEqual(hp.main(), 0)
            self.assertFalse(execute.call_args.args[0].execute_approved)
            self.assertTrue(all(name not in os.environ for name in variables))
            self.assertEqual(core.DOCKER, ['docker', '--host=unix:///var/run/docker.sock'])

    def test_cli_rejects_wrong_operator_without_any_docker_calls(self):
        with patch('sys.argv', ['hp', 'check', '--run-root', str(self.runroot)]), \
                patch.object(hp, 'load_module') as load, redirect_stderr(io.StringIO()):
            self.assertEqual(hp.main(), 1)
        load.assert_not_called()


if __name__ == '__main__':
    unittest.main()
