#!/usr/bin/env python3
"""Assemble a checksummed compiled release from already verified artifacts."""
import argparse
import json
from pathlib import Path
import re
import shutil

import build11_artifacts as artifacts

TOOLS = ('gallery_entry.py', 'gallery_install.py', 'gallery-install.sh', 'gallery-upgrade.sh',
         'gallery-verify.sh', 'gallery-rollback.sh', 'build11_operator.py', 'build11_artifacts.py',
         'build11_restore_transition.py', 'candidate_restore.py', 'release_candidate.py', 'image_release.py',
         'trash_predeploy.py', 'trash_release.py', 'trash_image_identity.py', 'android_release.py',
         'android_sign_package.py', 'SignExistingApk.java', 'hp_build10_queued_delete.py',
         'hp_build10_queued_delete.mjs', 'hp_build10_rollback.py', 'hp_build10_rollback.sh',
         'build10-rollback-tooling.sha256')
DOCS = ('BUILD11-RELEASE-RUNBOOK.md', 'BUILD11-UPSTREAM-COMPATIBILITY.md', 'BUILD11-USER-MANUAL-RU.md', 'BUILD11-TEST-REPORT.md')


def assemble(args):
    profile = artifacts.load(args.profile, args.profile_sha256)
    compatibility = artifacts.pinned_json(args.compatibility, args.compatibility_sha256)
    artifacts.need(compatibility['candidateSource'] == profile['sourceCommit'] and
                   compatibility['candidateImage'] == profile['backend']['imageId'], 'SAME_CANDIDATE_COMPATIBILITY_REQUIRED')
    artifacts.need(not args.output.exists() and not args.output.is_symlink(), 'NEW_PACKAGE_OUTPUT_REQUIRED')
    paths = {'backend/gallery-server-linux-amd64.tar.gz': profile['backend']['archiveSHA256'],
             'android/app-release.apk': profile['android']['sha256'], 'ios/Photos-unsigned.ipa': profile['ios']['sha256']}
    for name, expected in paths.items():
        artifacts.need(artifacts.digest(args.artifacts / name) == expected, 'FROZEN_ARTIFACT_CHANGED')
    rollback_manifest = json.loads((args.rollback_artifacts / 'manifest.json').read_text())
    artifacts.need(rollback_manifest['sourceCommit'] == compatibility['rollbackSource'] and
                   rollback_manifest['imageId'] == compatibility['rollbackImage'] and
                   artifacts.digest(args.rollback_artifacts / 'gallery-server-linux-amd64.tar.gz') == rollback_manifest['archiveSHA256'],
                   'EXACT_ROLLBACK_ARTIFACT_REQUIRED')
    runtime_path = args.artifacts / 'backend/build11-rollback-runtime.json'
    artifacts.need(artifacts.digest(runtime_path) == compatibility['testReportSHA256'],
                   'REAL_ROLLBACK_RUNTIME_REPORT_REQUIRED')
    runtime = json.loads(runtime_path.read_text())
    checks = {'isolatedDatabase': True, 'oldRuntimeStartsOnUpgradedSchema': True,
              'storagePoliciesRejectedByRollback': True, 'trashRestoreAfterRollback': True,
              'syntheticMediaOnly': True, 'productionChanged': False}
    artifacts.need({field: runtime.get(field) for field in checks} == checks and
                   compatibility.get('rollbackTest') == checks and
                   runtime.get('sourceCommit') == profile['sourceCommit'] and
                   runtime.get('candidateImageId') == profile['backend']['imageId'] and
                   runtime.get('rollbackSourceCommit') == rollback_manifest['sourceCommit'] and
                   re.fullmatch('sha256:[0-9a-f]{64}', runtime.get('rollbackImageId', '')) and
                   runtime.get('rollbackArchiveSHA256') == rollback_manifest['archiveSHA256'],
                   'ROLLBACK_RUNTIME_IMAGE_SOURCE_OR_ACCEPTANCE_MISMATCH')
    if runtime['rollbackImageId'] != rollback_manifest['imageId']:
        mapping = compatibility.get('rollbackRuntimeImageIdentity', {})
        artifacts.need(mapping.get('configDigest') == rollback_manifest['imageId'] and
                       mapping.get('loadedImageId') == runtime['rollbackImageId'] and
                       mapping.get('identityKind') in ('MANIFEST_DIGEST', 'INDEX_DIGEST'),
                       'ROLLBACK_RUNTIME_DESCRIPTOR_MAPPING_REQUIRED')
        # Preserve the real backend receipt. Accept a containerd manifest/index
        # ID only after the same immutable archive proves its entire graph.
        with (args.rollback_artifacts / 'gallery-server-linux-amd64.tar.gz').open('rb') as file:
            identity = artifacts.identity.scan(file, rollback_manifest['imageId'], rollback_manifest['imageTag'],
                                               runtime['rollbackImageId'])
        artifacts.need(compatibility.get('rollbackRuntimeImageIdentity') ==
                       {key: identity[key] for key in ('configDigest', 'loadedImageId', 'identityKind')},
                       'VERIFIED_ROLLBACK_RUNTIME_DESCRIPTOR_MAPPING_REQUIRED')
    args.output.mkdir(mode=0o700)
    for name in paths:
        target = args.output / name; target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(args.artifacts / name, target)
    shutil.copyfile(args.artifacts / 'backend/manifest.json', args.output / 'backend/manifest.json')
    shutil.copyfile(runtime_path, args.output / 'backend/build11-rollback-runtime.json')
    (args.output / 'rollback').mkdir()
    for name in ('manifest.json', 'gallery-server-linux-amd64.tar.gz'):
        shutil.copyfile(args.rollback_artifacts / name, args.output / 'rollback' / name)
    shutil.copyfile(args.profile, args.output / 'candidate-profile.json')
    shutil.copyfile(args.compatibility, args.output / 'reviewed-compatibility.json')
    tool_root = Path(__file__).parent; (args.output / 'tools').mkdir()
    for name in TOOLS: shutil.copy2(tool_root / name, args.output / 'tools' / name)
    for relative in ('release/prepare_sidestore.py', 'release/ios_artifact.py', 'package_unsigned_ios.py', 'verify_ios_archive.py'):
        target = args.output / 'ios-tools' / relative; target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(artifacts.ROOT / 'mobile/scripts' / relative, target)
    (args.output / 'docs').mkdir()
    for name in DOCS: shutil.copyfile(artifacts.ROOT / 'docs' / name, args.output / 'docs' / name)
    (args.output / 'config').mkdir()
    shutil.copyfile(artifacts.ROOT / 'docker/docker-compose.yml', args.output / 'config/docker-compose.yml')
    config = {'schemaVersion': 1, 'sourceCommit': profile['sourceCommit'], 'version': artifacts.VERSION, 'build': artifacts.BUILD,
              'profileSHA256': artifacts.digest(args.output / 'candidate-profile.json'),
              'compatibilitySHA256': artifacts.digest(args.output / 'reviewed-compatibility.json'),
              'machineLearningImage': args.machine_learning_image,
              'machineLearningReference': getattr(args, 'machine_learning_reference', None),
              'signing': {'android': 'CI_DEBUG_OPERATOR_HP_SIGNING_REQUIRED', 'ios': 'UNSIGNED_SIDESTORE_REQUIRED'},
              'productionDeployment': 'NOT_EXECUTED', 'physicalAcceptance': 'NOT_TESTED'}
    (args.output / 'release-operator.json').write_text(json.dumps(config, indent=2) + '\n')
    entries = sorted(p for p in args.output.rglob('*') if p.is_file())
    (args.output / 'SHA256SUMS').write_text(''.join(artifacts.digest(p) + '  ' + p.relative_to(args.output).as_posix() + '\n' for p in entries))
    print('PASS compiled APK/IPA/server bytes packaged; no build, signing or deployment')
    print('PACKAGE=' + str(args.output)); print('SHA256SUMS_SHA256=' + artifacts.digest(args.output / 'SHA256SUMS'))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifacts', type=Path, required=True); parser.add_argument('--rollback-artifacts', type=Path, required=True)
    parser.add_argument('--profile', type=Path, required=True); parser.add_argument('--profile-sha256', required=True)
    parser.add_argument('--compatibility', type=Path, required=True); parser.add_argument('--compatibility-sha256', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--machine-learning-image', help='Verified immutable upstream ML ID; required for clean-install support')
    parser.add_argument('--machine-learning-reference', help='Verified registry name@sha256 digest for the same immutable ML image')
    args = parser.parse_args()
    if args.machine_learning_image is not None and not re.fullmatch('sha256:[0-9a-f]{64}', args.machine_learning_image):
        parser.error('machine-learning-image must be an immutable verified local ID')
    if args.machine_learning_reference is not None and (args.machine_learning_image is None or
            not re.fullmatch('ghcr.io/open-noodle/gallery-ml@sha256:[0-9a-f]{64}', args.machine_learning_reference)):
        parser.error('machine-learning-reference requires an immutable verified gallery-ml registry digest and image ID')
    assemble(args)
