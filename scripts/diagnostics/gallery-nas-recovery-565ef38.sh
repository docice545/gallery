#!/usr/bin/env bash
set -euo pipefail
umask 077
python3 - <<'PY'
import collections, contextlib, getpass, hashlib, importlib.util, json, os, pwd, re
import shutil, ssl, stat, subprocess, sys, tempfile, time, urllib.parse, urllib.request, warnings
from datetime import datetime, timedelta, timezone
from pathlib import Path, PurePosixPath

PIN='565ef38c0c39f3ee896f5afd055d4d57a676d503'
TOOL_SHA='56c12526736e51abad3adf321c0b9665ec9b70f8472641af966feba4c45f7a2c'
HOME_POINT='2026-10-09T03:00:02'
IMMICH_POINT='GMT+03-2026.10.09-20.15.17'
PHOTO={'.jpg','.jpeg','.png','.heic','.heif','.webp','.tif','.tiff','.avif'}
VIDEO={'.mp4','.mov','.m4v','.mkv','.webm','.avi','.3gp','.mts','.m2ts'}
LIMIT=256*1024**2; BUDGET=2*1024**3; MAX_ENTRIES=100000; MAX_SECONDS=900
ROOTS={'docice':('/mnt/synology-immich-docice','/volume1/homes/docice/Photos'),
 'chudo_anna':('/mnt/synology-immich-chudo','/volume1/homes/chudo_anna/Photos'),
 'Lenia':('/mnt/synology-immich-lenia','/volume1/homes/Lenia/Photos'),
 'managed':('/mnt/synology-immich-managed','/volume1/Immich'),
 'homes':('/mnt/synology-homes','/volume1/homes')}
SKIP={'#recycle','#snapshot','.snapshot','@eaDir','@Recycle','.git'}
class Stop(Exception): pass

def need(ok,code):
 if not ok: raise Stop(code)

def ask(prompt):
 with warnings.catch_warnings():
  warnings.simplefilter('error',getpass.GetPassWarning)
  try: return getpass.getpass(prompt).strip()
  except getpass.GetPassWarning: raise Stop('PRIVATE_INTERACTIVE_TTY_REQUIRED') from None

def sha(path):
 with path.open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()

def load(path):
 need(path.is_file() and not path.is_symlink() and path.stat().st_size<=2*1024**2,'INPUT_NOT_REGULAR_OR_TOO_LARGE')
 return json.loads(path.read_text())

def save(path,data):
 fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
 with os.fdopen(fd,'w') as f: json.dump(data,f,indent=2); f.write('\n')

def cmd(args):
 p=subprocess.run(args,capture_output=True,text=True,timeout=30)
 need(p.returncode==0,'READ_ONLY_LOCAL_COMMAND_FAILED')
 return p.stdout

def mount(path):
 rows=json.loads(cmd(['findmnt','-J','-T',str(path),'-o','TARGET,SOURCE,FSTYPE,OPTIONS']))['filesystems']
 need(len(rows)==1,'MOUNT_LOOKUP_AMBIGUOUS')
 return rows[0]

def no_links(path,root):
 need(path.is_relative_to(root),'PATH_OUTSIDE_SELECTED_ROOT')
 for p in (path,*path.parents):
  need(not p.is_symlink(),'SYMLINK_NOT_ALLOWED')
  if p==root: return
 raise Stop('ROOT_NOT_REACHED')

def point_time(name):
 m=re.fullmatch(r'GMT([+-])(\d{2})(?::?(\d{2}))?-(\d{4}\.\d{2}\.\d{2})-(\d{2}\.\d{2}\.\d{2})',name)
 if not m: return None
 try:
  offset=timedelta(hours=int(m[2]),minutes=int(m[3] or 0))*(1 if m[1]=='+' else -1)
  return datetime.strptime(m[4]+' '+m[5],'%Y.%m.%d %H.%M.%S').replace(tzinfo=timezone(offset))
 except ValueError: return None

def wanted(share,name):
 t=point_time(name)
 return bool(t and (name==IMMICH_POINT if share=='Immich' else t.replace(tzinfo=None).isoformat()==HOME_POINT))

