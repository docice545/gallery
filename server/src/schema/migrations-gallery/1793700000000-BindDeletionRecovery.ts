import { Kysely, sql } from 'kysely';

export async function up(db: Kysely<unknown>): Promise<void> {
  await sql`ALTER TABLE asset_deletion_policy ADD COLUMN IF NOT EXISTS "rootIdentities" jsonb NOT NULL DEFAULT '[]'::jsonb`.execute(
    db,
  );
  await sql`ALTER TABLE asset_deletion_policy ADD COLUMN IF NOT EXISTS "recoveryExpiresAt" timestamptz`.execute(db);
  // Legacy grants have neither authenticated recovery nor a bound filesystem identity.
  // No asset/index/Trash/receipt/file is modified; explicit fresh preparation+consent is required.
  await sql`UPDATE asset_deletion_policy SET enabled=false WHERE "rootIdentities"='[]'::jsonb OR "recoveryExpiresAt" IS NULL`.execute(
    db,
  );
}
export function down(): Promise<void> {
  return Promise.reject(
    new Error('Keep bound deletion policies and durable receipts. Use forward-compatible rollback.'),
  );
}
