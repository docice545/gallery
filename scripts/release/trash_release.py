#!/usr/bin/env python3
"""Approved HP execution only; defaults to no production mutation.

One existing Compose server service, pinned artifact, disposable backup restore,
private recovery evidence/journal, API-only rollback. Never cleans/retries jobs.
"""
import argparse
import base64
from datetime import datetime, timezone
import fcntl
import gzip
import hashlib
import json
import os
from pathlib import Path
import pwd
import secrets
import shutil
import struct
import subprocess
import sys
import tarfile
import time
import urllib.request
import urllib.parse
import zlib

SOURCE = '6a558b554e26e8c0fc5bc5c99259a92e7ef26a56'
IMAGE = 'sha256:fecdc0aa17477cdfef901dc32097b852f7f2ca94befeca4c2ea43ca16d6c8b3c'
ARCHIVE_SHA = '29679cf72b40eea7513addd26979771a4b4ebba9fb5106926d87ee2c05395194'
TAG = 'gallery-server:trash-6a558b554e26'
SERVER = 'immich_server'
POSTGRES = 'immich_postgres'
SERVICE = 'immich-server'
OTHER = ('immich_postgres', 'immich_redis', 'immich_machine_learning')
DOCKER = ['docker']
STATES = ('active','wait','paused','delayed','prioritized','waiting-children','failed')
NODE_BASE = r'''
import {createRequire} from 'node:module';import fs from 'node:fs';
const require=createRequire('/usr/src/app/server/package.json');
const {ConfigRepository}=await import('file:///usr/src/app/server/dist/repositories/config.repository.js');
const config=new ConfigRepository().getEnv();
'''
NODE_QUEUE = NODE_BASE + r'''
const Redis=require('ioredis');const r=new Redis({...config.redis,lazyConnect:true,
 maxRetriesPerRequest:0,retryStrategy:()=>null,commandTimeout:5000,enableReadyCheck:false});
r.on('error',()=>{});
try {await r.connect();const p=(config.bull.config.prefix??'immich_bull')+':backgroundTask:';
 const counts={};for(const state of ['active','wait','paused','delayed','prioritized','waiting-children','failed'])
 counts[state]=Number(await r[['active','wait','paused'].includes(state)?'llen':'zcard'](p+state));
 const flag=await r.hget(p+'meta','paused');
 console.log(JSON.stringify({paused:flag==='1'||flag==='true',counts}));
} catch {console.log(JSON.stringify({error:'QUEUE_READ_FAILED'}));process.exitCode=1;}
finally {r.disconnect();}
'''
NODE_MIGRATIONS = NODE_BASE + r'''
const postgres=require('postgres'),db=config.database.config;
const options={max:1,prepare:false,connect_timeout:5,onnotice:()=>{},
 connection:{default_transaction_read_only:'on',statement_timeout:3000}};
const sql=db.connectionType==='url'?postgres(db.url,options):postgres({...options,
 host:db.host,port:db.port,username:db.username,password:db.password,database:db.database,ssl:db.ssl});
try {const rows=await sql`SELECT name FROM kysely_migrations ORDER BY name`;
 console.log(JSON.stringify(rows.map(r=>r.name)));}
catch {console.log(JSON.stringify({error:'MIGRATION_READ_FAILED'}));process.exitCode=1;}
finally {await sql.end({timeout:1});}
'''


class Stop(Exception):
    pass


def check(value, message):
    if not value:
        raise Stop(message)


def run(args, *, input=None, timeout=120):
    result = subprocess.run(args, input=input, text=True, capture_output=True, timeout=timeout)
    check(result.returncode == 0, f'{Path(args[0]).name} failed; no private output printed')
    return result.stdout


def docker(*args, **kw):
    return run([*DOCKER, *args], **kw)


def inspect(name):
    return json.loads(docker('inspect', name))[0]


def digest(file):
    with file.open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()


def save(file, data):
    # New receipts never overwrite earlier state; journal has explicit revisions.
    fd = os.open(file, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd,'w') as handle:
        json.dump(data, handle, indent=2);handle.write('\n')


