import { type Kysely, sql } from 'kysely';
import { InjectKysely } from 'nestjs-kysely';
import { DummyValue, GenerateSql } from 'src/decorators.js';
import { AssetStatus } from 'src/enum.js';
import { DB } from 'src/schema/index.js';
import { DeletionError } from 'src/utils/authorized-deletion.js';

export class TrashRepository {
  constructor(@InjectKysely() private db: Kysely<DB>) {}

  private inTransaction<T>(action: (tx: Kysely<DB>) => Promise<T>): Promise<T> {
    return this.db.isTransaction ? action(this.db) : this.db.transaction().execute(action);
  }

  getDeletedIds(): AsyncIterableIterator<{ id: string }> {
    return this.db.selectFrom('asset').select(['id']).where('status', '=', AssetStatus.Deleted).stream();
  }

  @GenerateSql({ params: [DummyValue.UUID] })
  async restore(userId: string): Promise<number> {
    return this.inTransaction(async (tx) => {
      await sql`select pg_advisory_xact_lock(hashtextextended(${userId}, 731))`.execute(tx);
      const { numUpdatedRows } = await tx
        .updateTable('asset')
        .where('ownerId', '=', userId)
        .where('status', '=', AssetStatus.Trashed)
        .where((eb) =>
          eb.not(
            eb.exists(eb.selectFrom('asset_deletion_tombstone').select('assetId').whereRef('assetId', '=', 'asset.id')),
          ),
        )
        .set({ status: AssetStatus.Active, deletedAt: null })
        .executeTakeFirst();
      return Number(numUpdatedRows);
    });
  }

  @GenerateSql({ params: [DummyValue.UUID] })
  async empty(userId: string): Promise<number> {
    const { numUpdatedRows } = await this.db
      .updateTable('asset')
      .where('ownerId', '=', userId)
      .where('status', '=', AssetStatus.Trashed)
      .set({ status: AssetStatus.Deleted })
      .executeTakeFirst();

    return Number(numUpdatedRows);
  }

  @GenerateSql({ params: [[DummyValue.UUID]] })
  async restoreAll(ids: string[], ownerId?: string): Promise<string[]> {
    if (ids.length === 0) return [];
    return this.inTransaction(async (tx) => {
      if (ownerId) {
        await sql`select pg_advisory_xact_lock(hashtextextended(${ownerId}, 731))`.execute(tx);
        const receipt = await tx
          .selectFrom('asset_deletion_tombstone')
          .select('assetId')
          .where('ownerId', '=', ownerId)
          .where('assetId', 'in', ids)
          .executeTakeFirst();
        if (receipt) throw new DeletionError('ASSET_PERMANENTLY_DELETED');
      }
      const restored = await tx
        .updateTable('asset')
        .where('status', '=', AssetStatus.Trashed)
        .where('id', 'in', ids)
        .$if(ownerId !== undefined, (query) => query.where('ownerId', '=', ownerId!))
        .where((eb) =>
          eb.not(
            eb.exists(eb.selectFrom('asset_deletion_tombstone').select('assetId').whereRef('assetId', '=', 'asset.id')),
          ),
        )
        .set({ status: AssetStatus.Active, deletedAt: null })
        .returning('id')
        .execute();
      return restored.map(({ id }) => id);
    });
  }
}
