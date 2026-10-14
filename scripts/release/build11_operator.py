#!/usr/bin/env python3
"""Build11 thin operator wrapper over existing image-only and recovery tooling."""
import argparse
from datetime import datetime, timezone
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import tempfile
from types import SimpleNamespace

import build11_artifacts as artifacts
import image_release as core
import trash_image_identity as identity
import trash_predeploy as pre
import trash_release as legacy
from hp_build10_queued_delete import Runner, IDS

RECOVERY_RECEIPTS = ('fresh-backup.json', 'fresh-restore-verified.json', 'backup-verified.json',
                     'build11-restored-database-verified.json')


def cleanup_completed(runner):
    return any(r.get('completed') is True and r.get('preserved') == 21 and r.get('queuePaused') is True and
               r.get('libraryOriginalsDeleted') == 0 and {row.get('id') for row in r.get('records', [])} == set(IDS) and
               all(row.get('physicallyVerified') is True or row.get('verifiedAbsentAfterPriorAttempt') is True
                   for row in r.get('records', []))
               for r in (runner.core.private_json(p) for p in runner.phase.glob('deletion-report-*.json')))


def complete_bridge(root):
    """Reuse the existing exact-six state machine; never infer HP deployment."""
    previous = Runner(root)
    current = previous.core.inspect(previous.core.SERVER)
    previous.core.identity(current)
    if current['Image'] == previous.hp.CURRENT:
        # run(True) checks completion/physical absence before the existing
        # image-only deployment. It never replays an already completed job.
        previous.run(True)
    else:
        previous.core.need(cleanup_completed(previous),
                           'SIX_CONFIRMED_CLEANUP_COMPLETION_RECEIPT_REQUIRED_NO_REPLAY')
        previous.gate()
        print('PASS existing six completed cleanup receipts reused; no destructive operations repeated')


def cleanups(root, candidate, rollback):
    runner = Runner(root)
    core.need(cleanup_completed(runner), 'SIX_CONFIRMED_CLEANUP_COMPLETION_RECEIPT_REQUIRED_NO_REPLAY')
    values, intent = runner.values(), runner.intent_values()
    proofs = runner.core.private_json(runner.phase / 'file-proofs.json')
    expected = intent['intent']['files']
    core.need(proofs.get('snapshotSeal') == values['snapshotSeal'] and proofs.get('intentSeal') == intent['intentSeal'] and
              isinstance(proofs.get('proofs'), list) and len(proofs['proofs']) == len(expected) and
              len({(r.get('jobId'), r.get('file')) for r in proofs['proofs']}) == len(expected) and
              all(any(all(p.get(field) == s.get(field) for field in ('jobId', 'file', 'path', 'root', 'jobHash', 'kind', 'ownerId'))
                      for s in expected) for p in proofs['proofs']), 'EXACT_SEALED_SIX_FILE_PROOF_COVERAGE_REQUIRED')
    allowed = {candidate, rollback, runner.hp.CURRENT, runner.hp.TARGET}
    prior = root / 'hardened-rollback/rollback-evidence.json'
    if prior.exists(): allowed.add(runner.core.private_json(prior)['identity']['loadedImageId'])
    def readonly_node(action, **values):
        core.need(action == 'gate', 'BUILD11_QUEUE_VERIFICATION_IS_READ_ONLY')
        current = core.inspect(core.SERVER); core.identity(current)
        core.need(current['Image'] in allowed, 'UNREVIEWED_CURRENT_IMAGE')
        payload = {'action': action, **values}
        program = runner.program + '\ntry { const result = await execute(' + json.dumps(payload) + ''');
console.log(JSON.stringify({ok:true,result})); } catch(e) {
console.log(JSON.stringify({ok:false,code:/^[A-Z][A-Z0-9_]{0,180}$/.test(e.message)?e.message:'PRIVATE_NATIVE_FAILURE'})); }
'''
        result = json.loads(core.run([*core.DOCKER, 'exec', '-i', core.SERVER, 'node', '--input-type=module'], input=program, timeout=600))
        core.need(result.get('ok') is True, result.get('code', 'PRIVATE_QUEUE_CHECK_FAILED'))
        return result['result']
    runner.node = readonly_node
    return runner.gate


