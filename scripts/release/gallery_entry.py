#!/usr/bin/env python3
"""Binary-package entrypoint; verifies all package bytes before invoking tools."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess

REQUIRED_TOOLS = ('gallery_entry.py', 'gallery_install.py', 'gallery-install.sh', 'gallery-upgrade.sh',
                  'gallery-verify.sh', 'gallery-rollback.sh', 'build11_operator.py', 'build11_artifacts.py',
                  'build11_restore_transition.py', 'candidate_restore.py', 'release_candidate.py', 'image_release.py',
                  'trash_predeploy.py', 'trash_release.py', 'trash_image_identity.py', 'android_release.py',
                  'android_sign_package.py', 'SignExistingApk.java', 'hp_build10_queued_delete.py',
                  'hp_build10_queued_delete.mjs', 'hp_build10_rollback.py', 'hp_build10_rollback.sh',
                  'build10-rollback-tooling.sha256')


def need(value, code):
    if not value: raise ValueError(code)


def verify_package(package):
    need(package.is_dir() and not package.is_symlink(), 'REAL_RELEASE_PACKAGE_REQUIRED')
    sums = package / 'SHA256SUMS'
    need(sums.is_file() and not sums.is_symlink() and sums.stat().st_size <= 1024 * 1024, 'PACKAGE_CHECKSUM_MANIFEST_REQUIRED')
    records = {}
    for line in sums.read_text().splitlines():
        match = re.fullmatch(r'([0-9a-f]{64})  ([^\r\n]+)', line)
        need(match is not None, 'STRICT_PACKAGE_CHECKSUM_FORMAT')
        expected, name = match.groups(); path = PurePosixPath(name)
        need(not path.is_absolute() and '..' not in path.parts and name not in records and
             str(path) == name and name != 'SHA256SUMS', 'OWNED_UNIQUE_RELATIVE_PACKAGE_PATH_REQUIRED')
        target = package / name
        need(not any((package / Path(*path.parts[:i])).is_symlink() for i in range(1, len(path.parts) + 1)) and
             target.is_file(), 'PACKAGE_SYMLINK_OR_MISSING_FILE')
        with target.open('rb') as file: actual = hashlib.file_digest(file, 'sha256').hexdigest()
        need(actual == expected, 'RELEASE_PACKAGE_FILE_CHANGED')
        records[name] = expected
    need('release-operator.json' in records and 'candidate-profile.json' in records and
         'reviewed-compatibility.json' in records, 'COMPLETE_RELEASE_OPERATOR_PACKAGE_REQUIRED')
    required = {'tools/' + name for name in REQUIRED_TOOLS} | {
        'backend/manifest.json', 'backend/build11-rollback-runtime.json', 'backend/gallery-server-linux-amd64.tar.gz', 'android/app-release.apk',
        'ios/Photos-unsigned.ipa', 'rollback/manifest.json', 'rollback/gallery-server-linux-amd64.tar.gz',
        'config/docker-compose.yml', 'docs/BUILD11-RELEASE-RUNBOOK.md',
        'docs/BUILD11-UPSTREAM-COMPATIBILITY.md', 'docs/BUILD11-USER-MANUAL-RU.md',
        'ios-tools/release/prepare_sidestore.py', 'ios-tools/release/ios_artifact.py',
        'ios-tools/package_unsigned_ios.py', 'ios-tools/verify_ios_archive.py'}
    need(required <= records.keys() and
         not any(p.is_symlink() for p in package.rglob('*')) and
         {p.relative_to(package).as_posix() for p in package.rglob('*') if p.is_file() and p.name != 'SHA256SUMS'} == set(records),
         'ALL_EXECUTABLE_TOOLS_AND_ARTIFACTS_MUST_BE_CHECKSUMMED')
    config = json.loads((package / 'release-operator.json').read_text())
    need(config.get('schemaVersion') == 1 and config.get('profileSHA256') == records['candidate-profile.json'] and
         config.get('compatibilitySHA256') == records['reviewed-compatibility.json'], 'PINNED_PACKAGE_PROFILE_REQUIRED')
    profile = json.loads((package / 'candidate-profile.json').read_text())
    need(config.get('sourceCommit') == profile.get('sourceCommit') and
         (config.get('version'), config.get('build')) == (profile.get('mobileVersion'), profile.get('mobileBuild')),
         'PACKAGE_OPERATOR_SOURCE_VERSION_MISMATCH')
    compatibility = json.loads((package / 'reviewed-compatibility.json').read_text())
    need(compatibility.get('testReportSHA256') == records['backend/build11-rollback-runtime.json'],
         'PINNED_ROLLBACK_RUNTIME_REPORT_REQUIRED')
    return config


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('prepare', 'check', 'apply', 'upgrade', 'status', 'rollback', 'install'))
    parser.add_argument('package', type=Path); parser.add_argument('state', type=Path)
    parser.add_argument('previous_run_root', type=Path); parser.add_argument('nas_evidence', type=Path)
    parser.add_argument('--execute-approved', action='store_true'); parser.add_argument('--approve-migration', action='store_true')
    parser.add_argument('--complete-confirmed-cleanup', action='store_true')
    args = parser.parse_args()
    try:
        config = verify_package(args.package)
        need(args.action != 'install', 'CLEAN_INSTALL_REQUIRES_REVIEWED_UPSTREAM_CONFIG_USE_INSTALL_SCRIPT')
        command = ['python3', '-B', str(args.package / 'tools/build11_operator.py'), args.action,
                   '--profile', str(args.package / 'candidate-profile.json'), '--profile-sha256', config['profileSHA256'],
                   '--compatibility-receipt', str(args.package / 'reviewed-compatibility.json'),
                   '--compatibility-sha256', config['compatibilitySHA256'], '--artifacts', str(args.package),
                   '--rollback-artifacts', str(args.package / 'rollback'), '--state', str(args.state),
                   '--previous-run-root', str(args.previous_run_root), '--nas-evidence', str(args.nas_evidence)]
        if args.execute_approved: command.append('--execute-approved')
        if args.approve_migration: command.append('--approve-migration')
        if args.complete_confirmed_cleanup: command.append('--complete-confirmed-cleanup')
        return subprocess.run(command).returncode
    except Exception as error:
        code = str(error) if isinstance(error, ValueError) and re.fullmatch('[A-Z0-9_]+', str(error)) else 'PACKAGE_VALIDATION_FAILED_PRIVATE_DETAILS_OMITTED'
        print('STOP ' + code); return 1


if __name__ == '__main__': raise SystemExit(main())
