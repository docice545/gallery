import { Kysely, sql } from 'kysely';
import { AssetStatus } from 'src/enum.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { DB } from 'src/schema/index.js';
import { down, up } from 'src/schema/migrations-gallery/1794050000000-OwnerStorageDeletion.js';
import { BaseService } from 'src/services/base.service.js';
import { newMediumService } from 'test/medium.factory.js';
import { getKyselyDB } from 'test/utils.js';

let db: Kysely<DB>;
beforeAll(async () => {
  db = await getKyselyDB();
});
afterAll(async () => {
  await db.destroy();
});

describe('Build10 to Build11 additive storage authorization migration', () => {
  it('preserves Build10 policies, every asset field, offline tombstones, ownership and album membership on rerun', async () => {
    const { ctx } = newMediumService(BaseService, { database: db, real: [], mock: [LoggingRepository] });
    const { user } = await ctx.newUser();
    const { library } = await ctx.newLibrary({ ownerId: user.id });
    const { asset } = await ctx.newAsset({
      ownerId: user.id,
      libraryId: library.id,
      isExternal: true,
      isOffline: true,
      status: AssetStatus.Active,
      deletedAt: new Date('2026-10-01T10:00:00Z'),
    });
    const { album } = await ctx.newAlbum({ ownerId: user.id });
    await ctx.newAlbumAsset({ albumId: album.id, assetId: asset.id });
    await sql`ALTER TABLE asset_deletion_policy DROP CONSTRAINT IF EXISTS asset_deletion_policy_authorization_mode`.execute(
      db,
    );
    await sql`ALTER TABLE asset_deletion_policy DROP COLUMN "authorizationMode"`.execute(db);
    const inserted = await db
      .insertInto('asset_deletion_policy')
      .values({
        ownerId: user.id,
        scope: 'managed',
        enabled: true,
        roots: ['/synthetic-owner-root'],
        recoveryProof: 'old-signed-proof',
        authorizedBy: user.id,
      })
      .returningAll()
      .executeTakeFirstOrThrow();
    const beforeAsset = await db.selectFrom('asset').selectAll().where('id', '=', asset.id).executeTakeFirstOrThrow();
    const beforeMembership = await db.selectFrom('album_asset').selectAll().where('assetId', '=', asset.id).execute();
    await up(db as Kysely<unknown>);
    await up(db as Kysely<unknown>);
    const policy = await db
      .selectFrom('asset_deletion_policy')
      .selectAll()
      .where('ownerId', '=', user.id)
      .executeTakeFirstOrThrow();
    expect(policy).toEqual({ ...inserted, authorizationMode: 'recovery' });
    expect(await db.selectFrom('asset').selectAll().where('id', '=', asset.id).executeTakeFirstOrThrow()).toEqual(
      beforeAsset,
    );
    expect(await db.selectFrom('album_asset').selectAll().where('assetId', '=', asset.id).execute()).toEqual(
      beforeMembership,
    );
  });

  it('rollback disables only storage-mode grants, retaining legacy grants and durable receipts', async () => {
    const { ctx } = newMediumService(BaseService, { database: db, real: [], mock: [LoggingRepository] });
    const { user } = await ctx.newUser();
    await db
      .insertInto('asset_deletion_policy')
      .values([
        {
          ownerId: user.id,
          scope: 'managed',
          authorizationMode: 'storage',
          enabled: true,
          roots: ['/synthetic-owner-root'],
          recoveryProof: '',
          authorizedBy: user.id,
        },
        {
          ownerId: user.id,
          scope: 'legacy',
          authorizationMode: 'recovery',
          enabled: true,
          roots: ['/synthetic-legacy-root'],
          recoveryProof: 'old-signed-proof',
          authorizedBy: user.id,
        },
      ])
      .execute();
    const receiptsBefore = await db.selectFrom('asset_deletion_tombstone').selectAll().execute();
    await down(db as Kysely<unknown>);
    await down(db as Kysely<unknown>);
    const policies = await db.selectFrom('asset_deletion_policy').selectAll().where('ownerId', '=', user.id).execute();
    expect(policies.find((policy) => policy.scope === 'managed')).toMatchObject({
      authorizationMode: 'storage',
      enabled: false,
    });
    expect(policies.find((policy) => policy.scope === 'legacy')).toMatchObject({
      authorizationMode: 'recovery',
      enabled: true,
    });
    expect(await db.selectFrom('asset_deletion_tombstone').selectAll().execute()).toEqual(receiptsBefore);
  });
});