def artifact_image(backend, source, version, expected, cache=None, allow_load=False):
    def verify_artifact(directory):
        manifest = json.loads((directory / 'manifest.json').read_text())
        archive = directory / 'gallery-server-linux-amd64.tar.gz'
        core.need(manifest['sourceCommit'] == source and manifest['serverVersion'] == version and
                  manifest['imageId'] == expected['imageId'] and
                  artifacts.digest(archive) == expected['archiveSHA256'], 'EXACT_FROZEN_BACKEND_REQUIRED')
        return archive
    archive = verify_artifact(backend)
    if cache is not None and cache.exists():
        saved = core.private_json(cache)
        core.need(saved.get('archiveSHA256') == expected['archiveSHA256'] and saved.get('sourceCommit') == source and
                  saved.get('configDigest') == expected['imageId'], 'IMAGE_IDENTITY_RECEIPT_CHANGED')
        item = core.image(saved['loadedImageId'])
        core.need(item.get('RootFS', {}).get('Layers') == saved['layerDiffIds'] and
                  core.environment(item).get('IMMICH_SOURCE_COMMIT') == source,
                  'RECORDED_IMMUTABLE_IMAGE_CHANGED')
        return saved['loadedImageId']
    if allow_load:
        # Prove all archive config/layer bytes BEFORE Docker import; no application runs.
        with archive.open('rb') as stream: identity.scan(stream, expected['imageId'], expected['imageTag'])
        try:
            existing = json.loads(core.docker('image', 'inspect', expected['imageTag']))
            core.need(len(existing) == 1 and core.environment(existing[0]).get('IMMICH_SOURCE_COMMIT') == source,
                      'EXISTING_CANDIDATE_TAG_NOT_OUR_SOURCE')
        except core.Stop as error:
            if str(error) != 'COMMAND_FAILED_PRIVATE_OUTPUT_OMITTED': raise
            core.run([*core.DOCKER, 'image', 'load', '--input', str(archive)], timeout=900)
    tool = SimpleNamespace(verify_artifact=verify_artifact, docker=core.docker, DOCKER=core.DOCKER,
                           IMAGE=expected['imageId'], TAG=expected['imageTag'], SOURCE=source, SOURCE_REF='v' + version,
                           ARCHIVE_SHA=expected['archiveSHA256'])
    proof = identity.verify_loaded(tool, backend)
    if cache is not None: core.save(cache, {**proof, 'sourceCommit': source, 'archiveSHA256': expected['archiveSHA256']})
    return proof['loadedImageId']


def recovery_generation(state):
    """Use only a contiguous, immutable activation chain bound to this plan."""
    previous = artifacts.digest(state / 'build11-preflight.json')
    selected = state
    receipts = sorted(state.glob('recovery-generation-*.json'))
    core.need(len(receipts) <= 999999, 'RECOVERY_GENERATION_LIMIT')
    for number, path in enumerate(receipts, 1):
        core.need(path.name == f'recovery-generation-{number:06d}.json', 'RECOVERY_GENERATION_CHAIN_REQUIRED')
        row = core.private_json(path)
        name = row.get('directory', '')
        core.need(re.fullmatch(r'generation-[A-Za-z0-9_]{8}', name) and
                  type(row.get('schemaVersion')) is int and row['schemaVersion'] == 1 and
                  type(row.get('sequence')) is int and row['sequence'] == number and
                  row.get('productionChanged') is False and
                  row.get('previousReceiptSHA256') == previous and
                  row.get('planSHA256') == artifacts.digest(state / 'image-state/image-plan.json'),
                  'RECOVERY_GENERATION_BINDING_CHANGED')
        parent = state / 'recovery-generations'
        selected = parent / name
        for directory in (parent, selected):
            core.need(directory.is_dir() and not directory.is_symlink() and
                      directory.stat().st_mode & 0o777 == 0o700 and directory.stat().st_uid == os.getuid(),
                      'OWNED_PRIVATE_RECOVERY_GENERATION_REQUIRED')
        core.need(row.get('evidenceSHA256') == {
            file: artifacts.digest(selected / file) for file in
            ('build11-preflight.json', 'fresh-backup.json', 'fresh-restore-verified.json',
             'backup-verified.json', 'build11-restored-database-verified.json')},
            'RECOVERY_GENERATION_EVIDENCE_CHANGED')
        plan = core.private_json(state / 'image-state/image-plan.json')
        core.need((row.get('sourceCommit'), row.get('candidateImage'), row.get('rollbackImage')) ==
                  (plan['sourceCommit'], plan['candidateImage'], plan['rollbackImage']),
                  'RECOVERY_GENERATION_IMAGE_OR_SOURCE_CHANGED')
        previous = artifacts.digest(path)
    return selected, len(receipts), previous


