#!/usr/bin/env python3
"""Fresh empty installation using the packaged official Compose model."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import stat
import tempfile
from types import SimpleNamespace

import build11_artifacts as artifacts
from build11_operator import artifact_image
from gallery_entry import verify_package
import image_release as core


INITIALIZATION = 'fresh-install-initialization.json'

# Verified registry index -> linux/amd64 manifest -> image-config chains.
# Keep the actual container identity (config in the classic store, index in
# containerd) separate from --platform inspect's selected manifest identity.
PUBLIC_DEPENDENCIES = {
    'ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23': {
        'config': 'sha256:178719aeb38df6f0ce8edc1d8320008379fcf04eb3444e76419cc98d9861e331',
        'manifest': 'sha256:b1d33572a9a0634aa6d344077467ad32847812a37fa3859f702952cba22a2f55',
        'repositories': ('ghcr.io/immich-app/postgres',),
    },
    'docker.io/valkey/valkey:9@sha256:c123e3715db63d06d4ad6964884037aa0d5d4d703939b9929954112889708e1d': {
        'config': 'sha256:c439a6b7b7dfe74b25d78f9e5d27fbaeb761f676de82eb1a154c5b719a8cfb3e',
        'manifest': 'sha256:67878c70fc179bb928b1a9b510860aff1c475ff245e91d98d4b2133326bf8e3e',
        'repositories': ('valkey/valkey', 'docker.io/valkey/valkey'),
    },
}


def require_platform_inspection():
    """Read-only capability gate before any clean-install image import or pull."""
    code = 'DOCKER_PLATFORM_INSPECTION_API_1_49_REQUIRED'
    try:
        row = json.loads(core.docker('version', '--format', '{{json .}}'))
        versions = [row[side]['ApiVersion'] for side in ('Client', 'Server')]
        core.need(all(isinstance(value, str) and re.fullmatch(r'[0-9]{1,2}\.[0-9]{1,3}', value) and
                      tuple(map(int, value.split('.'))) >= (1, 49) for value in versions), code)
    except (KeyError, TypeError, ValueError, core.Stop):
        raise core.Stop('DOCKER_PLATFORM_INSPECTION_API_1_49_REQUIRED') from None
    try:
        help_text = core.docker('image', 'inspect', '--help')
    except core.Stop:
        raise core.Stop('DOCKER_PLATFORM_INSPECTION_CLI_REQUIRED') from None
    core.need(re.search(r'^\s+--platform(?:\s|$)', help_text, re.MULTILINE),
              'DOCKER_PLATFORM_INSPECTION_CLI_REQUIRED')


def pinned_public_dependency(reference):
    """Resolve one exact dependency without mistaking an index for a platform."""
    expected = PUBLIC_DEPENDENCIES.get(reference)
    core.need(expected is not None, 'PINNED_PUBLIC_DEPENDENCY_REFERENCE_REQUIRED')
    try:
        images = json.loads(core.docker('image', 'inspect', reference))
    except core.Stop:
        core.run([*core.DOCKER, 'image', 'pull', '--platform', 'linux/amd64', reference], timeout=900)
        images = json.loads(core.docker('image', 'inspect', reference))
    # API 1.49+ selects an actual platform. Unsupported daemons fail closed;
    # do not infer platform from an index or accept another architecture.
    selected = json.loads(core.docker('image', 'inspect', '--platform', 'linux/amd64', reference))
    code = 'PINNED_PUBLIC_DEPENDENCY_IDENTITY_REQUIRED'
    core.need(len(images) == len(selected) == 1, code)
    image, platform = images[0], selected[0]
    digest = reference.split('@', 1)[1]
    repo_digests = {repository + '@' + digest for repository in expected['repositories']}
    for item in (image, platform):
        core.need(isinstance(item.get('RepoDigests'), list) and
                  bool(repo_digests.intersection(item['RepoDigests'])), code)
    core.need(image.get('Id') in (expected['config'], digest) and
              platform.get('Id') in (expected['config'], expected['manifest']) and
              platform.get('Architecture') == 'amd64' and platform.get('Os') == 'linux', code)
    for item, descriptor_digest in ((image, digest), (platform, expected['manifest'])):
        descriptor = item.get('Descriptor')
        if descriptor is None:
            # The classic image store exposes only the verified config ID.
            core.need(item.get('Id') == expected['config'], code)
        else:
            core.need(isinstance(descriptor, dict) and descriptor.get('digest') == descriptor_digest and
                      item.get('Id') == descriptor_digest, code)
    # Containerd creates containers with the original index ID, not the
    # --platform inspection's child manifest ID (Moby ImageService.GetImage).
    return image['Id']


def publish_initialization_file(directory, name, data):
    """Publish one journal-owned immutable file; interrupted full staging is reusable."""
    target, pending = directory / name, directory / (name + '.pending')
    expected = hashlib.sha256(data).hexdigest()
    def verify(path):
        info = path.lstat()
        core.need(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and
                  stat.S_IMODE(info.st_mode) == 0o600 and artifacts.digest(path) == expected,
                  'INTERRUPTED_INSTALL_INITIALIZATION_CHANGED')
    if target.exists() or target.is_symlink():
        verify(target)
    else:
        if pending.exists() or pending.is_symlink():
            verify(pending)
        else:
            with os.fdopen(os.open(pending, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), 'wb') as file:
                file.write(data); file.flush(); os.fsync(file.fileno())
        os.link(pending, target)  # Never overwrite a concurrent/unreviewed entry.
        sync_install_directory(directory)
    if pending.exists() or pending.is_symlink():
        verify(pending)
        core.need(pending.stat().st_dev == target.stat().st_dev and pending.stat().st_ino == target.stat().st_ino,
                  'INTERRUPTED_INSTALL_INITIALIZATION_CHANGED')
        pending.unlink()
        sync_install_directory(directory)


def sync_install_directory(directory):
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try: os.fsync(fd)
    finally: os.close(fd)


def initialize_configuration(directory, context, files):
    """Only this exact private initialization journal may authorize config resume."""
    journal = json.dumps(context, indent=2).encode() + b'\n'
    names = {INITIALIZATION, INITIALIZATION + '.pending', 'media', 'postgres'}
    names |= set(files) | {name + '.pending' for name in files}
    core.need({path.name for path in directory.iterdir()} <= names,
              'UNREVIEWED_INSTALL_INITIALIZATION_ENTRY')
    # Journal is durably published BEFORE any configuration/data directory.
    publish_initialization_file(directory, INITIALIZATION, journal)
    for name in ('media', 'postgres'):
        path = directory / name
        if not path.exists() and not path.is_symlink():
            path.mkdir(mode=0o700); sync_install_directory(directory)
        info = path.lstat()
        core.need(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and
                  stat.S_IMODE(info.st_mode) == 0o700 and not any(path.iterdir()),
                  'UNREVIEWED_INSTALL_INITIALIZATION_DIRECTORY')
    for name, data in files.items():
        publish_initialization_file(directory, name, data)


def verify_server_configuration(item, base, resolved, candidate):
    """Check the actual server, not its image/PID or a successful prior command alone."""
    expected_hash = core.config_hash(base)
    labels = item.get('Config', {}).get('Labels', {})
    core.need(labels.get('com.docker.compose.config-hash') == expected_hash and
              core.environment(item) == core.merged_environment(resolved, core.image(candidate)),
              'FRESH_INSTALL_EFFECTIVE_SERVER_CONFIGURATION_CHANGED')
    service = resolved['services'][core.SERVICE]
    expected_mounts = []
    for mount in service.get('volumes', []):
        core.need(mount.get('type') == 'bind', 'FRESH_INSTALL_UNREVIEWED_SERVER_VOLUME_TYPE')
        expected_mounts.append((mount['type'], mount['source'], mount['target'], not mount.get('read_only', False)))
    actual_mounts = [(mount.get('Type'), mount.get('Source'), mount.get('Destination'), mount.get('RW'))
                     for mount in item.get('Mounts', [])]
    core.need(sorted(actual_mounts) == sorted(expected_mounts), 'FRESH_INSTALL_SERVER_MOUNTS_CHANGED')
    network_names = {resolved['networks'][name]['name'] for name in service.get('networks', {})}
    core.need(set(item.get('NetworkSettings', {}).get('Networks', {})) == network_names,
              'FRESH_INSTALL_SERVER_NETWORKS_CHANGED')
    return expected_hash


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
    require_platform_inspection()
    directory = args.directory.absolute()
    core.need(directory.is_dir() and not directory.is_symlink() and directory.resolve() == directory and
              not any(char in str(directory) for char in ('\n', '\r', '$')) and
              directory.stat().st_mode & 0o777 == 0o700 and directory.stat().st_uid == os.getuid(),
              'NEW_EMPTY_OWNED_PRIVATE_INSTALL_DIRECTORY_REQUIRED')
    plan_path = directory / 'fresh-install-plan.json'
    resuming = plan_path.exists()
    initializing = any((directory / name).exists() or (directory / name).is_symlink()
                       for name in (INITIALIZATION, INITIALIZATION + '.pending'))
    core.need(resuming or initializing or not any(directory.iterdir()), 'NEW_EMPTY_OWNED_PRIVATE_INSTALL_DIRECTORY_REQUIRED')
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
    rows = []
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
    dependency_images = [pinned_public_dependency(reference) for reference in PUBLIC_DEPENDENCIES]
    # All persistent paths are NEW local directories below this fresh state.
    if not resuming:
        managed = next((row for row in nas['mounts'] if row['destination'] == '/data'), None)
        core.need(not managed or not any(Path(managed['source']).iterdir()), 'CLEAN_INSTALL_REQUIRES_EMPTY_MANAGED_NAS_ROOT')
        media = managed['source'] if managed else str(directory / 'media')
        env_data = '\n'.join(key + '=' + value for key, value in values.items()) + '\nUPLOAD_LOCATION=' + media + '\nDB_DATA_LOCATION=' + str(directory / 'postgres') + '\n'
        server_config = {'image': candidate}
        if nas['mounts']:
            server_config['volumes'] = [{'type': 'bind', 'source': row['source'], 'target': row['destination'],
                                        'read_only': row['readOnly'], 'bind': {'create_host_path': False}}
                                       for row in nas['mounts']]
        override = {'services': {core.SERVICE: server_config,
                                'immich-machine-learning': {'image': machine_learning_image}}}
        files = {'.env': env_data.encode(),
                 'docker-compose.yml': (package / 'config/docker-compose.yml').read_bytes(),
                 'image-only.override.json': json.dumps(override, indent=2).encode() + b'\n'}
        context = {'schemaVersion': 1, 'sourceCommit': profile['sourceCommit'],
                   'packageSHA256': artifacts.digest(package / 'SHA256SUMS'),
                   'environmentSHA256': hashlib.sha256(raw_env).hexdigest(), 'nasStorage': nas,
                   'directoryIdentity': {'device': directory.stat().st_dev, 'inode': directory.stat().st_ino},
                   'serviceImages': {core.SERVICE: candidate, 'immich-machine-learning': machine_learning_image,
                                     'database': dependency_images[0], 'redis': dependency_images[1]},
                   'configFiles': {name: hashlib.sha256(data).hexdigest() for name, data in files.items()}}
        initialize_configuration(directory, context, files)
    base = [*core.DOCKER, 'compose', '--project-directory', str(directory), '-p', 'immich',
            '-f', str(directory / 'docker-compose.yml'), '-f', str(directory / 'image-only.override.json')]
    resolved = core.effective(base)
    core.need(set(resolved.get('services', {})) == {core.SERVICE, 'immich-machine-learning', 'redis', 'database'},
              'EXACT_OFFICIAL_SERVICE_SET_REQUIRED')
    core.workers(core.merged_environment(resolved, core.image(candidate)))
    existing_server = next((row for row in rows if row.get('Name') == '/' + core.SERVER), None)
    if existing_server is not None:
        verify_server_configuration(existing_server, base, resolved, candidate)
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
        current = core.health('http://127.0.0.1:2283/api', candidate, profile['sourceCommit'],
                              {'major': 5, 'minor': 7, 'patch': 3, 'prerelease': None})
        core.need(current['Id'] == completed.get('containerId') and
                  verify_server_configuration(current, base, resolved, candidate) == completed.get('composeConfigHash'),
                  'FRESH_INSTALLED_CONTAINER_CHANGED_REVIEW_REQUIRED')
        print('PASS existing exact Build11 fresh installation verified; no service operation repeated')
        return
    # This fresh-only path deliberately does not exist in the HP upgrade workflow.
    core.need(nas_storage(getattr(args, 'nas_storage_config', None)) == nas,
              'NAS_MOUNT_CHANGED_BEFORE_INSTALLATION')
    core.run([*base, 'up', '-d', '--no-build', '--pull', 'never'], timeout=180)
    current = core.health('http://127.0.0.1:2283/api', candidate, profile['sourceCommit'],
                          {'major': 5, 'minor': 7, 'patch': 3, 'prerelease': None})
    current_hash = verify_server_configuration(current, base, resolved, candidate)
    core.save(directory / 'fresh-install-completed.json', {'sourceCommit': profile['sourceCommit'],
              'contract': 'verified-fresh-install-v1', 'candidateImage': candidate, 'containerId': current['Id'],
              'composeConfigHash': current_hash,
              'installPlanSHA256': artifacts.digest(plan_path), 'packageSHA256': artifacts.digest(package / 'SHA256SUMS'),
              'completedAt': datetime.now(timezone.utc).isoformat()})
    sync_install_directory(directory)
    print('PASS fresh Build11 server healthy; original official services and new local data directories')
    print('NOT_TESTED device installation, backups, NAS writable scopes and thumbnail/preview acceptance')


def fresh_deletion_queue_check():
    """Read the same bounded atomic inventory; ordinary jobs are neither drained nor changed."""
    import trash_release as legacy
    import trash_predeploy as pre
    program = legacy.NODE_BASE + pre.QUEUE_BODY.replace('__LUA__', json.dumps(pre.COUNTS_LUA))
    row = json.loads(core.run([*core.DOCKER, 'exec', '-i', core.SERVER, 'node', '--input-type=module'], input=program))
    states = set(legacy.STATES)
    core.need(isinstance(row, dict) and not row.get('error') and row.get('atomic') is True and
              row.get('inventoryComplete') is True and type(row.get('unresolvedDeletionHashes')) is int and
              row['unresolvedDeletionHashes'] == 0 and
              set(row.get('deletionNames', {})) == {'AssetDelete', 'FileDelete'} and
              all(type(n) is int and n == 0 for n in row['deletionNames'].values()) and
              row.get('deletionNames') == {'AssetDelete': 0, 'FileDelete': 0} and
              all(set(row.get(field, {})) == states and all(type(n) is int and n >= 0 for n in row[field].values())
                  for field in ('before', 'counts')),
              'FRESH_ROLLBACK_DELETION_JOBS_PENDING_OR_INCOMPLETE')
    print('PASS read-only fresh rollback deletion inventory; ordinary queued jobs unchanged')


def rollback_fresh(args):
    core.need(args.execute_approved and os.environ.get('GALLERY_DEPLOYMENT_APPROVED') == 'YES',
              'EXPLICIT_FRESH_ROLLBACK_APPROVAL_REQUIRED')
    core.DOCKER = ['sudo', '-n', 'docker', '--host=unix:///var/run/docker.sock']
    config = verify_package(args.package)
    profile = artifacts.load(args.package / 'candidate-profile.json', config['profileSHA256'])
    directory = args.directory.absolute()
    core.need(directory.is_dir() and not directory.is_symlink() and directory.resolve() == directory and
              directory.stat().st_uid == os.getuid() and directory.stat().st_mode & 0o777 == 0o700,
              'OWNED_PRIVATE_FRESH_INSTALL_DIRECTORY_REQUIRED')
    core.DIRECTORY = directory
    plan = core.private_json(directory / 'fresh-install-plan.json')
    completed = core.private_json(directory / 'fresh-install-completed.json')
    receipt_sha = artifacts.digest(directory / 'fresh-install-completed.json')
    core.completed_fresh_install(receipt_sha, profile['sourceCommit'], plan['candidateImage'], completed['containerId'])
    core.need(plan['packageSHA256'] == artifacts.digest(args.package / 'SHA256SUMS') and
              set(plan['serviceImages']) == {core.SERVICE, 'immich-machine-learning', 'database', 'redis'},
              'FRESH_ROLLBACK_PACKAGE_OR_SERVICE_SET_CHANGED')
    if plan['nasStorage']['mounts']:
        # Reuse the exact NFS validator with private local input, never remount
        # or rely solely on unchanged host-path strings in Docker inspect.
        mappings = [{key: row[key] for key in ('source', 'destination', 'nfsSource', 'readOnly')}
                    for row in plan['nasStorage']['mounts']]
        with tempfile.TemporaryDirectory(prefix='.rollback-nas-', dir=directory) as temporary:
            path = Path(temporary) / 'nas.json'
            core.save(path, {'schemaVersion': 1, 'mounts': mappings})
            core.need(nas_storage(path)['mounts'] == plan['nasStorage']['mounts'], 'FRESH_ROLLBACK_NAS_MOUNT_CHANGED')
    candidate = artifact_image(args.package / 'backend', profile['sourceCommit'], artifacts.VERSION,
                               profile['backend'], allow_load=True)
    core.need(candidate == plan['candidateImage'], 'FRESH_INSTALLED_IMAGE_IDENTITY_CHANGED')
    metadata = json.loads((args.package / 'rollback/manifest.json').read_text())
    rollback = artifact_image(args.package / 'rollback', metadata['sourceCommit'], metadata['serverVersion'],
                              metadata, allow_load=True)
    compatibility = artifacts.pinned_json(args.package / 'reviewed-compatibility.json', config['compatibilitySHA256'])
    core.need(compatibility['candidateSource'] == profile['sourceCommit'] and
              compatibility['candidateImage'] == profile['backend']['imageId'] and
              compatibility['rollbackSource'] == metadata['sourceCommit'] and
              compatibility['rollbackImage'] == metadata['imageId'], 'PINNED_FRESH_ROLLBACK_ARTIFACT_REQUIRED')
    compatibility = {**compatibility, 'candidateImage': candidate, 'rollbackImage': rollback}
    state = directory / 'fresh-rollback-state'
    if not state.exists(): state.mkdir(mode=0o700); sync_install_directory(directory)
    core.need(not state.is_symlink() and state.stat().st_uid == os.getuid() and state.stat().st_mode & 0o777 == 0o700,
              'OWNED_PRIVATE_FRESH_ROLLBACK_STATE_REQUIRED')
    if not (state / 'image-plan.json').exists():
        core.need(not any(state.iterdir()), 'PARTIAL_FRESH_ROLLBACK_PLAN_REQUIRES_REVIEW_NO_REPLAY')
        current = core.inspect(core.SERVER); core.identity(current)
        core.need(current['Image'] == candidate and current['Id'] == completed['containerId'],
                  'FRESH_INSTALLED_CONTAINER_CHANGED')
        fresh_deletion_queue_check()
        compatibility_path = directory / 'fresh-rollback-compatibility.json'
        if compatibility_path.exists():
            core.need(core.private_json(compatibility_path) == compatibility, 'FRESH_ROLLBACK_COMPATIBILITY_CHANGED')
        else:
            core.save(compatibility_path, compatibility); sync_install_directory(directory)
        core.plan(SimpleNamespace(state=state, image=candidate, expected_current_image=candidate,
                    source_commit=profile['sourceCommit'], server_version=(5, 7, 3), api='http://127.0.0.1:2283/api',
                    rollback_image=rollback, rollback_source_commit=metadata['sourceCommit'],
                    rollback_server_version=core.version(metadata['serverVersion']),
                    compatibility_receipt=compatibility_path, compatibility_sha256=artifacts.digest(compatibility_path),
                    completed_install_receipt_sha256=receipt_sha))
    if (state / 'rolled-back.json').exists():
        receipt, current = core.prerequisites(state, rollback=True)
        core.health(receipt['api'], rollback, metadata['sourceCommit'], receipt['rollbackVersion'], timeout=0)
        print('PASS existing exact fresh-install rollback verified; no service operation repeated')
        return
    core.need(not (state / 'rollback-attempt.json').exists(), 'INTERRUPTED_FRESH_ROLLBACK_REQUIRES_REVIEW_NO_REPLAY')
    fresh_deletion_queue_check()
    core.execute(SimpleNamespace(state=state, execute_approved=True, approve_migration=False), rollback=True)
    print('PASS fresh-install image-only rollback; database, media, migrations and other services preserved')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package', type=Path); parser.add_argument('directory', type=Path)
    parser.add_argument('environment', type=Path, nargs='?'); parser.add_argument('machine_learning_image', nargs='?')
    parser.add_argument('--execute-approved', action='store_true')
    parser.add_argument('--rollback-fresh', action='store_true')
    parser.add_argument('--nas-storage-config', type=Path, help='Private exact already-mounted NFS mappings; no mounts or permissions are changed')
    try:
        args = parser.parse_args()
        if args.rollback_fresh: rollback_fresh(args)
        else:
            if args.environment is None or args.machine_learning_image is None:
                parser.error('fresh install requires PRIVATE_ENV_FILE and VERIFIED_ML_IMAGE_ID')
            install(args)
    except Exception as error:
        code = str(error) if isinstance(error, core.Stop) else 'FRESH_INSTALL_FAILED_PRIVATE_DETAILS_OMITTED'
        print('STOP ' + code); raise SystemExit(1) from None
