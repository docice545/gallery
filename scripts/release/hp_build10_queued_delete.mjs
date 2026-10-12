// Exact approved jobs only. This is not a worker, queue resume or deletion API.
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import fs from 'node:fs/promises';
import { isAbsolute, normalize, relative, resolve } from 'node:path';

export const IDS = ['886', '887', '888', '929', '930', '953'];
const states = ['active', 'wait', 'paused', 'delayed', 'prioritized', 'waiting-children', 'failed'];
// Retention/account/Memories housekeeping is held unchanged, never executed.
// Unfinished photo-original operations need their own durable authorization.
const destructive = new Set(['AssetDelete', 'AssetEmptyTrash']);
const background = ['VersionCheck', 'UserSyncUsage', 'UserDeleteCheck', 'UserDelete', 'AssetEmptyTrash',
  'HlsSessionCleanup', 'TagCleanup', 'AuditTableCleanup', 'FileDelete', 'SharedSpaceAlbumGrantReconcile',
  'SharedSpaceAlbumGrantReconcileSweep', 'SharedSpaceIdentityReconciliationSweep', 'SharedSpaceBulkAddAssets',
  'AssetDeleteCheck', 'AssetDelete', 'FaceRepairScan', 'SessionCleanup', 'PersonCleanup', 'NotificationsCleanup',
  'MemoryGenerate', 'MemoryCleanup'];
export function need(value, code) { if (!value) throw new Error(code); }
export const digest = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
export const below = (root, file) => file.startsWith(root + '/');
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

// Bind mounts change mount IDs/namespaces, never the backing filesystem scope.
export const backingIdentity = root => ({ path: root.path, device: root.device, inode: root.inode,
  mountType: root.mountType, mountSource: root.mountSource,
  coordinate: resolve(root.mountRoot, relative(root.mountTarget, root.path)) });

// temporaryOwnerId is an EXISTING authenticated upload-cleanup marker, not a
// permanent-deletion policy. Never synthesize it for a bare legacy original.
export function fileScope(job, file, mediaRoot, roots) {
  need(typeof file === 'string' && file.length > 0 && !file.includes('\0') && file === normalize(file) &&
    !file.split('/').some(part => part === '..' || part === '.gallery-deletion-quarantine'),
    'NONCANONICAL_FILEDELETE_PATH');
  const path = isAbsolute(file) ? file : resolve(mediaRoot, file);
  const derivative = roots.find(root => below(root, path));
  if (derivative) return { jobId: job.id, jobHash: job.hash, file, path, root: derivative, kind: 'derivative' };
  need(uuid.test(job.data.temporaryOwnerId ?? ''), 'LEGACY_ORIGINAL_REQUIRES_ASSET_DELETION_INTENT_JOB_' +
    (IDS.includes(job.id) ? job.id : 'UNREVIEWED'));
  const root = mediaRoot + '/upload/' + job.data.temporaryOwnerId;
  need(below(root, path) && !relative(root, path).split('/').includes('.gallery-deletion-quarantine'),
    'TEMPORARY_UPLOAD_OWNER_SCOPE_MISMATCH');
  return { jobId: job.id, jobHash: job.hash, file, path, root, kind: 'temporary-upload',
    ownerId: job.data.temporaryOwnerId };
}

export async function verifyCleanupIntent(spec, dependencies) {
  need(!(await dependencies.referenced(spec)), 'SHARED_OR_LIVE_FILE_PROTECTED');
  if (spec.kind !== 'temporary-upload') return;
  const owner = await dependencies.owner(spec.ownerId);
  need(owner?.id === spec.ownerId && owner.deletedAt === null, 'TEMPORARY_UPLOAD_OWNER_NOT_ACTIVE');
  // An original covered by the asset-deletion lifecycle must go through its
  // real receipt/policy/recovery checks, even if a cleanup job also names it.
  need(!(await dependencies.tombstone(spec)), 'UPLOAD_HAS_ASSET_DELETION_INTENT_USE_AUTHORIZED_HANDLER');
}