def recovered_backup(state, require_fresh=True):
    generation, _, _ = recovery_generation(state)
    context = core.private_json(generation / 'build11-preflight.json')
    backup = core.private_json(generation / 'fresh-backup.json')
    restored = core.private_json(generation / 'fresh-restore-verified.json')
    core.need(context['backupSHA256'] == backup['backupSHA256'] == restored['backupSHA256'] ==
              artifacts.digest(generation / 'fresh-immich.sql.gz') and
              restored['restore'] == 'PASS_EXACT_DUMP_SNAPSHOT' and context.get('productionChanged') is False,
              'FRESH_BACKUP_AND_EXACT_RESTORE_REQUIRED')
    for path, digest in context['nasEvidenceHashes'].items():
        core.need(artifacts.digest(Path(path)) == digest, 'NAS_RECOVERY_EVIDENCE_CHANGED')
    nas_receipts = [Path(path) for path in context['nasEvidenceHashes'] if Path(path).name == 'nas-verified.json']
    core.need(len(nas_receipts) == 1, 'REAL_NAS_RECOVERY_EVIDENCE_REQUIRED')
    expected = context.get('recoveryEvidenceSHA256')
    if expected is None and not require_fresh:
        return {**context, 'recoveryFreshness': 'HISTORIC_RECOVERY_METADATA_UNPINNED_RUN_REFRESH'}
    core.need(expected == {name: artifacts.digest(generation / name) for name in RECOVERY_RECEIPTS},
              'RECOVERY_RECEIPT_METADATA_CHANGED_RUN_REFRESH')
    try:
        pre.age_ok(backup['createdAt'], 86400, 'FRESH_RESTORED_BACKUP_EXPIRED')
        pre.age_ok(pre.private_json(nas_receipts[0])['verifiedAt'], 86400,
                   'NAS_RECOVERY_VERIFICATION_EXPIRED_NO_TIMESTAMP_REFRESH')
    except pre.Stop as error:
        if require_fresh:
            raise
        return {**context, 'recoveryFreshness': str(error)}
    return {**context, 'recoveryFreshness': 'FRESH_BACKUP_AND_NAS_WITHIN_24H'}


