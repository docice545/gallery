import { Kysely } from 'kysely';
import { AssetEditAction } from 'src/dtos/editing.dto.js';
import { AssetStatus, MemoryType, SyncEntityType, SyncRequestType } from 'src/enum.js';
import { AssetEditRepository } from 'src/repositories/asset-edit.repository.js';
import { SyncRepository } from 'src/repositories/sync.repository.js';
import { DB } from 'src/schema/index.js';
import { SyncTestContext } from 'test/medium.factory.js';
import { getKyselyDB } from 'test/utils.js';

let db: Kysely<DB>;
beforeAll(async () => {
  db = await getKyselyDB();
});
afterAll(async () => {
  await db?.destroy();
});

it.each([SyncRequestType.MemoriesV1, SyncRequestType.MemoriesV2])(
  'official %s projects parents and links together',
  async (memoryType) => {
    const ctx = new SyncTestContext(db);
    const { auth, user } = await ctx.newSyncAuthUser();
    const { asset } = await ctx.newAsset({ ownerId: user.id });
    const { memory: day } = await ctx.newMemory({ ownerId: user.id, type: MemoryType.OnThisDay });
    const { memory: rule } = await ctx.newMemory({ ownerId: user.id, type: MemoryType.Rule });
    await ctx.newMemoryAsset({ memoryId: day.id, assetId: asset.id });
    await ctx.newMemoryAsset({ memoryId: rule.id, assetId: asset.id });
    const linkType =
      memoryType === SyncRequestType.MemoriesV1 ? SyncRequestType.MemoryToAssetsV1 : SyncRequestType.MemoryToAssetsV2;
    const messages = await ctx.syncStream(auth, [SyncRequestType.AssetsV2, memoryType, linkType]);
    const parents = messages.filter((e) => e.type === SyncEntityType.MemoryV1 || e.type === SyncEntityType.MemoryV2);
    const links = messages.filter(
      (e) => e.type === SyncEntityType.MemoryToAssetV1 || e.type === SyncEntityType.MemoryToAssetV2,
    );
    expect(parents.map((e: any) => e.data.id)).toEqual([day.id]);
    expect(links.map((e: any) => e.data.memoryId)).toEqual([day.id]);
    expect(await db.selectFrom('memory').select('id').where('id', '=', rule.id).executeTakeFirst()).toBeDefined();
    await ctx.syncAckAll(auth, messages);
    await ctx.assertSyncIsComplete(auth, [SyncRequestType.AssetsV2, memoryType, linkType]);
  },
);

it('keeps rule parents and links for fork-aware clients', async () => {
  const ctx = new SyncTestContext(db);
  const { auth, user } = await ctx.newSyncAuthUser();
  const { asset } = await ctx.newAsset({ ownerId: user.id });
  const { memory } = await ctx.newMemory({ ownerId: user.id, type: MemoryType.Rule });
  await ctx.newMemoryAsset({ memoryId: memory.id, assetId: asset.id });
  const messages = await ctx.syncStream(auth, [
    SyncRequestType.SharedSpacesV1,
    SyncRequestType.MemoriesV1,
    SyncRequestType.MemoryToAssetsV1,
  ]);
  expect(messages).toContainEqual(
    expect.objectContaining({ type: SyncEntityType.MemoryV1, data: expect.objectContaining({ id: memory.id }) }),
  );
  expect(messages).toContainEqual(
    expect.objectContaining({
      type: SyncEntityType.MemoryToAssetV1,
      data: expect.objectContaining({ memoryId: memory.id }),
    }),
  );
});

it('omits offline index assets and their album/memory FK links without deleting originals or catalog rows', async () => {
  const ctx = new SyncTestContext(db);
  const { auth, user } = await ctx.newSyncAuthUser();
  const { library } = await ctx.newLibrary({ ownerId: user.id });
  const { asset } = await ctx.newAsset({
    ownerId: user.id,
    libraryId: library.id,
    isExternal: true,
    isOffline: true,
    status: AssetStatus.Active,
    deletedAt: new Date(),
  });
  const { album } = await ctx.newAlbum({ ownerId: user.id });
  await ctx.newAlbumAsset({ albumId: album.id, assetId: asset.id });
  const { memory } = await ctx.newMemory({ ownerId: user.id });
  await ctx.newMemoryAsset({ memoryId: memory.id, assetId: asset.id });
  const messages = await ctx.syncStream(auth, [
    SyncRequestType.AssetsV2,
    SyncRequestType.AlbumsV2,
    SyncRequestType.AlbumAssetsV2,
    SyncRequestType.AlbumToAssetsV1,
    SyncRequestType.MemoriesV1,
    SyncRequestType.MemoryToAssetsV1,
  ]);
  expect(messages.filter((e: any) => e.data.id === asset.id || e.data.assetId === asset.id)).toEqual([]);
  expect(messages.some((e) => e.type === SyncEntityType.AssetDeleteV1)).toBe(false);
  expect(await db.selectFrom('asset').select('id').where('id', '=', asset.id).executeTakeFirst()).toBeDefined();
});

it('resets an already synced index before emitting a newly offline asset, with no destructive delete event', async () => {
  const ctx = new SyncTestContext(db);
  const { auth, user } = await ctx.newSyncAuthUser();
  const { asset } = await ctx.newAsset({ ownerId: user.id });
  const messages = await ctx.syncStream(auth, [SyncRequestType.AssetsV2]);
  await ctx.syncAckAll(auth, messages);
  await db
    .updateTable('asset')
    .set({ status: AssetStatus.Active, isOffline: true, deletedAt: new Date() })
    .where('id', '=', asset.id)
    .execute();
  const reset = await ctx.syncStream(auth, [SyncRequestType.AssetsV2]);
  expect(reset.map((e) => e.type)).toEqual([SyncEntityType.SyncResetV1]);
  await ctx.syncAckAll(auth, reset);
  const fresh = await ctx.syncStream(auth, [SyncRequestType.AssetsV2]);
  expect(fresh.filter((e: any) => e.data.id === asset.id)).toEqual([]);
});

