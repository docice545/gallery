"""Mocked artifact/ephemeral-lab contract tests; no Docker, keys or signing."""
import base64
from contextlib import redirect_stdout
import copy
from datetime import datetime, timezone
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import urllib.error


ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location('artifact_smoke_tests', ROOT / 'scripts/release/server_artifact_smoke.py')
smoke = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(smoke)
SOURCE = 'b' * 40
IMAGE = 'sha256:' + 'a' * 64
POSTGRES_IMAGE = 'sha256:' + 'c' * 64
OWNER = '11111111-2222-3333-4444-555555555555'
ASSET = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
DIGEST = 'd' * 64
LAB_ENV = {'GITHUB_ACTIONS': 'true', 'GALLERY_ISOLATED_CI': '1'}
KEYS = {'publicKey': '-----BEGIN PUBLIC KEY-----\nMOCK_LAB_PUBLIC\n-----END PUBLIC KEY-----\n',
        'privateKey': '-----BEGIN PRIVATE KEY-----\nMOCK_LAB_PRIVATE\n-----END PRIVATE KEY-----\n'}
NOW = datetime(2026, 10, 10, 12, 0, tzinfo=timezone.utc)


def root_identity():
    return {'path': '/data/upload/' + OWNER, 'device': '123', 'inode': '456', 'mountId': '42',
            'mountNamespace': 'mnt:[987654]', 'mountType': 'ext4', 'mountSource': '/dev/lab',
            'mountRoot': '/lab-volume', 'mountTarget': '/data'}


