import { Kysely, sql } from 'kysely';

export async function up(db: Kysely<any>): Promise<void> {
  // Intentionally no backfill: duplicate-resolution aliases may identify
  // different bytes, and old external indexes are not current file evidence.
  await sql`ALTER TABLE asset ADD COLUMN "contentChecksum" bytea`.execute(db);
  const indexSql =
    'CREATE INDEX "asset_owner_content_checksum_idx" ON "asset" ("ownerId", "contentChecksum") WHERE ("contentChecksum" IS NOT NULL);';
  await sql.raw(indexSql).execute(db);
  // Partial indexes need their exact code-generated DDL in sql-tools' override
  // registry, otherwise the startup/CLI comparison cannot round-trip the WHERE.
  await sql`INSERT INTO migration_overrides (name, value)
    VALUES ('index_asset_owner_content_checksum_idx',
      ${{ type: 'index', name: 'asset_owner_content_checksum_idx', sql: indexSql }}::jsonb)`.execute(db);
}

export async function down(db: Kysely<any>): Promise<void> {
  await sql`DROP INDEX asset_owner_content_checksum_idx`.execute(db);
  await sql`DELETE FROM migration_overrides WHERE name = 'index_asset_owner_content_checksum_idx'`.execute(db);
  await sql`ALTER TABLE asset DROP COLUMN "contentChecksum"`.execute(db);
}