def private_json(file):
    check(not file.is_symlink() and file.is_file() and file.stat().st_mode & 0o077 == 0,
          'private regular 0600 input required')
    return json.loads(file.read_text())


def api(base, keyfile, path, method='GET', data=None, raw=False, content_type='application/json'):
    parsed=urllib.parse.urlsplit(base)
    check(parsed.scheme=='http' and parsed.hostname=='127.0.0.1' and parsed.port and
          parsed.path=='/api' and not parsed.username and not parsed.password and not parsed.query and not parsed.fragment,
          'only local API allowed')
    headers={'Content-Type':content_type}
    if keyfile:
        check(not keyfile.is_symlink() and keyfile.stat().st_mode & 0o077 == 0, 'private admin key file required')
        key=keyfile.read_text().strip()
        check(key and '\n' not in key and '\r' not in key, 'invalid private admin key file')
        headers['x-api-key']=key
    body=data if isinstance(data,bytes) else json.dumps(data).encode() if data is not None else None
    # Loopback never goes through an external proxy with authentication headers.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            raise Stop('API redirect rejected; credentials remain on loopback')
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),NoRedirect())
    with opener.open(urllib.request.Request(base+path,body,headers,method=method),timeout=15) as response:
        value=response.read()
        return value if raw else json.loads(value) if value else None


def queue_empty(require_paused=False):
    result=json.loads(docker('exec','-i',SERVER,'node','--input-type=module',input=NODE_QUEUE))
    check(not result.get('error') and set(result.get('counts',{}))==set(STATES), 'queue state unknown')
    check(all(value==0 for value in result['counts'].values()), 'queue changed/nonempty; no jobs altered')
    check(not require_paused or result['paused'], 'deletion queue is not paused')
    return result


def api_only(item):
    env=dict(value.split('=',1) for value in item['Config'].get('Env',[]) if '=' in value)
    return env.get('IMMICH_WORKERS_INCLUDE')=='api' and env.get('IMMICH_WORKERS_EXCLUDE')=='microservices'


def migrations_match(image):
    live=json.loads(docker('exec','-i',SERVER,'node','--input-type=module',input=NODE_MIGRATIONS))
    program="const fs=require('fs');console.log(JSON.stringify([...new Set(['migrations','migrations-gallery'].flatMap(d=>fs.readdirSync('/usr/src/app/server/dist/schema/'+d).filter(f=>f.endsWith('.js')).map(f=>f.slice(0,-3))))].sort()));"
    built=json.loads(docker('run','--rm','--network','none','--read-only','--entrypoint','node',image,'-e',program))
    check(isinstance(live,list) and live and set(live)==set(built), 'migration sets differ; no migration authorized')
    return sorted(live)


def verify_artifact(directory):
    manifest=json.loads((directory/'manifest.json').read_text())
    check(all(manifest.get(key)==value for key,value in {
        'sourceCommit':SOURCE,'toolingCommit':'d3f999e7d21c7c7f4e9b9bc5ac1e1af62de6cf3d',
        'imageId':IMAGE,'imageTag':TAG,'archiveSHA256':ARCHIVE_SHA,'serverVersion':'5.7.1',
        'mobileVersion':'5.7.2','mobileBuild':8,'schemaDelta':'NONE_FROM_42790b06',
        'isolatedSmoke':'PASS: fresh PG migrations + HTTP Trash/Restore + read-only audit'}.items()),
        'backend manifest differs from successful run 37953392247')
    archive=directory/'gallery-server-linux-amd64.tar.gz'
    check(digest(archive)==ARCHIVE_SHA,'backend archive checksum mismatch')
    # Inspect Docker archive metadata in a stream; no extraction or arbitrary paths.
    with tarfile.open(archive,mode='r|gz') as contents:
        found=False
        for member in contents:
            if member.name=='manifest.json':
                check(member.isfile() and member.size<1024*1024,'invalid Docker archive manifest')
                rows=json.load(contents.extractfile(member))
                check(len(rows)==1 and rows[0]['RepoTags']==[TAG],'unexpected archived image/tag')
                found=True;break
        check(found,'Docker archive manifest missing')
    print('PASS pinned backend manifest/archive/source SHA')
    return archive


