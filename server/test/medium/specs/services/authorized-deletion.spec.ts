import { Kysely, sql } from 'kysely';
import { createHash, randomUUID } from 'node:crypto';
import fs, { mkdir, mkdtemp, readFile, rename, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { AssetStatus, AssetType, AssetVisibility, ChecksumAlgorithm, JobName, JobStatus } from 'src/enum.js';
import { AccessRepository } from 'src/repositories/access.repository.js';
import { AssetJobRepository } from 'src/repositories/asset-job.repository.js';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { LibraryRepository } from 'src/repositories/library.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { StorageRepository } from 'src/repositories/storage.repository.js';
import { TrashRepository } from 'src/repositories/trash.repository.js';
import { UserRepository } from 'src/repositories/user.repository.js';
import { DB } from 'src/schema/index.js';
import { up as bindRecovery } from 'src/schema/migrations-gallery/1793700000000-BindDeletionRecovery.js';
import { AssetService } from 'src/services/asset.service.js';
import { collectRootIdentities, snapshotOriginal, unlinkOriginal } from 'src/utils/authorized-deletion.js';
import { authStub } from 'test/fixtures/auth.stub.js';
import { newMediumService } from 'test/medium.factory.js';
import { createTestRecoveryEvidenceStore } from 'test/recovery-evidence.js';
import { getKyselyDB, newTestService } from 'test/utils.js';

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
  root = await mkdtemp(join(tmpdir(), 'gallery-delete-pg-'));
  evidence = await createTestRecoveryEvidenceStore();
});
afterEach(async () => {
  vi.restoreAllMocks();
  await evidence.cleanup();
  await rm(root, { recursive: true, force: true });
});
const fixture = async (external = false) => {
  const { ctx } = newMediumService(AssetService, { database: db, real: [AssetRepository], mock: [LoggingRepository] });
  const { user } = await ctx.newUser();
  const libraryFixture = external ? await ctx.newLibrary({ ownerId: user.id }) : undefined;
  const library = libraryFixture?.library;
  if (library) await new LibraryRepository(db).update(library.id, { importPaths: [root] });
  const path = join(root, 'photo.heic');
  await writeFile(path, 'synthetic disposable original');
  const { asset } = await ctx.newAsset({
    ownerId: user.id,
    originalPath: path,
    libraryId: library?.id ?? null,
    isExternal: external,
    checksumAlgorithm: external ? ChecksumAlgorithm.sha1Path : ChecksumAlgorithm.sha1File,
    status: AssetStatus.Trashed,
    deletedAt: new Date(),
  });
  return { ctx, user, asset, repo: new AssetRepository(db), scope: library?.id ?? 'managed' };
};
const prepared = async (f: Awaited<ReturnType<typeof fixture>>, enabled = true, actor = f.user.id) => {
  const identities = await collectRootIdentities([root]);
  const proof = await evidence.install(f.user.id, f.scope, identities);
  return {
    enabled,
    roots: [root],
    rootIdentities: identities,
    recoveryExpiresAt: new Date(proof.expiresAt),
    recoveryProof: proof.digest,
    authorizedBy: actor,
  };
};
const authorize = async (f: Awaited<ReturnType<typeof fixture>>) =>
  f.repo.setDeletionPolicy(f.user.id, f.scope, await prepared(f));

const service = (f: Awaited<ReturnType<typeof fixture>>) => {
  const storage = new StorageRepository(f.ctx.getMock(LoggingRepository));
  const test = newTestService(AssetService, {
    asset: f.repo,
    access: new AccessRepository(db),
    assetJob: new AssetJobRepository(db),
    storage,
  });
  test.mocks.sharedSpace.getSpacePersonsForAsset.mockResolvedValue([]);
  test.mocks.event.emit.mockResolvedValue();
  test.mocks.user.updateUsage.mockResolvedValue();
  test.mocks.job.queue.mockResolvedValue();
  test.mocks.user.get.mockImplementation((id, options) => new UserRepository(db).get(id, options));
  const libraries = new LibraryRepository(db);
  test.mocks.library.get.mockImplementation((id) => libraries.get(id));
  test.mocks.library.getAll.mockImplementation(() => libraries.getAll());
  return { storage, ...test };
};
const authFor = (f: Awaited<ReturnType<typeof fixture>>) => ({
  ...authStub.user1,
  user: { ...authStub.user1.user, id: f.user.id },
});

const externalConsent = async (f: Awaited<ReturnType<typeof fixture>>) => {
  await f.repo.setDeletionPolicy(f.user.id, f.scope, await prepared(f, false, randomUUID()));
  const s = service(f);
  await s.sut.setLibraryDeletionConsent(authFor(f), f.scope, true);
  expect(await f.repo.getDeletionPolicy(f.user.id, f.scope)).toMatchObject({ authorizedBy: f.user.id });
  return s;
};

