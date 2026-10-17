import { Kysely, sql } from 'kysely';
import { gallery_block_deleted_asset, gallery_lock_asset_file_path } from 'src/schema/functions.js';

export async function up(db: Kysely<unknown>): Promise<void> {
  await sql`CREATE TABLE asset_deletion_policy (
    "ownerId" uuid NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
    scope text NOT NULL, enabled boolean NOT NULL DEFAULT false,
    roots jsonb NOT NULL, "recoveryProof" text NOT NULL, "authorizedBy" text NOT NULL,
    "updatedAt" timestamptz NOT NULL DEFAULT now(), PRIMARY KEY ("ownerId", scope)
  )`.execute(db);
  await sql`CREATE TABLE asset_deletion_tombstone (
    "assetId" uuid PRIMARY KEY, "ownerId" uuid NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
    "libraryId" uuid, "operationId" uuid NOT NULL, scope text NOT NULL,
    "originalPath" text NOT NULL, checksum bytea NOT NULL, "checksumAlgorithm" text NOT NULL, "contentChecksum" bytea NOT NULL,
    aliases jsonb NOT NULL, "authorization" jsonb NOT NULL, files jsonb NOT NULL, state text NOT NULL CHECK (state IN ('preparing', 'pending', 'failed', 'files-removed', 'complete')),
    "errorCode" text, "createdAt" timestamptz NOT NULL DEFAULT now()
  )`.execute(db);
  await sql`CREATE INDEX "asset_deletion_tombstone_ownerId_idx" ON asset_deletion_tombstone ("ownerId")`.execute(db);
  await sql`CREATE INDEX asset_deletion_owner_checksum ON asset_deletion_tombstone ("ownerId", checksum)`.execute(db);
  await sql`CREATE INDEX asset_deletion_library_path ON asset_deletion_tombstone ("libraryId", "originalPath")`.execute(
    db,
  );
  // Check at INSERT, not only at preflight: a previously queued upload/scan cannot recreate an original.
  await sql.raw(gallery_block_deleted_asset.expression).execute(db);
  await sql`CREATE TRIGGER gallery_block_deleted_asset BEFORE INSERT OR UPDATE OF "originalPath", "ownerId", checksum ON asset
    FOR EACH ROW EXECUTE FUNCTION gallery_block_deleted_asset()`.execute(db);
  await sql.raw(gallery_lock_asset_file_path.expression).execute(db);
  await sql`CREATE TRIGGER gallery_lock_asset_file_path BEFORE INSERT OR UPDATE OF path ON asset_file
    FOR EACH ROW EXECUTE FUNCTION gallery_lock_asset_file_path()`.execute(db);
  for (const fn of [gallery_block_deleted_asset, gallery_lock_asset_file_path]) {
    await sql`INSERT INTO migration_overrides (name, value)
      VALUES (${`function_${fn.name}`}, ${{ type: 'function', name: fn.name, sql: fn.expression }}::jsonb)`.execute(db);
  }
}

export function down(): Promise<void> {
  return Promise.reject(
    new Error(
      'Deletion tombstones must survive rollback. Use the documented forward-compatible rollback, never drop suppression evidence.',
    ),
  );
}
