import { Kysely } from 'kysely';
import { randomUUID } from 'node:crypto';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { StorageCore } from 'src/cores/storage.core.js';
import { AssetStatus, AssetType, AssetVisibility, JobName, JobStatus, StorageFolder } from 'src/enum.js';
import { AccessRepository } from 'src/repositories/access.repository.js';
import { AssetJobRepository } from 'src/repositories/asset-job.repository.js';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { LibraryRepository } from 'src/repositories/library.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { StorageRepository } from 'src/repositories/storage.repository.js';
import { UserRepository } from 'src/repositories/user.repository.js';
import { DB } from 'src/schema/index.js';
import { AssetService } from 'src/services/asset.service.js';
import { DeletionError, collectRootIdentities, snapshotOriginal } from 'src/utils/authorized-deletion.js';
import { authStub } from 'test/fixtures/auth.stub.js';
import { newMediumService } from 'test/medium.factory.js';
import { getKyselyDB, newTestService } from 'test/utils.js';

let db: Kysely<DB>;
let directory: string;

beforeAll(async () => {
  db = await getKyselyDB();
});
afterAll(async () => {
  await db.destroy();
});
beforeEach(async () => {
  directory = await mkdtemp(join(tmpdir(), 'gallery-cli-livephoto-retry-'));
});
afterEach(async () => {
  vi.restoreAllMocks();
  await rm(directory, { recursive: true, force: true });
});

const fixture = async ({ seedFailure = true }: { seedFailure?: boolean } = {}) => {
  const { ctx } = newMediumService(AssetService, { database: db, real: [AssetRepository], mock: [LoggingRepository] });
  const { user } = await ctx.newUser();
  const upload = join(directory, 'upload', user.id);
  const encoded = join(directory, 'encoded-video', user.id);
  await Promise.all([mkdir(upload, { recursive: true }), mkdir(encoded, { recursive: true })]);
  const actualFolder = StorageCore.getFolderLocation;
  const actualLibrary = StorageCore.getLibraryFolder;
  vi.spyOn(StorageCore, 'getFolderLocation').mockImplementation((folder, owner) => {
    if (owner !== user.id) return actualFolder(folder, owner);
    if (folder === StorageFolder.Upload) return upload;
    if (folder === StorageFolder.EncodedVideo) return encoded;
    return actualFolder(folder, owner);
  });
  vi.spyOn(StorageCore, 'getLibraryFolder').mockImplementation((owner) =>
    owner.id === user.id ? upload : actualLibrary(owner),
  );

  const motionId = randomUUID();
  const motionPath = join(encoded, motionId.slice(0, 2), motionId.slice(2, 4), `${motionId}-MP.mp4`);
  await mkdir(join(encoded, motionId.slice(0, 2), motionId.slice(2, 4)), { recursive: true });
  await writeFile(motionPath, 'synthetic exclusive Live Photo MP4');
  const { asset: motion } = await ctx.newAsset({
    id: motionId,
    ownerId: user.id,
    type: AssetType.Video,
    visibility: AssetVisibility.Hidden,
    originalPath: motionPath,
  });
  const originalPath = join(upload, 'disposable-live-photo.jpg');
  await writeFile(originalPath, 'synthetic Live Photo JPG');
  const { asset: still } = await ctx.newAsset({
    ownerId: user.id,
    originalPath,
    livePhotoVideoId: motion.id,
    status: AssetStatus.Trashed,
    deletedAt: new Date(),
  });
  const repo = new AssetRepository(db);
  const identities = await collectRootIdentities([upload]);
  await repo.setDeletionPolicy(user.id, 'managed', {
    enabled: true,
    authorizationMode: 'storage',
    roots: [upload],
    rootIdentities: identities,
    recoveryProof: '',
    recoveryExpiresAt: null,
    authorizedBy: user.id,
  });

  let legacy = await db
    .selectFrom('asset_deletion_tombstone')
    .selectAll()
    .where('ownerId', '=', user.id)
    .where('operationId', '=', still.id)
    .orderBy('assetId')
    .execute();
  if (seedFailure) {
    // Seed the historical failed/empty receipt shape produced by the old
    // upload-only worker, which passed only the persisted policy roots.
    await expect(
      repo.preparePermanentDeletion(still.id, user.id, (path) => snapshotOriginal(path, identities)),
    ).rejects.toMatchObject({ code: 'ORIGINAL_OUTSIDE_AUTHORIZED_ROOT' });
    legacy = await db
      .selectFrom('asset_deletion_tombstone')
      .selectAll()
      .where('ownerId', '=', user.id)
      .where('operationId', '=', still.id)
      .orderBy('assetId')
      .execute();
    expect(legacy).toHaveLength(2);
    for (const receipt of legacy) {
      expect(receipt).toMatchObject({
        ownerId: user.id,
        operationId: still.id,
        scope: 'managed',
        state: 'failed',
        errorCode: 'ORIGINAL_OUTSIDE_AUTHORIZED_ROOT',
        files: [],
        authorization: { mode: 'storage', recoveryProof: '' },
      });
    }
  }

  const storage = new StorageRepository(ctx.getMock(LoggingRepository));
  const service = newTestService(AssetService, {
    asset: repo,
    access: new AccessRepository(db),
    assetJob: new AssetJobRepository(db),
    storage,
  });
  service.mocks.sharedSpace.getSpacePersonsForAsset.mockResolvedValue([]);
  service.mocks.event.emit.mockResolvedValue();
  service.mocks.user.updateUsage.mockResolvedValue();
  service.mocks.job.queue.mockResolvedValue();
  service.mocks.user.get.mockImplementation((id, options) => new UserRepository(db).get(id, options));
  const libraries = new LibraryRepository(db);
  service.mocks.library.get.mockImplementation((id, includeDeleted) => libraries.get(id, includeDeleted));
  service.mocks.library.getAll.mockImplementation(() => libraries.getAll());
  const auth = { ...authStub.user1, user: { ...authStub.user1.user, id: user.id } };
  return { ctx, user, still, motion, repo, storage, upload, encoded, legacy, auth, ...service };
};

