"""Content-addressed import proofs; synthetic media only, no production access."""
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import secrets
import subprocess
import tarfile
import tempfile
from types import SimpleNamespace
import unittest

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('identity', ROOT / 'scripts/release/trash_image_identity.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def layer(value=b'synthetic-disposable'):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode='w') as archive:
        entry = tarfile.TarInfo('fixture'); entry.size = len(value)
        archive.addfile(entry, io.BytesIO(value))
    return stream.getvalue()


def fixture(oci=False, compress=False, tamper=None, tag='gallery-test:identity'):
    raw_layer = layer()
    config = json.dumps({'architecture': 'amd64', 'os': 'linux', 'config': {'Env': [
        'IMMICH_SOURCE_COMMIT=' + 'a' * 40, 'IMMICH_SOURCE_REF=v5.7.1', 'IMMICH_REPOSITORY=docice545/gallery']},
        'rootfs': {'type': 'layers', 'diff_ids': [m.digest_bytes(raw_layer)]}}).encode()
    config_id = m.digest_bytes(config)
    blob = gzip.compress(raw_layer, mtime=0) if compress else raw_layer
    layer_id = m.digest_bytes(blob)
    blobs = {config_id[7:] + '.json': config, 'layer/layer.tar': blob}
    row = {'Config': config_id[7:] + '.json', 'Layers': ['layer/layer.tar'], 'RepoTags': [tag] if tag else None}
    loaded_id = config_id
    if oci:
        document = {'schemaVersion': 2, 'mediaType': 'application/vnd.docker.distribution.manifest.v2+json',
                    'config': {'mediaType': 'application/vnd.docker.container.image.v1+json', 'digest': config_id, 'size': len(config)},
                    'layers': [{'mediaType': 'application/vnd.docker.image.rootfs.diff.tar' + ('.gzip' if compress else ''),
                                'digest': layer_id, 'size': len(blob)}]}
        encoded = json.dumps(document, separators=(',', ':')).encode()
        loaded_id = m.digest_bytes(encoded)
        blobs['blobs/sha256/' + loaded_id[7:]] = encoded
        index = {'schemaVersion': 2, 'manifests': [{'mediaType': document['mediaType'], 'digest': loaded_id, 'size': len(encoded)}]}
        blobs['index.json'] = json.dumps(index).encode()
    blobs['manifest.json'] = json.dumps([row]).encode()
    if tamper:
        tamper(blobs, row, loaded_id)
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode='w') as archive:
        for name, value in blobs.items():
            entry = tarfile.TarInfo(name); entry.size = len(value)
            archive.addfile(entry, io.BytesIO(value))
    stream.seek(0)
    return stream, config_id, loaded_id


