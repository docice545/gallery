import { Kysely, sql } from 'kysely';
import { spawn } from 'node:child_process';
import { watch } from 'node:fs';
import fs from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { StorageCore } from 'src/cores/storage.core.js';
import { AssetStatus, ChecksumAlgorithm, StorageFolder } from 'src/enum.js';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { LibraryRepository } from 'src/repositories/library.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { DB } from 'src/schema/index.js';
import { AssetService } from 'src/services/asset.service.js';
import { collectRootIdentities, snapshotOriginal, unlinkOriginal } from 'src/utils/authorized-deletion.js';
import { newMediumService } from 'test/medium.factory.js';
import { emulateNfsRootSquash } from 'test/nfs-quarantine.js';
import { createTestRecoveryEvidenceStore } from 'test/recovery-evidence.js';
import { getKyselyDB } from 'test/utils.js';

let db: Kysely<DB>;
let root: string;
let evidence: Awaited<ReturnType<typeof createTestRecoveryEvidenceStore>>;
beforeAll(async () => {
  db = await getKyselyDB();
});
afterAll(async () => {
  await db.destroy();
});
beforeEach(async () => {
  root = await fs.mkdtemp(join(tmpdir(), 'gallery-quarantine-crash-pg-'));
  evidence = await createTestRecoveryEvidenceStore();
});
afterEach(async () => {
  vi.restoreAllMocks();
  await evidence.cleanup();
  await fs.rm(root, { recursive: true, force: true });
});

const qpath = () => join(root, '.gallery-deletion-quarantine');
const fixture = async (external = true) => {
  const { ctx } = newMediumService(AssetService, { database: db, real: [AssetRepository], mock: [LoggingRepository] });
  const { user } = await ctx.newUser();
  const actualFolder = StorageCore.getFolderLocation;
  const actualLibrary = StorageCore.getLibraryFolder;
  vi.spyOn(StorageCore, 'getFolderLocation').mockImplementation((folder, owner) =>
    owner === user.id && folder === StorageFolder.Upload ? root : actualFolder(folder, owner),
  );
  vi.spyOn(StorageCore, 'getLibraryFolder').mockImplementation((owner) =>
    owner.id === user.id ? root : actualLibrary(owner),
  );
  const libraryFixture = external ? await ctx.newLibrary({ ownerId: user.id }) : undefined;
  const library = libraryFixture?.library;
  if (library) await new LibraryRepository(db).update(library.id, { importPaths: [root] });
  const path = join(root, 'synthetic-photo.heic');
  await fs.writeFile(path, 'disposable crash recovery original');
  const { asset } = await ctx.newAsset({
    ownerId: user.id,
    originalPath: path,
    libraryId: library?.id ?? null,
    isExternal: external,
    checksumAlgorithm: external ? ChecksumAlgorithm.sha1Path : ChecksumAlgorithm.sha1File,
    status: AssetStatus.Trashed,
    deletedAt: new Date(),
  });
  const nfs = await emulateNfsRootSquash(root);
  const roots = await collectRootIdentities([root]);
  const scope = library?.id ?? 'managed';
  const proof = await evidence.install(user.id, scope, roots);
  const repo = new AssetRepository(db);
  await repo.setDeletionPolicy(user.id, scope, {
    enabled: true,
    roots: [root],
    rootIdentities: roots,
    recoveryExpiresAt: new Date(proof.expiresAt),
    recoveryProof: proof.digest,
    authorizedBy: user.id,
  });
  await repo.preparePermanentDeletion(asset.id, user.id, snapshotOriginal);
  return { user, asset, scope, repo, nfs };
};
type Fixture = Awaited<ReturnType<typeof fixture>>;
const policyRoot = async (f: Fixture) => {
  const policy = await new AssetRepository(db).getDeletionPolicy(f.user.id, f.scope);
  return policy!.rootIdentities[0];
};
const readReceipt = (f: Fixture) =>
  db.selectFrom('asset_deletion_tombstone').selectAll().where('assetId', '=', f.asset.id).executeTakeFirstOrThrow();

