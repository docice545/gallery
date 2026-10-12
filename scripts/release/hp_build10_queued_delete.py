#!/usr/bin/env python3
"""Confirmed FileDelete jobs, physical verification, preserved paused jobs, image-only update."""
import argparse
from datetime import datetime, timezone
import fcntl
from functools import wraps
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
KERNEL_PROFILE_PROBE = r'''import fs from 'node:fs/promises';
const s=await fs.readFile('/proc/1/status','utf8'),r={};
for(const k of ['CapEff','CapPrm','CapBnd','CapInh','CapAmb','NoNewPrivs','Seccomp'])
 r[k]=new RegExp('^'+k+':\\s*(\\S+)','m').exec(s)?.[1];
console.log(JSON.stringify(r));'''


def capability_names(values):
    # Docker versions serialize --cap-add FOWNER as FOWNER or CAP_FOWNER.
    # Keep cardinality/order: extra or duplicate capabilities still fail.
    if not isinstance(values, list) or not all(isinstance(v, str) for v in values):
        return None
    return [v.removeprefix('CAP_') for v in values]


def command_kind(command):
    # Fixed operation names only; never echo argv, stderr, credentials or paths.
    if command[:3] == ['sudo', '-n', 'realpath']: return 'HOST_MAPPING'
    prefix = 1 if command[:1] == ['docker'] else 3 if command[:3] == ['sudo', '-n', 'docker'] else None
    if prefix is not None:
        args = command[prefix:]
        if args and args[0].startswith('--host='): args = args[1:]
        if args and args[0] in ('exec', 'run', 'inspect', 'ps', 'compose', 'image', 'stop', 'rm'):
            return 'DOCKER_' + args[0].upper()
    return 'PRIVATE_SUBPROCESS'


def checked_command(core, original_run, stage, command, **kwargs):
    try:
        return original_run(command, **kwargs)
    except core.Stop as error:
        if str(error) == 'COMMAND_FAILED_PRIVATE_OUTPUT_OMITTED':
            raise core.Stop(stage + '_' + command_kind(command) + '_FAILED') from None
        raise


def command_stage(name):
    def decorate(method):
        @wraps(method)
        def scoped(self, *args, **kwargs):
            previous = self.command_stage
            self.command_stage = name
            try:
                return method(self, *args, **kwargs)
            finally:
                self.command_stage = previous
        return scoped
    return decorate


