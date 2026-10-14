"""Lab boundary/unit contracts; these tests do NOT claim an installation passed."""
from contextlib import redirect_stdout
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build11_installation_smoke as lab
import gallery_install as installer

CI = {'GITHUB_ACTIONS': 'true', 'GALLERY_ISOLATED_CI': '1'}
UUID = '11111111-2222-3333-4444-555555555555'


def queue():
    return {'paused': True, 'ids': list(lab.JOB_IDS), 'active': [],
            'hashes': [{'id': value, 'hash': 'a' * 64} for value in lab.JOB_IDS],
            'originals': ['b' * 64] * 6}


class ReadOnlyPackagedImports(unittest.TestCase):
    """Actual Python imports of checksum-sealed synthetic binary packages."""
    def setUp(self):
        # Reuse the complete package fixture; payloads are tiny synthetic bytes,
        # and no Docker, API, signing or application build is performed.
        from test_build11_package import Assembly
        fixture = Assembly('test_complete_package_can_be_checked_and_all_tool_entrypoints_import_without_source_checkout')
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        with redirect_stdout(io.StringIO()):
            from build11_package import assemble
            assemble(fixture.args)
        self.package = fixture.args.output
        self.assertIsInstance(lab.verify_package(self.package), dict)

    def package_bytes(self):
        return {path.relative_to(self.package).as_posix(): path.read_bytes()
                for path in self.package.rglob('*') if path.is_file()}

    def test_original_dynamic_import_writes_unsealed_bytecode_and_verifier_rejects_it(self):
        with patch.object(sys, 'dont_write_bytecode', False):
            lab.load_packaged_tools(self.package)
        self.assertTrue(list((self.package / 'tools/__pycache__').glob('image_release*.pyc')))
        with self.assertRaisesRegex(ValueError, 'ALL_EXECUTABLE_TOOLS_AND_ARTIFACTS_MUST_BE_CHECKSUMMED'):
            lab.verify_package(self.package)

    def test_entire_lab_covers_direct_and_deferred_imports_without_mutating_package(self):
        helper = self.package / 'tools/build11_test_deferred_helper.py'
        helper.write_text('VALUE = "synthetic deferred import"\n')
        # The fixture helper is sealed before validation, never ignored later.
        with (self.package / 'SHA256SUMS').open('a') as manifest:
            manifest.write(lab.digest(helper) + '  tools/' + helper.name + '\n')
        lab.verify_package(self.package)
        before = self.package_bytes()

        def actual_imports(package, output):
            self.assertTrue(sys.dont_write_bytecode)
            engine = lab.load_packaged_tools(package)
            self.assertEqual(engine.SERVICE, 'immich-server')
            # A later import runs after the engine has loaded, just like the
            # recovery hooks. The whole lab must remain read-only throughout.
            module = importlib.import_module('build11_test_deferred_helper')
            self.assertEqual(module.VALUE, 'synthetic deferred import')
            return 0

        with patch.object(sys, 'dont_write_bytecode', False), \
                patch.object(sys, 'path', [str(self.package / 'tools'), *sys.path]), \
                patch.dict(sys.modules), patch.object(lab, 'run_lab', side_effect=actual_imports):
            self.assertEqual(lab.run(self.package, self.package.parent / 'report.json'), 0)
            self.assertFalse(sys.dont_write_bytecode)
        self.assertEqual(self.package_bytes(), before)
        self.assertFalse(list(self.package.rglob('*.pyc')))
        lab.verify_package(self.package)

    def test_failure_restores_interpreter_flag_and_preserves_sealed_bytes(self):
        before = self.package_bytes()
        def interrupted(package, output):
            lab.load_packaged_tools(package)
            raise RuntimeError('SYNTHETIC_IMPORT_INTERRUPTION')
        with patch.object(sys, 'dont_write_bytecode', False), \
                patch.object(lab, 'run_lab', side_effect=interrupted):
            with self.assertRaisesRegex(RuntimeError, 'SYNTHETIC_IMPORT_INTERRUPTION'):
                lab.run(self.package, self.package.parent / 'report.json')
            self.assertFalse(sys.dont_write_bytecode)
        self.assertEqual(self.package_bytes(), before)
        lab.verify_package(self.package)

    def test_existing_no_bytecode_policy_is_preserved(self):
        with patch.object(sys, 'dont_write_bytecode', True), \
                patch.object(lab, 'run_lab', return_value=0):
            self.assertEqual(lab.run(self.package, self.package.parent / 'report.json'), 0)
            self.assertTrue(sys.dont_write_bytecode)

    def test_finalization_accepts_unchanged_package_after_actual_tool_import(self):
        import build11_distribution_finalize as finalizer
        config = lab.verify_package(self.package)
        with patch.object(lab, 'run_lab', side_effect=lambda package, output: lab.load_packaged_tools(package)):
            lab.run(self.package, self.package.parent / 'unused.json')
        # Unit-contract report only. Real Docker acceptance is supplied by CI;
        # these synthetic payloads cannot be shipped as a release artifact.
        report = self.package.parent / 'synthetic-unit-report.json'
        report.write_text(json.dumps({'schemaVersion': 1, 'marker': finalizer.MARKER, 'result': 'PASS',
            'sourceCommit': config['sourceCommit'], 'packageSHA256': lab.digest(self.package / 'SHA256SUMS'),
            'cleanupErrors': [], 'syntheticMediaOnly': True, 'productionChanged': False,
            **{gate: False for gate in finalizer.GATES}, 'checks': {check: True for check in finalizer.CHECKS},
            'installationEngine': 'PACKAGED_GALLERY_INSTALL',
            'upgradeEngine': 'PACKAGED_IMAGE_RELEASE_WITH_REAL_READ_ONLY_LAB_QUEUE_GATE',
            'hpWrapper': 'NOT_TESTED_HP_RECOVERY_AND_OLD_SIX_REQUIRED'}))
        upstream = self.package.parent / 'synthetic-upstream-report.json'
        upstream.write_text(json.dumps({'status': 'PASS', 'upstreamURL': 'https://github.com/open-noodle/gallery',
            'upstreamBase': finalizer.UPSTREAM, 'api': {'status': 'PASS'}, 'migrations': {'status': 'PASS'},
            'workingTreeDirty': False, 'candidateHead': config['sourceCommit']}))
        notes = self.package.parent / 'synthetic-release-notes.md'
        notes.write_text('Synthetic fixture, not real installation acceptance.\n')
        args = SimpleNamespace(package=self.package, installation_report=report,
                               upstream_report=upstream, release_notes=notes)
        with patch.dict(os.environ, CI), redirect_stdout(io.StringIO()):
            finalizer.finalize(args)
        self.assertFalse(list(self.package.rglob('*.pyc')))
        sealed = lab.verify_package(self.package)
        self.assertEqual(sealed['installationValidation']['status'],
                         'ACTUAL_ISOLATED_PASS_HP_AND_DEVICES_NOT_TESTED')
        self.assertEqual(sealed['physicalAcceptance'], 'NOT_TESTED')
        self.assertEqual(sealed['productionDeployment'], 'NOT_EXECUTED')

    def test_existing_unsealed_files_are_never_removed_or_tolerated(self):
        extra = self.package / 'tools/unsealed.py'
        extra.write_text('raise RuntimeError("must never run")\n')
        with patch.object(lab, 'run_lab', side_effect=lambda package, output: lab.verify_package(package)):
            with self.assertRaisesRegex(ValueError, 'ALL_EXECUTABLE_TOOLS_AND_ARTIFACTS_MUST_BE_CHECKSUMMED'):
                lab.run(self.package, self.package.parent / 'report.json')
        self.assertEqual(extra.read_text(), 'raise RuntimeError("must never run")\n')


