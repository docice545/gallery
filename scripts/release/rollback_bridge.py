#!/usr/bin/env python3
"""Migration-recognition overlay for API-only rollback; never drops deletion evidence."""
import hashlib
import json
import re
import tarfile
import tempfile
from pathlib import Path, PurePosixPath

from release_candidate import MIGRATION, digest, need

MARKER = b'''
// Recognition only. This bridge must NEVER initialize a fresh database.
export async function up() { throw new Error("Rollback bridge requires already applied authorized-deletion migration"); }
export async function down() { throw new Error("Deletion tombstones must survive rollback"); }
'''
ROOTS = ('/usr/src/app/server/dist/schema/migrations', '/usr/src/app/server/dist/schema/migrations-gallery')


def verify(tool, parent, bridge):
    before, after = json.loads(tool.docker('image', 'inspect', parent, bridge))
    need(before['Id'] == parent and after['Id'] == bridge, 'ROLLBACK_BRIDGE_IMMUTABLE_ID')
    layers, added = before['RootFS']['Layers'], after['RootFS']['Layers']
    need(added[:-1] == layers and len(added) == len(layers) + 1, 'ROLLBACK_BRIDGE_PARENT_LAYERS')
    need(after['Architecture'] == before['Architecture'] == 'amd64' and after['Os'] == before['Os'] == 'linux' and
         after['Config'] == before['Config'], 'ROLLBACK_BRIDGE_CONFIG_CHANGED')
    # Inspect the sole added layer: EXACTLY the two migration-recognition files,
    # no executable/app/config override and no whiteouts. Never starts a container.
    with tempfile.TemporaryFile() as stream:
        import subprocess
        with tempfile.TemporaryFile() as errors:
            result = subprocess.run([*tool.DOCKER, 'image', 'save', bridge], stdout=stream, stderr=errors, timeout=900)
        need(result.returncode == 0, 'ROLLBACK_BRIDGE_EXPORT')
        stream.seek(0)
        with tarfile.open(fileobj=stream, mode='r|*') as archive:
            manifest = next(json.load(archive.extractfile(m)) for m in archive if m.name == 'manifest.json')
        need(len(manifest) == 1, 'ROLLBACK_BRIDGE_ARCHIVE_COUNT')
        last = manifest[0]['Layers'][-1]
        stream.seek(0)
        found = {}
        with tarfile.open(fileobj=stream, mode='r|*') as archive:
            for member in archive:
                if member.name != last:
                    continue
                with tarfile.open(fileobj=archive.extractfile(member), mode='r|*') as layer:
                    for item in layer:
                        if item.isdir():
                            continue
                        need(item.isfile() and item.size == len(MARKER), 'ROLLBACK_BRIDGE_EXTRA_OR_INVALID_FILE')
                        need(not PurePosixPath(item.name).is_absolute() and '..' not in PurePosixPath(item.name).parts,
                             'ROLLBACK_BRIDGE_INVALID_LAYER_PATH')
                        path = '/' + item.name.lstrip('./')
                        need(path in [r + '/' + MIGRATION + '.js' for r in ROOTS] and path not in found,
                             'ROLLBACK_BRIDGE_UNEXPECTED_FILE')
                        found[path] = layer.extractfile(item).read()
        need(len(found) == 2 and all(v == MARKER for v in found.values()), 'ROLLBACK_BRIDGE_MARKER_CHANGED')
    return {'parentImage': parent, 'imageId': bridge, 'markerSHA256': hashlib.sha256(MARKER).hexdigest(),
            'migration': MIGRATION, 'workers': 'API_ONLY_REQUIRED'}


