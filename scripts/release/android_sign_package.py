#!/usr/bin/env python3
"""HP-only existing-key signing of a sealed Build 11 APK; never compiles or installs."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import shutil
import tempfile

import android_release as android


def need(value, message):
    if not value:
        raise android.ReleaseError(message)


def private(path, directory=False):
    info = path.lstat()
    need((stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)) and
         info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == (0o700 if directory else 0o600),
         'existing signing/output paths must be owned and private; nothing chmodded')


def key_stats(directory):
    result = []
    for name in ('key.jks', 'key.properties'):
        path = directory / name
        private(path)
        info = path.stat()
        need(info.st_size > 0, 'existing nonempty keys required; no keys created')
        result.append((info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns))
    return result


def receipt(profile, profile_sha, metadata):
    return {'schemaVersion': 1, 'sourceCommit': profile['sourceCommit'],
            'profileSHA256': profile_sha, 'inputSHA256': profile['android']['sha256'],
            'ciRun': profile['android']['run'], 'deliveryMode': 'existing-hp-key-no-rebuild', **metadata}


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def sign(profile, profile_sha, source, directory, output, env):
    """Pin a private input snapshot; Java never reopens the caller's mutable APK."""
    need(source.is_file() and not source.is_symlink() and android.digest(source) == profile['android']['sha256'],
         'input APK differs from sealed successful CI artifact; nothing signed')
    need((profile['mobileVersion'], profile['mobileBuild']) == ('5.7.3', 11), 'exact Build 11 required')
    output = output.absolute()
    private(output.parent, directory=True)
    if not output.exists():
        output.mkdir(mode=0o700)
    private(output, directory=True)
    with tempfile.TemporaryDirectory(prefix='.ci-input-', dir=output) as temporary:
        verified = Path(temporary) / 'input.apk'
        with os.fdopen(os.open(source, os.O_RDONLY | os.O_NOFOLLOW), 'rb') as src:
            need(stat.S_ISREG(os.fstat(src.fileno()).st_mode), 'regular input APK required')
            with os.fdopen(os.open(verified, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as dst:
                shutil.copyfileobj(src, dst, 1024 * 1024)
                dst.flush()
                os.fsync(dst.fileno())
        need(android.digest(verified) == profile['android']['sha256'], 'input APK changed while staging; nothing signed')
        return sign_verified(profile, profile_sha, verified, directory, output, env)


def sign_verified(profile, profile_sha, source, directory, output, env):
    sdk = android.sdk_path(env)
    cwd = output
    version, build = profile['mobileVersion'], profile['mobileBuild']
    android.apk_metadata(source, sdk, cwd, version, build, profile['android']['certificateSHA256'])
    payload = android.apk_payload(source)
    need(android.digest(source) == profile['android']['sha256'], 'input APK changed during validation; nothing signed')
    apk, report = output / 'Foto.apk', output / 'android-signed.json'
    with os.fdopen(os.open(output / '.sign.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600), 'w') as lock:
        private(output / '.sign.lock')
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if apk.exists():
            private(apk)
            metadata = android.apk_metadata(apk, sdk, cwd, version, build)
            need(android.apk_payload(apk) == payload, 'existing signed APK payload differs; nothing overwritten')
        else:
            need(not report.exists(), 'signed receipt without APK; nothing overwritten')
            before = key_stats(directory)
            java = Path(env.get('JAVA_HOME', '')) / 'bin/java'
            need(java.is_file() and re.search(r'version "17\.', android.run([str(java), '-version'], cwd, env)),
                 'existing JDK 17 required; no installation performed')
            with tempfile.TemporaryDirectory(prefix='.sign-', dir=output) as temporary:
                staged = Path(temporary) / 'Foto.apk'
                android.run([str(java), str(Path(__file__).with_name('SignExistingApk.java')),
                             str(directory), str(sdk / f'build-tools/{android.BUILD_TOOLS}/apksigner'),
                             str(source.absolute()), str(staged)], cwd, env)
                need(key_stats(directory) == before, 'signing key metadata changed; output rejected')
                metadata = android.apk_metadata(staged, sdk, cwd, version, build)
                need(android.apk_payload(staged) == payload, 'signing changed application payload; output rejected')
                android.run([str(sdk / f'build-tools/{android.BUILD_TOOLS}/zipalign'), '-c', '-P', '16', '4', str(staged)], cwd, env)
                staged.chmod(0o600)
                os.link(staged, apk)  # Atomic no-clobber publication, including a concurrent uncooperative writer.
                staged.unlink()
                sync_directory(output)
        android.run([str(sdk / f'build-tools/{android.BUILD_TOOLS}/zipalign'), '-c', '-P', '16', '4', str(apk)], cwd, env)
        expected = receipt(profile, profile_sha, metadata)
        if report.exists():
            private(report)
            need(json.loads(report.read_text()) == expected, 'signed receipt mismatch; nothing overwritten')
        else:
            with tempfile.TemporaryDirectory(prefix='.receipt-', dir=output) as temporary:
                staged_report = Path(temporary) / 'android-signed.json'
                with os.fdopen(os.open(staged_report, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), 'w') as handle:
                    json.dump(expected, handle, indent=2)
                    handle.write('\n')
                    handle.flush()
                    os.fsync(handle.fileno())
                os.link(staged_report, report)
                staged_report.unlink()
                sync_directory(output)
        print('PASS existing HP certificate and unchanged Build 11 APK payload')
        print('APK ' + str(apk))
        print('SHA256 ' + metadata['apk_sha256'])
        print('CERTIFICATE_SHA256 ' + android.CERTIFICATE_SHA256)
        print('NOT INSTALLED; existing application data remains unchanged')
    return expected


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', type=Path, required=True)
    parser.add_argument('--profile-sha256', required=True)
    parser.add_argument('--input-apk', type=Path, required=True)
    parser.add_argument('--android-directory', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--authorize-production-signing', action='store_true')
    args = parser.parse_args(argv)
    os.umask(0o077)
    try:
        need(args.authorize_production_signing, 'explicit production signing approval required; keys not accessed')
        import build11_artifacts
        profile = build11_artifacts.load(args.profile, args.profile_sha256)
        sign(profile, args.profile_sha256, args.input_apk, args.android_directory, args.output, os.environ.copy())
        return 0
    except (android.ReleaseError, OSError, ValueError, KeyError):
        # Inputs or tools may contain credential/media paths. Never print arbitrary errors.
        print('FAIL signing prerequisites or immutable verification; no installation or key changes requested')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