def discover(base,share):
 found=[]
 for label in ('#snapshot','.snapshot'):
  directory=base/label
  try:
   if directory.is_symlink(): continue
   with os.scandir(directory) as it:
    for n,row in enumerate(it):
     need(n<4096,'SNAPSHOT_DIRECTORY_INVENTORY_LIMIT')
     if wanted(share,row.name) and row.is_dir(follow_symlinks=False): found.append(Path(row.path))
  except OSError: pass
 need(len(found)<=1,'MULTIPLE_MATCHING_SNAPSHOT_ROOTS')
 return found[0] if found else None

class NoRedirect(urllib.request.HTTPRedirectHandler):
 def redirect_request(self,*args,**kwargs): raise Stop('HTTP_REDIRECT_REJECTED')

class DSM:
 def __init__(self):
  self.sid=''; self.token=''; self.api={}
  self.url=ask('DSM HTTPS URL (пусто = STOP; без /webapi): ')
  u=urllib.parse.urlsplit(self.url)
  need(u.scheme=='https' and u.hostname and u.path in ('','/') and not(u.username or u.password or u.query or u.fragment),'DSM_HTTPS_ORIGIN_REQUIRED')
  # Only the existing NAS endpoint; no external proxy or redirect carries credentials.
  import socket
  need({r[4][0] for r in socket.getaddrinfo(u.hostname,u.port or 443)}=={'10.10.10.95'},'DSM_HOST_MUST_RESOLVE_TO_10_10_10_95')
  ca=ask('Путь доверенного DSM CA PEM (Enter = системные CA): ')
  ctx=ssl.create_default_context(cafile=ca or None)
  self.opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),NoRedirect(),urllib.request.HTTPSHandler(context=ctx))
  with self.request('query.cgi',{'api':'SYNO.API.Info','version':1,'method':'query',
   'query':'SYNO.API.Auth,SYNO.Core.Share.Snapshot,SYNO.FileStation.List,SYNO.FileStation.Download'}) as r:
   self.api=self.decode(r)['data']
  account=ask('DSM account с чтением homes, Immich и snapshots: ')
  password=ask('DSM password (только RAM): '); otp=ask('DSM OTP, если включён 2FA (иначе Enter): ')
  need(account and password,'DSM_READ_ACCOUNT_REQUIRED')
  params={'account':account,'passwd':password,'session':'FileStation','format':'sid','enable_syno_token':'yes'}
  if otp: params['otp_code']=otp
  data=self.call('SYNO.API.Auth',6,'login',**params)['data']
  self.sid=data['sid']; self.token=data.get('synotoken','')
  del password,params
 def request(self,path,params):
  need(re.fullmatch(r'[A-Za-z0-9_./-]+\.cgi',path) and '..' not in path.split('/'),'UNSAFE_DSM_API_ENDPOINT')
  data=dict(params)
  if self.sid: data['_sid']=self.sid
  headers={'Content-Type':'application/x-www-form-urlencoded'}
  if self.token: headers['X-SYNO-TOKEN']=self.token
  req=urllib.request.Request(self.url.rstrip('/')+'/webapi/'+path,urllib.parse.urlencode(data).encode(),headers,method='POST')
  return self.opener.open(req,timeout=30)
 def decode(self,r):
  raw=r.read(2*1024**2+1); need(len(raw)<=2*1024**2,'DSM_METADATA_RESPONSE_LIMIT')
  value=json.loads(raw)
  need(value.get('success') is True,'DSM_READ_API_ERROR_'+str(value.get('error',{}).get('code','UNKNOWN')))
  return value
 def call(self,api,version,method,**params):
  need((api,method) in {('SYNO.API.Auth','login'),('SYNO.API.Auth','logout'),
   ('SYNO.Core.Share.Snapshot','list'),('SYNO.FileStation.List','getinfo'),('SYNO.FileStation.List','list')},'DSM_MUTATING_METHOD_FORBIDDEN')
  info=self.api.get(api,{})
  need(info.get('minVersion',999)<=version<=info.get('maxVersion',0),'DSM_READ_API_UNAVAILABLE_'+api)
  with self.request(info['path'],dict(api=api,version=version,method=method,**params)) as r: return self.decode(r)
 def point(self,share):
  out=[]; total=None
  for offset in range(0,4096,100):
   data=self.call('SYNO.Core.Share.Snapshot',2,'list',name=share,filter=json.dumps({'attr':[]}),
    additional=json.dumps(['lock','worm_lock']),offset=offset,limit=100)['data']
   rows=data['snapshots']; total=int(data['total']); out.extend(r for r in rows if wanted(share,r.get('time','')))
   if offset+len(rows)>=total: break
   need(bool(rows),'DSM_SNAPSHOT_PAGINATION_INCOMPLETE')
  else: raise Stop('DSM_SNAPSHOT_INVENTORY_LIMIT')
  need(len(out)==1,'DSM_SNAPSHOT_POINT_NOT_UNIQUE_OR_MISSING_'+share)
  need(share!='Immich' or out[0].get('lock') is True,'IMMICH_SNAPSHOT_LOCK_NOT_CONFIRMED')
  return out[0]
 def info(self,path):
  data=self.call('SYNO.FileStation.List',2,'getinfo',path=json.dumps([path]),additional=json.dumps(['size','real_path']))['data']['files']
  need(len(data)==1 and data[0].get('path')==path,'DSM_RETURNED_DIFFERENT_PATH')
  return data[0]
 def children(self,path):
  for offset in range(0,MAX_ENTRIES+1,100):
   data=self.call('SYNO.FileStation.List',2,'list',folder_path=path,offset=offset,limit=100,additional=json.dumps(['size','real_path']))['data']
   rows=data['files']
   for row in rows:
    p=PurePosixPath(row['path']); need(p.parent==PurePosixPath(path) and '..' not in p.parts,'DSM_DIRECTORY_ESCAPE')
    real=row.get('additional',{}).get('real_path')
    point=next((v for v in PurePosixPath(path).parts if point_time(v)),None)
    need(not real or not point or point in PurePosixPath(real).parts,'DSM_FILE_REAL_PATH_NOT_SELECTED_SNAPSHOT')
    yield row
   if offset+len(rows)>=int(data['total']): return
   need(bool(rows),'DSM_FILE_PAGINATION_INCOMPLETE')
  raise Stop('DSM_FILE_DIRECTORY_LIMIT')
 def download(self,path):
  info=self.api.get('SYNO.FileStation.Download',{})
  need(info.get('minVersion',999)<=2<=info.get('maxVersion',0),'DSM_DOWNLOAD_API_UNAVAILABLE')
  return self.request(info['path'],dict(api='SYNO.FileStation.Download',version=2,method='download',path=path,mode='download'))
 def close(self):
  if self.sid:
   try: self.call('SYNO.API.Auth',6,'logout',session='FileStation')
   except Exception: pass
   self.sid=''; self.token=''

