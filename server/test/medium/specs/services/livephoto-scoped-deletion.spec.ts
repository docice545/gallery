import { Kysely } from 'kysely';
import { randomUUID } from 'node:crypto';
import fs from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { StorageCore } from 'src/cores/storage.core.js';
import { AssetFileType, AssetStatus, AssetType, AssetVisibility, JobStatus, StorageFolder } from 'src/enum.js';
import { AccessRepository } from 'src/repositories/access.repository.js';
import { AssetJobRepository } from 'src/repositories/asset-job.repository.js';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { LibraryRepository } from 'src/repositories/library.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { StorageRepository } from 'src/repositories/storage.repository.js';
import { UserRepository } from 'src/repositories/user.repository.js';
import { DB } from 'src/schema/index.js';
import { AssetService } from 'src/services/asset.service.js';
import {
  DeletionError,
  collectRootIdentities,
  snapshotOriginal,
  unlinkOriginal,
} from 'src/utils/authorized-deletion.js';
import { authStub } from 'test/fixtures/auth.stub.js';
import { newMediumService } from 'test/medium.factory.js';
import { emulateNfsRootSquash } from 'test/nfs-quarantine.js';
import { createTestRecoveryEvidenceStore } from 'test/recovery-evidence.js';
import { getKyselyDB, newTestService } from 'test/utils.js';

let db: Kysely<DB>;
let base: string;
let evidence: Awaited<ReturnType<typeof createTestRecoveryEvidenceStore>>;
beforeAll(async () => {
  db = await getKyselyDB();
});
afterAll(async () => {
  await db.destroy();
});
beforeEach(async () => {
  base = await fs.mkdtemp(join(tmpdir(), 'gallery-livephoto-scoped-'));
  evidence = await createTestRecoveryEvidenceStore();
});
afterEach(async () => {
  vi.restoreAllMocks();
  await evidence.cleanup();
  await fs.rm(base, { recursive: true, force: true });
});

