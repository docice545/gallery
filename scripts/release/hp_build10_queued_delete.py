#!/usr/bin/env python3
"""Confirmed FileDelete jobs, physical verification, preserved paused jobs, image-only update."""
import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import pwd
import re
import posixpath
import sys
from types import SimpleNamespace

IDS = ['886', '887', '888', '929', '930', '953']
FILES = ['services/storage.service.js', 'repositories/storage.repository.js', 'repositories/asset.repository.js',
         'utils/authorized-deletion.js', 'utils/deletion-recovery.js', 'backends/disk-storage.backend.js',
         'services/job.service.js', 'enum.js', 'repositories/config.repository.js', 'services/asset-media.service.js']


def load(name):
    path = Path(__file__).with_name(name + '.py')
    spec = importlib.util.spec_from_file_location('queue_release_' + name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Runner:
    def __init__(self, root):
        self.root = root
        self.core = load('image_release')
        self.hp = load('hp_build10_rollback')
        self.core.DOCKER = ['sudo', '-n', 'docker', '--host=unix:///var/run/docker.sock']
        self.phase = root / 'queued-user-deletions'
        self.program = Path(__file__).with_suffix('.mjs').read_text()
        self.helper = 'gallery-confirmed-files-' + hashlib.sha256(str(root).encode()).hexdigest()[:12]

    def node(self, action, **values):
        item = self.core.inspect(self.core.SERVER)
        self.core.identity(item)
        allowed = {self.hp.CURRENT, self.hp.TARGET}
        if (self.root / 'hardened-rollback/rollback-evidence.json').exists():
            allowed.add(self.core.private_json(self.root / 'hardened-rollback/rollback-evidence.json')['identity']['loadedImageId'])
        self.core.need(item['Image'] in allowed, 'UNEXPECTED_PRODUCTION_IMAGE')
        target = self.core.SERVER
        if action in ('prepare', 'execute'):
            helper = self.core.inspect(self.helper)
            self.core.need(helper['Image'] == self.hp.TARGET and helper['State'].get('Running') and
                           helper['Config']['Labels'].get('gallery.confirmed-files.run') == str(self.root),
                           'VERIFIED_RUNNING_NATIVE_HANDLER_REQUIRED')
            self.helper_binding(helper)
            target = self.helper
        payload = {'action': action, **values}
        text = self.program + '\ntry { const result = await execute(' + json.dumps(payload) + ''');
console.log(JSON.stringify({ok:true,result})); } catch(e) {
console.log(JSON.stringify({ok:false,code:/^[A-Z][A-Z0-9_]{0,180}$/.test(e.message)?e.message:'PRIVATE_NATIVE_FAILURE'})); }
'''
        row = json.loads(self.core.run([*self.core.DOCKER, 'exec', '-i', target,
                                       'node', '--input-type=module'], input=text, timeout=600))
        self.core.need(row.get('ok') is True, row.get('code', 'NATIVE_RESULT_INVALID'))
        return row['result']

    def handlers(self):
        code = '''import fs from 'node:fs/promises';import {createHash} from 'node:crypto';
const result={};for(const file of ''' + json.dumps(FILES) + ''')result[file]=createHash('sha256').update(
await fs.readFile('/usr/src/app/server/dist/'+file)).digest('hex');console.log(JSON.stringify(result));'''
        actual = json.loads(self.core.run([*self.core.DOCKER, 'exec', self.helper,
                                          'node', '--input-type=module', '-e', code]))
        expected = json.loads(self.core.run([*self.core.DOCKER, 'run', '--rm', '--pull', 'never', '--network', 'none',
                                            '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
                                            '--memory', '256m', '--cpus', '1', '--pids-limit', '64', '--entrypoint', 'node',
                                            self.hp.TARGET, '--input-type=module', '-e', code]))
        self.core.need(set(actual) == set(FILES) and actual == expected, 'RUNNING_HANDLERS_DIFFER_REQUIRE_REVIEW')

    def producer_contract(self):
        # The persisted temporaryOwnerId must be the real existing native
        # authenticated upload-cleanup contract, never a newly invented flag.
        code = "import fs from 'node:fs/promises';import {createHash} from 'node:crypto';console.log(createHash('sha256').update(await fs.readFile('/usr/src/app/server/dist/services/asset-media.service.js')).digest('hex'));"
        actual = self.core.run([*self.core.DOCKER, 'exec', self.core.SERVER, 'node', '--input-type=module', '-e', code]).strip()
        expected = self.core.run([*self.core.DOCKER, 'run', '--rm', '--pull', 'never', '--network', 'none',
                                  '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
                                  '--memory', '256m', '--cpus', '1', '--pids-limit', '64', '--entrypoint', 'node',
                                  self.hp.TARGET, '--input-type=module', '-e', code]).strip()
        self.core.need(re.fullmatch('[a-f0-9]{64}', actual) and actual == expected,
                       'LEGACY_UPLOAD_PRODUCER_DIFFERS_FROM_FROZEN_SOURCE')
        return {'image': self.hp.CURRENT, 'nativeProducerSHA256': actual}

    def intent_values(self):
        intent = self.core.private_json(self.phase / 'cleanup-intent-v1.json')
        seal = self.core.private_json(self.phase / 'cleanup-intent-seal-v1.json')['sha256']
        self.core.need(hashlib.sha256(json.dumps(intent, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest() == seal,
                       'SEALED_CLEANUP_INTENT_CHANGED')
        self.core.need(intent.get('contract') == 'confirmed-native-cleanup-v1' and
                       intent.get('snapshotSeal') == self.values()['snapshotSeal'], 'CLEANUP_INTENT_CONTRACT_CHANGED')
        return {'intent': intent, 'intentSeal': seal}

    def start_helper(self):
        # No production AppModule bootstrap. Existing originals/evidence are RO;
        # only verified derivative/owner upload subdirectories are writable.
        current = self.core.inspect(self.core.SERVER)
        self.core.need(current['Image'] == self.hp.CURRENT, 'EXPECTED_CURRENT_IMAGE_REQUIRED')
        ids = self.core.docker('ps', '-aq', '--filter', 'name=^/' + self.helper + '$').split()
        if ids:
            self.core.need(len(ids) == 1, 'HELPER_AMBIGUOUS')
            item = self.core.inspect(self.helper)
            self.core.need(item['Image'] == self.hp.TARGET and item['State'].get('Running') and
                           item['Config']['Labels'].get('gallery.confirmed-files.run') == str(self.root),
                           'EXISTING_HELPER_NOT_OUR_RUNNING_NAMESPACE')
            self.helper_binding(item)
            writable = {r['path'] for r in self.intent_values()['intent']['rootPhysical']}
            self.core.need({r['Destination'] for r in item['Mounts'] if r.get('RW')} == writable,
                           'EXISTING_HELPER_SCOPE_DIFFERS_NO_AUTOMATIC_REMOUNT')
            self.handlers()
            return
        media = self.values()['snapshot']['mediaRoot']
        self.core.need(media.startswith('/') and media == posixpath.normpath(media), 'VERIFIED_MEDIA_ROOT_REQUIRED')
        # Never grant RW to the whole upload tree or any library/external root.
        mounts = []
        rows = current['Mounts']
        self.core.need(len({r['Destination'] for r in rows}) == len(rows), 'UNAMBIGUOUS_CONTAINER_MOUNTS_REQUIRED')
        intent = self.intent_values()['intent']
        writable = {r['path'] for r in intent['rootPhysical']}
        expected = {s['root'] for s in intent['files']}
        self.core.need(writable == expected and bool(writable) and len(writable) <= 128,
                       'EXACT_CONFIRMED_WRITABLE_ROOTS_REQUIRED')
        for destination in sorted(writable):
            relative = destination.removeprefix(media + '/')
            self.core.need(destination.startswith(media + '/') and destination == posixpath.normpath(destination) and
                           (relative in ('thumbs', 'encoded-video', 'profile') or
                            re.fullmatch('upload/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}', relative)),
                           'UNSUPPORTED_WRITABLE_CLEANUP_SCOPE')
            self.core.need(not any(r['Destination'].startswith(destination + '/') for r in rows), 'NESTED_CLEANUP_MOUNT_REQUIRES_REVIEW')
            parents = [r for r in rows if destination == r['Destination'] or destination.startswith(r['Destination'].rstrip('/') + '/')]
            self.core.need(bool(parents), 'EXISTING_MEDIA_MOUNT_REQUIRED')
            bound = max(parents, key=lambda r: len(r['Destination']))
            self.core.need(bound['Type'] in ('bind', 'volume') and bound.get('RW') is True,
                           'EXISTING_WRITABLE_CLEANUP_MOUNT_REQUIRED')
            source = bound['Source'].rstrip('/') + destination[len(bound['Destination'].rstrip('/')):]
            actual = self.core.run(['sudo', '-n', 'realpath', '--canonicalize-existing', source]).strip()
            self.core.need(actual == source and ',' not in source and ',' not in destination,
                           'CANONICAL_EXISTING_CLEANUP_SOURCE_REQUIRED')
            mounts.extend(['--mount', 'type=bind,src=' + source + ',dst=' + destination])
        env_file = self.phase / 'native-handler.env'
        self.core.need(not env_file.exists(), 'FAILED_HELPER_CREATION_RETAINED_NO_ENV_OVERWRITE')
        env = [v for v in current['Config']['Env'] if not v.split('=', 1)[0].startswith(('IMMICH_SOURCE_', 'IMMICH_BUILD_', 'IMMICH_REPOSITORY'))]
        self.core.need(all('\n' not in value and '\r' not in value for value in env), 'SINGLE_LINE_HELPER_ENV_REQUIRED')
        with os.fdopen(os.open(env_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), 'w') as out:
            out.write('\n'.join(env) + '\n'); out.flush(); os.fsync(out.fileno())
        self.core.run([*self.core.DOCKER, 'run', '-d', '--pull', 'never', '--name', self.helper,
                       '--label', 'gallery.confirmed-files.run=' + str(self.root), '--network', 'container:' + self.core.SERVER,
                       '--volumes-from', self.core.SERVER + ':ro', *mounts, '--read-only', '--cap-drop', 'ALL',
                       '--cap-add', 'FOWNER', '--security-opt', 'no-new-privileges', '--pids-limit', '128',
                       '--memory', '512m', '--cpus', '0.5', '--env-file', str(env_file),
                       '--entrypoint', 'node', self.hp.TARGET, '-e', 'setInterval(()=>{},10000)'])
        item = self.core.inspect(self.helper)
        host = item['HostConfig']
        self.core.need(host.get('ReadonlyRootfs') is True and not host.get('Privileged') and
                       host.get('CapDrop') == ['ALL'] and host.get('CapAdd') == ['FOWNER'] and
                       host.get('Memory') == 512 * 1024 ** 2 and host.get('NanoCpus') == 500_000_000 and
                       host.get('NetworkMode') == 'container:' + current['Id'],
                       'SCOPED_HELPER_SECURITY_PROFILE_REQUIRED')
        self.core.need(len({r['Destination'] for r in item['Mounts']}) == len(item['Mounts']) and
                       {r['Destination'] for r in item['Mounts']} == {r['Destination'] for r in rows} | writable and
                       all(r.get('RW') is (r['Destination'] in writable) for r in item['Mounts']),
                       'NONSELECTED_ORIGINALS_AND_EVIDENCE_MUST_BE_READ_ONLY_IN_HELPER')
        self.core.save(self.phase / 'native-handler.json', self.helper_fingerprint(item))
        self.handlers()
        # Bind the admissible directory BEFORE mounting it writable in a new
        # namespace. Cross-namespace mount IDs differ, device/inode must not.
        code = "import fs from 'node:fs/promises';const result=[];for(const path of " + json.dumps(
            [r['path'] for r in intent['rootPhysical']]) + \
            "){const s=await fs.stat(path,{bigint:true});result.push({path,device:String(s.dev),inode:String(s.ino),uid:String(s.uid),gid:String(s.gid)});}console.log(JSON.stringify(result));"
        observed = json.loads(self.core.run([*self.core.DOCKER, 'exec', self.helper, 'node', '--input-type=module', '-e', code]))
        self.core.need(observed == intent['rootPhysical'], 'CLEANUP_ROOT_SUBSTITUTED_NO_FILES_TOUCHED')

    def helper_fingerprint(self, item):
        return {'id': item['Id'], 'image': item['Image'],
                'startedAt': item['State'].get('StartedAt'), 'pid': item['State'].get('Pid'),
                'configuration': hashlib.sha256(json.dumps({'config': item['Config'], 'host': item['HostConfig'],
                    'mounts': sorted(item['Mounts'], key=lambda r: json.dumps(r, sort_keys=True))},
                    sort_keys=True).encode()).hexdigest()}

    def helper_binding(self, item):
        self.core.need(self.helper_fingerprint(item) == self.core.private_json(self.phase / 'native-handler.json'),
                       'NATIVE_HANDLER_IDENTITY_CHANGED')

    def preparation_prerequisites(self, state):
        # A retained helper after an interrupted file operation is our sole
        # permitted addition during preparation. Deployment uses the original,
        # unfiltered inventory after this exact helper has been removed.
        original = self.core.inventory
        def preparation_inventory():
            rows = original()
            if '/' + self.helper in rows:
                self.helper_binding(self.core.inspect(self.helper))
                rows.pop('/' + self.helper)
            return rows
        try:
            self.core.inventory = preparation_inventory
            self.core.prerequisites(state)
        finally:
            self.core.inventory = original

    def close_helper(self):
        helper = self.core.inspect(self.helper)
        self.helper_binding(helper)
        self.core.need(helper['Config']['Labels'].get('gallery.confirmed-files.run') == str(self.root) and
                       helper['Image'] == self.hp.TARGET, 'VERIFIED_HELPER_CLEANUP_REQUIRED')
        self.core.docker('stop', '--time', '5', self.helper)
        self.core.docker('rm', self.helper)

    def values(self):
        snapshot = self.core.private_json(self.phase / 'queue-snapshot.json')
        # SHA is stored separately before file preparation/execution.
        seal = self.core.private_json(self.phase / 'inventory-seal.json')['sha256']
        self.core.need(hashlib.sha256(json.dumps(snapshot, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest() == seal,
                       'SEALED_QUEUE_SNAPSHOT_CHANGED')
        return {'snapshot': snapshot, 'snapshotSeal': seal}

    def gate(self):
        proof = self.core.private_json(self.phase / 'file-proofs.json')
        result = self.node('gate', **self.values(), **self.intent_values(), proof=proof)
        self.core.need(result.get('passed') is True, 'PRESERVED_QUEUE_GATE_FAILED')
        print('PASS no pending AssetDelete/FileDelete; other jobs unchanged and paused:', result['preserved'])
        return result

    def run(self, execute):
        self.hp.private(self.root, True)
        if not self.phase.exists():
            self.phase.mkdir(mode=0o700)
        self.hp.private(self.phase, True)
        lock = self.phase / '.operator.lock'
        with os.fdopen(os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600), 'w') as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                self.core.need(False, 'CONFIRMED_OPERATION_ALREADY_RUNNING')
            item = self.core.inspect(self.core.SERVER)
            self.core.identity(item)
            self.core.need(item['Image'] == self.hp.CURRENT, 'EXPECTED_CURRENT_IMAGE_REQUIRED')
            if not (self.phase / 'queue-snapshot.json').exists():
                snapshot = self.node('inventory')
                # Node's read-only gate/admission validates all jobs before any filesystem mutation.
                self.core.save(self.phase / 'queue-snapshot.json', snapshot)
                seal = hashlib.sha256(json.dumps(snapshot, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()
                self.core.save(self.phase / 'inventory-seal.json', {'sha256': seal})
            values = self.values()
            inventory = values['snapshot']
            counts = {}
            for job in inventory['jobs']:
                counts[job['name']] = counts.get(job['name'], 0) + 1
            print('INVENTORY job IDs/names only:', json.dumps([{
                'id': j['id'] if re.fullmatch('[0-9]+', j['id']) else 'NONNUMERIC_ID_' + hashlib.sha256(j['id'].encode()).hexdigest()[:12],
                'name': j['name'] if j['name'] in inventory['knownBackgroundJobs'] else 'UNKNOWN_JOB_NAME'} for j in inventory['jobs']]))
            print('INVENTORY counts:', json.dumps(counts, sort_keys=True))
            self.core.need(inventory['paused'] and inventory['counts']['paused'] == 27, 'EXPECTED_27_PAUSED_JOBS_REQUIRED')
            self.node('admit', **values)
            if not execute:
                print('READ_ONLY_INVENTORY_ONLY; no queue, filesystem or service mutation')
                return
            self.core.need(os.environ.get('GALLERY_USER_QUEUED_DELETION_APPROVED') == 'YES' and
                           os.environ.get('GALLERY_DEPLOYMENT_APPROVED') == 'YES', 'EXPLICIT_QUEUE_AND_IMAGE_APPROVAL_REQUIRED')
            intent_file = self.phase / 'cleanup-intent-v1.json'
            if any(j.get('data', {}).get('temporaryOwnerId') for j in inventory['jobs'] if j['id'] in IDS):
                producer = self.producer_contract()
                producer_file = self.phase / 'native-cleanup-producer-v1.json'
                if producer_file.exists():
                    self.core.need(self.core.private_json(producer_file) == producer, 'NATIVE_CLEANUP_PRODUCER_CHANGED')
                else:
                    self.core.save(producer_file, producer)
            if not intent_file.exists():
                intent = self.node('intent', **values)
                self.core.save(intent_file, intent)  # Read-only, before any helper RW bind or quarantine.
                self.core.save(self.phase / 'cleanup-intent-seal-v1.json', {'sha256': hashlib.sha256(
                    json.dumps(intent, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()})
            intent_values = self.intent_values()
            print('PASS existing native cleanup intent; sealed files:', len(intent_values['intent']['files']))
            # Prepare independently verified rollback before executing any deletion.
            if not (self.root / 'hardened-rollback').exists():
                self.core.run(['bash', str(Path(__file__).with_name('hp_build10_rollback.sh')),
                               'prepare-images', str(self.root)], timeout=1800)
            state = self.hp.binding(self.root, self.core)
            self.preparation_prerequisites(state)
            self.core.need(not (state / 'apply-attempt.json').exists(), 'EXISTING_APPLY_ATTEMPT_NO_AUTOMATIC_RETRY')
            proof_file = self.phase / 'file-proofs.json'
            completed = [self.core.private_json(path) for path in sorted(self.phase.glob('deletion-report-*.json'))
                         if self.core.private_json(path).get('completed') is True]
            if completed:
                result = completed[-1]
                self.gate()  # Idempotent resume after physical completion; no new helper/namespace/proofs.
            else:
                self.start_helper()
                if not proof_file.exists():
                    proof = self.node('prepare', **values, **intent_values)
                    self.core.save(proof_file, proof)  # Durable identity/checksum/quarantine names BEFORE capture/unlink.
                proof = self.core.private_json(proof_file)
                result = self.node('execute', **values, **intent_values, proof=proof)
                report = self.phase / ('deletion-report-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ') + '.json')
                self.core.save(report, result)
            print('DELETION_RESULT:', json.dumps(result, sort_keys=True))
            self.core.need(result.get('completed') is True, result.get('code', 'NATIVE_DELETION_INCOMPLETE'))
            self.gate()
            if self.core.docker('ps', '-aq', '--filter', 'name=^/' + self.helper + '$').split():
                self.close_helper()  # Restore the exact pre-plan inventory before deployment.
            # Narrow operator workflow only. The base tool's default empty-queue
            # gate is untouched; here a full sealed inventory proves preservation.
            self.core.queue_safety = self.gate
            self.core.execute(SimpleNamespace(state=state, execute_approved=False), rollback=False)
            try:
                self.core.execute(SimpleNamespace(state=state, execute_approved=True), rollback=False)
            except Exception:
                if (state / 'apply-attempt.json').exists() and not (state / 'rolled-back.json').exists():
                    self.core.execute(SimpleNamespace(state=state, execute_approved=True), rollback=True)
                    print('DEPLOYMENT_FAILED_HARDENED_ROLLBACK_VERIFIED')
                raise
            self.gate()
            self.core.save(self.phase / 'installation-report.json', {'source': self.hp.SOURCE, 'image': self.hp.TARGET,
                           'healthy': True, 'otherJobsPausedAndPreserved': result['preserved'],
                           'completedAt': datetime.now(timezone.utc).isoformat()})
            print('PASS exact ea51 image installed; API/microservices enabled; other services unchanged')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--run-root', type=Path, required=True)
    p.add_argument('--execute-approved', action='store_true')
    args = p.parse_args()
    os.umask(0o077)
    runner = None
    try:
        actor = pwd.getpwuid(os.getuid())
        if actor.pw_name != 'doctoriceadm' or args.run_root.parent != Path(actor.pw_dir) or \
                args.run_root.name != 'gallery-build10-release-TxDlXAuj':
            raise ValueError('RUN_AS_DOCTORICEADM_WITH_EXISTING_PRIVATE_ROOT')
        runner = Runner(args.run_root)
        runner.run(args.execute_approved)
        return 0
    except Exception as error:
        code = str(error)
        if not re.fullmatch('[A-Z][A-Z0-9_]{0,180}', code): code = 'PRIVATE_FAILURE_DETAILS_OMITTED'
        print('STOP ' + code, file=sys.stderr)
        if runner and runner.phase.exists():
            file = runner.phase / ('stop-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ') + '.json')
            runner.core.save(file, {'status': 'STOP', 'code': code, 'noAutomaticRetryOrQueueResume': True})
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