def iter_files(root,dsm,stats,managed=False):
 todo=collections.deque([(root,0)]); start=time.monotonic()
 while todo:
  current,depth=todo.popleft()
  need(time.monotonic()-start<MAX_SECONDS,'SNAPSHOT_SCAN_TIME_BOUND')
  if dsm:
   rows=((PurePosixPath(r['path']),r['isdir'],int(r.get('additional',{}).get('size',-1))) for r in dsm.children(str(current)))
   manager=contextlib.nullcontext(rows)
  else: manager=os.scandir(current)
  with manager as it:
   for row in it:
    stats['entries']+=1; need(stats['entries']<=MAX_ENTRIES,'SNAPSHOT_SCAN_ENTRY_BOUND')
    if dsm: path,isdir,size=row
    else:
     if row.is_symlink(): stats['unreadable']+=1; continue
     path=Path(row.path); isdir=row.is_dir(follow_symlinks=False)
     if not isdir and not row.is_file(follow_symlinks=False): continue
     size=-1 if isdir else row.stat(follow_symlinks=False).st_size
    if managed and depth==0 and (not isdir or path.name not in ('upload','library')): continue
    if path.name in SKIP: continue
    if isdir:
     need(depth<24,'SNAPSHOT_SCAN_DEPTH_BOUND'); todo.append((path,depth+1))
    else: yield path,size
 stats['complete']=True