describe('durable per-library authorization with real PostgreSQL and disposable media', () => {
  it('rejects a fabricated digest before committing deletion intent', async () => {
    const f = await fixture();
    await f.repo.setDeletionPolicy(f.user.id, f.scope, { ...(await prepared(f)), recoveryProof: 'a'.repeat(64) });
    await expect(f.repo.preparePermanentDeletion(f.asset.id, f.user.id, snapshotOriginal)).rejects.toMatchObject({
      code: 'DELETION_RECOVERY_UNAVAILABLE',
    });
    expect(await f.repo.getDeletionReceipt(f.user.id, f.asset.id)).toBeUndefined();
    expect(await new TrashRepository(db).restoreAll([f.asset.id])).toEqual([f.asset.id]);
    expect(await readFile(f.asset.originalPath, 'utf8')).toContain('synthetic');
  });

  it('rejects correctly signed evidence belonging to another owner', async () => {
    const f = await fixture();
    const values = await prepared(f);
    const wrong = await evidence.install(randomUUID(), f.scope, values.rootIdentities);
    await f.repo.setDeletionPolicy(f.user.id, f.scope, { ...values, recoveryProof: wrong.digest });
    await expect(f.repo.preparePermanentDeletion(f.asset.id, f.user.id, snapshotOriginal)).rejects.toMatchObject({
      code: 'DELETION_RECOVERY_SCOPE_MISMATCH',
    });
    expect(await f.repo.getDeletionReceipt(f.user.id, f.asset.id)).toBeUndefined();
    expect(await readFile(f.asset.originalPath, 'utf8')).toContain('synthetic');
  });

  it('rejects the ancestor-symlink attack against a persisted grant before creating a receipt', async () => {
    const base = root;
    const granted = join(base, 'accepted');
    const outside = join(base, 'outside');
    await mkdir(granted);
    await mkdir(outside);
    root = join(granted, 'library');
    await mkdir(root);
    const f = await fixture();
    await authorize(f);
    await mkdir(join(outside, 'library'));
    await writeFile(join(outside, 'library', 'photo.heic'), 'outside must survive');
    await rename(granted, granted + '.saved');
    await symlink(outside, granted);
    try {
      await expect(f.repo.preparePermanentDeletion(f.asset.id, f.user.id, snapshotOriginal)).rejects.toMatchObject({
        code: 'DELETION_ROOT_CHANGED',
      });
      expect(await f.repo.getDeletionReceipt(f.user.id, f.asset.id)).toBeUndefined();
      expect(await readFile(join(outside, 'library', 'photo.heic'), 'utf8')).toBe('outside must survive');
      expect(await readFile(join(granted + '.saved', 'library', 'photo.heic'), 'utf8')).toContain('synthetic');
    } finally {
      root = base;
    }
  });

  it('freshness expiration after capture leaves durable recovery state and permits only a verified retry', async () => {
    const f = await fixture();
    await authorize(f);
    await f.repo.preparePermanentDeletion(f.asset.id, f.user.id, snapshotOriginal);
    const realNow = Date.now;
    const clock = vi.spyOn(Date, 'now').mockImplementation(realNow);
    let calls = 0;
    try {
      await expect(
        f.repo.removeAuthorizedOriginals(f.asset.id, (file, recheck) =>
          unlinkOriginal(file, async () => {
            if (++calls === 2) clock.mockReturnValue(realNow() + 48 * 3_600_000);
            await recheck();
          }),
        ),
      ).rejects.toMatchObject({ code: 'DELETION_RECOVERY_EXPIRED' });
    } finally {
      clock.mockRestore();
    }
    const receipt = await db
      .selectFrom('asset_deletion_tombstone')
      .selectAll()
      .where('assetId', '=', f.asset.id)
      .executeTakeFirstOrThrow();
    expect(receipt).toMatchObject({ state: 'failed', errorCode: 'DELETION_RECOVERY_EXPIRED' });
    expect(
      await readFile(join(root, '.gallery-deletion-quarantine', receipt.files[0].quarantineName), 'utf8'),
    ).toContain('synthetic');
    await f.repo.removeAuthorizedOriginals(f.asset.id, unlinkOriginal);
    expect(await f.repo.removeForDeletion(f.asset)).toBe(true);
  });

  it('is disabled by default and preserves the original and restorable Trash', async () => {
    const f = await fixture();
    await expect(f.repo.preparePermanentDeletion(f.asset.id, f.user.id, snapshotOriginal)).rejects.toMatchObject({
      code: 'LIBRARY_DELETION_NOT_AUTHORIZED',
    });
    expect(await readFile(f.asset.originalPath, 'utf8')).toContain('synthetic');
    expect(await new TrashRepository(db).restoreAll([f.asset.id])).toEqual([f.asset.id]);
  });

  it('never imports retained private quarantine media through an external rescan', async () => {
    const f = await fixture(true);
    const directory = join(root, '.gallery-deletion-quarantine');
    await mkdir(directory, { mode: 0o700 });
    const retained = join(directory, randomUUID() + '.heic');
    await writeFile(retained, 'private disposable retained recovery media');
    expect(await f.repo.filterNewExternalAssetPaths(f.scope, [retained])).toEqual([]);
    expect(await readFile(retained, 'utf8')).toBe('private disposable retained recovery media');
    expect(await f.repo.getDeletionReceipt(f.user.id, f.asset.id)).toBeUndefined();
  });

  it.each([false, true])(
    'deletes only an explicitly authorized original (external=%s) and blocks restart/reimport',
    async (external) => {
      const f = await fixture(external);
      await authorize(f);
      await f.repo.preparePermanentDeletion(f.asset.id, f.user.id, snapshotOriginal);
      expect(await new TrashRepository(db).restoreAll([f.asset.id])).toEqual([]);
      expect(await f.repo.removeAuthorizedOriginals(f.asset.id, unlinkOriginal)).toBe(true);
      expect(await f.repo.removeForDeletion(f.asset)).toBe(true);
      await expect(readFile(f.asset.originalPath)).rejects.toHaveProperty('code', 'ENOENT');
      const completedReceipt = await new AssetRepository(db).getDeletionReceipt(f.user.id, f.asset.id);
      expect(completedReceipt?.state).toBe('complete');
      await expect(
        f.ctx.newAsset({
          ownerId: f.user.id,
          libraryId: f.asset.libraryId,
          originalPath: f.asset.originalPath,
          checksum: f.asset.checksum,
          checksumAlgorithm: f.asset.checksumAlgorithm,
        }),
      ).rejects.toHaveProperty('constraint_name', 'asset_deletion_tombstone_identity');
      const proof = await db
        .selectFrom('asset_deletion_tombstone')
        .selectAll()
        .where('assetId', '=', f.asset.id)
        .executeTakeFirstOrThrow();
      await expect(
        f.ctx.newAsset({
          ownerId: f.user.id,
          checksum: proof.contentChecksum,
          checksumAlgorithm: ChecksumAlgorithm.sha1File,
        }),
      ).rejects.toHaveProperty('constraint_name', 'asset_deletion_tombstone_identity');
      if (external) {
        expect(await f.repo.filterNewExternalAssetPaths(f.scope, [f.asset.originalPath])).toEqual([]);
      }
    },
  );

  it('does not authorize another owner or an Active asset', async () => {
    const f = await fixture();
    await authorize(f);
    const { user: other } = await f.ctx.newUser();
    await expect(f.repo.preparePermanentDeletion(f.asset.id, other.id, snapshotOriginal)).rejects.toMatchObject({
      code: 'ASSET_NOT_IN_TRASH',
    });
    await new TrashRepository(db).restoreAll([f.asset.id]);
    await expect(f.repo.preparePermanentDeletion(f.asset.id, f.user.id, snapshotOriginal)).rejects.toMatchObject({
      code: 'ASSET_NOT_IN_TRASH',
    });
    expect(await readFile(f.asset.originalPath, 'utf8')).toContain('synthetic');
  });

  it('rejects shared original paths even between two assets of the same owner', async () => {
    const f = await fixture();
    await authorize(f);
    await f.ctx.newAsset({ ownerId: f.user.id, originalPath: f.asset.originalPath });
    await expect(f.repo.preparePermanentDeletion(f.asset.id, f.user.id, snapshotOriginal)).rejects.toMatchObject({
      code: 'ORIGINAL_SHARED_WITH_OTHER_ASSET',
    });
  });

  it('failure leaves a durable retry record, preserves the DB row and never reports completion', async () => {
    const f = await fixture();
    await authorize(f);
    await f.repo.preparePermanentDeletion(f.asset.id, f.user.id, snapshotOriginal);
    await expect(
      f.repo.removeAuthorizedOriginals(f.asset.id, () =>
        Promise.reject(Object.assign(new Error('private path MUST NOT leak'), { code: 'EROFS' })),
      ),
    ).rejects.toBeDefined();
    expect(await f.repo.removeForDeletion(f.asset)).toBe(false);
    const failedReceipt = await f.repo.getDeletionReceipt(f.user.id, f.asset.id);
    expect(failedReceipt?.state).toBe('failed');
    expect(failedReceipt?.errorCode).toBe('ORIGINAL_DELETE_FAILED');
    expect(await readFile(f.asset.originalPath, 'utf8')).toContain('synthetic');
    await f.repo.removeAuthorizedOriginals(f.asset.id, unlinkOriginal);
    expect(await f.repo.removeForDeletion(f.asset)).toBe(true);
  });

  it('revocation before job execution blocks unlink', async () => {
    const f = await fixture();
    await authorize(f);
    await f.repo.preparePermanentDeletion(f.asset.id, f.user.id, snapshotOriginal);
    await f.repo.setDeletionPolicy(f.user.id, f.scope, {
      enabled: false,
      roots: [root],
      recoveryProof: 'a'.repeat(64),
      authorizedBy: f.user.id,
    });
    await expect(f.repo.removeAuthorizedOriginals(f.asset.id, unlinkOriginal)).rejects.toMatchObject({
      code: 'LIBRARY_DELETION_NOT_AUTHORIZED',
    });
    expect(await readFile(f.asset.originalPath, 'utf8')).toContain('synthetic');
  });

  it('competing original workers unlink and own row effects only once', async () => {
    const f = await fixture();
    await authorize(f);
    await f.repo.preparePermanentDeletion(f.asset.id, f.user.id, snapshotOriginal);
    let calls = 0;
    await Promise.all(
      [1, 2].map(() =>
        f.repo.removeAuthorizedOriginals(f.asset.id, async (proof) => {
          calls++;
          await unlinkOriginal(proof);
        }),
      ),
    );
    expect(calls).toBe(1);
    const removedRows = await Promise.all([f.repo.removeForDeletion(f.asset), f.repo.removeForDeletion(f.asset)]);
    expect(removedRows.sort()).toEqual([false, true]);
  });

  it.each([false, true])(
    'existing worker completes HTTP-service lifecycle and emits effects once (external=%s)',
    async (external) => {
      const f = await fixture(external);
      await authorize(f);
      const { sut, mocks } = service(f);
      const auth = authFor(f);
      await f.repo.preparePermanentDeletion(f.asset.id, f.user.id, snapshotOriginal);
      expect(await sut.handleAssetDeletion({ id: f.asset.id, deleteOnDisk: true, deletionId: f.asset.id })).toBe(
        JobStatus.Success,
      );
      expect(await sut.permanentlyDelete(auth, [f.asset.id])).toEqual([
        { id: f.asset.id, state: 'complete', scope: f.scope },
      ]);
      expect(await sut.permanentlyDelete(auth, [f.asset.id])).toEqual([
        { id: f.asset.id, state: 'complete', scope: f.scope },
      ]);
      expect(mocks.event.emit).toHaveBeenCalledTimes(1);
      expect(mocks.event.emit).toHaveBeenCalledWith(
        'AssetDelete',
        expect.objectContaining({ assetId: f.asset.id, userId: f.user.id }),
      );
      expect(mocks.job.queue).not.toHaveBeenCalledWith(expect.objectContaining({ name: JobName.FileDelete }));
      await expect(readFile(f.asset.originalPath)).rejects.toHaveProperty('code', 'ENOENT');
    },
  );

  it('bulk results preserve an unauthorized library, Active media and another owner', async () => {
    const f = await fixture();
    await authorize(f);
    const { library } = await f.ctx.newLibrary({ ownerId: f.user.id });
    const { asset: blocked } = await f.ctx.newAsset({
      ownerId: f.user.id,
      libraryId: library.id,
      status: AssetStatus.Trashed,
      deletedAt: new Date(),
    });
    const { asset: active } = await f.ctx.newAsset({ ownerId: f.user.id });
    const { user: other } = await f.ctx.newUser();
    const { asset: foreign } = await f.ctx.newAsset({ ownerId: other.id });
    const { sut } = service(f);
    const result = await sut.permanentlyDelete(authFor(f), [f.asset.id, blocked.id, active.id, foreign.id]);
    expect(result.map((item) => item.state)).toEqual(['blocked', 'blocked', 'blocked', 'blocked']);
    expect(
      await db
        .selectFrom('asset')
        .select('id')
        .where('id', 'in', [f.asset.id, blocked.id, active.id, foreign.id])
        .execute(),
    ).toHaveLength(4);
  });

  it.each([false, true])(
    'deletes the exclusive Live/Motion video first and retains the still for retry (external=%s)',
    async (external) => {
      const f = await fixture(external);
      await authorize(f);
      const motionPath = join(root, 'motion.mov');
      await writeFile(motionPath, 'synthetic paired video');
      const { asset: motion } = await f.ctx.newAsset({
        ownerId: f.user.id,
        type: AssetType.Video,
        visibility: AssetVisibility.Hidden,
        originalPath: motionPath,
        libraryId: f.asset.libraryId,
        isExternal: external,
      });
      await db.updateTable('asset').set({ livePhotoVideoId: motion.id }).where('id', '=', f.asset.id).execute();
      const { sut, storage } = service(f);
      const unlink = new StorageRepository(f.ctx.getMock(LoggingRepository)).unlinkOriginal;
      let fail = true;
      vi.spyOn(storage, 'unlinkOriginal').mockImplementation(async (proof) => {
        if (fail && proof.path === motionPath) throw new Error('fixture failure');
        await unlink(proof);
      });
      const failed = await sut.permanentlyDelete(authFor(f), [f.asset.id]);
      expect(failed[0].state).toBe('failed');
      expect(await readFile(f.asset.originalPath, 'utf8')).toContain('synthetic');
      expect(await db.selectFrom('asset').select('id').where('id', '=', f.asset.id).executeTakeFirst()).toBeDefined();
      fail = false;
      const completed = await sut.permanentlyDelete(authFor(f), [f.asset.id]);
      expect(completed[0].state).toBe('complete');
      await expect(readFile(motionPath)).rejects.toHaveProperty('code', 'ENOENT');
      expect(await db.selectFrom('asset').select('id').where('id', '=', motion.id).executeTakeFirst()).toBeUndefined();
    },
  );

  it('suppresses renamed/recreated-library byte-identical imports without changing path checksums', async () => {
    const f = await fixture(true);
    await authorize(f);
    const data = await readFile(f.asset.originalPath);
    const content = createHash('sha1').update(data).digest();
    await f.repo.preparePermanentDeletion(f.asset.id, f.user.id, snapshotOriginal);
    await f.repo.removeAuthorizedOriginals(f.asset.id, unlinkOriginal);
    await f.repo.removeForDeletion(f.asset);
    const { library } = await f.ctx.newLibrary({ ownerId: f.user.id });
    const proposed = {
      ...f.asset,
      id: randomUUID(),
      libraryId: library.id,
      originalPath: join(root, 'renamed.heic'),
      checksum: Buffer.from('different-path'),
      status: AssetStatus.Active,
      deletedAt: null,
      deletionChecksum: content,
    };
    expect(await f.repo.createAll([proposed])).toEqual([]);
    expect(
      await f.repo.createAll([
        { ...proposed, id: randomUUID(), deletionChecksum: Buffer.from('different-byte-proof') },
      ]),
    ).toHaveLength(1);
  });

  it('preserves duplicate byte identities after the FK-bound alias rows disappear', async () => {
    const f = await fixture();
    await authorize(f);
    const alias = createHash('sha1').update('alternate comparable upload bytes').digest();
    await db
      .insertInto('asset_duplicate_checksum')
      .values({ assetId: f.asset.id, ownerId: f.user.id, checksum: alias })
      .execute();
    await f.repo.preparePermanentDeletion(f.asset.id, f.user.id, snapshotOriginal);
    await f.repo.removeAuthorizedOriginals(f.asset.id, unlinkOriginal);
    await f.repo.removeForDeletion(f.asset);
    expect(await f.repo.getUploadAssetIdByChecksum(f.user.id, alias)).toBe(f.asset.id);
    const duplicates = await f.repo.getByChecksums(f.user.id, [alias]);
    expect(duplicates.some((item) => item.checksum.equals(alias) && item.deletedAt)).toBe(true);
    await expect(f.ctx.newAsset({ ownerId: f.user.id, checksum: alias })).rejects.toHaveProperty(
      'constraint_name',
      'asset_deletion_tombstone_identity',
    );
  });

  it('intent-less legacy workers cannot touch a trashed original or emit any row effects', async () => {
    const f = await fixture();
    const { sut, mocks } = service(f);
    expect(await sut.handleAssetDeletion({ id: f.asset.id, deleteOnDisk: true })).toBe(JobStatus.Skipped);
    expect(await readFile(f.asset.originalPath, 'utf8')).toContain('synthetic');
    expect(mocks.event.emit).not.toHaveBeenCalled();
    expect(await db.selectFrom('asset').select('status').where('id', '=', f.asset.id).executeTakeFirst()).toEqual({
      status: AssetStatus.Trashed,
    });
  });
});

