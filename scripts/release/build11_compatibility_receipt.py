#!/usr/bin/env python3
"""Bind actual compiled image probes to the existing isolated rollback runtime test.

This runs only on a disposable GitHub Actions runner. It reuses the image/archive
verifier and probes packaged files in networkless read-only containers. It never
runs application workers, touches HP, creates recovery proofs or invents results.
"""
import argparse
import json
import os
from pathlib import Path
import re

import build11_artifacts as artifacts
import build11_operator as operator
import image_release as core

MIGRATION = '1794050000000-OwnerStorageDeletion'
CHECKS = {'isolatedDatabase': True, 'oldRuntimeStartsOnUpgradedSchema': True,
          'storagePoliciesRejectedByRollback': True, 'trashRestoreAfterRollback': True,
          'syntheticMediaOnly': True, 'productionChanged': False}
ARTIFACTS = {'backend': 'gallery-trash-server-linux-amd64',
             'android': 'android-media-pilot-validation-apk', 'ios': 'ios-unsigned-ipa',
             'rollback': 'gallery-trash-server-linux-amd64'}


def verify_runs(source, runs, rollback_source):
    """Fail before downloading if an exact successful source/artifact is missing."""
    artifacts.need(re.fullmatch('[0-9a-f]{40}', source or '') and
                   re.fullmatch('[0-9a-f]{40}', rollback_source or '') and source != rollback_source,
                   'EXACT_DISTINCT_APPLICATION_AND_ROLLBACK_SOURCES_REQUIRED')
    artifacts.need(set(runs) == set(ARTIFACTS) and
                   all(type(run) is int and run > 0 for run in runs.values()) and
                   len(set(runs.values())) == 4, 'FOUR_DISTINCT_EXPLICIT_CI_RUNS_REQUIRED')
    result = {}
    for platform, run in runs.items():
        endpoint = f'repos/docice545/gallery/actions/runs/{run}'
        row = artifacts.gh(endpoint)
        workflow = 'gallery-build-mobile.yml' if platform in ('android', 'ios') else 'gallery-trash-server-build.yml'
        expected_source = rollback_source if platform == 'rollback' else source
        if platform == 'backend':
            artifacts.verify_backend_source(row, source)
        artifacts.need(row.get('status') == 'completed' and row.get('conclusion') == 'success' and
                       (platform == 'backend' or row.get('head_sha') == expected_source) and
                       row.get('path', '').endswith('/' + workflow) and
                       row.get('repository', {}).get('full_name') == 'docice545/gallery',
                       'EXACT_SUCCESSFUL_WORKFLOW_SOURCE_REQUIRED')
        items = artifacts.gh(endpoint + '/artifacts?per_page=100')
        artifacts.need(type(items.get('total_count')) is int and items['total_count'] <= 100,
                       'BOUNDED_COMPLETE_ARTIFACT_INVENTORY_REQUIRED')
        artifacts.need(len(items.get('artifacts', [])) == items['total_count'],
                       'BOUNDED_COMPLETE_ARTIFACT_INVENTORY_REQUIRED')
        matches = [item for item in items['artifacts'] if item.get('name') == ARTIFACTS[platform]
                   and item.get('expired') is False]
        artifacts.need(len(matches) == 1 and type(matches[0].get('id')) is int and matches[0]['id'] > 0 and
                       type(matches[0].get('size_in_bytes')) is int and
                       0 < matches[0]['size_in_bytes'] <= 3 * 1024**3,
                       'EXACT_BOUNDED_DOWNLOADABLE_ARTIFACT_REQUIRED')
        result[platform] = {'run': run, 'artifactId': matches[0]['id'], 'sourceCommit': expected_source,
                            'name': ARTIFACTS[platform], 'toolingCommit': row['head_sha']}
    return result


