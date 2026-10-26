import { Kysely, type Transaction, sql } from 'kysely';
import { AssetStatus, AssetVisibility } from 'src/enum.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { OcrRepository } from 'src/repositories/ocr.repository.js';
import { DB } from 'src/schema/index.js';
import { BaseService } from 'src/services/base.service.js';
import { newMediumService } from 'test/medium.factory.js';
import { factory } from 'test/small.factory.js';
import { getKyselyDB } from 'test/utils.js';

let database: Kysely<DB>;
beforeAll(async () => {
  database = await getKyselyDB();
});
afterAll(async () => {
  await database.destroy();
});

const newAsset = async () => {
  const { ctx } = newMediumService(BaseService, { database, real: [OcrRepository], mock: [LoggingRepository] });
  const { user } = await ctx.newUser();
  const { asset } = await ctx.newAsset({ ownerId: user.id });
  return asset;
};
const save = (db: Kysely<DB>, assetId: string, text = 'synthetic OCR') =>
  new OcrRepository(db).upsert(assetId, [factory.assetOcr({ assetId, text })], text);

// Enforce both serializations with real row locks on separate PostgreSQL connections.
// Merely scheduling two promises would not prove that either operation actually overlapped.
const compete = async <A, B>(
  first: (tx: Transaction<DB>) => Promise<A>,
  second: (tx: Transaction<DB>) => Promise<B>,
) => {
  const locked = Promise.withResolvers<void>();
  const release = Promise.withResolvers<void>();
  const waiter = Promise.withResolvers<number>();
  const a = database.transaction().execute(async (tx) => {
    const result = await first(tx);
    locked.resolve();
    await release.promise;
    return result;
  });
  void a.catch(locked.reject);
  await locked.promise;
  const b = database.transaction().execute(async (tx) => {
    const { rows } = await sql<{ pid: number }>`select pg_backend_pid() as pid`.execute(tx);
    waiter.resolve(rows[0].pid);
    return second(tx);
  });
  void b.catch(waiter.reject);
  try {
    const pid = await waiter.promise;
    await expect
      .poll(
        async () => {
          const { rows } = await sql<{ wait: string | null }>`
        select wait_event_type as wait from pg_stat_activity where pid = ${pid}`.execute(database);
          return rows[0]?.wait;
        },
        { timeout: 2000, interval: 5 },
      )
      .toBe('Lock');
  } finally {
    release.resolve();
    await Promise.allSettled([a, b]);
  }
  return Promise.all([a, b]);
};

const expectAbsent = async (assetId: string) => {
  for (const table of ['asset_ocr', 'ocr_search', 'asset_job_status'] as const) {
    await expect(
      database.selectFrom(table).select('assetId').where('assetId', '=', assetId).execute(),
    ).resolves.toEqual([]);
  }
};

