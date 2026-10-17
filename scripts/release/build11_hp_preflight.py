#!/usr/bin/env python3
"""Run the non-deploying Build11 HP gates as one fail-closed operation.

This wrapper deliberately delegates image, migration, backup, rollback and
sealed-intent validation to the reviewed release tools. It never calls apply,
rollback, compose up/down, queue cleanup, retry or resume.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import subprocess
import sys
import urllib.error
import urllib.request

import gallery_entry

CANDIDATE_IMAGE = 'sha256:1b6ee28e2b868280a9787cef5533636736de1148a18d2915ca5ff42835362bef'
CANDIDATE_SOURCE = '8af3a7a923c1391474dc9b7410e2f7833bc7771d'
AUDIT = Path('/opt/gallery-fork/scripts/diagnostics/hp_trash_release_audit.py')
REPORT_NAME = 'build11-hp-preflight-report.json'


class Stop(Exception):
    pass


def need(value, code):
    if not value:
        raise Stop(code)


def private_directory(path):
    need(path.is_dir() and not path.is_symlink() and path.stat().st_uid == os.getuid() and
         path.stat().st_mode & 0o777 == 0o700, 'PRIVATE_STATE_DIRECTORY_REQUIRED')


def private_file(path):
    need(path.is_file() and not path.is_symlink() and path.stat().st_uid == os.getuid() and
         path.stat().st_mode & 0o777 == 0o600, 'PRIVATE_EVIDENCE_FILE_REQUIRED')


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def seal_intents(run_root):
    phase = run_root / 'queued-user-deletions'
    private_directory(run_root)
    private_directory(phase)
    paths = {name: phase / name for name in
             ('cleanup-intent-v1.json', 'cleanup-intent-seal-v1.json', 'file-proofs.json')}
    for path in paths.values():
        private_file(path)
    intent = json.loads(paths['cleanup-intent-v1.json'].read_text())
    seal = json.loads(paths['cleanup-intent-seal-v1.json'].read_text())
    expected_seal = hashlib.sha256(json.dumps(intent, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()
    need(seal.get('sha256') == expected_seal, 'SEALED_CLEANUP_INTENT_CHANGED')
    proofs = json.loads(paths['file-proofs.json'].read_text())
    expected = intent.get('files')
    proof_rows = proofs.get('proofs')
    need(proofs.get('intentSeal') == expected_seal and isinstance(expected, list) and
         isinstance(proof_rows, list) and len(expected) == len(proof_rows), 'SEALED_CLEANUP_PROOFS_CHANGED')
    fields = ('jobId', 'file', 'path', 'root', 'jobHash', 'kind', 'ownerId')
    need(all(any(all(proof.get(field) == item.get(field) for field in fields) for proof in proof_rows)
             for item in expected), 'SEALED_CLEANUP_PROOF_COVERAGE_REQUIRED')
    return {'intentSHA256': sha(paths['cleanup-intent-v1.json']), 'sealSHA256': sha(paths['cleanup-intent-seal-v1.json']),
            'proofSHA256': sha(paths['file-proofs.json']), 'fileCount': len(expected)}


def run_audit():
    need(AUDIT.is_file() and not AUDIT.is_symlink(), 'HP_READONLY_AUDIT_TOOL_REQUIRED')
    result = subprocess.run([sys.executable, '-B', str(AUDIT)], capture_output=True, text=True, timeout=180)
    if result.returncode:
        raise Stop('HP_READONLY_AUDIT_FAILED')
    match = re.search(r'^PASS private report created: (.+)$', result.stdout, re.MULTILINE)
    need(match is not None, 'HP_READONLY_AUDIT_REPORT_REQUIRED')
    report = Path(match.group(1))
    private_file(report)
    row = json.loads(report.read_text())
    audit = row.get('backendReadOnlyAudit', {})
    queue = audit.get('queue', {})
    jobs = audit.get('deletionJobs', {})
    need(not audit.get('errors') and audit.get('readOnly') is True and queue.get('truncated') is False and
         queue.get('states', {}).get('active') == 0 and
         jobs.get('inventoryComplete') is True and jobs.get('fileDelete') == 0 and
         jobs.get('legacyAssetDelete') == 0, 'HP_AUDIT_QUEUE_NOT_EMPTY_OR_INCOMPLETE')
    return {'path': str(report), 'queuePaused': queue.get('paused') is True,
            'auditSHA256': sha(report), 'trashRestore': audit.get('backupSettings', {}).get('restoreValidated')}


def pause_and_drain(key_file):
    need(os.environ.get('GALLERY_QUEUE_PAUSE_APPROVED') == 'YES', 'QUEUE_PAUSE_APPROVAL_REQUIRED')
    private_file(key_file)
    key = key_file.read_text().strip()
    need(key and '\n' not in key and '\r' not in key, 'ADMIN_API_KEY_INVALID')
    request = urllib.request.Request('http://127.0.0.1:2283/api/jobs/backgroundTask',
                                     data=b'{"command":"pause"}', method='PUT',
                                     headers={'x-api-key': key, 'content-type': 'application/json'})
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            need(200 <= response.status < 300, 'QUEUE_PAUSE_REQUEST_FAILED')
    except (urllib.error.URLError, TimeoutError):
        raise Stop('QUEUE_PAUSE_REQUEST_FAILED') from None
    del key
    for _ in range(60):
        report = run_audit()
        if report['queuePaused']:
            return report
        import time
        time.sleep(5)
    raise Stop('DELETION_QUEUE_DID_NOT_DRAIN')


def operator_prepare(args, config):
    operator = args.package / 'tools' / 'build11_operator.py'
    need(operator.is_file() and not operator.is_symlink(), 'PACKAGED_OPERATOR_TOOL_REQUIRED')
    command = [sys.executable, '-B', str(operator), 'prepare',
               '--profile', str(args.package / 'candidate-profile.json'), '--profile-sha256', config['profileSHA256'],
               '--compatibility-receipt', str(args.package / 'reviewed-compatibility.json'),
               '--compatibility-sha256', config['compatibilitySHA256'], '--artifacts', str(args.package),
               '--rollback-artifacts', str(args.package / 'rollback'), '--state', str(args.state),
               '--previous-run-root', str(args.previous_run_root), '--nas-evidence', str(args.nas_evidence)]
    result = subprocess.run(command, capture_output=True, text=True, timeout=3600)
    if result.returncode:
        match = re.search(r'STOP ([A-Z0-9_]+)', result.stdout + result.stderr)
        raise Stop(match.group(1) if match else 'BUILD11_PREPARE_FAILED')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, required=True)
    parser.add_argument('--state', type=Path, required=True)
    parser.add_argument('--previous-run-root', type=Path, required=True)
    parser.add_argument('--nas-evidence', type=Path, required=True)
    parser.add_argument('--pause-drain-key', type=Path)
    args = parser.parse_args(argv)
    report = {'schemaVersion': 1, 'productionChanged': False, 'deploymentExecuted': False,
              'startedAt': datetime.now(timezone.utc).isoformat()}
    target = args.state / REPORT_NAME
    try:
        need(pwd.getpwuid(os.getuid()).pw_name == 'doctoriceadm', 'RUN_AS_DOCTORICEADM')
        if not args.state.exists():
            args.state.mkdir(mode=0o700, parents=False)
        private_directory(args.state)
        config = gallery_entry.verify_package(args.package)
        profile = json.loads((args.package / 'candidate-profile.json').read_text())
        need(profile['sourceCommit'] == CANDIDATE_SOURCE and profile['backend']['imageId'] == CANDIDATE_IMAGE,
             'BUILD11_CANDIDATE_IMAGE_OR_SOURCE_MISMATCH')
        report['packageSHA256'] = sha(args.package / 'SHA256SUMS')
        report['candidateImage'] = CANDIDATE_IMAGE
        report['sealedIntent'] = seal_intents(args.previous_run_root)
        report['audit'] = run_audit()
        if args.pause_drain_key:
            report['auditAfterPause'] = pause_and_drain(args.pause_drain_key)
        operator_prepare(args, config)
        if not args.pause_drain_key and not report['audit']['queuePaused']:
            raise Stop('QUEUE_PAUSE_APPROVAL_REQUIRED')
        report['result'] = 'READY_FOR_SEPARATE_DEPLOYMENT_APPROVAL'
        report['finishedAt'] = datetime.now(timezone.utc).isoformat()
        need(not target.exists() and not target.is_symlink(), 'PREFLIGHT_REPORT_ALREADY_EXISTS')
        with os.fdopen(os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), 'w') as stream:
            json.dump(report, stream, indent=2); stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
        print('READY')
        print('REPORT ' + str(target))
        return 0
    except (Stop, ValueError) as error:
        code = str(error) if re.fullmatch(r'[A-Z0-9_]+', str(error)) else 'BUILD11_PREFLIGHT_FAILED'
        report.update(result='BLOCKED', blocker=code, finishedAt=datetime.now(timezone.utc).isoformat())
        try:
            if args.state.is_dir() and not target.exists() and not target.is_symlink():
                with os.fdopen(os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), 'w') as stream:
                    json.dump(report, stream, indent=2); stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
        except OSError:
            pass
        print('BLOCKED ' + code)
        return 1
    except Exception:
        report.update(result='BLOCKED', blocker='BUILD11_PREFLIGHT_FAILED', finishedAt=datetime.now(timezone.utc).isoformat())
        try:
            if args.state.is_dir() and not target.exists() and not target.is_symlink():
                with os.fdopen(os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), 'w') as stream:
                    json.dump(report, stream, indent=2); stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
        except OSError:
            pass
        print('BLOCKED BUILD11_PREFLIGHT_FAILED')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