class IdentityTests(unittest.TestCase):
    def test_classic_config_identity(self):
        stream, config, loaded = fixture()
        self.assertEqual(m.scan(stream, config, 'gallery-test:identity', loaded)['identityKind'], 'CONFIG_DIGEST')

    def test_containerd_manifest_identity(self):
        stream, config, loaded = fixture(oci=True)
        self.assertNotEqual(config, loaded)
        self.assertEqual(m.scan(stream, config, 'gallery-test:identity', loaded)['identityKind'], 'MANIFEST_DIGEST')

    def test_gzip_layers_preserve_diff_identity(self):
        stream, config, loaded = fixture(oci=True, compress=True)
        result = m.scan(stream, config, 'gallery-test:identity', loaded)
        self.assertEqual(result['layerDiffIds'], [m.digest_bytes(layer())])

    def test_outer_gzip_archive(self):
        stream, config, _ = fixture()
        self.assertEqual(m.scan(io.BytesIO(gzip.compress(stream.getvalue())), config, 'gallery-test:identity')['layerCount'], 1)

    def test_layer_tamper(self):
        stream, config, loaded = fixture(tamper=lambda b, r, i: b.__setitem__('layer/layer.tar', layer(b'changed')))
        with self.assertRaisesRegex(m.IdentityError, 'DIFF_ID_MISMATCH'):
            m.scan(stream, config, 'gallery-test:identity', loaded)

    def test_config_tamper(self):
        def change(b, row, unused): b[row['Config']] += b' '
        stream, config, loaded = fixture(tamper=change)
        with self.assertRaisesRegex(m.IdentityError, 'CONFIG_DIGEST_MISMATCH'):
            m.scan(stream, config, 'gallery-test:identity', loaded)

    def test_label_alone_cannot_prove_foreign_loaded_id(self):
        stream, config, _ = fixture(oci=True)
        with self.assertRaisesRegex(m.IdentityError, 'LOADED_ID_NOT_IN_VERIFIED_GRAPH'):
            m.scan(stream, config, 'gallery-test:identity', 'sha256:' + 'f' * 64)

    def test_no_descriptor_graph_blocks_nonconfig_id(self):
        stream, config, _ = fixture()
        with self.assertRaisesRegex(m.IdentityError, 'GRAPH_MISSING'):
            m.scan(stream, config, 'gallery-test:identity', 'sha256:' + 'f' * 64)

    def test_descriptor_blob_tamper(self):
        def change(b, row, ident): b['blobs/sha256/' + ident[7:]] += b' '
        stream, config, loaded = fixture(oci=True, tamper=change)
        with self.assertRaisesRegex(m.IdentityError, 'DESCRIPTOR_MISSING'):
            m.scan(stream, config, 'gallery-test:identity', loaded)

    def test_extra_manifest_rejected(self):
        def change(b, row, ident):
            d = json.loads(b['index.json']); d['manifests'] *= 2; b['index.json'] = json.dumps(d).encode()
        stream, config, loaded = fixture(oci=True, tamper=change)
        with self.assertRaisesRegex(m.IdentityError, 'INDEX_INVALID'):
            m.scan(stream, config, 'gallery-test:identity', loaded)

    def test_wrong_export_tag_rejected(self):
        stream, config, _ = fixture()
        with self.assertRaisesRegex(m.IdentityError, 'WRONG_TAG'):
            m.scan(stream, config, 'foreign:tag')

    def test_unsafe_archive_path_rejected(self):
        stream, config, _ = fixture(tamper=lambda b, r, i: b.__setitem__('../outside', b'bad'))
        with self.assertRaisesRegex(m.IdentityError, 'UNSAFE_PATH'):
            m.scan(stream, config, 'gallery-test:identity')

    def test_immutable_export_omitted_tag(self):
        stream, config, loaded = fixture(oci=True, tag=None)
        self.assertEqual(m.scan(stream, config, None, loaded)['identityKind'], 'MANIFEST_DIGEST')


@unittest.skipUnless(os.environ.get('GALLERY_DISPOSABLE_RELEASE_TESTS') == '1', 'opt-in local Docker only')
class LocalImportTests(unittest.TestCase):
    def test_actual_docker_load_and_immutable_save(self):
        tag = 'gallery-disposable-proof:' + secrets.token_hex(8)
        stream, config, unused = fixture(tag=tag)
        docker = ['docker', '--host=unix:///var/run/docker.sock']
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixture.tar'; path.write_bytes(stream.getvalue())
            def command(*args, **kwargs):
                return subprocess.run([*docker, *args], text=True, capture_output=True, check=True, timeout=60).stdout
            try:
                command('load', '-i', str(path))
                tool = SimpleNamespace(verify_artifact=lambda root: path, IMAGE=config, TAG=tag,
                                       SOURCE='a' * 40, ARCHIVE_SHA=hashlib.sha256(path.read_bytes()).hexdigest(),
                                       DOCKER=docker, docker=command)
                result = m.verify_loaded(tool, Path(directory))
                self.assertEqual(result['configDigest'], config)
                self.assertEqual(result['layerCount'], 1)
            finally:
                command('image', 'rm', tag)  # Only this unique synthetic image.


if __name__ == '__main__':
    unittest.main()
