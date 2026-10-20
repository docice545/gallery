import { Kysely } from 'kysely';
import { mkdir, mkdtemp, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { StorageCore } from 'src/cores/storage.core.js';
import { AssetStatus, ChecksumAlgorithm, JobStatus, StorageFolder } from 'src/enum.js';
import { AccessRepository } from 'src/repositories/access.repository.js';
import { AssetJobRepository } from 'src/repositories/asset-job.repository.js';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { LibraryRepository } from 'src/repositories/library.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { StorageRepository } from 'src/repositories/storage.repository.js';
import { TrashRepository } from 'src/repositories/trash.repository.js';
import { UserRepository } from 'src/repositories/user.repository.js';
import { DB } from 'src/schema/index.js';
import { AssetService } from 'src/services/asset.service.js';
import { DeletionError, snapshotOriginal, unlinkOriginal } from 'src/utils/authorized-deletion.js';
import { newMediumService } from 'test/medium.factory.js';
import { factory } from 'test/small.factory.js';
import { getKyselyDB, newTestService } from 'test/utils.js';

let db: Kysely<DB>;
let base: string;
beforeAll(async () => {
  db = await getKyselyDB();
});
afterAll(async () => {
  await db.destroy();
});
beforeEach(async () => {
  base = await mkdtemp(join(tmpdir(), 'gallery-build11-lifecycle-'));
});
afterEach(async () => {
  vi.restoreAllMocks();
  await rm(base, { recursive: true, force: true });
});

const fixture = async (external = false) => {
  const { ctx } = newMediumService(AssetService, { database: db, real: [AssetRepository], mock: [LoggingRepository] });
  const { user } = await ctx.newUser();
  const root = join(base, user.id);
  await mkdir(root);
  const { library } = external ? await ctx.newLibrary({ ownerId: user.id }) : { library: undefined };
  if (library) await new LibraryRepository(db).update(library.id, { importPaths: [root] });
  const originalPath = join(root, 'synthetic.heic');
  await writeFile(originalPath, 'disposable original ' + user.id);
  const { asset } = await ctx.newAsset({
    ownerId: user.id,
    libraryId: library?.id ?? null,
    isExternal: external,
    originalPath,
    checksumAlgorithm: external ? ChecksumAlgorithm.sha1Path : ChecksumAlgorithm.sha1File,
    status: AssetStatus.Trashed,
    deletedAt: new Date('2026-01-01T00:00:00Z'),
  });
  const repo = new AssetRepository(db);
  const storage = new StorageRepository(ctx.getMock(LoggingRepository));
  const test = newTestService(AssetService, {
    asset: repo,
    access: new AccessRepository(db),
    assetJob: new AssetJobRepository(db),
    storage,
  });
  const users = new UserRepository(db);
  const libraries = new LibraryRepository(db);
  test.mocks.user.get.mockImplementation((id, options) => users.get(id, options));
  test.mocks.library.get.mockImplementation((id, includeDeleted) => libraries.get(id, includeDeleted));
  test.mocks.library.getAll.mockImplementation(() => libraries.getAll());
  test.mocks.sharedSpace.getSpacePersonsForAsset.mockResolvedValue([]);
  test.mocks.event.emit.mockResolvedValue();
  test.mocks.user.updateUsage.mockResolvedValue();
  test.mocks.job.queue.mockResolvedValue();
  const actualFolder = StorageCore.getFolderLocation;
  const actualLibrary = StorageCore.getLibraryFolder;
  vi.spyOn(StorageCore, 'getFolderLocation').mockImplementation((folder, owner) =>
    folder === StorageFolder.Upload && owner === user.id ? root : actualFolder(folder, owner),
  );
  vi.spyOn(StorageCore, 'getLibraryFolder').mockImplementation((owner) =>
    owner.id === user.id ? root : actualLibrary(owner),
  );
  return {
    ctx,
    user,
    root,
    asset,
    repo,
    storage,
    library,
    scope: library?.id ?? 'managed',
    auth: factory.auth({ user }),
    ...test,
  };
};

describe('Build11 ordinary owner deletion with real PostgreSQL and synthetic filesystem media', () => {
  it('managed owner can delete without recovery evidence and durable receipt prevents restart/reimport', async () => {
    const f = await fixture();
    expect(await f.repo.getDeletionPolicy(f.user.id, 'managed')).toBeUndefined();
    expect(await f.sut.permanentlyDelete(f.auth, [f.asset.id])).toEqual([
      { id: f.asset.id, scope: 'managed', state: 'complete' },
    ]);
    await expect(readFile(f.asset.originalPath)).rejects.toHaveProperty('code', 'ENOENT');
    expect(await new AssetRepository(db).getDeletionReceipt(f.user.id, f.asset.id)).toMatchObject({
      state: 'complete',
    });
    await expect(
      f.ctx.newAsset({ ownerId: f.user.id, checksum: f.asset.checksum, checksumAlgorithm: f.asset.checksumAlgorithm }),
    ).rejects.toHaveProperty('constraint_name', 'asset_deletion_tombstone_identity');
    expect(await f.sut.permanentlyDelete(f.auth, [f.asset.id])).toEqual([
      { id: f.asset.id, scope: 'managed', state: 'complete' },
    ]);
  });

  it('external is read-only by default and becomes writable only through its owner exact scope consent', async () => {
    const f = await fixture(true);
    expect(await f.sut.permanentlyDelete(f.auth, [f.asset.id])).toEqual([
      { id: f.asset.id, scope: f.scope, state: 'blocked', code: 'LIBRARY_DELETION_NOT_AUTHORIZED' },
    ]);
    expect(await readFile(f.asset.originalPath, 'utf8')).toContain('disposable');
    await f.sut.setLibraryDeletionConsent(f.auth, f.scope, true);
    expect(await f.repo.getDeletionPolicy(f.user.id, f.scope)).toMatchObject({
      enabled: true,
      authorizationMode: 'storage',
      authorizedBy: f.user.id,
      recoveryProof: '',
    });
    expect(await f.sut.permanentlyDelete(f.auth, [f.asset.id])).toEqual([
      { id: f.asset.id, scope: f.scope, state: 'complete' },
    ]);
    await expect(readFile(f.asset.originalPath)).rejects.toHaveProperty('code', 'ENOENT');
    expect(await f.repo.filterNewExternalAssetPaths(f.scope, [f.asset.originalPath])).toEqual([]);
  });

  it('administrator status cannot consent to another owner external scope', async () => {
    const f = await fixture(true);
    const { user: other } = await f.ctx.newUser({ isAdmin: true });
    await expect(f.sut.setLibraryDeletionConsent(factory.auth({ user: other }), f.scope, true)).rejects.toThrow();
    expect(await f.repo.getDeletionPolicy(f.user.id, f.scope)).toBeUndefined();
    expect(await readFile(f.asset.originalPath, 'utf8')).toContain('disposable');
  });

  it('mixed managed/external scope preflight preserves every original when external consent is absent', async () => {
    const f = await fixture();
    const externalRoot = join(base, 'external');
    await mkdir(externalRoot);
    const { library } = await f.ctx.newLibrary({ ownerId: f.user.id });
    await new LibraryRepository(db).update(library.id, { importPaths: [externalRoot] });
    const externalPath = join(externalRoot, 'synthetic-video.mov');
    await writeFile(externalPath, 'external disposable video');
    const { asset: external } = await f.ctx.newAsset({
      ownerId: f.user.id,
      libraryId: library.id,
      isExternal: true,
      originalPath: externalPath,
      status: AssetStatus.Trashed,
      deletedAt: new Date(),
    });
    const result = await f.sut.permanentlyDelete(f.auth, [f.asset.id, external.id]);
    expect(result).toEqual([
      { id: f.asset.id, scope: 'managed', state: 'blocked', code: 'DELETION_BATCH_NOT_AUTHORIZED' },
      { id: external.id, scope: library.id, state: 'blocked', code: 'LIBRARY_DELETION_NOT_AUTHORIZED' },
    ]);
    expect(await readFile(f.asset.originalPath, 'utf8')).toContain('disposable');
    expect(await readFile(externalPath, 'utf8')).toBe('external disposable video');
    expect(await f.repo.getDeletionReceipt(f.user.id, f.asset.id)).toBeUndefined();
  });

  it('explicit managed revocation cannot be overwritten by default policy creation', async () => {
    const f = await fixture();
    await f.sut.setManagedDeletionConsent(f.auth, false);
    const results = await f.sut.permanentlyDelete(f.auth, [f.asset.id]);
    expect(results[0]).toMatchObject({
      state: 'blocked',
      code: 'LIBRARY_DELETION_NOT_AUTHORIZED',
    });
    expect(await f.repo.getDeletionPolicy(f.user.id, 'managed')).toMatchObject({ enabled: false });
    expect(await readFile(f.asset.originalPath, 'utf8')).toContain('disposable');
  });

  it('external root replacement is refused after owner consent without touching the replacement', async () => {
    const f = await fixture(true);
    await f.sut.setLibraryDeletionConsent(f.auth, f.scope, true);
    await rename(f.root, f.root + '.saved');
    await mkdir(f.root);
    await writeFile(f.asset.originalPath, 'replacement must survive');
    const results = await f.sut.permanentlyDelete(f.auth, [f.asset.id]);
    expect(results[0]).toMatchObject({
      state: 'blocked',
      code: 'DELETION_ROOT_CHANGED',
    });
    expect(await readFile(f.asset.originalPath, 'utf8')).toBe('replacement must survive');
    expect(await readFile(join(f.root + '.saved', 'synthetic.heic'), 'utf8')).toContain('disposable');
  });

  it.each(['edited', 'deleted'] as const)(
    'external owner can revoke a %s library grant without replacing its bound identity or receipts',
    async (mutation) => {
      const f = await fixture(true);
      await f.sut.setLibraryDeletionConsent(f.auth, f.scope, true);
      const before = await f.repo.getDeletionPolicy(f.user.id, f.scope);
      expect(before?.enabled).toBe(true);
      const receipts = await db.selectFrom('asset_deletion_tombstone').selectAll().execute();
      const library = new LibraryRepository(db);
      if (mutation === 'edited') {
        await library.update(f.scope, { importPaths: [join(base, 'unavailable-replacement')] });
      } else {
        await library.softDelete(f.scope);
      }

      await f.sut.setLibraryDeletionConsent(f.auth, f.scope, false);

      const after = await f.repo.getDeletionPolicy(f.user.id, f.scope);
      expect(after).toEqual({ ...before, enabled: false, updatedAt: after!.updatedAt });
      expect(await db.selectFrom('asset_deletion_tombstone').selectAll().execute()).toEqual(receipts);
      expect(await readFile(f.asset.originalPath, 'utf8')).toContain('disposable');
      const result = await f.sut.permanentlyDelete(f.auth, [f.asset.id]);
      expect(result[0]).toMatchObject({ state: 'blocked', code: 'LIBRARY_DELETION_NOT_AUTHORIZED' });
      expect(await readFile(f.asset.originalPath, 'utf8')).toContain('disposable');
    },
  );

  it('retention cutoff cannot create intent for restored/retrashed assets or offline index tombstones', async () => {
    const f = await fixture(true);
    await f.sut.setLibraryDeletionConsent(f.auth, f.scope, true);
    expect(await new TrashRepository(db).restoreAll([f.asset.id])).toEqual([f.asset.id]);
    await f.repo.markDeletionState([f.asset.id], {
      status: AssetStatus.Trashed,
      deletedAt: new Date('2026-10-12T00:00:00Z'),
    });
    await expect(
      f.repo.preparePermanentDeletion(f.asset.id, f.user.id, snapshotOriginal, new Date('2026-09-01T00:00:00Z')),
    ).rejects.toMatchObject({ code: 'ASSET_NOT_IN_TRASH' });
    const { asset: offline } = await f.ctx.newAsset({
      ownerId: f.user.id,
      libraryId: f.library!.id,
      isExternal: true,
      isOffline: true,
      status: AssetStatus.Active,
      deletedAt: new Date('2020-01-01'),
    });
    const expired = [];
    for await (const item of f.repo.streamExpiredTrash(new Date('2026-09-01'))) expired.push(item.id);
    expect(expired).not.toContain(f.asset.id);
    expect(expired).not.toContain(offline.id);
    expect(await f.repo.getDeletionReceipt(f.user.id, f.asset.id)).toBeUndefined();
  });

  it('interruption after capture retains durable file and safe retry finishes only the original', async () => {
    const f = await fixture(true);
    await f.sut.setLibraryDeletionConsent(f.auth, f.scope, true);
    await f.repo.preparePermanentDeletion(f.asset.id, f.user.id, snapshotOriginal);
    let calls = 0;
    await expect(
      f.repo.removeAuthorizedOriginals(f.asset.id, (file, recheck) =>
        unlinkOriginal(file, async () => {
          await recheck();
          if (++calls === 2) throw new DeletionError('SYNTHETIC_INTERRUPTED');
        }),
      ),
    ).rejects.toMatchObject({ code: 'SYNTHETIC_INTERRUPTED' });
    const receipt = await db
      .selectFrom('asset_deletion_tombstone')
      .selectAll()
      .where('assetId', '=', f.asset.id)
      .executeTakeFirstOrThrow();
    expect(receipt.state).toBe('failed');
    const quarantineDirectory = receipt.files[0].rootIdentity.quarantineDirectory ?? '.gallery-deletion-quarantine';
    expect(await readFile(join(f.root, quarantineDirectory, receipt.files[0].quarantineName), 'utf8')).toContain(
      'disposable',
    );
    expect(await new AssetRepository(db).removeAuthorizedOriginals(f.asset.id, unlinkOriginal)).toBe(true);
    expect(await new AssetRepository(db).removeForDeletion(f.asset)).toBe(true);
    expect(await f.repo.getDeletionReceipt(f.user.id, f.asset.id)).toMatchObject({ state: 'complete' });
  });

  it('shared originals belonging to another user are never physically deleted', async () => {
    const f = await fixture();
    const { user: other } = await f.ctx.newUser();
    const { asset: reference } = await f.ctx.newAsset({ ownerId: other.id, originalPath: f.asset.originalPath });
    const results = await f.sut.permanentlyDelete(f.auth, [f.asset.id]);
    expect(results[0]).toMatchObject({
      state: 'blocked',
      code: 'ORIGINAL_SHARED_WITH_OTHER_ASSET',
    });
    expect(await readFile(f.asset.originalPath, 'utf8')).toContain('disposable');
    expect(await db.selectFrom('asset').select('id').where('id', '=', reference.id).executeTakeFirst()).toBeDefined();
  });

  it('interrupted preparation with no file proofs resumes only its durable receipt through the native worker', async () => {
    const f = await fixture();
    await f.sut.setManagedDeletionConsent(f.auth, true);
    await expect(
      f.repo.preparePermanentDeletion(f.asset.id, f.user.id, () =>
        Promise.reject(new DeletionError('SYNTHETIC_HASH_INTERRUPTION')),
      ),
    ).rejects.toMatchObject({ code: 'SYNTHETIC_HASH_INTERRUPTION' });
    const receipt = await db
      .selectFrom('asset_deletion_tombstone')
      .selectAll()
      .where('assetId', '=', f.asset.id)
      .executeTakeFirstOrThrow();
    expect(receipt).toMatchObject({ state: 'failed', files: [] });
    expect(await readFile(f.asset.originalPath, 'utf8')).toContain('disposable');
    expect(await f.sut.handleAssetDeletion({ id: f.asset.id, deletionId: f.asset.id, deleteOnDisk: true })).toBe(
      JobStatus.Success,
    );
    expect(await f.repo.getDeletionReceipt(f.user.id, f.asset.id)).toMatchObject({ state: 'complete' });
    await expect(readFile(f.asset.originalPath)).rejects.toHaveProperty('code', 'ENOENT');
    expect(await f.sut.handleAssetDeletion({ id: f.asset.id, deletionId: f.asset.id, deleteOnDisk: true })).toBe(
      JobStatus.Skipped,
    );
  });

  it('upstream force DELETE remains owner-scoped for Active managed assets', async () => {
    const f = await fixture();
    await db
      .updateTable('asset')
      .set({ status: AssetStatus.Active, deletedAt: null })
      .where('id', '=', f.asset.id)
      .execute();
    await f.sut.deleteAll(f.auth, { ids: [f.asset.id], force: true });
    expect(await f.repo.getDeletionReceipt(f.user.id, f.asset.id)).toMatchObject({ state: 'complete' });
    await expect(readFile(f.asset.originalPath)).rejects.toHaveProperty('code', 'ENOENT');
  });
});
