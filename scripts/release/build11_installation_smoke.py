#!/usr/bin/env python3
"""Actual compiled-package installation/upgrade lab; isolated CI only.

This invokes the packaged installer and image-only engine. It never creates HP
recovery evidence, authorizes a production library, or connects to an HP daemon.
The small fault injections interrupt real configuration/startup operations;
they do not replace Docker, PostgreSQL, HTTP, migration or queue assertions.
"""
import argparse
import ast
from datetime import datetime, timezone
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import socket
import subprocess
import sys
import tempfile
import time
import traceback
from types import SimpleNamespace
import urllib.error
import urllib.parse
import urllib.request

from gallery_entry import verify_package
import server_artifact_smoke as media

SOCKET = 'unix:///var/run/docker.sock'
PROJECT = 'immich'
NAMES = ('immich_server', 'immich_postgres', 'immich_redis', 'immich_machine_learning')
MARKER = 'BUILD11_DISPOSABLE_COMPILED_PACKAGE_LAB_NOT_HP_VALIDATION'
MIGRATION = '1794050000000-OwnerStorageDeletion'
JOB_IDS = tuple('build11-lab-' + str(n) for n in range(1, 28))
STAGES = frozenset({
    'interrupted configuration creation',
    'configuration resume and real service-start interruption',
    'actual clean-install resume', 'actual completed-install repeat',
    'actual packaged fresh-install rollback and repeat',
    'representative paused queue fixture creation',
    'compiled Build10 runtime representative state',
    'representative upstream database snapshot',
    'real image-only upgrade plan and dry-run',
    'real migration and simulated post-upgrade health interruption',
    'actual HTTP synthetic Trash/Restore/managed permanent delete',
    'fresh already-upgraded backup and isolated restore',
    'real hardened rollback after interrupted upgrade',
    'idempotent interrupted attempt refusal',
})
OPERATIONS = frozenset({
    'DOCKER_IMAGE_INSPECT', 'DOCKER_IMAGE_INSPECT_PLATFORM', 'DOCKER_IMAGE_PULL',
    'DOCKER_IMAGE_LOAD', 'DOCKER_CONTAINER_INSPECT', 'DOCKER_CONTAINER_LIST',
    'DOCKER_CONTAINER_EXEC', 'DOCKER_COMPOSE_CONFIG', 'DOCKER_COMPOSE_START',
    'DOCKER_COMPOSE_LIST', 'DOCKER_VERSION', 'DOCKER_OTHER', 'OTHER_COMMAND',
})
ERROR_CATEGORIES = frozenset({
    'DOCKER_API_VERSION_UNSUPPORTED', 'DOCKER_PLATFORM_FLAG_UNSUPPORTED',
    'DOCKER_REQUESTED_PLATFORM_UNAVAILABLE', 'DOCKER_IMAGE_UNAVAILABLE',
    'DOCKER_IMAGE_CONTENT_UNAVAILABLE',
    'SUDO_NONINTERACTIVE_AUTHORIZATION_REQUIRED', 'PERMISSION_DENIED',
    'DOCKER_LOCAL_DAEMON_UNAVAILABLE', 'COMPOSE_CONFIGURATION_INVALID',
    'DOCKER_RESOURCE_CONFLICT', 'REGISTRY_ACCESS_DENIED', 'COMMAND_TIMEOUT',
    'PRIVATE_ERROR_OMITTED',
})
AVAILABILITY_BOOLEANS = frozenset({
    'rootIdMatches', 'rootDescriptorMatches', 'rootRepositoryDigestMatches',
    'manifestSummariesPresent', 'expectedManifestPresent', 'expectedManifestDescriptorMatches',
    'expectedManifestAvailabilityPresent', 'expectedManifestAvailable',
    'expectedManifestKindImage', 'expectedManifestPlatformMatches',
})
AVAILABILITY_COUNTS = frozenset({'manifestSummaryCount', 'expectedManifestCount'})


class LabFailure(Exception):
    def __init__(self, code, diagnostic=None):
        super().__init__(code)
        self.diagnostic = validated_diagnostic(diagnostic)


def docker_operation(args):
    """Return only a fixed operation; arguments, image names and paths stay private."""
    tokens = list(args) if isinstance(args, (list, tuple)) else []
    if tokens[:2] == ['sudo', '-n']:
        tokens = tokens[2:]
    if not tokens or tokens.pop(0) != 'docker':
        return 'OTHER_COMMAND'
    if tokens and tokens[0] == '--host=' + SOCKET:
        tokens.pop(0)
    if tokens[:2] == ['image', 'inspect']:
        return 'DOCKER_IMAGE_INSPECT_PLATFORM' if '--platform' in tokens[2:] else 'DOCKER_IMAGE_INSPECT'
    fixed = {('image', 'pull'): 'DOCKER_IMAGE_PULL', ('image', 'load'): 'DOCKER_IMAGE_LOAD'}
    if tuple(tokens[:2]) in fixed:
        return fixed[tuple(tokens[:2])]
    if tokens and tokens[0] == 'compose':
        tokens = tokens[1:]
        while tokens and tokens[0] in ('--project-directory', '-p', '--project-name', '-f', '--file', '--env-file'):
            tokens = tokens[2:]
        return {'config': 'DOCKER_COMPOSE_CONFIG', 'up': 'DOCKER_COMPOSE_START',
                'ps': 'DOCKER_COMPOSE_LIST'}.get(tokens[0] if tokens else '', 'DOCKER_OTHER')
    return {'inspect': 'DOCKER_CONTAINER_INSPECT', 'ps': 'DOCKER_CONTAINER_LIST',
            'exec': 'DOCKER_CONTAINER_EXEC', 'version': 'DOCKER_VERSION'}.get(
                tokens[0] if tokens else '', 'DOCKER_OTHER')


def error_category(stderr):
    """Classify Docker stderr without publishing a single byte of its contents."""
    text = stderr[:65536].lower() if isinstance(stderr, str) else ''
    cases = (
        ('DOCKER_API_VERSION_UNSUPPORTED', r'requires? api version|client is newer than server|client version .* is too (?:new|old)|minimum supported api version'),
        ('DOCKER_PLATFORM_FLAG_UNSUPPORTED', r'unknown flag: --platform|flag provided but not defined: -platform'),
        ('DOCKER_REQUESTED_PLATFORM_UNAVAILABLE', r'no matching manifest for|platform .*not (?:found|available)|does not match the specified platform|was found but does not provide the specified platform'),
        ('DOCKER_IMAGE_CONTENT_UNAVAILABLE', r'content digest sha256:[0-9a-f]{64}.*not found|failed to get (?:image )?config|failed to read.*(?:manifest|config|blob)|failed to calculate.*size'),
        ('DOCKER_IMAGE_UNAVAILABLE', r'no such image|image .*not found|manifest unknown'),
        ('SUDO_NONINTERACTIVE_AUTHORIZATION_REQUIRED', r'sudo:.*(?:password is required|terminal is required|not allowed)'),
        ('DOCKER_LOCAL_DAEMON_UNAVAILABLE', r'cannot connect to the docker daemon|error during connect|is the docker daemon running'),
        ('COMPOSE_CONFIGURATION_INVALID', r'validating .*additional propert|unsupported config option|invalid compose|services\..*must be a'),
        ('DOCKER_RESOURCE_CONFLICT', r'container name .*already in use|port is already allocated|address already in use'),
        ('REGISTRY_ACCESS_DENIED', r'pull access denied|unauthorized:|denied: requested access'),
        ('PERMISSION_DENIED', r'permission denied|operation not permitted'),
    )
    return next((category for category, pattern in cases if re.search(pattern, text)), 'PRIVATE_ERROR_OMITTED')


def validated_availability(value):
    """Only fixed booleans and bounded counts may leave the read-only API probe."""
    if not isinstance(value, dict) or set(value) != AVAILABILITY_BOOLEANS | AVAILABILITY_COUNTS or \
            any(type(value[key]) is not bool for key in AVAILABILITY_BOOLEANS) or \
            any(type(value[key]) is not int or not 0 <= value[key] <= 32 for key in AVAILABILITY_COUNTS) or \
            value['expectedManifestCount'] > value['manifestSummaryCount'] or \
            value['expectedManifestPresent'] != (value['expectedManifestCount'] > 0):
        return None
    return {key: value[key] for key in sorted(value)}