describe('OCR persistence competing with asset deletion', () => {
  it('deletion commits first: the waiting OCR writer skips without a foreign key violation', async () => {
    const asset = await newAsset();
    const [, written] = await compete(
      (tx) => tx.deleteFrom('asset').where('id', '=', asset.id).execute(),
      (tx) => save(tx, asset.id),
    );
    expect(written).toBe(false);
    await expectAbsent(asset.id);
  });

  it('OCR commits first: delete waits for all results and the completion marker, then cascades them', async () => {
    const asset = await newAsset();
    const [written] = await compete(
      (tx) => save(tx, asset.id),
      (tx) => tx.deleteFrom('asset').where('id', '=', asset.id).execute(),
    );
    expect(written).toBe(true);
    await expectAbsent(asset.id);
  });

  it('serializes duplicate OCR writers without retaining duplicate boxes', async () => {
    const asset = await newAsset();
    const results = await compete(
      (tx) => save(tx, asset.id, 'first'),
      (tx) => save(tx, asset.id, 'second'),
    );
    expect(results).toEqual([true, true]);
    await expect(new OcrRepository(database).getByAssetId(asset.id)).resolves.toEqual([
      expect.objectContaining({ text: 'second' }),
    ]);
    await expect(
      database.selectFrom('ocr_search').select('text').where('assetId', '=', asset.id).execute(),
    ).resolves.toEqual([{ text: 'second' }]);
  });

  it('rolls back the previous results on an unrelated child foreign key failure', async () => {
    const asset = await newAsset();
    await save(database, asset.id, 'previous result');
    const previous = await new OcrRepository(database).getByAssetId(asset.id);
    const previousStatus = await database
      .selectFrom('asset_job_status')
      .selectAll()
      .where('assetId', '=', asset.id)
      .execute();
    await expect(
      new OcrRepository(database).upsert(
        asset.id,
        [factory.assetOcr({ assetId: '00000000-0000-4000-8000-000000000001', text: 'invalid association' })],
        'must not persist',
      ),
    ).rejects.toMatchObject({ code: '23503', constraint_name: 'asset_ocr_assetId_fkey' });
    await expect(new OcrRepository(database).getByAssetId(asset.id)).resolves.toEqual(previous);
    await expect(
      database.selectFrom('ocr_search').select('text').where('assetId', '=', asset.id).execute(),
    ).resolves.toEqual([{ text: 'previous result' }]);
    await expect(
      database.selectFrom('asset_job_status').selectAll().where('assetId', '=', asset.id).execute(),
    ).resolves.toEqual(previousStatus);
  });

  it.each([{ status: AssetStatus.Trashed, deletedAt: new Date() }, { visibility: AssetVisibility.Hidden }])(
    'skips an asset that became ineligible during OCR: %s',
    async (changes) => {
      const asset = await newAsset();
      await database.updateTable('asset').set(changes).where('id', '=', asset.id).execute();
      await expect(save(database, asset.id)).resolves.toBe(false);
      await expectAbsent(asset.id);
    },
  );

  it('rolls back both result tables if recording completion fails', async () => {
    const asset = await newAsset();
    await save(database, asset.id, 'previous result');
    const previous = await new OcrRepository(database).getByAssetId(asset.id);
    const previousStatus = await database
      .selectFrom('asset_job_status')
      .selectAll()
      .where('assetId', '=', asset.id)
      .execute();
    await sql`create function medium_ocr_completion_failure() returns trigger language plpgsql as $$
      begin raise exception 'synthetic completion failure'; end $$`.execute(database);
    await sql`create trigger medium_ocr_completion_failure before insert or update on asset_job_status
      for each row execute function medium_ocr_completion_failure()`.execute(database);
    try {
      await expect(save(database, asset.id, 'must roll back')).rejects.toThrow('synthetic completion failure');
    } finally {
      await sql`drop trigger medium_ocr_completion_failure on asset_job_status`.execute(database);
      await sql`drop function medium_ocr_completion_failure()`.execute(database);
    }
    await expect(new OcrRepository(database).getByAssetId(asset.id)).resolves.toEqual(previous);
    await expect(
      database.selectFrom('ocr_search').select('text').where('assetId', '=', asset.id).execute(),
    ).resolves.toEqual([{ text: 'previous result' }]);
    await expect(
      database.selectFrom('asset_job_status').selectAll().where('assetId', '=', asset.id).execute(),
    ).resolves.toEqual(previousStatus);
  });

  it('preserves other completion markers and atomically records empty OCR', async () => {
    const asset = await newAsset();
    const metadataExtractedAt = new Date('2026-10-01T12:00:00Z');
    await database
      .insertInto('asset_job_status')
      .values({ assetId: asset.id, metadataExtractedAt })
      .onConflict((oc) => oc.column('assetId').doUpdateSet({ metadataExtractedAt }))
      .execute();
    await save(database, asset.id);
    await expect(new OcrRepository(database).upsert(asset.id, [], '')).resolves.toBe(true);
    await expect(new OcrRepository(database).getByAssetId(asset.id)).resolves.toEqual([]);
    await expect(
      database.selectFrom('ocr_search').selectAll().where('assetId', '=', asset.id).execute(),
    ).resolves.toEqual([]);
    await expect(
      database
        .selectFrom('asset_job_status')
        .select(['metadataExtractedAt', 'ocrAt'])
        .where('assetId', '=', asset.id)
        .executeTakeFirst(),
    ).resolves.toEqual({ metadataExtractedAt, ocrAt: expect.any(Date) });
  });
});
