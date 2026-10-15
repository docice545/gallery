import { Kysely } from 'kysely';
import { randomUUID } from 'node:crypto';
import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { StorageCore } from 'src/cores/storage.core.js';
import { AssetStatus, AssetType, AssetVisibility, JobStatus, StorageFolder } from 'src/enum.js';
import { AccessRepository } from 'src/repositories/access.repository.js';
import { AssetJobRepository } from 'src/repositories/asset-job.repository.js';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { LibraryRepository } from 'src/repositories/library.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { StorageRepository } from 'src/repositories/storage.repository.js';
import { UserRepository } from 'src/repositories/user.repository.js';
import { DB } from 'src/schema/index.js';
import { AssetService } from 'src/services/asset.service.js';
import { collectRootIdentities, snapshotOriginal } from 'src/utils/authorized-deletion.js';
import { authStub } from 'test/fixtures/auth.stub.js';
import { newMediumService } from 'test/medium.factory.js';
import { getKyselyDB, newTestService } from 'test/utils.js';

let db: Kysely<DB>;
let directory: string;
let previousMediaLocation: string | undefined;

beforeAll(async () => {
  db = await getKyselyDB();
  try {
    previousMediaLocation = StorageCore.getMediaLocation();
  } catch {
    // Each Vitest file has an isolated module graph; an unset location is normal.
  }
});
afterAll(async () => {
  if (previousMediaLocation !== undefined) StorageCore.setMediaLocation(previousMediaLocation);
  await db.destroy();
});
beforeEach(async () => {
  directory = await mkdtemp(join(tmpdir(), 'gallery-real-storage-roots-'));
  StorageCore.setMediaLocation(directory);
});
afterEach(async () => {
  vi.restoreAllMocks();
  await rm(directory, { recursive: true, force: true });
});