describe('external selective deletion, Empty Trash and NFS-like failure recovery', () => {
  it.each([false, true])(
    'secures NFS-like 0777 quarantine for managed/external=%s photo/video deletion with completed receipts',
    async (external) => {
      const f = await fixture(external);
      const videoPath = join(root, 'disposable-video.mp4');
      const controlPath = join(root, 'control');
      await writeFile(videoPath, 'synthetic disposable video');
      await writeFile(controlPath, 'unselected original must survive');
      const { asset: video } = await f.ctx.newAsset({
        ownerId: f.user.id,
        libraryId: external ? f.scope : null,
        isExternal: external,
        type: AssetType.Video,
        originalPath: videoPath,
        status: AssetStatus.Trashed,
        deletedAt: new Date(),
      });
      if (!external) await authorize(f);
      const { sut } = external ? await externalConsent(f) : service(f);
      const mkdirActual = fs.mkdir;
      const chmodActual = fs.chmod;
      vi.spyOn(fs, 'mkdir').mockImplementation(async (path, options) => {
        const result = await mkdirActual(path, options);
        if (String(path).endsWith('/.gallery-deletion-quarantine')) await chmodActual(path, 0o777);
        return result;
      });
      const openActual = fs.open;
      const chmod = vi.fn();
      vi.spyOn(fs, 'open').mockImplementation(async (path, flags, mode) => {
        const handle = await openActual(path, flags, mode);
        if (String(path).endsWith('/.gallery-deletion-quarantine')) {
          const actual = handle.chmod.bind(handle);
          vi.spyOn(handle, 'chmod').mockImplementation(async (mode) => {
            chmod(mode);
            await actual(mode);
          });
        }
        return handle;
      });
      expect(await sut.permanentlyDelete(authFor(f), [f.asset.id, video.id])).toEqual([
        { id: f.asset.id, scope: f.scope, state: 'complete' },
        { id: video.id, scope: f.scope, state: 'complete' },
      ]);
      expect(chmod).toHaveBeenCalledExactlyOnceWith(0o700);
      for (const asset of [f.asset, video]) {
        await expect(readFile(asset.originalPath)).rejects.toHaveProperty('code', 'ENOENT');
        expect(await f.repo.getDeletionReceipt(f.user.id, asset.id)).toMatchObject({ state: 'complete' });
        expect(await f.repo.getById(asset.id)).toBeUndefined();
      }
      expect(await readFile(controlPath, 'utf8')).toBe('unselected original must survive');
      const stat = await fs.stat(join(root, '.gallery-deletion-quarantine'));
      expect(stat.mode & 0o7777).toBe(0o700);
    },
  );

  it.each([false, true])(
    'failed chmod for managed/external=%s preserves bytes and failed receipts across restart/retry',
    async (external) => {
      const f = await fixture(external);
      if (!external) await authorize(f);
      const { sut } = external ? await externalConsent(f) : service(f);
      const mkdirActual = fs.mkdir;
      const chmodActual = fs.chmod;
      vi.spyOn(fs, 'mkdir').mockImplementation(async (path, options) => {
        const result = await mkdirActual(path, options);
        if (String(path).endsWith('/.gallery-deletion-quarantine')) await chmodActual(path, 0o777);
        return result;
      });
      const openActual = fs.open;
      const chmod = vi.fn().mockRejectedValue(Object.assign(new Error('injected chmod failure'), { code: 'EACCES' }));
      vi.spyOn(fs, 'open').mockImplementation(async (path, flags, mode) => {
        const handle = await openActual(path, flags, mode);
        if (String(path).endsWith('/.gallery-deletion-quarantine')) vi.spyOn(handle, 'chmod').mockImplementation(chmod);
        return handle;
      });
      expect(await sut.permanentlyDelete(authFor(f), [f.asset.id])).toEqual([
        { id: f.asset.id, scope: f.scope, state: 'failed', code: 'ORIGINAL_DELETE_FAILED' },
      ]);
      const receipt = await f.repo.getDeletionReceipt(f.user.id, f.asset.id);
      expect(receipt).toMatchObject({ state: 'failed' });
      await expect(new AssetRepository(db).removeAuthorizedOriginals(f.asset.id, unlinkOriginal)).rejects.toMatchObject(
        {
          code: 'DELETION_QUARANTINE_CONFLICT',
        },
      );
      expect(chmod).toHaveBeenCalledTimes(1); // EEXIST retry must not repair an insecure directory.
      expect(await f.repo.getDeletionReceipt(f.user.id, f.asset.id)).toMatchObject({
        operationId: receipt!.operationId,
        state: 'failed',
        errorCode: 'DELETION_QUARANTINE_CONFLICT',
      });
      expect(await f.repo.getById(f.asset.id)).toBeDefined();
      expect(await readFile(f.asset.originalPath, 'utf8')).toContain('synthetic');
      expect(await fs.readdir(join(root, '.gallery-deletion-quarantine'))).toEqual([]);
    },
  );

  it('selective external deletion removes the real disposable original only after scoped owner consent', async () => {
    const f = await fixture(true);
    const { sut } = await externalConsent(f);
    expect(await sut.permanentlyDelete(authFor(f), [f.asset.id])).toEqual([
      { id: f.asset.id, scope: f.scope, state: 'complete' },
    ]);
    await expect(readFile(f.asset.originalPath)).rejects.toHaveProperty('code', 'ENOENT');
    expect(await f.repo.getDeletionReceipt(f.user.id, f.asset.id)).toMatchObject({ state: 'complete' });
    expect(await db.selectFrom('asset').select('id').where('id', '=', f.asset.id).executeTakeFirst()).toBeUndefined();
    expect(await f.repo.getDeletionPolicy(f.user.id, 'managed')).toBeUndefined();
  });

  it('Empty Trash removes eligible external photo/video originals but excludes active offline tombstones', async () => {
    const f = await fixture(true);
    const videoPath = join(root, 'disposable-video.mp4');
    const offlinePath = join(root, 'offline-photo.heic');
    await writeFile(videoPath, 'disposable synthetic video');
    await writeFile(offlinePath, 'offline original must survive');
    const { asset: video } = await f.ctx.newAsset({
      ownerId: f.user.id,
      libraryId: f.scope,
      isExternal: true,
      type: AssetType.Video,
      originalPath: videoPath,
      status: AssetStatus.Trashed,
      deletedAt: new Date(),
    });
    const { asset: offline } = await f.ctx.newAsset({
      ownerId: f.user.id,
      libraryId: f.scope,
      isExternal: true,
      originalPath: offlinePath,
      status: AssetStatus.Active,
      isOffline: true,
      deletedAt: new Date('2026-10-02T12:00:00Z'),
    });
    const { sut } = await externalConsent(f);
    expect(await sut.emptyAuthorizedTrash(authFor(f))).toEqual({ count: 2 });
    for (const id of [f.asset.id, video.id])
      expect(await f.repo.getDeletionReceipt(f.user.id, id)).toMatchObject({ state: 'complete' });
    await expect(readFile(videoPath)).rejects.toHaveProperty('code', 'ENOENT');
    expect(await readFile(offlinePath, 'utf8')).toBe('offline original must survive');
    expect(await f.repo.getDeletionReceipt(f.user.id, offline.id)).toBeUndefined();
    expect(
      await db.selectFrom('asset').select(['status', 'isOffline']).where('id', '=', offline.id).executeTakeFirst(),
    ).toEqual({ status: AssetStatus.Active, isOffline: true });
    expect(await sut.libraryDeletionScopes(authFor(f))).toEqual([
      expect.objectContaining({ scope: f.scope, count: 0, authorized: true }),
    ]);
    await sut.setLibraryDeletionConsent(authFor(f), f.scope, false);
    expect(await f.repo.getDeletionPolicy(f.user.id, f.scope)).toMatchObject({ enabled: false });
  });

  it('another administrator flag alone cannot authorize an external original', async () => {
    const f = await fixture(true);
    await f.repo.setDeletionPolicy(f.user.id, f.scope, await prepared(f, true, randomUUID()));
    await expect(f.repo.preparePermanentDeletion(f.asset.id, f.user.id, snapshotOriginal)).rejects.toMatchObject({
      code: 'LIBRARY_DELETION_NOT_AUTHORIZED',
    });
    expect(await readFile(f.asset.originalPath, 'utf8')).toContain('synthetic');
    expect(await new TrashRepository(db).restoreAll([f.asset.id])).toEqual([f.asset.id]);
  });

  it('external consent revocation blocks a persisted operation and a renewed consent can safely resume it', async () => {
    const f = await fixture(true);
    const { sut } = await externalConsent(f);
    await f.repo.preparePermanentDeletion(f.asset.id, f.user.id, snapshotOriginal);
    await sut.setLibraryDeletionConsent(authFor(f), f.scope, false);
    await expect(f.repo.removeAuthorizedOriginals(f.asset.id, unlinkOriginal)).rejects.toMatchObject({
      code: 'LIBRARY_DELETION_NOT_AUTHORIZED',
    });
    expect(await readFile(f.asset.originalPath, 'utf8')).toContain('synthetic');
    await sut.setLibraryDeletionConsent(authFor(f), f.scope, true);
    expect(await sut.permanentlyDelete(authFor(f), [f.asset.id])).toEqual([
      { id: f.asset.id, scope: f.scope, state: 'complete' },
    ]);
  });

  it.each(['paths', 'owner', 'deleted'])(
    'changed external library %s blocks an already committed intent',
    async (change) => {
      const f = await fixture(true);
      await externalConsent(f);
      await f.repo.preparePermanentDeletion(f.asset.id, f.user.id, snapshotOriginal);
      const libraries = new LibraryRepository(db);
      switch (change) {
        case 'paths': {
          await libraries.update(f.scope, { importPaths: [] });
          break;
        }
        case 'owner': {
          const { user } = await f.ctx.newUser();
          await libraries.update(f.scope, { ownerId: user.id });

          break;
        }
        case 'deleted': {
          await libraries.softDelete(f.scope);
          // No default
          break;
        }
      }
      await expect(f.repo.removeAuthorizedOriginals(f.asset.id, unlinkOriginal)).rejects.toMatchObject({
        code: change === 'paths' ? 'DELETION_ROOT_CHANGED' : 'LIBRARY_DELETION_NOT_AUTHORIZED',
      });
      expect(await readFile(f.asset.originalPath, 'utf8')).toContain('synthetic');
      expect(await f.repo.getDeletionReceipt(f.user.id, f.asset.id)).toMatchObject({ state: 'failed' });
    },
  );

  it('library edits cannot race the destructive transaction after its scope check', async () => {
    const f = await fixture(true);
    await externalConsent(f);
    await f.repo.preparePermanentDeletion(f.asset.id, f.user.id, snapshotOriginal);
    const { promise: ready, resolve: entered } = Promise.withResolvers<void>();
    const { promise: gate, resolve: release } = Promise.withResolvers<void>();
    const deletion = f.repo.removeAuthorizedOriginals(f.asset.id, async (file, recheck) => {
      entered();
      await gate;
      await unlinkOriginal(file, recheck);
    });
    await ready;
    try {
      await expect(
        db.transaction().execute(async (tx) => {
          await sql`set local lock_timeout = '150ms'`.execute(tx);
          await tx.updateTable('library').set({ importPaths: [] }).where('id', '=', f.scope).execute();
        }),
      ).rejects.toHaveProperty('code', '55P03');
    } finally {
      release();
      await deletion;
    }
    expect(await f.repo.removeForDeletion(f.asset)).toBe(true);
  });

  it('external authorization never deletes an original referenced by another owner', async () => {
    const f = await fixture(true);
    await externalConsent(f);
    const { user } = await f.ctx.newUser();
    const { library } = await f.ctx.newLibrary({ ownerId: user.id });
    const { asset: shared } = await f.ctx.newAsset({
      ownerId: user.id,
      libraryId: library.id,
      isExternal: true,
      originalPath: f.asset.originalPath,
    });
    await expect(f.repo.preparePermanentDeletion(f.asset.id, f.user.id, snapshotOriginal)).rejects.toMatchObject({
      code: 'ORIGINAL_SHARED_WITH_OTHER_ASSET',
    });
    expect(await readFile(f.asset.originalPath, 'utf8')).toContain('synthetic');
    expect(await db.selectFrom('asset').select('id').where('id', '=', shared.id).executeTakeFirst()).toBeDefined();
    expect(await f.repo.getDeletionReceipt(f.user.id, f.asset.id)).toBeUndefined();
    expect(await new TrashRepository(db).restoreAll([f.asset.id])).toEqual([f.asset.id]);
  });

  it('managed consent does not authorize external assets or create a partial mixed-scope deletion', async () => {
    const f = await fixture(true);
    const managedPath = join(root, 'managed.heic');
    await writeFile(managedPath, 'managed must survive');
    const { asset: managed } = await f.ctx.newAsset({
      ownerId: f.user.id,
      originalPath: managedPath,
      status: AssetStatus.Trashed,
      deletedAt: new Date(),
    });
    await f.repo.setDeletionPolicy(f.user.id, 'managed', await prepared({ ...f, scope: 'managed' }));
    const { sut } = service(f);
    const result = await sut.permanentlyDelete(authFor(f), [managed.id, f.asset.id]);
    expect(result.map((r) => r.state)).toEqual(['blocked', 'blocked']);
    await expect(sut.emptyAuthorizedTrash(authFor(f))).rejects.toThrow('LIBRARY_DELETION_NOT_AUTHORIZED');
    for (const id of [managed.id, f.asset.id]) expect(await f.repo.getDeletionReceipt(f.user.id, id)).toBeUndefined();
    expect(await readFile(managedPath, 'utf8')).toBe('managed must survive');
    expect(await readFile(f.asset.originalPath, 'utf8')).toContain('synthetic');
  });

  it.each(['ESTALE', 'EROFS', 'EACCES', 'ETIMEDOUT'])(
    'NFS-like capture %s failure preserves bytes and a retryable receipt',
    async (code) => {
      const f = await fixture(true);
      await externalConsent(f);
      await f.repo.preparePermanentDeletion(f.asset.id, f.user.id, snapshotOriginal);
      const renameSpy = vi
        .spyOn(fs, 'rename')
        .mockRejectedValueOnce(Object.assign(new Error('disposable injected fault'), { code }));
      await expect(f.repo.removeAuthorizedOriginals(f.asset.id, unlinkOriginal)).rejects.toMatchObject({
        code: 'ORIGINAL_DELETE_FAILED',
      });
      expect(await f.repo.getDeletionReceipt(f.user.id, f.asset.id)).toMatchObject({ state: 'failed' });
      expect(await readFile(f.asset.originalPath, 'utf8')).toContain('synthetic');
      renameSpy.mockRestore();
      expect(await new AssetRepository(db).removeAuthorizedOriginals(f.asset.id, unlinkOriginal)).toBe(true);
      expect(await f.repo.removeForDeletion(f.asset)).toBe(true);
    },
  );

  it('lost NFS rename acknowledgement resumes from the captured original without overwriting or guessing', async () => {
    const f = await fixture(true);
    await externalConsent(f);
    await f.repo.preparePermanentDeletion(f.asset.id, f.user.id, snapshotOriginal);
    const renameActual = fs.rename;
    const renameSpy = vi.spyOn(fs, 'rename').mockImplementationOnce(async (source, target) => {
      await renameActual(source, target);
      throw Object.assign(new Error('injected lost response'), { code: 'ETIMEDOUT' });
    });
    await expect(f.repo.removeAuthorizedOriginals(f.asset.id, unlinkOriginal)).rejects.toThrow();
    const receipt = await db
      .selectFrom('asset_deletion_tombstone')
      .selectAll()
      .where('assetId', '=', f.asset.id)
      .executeTakeFirstOrThrow();
    expect(receipt.state).toBe('failed');
    expect(
      await readFile(join(root, '.gallery-deletion-quarantine', receipt.files[0].quarantineName), 'utf8'),
    ).toContain('synthetic');
    renameSpy.mockRestore();
    expect(await new AssetRepository(db).removeAuthorizedOriginals(f.asset.id, unlinkOriginal)).toBe(true);
    expect(await f.repo.removeForDeletion(f.asset)).toBe(true);
    expect(await f.repo.getDeletionReceipt(f.user.id, f.asset.id)).toMatchObject({ state: 'complete' });
  });

  it('unsupported NFS directory fsync cannot unlink on first attempt or resumed capture', async () => {
    const f = await fixture(true);
    await externalConsent(f);
    await f.repo.preparePermanentDeletion(f.asset.id, f.user.id, snapshotOriginal);
    const openActual = fs.open;
    const openSpy = vi.spyOn(fs, 'open').mockImplementation(async (file, flags, mode) => {
      const handle = await openActual(file, flags, mode);
      if (String(file).endsWith('/.gallery-deletion-quarantine'))
        vi.spyOn(handle, 'sync').mockRejectedValue(Object.assign(new Error('injected NFS fsync'), { code: 'EINVAL' }));
      return handle;
    });
    const unlinkSpy = vi.spyOn(fs, 'unlink');
    for (const repository of [f.repo, new AssetRepository(db)]) {
      await expect(repository.removeAuthorizedOriginals(f.asset.id, unlinkOriginal)).rejects.toMatchObject({
        code: 'ORIGINAL_DELETE_FAILED',
      });
      expect(await f.repo.getDeletionReceipt(f.user.id, f.asset.id)).toMatchObject({ state: 'failed' });
    }
    expect(unlinkSpy).not.toHaveBeenCalled();
    const receipt = await db
      .selectFrom('asset_deletion_tombstone')
      .selectAll()
      .where('assetId', '=', f.asset.id)
      .executeTakeFirstOrThrow();
    expect(
      await readFile(join(root, '.gallery-deletion-quarantine', receipt.files[0].quarantineName), 'utf8'),
    ).toContain('synthetic');
    openSpy.mockRestore();
    expect(await f.repo.removeAuthorizedOriginals(f.asset.id, unlinkOriginal)).toBe(true);
    expect(await f.repo.removeForDeletion(f.asset)).toBe(true);
  });

  it('a mutation during resumed directory sync is detected before unlink', async () => {
    const f = await fixture(true);
    await externalConsent(f);
    await f.repo.preparePermanentDeletion(f.asset.id, f.user.id, snapshotOriginal);
    const renameActual = fs.rename;
    const renameSpy = vi.spyOn(fs, 'rename').mockImplementationOnce(async (source, target) => {
      await renameActual(source, target);
      throw Object.assign(new Error('lost capture response'), { code: 'ETIMEDOUT' });
    });
    await expect(f.repo.removeAuthorizedOriginals(f.asset.id, unlinkOriginal)).rejects.toThrow();
    renameSpy.mockRestore();
    const receipt = await db
      .selectFrom('asset_deletion_tombstone')
      .selectAll()
      .where('assetId', '=', f.asset.id)
      .executeTakeFirstOrThrow();
    const captured = join(root, '.gallery-deletion-quarantine', receipt.files[0].quarantineName);
    const openActual = fs.open;
    let mutated = false;
    vi.spyOn(fs, 'open').mockImplementation(async (file, flags, mode) => {
      const handle = await openActual(file, flags, mode);
      if (String(file).endsWith('/.gallery-deletion-quarantine')) {
        const syncActual = handle.sync.bind(handle);
        vi.spyOn(handle, 'sync').mockImplementation(async () => {
          if (!mutated) {
            mutated = true;
            await writeFile(captured, 'mutated bytes must not be unlinked');
          }
          await syncActual();
        });
      }
      return handle;
    });
    await expect(f.repo.removeAuthorizedOriginals(f.asset.id, unlinkOriginal)).rejects.toMatchObject({
      code: 'ORIGINAL_IDENTITY_CHANGED',
    });
    expect(await readFile(captured, 'utf8')).toBe('mutated bytes must not be unlinked');
    expect(await f.repo.removeForDeletion(f.asset)).toBe(false);
  });

  it('lost NFS unlink acknowledgement leaves failed receipt until an authorized retry completes', async () => {
    const f = await fixture(true);
    await externalConsent(f);
    await f.repo.preparePermanentDeletion(f.asset.id, f.user.id, snapshotOriginal);
    const unlinkActual = fs.unlink;
    const unlinkSpy = vi.spyOn(fs, 'unlink').mockImplementationOnce(async (file) => {
      await unlinkActual(file);
      throw Object.assign(new Error('injected lost response'), { code: 'ETIMEDOUT' });
    });
    await expect(f.repo.removeAuthorizedOriginals(f.asset.id, unlinkOriginal)).rejects.toThrow();
    expect(await f.repo.getDeletionReceipt(f.user.id, f.asset.id)).toMatchObject({ state: 'failed' });
    unlinkSpy.mockRestore();
    expect(await new AssetRepository(db).removeAuthorizedOriginals(f.asset.id, unlinkOriginal)).toBe(true);
    expect(await f.repo.removeForDeletion(f.asset)).toBe(true);
    expect(await f.repo.getDeletionReceipt(f.user.id, f.asset.id)).toMatchObject({ state: 'complete' });
  });
});

