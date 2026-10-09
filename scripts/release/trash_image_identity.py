#!/usr/bin/env python3
"""Streaming proof of config + ordered layer bytes across Docker image stores.

No extraction, registry requests, tags or container execution. A containerd image
ID is a manifest/index digest; it is not the classic store's config digest.
"""
import gzip
import hashlib
import io
import json
from pathlib import PurePosixPath
import subprocess
import tempfile
import threading


class IdentityError(Exception):
    pass


def need(value, code):
    if not value:
        raise IdentityError(code)


def digest_bytes(value):
    return 'sha256:' + hashlib.sha256(value).hexdigest()


class HashReader(io.RawIOBase):
    def __init__(self, source):
        self.source, self.hash = source, hashlib.sha256()

    def readable(self):
        return True

    def readinto(self, buffer):
        chunk = self.source.read(len(buffer))
        self.hash.update(chunk)
        buffer[:len(chunk)] = chunk
        return len(chunk)


def scan(stream, expected_config, tag, loaded_id=None):
    import tarfile
    blobs, small, total = {}, {}, 0
    small_size = 0
    # Tar/gzip parsing streams at <=1 MiB; never materialize a layer in RAM.
    with tarfile.open(fileobj=stream, mode='r|*') as archive:
        for entry in archive:
            path = PurePosixPath(entry.name)
            need(not path.is_absolute() and '..' not in path.parts, 'IMAGE_ARCHIVE_UNSAFE_PATH')
            name = str(path)
            if entry.isdir():
                continue
            need(entry.isfile() and name not in blobs and len(blobs) < 10000, 'IMAGE_ARCHIVE_DUPLICATE_OR_UNSAFE_ENTRY')
            need(0 <= entry.size <= 16 * 1024**3, 'IMAGE_ARCHIVE_SIZE_LIMIT')
            source = HashReader(archive.extractfile(entry))
            buffered = io.BufferedReader(source, buffer_size=1024 * 1024)
            compressed = buffered.peek(2)[:2] == b'\x1f\x8b'
            decoded = gzip.GzipFile(fileobj=buffered) if compressed else buffered
            value, size = hashlib.sha256(), 0
            capture = bytearray() if entry.size <= 4 * 1024**2 and not compressed else None
            while chunk := decoded.read(1024 * 1024):
                value.update(chunk)
                size += len(chunk)
                total += len(chunk)
                need(total <= 16 * 1024**3, 'IMAGE_ARCHIVE_SIZE_LIMIT')
                if capture is not None:
                    capture.extend(chunk)
            # Read the complete outer member, including compression trailers.
            while buffered.read(1024 * 1024):
                pass
            raw_digest = 'sha256:' + source.hash.hexdigest()
            blobs[name] = {'digest': raw_digest, 'size': entry.size,
                           'diff': 'sha256:' + value.hexdigest(), 'compressed': compressed}
            if capture is not None:
                try:
                    data = json.loads(capture)
                except (ValueError, UnicodeDecodeError):
                    continue
                small_size += len(capture)
                need(small_size <= 64 * 1024**2, 'IMAGE_METADATA_SIZE_LIMIT')
                small[name] = (data, bytes(capture))
    need('manifest.json' in small, 'IMAGE_ARCHIVE_MANIFEST_MISSING')
    rows = small['manifest.json'][0]
    need(isinstance(rows, list) and len(rows) == 1 and
         (rows[0].get('RepoTags') == [tag] if tag is not None else not rows[0].get('RepoTags')),
         'IMAGE_ARCHIVE_WRONG_TAG_OR_COUNT')
    row = rows[0]
    config_name, layers = row.get('Config'), row.get('Layers')
    need(config_name in small and blobs[config_name]['digest'] == expected_config, 'IMAGE_CONFIG_DIGEST_MISMATCH')
    config = small[config_name][0]
    need(config.get('architecture') == 'amd64' and config.get('os') == 'linux', 'IMAGE_PLATFORM_MISMATCH')
    need(isinstance(layers, list) and layers and len(set(layers)) == len(layers) and
         all(name in blobs for name in layers), 'IMAGE_LAYER_SET_INVALID')
    diff_ids = [blobs[name]['diff'] for name in layers]
    need(config.get('rootfs', {}).get('type') == 'layers' and
         config['rootfs'].get('diff_ids') == diff_ids, 'IMAGE_LAYER_DIFF_ID_MISMATCH')
    result = {'configDigest': expected_config, 'layerDiffIds': diff_ids,
              'sourceConfig': config.get('config', {}), 'layerCount': len(layers)}
    if loaded_id is None:
        return result
    if loaded_id == expected_config:
        result.update(loadedImageId=loaded_id, identityKind='CONFIG_DIGEST')
        return result
    # Follow only an exact, content-addressed, single-image OCI descriptor graph.
    # A copied label, arbitrary ID, unrelated index or extra manifest proves nothing.
    by_digest = {blobs[name]['digest']: (data, raw) for name, (data, raw) in small.items()}
    need('index.json' in small, 'IMAGE_LOADED_DESCRIPTOR_GRAPH_MISSING')
    reached = {}

    def walk(descriptor, depth=0):
        need(depth < 8 and isinstance(descriptor, dict), 'IMAGE_DESCRIPTOR_INVALID')
        key = descriptor.get('digest')
        need(key in by_digest and key not in reached, 'IMAGE_DESCRIPTOR_MISSING_OR_REPEATED')
        document, raw = by_digest[key]
        need(descriptor.get('size') == len(raw) and digest_bytes(raw) == key, 'IMAGE_DESCRIPTOR_DIGEST_OR_SIZE_MISMATCH')
        need(isinstance(document, dict) and document.get('schemaVersion') == 2, 'IMAGE_DESCRIPTOR_SCHEMA_INVALID')
        reached[key] = 'INDEX_DIGEST' if 'manifests' in document else 'MANIFEST_DIGEST'
        if 'manifests' in document:
            need(len(document['manifests']) == 1, 'IMAGE_MULTIPLATFORM_OR_EXTRA_MANIFEST')
            walk(document['manifests'][0], depth + 1)
            return
        expected_layers = [(blobs[name]['digest'], blobs[name]['size']) for name in layers]
        need(document.get('config', {}).get('digest') == expected_config and
             document['config'].get('size') == blobs[config_name]['size'] and
             [(d.get('digest'), d.get('size')) for d in document.get('layers', [])] == expected_layers,
             'IMAGE_MANIFEST_CONFIG_OR_LAYERS_MISMATCH')

    index = small['index.json'][0]
    need(isinstance(index, dict) and index.get('schemaVersion') == 2 and
         len(index.get('manifests', [])) == 1, 'IMAGE_INDEX_INVALID')
    walk(index['manifests'][0])
    need(loaded_id in reached, 'IMAGE_LOADED_ID_NOT_IN_VERIFIED_GRAPH')
    result.update(loadedImageId=loaded_id, identityKind=reached[loaded_id])
    return result


