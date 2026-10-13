#!/usr/bin/env python3
"""Seal Build11 existing CI artifacts; no signing, builds, imports or deployment."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

import android_release as android
import trash_image_identity as identity

BASE = 'ea51a8acdc6f18ab5917c19b6f3833d740b4e9ba'
VERSION = '5.7.3'
BUILD = 11
ROOT = Path(__file__).resolve().parents[2]
APPLICATION_INPUTS = ('server', 'mobile', 'web', 'packages', 'i18n', 'branding', 'package.json', 'pnpm-lock.yaml',
                      'pnpm-workspace.yaml', '.pnpmfile.cjs', 'patches', '.dockerignore')


def need(value, code):
    if not value: raise ValueError(code)


def digest(path):
    need(path.is_file() and not path.is_symlink(), 'REAL_ARTIFACT_REQUIRED')
    with path.open('rb') as file: return hashlib.file_digest(file, 'sha256').hexdigest()


def validate(profile):
    need(profile.get('schemaVersion') == 3 and profile.get('productionBase') == BASE and
         (profile.get('serverVersion'), profile.get('mobileVersion'), profile.get('mobileBuild')) ==
         (VERSION, VERSION, BUILD), 'BUILD11_PROFILE_VERSION_BASE_REQUIRED')
    source = profile.get('sourceCommit', '')
    need(re.fullmatch('[0-9a-f]{40}', source), 'EXACT_SOURCE_REQUIRED')
    backend = profile.get('backend', {})
    need(backend.get('sourceCommit') == source and backend.get('serverVersion') == VERSION and
         backend.get('mobileVersion') == VERSION and backend.get('mobileBuild') == BUILD and
         backend.get('platform') == 'linux/amd64' and backend.get('deployment') == 'NOT_DEPLOYED' and
         re.fullmatch('sha256:[0-9a-f]{64}', backend.get('imageId', '')) and
         re.fullmatch('[0-9a-f]{64}', backend.get('archiveSHA256', '')) and
         backend.get('imageTag') == 'gallery-server:trash-' + source[:12], 'BUILD11_BACKEND_PROVENANCE')
    for platform in ('android', 'ios'):
        item = profile.get(platform, {})
        need(item.get('sourceCommit') == source and type(item.get('run')) is int and item['run'] > 0 and
             type(item.get('artifactId')) is int and item['artifactId'] > 0 and
             re.fullmatch('[0-9a-f]{64}', item.get('sha256', '')), 'BUILD11_MOBILE_PROVENANCE')
    need(re.fullmatch('[0-9a-f]{64}', profile['android'].get('certificateSHA256', '')) and
         profile['android']['certificateSHA256'] != android.CERTIFICATE_SHA256,
         'CI_ARTIFACT_NOT_HP_PRODUCTION_SIGNED')
    need(type(profile.get('backendRun')) is int and profile['backendRun'] > 0 and
         type(profile.get('backendArtifactId')) is int and profile['backendArtifactId'] > 0,
         'BUILD11_BACKEND_RUN_PROVENANCE')
    return profile


def load(path, expected):
    return validate(pinned_json(path, expected))


def pinned_json(path, expected):
    need(path is not None and re.fullmatch('[0-9a-f]{64}', expected or ''), 'PINNED_BUILD11_PROFILE_REQUIRED')
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), 'rb') as file:
        need(os.fstat(file.fileno()).st_size <= 1024 * 1024, 'PROFILE_SIZE_LIMIT')
        raw = file.read(1024 * 1024 + 1)
    need(len(raw) <= 1024 * 1024 and hashlib.sha256(raw).hexdigest() == expected, 'PINNED_BUILD11_PROFILE_REQUIRED')
    return json.loads(raw)


def gh(endpoint):
    return json.loads(subprocess.check_output(['gh', 'api', endpoint], text=True))


def verify_backend_source(row, source, backend=None):
    tooling = row.get('head_sha', '')
    need(re.fullmatch('[0-9a-f]{40}', tooling), 'EXACT_BACKEND_TOOLING_SOURCE_REQUIRED')
    if tooling != source:
        # Harness-only corrections may be built from a reviewed descendant.
        # The immutable application revision is still git-archived by the
        # existing server builder. Verify ancestry and ALL application inputs,
        # then require the downloaded manifest to name that exact workflow HEAD.
        for command in (['git', '-C', str(ROOT), 'merge-base', '--is-ancestor', source, tooling],
                        ['git', '-C', str(ROOT), 'diff', '--exit-code', source, tooling, '--', *APPLICATION_INPUTS]):
            result = subprocess.run(command, capture_output=True, check=False)
            need(result.returncode == 0, 'BACKEND_TOOLING_ONLY_IDENTICAL_APPLICATION_INPUTS_REQUIRED')
    if backend is not None:
        need(backend.get('sourceCommit') == source and backend.get('toolingCommit') == tooling,
             'EXACT_BACKEND_SOURCE_AND_TOOLING_MANIFEST_REQUIRED')
    return tooling


def seal(directory, source, runs, output):
    need(re.fullmatch('[0-9a-f]{40}', source) and not output.exists() and not output.is_symlink(), 'NEW_PROFILE_AND_EXACT_SOURCE')
    backend = json.loads((directory / 'backend/manifest.json').read_text())
    artifact_ids = {}
    for platform, run in zip(('backend', 'android', 'ios'), runs, strict=True):
        row = gh(f'repos/docice545/gallery/actions/runs/{run}')
        need(row['status'] == 'completed' and row['conclusion'] == 'success', 'SUCCESSFUL_CI_REQUIRED')
        expected = 'gallery-trash-server-build.yml' if platform == 'backend' else 'gallery-build-mobile.yml'
        need(row['path'].endswith('/' + expected), 'EXISTING_WORKFLOW_REQUIRED')
        if platform == 'backend':
            verify_backend_source(row, source, backend)
        else:
            need(row['head_sha'] == source, 'SAME_EXACT_APPLICATION_SOURCE_REQUIRED')
        items = gh(f'repos/docice545/gallery/actions/runs/{run}/artifacts')['artifacts']
        name = {'backend': 'gallery-trash-server-linux-amd64', 'android': 'android-media-pilot-validation-apk',
                'ios': 'ios-unsigned-ipa'}[platform]
        matches = [item for item in items if item['name'] == name and not item['expired']]
        need(len(matches) == 1, 'EXACT_DOWNLOADABLE_ARTIFACT_REQUIRED')
        artifact_ids[platform] = matches[0]['id']
    archive = directory / 'backend/gallery-server-linux-amd64.tar.gz'
    need(digest(archive) == backend['archiveSHA256'], 'BACKEND_ARCHIVE_CHECKSUM')
    with archive.open('rb') as file: proof = identity.scan(file, backend['imageId'], backend['imageTag'])
    env = dict(value.split('=', 1) for value in proof['sourceConfig'].get('Env', []) if '=' in value)
    need(env.get('IMMICH_SOURCE_COMMIT') == source and env.get('IMMICH_REPOSITORY') == 'docice545/gallery',
         'PACKAGED_SERVER_SOURCE_REQUIRED')
    apk = directory / 'android/app-release.apk'
    sdk = android.sdk_path(__import__('os').environ)
    signature = android.run([str(sdk / 'build-tools/36.0.0/apksigner'), 'verify', '--print-certs', str(apk)], ROOT)
    certificates = re.findall(r'^Signer #\d+ certificate SHA-256 digest:\s*([0-9a-fA-F:]+)\s*$', signature, re.MULTILINE)
    need(len(certificates) == 1, 'SINGLE_CI_SIGNER_REQUIRED')
    certificate = certificates[0].lower().replace(':', '')
    android.apk_metadata(apk, sdk, ROOT, VERSION, BUILD, certificate)
    android.run([str(sdk / 'build-tools/36.0.0/zipalign'), '-c', '-P', '16', '4', str(apk)], ROOT)
    spec = importlib.util.spec_from_file_location('build11_ipa', ROOT / 'mobile/scripts/release/ios_artifact.py')
    ios = importlib.util.module_from_spec(spec); spec.loader.exec_module(ios)
    ipa = directory / 'ios/Photos-unsigned.ipa'
    with tempfile.TemporaryDirectory() as temporary:
        staging = Path(temporary) / 'Runner.xcarchive'; ios.extract_ipa(ipa, staging)
        ios.verify_ipa_archive(staging, version=VERSION, build=str(BUILD))
    profile = dict(schemaVersion=3, productionBase=BASE, sourceCommit=source, serverVersion=VERSION,
                   mobileVersion=VERSION, mobileBuild=BUILD, backend=backend, backendRun=runs[0],
                   backendArtifactId=artifact_ids['backend'],
                   android=dict(sourceCommit=source, run=runs[1], artifactId=artifact_ids['android'], sha256=digest(apk),
                                certificateSHA256=certificate, signing='CI_DEBUG_NOT_HP_UPDATE'),
                   ios=dict(sourceCommit=source, run=runs[2], artifactId=artifact_ids['ios'], sha256=digest(ipa),
                            signing='UNSIGNED_SIDESTORE_REQUIRED'))
    validate(profile)
    with output.open('x') as file: file.write(json.dumps(profile, indent=2) + '\n')
    print('PASS same source, complete image layer integrity, APK metadata/signature and unsigned IPA extensions')
    print('BUILD11_PROFILE_SHA256=' + digest(output))
    return profile


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifacts', type=Path); parser.add_argument('source')
    parser.add_argument('backend_run', type=int); parser.add_argument('android_run', type=int); parser.add_argument('ios_run', type=int)
    parser.add_argument('new_profile', type=Path)
    args = parser.parse_args()
    seal(args.artifacts, args.source, [args.backend_run, args.android_run, args.ios_run], args.new_profile)
