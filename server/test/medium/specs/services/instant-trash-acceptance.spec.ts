import { Kysely } from 'kysely';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { StorageCore } from 'src/cores/storage.core.js';
import {
  AssetStatus,
  AssetType,
  AssetVisibility,
  ChecksumAlgorithm,
  StorageFolder,
  SyncEntityType,
  SyncRequestType,
  TimeBucketSize,
} from 'src/enum.js';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { LibraryRepository } from 'src/repositories/library.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { TrashRepository } from 'src/repositories/trash.repository.js';
import { DB } from 'src/schema/index.js';
import { AssetService } from 'src/services/asset.service.js';
import { collectRootIdentities } from 'src/utils/authorized-deletion.js';
import { authStub } from 'test/fixtures/auth.stub.js';
import { SyncTestContext, newMediumService } from 'test/medium.factory.js';
import { factory } from 'test/small.factory.js';
import { getKyselyDB } from 'test/utils.js';

let db: Kysely<DB>;
let directory: string;
let previousMediaLocation: string | undefined;

beforeAll(async () => {
  db = await getKyselyDB();
  try {
    previousMediaLocation = StorageCore.getMediaLocation();
  } catch {
    // Each spec has an isolated module graph; an unset media location is normal.
  }
});
afterAll(async () => {
  if (previousMediaLocation !== undefined) StorageCore.setMediaLocation(previousMediaLocation);
  await db.destroy();
});
beforeEach(async () => {
  directory = await mkdtemp(join(tmpdir(), 'foto-instant-trash-pg-'));
});
afterEach(async () => {
  vi.restoreAllMocks();
  await rm(directory, { recursive: true, force: true });
});

const fixture = async (external = false) => {
  const { ctx } = newMediumService(AssetService, { database: db, real: [AssetRepository], mock: [LoggingRepository] });
  StorageCore.setMediaLocation(directory);
  const { user } = await ctx.newUser();
  const folder = StorageCore.getFolderLocation(StorageFolder.Upload, user.id);
  await mkdir(folder, { recursive: true });
  const libraryFixture = external ? await ctx.newLibrary({ ownerId: user.id }) : undefined;
  const library = libraryFixture?.library;
  if (library) await new LibraryRepository(db).update(library.id, { importPaths: [folder] });
  const originalPath = join(folder, 'synthetic-original.jpg');
  const bytes = Buffer.from('synthetic disposable original, no user media');
  await writeFile(originalPath, bytes);
  const contentChecksum = createHash('sha1').update(bytes).digest();
  const { asset } = await ctx.newAsset({
    ownerId: user.id,
    libraryId: library?.id ?? null,
    isExternal: external,
    originalPath,
    checksum: external ? createHash('sha1').update(originalPath).digest() : contentChecksum,
    checksumAlgorithm: external ? ChecksumAlgorithm.sha1Path : ChecksumAlgorithm.sha1File,
    contentChecksum,
    status: AssetStatus.Trashed,
    deletedAt: new Date(),
  });
  const repo = new AssetRepository(db);
  const scope = library?.id ?? 'managed';
  const policy = {
    enabled: true,
    authorizationMode: 'storage' as const,
    roots: [folder],
    rootIdentities: await collectRootIdentities([folder]),
    recoveryProof: '',
    recoveryExpiresAt: null,
    authorizedBy: user.id,
  };
  await repo.setDeletionPolicy(user.id, scope, policy);
  const auth = { ...authStub.user1, user: { ...authStub.user1.user, id: user.id } };
  return { ctx, repo, user, asset, library, scope, folder, originalPath, bytes, contentChecksum, policy, auth };
};