export function admit(snapshot, expected = 27) {
  need(snapshot.paused === true && snapshot.atomic && snapshot.inventoryComplete, 'COMPLETE_PAUSED_QUEUE_REQUIRED');
  need(states.every(s => snapshot.counts[s] === (s === 'paused' ? expected : 0)), 'QUEUE_STATE_CHANGED_OR_ACTIVE');
  need(snapshot.jobs.length === expected && new Set(snapshot.jobs.map(j => j.id)).size === expected,
    'EXACT_PENDING_JOB_INVENTORY_REQUIRED');
  need(snapshot.deletionHashes === IDS.length, 'OTHER_DELETION_HASH_REQUIRES_INTENT_REVIEW');
  need(snapshot.jobs.filter(j => j.name === 'FileDelete').map(j => j.id).sort().join() === [...IDS].sort().join(),
    'EXPECTED_SIX_FILEDELETE_JOBS_REQUIRED');
  const allowed = new Set(snapshot.knownBackgroundJobs);
  for (const job of snapshot.jobs) {
    need(allowed.has(job.name), 'UNKNOWN_BACKGROUND_JOB_REQUIRES_REVIEW');
    if (!IDS.includes(job.id)) need(!destructive.has(job.name), 'OTHER_DELETION_JOB_REQUIRES_INTENT_REVIEW');
    else {
      need(job.name === 'FileDelete' && Array.isArray(job.data.files) && job.data.files.length > 0 &&
        job.data.files.filter(Boolean).length > 0 && job.data.files.length <= 256 &&
        !job.parentKey && !job.opts.parent && !job.opts.repeat &&
        job.opts.removeOnComplete === true, 'UNSUPPORTED_FILEDELETE_JOB_CONTRACT');
      if (Object.hasOwn(job.data, 'temporaryOwnerId')) {
        need(typeof job.data.temporaryOwnerId === 'string' && uuid.test(job.data.temporaryOwnerId) &&
          Object.keys(job.data).every(k => k === 'files' || k === 'temporaryOwnerId'),
          'UNVERIFIED_TEMPORARY_UPLOAD_JOB_CONTRACT');
      }
    }
  }
  return snapshot.jobs.filter(j => !IDS.includes(j.id));
}

export function retainedOnly(current, retained) {
  need(current.paused === true && current.atomic && current.inventoryComplete, 'PAUSED_PRESERVATION_REQUIRED');
  need(states.every(s => current.counts[s] === (s === 'paused' ? retained.length : 0)) &&
    current.deletionHashes === 0 && current.jobs.length === retained.length,
    'DELETION_QUEUE_NOT_DRAINED_OR_UNKNOWN_JOBS');
  need(digest(current.jobs) === digest(retained), 'OTHER_JOBS_CHANGED_NO_DEPLOYMENT');
}

// Queue acknowledgement happens only AFTER handler success and physical checks.
export async function finishJob(job, proofs, dependencies) {
  const result = await dependencies.handler(job.data);
  need(result === dependencies.success, 'NATIVE_FILEDELETE_FAILED_JOB_RETAINED');
  for (const proof of proofs) {
    need(await dependencies.absent(proof.path), 'SOURCE_STILL_EXISTS_JOB_RETAINED');
    if (proof.quarantineName) need(await dependencies.absent(proof.root + '/.gallery-deletion-quarantine/' + proof.quarantineName),
      'CAPTURE_STILL_EXISTS_JOB_RETAINED');
  }
  await dependencies.recheck();
  await dependencies.acknowledge(); // BullMQ Job.remove, same removeOnComplete semantics; never drain/clean.
}