def verify_loaded(tool, backend):
    archive = tool.verify_artifact(backend)
    with archive.open('rb') as stream:
        expected = scan(stream, tool.IMAGE, tool.TAG)
    item = json.loads(tool.docker('image', 'inspect', tool.TAG))[0]
    env = dict(x.split('=', 1) for x in expected['sourceConfig'].get('Env', []) if '=' in x)
    need(env.get('IMMICH_SOURCE_COMMIT') == tool.SOURCE and env.get('IMMICH_SOURCE_REF') == 'v5.7.1' and
         env.get('IMMICH_REPOSITORY') == 'docice545/gallery', 'IMAGE_SOURCE_METADATA_MISMATCH')
    need(item.get('Architecture') == 'amd64' and item.get('Os') == 'linux' and
         item.get('RootFS', {}).get('Layers') == expected['layerDiffIds'], 'IMAGE_INSPECT_CONFIG_OR_ROOTFS_MISMATCH')
    # Export by IMMUTABLE ID, never by a mutable tag. No disk copy of image layers.
    with tempfile.TemporaryFile() as errors:
        child = subprocess.Popen([*tool.DOCKER, 'image', 'save', item['Id']],
                                 stdout=subprocess.PIPE, stderr=errors)
        timer = threading.Timer(900, child.kill)
        timer.start()
        try:
            # Saving by ID can omit RepoTags. Accept this one deterministic tag
            # alias only for exported manifest checks; inspect above binds our tag.
            result = scan(child.stdout, tool.IMAGE, None, item['Id'])
            need(child.wait(timeout=15) == 0, 'IMAGE_EXPORT_FAILED')
        finally:
            timer.cancel()
            child.stdout.close()
            if child.poll() is None:
                child.kill()
                child.wait()
    need(result['sourceConfig'] == expected['sourceConfig'] and
         result['layerDiffIds'] == expected['layerDiffIds'], 'IMAGE_EXPORTED_CONTENT_MISMATCH')
    need(json.loads(tool.docker('image', 'inspect', tool.TAG))[0]['Id'] == item['Id'], 'IMAGE_TAG_CHANGED_DURING_PROOF')
    result.pop('sourceConfig')
    result.update(sourceCommit=tool.SOURCE, archiveSHA256=tool.ARCHIVE_SHA)
    print('PASS loaded image config + ordered layer bytes + descriptor graph: ' + result['identityKind'])
    return result