def runtime_report(directory, profile, rollback):
    path = directory / 'backend/build11-rollback-runtime.json'
    report_sha = artifacts.digest(path)
    runtime = artifacts.pinned_json(path, report_sha)
    manifest = artifacts.pinned_json(directory / 'backend/manifest.json',
                                     artifacts.digest(directory / 'backend/manifest.json'))
    artifacts.need(manifest == profile['backend'], 'SEALED_BACKEND_MANIFEST_CHANGED')
    artifacts.need(manifest.get('rollbackVerification') == 'PASS_ACTUAL_PINNED_OLD_RUNTIME_HTTP_ON_BUILD11_SCHEMA' and
                   manifest.get('rollbackRuntimeReceiptSHA256') == report_sha and
                   manifest.get('isolatedWorkerConfiguration') == 'API_AND_MICROSERVICES' and
                   manifest.get('thumbnailPreviewVerification') == 'PASS_SYNTHETIC_FILES_AND_HTTP',
                   'ACTUAL_RUNTIME_WORKER_AND_ROLLBACK_REPORT_REQUIRED')
    artifacts.need(type(runtime.get('schemaVersion')) is int and runtime['schemaVersion'] == 1 and
                   all(type(runtime.get(key)) is bool and runtime[key] is value for key, value in CHECKS.items()) and
                   runtime.get('sourceCommit') == profile['sourceCommit'] and
                   runtime.get('candidateImageId') == manifest['imageId'] and
                   runtime.get('rollbackSourceCommit') == rollback['sourceCommit'] and
                   re.fullmatch('sha256:[0-9a-f]{64}', runtime.get('rollbackImageId', '')) and
                   runtime.get('rollbackArchiveSHA256') == rollback['archiveSHA256'],
                   'EXACT_REAL_ISOLATED_ROLLBACK_REPORT_REQUIRED')
    return report_sha, runtime


def runtime_image_binding(directory, rollback, runtime):
    recorded = runtime['rollbackImageId']
    if recorded == rollback['imageId']:
        return {'configDigest': rollback['imageId'], 'loadedImageId': recorded, 'identityKind': 'CONFIG_DIGEST'}
    # Containerd reports the immutable manifest ID rather than the config ID.
    # The existing byte-level descriptor graph verifier must prove that exact
    # recorded ID reaches the expected config and ordered layer blobs. A label,
    # similar source or arbitrary ID is never accepted as an alias.
    archive = directory / 'gallery-server-linux-amd64.tar.gz'
    artifacts.need(artifacts.digest(archive) == rollback['archiveSHA256'], 'PINNED_ROLLBACK_ARCHIVE_CHANGED')
    with archive.open('rb') as file:
        identity = artifacts.identity.scan(file, rollback['imageId'], rollback['imageTag'], recorded)
    return {key: identity[key] for key in ('configDigest', 'loadedImageId', 'identityKind')}


