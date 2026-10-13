#!/usr/bin/env python3
"""Plan and separately approve one existing HP server image update or rollback.

Only locally verified immutable image IDs are accepted. No image build/import,
queue mutation, library authorization or database recovery is performed.
"""
import argparse
import copy
from datetime import datetime, timezone
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request

DIRECTORY = Path('/opt/immich')
PROJECT = 'immich'
SERVICE = 'immich-server'
SERVER = 'immich_server'
POSTGRES = 'immich_postgres'
DOCKER = ['docker', '--host=unix:///var/run/docker.sock']
ID = r'sha256:[0-9a-f]{64}'
CAPABILITY = 'bound-root-quarantine-signed-recovery-v1'
OWNER_STORAGE_CAPABILITY = 'bound-root-quarantine-owner-storage-v2'
CONFIG_HASH_MODE = 'resolved-environment-compose-escaped-v1'
BOUND_MIGRATION = '1793700000000-BindDeletionRecovery'
# Upstream ships a .ts.ts source, hence a .ts.js compiled file and this exact
# existing Kysely ledger name. No other dotted or path-like names are accepted.
LEGACY_CHECKSUM_MIGRATION = '1774548649115-AddChecksumAlgorithm.ts'
IMAGE_PROBE = r'''
import fs from 'node:fs';import crypto from 'node:crypto';
const root='/usr/src/app/server',dist=root+'/dist';
const {AUTHORIZED_DELETION_CAPABILITY}=await import('file://'+dist+'/utils/authorized-deletion.js');
const hashes={};
for(const file of ['utils/authorized-deletion.js','utils/deletion-recovery.js',
 'repositories/asset.repository.js','repositories/storage.repository.js','services/asset.service.js',
 'services/library.service.js'])
 hashes[file]=crypto.createHash('sha256').update(fs.readFileSync(dist+'/'+file)).digest('hex');
const migrations=new Map();
for(const dir of ['migrations','migrations-gallery'])
 for(const file of fs.readdirSync(dist+'/schema/'+dir).filter(f=>f.endsWith('.js'))){
  const name=file.slice(0,-3),sha256=crypto.createHash('sha256').update(fs.readFileSync(dist+'/schema/'+dir+'/'+file)).digest('hex');
  if(migrations.has(name)&&migrations.get(name)!==sha256)throw new Error('Migration files differ');
  migrations.set(name,sha256);
 }
console.log(JSON.stringify({capability:AUTHORIZED_DELETION_CAPABILITY,
 sourceCommit:process.env.IMMICH_SOURCE_COMMIT,serverVersion:JSON.parse(fs.readFileSync(root+'/package.json')).version,
 guardFiles:hashes,migrations:[...migrations].sort(([a],[b])=>a.localeCompare(b)).map(([name,sha256])=>({name,sha256}))}));
'''
LIVE_MIGRATIONS = "SELECT coalesce(json_agg(name ORDER BY name),'[]'::json) FROM kysely_migrations;"


class Stop(Exception):
    pass


def need(value, code):
    if not value:
        raise Stop(code)


def run(command, timeout=30, input=None):
    local_env = dict(os.environ)
    for key in ('DOCKER_HOST', 'DOCKER_CONTEXT', 'DOCKER_TLS', 'DOCKER_TLS_VERIFY', 'DOCKER_CERT_PATH'):
        local_env.pop(key, None)
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout, input=input, env=local_env)
    need(result.returncode == 0, 'COMMAND_FAILED_PRIVATE_OUTPUT_OMITTED')
    return result.stdout


def docker(*args):
    return run([*DOCKER, *args])


def inspect(name):
    rows = json.loads(docker('inspect', name))
    need(len(rows) == 1, 'CONTAINER_INSPECTION_INCOMPLETE')
    return rows[0]


def image(image_id):
    need(re.fullmatch(ID, image_id or ''), 'IMMUTABLE_LOCAL_IMAGE_ID_REQUIRED')
    rows = json.loads(docker('image', 'inspect', image_id))
    need(len(rows) == 1 and rows[0]['Id'] == image_id and
         rows[0].get('Architecture') == 'amd64' and rows[0].get('Os') == 'linux',
         'LOCAL_IMAGE_ID_OR_PLATFORM_MISMATCH')
    return rows[0]


def migration_names(proof):
    return {row['name'] for row in proof['migrations']}


def valid_migration_name(name):
    return isinstance(name, str) and (name == LEGACY_CHECKSUM_MIGRATION or
                                     re.fullmatch(r'[0-9]{13}-[A-Za-z0-9_-]+', name) is not None)


