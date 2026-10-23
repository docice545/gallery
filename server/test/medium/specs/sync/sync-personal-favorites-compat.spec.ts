import { Kysely } from 'kysely';
import { SyncEntityType, SyncRequestType } from 'src/enum.js';
import { AssetFavoriteRepository } from 'src/repositories/asset-favorite.repository.js';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { DB } from 'src/schema/index.js';
import { SyncTestContext } from 'test/medium.factory.js';
import { getKyselyDB, wait } from 'test/utils.js';

let db: Kysely<DB>;
beforeAll(async () => {
  db = await getKyselyDB();
});
afterAll(async () => {
  await db?.destroy();
});

it('non-owner favorites never modify owner state, and repeated add/remove are idempotent', async () => {
  const ctx = new SyncTestContext(db);
  const { user: owner } = await ctx.newSyncAuthUser();
  const { user: viewer } = await ctx.newSyncAuthUser();
  const { asset } = await ctx.newAsset({ ownerId: owner.id, isFavorite: false });
  const repo = ctx.get(AssetFavoriteRepository);
  const before = await db
    .selectFrom('asset')
    .select(['isFavorite', 'updateId'])
    .where('id', '=', asset.id)
    .executeTakeFirstOrThrow();
  await repo.addAll(viewer.id, [asset.id]);
  await repo.addAll(viewer.id, [asset.id]);
  expect(await repo.getForAssets(viewer.id, [asset.id])).toEqual(new Set([asset.id]));
  expect(await repo.getForAssets(owner.id, [asset.id])).toEqual(new Set());
  expect(
    await db
      .selectFrom('asset')
      .select(['isFavorite', 'updateId'])
      .where('id', '=', asset.id)
      .executeTakeFirstOrThrow(),
  ).toEqual(before);
  await repo.removeAll(viewer.id, [asset.id]);
  await repo.removeAll(viewer.id, [asset.id]);
  expect(await repo.getForAssets(viewer.id, [asset.id])).toEqual(new Set());
});

it('canonical owner favorites and legacy column writes agree in both directions', async () => {
  const ctx = new SyncTestContext(db);
  const { user } = await ctx.newSyncAuthUser();
  const { asset } = await ctx.newAsset({ ownerId: user.id, isFavorite: true });
  const repo = ctx.get(AssetFavoriteRepository);
  expect(await repo.getForAssets(user.id, [asset.id])).toEqual(new Set([asset.id]));
  await repo.removeAll(user.id, [asset.id]);
  const stored = await db.selectFrom('asset').select('isFavorite').where('id', '=', asset.id).executeTakeFirstOrThrow();
  expect(stored.isFavorite).toBe(false);
  await db.updateTable('asset').set({ isFavorite: true }).where('id', '=', asset.id).execute();
  expect(await repo.getForAssets(user.id, [asset.id])).toEqual(new Set([asset.id]));
  await repo.addAll(user.id, [asset.id]);
  await db.updateTable('asset').set({ isFavorite: false }).where('id', '=', asset.id).execute();
  expect(await repo.getForAssets(user.id, [asset.id])).toEqual(new Set());
});

it('favorite sync and deletion ACKs are caller-scoped and do not delete assets', async () => {
  const ctx = new SyncTestContext(db);
  const { auth: ownerAuth, user: owner } = await ctx.newSyncAuthUser();
  const { auth, user } = await ctx.newSyncAuthUser();
  const { asset } = await ctx.newAsset({ ownerId: owner.id });
  const repo = ctx.get(AssetFavoriteRepository);
  await repo.addAll(user.id, [asset.id]);
  const upserts = await ctx.syncStream(auth, [SyncRequestType.AssetFavoritesV1]);
  expect(upserts).toContainEqual(
    expect.objectContaining({ type: SyncEntityType.AssetFavoriteV1, data: { assetId: asset.id } }),
  );
  await ctx.assertSyncIsComplete(ownerAuth, [SyncRequestType.AssetFavoritesV1]);
  await ctx.syncAckAll(auth, upserts);
  await repo.removeAll(user.id, [asset.id]);
  const deletes = await ctx.syncStream(auth, [SyncRequestType.AssetFavoritesV1]);
  expect(deletes).toContainEqual(
    expect.objectContaining({ type: SyncEntityType.AssetFavoriteDeleteV1, data: { assetId: asset.id } }),
  );
  await ctx.syncAckAll(auth, deletes);
  await ctx.assertSyncIsComplete(auth, [SyncRequestType.AssetFavoritesV1]);
  expect(await db.selectFrom('asset').select('id').where('id', '=', asset.id).executeTakeFirst()).toBeDefined();
});

