"""Opt-in native Compose regressions on an explicitly named disposable daemon.

No application, database, NAS, network, build or pull. Only uniquely named sleep
fixtures using already cached images. Never use this suite on the HP daemon.
"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import uuid


ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location('native_compose_image_release', ROOT / 'scripts/release/image_release.py')
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)
DOCKER = ['docker', '--host=unix:///var/run/docker.sock']


@unittest.skipUnless(os.environ.get('GALLERY_TEST_LOCAL_DOCKER') == 'YES', 'disposable Docker opt-in required')
class NativeComposeHash(unittest.TestCase):
    @classmethod
    def command(cls, args, input=None):
        env = dict(os.environ)
        for key in ('DOCKER_HOST', 'DOCKER_CONTEXT', 'DOCKER_TLS', 'DOCKER_TLS_VERIFY', 'DOCKER_CERT_PATH'):
            env.pop(key, None)
        result = subprocess.run(args, capture_output=True, text=True, input=input, env=env, timeout=60)
        if result.returncode:
            raise AssertionError('Native fixture command failed; private output omitted')
        return result.stdout.strip()

    @classmethod
    def setUpClass(cls):
        expected = os.environ.get('GALLERY_TEST_DOCKER_NAME')
        if not expected or expected.lower() in ('hp', 'production'):
            raise AssertionError('An explicitly verified disposable Docker name is required')
        actual = cls.command([*DOCKER, 'info', '--format', '{{.Name}}'])
        if actual != expected:
            raise AssertionError('Disposable Docker identity mismatch')
        cls.image = json.loads(cls.command([*DOCKER, 'image', 'inspect', 'redis:7-alpine']))[0]['Id']
        cls.alternate = json.loads(cls.command([*DOCKER, 'image', 'inspect', 'postgres:16-alpine']))[0]['Id']

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='gallery-compose-hash-test-', dir='/tmp')
        self.root = Path(self.temporary.name)
        self.project = 'gallery-hash-test-' + uuid.uuid4().hex[:16]
        self.file = self.root / 'compose.json'
        self.envfile = self.root / 'fixture.env'
        self.envfile.write_text('PROBE=synthetic-private-value\n')
        self.envfile.chmod(0o600)
        self.model = {'services': {release.SERVICE: {
            'image': self.image, 'entrypoint': ['/bin/sleep', '300'], 'network_mode': 'none',
            'read_only': True, 'cap_drop': ['ALL'], 'security_opt': ['no-new-privileges:true'],
            'mem_limit': '32m', 'cpus': 0.25, 'pids_limit': 16}}}
        self.base = [*DOCKER, 'compose', '--project-directory', str(self.root), '-p', self.project,
                     '-f', str(self.file)]
        # Production helper intentionally pins its socket; remove selectors for
        # subprocesses just as the cloud Docker instructions require.
        clean = {k: v for k, v in os.environ.items() if k not in (
            'DOCKER_HOST', 'DOCKER_CONTEXT', 'DOCKER_TLS', 'DOCKER_TLS_VERIFY', 'DOCKER_CERT_PATH')}
        self.clean_environment = patch.dict(os.environ, clean, clear=True)
        self.clean_environment.start()

    def tearDown(self):
        try:
            ids = self.command([*DOCKER, 'ps', '-aq', '--filter', 'label=com.docker.compose.project=' + self.project]).split()
            for container in ids:
                item = json.loads(self.command([*DOCKER, 'inspect', container]))[0]
                self.assertEqual(item['Config']['Labels']['com.docker.compose.project'], self.project)
                self.assertEqual(item['Config']['Labels']['com.docker.compose.service'], release.SERVICE)
                if item['State']['Running']:
                    self.command([*DOCKER, 'stop', '--time', '1', container])
                # Only this unique verified fixture's anonymous volumes. No
                # named production volumes, compose down, or global prune.
                self.command([*DOCKER, 'rm', '--volumes', container])
        finally:
            self.clean_environment.stop()
            self.temporary.cleanup()

    def write(self):
        self.file.write_text(json.dumps(self.model))
        self.file.chmod(0o600)

    def create(self, override=None, start=False):
        base = [*self.base, *(['-f', str(override)] if override else [])]
        args = ['up', '-d', '--no-deps'] if start else ['create']
        self.command([*base, *args, '--no-build', '--pull', 'never', release.SERVICE])
        ids = self.command([*base, 'ps', '-aq', release.SERVICE]).split()
        self.assertEqual(len(ids), 1)
        return json.loads(self.command([*DOCKER, 'inspect', ids[0]]))[0]

    def test_ordinary_explicit_environment_matches_real_create_hash(self):
        self.model['services'][release.SERVICE]['environment'] = {'PROBE': 'synthetic'}
        self.write()
        item = self.create()
        actual = item['Config']['Labels']['com.docker.compose.config-hash']
        self.assertEqual(release.config_hash(self.base), actual)
        self.assertEqual(self.command([*self.base, 'config', '--hash', release.SERVICE]).split()[1], actual)

    def test_env_file_reproduces_original_false_stop_and_resolved_hash_matches(self):
        self.model['services'][release.SERVICE]['env_file'] = [str(self.envfile)]
        self.write()
        item = self.create()
        actual = item['Config']['Labels']['com.docker.compose.config-hash']
        self.assertNotEqual(self.command([*self.base, 'config', '--hash', release.SERVICE]).split()[1], actual)
        self.assertEqual(release.config_hash(self.base), actual)

    def test_literal_dollar_is_not_interpolated_twice_or_changed_in_container(self):
        with patch.dict(os.environ, {'GALLERY_HASH_SENTINEL': 'must-not-substitute'}):
            self.envfile.write_text("PROBE='literal-$GALLERY_HASH_SENTINEL-$$'\nEMPTY=\n")
            self.model['services'][release.SERVICE]['env_file'] = [str(self.envfile)]
            self.write()
            item = self.create()
            env = release.environment(item)
            self.assertEqual(env['PROBE'], 'literal-$GALLERY_HASH_SENTINEL-$$')
            self.assertEqual(env['EMPTY'], '')
            self.assertEqual(release.config_hash(self.base), item['Config']['Labels']['com.docker.compose.config-hash'])

    def test_changed_env_file_still_rejects_real_runtime_configuration(self):
        self.model['services'][release.SERVICE]['env_file'] = [str(self.envfile)]
        self.write()
        item = self.create()
        actual = item['Config']['Labels']['com.docker.compose.config-hash']
        self.assertEqual(release.config_hash(self.base), actual)
        raw = self.command([*self.base, 'config', '--hash', release.SERVICE])
        self.envfile.write_text('PROBE=different-synthetic-value\n')
        self.assertEqual(self.command([*self.base, 'config', '--hash', release.SERVICE]), raw)
        self.assertNotEqual(release.config_hash(self.base), actual)

    def test_image_update_and_rollback_preserve_readonly_evidence_mount_and_environment(self):
        evidence = self.root / 'evidence'
        evidence.mkdir(mode=0o700)
        service = self.model['services'][release.SERVICE]
        service['env_file'] = [str(self.envfile)]
        service['volumes'] = [{'type': 'bind', 'source': str(evidence), 'target': '/run/recovery', 'read_only': True}]
        # These two test images declare different data-volume defaults. Cover
        # both explicitly with disposable read-only binds; never compare or lose
        # image-specific anonymous database volumes in an image-only test.
        for target in ('/data', '/var/lib/postgresql/data'):
            staging = self.root / target.rsplit('/', 1)[-1]
            staging.mkdir(mode=0o700, exist_ok=True)
            service['volumes'].append({'type': 'bind', 'source': str(staging), 'target': target, 'read_only': True})
        self.write()
        original = self.create(start=True)
        before = release.effective(self.base)
        for filename, target in (('candidate.json', self.alternate), ('rollback.json', self.image)):
            override = self.root / filename
            release.save(override, {'services': {release.SERVICE: {'image': target}}})
            release.image_only(before, release.effective(self.base, override), target)
            item = self.create(override, start=True)
            self.assertEqual(item['Image'], target)
            canonical = lambda mounts: sorted(json.dumps(mount, sort_keys=True) for mount in mounts)
            self.assertEqual(canonical(item['Mounts']), canonical(original['Mounts']))
            self.assertEqual(release.environment(item)['PROBE'], release.environment(original)['PROBE'])
            self.assertEqual(release.config_hash(self.base, override), item['Config']['Labels']['com.docker.compose.config-hash'])


if __name__ == '__main__':
    unittest.main()
