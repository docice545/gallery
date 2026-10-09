#!/usr/bin/env python3
"""Sanitized, read-only HP deletion inventory. Only writes a new private report.

No API job listing (it can repair jobs), Queue/Worker constructors, Redis Lua,
job retry/cancel, file write probes, schema changes or service operations.
"""
import json
import os
from pathlib import Path
import pwd
import re
import subprocess
import sys

REPORT = Path('/home/doctoriceadm/gallery-trash-release-audit.txt')
SERVER = 'immich_server'

# Runs inside the existing server, resolving only its installed configuration
# and dependencies. Credentials and private paths never leave this process.
NODE_AUDIT = r'''
import {createRequire} from 'node:module';
import fs from 'node:fs';
import crypto from 'node:crypto';
const require = createRequire('/usr/src/app/server/package.json');
const roots = __MOUNT_ROOTS__;
const result = {readOnly:true, queueSnapshot:'LIVE_NON_ATOMIC', errors:[]};
let redis, sql;
try {
  const {ConfigRepository} = await import('file:///usr/src/app/server/dist/repositories/config.repository.js');
  const config = new ConfigRepository().getEnv();
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
  const [settings] = await sql`SELECT value->'trash' AS trash, value->'backup' AS backup
    FROM system_metadata WHERE key='system-config'`;
  let override;
  if (config.configFile) {
    try {override = JSON.parse(fs.readFileSync(config.configFile, 'utf8'));}
    catch {result.errors.push('CONFIG_FILE_UNREADABLE');}
  }
  const configUnknown = Boolean(config.configFile && !override);
  const value = override ?? settings ?? {};
  const trash = value.trash ?? {};
  result.trash = {source:config.configFile?'config-file':'database/defaults',
    enabled:configUnknown?null:typeof trash.enabled==='boolean'?trash.enabled:true,
    days:configUnknown?null:Number.isInteger(trash.days)?trash.days:30};
  result.backupSettings = {automaticEnabled:configUnknown?null:value.backup?.database?.enabled ?? true};
  const states = await sql`SELECT status, count(*)::text AS count,
    count(*) FILTER (WHERE "libraryId" IS NOT NULL)::text AS external,
    count(*) FILTER (WHERE "deletedAt" IS NOT NULL)::text AS with_deleted_at
    FROM asset GROUP BY status`;
  result.assetCounts = states;
  result.migrations = await sql`SELECT count(*)::text AS count, max(name) AS latest FROM kysely_migration`;
  const Redis = require('ioredis');
  redis = new Redis({...config.redis, lazyConnect:true, maxRetriesPerRequest:0,
    retryStrategy:()=>null, connectTimeout:5000});
  redis.on('error',()=>{});
  await redis.connect();
  const prefix='immich_bull:backgroundTask:';
  const ids=new Map();
  const maxJobs=5000, maxPaths=10000, started=Date.now();
  result.queue={paused:(await redis.hget(prefix+'meta','paused'))==='1', states:{}, truncated:false};
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
    const job={name,state,token:token(id),payload,
      ageDays:Math.max(0,Math.floor((Date.now()-Number(timestamp))/86400000))};
    jobs.push(job);
    if(name==='AssetDelete' && /^[0-9a-f-]{36}$/i.test(payload.id||'')) assetIds.add(payload.id);
    if(name==='FileDelete') {
      if(!Array.isArray(payload.files)) {result.errors.push('FILE_JOB_SHAPE');continue;}
      for(const path of payload.files) {
        if(typeof path!=='string'||!path.startsWith('/')) {result.errors.push('FILE_PATH_SHAPE');continue;}
        if(paths.size<maxPaths) paths.add(path); else result.queue.truncated=true;
      }
    }
  }
  const assets=new Map(), references=new Map();
  const batches=(values)=>Array.from({length:Math.ceil(values.length/250)},(_,i)=>values.slice(i*250,(i+1)*250));
  for(const batch of batches([...assetIds])) {
    const rows=await sql`SELECT id,status,"isOffline" AS offline,"originalPath" AS path,
      "libraryId" IS NOT NULL AS external FROM asset WHERE id=ANY(${batch}::uuid[])`;
    for(const row of rows) assets.set(row.id,row);
  }
  for(const batch of batches([...paths])) {
    const rows=await sql`SELECT "originalPath" AS path,status,'original' AS kind
      FROM asset WHERE "originalPath"=ANY(${batch}::text[])
      UNION ALL SELECT f.path,a.status,'asset_file' AS kind
      FROM asset_file f JOIN asset a ON a.id=f."assetId" WHERE f.path=ANY(${batch}::text[])`;
    for(const row of rows) {
      const set=references.get(row.path)??new Set();set.add(row.kind+':'+row.status);references.set(row.path,set);
    }
  }
  const onExternal=path=>typeof path==='string'&&roots.some(root=>path===root||path.startsWith(root+'/'));
  const counts={}, examples=[];
  for(const job of jobs) {
    let risk;
    if(job.name==='AssetDelete') {
      const a=assets.get(job.payload.id);
      const originalPossible=job.payload.deleteOnDisk===true&&a&&!a.offline;
      const reason=job.payload.deletionReason;
      risk=!a?'asset-missing':reason==='library'||reason==='motion'?
        'explicit-'+reason+'-guard-required':job.payload.trashedBefore===undefined?
        (a.status==='deleted'?'legacy-deleted':'legacy-active-or-trashed'):'cutoff-present-not-proof';
      if(originalPossible&&onExternal(a.path)) risk+=':external-original-unlink-capable';
    } else {
      const files=Array.isArray(job.payload.files)?job.payload.files:[];
      const current=files.some(path=>references.has(path));
      const nas=files.some(onExternal);
      risk=current?'CURRENT_DB_FILE_REFERENCE_STOP':nas?'EXTERNAL_PATH_UNLINK_CAPABLE_STOP':'SCOPE_UNPROVEN_REVIEW';
      if(examples.length<12) examples.push({jobToken:job.token,state:job.state,risk});
    }
    const key=job.name+':'+job.state+':'+risk;
    counts[key]=(counts[key]??0)+1;
  }
  result.deletionJobs={counts, fileDeleteExamples:examples,
    legacyAssetDelete:jobs.filter(j=>j.name==='AssetDelete'&&j.payload.trashedBefore===undefined&&!j.payload.deletionReason).length,
    fileDelete:jobs.filter(j=>j.name==='FileDelete').length,
    maximumAgeDays:Math.max(0,...jobs.map(j=>Number.isFinite(j.ageDays)?j.ageDays:0))};
  result.containerMountPermissionIndications=roots.map((root,index)=>{
    let writable=false;try {fs.accessSync(root,fs.constants.W_OK);writable=true;} catch {}
    return {mount:index+1, auditUid:process.getuid(), directoryAccessW_OK:writable,
      actualCreateUnlink:'NOT_TESTED'};
  });
  // Match StorageService.detectMediaLocation, including the legacy upload mount.
  const mediaCandidates=['/data','/usr/src/app/upload'].filter(path=>fs.existsSync(path));
  const mediaRoot=config.storage.mediaLocation||
    (mediaCandidates.length===1?mediaCandidates[0]:'/usr/src/app/upload');
  const backupRoot=mediaRoot+'/backups';
  try {
    const files=fs.readdirSync(backupRoot).slice(0,1000);
    const backups=files.filter(x=>x.endsWith('.sql.gz')).map(x=>fs.statSync(backupRoot+'/'+x)).filter(x=>x.isFile());
    result.backupFiles={count:backups.length, boundedAt:1000,
      newestAgeHours:backups.length?Math.round((Date.now()-Math.max(...backups.map(x=>x.mtimeMs)))/3600000):null,
      restoreValidated:'UNKNOWN', status:'INVENTORY_ONLY'};
  } catch {result.backupFiles={status:'UNKNOWN_OR_UNREADABLE'};}
  result.runningVersion=JSON.parse(fs.readFileSync('/usr/src/app/server/package.json','utf8')).version;
} catch {result.errors.push('AUDIT_INCOMPLETE_NO_ERROR_DETAILS_PRINTED');}
finally {
  redis?.disconnect();
  if(sql) await sql.end({timeout:1});
}
console.log(JSON.stringify(result));
'''


def command(args, *, input=None, timeout=15):
    result = subprocess.run(args, input=input, text=True, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError('read-only probe failed')
    return result.stdout


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
                            snapshot = Path(target) / '#snapshot'
                            public['externalMounts'][-1]['snapshotDirectoryVisible'] = snapshot.is_dir()
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
    if REPORT.exists() or REPORT.is_symlink():
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
        fd = os.open(REPORT, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except OSError:
        print('FAIL cannot create a new private report; nothing overwritten.', file=sys.stderr)
        return 1
    with os.fdopen(fd, 'w') as output:
        json.dump(collect(docker), output, indent=2)
        output.write('\n')
    print('PASS private report created: /home/doctoriceadm/gallery-trash-release-audit.txt')
    print('NOT READY for deployment until report, backups and queue plan are reviewed.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