def public_dependency_availability(reference, server_api_version):
    """CI-only immutable-image summaries; never a fallback to installer validation.

    Moby v28.4.0 api/types/image/manifest.go defines ID, Descriptor, Available,
    Kind and ImageData.Platform. No environment/configuration, command arguments,
    registry credentials or raw daemon payload can leave this function.
    """
    connection = None
    try:
        ci_environment()  # Reject production/remote use before creating a socket.
        from gallery_install import PUBLIC_DEPENDENCIES
        expected = PUBLIC_DEPENDENCIES.get(reference) if isinstance(reference, str) else None
        if expected is None or not isinstance(server_api_version, str) or \
                not re.fullmatch(r'[0-9]{1,2}\.[0-9]{1,3}', server_api_version) or \
                tuple(map(int, server_api_version.split('.'))) < (1, 49):
            return None

        class UnixDockerConnection(http.client.HTTPConnection):
            def connect(self):
                self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.sock.settimeout(self.timeout)
                self.sock.connect('/var/run/docker.sock')

        connection = UnixDockerConnection('localhost', timeout=10)
        target = '/v' + server_api_version + '/images/' + urllib.parse.quote(reference, safe='') + '/json?manifests=true'
        connection.request('GET', target)
        response = connection.getresponse()
        if response.status != 200:
            return None
        raw = response.read(1024 * 1024 + 1)
        if len(raw) > 1024 * 1024:
            return None
        row = json.loads(raw)
        if not isinstance(row, dict):
            return None
        summaries_present = row.get('Manifests') is not None
        summaries = row.get('Manifests') if summaries_present else []
        if not isinstance(summaries, list) or len(summaries) > 32 or \
                any(not isinstance(item, dict) for item in summaries):
            return None
        matches = [item for item in summaries if item.get('ID') == expected['manifest']]
        manifest = matches[0] if len(matches) == 1 else {}
        if manifest and (('Available' in manifest and type(manifest['Available']) is not bool) or
                         manifest.get('Kind') not in ('image', 'attestation', 'unknown')):
            return None
        descriptor = row.get('Descriptor')
        manifest_descriptor = manifest.get('Descriptor')
        image_data = manifest.get('ImageData')
        platform = image_data.get('Platform') if isinstance(image_data, dict) else None
        digest = reference.split('@', 1)[1]
        repositories = {repository + '@' + digest for repository in expected['repositories']}
        repo_digests = row.get('RepoDigests')
        return validated_availability({
            'rootIdMatches': row.get('Id') in (digest, expected['config']),
            'rootDescriptorMatches': isinstance(descriptor, dict) and descriptor.get('digest') == digest,
            'rootRepositoryDigestMatches': isinstance(repo_digests, list) and
                any(type(value) is str and value in repositories for value in repo_digests),
            'manifestSummariesPresent': summaries_present,
            'manifestSummaryCount': len(summaries), 'expectedManifestCount': len(matches),
            'expectedManifestPresent': bool(matches),
            'expectedManifestDescriptorMatches': isinstance(manifest_descriptor, dict) and
                manifest_descriptor.get('digest') == expected['manifest'],
            'expectedManifestAvailabilityPresent': 'Available' in manifest,
            'expectedManifestAvailable': manifest.get('Available') is True,
            'expectedManifestKindImage': manifest.get('Kind') == 'image',
            'expectedManifestPlatformMatches': isinstance(platform, dict) and
                platform.get('os') == 'linux' and platform.get('architecture') == 'amd64' and
                platform.get('variant') in (None, ''),
        })
    except Exception:
        return None  # Diagnostics never replace the original failed operation.
    finally:
        if connection is not None:
            try: connection.close()
            except Exception: pass


def validated_diagnostic(value):
    """An allowlist crosses both the child-process and public Checks API boundary."""
    if not isinstance(value, dict) or not isinstance(value.get('operation'), str) or \
            value['operation'] not in OPERATIONS or not isinstance(value.get('errorCategory'), str) or \
            value['errorCategory'] not in ERROR_CATEGORIES:
        return None
    code = value.get('returnCode')
    if not (value['errorCategory'] == 'COMMAND_TIMEOUT' and code is None) and \
            (type(code) is not int or not -128 <= code <= 255):
        return None
    result = {key: value[key] for key in ('operation', 'returnCode', 'errorCategory')}
    if value.get('publicDependency') in ('POSTGRES_PINNED', 'VALKEY_PINNED'):
        result['publicDependency'] = value['publicDependency']
        availability = validated_availability(value.get('publicDependencyAvailability'))
        if availability is not None:
            result['publicDependencyAvailability'] = availability
    for name in ('clientApiVersion', 'serverApiVersion'):
        version = value.get(name)
        if isinstance(version, str) and re.fullmatch(r'[0-9]{1,2}\.[0-9]{1,3}', version):
            result[name] = version
    line = value.get('installerFailureLine')
    if type(line) is int and 1 <= line <= 1000000:
        result['installerFailureLine'] = line
    return result


def verified_failure_code(value):
    """Only literal guard codes in reviewed tooling may become a public error."""
    if not isinstance(value, str) or not re.fullmatch('[A-Z][A-Z0-9_]{0,150}', value):
        return None
    codes = {'LAB_COMMAND_FAILED_PRIVATE_OUTPUT_OMITTED', 'LAB_FAILED_PRIVATE_DETAILS_OMITTED',
             'INSTALLATION_LAB_FAILED_PRIVATE_DETAILS_OMITTED', 'STOP_PRIVATE_DETAILS_OMITTED'}
    for name in ('build11_installation_smoke.py', 'gallery_install.py', 'image_release.py',
                 'gallery_entry.py', 'build11_operator.py', 'trash_predeploy.py',
                 'build11_restore_transition.py'):
        for node in ast.walk(ast.parse((Path(__file__).parent / name).read_text())):
            if isinstance(node, ast.Call) and isinstance(node.func, (ast.Name, ast.Attribute)) and \
                    (node.func.id if isinstance(node.func, ast.Name) else node.func.attr) in ('need', 'Stop', 'LabFailure', 'age_ok'):
                codes.update(arg.value for arg in node.args if isinstance(arg, ast.Constant) and
                             isinstance(arg.value, str) and re.fullmatch('[A-Z][A-Z0-9_]{0,150}', arg.value))
    return value if value in codes or value.startswith('PACKAGED_INSTALLER_') and \
        value[len('PACKAGED_INSTALLER_'):] in codes else None


def public_failure(row):
    """Publish only fixed stage labels, bounded codes/numbers and validated diagnostics."""
    if not isinstance(row, dict) or row.get('result') != 'FAIL':
        return None
    code = verified_failure_code(row.get('failure')) or 'INSTALLATION_LAB_FAILED_PRIVATE_DETAILS_OMITTED'
    stage = row.get('failedStage')
    result = {'failure': code, 'failedStage': stage if isinstance(stage, str) and stage in STAGES else 'UNKNOWN_STAGE'}
    line = row.get('failureLine')
    if type(line) is int and 1 <= line <= 1000000:
        result['failureLine'] = line
    diagnostic = validated_diagnostic(row.get('commandDiagnostic'))
    if diagnostic:
        result['commandDiagnostic'] = diagnostic
    return result


def need(value, code):
    if not value:
        raise LabFailure(code)


def ci_environment():
    need(os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('GALLERY_ISOLATED_CI') == '1',
         'EXPLICIT_ISOLATED_GITHUB_INSTALLATION_LAB_REQUIRED')
    need(sys.platform == 'linux', 'LINUX_DESCRIPTOR_RELATIVE_LAB_REQUIRED')
    # Never inherit a remote daemon or accidentally select a Docker context.
    result = dict(os.environ)
    for key in ('DOCKER_HOST', 'DOCKER_CONTEXT', 'DOCKER_TLS', 'DOCKER_TLS_VERIFY', 'DOCKER_CERT_PATH'):
        result.pop(key, None)
    return result


def command(args, *, input=None, timeout=180, expected=0):
    result = subprocess.run(args, input=input, text=True, capture_output=True,
                            timeout=timeout, env=ci_environment())
    if result.returncode != expected:
        # Only fixed codes printed by our own wrapper become public diagnostics;
        # Docker/Compose stderr and request data remain private.
        fixed = [value for value in re.findall(r'^(?:FAIL_ACTUAL_PACKAGED_INSTALLER:|STOP) ([A-Z0-9_]+)$', result.stdout, re.MULTILINE)
                 if verified_failure_code(value)]
        diagnostic = None
        for line in result.stdout.splitlines():
            if line.startswith('INSTALL_COMMAND_DIAGNOSTIC ') and len(line) <= 2048:
                try:
                    diagnostic = validated_diagnostic(json.loads(line[len('INSTALL_COMMAND_DIAGNOSTIC '):]))
                except (ValueError, TypeError):
                    pass
        if diagnostic is None and docker_operation(args) != 'OTHER_COMMAND':
            diagnostic = validated_diagnostic({'operation': docker_operation(args), 'returnCode': result.returncode,
                                               'errorCategory': error_category(result.stderr)})
        raise LabFailure('PACKAGED_INSTALLER_' + fixed[-1] if fixed else 'LAB_COMMAND_FAILED_PRIVATE_OUTPUT_OMITTED', diagnostic)
    return result.stdout


def docker(*args, input=None, timeout=180):
    return command(['docker', '--host=' + SOCKET, *args], input=input, timeout=timeout).strip()


def digest(path):
    need(path.is_file() and not path.is_symlink(), 'LAB_REGULAR_FILE_REQUIRED')
    with path.open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()


