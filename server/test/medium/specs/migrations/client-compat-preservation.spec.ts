import { Kysely } from 'kysely';
import { AssetStatus, SyncEntityType } from 'src/enum.js';
import { AssetFavoriteRepository } from 'src/repositories/asset-favorite.repository.js';
import { DatabaseRepository } from 'src/repositories/database.repository.js';
import { SyncCheckpointRepository } from 'src/repositories/sync-checkpoint.repository.js';
import { DB } from 'src/schema/index.js';
import { down as removeFavorites } from 'src/schema/migrations-gallery/1794000000000-AddAssetFavoriteTables.js';
import { down as removeActorColumn } from 'src/schema/migrations-gallery/1796000000000-AddAssetFaceCreatedBy.js';
import { down as removeOwnerMirror } from 'src/schema/migrations-gallery/1796000000200-MirrorOwnerFavorites.js';
import { down as removeCatalogProjection } from 'src/schema/migrations-gallery/1796000000300-TrackCatalogIndexRecovery.js';
import { SyncTestContext } from 'test/medium.factory.js';
import { newUuidV7 } from 'test/small.factory.js';
import { getKyselyDB } from 'test/utils.js';

let db: Kysely<DB>;
beforeAll(async () => {
  db = await getKyselyDB();
});
afterAll(async () => {
  await db?.destroy();
});

it('upgrades representative existing metadata without converting indexes or losing IDs, albums or favorites', async () => {
  // Only this disposable cloned test DB is changed. Reverts construct the pre-extension
  // schema; they are NOT evidence that a production downgrade is safe.
  await removeCatalogProjection(db);
  await removeOwnerMirror(db);
  await removeFavorites(db);
  await removeActorColumn(db);
  await db
    .deleteFrom('kysely_migrations')
    .where('name', 'in', [
      '1794000000000-AddAssetFavoriteTables',
      '1796000000000-AddAssetFaceCreatedBy',
      '1796000000100-ResetCatalogSyncProjection',
      '1796000000200-MirrorOwnerFavorites',
      '1796000000300-TrackCatalogIndexRecovery',
    ])
    .execute();
  const ctx = new SyncTestContext(db);
  const { auth, user } = await ctx.newSyncAuthUser();
  const { asset } = await ctx.newAsset({ ownerId: user.id, isFavorite: true });
  const { asset: offline } = await ctx.newAsset({
    ownerId: user.id,
    status: AssetStatus.Active,
    isOffline: true,
    deletedAt: new Date(),
  });
  const { album } = await ctx.newAlbum({ ownerId: user.id });
  await ctx.newAlbumAsset({ albumId: album.id, assetId: asset.id });
  const { assetFace } = await ctx.newAssetFace({ assetId: asset.id });
  const before = await db.selectFrom('asset').selectAll().orderBy('id').execute();
  await ctx
    .get(SyncCheckpointRepository)
    .upsertAll([
      { sessionId: auth.session!.id, type: SyncEntityType.SyncCompleteV1, ack: `SyncCompleteV1|${newUuidV7()}` },
    ]);
  // Exercise the actual runtime migrator on a populated pre-extension schema, including
  // the pending 179400... migration interleaved before the already-recorded 179405... baseline.
  await ctx.get(DatabaseRepository).runMigrations();
  expect(await db.selectFrom('asset').selectAll().orderBy('id').execute()).toEqual(before);
  expect(await ctx.get(AssetFavoriteRepository).getForAssets(user.id, [asset.id])).toEqual(new Set([asset.id]));
  expect(await db.selectFrom('album_asset').select('assetId').where('albumId', '=', album.id).execute()).toEqual([
    { assetId: asset.id },
  ]);
  const face = await db
    .selectFrom('asset_face')
    .select(['id', 'createdBy'])
    .where('id', '=', assetFace.id)
    .executeTakeFirstOrThrow();
  expect(face).toEqual({ id: assetFace.id, createdBy: null });
  const index = await db
    .selectFrom('asset')
    .select(['status', 'isOffline'])
    .where('id', '=', offline.id)
    .executeTakeFirstOrThrow();
  expect(index).toEqual({ status: AssetStatus.Active, isOffline: true });
  const session = await db
    .selectFrom('session')
    .select('isPendingSyncReset')
    .where('id', '=', auth.session!.id)
    .executeTakeFirstOrThrow();
  expect(session.isPendingSyncReset).toBe(true);
});