def kind_for(path):
 ext=path.suffix.lower()
 return 'photo' if ext in PHOTO else 'video' if ext in VIDEO else None

def media_header(path,kind):
 with path.open('rb') as f: h=f.read(4096)
 iso=len(h)>12 and h[4:8]==b'ftyp'
 image=(h.startswith((b'\xff\xd8\xff',b'\x89PNG\r\n\x1a\n',b'II*\x00',b'MM\x00*')) or
  (h[:4]==b'RIFF' and h[8:12]==b'WEBP') or (iso and any(x in h[8:128] for x in (b'heic',b'heix',b'hevc',b'hevx',b'heis',b'heif',b'mif1',b'msf1',b'avif',b'avis'))))
 if kind=='photo': return image
 return not image and (iso or h.startswith(b'\x1aE\xdf\xa3') or
  (h[:4]==b'RIFF' and h[8:12]==b'AVI ') or h[4:8] in (b'mdat',b'moov',b'wide') or
  (len(h)>188 and h[0]==h[188]==0x47) or (len(h)>196 and h[4]==h[196]==0x47))

def fingerprint(s): return (s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)

def recover(source,live,target,dsm,stats):
 before=live.stat(); need(0<before.st_size<=LIMIT,'SAMPLE_SIZE_BOUND')
 need(stats['written']+before.st_size<=BUDGET and shutil.disk_usage(target.parent).free>before.st_size+1024**3,'STAGING_SPACE_OR_TOTAL_BOUND')
 if not dsm: no_links(source,stats['snapshotRoot']); source_before=source.stat()
 fd=os.open(target,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
 try:
  manager=dsm.download(str(source)) if dsm else source.open('rb')
  h=hashlib.sha256(); n=0
  with manager as inp,os.fdopen(fd,'wb') as out:
   if dsm: need(inp.status==200,'DSM_DOWNLOAD_NOT_200')
   while chunk:=inp.read(1024*1024):
    n+=len(chunk); need(n<=before.st_size and n<=LIMIT,'DOWNLOAD_EXCEEDS_EXPECTED_FILE_SIZE')
    stats['written']+=len(chunk); need(stats['written']<=BUDGET,'TOTAL_READ_BUDGET_EXCEEDED')
    out.write(chunk); h.update(chunk)
   out.flush(); os.fsync(out.fileno())
  need(n==before.st_size and n>0,'RECOVERED_SIZE_DIFFERS')
  need(fingerprint(live.stat())==fingerprint(before),'LIVE_CHANGED_DURING_EXPORT')
  value=sha(live)
  need(fingerprint(live.stat())==fingerprint(before),'LIVE_CHANGED_DURING_HASH')
  if not dsm: need(fingerprint(source.stat())==fingerprint(source_before),'SNAPSHOT_CHANGED_DURING_EXPORT')
  need(value==h.hexdigest(),'RECOVERED_BYTES_DIFFER')
  return {'original':str(live),'recovered':str(target),'size':n,'sha256':value,'snapshotSource':str(source)}
 except Exception:
  with contextlib.suppress(OSError): os.close(fd)
  target.unlink(missing_ok=True)  # Only this new local incomplete export.
  raise

def select_samples(root,live_root,state,label,dsm,budget,managed=False):
 stats={'originalsScope':'upload + library' if managed else 'owner Photos tree','entries':0,'complete':False,'unreadable':0,'mismatched':0,'tooLarge':0,'seen':{'photo':0,'video':0}}
 samples=[]; found=set()
 try:
  for source,size in iter_files(root,dsm,stats,managed):
   kind=kind_for(source)
   if not kind: continue
   stats['seen'][kind]+=1
   if kind in found: continue
   if size<=0 or size>LIMIT: stats['tooLarge']+=1; continue
   relative=source.relative_to(root); live=live_root.joinpath(*relative.parts)
   if not live.is_file(): continue
   no_links(live,live_root)
   if live.stat().st_size!=size: stats['mismatched']+=1; continue
   target=state/f'{label}-{kind}.bin'
   try:
    budget['snapshotRoot']=root
    sample=recover(source,live,target,dsm,budget)
    need(media_header(target,kind),'MEDIA_HEADER_DOES_NOT_MATCH_TYPE')
   except Stop as e:
    target.unlink(missing_ok=True)
    if str(e) in ('RECOVERED_BYTES_DIFFER','RECOVERED_SIZE_DIFFERS','MEDIA_HEADER_DOES_NOT_MATCH_TYPE'):
     stats['mismatched']+=1; continue
    raise
   sample['kind']=kind; sample['relativeSnapshotPath']=str(relative)
   samples.append(sample); found.add(kind)
   if found=={'photo','video'}: break
 except Exception as e:
  stats['error']=str(e) if isinstance(e,Stop) else 'SNAPSHOT_READ_FAILED_'+type(e).__name__
 stats['result']={k:'PASS' if k in found else 'ABSENT' if stats['complete'] and stats['seen'][k]==0 and not stats['unreadable'] else 'NO_VERIFIED_SAMPLE' for k in ('photo','video')}
 return samples,stats

def get_tool(state,old_state):
 candidates=[old_state/'trash_release.py']
 data=None
 if candidates[0].is_file(): data=candidates[0].read_bytes()
 if data is None or hashlib.sha256(data).hexdigest()!=TOOL_SHA:
  p=subprocess.run(['git','-C','/opt/gallery-fork','show',PIN+':scripts/release/trash_release.py'],capture_output=True,timeout=15)
  if p.returncode==0: data=p.stdout
  else:
   with urllib.request.urlopen('https://raw.githubusercontent.com/docice545/gallery/'+PIN+'/scripts/release/trash_release.py',timeout=30) as r: data=r.read(131073)
 need(data and len(data)<=131072 and hashlib.sha256(data).hexdigest()==TOOL_SHA,'PINNED_RELEASE_HELPER_CHECKSUM')
 file=state/'trash_release.py'; file.write_bytes(data); file.chmod(0o600)
 spec=importlib.util.spec_from_file_location('pinned_nas_release',file)
 tool=importlib.util.module_from_spec(spec); spec.loader.exec_module(tool)
 return tool

def main():
 need(pwd.getpwuid(os.getuid()).pw_name=='doctoriceadm','RUN_AS_DOCTORICEADM_WITHOUT_SUDO')
 need(sys.version_info>=(3,11),'PYTHON_3_11_REQUIRED'); os.umask(0o077)
 state=Path(tempfile.mkdtemp(prefix='gallery-nas-recovery-',dir='/home/doctoriceadm'))
 report={'scope':'NAS_ONLY_NO_PRODUCTION_MUTATION','toolingCommit':PIN,
  'checks':{'POSTGRES_RESTORE':'NOT_REPEATED','NAS_RECOVERY':'FAIL'},'scopes':{},'blockers':[],'deploymentAuthorized':False}
 proof={'mounts':{},'provenance':{},'scopeResults':{},'postgresRestoreReused':True}; dsm=None; inputs={}
 try:
  old=Path(ask('Папка прежнего PG PASS: recovery-report.txt + backup-verified.json (скрыто): ')).expanduser()
  audit=Path(ask('Путь завершённого PASS audit JSON/TXT (скрыто): ')).expanduser()
  previous=load(old/'recovery-report.txt'); receipt=load(old/'backup-verified.json'); a=load(audit)
  need(str(previous['checks']['POSTGRES_RESTORE']).startswith('PASS') and receipt.get('restore')=='PASS_ISOLATED_SQL_TRANSACTION' and receipt.get('productionChanged') is False,'EXISTING_POSTGRES_PASS_EVIDENCE_REQUIRED')
  inputs={p:sha(p) for p in (old/'recovery-report.txt',old/'backup-verified.json',audit)}
  report['checks']['POSTGRES_RESTORE']='PASS_REUSED_NO_RESTORE'
  save(state/'backup-verified.json',receipt)
  summary=a['backendReadOnlyAudit']
  need(summary.get('errors')==[] and len(summary['sections'])==10 and all(x=='PASS' for x in summary['sections'].values()),'COMPLETED_PASS_AUDIT_REQUIRED')
  server=next(x for x in a['containers'] if x.get('role')=='immich_server')
  mounts=server['externalMounts']; need(mounts and not server.get('mountProbeUnknown'),'AUDIT_NAS_SCOPE_REQUIRED')
  mapping={Path(v[0]):k for k,v in ROOTS.items()}; auditmap={}
  for row in mounts:
   root=Path(row['hostMountpoint']); need(root in mapping,'UNKNOWN_AUDITED_NAS_SCOPE')
   need(row['containerMountpoint'] not in auditmap,'DUPLICATE_AUDITED_NAS_SCOPE')
   auditmap[row['containerMountpoint']]=mapping[root]
  need(mount(state)['fstype'] in ('ext4','xfs','btrfs'),'STAGING_MUST_BE_LOCAL_HP_DISK')
  for label,(path,export) in ROOTS.items():
   m=mount(Path(path)); need(m['target']==path and m['fstype'] in ('nfs','nfs4') and m['source']=='10.10.10.95:'+export,'LIVE_NFS_MAPPING_MISMATCH_'+label)
   if label=='homes': need('ro' in m['options'].split(','),'HOMES_PARENT_NOT_READ_ONLY')
  tool=get_tool(state,old)
  points={'homes':discover(Path(ROOTS['homes'][0]),'homes'), 'Immich':discover(Path(ROOTS['managed'][0]),'Immich')}
  if any(p is None for p in points.values()): dsm=DSM()
  api_roots={}
  for share,root in points.items():
   row=dsm.point(share) if dsm else {'time':root.name}
   name=row['time']; need(root is None or root.name==name,'NFS_AND_DSM_SNAPSHOT_ID_DIFFER')
   if root is None:
    remote='/'+share+'/#snapshot/'+name
    try: info=dsm.info(remote)
    except Stop:
     remote=ask('File Station Location корня '+share+' snapshot (скрыто; ID должен входить в путь): ')
     p=PurePosixPath(remote)
     need(p.is_absolute() and '..' not in p.parts and name in p.parts,'ACTUAL_SNAPSHOT_LOCATION_REQUIRED')
     info=dsm.info(remote)
    need(info.get('isdir') is True,'SNAPSHOT_ROOT_NOT_DIRECTORY')
    api_roots[share]=PurePosixPath(remote)
   if root is None:
    real=info.get('additional',{}).get('real_path')
    need(not real or name in PurePosixPath(real).parts,'DSM_REAL_PATH_NOT_SELECTED_SNAPSHOT')
   proof['provenance'][share]={'snapshotId':name,'snapshotTimestamp':point_time(name).isoformat(),
    'metadataSource':'DSM_SNAPSHOT_LIST' if dsm else 'NFS_DIRECTORY_ID_PLUS_DSM_OPERATOR_ATTESTATION',
    'dsmSnapshotMetadata':row,'nfsSnapshotAccessible':root is not None,
    'fileStationRootMetadata':{k:info[k] for k in ('path','isdir','additional') if k in info} if root is None else None}
   print(share+': snapshot '+name+'; '+('NFS READ-ONLY OPERATIONS' if root else 'DSM FILE STATION READ/DOWNLOAD'))
  need(ask('Подтверждаю по DSM: показанные ID/даты принадлежат snapshots ВСЕЙ homes/Immich; Immich locked. YES: ')=='YES','DSM_SNAPSHOT_ORIGIN_SCOPE_ATTESTATION_REQUIRED')
  budget={'written':0}; scopes={}
  for label in ('docice','chudo_anna','Lenia','managed'):
   share='Immich' if label=='managed' else 'homes'; suffix=PurePosixPath('.') if label=='managed' else PurePosixPath(label)/'Photos'
   nfs=points[share]; api=dsm if nfs is None else None
   root=(nfs.joinpath(*suffix.parts) if nfs else api_roots[share]/suffix)
   live=Path(ROOTS[label][0])
   samples,stats=select_samples(root,live,state,label,api,budget,managed=label=='managed')
   scopes[label]=samples; report['scopes'][label]=stats
   for kind,status in stats['result'].items():
    print(label+' '+kind+': '+status)
    if status!='PASS': report['blockers'].append(label+'_'+kind.upper()+'_'+status)
  proof['scopeResults']=report['scopes']
  for dest,label in auditmap.items():
   labels=('docice','chudo_anna','Lenia') if label=='homes' else (label,)
   share='Immich' if label=='managed' else 'homes'; p=proof['provenance'][share]
   samples=[]
   for owner in labels:
    for original_sample in scopes[owner]:
     s=dict(original_sample)
     if label=='homes': s['original']=str(Path(ROOTS['homes'][0])/owner/'Photos'/Path(s['relativeSnapshotPath']))
     samples.append(s)
   proof['mounts'][dest]={'operator_attests_snapshot_export':True,
    'snapshot_reference':share+' '+p['snapshotId']+' '+p['snapshotTimestamp'], 'samples':samples}
  save(state/'nas-proof.json',proof)
  if not report['blockers']:
   need(all(sha(p)==v for p,v in inputs.items()),'PREVIOUS_EVIDENCE_CHANGED')
   tool.nas_check(state/'nas-proof.json',audit,state)
   report['checks']['NAS_RECOVERY']='PASS'
  else: report['blockers'].append('PINNED_NAS_CHECK_REQUIRES_PHOTO_AND_VIDEO_FOR_EACH_MOUNT_NO_RECEIPT_ISSUED')
 except Exception as e:
  safe=isinstance(e,Stop) or ('tool' in locals() and isinstance(e,tool.Stop))
  code=str(e) if safe else 'NAS_INPUT_OR_READ_ERROR_'+type(e).__name__
  if isinstance(e,urllib.error.HTTPError): code='DSM_READ_HTTP_STATUS_'+str(e.code)
  elif isinstance(e,urllib.error.URLError):
   code='DSM_TRUSTED_CA_AND_MATCHING_HTTPS_HOSTNAME_REQUIRED' if isinstance(e.reason,ssl.SSLCertVerificationError) else 'DSM_OR_PINNED_HELPER_HTTPS_READ_UNAVAILABLE'
  report['blockers'].append(code)
 finally:
  if dsm: dsm.close()
  if not (state/'nas-proof.json').exists(): save(state/'nas-proof.json',proof)
  try:
   need(bool(inputs) and all(sha(p)==v for p,v in inputs.items()),'PREVIOUS_EVIDENCE_CHANGED_OR_NOT_VERIFIED'); report['checks']['PREVIOUS_EVIDENCE']='PASS_UNCHANGED'
  except Exception: report['blockers'].append('PREVIOUS_EVIDENCE_NOT_VERIFIED_UNCHANGED')
  report['result']='PASS' if not report['blockers'] and report['checks']['NAS_RECOVERY']=='PASS' else 'FAIL'
  if report['result']!='PASS' and (state/'nas-verified.json').exists():
   (state/'nas-verified.json').rename(state/'nas-verification-incomplete.json')
   report['checks']['NAS_RECOVERY']='FAIL'
  save(state/'nas-recovery-report.txt',report)
  print('POSTGRES_RESTORE: '+report['checks']['POSTGRES_RESTORE']); print('NAS_RECOVERY: '+report['result'])
  for b in report['blockers']: print('BLOCKER: '+b)
  print('Private report/proof: '+str(state)); print('NO DEPLOYMENT / NO WORKER OR QUEUE CHANGES / NO SIGNING / NO MERGE')
 return 0 if report['result']=='PASS' else 1

if __name__=='__main__':
 try: sys.exit(main())
 except Exception: print('FAIL NAS bootstrap; doctoriceadm/Python/private local home required'); sys.exit(1)
PY