def probe_image(image_id, source_commit, server_version, capability=CAPABILITY):
    """Read the actual packaged guard/migrations; never start application workers."""
    need(environment(image(image_id)).get('IMMICH_SOURCE_COMMIT') == source_commit, 'TARGET_SOURCE_MISMATCH')
    proof = json.loads(run([*DOCKER, 'run', '--rm', '--pull', 'never', '--network', 'none', '--read-only',
                           '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--pids-limit', '64',
                           '--memory', '256m', '--cpus', '1', '--entrypoint', 'node', image_id,
                           '--input-type=module', '-e', IMAGE_PROBE]))
    expected_version = '.'.join(str(part) for part in server_version)
    need(capability in (CAPABILITY, OWNER_STORAGE_CAPABILITY) and proof.get('capability') == capability and proof.get('sourceCommit') == source_commit and
         proof.get('serverVersion') == expected_version, 'HARDENED_IMAGE_CAPABILITY_SOURCE_VERSION_REQUIRED')
    files = proof.get('guardFiles', {})
    need(set(files) == {'utils/authorized-deletion.js', 'utils/deletion-recovery.js',
                        'repositories/asset.repository.js', 'repositories/storage.repository.js',
                        'services/asset.service.js', 'services/library.service.js'} and
         all(re.fullmatch('[0-9a-f]{64}', value or '') for value in files.values()),
         'PACKAGED_DELETION_GUARD_FILES_REQUIRED')
    migrations = proof.get('migrations', [])
    need(isinstance(migrations, list) and 0 < len(migrations) <= 1000 and
         all(isinstance(row, dict) and set(row) == {'name', 'sha256'} and
             valid_migration_name(row.get('name')) and
             re.fullmatch('[0-9a-f]{64}', row.get('sha256', '')) for row in migrations),
         'PACKAGED_MIGRATION_PROOF_REQUIRED')
    names = migration_names(proof)
    need(len(names) == len(migrations) and BOUND_MIGRATION in names, 'BOUND_DELETION_MIGRATION_REQUIRED')
    return proof


def proof_digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def rollback_compatibility(candidate, rollback, reviewed=None):
    if reviewed is None:
        need(candidate['migrations'] == rollback['migrations'], 'HARDENED_ROLLBACK_MIGRATIONS_MUST_MATCH')
        need(candidate['guardFiles'] == rollback['guardFiles'], 'HARDENED_ROLLBACK_GUARD_FILES_MUST_MATCH')
        return
    need(reviewed.get('schemaVersion') == 1 and reviewed.get('contract') == 'build11-reviewed-additive-upgrade-v1',
         'REVIEWED_COMPATIBILITY_CONTRACT_REQUIRED')
    for field, actual in (('candidateProofSHA256', candidate), ('rollbackProofSHA256', rollback)):
        need(reviewed.get(field) == proof_digest(actual), 'REVIEWED_PACKAGED_PROOF_MISMATCH')
    need(candidate['capability'] == OWNER_STORAGE_CAPABILITY and rollback['capability'] == CAPABILITY,
         'REVIEWED_STORAGE_AND_RECOVERY_GUARDS_REQUIRED')
    old = {r['name']: r['sha256'] for r in rollback['migrations']}
    new = {r['name']: r['sha256'] for r in candidate['migrations']}
    need(old.keys() <= new.keys() and all(new[k] == v for k, v in old.items()),
         'APPLIED_MIGRATIONS_REMOVED_OR_CHANGED')
    added = [{'name': k, 'sha256': new[k]} for k in sorted(new.keys() - old.keys())]
    declared = reviewed.get('migrationsAdded')
    need(isinstance(declared, list) and len(declared) == 1 and
         declared[0].get('name') == '1794050000000-OwnerStorageDeletion' and
         re.fullmatch('[0-9a-f]{64}', declared[0].get('sha256', '')), 'ONLY_REVIEWED_ADDITIVE_STORAGE_MODE_ALLOWED')
    if added:
        need(added == declared, 'ONLY_REVIEWED_ADDITIVE_STORAGE_MODE_ALLOWED')
    else:
        # A hardened fallback may include this exact forward-only migration,
        # because Kysely refuses applied names whose source files are absent.
        # This is a separately built, tested image, never a runtime bind/alias.
        selected = declared[0]
        need(reviewed.get('rollbackContainsAdditiveMigration') is True and
             old.get(selected['name']) == new.get(selected['name']) == selected['sha256'],
             'REVIEWED_FORWARD_MIGRATION_IN_ROLLBACK_REQUIRED')
    checks = {'isolatedDatabase': True, 'oldRuntimeStartsOnUpgradedSchema': True,
              'storagePoliciesRejectedByRollback': True, 'trashRestoreAfterRollback': True,
              'syntheticMediaOnly': True, 'productionChanged': False}
    need(reviewed.get('rollbackTest') == checks and re.fullmatch('[0-9a-f]{64}', reviewed.get('testReportSHA256', '')),
         'REAL_ISOLATED_ROLLBACK_TEST_REPORT_REQUIRED')


