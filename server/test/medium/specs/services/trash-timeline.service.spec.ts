import { Kysely } from 'kysely';
import type { TimeBucketAssetResponseDto } from 'src/dtos/time-bucket.dto.js';
import { AssetOrder, AssetOrderBy, AssetStatus, TimeBucketSize } from 'src/enum.js';
import { AccessRepository } from 'src/repositories/access.repository.js';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { PartnerRepository } from 'src/repositories/partner.repository.js';
import { SharedSpaceRepository } from 'src/repositories/shared-space.repository.js';
import { TrashRepository } from 'src/repositories/trash.repository.js';
import { DB } from 'src/schema/index.js';
import { TimelineService } from 'src/services/timeline.service.js';
import { newMediumService } from 'test/medium.factory.js';
import { factory } from 'test/small.factory.js';
import { getKyselyDB } from 'test/utils.js';

let database: Kysely<DB>;
const setup = () =>
  newMediumService(TimelineService, {
    database,
    real: [AssetRepository, AccessRepository, PartnerRepository, SharedSpaceRepository],
    mock: [LoggingRepository],
  });

beforeAll(async () => {
  database = await getKyselyDB();
});

afterAll(async () => {
  await database.destroy();
});

const fixture = async () => {
  const { sut, ctx } = setup();
  const { user } = await ctx.newUser();
  const { user: otherOwner } = await ctx.newUser();
  const auth = factory.auth({ user });
  const create = async (ownerId: string, captured: string, deleted: string | null) => {
    const captureDate = new Date(captured);
    const { asset } = await ctx.newAsset({
      ownerId,
      fileCreatedAt: captureDate,
      localDateTime: captureDate,
      deletedAt: deleted ? new Date(deleted) : null,
      status: deleted ? AssetStatus.Trashed : AssetStatus.Active,
      width: 300,
      height: 400,
    });
    await ctx.newExif({ assetId: asset.id, timeZone: 'UTC' });
    return asset;
  };
  const older = await create(user.id, '2024-10-05T10:00:00Z', '2026-10-04T23:59:59Z');
  const latest = await create(user.id, '2020-01-02T10:00:00Z', '2026-10-05T11:00:00Z');
  const morning = await create(user.id, '2025-07-03T10:00:00Z', '2026-10-05T09:00:00Z');
  const notTrashed = await create(user.id, '2026-10-05T12:00:00Z', null);
  const other = await create(otherOwner.id, '2024-10-05T10:00:00Z', '2026-10-05T13:00:00Z');
  return { sut, auth, older, latest, morning, notTrashed, other };
};