it('preserves real user Trash in sync', async () => {
  const ctx = new SyncTestContext(db);
  const { auth, user } = await ctx.newSyncAuthUser();
  const { asset } = await ctx.newAsset({ ownerId: user.id, status: AssetStatus.Trashed, deletedAt: new Date() });
  const messages = await ctx.syncStream(auth, [SyncRequestType.AssetsV2]);
  expect(messages).toContainEqual(
    expect.objectContaining({
      type: SyncEntityType.AssetV2,
      data: expect.objectContaining({ id: asset.id, deletedAt: expect.any(String) }),
    }),
  );
});

it('official trim filtering advances ACK while preserving persisted edits and fork sync', async () => {
  const ctx = new SyncTestContext(db);
  const { auth, user } = await ctx.newSyncAuthUser();
  const { asset } = await ctx.newAsset({ ownerId: user.id });
  await ctx
    .get(AssetEditRepository)
    .replaceAll(asset.id, [{ action: AssetEditAction.Trim, parameters: { startTime: 1, endTime: 3 } }]);
  const messages = await ctx.syncStream(auth, [SyncRequestType.AssetEditsV1]);
  expect(messages.some((e) => e.type === SyncEntityType.AssetEditV1)).toBe(false);
  expect(messages.some((e) => e.type === SyncEntityType.SyncAckV1)).toBe(true);
  await ctx.syncAckAll(auth, messages);
  await ctx.assertSyncIsComplete(auth, [SyncRequestType.AssetEditsV1]);
  expect(await ctx.get(AssetEditRepository).getAll(asset.id)).toHaveLength(1);
  await ctx.sut.deleteAcks(auth, { types: [SyncEntityType.AssetEditV1] });
  const fork = await ctx.syncStream(auth, [SyncRequestType.SharedSpacesV1, SyncRequestType.AssetEditsV1]);
  expect(fork).toContainEqual(
    expect.objectContaining({
      type: SyncEntityType.AssetEditV1,
      data: expect.objectContaining({ action: AssetEditAction.Trim }),
    }),
  );
});

it('V3 faces follow the upstream cluster scope, while V2 remains owner-only', async () => {
  const ctx = new SyncTestContext(db);
  const { auth, user } = await ctx.newSyncAuthUser();
  const { user: sameCluster } = await ctx.newSyncAuthUser();
  const { user: unrelated } = await ctx.newSyncAuthUser();
  await db.updateTable('user').set({ clusterGroupId: user.clusterGroupId }).where('id', '=', sameCluster.id).execute();
  const own = await ctx.newAsset({ ownerId: user.id });
  const shared = await ctx.newAsset({ ownerId: sameCluster.id });
  const outside = await ctx.newAsset({ ownerId: unrelated.id });
  const f1 = await ctx.newAssetFace({ assetId: own.asset.id });
  const f2 = await ctx.newAssetFace({ assetId: shared.asset.id });
  const f3 = await ctx.newAssetFace({ assetId: outside.asset.id });
  const v3 = await ctx.syncStream(auth, [SyncRequestType.AssetFacesV3]);
  const faceIds = v3.filter((e) => e.type === SyncEntityType.AssetFaceV3).map((e: any) => e.data.id);
  expect(faceIds).toEqual(expect.arrayContaining([f1.assetFace.id, f2.assetFace.id]));
  expect(faceIds).not.toContain(f3.assetFace.id);
  const v2 = await ctx.syncStream(auth, [SyncRequestType.AssetFacesV2]);
  expect(v2.filter((e) => e.type === SyncEntityType.AssetFaceV2).map((e: any) => e.data.id)).toEqual([f1.assetFace.id]);
});

it('does not acknowledge over an offline-index change racing the invalidation check', async () => {
  const ctx = new SyncTestContext(db);
  const { auth, user } = await ctx.newSyncAuthUser();
  const { asset } = await ctx.newAsset({ ownerId: user.id });
  await ctx.syncAckAll(auth, await ctx.syncStream(auth, [SyncRequestType.AssetsV2]));
  const repo = ctx.get(SyncRepository);
  const check = repo.hasIndexTombstoneChanges.bind(repo);
  const spy = vi.spyOn(repo, 'hasIndexTombstoneChanges').mockImplementationOnce(async (after) => {
    const result = await check(after);
    await db
      .updateTable('asset')
      .set({ isOffline: true, status: AssetStatus.Active, deletedAt: new Date() })
      .where('id', '=', asset.id)
      .execute();
    // Make the previously buggy getNow-after-check order acknowledge past this real DB update.
    await new Promise((resolve) => setTimeout(resolve, 5));
    return result;
  });
  const raced = await ctx.syncStream(auth, [SyncRequestType.AssetsV2]);
  spy.mockRestore();
  await ctx.syncAckAll(auth, raced);
  const next = await ctx.syncStream(auth, [SyncRequestType.AssetsV2]);
  expect(next.map((e) => e.type)).toEqual([SyncEntityType.SyncResetV1]);
  expect(raced.some((e) => e.type === SyncEntityType.AssetDeleteV1)).toBe(false);
});