def security_profile(core, item, current):
    host = item['HostConfig']
    core.need(host.get('ReadonlyRootfs') is True and host.get('Privileged') is False,
              'SCOPED_HELPER_READONLY_PRIVILEGE_REQUIRED')
    core.need(capability_names(host.get('CapDrop')) == ['ALL'] and
              capability_names(host.get('CapAdd')) == ['FOWNER'], 'SCOPED_HELPER_CAPABILITIES_REQUIRED')
    core.need(host.get('Memory') == 512 * 1024 ** 2 and host.get('NanoCpus') == 500_000_000 and
              host.get('PidsLimit') == 128, 'SCOPED_HELPER_RESOURCE_LIMITS_REQUIRED')
    core.need(host.get('SecurityOpt') in (['no-new-privileges'], ['no-new-privileges:true']),
              'SCOPED_HELPER_NO_NEW_PRIVILEGES_REQUIRED')
    core.need(host.get('PidMode') == '' and host.get('IpcMode') in ('', 'private') and
              host.get('UTSMode') == '' and host.get('UsernsMode') == '', 'SCOPED_HELPER_PRIVATE_NAMESPACES_REQUIRED')
    core.need(not host.get('Devices') and not host.get('DeviceRequests') and not host.get('PortBindings'),
              'SCOPED_HELPER_NO_HOST_DEVICES_OR_PORTS_REQUIRED')
    core.need(host.get('NetworkMode') == 'container:' + current['Id'], 'SCOPED_HELPER_PINNED_NETWORK_REQUIRED')


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
        self.command_stage = 'PREFLIGHT'
        original_run = self.core.run
        def checked_run(command, **kwargs):
            return checked_command(self.core, original_run, self.command_stage, command, **kwargs)
        self.core.run = checked_run

    @command_stage('NATIVE_REQUEST')
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

    @command_stage('HANDLER_HASH_VERIFICATION')
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

    @command_stage('PRODUCER_VERIFICATION')
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

    def helper_mounts(self, current):
        media = self.values()['snapshot']['mediaRoot']
        self.core.need(media.startswith('/') and media == posixpath.normpath(media), 'VERIFIED_MEDIA_ROOT_REQUIRED')
        # Never grant RW to the whole upload tree or any library/external root.
        mounts = {}
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
            mounts[destination] = source
        return mounts

    def verify_helper(self, item, current):
        self.core.need(item['Image'] == self.hp.TARGET and item['State'].get('Running') and
                       item.get('Name') == '/' + self.helper and
                       item['Config'].get('Labels', {}).get('gallery.confirmed-files.run') == str(self.root),
                       'EXISTING_HELPER_NOT_OUR_RUNNING_NAMESPACE')
        security_profile(self.core, item, current)
        self.core.need(item['Config'].get('Entrypoint') == ['node'] and
                       item['Config'].get('Cmd') == ['-e', 'setInterval(()=>{},10000)'] and item.get('Path') == 'node' and
                       item.get('Args') == ['-e', 'setInterval(()=>{},10000)'], 'HELPER_IDLE_PROCESS_REQUIRED')
        mounts = self.helper_mounts(current)
        rows = current['Mounts']
        actual = item['Mounts']
        self.core.need(len({r['Destination'] for r in actual}) == len(actual) and
                       {r['Destination'] for r in actual} == {r['Destination'] for r in rows} | set(mounts),
                       'EXACT_SCOPED_HELPER_MOUNTS_REQUIRED')
        previous = {r['Destination']: r for r in rows}
        for row in actual:
            destination = row['Destination']
            if destination in mounts:
                self.core.need(row.get('RW') is True and row['Type'] == 'bind' and row['Source'] == mounts[destination] and
                               row.get('Propagation') == 'rprivate', 'SCOPED_HELPER_WRITABLE_BIND_CHANGED')
            else:
                before = previous[destination]
                self.core.need(row.get('RW') is False and all(row.get(k) == before.get(k) for k in
                               ('Type', 'Source', 'Name', 'Driver', 'Propagation')),
                               'NONSELECTED_ORIGINALS_AND_EVIDENCE_MUST_BE_READ_ONLY_IN_HELPER')
        self.handlers()
        self.verify_helper_roots()

    def verify_helper_roots(self):
        intent = self.intent_values()['intent']
        code = "import fs from 'node:fs/promises';const result=[];for(const path of " + json.dumps(
            [r['path'] for r in intent['rootPhysical']]) + \
            "){const s=await fs.stat(path,{bigint:true});result.push({path,device:String(s.dev),inode:String(s.ino),uid:String(s.uid),gid:String(s.gid)});}console.log(JSON.stringify(result));"
        observed = json.loads(self.core.run([*self.core.DOCKER, 'exec', self.helper, 'node', '--input-type=module', '-e', code]))
        self.core.need(observed == intent['rootPhysical'], 'CLEANUP_ROOT_SUBSTITUTED_NO_FILES_TOUCHED')

    @command_stage('HELPER_RECOVERY')
    def recover_unsealed_helper(self, item, current):
        # The old guard stopped AFTER docker run but BEFORE recording its identity.
        # Only this verified early failure may be recovered; never adopt a helper
        # once file preparation/deletion could have started.
        self.core.need(not (self.phase / 'file-proofs.json').exists() and
                       not list(self.phase.glob('deletion-report-*.json')) and
                       not (self.phase / 'installation-report.json').exists(), 'UNSEALED_HELPER_AFTER_FILE_WORK_FORBIDDEN')
        self.core.need(any(self.core.private_json(p).get('code') == 'SCOPED_HELPER_SECURITY_PROFILE_REQUIRED'
                           for p in self.phase.glob('stop-*.json')), 'VERIFIED_EARLY_HELPER_STOP_REQUIRED')
        fresh = self.node('intent', **self.values())  # Exact queue, owners/references, physical/mount roots; read-only.
        self.core.need(fresh == self.intent_values()['intent'], 'CLEANUP_INTENT_CHANGED_NO_HELPER_RECOVERY')
        self.verify_helper(item, current)
        self.command_stage = 'HELPER_RECOVERY_KERNEL'
        # Validate original private env-file against production; don't trust an
        # existing labelled helper with different credentials or process defaults.
        env_file = self.phase / 'native-handler.env'
        self.hp.private(env_file)
        expected_env = [v for v in current['Config']['Env'] if not v.split('=', 1)[0].startswith(
            ('IMMICH_SOURCE_', 'IMMICH_BUILD_', 'IMMICH_REPOSITORY'))]
        self.core.need(env_file.read_text() == '\n'.join(expected_env) + '\n', 'HELPER_ENV_SOURCE_CHANGED')
        target = self.core.image(self.hp.TARGET)['Config']
        def env_map(values):
            self.core.need(all('=' in v and '\n' not in v and '\r' not in v for v in values), 'HELPER_ENV_INVALID')
            pairs = [v.split('=', 1) for v in values]
            self.core.need(len({k for k, _ in pairs}) == len(pairs), 'HELPER_ENV_AMBIGUOUS')
            return dict(pairs)
        expected = {**env_map(target.get('Env', [])), **env_map(expected_env)}
        self.core.need(env_map(item['Config'].get('Env', [])) == expected and
                       all(item['Config'].get(k) == target.get(k) for k in ('User', 'WorkingDir')),
                       'UNSEALED_HELPER_ENV_OR_IMAGE_DEFAULTS_CHANGED')
        status = json.loads(self.core.run([*self.core.DOCKER, 'exec', self.helper, 'node', '--input-type=module', '-e', KERNEL_PROFILE_PROBE]))
        self.core.need(status.get('NoNewPrivs') == '1' and status.get('Seccomp') == '2' and
                       all(isinstance(status.get(k), str) and re.fullmatch('[0-9a-f]{1,16}', status[k]) and
                           (int(status[k], 16) & ~8) == 0 for k in ('CapEff', 'CapPrm', 'CapBnd')) and
                       int(status.get('CapBnd', '0'), 16) == 8 and
                       status.get('CapInh') == '0000000000000000' and status.get('CapAmb') == '0000000000000000',
                       'HELPER_KERNEL_SANDBOX_REQUIRED')
        self.core.need(self.core.inspect(self.core.SERVER)['Id'] == current['Id'] and
                       self.helper_fingerprint(self.core.inspect(self.helper)) == self.helper_fingerprint(item),
                       'HELPER_OR_SERVER_CHANGED_DURING_RECOVERY')
        self.core.save(self.phase / 'native-handler.json', self.helper_fingerprint(item))
        self.core.save(self.phase / ('helper-recovery-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ') + '.json'),
                       {'verifiedBeforeFilePreparation': True, 'intentSeal': self.intent_values()['intentSeal'],
                        'helperIdentity': self.helper_fingerprint(item), 'kernelSandboxVerified': True})
        print('PASS existing scoped helper revalidated after early STOP; no file preparation/deletion yet')

    def start_helper(self):
        current = self.core.inspect(self.core.SERVER)
        self.core.need(current['Image'] == self.hp.CURRENT, 'EXPECTED_CURRENT_IMAGE_REQUIRED')
        ids = self.core.docker('ps', '-aq', '--filter', 'name=^/' + self.helper + '$').split()
        if ids:
            self.core.need(len(ids) == 1, 'HELPER_AMBIGUOUS')
            item = self.core.inspect(self.helper)
            self.helper_binding(item)
            self.verify_helper(item, current)
            return
        mounts = self.helper_mounts(current)
        env_file = self.phase / 'native-handler.env'
        self.core.need(not env_file.exists(), 'FAILED_HELPER_CREATION_RETAINED_NO_ENV_OVERWRITE')
        env = [v for v in current['Config']['Env'] if not v.split('=', 1)[0].startswith(('IMMICH_SOURCE_', 'IMMICH_BUILD_', 'IMMICH_REPOSITORY'))]
        self.core.need(all('\n' not in value and '\r' not in value for value in env), 'SINGLE_LINE_HELPER_ENV_REQUIRED')
        with os.fdopen(os.open(env_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), 'w') as out:
            out.write('\n'.join(env) + '\n'); out.flush(); os.fsync(out.fileno())
        self.core.run([*self.core.DOCKER, 'run', '-d', '--pull', 'never', '--name', self.helper,
                       '--label', 'gallery.confirmed-files.run=' + str(self.root), '--network', 'container:' + self.core.SERVER,
                       '--volumes-from', self.core.SERVER + ':ro', *[value for destination, source in mounts.items()
                       for value in ('--mount', 'type=bind,src=' + source + ',dst=' + destination)], '--read-only', '--cap-drop', 'ALL',
                       '--cap-add', 'FOWNER', '--security-opt', 'no-new-privileges', '--pids-limit', '128',
                       '--memory', '512m', '--cpus', '0.5', '--env-file', str(env_file),
                       '--entrypoint', 'node', self.hp.TARGET, '-e', 'setInterval(()=>{},10000)'])
        item = self.core.inspect(self.helper)
        self.verify_helper(item, current)
        self.core.save(self.phase / 'native-handler.json', self.helper_fingerprint(item))

    def helper_fingerprint(self, item):
        return {'id': item['Id'], 'image': item['Image'],
                'startedAt': item['State'].get('StartedAt'), 'pid': item['State'].get('Pid'),
                'configuration': hashlib.sha256(json.dumps({'config': item['Config'], 'host': item['HostConfig'],
                    'mounts': sorted(item['Mounts'], key=lambda r: json.dumps(r, sort_keys=True))},
                    sort_keys=True).encode()).hexdigest()}

    def helper_binding(self, item):
        self.core.need(self.helper_fingerprint(item) == self.core.private_json(self.phase / 'native-handler.json'),
                       'NATIVE_HANDLER_IDENTITY_CHANGED')

    @command_stage('IMAGE_PREFLIGHT')
    def preparation_prerequisites(self, state):
        # A retained helper after an interrupted file operation is our sole
        # permitted addition during preparation. Deployment uses the original,
        # unfiltered inventory after this exact helper has been removed.
        original = self.core.inventory
        def preparation_inventory():
            rows = original()
            if '/' + self.helper in rows:
                item = self.core.inspect(self.helper)
                if not (self.phase / 'native-handler.json').exists():
                    self.recover_unsealed_helper(item, self.core.inspect(self.core.SERVER))
                self.helper_binding(item)
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
            self.command_stage = 'IMAGE_UPDATE_PREFLIGHT'
            self.core.execute(SimpleNamespace(state=state, execute_approved=False), rollback=False)
            try:
                self.command_stage = 'IMAGE_UPDATE'
                self.core.execute(SimpleNamespace(state=state, execute_approved=True), rollback=False)
            except Exception:
                if (state / 'apply-attempt.json').exists() and not (state / 'rolled-back.json').exists():
                    self.command_stage = 'HARDENED_ROLLBACK'
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
