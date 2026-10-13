"""Real archive parsing across the operator/verifier boundary; synthetic bytes only."""
import hashlib
import json
import os
from pathlib import Path
import sys
import secrets
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build11_operator as operator
from test_trash_image_identity import fixture, layer


class Child:
    def __init__(self, stream): self.stdout = stream
    def wait(self, timeout=None): return 0
    def poll(self): return 0
    def kill(self): raise AssertionError('completed synthetic export must not be killed')


class OperatorIdentity(unittest.TestCase):
    def check_store(self, containerd):
        source, version, tag = 'a' * 40, '5.7.1', 'gallery-test:identity'
        original, config, loaded = fixture(oci=containerd, tag=tag)
        exported, _, _ = fixture(oci=containerd, tag=None)
        item = {'Id': loaded, 'Architecture': 'amd64', 'Os': 'linux',
                'RootFS': {'Layers': ['sha256:' + hashlib.sha256(layer()).hexdigest()]}}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / 'gallery-server-linux-amd64.tar.gz'
            archive.write_bytes(original.getvalue())
            expected = {'sourceCommit': source, 'serverVersion': version, 'imageId': config,
                        'imageTag': tag, 'archiveSHA256': hashlib.sha256(archive.read_bytes()).hexdigest()}
            (root / 'manifest.json').write_text(json.dumps(expected))
            cache = root / 'identity.json'
            with patch.object(operator.core, 'docker', return_value=json.dumps([item])), \
                    patch.object(operator.identity.subprocess, 'Popen', return_value=Child(exported)) as process:
                self.assertEqual(operator.artifact_image(root, source, version, expected, cache), loaded)
            receipt = json.loads(cache.read_text())
            self.assertEqual(receipt['archiveSHA256'], expected['archiveSHA256'])
            self.assertEqual(receipt['sourceCommit'], source)
            self.assertEqual(receipt['configDigest'], config)
            self.assertEqual(receipt['loadedImageId'], loaded)
            self.assertEqual(receipt['identityKind'], 'MANIFEST_DIGEST' if containerd else 'CONFIG_DIGEST')
            self.assertEqual(process.call_args.args[0][-1], loaded)
            archive.write_bytes(b'tampered artifact')
            with patch.object(operator.core, 'docker') as docker, \
                    self.assertRaisesRegex(operator.core.Stop, 'EXACT_FROZEN_BACKEND_REQUIRED'):
                operator.artifact_image(root, source, version, expected)
            docker.assert_not_called()

    def test_real_classic_archive_verifier_produces_complete_receipt(self): self.check_store(False)
    def test_real_containerd_archive_verifier_produces_complete_receipt(self): self.check_store(True)


@unittest.skipUnless(os.environ.get('GALLERY_DISPOSABLE_RELEASE_TESTS') == '1', 'opt-in managed local Docker only')
class ActualOperatorImport(unittest.TestCase):
    def test_real_docker_operator_load_export_and_receipt(self):
        tag = 'gallery-build11-disposable-operator:' + secrets.token_hex(8)
        stream, config, _ = fixture(tag=tag)
        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(operator.core, 'DOCKER', ['docker', '--host=unix:///var/run/docker.sock']):
            root = Path(temporary)
            archive = root / 'gallery-server-linux-amd64.tar.gz'
            archive.write_bytes(stream.getvalue())
            metadata = {'sourceCommit': 'a' * 40, 'serverVersion': '5.7.1', 'imageId': config, 'imageTag': tag,
                        'archiveSHA256': hashlib.sha256(archive.read_bytes()).hexdigest()}
            (root / 'manifest.json').write_text(json.dumps(metadata))
            try:
                loaded = operator.artifact_image(root, 'a' * 40, '5.7.1', metadata, root / 'receipt.json', allow_load=True)
                receipt = json.loads((root / 'receipt.json').read_text())
                self.assertEqual(receipt['loadedImageId'], loaded)
                self.assertEqual(receipt['configDigest'], config)
                self.assertEqual(receipt['archiveSHA256'], metadata['archiveSHA256'])
            finally:
                operator.core.docker('image', 'rm', tag)  # Only this unique synthetic image.


if __name__ == '__main__': unittest.main()
