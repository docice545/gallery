import { Kysely } from 'kysely';
import { createHash, randomUUID } from 'node:crypto';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { AssetStatus, AssetType, AssetVisibility, ChecksumAlgorithm, JobName, JobStatus } from 'src/enum.js';
import { AccessRepository } from 'src/repositories/access.repository.js';
import { AssetJobRepository } from 'src/repositories/asset-job.repository.js';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { StorageRepository } from 'src/repositories/storage.repository.js';
import { TrashRepository } from 'src/repositories/trash.repository.js';
import { DB } from 'src/schema/index.js';
import { AssetService } from 'src/services/asset.service.js';
import { snapshotOriginal, unlinkOriginal } from 'src/utils/authorized-deletion.js';
import { authStub } from 'test/fixtures/auth.stub.js';
import { newMediumService } from 'test/medium.factory.js';
import { getKyselyDB, newTestService } from 'test/utils.js';

let db: Kysely<DB>;
let root: string;
beforeAll(async () => {
  db = await getKyselyDB();
});
afterAll(async () => {
  await db.destroy();
});
beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), 'gallery-delete-pg-'));
});
afterEach(async () => {
  await rm(root, { recursive: true, force: true });
});
const fixture = async (external = false) => {
  const { ctx } = newMediumService(AssetService, { database: db, real: [AssetRepository], mock: [LoggingRepository] });
  const { user } = await ctx.newUser();
  const libraryFixture = external ? await ctx.newLibrary({ ownerId: user.id }) : undefined;
  const library = libraryFixture?.library;
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
const authorize = async (f: Awaited<ReturnType<typeof fixture>>) =>
  f.repo.setDeletionPolicy(f.user.id, f.scope, {
    enabled: true,
    roots: [root],
    recoveryProof: 'a'.repeat(64),
    authorizedBy: f.user.id,
  });

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
  return { storage, ...test };
};
const authFor = (f: Awaited<ReturnType<typeof fixture>>) => ({
  ...authStub.user1,
  user: { ...authStub.user1.user, id: f.user.id },
});

describe('durable per-library authorization with real PostgreSQL and disposable media', () => {
  it('is disabled by default and preserves the original and restorable Trash', async () => {
    const f = await fixture();
    await expect(f.repo.preparePermanentDeletion(f.asset.id, f.user.id, snapshotOriginal)).rejects.toMatchObject({
      code: 'LIBRARY_DELETION_NOT_AUTHORIZED',
    });
    expect(await readFile(f.asset.originalPath, 'utf8')).toContain('synthetic');
    expect(await new TrashRepository(db).restoreAll([f.asset.id])).toEqual([f.asset.id]);
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

  it('deletes the exclusive Live/Motion video first and retains the still for retry on failure', async () => {
    const f = await fixture();
    await authorize(f);
    const motionPath = join(root, 'motion.mov');
    await writeFile(motionPath, 'synthetic paired video');
    const { asset: motion } = await f.ctx.newAsset({
      ownerId: f.user.id,
      type: AssetType.Video,
      visibility: AssetVisibility.Hidden,
      originalPath: motionPath,
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
  });

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

describe('managed owner consent and offline index compatibility', () => {
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
    await f.repo.setDeletionPolicy(f.user.id, 'managed', {
      enabled: false,
      roots: [root],
      recoveryProof: 'b'.repeat(64),
      authorizedBy: actor,
    });
    const validate = vi.fn(async () => {});
    await f.repo.updateManagedDeletionConsent(f.user.id, true, validate);
    await f.repo.updateManagedDeletionConsent(f.user.id, true, validate);
    expect(await f.repo.getDeletionPolicy(f.user.id, 'managed')).toMatchObject({
      enabled: true,
      roots: [root],
      recoveryProof: 'b'.repeat(64),
      authorizedBy: actor,
    });
    expect(validate).toHaveBeenCalledWith([root], 'b'.repeat(64));
    expect(await f.repo.getDeletionPolicy(f.user.id, randomUUID())).toBeUndefined();
    await f.repo.updateManagedDeletionConsent(f.user.id, false, () =>
      Promise.reject(new Error('must not validate revocation')),
    );
    const policy = await f.repo.getDeletionPolicy(f.user.id, 'managed');
    expect(policy?.enabled).toBe(false);
  });
  it('failed current-root validation rolls back consent atomically', async () => {
    const f = await fixture();
    await f.repo.setDeletionPolicy(f.user.id, 'managed', {
      enabled: false,
      roots: [root],
      recoveryProof: 'b'.repeat(64),
      authorizedBy: f.user.id,
    });
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
    await f.repo.setDeletionPolicy(f.user.id, 'managed', {
      enabled: false,
      roots: [root],
      recoveryProof: 'b'.repeat(64),
      authorizedBy: f.user.id,
    });
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
