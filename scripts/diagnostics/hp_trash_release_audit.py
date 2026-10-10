#!/usr/bin/env python3
"""Sanitized, read-only HP deletion inventory. Only writes a new private report.

No API job listing (it can repair jobs), Queue/Worker constructors, Redis Lua,
job retry/cancel, file write probes, schema changes or service operations.
"""
import json
from datetime import datetime, timezone
import os
from pathlib import Path
import pwd
import re
import subprocess
import sys
import uuid

REPORT = None  # Every invocation gets a new name; tests may supply an exact path.
REPORT_DIRECTORY = Path('/home/doctoriceadm')
SERVER = 'immich_server'

# Runs inside the existing server, resolving only its installed configuration
# and dependencies. Credentials and private paths never leave this process.
NODE_AUDIT = r'''
import {createRequire} from 'node:module';
import fs from 'node:fs';
import crypto from 'node:crypto';
import path from 'node:path';
const require = createRequire('/usr/src/app/server/package.json');
const roots = __MOUNT_ROOTS__;
const result = {readOnly:true, queueSnapshot:'LIVE_NON_ATOMIC', sections:{}, errors:[]};
const allowedCodes=new Set(['42P01','42703','42501','57014','28P01','3D000',
  'ECONNREFUSED','ECONNRESET','ETIMEDOUT','ENOENT','EACCES','EPERM','ENOTDIR']);
const errorCode=error=>allowedCodes.has(error?.code)?error.code:'UNCLASSIFIED_ERROR';
const probe=async(stage, action)=>{
  try {const value=await action();result.sections[stage]='PASS';return value;}
  catch(error) {result.sections[stage]='FAILED';result.errors.push(stage+':'+errorCode(error));}
};
let redis, sql, config;
try {
  const {ConfigRepository} = await import('file:///usr/src/app/server/dist/repositories/config.repository.js');
  config = new ConfigRepository().getEnv();
  const postgres = require('postgres');
  const options = {max:1, connect_timeout:5, idle_timeout:2, prepare:false,
    onnotice:()=>{}, debug:false,
    connection:{default_transaction_read_only:'on', statement_timeout:3000,
      application_name:'gallery-trash-readonly-audit'}};
  const db = config.database.config;
  sql = db.connectionType === 'url' ? postgres(db.url, options) : postgres({...options,
    host:db.host, port:db.port, username:db.username, password:db.password,
    database:db.database, ssl:db.ssl});
  const [session] = await sql`SELECT current_setting('default_transaction_read_only') AS ro,
    current_setting('server_version') AS version`;
  if (session.ro !== 'on') throw Error('readonly');
  result.postgres = {version:session.version, readOnly:session.ro};
  const settings = await probe('SETTINGS',async()=>{
    const [row]=await sql`SELECT value->'trash' AS trash, value->'backup' AS backup
      FROM system_metadata WHERE key='system-config'`;return row??{};
  });
  let override;
  if (config.configFile) {
    try {override = JSON.parse(fs.readFileSync(config.configFile, 'utf8'));}
    catch {result.errors.push('CONFIG_FILE_UNREADABLE');}
  }
  const configUnknown = Boolean(config.configFile && !override)||(!config.configFile&&settings===undefined);
  const value = override ?? settings ?? {};
  const trash = value.trash ?? {};
  result.trash = {source:config.configFile?'config-file':'database/defaults',
    enabled:configUnknown?null:typeof trash.enabled==='boolean'?trash.enabled:true,
    days:configUnknown?null:Number.isInteger(trash.days)?trash.days:30};
  result.backupSettings = {automaticEnabled:configUnknown?null:value.backup?.database?.enabled ?? true,
    restoreValidated:'UNKNOWN'};
  await probe('ASSET_COUNTS',async()=>{
    result.assetCounts = await sql`SELECT status, count(*)::text AS count,
    count(*) FILTER (WHERE "libraryId" IS NOT NULL)::text AS external,
    count(*) FILTER (WHERE "deletedAt" IS NOT NULL)::text AS with_deleted_at
    FROM asset GROUP BY status`;
  });
  await probe('ACTIVE_DELETED_AT',async()=>{
    // Library scan marks missing external assets offline without changing Active.
    // Library removal also sets deletedAt before its index-cleanup jobs run.
    const rows=await sql`SELECT a."libraryId" IS NOT NULL AS external,
      a."isOffline" AS offline,l."deletedAt" IS NOT NULL AS library_removal_pending,
      count(*)::text AS count,
      count(*) FILTER (WHERE a."deletedAt"<=CURRENT_TIMESTAMP-
        (${result.trash.days??30}::int*interval '1 day'))::text AS older_than_retention
      FROM asset a LEFT JOIN library l ON l.id=a."libraryId"
      WHERE a.status='active' AND a."deletedAt" IS NOT NULL
      GROUP BY 1,2,3`;
    result.activeWithDeletedAt={total:rows.reduce((n,r)=>n+Number(r.count),0), groups:rows.map(r=>({...r,
      classification:r.external&&r.library_removal_pending?'LIBRARY_REMOVAL_INDEX_CLEANUP_EXPECTED':
        r.external&&r.offline?'OFFLINE_EXTERNAL_INDEX_TOMBSTONE_EXPECTED':
        'ACTIVE_ONLINE_OR_MANAGED_INCONSISTENCY_REVIEW_STOP'})),
      interpretation:'Expected index lifecycle is not user Trash; unknown/inconsistent groups block release.'};
  });
  await probe('MIGRATIONS',async()=>{
    // DatabaseRepository.createMigrator explicitly uses the plural table name.
    result.migrations = await sql`SELECT count(*)::text AS count, max(name) AS latest FROM kysely_migrations`;
  });
  await probe('DELETION_QUEUES',async()=>{
  const Redis = require('ioredis');
  redis = new Redis({...config.redis, lazyConnect:true, maxRetriesPerRequest:0,
    retryStrategy:()=>null, connectTimeout:5000, commandTimeout:5000,
    enableOfflineQueue:false, enableReadyCheck:false});
  redis.on('error',()=>{});
  await redis.connect();
  const prefix=(config.bull.config.prefix??'immich_bull')+':backgroundTask:';
  const ids=new Map();
  const maxJobs=5000, maxPaths=10000, started=Date.now();
  const paused=await redis.hget(prefix+'meta','paused');
  result.queue={paused:paused==='1'||paused==='true', states:{}, truncated:false};
  for (const state of ['active','wait','paused','delayed','prioritized','waiting-children','failed']) {
    const list=['active','wait','paused'].includes(state);
    const size=Number(await redis[list?'llen':'zcard'](prefix+state));
    result.queue.states[state]=size;
    const values=await redis[list?'lrange':'zrange'](prefix+state,0,maxJobs-1);
    if (size>values.length) result.queue.truncated=true;
    for (const id of values) {
      if(ids.size>=maxJobs && !ids.has(id)) {result.queue.truncated=true;break;}
      ids.set(id,state);
    }
  }
  const secret=crypto.randomBytes(32);
  const token=id=>crypto.createHmac('sha256',secret).update(id).digest('hex').slice(0,12);
  const jobs=[], paths=new Set(), assetIds=new Set();
  for(const [id,state] of ids) {
    if(Date.now()-started>45000) {result.queue.truncated=true;break;}
    const [name,data,timestamp]=await redis.hmget(prefix+id,'name','data','timestamp');
    if(!['AssetDelete','FileDelete'].includes(name)) continue;
    let payload;
    try {if(!data||data.length>262144) throw Error();payload=JSON.parse(data);}
    catch {result.errors.push('JOB_PAYLOAD_UNREADABLE');continue;}
    if(!payload||typeof payload!=='object'||Array.isArray(payload)) {
      result.errors.push('JOB_PAYLOAD_SHAPE');continue;
    }
    const job={name,state,token:token(id),payload,
      ageDays:Math.max(0,Math.floor((Date.now()-Number(timestamp))/86400000))};
    jobs.push(job);
    if(name==='AssetDelete') {
      if(/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(payload.id||'')) assetIds.add(payload.id);
      else result.errors.push('ASSET_JOB_ID_SHAPE');
    }
    if(name==='FileDelete') {
      if(!Array.isArray(payload.files)) {result.errors.push('FILE_JOB_SHAPE');continue;}
      for(const path of payload.files) {
        // IDeleteFilesJob permits absent optional derivatives. JSON serializes
        // undefined array slots as null; the worker skips these without I/O.
        if(path===null) continue;
        if(typeof path!=='string'||!path.startsWith('/')) {result.errors.push('FILE_PATH_SHAPE');continue;}
        if(paths.size<maxPaths) paths.add(path); else result.queue.truncated=true;
      }
    }
  }
  const assets=new Map(), references=new Map();
  const batches=(values)=>Array.from({length:Math.ceil(values.length/250)},(_,i)=>values.slice(i*250,(i+1)*250));
  const assetReferencesKnown=await probe('ASSET_JOB_REFERENCES',async()=>{
  for(const batch of batches([...assetIds])) {
    const rows=await sql`SELECT id,status,"isOffline" AS offline,"originalPath" AS path,
      "libraryId" IS NOT NULL AS external,"deletedAt" IS NOT NULL AS with_deleted_at
      FROM asset WHERE id=ANY(${batch}::uuid[])`;
    for(const row of rows) assets.set(row.id,row);
  }
  return true;
  });
  const fileReferencesKnown=await probe('FILE_JOB_REFERENCES',async()=>{
  for(const batch of batches([...paths])) {
    const rows=await sql`SELECT "originalPath" AS path,status,'original' AS kind
      FROM asset WHERE "originalPath"=ANY(${batch}::text[])
      UNION ALL SELECT f.path,a.status,'asset_file' AS kind
      FROM asset_file f JOIN asset a ON a.id=f."assetId" WHERE f.path=ANY(${batch}::text[])`;
    for(const row of rows) {
      const set=references.get(row.path)??new Set();set.add(row.kind+':'+row.status);references.set(row.path,set);
    }
  }
  return true;
  });
  const onExternal=file=>typeof file==='string'&&roots.some(root=>{
    const normalized=path.resolve(file);return normalized===root||normalized.startsWith(root+'/');
  });
  const counts={}, examples=[], assetReferences={}, fileReferences={};
  for(const job of jobs) {
    let risk;
    if(job.name==='AssetDelete') {
      const a=assets.get(job.payload.id);
      const originalPossible=job.payload.deleteOnDisk===true&&a&&!a.offline;
      const reason=job.payload.deletionReason;
      const reference=!assetReferencesKnown?'UNKNOWN_STOP':!a?'missing':
        a.status+':'+(a.external?'external':'managed')+':'+(a.offline?'offline':'online')+
        ':deletedAt='+(a.with_deleted_at?'set':'null');
      assetReferences[reference]=(assetReferences[reference]??0)+1;
      risk=!assetReferencesKnown?'ASSET_REFERENCES_UNKNOWN_STOP':!a?'asset-missing':reason==='library'||reason==='motion'?
        'explicit-'+reason+'-guard-required':job.payload.trashedBefore===undefined?
        (a.status==='deleted'?'legacy-deleted':'legacy-active-or-trashed'):'cutoff-present-not-proof';
      if(originalPossible&&onExternal(a.path)) risk+=':external-original-unlink-capable';
    } else {
      const files=Array.isArray(job.payload.files)?job.payload.files.filter(file=>file!==null):[];
      const current=files.some(path=>references.has(path));
      const nas=files.some(onExternal);
      risk=!fileReferencesKnown?'FILE_REFERENCES_UNKNOWN_STOP':
        current?'CURRENT_DB_FILE_REFERENCE_STOP':nas?'NAS_PATH_UNLINK_CAPABLE_STOP':'SCOPE_UNPROVEN_REVIEW';
      for(const file of files) for(const reference of references.get(file)??[]) {
        fileReferences[reference]=(fileReferences[reference]??0)+1;
      }
      if(examples.length<12) examples.push({jobToken:job.token,state:job.state,risk});
    }
    const key=job.name+':'+job.state+':'+risk;
    counts[key]=(counts[key]??0)+1;
  }
  result.deletionJobs={counts, fileDeleteExamples:examples,
    assetReferences, fileReferences, inventoryComplete:!result.queue.truncated&&
      Boolean(assetReferencesKnown)&&Boolean(fileReferencesKnown)&&result.errors.length===0,
    legacyAssetDelete:jobs.filter(j=>j.name==='AssetDelete'&&j.payload.trashedBefore===undefined&&!j.payload.deletionReason).length,
    fileDelete:jobs.filter(j=>j.name==='FileDelete').length,
    fileDeleteContract:'PATH_ONLY_NO_ASSET_CUTOFF_ALL_EXISTING_JOBS_REQUIRE_REVIEW',
    maximumAgeDays:Math.max(0,...jobs.map(j=>Number.isFinite(j.ageDays)?j.ageDays:0))};
  });
  result.containerMountPermissionIndications=roots.map((root,index)=>{
    let writable=false;try {fs.accessSync(root,fs.constants.W_OK);writable=true;} catch {}
    return {mount:index+1, auditUid:process.getuid(), directoryAccessW_OK:writable,
      actualCreateUnlink:'NOT_TESTED'};
  });
} catch(error) {result.errors.push('CONFIG_OR_POSTGRES_CONNECT:'+errorCode(error));}
// Inventory independent filesystem evidence even if PostgreSQL/Redis failed.
result.backupFiles={status:'UNKNOWN_NOT_INVENTORIED',restoreValidated:'UNKNOWN'};
await probe('BACKUP_INVENTORY',async()=>{
  if(!config) throw Error();
  // Match StorageService.detectMediaLocation, including the legacy upload mount.
  const mediaCandidates=['/data','/usr/src/app/upload'].filter(path=>fs.existsSync(path));
  const mediaRoot=config.storage.mediaLocation||
    (mediaCandidates.length===1?mediaCandidates[0]:'/usr/src/app/upload');
  const backupRoot=mediaRoot+'/backups';
  const files=fs.readdirSync(backupRoot), limited=files.slice(0,1000);
  const backups=limited.filter(x=>/^[\d\w-.]+\.sql(?:\.gz)?$/.test(x))
    .map(x=>fs.lstatSync(backupRoot+'/'+x)).filter(x=>x.isFile());
  result.backupFiles={count:backups.length, boundedAt:1000, truncated:files.length>1000,
      incompleteTempFiles:limited.filter(x=>x.endsWith('.sql.gz.tmp')).length,
      zeroByteFiles:backups.filter(x=>x.size===0).length,
      totalBytes:backups.reduce((n,x)=>n+x.size,0),
      newestAgeHours:backups.length?Math.round((Date.now()-Math.max(...backups.map(x=>x.mtimeMs)))/3600000):null,
      restoreValidated:'UNKNOWN', status:'INVENTORY_ONLY'};
});
await probe('VERSION',async()=>{
  result.runningVersion=JSON.parse(fs.readFileSync('/usr/src/app/server/package.json','utf8')).version;
});
await probe('RESOURCE_CLEANUP',async()=>{
  redis?.disconnect();
  if(sql) await sql.end({timeout:1});
});
console.log(JSON.stringify(result));
'''


