import { Kysely, sql } from 'kysely';
import { Migration, Migrator } from 'kysely/migration';
import { resolve } from 'node:path';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { CompositeMigrationProvider } from 'src/schema/composite-migration-provider.js';
import { DB } from 'src/schema/index.js';
import { down, up } from 'src/schema/migrations-gallery/1796000000400-AddVerifiedAssetContentChecksum.js';
import { AssetMediaService } from 'src/services/asset-media.service.js';
import { newMediumService } from 'test/medium.factory.js';
import { getKyselyDB } from 'test/utils.js';

const migrationName = '1796000000400-AddVerifiedAssetContentChecksum';
let db: Kysely<DB>;
beforeAll(async () => {
  db = await getKyselyDB();
});
afterAll(async () => {
  await db.destroy();
});

const migrate = (catalog: Record<string, Migration>) =>
  new Migrator({
    db,
    provider: { getMigrations: () => Promise.resolve(catalog) },
    allowUnorderedMigrations: true,
    migrationTableName: 'kysely_migrations',
    migrationLockTableName: 'kysely_migrations_lock',
  }).migrateToLatest();

it('adds a nullable proof without rewriting existing asset identity or defaults', async () => {
  const { rows } = await sql<{ nullable: string; defaultValue: string | null; type: string }>`
    select is_nullable as nullable, column_default as "defaultValue", data_type as type
    from information_schema.columns
    where table_schema = 'public' and table_name = 'asset' and column_name = 'contentChecksum'
  `.execute(db);
  expect(rows).toEqual([{ nullable: 'YES', defaultValue: null, type: 'bytea' }]);
  const index = await sql<{ definition: string }>`
    select indexdef as definition from pg_indexes
    where schemaname = 'public' and indexname = 'asset_owner_content_checksum_idx'
  `.execute(db);
  expect(index.rows[0].definition).toContain('("ownerId", "contentChecksum")');
  expect(index.rows[0].definition).toContain('WHERE ("contentChecksum" IS NOT NULL)');
});

it('can reverse and reapply the derived column in a rolled-back isolated transaction', async () => {
  const { ctx } = newMediumService(AssetMediaService, {
    database: db,
    real: [AssetRepository],
    mock: [LoggingRepository],
  });
  const { user } = await ctx.newUser();
  const proof = Buffer.alloc(20, 7);
  const { result: asset } = await ctx.newAsset({ ownerId: user.id, contentChecksum: proof });
  const identity = { id: asset.id, checksum: asset.checksum, originalPath: asset.originalPath };
  const counts = await sql<{ assets: string; receipts: string }>`
    select (select count(*) from asset)::text as assets,
           (select count(*) from asset_deletion_tombstone)::text as receipts
  `.execute(db);
  const rollback = new Error('isolated migration rehearsal rollback');
  await expect(
    db.transaction().execute(async (tx) => {
      await down(tx);
      const unchanged = await tx
        .selectFrom('asset')
        .select(['id', 'checksum', 'originalPath'])
        .where('id', '=', asset.id)
        .executeTakeFirstOrThrow();
      expect(unchanged).toEqual(identity);
      const removed = await sql<{ count: string }>`
      select count(*)::text as count from information_schema.columns
      where table_schema = 'public' and table_name = 'asset' and column_name = 'contentChecksum'
    `.execute(tx);
      expect(removed.rows[0].count).toBe('0');
      await up(tx);
      const reapplied = await tx
        .selectFrom('asset')
        .select('contentChecksum')
        .where('id', '=', asset.id)
        .executeTakeFirstOrThrow();
      expect(reapplied.contentChecksum).toBeNull();
      const after = await sql<{ assets: string; receipts: string }>`
      select (select count(*) from asset)::text as assets,
             (select count(*) from asset_deletion_tombstone)::text as receipts
    `.execute(tx);
      expect(after.rows).toEqual(counts.rows);
      throw rollback;
    }),
  ).rejects.toBe(rollback);
  const retained = await db
    .selectFrom('asset')
    .select('contentChecksum')
    .where('id', '=', asset.id)
    .executeTakeFirstOrThrow();
  expect(retained.contentChecksum).toEqual(proof);
});

it('requires the new migration module even when rolling back to the previous runtime policy', async () => {
  const provider = new CompositeMigrationProvider([
    resolve('src/schema/migrations'),
    resolve('src/schema/migrations-gallery'),
  ]);
  const current = await provider.getMigrations();
  expect(current[migrationName]).toBeDefined();
  const oldCatalog = { ...current };
  delete oldCatalog[migrationName];
  const missing = await migrate(oldCatalog);
  expect(missing.error).toBeInstanceOf(Error);
  expect((missing.error as Error).message).toContain('previously executed migration');
  expect((missing.error as Error).message).toContain(migrationName);
  const compatible = await migrate({ ...oldCatalog, [migrationName]: current[migrationName] });
  expect(compatible.error).toBeUndefined();
  expect(compatible.results).toEqual([]);
});