const receipts = (ownerId: string, operationId: string) =>
  db
    .selectFrom('asset_deletion_tombstone')
    .selectAll()
    .where('ownerId', '=', ownerId)
    .where('operationId', '=', operationId)
    .orderBy('assetId')
    .execute();

const expectOriginals = async (f: Awaited<ReturnType<typeof fixture>>) => {
  expect(await readFile(f.still.originalPath, 'utf8')).toBe('synthetic Live Photo JPG');
  expect(await readFile(f.motion.originalPath, 'utf8')).toBe('synthetic exclusive Live Photo MP4');
};

describe('CLI failed empty Live Photo receipts', () => {
  it('captures the JPG and MP4 under separate roots without broadening the managed policy', async () => {
    const f = await fixture({ seedFailure: false });
    const rootsByPath = new Map<string, string[]>();
    await f.repo.preparePermanentDeletion(f.still.id, f.user.id, (path, roots) => {
      rootsByPath.set(
        path,
        roots.map(({ path: root }) => root),
      );
      return snapshotOriginal(path, roots);
    });
    expect(rootsByPath.get(f.still.originalPath)).toEqual([f.upload]);
    expect(rootsByPath.get(f.motion.originalPath)).toEqual([f.upload, f.encoded]);
    const result = await receipts(f.user.id, f.still.id);
    expect(result).toHaveLength(2);
    expect(result.every(({ state, files }) => state === 'pending' && files.length === 1)).toBe(true);
    expect(result.find(({ assetId }) => assetId === f.motion.id)?.files[0].root).toBe(f.encoded);
    const policy = await f.repo.getDeletionPolicy(f.user.id, 'managed');
    expect(policy?.roots).toEqual([f.upload]);
    await expectOriginals(f);
  });

  it.each(['still', 'motion'] as const)(
    'persists the current failed preparation error for the whole operation when retry starts at %s',
    async (component) => {
      const f = await fixture();
      const snapshot = vi.fn().mockRejectedValue(new DeletionError('DELETION_ROOT_CHANGED'));
      await expect(f.repo.preparePermanentDeletion(f[component].id, f.user.id, snapshot)).rejects.toMatchObject({
        code: 'DELETION_ROOT_CHANGED',
      });
      expect(snapshot).toHaveBeenCalled();
      const result = await receipts(f.user.id, f.still.id);
      expect(result).toHaveLength(2);
      for (const receipt of result) {
        expect(receipt).toMatchObject({ state: 'failed', errorCode: 'DELETION_ROOT_CHANGED', files: [] });
      }
      await expectOriginals(f);
    },
  );

  it('does not overwrite terminal, foreign-owner or unrelated-operation receipts after a child retry fails', async () => {
    const f = await fixture();
    const { user: other } = await f.ctx.newUser();
    const source = f.legacy[0];
    const proof = await snapshotOriginal(f.still.originalPath, await collectRootIdentities([f.upload]));
    const unrelated = [
      { ...source, assetId: randomUUID(), files: [proof], state: 'complete' as const, errorCode: null },
      { ...source, assetId: randomUUID(), files: [proof], state: 'files-removed' as const, errorCode: null },
      { ...source, assetId: randomUUID(), ownerId: other.id },
      { ...source, assetId: randomUUID(), operationId: randomUUID() },
    ];
    await db.insertInto('asset_deletion_tombstone').values(unrelated).execute();
    const before = await db
      .selectFrom('asset_deletion_tombstone')
      .selectAll()
      .where(
        'assetId',
        'in',
        unrelated.map(({ assetId }) => assetId),
      )
      .orderBy('assetId')
      .execute();
    await expect(
      f.repo.preparePermanentDeletion(f.motion.id, f.user.id, () =>
        Promise.reject(new DeletionError('DELETION_ROOT_CHANGED')),
      ),
    ).rejects.toMatchObject({ code: 'DELETION_ROOT_CHANGED' });
    const after = await db
      .selectFrom('asset_deletion_tombstone')
      .selectAll()
      .where(
        'assetId',
        'in',
        unrelated.map(({ assetId }) => assetId),
      )
      .orderBy('assetId')
      .execute();
    expect(after).toEqual(before);
    expect(await receipts(f.user.id, f.still.id)).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ assetId: f.still.id, state: 'failed', errorCode: 'DELETION_ROOT_CHANGED' }),
        expect.objectContaining({ assetId: f.motion.id, state: 'failed', errorCode: 'DELETION_ROOT_CHANGED' }),
      ]),
    );
    await expectOriginals(f);
  });

  it("cannot poison another owner's existing operation by retrying its child ID", async () => {
    const f = await fixture();
    const { user: other } = await f.ctx.newUser();
    const before = await receipts(f.user.id, f.still.id);
    const snapshot = vi.fn(snapshotOriginal);
    await expect(f.repo.preparePermanentDeletion(f.motion.id, other.id, snapshot)).rejects.toMatchObject({
      code: 'ASSET_NOT_OWNED',
    });
    expect(snapshot).not.toHaveBeenCalled();
    expect(await receipts(f.user.id, f.still.id)).toEqual(before);
    await expectOriginals(f);
  });

  it('records revoked authorization for both old receipts before hashing or unlinking', async () => {
    const f = await fixture();
    await f.sut.setManagedDeletionConsent(f.auth, false);
    const snapshot = vi.fn(snapshotOriginal);
    await expect(f.repo.preparePermanentDeletion(f.motion.id, f.user.id, snapshot)).rejects.toMatchObject({
      code: 'LIBRARY_DELETION_NOT_AUTHORIZED',
    });
    expect(snapshot).not.toHaveBeenCalled();
    const result = await receipts(f.user.id, f.still.id);
    expect(result).toHaveLength(2);
    for (const receipt of result) {
      expect(receipt).toMatchObject({
        state: 'failed',
        errorCode: 'LIBRARY_DELETION_NOT_AUTHORIZED',
        files: [],
      });
    }
    await expectOriginals(f);
    const policy = await f.repo.getDeletionPolicy(f.user.id, 'managed');
    expect(policy?.enabled).toBe(false);
  });

  it('rebuilds old empty receipts through the real child worker and completes inline HTTP retry without broadening roots', async () => {
    const f = await fixture();
    expect(await f.sut.handleAssetDeletion({ id: f.motion.id, deleteOnDisk: true, deletionId: f.motion.id })).toBe(
      JobStatus.Success,
    );
    expect(await readFile(f.still.originalPath, 'utf8')).toBe('synthetic Live Photo JPG');
    await expect(readFile(f.motion.originalPath)).rejects.toHaveProperty('code', 'ENOENT');
    expect(await f.sut.permanentlyDelete(f.auth, [f.still.id])).toEqual([
      { id: f.still.id, state: 'complete', scope: 'managed' },
    ]);
    await expect(readFile(f.still.originalPath)).rejects.toHaveProperty('code', 'ENOENT');
    const complete = await receipts(f.user.id, f.still.id);
    expect(complete).toHaveLength(2);
    expect(complete.every((receipt) => receipt.state === 'complete' && receipt.errorCode === null)).toBe(true);
    expect(await db.selectFrom('asset').select('id').where('id', 'in', [f.still.id, f.motion.id]).execute()).toEqual(
      [],
    );
    const policy = await f.repo.getDeletionPolicy(f.user.id, 'managed');
    expect(policy?.roots).toEqual([f.upload]);
    expect(policy?.rootIdentities.map(({ path }) => path)).toEqual([f.upload]);
    expect(f.mocks.event.emit).toHaveBeenCalledTimes(2);
    expect(f.mocks.job.queue).not.toHaveBeenCalledWith(expect.objectContaining({ name: JobName.FileDelete }));
    expect(await f.sut.permanentlyDelete(f.auth, [f.still.id])).toEqual([
      { id: f.still.id, state: 'complete', scope: 'managed' },
    ]);
    expect(f.mocks.event.emit).toHaveBeenCalledTimes(2);
  });

  it('preserves the visible still and both originals after worker preparation fails, then succeeds on the ordinary retry', async () => {
    const f = await fixture();
    const snapshot = vi.spyOn(f.storage, 'snapshotOriginal');
    snapshot.mockRejectedValueOnce(new DeletionError('DELETION_ROOT_CHANGED'));
    expect(await f.sut.handleAssetDeletion({ id: f.motion.id, deleteOnDisk: true, deletionId: f.motion.id })).toBe(
      JobStatus.Failed,
    );
    await expectOriginals(f);
    expect(await f.repo.getDeletionReceipt(f.user.id, f.still.id)).toMatchObject({
      state: 'failed',
      errorCode: 'DELETION_ROOT_CHANGED',
    });
    snapshot.mockRestore();
    expect(await f.sut.permanentlyDelete(f.auth, [f.still.id])).toEqual([
      { id: f.still.id, state: 'complete', scope: 'managed' },
    ]);
    const complete = await receipts(f.user.id, f.still.id);
    expect(complete.every(({ state }) => state === 'complete')).toBe(true);
  });

  it('rejects a motion path outside the owner encoded-video root without touching either original', async () => {
    const f = await fixture({ seedFailure: false });
    const outside = join(directory, 'outside-motion.mp4');
    await writeFile(outside, 'must survive');
    await db.updateTable('asset').set({ originalPath: outside }).where('id', '=', f.motion.id).execute();
    await expect(f.repo.preparePermanentDeletion(f.still.id, f.user.id, snapshotOriginal)).rejects.toMatchObject({
      code: 'MOTION_ORIGINAL_OUTSIDE_MANAGED_ROOT',
    });
    expect(await readFile(f.still.originalPath, 'utf8')).toBe('synthetic Live Photo JPG');
    expect(await readFile(f.motion.originalPath, 'utf8')).toBe('synthetic exclusive Live Photo MP4');
    expect(await readFile(outside, 'utf8')).toBe('must survive');
  });
});
