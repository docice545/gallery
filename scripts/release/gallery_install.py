#!/usr/bin/env python3
"""Fresh empty installation using the packaged official Compose model."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket

import build11_artifacts as artifacts
from build11_operator import artifact_image
from gallery_entry import verify_package
import image_release as core


def nas_storage(path):
    """Verify already-mounted NFS roots; never mounts/chmods a NAS directory."""
    if path is None:
        return {'mounts': [], 'sha256': None}
    info = path.lstat()
    core.need(path.is_file() and not path.is_symlink() and info.st_mode & 0o777 == 0o600 and
              info.st_uid == os.getuid(), 'PRIVATE_NAS_STORAGE_CONFIGURATION_REQUIRED')
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), 'rb') as file:
        raw = file.read(65537)
    core.need(len(raw) <= 65536, 'NAS_STORAGE_CONFIGURATION_SIZE_LIMIT')
    config = json.loads(raw)
    core.need(set(config) == {'schemaVersion', 'mounts'} and config['schemaVersion'] == 1 and
              isinstance(config['mounts'], list) and 1 <= len(config['mounts']) <= 32,
              'EXACT_NAS_STORAGE_CONFIGURATION_REQUIRED')
    mounts = []
    for row in config['mounts']:
        core.need(set(row) == {'source', 'destination', 'nfsSource', 'readOnly'} and
                  type(row['readOnly']) is bool and isinstance(row['nfsSource'], str) and
                  re.fullmatch(r'[A-Za-z0-9.-]+:/[^\r\n,]+', row['nfsSource']), 'STRICT_NAS_MOUNT_MAPPING_REQUIRED')
        source, destination = Path(row['source']), row['destination']
        core.need(source.is_absolute() and source.is_dir() and source.resolve() == source and
                  (destination == '/data' or re.fullmatch(r'/external/[A-Za-z0-9_-]+', destination)) and
                  not any(char in str(source) for char in (',', '\n', '\r', '$')), 'NARROW_REAL_NAS_ROOT_REQUIRED')
        core.need(destination != '/data' or row['readOnly'] is False, 'MANAGED_NAS_ROOT_REQUIRES_EXPLICIT_EXISTING_RW_MODE')
        data = json.loads(core.run(['findmnt', '-J', '-T', str(source), '-o', 'SOURCE,TARGET,FSTYPE,OPTIONS']))
        def rows(values):
            for item in values:
                yield item
                yield from rows(item.get('children', []))
        actual = [item for item in rows(data.get('filesystems', [])) if item.get('fstype') != 'autofs']
        core.need(len(actual) == 1 and actual[0].get('fstype') in ('nfs', 'nfs4') and
                  actual[0].get('target') == str(source) and actual[0].get('source') == row['nfsSource'],
                  'EXACT_NAS_NFS_SOURCE_AND_TARGET_REQUIRED')
        options = set(actual[0].get('options', '').split(','))
        core.need(('ro' in options) != ('rw' in options) and (row['readOnly'] or 'rw' in options),
                  'NFS_WRITE_MODE_MUST_ALREADY_BE_EXPLICITLY_CONFIGURED')
        stat = source.stat()
        mounts.append({**row, 'device': stat.st_dev, 'inode': stat.st_ino,
                       'mountOptions': sorted(options), 'fileSystem': actual[0]['fstype']})
    core.need(len({row['source'] for row in mounts}) == len(mounts) and
              len({row['destination'] for row in mounts}) == len(mounts), 'UNIQUE_NAS_STORAGE_MAPPINGS_REQUIRED')
    return {'mounts': mounts, 'sha256': hashlib.sha256(raw).hexdigest()}


def install(args):
    core.need(args.execute_approved and os.environ.get('GALLERY_FRESH_INSTALL_APPROVED') == 'YES',
              'EXPLICIT_FRESH_INSTALL_APPROVAL_REQUIRED')
    core.DOCKER = ['sudo', '-n', 'docker', '--host=unix:///var/run/docker.sock']
    package = args.package; config = verify_package(package)
    profile = artifacts.load(package / 'candidate-profile.json', config['profileSHA256'])
    directory = args.directory.absolute()
    core.need(directory.is_dir() and not directory.is_symlink() and directory.resolve() == directory and
              not any(char in str(directory) for char in ('\n', '\r', '$')) and
              directory.stat().st_mode & 0o777 == 0o700 and directory.stat().st_uid == os.getuid(),
              'NEW_EMPTY_OWNED_PRIVATE_INSTALL_DIRECTORY_REQUIRED')
    plan_path = directory / 'fresh-install-plan.json'
    resuming = plan_path.exists()
    core.need(resuming or not any(directory.iterdir()), 'NEW_EMPTY_OWNED_PRIVATE_INSTALL_DIRECTORY_REQUIRED')
    core.need(args.environment.is_file() and not args.environment.is_symlink() and
              args.environment.stat().st_mode & 0o777 == 0o600 and args.environment.stat().st_uid == os.getuid(),
              'PRIVATE_OWNER_ENV_FILE_REQUIRED')
    with os.fdopen(os.open(args.environment, os.O_RDONLY | os.O_NOFOLLOW), 'rb') as file:
        raw_env = file.read(65537)
    core.need(len(raw_env) <= 65536, 'PRIVATE_ENV_SIZE_LIMIT')
    env_lines = raw_env.decode().splitlines()
    core.need(all(not line or line.startswith('#') or re.fullmatch('[A-Z_][A-Z0-9_]*=.*', line) for line in env_lines),
              'SIMPLE_PRIVATE_ENV_FORMAT_REQUIRED')
    entries = [line.split('=', 1) for line in env_lines if line and not line.startswith('#')]
    core.need(len({key for key, value in entries}) == len(entries), 'DUPLICATE_PRIVATE_ENV_KEY')
    values = dict(entries)
    values.setdefault('DB_USERNAME', 'postgres'); values.setdefault('DB_DATABASE_NAME', 'immich')
    allowed = {'DB_PASSWORD', 'DB_USERNAME', 'DB_DATABASE_NAME', 'TZ'}
    core.need(values.keys() <= allowed and values.get('DB_PASSWORD') and
              re.fullmatch('[A-Za-z0-9_-]{20,128}', values['DB_PASSWORD']) and
              values.get('DB_USERNAME', 'postgres') == 'postgres' and values.get('DB_DATABASE_NAME', 'immich') == 'immich',
              'FRESH_INSTALL_SAFE_ENV_KEYS_REQUIRED')
    core.workers(values)
    nas = nas_storage(getattr(args, 'nas_storage_config', None))
    plan = core.private_json(plan_path) if resuming else None
    if resuming:
        core.need(plan.get('sourceCommit') == profile['sourceCommit'] and
                  plan.get('packageSHA256') == artifacts.digest(package / 'SHA256SUMS') and
                  plan.get('environmentSHA256') == hashlib.sha256(raw_env).hexdigest() and
                  plan.get('nasStorage') == nas and
                  plan.get('directoryIdentity') == {'device': directory.stat().st_dev, 'inode': directory.stat().st_ino},
                  'INTERRUPTED_INSTALL_CONTEXT_CHANGED')
        for name, expected in plan['configFiles'].items():
            core.need(artifacts.digest(directory / name) == expected, 'INTERRUPTED_INSTALL_CONFIGURATION_CHANGED')
    ids = core.docker('ps', '-aq', '--filter', 'label=com.docker.compose.project=immich').split()
    if ids:
        core.need(resuming, 'EXISTING_IMMICH_PROJECT_USE_UPGRADE')
        rows = json.loads(core.docker('inspect', *ids))
        core.need(len(rows) == len(ids), 'FRESH_INSTALL_CONTAINER_INVENTORY_INCOMPLETE')
        for row in rows:
            labels = row.get('Config', {}).get('Labels', {})
            core.need(labels.get('com.docker.compose.project.working_dir') == str(directory) and
                      labels.get('com.docker.compose.service') in plan['serviceImages'] and
                      row['Image'] == plan['serviceImages'][labels['com.docker.compose.service']],
                      'UNREVIEWED_EXISTING_INSTALL_CONTAINER')
    for name in (core.SERVER, core.POSTGRES, 'immich_redis', 'immich_machine_learning'):
        found = core.docker('ps', '-aq', '--filter', 'name=^/' + name + '$').split()
        core.need(not found or resuming and set(found) <= set(ids), 'EXISTING_GALLERY_CONTAINER_USE_UPGRADE')
    if not ids:
        with socket.socket() as probe:
            probe.bind(('0.0.0.0', 2283))  # Check the actual official published port, before service operations.
    candidate = artifact_image(package / 'backend', profile['sourceCommit'], artifacts.VERSION, profile['backend'], allow_load=True)
    core.need(config.get('machineLearningImage') == args.machine_learning_image and
              re.fullmatch('sha256:[0-9a-f]{64}', config.get('machineLearningImage', '')),
              'VERIFIED_UPSTREAM_MACHINE_LEARNING_IMAGE_REQUIRED')
    ml_reference = config.get('machineLearningReference')
    machine_learning_image = args.machine_learning_image
    try:
        core.image(args.machine_learning_image)
    except core.Stop:
        core.need(isinstance(ml_reference, str) and
                  re.fullmatch('ghcr.io/open-noodle/gallery-ml@sha256:[0-9a-f]{64}', ml_reference),
                  'PINNED_MACHINE_LEARNING_DEPENDENCY_REQUIRED')
        core.run([*core.DOCKER, 'image', 'pull', '--platform', 'linux/amd64', ml_reference], timeout=1800)
        ml = json.loads(core.docker('image', 'inspect', ml_reference))
        core.need(len(ml) == 1 and ml[0]['Id'] in
                  (args.machine_learning_image, 'sha256:' + ml_reference.rsplit('sha256:', 1)[1]) and
                  ml_reference in ml[0].get('RepoDigests', []), 'PINNED_MACHINE_LEARNING_IMAGE_ID_MISMATCH')
        # Docker's classic store exposes config ID; its containerd store may
        # expose the exact registry manifest ID. Only these two verified
        # identities for this immutable digest are accepted, never arbitrary IDs.
        machine_learning_image = ml[0]['Id']
        core.image(machine_learning_image)
    dependencies = (
        'ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23',
        'docker.io/valkey/valkey:9@sha256:c123e3715db63d06d4ad6964884037aa0d5d4d703939b9929954112889708e1d')
    dependency_images = []
    for reference in dependencies:
        try:
            images = json.loads(core.docker('image', 'inspect', reference))
        except core.Stop:
            core.run([*core.DOCKER, 'image', 'pull', '--platform', 'linux/amd64', reference], timeout=900)
            images = json.loads(core.docker('image', 'inspect', reference))
        core.need(len(images) == 1 and images[0].get('Architecture') == 'amd64' and images[0].get('Os') == 'linux',
                  'PINNED_PUBLIC_DEPENDENCY_IDENTITY_REQUIRED')
        dependency_images.append(images[0]['Id'])
    # All persistent paths are NEW local directories below this fresh state.
    if not resuming:
        managed = next((row for row in nas['mounts'] if row['destination'] == '/data'), None)
        core.need(not managed or not any(Path(managed['source']).iterdir()), 'CLEAN_INSTALL_REQUIRES_EMPTY_MANAGED_NAS_ROOT')
        (directory / 'media').mkdir(mode=0o700); (directory / 'postgres').mkdir(mode=0o700)
        media = managed['source'] if managed else str(directory / 'media')
        env_data = '\n'.join(key + '=' + value for key, value in values.items()) + '\nUPLOAD_LOCATION=' + media + '\nDB_DATA_LOCATION=' + str(directory / 'postgres') + '\n'
        with os.fdopen(os.open(directory / '.env', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), 'w') as file:
            file.write(env_data)
            file.flush(); os.fsync(file.fileno())
        shutil.copyfile(package / 'config/docker-compose.yml', directory / 'docker-compose.yml')
        server_config = {'image': candidate}
        if nas['mounts']:
            server_config['volumes'] = [{'type': 'bind', 'source': row['source'], 'target': row['destination'],
                                        'read_only': row['readOnly'], 'bind': {'create_host_path': False}}
                                       for row in nas['mounts']]
        core.save(directory / 'image-only.override.json', {'services': {core.SERVICE: server_config,
                  'immich-machine-learning': {'image': machine_learning_image}}})
    base = [*core.DOCKER, 'compose', '--project-directory', str(directory), '-p', 'immich',
            '-f', str(directory / 'docker-compose.yml'), '-f', str(directory / 'image-only.override.json')]
    resolved = core.effective(base)
    core.need(set(resolved.get('services', {})) == {core.SERVICE, 'immich-machine-learning', 'redis', 'database'},
              'EXACT_OFFICIAL_SERVICE_SET_REQUIRED')
    core.workers(core.merged_environment(resolved, core.image(candidate)))
    service_images = {core.SERVICE: candidate, 'immich-machine-learning': machine_learning_image,
                      'database': dependency_images[0], 'redis': dependency_images[1]}
    if not resuming:
        core.save(plan_path, {'schemaVersion': 1, 'sourceCommit': profile['sourceCommit'],
                  'candidateImage': candidate, 'machineLearningImage': machine_learning_image, 'dataCreatedNew': True,
                  'packageSHA256': artifacts.digest(package / 'SHA256SUMS'),
                  'environmentSHA256': hashlib.sha256(raw_env).hexdigest(),
                  'nasStorage': nas,
                  'directoryIdentity': {'device': directory.stat().st_dev, 'inode': directory.stat().st_ino},
                  'serviceImages': service_images,
                  'configFiles': {name: artifacts.digest(directory / name) for name in
                                  ('.env', 'docker-compose.yml', 'image-only.override.json')}})
    else:
        core.need(plan['serviceImages'] == service_images and plan['candidateImage'] == candidate,
                  'INTERRUPTED_INSTALL_IMAGE_IDENTITY_CHANGED')
    core.DIRECTORY = directory
    if (directory / 'fresh-install-completed.json').exists():
        completed = core.private_json(directory / 'fresh-install-completed.json')
        core.need(completed['sourceCommit'] == profile['sourceCommit'] and completed['candidateImage'] == candidate,
                  'INSTALL_COMPLETION_RECEIPT_CHANGED')
        core.health('http://127.0.0.1:2283/api', candidate, profile['sourceCommit'],
                    {'major': 5, 'minor': 7, 'patch': 3, 'prerelease': None})
        print('PASS existing exact Build11 fresh installation verified; no service operation repeated')
        return
    # This fresh-only path deliberately does not exist in the HP upgrade workflow.
    core.need(nas_storage(getattr(args, 'nas_storage_config', None)) == nas,
              'NAS_MOUNT_CHANGED_BEFORE_INSTALLATION')
    core.run([*base, 'up', '-d', '--no-build', '--pull', 'never'], timeout=180)
    core.health('http://127.0.0.1:2283/api', candidate, profile['sourceCommit'],
                {'major': 5, 'minor': 7, 'patch': 3, 'prerelease': None})
    core.save(directory / 'fresh-install-completed.json', {'sourceCommit': profile['sourceCommit'],
              'candidateImage': candidate, 'completedAt': datetime.now(timezone.utc).isoformat()})
    print('PASS fresh Build11 server healthy; original official services and new local data directories')
    print('NOT_TESTED device installation, backups, NAS writable scopes and thumbnail/preview acceptance')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package', type=Path); parser.add_argument('directory', type=Path)
    parser.add_argument('environment', type=Path); parser.add_argument('machine_learning_image')
    parser.add_argument('--execute-approved', action='store_true')
    parser.add_argument('--nas-storage-config', type=Path, help='Private exact already-mounted NFS mappings; no mounts or permissions are changed')
    try: install(parser.parse_args())
    except Exception as error:
        code = str(error) if isinstance(error, core.Stop) else 'FRESH_INSTALL_FAILED_PRIVATE_DETAILS_OMITTED'
        print('STOP ' + code); raise SystemExit(1) from None
