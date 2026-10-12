#!/usr/bin/env python3
"""Prepare a separately built hardened rollback; never guess an old image source."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import pwd
import re
import stat
import sys
import tarfile
from types import SimpleNamespace
import zipfile

SOURCE = 'ea51a8acdc6f18ab5917c19b6f3833d740b4e9ba'
TARGET = 'sha256:4d4f9d581a654713b6d305f9aa1341b302fd36fc4ef7fca832dcb94de4004e75'
CURRENT = 'sha256:828523317c332cb312246c9b0ca43e0eef1eb724f7f9aadb58c61b7f87068f43'
ROLLBACK_SOURCE = '81867689be4d773473b6a3f417eee16c0329231e'
CI_RUN = 38166908087
# Set only from the completed immutable GitHub Actions artifact, not operator input.
CI_ARTIFACT = 11712627739
ZIP_SHA256 = '48527713b211b8c66a41f78dc7677bb9cff06afc952bc1cb53d6b61b80299329'
CI_IMAGE = 'sha256:0f9e791e36ce747a02b53827122e514277b0195ef2ec43e64d2b7eaaa0238ab2'
ARCHIVE_SHA256 = 'd0e9e46997df44e6fe5bcb614608672b7e3bec3a6ab8667f440583337f27a45a'
VERSION = (5, 7, 3)
FILES = ('manifest.json', 'image-inspect.json', 'SHA256SUMS', 'gallery-server-linux-amd64.tar.gz')


class Stop(Exception):
    pass


def need(value, code):
    if not value:
        raise Stop(code)


def load_module(name):
    path = Path(__file__).with_name(name + '.py')
    need(path.is_file() and not path.is_symlink(), 'VERIFIED_ADJACENT_HELPER_REQUIRED')
    spec = importlib.util.spec_from_file_location('hardened_' + name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def private(path, directory=False):
    st = path.lstat()
    need((stat.S_ISDIR(st.st_mode) if directory else stat.S_ISREG(st.st_mode)) and
         st.st_uid == os.getuid() and stat.S_IMODE(st.st_mode) == (0o700 if directory else 0o600),
         'OWNED_PRIVATE_REGULAR_PATH_REQUIRED')


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def extract_zip(path, destination):
    private(path)
    need(isinstance(CI_ARTIFACT, int) and CI_ARTIFACT > 0 and
         isinstance(ZIP_SHA256, str) and re.fullmatch('[0-9a-f]{64}', ZIP_SHA256),
         'COMPLETED_PINNED_CI_ARTIFACT_REQUIRED')
    # Hash and decode the same descriptor; a symlink/path replacement cannot
    # substitute another archive after the checksum check.
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), 'rb') as stream:
        before = os.fstat(stream.fileno())
        need(before.st_size <= 4 * 1024**3 and hashlib.file_digest(stream, 'sha256').hexdigest() == ZIP_SHA256,
             'PINNED_ROLLBACK_ZIP_MISMATCH')
        stream.seek(0)
        with zipfile.ZipFile(stream) as archive:
            entries = archive.infolist()
            need(len(entries) <= 1000 and len({entry.filename for entry in entries}) == len(entries),
                 'ZIP_DUPLICATE_OR_TOO_MANY_ENTRIES')
            for entry in entries:
                name = PurePosixPath(entry.filename)
                mode = entry.external_attr >> 16
                need(not name.is_absolute() and '..' not in name.parts and
                     stat.S_IFMT(mode) in (0, stat.S_IFREG, stat.S_IFDIR), 'ZIP_UNSAFE_PATH')
            for name in FILES:
                entry = archive.getinfo(name)
                limit = 4 * 1024**3 if name.endswith('.tar.gz') else 4 * 1024**2
                need(not entry.is_dir() and stat.S_IFMT(entry.external_attr >> 16) in (0, stat.S_IFREG) and
                     0 < entry.file_size <= limit, 'ZIP_MEMBER_SIZE_OR_TYPE')
                with archive.open(entry) as source, os.fdopen(os.open(destination / name,
                        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), 'wb') as out:
                    copied = 0
                    while chunk := source.read(1024 * 1024):
                        copied += len(chunk)
                        need(copied <= limit, 'ZIP_MEMBER_SIZE_LIMIT')
                        out.write(chunk)
                    need(copied == entry.file_size, 'ZIP_MEMBER_TRUNCATED')
                    out.flush()
                    os.fsync(out.fileno())
        after = os.fstat(stream.fileno())
        need((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
             (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns),
             'ZIP_CHANGED_DURING_VERIFICATION')


def artifact(directory):
    for name in FILES:
        private(directory / name)
    row = json.loads((directory / 'manifest.json').read_text())
    need((row.get('sourceCommit'), row.get('serverVersion'), row.get('mobileVersion'), row.get('mobileBuild'),
          row.get('platform'), row.get('imageTag')) ==
         (ROLLBACK_SOURCE, '5.7.3', '5.7.3', 10, 'linux/amd64', 'gallery-server:trash-' + ROLLBACK_SOURCE[:12]),
         'ROLLBACK_ARTIFACT_SOURCE_VERSION_PLATFORM')
    need(re.fullmatch(r'sha256:[0-9a-f]{64}', row.get('imageId', '')) and
         re.fullmatch('[0-9a-f]{64}', row.get('archiveSHA256', '')), 'ROLLBACK_ARTIFACT_DIGEST_REQUIRED')
    need(row['imageId'] == CI_IMAGE and row['archiveSHA256'] == ARCHIVE_SHA256,
         'PINNED_CI_IMAGE_OR_ARCHIVE_CHANGED')
    archive = directory / 'gallery-server-linux-amd64.tar.gz'
    need(sha(archive) == row['archiveSHA256'] and
         (directory / 'SHA256SUMS').read_text() == row['archiveSHA256'] + '  ' + archive.name + '\n',
         'ROLLBACK_ARCHIVE_OR_CHECKSUM_MISMATCH')
    image = json.loads((directory / 'image-inspect.json').read_text())
    need(isinstance(image, list) and len(image) == 1 and image[0]['Id'] == row['imageId'] and
         image[0].get('Architecture') == 'amd64' and image[0].get('Os') == 'linux', 'CI_IMAGE_INSPECTION_MISMATCH')
    need(row.get('isolatedSmoke', '').startswith('PASS: disposable lab migrations + HTTP Trash/Restore/consent/permanent deletion')
         and row.get('isolatedWorkerConfiguration') == 'API_AND_MICROSERVICES', 'COMPLETED_CI_SMOKE_REQUIRED')
    return row, archive


def archive_proof(identity, archive, manifest):
    # Reuse the streaming config/layer/descriptor proof, including both classic
    # and containerd image IDs. Never infer source from matching guard files.
    config = None
    with tarfile.open(archive, 'r|gz') as tar:
        for member in tar:
            if member.name == 'manifest.json':
                need(member.isfile() and member.size <= 4 * 1024**2, 'IMAGE_MANIFEST_SIZE_OR_TYPE')
                rows = json.load(tar.extractfile(member))
                need(isinstance(rows, list) and len(rows) == 1, 'ONE_IMAGE_REQUIRED')
                match = re.fullmatch(r'(?:blobs/sha256/([0-9a-f]{64})|([0-9a-f]{64})\.json)', rows[0].get('Config', ''))
                need(match, 'CONTENT_ADDRESSED_IMAGE_CONFIG_REQUIRED')
                config = 'sha256:' + (match[1] or match[2])
                break
    need(config, 'IMAGE_CONFIG_UNAVAILABLE')
    with archive.open('rb') as stream:
        proof = identity.scan(stream, config, manifest['imageTag'], manifest['imageId'])
    env = dict(value.split('=', 1) for value in proof['sourceConfig'].get('Env', []) if '=' in value)
    need(env.get('IMMICH_SOURCE_COMMIT') == ROLLBACK_SOURCE and env.get('IMMICH_SOURCE_REF') == 'v5.7.3' and
         env.get('IMMICH_REPOSITORY') == 'docice545/gallery', 'PACKAGED_ROLLBACK_SOURCE_MISMATCH')
    return config, proof


def prepare(args, core):
    phase = args.run_root / 'hardened-rollback'
    need(not phase.exists() and not phase.is_symlink(), 'KEEP_EXISTING_PHASE_USE_CHECK_OR_STATUS')
    old = core.inspect(core.SERVER)
    core.identity(old)
    need(old['Image'] == CURRENT and old['State'].get('Health', {}).get('Status') == 'healthy',
         'EXPECTED_HEALTHY_PRODUCTION_IMAGE_REQUIRED')
    core.probe_image(TARGET, SOURCE, VERSION)
    base, _ = core.compose_base(old)
    need(core.config_hash(base) == core.identity(old).get('com.docker.compose.config-hash'),
         'COMPOSE_DIFFERS_FROM_RUNNING_SERVER')
    core.workers(core.environment(old))
    phase.mkdir(mode=0o700)
    directory = phase / 'artifact'
    directory.mkdir(mode=0o700)
    extract_zip(args.artifact_zip, directory)
    manifest, archive = artifact(directory)
    identity = load_module('trash_image_identity')
    config, proof = archive_proof(identity, archive, manifest)
    found = core.docker('image', 'ls', '--no-trunc', '--quiet', '--filter', 'reference=' + manifest['imageTag']).split()
    need(len(found) <= 1, 'ROLLBACK_ALIAS_AMBIGUOUS')
    if found:
        item = json.loads(core.docker('image', 'inspect', manifest['imageTag']))[0]
        need(item['RootFS']['Layers'] == proof['layerDiffIds'] and
             core.environment(item).get('IMMICH_SOURCE_COMMIT') == ROLLBACK_SOURCE,
             'EXISTING_ALIAS_NOT_OUR_ROLLBACK_NO_OVERWRITE')
    else:
        core.run([*core.DOCKER, 'image', 'load', '-i', str(archive)], timeout=900)
    adapter = SimpleNamespace(DOCKER=core.DOCKER, IMAGE=config, TAG=manifest['imageTag'], SOURCE=ROLLBACK_SOURCE,
                              SOURCE_REF='v5.7.3', ARCHIVE_SHA=manifest['archiveSHA256'], docker=core.docker,
                              verify_artifact=lambda _: archive)
    loaded = identity.verify_loaded(adapter, directory)
    state = phase / 'image-state'
    state.mkdir(mode=0o700)
    plan_args = SimpleNamespace(state=state, image=TARGET, expected_current_image=CURRENT,
                               source_commit=SOURCE, server_version=VERSION, api=args.api,
                               rollback_image=loaded['loadedImageId'], rollback_source_commit=ROLLBACK_SOURCE,
                               rollback_server_version=VERSION)
    core.plan(plan_args)  # All original guard/migration/recovery/config checks, unchanged.
    receipt = core.private_json(state / 'image-plan.json')
    need(not receipt['migrationsAdded'], 'MIGRATIONS_REQUIRE_SEPARATE_BACKUP_AND_APPROVAL_WORKFLOW')
    backups = phase / 'compose-input-backups'
    backups.mkdir(mode=0o700)
    index = []
    for number, (path, expected) in enumerate(receipt['fileHashes'].items()):
        data = Path(path).read_bytes()
        need(hashlib.sha256(data).hexdigest() == expected, 'COMPOSE_CHANGED_BEFORE_BACKUP')
        name = f'input-{number}.backup'
        with os.fdopen(os.open(backups / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), 'wb') as out:
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
        index.append({'original': path, 'backup': name, 'sha256': expected})
    core.save(backups / 'index.json', index)
    core.save(phase / 'rollback-evidence.json', {'ciRun': CI_RUN, 'artifactId': CI_ARTIFACT, 'zipSHA256': ZIP_SHA256,
              'sourceCommit': ROLLBACK_SOURCE, 'identity': loaded, 'manifestSHA256': sha(directory / 'manifest.json'),
              'planSHA256': sha(state / 'image-plan.json'), 'previousSource': 'UNVERIFIED_NOT_SELECTED_FOR_ROLLBACK'})
    core.execute(SimpleNamespace(state=state, execute_approved=False), rollback=False)
    print('PASS hardened rollback loaded and full deployment preflight; production not changed')


def binding(root, core):
    phase = root / 'hardened-rollback'
    private(phase, True)
    private(phase / 'artifact', True)
    evidence = core.private_json(phase / 'rollback-evidence.json')
    manifest, _ = artifact(phase / 'artifact')
    state = phase / 'image-state'
    private(state, True)
    row = core.private_json(state / 'image-plan.json')
    need(evidence['ciRun'] == CI_RUN and evidence['artifactId'] == CI_ARTIFACT and evidence['zipSHA256'] == ZIP_SHA256 and
         evidence['sourceCommit'] == ROLLBACK_SOURCE and evidence['planSHA256'] == sha(state / 'image-plan.json') and
         evidence['manifestSHA256'] == sha(phase / 'artifact/manifest.json') and
         row['serverVersion'] == {'major': 5, 'minor': 7, 'patch': 3, 'prerelease': None} and
         row['rollbackVersion'] == row['serverVersion'] and row.get('configHashMode') == core.CONFIG_HASH_MODE and
         row['previousImage'] == CURRENT and row['candidateImage'] == TARGET and row['sourceCommit'] == SOURCE and
         row['rollbackSource'] == ROLLBACK_SOURCE and row['rollbackImage'] == evidence['identity']['loadedImageId'] and
         not row['migrationsAdded'] and evidence['identity']['archiveSHA256'] == manifest['archiveSHA256'],
         'PINNED_ROLLBACK_PLAN_OR_EVIDENCE_CHANGED')
    return state


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('prepare', 'check', 'apply', 'rollback', 'status'))
    parser.add_argument('--run-root', required=True, type=Path)
    parser.add_argument('--artifact-zip', type=Path)
    parser.add_argument('--api', default='http://127.0.0.1:2283/api')
    parser.add_argument('--sudo-docker', action='store_true')
    parser.add_argument('--execute-approved', action='store_true')
    args = parser.parse_args()
    os.umask(0o077)
    try:
        actor = pwd.getpwuid(os.getuid())
        root = args.run_root.absolute()
        need(actor.pw_name == 'doctoriceadm' and root.parent == Path(actor.pw_dir) and
             root.name.startswith('gallery-build10-release-'), 'EXISTING_DOCTORICEADM_RELEASE_ROOT_REQUIRED')
        private(root, True)
        args.run_root = root
        need(args.action != 'prepare' or (args.artifact_zip and not args.execute_approved),
             'PREPARE_REQUIRES_ZIP_AND_NEVER_DEPLOYS')
        need(not args.execute_approved or args.action in ('apply', 'rollback'), 'ONLY_APPLY_ROLLBACK_EXECUTE')
        for key in ('DOCKER_HOST', 'DOCKER_CONTEXT', 'DOCKER_TLS', 'DOCKER_TLS_VERIFY', 'DOCKER_CERT_PATH'):
            os.environ.pop(key, None)
        core = load_module('image_release')
        core.DOCKER = [*(['sudo', '-n'] if args.sudo_docker else []), 'docker', '--host=unix:///var/run/docker.sock']
        if args.action == 'prepare':
            prepare(args, core)
        else:
            state = binding(root, core)
            if args.action == 'status':
                for name in ('applied.json', 'rolled-back.json'):
                    if (state / name).exists():
                        row = core.private_json(state / name)
                        print('RECORDED_PASS', name, row['image'], row['completedAt'])
                need(not (state / 'rollback-attempt.json').exists() or (state / 'rolled-back.json').exists(),
                     'INCOMPLETE_ROLLBACK_NO_AUTOMATIC_RETRY')
                need(not (state / 'apply-attempt.json').exists() or (state / 'applied.json').exists() or
                     (state / 'rolled-back.json').exists(), 'INCOMPLETE_UPDATE_REVIEW_ROLLBACK')
                if not (state / 'apply-attempt.json').exists():
                    print('PLANNED_ONLY_NOT_DEPLOYED')
            else:
                core.execute(SimpleNamespace(state=state, execute_approved=args.execute_approved), args.action == 'rollback')
        return 0
    except Exception as error:
        print('STOP ' + (str(error) if isinstance(error, Stop) or error.__class__.__name__ in ('Stop', 'IdentityError')
                        else 'PRIVATE_FAILURE_DETAILS_OMITTED'), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