def load_artifact(directory):
    archive=verify_artifact(directory)
    existing=subprocess.run([*DOCKER,'image','inspect',TAG],capture_output=True,text=True)
    if existing.returncode==0:
        check(json.loads(existing.stdout)[0]['Id']==IMAGE,'existing target tag has another image; not overwritten')
    else:
        docker('load','-i',str(archive),timeout=900)
    item=json.loads(docker('image','inspect',TAG))[0]
    env=dict(value.split('=',1) for value in item['Config'].get('Env',[]) if '=' in value)
    check(item['Id']==IMAGE and item['Architecture']=='amd64' and
          env.get('IMMICH_SOURCE_COMMIT')==SOURCE and env.get('IMMICH_SOURCE_REF')=='v5.7.1',
          'loaded image identity mismatch')
    print('PASS loaded image integrity/source/version metadata')


def restore_check(backup, state):
    check(backup.is_file() and not backup.is_symlink() and backup.stat().st_size>0, 'selected backup missing')
    backup_hash=digest(backup)
    if (state/'backup-verified.json').exists():
        receipt=private_json(state/'backup-verified.json')
        check(receipt['backupSHA256']==backup_hash,'existing recovery receipt belongs to another backup; use a new state directory')
        print('PASS REUSED backup restore receipt; restore not repeated')
        return
    check(not (state/'restore-private.log').exists(),'previous incomplete restore log retained; inspect it and use a new state directory')
    check(shutil.disk_usage(Path(docker('info','--format','{{.DockerRootDir}}').strip())).free>8*1024**3,
          'isolated restore needs at least 8 GiB free Docker disk; no cleanup performed')
    check(int(Path('/proc/meminfo').read_text().split('MemAvailable:')[1].split()[0])*1024>3*1024**3,
          'isolated restore needs 3 GiB available RAM; schedule a quiet window')
    pg=inspect(POSTGRES)
    env=dict(value.split('=',1) for value in pg['Config'].get('Env',[]) if '=' in value)
    user, database=env.get('POSTGRES_USER','postgres'),env.get('POSTGRES_DB','immich')
    name='gallery-restore-check-'+secrets.token_hex(8)
    before={service:inspect(service)['Id'] for service in (SERVER,*OTHER)}
    created=False
    try:
        docker('run','-d','--pull','never','--network','none','--name',name,
               '--cpus','1','--memory','2g','--pids-limit','512',
               '-e','POSTGRES_PASSWORD=disposable-restore-only','-e','POSTGRES_USER='+user,
               '-e','POSTGRES_DB='+database,pg['Image'],'postgres',
               '-c','shared_preload_libraries=vchord.so',
               '-c','config_file=/var/lib/postgresql/data/postgresql.conf')
        created=True
        # Readiness is bounded and only for the newly created isolated PG.
        docker('exec',name,'sh','-c','for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do '
               'pg_isready -h 127.0.0.1 >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1')
        log=state/'restore-private.log'
        fd=os.open(log,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        with os.fdopen(fd,'wb') as errors, gzip.open(backup,'rb') as data:
            process=subprocess.Popen([*DOCKER,'exec','-i',name,'psql','-X','--quiet','--single-transaction',
                                      '--set','ON_ERROR_STOP=on','-U',user,'-d',database],
                                     stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=errors)
            try:
                prefix=data.read(5)
                check(prefix!=b'PGDMP','backup is custom format, not the project SQL/gzip format')
                process.stdin.write(prefix)
                shutil.copyfileobj(data,process.stdin,1024*1024)
                process.stdin.close()
                check(process.wait(timeout=900)==0,'isolated SQL restore failed; inspect private log locally')
            finally:
                if process.poll() is None: process.kill();process.wait()
        query='SELECT json_build_array((SELECT count(*) FROM asset),(SELECT count(*) FROM kysely_migrations),(SELECT count(*) FROM asset a LEFT JOIN library l ON l.id=a."libraryId" WHERE a."libraryId" IS NOT NULL AND l.id IS NULL));'
        rows=json.loads(docker('exec',name,'psql','-X','-t','-A','-v','ON_ERROR_STOP=on','-U',user,'-d',database,'-c',query))
        check(len(rows)==3 and all(type(row) is int for row in rows) and rows[0]>0 and rows[1]>0 and rows[2]==0,
              'restored backup schema/count/referential checks failed')
        check(all(inspect(service)['Id']==value for service,value in before.items()),'production container changed during restore check')
        check(digest(backup)==backup_hash,'backup changed during restore; result rejected')
        receipt={'backupSHA256':backup_hash,'backupPath':str(backup.resolve()),'postgresImage':pg['Image'],
             'backupModifiedAt':datetime.fromtimestamp(backup.stat().st_mtime,timezone.utc).isoformat(),
             'checkedAt':datetime.now(timezone.utc).isoformat(),'assetCount':int(rows[0]),
             'migrationCount':int(rows[1]),'restore':'PASS_ISOLATED_SQL_TRANSACTION', 'productionChanged':False}
    finally:
        # Remove only our unique fixture and its anonymous volume, never a production volume.
        if created:
            cleaned=subprocess.run([*DOCKER,'rm','-f','-v',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            check(cleaned.returncode==0,'isolated restore fixture cleanup failed; no recovery receipt issued')
    save(state/'backup-verified.json',receipt)
    print('PASS PostgreSQL backup restored in isolated network/storage; production unchanged')


def nas_check(proof_file, audit_file, state):
    proof=private_json(proof_file);report=json.loads(audit_file.read_text())
    server=next(row for row in report['containers'] if row.get('role')==SERVER)
    expected={row['containerMountpoint'] for row in server['externalMounts']}
    host_roots={row['containerMountpoint']:Path(row['hostMountpoint']).resolve() for row in server['externalMounts']}
    check(expected and set(proof.get('mounts',{}))==expected,'NAS recovery proof must cover every server NFS mount')
    receipt={}
    for root, evidence in proof['mounts'].items():
        check(evidence.get('operator_attests_snapshot_export') is True and evidence.get('snapshot_reference'),
              'actual NAS snapshot/backup export must be independently attested by operator')
        check({sample['kind'] for sample in evidence['samples']}=={'photo','video'},'photo and video recovery samples required')
        hashes=[]
        for sample in evidence['samples']:
            original,recovered=Path(sample['original']),Path(sample['recovered'])
            check(original.is_file() and recovered.is_file() and original.resolve()!=recovered.resolve(), 'separate restored media samples required')
            check(original.stat().st_size>0 and original.resolve().is_relative_to(host_roots[root]),'recovery original is outside its NAS mount')
            check(not any(recovered.resolve().is_relative_to(host) for host in host_roots.values()),
                  'recovery samples must be exported to separate HP local storage, never NAS originals')
            value=digest(original)
            check(value==digest(recovered),'NAS recovered bytes differ; no deployment allowed')
            hashes.append(value)
        receipt[root]={'sampleHashes':hashes,'snapshotReferenceSHA256':hashlib.sha256(evidence['snapshot_reference'].encode()).hexdigest()}
    if (state/'nas-verified.json').exists():
        check(private_json(state/'nas-verified.json')['mounts']==receipt,'existing NAS recovery receipt differs; use new state')
        print('PASS REUSED NAS recovery evidence; verification timestamp retained')
        return
    save(state/'nas-verified.json',{'mounts':receipt,'verifiedAt':datetime.now(timezone.utc).isoformat(),
         'validation':'SAMPLE_BYTE_RECOVERY_PLUS_OPERATOR_SNAPSHOT_SCOPE_ATTESTATION'})
    print('PASS recovered NAS photo/video sample hashes; snapshot scope is operator attested')


def compose_base(item):
    labels=item['Config'].get('Labels',{})
    check(labels.get('com.docker.compose.service')==SERVICE,'server is not the expected Compose service')
    files=[Path(x) for x in labels.get('com.docker.compose.project.config_files','').split(',') if x]
    check(files and files[0]==Path('/opt/immich/docker-compose.yml') and all(p.is_file() for p in files),
          'actual production Compose files unavailable/unexpected')
    project=labels['com.docker.compose.project']
    return [*DOCKER,'compose','--project-directory',str(files[0].parent),'-p',project,
            *[value for file in files for value in ('-f',str(file))]],files


def override(state, image, normal=None, name='active-server.override.json'):
    env=normal or {'IMMICH_WORKERS_INCLUDE':'api','IMMICH_WORKERS_EXCLUDE':'microservices'}
    file=state/name
    content={'services':{SERVICE:{'image':image,'environment':env}}}
    if file.exists():
        check(private_json(file)==content,'existing override differs; nothing overwritten')
    else:
        save(file,content)
    return file


def recreate(base, file):
    old=json.loads(run([*base,'config','--format','json']))
    new=json.loads(run([*base,'-f',str(file),'config','--format','json']))
    check(set(old['services'])==set(new['services']),'Compose service set changed')
    for name, service in old['services'].items():
        if name!=SERVICE: check(service==new['services'][name],'unrelated Compose service changed')
    a,b=dict(old['services'][SERVICE]),dict(new['services'][SERVICE])
    a.pop('image',None);b.pop('image',None)
    a=dict(a);b=dict(b);a['environment']=dict(a.get('environment',{}));b['environment']=dict(b.get('environment',{}))
    for value in (a,b):
        for key in ('IMMICH_WORKERS_INCLUDE','IMMICH_WORKERS_EXCLUDE'): value['environment'].pop(key,None)
    check(a==b,'server fields other than image/worker gate changed')
    run([*base,'-f',str(file),'up','-d','--no-deps','--no-build','--pull','never',SERVICE],timeout=180)


def health(base, source=None, timeout=90):
    deadline=time.monotonic()+timeout
    while True:
        item=inspect(SERVER)
        try:
            check(item['State'].get('Health',{}).get('Status')=='healthy','server not healthy')
            check(api(base,None,'/server/ping')=={'res':'pong'},'API ping failed')
            check(api(base,None,'/server/version')=={'major':5,'minor':7,'patch':1,'prerelease':None},'API version mismatch')
            if source:
                env=dict(v.split('=',1) for v in item['Config'].get('Env',[]) if '=' in v)
                check(env.get('IMMICH_SOURCE_COMMIT')==source,'running source differs')
            print('PASS container health/API ping/version/source')
            return
        except Exception:
            check(time.monotonic()<deadline,'server health timeout; use guarded rollback')
            time.sleep(2)


def deploy(args):
    state=args.state
    check(not (state/'deployment.json').exists(),'deployment journal already exists; do not repeat/recreate')
    backup=private_json(state/'backup-verified.json');nas=private_json(state/'nas-verified.json')
    check(backup['restore']=='PASS_ISOLATED_SQL_TRANSACTION' and nas['mounts'],'recovery gates missing')
    check(inspect(POSTGRES)['Image']==backup['postgresImage'],'PostgreSQL image changed since recovery check')
    check(digest(Path(backup['backupPath']))==backup['backupSHA256'],'verified backup absent/changed')
    check((datetime.now(timezone.utc)-datetime.fromisoformat(backup['checkedAt'])).total_seconds()<86400,
          'backup recovery verification older than 24 hours')
    check((datetime.now(timezone.utc)-datetime.fromisoformat(backup['backupModifiedAt'])).total_seconds()<3600,
          'fresh pre-deployment backup required (under 1 hour), not only the 17-hour audit backup')
    check((datetime.now(timezone.utc)-datetime.fromisoformat(nas['verifiedAt'])).total_seconds()<86400,
          'NAS recovery verification older than 24 hours')
    load_artifact(args.artifact)
    report=json.loads(args.audit.read_text());old=inspect(SERVER)
    expected=next(row for row in report['containers'] if row.get('role')==SERVER)
    check(old['Image']==expected['imageId'] and old['Id'][:12]==expected['containerId'],'production server moved since approved audit')
    check(not report['backendReadOnlyAudit']['errors'],'audit incomplete')
    check(all(status=='PASS' for status in report['backendReadOnlyAudit']['sections'].values()) and
          report['backendReadOnlyAudit']['deletionJobs']['inventoryComplete'],'incomplete approved audit')
    check(all(row['classification']=='OFFLINE_EXTERNAL_INDEX_TOMBSTONE_EXPECTED'
              for row in report['backendReadOnlyAudit']['activeWithDeletedAt']['groups']),
          'active/deletedAt state differs from approved offline-only classification')
    check(set(nas['mounts'])=={row['containerMountpoint'] for row in expected['externalMounts']},'NAS evidence scope changed')
    check(not any(row.get('role') not in (SERVER,*OTHER) for row in report['containers']), 'additional workers need explicit review')
    base,files=compose_base(old)
    current=queue_empty()
    migrations=migrations_match(IMAGE)
    other={name:inspect(name)['Id'] for name in OTHER}
    oldenv=dict(v.split('=',1) for v in old['Config'].get('Env',[]) if '=' in v)
    normal={key:oldenv.get(key,default) for key,default in [('IMMICH_WORKERS_INCLUDE','api,microservices'),('IMMICH_WORKERS_EXCLUDE','')]}
    for index,file in enumerate(files):
        target=state/('compose-backup-'+str(index));shutil.copyfile(file,target);target.chmod(0o600)
    envfile=files[0].parent/'.env'
    if envfile.is_file(): shutil.copyfile(envfile,state/'dotenv-private-backup');(state/'dotenv-private-backup').chmod(0o600)
    # Retain old image under its immutable ID; never overwrite the live custom tag.
    previous='gallery-server:rollback-'+old['Image'].split(':')[1][:16]
    check(shutil.disk_usage(state).free>int(json.loads(docker('image','inspect',old['Image']))[0]['Size'])*1.2,
          'insufficient free space for previous image backup; no cleanup performed')
    prior=subprocess.run([*DOCKER,'image','inspect',previous],text=True,capture_output=True)
    if prior.returncode==0:
        check(json.loads(prior.stdout)[0]['Id']==old['Image'],'rollback tag changed externally')
    docker('tag',old['Image'],previous)
    docker('save','-o',str(state/'previous-server-image.tar'),previous,timeout=900)
    (state/'previous-server-image.tar').chmod(0o600)
    journal={'source':SOURCE,'previousImage':old['Image'],'previousTag':previous,
             'previousArchiveSHA256':digest(state/'previous-server-image.tar'),
             'base':base,'configHashes':{str(p):digest(p) for p in [*files,*([envfile] if envfile.is_file() else [])]},'otherContainers':other,
             'normalWorkers':normal,'previousPaused':current['paused'],'migrations':migrations,'phase':'PAUSED_API_ONLY'}
    save(state/'deployment.json',journal)
    api(args.api,args.key,'/jobs/backgroundTask','PUT',{'command':'pause'})
    queue_empty(require_paused=True) # No waiting/retrying/deleting jobs: any change is STOP.
    file=override(state,TAG)
    recreate(base,file)
    check(api_only(inspect(SERVER)),'new server deletion workers not gated')
    health(args.api,SOURCE)
    check(all(inspect(name)['Id']==value for name,value in other.items()),'unrelated container changed')
    queue_empty(require_paused=True)
    check(migrations_match(IMAGE)==migrations,'schema changed after startup')
    save(state/'backend-healthy.json',{'source':SOURCE,'workers':'API_ONLY','queue':'PAUSED_EMPTY'})
    print('PASS backend only updated; workers remain gated; no queues cleared')


def enable(args):
    check(args.retention_approved,'separate approval to resume existing retention/deletion workers required')
    state=args.state;journal=private_json(state/'deployment.json')
    if (state/'workers-enabled.json').exists():
        check(inspect(SERVER)['Image']==IMAGE and not api_only(inspect(SERVER)),'previous enable receipt differs from live state')
        health(args.api,SOURCE)
        print('PASS REUSED workers-enabled receipt; no queue/recreation repeated')
        return
    check((state/'backend-healthy.json').is_file(),'backend health gate missing')
    check(api_only(inspect(SERVER)) and inspect(SERVER)['Image']==IMAGE,'current server is not the gated candidate')
    queue_empty(require_paused=True)
    check(all(digest(Path(p))==value for p,value in journal['configHashes'].items()),'Compose changed externally')
    file=override(state,TAG,journal['normalWorkers'],'normal-workers.override.json')
    recreate(journal['base'],file)
    health(args.api,SOURCE)
    check(all(inspect(name)['Id']==value for name,value in journal['otherContainers'].items()),'unrelated container changed')
    queue_empty(require_paused=True)
    if not journal['previousPaused']:
        api(args.api,args.key,'/jobs/backgroundTask','PUT',{'command':'resume'})
    save(state/'workers-enabled.json',{'source':SOURCE,'previousPauseRespected':True})
    print('PASS candidate workers enabled; prior pause policy respected')


def rollback(args):
    state=args.state;journal=private_json(state/'deployment.json')
    check(inspect(SERVER)['Image'] in (IMAGE,journal['previousImage']),'server image changed externally; rollback stopped')
    check(all(digest(Path(p))==value for p,value in journal['configHashes'].items()),'Compose changed externally; manual review required')
    if not api_only(inspect(SERVER)):
        api(args.api,args.key,'/jobs/backgroundTask','PUT',{'command':'pause'})
        queue_empty(require_paused=True)
    file=override(state,journal['previousTag'],name='rollback-api-only.override.json')
    available=subprocess.run([*DOCKER,'image','inspect',journal['previousTag']],text=True,capture_output=True)
    if available.returncode!=0:
        check(digest(state/'previous-server-image.tar')==journal['previousArchiveSHA256'],'previous image archive checksum differs')
        docker('load','-i',str(state/'previous-server-image.tar'),timeout=900)
    check(json.loads(docker('image','inspect',journal['previousTag']))[0]['Id']==journal['previousImage'],'previous image missing/mismatched')
    recreate(journal['base'],file)
    check(inspect(SERVER)['Image']==journal['previousImage'] and api_only(inspect(SERVER)),'rollback image/worker gate failed')
    health(args.api)
    check(all(inspect(name)['Id']==value for name,value in journal['otherContainers'].items()),'unrelated container changed')
    queue_empty(require_paused=True)
    print('PASS previous server restored API-only; deletion workers stay disabled; no DB/NAS rollback executed')


def acceptance(args):
    check(inspect(SERVER)['Image']==IMAGE,'acceptance requires the verified candidate')
    check(not (args.state/'acceptance.json').exists(),'existing acceptance receipt retained; no extra fixture created')
    # IDs come only from this synthetic upload, never caller-supplied real media.
    media=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j/1cAAAAASUVORK5CYII=')
    # Unique harmless PNG chunk prevents checksum dedupe returning a pre-existing
    # asset ID. A duplicate response is always rejected before any Trash action.
    chunk=b'tEXt'+b'GalleryDisposable\0'+secrets.token_hex(32).encode()
    media=media[:-12]+struct.pack('>I',len(chunk)-4)+chunk+struct.pack('>I',zlib.crc32(chunk))+media[-12:]
    boundary='gallery-test-'+secrets.token_hex(8)
    body=b''.join(f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"\r\n\r\n2024-05-06T10:20:30.000Z\r\n'.encode()
                  for key in ('fileCreatedAt','fileModifiedAt'))
    body+=f'--{boundary}\r\nContent-Disposition: form-data; name="assetData"; filename="disposable-gallery-trash-test.png"\r\nContent-Type: image/png\r\n\r\n'.encode()+media+f'\r\n--{boundary}--\r\n'.encode()
    uploaded=api(args.api,args.key,'/assets','POST',body,content_type='multipart/form-data; boundary='+boundary)
    check(uploaded.get('status')=='created','upload did not create a new disposable asset; no Trash attempted')
    asset=uploaded['id']
    before=api(args.api,args.key,'/assets/'+asset)
    check(api(args.api,args.key,'/assets/'+asset+'/original',raw=True)==media,'fixture upload differs')
    try:
        api(args.api,args.key,'/assets','DELETE',{'ids':[asset],'force':False})
        check(api(args.api,args.key,'/assets/'+asset)['isTrashed'],'synthetic Trash not confirmed')
        check(api(args.api,args.key,'/assets/'+asset+'/original',raw=True)==media,'synthetic original changed')
    finally:
        api(args.api,args.key,'/trash/restore/assets','POST',{'ids':[asset]})
    after=api(args.api,args.key,'/assets/'+asset)
    check(not after['isTrashed'] and all(before[k]==after[k] for k in ('id','fileCreatedAt','localDateTime')),
          'synthetic Restore/date/identity failed')
    check(api(args.api,args.key,'/assets/'+asset+'/original',raw=True)==media,'restored original changed')
    check(api(args.api,args.key,'/trash/restore/assets','POST',{'ids':[asset]})['count']==0,'Restore idempotency failed')
    save(args.state/'acceptance.json',{'source':SOURCE,'syntheticPhotoTrashRestore':'PASS','fixtureLeftActive':True,
         'permanentDelete':'NOT_RUN','physicalS23iPhone':'NOT_VALIDATED'})
    print('PASS synthetic photo Trash/Restore/date/bytes; fixture left active, no permanent deletion')


def main():
    global DOCKER
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=['verify-artifact','restore-check','nas-check','deploy','enable-workers','rollback','acceptance'])
    parser.add_argument('--state',type=Path,required=True)
    parser.add_argument('--artifact',type=Path)
    parser.add_argument('--backup',type=Path)
    parser.add_argument('--audit',type=Path)
    parser.add_argument('--nas-proof',type=Path)
    parser.add_argument('--key',type=Path)
    parser.add_argument('--api',default='http://127.0.0.1:2283/api')
    parser.add_argument('--execute-approved',action='store_true')
    parser.add_argument('--retention-approved',action='store_true')
    args=parser.parse_args()
    try:
        check(pwd.getpwuid(os.getuid()).pw_name=='doctoriceadm','run as doctoriceadm')
        if args.action!='verify-artifact': check(args.execute_approved,'explicit operator approval required; nothing executed')
        check(args.state.is_dir() and not args.state.is_symlink() and args.state.stat().st_mode & 0o077==0,'private existing 0700 state directory required')
        if args.action not in ('verify-artifact','nas-check'):
            for prefix in (['docker'],['sudo','-n','docker']):
                try:
                    result=subprocess.run([*prefix,'info'],capture_output=True,timeout=15)
                    if result.returncode==0:
                        DOCKER=prefix;break
                except (OSError,subprocess.TimeoutExpired):
                    continue
            else:
                raise Stop('existing Docker access required; no sudo/group policy changed')
        fd=os.open(args.state/'.execution.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,'w') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            if args.action=='verify-artifact': verify_artifact(args.artifact)
            elif args.action=='restore-check': restore_check(args.backup,args.state)
            elif args.action=='nas-check': nas_check(args.nas_proof,args.audit,args.state)
            elif args.action=='deploy': deploy(args)
            elif args.action=='enable-workers': enable(args)
            elif args.action=='rollback': rollback(args)
            else: acceptance(args)
        return 0
    except Exception as error:
        print('STOP '+(str(error) if isinstance(error,Stop) else 'operation failed; private details omitted'),file=sys.stderr)
        return 1


if __name__=='__main__':
    raise SystemExit(main())
