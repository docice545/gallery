import { Kysely } from 'kysely';
import { AssetStatus, SyncEntityType, SyncRequestType } from 'src/enum.js';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { DB } from 'src/schema/index.js';
import { SyncTestContext } from 'test/medium.factory.js';
import { factory } from 'test/small.factory.js';
import { getKyselyDB } from 'test/utils.js';

let defaultDatabase: Kysely<DB>;

const setup = async (db?: Kysely<DB>) => {
  const ctx = new SyncTestContext(db || defaultDatabase);
  const { auth, user, session } = await ctx.newSyncAuthUser();
  return { auth, user, session, ctx };
};

beforeAll(async () => {
  defaultDatabase = await getKyselyDB();
});

describe(SyncEntityType.AssetV2, () => {
  for (const type of [SyncRequestType.AssetsV2, SyncRequestType.LibraryAssetsV1]) {
    it(`distinguishes an offline index tombstone from user Trash in ${type}`, async () => {
      const { auth, ctx } = await setup();
      const { library } = await ctx.newLibrary({ ownerId: auth.user.id });
      const { asset } = await ctx.newAsset({
        ownerId: auth.user.id,
        libraryId: library.id,
        status: AssetStatus.Active,
        isOffline: true,
        isExternal: true,
        deletedAt: new Date('2026-10-05T00:00:00Z'),
      });
      const response = await ctx.syncStream(auth, [type]);
      const event = response.find((event) => 'id' in event.data && event.data.id === asset.id);
      expect(event).toBeDefined();
      expect(event!.data).toMatchObject({
        id: asset.id,
        isTrashed: false,
        deletedAt: new Date(asset.deletedAt!).toISOString(),
      });
      expect(event!.data).not.toHaveProperty('status');
    });
  }

  it('should detect and sync the first asset', async () => {
    const originalFileName = 'firstAsset';
    const checksum = '1115vHcVkZzNp3Q9G+FEA0nu6zUbGb4Tj4UOXkN0wRA=';
    const thumbhash = '2225vHcVkZzNp3Q9G+FEA0nu6zUbGb4Tj4UOXkN0wRA=';
    const date = new Date().toISOString();

    const { auth, ctx } = await setup();
    const { asset } = await ctx.newAsset({
      originalFileName,
      ownerId: auth.user.id,
      checksum: Buffer.from(checksum, 'base64'),
      thumbhash: Buffer.from(thumbhash, 'base64'),
      fileCreatedAt: date,
      fileModifiedAt: date,
      localDateTime: date,
      createdAt: date,
      deletedAt: null,
      duration: 600_000,
      libraryId: null,
      width: 1920,
      height: 1080,
    });

    const response = await ctx.syncStream(auth, [SyncRequestType.AssetsV2]);
    expect(response).toEqual([
      {
        ack: expect.any(String),
        data: {
          id: asset.id,
          originalFileName,
          ownerId: asset.ownerId,
          thumbhash,
          checksum,
          deletedAt: asset.deletedAt,
          fileCreatedAt: asset.fileCreatedAt,
          fileModifiedAt: asset.fileModifiedAt,
          createdAt: asset.createdAt,
          isFavorite: asset.isFavorite,
          localDateTime: asset.localDateTime,
          type: asset.type,
          visibility: asset.visibility,
          duration: asset.duration,
          stackId: null,
          livePhotoVideoId: null,
          libraryId: asset.libraryId,
          width: asset.width,
          height: asset.height,
          isEdited: asset.isEdited,
        },
        type: 'AssetV2',
      },
      expect.objectContaining({ type: SyncEntityType.SyncCompleteV1 }),
    ]);

    await ctx.syncAckAll(auth, response);
    await ctx.assertSyncIsComplete(auth, [SyncRequestType.AssetsV2]);
  });

  it('should detect and sync a deleted asset', async () => {
    const { auth, ctx } = await setup();
    const assetRepo = ctx.get(AssetRepository);
    const { asset } = await ctx.newAsset({ ownerId: auth.user.id });
    await assetRepo.remove(asset);

    const response = await ctx.syncStream(auth, [SyncRequestType.AssetsV2]);
    expect(response).toEqual([
      {
        ack: expect.any(String),
        data: {
          assetId: asset.id,
        },
        type: 'AssetDeleteV1',
      },
      expect.objectContaining({ type: SyncEntityType.SyncCompleteV1 }),
    ]);

    await ctx.syncAckAll(auth, response);
    await ctx.assertSyncIsComplete(auth, [SyncRequestType.AssetsV2]);
  });

  it('should not sync an asset or asset delete for an unrelated user', async () => {
    const { auth, ctx } = await setup();
    const assetRepo = ctx.get(AssetRepository);
    const { user: user2 } = await ctx.newUser();
    const { session } = await ctx.newSession({ userId: user2.id });
    const { asset } = await ctx.newAsset({ ownerId: user2.id });
    const auth2 = factory.auth({ session, user: user2 });

    expect(await ctx.syncStream(auth2, [SyncRequestType.AssetsV2])).toEqual([
      expect.objectContaining({ type: SyncEntityType.AssetV2 }),
      expect.objectContaining({ type: SyncEntityType.SyncCompleteV1 }),
    ]);
    await ctx.assertSyncIsComplete(auth, [SyncRequestType.AssetsV2]);

    await assetRepo.remove(asset);
    expect(await ctx.syncStream(auth2, [SyncRequestType.AssetsV2])).toEqual([
      expect.objectContaining({ type: SyncEntityType.AssetDeleteV1 }),
      expect.objectContaining({ type: SyncEntityType.SyncCompleteV1 }),
    ]);
    await ctx.assertSyncIsComplete(auth, [SyncRequestType.AssetsV2]);
  });
});
