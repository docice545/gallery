import { Kysely, sql } from 'kysely';

// Additive fork extension only: upstream assets/libraries/authentication are unchanged.
export async function up(db: Kysely<unknown>): Promise<void> {
  await sql`ALTER TABLE asset_deletion_policy ADD COLUMN IF NOT EXISTS "authorizationMode" text NOT NULL DEFAULT 'recovery'`.execute(
    db,
  );
  await sql`DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='asset_deletion_policy_authorization_mode') THEN
      ALTER TABLE asset_deletion_policy ADD CONSTRAINT asset_deletion_policy_authorization_mode CHECK ("authorizationMode" IN ('recovery', 'storage'));
    END IF;
  END $$`.execute(db);
}

export async function down(db: Kysely<unknown>): Promise<void> {
  // Build10 rejects storage grants (empty recoveryProof and NULL expiry). Keep
  // identities and suppression receipts for safe forward-compatible rollback.
  await sql`UPDATE asset_deletion_policy SET enabled=false WHERE "authorizationMode"='storage'`.execute(db);
}