const failMkdirWithoutCreatingQuarantine = async (f: Fixture) => {
  const mkdirActual = vi.mocked(fs.mkdir).getMockImplementation()!;
  let injected = false;
  let reservedId: string | undefined;
  const mkdir = vi.spyOn(fs, 'mkdir').mockImplementation(async (path, options) => {
    if (String(path).endsWith('/.gallery-deletion-quarantine')) {
      injected = true;
      const reserved = await policyRoot(f);
      expect(reserved.quarantineIntent?.state).toBe('reserved');
      reservedId = reserved.quarantineIntent?.id;
      throw Object.assign(new Error('Synthetic no space before directory creation'), { code: 'ENOSPC' });
    }
    return mkdirActual(path, options);
  });
  try {
    await expect(f.repo.removeAuthorizedOriginals(f.asset.id, unlinkOriginal)).rejects.toBeDefined();
  } finally {
    mkdir.mockImplementation(mkdirActual);
  }
  expect(injected).toBe(true);
  const failed = await policyRoot(f);
  expect(failed.quarantineIntent).toMatchObject({ state: 'failed', id: reservedId });
  await expect(fs.lstat(qpath())).rejects.toHaveProperty('code', 'ENOENT');
  expect(await fs.readFile(f.asset.originalPath, 'utf8')).toContain('disposable');
  return reservedId;
};

// A separate Vitest process reaches a durable checkpoint, writes a private
// barrier, then waits. The parent verifies its process group and SIGKILLs ONLY
// the group it created. No application catch/finally executes after the crash.
type CrashStage =
  'before-mkdir' | 'after-mkdir' | 'before-chmod' | 'after-chmod' | 'after-quarantine-sync' | 'after-root-sync';
const injectCrash = async (f: Fixture, stage: CrashStage) => {
  const current = await sql<{ name: string }>`select current_database() as name`.execute(db);
  const databaseUrl = new URL(process.env.IMMICH_TEST_POSTGRES_URL!);
  databaseUrl.pathname = '/' + current.rows[0].name;
  const serverRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../../../../');
  let output = '';
  let rejectMarker: (error: Error) => void;
  let watcher: ReturnType<typeof watch>;
  const marker = new Promise<{ stage: string; pid: number }>((resolve, reject) => {
    rejectMarker = reject;
    const readMarker = async () => {
      try {
        const value = JSON.parse(await fs.readFile(join(root, 'crash-checkpoint.json'), 'utf8'));
        resolve(value);
      } catch {
        return;
      }
    };
    watcher = watch(root, (_event, filename) => {
      if (String(filename) === 'crash-checkpoint.json') void readMarker();
    });
  });
  const child = spawn(
    process.execPath,
    [
      join(serverRoot, 'node_modules/vitest/vitest.mjs'),
      'run',
      '--config',
      'test/medium/quarantine-crash.config.mjs',
      '--reporter=dot',
    ],
    {
      cwd: serverRoot,
      detached: true,
      stdio: ['ignore', 'pipe', 'pipe'],
      env: {
        ...process.env,
        GALLERY_NFS_CRASH_INPUT: JSON.stringify({ databaseUrl: databaseUrl.href, root, assetId: f.asset.id, stage }),
      },
    },
  );
  const exited = new Promise<{ code: number | null; signal: string | null }>((resolve, reject) => {
    child.once('error', reject);
    child.once('exit', (code, signal) => {
      resolve({ code, signal });
      if (signal !== 'SIGKILL')
        rejectMarker(new Error('Synthetic worker exited before checkpoint: ' + output.slice(-6000)));
    });
  });
  const collect = (chunk: Buffer) => {
    output += chunk.toString();
    if (output.length > 1024 * 1024) rejectMarker(new Error('Synthetic worker output exceeded limit'));
  };
  child.stdout.on('data', collect);
  child.stderr.on('data', collect);
  const timeout = setTimeout(
    () => rejectMarker(new Error('Synthetic worker checkpoint timeout: ' + output.slice(-6000))),
    25_000,
  );
  try {
    const checkpoint = await marker;
    expect(checkpoint.stage).toBe(stage);
    expect(Number.isSafeInteger(checkpoint.pid) && checkpoint.pid > 0).toBe(true);
    const stat = await fs.readFile('/proc/' + checkpoint.pid + '/stat', 'utf8');
    const processGroup = stat.slice(stat.lastIndexOf(') ') + 2).split(' ', 3)[2];
    expect(Number(processGroup)).toBe(child.pid);
    process.kill(-child.pid!, 'SIGKILL');
    expect(await exited).toEqual({ code: null, signal: 'SIGKILL' });
  } finally {
    clearTimeout(timeout);
    watcher!.close();
    if (child.exitCode === null && child.signalCode === null && child.pid) {
      process.kill(-child.pid, 'SIGKILL');
      await exited;
    }
  }
  expect(await fs.readFile(f.asset.originalPath, 'utf8')).toBe('disposable crash recovery original');
};

