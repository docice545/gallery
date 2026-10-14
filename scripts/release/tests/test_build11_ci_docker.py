"""Execute the actual bounded APT selector embedded in the CI workflow."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

WORKFLOW = Path(__file__).resolve().parents[3] / '.github/workflows/gallery-trash-release-proof.yml'
EXPECTED = '5:29.9.0-1~ubuntu.24.04~noble'
SOURCE = 'https://download.docker.com/linux/ubuntu'
TRANSITION = WORKFLOW.parents[2] / 'scripts/release/build11_ci_docker.sh'


class SignedDockerSelection(unittest.TestCase):
    def execute(self, rows):
        section = WORKFLOW.read_text().split('for package in docker-ce docker-ce-cli; do', 1)[1]
        program = section.split("<<'PY'\n", 1)[1].split('\n          PY', 1)[0]
        program = '\n'.join(line[10:] for line in program.splitlines())
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'public-package-versions'
            path.write_text(rows)
            result = subprocess.run([sys.executable, '-', 'docker-ce', EXPECTED, str(path)],
                                    input=program, text=True, capture_output=True)
        notices = [line.split('::', 2)[2] for line in result.stdout.splitlines() if line.startswith('::notice')]
        return result, json.loads(notices[0]) if notices else None

    def row(self, version=EXPECTED, source=SOURCE, package='docker-ce'):
        return f'  {package} | {version} | {source} noble/stable amd64 Packages\n'

    def test_exact_signed_repository_package_is_selected(self):
        result, notice = self.execute(self.row())
        self.assertEqual(result.returncode, 0)
        self.assertTrue(notice['expectedVersionPresent'])
        self.assertEqual(notice['availableOfficialVersions'], [EXPECTED])

    def test_canonical_trailing_slash_does_not_change_repository_identity(self):
        result, notice = self.execute(self.row(source=SOURCE + '/'))
        self.assertEqual(result.returncode, 0)
        self.assertTrue(notice['officialRepositoryPresent'])

    def test_other_repository_or_package_cannot_authorize_the_same_version(self):
        for row in (self.row(source='https://other.invalid/ubuntu'), self.row(package='other-package'),
                    self.row(source='https://PRIVATE_TOKEN@download.docker.com/linux/ubuntu')):
            with self.subTest(row=row):
                result, notice = self.execute(row)
                self.assertEqual(result.returncode, 1)
                self.assertFalse(notice['expectedVersionPresent'])
                self.assertNotIn('PRIVATE_TOKEN', result.stdout + result.stderr)

    def test_missing_version_or_repository_is_an_explicit_stop(self):
        for rows in ('', self.row(version='5:28.3.0-1~ubuntu.24.04~noble')):
            with self.subTest(rows=rows):
                result, notice = self.execute(rows)
                self.assertEqual(result.returncode, 1)
                self.assertFalse(notice['expectedVersionPresent'])
                self.assertIn('PINNED_OFFICIAL_DOCKER_PACKAGE_UNAVAILABLE', result.stdout)

    def test_notice_is_bounded_without_truncating_actual_version_search(self):
        rows = ''.join(self.row(version=f'5:30.0.{i}-1~ubuntu.24.04~noble') for i in range(20)) + self.row()
        result, notice = self.execute(rows)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(notice['availableOfficialVersions']), 8)


class DisposableDockerTransitions(unittest.TestCase):
    """Execute the actual shell helper/trap with disposable command doubles."""

    def execute(self, *, env=None, body=None):
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            log = temporary / 'calls'
            commands = {
                'docker': '''#!/bin/bash
echo "docker $*" >> "$CALL_LOG"
case "$*" in
  *' ps -aq')
    if [[ ${INSPECT_FAIL:-} == 1 ]]; then echo PRIVATE_TOKEN >&2; exit 1; fi
    printf '%s' "${CONTAINERS:-}" ;;
  *' image inspect '*)
    if [[ ${IMAGE_PRESENT:-} == 1 && ! -f "$CALL_LOG.removed" ]]; then echo sha256:private; exit 0; fi
    if [[ ${IMAGE_INSPECT_ERROR:-} == 1 ]]; then echo PRIVATE_TOKEN >&2; exit 1; fi
    echo 'Error response from daemon: No such image: fixed-immutable-reference' >&2; exit 1 ;;
  *' image rm '*)
    if [[ ${REMOVE_FAIL:-} == 1 ]]; then echo PRIVATE_TOKEN >&2; exit 1; fi
    if [[ ${REMOVE_UNCHANGED:-} != 1 ]]; then touch "$CALL_LOG.removed"; fi ;;
  *) exit 1 ;;
esac
''',
                'sudo': '''#!/bin/bash
echo "sudo $*" >> "$CALL_LOG"
case "$*" in
  '-n systemctl reset-failed docker.service')
    if [[ ${RESET_FAIL:-} == 1 ]]; then echo PRIVATE_TOKEN >&2; exit 1; fi ;;
  '-n systemctl restart docker.service')
    if [[ ${RESTART_FAIL:-} == 1 ]]; then echo PRIVATE_TOKEN >&2; exit 1; fi ;;
  '-n systemctl show docker.service --property=Result --value')
    printf '%s' "${SERVICE_RESULT:-start-limit-hit}" ;;
  'cp '*) ;; # The workflow trap must never write a host file in this test.
  *) exit 1 ;;
esac
''',
                'jq': '#!/bin/bash\nprintf \'{}\\n\'\n',
            }
            for name, program in commands.items():
                path = temporary / name
                path.write_text(program)
                path.chmod(0o700)
            environment = {key: value for key, value in os.environ.items() if not key.startswith('DOCKER_')}
            environment.update(PATH=str(temporary) + ':' + os.environ['PATH'], CALL_LOG=str(log),
                               GITHUB_ACTIONS='true', GALLERY_ISOLATED_CI='1', RUNNER_OS='Linux',
                               RUNNER_TEMP=str(temporary))
            environment.update(env or {})
            result = subprocess.run(['bash', '-c', 'set -euo pipefail\nsource "$1"\n' +
                                     (body or 'build11_restart_disposable_docker'), 'bash', str(TRANSITION)],
                                    env=environment, text=True, capture_output=True)
            return result, log.read_text().splitlines() if log.exists() else []

    def test_intentional_transition_resets_counter_only_after_empty_local_inspection(self):
        result, calls = self.execute()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ['docker --host=unix:///var/run/docker.sock ps -aq',
                                 'sudo -n systemctl reset-failed docker.service',
                                 'sudo -n systemctl restart docker.service'])

    def test_missing_ci_guard_or_remote_options_prevent_any_command(self):
        for env in ({'GITHUB_ACTIONS': 'false'}, {'GALLERY_ISOLATED_CI': ''}, {'RUNNER_OS': 'Windows'},
                    *({key: 'private-option'} for key in ('DOCKER_HOST', 'DOCKER_CONTEXT', 'DOCKER_TLS',
                                                        'DOCKER_TLS_VERIFY', 'DOCKER_CERT_PATH', 'DOCKER_API_VERSION'))):
            with self.subTest(env=env):
                result, calls = self.execute(env=env)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(calls, [])
                self.assertNotIn('private-option', result.stdout + result.stderr)

    def test_failed_inspection_or_existing_container_prevents_restart(self):
        for env in ({'INSPECT_FAIL': '1'}, {'CONTAINERS': 'private-container'}):
            with self.subTest(env=env):
                result, calls = self.execute(env=env)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(calls, ['docker --host=unix:///var/run/docker.sock ps -aq'])
                self.assertNotIn('PRIVATE_TOKEN', result.stdout + result.stderr)
                self.assertNotIn('private-container', result.stdout + result.stderr)

    def test_counter_reset_failure_is_not_ignored_or_followed_by_restart(self):
        result, calls = self.execute(env={'RESET_FAIL': '1'})
        self.assertEqual(result.returncode, 1)
        self.assertEqual(calls[-1], 'sudo -n systemctl reset-failed docker.service')
        self.assertNotIn('PRIVATE_TOKEN', result.stdout + result.stderr)
        self.assertIn('DISPOSABLE_DOCKER_COUNTER_RESET_FAILED', result.stdout)

    def test_restart_failure_is_classified_without_raw_systemd_or_journal_output(self):
        for service, suffix in (('start-limit-hit', 'START_LIMIT_HIT'), ('exit-code', 'EXIT_CODE'),
                                ('timeout', 'TIMEOUT'), ('signal', 'SIGNAL'), ('oom-kill', 'OOM'),
                                ('PRIVATE_TOKEN /personal/file', 'FAILED_PRIVATE_DETAILS_OMITTED')):
            with self.subTest(service=service):
                result, calls = self.execute(env={'RESTART_FAIL': '1', 'SERVICE_RESULT': service})
                self.assertEqual(result.returncode, 1)
                self.assertEqual(calls[-1], 'sudo -n systemctl show docker.service --property=Result --value')
                self.assertIn('DISPOSABLE_DOCKER_RESTART_' + suffix, result.stdout)
                self.assertNotIn('PRIVATE_TOKEN', result.stdout + result.stderr)
                self.assertNotIn('/personal/file', result.stdout + result.stderr)

    def workflow_trap(self):
        text = WORKFLOW.read_text()
        function = text.split('          restore_classic_store() {\n', 1)[1].split('\n          trap restore_classic_store EXIT', 1)[0]
        return 'restore_classic_store() {\n' + '\n'.join(line[10:] for line in function.splitlines())

    def test_probe_failure_is_preserved_when_classic_restore_also_fails(self):
        result, calls = self.execute(env={'RESTART_FAIL': '1'},
                                     body=self.workflow_trap() + '\ntrap restore_classic_store EXIT\nexit 17\n')
        self.assertEqual(result.returncode, 17)
        self.assertIn('sudo -n systemctl restart docker.service', calls)

    def test_successful_probe_cannot_hide_classic_restore_failure(self):
        result, _ = self.execute(env={'RESTART_FAIL': '1'},
                                 body=self.workflow_trap() + '\ntrap restore_classic_store EXIT\nexit 0\n')
        self.assertEqual(result.returncode, 1)

    def test_successful_probe_and_restore_leave_success(self):
        result, _ = self.execute(body=self.workflow_trap() + '\ntrap restore_classic_store EXIT\nexit 0\n')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_existing_container_in_restore_prevents_configuration_write_or_restart(self):
        result, calls = self.execute(env={'CONTAINERS': 'private-container'},
                                     body=self.workflow_trap() + '\ntrap restore_classic_store EXIT\nexit 0\n')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(calls, ['docker --host=unix:///var/run/docker.sock ps -aq'])

    def test_both_probe_and_later_store_transition_use_the_same_guarded_restart(self):
        text = WORKFLOW.read_text()
        for start, end in (('Check immutable Valkey platform before large artifact downloads',
                            'Enforce exact application inputs and complete build provenance'),
                           ('Containerd store on disposable Actions VM only',
                            'Verify Build11 on containerd and assemble compiled distribution')):
            section = text.split('- name: ' + start, 1)[1].split('- name: ' + end, 1)[0]
            self.assertIn("GALLERY_ISOLATED_CI: '1'", section)
            self.assertIn('source scripts/release/build11_ci_docker.sh', section)
            self.assertIn('build11_require_disposable_docker', section)
            self.assertIn('build11_restart_disposable_docker', section)
            self.assertNotIn('systemctl restart docker', section)
            self.assertNotIn('systemctl stop docker', section)
            self.assertNotIn('systemctl start docker', section)

    def test_probe_reference_exactly_matches_the_validated_installer_leaf(self):
        sys.path.insert(0, str(TRANSITION.parent))
        import gallery_install
        literal = TRANSITION.read_text().split("readonly BUILD11_CI_VALKEY_REFERENCE='", 1)[1].split("'", 1)[0]
        self.assertEqual(literal, gallery_install.VALKEY_AMD64_REFERENCE)

    def test_probe_does_not_adopt_or_remove_preexisting_reference(self):
        result, calls = self.execute(env={'IMAGE_PRESENT': '1'}, body='build11_require_absent_valkey_probe_image')
        self.assertEqual(result.returncode, 1)
        self.assertIn('PROBE_REQUIRES_ABSENT_REFERENCE', result.stdout)
        self.assertFalse(any('image rm' in call for call in calls))

    def test_absence_requires_real_missing_image_not_a_private_command_error(self):
        result, _ = self.execute(body='build11_require_absent_valkey_probe_image')
        self.assertEqual(result.returncode, 0)
        result, _ = self.execute(env={'IMAGE_INSPECT_ERROR': '1'}, body='build11_require_absent_valkey_probe_image')
        self.assertEqual(result.returncode, 1)
        self.assertIn('DISPOSABLE_VALKEY_ABSENCE_NOT_VERIFIED', result.stdout)
        self.assertNotIn('PRIVATE_TOKEN', result.stdout + result.stderr)

    def test_cleanup_removes_only_the_fixed_reference_and_verifies_absence(self):
        result, calls = self.execute(env={'IMAGE_PRESENT': '1'}, body='build11_remove_valkey_probe_image')
        self.assertEqual(result.returncode, 0, result.stderr)
        reference = TRANSITION.read_text().split("readonly BUILD11_CI_VALKEY_REFERENCE='", 1)[1].split("'", 1)[0]
        removals = [call for call in calls if 'image rm' in call]
        self.assertEqual(removals, ['docker --host=unix:///var/run/docker.sock image rm ' + reference])
        self.assertIn('image inspect', calls[-1])
        self.assertFalse(any('prune' in call or '--force' in call for call in calls))

    def test_cleanup_failure_or_remaining_reference_cannot_be_ignored(self):
        for env in ({'REMOVE_FAIL': '1'}, {'IMAGE_PRESENT': '1', 'REMOVE_UNCHANGED': '1'}):
            with self.subTest(env=env):
                result, _ = self.execute(env=env, body='build11_remove_valkey_probe_image')
                self.assertEqual(result.returncode, 1)
                self.assertNotIn('PRIVATE_TOKEN', result.stdout + result.stderr)

    def test_actual_installer_cannot_be_prewarmed_by_successful_early_probe(self):
        section = WORKFLOW.read_text().split('- name: Check immutable Valkey platform before large artifact downloads', 1)[1]
        section = section.split('- name: Enforce exact application inputs and complete build provenance', 1)[0]
        self.assertLess(section.index('build11_require_absent_valkey_probe_image'), section.index('installer.pinned_public_dependency(reference)'))
        self.assertGreater(section.index('build11_remove_valkey_probe_image'), section.index("raise SystemExit(1)"))


if __name__ == '__main__':
    unittest.main()
