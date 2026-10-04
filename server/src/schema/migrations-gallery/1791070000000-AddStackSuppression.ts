import { Kysely, sql } from 'kysely';

export async function up(db: Kysely<any>): Promise<void> {
  await sql`CREATE TABLE "stack_suppression" (
    "assetId" uuid PRIMARY KEY REFERENCES "asset" ("id") ON DELETE CASCADE,
    "ownerId" uuid NOT NULL REFERENCES "user" ("id") ON DELETE CASCADE,
    "createdAt" timestamptz NOT NULL DEFAULT now()
  )`.execute(db);
  await sql`CREATE INDEX "stack_suppression_ownerId_idx" ON "stack_suppression" ("ownerId")`.execute(db);
}

export async function down(db: Kysely<any>): Promise<void> {
  await sql`DROP TABLE "stack_suppression"`.execute(db);
}
