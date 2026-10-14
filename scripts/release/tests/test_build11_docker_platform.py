"""Regression for the actual API-1.48 installation failure; no daemon changes."""
import json
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import gallery_install as m


def versions(client='1.51', server='1.51'):
    return json.dumps({'Client': {'ApiVersion': client}, 'Server': {'ApiVersion': server}})


class PlatformInspection(unittest.TestCase):
    def probe(self, response, help_text='      --platform string   Inspect an actual image platform\n'):
        calls = Mock(side_effect=[response, help_text])
        with patch.object(m.core, 'docker', calls):
            m.require_platform_inspection()
        return calls

    def test_supported_client_and_server_and_real_cli_flag(self):
        for version in ('1.49', '1.51', '1.100'):
            with self.subTest(version=version):
                calls = self.probe(versions(version, version))
                self.assertEqual(calls.call_args_list, [
                    unittest.mock.call('version', '--format', '{{json .}}'),
                    unittest.mock.call('image', 'inspect', '--help')])

    def test_either_old_api_blocks_before_any_platform_lookup_or_pull(self):
        for client, server in (('1.48', '1.48'), ('1.48', '1.51'), ('1.51', '1.48')):
            calls = Mock(return_value=versions(client, server))
            with self.subTest(client=client, server=server), patch.object(m.core, 'docker', calls), \
                    self.assertRaisesRegex(m.core.Stop, '^DOCKER_PLATFORM_INSPECTION_API_1_49_REQUIRED$'):
                m.require_platform_inspection()
            calls.assert_called_once_with('version', '--format', '{{json .}}')

    def test_malformed_or_missing_api_fails_closed_without_private_output(self):
        for response in ('private-token', 'null', '[]', '{}', versions(None), versions('1.51 private-token'),
                         versions(True), versions('1.9999')):
            calls = Mock(return_value=response)
            with self.subTest(response=response), patch.object(m.core, 'docker', calls), \
                    self.assertRaisesRegex(m.core.Stop, '^DOCKER_PLATFORM_INSPECTION_API_1_49_REQUIRED$'):
                m.require_platform_inspection()
            calls.assert_called_once_with('version', '--format', '{{json .}}')

    def test_read_only_version_failure_does_not_expose_raw_error(self):
        with patch.object(m.core, 'docker', side_effect=m.core.Stop('private-token /private-path')), \
                self.assertRaisesRegex(m.core.Stop, '^DOCKER_PLATFORM_INSPECTION_API_1_49_REQUIRED$'):
            m.require_platform_inspection()

    def test_new_api_cannot_substitute_for_missing_cli_platform_flag(self):
        for help_text in ('Usage: image inspect', 'This flag requires --platform in a newer CLI'):
            with self.subTest(help_text=help_text), \
                    self.assertRaisesRegex(m.core.Stop, '^DOCKER_PLATFORM_INSPECTION_CLI_REQUIRED$'):
                self.probe(versions(), help_text)

    def test_help_failure_is_bounded_and_public_diagnostics_recognize_both_guards(self):
        from build11_installation_smoke import verified_failure_code
        with patch.object(m.core, 'docker', side_effect=[versions(), m.core.Stop('private-token')]), \
                self.assertRaisesRegex(m.core.Stop, '^DOCKER_PLATFORM_INSPECTION_CLI_REQUIRED$'):
            m.require_platform_inspection()
        for code in ('DOCKER_PLATFORM_INSPECTION_API_1_49_REQUIRED', 'DOCKER_PLATFORM_INSPECTION_CLI_REQUIRED'):
            self.assertEqual(verified_failure_code(code), code)

    def test_clean_install_checks_capability_before_loading_or_creating_anything(self):
        args = SimpleNamespace(execute_approved=True, package=Path('/synthetic-package'))
        with patch.dict(m.os.environ, {'GALLERY_FRESH_INSTALL_APPROVED': 'YES'}), \
                patch.object(m, 'verify_package', return_value={'profileSHA256': 'a' * 64}), \
                patch.object(m.artifacts, 'load', return_value={}), \
                patch.object(m.core, 'docker', return_value=versions('1.48', '1.48')), \
                patch.object(m, 'artifact_image') as images, \
                self.assertRaisesRegex(m.core.Stop, '^DOCKER_PLATFORM_INSPECTION_API_1_49_REQUIRED$'):
            m.install(args)
        images.assert_not_called()


if __name__ == '__main__':
    unittest.main()