async function runtime() {
  const require = createRequire('/usr/src/app/server/package.json');
  const { ConfigRepository } = await import('file:///usr/src/app/server/dist/repositories/config.repository.js');
  const { StorageCore } = await import('file:///usr/src/app/server/dist/cores/storage.core.js');
  const { StorageService } = await import('file:///usr/src/app/server/dist/services/storage.service.js');
  const { StorageRepository } = await import('file:///usr/src/app/server/dist/repositories/storage.repository.js');
  const { AssetRepository } = await import('file:///usr/src/app/server/dist/repositories/asset.repository.js');
  const { DiskStorageBackend } = await import('file:///usr/src/app/server/dist/backends/disk-storage.backend.js');
  const secure = await import('file:///usr/src/app/server/dist/utils/authorized-deletion.js');
  const { getKyselyConfig } = await import('file:///usr/src/app/server/dist/utils/database.js');
  const { JobStatus, StorageFolder } = await import('file:///usr/src/app/server/dist/enum.js');
  const { Kysely, sql } = require('kysely');
  const { Queue } = require('bullmq');
  const config = new ConfigRepository().getEnv();
  need(config.storage.backend === 'disk' && !config.storage.s3.bucket, 'VERIFIED_DISK_STORAGE_REQUIRED');
  let location = config.storage.mediaLocation;
  if (!location) {
    const found = [];
    for (const path of ['/data', '/usr/src/app/upload']) { try { if ((await fs.stat(path)).isDirectory()) found.push(path); } catch (e) { if (e.code !== 'ENOENT') throw e; } }
    need(found.length === 1, 'UNAMBIGUOUS_EXISTING_MEDIA_LOCATION_REQUIRED'); location = found[0];
  }
  need(isAbsolute(location) && location === await fs.realpath(location), 'CANONICAL_MEDIA_LOCATION_REQUIRED');
  StorageCore.setMediaLocation(location);
  const queue = new Queue('backgroundTask', { ...config.bull.config, skipMetasUpdate: true });
  const redis = await queue.client;
  const prefix = queue.toKey('');
  const { log: unused, ...options } = getKyselyConfig(config.database.config);
  const db = new Kysely(options);
  const quiet = { setContext() {}, warn() {} };
  const storage = new StorageRepository(quiet);
  const roots = [StorageFolder.Thumbnails, StorageFolder.EncodedVideo, StorageFolder.Profile].map(f => StorageCore.getBaseFolder(f));

  async function snapshot() {
    const script = `local r={}; for i=1,7 do if i<=3 then r[i]=redis.call('LLEN',KEYS[i]) else r[i]=redis.call('ZCARD',KEYS[i]) end end
      r[8]=redis.call('HGET',KEYS[8],'paused') or ''; r[9]=redis.call('LRANGE',KEYS[3],0,1000); return r`;
    const before = await redis.eval(script, 8, ...states.map(s => prefix + s), prefix + 'meta');
    const ids = before[8]; need(ids.length <= 256, 'BOUNDED_INVENTORY_REQUIRED');
    const jobs = [];
    for (const id of ids) {
      const raw = await redis.hgetall(prefix + id);
      need(raw.name && raw.data && raw.opts, 'JOB_HASH_INCOMPLETE');
      need(Buffer.byteLength(JSON.stringify(raw)) <= 128 * 1024, 'BOUNDED_JOB_DATA_REQUIRED');
      const ordered = Object.fromEntries(Object.entries(raw).sort());
      jobs.push({ id, name: raw.name, data: JSON.parse(raw.data), opts: JSON.parse(raw.opts),
        parentKey: raw.parentKey ?? null, hash: digest(ordered) });
    }
    // Bounded supplementary hash inventory; list/ZSET cardinalities prove state counts.
    let cursor = '0', examined = 0, deletionHashes = 0;
    do {
      const [next, keys] = await redis.scan(cursor, 'MATCH', prefix + '*', 'COUNT', 100); cursor = next;
      for (const key of keys) {
        need(++examined <= 5000, 'HASH_INVENTORY_LIMIT');
        if (await redis.type(key) !== 'hash') continue;
        const name = await redis.hget(key, 'name');
        if ((name === 'FileDelete' || name === 'AssetDelete') &&
          await redis.zscore(prefix + 'completed', key.slice(prefix.length)) === null) deletionHashes++;
      }
    } while (cursor !== '0');
    const after = await redis.eval(script, 8, ...states.map(s => prefix + s), prefix + 'meta');
    need(digest(before) === digest(after), 'QUEUE_CHANGED_DURING_INVENTORY');
    // Classification comes from the pinned frozen source, never arbitrary job data.
    const rootPhysical = [];
    for (const path of roots) {
      try {
        need(await fs.realpath(path) === path, 'CANONICAL_DERIVATIVE_ROOT_REQUIRED');
        const st = await fs.stat(path, { bigint: true });
        need(st.isDirectory(), 'DERIVATIVE_ROOT_DIRECTORY_REQUIRED');
        rootPhysical.push({ path, device: String(st.dev), inode: String(st.ino), uid: String(st.uid), gid: String(st.gid) });
      } catch (e) { if (e.code !== 'ENOENT') throw e; }
    }
    return { paused: before[7] === '1' || before[7] === 'true', atomic: true, inventoryComplete: true,
      counts: Object.fromEntries(states.map((s, i) => [s, Number(before[i])])), jobs, deletionHashes,
      mediaRoot: location, rootPhysical, knownBackgroundJobs: background };
  }
  const absent = async path => { try { await fs.lstat(path); return false; } catch (e) { if (e.code === 'ENOENT') return true; throw e; } };
  return { queue, db, sql, AssetRepository, StorageService, DiskStorageBackend, secure, storage, roots, quiet,
    storageRoot: location, originalRoots: [StorageFolder.Upload, StorageFolder.Library].map(f => StorageCore.getBaseFolder(f)),
    JobStatus, snapshot, absent, close: async () => { await queue.close(); await db.destroy(); } };
}

