"""Lab boundary/unit contracts; these tests do NOT claim an installation passed."""
from contextlib import redirect_stdout
import copy
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build11_installation_smoke as lab

CI = {'GITHUB_ACTIONS': 'true', 'GALLERY_ISOLATED_CI': '1'}
UUID = '11111111-2222-3333-4444-555555555555'


def queue():
    return {'paused': True, 'ids': list(lab.JOB_IDS), 'active': [],
            'hashes': [{'id': value, 'hash': 'a' * 64} for value in lab.JOB_IDS],
            'originals': ['b' * 64] * 6}


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

    def test_unknown_stdout_error_marker_cannot_publish_arbitrary_uppercase_secret(self):
        result=subprocess.CompletedProcess([],1,'STOP PRIVATE_SECRET_TOKEN\n','/personal/photo.jpg')
        with patch.dict(os.environ,CI),patch.object(lab.subprocess,'run',return_value=result):
            with self.assertRaisesRegex(lab.LabFailure,'^LAB_COMMAND_FAILED_PRIVATE_OUTPUT_OMITTED$'):
                lab.command(['private-command'])


class PausedQueue(unittest.TestCase):
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


class GenuineFaultInjection(unittest.TestCase):
    def test_fault_child_only_recognizes_the_exact_injected_failure(self):
        # Exercise the subprocess wrapper, not string assertions. This tiny
        # fixture is NOT an installer and cannot yield a real lab PASS report.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); tools = root / 'tools'; tools.mkdir()
            fixture = tools / 'gallery_install.py'
            prefix=("from types import SimpleNamespace\nimport subprocess\n"
                    "class Stop(Exception): pass\n"
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