def command(args, *, input=None, timeout=15):
    result = subprocess.run(args, input=input, text=True, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError('read-only probe failed')
    return result.stdout


def snapshot_evidence(mountpoint):
    """Bounded directory inventory, never names/media/credentials or NAS API calls."""
    evidence = []
    for marker in ('#snapshot', '.snapshot'):
        item = {'marker': marker, 'recoverability': 'NOT_VERIFIED'}
        try:
            directory = mountpoint / marker
            if not directory.is_dir():
                item['status'] = 'NOT_VISIBLE_NOT_PROOF_OF_ABSENCE'
            else:
                count = 0
                inspected = 0
                with os.scandir(directory) as entries:
                    for entry in entries:
                        inspected += 1
                        if entry.is_dir(follow_symlinks=False):
                            count += 1
                        if inspected >= 100:
                            break
                item.update(status='VISIBLE_DIRECTORY_INVENTORY_ONLY',
                            visibleDirectories=count, boundedAt=100, truncated=inspected >= 100)
        except OSError:
            item['status'] = 'UNKNOWN_OR_INACCESSIBLE'
        evidence.append(item)
    return evidence


def collect(docker):
    report = {'scope': 'READ_ONLY_NO_JOB_RETRY_OR_MUTATION', 'deploymentReady': False}
    names = ['immich_server', 'immich_postgres', 'immich_redis', 'immich_machine_learning']
    containers = []
    external_roots = []
    try:
        mounts = json.loads(command(['findmnt', '-J', '-t', 'cifs,nfs,nfs4', '-o', 'TARGET,FSTYPE,VFS-OPTIONS']))
        def flatten(rows):
            for row in rows:
                yield row
                yield from flatten(row.get('children', []))
        nas_mounts = list(flatten(mounts.get('filesystems', [])))[:100]
    except Exception:
        nas_mounts = []
        report['hostMountInventory'] = 'UNKNOWN_OR_NO_VISIBLE_NETWORK_FILESYSTEMS'
    report['hostNetworkMounts'] = [{'mountpoint': m['target'], 'fstype': m['fstype'],
                                  'readOnly': 'ro' in m.get('vfs-options', '').split(',')}
                                 for m in nas_mounts]
    try:
        discovered = command([*docker, 'ps', '--filter', 'label=com.docker.compose.project', '--format', '{{.Names}}']).splitlines()[:100]
        # Read topology only; never emit unrelated container/environment names.
        names.extend(n for n in discovered if n.startswith(('immich_', 'gallery_')) and n not in names)
    except Exception:
        report['additionalConsumers'] = 'UNKNOWN'
    for name in names:
        try:
            item = json.loads(command([*docker, 'inspect', name]))[0]
            public = {'role': name, 'containerId': item['Id'][:12],
                      'imageId': item['Image'], 'running': item['State']['Running'],
                      'health': item['State'].get('Health', {}).get('Status', 'unknown'),
                      'composeService': item.get('Config', {}).get('Labels', {}).get('com.docker.compose.service')}
            if name == SERVER:
                # Never print Config.Env. Inspect it only for public build SHA/ref.
                env = dict(x.split('=', 1) for x in item.get('Config', {}).get('Env', []) if '=' in x)
                source = env.get('IMMICH_SOURCE_COMMIT', '')
                public['sourceCommit'] = source if re.fullmatch('[0-9a-fA-F]{40}', source) else 'unknown'
                public['workerMode'] = 'API_ONLY' if env.get('IMMICH_WORKERS_EXCLUDE') == 'microservices' else 'DEFAULT_OR_CUSTOM_NOT_PROVEN'
                public['externalMounts'] = []
                for mount in item.get('Mounts', []):
                    if mount.get('Type') != 'bind':
                        continue
                    try:
                        source = Path(mount['Source'])
                        matches = []
                        for found in nas_mounts:
                            target = Path(found['target'])
                            if source == target or target in source.parents:
                                matches.append((found, mount['Destination']))
                            elif source in target.parents:
                                matches.append((found, str(Path(mount['Destination']) / target.relative_to(source))))
                        for found, destination in matches:
                            target = found['target']
                        # Only mountpoints, never filenames/source/share addresses or mount options.
                            public['externalMounts'].append({'hostMountpoint': target, 'containerMountpoint': destination,
                                'fstype': found['fstype'], 'hostReadOnly': 'ro' in found.get('vfs-options', '').split(','),
                                'dockerRW': mount['RW'], 'unlinkTest': 'NOT_RUN'})
                            external_roots.append(destination.rstrip('/'))
                            public['externalMounts'][-1]['snapshotEvidence'] = snapshot_evidence(Path(target))
                            public['externalMounts'][-1]['snapshotAvailability'] = 'NEEDS_NAS_OPERATOR_CONFIRMATION'
                    except Exception:
                        public.setdefault('mountProbeUnknown', 0)
                        public['mountProbeUnknown'] += 1
            containers.append(public)
        except Exception:
            containers.append({'role': name, 'status': 'UNKNOWN_OR_INACCESSIBLE'})
    report['containers'] = containers
    try:
        program = NODE_AUDIT.replace('__MOUNT_ROOTS__', json.dumps(external_roots))
        report['backendReadOnlyAudit'] = json.loads(command([*docker, 'exec', '-i', SERVER, 'node', '--input-type=module'], input=program, timeout=90))
    except Exception:
        report['backendReadOnlyAudit'] = {'status': 'UNKNOWN_OR_INCOMPLETE'}
    report['limits'] = ['Live queue snapshot is not atomic; recheck paused/drained state before deployment.',
                        'W_OK/ro/rw are indications, not a file-specific SMB/NFS ACL or unlink test.',
                        'No visible #snapshot does not prove absence of Synology snapshots.',
                        'Backup existence is not proof of successful restoration.']
    return report


def main():
    if pwd.getpwuid(os.getuid()).pw_name != 'doctoriceadm':
        print('FAIL run as doctoriceadm; no report or production mutation performed.', file=sys.stderr)
        return 1
    report = REPORT or REPORT_DIRECTORY / (
        'gallery-trash-release-audit-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
        + '-' + uuid.uuid4().hex[:12] + '.txt')
    if report.exists() or report.is_symlink():
        print('FAIL audit report already exists; it was not overwritten.', file=sys.stderr)
        return 1
    try:
        command(['docker', 'version', '--format', '{{.Server.Version}}'], timeout=5)
        docker = ['docker']
    except Exception:
        try:
            command(['sudo', '-n', 'docker', 'version', '--format', '{{.Server.Version}}'], timeout=5)
            docker = ['sudo', '-n', 'docker']
        except Exception:
            print('FAIL read-only Docker access unavailable; no password requested.', file=sys.stderr)
            return 1
    # O_EXCL handles races; O_NOFOLLOW protects a symlink appearing after the check.
    try:
        fd = os.open(report, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except OSError:
        print('FAIL cannot create a new private report; nothing overwritten.', file=sys.stderr)
        return 1
    with os.fdopen(fd, 'w') as output:
        json.dump(collect(docker), output, indent=2)
        output.write('\n')
    print('PASS private report created:', report)
    print('NOT READY for deployment until report, backups and queue plan are reviewed.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
