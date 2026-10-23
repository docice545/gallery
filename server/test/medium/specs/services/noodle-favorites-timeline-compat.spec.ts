import { Kysely } from 'kysely';
import { AssetVisibility, SharedSpaceRole, TimeBucketSize } from 'src/enum.js';
import { AccessRepository } from 'src/repositories/access.repository.js';
import { AssetFavoriteRepository } from 'src/repositories/asset-favorite.repository.js';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { FaceIdentityRepository } from 'src/repositories/face-identity.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { PartnerRepository } from 'src/repositories/partner.repository.js';
import { SharedSpaceRepository } from 'src/repositories/shared-space.repository.js';
import { DB } from 'src/schema/index.js';
import { TimelineService } from 'src/services/timeline.service.js';
import { newMediumService } from 'test/medium.factory.js';
import { getKyselyDB } from 'test/utils.js';

let db: Kysely<DB>;
beforeAll(async () => {
  db = await getKyselyDB();
});
afterAll(async () => {
  await db?.destroy();
});

it('serves stock Noodle favorites timeline buckets and columns, and respects membership revocation', async () => {
  const { sut, ctx } = newMediumService(TimelineService, {
    database: db,
    real: [
      AccessRepository,
      AssetRepository,
      AssetFavoriteRepository,
      FaceIdentityRepository,
      PartnerRepository,
      SharedSpaceRepository,
    ],
    mock: [LoggingRepository],
  });
  const { auth: ownerAuth, user: owner } = await ctx.newSyncAuthUser();
  const { auth, user } = await ctx.newSyncAuthUser();
  const { space } = await ctx.newSharedSpace({ createdById: owner.id });
  await ctx.newSharedSpaceMember({
    spaceId: space.id,
    userId: owner.id,
    role: SharedSpaceRole.Owner,
    showInTimeline: true,
  });
  await ctx.newSharedSpaceMember({
    spaceId: space.id,
    userId: user.id,
    role: SharedSpaceRole.Viewer,
    showInTimeline: true,
  });
  const { asset } = await ctx.newAsset({ ownerId: owner.id, isFavorite: false, visibility: AssetVisibility.Timeline });
  await ctx.newExif({ assetId: asset.id, exifImageWidth: 100, exifImageHeight: 100 });
  await ctx.newSharedSpaceAsset({ spaceId: space.id, assetId: asset.id, addedById: owner.id });
  await ctx.get(AssetFavoriteRepository).addAll(user.id, [asset.id]);
  // These are the actual options in the unmodified v5.8.0 favorites page.
  const flags = {
    isFavorite: true,
    withStacked: true,
    withPartners: true,
    withSharedSpaces: true,
    visibility: AssetVisibility.Timeline,
    bucketSize: TimeBucketSize.Month,
  };
  const buckets = await sut.getTimeBuckets(auth, { ...flags });
  expect(buckets).toHaveLength(1);
  const columns = JSON.parse(await sut.getTimeBucket(auth, { ...flags, timeBucket: buckets[0].timeBucket }));
  expect(columns.id).toEqual([asset.id]);
  expect(columns.isFavorite).toEqual([true]);
  expect(await sut.getTimeBuckets(ownerAuth, { ...flags })).toEqual([]);
  await db.deleteFrom('shared_space_member').where('spaceId', '=', space.id).where('userId', '=', user.id).execute();
  expect(await sut.getTimeBuckets(auth, { ...flags })).toEqual([]);
  expect(await ctx.get(AssetFavoriteRepository).getForAssets(user.id, [asset.id])).toEqual(new Set([asset.id]));
});
