import { Kysely, sql } from 'kysely';

export async function up(db: Kysely<any>): Promise<void> {
  // Only client sync metadata changes. No asset, media, queue, or deletion intent is mutated.
  await sql`update session set "isPendingSyncReset" = true
    where exists (select 1 from session_sync_checkpoint c where c."sessionId" = session.id)`.execute(db);
}

export async function down(): Promise<void> {
  // A completed client cache reset cannot be undone; application/catalog data is unchanged.
}
