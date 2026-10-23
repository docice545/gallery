import { Injectable } from '@nestjs/common';
import { Kysely, sql } from 'kysely';
import { InjectKysely } from 'nestjs-kysely';
import { Chunked, DummyValue, GenerateSql } from 'src/decorators.js';
import { DB } from 'src/schema/index.js';
import { retryOnDeadlock } from 'src/utils/database.js';

// Caller-scoped personal favorites. The service supplies the authenticated user's ID.
// Owner writes keep the legacy asset.isFavorite column in the same transaction;
// a non-owner's favorite never changes the owner's asset or its update watermark.
@Injectable()
export class AssetFavoriteRepository {
  constructor(@InjectKysely() private db: Kysely<DB>) {}

  // (E8) Re-favoriting an already-favorited asset must be a no-op, not a constraint violation.
  @GenerateSql({ params: [DummyValue.UUID, [DummyValue.UUID]] })
  @Chunked({ paramIndex: 1 })
  async addAll(userId: string, assetIds: string[]): Promise<void> {
    if (assetIds.length === 0) {
      return;
    }

    await retryOnDeadlock(() =>
      this.db.transaction().execute(async (tx) => {
        await tx
          .selectFrom('asset')
          .select('id')
          .where('ownerId', '=', userId)
          .where('id', 'in', assetIds)
          .orderBy('id')
          .forUpdate()
          .execute();
        const changed = await tx
          .insertInto('asset_favorite')
          .values(assetIds.map((assetId) => ({ userId, assetId })))
          .onConflict((oc) => oc.doNothing())
          .returning('assetId')
          .execute();
        await this.touchOwnedAssets(tx, userId, changed, true);
      }),
    );
  }

  // (E9) Unfavoriting a never-favorited asset must be a no-op, not an error.
  @GenerateSql({ params: [DummyValue.UUID, [DummyValue.UUID]] })
  @Chunked({ paramIndex: 1 })
  async removeAll(userId: string, assetIds: string[]): Promise<void> {
    if (assetIds.length === 0) {
      return;
    }

    await retryOnDeadlock(() =>
      this.db.transaction().execute(async (tx) => {
        await tx
          .selectFrom('asset')
          .select('id')
          .where('ownerId', '=', userId)
          .where('id', 'in', assetIds)
          .orderBy('id')
          .forUpdate()
          .execute();
        const changed = await tx
          .deleteFrom('asset_favorite')
          .where('userId', '=', userId)
          .where('assetId', 'in', assetIds)
          .returning('assetId')
          .execute();
        await this.touchOwnedAssets(tx, userId, changed, false);
      }),
    );
  }

  // Legacy-client compatibility: an app that predates AssetFavoritesV1 only learns a favorite
  // change through the asset streams, i.e. through asset.updateId. Before #763 an owner's favorite
  // was a column write that bumped it, so bump it again — but ONLY for assets the caller owns and
  // whose favorite actually changed. That is exactly the pre-#763 re-sync footprint; a non-owner's
  // favorite never touches the asset, so it still cannot amplify into other users' re-syncs.
  private async touchOwnedAssets(tx: Kysely<DB>, userId: string, changed: { assetId: string }[], isFavorite: boolean) {
    if (changed.length === 0) {
      return;
    }

    await tx
      .updateTable('asset')
      .set({ isFavorite, updatedAt: sql`clock_timestamp()` })
      .where('ownerId', '=', userId)
      .where(
        'id',
        'in',
        changed.map(({ assetId }) => assetId),
      )
      .execute();
  }

  async getForAssets(userId: string, assetIds: string[]): Promise<Set<string>> {
    if (assetIds.length === 0) return new Set();
    const rows = await this.db
      .selectFrom('asset_favorite')
      .select('assetId')
      .where('userId', '=', userId)
      .where('assetId', 'in', assetIds)
      .execute();
    return new Set(rows.map((row) => row.assetId));
  }
}
