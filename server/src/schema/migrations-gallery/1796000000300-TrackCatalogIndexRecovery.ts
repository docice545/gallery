import { Kysely, sql } from 'kysely';
import { gallery_index_projection_changed } from 'src/schema/functions.js';

export async function up(db: Kysely<any>): Promise<void> {
  await sql`CREATE TABLE catalog_projection_audit (
    id uuid PRIMARY KEY DEFAULT immich_uuid_v7(),
    "deletedAt" timestamptz NOT NULL DEFAULT clock_timestamp()
  )`.execute(db);
  await sql`CREATE INDEX "catalog_projection_audit_deletedAt_idx" ON catalog_projection_audit ("deletedAt")`.execute(
    db,
  );
  const functionSql = gallery_index_projection_changed.expression;
  const triggerSql =
    'CREATE OR REPLACE TRIGGER "gallery_index_projection_changed"\n  AFTER UPDATE ON "asset"\n  FOR EACH ROW\n  EXECUTE FUNCTION gallery_index_projection_changed();';
  await sql.raw(functionSql).execute(db);
  await sql.raw(triggerSql).execute(db);
  for (const [type, statement] of [
    ['function', functionSql],
    ['trigger', triggerSql],
  ] as const) {
    await sql`INSERT INTO migration_overrides (name, value) VALUES (${`${type}_gallery_index_projection_changed`},
      ${{ type, name: 'gallery_index_projection_changed', sql: statement }}::jsonb)`.execute(db);
  }
}

export async function down(db: Kysely<any>): Promise<void> {
  // Only disposable cache markers are removed; no asset, policy, or deletion evidence is touched.
  await sql`DROP TRIGGER IF EXISTS gallery_index_projection_changed ON asset`.execute(db);
  await sql`DROP FUNCTION IF EXISTS gallery_index_projection_changed()`.execute(db);
  await sql`DROP TABLE catalog_projection_audit`.execute(db);
  await sql`DELETE FROM migration_overrides WHERE name IN ('function_gallery_index_projection_changed', 'trigger_gallery_index_projection_changed')`.execute(
    db,
  );
}
