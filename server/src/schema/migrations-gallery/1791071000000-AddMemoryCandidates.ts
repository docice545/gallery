import { Kysely, sql } from 'kysely';

export async function up(db: Kysely<any>): Promise<void> {
  await sql`CREATE TABLE "memory_candidate" (
    "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    "ownerId" uuid NOT NULL REFERENCES "user" ("id") ON DELETE CASCADE,
    "memoryId" uuid REFERENCES "memory" ("id") ON DELETE SET NULL,
    "fingerprint" character varying NOT NULL,
    "assetIds" jsonb NOT NULL,
    "state" character varying NOT NULL CHECK ("state" IN ('pending', 'saved', 'dismissed')),
    "remindAt" timestamptz NOT NULL,
    "createdAt" timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT "memory_candidate_owner_fingerprint_uq" UNIQUE ("ownerId", "fingerprint")
  )`.execute(db);
  await sql`CREATE INDEX "memory_candidate_ownerId_idx" ON "memory_candidate" ("ownerId")`.execute(db);
  await sql`CREATE INDEX "memory_candidate_memoryId_idx" ON "memory_candidate" ("memoryId")`.execute(db);
}

export async function down(db: Kysely<any>): Promise<void> {
  // Preserve dismissed memories' visibility semantics when rolling back the decision table.
  // Pending proposals are removed; saved memories remain ordinary permanent memories.
  await sql`DELETE FROM "memory" USING "memory_candidate" WHERE "memory"."id" = "memory_candidate"."memoryId"
    AND "memory_candidate"."state" <> 'saved'`.execute(db);
  await sql`DROP TABLE "memory_candidate"`.execute(db);
}