describe('Trash timeline uses authoritative deletion timestamps', () => {
  const options = { isTrashed: true, orderBy: AssetOrderBy.DeletedAt, order: AssetOrder.Desc };

  it('excludes active offline external index tombstones from user Trash', async () => {
    const { sut, auth, latest, morning, older } = await fixture();
    const { ctx } = setup();
    const { library } = await ctx.newLibrary({ ownerId: auth.user.id });
    const { asset: offline } = await ctx.newAsset({
      ownerId: auth.user.id,
      libraryId: library.id,
      isExternal: true,
      isOffline: true,
      status: AssetStatus.Active,
      deletedAt: new Date('2026-10-05T15:00:00Z'),
      fileCreatedAt: new Date('2024-01-02T10:00:00Z'),
      localDateTime: new Date('2024-01-02T10:00:00Z'),
      width: 300,
      height: 400,
    });
    await ctx.newExif({ assetId: offline.id, timeZone: 'UTC' });
    const response = JSON.parse(
      await sut.getTimeBucket(auth, { ...options, timeBucket: '2026-10-01' }),
    ) as TimeBucketAssetResponseDto;
    expect(response.id).not.toContain(offline.id);
    expect(response.id).toEqual([latest.id, morning.id, older.id]);
    const buckets = await sut.getTimeBuckets(auth, { ...options, bucketSize: TimeBucketSize.Month });
    expect(buckets).toEqual([{ count: 3, timeBucket: '2026-10-01' }]);
    const covers = await sut.getTimeBucketCovers(auth, {
      ...options,
      bucketSize: TimeBucketSize.Day,
      timeBuckets: ['2026-10-05'],
    });
    expect(covers[0].representativeAssetId).toBe(latest.id);
    const row = await database
      .selectFrom('asset')
      .select(['status', 'deletedAt'])
      .where('id', '=', offline.id)
      .executeTakeFirstOrThrow();
    expect(row.status).toBe(AssetStatus.Active);
    expect(row.deletedAt).not.toBeNull();
  });

  it('keeps failed authorized deletion visible, excluding legacy Deleted rows without a receipt', async () => {
    const { sut, auth, latest, morning, older } = await fixture();
    await database
      .updateTable('asset')
      .set({ status: AssetStatus.Deleted })
      .where('id', 'in', [latest.id, morning.id])
      .execute();
    await database
      .insertInto('asset_deletion_tombstone')
      .values({
        assetId: latest.id,
        ownerId: auth.user.id,
        libraryId: null,
        operationId: latest.id,
        scope: 'managed',
        originalPath: latest.originalPath,
        checksum: latest.checksum,
        checksumAlgorithm: latest.checksumAlgorithm,
        contentChecksum: latest.checksum,
        aliases: [],
        authorization: {
          actor: auth.user.id,
          recoveryProof: 'a'.repeat(64),
          policyUpdatedAt: new Date().toISOString(),
        },
        files: [],
        state: 'failed',
        errorCode: 'ORIGINAL_DELETE_FAILED',
      })
      .execute();
    const response = JSON.parse(
      await sut.getTimeBucket(auth, { ...options, timeBucket: '2026-10-01' }),
    ) as TimeBucketAssetResponseDto;
    expect(response.id).toEqual([latest.id, older.id]);
    expect(await sut.getTimeBuckets(auth, { ...options, bucketSize: TimeBucketSize.Month })).toEqual([
      { count: 2, timeBucket: '2026-10-01' },
    ]);
  });

  it('groups only the owner trash by deletion day/month/year, newest first', async () => {
    const { sut, auth } = await fixture();
    await expect(sut.getTimeBuckets(auth, { ...options, bucketSize: TimeBucketSize.Day })).resolves.toEqual([
      { count: 2, timeBucket: '2026-10-05' },
      { count: 1, timeBucket: '2026-10-04' },
    ]);
    await expect(sut.getTimeBuckets(auth, { ...options, bucketSize: TimeBucketSize.Month })).resolves.toEqual([
      { count: 3, timeBucket: '2026-10-01' },
    ]);
    await expect(sut.getTimeBuckets(auth, { ...options, bucketSize: TimeBucketSize.Year })).resolves.toEqual([
      { count: 3, timeBucket: '2026-01-01' },
    ]);
  });

  it('returns aligned deletion dates and orders full buckets independently of capture date', async () => {
    const { sut, auth, latest, morning, older } = await fixture();
    const response = JSON.parse(
      await sut.getTimeBucket(auth, { ...options, timeBucket: '2026-10-01' }),
    ) as TimeBucketAssetResponseDto;
    expect(response.id).toEqual([latest.id, morning.id, older.id]);
    expect(response.deletedAt).toHaveLength(response.id.length);
    expect(response.deletedAt!.map((date) => new Date(date!).toISOString())).toEqual([
      '2026-10-05T11:00:00.000Z',
      '2026-10-05T09:00:00.000Z',
      '2026-10-04T23:59:59.000Z',
    ]);
    expect(response.fileCreatedAt.map((date) => new Date(date).getUTCFullYear())).toEqual([2020, 2025, 2024]);
    expect(response.isTrashed).toEqual([true, true, true]);
    const ascending = JSON.parse(
      await sut.getTimeBucket(auth, { ...options, order: AssetOrder.Asc, timeBucket: '2026-10-01' }),
    ) as TimeBucketAssetResponseDto;
    expect(ascending.id).toEqual([older.id, morning.id, latest.id]);
  });

  it('selects trash covers using the same deletion date and owner scope', async () => {
    const { sut, auth, latest, older } = await fixture();
    const covers = await sut.getTimeBucketCovers(auth, {
      ...options,
      bucketSize: TimeBucketSize.Day,
      timeBuckets: ['2026-10-05', '2026-10-04'],
    });
    expect(covers.map((cover) => [cover.timeBucket, cover.representativeAssetId])).toEqual([
      ['2026-10-05', latest.id],
      ['2026-10-04', older.id],
    ]);
  });

  it('restored assets leave trash and retain original capture date in the regular timeline', async () => {
    const { sut, auth, latest } = await fixture();
    await new TrashRepository(database).restoreAll([latest.id]);
    const trash = JSON.parse(
      await sut.getTimeBucket(auth, { ...options, timeBucket: '2026-10-01' }),
    ) as TimeBucketAssetResponseDto;
    expect(trash.id).not.toContain(latest.id);
    const regular = JSON.parse(
      await sut.getTimeBucket(auth, { timeBucket: '2020-01-01', orderBy: AssetOrderBy.TakenAt }),
    ) as TimeBucketAssetResponseDto;
    expect(regular.id).toEqual([latest.id]);
    expect(regular.deletedAt).toEqual([null]);
    expect(new Date(regular.fileCreatedAt[0]).toISOString()).toBe('2020-01-02T10:00:00.000Z');
  });

  it('a restored row cannot be claimed by a queued retention deletion', async () => {
    const { latest } = await fixture();
    const assets = new AssetRepository(database);
    const trash = new TrashRepository(database);
    expect(await trash.restoreAll([latest.id])).toEqual([latest.id]);
    expect(await assets.claimExpiredDeletion(latest.id, new Date('2026-10-06T00:00:00Z'))).toBe(false);
    const row = await database.selectFrom('asset').selectAll().where('id', '=', latest.id).executeTakeFirstOrThrow();
    expect(row.status).toBe(AssetStatus.Active);
    expect(row.deletedAt).toBeNull();
    expect(row.fileCreatedAt).toEqual(latest.fileCreatedAt);
  });

  it('a new Trash timestamp is protected from the old queued retention cutoff', async () => {
    const { latest } = await fixture();
    const assets = new AssetRepository(database);
    await new TrashRepository(database).restoreAll([latest.id]);
    await assets.updateAll([latest.id], { status: AssetStatus.Trashed, deletedAt: new Date('2026-10-09T00:00:00Z') });
    expect(await assets.claimExpiredDeletion(latest.id, new Date('2026-10-06T00:00:00Z'))).toBe(false);
    const row = await database.selectFrom('asset').selectAll().where('id', '=', latest.id).executeTakeFirstOrThrow();
    expect(row.status).toBe(AssetStatus.Trashed);
    expect(row.deletedAt).toEqual(new Date('2026-10-09T00:00:00Z'));
  });

  it('when retention wins, Restore returns only still-restorable IDs and leaves the claim Deleted', async () => {
    const { latest, morning } = await fixture();
    const assets = new AssetRepository(database);
    expect(await assets.claimExpiredDeletion(latest.id, new Date('2026-10-06T00:00:00Z'))).toBe(true);
    expect(await new TrashRepository(database).restoreAll([latest.id, morning.id])).toEqual([morning.id]);
    const row = await database.selectFrom('asset').selectAll().where('id', '=', latest.id).executeTakeFirstOrThrow();
    expect(row.status).toBe(AssetStatus.Deleted);
  });
});