it('commits irreversible state before any file work and excludes pending/failed receipts from user Trash', async () => {
  const f = await fixture();
  const beforeBuckets = await f.repo.getTimeBuckets(
    { userIds: [f.user.id], isTrashed: true, bucketSize: TimeBucketSize.Month },
    f.auth,
  );
  expect(beforeBuckets.reduce((sum, item) => sum + Number(item.count), 0)).toBe(1);
  const accepted = await f.repo.acceptPermanentDeletion([f.asset.id], f.user.id);
  expect(accepted).toMatchObject([{ assetId: f.asset.id, state: 'preparing', operationId: f.asset.id }]);
  expect(await readFile(f.originalPath)).toEqual(f.bytes);
  const journal = await db
    .selectFrom('asset_deletion_tombstone')
    .selectAll()
    .where('assetId', '=', f.asset.id)
    .executeTakeFirstOrThrow();
  expect(journal.files).toEqual([]);
  expect(journal.contentChecksum).toEqual(f.contentChecksum);
  const deleted = await f.repo.getById(f.asset.id);
  expect(deleted?.status).toBe(AssetStatus.Deleted);
  expect(await f.repo.getOwnerTrash(f.user.id)).toEqual([]);
  await db
    .updateTable('asset_deletion_tombstone')
    .set({ state: 'failed', errorCode: 'SYNTHETIC_OFFLINE' })
    .where('assetId', '=', f.asset.id)
    .execute();
  expect(await f.repo.getOwnerTrash(f.user.id)).toEqual([]);
  const statistics = await f.repo.getStatistics(f.user.id, { isTrashed: true });
  expect(statistics[AssetType.Image]).toBe(0);
  expect(
    await f.repo.getTimeBuckets({ userIds: [f.user.id], isTrashed: true, bucketSize: TimeBucketSize.Month }, f.auth),
  ).toEqual([]);
  await expect(new TrashRepository(db).restoreAll([f.asset.id], f.user.id)).rejects.toMatchObject({
    code: 'ASSET_PERMANENTLY_DELETED',
  });
});

it('rolls back every new receipt if one member is not owned or no longer in Trash', async () => {
  const f = await fixture();
  const { user: other } = await f.ctx.newUser();
  const { asset: foreign } = await f.ctx.newAsset({
    ownerId: other.id,
    status: AssetStatus.Trashed,
    deletedAt: new Date(),
  });
  await expect(f.repo.acceptPermanentDeletion([f.asset.id, foreign.id], f.user.id)).rejects.toMatchObject({
    code: 'ASSET_NOT_IN_TRASH',
  });
  expect(await f.repo.getDeletionReceipt(f.user.id, f.asset.id)).toBeUndefined();
  const ownedAsset = await f.repo.getById(f.asset.id);
  const foreignAsset = await f.repo.getById(foreign.id);
  expect(ownedAsset?.status).toBe(AssetStatus.Trashed);
  expect(foreignAsset?.status).toBe(AssetStatus.Trashed);
  expect(await readFile(f.originalPath)).toEqual(f.bytes);
});

it('serializes a real concurrent restore against acceptance so exactly one decision wins', async () => {
  const f = await fixture();
  const result = await Promise.allSettled([
    f.repo.acceptPermanentDeletion([f.asset.id], f.user.id),
    new TrashRepository(db).restoreAll([f.asset.id], f.user.id),
  ]);
  expect(result.filter((item) => item.status === 'fulfilled')).toHaveLength(1);
  expect(result.filter((item) => item.status === 'rejected')).toHaveLength(1);
  const current = await f.repo.getById(f.asset.id);
  const journal = await f.repo.getDeletionReceipt(f.user.id, f.asset.id);
  if (result[0].status === 'fulfilled') {
    expect(current?.status).toBe(AssetStatus.Deleted);
    expect(journal?.state).toBe('preparing');
  } else {
    expect(current?.status).toBe(AssetStatus.Active);
    expect(journal).toBeUndefined();
  }
  expect(await readFile(f.originalPath)).toEqual(f.bytes);
});

