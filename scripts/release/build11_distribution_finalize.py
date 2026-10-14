#!/usr/bin/env python3
"""Seal genuine isolated installer/upgrade/rollback evidence into the CI package.

The lab verifies the provisional compiled package first. Its unchanged checksum
manifest is retained so the final package can contain the report without a
circular hash. Production recovery and physical devices remain operator gates.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil

import build11_artifacts as artifacts
from gallery_entry import verify_package

MARKER = 'BUILD11_DISPOSABLE_COMPILED_PACKAGE_LAB_NOT_HP_VALIDATION'
UPSTREAM = 'da5480ae42b77db9cae729f2447ec9b3079ba4a7'
CHECKS = ('cleanInstallation', 'configurationInterruptionResume', 'serviceStartInterruptionResume',
          'idempotentCompletedInstall', 'representativeBuild10Upgrade', 'additiveMigrationExecuted',
          'existingDataPreserved', 'offlineIndexTombstonePreserved', 'all27PausedJobBytesAndOrderPreserved',
          'sixSyntheticLegacyOriginalsPreserved', 'storageMountsNetworksEnvironmentPreserved',
          'unrelatedServicesPreserved', 'rollbackAfterInjectedFailure', 'rollbackTrashRestore',
          'oldRuntimeRejectsStorageGrants', 'interruptedAttemptReplayPrevented', 'bulkTrashRestore',
          'originalTimelineDatesPreserved', 'managedRevocationAndBulkPermanentDelete', 'otherOwnerIsolated',
          'managedOriginalsPhysicallyRemoved', 'thumbnailPreviewActualFilesAndHttp',
          'externalDefaultReadOnlyProtected', 'explicitOwnerWritableExternalPhysicalDelete',
          'externalRescanTombstoneGate', 'mixedScopePreflightNoPartialDeletion', 'emptyTrashMixedScopesPhysicalDeletion',
          'freshInstallRollbackWithPackagedWrapper', 'idempotentFreshRollback', 'apiAndMicroservicesPreserved',
          'alreadyUpgradedFreshBackupRestore')
GATES = ('hpRecoveryEvidenceVerified', 'productionNfsVerified', 'physicalAndroidIosVerified', 'hpSixLegacyCleanupExecuted')


def finalize(args):
    artifacts.need(os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('GALLERY_ISOLATED_CI') == '1',
                   'DISPOSABLE_GITHUB_ACTIONS_FINALIZATION_ONLY')
    config = verify_package(args.package)
    input_sums = args.package / 'SHA256SUMS'
    input_digest = artifacts.digest(input_sums)
    report_sha = artifacts.digest(args.installation_report)
    report = artifacts.pinned_json(args.installation_report, report_sha)
    artifacts.need(type(report.get('schemaVersion')) is int and report['schemaVersion'] == 1 and
                   report.get('marker') == MARKER and report.get('result') == 'PASS' and
                   report.get('sourceCommit') == config['sourceCommit'] and
                   report.get('packageSHA256') == input_digest and
                   report.get('cleanupErrors') == [] and
                   report.get('syntheticMediaOnly') is True and report.get('productionChanged') is False and
                   all(report.get(gate) is False for gate in GATES) and
                   all(report.get('checks', {}).get(check) is True for check in CHECKS),
                   'ACTUAL_ALL_REQUIRED_ISOLATED_INSTALLATION_CHECKS_MUST_PASS')
    artifacts.need(report.get('installationEngine') == 'PACKAGED_GALLERY_INSTALL' and
                   report.get('upgradeEngine') == 'PACKAGED_IMAGE_RELEASE_WITH_REAL_READ_ONLY_LAB_QUEUE_GATE' and
                   report.get('hpWrapper') == 'NOT_TESTED_HP_RECOVERY_AND_OLD_SIX_REQUIRED',
                   'EXACT_TESTED_INSTALLATION_ENGINE_AND_HP_LIMITATIONS_REQUIRED')
    upstream_sha = artifacts.digest(args.upstream_report)
    upstream = artifacts.pinned_json(args.upstream_report, upstream_sha)
    artifacts.need(upstream.get('status') == 'PASS' and upstream.get('upstreamURL') == 'https://github.com/open-noodle/gallery' and
                   upstream.get('upstreamBase') == UPSTREAM and upstream.get('api', {}).get('status') == 'PASS' and
                   upstream.get('migrations', {}).get('status') == 'PASS' and upstream.get('workingTreeDirty') is False and
                   re.fullmatch('[0-9a-f]{40}', upstream.get('candidateHead', '')),
                   'GENUINE_PINNED_UPSTREAM_STRUCTURAL_REPORT_REQUIRED')
    artifacts.need(args.release_notes.is_file() and not args.release_notes.is_symlink() and
                   args.release_notes.stat().st_size <= 1024 * 1024, 'RELEASE_NOTES_REQUIRED')
    validation = args.package / 'validation'
    artifacts.need(not validation.exists() and not validation.is_symlink() and
                   not (args.package / 'docs/BUILD11-RELEASE-NOTES.md').exists(), 'NEW_VALIDATION_OUTPUT_REQUIRED')
    validation.mkdir(mode=0o700)
    shutil.copyfile(input_sums, validation / 'installation-lab-input-SHA256SUMS')
    shutil.copyfile(args.installation_report, validation / 'installation-lab.json')
    shutil.copyfile(args.upstream_report, validation / 'upstream-compatibility.json')
    shutil.copyfile(args.release_notes, args.package / 'docs/BUILD11-RELEASE-NOTES.md')
    config['installationValidation'] = {'reportSHA256': report_sha, 'inputChecksumManifestSHA256': input_digest,
                                        'upstreamReportSHA256': upstream_sha,
                                        'status': 'ACTUAL_ISOLATED_PASS_HP_AND_DEVICES_NOT_TESTED'}
    (args.package / 'release-operator.json').write_text(json.dumps(config, indent=2) + '\n')
    entries = sorted(p for p in args.package.rglob('*') if p.is_file() and p != input_sums)
    input_sums.write_text(''.join(artifacts.digest(p) + '  ' + p.relative_to(args.package).as_posix() + '\n' for p in entries))
    verify_package(args.package)
    print('PASS genuine compiled clean-install/upgrade/rollback report and upstream report sealed')
    print('FINAL_SHA256SUMS_SHA256=' + artifacts.digest(input_sums))
    print('OPERATOR_GATES=HP_BACKUP_NFS_OLD_SIX_QUEUE_SIGNING_S23_IPHONE_NOT_EXECUTED')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package', type=Path)
    parser.add_argument('--installation-report', type=Path, required=True)
    parser.add_argument('--upstream-report', type=Path, required=True)
    parser.add_argument('--release-notes', type=Path, required=True)
    finalize(parser.parse_args())
