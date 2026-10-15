import { Kysely } from 'kysely';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { StorageCore } from 'src/cores/storage.core.js';
import { AssetStatus, AssetType, AssetVisibility, StorageFolder } from 'src/enum.js';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { LibraryRepository } from 'src/repositories/library.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { SyncRepository } from 'src/repositories/sync.repository.js';
import { DB } from 'src/schema/index.js';
import { AssetService } from 'src/services/asset.service.js';
import {
  DeletionError,
  collectRootIdentities,
  snapshotOriginal,
  unlinkOriginal,
} from 'src/utils/authorized-deletion.js';
import { newMediumService } from 'test/medium.factory.js';
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
  root = await mkdtemp(join(tmpdir(), 'gallery-livephoto-projection-'));
  StorageCore.setMediaLocation(root);
  evidence = await createTestRecoveryEvidenceStore();
});
afterEach(async () => {
  vi.restoreAllMocks();
  await evidence.cleanup();
  await rm(root, { recursive: true, force: true });
});

async function fixture(external: boolean) {
  const { ctx } = newMediumService(AssetService, { database: db, real: [AssetRepository], mock: [LoggingRepository] });
  const { user } = await ctx.newUser();
  const actualFolder = StorageCore.getFolderLocation;
  const actualLibrary = StorageCore.getLibraryFolder;
  vi.spyOn(StorageCore, 'getFolderLocation').mockImplementation((folder, owner) =>
    folder === StorageFolder.Upload && owner === user.id ? root : actualFolder(folder, owner),
  );
  vi.spyOn(StorageCore, 'getLibraryFolder').mockImplementation((owner) =>
    owner.id === user.id ? root : actualLibrary(owner),
  );
  const { library } = external ? await ctx.newLibrary({ ownerId: user.id }) : { library: undefined };
  if (library) await new LibraryRepository(db).update(library.id, { importPaths: [root] });
  const scope = library?.id ?? 'managed';
  const stillPath = join(root, 'synthetic-still.jpg');
  const motionPath = join(root, 'synthetic-motion.mov');
  await writeFile(stillPath, 'disposable live photo still');
  await writeFile(motionPath, 'disposable live photo motion');
  const { asset: motion } = await ctx.newAsset({
    ownerId: user.id,
    libraryId: library?.id ?? null,
    isExternal: external,
    originalPath: motionPath,
    type: AssetType.Video,
    visibility: AssetVisibility.Hidden,
  });
  const trashedAt = new Date('2026-10-02T12:00:00Z');
  const { asset: still } = await ctx.newAsset({
    ownerId: user.id,
    libraryId: library?.id ?? null,
    isExternal: external,
    originalPath: stillPath,
    livePhotoVideoId: motion.id,
    status: AssetStatus.Trashed,
    deletedAt: trashedAt,
  });
  const repo = new AssetRepository(db);
  const identities = await collectRootIdentities([root]);
  const proof = await evidence.install(user.id, scope, identities);
  await repo.setDeletionPolicy(user.id, scope, {
    enabled: true,
    roots: [root],
    rootIdentities: identities,
    authorizedBy: user.id,
    recoveryExpiresAt: new Date(proof.expiresAt),
    recoveryProof: proof.digest,
  });
  return { ctx, user, repo, still, motion, trashedAt };
}

async function syncRows(ownerId: string) {
  return Array.fromAsync(
    new SyncRepository(db).asset.getUpserts({ userId: ownerId, nowId: 'ffffffff-ffff-7fff-bfff-ffffffffffff' }),
  );
}