def reviewed_compatibility(args):
    path, expected = getattr(args, 'compatibility_receipt', None), getattr(args, 'compatibility_sha256', None)
    if path is None and expected is None:
        return None
    need(path is not None and re.fullmatch('[0-9a-f]{64}', expected or '') and
         path.is_file() and not path.is_symlink() and path.stat().st_size <= 1024 * 1024 and sha(path) == expected,
         'PINNED_REVIEWED_COMPATIBILITY_RECEIPT_REQUIRED')
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), 'rb') as file:
        raw = file.read(1024 * 1024 + 1)
    need(len(raw) <= 1024 * 1024 and hashlib.sha256(raw).hexdigest() == expected,
         'PINNED_REVIEWED_COMPATIBILITY_RECEIPT_REQUIRED')
    value = json.loads(raw)
    need(value.get('candidateImage') == args.image and value.get('candidateSource') == args.source_commit and
         value.get('rollbackImage') == args.rollback_image and value.get('rollbackSource') == args.rollback_source_commit,
         'REVIEWED_COMPATIBILITY_IMAGE_SOURCE_MISMATCH')
    return value


def postgres():
    item = inspect(POSTGRES)
    labels = item['Config'].get('Labels', {})
    need(item.get('Name') == '/' + POSTGRES and labels.get('com.docker.compose.project') == PROJECT and
         labels.get('com.docker.compose.service') and item['State'].get('Running'), 'EXISTING_LOCAL_POSTGRES_REQUIRED')
    env = environment(item)
    need(not env.get('POSTGRES_USER_FILE') and not env.get('POSTGRES_DB_FILE'),
         'SECRET_FILE_POSTGRES_BINDING_UNSUPPORTED')
    user = env.get('POSTGRES_USER', 'postgres')
    return labels['com.docker.compose.service'], user, env.get('POSTGRES_DB', user)


def database_binding(config, target):
    """Only the verified local PG may supply migration evidence, even with a stopped API."""
    service, user, database = postgres()
    env = merged_environment(config, target)
    need(not env.get('CREDENTIALS_DIRECTORY') and
         not any(env.get(key) for key in env if key.startswith('DB_') and key.endswith('_FILE')),
         'SECRET_FILE_DATABASE_BINDING_UNSUPPORTED')
    if env.get('DB_URL'):
        parsed = urllib.parse.urlsplit(env['DB_URL'])
        need(parsed.scheme in ('postgres', 'postgresql') and not parsed.query and not parsed.fragment,
             'LOCAL_POSTGRES_BINDING_REQUIRED')
        host, port = parsed.hostname, parsed.port or 5432
        actual_user, actual_database = urllib.parse.unquote(parsed.username or ''), urllib.parse.unquote(parsed.path[1:])
    else:
        host, port = env.get('DB_HOSTNAME', 'database'), int(env.get('DB_PORT', '5432'))
        actual_user, actual_database = env.get('DB_USERNAME', 'postgres'), env.get('DB_DATABASE_NAME', 'immich')
    need(host in (service, POSTGRES) and port == 5432 and actual_user == user and actual_database == database,
         'LOCAL_POSTGRES_BINDING_REQUIRED')


def live_migrations():
    _, user, database = postgres()
    names = json.loads(run([*DOCKER, 'exec', '--env',
                           'PGOPTIONS=-c default_transaction_read_only=on -c statement_timeout=3000',
                           POSTGRES, 'psql', '-X', '--quiet', '-A', '-t', '--set', 'ON_ERROR_STOP=on',
                           '-h', '/var/run/postgresql', '-p', '5432',
                           '-U', user, '-d', database, '--command', LIVE_MIGRATIONS], timeout=30))
    need(isinstance(names, list) and names and len(set(names)) == len(names) and
         all(valid_migration_name(name) for name in names),
         'LIVE_MIGRATION_INVENTORY_REQUIRED')
    return set(names)


def environment(item):
    return dict(value.split('=', 1) for value in item.get('Config', {}).get('Env', []) if '=' in value)


def workers(env):
    # Mirror ConfigRepository.asSet: remove all whitespace; empty means defaults.
    def values(key, defaults):
        found = set(filter(None, re.sub(r'\s', '', str(env.get(key) or '')).split(',')))
        return found or defaults
    active = values('IMMICH_WORKERS_INCLUDE', {'api', 'microservices'}) - values('IMMICH_WORKERS_EXCLUDE', set())
    need({'api', 'microservices'} <= active and active <= {'api', 'microservices', 'maintenance'},
         'API_AND_MICROSERVICES_REQUIRED')


def merged_environment(config, target):
    env = environment(target)
    for key, value in config['services'][SERVICE].get('environment', {}).items():
        if value is None:
            env.pop(key, None)
        else:
            env[key] = str(value)
    return env


def sha(path):
    with path.open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()


