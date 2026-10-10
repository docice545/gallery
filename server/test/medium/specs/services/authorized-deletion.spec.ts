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
      expect(await sut.permanentlyDelete(auth, [f.asset.id])).toEqual([{ id: f.asset.id, state: 'complete' }]);
      expect(await sut.permanentlyDelete(auth, [f.asset.id])).toEqual([{ id: f.asset.id, state: 'complete' }]);
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
    expect(result.map((item) => item.state)).toEqual(['complete', 'blocked', 'blocked', 'blocked']);
    expect(
      await db.selectFrom('asset').select('id').where('id', 'in', [blocked.id, active.id, foreign.id]).execute(),
    ).toHaveLength(3);
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
