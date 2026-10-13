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
            fixture.write_text("from types import SimpleNamespace\n"
                               "core=SimpleNamespace(save=lambda *a:None,health=lambda *a:None)\n"
                               "def install(args): raise RuntimeError('REAL_SETUP_FAILURE')\n")
            result = subprocess.run([sys.executable, '-B', '-c', lab.INSTALL_CHILD, str(root), str(root),
                                     str(root / 'env'), 'sha256:' + 'a' * 64, 'before-plan'],
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertNotIn('PASS_EXPECTED', result.stdout)
            fixture.write_text("from types import SimpleNamespace\n"
                               "core=SimpleNamespace(save=lambda *a:None,health=lambda *a:None)\n"
                               "def install(args): core.save(args.directory/'fresh-install-plan.json',{})\n")
            result = subprocess.run([sys.executable, '-B', '-c', lab.INSTALL_CHILD, str(root), str(root),
                                     str(root / 'env'), 'sha256:' + 'a' * 64, 'before-plan'],
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 90)
            self.assertIn('PASS_EXPECTED_INJECTED_INTERRUPTION', result.stdout)


if __name__ == '__main__':
    unittest.main()