def fail_if_existing_installation():
    ci_environment()
    need(not docker('ps', '-aq').split(), 'LAB_REQUIRES_EMPTY_DISPOSABLE_DOCKER_DAEMON')
    # Also reject unlabeled pre-existing named volumes: Compose would otherwise
    # be able to adopt an unrelated `immich_model-cache` despite absent labels.
    need(not docker('volume', 'ls', '-q').split(),
         'EXISTING_IMMICH_VOLUMES_NEVER_ADOPTED')
    need(not docker('network', 'ls', '-q', '--filter', 'name=^immich_default$').split(),
         'EXISTING_IMMICH_NETWORK_NEVER_ADOPTED')


def inspect(name):
    rows = json.loads(docker('inspect', name))
    need(len(rows) == 1, 'LAB_CONTAINER_INSPECTION_INCOMPLETE')
    return rows[0]


def installation_containers(directory):
    ids = docker('ps', '-aq', '--filter', 'label=com.docker.compose.project=immich').split()
    need(ids, 'LAB_INSTALLATION_CONTAINERS_MISSING')
    rows = json.loads(docker('inspect', *ids))
    need(len(rows) == len(ids), 'LAB_CONTAINER_INVENTORY_INCOMPLETE')
    for row in rows:
        labels = row.get('Config', {}).get('Labels', {})
        need(labels.get('com.docker.compose.project.working_dir') == str(directory) and
             row.get('Name') in {'/' + name for name in NAMES}, 'FOREIGN_CONTAINER_NEVER_ADOPTED')
    return {row['Name']: row['Id'] for row in rows}


INSTALL_CHILD = r'''
import json,os,sys,traceback
from pathlib import Path
from types import SimpleNamespace
sys.path.insert(0, str(Path(sys.argv[1])/'tools'))
import gallery_install as installer
# Diagnostic helpers belong to the reviewed CI harness, not the application or
# production installer. Observe the actual subprocess without changing execution.
sys.path.append(str(Path(sys.argv[6]).parent))
import build11_installation_smoke as diagnostics
previous_process=installer.core.subprocess.run
last_failure=None
last_public_dependency=None
public_dependencies=dict(zip(installer.PUBLIC_DEPENDENCIES,('POSTGRES_PINNED','VALKEY_PINNED')))
def observed_process(command,*args,**kwargs):
  global last_failure,last_public_dependency
  last_failure=None
  last_public_dependency=None
  try: result=previous_process(command,*args,**kwargs)
  except installer.core.subprocess.TimeoutExpired:
    last_failure={'operation':diagnostics.docker_operation(command),'returnCode':None,'errorCategory':'COMMAND_TIMEOUT'}
    raise
  if result.returncode != 0:
    last_failure={'operation':diagnostics.docker_operation(command),'returnCode':result.returncode,
                  'errorCategory':diagnostics.error_category(result.stderr)}
    if command and command[-1] in public_dependencies:
      last_failure['publicDependency']=public_dependencies[command[-1]]
      last_public_dependency=command[-1]
  return result
installer.core.subprocess.run=observed_process
fault=sys.argv[5]
if fault == 'before-plan':
  previous=installer.core.save
  def save(path,value):
    if path.name == 'fresh-install-plan.json': raise RuntimeError('INJECTED_PLAN_WRITE_INTERRUPTION')
    return previous(path,value)
  installer.core.save=save
elif fault == 'after-start':
  def health(*args,**kwargs): raise RuntimeError('INJECTED_POST_START_INTERRUPTION')
  installer.core.health=health
args=SimpleNamespace(package=Path(sys.argv[1]),directory=Path(sys.argv[2]),environment=Path(sys.argv[3]),
                     machine_learning_image=sys.argv[4],execute_approved=True,nas_storage_config=None)
try: installer.install(args)
except Exception as error:
  expected={'before-plan':'INJECTED_PLAN_WRITE_INTERRUPTION','after-start':'INJECTED_POST_START_INTERRUPTION'}.get(fault)
  if isinstance(error,RuntimeError) and str(error)==expected:
    print('PASS_EXPECTED_INJECTED_INTERRUPTION');sys.exit(90)
  if last_failure is not None and (isinstance(error,installer.core.subprocess.TimeoutExpired) or
      isinstance(error,installer.core.Stop) and str(error)=='COMMAND_FAILED_PRIVATE_OUTPUT_OMITTED'):
    last_failure['installerFailureLine']=traceback.extract_tb(error.__traceback__)[-1].lineno
    # Numeric API versions only; a failed read-only version probe never replaces
    # the real failure or exposes registry credentials, stderr or command args.
    try:
      versions=previous_process([*installer.core.DOCKER,'version','--format','{{json .}}'],text=True,capture_output=True,timeout=10)
      if versions.returncode == 0:
        row=json.loads(versions.stdout)
        for side,name in [('Client','clientApiVersion'),('Server','serverApiVersion')]:
          last_failure[name]=row.get(side,{}).get('ApiVersion')
    except Exception: pass
    if last_failure.get('operation')=='DOCKER_IMAGE_INSPECT_PLATFORM' and last_public_dependency is not None:
      availability=diagnostics.public_dependency_availability(last_public_dependency,last_failure.get('serverApiVersion'))
      if availability is not None: last_failure['publicDependencyAvailability']=availability
    safe=diagnostics.validated_diagnostic(last_failure)
    if safe is not None: print('INSTALL_COMMAND_DIAGNOSTIC '+json.dumps(safe,sort_keys=True))
  code=diagnostics.verified_failure_code(str(error)) if isinstance(error,installer.core.Stop) else None
  if code is None: code='STOP_PRIVATE_DETAILS_OMITTED'
  print('FAIL_ACTUAL_PACKAGED_INSTALLER: '+code);sys.exit(1)
if fault: print('FAIL_FAULT_NOT_REACHED');sys.exit(1)
'''


def invoke_installer(package, directory, environment, ml_image, fault=''):
    previous = os.environ.get('GALLERY_FRESH_INSTALL_APPROVED')
    os.environ['GALLERY_FRESH_INSTALL_APPROVED'] = 'YES'
    try:
        return command([sys.executable, '-B', '-c', INSTALL_CHILD, str(package), str(directory),
                        str(environment), ml_image, fault, str(Path(__file__).resolve())], timeout=2400, expected=90 if fault else 0)
    finally:
        if previous is None:
            os.environ.pop('GALLERY_FRESH_INSTALL_APPROVED', None)
        else:
            os.environ['GALLERY_FRESH_INSTALL_APPROVED'] = previous


class Api:
    def __init__(self):
        self.base = 'http://127.0.0.1:2283/api'
        self.token = None
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args, **kwargs):
                raise LabFailure('ISOLATED_API_REDIRECT_REJECTED')
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def __call__(self, path, method='GET', data=None, content_type='application/json', raw=False):
        need(path.startswith('/') and not path.startswith('//') and '\\' not in path,
             'FIXED_ISOLATED_API_ROUTE_REQUIRED')
        body = data if isinstance(data, bytes) else None if data is None else json.dumps(data).encode()
        headers = {'Content-Type': content_type}
        if self.token:
            headers['Authorization'] = 'Bearer ' + self.token
        with self.opener.open(urllib.request.Request(self.base + path, body, headers, method=method),
                              timeout=15) as response:
            output = response.read(16 * 1024 * 1024 + 1)
            need(len(output) <= 16 * 1024 * 1024, 'LAB_HTTP_RESPONSE_SIZE_LIMIT')
            return output if raw else json.loads(output) if output else None

    def login(self, credentials):
        self.token = None
        self.token = self('/auth/login', 'POST', credentials)['accessToken']


def sql(query, *, write=False):
    # Every database connection goes through this lab-owned local container.
    pg = inspect('immich_postgres')
    need(pg['Name'] == '/immich_postgres' and pg['Config'].get('Labels', {}).get(
        'com.docker.compose.project') == PROJECT, 'OWNED_LAB_POSTGRES_REQUIRED')
    args = ['exec', '-i']
    if not write:
        args += ['--env', 'PGOPTIONS=-c default_transaction_read_only=on -c statement_timeout=10000']
    args += ['immich_postgres', 'psql', '-X', '--quiet', '-A', '-t', '--set', 'ON_ERROR_STOP=1',
             '-h', '/var/run/postgresql', '-U', 'postgres', '-d', 'immich', '--command', query]
    return docker(*args, timeout=60)


DATABASE_SNAPSHOT_SQL = '''SELECT json_build_object(
      'users',(SELECT coalesce(json_agg(json_build_object('id',id,'email',email,'status',status) ORDER BY id),'[]'::json) FROM public."user"),
      'assets',(SELECT coalesce(json_agg(json_build_object('id',id,'owner',"ownerId",'library',"libraryId",'status',status,
           'deletedAt',"deletedAt",'offline',"isOffline",'created',"fileCreatedAt",'localDate',"localDateTime") ORDER BY id),'[]'::json) FROM asset),
      'albums',(SELECT coalesce(json_agg(json_build_object('id',a.id,'owner',au."userId",'name',a."albumName") ORDER BY a.id),'[]'::json)
           FROM album a LEFT JOIN album_user au ON au."albumId"=a.id AND au.role='owner'),
      'albumUsers',(SELECT coalesce(json_agg(json_build_object('album',"albumId",'user',"userId",'role',role)
           ORDER BY "albumId","userId"),'[]'::json) FROM album_user),
      'membership',(SELECT coalesce(json_agg(json_build_object('album',"albumId",'asset',"assetId") ORDER BY "albumId","assetId"),'[]'::json) FROM album_asset));'''