// Real StorageCore folder selection, with two disposable local roots, not real NFS.
const fixture = async () => {
  const { ctx } = newMediumService(AssetService, { database: db, real: [AssetRepository], mock: [LoggingRepository] });
  // Service factories construct storage mocks that reset the shared location to /data.
  // Restore our disposable root before generating any actual StorageCore paths.
  StorageCore.setMediaLocation(directory);
  const { user } = await ctx.newUser();
  const upload = StorageCore.getFolderLocation(StorageFolder.Upload, user.id);
  const encoded = StorageCore.getFolderLocation(StorageFolder.EncodedVideo, user.id);
  const motionId = randomUUID();
  const motionPath = StorageCore.getAndroidMotionPath({ id: motionId, ownerId: user.id }, motionId);
  const stillPath = join(upload, '94', 'c5', `${randomUUID()}.jpg`);
  await Promise.all([mkdir(dirname(stillPath), { recursive: true }), mkdir(dirname(motionPath), { recursive: true })]);
  await writeFile(stillPath, 'disposable still original');
  await writeFile(motionPath, 'disposable linked motion original');
  const { asset: motion } = await ctx.newAsset({
    id: motionId,
    ownerId: user.id,
    type: AssetType.Video,
    visibility: AssetVisibility.Hidden,
    originalPath: motionPath,
  });
  const { asset: still } = await ctx.newAsset({
    ownerId: user.id,
    originalPath: stillPath,
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
  const storage = new StorageRepository(ctx.getMock(LoggingRepository));
  const service = newTestService(AssetService, {
    asset: repo,
    access: new AccessRepository(db),
    assetJob: new AssetJobRepository(db),
    storage,
  });
  // newTestService also constructs defaults before applying repository overrides.
  StorageCore.setMediaLocation(directory);
  service.mocks.sharedSpace.getSpacePersonsForAsset.mockResolvedValue([]);
  service.mocks.event.emit.mockResolvedValue();
  service.mocks.user.updateUsage.mockResolvedValue();
  service.mocks.job.queue.mockResolvedValue();
  service.mocks.user.get.mockImplementation((id, options) => new UserRepository(db).get(id, options));
  const libraries = new LibraryRepository(db);
  service.mocks.library.get.mockImplementation((id, includeDeleted) => libraries.get(id, includeDeleted));
  service.mocks.library.getAll.mockImplementation(() => libraries.getAll());
  const auth = { ...authStub.user1, user: { ...authStub.user1.user, id: user.id } };
  return { ctx, user, still, motion, repo, storage, upload, encoded, identities, auth, ...service };
};

const expectOriginals = async (f: Awaited<ReturnType<typeof fixture>>) => {
  expect(await readFile(f.still.originalPath, 'utf8')).toBe('disposable still original');
  expect(await readFile(f.motion.originalPath, 'utf8')).toBe('disposable linked motion original');
  expect(await db.selectFrom('asset').select('id').where('id', 'in', [f.still.id, f.motion.id]).execute()).toHaveLength(
    2,
  );
};

describe('Live Photo root admission with actual StorageCore path generation', () => {
  it('passes upload only to the JPG and adds only the owner encoded root to its linked MP4 on an empty-receipt retry', async () => {
    const f = await fixture();
    await expect(
      f.repo.preparePermanentDeletion(f.still.id, f.user.id, (path) => snapshotOriginal(path, f.identities)),
    ).rejects.toMatchObject({ code: 'ORIGINAL_OUTSIDE_AUTHORIZED_ROOT' });
    const failed = await db
      .selectFrom('asset_deletion_tombstone')
      .selectAll()
      .where('operationId', '=', f.still.id)
      .execute();
    expect(failed).toHaveLength(2);
    expect(failed.every(({ state, files }) => state === 'failed' && files.length === 0)).toBe(true);
    const snapshot = vi.fn(snapshotOriginal);
    await f.repo.preparePermanentDeletion(f.motion.id, f.user.id, snapshot);
    expect(snapshot).toHaveBeenCalledTimes(2);
    const rootsFor = (path: string) => snapshot.mock.calls.find(([file]) => file === path)?.[1].map(({ path }) => path);
    expect(rootsFor(f.still.originalPath)).toEqual([f.upload]);
    expect(rootsFor(f.motion.originalPath)).toEqual([f.upload, f.encoded]);
    expect(await f.sut.handleAssetDeletion({ id: f.motion.id, deleteOnDisk: true, deletionId: f.motion.id })).toBe(
      JobStatus.Success,
    );
    expect(await f.sut.permanentlyDelete(f.auth, [f.still.id])).toEqual([
      { id: f.still.id, state: 'complete', scope: 'managed' },
    ]);
    await expect(readFile(f.motion.originalPath)).rejects.toHaveProperty('code', 'ENOENT');
    await expect(readFile(f.still.originalPath)).rejects.toHaveProperty('code', 'ENOENT');
    const policy = await f.repo.getDeletionPolicy(f.user.id, 'managed');
    expect(policy?.roots).toEqual([f.upload]);
  });

  it('deletes an ordinary JPG without admitting or deleting an unrelated encoded video', async () => {
    const f = await fixture();
    await db.updateTable('asset').set({ livePhotoVideoId: null }).where('id', '=', f.still.id).execute();
    const snapshot = vi.spyOn(f.storage, 'snapshotOriginal');
    expect(await f.sut.permanentlyDelete(f.auth, [f.still.id])).toEqual([
      { id: f.still.id, state: 'complete', scope: 'managed' },
    ]);
    expect(snapshot).toHaveBeenCalledTimes(1);
    expect(snapshot.mock.calls[0][1].map(({ path }) => path)).toEqual([f.upload]);
    expect(await readFile(f.motion.originalPath, 'utf8')).toBe('disposable linked motion original');
    await expect(readFile(f.still.originalPath)).rejects.toHaveProperty('code', 'ENOENT');
  });

  it('does not admit the encoded root solely because a linked image has an MP4 path', async () => {
    const f = await fixture();
    await db.updateTable('asset').set({ type: AssetType.Image }).where('id', '=', f.motion.id).execute();
    await expect(f.repo.preparePermanentDeletion(f.still.id, f.user.id, snapshotOriginal)).rejects.toMatchObject({
      code: 'ORIGINAL_OUTSIDE_AUTHORIZED_ROOT',
    });
    await expectOriginals(f);
  });

  it.each(['owner', 'library'] as const)('rejects a companion with a different %s', async (mismatch) => {
    const f = await fixture();
    if (mismatch === 'owner') {
      const { user } = await f.ctx.newUser();
      await db.updateTable('asset').set({ ownerId: user.id }).where('id', '=', f.motion.id).execute();
    } else {
      const { library } = await f.ctx.newLibrary({ ownerId: f.user.id });
      await db.updateTable('asset').set({ libraryId: library.id }).where('id', '=', f.motion.id).execute();
    }
    const snapshot = vi.fn(snapshotOriginal);
    await expect(f.repo.preparePermanentDeletion(f.still.id, f.user.id, snapshot)).rejects.toMatchObject({
      code: 'MOTION_SCOPE_MISMATCH',
    });
    expect(snapshot).not.toHaveBeenCalled();
    await expectOriginals(f);
  });

  it('rejects a motion original referenced by a second still without touching either original', async () => {
    const f = await fixture();
    await f.ctx.newAsset({ ownerId: f.user.id, livePhotoVideoId: f.motion.id });
    await expect(f.repo.preparePermanentDeletion(f.still.id, f.user.id, snapshotOriginal)).rejects.toMatchObject({
      code: 'ORIGINAL_SHARED_WITH_OTHER_ASSET',
    });
    await expectOriginals(f);
  });

  it('rejects an otherwise valid companion located in another owner encoded directory', async () => {
    const f = await fixture();
    const outside = StorageCore.getAndroidMotionPath({ id: f.motion.id, ownerId: randomUUID() }, f.motion.id);
    await mkdir(dirname(outside), { recursive: true });
    await writeFile(outside, 'disposable linked motion original');
    await db.updateTable('asset').set({ originalPath: outside }).where('id', '=', f.motion.id).execute();
    await expect(f.repo.preparePermanentDeletion(f.still.id, f.user.id, snapshotOriginal)).rejects.toMatchObject({
      code: 'MOTION_ORIGINAL_OUTSIDE_MANAGED_ROOT',
    });
    expect(await readFile(outside, 'utf8')).toBe('disposable linked motion original');
    await expectOriginals(f);
  });

  it('identifies the JPG as outside when persisted storage identity paths omit its valid upload root', async () => {
    const f = await fixture();
    const library = StorageCore.getLibraryFolder(f.user);
    await mkdir(library, { recursive: true });
    // Isolated legacy/inconsistent policy: configured roots remain owner upload,
    // but the physically valid persisted identity belongs to owner library.
    await f.repo.setDeletionPolicy(f.user.id, 'managed', {
      enabled: true,
      authorizationMode: 'storage',
      roots: [f.upload],
      rootIdentities: await collectRootIdentities([library]),
      recoveryProof: '',
      recoveryExpiresAt: null,
      authorizedBy: f.user.id,
    });
    await db.updateTable('asset').set({ livePhotoVideoId: null }).where('id', '=', f.still.id).execute();
    const snapshot = vi.fn(snapshotOriginal);
    await expect(f.repo.preparePermanentDeletion(f.still.id, f.user.id, snapshot)).rejects.toMatchObject({
      code: 'ORIGINAL_OUTSIDE_AUTHORIZED_ROOT',
    });
    expect(snapshot).toHaveBeenCalledTimes(1);
    expect(snapshot.mock.calls[0][0]).toBe(f.still.originalPath);
    expect(snapshot.mock.calls[0][1].map(({ path }) => path)).toEqual([library]);
    await expectOriginals(f);
  });

  it('rejects a linked motion symlink instead of hashing or deleting its target', async () => {
    const f = await fixture();
    const outside = join(directory, 'unrelated-original');
    await writeFile(outside, 'unrelated protected bytes');
    await rm(f.motion.originalPath);
    await symlink(outside, f.motion.originalPath);
    await expect(f.repo.preparePermanentDeletion(f.still.id, f.user.id, snapshotOriginal)).rejects.toBeDefined();
    expect(await readFile(outside, 'utf8')).toBe('unrelated protected bytes');
    expect(await readFile(f.still.originalPath, 'utf8')).toBe('disposable still original');
    expect(
      await db.selectFrom('asset').select('id').where('id', 'in', [f.still.id, f.motion.id]).execute(),
    ).toHaveLength(2);
  });
});
