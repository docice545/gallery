"""Read-only audit boundaries and release failure guards, with synthetic data."""
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout, redirect_stderr
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


audit = module('audit', ROOT / 'scripts/diagnostics/hp_trash_release_audit.py')
android = module('android', ROOT / 'scripts/release/android_release.py')
smoke = module('smoke', ROOT / 'scripts/release/server_artifact_smoke.py')


class ReleasePreparation(unittest.TestCase):
    def test_wrong_user_fails_before_probing_or_writing(self):
        with patch.object(audit.pwd, 'getpwuid', return_value=SimpleNamespace(pw_name='other')), patch.object(audit, 'command') as command, redirect_stderr(io.StringIO()):
            self.assertEqual(audit.main(), 1)
            command.assert_not_called()

    def test_existing_report_survives(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / 'report'; report.write_text('previous private report')
            with patch.object(audit, 'REPORT', report), patch.object(audit.pwd, 'getpwuid', return_value=SimpleNamespace(pw_name='doctoriceadm')), patch.object(audit, 'command') as command, redirect_stderr(io.StringIO()):
                self.assertEqual(audit.main(), 1)
                command.assert_not_called()
            self.assertEqual(report.read_text(), 'previous private report')

    def test_symlink_report_is_never_followed(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / 'report'; target = Path(directory) / 'absent'; report.symlink_to(target)
            with patch.object(audit, 'REPORT', report), patch.object(audit.pwd, 'getpwuid', return_value=SimpleNamespace(pw_name='doctoriceadm')), redirect_stderr(io.StringIO()):
                self.assertEqual(audit.main(), 1)
            self.assertFalse(target.exists())

    def test_new_report_private_and_non_overwriting(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / 'report'
            with patch.object(audit, 'REPORT', report), patch.object(audit.pwd, 'getpwuid', return_value=SimpleNamespace(pw_name='doctoriceadm')), patch.object(audit, 'command', return_value='24.0'), patch.object(audit, 'collect', return_value={'deploymentReady': False}), redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                self.assertEqual(audit.main(), 0)
                self.assertEqual(audit.main(), 1)
            self.assertEqual(report.stat().st_mode & 0o777, 0o600)
            self.assertFalse(json.loads(report.read_text())['deploymentReady'])

    def test_docker_error_details_are_not_printed(self):
        with patch.object(audit.subprocess, 'run', return_value=SimpleNamespace(returncode=1, stdout='SECRET', stderr='TOKEN private/file.jpg')):
            with self.assertRaisesRegex(RuntimeError, '^read-only probe failed$'):
                audit.command(['docker', 'inspect', 'fixture'])

    def test_sanitized_topology_and_nested_nas_mount(self):
        private = 'AUTH_SECRET_PRIVATE_FILENAME'
        def probe(args, **kwargs):
            if args[0] == 'findmnt':
                return json.dumps({'filesystems': [{'target': '/mnt/nas', 'fstype': 'cifs', 'vfs-options': 'rw,relatime'}]})
            if args[1] == 'ps':
                return 'immich_server\nunrelated_service'
            if args[1] == 'inspect':
                return json.dumps([{'Id': 'a'*64, 'Image': 'sha256:'+'b'*64, 'State': {'Running': True},
                    'Config': {'Env': ['TOKEN='+private, 'IMMICH_SOURCE_COMMIT='+'c'*40], 'Labels': {}},
                    'Mounts': [{'Type': 'bind', 'Source': '/mnt', 'Destination': '/external', 'RW': True}]}])
            if args[1] == 'exec':
                self.assertIn('/external/nas', kwargs['input'])
                return '{"readOnly":true}'
            self.fail(args)
        with patch.object(audit, 'command', side_effect=probe):
            report = audit.collect(['docker'])
        encoded = json.dumps(report)
        self.assertNotIn(private, encoded)
        self.assertNotIn('unrelated_service', encoded)
        self.assertEqual(report['containers'][0]['externalMounts'][0]['containerMountpoint'], '/external/nas')
        self.assertFalse(report['deploymentReady'])

    def test_audit_node_program_parses_and_has_no_queue_mutator(self):
        program = audit.NODE_AUDIT.replace('__MOUNT_ROOTS__', '[]')
        result = subprocess.run(['node', '--input-type=module', '--check'], input=program, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        for prohibited in ('new Queue(', 'new Worker(', '.eval(', '.set(', '.del(', '.retry(', '.remove(', 'UPDATE ', 'DELETE FROM ', 'INSERT INTO '):
            # Internal JS maps use .set; only Redis writes are prohibited.
            if prohibited == '.set(':
                self.assertNotIn('redis.set(', program)
            else:
                self.assertNotIn(prohibited, program)
        self.assertIn("default_transaction_read_only:'on'", program)

    def test_android_rejects_installed_build_number_before_preflight(self):
        with patch('sys.argv', ['android_release.py', 'preflight', '--expected-head', 'a'*40, '--build-number', '7']), patch.object(android, 'preflight') as check, redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                android.main()
            check.assert_not_called()

    def test_android_default_is_build_eight(self):
        with patch('sys.argv', ['android_release.py', 'postflight', '--expected-head', 'a'*40]), patch.object(android, 'postflight', return_value={}) as check, redirect_stdout(io.StringIO()):
            self.assertEqual(android.main(), 0)
            self.assertEqual(check.call_args.args[2], 8)

    def test_unsigned_ios_keeps_source_metadata_without_enabling_paid_gate(self):
        workflow = (ROOT / '.github/workflows/gallery-build-mobile.yml').read_text().split('  build-sign-ios:', 1)[1]
        metadata = workflow.index('id: ios-source-meta')
        branding = workflow.index('- uses: ./.github/actions/apply-branding')
        self.assertLess(metadata, branding)
        self.assertIn("awk -F'[ +]' '/^version:/ {print $2, $3}' mobile/pubspec.yaml", workflow)
        self.assertIn('version: ${{ inputs.version || steps.ios-source-meta.outputs.version }}', workflow)
        self.assertIn('build_number: ${{ steps.ios-source-meta.outputs.build }}', workflow)
        self.assertIn("if: inputs.version == ''", workflow)
        self.assertIn("if: inputs.version != ''", workflow)
        self.assertNotIn('echo "version=', workflow[branding:])

    def test_backend_smoke_refuses_non_ci_environment(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(smoke, 'docker') as docker, redirect_stdout(io.StringIO()):
            self.assertEqual(smoke.main(), 1)
            docker.assert_not_called()

    def test_backend_build_refuses_wrong_sha_before_docker(self):
        result = subprocess.run(['bash', str(ROOT / 'scripts/release/server_build.sh'), 'a'*40, '/unused-output'], cwd=ROOT, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('FAIL source commit unavailable', result.stdout)

    def test_backend_smoke_uses_actual_version_dto(self):
        source = (ROOT / 'scripts/release/server_artifact_smoke.py').read_text()
        self.assertIn("{'major': 5, 'minor': 7, 'patch': 1, 'prerelease': None}", source)

    def test_old_backend_source_cannot_hide_application_changes(self):
        source = (ROOT / 'scripts/release/server_build.sh').read_text()
        self.assertIn('git merge-base --is-ancestor', source)
        self.assertIn('git diff --quiet "$release_sha" "$tooling_sha" -- server mobile packages web i18n branding', source)
        self.assertIn('git archive --format=tar "$release_sha"', source)
        self.assertIn('toolingCommit=sys.argv[4]', source)

    def test_docker_fixture_failure_classifies_without_echoing_credentials(self):
        for message, category in (
            ('write private/file: no space left on device TOKEN=private-secret', 'NO_SPACE'),
            ('toomanyrequests: unauthenticated pull rate limit', 'REGISTRY_RATE_LIMIT'),
            ('manifest unknown', 'IMAGE_UNAVAILABLE'),
            ('secret=anything unknown error', 'UNCLASSIFIED_CLI_FAILURE'),
        ):
            with patch.object(smoke.subprocess, 'run', return_value=SimpleNamespace(returncode=125, stdout='', stderr=message)):
                with self.assertRaisesRegex(RuntimeError, category) as caught:
                    smoke.docker('run', 'fixture')
                self.assertNotIn('private-secret', str(caught.exception))
                self.assertNotIn('private/file', str(caught.exception))
                self.assertNotIn('anything', str(caught.exception))


if __name__ == '__main__':
    unittest.main()
