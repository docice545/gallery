import { Kysely, sql } from 'kysely';

export async function up(db: Kysely<any>): Promise<void> {
  const functionSql =
    'CREATE OR REPLACE FUNCTION gallery_mirror_owner_favorite()\n  RETURNS TRIGGER\n  LANGUAGE PLPGSQL\n  AS $$\n    BEGIN\n      IF TG_OP = \'UPDATE\' AND OLD."isFavorite" IS NOT DISTINCT FROM NEW."isFavorite" THEN\n        RETURN NULL;\n      END IF;\n      IF NEW."isFavorite" THEN\n        INSERT INTO asset_favorite ("userId", "assetId") VALUES (NEW."ownerId", NEW.id) ON CONFLICT DO NOTHING;\n      ELSE\n        DELETE FROM asset_favorite WHERE "userId" = NEW."ownerId" AND "assetId" = NEW.id;\n      END IF;\n      RETURN NULL;\n    END\n  $$;';
  const triggerSql =
    'CREATE OR REPLACE TRIGGER "gallery_mirror_owner_favorite"\n  AFTER INSERT OR UPDATE ON "asset"\n  FOR EACH ROW\n  EXECUTE FUNCTION gallery_mirror_owner_favorite();';
  await sql.raw(functionSql).execute(db);
  await sql.raw(triggerSql).execute(db);
  for (const [type, statement] of [
    ['function', functionSql],
    ['trigger', triggerSql],
  ] as const) {
    await sql`INSERT INTO migration_overrides (name, value) VALUES (${`${type}_gallery_mirror_owner_favorite`},
      ${{ type, name: 'gallery_mirror_owner_favorite', sql: statement }}::jsonb)`.execute(db);
  }
}
export async function down(db: Kysely<any>): Promise<void> {
  await sql`DROP TRIGGER IF EXISTS gallery_mirror_owner_favorite ON asset`.execute(db);
  await sql`DROP FUNCTION IF EXISTS gallery_mirror_owner_favorite()`.execute(db);
  await sql`DELETE FROM migration_overrides WHERE name IN ('function_gallery_mirror_owner_favorite', 'trigger_gallery_mirror_owner_favorite')`.execute(
    db,
  );
}