class Boundary(unittest.TestCase):
    def test_absent_explicit_ci_guards_do_not_call_docker(self):
        for env in ({}, {'GITHUB_ACTIONS': 'true'}, {'GALLERY_ISOLATED_CI': '1'}):
            with self.subTest(env=env), patch.dict(os.environ, env, clear=True), patch.object(lab, 'docker') as docker:
                with self.assertRaisesRegex(lab.LabFailure, 'EXPLICIT_ISOLATED'):
                    lab.fail_if_existing_installation()
                docker.assert_not_called()

    def test_remote_context_and_tls_options_are_removed_only_from_child_environment(self):
        env = {**CI, 'DOCKER_HOST': 'tcp://production.invalid', 'DOCKER_CONTEXT': 'hp',
               'DOCKER_TLS': '1', 'DOCKER_TLS_VERIFY': '1', 'DOCKER_CERT_PATH': '/private', 'OTHER': 'preserved'}
        with patch.dict(os.environ, env, clear=True):
            result = lab.ci_environment()
            self.assertEqual(result['OTHER'], 'preserved')
            self.assertFalse(any(key.startswith('DOCKER_') for key in result))
            self.assertEqual(os.environ['DOCKER_CONTEXT'], 'hp')

    def test_any_existing_container_volume_or_network_rejects_without_mutation(self):
        for responses, code in ((['foreign'], 'EMPTY_DISPOSABLE'),
                                (['', 'immich_model-cache'], 'VOLUMES_NEVER'),
                                (['', '', 'network-id'], 'NETWORK_NEVER')):
            with self.subTest(code=code), patch.dict(os.environ, CI), \
                    patch.object(lab, 'docker', side_effect=responses) as docker:
                with self.assertRaisesRegex(lab.LabFailure, code):
                    lab.fail_if_existing_installation()
                self.assertTrue(all(call.args[0] in ('ps', 'volume', 'network') for call in docker.call_args_list))

    def test_empty_disposable_daemon_is_required_before_real_commands(self):
        with patch.dict(os.environ, CI), patch.object(lab, 'docker', side_effect=['', '', '']) as docker:
            lab.fail_if_existing_installation()
        self.assertEqual(docker.call_count, 3)

    def test_no_release_report_overwrite_even_before_package_inspection(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(lab, 'verify_package') as verify:
            path = Path(directory) / 'existing.json'
            path.write_text('preserve exact receipt')
            with self.assertRaisesRegex(lab.LabFailure, 'NEW_INSTALLATION_LAB_REPORT'):
                lab.run(Path(directory), path)
            self.assertEqual(path.read_text(), 'preserve exact receipt')
            verify.assert_not_called()

    def test_command_error_never_prints_captured_credentials(self):
        completed = subprocess.CompletedProcess([], 1, 'private-token', 'private-password')
        with patch.dict(os.environ, CI), patch.object(lab.subprocess, 'run', return_value=completed):
            with self.assertRaisesRegex(lab.LabFailure, '^LAB_COMMAND_FAILED_PRIVATE_OUTPUT_OMITTED$'):
                lab.command(['docker', 'bad'])


class SanitizedDiagnostics(unittest.TestCase):
    def test_allowlisted_operation_omits_compose_paths_images_and_arguments(self):
        cases = [(['sudo', '-n', 'docker', '--host='+lab.SOCKET, 'image', 'inspect', '--platform', 'linux/amd64', 'private-image'],
                  'DOCKER_IMAGE_INSPECT_PLATFORM'),
                 (['docker', '--host='+lab.SOCKET, 'compose', '--project-directory', '/private-user', '-p', 'immich',
                   '-f', '/private-configuration', 'config', '--hash', '*'], 'DOCKER_COMPOSE_CONFIG'),
                 (['docker', '--host='+lab.SOCKET, 'compose', '-f', '/private-config', 'up', '-d'], 'DOCKER_COMPOSE_START'),
                 (['docker', '--host='+lab.SOCKET, 'exec', 'private-container', 'private-command'], 'DOCKER_CONTAINER_EXEC'),
                 (['private-api-token'], 'OTHER_COMMAND')]
        for args, expected in cases:
            with self.subTest(expected=expected):self.assertEqual(lab.docker_operation(args), expected)

    def test_stderr_is_only_classified_never_returned_or_printed(self):
        cases = [('--platform requires API version 1.49 private-token', 'DOCKER_API_VERSION_UNSUPPORTED'),
                 ('unknown flag: --platform /private-name', 'DOCKER_PLATFORM_FLAG_UNSUPPORTED'),
                 ('no matching manifest for linux/arm64 secret-token', 'DOCKER_REQUESTED_PLATFORM_UNAVAILABLE'),
                 ('image with reference private was found but does not provide the specified platform (linux/amd64)',
                  'DOCKER_REQUESTED_PLATFORM_UNAVAILABLE'),
                 ('content digest sha256:'+'a'*64+': not found /private/blob', 'DOCKER_IMAGE_CONTENT_UNAVAILABLE'),
                 ('no such image private-path', 'DOCKER_IMAGE_UNAVAILABLE'),
                 ('sudo: a password is required SECRET_PASSWORD', 'SUDO_NONINTERACTIVE_AUTHORIZATION_REQUIRED'),
                 ('Cannot connect to the Docker daemon /private-socket', 'DOCKER_LOCAL_DAEMON_UNAVAILABLE'),
                 ('validating /private-compose: Additional property private is not allowed', 'COMPOSE_CONFIGURATION_INVALID'),
                 ('permission denied /personal/photo.jpg', 'PERMISSION_DENIED'),
                 ('arbitrary stderr SECRET_PASSWORD /personal/photo.jpg', 'PRIVATE_ERROR_OMITTED')]
        for stderr, expected in cases:
            with self.subTest(expected=expected):self.assertEqual(lab.error_category(stderr), expected)

    def test_failing_docker_operation_exposes_only_fixed_metadata(self):
        args=['docker', '--host='+lab.SOCKET, 'image', 'inspect', '--platform', 'linux/amd64', '/private-image']
        completed=subprocess.CompletedProcess(args, 17, 'SECRET_TOKEN', 'requires API version 1.49 SECRET_PASSWORD /private-name')
        with patch.dict(os.environ, CI), patch.object(lab.subprocess,'run',return_value=completed):
            with self.assertRaises(lab.LabFailure) as caught:lab.command(args)
        self.assertEqual(caught.exception.diagnostic, {'operation':'DOCKER_IMAGE_INSPECT_PLATFORM', 'returnCode':17,
                                                     'errorCategory':'DOCKER_API_VERSION_UNSUPPORTED'})
        self.assertNotIn('SECRET',str(caught.exception));self.assertNotIn('private',json.dumps(caught.exception.diagnostic))

    def test_child_metadata_and_actual_installer_code_are_preserved_without_private_fields(self):
        diagnostic={'operation':'DOCKER_IMAGE_INSPECT_PLATFORM','returnCode':1,
                    'errorCategory':'DOCKER_API_VERSION_UNSUPPORTED','clientApiVersion':'1.50',
                    'serverApiVersion':'1.48','installerFailureLine':73,'privatePath':'/family/private','stderr':'SECRET'}
        stdout='INSTALL_COMMAND_DIAGNOSTIC '+json.dumps(diagnostic)+'\nFAIL_ACTUAL_PACKAGED_INSTALLER: COMMAND_FAILED_PRIVATE_OUTPUT_OMITTED\n'
        with patch.dict(os.environ,CI),patch.object(lab.subprocess,'run',return_value=subprocess.CompletedProcess([],1,stdout,'SECRET')):
            with self.assertRaises(lab.LabFailure) as caught:lab.command(['python3','private-installer'])
        self.assertEqual(str(caught.exception),'PACKAGED_INSTALLER_COMMAND_FAILED_PRIVATE_OUTPUT_OMITTED')
        self.assertEqual(caught.exception.diagnostic['serverApiVersion'],'1.48')
        self.assertNotIn('private',json.dumps(caught.exception.diagnostic));self.assertNotIn('SECRET',json.dumps(caught.exception.diagnostic))

    def test_untrusted_public_report_cannot_publish_paths_tokens_or_non_numeric_versions(self):
        row={'result':'FAIL','failure':'PRIVATE_SECRET_TOKEN','failedStage':'/private/family-name',
             'failureLine':'SECRET','stderr':'private-password','commandDiagnostic':{
                 'operation':'DOCKER_IMAGE_PULL','returnCode':1,'errorCategory':'REGISTRY_ACCESS_DENIED',
                 'clientApiVersion':'private-password','serverApiVersion':'1.50\nSECRET',
                 'installerFailureLine':'/private/source','argv':['private-secret'], 'stderr':'SECRET'}}
        safe=lab.public_failure(row)
        self.assertEqual(safe,{'failure':'INSTALLATION_LAB_FAILED_PRIVATE_DETAILS_OMITTED','failedStage':'UNKNOWN_STAGE',
                              'commandDiagnostic':{'operation':'DOCKER_IMAGE_PULL','returnCode':1,'errorCategory':'REGISTRY_ACCESS_DENIED'}})
        self.assertFalse(any(value in json.dumps(safe) for value in ('PRIVATE_SECRET','private','password','SECRET')))
        row.update(failure='PACKAGED_INSTALLER_COMMAND_FAILED_PRIVATE_OUTPUT_OMITTED',
                   failedStage='interrupted configuration creation',failureLine=187)
        self.assertEqual(lab.public_failure(row)['failureLine'],187)
        self.assertEqual(lab.public_failure(row)['failedStage'],'interrupted configuration creation')

    def test_invalid_diagnostic_types_out_of_range_numbers_and_unknown_categories_are_rejected(self):
        base={'operation':'DOCKER_COMPOSE_CONFIG','returnCode':1,'errorCategory':'COMPOSE_CONFIGURATION_INVALID'}
        for key,value in [('operation',{}),('operation','private-password'),('returnCode',True),('returnCode',10000),
                          ('errorCategory',[]),('errorCategory','PRIVATE_SECRET')]:
            with self.subTest(key=key,value=value):self.assertIsNone(lab.validated_diagnostic({**base,key:value}))
        self.assertIsNone(lab.public_failure({'result':'PASS'}))
        self.assertEqual(lab.public_failure({'result':'FAIL','failedStage':[]})['failedStage'],'UNKNOWN_STAGE')

    def test_only_fixed_public_dependency_names_can_cross_diagnostic_boundary(self):
        base={'operation':'DOCKER_IMAGE_INSPECT_PLATFORM','returnCode':1,
              'errorCategory':'DOCKER_REQUESTED_PLATFORM_UNAVAILABLE'}
        for value in ('POSTGRES_PINNED','VALKEY_PINNED'):
            self.assertEqual(lab.validated_diagnostic({**base,'publicDependency':value}),
                             {**base,'publicDependency':value})
        for value in ('/private/file','SECRET_TOKEN',None,{},['POSTGRES_PINNED']):
            with self.subTest(value=value):
                self.assertEqual(lab.validated_diagnostic({**base,'publicDependency':value}),base)

    def test_unknown_stdout_error_marker_cannot_publish_arbitrary_uppercase_secret(self):
        result=subprocess.CompletedProcess([],1,'STOP PRIVATE_SECRET_TOKEN\n','/personal/photo.jpg')
        with patch.dict(os.environ,CI),patch.object(lab.subprocess,'run',return_value=result):
            with self.assertRaisesRegex(lab.LabFailure,'^LAB_COMMAND_FAILED_PRIVATE_OUTPUT_OMITTED$'):
                lab.command(['private-command'])


class PublicDependencyAvailability(unittest.TestCase):
    def setUp(self):
        self.reference=installer.VALKEY_AMD64_REFERENCE
        self.expected=installer.PUBLIC_DEPENDENCIES[self.reference]
        digest=self.reference.split('@',1)[1]
        self.row={'Id':digest,'Descriptor':{'digest':digest},
                  'RepoDigests':['valkey/valkey@'+digest],
                  'Config':{'Env':['SECRET_PRIVATE_CREDENTIAL']},
                  'Manifests':[{'ID':self.expected['manifest'],'Descriptor':{'digest':self.expected['manifest']},
                                'Available':True,'Kind':'image',
                                'ImageData':{'Platform':{'os':'linux','architecture':'amd64'},
                                             'Containers':['private-container-name']}}]}

    def probe(self,row=None,status=200,raw=None):
        data=json.dumps(self.row if row is None else row).encode() if raw is None else raw
        response=SimpleNamespace(status=status,read=Mock(return_value=data))
        connection_socket=Mock()
        requests=[]
        def request(connection,method,path):
            requests.append((method,path));connection.connect()
        with patch.dict(os.environ,CI,clear=True),\
             patch.object(lab.socket,'socket',return_value=connection_socket) as sockets,\
             patch.object(lab.http.client.HTTPConnection,'request',request),\
             patch.object(lab.http.client.HTTPConnection,'getresponse',return_value=response):
            result=lab.public_dependency_availability(self.reference,'1.51')
        sockets.assert_called_once_with(lab.socket.AF_UNIX,lab.socket.SOCK_STREAM)
        connection_socket.connect.assert_called_once_with('/var/run/docker.sock')
        connection_socket.settimeout.assert_called_once_with(10)
        connection_socket.close.assert_called_once()
        self.assertEqual(requests,[('GET','/v1.51/images/'+lab.urllib.parse.quote(self.reference,safe='')+'/json?manifests=true')])
        if status==200:response.read.assert_called_once_with(1024*1024+1)
        else:response.read.assert_not_called()
        return result

    def test_absent_ci_guards_unreviewed_references_and_invalid_api_never_connect(self):
        for env in ({},{'GITHUB_ACTIONS':'true'},{'GALLERY_ISOLATED_CI':'1'}):
            with self.subTest(env=env),patch.dict(os.environ,env,clear=True),\
                 patch.object(lab.socket,'socket') as sockets:
                self.assertIsNone(lab.public_dependency_availability(self.reference,'1.51'))
                sockets.assert_not_called()
        for reference,version in [('tcp://production.invalid/private','1.51'),
                                  (installer.VALKEY_UPSTREAM_REFERENCE,'1.51'),
                                  (self.reference,'1.48'),(self.reference,'1.51\nPRIVATE'),
                                  (self.reference,True),(None,'1.51')]:
            with self.subTest(reference=reference,version=version),patch.dict(os.environ,CI,clear=True),\
                 patch.object(lab.socket,'socket') as sockets:
                self.assertIsNone(lab.public_dependency_availability(reference,version))
                sockets.assert_not_called()

    def test_fixed_unix_read_only_request_returns_only_expected_public_metadata(self):
        result=self.probe()
        self.assertEqual(set(result),lab.AVAILABILITY_BOOLEANS|lab.AVAILABILITY_COUNTS)
        self.assertTrue(all(result[key] for key in lab.AVAILABILITY_BOOLEANS))
        self.assertEqual(result['expectedManifestCount'],1)
        self.assertFalse(any(value in json.dumps(result) for value in
                             ('SECRET','private','Config','Env','sha256','valkey','/var/run')))

    def test_available_false_true_and_absent_are_distinct_without_guessing(self):
        for available in (False,True,None):
            row=copy.deepcopy(self.row)
            if available is None:row['Manifests'][0].pop('Available')
            else:row['Manifests'][0]['Available']=available
            with self.subTest(available=available):result=self.probe(row)
            self.assertTrue(result['expectedManifestPresent'])
            self.assertEqual(result['expectedManifestAvailabilityPresent'],available is not None)
            self.assertEqual(result['expectedManifestAvailable'],available is True)

    def test_missing_or_duplicate_known_summary_never_claims_usable_image(self):
        for summaries in (None,[],[{**self.row['Manifests'][0],'ID':'unrelated-private-digest'}],
                          [self.row['Manifests'][0]]*2):
            row=copy.deepcopy(self.row);row['Manifests']=summaries
            with self.subTest(summaries=summaries):result=self.probe(row)
            self.assertFalse(result['expectedManifestAvailable'])
            self.assertEqual(result['expectedManifestCount'],2 if summaries and len(summaries)==2 else 0)
            self.assertEqual(result['manifestSummariesPresent'],summaries is not None)

    def test_wrong_platform_root_digest_kind_and_descriptor_report_only_false_flags(self):
        row=copy.deepcopy(self.row)
        row['Id']='PRIVATE_UNKNOWN';row['RepoDigests']=['private.invalid/SECRET']
        row['Descriptor']['digest']='PRIVATE_ROOT'
        row['Manifests'][0].update(Kind='attestation',Descriptor={'digest':'PRIVATE_MANIFEST'})
        row['Manifests'][0]['ImageData']['Platform']['architecture']='arm64'
        result=self.probe(row)
        for field in ('rootIdMatches','rootDescriptorMatches','rootRepositoryDigestMatches',
                      'expectedManifestDescriptorMatches','expectedManifestKindImage','expectedManifestPlatformMatches'):
            self.assertFalse(result[field])
        self.assertNotIn('PRIVATE',json.dumps(result))

    def test_failed_oversized_invalid_or_unbounded_api_result_returns_no_diagnostic(self):
        self.assertIsNone(self.probe(status=500))
        self.assertIsNone(self.probe(raw=b'PRIVATE_NOT_JSON'))
        self.assertIsNone(self.probe(raw=b'X'*(1024*1024+1)))
        for row in ([],{'Manifests':'PRIVATE'}, {'Manifests':[{}]*33},
                    {**self.row,'Manifests':[dict(self.row['Manifests'][0],Available='true')]},
                    {**self.row,'Manifests':[dict(self.row['Manifests'][0],Kind='PRIVATE')]}):
            with self.subTest(row=row):self.assertIsNone(self.probe(row))

    def test_nested_public_sanitizer_rejects_types_private_fields_and_unbounded_counts(self):
        good=self.probe()
        base={'operation':'DOCKER_IMAGE_INSPECT_PLATFORM','returnCode':1,
              'errorCategory':'DOCKER_REQUESTED_PLATFORM_UNAVAILABLE','publicDependency':'VALKEY_PINNED'}
        self.assertEqual(lab.validated_diagnostic({**base,'publicDependencyAvailability':good}),
                         {**base,'publicDependencyAvailability':good})
        invalid=[{**good,'privatePath':'/family/photo'}, {**good,'rootIdMatches':1},
                 {**good,'manifestSummaryCount':True},{**good,'manifestSummaryCount':33},
                 {**good,'expectedManifestCount':-1},{**good,'expectedManifestCount':2},
                 {**good,'expectedManifestPresent':False}]
        for value in invalid:
            with self.subTest(value=value):
                self.assertIsNone(lab.validated_availability(value))
                self.assertEqual(lab.validated_diagnostic({**base,'publicDependencyAvailability':value}),base)
        self.assertEqual(lab.validated_diagnostic({**base,'publicDependency':'SECRET',
                                                  'publicDependencyAvailability':good}),
                         {key:value for key,value in base.items() if key!='publicDependency'})

    def test_socket_failure_is_optional_and_does_not_publish_its_private_error(self):
        with patch.dict(os.environ,CI,clear=True),\
             patch.object(lab.socket,'socket',side_effect=OSError('PRIVATE_DAEMON_SECRET')):
            self.assertIsNone(lab.public_dependency_availability(self.reference,'1.51'))


class PausedQueue(unittest.TestCase):
    def fixture_container(self, directory):
        installation = Path(directory) / 'installation'
        installation.mkdir(mode=0o700)
        (installation / 'media').mkdir(mode=0o700)
        return {'Name': '/immich_server', 'Config': {'Labels': {
            'com.docker.compose.project': 'immich', 'com.docker.compose.service': 'immich-server',
            'com.docker.compose.project.working_dir': str(installation)}}, 'Mounts': [
                {'Destination': '/data', 'Source': str(installation / 'media'), 'Type': 'bind', 'RW': True}]}

    def test_queue_read_requires_actual_owned_local_bind_and_reuses_compiled_storage_detection(self):
        with tempfile.TemporaryDirectory(prefix='gallery-build11-install-lab-') as directory:
            row = self.fixture_container(directory)
            with patch.dict(os.environ, CI), patch.object(lab, 'inspect', return_value=row) as inspect, \
                    patch.object(lab, 'docker', return_value=json.dumps(queue())) as docker:
                self.assertEqual(lab.queue_snapshot(UUID), queue())
            inspect.assert_called_once_with('immich_server')
            self.assertTrue(docker.call_args.args[-1].startswith(lab.media.NODE_LAB_STORAGE))
            self.assertFalse('--env' in docker.call_args.args)

    def test_changed_missing_duplicate_or_readonly_queue_fixture_bind_cannot_exec_node(self):
        with tempfile.TemporaryDirectory(prefix='gallery-build11-install-lab-') as directory:
            original = self.fixture_container(directory)
            cases = []
            row = copy.deepcopy(original); row['Mounts'] = []; cases.append(row)
            row = copy.deepcopy(original); row['Mounts'] *= 2; cases.append(row)
            row = copy.deepcopy(original); row['Mounts'][0]['RW'] = False; cases.append(row)
            row = copy.deepcopy(original); row['Mounts'][0]['Source'] = '/unrelated'; cases.append(row)
            row = copy.deepcopy(original); row['Mounts'][0]['Type'] = 'volume'; cases.append(row)
            row = copy.deepcopy(original); row['Config']['Labels']['com.docker.compose.project'] = 'unrelated'; cases.append(row)
            for row in cases:
                with self.subTest(row=row), patch.dict(os.environ, CI), \
                        patch.object(lab, 'inspect', return_value=row), patch.object(lab, 'docker') as docker:
                    with self.assertRaisesRegex(lab.LabFailure, 'QUEUE_FIXTURE'):
                        lab.queue_snapshot(UUID)
                    docker.assert_not_called()

    def test_exact_all_27_hashes_order_and_six_originals_pass(self):
        lab.unchanged_queue(queue(), copy.deepcopy(queue()))

    def test_reordering_or_job_byte_changes_are_not_ignored(self):
        for kind in ('order', 'hash', 'original'):
            actual = queue()
            if kind == 'order':
                actual['ids'].reverse()
            elif kind == 'hash':
                actual['hashes'][0]['hash'] = 'c' * 64
            else:
                actual['originals'][0] = 'd' * 64
            with self.subTest(kind=kind), self.assertRaisesRegex(lab.LabFailure, 'JOBS_OR_SYNTHETIC'):
                lab.unchanged_queue(queue(), actual)

    def test_missing_duplicate_active_or_unpaused_jobs_fail_closed(self):
        cases = []
        row = queue(); row['ids'].pop(); cases.append(row)
        row = queue(); row['ids'][0] = row['ids'][1]; cases.append(row)
        row = queue(); row['hashes'].pop(); cases.append(row)
        row = queue(); row['hashes'][0]['id'] = row['hashes'][1]['id']; cases.append(row)
        row = queue(); row['active'] = [lab.JOB_IDS[0]]; cases.append(row)
        row = queue(); row['paused'] = False; cases.append(row)
        row = queue(); row['originals'].pop(); cases.append(row)
        for value in cases:
            with self.subTest(value=value), self.assertRaisesRegex(lab.LabFailure, 'ALL_27_PAUSED'):
                lab.validate_queue(value)

    def test_invalid_owner_is_rejected_before_docker_exec(self):
        with patch.object(lab, 'docker') as docker:
            for owner in ('not-owner', UUID + '\n', '../escape'):
                with self.subTest(owner=owner), self.assertRaisesRegex(lab.LabFailure, 'OWNER_UUID'):
                    lab.queue_snapshot(owner)
            docker.assert_not_called()


class ResourcePreservation(unittest.TestCase):
    def test_mount_network_env_or_unrelated_id_mutation_is_rejected(self):
        original = {'/immich_server': {'mounts': [{'Source': '/tmp/lab', 'Destination': '/data', 'RW': True}],
                                     'networks': ['immich_default'], 'env': ['TZ=UTC']},
                    '/immich_postgres': {'id': 'original-container', 'image': 'sha256:' + 'a' * 64}}
        lab.exact_namespace_preserved(original, copy.deepcopy(original))
        for kind in ('mount', 'network', 'env', 'id'):
            changed = copy.deepcopy(original)
            if kind == 'mount': changed['/immich_server']['mounts'][0]['RW'] = False
            elif kind == 'network': changed['/immich_server']['networks'] = ['different']
            elif kind == 'env': changed['/immich_server']['env'] = ['IMMICH_WORKERS_INCLUDE=api']
            else: changed['/immich_postgres']['id'] = 'recreated'
            with self.subTest(kind=kind), self.assertRaisesRegex(lab.LabFailure, 'UNRELATED_SERVICES_CHANGED'):
                lab.exact_namespace_preserved(original, changed)

    def test_foreign_compose_container_is_never_removed(self):
        row = {'Id': 'foreign-container', 'Config': {'Labels': {'com.docker.compose.project.working_dir': '/opt/immich'}}}
        with patch.object(lab, 'docker', side_effect=['foreign-container', json.dumps([row])]) as docker:
            with self.assertRaisesRegex(lab.LabFailure, 'CLEANUP_REFUSES_FOREIGN'):
                lab.cleanup_owned(Path('/tmp/disposable'), None)
        self.assertFalse(any(call.args[0] == 'rm' for call in docker.call_args_list))

    def test_orphan_with_matching_project_directory_is_not_removed(self):
        row = {'Id': 'inpainting-container', 'Name': '/immich-gallery-inpainting-1',
               'Config': {'Labels': {'com.docker.compose.project.working_dir': '/tmp/disposable'}}}
        with patch.object(lab, 'docker', side_effect=['inpainting-container', json.dumps([row])]) as docker:
            with self.assertRaisesRegex(lab.LabFailure, 'CLEANUP_REFUSES_FOREIGN'):
                lab.cleanup_owned(Path('/tmp/disposable'), None)
        self.assertFalse(any(call.args[0] == 'rm' for call in docker.call_args_list))

    def test_foreign_named_volume_is_never_removed(self):
        volume = {'Name': 'unrelated-volume', 'Labels': {'com.docker.compose.project': 'immich'}}
        with patch.object(lab, 'docker', side_effect=['', 'unrelated-volume', json.dumps([volume])]) as docker:
            with self.assertRaisesRegex(lab.LabFailure, 'CLEANUP_REFUSES_FOREIGN_VOLUME'):
                lab.cleanup_owned(Path('/tmp/disposable'), None)
        self.assertFalse(any(call.args[:2] == ('volume', 'rm') for call in docker.call_args_list))

    def test_invalid_media_path_cannot_reach_node_reader(self):
        with patch.object(lab, 'docker') as docker:
            for path in (Path('/etc/shadow'), Path('/data/../etc/shadow'), Path('relative')):
                with self.subTest(path=path), self.assertRaisesRegex(lab.LabFailure, 'ORIGINAL_PATH_REQUIRED'):
                    lab.physical_state(path)
            docker.assert_not_called()


class AlreadyUpgradedRecovery(unittest.TestCase):
    """Unit boundaries only; fixture receipts cannot prove an actual restore."""
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.parent = Path(self.temporary.name)
        self.parent.chmod(0o700)
        self.state = self.parent / 'new-recovery'
        self.source = 'a' * 40
        self.candidate, self.fallback = ('sha256:' + value * 64 for value in ('b', 'c'))
        self.summary = {'assetCount': 2, 'libraryCount': 1, 'statusCounts': {'active': 2},
                        'migrationNames': [lab.MIGRATION], 'orphans': 0}
        self.timestamp = datetime.now(timezone.utc).isoformat()
        self.changes = {}
        self.before_ledger = None
        self.transition = Mock()
        self.spec = SimpleNamespace(loader=SimpleNamespace(exec_module=lambda module: None))
        self.transition_module = SimpleNamespace(build11_restore_transition=self.transition)
        legacy = SimpleNamespace(SERVER='immich_server', POSTGRES='immich_postgres',
                                 OTHER=('immich_postgres', 'immich_redis', 'immich_machine_learning'),
                                 inspect=Mock(side_effect=lambda name: {'Image': self.candidate,
                                     'Config': {'Env': ['IMMICH_SOURCE_COMMIT=' + self.source]}}))
        pre = SimpleNamespace(postgres_identity=Mock(), fresh_backup=Mock(side_effect=self.fresh),
                              restore_exact=Mock(side_effect=self.restore),
                              private_json=lambda path: json.loads(path.read_text()), age_ok=Mock())
        self.operator = SimpleNamespace(legacy=legacy, pre=pre,
            core=SimpleNamespace(DOCKER=['sudo', '-n', 'docker', '--host=' + lab.SOCKET]),
            __file__=str(self.parent / 'tools/build11_operator.py'))

    def fresh(self, tool, state):
        backup = state / 'fresh-immich.sql.gz'
        backup.write_bytes(b'UNIT_FIXTURE_NOT_AN_ACTUAL_POSTGRES_BACKUP')
        backup.chmod(0o600)
        summary = copy.deepcopy(self.summary)
        if self.before_ledger is not None:
            summary['migrationNames'] = self.before_ledger
        (state / 'fresh-backup.json').write_text(json.dumps({
            'source': self.source, 'backupSHA256': lab.digest(backup), 'createdAt': self.timestamp}))
        return backup, summary

    def restore(self, tool, backup, state, summary, transition):
        transition(tool, Mock(), 'gallery-restore-check-' + '1' * 16, [], summary, state, backup)
        checksum = lab.digest(backup)
        receipts = {
            'fresh-restore-verified.json': {'backupSHA256': checksum, 'summary': summary,
                                           'restore': 'PASS_EXACT_DUMP_SNAPSHOT'},
            'backup-verified.json': {'backupSHA256': checksum, 'backupPath': str(backup.resolve()),
                                     'restore': 'PASS_ISOLATED_SQL_TRANSACTION', 'productionChanged': False,
                                     'checkedAt': self.timestamp},
            'build11-restored-database-verified.json': {
                'backupSHA256': checksum, 'sourceCommit': self.source, 'imageId': self.candidate,
                'rollbackImageId': self.fallback, 'productionChanged': False, 'isolatedDatabase': True,
                'baseAlreadyBuild11': True, 'policiesPreserved': True, 'rollbackMigrationsAccepted': True,
                'baseMigrations': summary['migrationNames'], 'targetMigrations': summary['migrationNames'],
                'existingStoragePolicyCount': 2, 'implicitStoragePolicies': 0,
                'mediaFilesMounted': False, 'destructiveTestsPerformed': False, 'testedAt': self.timestamp,
                'validation': 'PASS_ISOLATED_BUILD11_MIGRATION_AND_EXISTING_ROW_PRESERVATION'},
        }
        for name, row in receipts.items():
            row.update(self.changes.get(name, {}))
            path = state / name
            path.write_text(json.dumps(row))
            path.chmod(0o600)

    def invoke(self):
        with patch.dict(os.environ, CI), \
                patch.object(lab.importlib.util, 'spec_from_file_location', return_value=self.spec), \
                patch.object(lab.importlib.util, 'module_from_spec', return_value=self.transition_module):
            return lab.upgraded_backup_restore(self.operator, self.state, self.source, self.candidate, self.fallback)

    def test_fresh_hook_requires_already_upgraded_ledger_and_passes_exact_images_to_callback(self):
        result = self.invoke()
        self.assertTrue(result['migrationLedgerUnchanged'])
        self.assertEqual(result['existingStoragePolicyCount'], 2)
        self.assertFalse(result['mediaFilesMounted'])
        self.assertEqual(self.transition.call_args.args[-2:], (self.candidate, self.fallback))
        self.operator.pre.postgres_identity.assert_called_once()
        self.assertEqual(len(self.operator.pre.age_ok.call_args_list), 3)
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o700)

    def test_literal_restore_and_freshness_guards_are_public_but_private_errors_stay_omitted(self):
        for code in ('POSTGRES_IMAGE_REFERENCE_CHANGED', 'RESTORED_EXISTING_POLICY_MODES_INVALID',
                     'FRESH_RESTORE_COUNTS_OR_MIGRATIONS_DIFFER_FROM_DUMP_SNAPSHOT',
                     'ALREADY_UPGRADED_RECOVERY_RECEIPT_EXPIRED'):
            with self.subTest(code=code):
                self.assertEqual(lab.verified_failure_code(code), code)
                self.assertEqual(lab.verified_failure_code('PACKAGED_INSTALLER_' + code), 'PACKAGED_INSTALLER_' + code)
        for error in ('PRIVATE_SECRET_TOKEN', '/family/media.jpg', 'ERROR password=private', 'READ_RECOVERY_PROOF_aabb'):
            with self.subTest(error=error):
                self.assertIsNone(lab.verified_failure_code(error))

    def test_missing_or_changed_current_storage_policy_receipt_cannot_yield_completion(self):
        for key, value in [('baseAlreadyBuild11', False), ('policiesPreserved', False),
                           ('existingStoragePolicyCount', 0), ('existingStoragePolicyCount', True),
                           ('rollbackMigrationsAccepted', False), ('sourceCommit', 'd' * 40),
                           ('imageId', self.fallback), ('backupSHA256', 'e' * 64),
                           ('targetMigrations', []), ('productionChanged', True), ('mediaFilesMounted', True),
                           ('destructiveTestsPerformed', True)]:
            self.state = self.parent / ('new-' + key)
            if self.state.exists():
                self.state = self.parent / ('new-' + key + '-second')
            self.changes = {'build11-restored-database-verified.json': {key: value}}
            with self.subTest(key=key, value=value), self.assertRaisesRegex(lab.LabFailure, 'ACTUAL_ALREADY_UPGRADED'):
                self.invoke()

    def test_old_backup_receipt_or_changed_backup_path_cannot_be_reused(self):
        self.changes = {'backup-verified.json': {'backupPath': '/old/private-copy.sql.gz'}}
        with self.assertRaisesRegex(lab.LabFailure, 'ACTUAL_ALREADY_UPGRADED'):
            self.invoke()
        self.operator.pre.restore_exact.assert_called_once()

    def test_stale_actual_receipt_is_not_accepted_or_refreshed(self):
        self.operator.pre.age_ok.side_effect = RuntimeError('ALREADY_UPGRADED_RECOVERY_RECEIPT_EXPIRED')
        with self.assertRaisesRegex(RuntimeError, 'RECEIPT_EXPIRED'):
            self.invoke()
        self.assertEqual(json.loads((self.state / 'fresh-backup.json').read_text())['createdAt'], self.timestamp)

    def test_preupgrade_snapshot_cannot_stand_in_for_already_upgraded_path(self):
        self.before_ledger = ['old-migration']
        with self.assertRaisesRegex(lab.LabFailure, 'ALREADY_UPGRADED_FRESH_BACKUP_REQUIRED'):
            self.invoke()
        self.operator.pre.restore_exact.assert_not_called()

    def test_existing_state_or_missing_ci_approval_never_starts_a_backup(self):
        self.state.mkdir(mode=0o700)
        with self.assertRaisesRegex(lab.LabFailure, 'NEW_PRIVATE'):
            self.invoke()
        self.operator.pre.fresh_backup.assert_not_called()
        with patch.dict(os.environ, CI | {'GALLERY_ISOLATED_CI': '0'}), self.assertRaisesRegex(lab.LabFailure, 'EXPLICIT_ISOLATED'):
            lab.upgraded_backup_restore(self.operator, self.parent / 'another', self.source, self.candidate, self.fallback)
        self.operator.pre.fresh_backup.assert_not_called()