// The two stores are distinct disposable directories. The NFS helper injects
// only server metadata/mkdir behavior; hashing, chmod, fsync, rename and unlink
// operate on real files. These fixtures do not claim actual NFS server testing.
const fixture = async (external = false) => {
  const { ctx } = newMediumService(AssetService, { database: db, real: [AssetRepository], mock: [LoggingRepository] });
  const { user } = await ctx.newUser();
  const upload = join(base, 'upload', user.id);
  const encodedBase = join(base, 'encoded-video');
  await fs.mkdir(upload, { recursive: true });
  await fs.mkdir(join(encodedBase, user.id), { recursive: true });
  const getBase = StorageCore.getBaseFolder;
  const getFolder = StorageCore.getFolderLocation;
  const getLibrary = StorageCore.getLibraryFolder;
  vi.spyOn(StorageCore, 'getBaseFolder').mockImplementation((folder) =>
    folder === StorageFolder.EncodedVideo ? encodedBase : getBase(folder),
  );
  vi.spyOn(StorageCore, 'getFolderLocation').mockImplementation((folder, owner) =>
    folder === StorageFolder.Upload && owner === user.id ? upload : getFolder(folder, owner),
  );
  vi.spyOn(StorageCore, 'getLibraryFolder').mockImplementation((owner) =>
    owner.id === user.id ? upload : getLibrary(owner),
  );
  const { library } = external ? await ctx.newLibrary({ ownerId: user.id }) : { library: undefined };
  if (library) await new LibraryRepository(db).update(library.id, { importPaths: [upload] });
  const scope = library?.id ?? 'managed';
  const repo = new AssetRepository(db);
  const storage = new StorageRepository(ctx.getMock(LoggingRepository));
  const test = newTestService(AssetService, {
    asset: repo,
    access: new AccessRepository(db),
    assetJob: new AssetJobRepository(db),
    storage,
  });
  test.mocks.user.get.mockImplementation((id, options) => new UserRepository(db).get(id, options));
  const libraries = new LibraryRepository(db);
  test.mocks.library.get.mockImplementation((id, deleted) => libraries.get(id, deleted));
  test.mocks.library.getAll.mockImplementation(() => libraries.getAll());
  test.mocks.sharedSpace.getSpacePersonsForAsset.mockResolvedValue([]);
  test.mocks.event.emit.mockResolvedValue();
  test.mocks.user.updateUsage.mockResolvedValue();
  test.mocks.job.queue.mockResolvedValue();
  const auth = { ...authStub.user1, user: { ...authStub.user1.user, id: user.id } };
  const authorize = async () => {
    const identities = await collectRootIdentities([upload]);
    const proof = await evidence.install(user.id, scope, identities);
    await repo.setDeletionPolicy(user.id, scope, {
      enabled: true,
      roots: [upload],
      rootIdentities: identities,
      recoveryExpiresAt: new Date(proof.expiresAt),
      recoveryProof: proof.digest,
      authorizedBy: user.id,
    });
  };
  const pair = async () => {
    const jpgPath = join(upload, randomUUID() + '.jpg');
    await fs.writeFile(jpgPath, 'synthetic still ' + jpgPath);
    const { asset: jpg } = await ctx.newAsset({
      ownerId: user.id,
      libraryId: library?.id ?? null,
      isExternal: external,
      originalPath: jpgPath,
      type: AssetType.Image,
      visibility: AssetVisibility.Timeline,
      status: AssetStatus.Trashed,
      deletedAt: new Date(),
    });
    const { asset: mp4 } = await ctx.newAsset({
      ownerId: user.id,
      libraryId: library?.id ?? null,
      isExternal: external,
      originalPath: join(upload, 'unused-' + randomUUID() + '.mp4'),
      type: AssetType.Video,
      visibility: AssetVisibility.Hidden,
    });
    const motionPath = StorageCore.getAndroidMotionPath(mp4, mp4.id);
    await fs.mkdir(dirname(motionPath), { recursive: true });
    await fs.writeFile(motionPath, 'synthetic motion ' + mp4.id);
    await db.updateTable('asset').set({ originalPath: motionPath }).where('id', '=', mp4.id).execute();
    await db.updateTable('asset').set({ livePhotoVideoId: mp4.id }).where('id', '=', jpg.id).execute();
    return { jpg: { ...jpg, livePhotoVideoId: mp4.id }, mp4: { ...mp4, originalPath: motionPath } };
  };
  return { ctx, user, upload, encodedBase, repo, storage, auth, authorize, pair, scope, ...test };
};
type Fixture = Awaited<ReturnType<typeof fixture>>;
type Pair = Awaited<ReturnType<Fixture['pair']>>;
const receipts = (pair: Pair) =>
  db
    .selectFrom('asset_deletion_tombstone')
    .selectAll()
    .where('operationId', '=', pair.jpg.id)
    .orderBy('assetId')
    .execute();
const intact = async (pair: Pair) => {
  expect(await fs.readFile(pair.jpg.originalPath, 'utf8')).toContain('synthetic still');
  expect(await fs.readFile(pair.mp4.originalPath, 'utf8')).toContain('synthetic motion');
};
const complete = async (f: Fixture, pair: Pair) => {
  const result = await f.sut.permanentlyDelete(f.auth, [pair.jpg.id]);
  expect(result, JSON.stringify(result)).toEqual([{ id: pair.jpg.id, scope: f.scope, state: 'complete' }]);
  await expect(fs.readFile(pair.jpg.originalPath)).rejects.toHaveProperty('code', 'ENOENT');
  await expect(fs.readFile(pair.mp4.originalPath)).rejects.toHaveProperty('code', 'ENOENT');
  expect(await db.selectFrom('asset').select('id').where('id', 'in', [pair.jpg.id, pair.mp4.id]).execute()).toEqual([]);
  const stored = await receipts(pair);
  expect(stored.map(({ state }) => state)).toEqual(['complete', 'complete']);
};