def refresh_recovery(args, source, candidate, rollback):
    """Append new tested bytes; never rewrite any previous backup or receipt."""
    row, before = core.prerequisites(args.state / 'image-state', rollback=True)
    core.need((row['sourceCommit'], row['candidateImage'], row['rollbackImage']) == (source, candidate, rollback),
              'REFRESH_PLAN_IMAGE_OR_SOURCE_CHANGED')
    fd = os.open(args.state / '.recovery-refresh.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as lock:
        info = os.fstat(lock.fileno())
        core.need(stat.S_ISREG(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o600 and info.st_uid == os.getuid(),
                  'PRIVATE_RECOVERY_REFRESH_LOCK_REQUIRED')
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise core.Stop('RECOVERY_REFRESH_ALREADY_IN_PROGRESS') from None
        _, number, previous = recovery_generation(args.state)
        core.need(number < 999999, 'RECOVERY_GENERATION_LIMIT')
        core.queue_safety()
        parent = args.state / 'recovery-generations'
        if not parent.exists():
            parent.mkdir(mode=0o700)
        core.need(parent.is_dir() and not parent.is_symlink() and parent.stat().st_mode & 0o777 == 0o700 and
                  parent.stat().st_uid == os.getuid(), 'OWNED_PRIVATE_RECOVERY_GENERATION_REQUIRED')
        generation = Path(tempfile.mkdtemp(prefix='generation-', dir=parent))
        # A failed attempt stays private and inactive. Retrying creates new bytes.
        prepare_backup(generation, source, candidate, rollback, args.nas_evidence)
        context = recovered_backup(generation)
        core.need(context['sourceCommit'] == source, 'PREFLIGHT_SOURCE_CHANGED')
        migration = core.private_json(generation / 'build11-restored-database-verified.json')
        core.need(migration.get('sourceCommit') == source and migration.get('imageId') == candidate and
                  migration.get('rollbackImageId') == rollback and migration.get('backupSHA256') == context['backupSHA256'] and
                  migration.get('validation') == 'PASS_ISOLATED_BUILD11_MIGRATION_AND_EXISTING_ROW_PRESERVATION' and
                  migration.get('policiesPreserved') is True and migration.get('rollbackMigrationsAccepted') is True and
                  migration.get('productionChanged') is False,
                  'EXACT_REFRESH_MIGRATION_RESTORE_REQUIRED')
        current_row, after = core.prerequisites(args.state / 'image-state', rollback=True)
        core.need(current_row == row and after['Id'] == before['Id'], 'SERVER_CHANGED_DURING_RECOVERY_REFRESH')
        core.queue_safety()
        activation = generation / 'activation-receipt.json'
        core.save(activation, {
            'schemaVersion': 1, 'sequence': number + 1, 'directory': generation.name,
            'previousReceiptSHA256': previous, 'planSHA256': artifacts.digest(args.state / 'image-state/image-plan.json'),
            'sourceCommit': source, 'candidateImage': candidate, 'rollbackImage': rollback,
            'evidenceSHA256': {file: artifacts.digest(generation / file) for file in
                              ('build11-preflight.json', 'fresh-backup.json', 'fresh-restore-verified.json',
                               'backup-verified.json', 'build11-restored-database-verified.json')},
            'activatedAt': datetime.now(timezone.utc).isoformat(), 'productionChanged': False})
        # Publish a completely flushed receipt atomically; a crash before this
        # hard link leaves only an inactive generation, never a partial pointer.
        for path in generation.iterdir():
            if path.is_file() and not path.is_symlink():
                descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
                try:
                    os.fsync(descriptor)
                finally:
                    os.close(descriptor)
        for directory in (generation, parent):
            descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        os.link(activation, args.state / f'recovery-generation-{number + 1:06d}.json', follow_symlinks=False)
        descriptor = os.open(args.state, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    print('PASS fresh recovery generation activated; previous backups/evidence retained; deployment not executed')


def prepare_backup(state, source, candidate, rollback, nas):
    core.need(not (state / 'build11-preflight.json').exists(), 'PREPARATION_ALREADY_RECORDED_USE_CHECK')
    pre.private_dir(nas)
    receipt = pre.private_json(nas / 'nas-verified.json')
    report = pre.private_json(nas / 'nas-recovery-report.txt')
    proof = pre.private_json(nas / 'nas-proof.json')
    core.need(report.get('result') == 'PASS' and report.get('checks', {}).get('NAS_RECOVERY') == 'PASS' and
              receipt.get('validation') == 'SAMPLE_BYTE_RECOVERY_PLUS_OPERATOR_SNAPSHOT_SCOPE_ATTESTATION' and
              set(proof.get('mounts', {})) == set(receipt.get('mounts', {})) and proof.get('mounts'),
              'REAL_NAS_RECOVERY_EVIDENCE_REQUIRED')
    for point in proof.get('provenance', {}).values():
        core.need(point.get('snapshotId') and point.get('snapshotTimestamp') and
                  point.get('metadataSource') in ('DSM_SNAPSHOT_LIST', 'NFS_DIRECTORY_ID_PLUS_DSM_OPERATOR_ATTESTATION'),
                  'REAL_SNAPSHOT_PROVENANCE_REQUIRED')
    core.need(set(proof.get('provenance', {})) == {'homes', 'Immich'}, 'FULL_NAS_SNAPSHOT_SCOPE_REQUIRED')
    for root, entry in proof['mounts'].items():
        core.need(entry.get('operator_attests_snapshot_export') is True and
                  {r['kind'] for r in entry['samples']} == {'photo', 'video'} and
                  [r['sha256'] for r in entry['samples']] == receipt['mounts'][root]['sampleHashes'],
                  'REAL_PHOTO_VIDEO_RECOVERY_SAMPLES_REQUIRED')
    pre.age_ok(receipt['verifiedAt'], 86400, 'NAS_RECOVERY_VERIFICATION_EXPIRED_NO_TIMESTAMP_REFRESH')
    legacy.DOCKER = core.DOCKER
    legacy.SOURCE = source
    legacy.BUILD11_SOURCE = source
    pre.postgres_identity(legacy, legacy.inspect(legacy.POSTGRES))
    backup, summary = pre.fresh_backup(legacy, state)
    from build11_restore_transition import build11_restore_transition
    def transition(tool, docker, container, query, restored, directory, original):
        return build11_restore_transition(tool, docker, container, query, restored, directory, original, candidate, rollback)
    pre.restore_exact(legacy, backup, state, summary, transition=transition)
    core.save(state / 'build11-preflight.json', {'sourceCommit': source, 'backupSHA256': artifacts.digest(backup),
              'recoveryEvidenceSHA256': {name: artifacts.digest(state / name) for name in RECOVERY_RECEIPTS},
              'nasEvidenceHashes': {str(nas / file): artifacts.digest(nas / file) for file in
                                   ('nas-verified.json', 'nas-proof.json', 'nas-recovery-report.txt')},
              'preparedAt': datetime.now(timezone.utc).isoformat(), 'productionChanged': False})
    print('PASS fresh SQL/gzip backup and isolated exact restore; originals, workers and queues unchanged')


def operate(args):
    core.DOCKER = ['sudo', '-n', 'docker', '--host=unix:///var/run/docker.sock']
    core.need(os.getuid() != 0 and __import__('pwd').getpwuid(os.getuid()).pw_name == 'doctoriceadm', 'RUN_AS_DOCTORICEADM')
    profile = artifacts.load(args.profile, args.profile_sha256)
    core.need(args.state.is_dir() and not args.state.is_symlink() and args.state.stat().st_mode & 0o777 == 0o700 and
              args.state.stat().st_uid == os.getuid(), 'OWNED_PRIVATE_BUILD11_STATE_REQUIRED')
    if args.complete_confirmed_cleanup:
        core.need(args.action == 'prepare' and args.execute_approved and
                  os.environ.get('GALLERY_USER_QUEUED_DELETION_APPROVED') == 'YES' and
                  os.environ.get('GALLERY_DEPLOYMENT_APPROVED') == 'YES', 'EXPLICIT_SEPARATE_OLD_CLEANUP_APPROVAL_REQUIRED')
        complete_bridge(args.previous_run_root)
    compatibility = artifacts.pinned_json(args.compatibility_receipt, args.compatibility_sha256)
    core.need(compatibility['candidateSource'] == profile['sourceCommit'] and
              compatibility['candidateImage'] == profile['backend']['imageId'], 'PINNED_CANDIDATE_COMPATIBILITY_REQUIRED')
    candidate = artifact_image(args.artifacts / 'backend', profile['sourceCommit'], artifacts.VERSION, profile['backend'],
                               args.state / 'candidate-image-identity.json', allow_load=args.action == 'prepare')
    rollback_metadata = json.loads((args.rollback_artifacts / 'manifest.json').read_text())
    core.need(rollback_metadata['imageId'] == compatibility['rollbackImage'] and
              rollback_metadata['sourceCommit'] == compatibility['rollbackSource'], 'PINNED_ROLLBACK_ARTIFACT_REQUIRED')
    rollback = artifact_image(args.rollback_artifacts, rollback_metadata['sourceCommit'], rollback_metadata['serverVersion'], rollback_metadata,
                              args.state / 'rollback-image-identity.json', allow_load=args.action == 'prepare')
    candidate_proof = core.probe_image(candidate, profile['sourceCommit'], (5, 7, 3), core.OWNER_STORAGE_CAPABILITY)
    rollback_proof = core.probe_image(rollback, rollback_metadata['sourceCommit'], core.version(rollback_metadata['serverVersion']))
    core.rollback_compatibility(candidate_proof, rollback_proof, compatibility)
    if args.action == 'prepare':
        derived = {**compatibility, 'candidateImage': candidate, 'rollbackImage': rollback}
        derived_path = args.state / 'verified-store-compatibility.json'
        core.save(derived_path, derived)
        core.queue_safety = cleanups(args.previous_run_root, candidate, rollback)
        core.queue_safety()
        current = core.inspect(core.SERVER)
        core.need(current['Image'] in (Runner(args.previous_run_root).hp.TARGET, rollback), 'COMPLETE_BUILD10_BRIDGE_FIRST')
        prepare_backup(args.state, profile['sourceCommit'], candidate, rollback, args.nas_evidence)
        plan_args = SimpleNamespace(state=args.state, image=candidate, expected_current_image=current['Image'],
                                    source_commit=profile['sourceCommit'], server_version=(5, 7, 3), api=args.api,
                                    rollback_image=rollback, rollback_source_commit=rollback_metadata['sourceCommit'],
                                    rollback_server_version=core.version(rollback_metadata['serverVersion']),
                                    compatibility_receipt=derived_path, compatibility_sha256=artifacts.digest(derived_path))
        # plan requires an empty image-state; backup/evidence live in the parent private directory.
        image_state = args.state / 'image-state'; image_state.mkdir(mode=0o700)
        plan_args.state = image_state
        core.plan(plan_args)
        print('PASS BUILD11_PREPARED_NOT_DEPLOYED; separate explicit approval required')
        return
    core.queue_safety = cleanups(args.previous_run_root, candidate, rollback)
    if args.action == 'refresh-recovery':
        refresh_recovery(args, profile['sourceCommit'], candidate, rollback)
        return
    context = recovered_backup(args.state, require_fresh=args.action != 'status')
    core.need(context['sourceCommit'] == profile['sourceCommit'], 'PREFLIGHT_SOURCE_CHANGED')
    core.queue_safety = cleanups(args.previous_run_root, candidate, rollback)
    execute_args = SimpleNamespace(state=args.state / 'image-state', execute_approved=args.execute_approved,
                                   approve_migration=args.approve_migration)
    if args.action == 'check':
        execute_args.execute_approved = False
        core.execute(execute_args, rollback=False)
    elif args.action in ('apply', 'rollback'):
        core.need(args.execute_approved, 'EXPLICIT_DEPLOYMENT_APPROVAL_REQUIRED')
        core.execute(execute_args, rollback=args.action == 'rollback')
        core.queue_safety()
    elif args.action == 'status':
        row, current = core.prerequisites(args.state / 'image-state', rollback=True)
        core.need(current['Image'] in (row['candidateImage'], row['rollbackImage']), 'INTENDED_RELEASE_NOT_RUNNING')
        target = current['Image']; source = row['sourceCommit'] if target == row['candidateImage'] else row['rollbackSource']
        version = row['serverVersion'] if target == row['candidateImage'] else row['rollbackVersion']
        core.health(args.api, target, source, version, timeout=0); core.queue_safety()
        print('PASS exact running image/source, healthy APIs, API+microservices and preserved paused jobs')
        if context['recoveryFreshness'] != 'FRESH_BACKUP_AND_NAS_WITHIN_24H':
            print('STOP rollback/apply recovery freshness: ' + context['recoveryFreshness'] + '; run refresh-recovery before changes')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('prepare', 'refresh-recovery', 'check', 'apply', 'upgrade', 'rollback', 'status'))
    for name in ('profile', 'artifacts', 'rollback-artifacts', 'compatibility-receipt', 'state', 'previous-run-root'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--profile-sha256', required=True); parser.add_argument('--compatibility-sha256', required=True)
    parser.add_argument('--nas-evidence', type=Path); parser.add_argument('--api', default='http://127.0.0.1:2283/api')
    parser.add_argument('--execute-approved', action='store_true'); parser.add_argument('--approve-migration', action='store_true')
    parser.add_argument('--complete-confirmed-cleanup', action='store_true')
    try:
        args = parser.parse_args()
        if args.action == 'upgrade':
            core.need(args.execute_approved and args.approve_migration and
                      os.environ.get('GALLERY_DEPLOYMENT_APPROVED') == 'YES' and
                      os.environ.get('GALLERY_ADDITIVE_MIGRATION_APPROVED') == 'YES',
                      'EXPLICIT_DEPLOYMENT_AND_ADDITIVE_MIGRATION_APPROVAL_REQUIRED')
            if not (args.state / 'image-state/image-plan.json').exists():
                operate(SimpleNamespace(**{**vars(args), 'action': 'prepare'}))
            if (args.state / 'image-state/applied.json').exists():
                operate(SimpleNamespace(**{**vars(args), 'action': 'status', 'complete_confirmed_cleanup': False}))
            else:
                for action in ('check', 'apply', 'status'):
                    operate(SimpleNamespace(**{**vars(args), 'action': action, 'complete_confirmed_cleanup': False}))
        else:
            operate(args)
        return 0
    except Exception as error:
        code = str(error) if isinstance(error, (core.Stop, pre.Stop, ValueError)) and re.fullmatch('[A-Z0-9_]+', str(error)) else 'BUILD11_OPERATION_FAILED_PRIVATE_DETAILS_OMITTED'
        print('STOP ' + code); return 1


if __name__ == '__main__': raise SystemExit(main())