def database_snapshot():
    # Upstream migrated album ownership to album_user (1776848612954). Capture
    # stable identities and all sharing roles; do not assume the removed column.
    return json.loads(sql(DATABASE_SNAPSHOT_SQL))


NODE_QUEUE = media.NODE_LAB_STORAGE + r'''
import crypto from 'node:crypto';import fs from 'node:fs/promises';
const {Queue}=require('bullmq');
let input='';for await(const chunk of process.stdin)input+=chunk;const data=JSON.parse(input);
if(!['seed','read'].includes(data.action)||!/^\w{8}-\w{4}-\w{4}-\w{4}-\w{12}$/.test(data.owner))throw new Error('BAD_LAB_ACTION');
const queue=new Queue('backgroundTask',{...config.bull.config,skipMetasUpdate:true});
const ids=Array.from({length:27},(_,i)=>'build11-lab-'+(i+1));
try{
 if(data.action==='seed'){
   await queue.pause();
   for(let i=0;i<27;i++){
     const file='/data/build11-installation-synthetic/legacy-'+i+'.png';
     if(i<6){await fs.mkdir('/data/build11-installation-synthetic',{recursive:true,mode:0o700});
       await fs.writeFile(file,'synthetic legacy original '+i,{flag:'wx',mode:0o600});}
     await queue.add(i<6?'FileDelete':'UserSyncUsage',i<6?{files:[file],temporaryOwnerId:data.owner}:{id:data.owner,testOnly:true},
       {jobId:ids[i],removeOnComplete:false,removeOnFail:false});
   }
 }
 const redis=await queue.client,prefix=queue.toKey('');
 const snapshot=await redis.eval(`local paused=redis.call('HGET',KEYS[1],'paused');
   return {paused or '',redis.call('LRANGE',KEYS[2],0,-1),redis.call('LRANGE',KEYS[3],0,-1)}`,3,
   prefix+'meta',prefix+'paused',prefix+'active');
 const retained=snapshot[1].filter(id=>ids.includes(id));
 const hashes=[];for(const id of ids){const raw=await redis.hgetall(prefix+id);
   hashes.push({id,hash:crypto.createHash('sha256').update(JSON.stringify(Object.fromEntries(Object.entries(raw).sort()))).digest('hex')});}
 const originals=[];for(let i=0;i<6;i++)originals.push(crypto.createHash('sha256').update(
   await fs.readFile('/data/build11-installation-synthetic/legacy-'+i+'.png')).digest('hex'));
 console.log(JSON.stringify({paused:snapshot[0]==='1',ids:retained,active:snapshot[2].filter(id=>ids.includes(id)),hashes,originals}));
}finally{await queue.close();}
'''