def save(path, value):
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), 'w') as file:
        json.dump(value, file, indent=2)
        file.write('\n')
        file.flush()
        os.fsync(file.fileno())


def private_json(path):
    need(path.is_file() and not path.is_symlink() and path.stat().st_mode & 0o777 == 0o600,
         'PRIVATE_REGULAR_0600_RECEIPT_REQUIRED')
    return json.loads(path.read_text())


def identity(item, require_running=True):
    labels = item['Config'].get('Labels', {})
    need(item.get('Name') == '/' + SERVER and labels.get('com.docker.compose.project') == PROJECT and
         labels.get('com.docker.compose.service') == SERVICE and
         labels.get('com.docker.compose.project.working_dir') == str(DIRECTORY),
         'EXISTING_HP_COMPOSE_SERVER_REQUIRED')
    need(not require_running or item['State'].get('Running'), 'EXISTING_SERVER_NOT_RUNNING')
    return labels


def compose_base(item):
    labels = identity(item)
    files = [Path(value) for value in labels.get('com.docker.compose.project.config_files', '').split(',') if value]
    need(files and files[0] == DIRECTORY / 'docker-compose.yml' and
         all(path.is_absolute() and path.is_file() and not path.is_symlink() for path in files),
         'ACTUAL_COMPOSE_FILES_REQUIRED')
    base = [*DOCKER, 'compose', '--project-directory', str(DIRECTORY), '-p', PROJECT]
    for path in files:
        base.extend(['-f', str(path)])
    return base, files


def effective(base, override=None):
    return json.loads(run([*base, *(['-f', str(override)] if override else []), 'config', '--format', 'json']))


def config_hash(base, override=None):
    # Compose's config --hash uses WithoutEnvironmentResolution. Unlike create/up,
    # it omits env_file contents, so hashing the source files gives a false drift
    # alarm. Hash the already resolved model instead, using the SAME Compose
    # ServiceHash implementation. Compose escapes literal $ as $$ in this output:
    # its loader reverses that escape once, WITHOUT expanding the original value.
    # --no-interpolate would wrongly retain doubled dollars and give a bad hash.
    # Pass private values through stdin, never argv, a public file or diagnostics.
    resolved = effective(base, override)
    need('-f' in base, 'ACTUAL_COMPOSE_FILES_REQUIRED')
    prefix = base[:base.index('-f')]
    parts = run([*prefix, '-f', '-', 'config', '--hash', SERVICE],
                input=json.dumps(resolved)).split()
    need(len(parts) == 2 and parts[0] == SERVICE and re.fullmatch('[0-9a-f]{64}', parts[1]),
         'COMPOSE_CONFIG_HASH_UNAVAILABLE')
    return parts[1]


def image_only(before, after, target):
    expected = copy.deepcopy(before)
    need(SERVICE in expected.get('services', {}), 'SERVER_SERVICE_MISSING')
    expected['services'][SERVICE]['image'] = target
    need(after == expected, 'COMPOSE_CHANGED_BEYOND_SELECTED_IMAGE')