it('accepts a still and its exclusive motion once even if both IDs occur in the snapshot', async () => {
  const f = await fixture();
  const motionPath = join(f.folder, 'synthetic-motion.mp4');
  await writeFile(motionPath, 'synthetic disposable motion component');
  const { asset: motion } = await f.ctx.newAsset({
    ownerId: f.user.id,
    originalPath: motionPath,
    type: AssetType.Video,
    visibility: AssetVisibility.Hidden,
  });
  await f.repo.update({ id: f.asset.id, livePhotoVideoId: motion.id });
  const accepted = await f.repo.acceptPermanentDeletion([motion.id, f.asset.id, f.asset.id], f.user.id);
  expect(accepted).toHaveLength(2);
  expect(accepted.map((item) => item.assetId)).toEqual(expect.arrayContaining([f.asset.id, motion.id]));
  expect(accepted.every((item) => item.operationId === f.asset.id && item.state === 'preparing')).toBe(true);
  const deletedMotion = await f.repo.getById(motion.id);
  expect(deletedMotion?.status).toBe(AssetStatus.Deleted);
  expect(await readFile(motionPath, 'utf8')).toContain('synthetic');
  await f.repo.acceptPermanentDeletion([f.asset.id], f.user.id);
  expect(
    await db.selectFrom('asset_deletion_tombstone').select('assetId').where('ownerId', '=', f.user.id).execute(),
  ).toHaveLength(2);
});

it('rejects an unauthorized External scope without changing files, then suppresses accepted paths and reupload', async () => {
  const f = await fixture(true);
  await f.repo.setDeletionPolicy(f.user.id, f.scope, { ...f.policy, enabled: false });
  await expect(f.repo.acceptPermanentDeletion([f.asset.id], f.user.id)).rejects.toMatchObject({
    code: 'LIBRARY_DELETION_NOT_AUTHORIZED',
  });
  expect(await f.repo.getDeletionReceipt(f.user.id, f.asset.id)).toBeUndefined();
  await f.repo.setDeletionPolicy(f.user.id, f.scope, f.policy);
  await f.repo.acceptPermanentDeletion([f.asset.id], f.user.id);
  expect(await f.repo.filterNewExternalAssetPaths(f.library!.id, [f.originalPath])).toEqual([]);
  expect(await f.repo.getUploadAssetIdByChecksum(f.user.id, f.contentChecksum)).toMatchObject({ assetId: f.asset.id });
  expect(await readFile(f.originalPath)).toEqual(f.bytes);
});

it('retains the same accepted receipt across repository restart and policy revocation', async () => {
  const f = await fixture();
  await f.repo.acceptPermanentDeletion([f.asset.id], f.user.id);
  await f.repo.setDeletionPolicy(f.user.id, f.scope, { ...f.policy, enabled: false });
  const restarted = new AssetRepository(db);
  const retried = await restarted.acceptPermanentDeletion([f.asset.id], f.user.id);
  expect(retried).toMatchObject([{ assetId: f.asset.id, operationId: f.asset.id, state: 'preparing' }]);
  const recovery = [];
  for await (const item of restarted.streamPendingDeletions()) if (item.ownerId === f.user.id) recovery.push(item);
  expect(recovery).toHaveLength(1);
  expect(await new TrashRepository(db).restore(f.user.id)).toBe(0);
  await expect(new TrashRepository(db).restoreAll([f.asset.id], f.user.id)).rejects.toMatchObject({
    code: 'ASSET_PERMANENTLY_DELETED',
  });
  expect(await readFile(f.originalPath)).toEqual(f.bytes);
});

it('preserves the explicit rejection of deprecated AssetsV1 after accepting deletion', async () => {
  const f = await fixture();
  const sync = new SyncTestContext(db);
  const { session } = await sync.newSession({ userId: f.user.id });
  const auth = factory.auth({ session, user: { id: f.user.id, email: f.user.email, name: f.user.name } });
  await f.repo.acceptPermanentDeletion([f.asset.id], f.user.id);
  await expect(sync.syncStream(auth, [SyncRequestType.AssetsV1])).rejects.toMatchObject({
    status: 400,
    message: 'SyncRequestType.AssetsV1 is deprecated, use SyncRequestType.AssetsV2 instead',
  });
  const receipt = await f.repo.getDeletionReceipt(f.user.id, f.asset.id);
  expect(receipt?.state).toBe('preparing');
  expect(await readFile(f.originalPath)).toEqual(f.bytes);
});