class GenuineFaultInjection(unittest.TestCase):
    def test_fault_child_only_recognizes_the_exact_injected_failure(self):
        # Exercise the subprocess wrapper, not string assertions. This tiny
        # fixture is NOT an installer and cannot yield a real lab PASS report.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); tools = root / 'tools'; tools.mkdir()
            fixture = tools / 'gallery_install.py'
            prefix=("from types import SimpleNamespace\nimport subprocess\n"
                    "class Stop(Exception): pass\n"
                    "PUBLIC_DEPENDENCIES={}\n"
                    "core=SimpleNamespace(save=lambda *a:None,health=lambda *a:None,subprocess=subprocess,Stop=Stop,DOCKER=['docker'])\n")
            fixture.write_text(prefix+
                               "def install(args): raise RuntimeError('REAL_SETUP_FAILURE')\n")
            result = subprocess.run([sys.executable, '-B', '-c', lab.INSTALL_CHILD, str(root), str(root),
                                     str(root / 'env'), 'sha256:' + 'a' * 64, 'before-plan', str(Path(lab.__file__).resolve())],
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertNotIn('PASS_EXPECTED', result.stdout)
            fixture.write_text(prefix+
                               "def install(args): core.save(args.directory/'fresh-install-plan.json',{})\n")
            result = subprocess.run([sys.executable, '-B', '-c', lab.INSTALL_CHILD, str(root), str(root),
                                     str(root / 'env'), 'sha256:' + 'a' * 64, 'before-plan', str(Path(lab.__file__).resolve())],
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 90)
            self.assertIn('PASS_EXPECTED_INJECTED_INTERRUPTION', result.stdout)

    def test_child_observes_actual_failed_process_and_sanitizes_version_probe(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);tools=root/'tools';tools.mkdir()
            (tools/'gallery_install.py').write_text("""from types import SimpleNamespace
import subprocess,json
class Stop(Exception):pass
PUBLIC_DEPENDENCIES={}
def process(command,*args,**kwargs):
  if 'version' in command:
    return subprocess.CompletedProcess(command,0,json.dumps({'Client':{'ApiVersion':'1.50'},'Server':{'ApiVersion':'1.48'},'private':'SECRET'}),'')
  return subprocess.CompletedProcess(command,1,'private-stdout','--platform requires API version 1.49 SECRET_PASSWORD /private-family')
core=SimpleNamespace(save=lambda *a:None,health=lambda *a:None,subprocess=SimpleNamespace(run=process,TimeoutExpired=subprocess.TimeoutExpired),Stop=Stop,DOCKER=['docker','--host=unix:///var/run/docker.sock'])
def install(args):
  result=core.subprocess.run([*core.DOCKER,'image','inspect','--platform','linux/amd64','/private-image'],text=True,capture_output=True)
  if result.returncode:raise Stop('COMMAND_FAILED_PRIVATE_OUTPUT_OMITTED')
""")
            result=subprocess.run([sys.executable,'-B','-c',lab.INSTALL_CHILD,str(root),str(root),str(root/'env'),
                                   'sha256:'+'a'*64,'before-plan',str(Path(lab.__file__).resolve())],text=True,capture_output=True)
            self.assertEqual(result.returncode,1);self.assertNotIn('PASS_EXPECTED',result.stdout)
            line=next(line for line in result.stdout.splitlines() if line.startswith('INSTALL_COMMAND_DIAGNOSTIC '))
            safe=json.loads(line[len('INSTALL_COMMAND_DIAGNOSTIC '):])
            self.assertEqual(safe['operation'],'DOCKER_IMAGE_INSPECT_PLATFORM')
            self.assertEqual(safe['returnCode'],1);self.assertEqual(safe['errorCategory'],'DOCKER_API_VERSION_UNSUPPORTED')
            self.assertEqual(safe['clientApiVersion'],'1.50');self.assertEqual(safe['serverApiVersion'],'1.48')
            self.assertTrue(type(safe['installerFailureLine']) is int)
            self.assertFalse(any(value in result.stdout+result.stderr for value in ('SECRET_PASSWORD','/private-family','private-stdout','/private-image')))


if __name__ == '__main__':
    unittest.main()
