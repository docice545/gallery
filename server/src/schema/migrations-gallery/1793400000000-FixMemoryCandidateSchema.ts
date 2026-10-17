import { Kysely, sql } from 'kysely';

export async function up(db: Kysely<unknown>): Promise<void> {
  await sql`ALTER TABLE "memory_candidate" ALTER COLUMN "id" SET DEFAULT uuid_generate_v4()`.execute(db);
  await sql`ALTER TABLE "memory_candidate" DROP CONSTRAINT IF EXISTS "memory_candidate_state_check"`.execute(db);
  await sql`ALTER TABLE "memory_candidate" DROP CONSTRAINT IF EXISTS "memory_candidate_owner_fingerprint_uq"`.execute(db);
  await sql`CREATE UNIQUE INDEX IF NOT EXISTS "memory_candidate_owner_fingerprint_uq" ON "memory_candidate" ("ownerId", "fingerprint")`.execute(db);
}

export async function down(): Promise<void> {
  // Intentionally empty: reverting would recreate the schema drift.
}
