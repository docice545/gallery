#!/usr/bin/env python3
"""Verify and package existing artifacts only; never builds/signs/deploys."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import tempfile

import android_release as android
import trash_image_identity as identity
import trash_release as release

ROOT = Path(__file__).resolve().parents[2]


def verify(root, output, candidate=None):
    if output.exists() or output.is_symlink():
        raise ValueError('new release output required; frozen artifacts never overwritten')
    output.mkdir(mode=0o700)
    if candidate is not None:
        import release_candidate
        release_candidate.configure(release, candidate)
    proof = identity.verify_loaded(release, root / 'backend')
    build = candidate['mobileBuild'] if candidate else 8
    android_hash = candidate['android']['sha256'] if candidate else android.CI_APK_SHA256
    android_certificate = candidate['android']['certificateSHA256'] if candidate else android.CI_CERTIFICATE_SHA256
    apk = root / 'android/app-release.apk'
    if android.digest(apk) != android_hash:
        raise ValueError('frozen APK differs')
    apk_metadata = android.apk_metadata(apk, android.sdk_path(os.environ), ROOT, '5.7.2', build, android_certificate)
    android.run([str(android.sdk_path(os.environ) / 'build-tools/36.0.0/zipalign'), '-c', '-P', '16', '4', str(apk)], ROOT)
    spec = importlib.util.spec_from_file_location('ios_artifact', ROOT / 'mobile/scripts/release/ios_artifact.py')
    ios = importlib.util.module_from_spec(spec); spec.loader.exec_module(ios)
    ipa = root / 'ios/Photos-unsigned.ipa'
    if ios.sha256(ipa) != (candidate['ios']['sha256'] if candidate else '4abfdbd7007c5f72d85fbb2cc8b35c20891c7342d2c9e6cba85c23792278a6bd'):
        raise ValueError('frozen IPA differs')
    with tempfile.TemporaryDirectory() as temporary:
        archive = Path(temporary) / 'Runner.xcarchive'
        app = ios.extract_ipa(ipa, archive)
        ios.verify_ipa_archive(archive, version='5.7.2', build=str(build))
        bundles = [{key: plistlib.loads((bundle / 'Info.plist').read_bytes())[key] for key in
                   ('CFBundleIdentifier', 'CFBundleDisplayName', 'CFBundleShortVersionString', 'CFBundleVersion', 'MinimumOSVersion', 'AppGroupId')}
                   for bundle in ios.bundles(app)]
    manifest = {'schemaVersion': 1, 'applicationSource': release.SOURCE, 'serverVersion': '5.7.2' if candidate else '5.7.1',
                'mobileVersion': '5.7.2', 'mobileBuild': build, 'imageProof': proof,
                'android': apk_metadata, 'ios': {'signed': False, 'bundles': bundles},
                'ciRun': os.environ.get('GITHUB_RUN_ID'), 'deployment': 'NOT_DEPLOYED',
                'releaseVerdict': 'RELEASE_READY_WITH_OPERATOR_GATES' if candidate else 'BLOCKED_PENDING_NEW_DELETION_CONTRACT_AND_PHYSICAL_ACCEPTANCE',
                'artifacts': [
                    {'path': 'backend/gallery-server-linux-amd64.tar.gz', 'run': candidate['backendRun'] if candidate else 37953392247, 'artifactId': candidate['backendArtifactId'] if candidate else 11626603468, 'sha256': release.ARCHIVE_SHA},
                    {'path': 'android/app-release.apk', 'run': candidate['android']['run'] if candidate else 37944044747, 'artifactId': candidate['android']['artifactId'] if candidate else 11624073289, 'sha256': android_hash, 'signing': 'CI_DEBUG_NOT_HP_UPDATE'},
                    {'path': 'ios/Photos-unsigned.ipa', 'run': candidate['ios']['run'] if candidate else 37936380827, 'artifactId': candidate['ios']['artifactId'] if candidate else 11618922989, 'sha256': ios.sha256(ipa), 'signing': 'UNSIGNED_SIDESTORE_REQUIRED'},
                ]}
    for item in manifest['artifacts']:
        target = output / item['path']; target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / item['path'], target)
    shutil.copyfile(root / 'backend/manifest.json', output / 'backend/manifest.json')
    tooling = output / 'tooling'; tooling.mkdir()
    for name in ('trash_predeploy.py', 'trash_image_identity.py', 'trash_release.py', 'trash_execute.sh',
                 'android_release.py', 'SignExistingApk.java', 'TRASH_PREDEPLOY.md', 'release_candidate.py', 'rollback_bridge.py', 'candidate_restore.py', 'authorize_library.py'):
        shutil.copy2(Path(__file__).parent / name, tooling / name)
    for relative in ('release/prepare_sidestore.py','release/ios_artifact.py',
                     'package_unsigned_ios.py','verify_ios_archive.py'):
        target=tooling/'ios'/relative
        target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(ROOT/'mobile/scripts'/relative,target)
    if candidate:
        (output / 'candidate-profile.json').write_text(json.dumps(candidate, indent=2) + '\n')
    for name in ('RELEASE_RUNBOOK.md', 'GALLERY_BUILD9_ACCEPTANCE.md' if candidate else 'GALLERY_BUILD8_ACCEPTANCE.md'):
        shutil.copyfile(ROOT / 'docs' / name, output / name)
    (output / 'release-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    entries = sorted(p for p in output.rglob('*') if p.is_file())
    (output / 'SHA256SUMS').write_text(''.join(release.digest(p) + '  ' + str(p.relative_to(output)) + '\n' for p in entries))
    print('PASS frozen archive/APK/IPA bytes, config/layers and bundle metadata; no rebuild/sign/deploy')
    print(json.dumps(manifest, sort_keys=True))
    # Public artifact digests/provenance only, readable via Checks API without
    # downloading a multi-GB archive or exposing any operator recovery evidence.
    public=json.dumps(manifest,sort_keys=True).replace('%','%25').replace('\r','%0D').replace('\n','%0A')
    print('::notice title=Release manifest::' + public)
    print('::notice title=Release manifest SHA256::' + release.digest(output/'release-manifest.json'))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifacts', type=Path)
    parser.add_argument('new_output', type=Path)
    parser.add_argument('--candidate-profile', type=Path)
    parser.add_argument('--candidate-profile-sha256')
    args = parser.parse_args()
    try:
        candidate = None
        if args.candidate_profile is not None or args.candidate_profile_sha256 is not None:
            import release_candidate
            candidate = release_candidate.load(args.candidate_profile, args.candidate_profile_sha256)
        verify(args.artifacts, args.new_output, candidate)
    except Exception as error:
        # This runner handles only public frozen artifacts, never user media or
        # credentials. Emit a bounded annotation so API-only diagnostics work.
        message = f'{type(error).__name__}: {error}'[:400]
        message = message.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
        print('::error title=Frozen artifact proof::' + message)
        raise SystemExit(1) from None