describe('owner-scoped Live Photo originals across upload and encoded-video stores', () => {
  it('completes ordinary JPG deletion without authorizing the encoded-video root', async () => {
    const f = await fixture();
    await emulateNfsRootSquash(f.upload);
    await f.authorize();
    const originalPath = join(f.upload, 'ordinary.jpg');
    await fs.writeFile(originalPath, 'disposable ordinary photo');
    const { asset } = await f.ctx.newAsset({
      ownerId: f.user.id,
      originalPath,
      status: AssetStatus.Trashed,
      deletedAt: new Date(),
    });
    expect(await f.sut.permanentlyDelete(f.auth, [asset.id])).toEqual([
      { id: asset.id, scope: 'managed', state: 'complete' },
    ]);
    await expect(fs.readFile(originalPath)).rejects.toHaveProperty('code', 'ENOENT');
    const policy = await f.repo.getDeletionPolicy(f.user.id, 'managed');
    expect(policy?.roots).toEqual([f.upload]);
  });

  it('deletes both originals with upload-only authorization, preserving exact child proof and narrow policy', async () => {
    const f = await fixture();
    await emulateNfsRootSquash(f.upload);
    await f.authorize();
    const pair = await f.pair();
    await complete(f, pair);
    const stored = await receipts(pair);
    const child = stored.find(({ assetId }) => assetId === pair.mp4.id)!;
    expect(child.files).toHaveLength(1);
    expect(child.files[0].path).toBe(StorageCore.getAndroidMotionPath(pair.mp4, pair.mp4.id));
    expect(child.files[0].root).toBe(join(f.encodedBase, f.user.id));
    expect(child.files[0].rootIdentity.quarantineIdentity).toBeDefined();
    const policy = await f.repo.getDeletionPolicy(f.user.id, 'managed');
    expect(policy?.roots).toEqual([f.upload]);
    expect(policy?.rootIdentities.map(({ path }) => path)).toEqual([f.upload]);
  });

  it('reuses only a previously committed encoded quarantine for a second different Live Photo', async () => {
    const f = await fixture();
    await f.authorize();
    const first = await f.pair();
    const second = await f.pair();
    await complete(f, first);
    await complete(f, second);
    const firstReceipts = await receipts(first);
    const secondReceipts = await receipts(second);
    const firstChild = firstReceipts.find(({ assetId }) => assetId === first.mp4.id)!;
    const secondChild = secondReceipts.find(({ assetId }) => assetId === second.mp4.id)!;
    expect(secondChild.files[0].rootIdentity.quarantineIdentity).toEqual(
      firstChild.files[0].rootIdentity.quarantineIdentity,
    );
  });

  it('retries the deployed files-empty failed tombstones without direct journal edits', async () => {
    const f = await fixture();
    await f.authorize();
    const pair = await f.pair();
    const policy = await f.repo.getDeletionPolicy(f.user.id, 'managed');
    await expect(
      // Reproduce the old runtime's actual upload-only snapshot call, not a
      // fabricated error. The new runtime retries these unchanged receipts.
      f.repo.preparePermanentDeletion(pair.jpg.id, f.user.id, (path) => snapshotOriginal(path, policy!.rootIdentities)),
    ).rejects.toMatchObject({ code: 'ORIGINAL_OUTSIDE_AUTHORIZED_ROOT' });
    const failed = await receipts(pair);
    expect(failed).toHaveLength(2);
    expect(failed.map(({ state, files, errorCode }) => ({ state, files, errorCode }))).toEqual([
      { state: 'failed', files: [], errorCode: 'ORIGINAL_OUTSIDE_AUTHORIZED_ROOT' },
      { state: 'failed', files: [], errorCode: 'ORIGINAL_OUTSIDE_AUTHORIZED_ROOT' },
    ]);
    await intact(pair);
    await complete(f, pair);
  });

  it.each(['owner', 'library'] as const)(
    'rejects a child with another %s before either original changes',
    async (field) => {
      const f = await fixture();
      await f.authorize();
      const pair = await f.pair();
      const { user: another } = await f.ctx.newUser();
      const { library: anotherLibrary } = await f.ctx.newLibrary({ ownerId: f.user.id });
      const values = field === 'owner' ? { ownerId: another.id } : { libraryId: anotherLibrary.id };
      await db.updateTable('asset').set(values).where('id', '=', pair.mp4.id).execute();
      await expect(f.repo.preparePermanentDeletion(pair.jpg.id, f.user.id, snapshotOriginal)).rejects.toMatchObject({
        code: 'MOTION_SCOPE_MISMATCH',
      });
      await intact(pair);
      expect(await receipts(pair)).toEqual([]);
    },
  );

  it('rejects a motion asset linked by another still without deleting the selected JPG', async () => {
    const f = await fixture();
    await f.authorize();
    const pair = await f.pair();
    await f.ctx.newAsset({ ownerId: f.user.id, livePhotoVideoId: pair.mp4.id });
    await expect(f.repo.preparePermanentDeletion(pair.jpg.id, f.user.id, snapshotOriginal)).rejects.toBeDefined();
    await intact(pair);
    expect(await receipts(pair)).toEqual([]);
  });

  it.each(['asset', 'sidecar'] as const)('rejects a motion original shared as another %s', async (reference) => {
    const f = await fixture();
    await f.authorize();
    const pair = await f.pair();
    const { asset: other } = await f.ctx.newAsset({
      ownerId: f.user.id,
      originalPath: reference === 'asset' ? pair.mp4.originalPath : join(f.upload, 'other.jpg'),
    });
    if (reference === 'sidecar')
      await db
        .insertInto('asset_file')
        .values({ assetId: other.id, type: AssetFileType.Sidecar, path: pair.mp4.originalPath })
        .execute();
    await expect(f.repo.preparePermanentDeletion(pair.jpg.id, f.user.id, snapshotOriginal)).rejects.toMatchObject({
      code: 'ORIGINAL_SHARED_WITH_OTHER_ASSET',
    });
    await intact(pair);
  });

  it.each(['different-name', 'other-owner-root', 'outside-stores', 'traversal'] as const)(
    'rejects a linked MP4 at %s instead of the exact owner motion path',
    async (kind) => {
      const f = await fixture();
      await f.authorize();
      const pair = await f.pair();
      const original = pair.mp4.originalPath;
      const path =
        kind === 'different-name'
          ? join(dirname(original), 'guessed.mp4')
          : kind === 'other-owner-root'
            ? join(f.encodedBase, randomUUID(), 'foreign-MP.mp4')
            : kind === 'outside-stores'
              ? join(base, 'unrelated.mp4')
              : dirname(original) + '/nested/../' + original.split('/').at(-1);
      if (kind !== 'traversal') {
        await fs.mkdir(dirname(path), { recursive: true });
        await fs.rename(original, path);
      }
      await db.updateTable('asset').set({ originalPath: path }).where('id', '=', pair.mp4.id).execute();
      const result = await f.sut.permanentlyDelete(f.auth, [pair.jpg.id]);
      expect(result[0].state).not.toBe('complete');
      expect(await fs.readFile(pair.jpg.originalPath, 'utf8')).toContain('synthetic still');
      expect(await fs.readFile(kind === 'traversal' ? original : path, 'utf8')).toContain('synthetic motion');
    },
  );

  it('does not extend external-library authorization to managed encoded-video storage', async () => {
    const f = await fixture(true);
    await f.authorize();
    const pair = await f.pair();
    const result = await f.sut.permanentlyDelete(f.auth, [pair.jpg.id]);
    expect(result[0].state).not.toBe('complete');
    await intact(pair);
  });

  it('rejects an encoded-root ancestor symlink while preserving its outside target', async () => {
    const f = await fixture();
    await f.authorize();
    const pair = await f.pair();
    const moved = f.encodedBase + '.saved';
    await fs.rename(f.encodedBase, moved);
    await fs.symlink(moved, f.encodedBase);
    const result = await f.sut.permanentlyDelete(f.auth, [pair.jpg.id]);
    expect(result[0].state).not.toBe('complete');
    await intact(pair);
  });

  it('rejects a changed encoded-root inode after the snapshot without removing either original', async () => {
    const f = await fixture();
    await f.authorize();
    const pair = await f.pair();
    await f.repo.preparePermanentDeletion(pair.jpg.id, f.user.id, snapshotOriginal);
    const ownerRoot = join(f.encodedBase, f.user.id);
    await fs.rename(ownerRoot, ownerRoot + '.saved');
    await fs.mkdir(ownerRoot);
    await expect(f.repo.removeAuthorizedOriginals(pair.mp4.id, unlinkOriginal)).rejects.toBeDefined();
    expect(await fs.readFile(pair.jpg.originalPath, 'utf8')).toContain('synthetic still');
    expect(await fs.readFile(ownerRoot + '.saved' + pair.mp4.originalPath.slice(ownerRoot.length), 'utf8')).toContain(
      'synthetic motion',
    );
  });

  it('retries after temporary upload/NFS unavailability without authorizing another root', async () => {
    const f = await fixture();
    await emulateNfsRootSquash(f.upload);
    await f.authorize();
    const pair = await f.pair();
    const openActual = vi.mocked(fs.open).getMockImplementation()!;
    const open = vi.spyOn(fs, 'open').mockImplementation(async (path, flags, mode) => {
      if (String(path).endsWith('/upload'))
        throw Object.assign(new Error('Synthetic NFS timeout'), { code: 'ETIMEDOUT' });
      return openActual(path, flags, mode);
    });
    const result = await f.sut.permanentlyDelete(f.auth, [pair.jpg.id]);
    expect(result[0].state).not.toBe('complete');
    await intact(pair);
    open.mockImplementation(openActual);
    await complete(f, pair);
  });

  it('resumes after child row/file completion and a subsequent still unlink failure', async () => {
    const f = await fixture();
    await f.authorize();
    const pair = await f.pair();
    const unlink = f.storage.unlinkOriginal.bind(f.storage);
    let fail = true;
    vi.spyOn(f.storage, 'unlinkOriginal').mockImplementation(async (file, recheck) => {
      if (fail && file.path === pair.jpg.originalPath) throw new DeletionError('SYNTHETIC_STILL_IO_FAILURE');
      return unlink(file, recheck);
    });
    const result = await f.sut.permanentlyDelete(f.auth, [pair.jpg.id]);
    expect(result[0].state).toBe('failed');
    expect(await fs.readFile(pair.jpg.originalPath, 'utf8')).toContain('synthetic still');
    await expect(fs.readFile(pair.mp4.originalPath)).rejects.toHaveProperty('code', 'ENOENT');
    expect(await db.selectFrom('asset').select('id').where('id', '=', pair.mp4.id).executeTakeFirst()).toBeUndefined();
    fail = false;
    await complete(f, pair);
  });

  it('rejects a non-video asset even when its original has the exact motion pathname', async () => {
    const f = await fixture();
    await f.authorize();
    const pair = await f.pair();
    await db.updateTable('asset').set({ type: AssetType.Image }).where('id', '=', pair.mp4.id).execute();
    await expect(f.repo.preparePermanentDeletion(pair.jpg.id, f.user.id, snapshotOriginal)).rejects.toMatchObject({
      code: 'MOTION_SCOPE_MISMATCH',
    });
    await intact(pair);
  });

  it('rejects a replaced motion inode after preparation and preserves the replacement and original', async () => {
    const f = await fixture();
    await f.authorize();
    const pair = await f.pair();
    await f.repo.preparePermanentDeletion(pair.jpg.id, f.user.id, snapshotOriginal);
    await fs.rename(pair.mp4.originalPath, pair.mp4.originalPath + '.saved');
    await fs.writeFile(pair.mp4.originalPath, 'synthetic replacement must survive');
    await expect(f.repo.removeAuthorizedOriginals(pair.mp4.id, unlinkOriginal)).rejects.toMatchObject({
      code: 'ORIGINAL_IDENTITY_CHANGED',
    });
    expect(await fs.readFile(pair.jpg.originalPath, 'utf8')).toContain('synthetic still');
    expect(await fs.readFile(pair.mp4.originalPath, 'utf8')).toBe('synthetic replacement must survive');
    expect(await fs.readFile(pair.mp4.originalPath + '.saved', 'utf8')).toContain('synthetic motion');
  });

  it.each([false, true])(
    'rejects a second still linked after preparation before any child capture (encoded=%s)',
    async (encoded) => {
      const f = await fixture();
      await f.authorize();
      const pair = await f.pair();
      if (!encoded) {
        const inside = join(f.upload, 'ordinary-live-video.mov');
        await fs.writeFile(inside, 'synthetic motion inside policy');
        await db.updateTable('asset').set({ originalPath: inside }).where('id', '=', pair.mp4.id).execute();
        pair.mp4.originalPath = inside;
      }
      await f.repo.preparePermanentDeletion(pair.jpg.id, f.user.id, snapshotOriginal);
      await f.ctx.newAsset({ ownerId: f.user.id, livePhotoVideoId: pair.mp4.id });
      await expect(f.repo.removeAuthorizedOriginals(pair.mp4.id, unlinkOriginal)).rejects.toMatchObject({
        code: 'ORIGINAL_SHARED_WITH_OTHER_ASSET',
      });
      await intact(pair);
    },
  );

  it('retains normal linking but refuses to link a resource after irreversible deletion was claimed', async () => {
    const f = await fixture();
    await f.authorize();
    const pair = await f.pair();
    // Reaffirming a live relationship still follows the existing update API.
    expect(await f.repo.update({ id: pair.jpg.id, livePhotoVideoId: pair.mp4.id })).toBeDefined();
    await f.repo.preparePermanentDeletion(pair.jpg.id, f.user.id, snapshotOriginal);
    const { asset: later } = await f.ctx.newAsset({ ownerId: f.user.id });
    await expect(f.repo.update({ id: later.id, livePhotoVideoId: pair.mp4.id })).rejects.toMatchObject({
      code: 'MOTION_SCOPE_MISMATCH',
    });
    await intact(pair);
    await complete(f, pair);
  });

  it('a link started during physical deletion cannot commit a new reference after files are removed', async () => {
    const f = await fixture();
    await f.authorize();
    const pair = await f.pair();
    const { asset: later } = await f.ctx.newAsset({ ownerId: f.user.id });
    await f.repo.preparePermanentDeletion(pair.jpg.id, f.user.id, snapshotOriginal);
    let linking: Promise<unknown> | undefined;
    await f.repo.removeAuthorizedOriginals(pair.mp4.id, (proof, recheck) =>
      unlinkOriginal(proof, async () => {
        await recheck();
        linking ??= f.repo
          .update({ id: later.id, livePhotoVideoId: pair.mp4.id })
          .then(() => 'unexpected successful link')
          .catch((error: unknown) => error);
      }),
    );
    expect(await linking).toMatchObject({ code: 'MOTION_SCOPE_MISMATCH' });
    expect(
      await db.selectFrom('asset').select('livePhotoVideoId').where('id', '=', later.id).executeTakeFirst(),
    ).toEqual({
      livePhotoVideoId: null,
    });
    await complete(f, pair);
  });

  it('refuses a substituted previously registered SSD quarantine for a different Live Photo', async () => {
    const f = await fixture();
    await f.authorize();
    const first = await f.pair();
    await complete(f, first);
    const second = await f.pair();
    const quarantine = join(f.encodedBase, f.user.id, '.gallery-deletion-quarantine');
    await fs.rename(quarantine, quarantine + '.forensic');
    await fs.mkdir(quarantine, { mode: 0o700 });
    await f.repo.preparePermanentDeletion(second.jpg.id, f.user.id, snapshotOriginal);
    await expect(f.repo.removeAuthorizedOriginals(second.mp4.id, unlinkOriginal)).rejects.toMatchObject({
      code: 'DELETION_QUARANTINE_CONFLICT',
    });
    await intact(second);
  });

  it('concurrent different Live Photos reuse one trusted SSD quarantine without duplicate capture', async () => {
    const f = await fixture();
    await f.authorize();
    const first = await f.pair();
    const second = await f.pair();
    await Promise.all([complete(f, first), complete(f, second)]);
    const firstReceipts = await receipts(first);
    const secondReceipts = await receipts(second);
    const a = firstReceipts.find(({ assetId }) => assetId === first.mp4.id)!;
    const b = secondReceipts.find(({ assetId }) => assetId === second.mp4.id)!;
    expect(a.files[0].rootIdentity.quarantineIdentity).toEqual(b.files[0].rootIdentity.quarantineIdentity);
  });

  it('never adopts an unregistered encoded quarantine merely because it is private and owner-matching', async () => {
    const f = await fixture();
    await f.authorize();
    const pair = await f.pair();
    const quarantine = join(f.encodedBase, f.user.id, '.gallery-deletion-quarantine');
    await fs.mkdir(quarantine, { mode: 0o700 });
    await f.repo.preparePermanentDeletion(pair.jpg.id, f.user.id, snapshotOriginal);
    await expect(f.repo.removeAuthorizedOriginals(pair.mp4.id, unlinkOriginal)).rejects.toMatchObject({
      code: 'DELETION_QUARANTINE_CONFLICT',
    });
    await intact(pair);
    expect(await fs.readdir(quarantine)).toEqual([]);
  });

  it('enforces owner revocation for the linked SSD original as well as the NFS still', async () => {
    const f = await fixture();
    await f.authorize();
    const pair = await f.pair();
    await f.repo.preparePermanentDeletion(pair.jpg.id, f.user.id, snapshotOriginal);
    await f.sut.setManagedDeletionConsent(f.auth, false);
    await expect(f.repo.removeAuthorizedOriginals(pair.mp4.id, unlinkOriginal)).rejects.toMatchObject({
      code: 'LIBRARY_DELETION_NOT_AUTHORIZED',
    });
    await intact(pair);
  });

  it('defers an out-of-order parent worker while the motion receipt is still pending', async () => {
    const f = await fixture();
    await f.authorize();
    const pair = await f.pair();
    await f.repo.preparePermanentDeletion(pair.jpg.id, f.user.id, snapshotOriginal);
    expect(await f.sut.handleAssetDeletion({ id: pair.jpg.id, deleteOnDisk: true, deletionId: pair.jpg.id })).toBe(
      JobStatus.Skipped,
    );
    await intact(pair);
    expect(await db.selectFrom('asset').select('id').where('id', '=', pair.jpg.id).executeTakeFirst()).toBeDefined();
    await complete(f, pair);
  });

  it('recovers an interrupted SSD capture through the durable receipt before finishing the JPG', async () => {
    const f = await fixture();
    await f.authorize();
    const pair = await f.pair();
    await f.repo.preparePermanentDeletion(pair.jpg.id, f.user.id, snapshotOriginal);
    let checks = 0;
    await expect(
      f.repo.removeAuthorizedOriginals(pair.mp4.id, (proof, recheck) =>
        unlinkOriginal(proof, async () => {
          await recheck();
          if (++checks === 2) throw new DeletionError('SYNTHETIC_INTERRUPT_AFTER_CAPTURE');
        }),
      ),
    ).rejects.toMatchObject({ code: 'SYNTHETIC_INTERRUPT_AFTER_CAPTURE' });
    const pending = await receipts(pair);
    const child = pending.find(({ assetId }) => assetId === pair.mp4.id)!;
    expect(child.state).toBe('failed');
    expect(await fs.readFile(pair.jpg.originalPath, 'utf8')).toContain('synthetic still');
    const captured = join(child.files[0].root, '.gallery-deletion-quarantine', child.files[0].quarantineName);
    expect(await fs.readFile(captured, 'utf8')).toContain('synthetic motion');
    await complete(f, pair);
    await expect(fs.readFile(captured)).rejects.toHaveProperty('code', 'ENOENT');
  });

  it('failed pair projects only the still in owner Trash and never a second gray motion tile', async () => {
    const f = await fixture();
    await f.authorize();
    const pair = await f.pair();
    await expect(
      f.repo.preparePermanentDeletion(pair.jpg.id, f.user.id, (path, roots) => {
        if (path === pair.mp4.originalPath) throw new DeletionError('ORIGINAL_OUTSIDE_AUTHORIZED_ROOT');
        return snapshotOriginal(path, roots);
      }),
    ).rejects.toBeDefined();
    const trash = await f.repo.getOwnerTrash(f.user.id);
    expect(trash.map(({ id }) => id)).toEqual([pair.jpg.id]);
    expect(await f.repo.getTimeBuckets({ ownerId: f.user.id, isTrashed: true }, f.auth)).toEqual([
      expect.objectContaining({ count: 1 }),
    ]);
    expect(await f.repo.getTimeBuckets({ ownerId: f.user.id }, f.auth)).toEqual([]);
    await intact(pair);
  });
});