it('retires accepted objects through AssetsV2 before file cleanup and keeps cold profiles empty', async () => {
  const f = await fixture();
  const sync = new SyncTestContext(db);
  const { session } = await sync.newSession({ userId: f.user.id });
  const auth = factory.auth({ session, user: { id: f.user.id, email: f.user.email, name: f.user.name } });
  await f.ctx.newExif({ assetId: f.asset.id, city: 'Synthetic fixture place' });
  const { album } = await f.ctx.newAlbum({ ownerId: f.user.id, albumThumbnailAssetId: f.asset.id });
  await f.ctx.newAlbumAsset({ albumId: album.id, assetId: f.asset.id });
  const { asset: unselected } = await f.ctx.newAsset({
    ownerId: f.user.id,
    status: AssetStatus.Trashed,
    deletedAt: new Date(),
  });
  const types = [SyncRequestType.AssetsV2, SyncRequestType.AssetExifsV1, SyncRequestType.AlbumsV1];
  const initial = await sync.syncStream(auth, types);
  expect(initial).toContainEqual(expect.objectContaining({ data: expect.objectContaining({ id: f.asset.id }) }));
  await sync.syncAckAll(auth, initial);

  await f.repo.acceptPermanentDeletion([f.asset.id], f.user.id);
  const delta = await sync.syncStream(auth, types);
  expect(delta).toContainEqual(
    expect.objectContaining({
      type: SyncEntityType.AssetDeleteV1,
      data: expect.objectContaining({ assetId: f.asset.id }),
    }),
  );
  expect(delta).not.toContainEqual(expect.objectContaining({ data: expect.objectContaining({ id: f.asset.id }) }));
  expect(delta).not.toContainEqual(
    expect.objectContaining({
      type: SyncEntityType.AssetExifV1,
      data: expect.objectContaining({ assetId: f.asset.id }),
    }),
  );
  await sync.syncAckAll(auth, delta);
  await sync.assertSyncIsComplete(auth, types);

  const { session: coldSession } = await sync.newSession({ userId: f.user.id });
  const coldAuth = factory.auth({
    session: coldSession,
    user: { id: f.user.id, email: f.user.email, name: f.user.name },
  });
  const cold = await sync.syncStream(coldAuth, types);
  expect(cold).not.toContainEqual(expect.objectContaining({ data: expect.objectContaining({ id: f.asset.id }) }));
  expect(cold).not.toContainEqual(
    expect.objectContaining({
      type: SyncEntityType.AssetExifV1,
      data: expect.objectContaining({ assetId: f.asset.id }),
    }),
  );
  expect(cold).toContainEqual(expect.objectContaining({ data: expect.objectContaining({ id: unselected.id }) }));
  expect(cold).toContainEqual(
    expect.objectContaining({
      type: SyncEntityType.AlbumV1,
      data: expect.objectContaining({ id: album.id, thumbnailAssetId: null }),
    }),
  );
  await f.repo.acceptPermanentDeletion([f.asset.id], f.user.id);
  expect(
    await db
      .selectFrom('asset_audit')
      .select('assetId')
      .where('ownerId', '=', f.user.id)
      .where('assetId', '=', f.asset.id)
      .execute(),
  ).toHaveLength(1);
  const receipt = await f.repo.getDeletionReceipt(f.user.id, f.asset.id);
  expect(receipt?.state).toBe('preparing');
  expect(await readFile(f.originalPath)).toEqual(f.bytes);
  const unselectedAsset = await f.repo.getById(unselected.id);
  expect(unselectedAsset?.status).toBe(AssetStatus.Trashed);
});
