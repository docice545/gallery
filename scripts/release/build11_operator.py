#!/usr/bin/env python3
"""Build11 thin operator wrapper over existing image-only and recovery tooling."""
import argparse
from datetime import datetime, timezone
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import re
from types import SimpleNamespace

import build11_artifacts as artifacts
import image_release as core
import trash_image_identity as identity
import trash_predeploy as pre
import trash_release as legacy
from hp_build10_queued_delete import Runner, IDS

EXPECTED_PRODUCTION_IMAGE = 'sha256:52e08a50b507ddddf591706eed8df70c1904b47fca53d5e913146853df2a2b8b'


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


def sealed_intent_queue_gate(root, candidate, rollback):
    """Read-only gate for an already sealed, empty queue.

    The old six-job bridge is intentionally not replayed when the HP audit has
    already proven that the queue is empty.  The intent and proof files remain
    mandatory; their absence never becomes an implicit permission to continue.
    """
    phase = root / 'queued-user-deletions'
    core.need(phase.is_dir() and not phase.is_symlink(), 'SEALED_CLEANUP_PHASE_REQUIRED')
    required = ('cleanup-intent-v1.json', 'cleanup-intent-seal-v1.json', 'file-proofs.json')
    for name in required:
        path = phase / name
        core.need(path.is_file() and not path.is_symlink() and path.stat().st_mode & 0o777 == 0o600,
                  'SEALED_CLEANUP_FILES_REQUIRED')
    intent = core.private_json(phase / 'cleanup-intent-v1.json')
    seal = core.private_json(phase / 'cleanup-intent-seal-v1.json')
    intent_hash = hashlib.sha256(json.dumps(intent, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()
    expected = intent.get('files')
    fields = ('jobId', 'file', 'path', 'root', 'jobHash', 'kind', 'ownerId')
    core.need(intent.get('contract') == 'confirmed-native-cleanup-v1' and
              isinstance(expected, list) and expected and
              all(isinstance(row, dict) and all(isinstance(row.get(field), str) and row[field] for field in fields)
                  for row in expected) and
              {row['jobId'] for row in expected} == set(IDS),
              'SEALED_CLEANUP_INTENT_SCOPE_CHANGED')
    core.need(seal.get('sha256') == intent_hash, 'SEALED_CLEANUP_INTENT_CHANGED')
    proofs = core.private_json(phase / 'file-proofs.json')
    core.need(proofs.get('intentSeal') == seal.get('sha256') and isinstance(expected, list) and
              len(expected) == len(IDS) and len({(row['jobId'], row['file']) for row in expected}) == len(expected) and
              all(isinstance(row, dict) and all(isinstance(row.get(field), str) and row[field] for field in fields)
                  for row in expected) and isinstance(proofs.get('proofs'), list) and
              len(proofs['proofs']) == len(expected),
              'SEALED_CLEANUP_PROOFS_CHANGED')
    core.need(all(any(all(proof.get(field) == source.get(field) for field in fields) for proof in proofs['proofs'])
                  for source in expected), 'SEALED_CLEANUP_PROOF_COVERAGE_REQUIRED')
    current = core.inspect(core.SERVER)
    core.identity(current)
    core.need(current['Image'] == EXPECTED_PRODUCTION_IMAGE,
              'EXPECTED_AUDITED_PRODUCTION_IMAGE_REQUIRED')
    result = core.queue_safety()
    core.need(result.get('inventoryComplete') is True and result.get('unresolvedDeletionHashes') == 0,
              'DELETION_QUEUE_READ_INCOMPLETE')
    print('PASS sealed intent/proof files and current empty deletion queue; no cleanup replay')
    return result


def cleanups(root, candidate, rollback):
    runner = Runner(root)
    if not cleanup_completed(runner):
        return lambda: sealed_intent_queue_gate(root, candidate, rollback)
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
                           IMAGE=expected['imageId'], TAG=expected['imageTag'], SOURCE=source, SOURCE_REF='v' + version)
    proof = identity.verify_loaded(tool, backend)
    if cache is not None: core.save(cache, {**proof, 'sourceCommit': source, 'archiveSHA256': expected['archiveSHA256']})
    return proof['loadedImageId']


def recovered_backup(state):
    context = core.private_json(state / 'build11-preflight.json')
    backup, restored = core.private_json(state / 'fresh-backup.json'), core.private_json(state / 'fresh-restore-verified.json')
    pre.age_ok(backup['createdAt'], 86400, 'FRESH_RESTORED_BACKUP_EXPIRED')
    core.need(context['backupSHA256'] == backup['backupSHA256'] == restored['backupSHA256'] ==
              artifacts.digest(state / 'fresh-immich.sql.gz') and restored['restore'] == 'PASS_EXACT_DUMP_SNAPSHOT',
              'FRESH_BACKUP_AND_EXACT_RESTORE_REQUIRED')
    for path, digest in context['nasEvidenceHashes'].items():
        core.need(artifacts.digest(Path(path)) == digest, 'NAS_RECOVERY_EVIDENCE_CHANGED')
    return context


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
        bridge_complete = cleanup_completed(Runner(args.previous_run_root))
        core.queue_safety = cleanups(args.previous_run_root, candidate, rollback)
        core.queue_safety()
        current = core.inspect(core.SERVER)
        if bridge_complete:
            core.need(current['Image'] in (Runner(args.previous_run_root).hp.TARGET, rollback),
                      'COMPLETE_BUILD10_BRIDGE_FIRST')
        else:
            core.need(current['Image'] == EXPECTED_PRODUCTION_IMAGE,
                      'EXPECTED_AUDITED_PRODUCTION_IMAGE_REQUIRED')
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
    context = recovered_backup(args.state)
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('prepare', 'check', 'apply', 'upgrade', 'rollback', 'status'))
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