def queue_snapshot(owner, action='read'):
    need(re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', owner), 'LAB_OWNER_UUID_REQUIRED')
    ci_environment()
    server = inspect('immich_server')
    labels = server.get('Config', {}).get('Labels', {})
    installation = Path(labels.get('com.docker.compose.project.working_dir', ''))
    need(server.get('Name') == '/immich_server' and labels.get('com.docker.compose.project') == PROJECT and
         labels.get('com.docker.compose.service') == 'immich-server' and installation.is_absolute() and
         installation.name == 'installation' and installation.parent.name.startswith('gallery-build11-install-lab-') and
         installation.is_dir() and installation.resolve() == installation and
         installation.parent.stat().st_uid == os.getuid() and installation.parent.stat().st_mode & 0o777 == 0o700,
         'OWNED_QUEUE_FIXTURE_INSTALLATION_REQUIRED')
    managed = [row for row in server.get('Mounts', []) if row.get('Destination') == '/data']
    source = installation / 'media'
    need(len(managed) == 1 and managed[0].get('Type') == 'bind' and managed[0].get('RW') is True and
         managed[0].get('Source') == str(source) and source.is_dir() and source.resolve() == source,
         'EXACT_QUEUE_FIXTURE_LOCAL_MANAGED_BIND_REQUIRED')
    row = json.loads(docker('exec', '-i', 'immich_server', 'node', '--input-type=module', '-e', NODE_QUEUE,
                            input=json.dumps({'action': action, 'owner': owner})))
    validate_queue(row)
    return row


def validate_queue(row):
    need(row.get('paused') is True and row.get('active') == [] and len(row.get('ids', [])) == 27 and
         set(row['ids']) == set(JOB_IDS) and len(row.get('hashes', [])) == 27 and
         {item.get('id') for item in row['hashes']} == set(JOB_IDS) and all(
             re.fullmatch('[0-9a-f]{64}', item.get('hash', '')) for item in row['hashes']) and
         len(row.get('originals', [])) == 6 and all(re.fullmatch('[0-9a-f]{64}', value) for value in row['originals']),
         'ALL_27_PAUSED_JOB_BYTES_ORDER_AND_SIX_ORIGINALS_REQUIRED')


def unchanged_queue(expected, actual):
    validate_queue(expected)
    validate_queue(actual)
    need(expected == actual, 'PAUSED_JOBS_OR_SYNTHETIC_LEGACY_ORIGINALS_CHANGED')


def storage_and_service_snapshot(directory):
    rows = json.loads(docker('inspect', *NAMES))
    need(len(rows) == len(NAMES), 'ALL_INSTALLATION_SERVICES_REQUIRED')
    result = {}
    for row in rows:
        labels = row['Config'].get('Labels', {})
        need(labels.get('com.docker.compose.project.working_dir') == str(directory),
             'OWNED_INSTALLATION_DIRECTORY_REQUIRED')
        mounts = sorted(row.get('Mounts', []), key=lambda m: json.dumps(m, sort_keys=True))
        networks = sorted(row['NetworkSettings']['Networks'])
        image_provenance = {'IMMICH_BUILD', 'IMMICH_BUILD_URL', 'IMMICH_BUILD_IMAGE', 'IMMICH_BUILD_IMAGE_URL',
                            'IMMICH_SOURCE_COMMIT', 'IMMICH_SOURCE_REF', 'IMMICH_SOURCE_URL'}
        result[row['Name']] = {'mounts': mounts, 'networks': networks,
                              'env': sorted(value for value in row['Config'].get('Env', [])
                                            if value.split('=', 1)[0] not in image_provenance)}
        if row['Name'] != '/immich_server':
            result[row['Name']]['id'] = row['Id']
            result[row['Name']]['image'] = row['Image']
    return result


def exact_namespace_preserved(before, after):
    need(before == after, 'MOUNTS_ENV_NETWORKS_OR_UNRELATED_SERVICES_CHANGED')


def load_packaged_tools(package):
    # Existing entrypoint already checked every executable byte and artifact.
    # The engine imported here is copied from those exact verified bytes.
    path = package / 'tools/image_release.py'
    spec = importlib.util.spec_from_file_location('actual_packaged_image_engine', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def upgraded_backup_restore(operator, state, source, candidate, fallback):
    """Exercise the packaged fresh-backup hook against the real upgraded lab DB.

    No previous recovery receipt, NAS proof or production root is supplied. The
    backup comes from the lab-owned PostgreSQL; restore_check creates its own
    network-none PostgreSQL with anonymous volumes, then removes only that DB.
    """
    ci_environment()
    need(state.is_absolute() and not state.exists() and not state.is_symlink() and
         state.parent.is_dir() and not state.parent.is_symlink() and
         state.parent.stat().st_mode & 0o777 == 0o700 and state.parent.stat().st_uid == os.getuid(),
         'NEW_PRIVATE_UPGRADED_RESTORE_STATE_REQUIRED')
    need(re.fullmatch('[0-9a-f]{40}', source) and all(re.fullmatch('sha256:[0-9a-f]{64}', image)
         for image in (candidate, fallback)), 'EXACT_LAB_RECOVERY_SOURCE_AND_IMAGES_REQUIRED')
    tool = operator.legacy
    need(tool.SERVER == 'immich_server' and tool.POSTGRES == 'immich_postgres' and
         tuple(tool.OTHER) == ('immich_postgres', 'immich_redis', 'immich_machine_learning'),
         'EXACT_LAB_RECOVERY_CONTAINERS_REQUIRED')
    tool.DOCKER = operator.core.DOCKER
    tool.SOURCE = tool.BUILD11_SOURCE = source
    server = tool.inspect(tool.SERVER)
    need(server['Image'] == candidate and dict(value.split('=', 1) for value in
         server['Config'].get('Env', []) if '=' in value).get('IMMICH_SOURCE_COMMIT') == source,
         'ALREADY_UPGRADED_LAB_SERVER_REQUIRED')
    operator.pre.postgres_identity(tool, tool.inspect(tool.POSTGRES))
    state.mkdir(mode=0o700)
    backup, summary = operator.pre.fresh_backup(tool, state)
    need(MIGRATION in summary['migrationNames'], 'ALREADY_UPGRADED_FRESH_BACKUP_REQUIRED')
    path = Path(operator.__file__).with_name('build11_restore_transition.py')
    spec = importlib.util.spec_from_file_location('actual_packaged_upgraded_restore_transition', path)
    transition_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(transition_module)
    def transition(tool, docker, container, query, before, directory, original):
        return transition_module.build11_restore_transition(
            tool, docker, container, query, before, directory, original, candidate, fallback)
    operator.pre.restore_exact(tool, backup, state, summary, transition=transition)
    metadata = operator.pre.private_json(state / 'fresh-backup.json')
    restored = operator.pre.private_json(state / 'fresh-restore-verified.json')
    receipt = operator.pre.private_json(state / 'backup-verified.json')
    verified = operator.pre.private_json(state / 'build11-restored-database-verified.json')
    checksum = digest(backup)
    need(metadata.get('backupSHA256') == restored.get('backupSHA256') == receipt.get('backupSHA256') ==
         verified.get('backupSHA256') == checksum and metadata.get('source') == source and
         restored.get('restore') == 'PASS_EXACT_DUMP_SNAPSHOT' and receipt.get('backupPath') == str(backup.resolve()) and
         receipt.get('restore') == 'PASS_ISOLATED_SQL_TRANSACTION' and receipt.get('productionChanged') is False and
         restored.get('summary') == summary and
         verified.get('validation') == 'PASS_ISOLATED_BUILD11_MIGRATION_AND_EXISTING_ROW_PRESERVATION' and
         verified.get('sourceCommit') == source and verified.get('imageId') == candidate and
         verified.get('rollbackImageId') == fallback and verified.get('productionChanged') is False and
         verified.get('isolatedDatabase') is True and verified.get('baseAlreadyBuild11') is True and
         verified.get('policiesPreserved') is True and verified.get('rollbackMigrationsAccepted') is True and
         verified.get('baseMigrations') == verified.get('targetMigrations') == summary['migrationNames'] and
         type(verified.get('existingStoragePolicyCount')) is int and verified['existingStoragePolicyCount'] >= 2 and
         verified.get('implicitStoragePolicies') == 0 and
         verified.get('mediaFilesMounted') is False and verified.get('destructiveTestsPerformed') is False,
         'ACTUAL_ALREADY_UPGRADED_FRESH_RESTORE_AND_STORAGE_POLICIES_REQUIRED')
    for timestamp in (metadata['createdAt'], receipt['checkedAt'], verified['testedAt']):
        operator.pre.age_ok(timestamp, 86400, 'ALREADY_UPGRADED_RECOVERY_RECEIPT_EXPIRED')
    return {'backupSHA256': checksum, 'restore': restored['restore'], 'baseAlreadyBuild11': True,
            'existingStoragePolicyCount': verified['existingStoragePolicyCount'], 'policiesPreserved': True,
            'migrationLedgerUnchanged': True, 'candidateAndRollbackMigrationsAccepted': True,
            'mediaFilesMounted': False, 'destructiveTestsPerformed': False}


def synthetic_thumbnail(api, asset):
    deadline = time.monotonic() + 120
    while True:
        types = json.loads(sql("SELECT coalesce(json_agg(type),'[]'::json) FROM asset_file WHERE \"assetId\"='" + asset + "';"))
        if {'thumbnail', 'preview'} <= set(types):
            break
        need(time.monotonic() < deadline, 'ACTUAL_THUMBNAIL_AND_PREVIEW_JOBS_DID_NOT_COMPLETE')
        time.sleep(2)
    need(api('/assets/' + asset + '/thumbnail?size=thumbnail', raw=True), 'ACTUAL_THUMBNAIL_HTTP_REQUIRED')
    need(api('/assets/' + asset + '/thumbnail?size=preview', raw=True), 'ACTUAL_PREVIEW_HTTP_REQUIRED')


def ownership_rejected(api, asset):
    try:
        result = api('/assets/permanent-deletion', 'POST', {'ids': [asset], 'confirmed': True})
    except urllib.error.HTTPError as error:
        need(error.code in (400, 403, 404), 'CROSS_OWNER_DELETION_REJECTION_REQUIRED')
        return
    need(result == [{'id': asset, 'state': 'blocked', 'code': 'ASSET_NOT_OWNED'}],
         'CROSS_OWNER_PERMANENT_DELETE_NOT_REJECTED')


def original_host_path(asset):
    need(re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', asset), 'LAB_ASSET_UUID_REQUIRED')
    path = json.loads(sql("SELECT to_json(\"originalPath\") FROM asset WHERE id='" + asset + "';"))
    target = next((root for root in ('/data', '/external') if isinstance(path, str) and path.startswith(root + '/')), None)
    mounts = [row for row in inspect('immich_server')['Mounts'] if row.get('Destination') == target]
    need(len(mounts) == 1 and mounts[0].get('Type') == 'bind' and mounts[0].get('RW') is True,
         'EXACT_DISPOSABLE_MANAGED_BIND_REQUIRED')
    source = Path(mounts[0]['Source'])
    need(source.is_dir() and source.resolve() == source and target is not None,
         'DISPOSABLE_ORIGINAL_HOST_MAPPING_REQUIRED')
    relative = Path(path).relative_to(target)
    need('..' not in relative.parts, 'DISPOSABLE_ORIGINAL_HOST_MAPPING_REQUIRED')
    # Report/validate actual filesystem bytes through the scoped lab container:
    # upstream creates root-owned private subdirectories, so never chmod them
    # merely to make the unprivileged CI runner able to inspect them.
    return Path(target) / relative


def physical_state(path):
    need(isinstance(path, Path) and path.is_absolute() and
         any(path.is_relative_to(root) for root in ('/data', '/external')) and
         '..' not in path.parts, 'DISPOSABLE_ORIGINAL_PATH_REQUIRED')
    program = r'''
import fs from 'node:fs/promises';import crypto from 'node:crypto';import {constants} from 'node:fs';let input='';
for await(const chunk of process.stdin)input+=chunk;const path=JSON.parse(input).path;
if(!['/data/','/external/'].some(root=>path.startsWith(root))||path.split('/').includes('..'))throw new Error('BAD_SYNTHETIC_PATH');
try{
 const stat=await fs.lstat(path);if(!stat.isFile()||stat.isSymbolicLink()||stat.size>4194304)throw new Error('BAD_SYNTHETIC_FILE');
 const handle=await fs.open(path,constants.O_RDONLY|constants.O_NOFOLLOW);
 try{console.log(JSON.stringify({exists:true,sha256:crypto.createHash('sha256').update(await handle.readFile()).digest('hex')}));}
 finally{await handle.close();}
}catch(error){if(error.code!=='ENOENT')throw error;console.log(JSON.stringify({exists:false}));}
'''
    return json.loads(docker('exec', '-i', 'immich_server', 'node', '--input-type=module', '-e', program,
                            input=json.dumps({'path': str(path)})))


def physical_hash(path):
    row = physical_state(path)
    need(row.get('exists') is True and re.fullmatch('[0-9a-f]{64}', row.get('sha256', '')),
         'ACTUAL_SYNTHETIC_FILE_HASH_REQUIRED')
    return row['sha256']


def physically_absent(path):
    return physical_state(path) == {'exists': False}


def real_lifecycle(api, other_credentials, other_asset):
    photos = [media.upload_synthetic(api, media.synthetic_png(color)) for color in (61, 62)]
    originals = [original_host_path(asset) for asset in photos]
    need([physical_hash(path) for path in originals] == [hashlib.sha256(media.synthetic_png(color)).hexdigest()
                                               for color in (61, 62)], 'ACTUAL_SYNTHETIC_ORIGINAL_BYTES_REQUIRED')
    before = [api('/assets/' + asset) for asset in photos]
    api('/assets', 'DELETE', {'ids': photos, 'force': False})
    need(all(api('/assets/' + asset)['isTrashed'] for asset in photos), 'BULK_TRASH_NOT_VISIBLE')
    need(api('/trash/restore/assets', 'POST', {'ids': photos}) == {'count': 2}, 'BULK_RESTORE_COUNT_INCORRECT')
    for asset, original in zip(photos, before, strict=True):
        restored = api('/assets/' + asset)
        need(not restored['isTrashed'] and restored['fileCreatedAt'] == original['fileCreatedAt'] and
             restored['localDateTime'] == original['localDateTime'], 'RESTORE_CAPTURE_DATE_OR_STATE_CHANGED')
    synthetic_thumbnail(api, photos[0])
    api('/assets', 'DELETE', {'ids': photos, 'force': False})
    api('/assets/managed-deletion-consent', 'PUT', {'enabled': False, 'confirmed': True})
    blocked = api('/assets/permanent-deletion', 'POST', {'ids': photos, 'confirmed': True})
    need(len(blocked) == 2 and all(row['state'] == 'blocked' and row['code'] == 'LIBRARY_DELETION_NOT_AUTHORIZED'
                                  for row in blocked), 'MANAGED_REVOCATION_NOT_ENFORCED')
    api('/assets/managed-deletion-consent', 'PUT', {'enabled': True, 'confirmed': True})
    ownership_rejected(api, other_asset)
    result = api('/assets/permanent-deletion', 'POST', {'ids': photos, 'confirmed': True})
    need(len(result) == 2 and all(row['state'] == 'complete' for row in result), 'BULK_MANAGED_DELETION_INCOMPLETE')
    for asset, path in zip(photos, originals, strict=True):
        need(api('/assets/' + asset + '/deletion-status') == {'id': asset, 'state': 'complete'}, 'DURABLE_RECEIPT_MISSING')
        need(physically_absent(path), 'MANAGED_ORIGINAL_PHYSICALLY_PRESENT')
        try:
            api('/assets/' + asset + '/original', raw=True)
        except urllib.error.HTTPError as error:
            need(error.code in (400, 404), 'PERMANENT_ORIGINAL_STILL_ACCESSIBLE')
        else:
            raise LabFailure('PERMANENT_ORIGINAL_STILL_ACCESSIBLE')
    owner_token = api.token
    api.login(other_credentials)
    need(api('/assets/' + other_asset + '/original', raw=True) == media.synthetic_png(49), 'OTHER_OWNER_ORIGINAL_CHANGED')
    api.token = owner_token
    return {'bulkTrashRestore': True, 'originalTimelineDatesPreserved': True,
            'managedRevocationAndBulkPermanentDelete': True, 'otherOwnerIsolated': True,
            'managedOriginalsPhysicallyRemoved': True, 'thumbnailPreviewActualFilesAndHttp': True}


def external_lifecycle(api, owner):
    need(re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', owner), 'LAB_OWNER_UUID_REQUIRED')
    media_bytes = media.synthetic_png(71)
    result = json.loads(docker('exec', '-i', 'immich_server', 'node', '--input-type=module', '-e',
                               media.NODE_STORAGE_FIXTURE,
                               input=json.dumps({'action': 'writeExternal', 'media': __import__('base64').b64encode(media_bytes).decode()})))
    scope = api('/libraries', 'POST', {'ownerId': owner, 'name': 'Disposable external installer lab',
                                      'importPaths': [result['root']]})['id']
    validation = api('/libraries/' + scope + '/validate', 'POST', {'importPaths': [result['root']]})
    need(validation == {'importPaths': [{'importPath': result['root'], 'isValid': True}]},
         'ACTUAL_EXTERNAL_IMPORT_PATH_VALIDATION_FAILED')
    api('/libraries/' + scope + '/scan', 'POST')
    deadline = time.monotonic() + 120
    while True:
        ids = json.loads(docker('exec', '-i', 'immich_server', 'node', '--input-type=module', '-e',
                                media.NODE_STORAGE_FIXTURE,
                                input=json.dumps({'action': 'externalIds', 'scope': scope})))
        if len(ids) == 1:
            break
        need(len(ids) == 0 and time.monotonic() < deadline, 'ACTUAL_EXTERNAL_SCAN_NOT_COMPLETE')
        time.sleep(2)
    asset = ids[0]
    original = original_host_path(asset)
    expected_hash = hashlib.sha256(media_bytes).hexdigest()
    need(physical_hash(original) == expected_hash, 'ACTUAL_EXTERNAL_ORIGINAL_BYTES_REQUIRED')
    api('/assets', 'DELETE', {'ids': [asset], 'force': False})
    need(api('/assets/' + asset)['isTrashed'], 'EXTERNAL_TRASH_NOT_VISIBLE')
    denied = api('/assets/permanent-deletion', 'POST', {'ids': [asset], 'confirmed': True})
    need(denied == [{'id': asset, 'scope': scope, 'state': 'blocked', 'code': 'LIBRARY_DELETION_NOT_AUTHORIZED'}]
         and physical_hash(original) == expected_hash, 'READONLY_EXTERNAL_ORIGINAL_NOT_PROTECTED')
    managed = media.upload_synthetic(api, media.synthetic_png(72))
    managed_original = original_host_path(managed)
    managed_hash = physical_hash(managed_original)
    api('/assets', 'DELETE', {'ids': [managed], 'force': False})
    mixed = api('/assets/permanent-deletion', 'POST', {'ids': [managed, asset], 'confirmed': True})
    need(mixed == [{'id': managed, 'scope': 'managed', 'state': 'blocked', 'code': 'DELETION_BATCH_NOT_AUTHORIZED'},
                   {'id': asset, 'scope': scope, 'state': 'blocked', 'code': 'LIBRARY_DELETION_NOT_AUTHORIZED'}] and
         physical_hash(original) == expected_hash and physical_hash(managed_original) == managed_hash,
         'MIXED_UNAUTHORIZED_SCOPE_CHANGED_AN_ORIGINAL')
    try:
        api('/trash/empty', 'POST')
    except urllib.error.HTTPError as error:
        need(error.code == 409, 'EMPTY_TRASH_MIXED_SCOPE_NOT_FAIL_CLOSED')
    else:
        raise LabFailure('EMPTY_TRASH_MIXED_SCOPE_NOT_FAIL_CLOSED')
    need(physical_hash(original) == expected_hash and physical_hash(managed_original) == managed_hash,
         'EMPTY_TRASH_MIXED_SCOPE_CHANGED_AN_ORIGINAL')
    api('/assets/library-deletion-consent/' + scope, 'PUT', {'enabled': True, 'confirmed': True})
    complete = api('/trash/empty', 'POST')
    need(complete.get('count') == 2 and
         physically_absent(original) and physically_absent(managed_original),
         'WRITABLE_EXTERNAL_ORIGINAL_NOT_PHYSICALLY_REMOVED')
    rescan = json.loads(docker('exec', '-i', 'immich_server', 'node', '--input-type=module', '-e',
                               media.NODE_STORAGE_FIXTURE, input=json.dumps({'action': 'rescanGate', 'scope': scope})))
    need(rescan == [], 'DURABLE_EXTERNAL_RESCAN_GATE_FAILED')
    return {'externalDefaultReadOnlyProtected': True, 'explicitOwnerWritableExternalPhysicalDelete': True,
            'externalRescanTombstoneGate': True, 'mixedScopePreflightNoPartialDeletion': True,
            'emptyTrashMixedScopesPhysicalDeletion': True}


def cleanup_owned(directory, sentinel):
    """Only containers/volumes/network created by this lab, never global prune."""
    failures = []
    ids = docker('ps', '-aq', '--filter', 'label=com.docker.compose.project=immich').split()
    if ids:
        rows = json.loads(docker('inspect', *ids))
        need(len(rows) == len(ids) and all(row['Config'].get('Labels', {}).get(
            'com.docker.compose.project.working_dir') == str(directory) and
            row.get('Name') in {'/' + name for name in NAMES} for row in rows),
             'CLEANUP_REFUSES_FOREIGN_COMPOSE_RESOURCES')
        for row in rows:
            try:
                docker('rm', '-f', '-v', row['Id'])
            except LabFailure:
                failures.append('OWNED_CONTAINER_CLEANUP_FAILED')
    if sentinel:
        row = inspect(sentinel)
        need(row['Config'].get('Labels', {}).get('gallery.build11.disposable-lab') == str(directory),
             'CLEANUP_REFUSES_FOREIGN_SENTINEL')
        docker('rm', '-f', row['Id'])
    for volume in docker('volume', 'ls', '-q', '--filter', 'label=com.docker.compose.project=immich').split():
        info = json.loads(docker('volume', 'inspect', volume))
        need(len(info) == 1 and info[0].get('Labels', {}).get('com.docker.compose.project') == PROJECT and
             volume == 'immich_model-cache', 'CLEANUP_REFUSES_FOREIGN_VOLUME')
        docker('volume', 'rm', volume)
    for network in docker('network', 'ls', '-q', '--filter', 'name=^immich_default$').split():
        info = json.loads(docker('network', 'inspect', network))
        need(len(info) == 1 and info[0].get('Labels', {}).get('com.docker.compose.project') == PROJECT,
             'CLEANUP_REFUSES_FOREIGN_NETWORK')
        docker('network', 'rm', network)
    return failures


def run(package, output):
    need(output.is_absolute() and not output.exists() and not output.is_symlink(), 'NEW_INSTALLATION_LAB_REPORT_REQUIRED')
    config = verify_package(package)
    need(config['version'] == '5.7.3' and config['build'] == 11, 'EXACT_BUILD11_COMPILED_PACKAGE_REQUIRED')
    fail_if_existing_installation()
    profile = json.loads((package / 'candidate-profile.json').read_text())
    compatibility = json.loads((package / 'reviewed-compatibility.json').read_text())
    directory = Path(tempfile.mkdtemp(prefix='gallery-build11-install-lab-')).resolve()
    directory.chmod(0o700)
    installation = directory / 'installation'
    installation.mkdir(mode=0o700)
    env = directory / 'private.env'
    env.write_text('DB_PASSWORD=' + secrets.token_urlsafe(30).replace('-', '_') + '\n')
    env.chmod(0o600)
    report = {'schemaVersion': 1, 'marker': MARKER, 'sourceCommit': config['sourceCommit'],
              'packageSHA256': digest(package / 'SHA256SUMS'), 'checks': {}, 'result': 'FAIL',
              'syntheticMediaOnly': True, 'productionChanged': False,
              'hpRecoveryEvidenceVerified': False, 'productionNfsVerified': False,
              'physicalAndroidIosVerified': False, 'hpSixLegacyCleanupExecuted': False}
    report.update(installationEngine='PACKAGED_GALLERY_INSTALL',
                  cleanInstallationStorage='LOCAL_MANAGED_ONLY', externalDeletionStorage='EXPLICIT_SYNTHETIC_LOCAL_BIND_AFTER_FRESH_ROLLBACK',
                  upgradeEngine='PACKAGED_IMAGE_RELEASE_WITH_REAL_READ_ONLY_LAB_QUEUE_GATE',
                  hpWrapper='NOT_TESTED_HP_RECOVERY_AND_OLD_SIX_REQUIRED')
    sentinel = None
    stage = 'interrupted configuration creation'
    try:
        invoke_installer(package, installation, env, config['machineLearningImage'], fault='before-plan')
        need(not (installation / 'fresh-install-plan.json').exists(), 'PLAN_FAULT_DID_NOT_INTERRUPT')
        need(not docker('ps', '-aq').split(), 'CONFIGURATION_FAULT_STARTED_SERVICES')
        config_hashes = {name: digest(installation / name) for name in
                         ('.env', 'docker-compose.yml', 'image-only.override.json')}
        stage = 'configuration resume and real service-start interruption'
        invoke_installer(package, installation, env, config['machineLearningImage'], fault='after-start')
        need((installation / 'fresh-install-plan.json').is_file() and
             not (installation / 'fresh-install-completed.json').exists(), 'POST_START_FAULT_NOT_RECORDED')
        need(config_hashes == {name: digest(installation / name) for name in config_hashes},
             'INITIALIZATION_RESUME_CHANGED_CONFIGURATION')
        stage = 'actual clean-install resume'
        invoke_installer(package, installation, env, config['machineLearningImage'])
        before_ids = installation_containers(installation)
        stage = 'actual completed-install repeat'
        invoke_installer(package, installation, env, config['machineLearningImage'])
        need(before_ids == installation_containers(installation), 'COMPLETED_INSTALL_REPEAT_RECREATED_SERVICES')
        report['checks'].update(cleanInstallation=True, configurationInterruptionResume=True,
                                serviceStartInterruptionResume=True, idempotentCompletedInstall=True)
        api = Api()
        credentials = {'email': 'installation-lab@example.invalid', 'password': secrets.token_urlsafe(24)}
        api('/auth/admin-sign-up', 'POST', {**credentials, 'name': 'Disposable installer lab'})
        api.login(credentials)
        owner = api('/users/me')['id']
        kept = media.upload_synthetic(api, media.synthetic_png(44))
        synthetic_thumbnail(api, kept)
        album = api('/albums', 'POST', {'albumName': 'Disposable preserved album', 'assetIds': [kept]})['id']
        other = {'email': 'other-installation-lab@example.invalid', 'password': secrets.token_urlsafe(24)}
        api('/admin/users', 'POST', {**other, 'name': 'Disposable other owner', 'shouldChangePassword': False})
        api.login(other)
        other_asset = media.upload_synthetic(api, media.synthetic_png(49))
        api.login(credentials)
        offline = media.upload_synthetic(api, media.synthetic_png(45))
        need(re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', offline), 'LAB_ASSET_UUID_REQUIRED')
        # A representative offline external index record, not user Trash. Keep
        # its synthetic original and every timestamp/identifier unchanged.
        offline_path = original_host_path(offline)
        offline_scope = api('/libraries', 'POST', {'ownerId': owner, 'name': 'Disposable offline index scope',
                                                  'importPaths': ['/external/build11-installation-offline']})['id']
        need(re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', offline_scope), 'LAB_SCOPE_UUID_REQUIRED')
        sql("UPDATE asset SET \"libraryId\"='" + offline_scope + "',\"isOffline\"=true,"
            "\"deletedAt\"='2024-05-01T00:00:00Z' WHERE id='" + offline + "';", write=True)
        offline_hash = physical_hash(offline_path)
        stage = 'actual packaged fresh-install rollback and repeat'
        os.environ['GALLERY_DEPLOYMENT_APPROVED'] = 'YES'
        command(['bash', str(package / 'tools/gallery-rollback.sh'), '--fresh-install', str(package),
                 str(installation), '--execute-approved'], timeout=2400)
        fresh_rollback_ids = installation_containers(installation)
        command(['bash', str(package / 'tools/gallery-rollback.sh'), '--fresh-install', str(package),
                 str(installation), '--execute-approved'], timeout=2400)
        need(fresh_rollback_ids == installation_containers(installation), 'FRESH_ROLLBACK_REPEAT_RECREATED_SERVICES')
        api.login(credentials)
        need(api('/assets/' + kept + '/original', raw=True) == media.synthetic_png(44) and
             physical_hash(offline_path) == offline_hash, 'FRESH_ROLLBACK_CHANGED_ORIGINALS')
        report['checks'].update(freshInstallRollbackWithPackagedWrapper=True, idempotentFreshRollback=True)
        stage = 'representative paused queue fixture creation'
        snapshot = queue_snapshot(owner, 'seed')
        report['checks']['representative27PausedJobsCreated'] = True
        engine = load_packaged_tools(package)
        engine.DIRECTORY = installation
        engine.DOCKER = ['sudo', '-n', 'docker', '--host=' + SOCKET]
        candidate = json.loads((installation / 'fresh-install-plan.json').read_text())['candidateImage']
        rollback = json.loads((package / 'rollback/manifest.json').read_text())
        # Artifact identity is already checksum-bound by verify_package; verify
        # every real Docker config/layer again before importing the fallback.
        sys.path.insert(0, str(package / 'tools'))
        spec = importlib.util.spec_from_file_location('actual_packaged_operator', package / 'tools/build11_operator.py')
        operator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(operator)
        operator.core.DOCKER = engine.DOCKER
        fallback = operator.artifact_image(package / 'rollback', rollback['sourceCommit'], rollback['serverVersion'],
                                           rollback, allow_load=True)
        # Docker containerd may expose the verified manifest ID rather than the
        # verified archive config ID. Only derive aliases from the streaming
        # archive verifier/actual install receipt; never resolve mutable tags.
        need(compatibility['candidateImage'] == profile['backend']['imageId'] and
             compatibility['rollbackImage'] == rollback['imageId'], 'PINNED_PACKAGE_COMPATIBILITY_IMAGE_MISMATCH')
        compatibility_path = directory / 'lab-verified-image-store-compatibility.json'
        engine.save(compatibility_path, {**compatibility, 'candidateImage': candidate, 'rollbackImage': fallback})
        current = engine.inspect(engine.SERVER)
        base, _ = engine.compose_base(current)
        stage = 'compiled Build10 runtime representative state'
        need(current['Image'] == fallback, 'REAL_PACKAGED_FRESH_ROLLBACK_IMAGE_MISMATCH')
        # Prepare the representative existing Build10 mount topology before
        # capturing the upgrade baseline. This is NOT a fake NFS configuration
        # or a modification of the sealed fresh installer: an explicit local
        # synthetic external bind models its already-configured storage roots.
        external = directory / 'external-synthetic'
        external.mkdir(mode=0o700)
        (external / 'build11-installation-offline').mkdir(mode=0o700)
        mount_override = installation / 'representative-build10-external.override.json'
        engine.save(mount_override, {'services': {engine.SERVICE: {'volumes': [
            {'type': 'bind', 'source': str(external), 'target': '/external', 'read_only': False,
             'bind': {'create_host_path': False}}]}}})
        engine.run([*base, '-f', str(mount_override), 'up', '-d', '--no-deps', '--no-build', '--pull', 'never',
                    engine.SERVICE], timeout=180)
        engine.health(api.base, fallback, rollback['sourceCommit'],
                      dict(zip(('major', 'minor', 'patch', 'prerelease'), (*engine.version(rollback['serverVersion']), None))), timeout=180)
        api.login(credentials)
        unchanged_queue(snapshot, queue_snapshot(owner))
        # The compatible fallback carries the exact future migration for safe
        # downgrade. Undo only that additive schema/ledger in this disposable
        # fixture to represent the existing Build10 schema before upgrading.
        sql('BEGIN; ALTER TABLE asset_deletion_policy DROP CONSTRAINT asset_deletion_policy_authorization_mode; '
            'ALTER TABLE asset_deletion_policy DROP COLUMN "authorizationMode"; '
            "DELETE FROM kysely_migrations WHERE name='" + MIGRATION + "'; COMMIT;", write=True)
        need(MIGRATION not in engine.live_migrations(), 'BUILD10_FIXTURE_LEDGER_NOT_ESTABLISHED')
        stage = 'representative upstream database snapshot'
        stable_database = database_snapshot()
        preserved_services = storage_and_service_snapshot(installation)
        sentinel = 'gallery-build11-unrelated-' + secrets.token_hex(6)
        docker('run', '-d', '--name', sentinel, '--label', 'gallery.build11.disposable-lab=' + str(installation),
               '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
               '--entrypoint', 'node', candidate, '-e', 'setInterval(()=>{},1000)')
        sentinel_id = inspect(sentinel)['Id']
        state = directory / 'image-state'
        state.mkdir(mode=0o700)
        args = SimpleNamespace(state=state, image=candidate, expected_current_image=fallback,
                               source_commit=profile['sourceCommit'], server_version=(5, 7, 3), api=api.base,
                               rollback_image=fallback, rollback_source_commit=rollback['sourceCommit'],
                               rollback_server_version=engine.version(rollback['serverVersion']),
                               compatibility_receipt=compatibility_path,
                               compatibility_sha256=digest(compatibility_path))
        # Actual read-only BullMQ/Redis gate. Never fake an empty queue or reuse
        # HP receipts. All 27 synthetic job hashes/order and six files must match.
        engine.queue_safety = lambda: unchanged_queue(snapshot, queue_snapshot(owner))
        stage = 'real image-only upgrade plan and dry-run'
        engine.plan(args)
        engine.execute(SimpleNamespace(state=state, execute_approved=False, approve_migration=False))
        need(database_snapshot() == stable_database, 'UPGRADE_PLAN_CHANGED_DATABASE')
        stage = 'real migration and simulated post-upgrade health interruption'
        os.environ['GALLERY_DEPLOYMENT_APPROVED'] = 'YES'
        os.environ['GALLERY_ADDITIVE_MIGRATION_APPROVED'] = 'YES'
        real_health = engine.health
        def injected_health_failure(*unused, **kwargs):
            raise engine.Stop('INJECTED_POST_UPGRADE_HEALTH_INTERRUPTION')
        engine.health = injected_health_failure
        try:
            engine.execute(SimpleNamespace(state=state, execute_approved=True, approve_migration=True))
        except engine.Stop as error:
            need(str(error) == 'INJECTED_POST_UPGRADE_HEALTH_INTERRUPTION', 'UNEXPECTED_UPGRADE_FAILURE')
        else:
            raise LabFailure('EXPECTED_POST_UPGRADE_FAILURE_NOT_REACHED')
        finally:
            engine.health = real_health
        engine.health(api.base, candidate, profile['sourceCommit'],
                      {'major': 5, 'minor': 7, 'patch': 3, 'prerelease': None}, timeout=180)
        need((state / 'apply-attempt.json').is_file() and not (state / 'applied.json').exists(),
             'INTERRUPTED_UPGRADE_JOURNAL_INVALID')
        need(MIGRATION in engine.live_migrations(), 'ACTUAL_ADDITIVE_MIGRATION_DID_NOT_RUN')
        need(database_snapshot() == stable_database, 'UPGRADE_CHANGED_USER_ASSET_ALBUM_OR_OFFLINE_RECORDS')
        unchanged_queue(snapshot, queue_snapshot(owner))
        exact_namespace_preserved(preserved_services, storage_and_service_snapshot(installation))
        need(inspect(sentinel)['Id'] == sentinel_id, 'UNRELATED_CONTAINER_RECREATED')
        api.login(credentials)
        need(any(item['id'] == album for item in api('/albums')), 'PRESERVED_ALBUM_NOT_ACCESSIBLE')
        need(api('/assets/' + kept + '/original', raw=True) == media.synthetic_png(44), 'PRESERVED_ORIGINAL_CHANGED')
        stage = 'actual HTTP synthetic Trash/Restore/managed permanent delete'
        report['checks'].update(real_lifecycle(api, other, other_asset))
        report['checks'].update(external_lifecycle(api, owner))
        report['checks']['apiAndMicroservicesPreserved'] = True
        need(physical_hash(offline_path) == offline_hash, 'OFFLINE_EXTERNAL_ORIGINAL_CHANGED')
        stage = 'fresh already-upgraded backup and isolated restore'
        database_before_recovery = database_snapshot()
        services_before_recovery = storage_and_service_snapshot(installation)
        report['alreadyUpgradedRecovery'] = upgraded_backup_restore(
            operator, directory / 'already-upgraded-recovery', profile['sourceCommit'], candidate, fallback)
        need(database_snapshot() == database_before_recovery, 'FRESH_RECOVERY_CHANGED_LAB_DATABASE')
        exact_namespace_preserved(services_before_recovery, storage_and_service_snapshot(installation))
        unchanged_queue(snapshot, queue_snapshot(owner))
        need(inspect(sentinel)['Id'] == sentinel_id and physical_hash(offline_path) == offline_hash,
             'FRESH_RECOVERY_CHANGED_UNRELATED_CONTAINER_OR_ORIGINAL')
        report['checks']['alreadyUpgradedFreshBackupRestore'] = True
        rollback_asset = media.upload_synthetic(api, media.synthetic_png(65))
        api('/assets', 'DELETE', {'ids': [rollback_asset], 'force': False})
        stage = 'real hardened rollback after interrupted upgrade'
        engine.execute(SimpleNamespace(state=state, execute_approved=True, approve_migration=True), rollback=True)
        api.login(credentials)
        need(api('/assets/' + rollback_asset)['isTrashed'] is True, 'ROLLBACK_LOST_TRASH')
        need(api('/assets/' + rollback_asset + '/original', raw=True) == media.synthetic_png(65), 'ROLLBACK_LOST_ORIGINAL')
        denied = api('/assets/permanent-deletion', 'POST', {'ids': [rollback_asset], 'confirmed': True})
        need(len(denied) == 1 and denied[0]['state'] == 'blocked' and
             denied[0]['code'] == 'MANAGED_DELETION_PREPARATION_REQUIRED', 'FALLBACK_ACCEPTED_STORAGE_GRANT')
        need(api('/trash/restore/assets', 'POST', {'ids': [rollback_asset]}) == {'count': 1}, 'ROLLBACK_RESTORE_FAILED')
        unchanged_queue(snapshot, queue_snapshot(owner))
        exact_namespace_preserved(preserved_services, storage_and_service_snapshot(installation))
        need(inspect(sentinel)['Id'] == sentinel_id, 'ROLLBACK_RECREATED_UNRELATED_CONTAINER')
        stage = 'idempotent interrupted attempt refusal'
        try:
            engine.execute(SimpleNamespace(state=state, execute_approved=True, approve_migration=True), rollback=True)
        except engine.Stop as error:
            need(str(error) == 'EXISTING_ATTEMPT_RETAINED_DO_NOT_REPEAT', 'ROLLBACK_REPEAT_UNEXPECTED_FAILURE')
        else:
            raise LabFailure('ROLLBACK_ATTEMPT_REPLAYED')
        report['checks'].update(representativeBuild10Upgrade=True, additiveMigrationExecuted=True,
                                existingDataPreserved=True, offlineIndexTombstonePreserved=True,
                                all27PausedJobBytesAndOrderPreserved=True, sixSyntheticLegacyOriginalsPreserved=True,
                                storageMountsNetworksEnvironmentPreserved=True, unrelatedServicesPreserved=True,
                                rollbackAfterInjectedFailure=True, rollbackTrashRestore=True,
                                oldRuntimeRejectsStorageGrants=True, interruptedAttemptReplayPrevented=True)
        report['result'] = 'PASS'
    except Exception as error:
        report['failedStage'] = stage
        code = str(error)
        report['failure'] = code if isinstance(error, LabFailure) or re.fullmatch('[A-Z0-9_]+', code) else 'LAB_FAILED_PRIVATE_DETAILS_OMITTED'
        report['failureType'] = type(error).__name__
        report['failureLine'] = traceback.extract_tb(error.__traceback__)[-1].lineno
        diagnostic = validated_diagnostic(getattr(error, 'diagnostic', None))
        if diagnostic:
            report['commandDiagnostic'] = diagnostic
        print('FAIL installation lab stage=' + stage + ' code=' + report['failure'], flush=True)
    finally:
        report['completedAt'] = datetime.now(timezone.utc).isoformat()
        try:
            report['cleanupErrors'] = cleanup_owned(installation, sentinel)
        except Exception:
            report['cleanupErrors'] = ['OWNED_LAB_CLEANUP_FAILED_NO_UNRELATED_RESOURCES_TOUCHED']
        if report['cleanupErrors']:
            report['result'] = 'FAIL'
        with os.fdopen(os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), 'w') as handle:
            json.dump(report, handle, indent=2)
            handle.write('\n')
            handle.flush()
            os.fsync(handle.fileno())
    print(report['result'] + ' actual compiled-package installation/upgrade/rollback lab; HP and NFS remain operator gates')
    return 0 if report['result'] == 'PASS' else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package', type=Path)
    parser.add_argument('report', type=Path)
    args = parser.parse_args(argv)
    try:
        return run(args.package.absolute(), args.report.absolute())
    except Exception as error:
        code = str(error) if isinstance(error, (LabFailure, ValueError)) and re.fullmatch('[A-Z0-9_]+', str(error)) else 'INSTALLATION_LAB_FAILED_PRIVATE_DETAILS_OMITTED'
        print('FAIL ' + code)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