class SmokeFixture(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        lab = patch.dict(os.environ, LAB_ENV)
        lab.start()
        self.addCleanup(lab.stop)
        self.archive = self.directory / 'gallery-server-linux-amd64.tar.gz'
        self.archive.write_bytes(b'mocked archive bytes; no release artifact')
        self.manifest = {'sourceCommit': SOURCE, 'toolingCommit': 'e' * 40, 'serverVersion': '5.7.3',
                         'mobileVersion': '5.7.3', 'mobileBuild': 10,
                         'imageTag': 'gallery-server:trash-' + SOURCE[:12], 'imageId': IMAGE,
                         'archiveSHA256': hashlib.sha256(self.archive.read_bytes()).hexdigest()}
        self.save_manifest()
        self.image = {'Id': IMAGE, 'Architecture': 'amd64', 'Os': 'linux', 'Config': {'Env': [
            'IMMICH_SOURCE_COMMIT=' + SOURCE, 'IMMICH_SOURCE_REF=v5.7.3', 'IMMICH_REPOSITORY=docice545/gallery']}}
        self.version = {'major': 5, 'minor': 7, 'patch': 3, 'prerelease': None}

    def save_manifest(self):
        (self.directory / 'manifest.json').write_text(json.dumps(self.manifest))


class ArtifactIdentity(SmokeFixture):
    def test_committed_pubspec_selects_dynamic_semantic_version_and_build(self):
        with patch.object(smoke.subprocess, 'run', return_value=SimpleNamespace(
                returncode=0, stdout='name: fixture\nversion: 5.8.1+11\n')) as run:
            self.assertEqual(smoke.committed_version(SOURCE), ('5.8.1', 11))
        self.assertEqual(run.call_args.args[0],
                         ['git', '-C', str(ROOT), 'show', SOURCE + ':mobile/pubspec.yaml'])

    def test_mutable_source_and_bad_pubspec_stop_without_private_output(self):
        with patch.object(smoke.subprocess, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'FULL_COMMITTED_SOURCE_REQUIRED'):
                smoke.committed_version('HEAD')
            run.assert_not_called()
        for text in ('version: 5.7.3+0\n', 'version: 5.7.3+10\nversion: 5.7.2+9\n',
                     'version: 5.7.3-rc.1+10\n', 'version: 5.7.3+2100000001\n'):
            with self.subTest(pubspec=text), patch.object(smoke.subprocess, 'run', return_value=SimpleNamespace(
                    returncode=0, stdout=text)):
                with self.assertRaisesRegex(RuntimeError, 'COMMITTED_RELEASE_VERSION_INVALID'):
                    smoke.committed_version(SOURCE)

    def test_verified_manifest_image_and_tag_resolve_to_same_committed_identity(self):
        with patch.object(smoke, 'committed_version', return_value=('5.7.3', 10)), \
                patch.object(smoke, 'docker', return_value=json.dumps([self.image, self.image])) as docker:
            manifest, version = smoke.verify_artifact(self.directory, SOURCE)
        self.assertEqual(manifest, self.manifest)
        self.assertEqual(version, self.version)
        docker.assert_called_once_with('image', 'inspect', IMAGE, self.manifest['imageTag'])

    def test_source_version_and_build_mismatch_block_before_docker(self):
        for field, value in (('sourceCommit', 'f' * 40), ('serverVersion', '5.7.2'),
                             ('mobileVersion', '5.7.2'), ('mobileBuild', 9), ('mobileBuild', 10.0)):
            original = self.manifest[field]
            self.manifest[field] = value
            self.save_manifest()
            with self.subTest(field=field), patch.object(smoke, 'committed_version', return_value=('5.7.3', 10)), \
                    patch.object(smoke, 'docker') as docker:
                with self.assertRaisesRegex(RuntimeError, 'ARTIFACT_COMMITTED_VERSION_OR_SOURCE_MISMATCH'):
                    smoke.verify_artifact(self.directory, SOURCE)
                docker.assert_not_called()
            self.manifest[field] = original

    def test_archive_mismatch_blocks_before_docker(self):
        self.archive.write_bytes(b'changed mocked bytes')
        with patch.object(smoke, 'committed_version', return_value=('5.7.3', 10)), patch.object(smoke, 'docker') as docker:
            with self.assertRaisesRegex(RuntimeError, 'ARTIFACT_ARCHIVE_CHANGED'):
                smoke.verify_artifact(self.directory, SOURCE)
            docker.assert_not_called()

    def test_mutable_tag_wrong_image_platform_or_source_is_rejected(self):
        for field, value in (('Id', POSTGRES_IMAGE), ('Architecture', 'arm64'), ('Os', 'windows')):
            changed = copy.deepcopy(self.image)
            changed[field] = value
            with self.subTest(field=field), patch.object(smoke, 'committed_version', return_value=('5.7.3', 10)), \
                    patch.object(smoke, 'docker', return_value=json.dumps([self.image, changed])):
                with self.assertRaisesRegex(RuntimeError, 'LOCAL_ARTIFACT_IMAGE_OR_SOURCE_MISMATCH'):
                    smoke.verify_artifact(self.directory, SOURCE)
        changed = copy.deepcopy(self.image)
        changed['Config']['Env'][1] = 'IMMICH_SOURCE_REF=v5.7.2'
        with patch.object(smoke, 'committed_version', return_value=('5.7.3', 10)), \
                patch.object(smoke, 'docker', return_value=json.dumps([changed, self.image])):
            with self.assertRaisesRegex(RuntimeError, 'LOCAL_ARTIFACT_IMAGE_OR_SOURCE_MISMATCH'):
                smoke.verify_artifact(self.directory, SOURCE)

    def test_local_daemon_is_forced_and_remote_environment_is_removed(self):
        variables = {'DOCKER_HOST': 'ssh://production', 'DOCKER_CONTEXT': 'production',
                     'DOCKER_TLS_VERIFY': '1', 'DOCKER_CERT_PATH': '/private/keys'}
        with patch.dict(os.environ, variables), patch.object(smoke.subprocess, 'run', return_value=SimpleNamespace(
                returncode=0, stdout='fixture', stderr='')) as run:
            self.assertEqual(smoke.docker('inspect', 'fixture'), 'fixture')
        self.assertEqual(run.call_args.args[0], ['docker', '--host=unix:///var/run/docker.sock', 'inspect', 'fixture'])
        for name in variables:
            self.assertNotIn(name, run.call_args.kwargs['env'])


class SignedLabContract(SmokeFixture):
    def test_key_generation_and_evidence_are_refused_outside_explicit_lab(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(smoke.subprocess, 'run') as run:
            for function, args in ((smoke.lab_keys, ()), (smoke.lab_payload, (OWNER, [root_identity()], POSTGRES_IMAGE)),
                                   (smoke.publish_lab_evidence, (self.directory, KEYS, {}))):
                with self.subTest(function=function.__name__), self.assertRaisesRegex(
                        RuntimeError, 'EXPLICIT_DISPOSABLE_CI_LAB_REQUIRED'):
                    function(*args)
            run.assert_not_called()

    def test_ephemeral_key_generator_selects_ed25519_without_reading_a_key_file(self):
        with patch.object(smoke.subprocess, 'run', return_value=SimpleNamespace(
                returncode=0, stdout=json.dumps(KEYS))) as run:
            self.assertEqual(smoke.lab_keys(), KEYS)
        self.assertIn("generateKeyPairSync('ed25519')", run.call_args.args[0][-1])
        self.assertNotIn('readFile', run.call_args.args[0][-1])

    def test_store_mount_is_read_only_and_contains_only_public_trust_material(self):
        arguments = smoke.prepare_lab_store(self.directory, KEYS['publicKey'])
        self.assertIn(f'type=bind,source={self.directory},target={smoke.LAB_TRUST},readonly', arguments)
        self.assertIn('GALLERY_DELETION_RECOVERY_DIR=' + smoke.LAB_TRUST + '/evidence', arguments)
        self.assertEqual(self.directory.stat().st_mode & 0o777, 0o555)
        self.assertEqual((self.directory / 'evidence').stat().st_mode & 0o777, 0o555)
        self.assertEqual((self.directory / 'public.pem').stat().st_mode & 0o777, 0o444)
        self.assertEqual((self.directory / 'public.pem').read_text(), KEYS['publicKey'])
        self.assertEqual({path.name for path in self.directory.iterdir()}, {'evidence', 'public.pem',
                         'manifest.json', 'gallery-server-linux-amd64.tar.gz'})

    def test_signed_report_matches_strict_verifier_keys_and_preserves_actual_namespace(self):
        identity = root_identity()
        payload = smoke.lab_payload(OWNER, [identity], POSTGRES_IMAGE, now=NOW)
        self.assertEqual(set(payload), {'version', 'ownerId', 'scope', 'roots', 'verifiedAt', 'expiresAt', 'postgres', 'mounts'})
        self.assertEqual(payload['roots'], [identity])
        self.assertEqual(payload['roots'][0]['mountNamespace'], 'mnt:[987654]')
        self.assertEqual(payload['scope'], 'managed')
        self.assertEqual(payload['expiresAt'], '2026-10-10T13:00:00.000Z')
        self.assertEqual(payload['postgres']['postgresImage'], POSTGRES_IMAGE)
        self.assertIs(payload['postgres']['productionChanged'], False)
        self.assertEqual({item['kind'] for item in payload['mounts'][identity['path']]['samples']}, {'photo', 'video'})

    def test_root_coverage_namespace_and_disposable_storage_boundary_are_required(self):
        for changes in ({'path': '/opt/immich'}, {'mountNamespace': ''}, {'mountNamespace': 'host'}, {'inode': ''}):
            identity = {**root_identity(), **changes}
            with self.subTest(changes=changes), self.assertRaisesRegex(RuntimeError, 'ACTUAL_DISPOSABLE_LAB_ROOT_IDENTITIES_REQUIRED'):
                smoke.lab_payload(OWNER, [identity], POSTGRES_IMAGE)
        with self.assertRaisesRegex(RuntimeError, 'ACTUAL_DISPOSABLE_LAB_ROOT_IDENTITIES_REQUIRED'):
            smoke.lab_payload(OWNER, [root_identity(), root_identity()], POSTGRES_IMAGE)

    def test_publication_signs_exact_payload_and_marks_receipt_as_synthetic(self):
        smoke.prepare_lab_store(self.directory, KEYS['publicKey'])
        payload = smoke.lab_payload(OWNER, [root_identity()], POSTGRES_IMAGE, now=NOW)
        signature = base64.b64encode(b'x' * 64)
        with patch.object(smoke.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=signature)) as run:
            digest = smoke.publish_lab_evidence(self.directory, KEYS, payload)
        request = json.loads(run.call_args.kwargs['input'])
        self.assertEqual(request['key'], KEYS['privateKey'])
        self.assertEqual(json.loads(base64.b64decode(request['payload'])), payload)
        envelope_path = self.directory / 'evidence' / (digest + '.json')
        envelope = json.loads(envelope_path.read_bytes())
        self.assertEqual(set(envelope), {'version', 'algorithm', 'payload', 'signature'})
        self.assertEqual(envelope['algorithm'], 'Ed25519')
        self.assertEqual(json.loads(base64.b64decode(envelope['payload'])), payload)
        self.assertEqual(hashlib.sha256(envelope_path.read_bytes()).hexdigest(), digest)
        self.assertEqual(envelope_path.stat().st_mode & 0o777, 0o444)
        receipt = json.loads((self.directory / 'lab-only.json').read_text())
        self.assertTrue(receipt['testOnly'])
        self.assertEqual(receipt['marker'], smoke.LAB_MARKER)
        self.assertFalse(receipt['productionRecoveryVerified'])
        self.assertFalse(receipt['productionAuthorization'])
        for path in self.directory.rglob('*'):
            if path.is_file():
                self.assertNotIn('MOCK_LAB_PRIVATE', path.read_text())

    def test_invalid_signature_cannot_publish_evidence_or_authorize_fixture(self):
        smoke.prepare_lab_store(self.directory, KEYS['publicKey'])
        payload = smoke.lab_payload(OWNER, [root_identity()], POSTGRES_IMAGE)
        for result in (SimpleNamespace(returncode=1, stdout=b''), SimpleNamespace(returncode=0, stdout=b'bad-base64')):
            with self.subTest(result=result), patch.object(smoke.subprocess, 'run', return_value=result):
                with self.assertRaisesRegex(RuntimeError, 'DISPOSABLE_LAB_SIGNING_FAILED'):
                    smoke.publish_lab_evidence(self.directory, KEYS, payload)
        self.assertEqual(list((self.directory / 'evidence').iterdir()), [])

    def test_authorization_collects_compiled_container_roots_then_prepares_and_consents(self):
        request = Mock(side_effect=[None, {'enabled': False, 'prepared': True, 'canPrepare': True}, None,
                                    {'enabled': True, 'prepared': True, 'canPrepare': True}])
        with patch.object(smoke, 'docker', return_value=json.dumps([root_identity()])) as docker, \
                patch.object(smoke, 'publish_lab_evidence', return_value=DIGEST) as publish:
            self.assertEqual(smoke.authorize_lab_fixture(request, 'lab-server', OWNER, POSTGRES_IMAGE,
                                                        self.directory, KEYS), DIGEST)
        command = docker.call_args.args
        self.assertEqual(command[:3], ('exec', '-i', 'lab-server'))
        self.assertIn('await collectRootIdentities(roots)', command[-1])
        self.assertEqual(json.loads(docker.call_args.kwargs['input']), {'id': OWNER, 'storageLabel': None})
        self.assertEqual(publish.call_args.args[2]['roots'], [root_identity()])
        self.assertEqual([call.args for call in request.call_args_list], [
            ('/assets/managed-deletion-preparation', 'PUT', {'recoveryProof': DIGEST, 'verifiedExclusiveRoots': True}),
            ('/assets/managed-deletion-policy',),
            ('/assets/managed-deletion-consent', 'PUT', {'enabled': True, 'confirmed': True}),
            ('/assets/managed-deletion-policy',)])

    def test_failed_preparation_never_requests_owner_consent(self):
        request = Mock(side_effect=[None, {'enabled': False, 'prepared': False, 'canPrepare': True}])
        with patch.object(smoke, 'docker', return_value=json.dumps([root_identity()])), \
                patch.object(smoke, 'publish_lab_evidence', return_value=DIGEST):
            with self.assertRaisesRegex(RuntimeError, 'DISPOSABLE_MANAGED_PREPARATION_FAILED'):
                smoke.authorize_lab_fixture(request, 'lab-server', OWNER, POSTGRES_IMAGE, self.directory, KEYS)
        self.assertEqual(request.call_count, 2)


class SmokeLifecycle(SmokeFixture):
    def test_identity_failure_happens_before_keys_or_container_creation(self):
        output = io.StringIO()
        with patch('sys.argv', ['smoke', SOURCE, str(self.directory)]), \
                patch.object(smoke, 'verify_artifact', side_effect=RuntimeError('ARTIFACT_ARCHIVE_CHANGED')), \
                patch.object(smoke, 'lab_keys') as keys, patch.object(smoke, 'docker') as docker, redirect_stdout(output):
            self.assertEqual(smoke.main(), 1)
        keys.assert_not_called()
        docker.assert_not_called()
        self.assertIn('verify committed artifact identity', output.getvalue())

    def test_writable_lab_mount_stops_before_api_authorization_and_cleans_owned_fixtures(self):
        calls = []
        def docker(*args, **kwargs):
            calls.append(args)
            if args[:2] == ('network', 'create'):
                return 'owned-network'
            if args[0] == 'run':
                return 'owned-container'
            if args[0] == 'inspect':
                return json.dumps([{'Mounts': []}])
            return ''
        with patch('sys.argv', ['smoke', SOURCE, str(self.directory)]), \
                patch.object(smoke, 'verify_artifact', return_value=(self.manifest, self.version)), \
                patch.object(smoke, 'lab_keys', return_value=KEYS), patch.object(smoke, 'docker', side_effect=docker), \
                patch.object(smoke, 'authorize_lab_fixture') as authorize, redirect_stdout(io.StringIO()):
            self.assertEqual(smoke.main(), 1)
        authorize.assert_not_called()
        self.assertEqual(len([call for call in calls if call[0] == 'run']), 3)
        removals = [call for call in calls if call[0] == 'rm']
        self.assertEqual(len(removals), 3)
        self.assertTrue(all(call[:4] == ('rm', '-f', '-v', call[3]) and call[3].startswith('gallery-trash-ci-')
                            for call in removals))
        self.assertIn(('network', 'rm', 'owned-network'), calls)

    def test_full_mocked_lab_flow_uses_new_version_immutable_image_and_explicit_consent(self):
        calls, requests, state = [], [], {'trashed': False, 'deleted': False, 'prepared': False, 'enabled': False}
        media = smoke.synthetic_png()
        def docker(*args, **kwargs):
            calls.append(args)
            if args[:2] == ('network', 'create'):
                return 'owned-network'
            if args[0] == 'run':
                return 'owned-container'
            if args[0] == 'inspect':
                if args[1].endswith('-pg'):
                    return json.dumps([{'Image': POSTGRES_IMAGE}])
                server_run = next(call for call in calls if call[0] == 'run' and call[-1] == IMAGE)
                mounts = [server_run[i + 1] for i, value in enumerate(server_run[:-1]) if value == '--mount']
                self.assertIn('type=volume,destination=/external', mounts)
                mount = next(value for value in mounts if value.startswith('type=bind,'))
                trust = mount.split('source=', 1)[1].split(',', 1)[0]
                return json.dumps([{'Mounts': [{'Type': 'bind', 'Source': trust, 'Destination': smoke.LAB_TRUST, 'RW': False},
                                               {'Type': 'volume', 'Destination': '/external', 'RW': True}],
                                    'NetworkSettings': {'Ports': {'2283/tcp': [{'HostPort': '12345'}]}}}])
            if args[0] == 'exec':
                if args[-1] == smoke.NODE_LAB_ROOTS:
                    return json.dumps([root_identity()])
                return json.dumps({'errors': [], 'postgres': {'readOnly': 'on'}, 'runningVersion': '5.7.3'})
            return ''
        def response(request, timeout):
            self.assertTrue(request.full_url.startswith('http://127.0.0.1:12345/api/'))
            path = request.full_url.split('/api', 1)[1]
            method = request.get_method()
            requests.append((path, method))
            body = json.loads(request.data) if request.data and request.headers.get('Content-type') == 'application/json' else None
            result = None
            if path == '/server/ping': result = {'res': 'pong'}
            elif path == '/server/version': result = self.version
            elif path == '/auth/login': result = {'accessToken': 'MOCK_DISPOSABLE_TOKEN'}
            elif path == '/assets' and method == 'POST':
                if state['deleted']: raise urllib.error.HTTPError('unused', 410, 'fixture', {}, None)
                result = {'id': ASSET}
            elif path == '/assets' and method == 'DELETE': state['trashed'] = True
            elif path == '/assets/' + ASSET:
                result = {'isTrashed': state['trashed'], 'fileCreatedAt': '2024-05-06', 'localDateTime': '2024-05-06'}
            elif path == '/assets/' + ASSET + '/original':
                if state['deleted']: raise urllib.error.HTTPError('unused', 404, 'fixture', {}, None)
                return io.BytesIO(media)
            elif path == '/trash/restore/assets':
                if state['deleted']: raise urllib.error.HTTPError('unused', 404, 'fixture', {}, None)
                result = {'count': int(state['trashed'])}
                state['trashed'] = False
            elif path == '/assets/permanent-deletion':
                if state['enabled']:
                    state['deleted'] = True
                    result = [{'id': ASSET, 'scope': 'managed', 'state': 'complete'}]
                else: result = [{'id': ASSET, 'scope': 'managed', 'state': 'blocked', 'code': 'LIBRARY_DELETION_NOT_AUTHORIZED'}]
            elif path == '/users/me': result = {'id': OWNER}
            elif path == '/assets/managed-deletion-preparation':
                self.assertEqual(body, {'recoveryProof': DIGEST, 'verifiedExclusiveRoots': True})
                state['prepared'] = True
            elif path == '/assets/managed-deletion-consent':
                self.assertEqual(body, {'enabled': body['enabled'], 'confirmed': True})
                state['prepared'] = True
                state['enabled'] = body['enabled']
            elif path == '/assets/managed-deletion-policy':
                result = {'enabled': state['enabled'], 'prepared': state['prepared'], 'canPrepare': False}
            elif path == '/assets/' + ASSET + '/deletion-status': result = {'id': ASSET, 'state': 'complete'}
            elif path != '/auth/admin-sign-up': self.fail('Unexpected mocked route: ' + path)
            return io.BytesIO(json.dumps(result).encode() if result is not None else b'')
        opener = Mock()
        opener.open.side_effect = response
        output = io.StringIO()
        with patch('sys.argv', ['smoke', SOURCE, str(self.directory)]), \
                patch.object(smoke, 'verify_artifact', return_value=(self.manifest, self.version)), \
                patch.object(smoke, 'lab_keys', return_value=KEYS), patch.object(smoke, 'docker', side_effect=docker), \
                patch.object(smoke, 'publish_lab_evidence', return_value=DIGEST), \
                patch.object(smoke, 'thumbnail_smoke') as thumbnails, \
                patch.object(smoke, 'external_smoke', return_value={'syntheticMediaOnly': True}) as external, \
                patch.object(smoke.urllib.request, 'build_opener', return_value=opener) as build_opener, redirect_stdout(output):
            self.assertEqual(smoke.main(), 0, output.getvalue())
        server_run = next(call for call in calls if call[0] == 'run' and call[-1] == IMAGE)
        self.assertIn('IMMICH_MEDIA_LOCATION=/data', server_run)
        self.assertIn('IMMICH_WORKERS_INCLUDE=api,microservices', server_run)
        self.assertIn('IMMICH_WORKERS_EXCLUDE=', server_run)
        self.assertNotIn('IMMICH_WORKERS_EXCLUDE=microservices', server_run)
        self.assertNotIn(self.manifest['imageTag'], server_run)
        self.assertNotIn(('/assets/managed-deletion-preparation', 'PUT'), requests)
        self.assertIn(('/assets/managed-deletion-consent', 'PUT'), requests)
        self.assertNotIn(('/assets/deletion-policy', 'PUT'), requests)
        self.assertEqual(build_opener.call_args.args[0].proxies, {})
        no_redirect = build_opener.call_args.args[1]
        with self.assertRaisesRegex(RuntimeError, 'DISPOSABLE_API_REDIRECT_REJECTED'):
            no_redirect.redirect_request()
        completed = json.loads((self.directory / 'manifest.json').read_text())
        self.assertFalse(completed['isolatedRecoveryEvidence']['productionRecoveryVerified'])
        self.assertTrue(completed['isolatedRecoveryEvidence']['testOnly'])
        self.assertEqual(completed['isolatedWorkerConfiguration'], 'API_AND_MICROSERVICES')
        self.assertEqual(completed['thumbnailPreviewVerification'], 'PASS_SYNTHETIC_FILES_AND_HTTP')
        self.assertIn('ordinary owner consent', completed['isolatedSmoke'])
        thumbnails.assert_called_once()
        external.assert_called_once()
        self.assertEqual(len([call for call in calls if call[0] == 'rm']), 3)


class Build11OrdinaryStorage(SmokeFixture):
    def test_managed_owner_revoke_then_consent_never_submits_a_recovery_proof(self):
        media = smoke.synthetic_png()
        request = Mock(side_effect=[None,
            [{'id': ASSET, 'scope': 'managed', 'state': 'blocked', 'code': 'LIBRARY_DELETION_NOT_AUTHORIZED'}],
            media, None, {'enabled': True, 'prepared': True, 'canPrepare': False},
            [{'id': ASSET, 'scope': 'managed', 'state': 'complete'}], {'id': ASSET, 'state': 'complete'}])
        with patch.object(smoke, 'publish_lab_evidence') as publish:
            smoke.ordinary_managed_smoke(request, ASSET, media)
        publish.assert_not_called()
        calls = [call.args for call in request.call_args_list]
        self.assertEqual(calls[0], ('/assets/managed-deletion-consent', 'PUT', {'enabled': False, 'confirmed': True}))
        self.assertEqual(calls[3], ('/assets/managed-deletion-consent', 'PUT', {'enabled': True, 'confirmed': True}))
        self.assertFalse(any('preparation' in call[0] for call in calls))

    def test_external_physical_success_requires_default_denial_owner_consent_and_file_absence(self):
        scope = 'bbbbbbbb-1111-4444-8888-aaaaaaaaaaaa'
        media = smoke.synthetic_png(22)
        request = Mock(side_effect=[{'id': scope}, {'importPaths': [{'importPath': smoke.EXTERNAL_LAB_ROOT, 'isValid': True}]}, None, None, {'isTrashed': True}, media,
            [{'id': ASSET, 'scope': scope, 'state': 'blocked', 'code': 'LIBRARY_DELETION_NOT_AUTHORIZED'}], None,
            [{'id': ASSET, 'scope': scope, 'state': 'complete'}]])
        with patch.object(smoke, 'storage_fixture', side_effect=[{'root': smoke.EXTERNAL_LAB_ROOT}, [ASSET], True, [], []]) as storage:
            result = smoke.external_smoke(request, 'gallery-trash-ci-123456789abc-server', OWNER)
        self.assertTrue(result['ownerWritablePhysicalDeletion'])
        self.assertFalse(result['productionNFSVerified'])
        self.assertEqual([call.args[1] for call in storage.call_args_list],
                         ['writeExternal', 'externalIds', 'fileGone', 'externalIds', 'rescanGate'])
        self.assertIn(('/assets/library-deletion-consent/' + scope, 'PUT', {'enabled': True, 'confirmed': True}),
                      [call.args for call in request.call_args_list])

    def test_external_success_response_cannot_hide_a_file_still_present(self):
        scope = 'bbbbbbbb-1111-4444-8888-aaaaaaaaaaaa'
        request = Mock(side_effect=[{'id': scope}, {'importPaths': [{'importPath': smoke.EXTERNAL_LAB_ROOT, 'isValid': True}]}, None, None, {'isTrashed': True}, smoke.synthetic_png(22),
            [{'id': ASSET, 'scope': scope, 'state': 'blocked', 'code': 'LIBRARY_DELETION_NOT_AUTHORIZED'}], None,
            [{'id': ASSET, 'scope': scope, 'state': 'complete'}]])
        with patch.object(smoke, 'storage_fixture', side_effect=[{'root': smoke.EXTERNAL_LAB_ROOT}, [ASSET], False]), self.assertRaises(AssertionError):
            smoke.external_smoke(request, 'gallery-trash-ci-123456789abc-server', OWNER)

    def test_runtime_fixture_refuses_production_container_before_any_exec(self):
        with patch.object(smoke, 'docker') as docker, self.assertRaisesRegex(RuntimeError, 'OWNED_DISPOSABLE_SERVER_REQUIRED'):
            smoke.storage_fixture('immich_server', 'writeExternal')
        docker.assert_not_called()

    def test_external_fixture_uses_separate_volume_not_managed_upload_root(self):
        self.assertTrue(smoke.EXTERNAL_LAB_ROOT.startswith('/external/'))
        self.assertIn("const root='" + smoke.EXTERNAL_LAB_ROOT + "'", smoke.NODE_STORAGE_FIXTURE)
        self.assertNotIn("const root='/data/", smoke.NODE_STORAGE_FIXTURE)
        with patch.object(smoke, 'storage_fixture', return_value={'root': '/data/build11-external-ci'}), \
                self.assertRaisesRegex(RuntimeError, 'EXACT_DISPOSABLE_EXTERNAL_ROOT_REQUIRED'):
            smoke.external_smoke(Mock(), 'gallery-trash-ci-123456789abc-server', OWNER)

    def test_invalid_external_import_root_stops_before_scan_or_deletion(self):
        scope = 'bbbbbbbb-1111-4444-8888-aaaaaaaaaaaa'
        for response in ({'importPaths': []}, {'importPaths': [{'importPath': smoke.EXTERNAL_LAB_ROOT, 'isValid': False}]},
                         {'importPaths': [{'importPath': '/unexpected', 'isValid': True}]}):
            request = Mock(side_effect=[{'id': scope}, response])
            with self.subTest(response=response), patch.object(smoke, 'storage_fixture', return_value={'root': smoke.EXTERNAL_LAB_ROOT}), \
                    self.assertRaisesRegex(RuntimeError, 'SYNTHETIC_EXTERNAL_IMPORT_ROOT_INVALID'):
                smoke.external_smoke(request, 'gallery-trash-ci-123456789abc-server', OWNER)
            self.assertFalse(any('scan' in call.args[0] or 'permanent-deletion' in call.args[0] for call in request.call_args_list))

    def test_thumbnails_require_both_processed_file_types_and_http_reads(self):
        request = Mock(return_value=b'encoded preview')
        with patch.object(smoke, 'storage_fixture', return_value=['thumbnail', 'preview']):
            smoke.thumbnail_smoke(request, 'gallery-trash-ci-123456789abc-server', ASSET)
        self.assertEqual(request.call_count, 2)
        with patch.object(smoke, 'storage_fixture', return_value=['thumbnail']), \
                patch.object(smoke.time, 'monotonic', side_effect=[0, 121]), self.assertRaisesRegex(RuntimeError, 'NOT_PROCESSED'):
            smoke.thumbnail_smoke(request, 'gallery-trash-ci-123456789abc-server', ASSET)

    def test_png_is_valid_deterministic_and_unique_for_independent_lifecycles(self):
        image = smoke.synthetic_png(33)
        self.assertEqual(image, smoke.synthetic_png(33))
        self.assertNotEqual(image, smoke.synthetic_png(22))
        self.assertTrue(image.startswith(b'\x89PNG\r\n\x1a\n'))
        data = image[8:]
        while data:
            size = int.from_bytes(data[:4], 'big')
            kind, payload = data[4:8], data[8:8 + size]
            crc = int.from_bytes(data[8 + size:12 + size], 'big')
            self.assertEqual(smoke.zlib.crc32(kind + payload), crc)
            data = data[12 + size:]

    def test_modified_existing_rollback_archive_is_rejected_before_docker_load(self):
        manifest = {**self.manifest, 'sourceCommit': smoke.ROLLBACK_SOURCE,
                    'imageId': smoke.ROLLBACK_IMAGE, 'archiveSHA256': smoke.ROLLBACK_ARCHIVE_SHA}
        (self.directory / 'manifest.json').write_text(json.dumps(manifest))
        with patch.object(smoke, 'docker') as docker, self.assertRaisesRegex(RuntimeError, 'ROLLBACK_ARCHIVE_CHANGED'):
            smoke.load_rollback(self.directory)
        docker.assert_not_called()

    def test_rollback_is_not_available_outside_explicit_disposable_lab(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(smoke, 'docker') as docker, \
                self.assertRaisesRegex(RuntimeError, 'EXPLICIT_DISPOSABLE_CI_LAB_REQUIRED'):
            smoke.load_rollback(self.directory)
        docker.assert_not_called()

    def test_reviewed_rollback_overrides_require_all_three_immutable_pins(self):
        pins = {'GALLERY_SMOKE_ROLLBACK_SOURCE': 'e' * 40,
                'GALLERY_SMOKE_ROLLBACK_IMAGE': IMAGE,
                'GALLERY_SMOKE_ROLLBACK_ARCHIVE_SHA256': DIGEST}
        with patch.dict(os.environ, pins):
            self.assertEqual(smoke.rollback_identity(), ('e' * 40, IMAGE, DIGEST))
        for field, value in ((name, '') for name in pins):
            with self.subTest(field=field), patch.dict(os.environ, {**pins, field: value}), \
                    self.assertRaisesRegex(RuntimeError, 'COMPLETE_IMMUTABLE_REVIEWED_ROLLBACK_PINS_REQUIRED'):
                smoke.rollback_identity()
        for field, value in (('GALLERY_SMOKE_ROLLBACK_SOURCE', 'work'),
                             ('GALLERY_SMOKE_ROLLBACK_IMAGE', 'gallery-server:latest'),
                             ('GALLERY_SMOKE_ROLLBACK_ARCHIVE_SHA256', 'unverified')):
            with self.subTest(field=field), patch.dict(os.environ, {**pins, field: value}), \
                    self.assertRaisesRegex(RuntimeError, 'COMPLETE_IMMUTABLE_REVIEWED_ROLLBACK_PINS_REQUIRED'):
                smoke.rollback_identity()

    def test_compiled_migration_is_read_with_no_database_mount_network_or_workers(self):
        with patch.object(smoke, 'docker', return_value=json.dumps([DIGEST, DIGEST])) as docker:
            self.assertEqual(smoke.additive_migration_hash(IMAGE), DIGEST)
        command = docker.call_args.args
        self.assertIn('--read-only', command)
        self.assertIn('none', command)
        self.assertNotIn('--mount', command)
        self.assertNotIn('--volumes-from', command)
        self.assertNotIn('-p', command)
        self.assertIn('--entrypoint', command)
        self.assertIn('1794050000000-OwnerStorageDeletion.js', command[-1])

    def test_missing_or_different_compiled_migration_copies_are_rejected(self):
        for hashes in ([], [DIGEST], [DIGEST, 'e' * 64], ['not-a-hash', 'not-a-hash']):
            with self.subTest(hashes=hashes), patch.object(smoke, 'docker', return_value=json.dumps(hashes)), \
                    self.assertRaisesRegex(RuntimeError, 'EXACT_COMPILED_ADDITIVE_MIGRATION_REQUIRED'):
                smoke.additive_migration_hash(IMAGE)
        with patch.object(smoke, 'docker') as docker, \
                self.assertRaisesRegex(RuntimeError, 'IMMUTABLE_MIGRATION_IMAGE_REQUIRED'):
            smoke.additive_migration_hash('gallery:latest')
        docker.assert_not_called()

    def test_rollback_requires_byte_identical_candidate_additive_migration(self):
        with patch.object(smoke, 'additive_migration_hash', side_effect=[DIGEST, DIGEST]) as check:
            self.assertEqual(smoke.verify_rollback_migration(POSTGRES_IMAGE, IMAGE), DIGEST)
        self.assertEqual([call.args[0] for call in check.call_args_list], [POSTGRES_IMAGE, IMAGE])
        with patch.object(smoke, 'additive_migration_hash', side_effect=[DIGEST, 'e' * 64]), \
                self.assertRaisesRegex(RuntimeError, 'PINNED_ROLLBACK_ADDITIVE_MIGRATION_MISMATCH'):
            smoke.verify_rollback_migration(POSTGRES_IMAGE, IMAGE)


if __name__ == '__main__':
    unittest.main()