it('keeps owner column and overlay consistent under concurrent legacy/canonical requests', async () => {
  const ctx = new SyncTestContext(db);
  const { user } = await ctx.newSyncAuthUser();
  const { asset } = await ctx.newAsset({ ownerId: user.id, isFavorite: false });
  const repo = ctx.get(AssetFavoriteRepository);
  await Promise.all([
    repo.addAll(user.id, [asset.id]),
    db.updateTable('asset').set({ isFavorite: false }).where('id', '=', asset.id).execute(),
  ]);
  const row = await db.selectFrom('asset').select('isFavorite').where('id', '=', asset.id).executeTakeFirstOrThrow();
  const favoriteIds = await repo.getForAssets(user.id, [asset.id]);
  expect(favoriteIds.has(asset.id)).toBe(row.isFavorite);
});

it('refreshes old FOTO shared-asset favorites on another device without touching the owners asset', async () => {
  const ctx = new SyncTestContext(db);
  const { user: owner } = await ctx.newSyncAuthUser();
  const { auth, user } = await ctx.newSyncAuthUser();
  const { space } = await ctx.newSharedSpace({ createdById: owner.id });
  await ctx.newSharedSpaceMember({ spaceId: space.id, userId: user.id, role: 'viewer' });
  const { asset } = await ctx.newAsset({ ownerId: owner.id, isFavorite: false });
  await ctx.newSharedSpaceAsset({ spaceId: space.id, assetId: asset.id, addedById: owner.id });
  const types = [SyncRequestType.SharedSpacesV1, SyncRequestType.SharedSpaceAssetsV1];
  const first = await ctx.syncStream(auth, types);
  await ctx.syncAckAll(auth, first);
  await ctx.get(AssetFavoriteRepository).addAll(user.id, [asset.id]);
  const reset = await ctx.syncStream(auth, types);
  expect(reset.map((e) => e.type)).toEqual([SyncEntityType.SyncResetV1]);
  await ctx.syncAckAll(auth, reset);
  const fresh = await ctx.syncStream(auth, types);
  expect(fresh).toContainEqual(
    expect.objectContaining({ data: expect.objectContaining({ id: asset.id, isFavorite: true }) }),
  );
  expect(fresh.some((e) => e.type === SyncEntityType.AssetDeleteV1)).toBe(false);
  await ctx.syncAckAll(auth, fresh);
  await ctx.assertSyncIsComplete(auth, types);
});

it('projects the viewers favorite in both partner backfill and incremental updates', async () => {
  const ctx = new SyncTestContext(db);
  const { user: owner } = await ctx.newSyncAuthUser();
  const { user: firstPartner } = await ctx.newSyncAuthUser();
  const { auth, user: viewer } = await ctx.newSyncAuthUser();
  const { asset } = await ctx.newAsset({ ownerId: owner.id, isFavorite: false });
  await ctx.get(AssetFavoriteRepository).addAll(viewer.id, [asset.id]);
  await wait(2);
  await ctx.newAsset({ ownerId: firstPartner.id });
  await ctx.newPartner({ sharedById: firstPartner.id, sharedWithId: viewer.id });
  const types = [SyncRequestType.PartnerAssetsV2];
  await ctx.syncAckAll(auth, await ctx.syncStream(auth, types));
  // The first partners newer asset watermark forces this owners older asset into backfill.
  await ctx.newPartner({ sharedById: owner.id, sharedWithId: viewer.id });
  const backfill = await ctx.syncStream(auth, types);
  expect(backfill).toContainEqual(
    expect.objectContaining({
      type: SyncEntityType.PartnerAssetBackfillV2,
      data: expect.objectContaining({ id: asset.id, isFavorite: true }),
    }),
  );
  await ctx.syncAckAll(auth, backfill);
  await ctx.get(AssetRepository).update({ id: asset.id, originalFileName: 'updated.jpg' });
  const updates = await ctx.syncStream(auth, types);
  expect(updates).toContainEqual(
    expect.objectContaining({
      type: SyncEntityType.PartnerAssetV2,
      data: expect.objectContaining({ id: asset.id, isFavorite: true }),
    }),
  );
  expect(await ctx.get(AssetFavoriteRepository).getForAssets(owner.id, [asset.id])).toEqual(new Set());
  const row = await db.selectFrom('asset').select('isFavorite').where('id', '=', asset.id).executeTakeFirstOrThrow();
  expect(row.isFavorite).toBe(false);
});