def build(args):
    artifacts.need(os.environ.get('GITHUB_ACTIONS') == 'true' and
                   os.environ.get('GALLERY_DISPOSABLE_RELEASE_TESTS') == '1',
                   'DISPOSABLE_GITHUB_ACTIONS_RUNNER_ONLY')
    artifacts.need(not args.output.exists() and not args.output.is_symlink(), 'NEW_COMPATIBILITY_OUTPUT_REQUIRED')
    profile = artifacts.load(args.profile, args.profile_sha256)
    rollback = artifacts.pinned_json(args.rollback_artifacts / 'manifest.json',
                                     artifacts.digest(args.rollback_artifacts / 'manifest.json'))
    artifacts.need(rollback.get('sourceCommit') == args.rollback_source and
                   re.fullmatch('sha256:[0-9a-f]{64}', rollback.get('imageId', '')) and
                   re.fullmatch('[0-9a-f]{64}', rollback.get('archiveSHA256', '')),
                   'PINNED_ROLLBACK_ARTIFACT_REQUIRED')
    provenance = verify_runs(profile['sourceCommit'],
                            {'backend': profile['backendRun'], 'android': profile['android']['run'],
                             'ios': profile['ios']['run'], 'rollback': args.rollback_run}, args.rollback_source)
    artifacts.need(profile['backend'].get('toolingCommit') == provenance['backend']['toolingCommit'],
                   'EXACT_BACKEND_SOURCE_AND_TOOLING_MANIFEST_REQUIRED')
    artifacts.need(provenance['backend']['artifactId'] == profile['backendArtifactId'] and
                   all(provenance[p]['artifactId'] == profile[p]['artifactId'] for p in ('android', 'ios')),
                   'SEALED_ARTIFACT_ID_CHANGED')
    report_sha, runtime = runtime_report(args.artifacts, profile, rollback)
    runtime_identity = runtime_image_binding(args.rollback_artifacts, rollback, runtime)
    candidate_image = operator.artifact_image(args.artifacts / 'backend', profile['sourceCommit'], artifacts.VERSION,
                                              profile['backend'], allow_load=True)
    rollback_image = operator.artifact_image(args.rollback_artifacts, rollback['sourceCommit'], rollback['serverVersion'],
                                             rollback, allow_load=True)
    candidate = core.probe_image(candidate_image, profile['sourceCommit'], (5, 7, 3), core.OWNER_STORAGE_CAPABILITY)
    old = core.probe_image(rollback_image, rollback['sourceCommit'], core.version(rollback['serverVersion']))
    candidates = {row['name']: row['sha256'] for row in candidate['migrations']}
    olds = {row['name']: row['sha256'] for row in old['migrations']}
    artifacts.need(MIGRATION in candidates, 'ACTUAL_OWNER_STORAGE_MIGRATION_REQUIRED')
    receipt = {'schemaVersion': 1, 'contract': 'build11-reviewed-additive-upgrade-v1',
               'candidateSource': profile['sourceCommit'], 'candidateImage': profile['backend']['imageId'],
               'rollbackSource': rollback['sourceCommit'], 'rollbackImage': rollback['imageId'],
               'candidateProofSHA256': core.proof_digest(candidate), 'rollbackProofSHA256': core.proof_digest(old),
               'candidateProof': candidate, 'rollbackProof': old,
               'migrationsAdded': [{'name': MIGRATION, 'sha256': candidates[MIGRATION]}],
               'rollbackContainsAdditiveMigration': olds.get(MIGRATION) == candidates[MIGRATION],
               'rollbackTest': {key: runtime[key] for key in CHECKS}, 'testReportSHA256': report_sha,
               'ciProvenance': provenance, 'rollbackRuntimeImageIdentity': runtime_identity}
    core.rollback_compatibility(candidate, old, receipt)
    with args.output.open('x') as file:
        json.dump(receipt, file, indent=2, sort_keys=True)
        file.write('\n')
    print('PASS actual imported image config/layers + compiled guards/migrations + pinned isolated HTTP rollback')
    print('COMPATIBILITY_SHA256=' + artifacts.digest(args.output))
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    verify = commands.add_parser('verify-runs')
    verify.add_argument('--source', required=True); verify.add_argument('--rollback-source', required=True)
    for platform in ARTIFACTS: verify.add_argument('--' + platform + '-run', type=int, required=True)
    package = commands.add_parser('build')
    for name in ('artifacts', 'rollback-artifacts', 'profile', 'output'):
        package.add_argument('--' + name, type=Path, required=True)
    package.add_argument('--profile-sha256', required=True)
    package.add_argument('--rollback-source', required=True); package.add_argument('--rollback-run', type=int, required=True)
    args = parser.parse_args()
    if args.command == 'verify-runs':
        result = verify_runs(args.source, {p: getattr(args, p + '_run') for p in ARTIFACTS}, args.rollback_source)
        print(json.dumps(result, sort_keys=True))
        print('PASS four exact successful downloadable CI artifact identities')
    else:
        build(args)


if __name__ == '__main__':
    main()