describe.each([false, true])('Live Photo projects one logical Trash card (external=%s)', (external) => {
  it('keeps the hidden motion out of Trash after a failed permanent-deletion preparation', async () => {
    const f = await fixture(external);
    const initial = await syncRows(f.user.id);
    expect(initial.find((row) => row.id === f.motion.id)).toMatchObject({
      visibility: AssetVisibility.Hidden,
      deletedAt: null,
    });
    await expect(
      f.repo.preparePermanentDeletion(f.still.id, f.user.id, () =>
        Promise.reject(new DeletionError('ORIGINAL_OUTSIDE_AUTHORIZED_ROOT')),
      ),
    ).rejects.toMatchObject({ code: 'ORIGINAL_OUTSIDE_AUTHORIZED_ROOT' });

    expect(await f.repo.getOwnerTrash(f.user.id)).toEqual([{ id: f.still.id, libraryId: f.still.libraryId }]);
    const synced = await syncRows(f.user.id);
    expect(synced.find((row) => row.id === f.still.id)).toMatchObject({
      deletedAt: f.trashedAt,
      livePhotoVideoId: f.motion.id,
    });
    expect(synced.find((row) => row.id === f.motion.id)).toMatchObject({
      visibility: AssetVisibility.Hidden,
      deletedAt: null,
    });
    expect(await db.selectFrom('asset').select(['id', 'status']).where('ownerId', '=', f.user.id).execute()).toEqual(
      expect.arrayContaining([
        { id: f.still.id, status: AssetStatus.Deleted },
        { id: f.motion.id, status: AssetStatus.Deleted },
      ]),
    );
    const receipts = await db
      .selectFrom('asset_deletion_tombstone')
      .select(['operationId', 'state', 'errorCode'])
      .where('operationId', '=', f.still.id)
      .execute();
    expect(receipts).toHaveLength(2);
    for (const receipt of receipts)
      expect(receipt).toEqual({
        operationId: f.still.id,
        state: 'failed',
        errorCode: 'ORIGINAL_OUTSIDE_AUTHORIZED_ROOT',
      });
    expect(await readFile(f.still.originalPath, 'utf8')).toBe('disposable live photo still');
    expect(await readFile(f.motion.originalPath, 'utf8')).toBe('disposable live photo motion');
  });

  it('repairs the old failed companion timestamp through ordinary retry and completes both originals', async () => {
    const f = await fixture(external);
    await expect(
      f.repo.preparePermanentDeletion(f.still.id, f.user.id, () =>
        Promise.reject(new DeletionError('ORIGINAL_OUTSIDE_AUTHORIZED_ROOT')),
      ),
    ).rejects.toBeDefined();
    // Disposable fixture reproduces the previously committed pair-wide timestamp.
    await db.updateTable('asset').set({ deletedAt: f.trashedAt }).where('id', '=', f.motion.id).execute();
    const { asset: unrelated } = await f.ctx.newAsset({
      ownerId: f.user.id,
      type: AssetType.Video,
      visibility: AssetVisibility.Hidden,
      status: AssetStatus.Trashed,
      deletedAt: f.trashedAt,
    });
    await f.repo.preparePermanentDeletion(f.still.id, f.user.id, snapshotOriginal);
    const synced = await syncRows(f.user.id);
    expect(synced.find((row) => row.id === f.motion.id)).toMatchObject({
      visibility: AssetVisibility.Hidden,
      deletedAt: null,
    });
    expect(synced.find((row) => row.id === unrelated.id)).toMatchObject({ deletedAt: f.trashedAt });
    const trash = await f.repo.getOwnerTrash(f.user.id);
    expect(trash.map(({ id }) => id).sort()).toEqual([f.still.id, unrelated.id].sort());
    for (const target of [f.motion, f.still]) {
      expect(await f.repo.removeAuthorizedOriginals(target.id, unlinkOriginal)).toBe(true);
      expect(await f.repo.removeForDeletion(target)).toBe(true);
      await expect(readFile(target.originalPath)).rejects.toHaveProperty('code', 'ENOENT');
    }
    const after = await syncRows(f.user.id);
    expect(after.some((row) => row.id === f.still.id || row.id === f.motion.id)).toBe(false);
    expect(await f.repo.getDeletionReceipt(f.user.id, f.still.id)).toMatchObject({ state: 'complete' });
    expect(await f.repo.getDeletionReceipt(f.user.id, f.motion.id)).toMatchObject({ state: 'complete' });
  });
});