def prepare(tool, state, backend):
    from trash_predeploy import private_json, save
    parent = tool.inspect(tool.SERVER)['Image']
    receipt = state / 'rollback-bridge.json'
    if receipt.exists():
        row = private_json(receipt)
        need(row['parentImage'] == parent, 'ROLLBACK_BRIDGE_RECEIPT_CHANGED')
        ensure(tool, state, row)
        return
    need(re.fullmatch('sha256:[0-9a-f]{64}', parent), 'ROLLBACK_PARENT_ID')
    alias = 'gallery-rollback-parent:bridge-' + hashlib.sha256(str(state).encode()).hexdigest()[:24]
    # BuildKit does not accept config IDs in FROM. A private unique alias is
    # resolved back to the exact immutable parent by the layer/config proof.
    tool.docker('tag', parent, alias)
    with tempfile.TemporaryDirectory(prefix='gallery-rollback-bridge-', dir=state) as temporary:
        root = Path(temporary)
        (root / 'marker.js').write_bytes(MARKER)
        (root / 'Dockerfile').write_text('FROM ' + alias + '\nCOPY marker.js ' + ROOTS[0] + '/' + MIGRATION + '.js\nCOPY marker.js ' + ROOTS[1] + '/' + MIGRATION + '.js\n')
        # Two COPY statements can create two layers; use one COPY with the exact
        # directory tree so proof always has a single immutable added layer.
        for directory in ROOTS:
            target = root / 'overlay' / directory.lstrip('/')
            target.mkdir(parents=True)
            (target / (MIGRATION + '.js')).write_bytes(MARKER)
        (root / 'Dockerfile').write_text('FROM ' + alias + '\nCOPY overlay/ /\n')
        idfile = root / 'image-id'
        tool.docker('build', '--network', 'none', '--pull=false', '--iidfile', str(idfile), str(root), timeout=900)
        image = idfile.read_text().strip()
    row = verify(tool, parent, image)
    # Only new rollback artifact, no production container/volume changes.
    archive = state / 'rollback-bridge-image.tar'
    need(not archive.exists(), 'ROLLBACK_BRIDGE_ARCHIVE_ALREADY_EXISTS')
    tool.docker('image', 'save', '-o', str(archive), image, timeout=900)
    archive.chmod(0o600)
    row['archiveSHA256'] = digest(archive)
    save(receipt, row)
    print('PASS immutable API-only rollback bridge; originals/journal/schema retained')


def ensure(tool, state, row):
    archive = state / 'rollback-bridge-image.tar'
    need(archive.is_file() and not archive.is_symlink() and
         archive.stat().st_mode & 0o077 == 0 and digest(archive) == row.get('archiveSHA256'),
         'ROLLBACK_BRIDGE_ARCHIVE_CHANGED')
    # Restore only our exact saved image if it was removed from the local store.
    # Never pull a floating previous tag and never prune unrelated images.
    images = tool.docker('image', 'ls', '--no-trunc', '--quiet').splitlines()
    if row['imageId'] not in images:
        tool.docker('image', 'load', '-i', str(archive), timeout=900)
    proof = verify(tool, row['parentImage'], row['imageId'])
    need(row == {**proof, 'archiveSHA256': digest(archive)}, 'ROLLBACK_BRIDGE_RECEIPT_CHANGED')


def rollback(tool, args):
    from trash_predeploy import private_json
    journal = private_json(args.state / 'deployment.json')
    bridge = private_json(args.state / 'rollback-bridge.json')
    need(bridge['parentImage'] == journal['previousImage'], 'ROLLBACK_BRIDGE_CHANGED')
    ensure(tool, args.state, bridge)
    need(tool.inspect(tool.SERVER)['Image'] in (tool.IMAGE, bridge['imageId']), 'ROLLBACK_LIVE_IMAGE_CHANGED')
    need(all(tool.digest(Path(p)) == value for p, value in journal['configHashes'].items()), 'ROLLBACK_COMPOSE_CHANGED')
    # Explicit approved rollback may gate the one deletion queue; never clear/retry jobs.
    tool.api(args.api, args.key, '/jobs/backgroundTask', 'PUT', {'command': 'pause'})
    tool.queue_empty(require_paused=True)
    file = tool.override(args.state, bridge['imageId'], name='rollback-bridge-api-only.override.json')
    tool.recreate(journal['base'], file)
    need(tool.inspect(tool.SERVER)['Image'] == bridge['imageId'] and tool.api_only(tool.inspect(tool.SERVER)),
         'ROLLBACK_BRIDGE_WORKER_GATE')
    tool.health(args.api)
    need(all(tool.inspect(name)['Id'] == value for name, value in journal['otherContainers'].items()),
         'ROLLBACK_UNRELATED_CONTAINER_CHANGED')
    tool.queue_empty(require_paused=True)
    print('PASS previous API plus recognition marker; deletion workers remain disabled; no DB/NAS rollback')