def queue_safety():
    # Reuse the existing bounded, read-only queue collector and atomic LLEN/ZCARD
    # checks. No SCAN-only emptiness claim, pause, retry, delete or worker switch.
    modules = {}
    for name in ('trash_release', 'trash_predeploy'):
        path = Path(__file__).with_name(name + '.py')
        need(path.is_file() and not path.is_symlink(), 'REVIEWED_QUEUE_HELPERS_REQUIRED')
        spec = importlib.util.spec_from_file_location('image_queue_' + name, path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        modules[name] = module
    legacy, predeploy = modules['trash_release'], modules['trash_predeploy']
    program = legacy.NODE_BASE + predeploy.QUEUE_BODY.replace('__LUA__', json.dumps(predeploy.COUNTS_LUA))
    row = json.loads(run([*DOCKER, 'exec', '-i', SERVER, 'node', '--input-type=module'], input=program))
    states = set(legacy.STATES)
    need(isinstance(row, dict) and not row.get('error') and row.get('atomic') is True and
         row.get('inventoryComplete') is True and type(row.get('unresolvedDeletionHashes')) is int and
         row['unresolvedDeletionHashes'] == 0 and
         set(row.get('deletionNames', {})) == {'AssetDelete', 'FileDelete'} and
         all(type(n) is int and n == 0 for n in row['deletionNames'].values()) and
         all(set(row.get(field, {})) == states and
             all(type(n) is int and n == 0 for n in row[field].values()) for field in ('before', 'counts')),
         'DELETION_QUEUES_NONEMPTY_OR_INCOMPLETE_NO_JOBS_CHANGED')
    print('PASS atomic deletion queue counts and legacy inventory; empty at this instant only')
    return row


def inventory():
    ids = docker('ps', '-aq', '--no-trunc').split()
    need(ids, 'LOCAL_CONTAINER_INVENTORY_EMPTY')
    rows = json.loads(docker('inspect', *ids))
    need(len(rows) == len(ids), 'LOCAL_CONTAINER_INVENTORY_INCOMPLETE')
    return {item['Name']: {'id': item['Id'], 'image': item['Image'], 'running': item['State']['Running']}
            for item in rows if item['Name'] != '/' + SERVER}


def ping(api_base, path):
    url = urllib.parse.urlsplit(api_base)
    need(url.scheme == 'http' and url.hostname == '127.0.0.1' and url.port and url.path == '/api' and
         not url.username and not url.password and not url.query and not url.fragment, 'LOCAL_API_REQUIRED')
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            raise Stop('LOCAL_API_REDIRECT_REJECTED')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(api_base + path, timeout=10) as response:
        return json.load(response)


def health(api_base, target, source, version, timeout=90):
    deadline = time.monotonic() + timeout
    while True:
        try:
            item = inspect(SERVER)
            identity(item)
            need(item['Image'] == target and item['State'].get('Health', {}).get('Status') == 'healthy',
                 'SERVER_IMAGE_OR_HEALTH_MISMATCH')
            workers(environment(item))
            need(not source or environment(item).get('IMMICH_SOURCE_COMMIT') == source, 'SERVER_SOURCE_MISMATCH')
            need(ping(api_base, '/server/ping') == {'res': 'pong'} and
                 ping(api_base, '/server/version') == version, 'SERVER_API_VERSION_MISMATCH')
            return item
        except Exception:
            need(time.monotonic() < deadline, 'SERVER_HEALTH_FAILED_REVIEW_PLAN_FOR_ROLLBACK')
            time.sleep(2)


def plan(args):
    state = args.state
    need(not any(state.iterdir()), 'NEW_EMPTY_PRIVATE_STATE_REQUIRED')
    old = inspect(SERVER)
    base, files = compose_base(old)
    need(old['Image'] == args.expected_current_image, 'CURRENT_IMAGE_CHANGED')
    previous, target = image(old['Image']), image(args.image)
    need(old['Image'] != args.image, 'TARGET_ALREADY_RUNNING')
    need(environment(target).get('IMMICH_SOURCE_COMMIT') == args.source_commit, 'TARGET_SOURCE_MISMATCH')
    before = effective(base)
    need(json.loads(docker('image', 'inspect', before['services'][SERVICE]['image']))[0]['Id'] == old['Image'],
         'COMPOSE_IMAGE_DIFFERS_FROM_RUNNING_SERVER')
    actual_hash = config_hash(base)
    running_hash = identity(old).get('com.docker.compose.config-hash')
    need(re.fullmatch('[0-9a-f]{64}', running_hash or ''), 'RUNNING_COMPOSE_HASH_REQUIRED')
    need(actual_hash == running_hash,
         f'COMPOSE_DIFFERS_FROM_RUNNING_SERVER running={running_hash} resolved={actual_hash}')
    print('PASS resolved env-file configuration hash equals running container')
    workers(environment(old))
    workers(merged_environment(before, previous))
    workers(merged_environment(before, target))
    need(merged_environment(before, target).get('IMMICH_SOURCE_COMMIT') == args.source_commit,
         'COMPOSE_OVERRIDES_TARGET_SOURCE')
    version = {'major': args.server_version[0], 'minor': args.server_version[1],
               'patch': args.server_version[2], 'prerelease': None}
    old_version = ping(args.api, '/server/version')
    rollback_image = getattr(args, 'rollback_image', None) or old['Image']
    need(rollback_image != args.image, 'DISTINCT_HARDENED_ROLLBACK_IMAGE_REQUIRED')
    rollback_source = getattr(args, 'rollback_source_commit', None) or environment(previous).get('IMMICH_SOURCE_COMMIT')
    rollback_version = getattr(args, 'rollback_server_version', None) or tuple(old_version[key] for key in ('major', 'minor', 'patch'))
    need(re.fullmatch('[0-9a-f]{40}', rollback_source or ''), 'REVIEWED_ROLLBACK_SOURCE_REQUIRED')
    compatibility = reviewed_compatibility(args)
    candidate_proof = probe_image(args.image, args.source_commit, args.server_version, OWNER_STORAGE_CAPABILITY) if compatibility else probe_image(args.image, args.source_commit, args.server_version)
    rollback_proof = probe_image(rollback_image, rollback_source, rollback_version)
    # Recognition markers alone are insufficient: the rollback application must
    # retain the descriptor, authenticated recovery and policy guards itself.
    rollback_compatibility(candidate_proof, rollback_proof, compatibility)
    workers(merged_environment(before, image(rollback_image)))
    need(merged_environment(before, image(rollback_image)).get('IMMICH_SOURCE_COMMIT') == rollback_source,
         'COMPOSE_OVERRIDES_ROLLBACK_SOURCE')
    for selected in (previous, target, image(rollback_image)):
        need((selected['Config'].get('Volumes') or {}) == (previous['Config'].get('Volumes') or {}),
             'IMAGE_VOLUME_DEFAULTS_CHANGED')
        database_binding(before, selected)
    live = live_migrations()
    need(live <= migration_names(candidate_proof), 'CANDIDATE_MISSING_APPLIED_MIGRATION')
    health(args.api, old['Image'], environment(old).get('IMMICH_SOURCE_COMMIT'), old_version, timeout=0)
    override = state / 'image-only.override.json'
    other = inventory()
    save(override, {'services': {SERVICE: {'image': args.image}}})
    after = effective(base, override)
    image_only(before, after, args.image)
    save(state / 'base-config.json', before)
    save(state / 'planned-config.json', after)
    # Compose/.env hashes plus effective config checks detect interpolation/env-file drift.
    dotenv = DIRECTORY / '.env'
    if dotenv.exists():
        need(dotenv.is_file() and not dotenv.is_symlink(), 'REGULAR_DOTENV_REQUIRED')
        files.append(dotenv)
    receipt = {'schemaVersion': 1, 'configHashMode': CONFIG_HASH_MODE,
               'createdAt': datetime.now(timezone.utc).isoformat(), 'base': base,
               'previousImage': old['Image'], 'candidateImage': args.image, 'previousContainer': old['Id'],
               'previousSource': environment(old).get('IMMICH_SOURCE_COMMIT'), 'sourceCommit': args.source_commit,
               'previousVersion': old_version, 'serverVersion': version, 'api': args.api,
               'rollbackImage': rollback_image, 'rollbackSource': rollback_source,
               'rollbackVersion': {'major': rollback_version[0], 'minor': rollback_version[1],
                                   'patch': rollback_version[2], 'prerelease': None},
               'candidateProof': candidate_proof, 'rollbackProof': rollback_proof,
               'liveMigrations': sorted(live), 'migrationsAdded': sorted(migration_names(candidate_proof) - live),
               'fileHashes': {str(path): sha(path) for path in files}, 'otherContainers': other,
               'baseConfigSHA256': sha(state / 'base-config.json'),
               'plannedConfigSHA256': sha(state / 'planned-config.json'), 'overrideSHA256': sha(override),
               'previousConfigHash': config_hash(base), 'candidateConfigHash': config_hash(base, override)}
    if compatibility:
        save(state / 'reviewed-compatibility.json', compatibility)
        receipt['reviewedCompatibilitySHA256'] = sha(state / 'reviewed-compatibility.json')
    need(inspect(SERVER)['Id'] == old['Id'] and inventory() == receipt['otherContainers'],
         'CONTAINERS_CHANGED_DURING_PLAN')
    save(state / 'image-plan.json', receipt)
    print('PASS private image-only plan; no services, jobs or policies changed')


def prerequisites(state, rollback=False):
    receipt = private_json(state / 'image-plan.json')
    need(receipt.get('configHashMode') == CONFIG_HASH_MODE, 'NEW_RESOLVED_COMPOSE_PLAN_REQUIRED')
    need(receipt.get('schemaVersion') == 1 and receipt['base'][:2] == DOCKER[:2] and
         receipt['base'] == [*DOCKER, 'compose', '--project-directory', str(DIRECTORY), '-p', PROJECT,
                             *[value for path in receipt['fileHashes'] if path != str(DIRECTORY / '.env')
                               for value in ('-f', path)]], 'PLAN_COMPOSE_INVOCATION_CHANGED')
    for filename, field in [('base-config.json', 'baseConfigSHA256'), ('planned-config.json', 'plannedConfigSHA256'),
                            ('image-only.override.json', 'overrideSHA256')]:
        private_json(state / filename)
        need(sha(state / filename) == receipt[field], 'PLAN_FILE_CHANGED')
    need(all(Path(path).is_file() and not Path(path).is_symlink() and sha(Path(path)) == value
             for path, value in receipt['fileHashes'].items()), 'COMPOSE_FILES_CHANGED')
    before = private_json(state / 'base-config.json')
    need(effective(receipt['base']) == before, 'EFFECTIVE_COMPOSE_CHANGED')
    after = effective(receipt['base'], state / 'image-only.override.json')
    image_only(before, after, receipt['candidateImage'])
    need(after == private_json(state / 'planned-config.json'), 'PLANNED_COMPOSE_CHANGED')
    item = inspect(SERVER)
    labels = identity(item, require_running=not rollback)
    accepted_images = (receipt['previousImage'], receipt['candidateImage'])
    if rollback and (state / 'rolled-back.json').exists():
        restored = private_json(state / 'rolled-back.json')
        need(restored.get('image') == receipt['rollbackImage'] and restored.get('container') == item['Id'],
             'RECORDED_ROLLBACK_CONTAINER_CHANGED')
        accepted_images = (*accepted_images, receipt['rollbackImage'])
    need(item['Image'] in accepted_images, 'LIVE_IMAGE_CHANGED_EXTERNALLY')
    if not rollback:
        need(item['Id'] == receipt['previousContainer'] and item['Image'] == receipt['previousImage'],
             'SERVER_CHANGED_SINCE_PLAN')
    expected_hash = receipt['previousConfigHash'] if item['Image'] == receipt['previousImage'] else receipt['candidateConfigHash']
    if item['Image'] == receipt['rollbackImage'] and (state / 'rolled-back.json').exists():
        expected_hash = config_hash(receipt['base'], state / 'rollback-image-only.override.json')
    need(labels.get('com.docker.compose.config-hash') == expected_hash, 'LIVE_COMPOSE_CHANGED_EXTERNALLY')
    need(inventory() == receipt['otherContainers'], 'UNRELATED_CONTAINERS_CHANGED')
    workers(environment(item))
    for selected in (receipt['previousImage'], receipt['candidateImage'], receipt['rollbackImage']):
        selected_image = image(selected)
        workers(merged_environment(before, selected_image))
        database_binding(before, selected_image)
    compatibility = None
    if receipt.get('reviewedCompatibilitySHA256'):
        compatibility = private_json(state / 'reviewed-compatibility.json')
        need(sha(state / 'reviewed-compatibility.json') == receipt['reviewedCompatibilitySHA256'],
             'REVIEWED_COMPATIBILITY_RECEIPT_CHANGED')
    for selected, source, version, field in (
        (receipt['candidateImage'], receipt['sourceCommit'], receipt['serverVersion'], 'candidateProof'),
        (receipt['rollbackImage'], receipt['rollbackSource'], receipt['rollbackVersion'], 'rollbackProof'),
    ):
        actual = probe_image(selected, source, tuple(version[key] for key in ('major', 'minor', 'patch')), OWNER_STORAGE_CAPABILITY) if compatibility and field == 'candidateProof' else probe_image(selected, source, tuple(version[key] for key in ('major', 'minor', 'patch')))
        need(actual == receipt[field], 'PACKAGED_IMAGE_PROOF_CHANGED')
    rollback_compatibility(receipt['candidateProof'], receipt['rollbackProof'], compatibility)
    live = live_migrations()
    need(set(receipt['liveMigrations']) <= live <= migration_names(receipt['candidateProof']),
         'LIVE_MIGRATIONS_CHANGED_EXTERNALLY')
    if not rollback:
        need(live == set(receipt['liveMigrations']), 'LIVE_MIGRATIONS_CHANGED_SINCE_PLAN')
    return receipt, item


def authorized(args):
    need(args.execute_approved and os.environ.get('GALLERY_DEPLOYMENT_APPROVED') == 'YES',
         'SEPARATE_EXPLICIT_DEPLOYMENT_APPROVAL_REQUIRED')


def execute(args, rollback=False):
    state = args.state
    need(not (state / ('rolled-back.json' if rollback else 'apply-attempt.json')).exists(),
         'EXISTING_ATTEMPT_RETAINED_DO_NOT_REPEAT')
    receipt, item = prerequisites(state, rollback)
    if rollback:
        need((state / 'apply-attempt.json').exists(), 'UPDATE_ATTEMPT_REQUIRED_FOR_ROLLBACK')
    if not args.execute_approved:
        if not rollback:
            queue_safety()
        print('PASS ' + ('rollback' if rollback else 'update') + ' preflight; dry-run, no mutation')
        return
    authorized(args)
    fd = os.open(state / '.execution.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        # Check again under the lock before writing an attempt or recreating.
        need(not (state / ('rollback-attempt.json' if rollback else 'apply-attempt.json')).exists(),
             'EXISTING_ATTEMPT_RETAINED_DO_NOT_REPEAT')
        receipt, item = prerequisites(state, rollback)
        target = receipt['rollbackImage'] if rollback else receipt['candidateImage']
        override = state / ('rollback-image-only.override.json' if rollback else 'image-only.override.json')
        if rollback and not override.exists():
            save(override, {'services': {SERVICE: {'image': target}}})
        need(private_json(override) == {'services': {SERVICE: {'image': target}}}, 'IMAGE_OVERRIDE_CHANGED')
        image_only(private_json(state / 'base-config.json'), effective(receipt['base'], override), target)
        pending = migration_names(receipt['rollbackProof'] if rollback else receipt['candidateProof']) - live_migrations()
        if pending:
            need(getattr(args, 'approve_migration', False) and os.environ.get('GALLERY_ADDITIVE_MIGRATION_APPROVED') == 'YES',
                 'SEPARATE_ADDITIVE_MIGRATION_APPROVAL_REQUIRED')
        if not rollback:
            queue_safety()  # Last bounded observation immediately before update; not a durable pause.
        attempt = state / ('rollback-attempt.json' if rollback else 'apply-attempt.json')
        save(attempt, {'targetImage': target, 'migrationsApproved': sorted(pending),
                       'startedAt': datetime.now(timezone.utc).isoformat()})
        changed = item['Image'] != target or not item['State'].get('Running')
        if changed:
            run([*receipt['base'], '-f', str(override), 'up', '-d', '--no-deps', '--no-build', '--pull', 'never', SERVICE], timeout=180)
        source = receipt['rollbackSource'] if rollback else receipt['sourceCommit']
        version = receipt['rollbackVersion'] if rollback else receipt['serverVersion']
        current = health(receipt['api'], target, source, version)
        expected_hash = config_hash(receipt['base'], override) if changed else receipt['previousConfigHash']
        need(identity(current).get('com.docker.compose.config-hash') == expected_hash,
             'RECREATED_SERVER_CONFIG_MISMATCH')
        need(inventory() == receipt['otherContainers'], 'UNRELATED_CONTAINERS_CHANGED')
        migrated = live_migrations()
        need(migrated == migration_names(receipt['candidateProof']),
             'APPLIED_MIGRATION_INVENTORY_MISMATCH')
        need(all(sha(Path(path)) == value for path, value in receipt['fileHashes'].items()) and
             effective(receipt['base']) == private_json(state / 'base-config.json'), 'COMPOSE_CHANGED_DURING_UPDATE')
        save(state / ('rolled-back.json' if rollback else 'applied.json'),
             {'image': target, 'container': current['Id'], 'workerConfiguration': 'API_AND_MICROSERVICES',
              'completedAt': datetime.now(timezone.utc).isoformat()})
    print('PASS image-only ' + ('rollback' if rollback else 'update') + '; verify disposable thumbnail/preview jobs separately')


def version(value):
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', value):
        raise argparse.ArgumentTypeError('SEMANTIC_SERVER_VERSION_REQUIRED')
    return tuple(int(part) for part in value.split('.'))


def main(argv=None):
    global DOCKER
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('plan', 'apply', 'rollback'))
    parser.add_argument('--state', required=True, type=Path)
    parser.add_argument('--image')
    parser.add_argument('--expected-current-image')
    parser.add_argument('--source-commit')
    parser.add_argument('--server-version', type=version)
    parser.add_argument('--rollback-image', help='Separately reviewed hardened immutable rollback image; defaults to current image')
    parser.add_argument('--rollback-source-commit')
    parser.add_argument('--rollback-server-version', type=version)
    parser.add_argument('--compatibility-receipt', type=Path, help='Public reviewed Build11 image/migration/rollback proof')
    parser.add_argument('--compatibility-sha256', help='Exact reviewed compatibility receipt checksum from release handoff')
    parser.add_argument('--api', default='http://127.0.0.1:2283/api')
    parser.add_argument('--execute-approved', action='store_true')
    parser.add_argument('--approve-migration', action='store_true')
    parser.add_argument('--sudo-docker', action='store_true', help='Use existing sudo -n Docker authorization')
    args = parser.parse_args(argv)
    try:
        DOCKER = ['docker', '--host=unix:///var/run/docker.sock']
        args.state = args.state.absolute()
        need(args.state.is_dir() and not args.state.is_symlink() and args.state.stat().st_mode & 0o777 == 0o700,
             'EXISTING_PRIVATE_0700_STATE_REQUIRED')
        if args.execute_approved:
            need(args.action != 'plan', 'PLAN_NEVER_EXECUTES')
            authorized(args)
        if args.sudo_docker:
            DOCKER = ['sudo', '-n', 'docker', '--host=unix:///var/run/docker.sock']
        if args.action == 'plan':
            need(re.fullmatch('[0-9a-f]{40}', args.source_commit or '') and args.server_version and
                 re.fullmatch(ID, args.image or '') and re.fullmatch(ID, args.expected_current_image or ''),
                 'EXACT_VERIFIED_IMAGE_SOURCE_VERSION_REQUIRED')
            if args.rollback_image or args.rollback_source_commit or args.rollback_server_version:
                need(re.fullmatch(ID, args.rollback_image or '') and
                     re.fullmatch('[0-9a-f]{40}', args.rollback_source_commit or '') and args.rollback_server_version,
                     'EXACT_HARDENED_ROLLBACK_IMAGE_SOURCE_VERSION_REQUIRED')
            plan(args)
        else:
            execute(args, args.action == 'rollback')
        return 0
    except Exception as error:
        print('STOP ' + (str(error) if isinstance(error, Stop) else 'OPERATION_FAILED_PRIVATE_DETAILS_OMITTED'), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