describe('managed owner consent and offline index compatibility', () => {
  it('migration rerun disables unbound legacy grants without modifying any asset or bound policy', async () => {
    const f = await fixture(true);
    const when = new Date('2026-10-02T12:00:00Z');
    const { asset: offline } = await f.ctx.newAsset({
      ownerId: f.user.id,
      libraryId: f.scope,
      status: AssetStatus.Active,
      deletedAt: when,
      isOffline: true,
    });
    await f.repo.setDeletionPolicy(f.user.id, 'managed', {
      enabled: true,
      roots: [root],
      recoveryProof: 'a'.repeat(64),
      authorizedBy: f.user.id,
    });
    await authorize(f);
    const snapshot = await db.selectFrom('asset').selectAll().where('id', 'in', [offline.id, f.asset.id]).execute();
    await bindRecovery(db as unknown as Kysely<unknown>);
    await bindRecovery(db as unknown as Kysely<unknown>);
    const legacy = await f.repo.getDeletionPolicy(f.user.id, 'managed');
    const bound = await f.repo.getDeletionPolicy(f.user.id, f.scope);
    expect(legacy?.enabled).toBe(false);
    expect(bound?.enabled).toBe(true);
    expect(await db.selectFrom('asset').selectAll().where('id', 'in', [offline.id, f.asset.id]).execute()).toEqual(
      snapshot,
    );
    expect(await readFile(f.asset.originalPath, 'utf8')).toContain('synthetic');
  });

  it('expired consent fails both mixed-scope preflights before creating any receipt', async () => {
    const f = await fixture();
    await authorize(f);
    const { library } = await f.ctx.newLibrary({ ownerId: f.user.id });
    const externalPath = join(root, 'expired-external.mp4');
    await writeFile(externalPath, 'external must survive');
    const { asset: external } = await f.ctx.newAsset({
      ownerId: f.user.id,
      libraryId: library.id,
      isExternal: true,
      status: AssetStatus.Trashed,
      deletedAt: new Date(),
      originalPath: externalPath,
    });
    const values = await prepared({ ...f, scope: library.id });
    await f.repo.setDeletionPolicy(f.user.id, library.id, { ...values, recoveryExpiresAt: new Date(0) });
    const { sut } = service(f);
    expect(await sut.permanentlyDelete(authFor(f), [f.asset.id, external.id])).toEqual([
      { id: f.asset.id, scope: 'managed', state: 'blocked', code: 'DELETION_BATCH_NOT_AUTHORIZED' },
      { id: external.id, scope: library.id, state: 'blocked', code: 'DELETION_RECOVERY_EXPIRED' },
    ]);
    await expect(sut.emptyAuthorizedTrash(authFor(f))).rejects.toThrow('DELETION_RECOVERY_EXPIRED');
    expect(await f.repo.getDeletionReceipt(f.user.id, f.asset.id)).toBeUndefined();
    expect(await f.repo.getDeletionReceipt(f.user.id, external.id)).toBeUndefined();
    expect(await readFile(f.asset.originalPath, 'utf8')).toContain('synthetic');
    expect(await readFile(externalPath, 'utf8')).toBe('external must survive');
  });

  it('rejects enabling a legacy unbound policy even with a syntactically valid hash', async () => {
    const f = await fixture();
    await f.repo.setDeletionPolicy(f.user.id, 'managed', {
      enabled: false,
      roots: [root],
      recoveryProof: 'a'.repeat(64),
      authorizedBy: f.user.id,
    });
    await expect(f.repo.updateManagedDeletionConsent(f.user.id, true, async () => {})).rejects.toMatchObject({
      code: 'MANAGED_DELETION_PREPARATION_REQUIRED',
    });
    const policy = await f.repo.getDeletionPolicy(f.user.id, 'managed');
    expect(policy?.enabled).toBe(false);
  });

  it('keeps active offline index tombstones out of Trash without changing their timestamp or originals', async () => {
    const f = await fixture(true);
    const offlineDate = new Date('2026-10-02T12:00:00Z');
    const { asset: offline } = await f.ctx.newAsset({
      ownerId: f.user.id,
      libraryId: f.scope,
      status: AssetStatus.Active,
      isOffline: true,
      deletedAt: offlineDate,
    });
    const { asset: active } = await f.ctx.newAsset({ ownerId: f.user.id, status: AssetStatus.Active });
    const trash = await f.repo.getOwnerTrash(f.user.id);
    expect(trash.map(({ id }) => id)).toEqual([f.asset.id]);
    expect(await f.repo.getDeletionScope(f.user.id, offline.id)).toBeUndefined();
    expect(
      await db
        .selectFrom('asset')
        .select(['status', 'deletedAt', 'isOffline'])
        .where('id', '=', offline.id)
        .executeTakeFirst(),
    ).toEqual({ status: AssetStatus.Active, deletedAt: offlineDate, isOffline: true });
    expect(trash.some(({ id }) => id === active.id)).toBe(false);
    expect(await readFile(f.asset.originalPath, 'utf8')).toContain('synthetic');
  });
  it('keeps active managed deletedAt records out of Trash rather than inventing historical user intent', async () => {
    const f = await fixture();
    const { asset } = await f.ctx.newAsset({ ownerId: f.user.id, status: AssetStatus.Active, deletedAt: new Date() });
    const trash = await f.repo.getOwnerTrash(f.user.id);
    expect(trash.map(({ id }) => id)).toEqual([f.asset.id]);
    expect(await f.repo.getDeletionScope(f.user.id, asset.id)).toBeUndefined();
  });
  it('requires existing verified preparation; never fabricates a policy', async () => {
    const f = await fixture();
    await expect(f.repo.updateManagedDeletionConsent(f.user.id, true, async () => {})).rejects.toMatchObject({
      code: 'MANAGED_DELETION_PREPARATION_REQUIRED',
    });
    expect(await f.repo.getDeletionPolicy(f.user.id, 'managed')).toBeUndefined();
  });
  it('consent is idempotent, preserves the administrator proof and cannot enable external scopes', async () => {
    const f = await fixture();
    const actor = randomUUID();
    await f.repo.setDeletionPolicy(f.user.id, 'managed', await prepared(f, false, actor));
    const originalPolicy = await f.repo.getDeletionPolicy(f.user.id, 'managed');
    const validate = vi.fn(async () => {});
    await f.repo.updateManagedDeletionConsent(f.user.id, true, validate);
    await f.repo.updateManagedDeletionConsent(f.user.id, true, validate);
    expect(await f.repo.getDeletionPolicy(f.user.id, 'managed')).toMatchObject({
      enabled: true,
      roots: [root],
      recoveryProof: originalPolicy!.recoveryProof,
      authorizedBy: actor,
    });
    expect(validate).toHaveBeenCalledWith([root], originalPolicy!.recoveryProof, originalPolicy!.rootIdentities);
    expect(await f.repo.getDeletionPolicy(f.user.id, randomUUID())).toBeUndefined();
    await f.repo.updateManagedDeletionConsent(f.user.id, false, () =>
      Promise.reject(new Error('must not validate revocation')),
    );
    const policy = await f.repo.getDeletionPolicy(f.user.id, 'managed');
    expect(policy?.enabled).toBe(false);
  });
  it('failed current-root validation rolls back consent atomically', async () => {
    const f = await fixture();
    await f.repo.setDeletionPolicy(f.user.id, 'managed', await prepared(f, false));
    await expect(
      f.repo.updateManagedDeletionConsent(f.user.id, true, () => Promise.reject(new Error('ROOT_REPLACED'))),
    ).rejects.toThrow('ROOT_REPLACED');
    const policy = await f.repo.getDeletionPolicy(f.user.id, 'managed');
    expect(policy?.enabled).toBe(false);
  });
  it('concurrent administrator revocation cannot be overwritten by stale consent', async () => {
    const f = await fixture();
    await authorize(f);
    const { promise: ready, resolve: entered } = Promise.withResolvers<void>();
    const { promise: gate, resolve: release } = Promise.withResolvers<void>();
    const consent = f.repo.updateManagedDeletionConsent(f.user.id, true, async () => {
      entered();
      await gate;
    });
    await ready;
    const revoke = f.repo.setDeletionPolicy(f.user.id, 'managed', {
      enabled: false,
      roots: [root],
      recoveryProof: 'c'.repeat(64),
      authorizedBy: f.user.id,
    });
    release();
    await Promise.all([consent, revoke]);
    expect(await f.repo.getDeletionPolicy(f.user.id, 'managed')).toMatchObject({
      enabled: false,
      recoveryProof: 'c'.repeat(64),
    });
  });
  it('selective and Empty Trash both fail closed across scopes, without receipts or partial unlink', async () => {
    const f = await fixture();
    await authorize(f);
    const { library } = await f.ctx.newLibrary({ ownerId: f.user.id });
    const externalPath = join(root, 'external.mp4');
    await writeFile(externalPath, 'synthetic external video');
    const { asset: external } = await f.ctx.newAsset({
      ownerId: f.user.id,
      libraryId: library.id,
      isExternal: true,
      status: AssetStatus.Trashed,
      deletedAt: new Date(),
      originalPath: externalPath,
    });
    const { sut } = service(f);
    const results = await sut.permanentlyDelete(authFor(f), [f.asset.id, external.id]);
    expect(results).toEqual([
      { id: f.asset.id, state: 'blocked', scope: 'managed', code: 'DELETION_BATCH_NOT_AUTHORIZED' },
      { id: external.id, state: 'blocked', scope: library.id, code: 'LIBRARY_DELETION_NOT_AUTHORIZED' },
    ]);
    await expect(sut.emptyAuthorizedTrash(authFor(f))).rejects.toThrow('LIBRARY_DELETION_NOT_AUTHORIZED');
    expect(await f.repo.getDeletionReceipt(f.user.id, f.asset.id)).toBeUndefined();
    expect(await f.repo.getDeletionReceipt(f.user.id, external.id)).toBeUndefined();
    expect(await readFile(f.asset.originalPath, 'utf8')).toContain('synthetic');
    expect(await readFile(externalPath, 'utf8')).toBe('synthetic external video');
  });
  it('authorized managed Empty Trash completes only this owner and is idempotent', async () => {
    const f = await fixture();
    await authorize(f);
    const { user: other } = await f.ctx.newUser();
    const otherPath = join(root, 'other-owner.heic');
    await writeFile(otherPath, 'synthetic other owner original');
    const { asset: otherAsset } = await f.ctx.newAsset({
      ownerId: other.id,
      status: AssetStatus.Trashed,
      deletedAt: new Date(),
      originalPath: otherPath,
    });
    const { sut } = service(f);
    expect(await sut.emptyAuthorizedTrash(authFor(f))).toEqual({ count: 1 });
    expect(await sut.emptyAuthorizedTrash(authFor(f))).toEqual({ count: 0 });
    expect(await f.repo.getById(otherAsset.id)).toBeDefined();
    expect(await readFile(otherPath, 'utf8')).toBe('synthetic other owner original');
    await expect(readFile(f.asset.originalPath)).rejects.toMatchObject({ code: 'ENOENT' });
  });

  it('explicit managed consent enables selective deletion through the existing guarded lifecycle', async () => {
    const f = await fixture();
    await f.repo.setDeletionPolicy(f.user.id, 'managed', await prepared(f, false));
    const { sut } = service(f);
    const blocked = await sut.permanentlyDelete(authFor(f), [f.asset.id]);
    expect(blocked[0].state).toBe('blocked');
    await f.repo.updateManagedDeletionConsent(f.user.id, true, async () => {});
    const completed = await sut.permanentlyDelete(authFor(f), [f.asset.id]);
    expect(completed[0].state).toBe('complete');
    await expect(readFile(f.asset.originalPath)).rejects.toMatchObject({ code: 'ENOENT' });
    const receipt = await f.repo.getDeletionReceipt(f.user.id, f.asset.id);
    expect(receipt?.state).toBe('complete');
  });
});