describe('NFS quarantine durable-intent crash recovery with real PostgreSQL', { timeout: 30_000 }, () => {
  it('a handled mkdir failure with verified absence permits only a newly committed reservation', async () => {
    const f = await fixture();
    const failedId = await failMkdirWithoutCreatingQuarantine(f);
    const mkdirActual = vi.mocked(fs.mkdir).getMockImplementation()!;
    let retriedId: string | undefined;
    vi.spyOn(fs, 'mkdir').mockImplementation(async (path, options) => {
      if (String(path).endsWith('/.gallery-deletion-quarantine')) {
        const reserved = await policyRoot(f);
        expect(reserved.quarantineIntent?.state).toBe('reserved');
        retriedId = reserved.quarantineIntent?.id;
        expect(retriedId).not.toBe(failedId);
      }
      return mkdirActual(path, options);
    });
    expect(await new AssetRepository(db).removeAuthorizedOriginals(f.asset.id, unlinkOriginal)).toBe(true);
    expect(retriedId).toEqual(expect.any(String));
    const bound = await policyRoot(f);
    expect(bound.quarantineIntent).toBeUndefined();
    expect(bound.quarantineIdentity).toMatchObject({ uid: '1024', gid: '100' });
    await expect(fs.readFile(f.asset.originalPath)).rejects.toHaveProperty('code', 'ENOENT');
    expect(await f.repo.removeForDeletion(f.asset)).toBe(true);
  });

  it('a failed existing quarantine requires revocation and forensic retirement before fresh reservation', async () => {
    const f = await fixture();
    const openActual = vi.mocked(fs.open).getMockImplementation()!;
    const chmod = vi.fn(() =>
      Promise.reject(Object.assign(new Error('Synthetic NFS permission failure'), { code: 'EACCES' })),
    );
    const open = vi.spyOn(fs, 'open').mockImplementation(async (path, flags, mode) => {
      const handle = await openActual(path, flags, mode);
      if (String(path).endsWith('/.gallery-deletion-quarantine')) {
        vi.spyOn(handle, 'chmod').mockImplementation(chmod);
      }
      return handle;
    });
    await expect(f.repo.removeAuthorizedOriginals(f.asset.id, unlinkOriginal)).rejects.toBeDefined();
    const failed = await policyRoot(f);
    expect(failed.quarantineIntent?.state).toBe('failed');
    const failedId = failed.quarantineIntent?.id;
    const before = await fs.stat(qpath(), { bigint: true });
    await expect(new AssetRepository(db).removeAuthorizedOriginals(f.asset.id, unlinkOriginal)).rejects.toBeDefined();
    expect(chmod).toHaveBeenCalledTimes(1);
    expect(await fs.readFile(f.asset.originalPath, 'utf8')).toContain('disposable');
    expect(await fs.readdir(qpath())).toEqual([]);
    await f.repo.setDeletionPolicy(f.user.id, f.scope, {
      ...(await f.repo.getDeletionPolicy(f.user.id, f.scope))!,
      enabled: false,
    });
    // Explicit operator recovery on this empty disposable fixture only. Keep
    // the rejected inode for forensics; neither mutate it nor adopt it again.
    const retained = qpath() + '.retained-forensics';
    await fs.rename(qpath(), retained);
    open.mockImplementation(openActual);
    await f.repo.setDeletionPolicy(f.user.id, f.scope, {
      ...(await f.repo.getDeletionPolicy(f.user.id, f.scope))!,
      enabled: true,
    });
    const mkdirActual = vi.mocked(fs.mkdir).getMockImplementation()!;
    vi.spyOn(fs, 'mkdir').mockImplementation(async (path, options) => {
      if (String(path).endsWith('/.gallery-deletion-quarantine')) {
        const reserved = await policyRoot(f);
        expect(reserved.quarantineIntent?.state).toBe('reserved');
        expect(reserved.quarantineIntent?.id).not.toBe(failedId);
      }
      return mkdirActual(path, options);
    });
    expect(await new AssetRepository(db).removeAuthorizedOriginals(f.asset.id, unlinkOriginal)).toBe(true);
    const after = await fs.stat(retained, { bigint: true });
    expect(after.dev).toBe(before.dev);
    expect(after.ino).toBe(before.ino);
    expect(after.mode).toBe(before.mode);
    expect(await fs.readdir(retained)).toEqual([]);
    await expect(fs.readFile(f.asset.originalPath)).rejects.toHaveProperty('code', 'ENOENT');
    expect(await f.repo.removeForDeletion(f.asset)).toBe(true);
  });

  it('a foreign directory created after verified absence cannot be adopted by a fresh reservation', async () => {
    const f = await fixture();
    const failedId = await failMkdirWithoutCreatingQuarantine(f);
    const mkdirActual = vi.mocked(fs.mkdir).getMockImplementation()!;
    let foreign: { ino: bigint; mode: bigint } | undefined;
    vi.spyOn(fs, 'mkdir').mockImplementation(async (path, options) => {
      if (String(path).endsWith('/.gallery-deletion-quarantine')) {
        const reserved = await policyRoot(f);
        expect(reserved.quarantineIntent?.state).toBe('reserved');
        expect(reserved.quarantineIntent?.id).not.toBe(failedId);
        await mkdirActual(path, { mode: 0o700 });
        await fs.chmod(path, 0o700);
        foreign = await fs.stat(path, { bigint: true });
      }
      // The genuine mkdir now receives EEXIST from the adversary's entry.
      return mkdirActual(path, options);
    });
    await expect(new AssetRepository(db).removeAuthorizedOriginals(f.asset.id, unlinkOriginal)).rejects.toBeDefined();
    expect(foreign).toBeDefined();
    const after = await fs.stat(qpath(), { bigint: true });
    expect(after.ino).toBe(foreign!.ino);
    expect(after.mode).toBe(foreign!.mode);
    const failed = await policyRoot(f);
    expect(failed.quarantineIdentity).toBeUndefined();
    expect(failed.quarantineIntent?.state).toBe('failed');
    expect(await fs.readFile(f.asset.originalPath, 'utf8')).toContain('disposable');
  });

  it('a failed durable-intent commit performs no filesystem action', async () => {
    const f = await fixture();
    await sql`create function fail_quarantine_intent_commit() returns trigger language plpgsql as $$
      begin
        if exists(select 1 from jsonb_array_elements(NEW."rootIdentities") root where root ? 'quarantineIntent') then
          raise exception 'Synthetic intent commit failure';
        end if;
        return NEW;
      end $$`.execute(db);
    await sql`create constraint trigger fail_quarantine_intent_commit after update on asset_deletion_policy
      deferrable initially deferred for each row execute function fail_quarantine_intent_commit()`.execute(db);
    try {
      await expect(f.repo.removeAuthorizedOriginals(f.asset.id, unlinkOriginal)).rejects.toBeDefined();
      const root = await policyRoot(f);
      expect(root.quarantineIntent).toBeUndefined();
      await expect(fs.lstat(qpath())).rejects.toHaveProperty('code', 'ENOENT');
      expect(await fs.readFile(f.asset.originalPath, 'utf8')).toContain('disposable');
    } finally {
      await sql`drop trigger fail_quarantine_intent_commit on asset_deletion_policy`.execute(db);
      await sql`drop function fail_quarantine_intent_commit()`.execute(db);
    }
  });

  it('a crash after intent commit but before mkdir resumes with no adopted entry', async () => {
    const f = await fixture();
    await injectCrash(f, 'before-mkdir');
    const reserved = await policyRoot(f);
    expect(reserved.quarantineIntent?.state).toBe('reserved');
    await expect(fs.lstat(qpath())).rejects.toHaveProperty('code', 'ENOENT');
    expect(await new AssetRepository(db).removeAuthorizedOriginals(f.asset.id, unlinkOriginal)).toBe(true);
    const bound = await policyRoot(f);
    expect(bound.quarantineIdentity).toMatchObject({ uid: '1024', gid: '100' });
  });

  it('a crash after mkdir before identity commit remains ambiguous and cannot adopt EEXIST', async () => {
    const f = await fixture();
    await injectCrash(f, 'after-mkdir');
    const reserved = await policyRoot(f);
    expect(reserved.quarantineIntent?.state).toBe('reserved');
    const before = await fs.stat(qpath(), { bigint: true });
    await expect(new AssetRepository(db).removeAuthorizedOriginals(f.asset.id, unlinkOriginal)).rejects.toBeDefined();
    const after = await fs.stat(qpath(), { bigint: true });
    expect(after.ino).toBe(before.ino);
    expect(after.mode).toBe(before.mode);
    expect(await fs.readFile(f.asset.originalPath, 'utf8')).toContain('disposable');
  });

  it.each<CrashStage>(['before-chmod', 'after-chmod', 'after-quarantine-sync', 'after-root-sync'])(
    'a real worker crash %s resumes only the committed observed identity after restart',
    async (stage) => {
      const f = await fixture();
      await injectCrash(f, stage);
      const observedRoot = await policyRoot(f);
      const observed = observedRoot.quarantineIntent;
      expect(observed?.state).toBe('observed');
      expect(observed?.identity).toMatchObject({ uid: '1024', gid: '100' });
      expect(observed?.mode).toBe(String(0o4_0777));
      const before = await fs.stat(qpath(), { bigint: true });
      const inode = before.ino;
      expect(await new AssetRepository(db).removeAuthorizedOriginals(f.asset.id, unlinkOriginal)).toBe(true);
      const bound = await policyRoot(f);
      expect(bound.quarantineIntent).toBeUndefined();
      expect(bound.quarantineIdentity?.inode).toBe(String(inode));
      const receipt = await readReceipt(f);
      expect(receipt.files[0].rootIdentity.quarantineIdentity).toEqual(bound.quarantineIdentity);
      expect(await f.repo.removeForDeletion(f.asset)).toBe(true);
      expect(await f.repo.getDeletionReceipt(f.user.id, f.asset.id)).toMatchObject({ state: 'complete' });
    },
  );

  it('concurrent restarted workers recover one observation and capture once', async () => {
    const f = await fixture();
    await injectCrash(f, 'after-chmod');
    const rename = vi.spyOn(fs, 'rename');
    expect(
      await Promise.all(
        [1, 2].map(() => new AssetRepository(db).removeAuthorizedOriginals(f.asset.id, unlinkOriginal)),
      ),
    ).toEqual([true, true]);
    expect(rename).toHaveBeenCalledTimes(1);
    expect(await f.repo.removeForDeletion(f.asset)).toBe(true);
    expect(await new AssetRepository(db).removeForDeletion(f.asset)).toBe(false);
  });

  it.each(['inode', 'uid', 'gid', 'mountId', 'mountNamespace'] as const)(
    'restart rejects a changed observed quarantine %s and preserves the original',
    async (field) => {
      const f = await fixture();
      await injectCrash(f, 'after-chmod');
      if (field === 'inode') {
        await fs.rename(qpath(), qpath() + '.retained');
        await fs.mkdir(qpath(), { mode: 0o700 });
        await fs.chmod(qpath(), 0o700);
      } else if (field === 'uid' || field === 'gid') {
        f.nfs.setOwner(field === 'uid' ? 2048 : 1024, field === 'gid' ? 200 : 100);
      } else {
        const policy = await f.repo.getDeletionPolicy(f.user.id, f.scope);
        policy!.rootIdentities[0].quarantineIntent!.identity![field] =
          field === 'mountId' ? '999999999' : 'mnt:[999999999]';
        await db
          .updateTable('asset_deletion_policy')
          .set({ rootIdentities: policy!.rootIdentities })
          .where('ownerId', '=', f.user.id)
          .where('scope', '=', f.scope)
          .execute();
      }
      await expect(new AssetRepository(db).removeAuthorizedOriginals(f.asset.id, unlinkOriginal)).rejects.toBeDefined();
      expect(await fs.readFile(f.asset.originalPath, 'utf8')).toContain('disposable');
      const receipt = await readReceipt(f);
      expect(receipt.state).not.toBe('files-removed');
    },
  );

  it('owner revocation after a crash denies resumed initialization and unlink', async () => {
    const f = await fixture();
    await injectCrash(f, 'after-chmod');
    // Normal owner-consent repository mutation; no direct activation of policy.
    await f.repo.setDeletionPolicy(f.user.id, f.scope, {
      ...(await f.repo.getDeletionPolicy(f.user.id, f.scope))!,
      enabled: false,
    });
    await expect(new AssetRepository(db).removeAuthorizedOriginals(f.asset.id, unlinkOriginal)).rejects.toMatchObject({
      code: 'LIBRARY_DELETION_NOT_AUTHORIZED',
    });
    expect(await fs.readFile(f.asset.originalPath, 'utf8')).toContain('disposable');
  });
});