export async function execute(input) {
  const r = await runtime();
  try {
    if (input.action === 'inventory') return await r.snapshot();
    need(input.snapshot && input.snapshotSeal === digest(input.snapshot), 'SEALED_INVENTORY_REQUIRED');
    const retained = admit(input.snapshot);
    if (input.action === 'admit') return { passed: true, retained: retained.length };
    const current = await r.snapshot();
    const specs = input.snapshot.jobs.filter(j => IDS.includes(j.id)).flatMap(job =>
      job.data.files.filter(Boolean).map(file => fileScope(job, file, r.storageRoot, r.roots)));
    need(new Set(specs.map(s => s.path)).size === specs.length, 'DUPLICATE_CONFIRMED_FILE_PATH');
    if (input.action !== 'intent') {
      need(input.intent && input.intentSeal === digest(input.intent) &&
        input.intent.snapshotSeal === input.snapshotSeal && digest(input.intent.files) === digest(specs),
        'SEALED_CLEANUP_INTENT_REQUIRED');
    }
    if (input.action === 'gate') {
      retainedOnly(current, retained);
      need(digest(current.rootPhysical) === digest(input.snapshot.rootPhysical), 'PRODUCTION_DERIVATIVE_ROOT_CHANGED');
      for (const [i, expected] of input.intent.rootPhysical.entries()) {
        need(await fs.realpath(expected.path) === expected.path, 'CONFIRMED_UPLOAD_ROOT_CHANGED');
        const [actual] = await r.secure.collectRootIdentities([expected.path]);
        const st = await fs.stat(expected.path, { bigint: true });
        need(actual.device === expected.device && actual.inode === expected.inode &&
          String(st.uid) === expected.uid && String(st.gid) === expected.gid,
          'CONFIRMED_UPLOAD_ROOT_CHANGED');
        need(digest(backingIdentity(actual)) === digest(input.intent.rootBacking[i]), 'CONFIRMED_UPLOAD_MOUNT_CHANGED');
      }
      if (input.proof) for (const p of input.proof.proofs) {
        const spec = specs.find(s => s.jobId === p.jobId && s.file === p.file);
        need(spec && p.path === spec.path && p.root === spec.root, 'FILE_PROOF_PATH_CHANGED');
        need(await r.absent(p.path) && (!p.quarantineName || await r.absent(
          p.root + '/.gallery-deletion-quarantine/' + p.quarantineName)), 'FINISHED_FILE_NOT_ABSENT_IN_PRODUCTION');
      }
      return { passed: true, preserved: retained.length };
    }
    if (input.action === 'prepare' || input.action === 'intent') need(digest(current) === digest(input.snapshot), 'QUEUE_CHANGED_SINCE_REVIEW');
    else {
      need(current.paused && states.every(s => current.counts[s] === (s === 'paused' ? current.jobs.length : 0)) &&
        digest(current.jobs.filter(j => !IDS.includes(j.id))) === digest(retained) &&
        current.jobs.every(j => input.snapshot.jobs.some(p => p.id === j.id && p.hash === j.hash)),
        'QUEUE_CHANGED_SINCE_REVIEW');
    }
    need(['intent', 'prepare', 'execute'].includes(input.action), 'SUPPORTED_ACTION_REQUIRED');
    return await r.db.transaction().setAccessMode('read only').execute(async tx => {
      const readOnly = await r.sql.raw('SHOW transaction_read_only').execute(tx);
      need(readOnly.rows[0].transaction_read_only === 'on', 'READ_ONLY_POSTGRES_REQUIRED');
      const locked = await r.sql`SELECT pg_try_advisory_xact_lock(hashtextextended(${input.snapshotSeal}, 791031)) AS locked`.execute(tx);
      need(locked.rows[0].locked === true, 'CONFIRMED_FILE_OPERATION_ALREADY_RUNNING');
      const repo = new r.AssetRepository(tx);
      const aliases = spec => [...new Set([spec.file, spec.path, relative(r.storageRoot, spec.path)])];
      const checks = {
        referenced: async spec => {
          const paths = aliases(spec);
          for (const path of paths) if (await repo.isOriginalReferenced(path)) return true;
          return !!(await tx.selectFrom('user').select('id').where('profileImagePath', 'in', paths).executeTakeFirst());
        },
        owner: id => tx.selectFrom('user').select(['id', 'deletedAt']).where('id', '=', id).executeTakeFirst(),
        tombstone: async spec => {
          const paths = aliases(spec);
          const row = await tx.selectFrom('asset_deletion_tombstone').select('assetId').where(eb => eb.or([
            eb('originalPath', 'in', paths), ...paths.flatMap(path => [
              r.sql`${r.sql.ref('aliases')} @> ${JSON.stringify([path])}::jsonb`,
              r.sql`${r.sql.ref('files')} @> ${JSON.stringify([{ path }])}::jsonb`,
            ]),
          ])).executeTakeFirst();
          return !!row;
        },
      };
      const protection = async spec => {
        const libraries = await tx.selectFrom('library').select('importPaths').execute();
        const external = libraries.flatMap(l => l.importPaths);
        if (spec.kind !== 'temporary-upload') return [...r.originalRoots, ...external];
        // Exempt only THIS owner's temporary upload root. Preserve every other
        // upload directory, managed library and external physical alias.
        const entries = await fs.readdir(r.originalRoots[0], { withFileTypes: true });
        need(entries.length <= 512, 'BOUNDED_UPLOAD_ROOT_INVENTORY_REQUIRED');
        const others = entries.filter(e => e.name !== spec.ownerId && (e.isDirectory() || e.isSymbolicLink()))
          .map(e => r.originalRoots[0] + '/' + e.name);
        return [r.originalRoots[1], ...r.roots, ...others, ...external];
      };
      if (input.action === 'prepare' || input.action === 'intent') {
        // Admit EVERY path before changing any directory or moving/unlinking files.
        const files = [];
        let bytes = 0;
        for (const spec of specs) {
          await verifyCleanupIntent(spec, checks);
          const missing = await r.absent(spec.path);
          if (!missing) {
            const st = await fs.lstat(spec.path);
            need(st.isFile() && st.nlink === 1, 'REGULAR_EXCLUSIVE_DISPOSABLE_FILE_REQUIRED');
            bytes += st.size; need(bytes <= 4 * 1024 ** 3, 'BOUNDED_FILE_BYTES_REQUIRED');
            await r.storage.verifyDisposablePath(spec.path, [spec.root]);
          }
          files.push({ ...spec, absent: missing });
        }
        const identities = [];
        for (const root of new Set(files.map(f => f.root))) {
          const spec = files.find(f => f.root === root);
          identities.push(...await r.secure.validateDeletionRoots([root], await protection(spec)));
        }
        const rootPhysical = [];
        for (const identity of identities) {
          const st = await fs.stat(identity.path, { bigint: true });
          rootPhysical.push({ path: identity.path, device: identity.device, inode: identity.inode,
            uid: String(st.uid), gid: String(st.gid) });
        }
        const rootBacking = identities.map(backingIdentity);
        if (input.action === 'intent') return { contract: 'confirmed-native-cleanup-v1', files: specs,
          rootPhysical, rootBacking, snapshotSeal: input.snapshotSeal };
        need(digest(rootPhysical) === digest(input.intent.rootPhysical), 'ROOT_CHANGED_BEFORE_NATIVE_PREPARATION');
        need(digest(rootBacking) === digest(input.intent.rootBacking), 'MOUNT_CHANGED_BEFORE_NATIVE_PREPARATION');
        const bound = [];
        for (const identity of identities) bound.push(await r.secure.bindQuarantine(identity));
        const proofs = [];
        for (const file of files) {
          const missing = await r.absent(file.path);
          proofs.push({ ...file, ...(missing ? { initiallyAbsent: true } :
            await r.secure.snapshotOriginal(file.path, bound)) });
        }
        return { proofs, roots: bound, snapshotSeal: input.snapshotSeal, intentSeal: input.intentSeal };
      }
      need(input.proof && input.proof.snapshotSeal === input.snapshotSeal && input.proof.intentSeal === input.intentSeal,
        'DURABLE_FILE_PROOFS_REQUIRED');
      const validateProof = p => {
        const spec = specs.find(s => s.jobId === p.jobId && s.file === p.file);
        need(spec && p.path === spec.path && p.root === spec.root && p.jobHash === spec.jobHash && p.kind === spec.kind &&
          p.ownerId === spec.ownerId, 'FILE_PROOF_SCOPE_CHANGED');
        return spec;
      };
      need(input.proof.proofs.length === specs.length, 'EXACT_FILE_PROOF_COVERAGE_REQUIRED');
      for (const p of input.proof.proofs) validateProof(p);
      const records = [];
      for (const previous of input.snapshot.jobs.filter(j => IDS.includes(j.id) && !current.jobs.some(p => p.id === j.id))) {
        const files = input.proof.proofs.filter(f => f.jobId === previous.id);
        need(files.length === previous.data.files.filter(Boolean).length, 'EXACT_FILE_PROOF_COVERAGE_REQUIRED');
        for (const file of files) {
          await verifyCleanupIntent(validateProof(file), checks);
          need(await r.absent(file.path) && (!file.quarantineName ||
            await r.absent(file.root + '/.gallery-deletion-quarantine/' + file.quarantineName)), 'PRIOR_ACK_FILES_NOT_ABSENT');
        }
        records.push({ id: previous.id, name: previous.name, verifiedAbsentAfterPriorAttempt: true });
      }
      for (const selected of current.jobs.filter(j => IDS.includes(j.id))) {
        const proofs = input.proof.proofs.filter(f => f.jobId === selected.id);
        need(proofs.length === selected.data.files.filter(Boolean).length, 'EXACT_FILE_PROOF_COVERAGE_REQUIRED');
        const byPath = new Map(proofs.map(p => [p.file, p]));
        let fileFailure;
        const safeUnlink = async file => {
          try {
            const p = byPath.get(file); need(p, 'UNEXPECTED_HANDLER_PATH');
            const spec = validateProof(p);
            await verifyCleanupIntent(spec, checks);
            if (p.initiallyAbsent) { need(await r.absent(p.path), 'PREVIOUSLY_ABSENT_FILE_REAPPEARED'); return; }
            await r.secure.unlinkOriginal(p, async () => {
              await verifyCleanupIntent(spec, checks);
              await r.secure.validateDeletionRoots([p.root], await protection(spec));
            });
          } catch (e) {
            fileFailure = /^[A-Z][A-Z0-9_]{0,160}$/.test(e.message) ? e.message :
              ['EACCES', 'EPERM', 'EROFS', 'EIO', 'ESTALE', 'EOPNOTSUPP', 'EINVAL', 'ENOSPC'].includes(e.code) ?
                'FILESYSTEM_' + e.code : 'PRIVATE_FILESYSTEM_FAILURE';
            throw e;
          }
        };
        const context = Object.create(r.StorageService.prototype);
        context.logger = r.quiet; context.assetRepository = repo;
        context.storageRepository = Object.create(r.storage);
        context.storageRepository.unlink = safeUnlink;
        const disk = new r.DiskStorageBackend(r.storageRoot);
        disk.delete = safeUnlink; r.StorageService.diskBackend = disk; // isolated exec process only; no bootstrap.
        const job = await r.queue.getJob(selected.id); need(job, 'SELECTED_JOB_DISAPPEARED');
        try {
          await finishJob(selected, proofs, { handler: data => context.handleDeleteFiles(data), success: r.JobStatus.Success,
            absent: r.absent, recheck: async () => {
              const now = await r.snapshot();
              need(now.paused && now.counts.active === 0 && now.jobs.find(j => j.id === selected.id)?.hash === selected.hash &&
                digest(now.jobs.filter(j => !IDS.includes(j.id))) === digest(retained),
                'QUEUE_OR_JOB_CHANGED_BEFORE_ACK');
            }, acknowledge: () => job.remove({ removeChildren: false }) });
        } catch (e) {
          let remaining = 0;
          for (const p of proofs) if (!(await r.absent(p.path)) || (p.quarantineName &&
            !(await r.absent(p.root + '/.gallery-deletion-quarantine/' + p.quarantineName)))) remaining++;
          return { completed: false, records, failedJob: selected.id, filesRemaining: remaining,
            code: fileFailure ?? (/^[A-Z][A-Z0-9_]{0,180}$/.test(e.message) ? e.message : 'PRIVATE_HANDLER_FAILURE'),
            preserved: retained.length, queuePaused: true, sqlWrites: false, libraryOriginalsDeleted: 0 };
        }
        records.push({ id: selected.id, name: selected.name, filesRemoved: proofs.filter(p => !p.initiallyAbsent).length,
          confirmedUploadCleanupFilesRemoved: proofs.filter(p => p.kind === 'temporary-upload' && !p.initiallyAbsent).length,
          alreadyAbsent: proofs.filter(p => p.initiallyAbsent).length, physicallyVerified: true });
      }
      retainedOnly(await r.snapshot(), retained);
      return { completed: true, records, preserved: retained.length, queuePaused: true, sqlWrites: false, libraryOriginalsDeleted: 0 };
    });
  } finally { await r.close(); }
}
