import { ConflictException, Injectable, NotFoundException } from '@nestjs/common';
import { type Insertable, type Kysely, type OrderByDirection, type Updateable, sql } from 'kysely';
import { jsonArrayFrom } from 'kysely/helpers/postgres';
import { DateTime } from 'luxon';
import { InjectKysely } from 'nestjs-kysely';
import type { IBulkAsset } from 'src/types.js';
import { Chunked, ChunkedSet, DummyValue, GenerateSql } from 'src/decorators.js';
import { MemorySearchDto } from 'src/dtos/memory.dto.js';
import { AssetOrderWithRandom, AssetVisibility, MemoryType } from 'src/enum.js';
import { DB } from 'src/schema/index.js';
import { MemoryTable } from 'src/schema/tables/memory.table.js';
import { asUuid } from 'src/utils/database.js';
import {
  MemorySuppressedException,
  memoryData,
  memoryFingerprint,
  similarMemoryAssets,
} from 'src/utils/memory-candidate.js';
import {
  type TimelineHiddenScope,
  hiddenFromOwnTimeline,
  spaceAlbumAssetExists,
  timelineHiddenScopeIsEmpty,
} from 'src/utils/shared-space-album-scope.js';

@Injectable()
export class MemoryRepository implements IBulkAsset {
  constructor(@InjectKysely() private db: Kysely<DB>) {}

  async createCandidate(memory: Insertable<MemoryTable>, assetIds: string[]) {
    const ownerId = memory.ownerId;
    const ids = [...new Set(assetIds)];
    const fingerprint = memoryFingerprint(ids);
    return this.db.transaction().execute(async (tx) => {
      await sql`SELECT pg_advisory_xact_lock(hashtext(${ownerId}), 179108)`.execute(tx);
      const history = await tx.selectFrom('memory_candidate').selectAll().where('ownerId', '=', ownerId).execute();
      if (history.some((row) => row.state === 'dismissed' && similarMemoryAssets(ids, row.assetIds))) {
        throw new MemorySuppressedException();
      }
      const existing = history.find((row) => row.fingerprint === fingerprint);
      if (existing) {
        if (existing.state === 'dismissed' || !existing.memoryId)
          throw new ConflictException('Candidate already declined');
        return { ...existing, created: false };
      }
      if (history.some((row) => similarMemoryAssets(ids, row.assetIds))) {
        throw new ConflictException('A similar memory has already been proposed');
      }
      // Do not create an AI duplicate of a standard/rule memory already stored for this owner.
      const memories = await tx
        .selectFrom('memory')
        .select('memory.id')
        .select((eb) =>
          jsonArrayFrom(eb.selectFrom('memory_asset').select('assetId').whereRef('memoriesId', '=', 'memory.id')).as(
            'assets',
          ),
        )
        .where('ownerId', '=', ownerId)
        .where('deletedAt', 'is', null)
        .execute();
      if (
        memories.some((row) =>
          similarMemoryAssets(
            ids,
            row.assets.map((asset) => asset.assetId),
          ),
        )
      ) {
        throw new ConflictException('Enrich the existing memory instead of duplicating it');
      }
      const { id: memoryId } = await tx
        .insertInto('memory')
        .values({
          ...memory,
          isSaved: false,
          data: { ...memory.data, candidateState: 'pending' },
        })
        .returning('id')
        .executeTakeFirstOrThrow();
      await tx
        .insertInto('memory_asset')
        .values(ids.map((assetId) => ({ memoriesId: memoryId, assetId })))
        .execute();
      const candidate = await tx
        .insertInto('memory_candidate')
        .values({
          ownerId,
          memoryId,
          fingerprint,
          assetIds: ids,
          state: 'pending',
          remindAt: new Date(),
        })
        .returningAll()
        .executeTakeFirstOrThrow();
      return { ...candidate, created: true };
    });
  }

  getCandidates(ownerId: string, hiddenScope?: TimelineHiddenScope, visibleSpaceIds: string[] = []) {
    return (
      this.db
        .selectFrom('memory_candidate')
        .innerJoin('memory', 'memory.id', 'memory_candidate.memoryId')
        .selectAll('memory_candidate')
        .where('memory_candidate.ownerId', '=', ownerId)
        .where('memory.ownerId', '=', ownerId)
        .where('memory.deletedAt', 'is', null)
        .where('memory_candidate.state', '=', 'pending')
        .where('memory_candidate.remindAt', '<=', new Date())
        // Filter before limiting, so old proposals with no renderable assets cannot block new ones.
        .where((eb) =>
          eb.exists(
            eb
              .selectFrom('memory_asset')
              .innerJoin('asset', 'asset.id', 'memory_asset.assetId')
              .select('asset.id')
              .whereRef('memory_asset.memoriesId', '=', 'memory_candidate.memoryId')
              .where('asset.visibility', '=', sql.lit(AssetVisibility.Timeline))
              .where('asset.deletedAt', 'is', null)
              .$if(!!hiddenScope && !timelineHiddenScopeIsEmpty(hiddenScope), (qb) =>
                qb.where((eb) =>
                  eb.or([
                    eb('asset.ownerId', '!=', asUuid(ownerId)),
                    hiddenFromOwnTimeline(eb, hiddenScope!, {
                      kind: 'inline',
                      visibleSpaceIds,
                      viewerId: ownerId,
                    })!,
                  ]),
                ),
              ),
          ),
        )
        .orderBy('memory_candidate.createdAt')
        .orderBy('memory_candidate.id')
        .limit(20)
        .execute()
    );
  }

  getCandidateForMemory(memoryId: string) {
    return this.db.selectFrom('memory_candidate').select('state').where('memoryId', '=', memoryId).executeTakeFirst();
  }

  async decideCandidate(ownerId: string, id: string, action: 'save' | 'dismiss' | 'later') {
    return this.db.transaction().execute(async (tx) => {
      await sql`SELECT pg_advisory_xact_lock(hashtext(${ownerId}), 179108)`.execute(tx);
      const candidate = await tx
        .selectFrom('memory_candidate')
        .selectAll()
        .where('ownerId', '=', ownerId)
        .where('id', '=', id)
        .forUpdate()
        .executeTakeFirst();
      if (!candidate) throw new NotFoundException('Memory candidate not found');
      const state = action === 'save' ? 'saved' : action === 'dismiss' ? 'dismissed' : 'pending';
      if (candidate.state !== 'pending') {
        if (candidate.state === state) return candidate;
        throw new ConflictException('Memory candidate already decided');
      }
      if (action === 'save' && !candidate.memoryId) {
        throw new ConflictException('Candidate memory no longer exists');
      }
      if (action === 'later') {
        return tx
          .updateTable('memory_candidate')
          .set({ remindAt: DateTime.utc().plus({ days: 1 }).toJSDate() })
          .where('id', '=', id)
          .returningAll()
          .executeTakeFirstOrThrow();
      }
      if (candidate.memoryId) {
        const original = await tx
          .selectFrom('memory')
          .select('data')
          .where('id', '=', candidate.memoryId)
          .where('ownerId', '=', ownerId)
          .forUpdate()
          .executeTakeFirst();
        const updated = await tx
          .updateTable('memory')
          .set({
            isSaved: action === 'save',
            showAt: new Date(),
            hideAt: null,
            deletedAt: action === 'dismiss' ? new Date() : null,
            data: { ...memoryData(original?.data), candidateState: state },
            updatedAt: new Date(),
          })
          .where('id', '=', candidate.memoryId)
          .where('ownerId', '=', ownerId)
          .returning('id')
          .execute();
        if (action === 'save' && updated.length === 0) {
          throw new ConflictException('Candidate memory no longer exists');
        }
      }
      return tx
        .updateTable('memory_candidate')
        .set({ state })
        .where('id', '=', id)
        .returningAll()
        .executeTakeFirstOrThrow();
    });
  }

  async cleanup(retentionDays: number) {
    await this.db
      .deleteFrom('memory_asset')
      .using('asset')
      .whereRef('memory_asset.assetId', '=', 'asset.id')
      .where('asset.visibility', '!=', AssetVisibility.Timeline)
      .execute();

    if (retentionDays === 0) {
      return [];
    }

    return this.db
      .deleteFrom('memory')
      .where(sql<Date>`coalesce("showAt", "createdAt")`, '<', DateTime.now().minus({ days: retentionDays }).toJSDate())
      .where('isSaved', '=', false)
      .where((eb) =>
        eb.not(
          eb.exists(
            eb
              .selectFrom('memory_candidate')
              .select('id')
              .whereRef('memory_candidate.memoryId', '=', 'memory.id')
              .where('state', '=', 'pending'),
          ),
        ),
      )
      .execute();
  }

  /** The fork's owner-scoped path. Keeps #486's implicit "hide not-yet-shown" default. */
  searchBuilder(ownerId: string, dto: MemorySearchDto) {
    return this.baseSearchBuilder(dto, { hideUnshownByDefault: true }).where('ownerId', '=', ownerId);
  }

  /**
   * #486 hides memories that are scheduled but not yet shown, for callers that say nothing about
   * `showAt`. immich-28675 turned that into an explicit, three-state request:
   *
   * - `isUpcoming: true`  — only the memories #486 hides. Applying #486 too makes the query
   *   provably empty.
   * - `isUpcoming: false` — the same thing #486 implies, stated by the caller.
   * - omitted             — no `showAt` scoping at all.
   *
   * The omitted case is why `hideUnshownByDefault` exists rather than a check on `dto`: upstream's
   * index says "show upcoming memories" by *leaving the parameter out*, which at this level is
   * indistinguishable from a legacy caller relying on #486. So the default is kept on the fork's
   * internal owner-scoped path and dropped on `GET /memories`, whose contract is upstream's. A
   * `for` window (the memory lane) still carries its own `showAt <= for` bound on both paths.
   */
  private baseSearchBuilder(dto: MemorySearchDto, { hideUnshownByDefault }: { hideUnshownByDefault: boolean }) {
    const visibleAt = dto.for ?? DateTime.now().toJSDate();
    const hideUnshown = dto.isUpcoming === undefined && (hideUnshownByDefault || dto.for !== undefined);

    return this.db
      .selectFrom('memory')
      .where((eb) =>
        eb.not(
          eb.exists(
            eb
              .selectFrom('memory_candidate')
              .select('id')
              .whereRef('memory_candidate.memoryId', '=', 'memory.id')
              .where('state', '!=', 'saved'),
          ),
        ),
      )
      .$if(dto.isSaved !== undefined, (qb) => qb.where('isSaved', '=', dto.isSaved!))
      .$if(dto.type !== undefined, (qb) => qb.where('type', '=', dto.type!))
      .$if(hideUnshown, (qb) =>
        qb.where((where) => where.or([where('showAt', 'is', null), where('showAt', '<=', visibleAt)])),
      )
      .$if(dto.for !== undefined, (qb) =>
        qb.where((where) => where.or([where('hideAt', 'is', null), where('hideAt', '>=', dto.for!)])),
      )
      .$if(dto.isUpcoming !== undefined, (qb) => {
        const now = DateTime.now().toJSDate();
        return dto.isUpcoming
          ? qb.where('showAt', '>', now)
          : qb.where((where) => where.or([where('showAt', 'is', null), where('showAt', '<=', now)]));
      })
      .where('deletedAt', dto.isTrashed ? 'is not' : 'is', null);
  }

  /** Serves `GET /memories`. Follows upstream's contract: `isUpcoming` alone scopes `showAt`. */
  private accessibleSearchBuilder(userId: string, dto: MemorySearchDto) {
    return this.baseSearchBuilder(dto, { hideUnshownByDefault: false }).where((eb) =>
      eb.or([
        eb('memory.ownerId', '=', userId),
        eb.exists(
          eb
            .selectFrom('memory_asset')
            .innerJoin('asset', 'asset.id', 'memory_asset.assetId')
            .select('memory_asset.assetId')
            .whereRef('memory_asset.memoriesId', '=', 'memory.id')
            .where('asset.visibility', '=', sql.lit(AssetVisibility.Timeline))
            .where('asset.deletedAt', 'is', null)
            .where((eb) =>
              eb.or([
                eb('asset.ownerId', '=', userId),
                eb.exists(
                  eb
                    .selectFrom('partner')
                    .select('partner.sharedById')
                    .where('partner.sharedWithId', '=', userId)
                    .whereRef('partner.sharedById', '=', 'asset.ownerId'),
                ),
                eb.exists(
                  eb
                    .selectFrom('shared_space_asset')
                    .innerJoin('shared_space_member', 'shared_space_member.spaceId', 'shared_space_asset.spaceId')
                    .select('shared_space_asset.assetId')
                    .where('shared_space_member.userId', '=', userId)
                    .whereRef('shared_space_asset.assetId', '=', 'asset.id'),
                ),
                eb.exists(
                  eb
                    .selectFrom('shared_space_library')
                    .innerJoin('shared_space_member', 'shared_space_member.spaceId', 'shared_space_library.spaceId')
                    .select('shared_space_library.libraryId')
                    .where('shared_space_member.userId', '=', userId)
                    .whereRef('shared_space_library.libraryId', '=', 'asset.libraryId')
                    .where('asset.isOffline', '=', false),
                ),
                spaceAlbumAssetExists(eb, {
                  correlateAssetId: 'asset.id',
                  scope: { memberUserId: userId },
                  albumTimelineGate: 'space-tab',
                }),
              ]),
            ),
        ),
      ]),
    );
  }

  @GenerateSql(
    { params: [DummyValue.UUID, {}] },
    { name: 'date filter', params: [DummyValue.UUID, { for: DummyValue.DATE }] },
  )
  statistics(ownerId: string, dto: MemorySearchDto) {
    return this.searchBuilder(ownerId, dto)
      .select((qb) => qb.fn.countAll<number>().as('total'))
      .executeTakeFirstOrThrow();
  }

  statisticsAccessible(userId: string, dto: MemorySearchDto) {
    return this.accessibleSearchBuilder(userId, dto)
      .select((qb) => qb.fn.countAll<number>().as('total'))
      .executeTakeFirstOrThrow();
  }

  @GenerateSql(
    { params: [DummyValue.UUID, {}] },
    { name: 'date filter', params: [DummyValue.UUID, { for: DummyValue.DATE }] },
    { name: 'upcoming filter', params: [DummyValue.UUID, { isUpcoming: true }] },
    { name: 'not upcoming filter', params: [DummyValue.UUID, { isUpcoming: false }] },
  )
  // #1041: `hiddenScope` is OPTIONAL and, when provided, resolved for `ownerId` — the memory
  // row's owner, NOT necessarily every asset's owner (a memory can include partner/space assets
  // via the candidate builder above). The subtraction is therefore `ownerId != asset.ownerId OR
  // notHidden`, never a bare AND — the same partner-trap shape §6.4 guards on the timeline. Passing
  // no `hiddenScope` (the only caller today, generation-time dedup) leaves the query unchanged.
  search(ownerId: string, dto: MemorySearchDto, hiddenScope?: TimelineHiddenScope, visibleSpaceIds: string[] = []) {
    return this.searchBuilder(ownerId, dto)
      .select((eb) =>
        jsonArrayFrom(
          eb
            .selectFrom('asset')
            .selectAll('asset')
            .innerJoin('memory_asset', 'asset.id', 'memory_asset.assetId')
            .whereRef('memory_asset.memoriesId', '=', 'memory.id')
            .where('asset.visibility', '=', sql.lit(AssetVisibility.Timeline))
            .where('asset.deletedAt', 'is', null)
            .$if(!!hiddenScope && !timelineHiddenScopeIsEmpty(hiddenScope), (qb) =>
              qb.where((eb) =>
                eb.or([
                  eb('asset.ownerId', '!=', asUuid(ownerId)),
                  hiddenFromOwnTimeline(eb, hiddenScope!, {
                    kind: 'inline',
                    visibleSpaceIds,
                    viewerId: ownerId,
                  })!,
                ]),
              ),
            )
            .where((eb) =>
              eb.not(
                eb.exists(
                  eb
                    .selectFrom('asset_face')
                    .innerJoin('person', (join) =>
                      join
                        .onRef('person.personGroupId', '=', 'asset_face.personGroupId')
                        .onRef('person.ownerId', '=', 'asset.ownerId'),
                    )
                    .select((eb) => eb.val(1).as('one'))
                    .whereRef('asset_face.assetId', '=', 'asset.id')
                    .where('person.isHidden', '=', true),
                ),
              ),
            )
            .orderBy('asset.localDateTime', 'asc'),
        ).as('assets'),
      )
      .selectAll('memory')
      .$call((qb) => {
        if (dto.order === AssetOrderWithRandom.Random) {
          return qb.orderBy(sql`RANDOM()`);
        }

        const direction = (dto.order?.toLowerCase() || 'desc') as OrderByDirection;
        return qb
          .orderBy('showAt', (ob) => (direction === 'asc' ? ob.asc() : ob.desc()).nullsLast())
          .orderBy('memoryAt', direction);
      })
      .$if(dto.id !== undefined, (qb) => qb.where('id', '=', dto.id!))
      .$if(dto.size !== undefined, (qb) => qb.limit(dto.size!))
      .$if(dto.page !== undefined && dto.size !== undefined, (qb) => qb.offset((dto.page! - 1) * dto.size!))
      .execute();
  }

  /**
   * Memories of one owner whose visible window overlaps `window`, with the asset ids they
   * actually render. The asset filters MUST stay identical to `search` — floors are measured
   * over what the card shows, and an asset carrying a hidden person's face is not shown.
   */
  @GenerateSql({ params: [DummyValue.UUID, { from: DummyValue.DATE, to: DummyValue.DATE }] })
  getForOverlapReconcile(ownerId: string, window: { from: Date; to: Date }) {
    return this.db
      .selectFrom('memory')
      .select(['memory.id', 'memory.type', 'memory.data', 'memory.isSaved', 'memory.showAt', 'memory.hideAt'])
      .select((eb) =>
        jsonArrayFrom(
          eb
            .selectFrom('asset')
            .select(['asset.id'])
            .innerJoin('memory_asset', 'asset.id', 'memory_asset.assetId')
            .whereRef('memory_asset.memoriesId', '=', 'memory.id')
            .where('asset.visibility', '=', sql.lit(AssetVisibility.Timeline))
            .where('asset.deletedAt', 'is', null)
            .where((eb) =>
              eb.not(
                eb.exists(
                  eb
                    .selectFrom('asset_face')
                    .innerJoin('person', (join) =>
                      join
                        .onRef('person.personGroupId', '=', 'asset_face.personGroupId')
                        .onRef('person.ownerId', '=', 'asset.ownerId'),
                    )
                    .select((eb) => eb.val(1).as('one'))
                    .whereRef('asset_face.assetId', '=', 'asset.id')
                    .where('person.isHidden', '=', true),
                ),
              ),
            )
            .orderBy('asset.localDateTime', 'asc'),
        ).as('assets'),
      )
      .where('memory.ownerId', '=', ownerId)
      .where('memory.deletedAt', 'is', null)
      .where((eb) => eb.or([eb('memory.showAt', 'is', null), eb('memory.showAt', '<=', window.to)]))
      .where((eb) => eb.or([eb('memory.hideAt', 'is', null), eb('memory.hideAt', '>=', window.from)]))
      .orderBy('memory.id')
      .execute();
  }

  /**
   * Earliest day any memory becomes visible, across all owners — the start of the one-off
   * overlap backfill. `coalesce` mirrors `cleanup`, so a memory with no `showAt` still counts.
   */
  @GenerateSql()
  async getOldestMemoryDate(): Promise<Date | null> {
    const row = await this.db
      .selectFrom('memory')
      .select(sql<Date | null>`min(coalesce("showAt", "createdAt"))`.as('oldest'))
      .where('deletedAt', 'is', null)
      .executeTakeFirst();

    return row?.oldest ?? null;
  }

  // #1041: same partner-trap-safe shape as `search` above, resolved for the VIEWER (`userId`).
  searchAccessible(
    userId: string,
    dto: MemorySearchDto,
    hiddenScope?: TimelineHiddenScope,
    visibleSpaceIds: string[] = [],
  ) {
    return (
      this.accessibleSearchBuilder(userId, dto)
        .select((eb) =>
          jsonArrayFrom(
            eb
              .selectFrom('asset')
              .selectAll('asset')
              .innerJoin('memory_asset', 'asset.id', 'memory_asset.assetId')
              .whereRef('memory_asset.memoriesId', '=', 'memory.id')
              .where('asset.visibility', '=', sql.lit(AssetVisibility.Timeline))
              .where('asset.deletedAt', 'is', null)
              .$if(!!hiddenScope && !timelineHiddenScopeIsEmpty(hiddenScope), (qb) =>
                qb.where((eb) =>
                  eb.or([
                    eb('asset.ownerId', '!=', asUuid(userId)),
                    hiddenFromOwnTimeline(eb, hiddenScope!, { kind: 'inline', visibleSpaceIds, viewerId: userId })!,
                  ]),
                ),
              )
              .where((eb) =>
                eb.not(
                  eb.exists(
                    eb
                      .selectFrom('asset_face')
                      .innerJoin('person', 'person.personGroupId', 'asset_face.personGroupId')
                      .select((eb) => eb.val(1).as('one'))
                      .whereRef('asset_face.assetId', '=', 'asset.id')
                      .where('person.isHidden', '=', true),
                  ),
                ),
              )
              .orderBy('asset.localDateTime', 'asc'),
          ).as('assets'),
        )
        .selectAll('memory')
        // Ordering, `id` and `page` are upstream's `search` contract (immich-28675). This is the
        // method that actually serves `GET /memories`, so it has to carry them: without `id` a deep
        // link resolves to an arbitrary memory, and without the offset every page returns page one.
        .$call((qb) => {
          if (dto.order === AssetOrderWithRandom.Random) {
            return qb.orderBy(sql`RANDOM()`);
          }

          const direction = (dto.order?.toLowerCase() || 'desc') as OrderByDirection;
          return qb
            .orderBy('showAt', (ob) => (direction === 'asc' ? ob.asc() : ob.desc()).nullsLast())
            .orderBy('memoryAt', direction);
        })
        .$if(dto.id !== undefined, (qb) => qb.where('id', '=', dto.id!))
        .$if(dto.size !== undefined, (qb) => qb.limit(dto.size!))
        .$if(dto.page !== undefined && dto.size !== undefined, (qb) => qb.offset((dto.page! - 1) * dto.size!))
        .execute()
    );
  }

  // #1041: `viewerId`/`hiddenScope` are optional — `create`/`update` below return the object right
  // after the caller's own action and pass neither, so their SQL is unchanged. `get()` is the
  // read surface and is the one MemoryService resolves a scope for.
  @GenerateSql({ params: [DummyValue.UUID] })
  get(id: string, viewerId?: string, hiddenScope?: TimelineHiddenScope, visibleSpaceIds: string[] = []) {
    return this.getByIdBuilder(id, viewerId, hiddenScope, visibleSpaceIds).executeTakeFirst();
  }

  async create(memory: Insertable<MemoryTable>, assetIds: Set<string>) {
    const id = await this.db.transaction().execute(async (tx) => {
      // External AI producers using ordinary POST /memories must respect the same user
      // decisions. Serialize their insertion with the existing candidate decision lane.
      await sql`SELECT pg_advisory_xact_lock(hashtext(${memory.ownerId}), 179108)`.execute(tx);
      if (assetIds.size > 0) {
        const history = tx
          .selectFrom('memory_candidate')
          .select('assetIds')
          .where('ownerId', '=', memory.ownerId)
          .where('state', '=', 'dismissed');
        for await (const row of history.stream(100)) {
          if (similarMemoryAssets([...assetIds], row.assetIds)) throw new MemorySuppressedException();
        }
      }
      const { id } = await tx.insertInto('memory').values(memory).returning('id').executeTakeFirstOrThrow();

      if (assetIds.size > 0) {
        const values = [...assetIds].map((assetId) => ({ memoriesId: id, assetId }));
        await tx.insertInto('memory_asset').values(values).execute();
      }

      return id;
    });

    return this.getByIdBuilder(id).executeTakeFirstOrThrow();
  }

  /** Only explicit user actions enter durable rejection history; retention/reconciliation do not. */
  private async suppressForUser(id: string, ownerId: string, action: 'hide' | 'delete') {
    await this.db.transaction().execute(async (tx) => {
      await sql`SELECT pg_advisory_xact_lock(hashtext(${ownerId}), 179108)`.execute(tx);
      const memory = await tx
        .selectFrom('memory')
        .select('id')
        .where('id', '=', id)
        .where('ownerId', '=', ownerId)
        .forUpdate()
        .executeTakeFirst();
      if (!memory) throw new NotFoundException('Memory not found');
      const rows = await tx.selectFrom('memory_asset').select('assetId').where('memoriesId', '=', id).execute();
      const assetIds = rows.map(({ assetId }) => assetId);
      let linkedDuplicateId: string | null = null;
      if (assetIds.length > 0) {
        const rejection = await tx
          .insertInto('memory_candidate')
          .values({
            ownerId,
            memoryId: id,
            fingerprint: memoryFingerprint(assetIds),
            assetIds,
            state: 'dismissed',
            remindAt: new Date(),
          })
          .onConflict((oc) => oc.columns(['ownerId', 'fingerprint']).doUpdateSet({ state: 'dismissed' }))
          .returning('memoryId')
          .executeTakeFirstOrThrow();
        linkedDuplicateId = rejection.memoryId;
        if (linkedDuplicateId && linkedDuplicateId !== id) {
          const linkedAssets = await tx
            .selectFrom('memory_asset')
            .select('assetId')
            .where('memoriesId', '=', linkedDuplicateId)
            .execute();
          if (memoryFingerprint(linkedAssets.map(({ assetId }) => assetId)) !== memoryFingerprint(assetIds)) {
            // A saved candidate may now contain a different, manually edited moment. Its
            // historical fingerprint must not hide that unrelated current memory.
            await tx
              .updateTable('memory_candidate')
              .set({ memoryId: id })
              .where('ownerId', '=', ownerId)
              .where('fingerprint', '=', memoryFingerprint(assetIds))
              .execute();
            linkedDuplicateId = null;
          }
        }
      }
      // A previously saved candidate may have been edited since its original fingerprint.
      // Preserve both fingerprints and make its former Save decision terminally dismissed too.
      await tx
        .updateTable('memory_candidate')
        .set({ state: 'dismissed' })
        .where('ownerId', '=', ownerId)
        .where('memoryId', '=', id)
        .execute();
      const hiddenIds = [
        ...(action === 'hide' ? [id] : []),
        ...(linkedDuplicateId && linkedDuplicateId !== id ? [linkedDuplicateId] : []),
      ];
      if (hiddenIds.length > 0) {
        // An exact existing candidate-backed duplicate shares this durable decision. Deliver
        // its tombstone through sync too, instead of leaving a stale offline/deep-link copy.
        const hiddenMemories = await tx
          .selectFrom('memory')
          .select(['id', 'data'])
          .where('id', 'in', hiddenIds)
          .where('ownerId', '=', ownerId)
          .forUpdate()
          .execute();
        for (const hidden of hiddenMemories) {
          await tx
            .updateTable('memory')
            .set({
              deletedAt: new Date(),
              updatedAt: new Date(),
              data: { ...memoryData(hidden.data), candidateState: 'dismissed' },
            })
            .where('id', '=', hidden.id)
            .where('ownerId', '=', ownerId)
            .execute();
        }
      }
      if (action === 'delete') {
        // The existing FK cascades remove only memory_asset links, never their asset rows.
        await tx.deleteFrom('memory').where('id', '=', id).where('ownerId', '=', ownerId).execute();
      }
    });
  }

  async hideForUser(id: string, ownerId: string) {
    await this.suppressForUser(id, ownerId, 'hide');
    return this.getByIdBuilder(id, undefined, undefined, [], true).executeTakeFirstOrThrow();
  }

  async deleteForUser(id: string, ownerId: string) {
    await this.suppressForUser(id, ownerId, 'delete');
  }

  @GenerateSql({ params: [DummyValue.UUID, { ownerId: DummyValue.UUID, isSaved: true }] })
  async update(id: string, memory: Updateable<MemoryTable>) {
    if (memory.isSaved !== undefined) {
      const candidate = await this.getCandidateForMemory(id);
      if (candidate && candidate.state !== 'saved') throw new ConflictException('Use the candidate decision endpoint');
    }
    await this.db.updateTable('memory').set(memory).where('id', '=', id).execute();
    return this.getByIdBuilder(id).executeTakeFirstOrThrow();
  }

  async updateDisplay(
    id: string,
    memory: Updateable<MemoryTable>,
    display: { title?: string | null; subtitle?: string | null },
  ) {
    if (memory.isSaved !== undefined) {
      const candidate = await this.getCandidateForMemory(id);
      if (candidate && candidate.state !== 'saved') throw new ConflictException('Use the candidate decision endpoint');
    }
    await this.db.transaction().execute(async (tx) => {
      const original = await tx.selectFrom('memory').select('data').where('id', '=', id).forUpdate().executeTakeFirst();
      if (!original) throw new NotFoundException('Memory not found');
      const patch = Object.fromEntries(Object.entries(display).filter(([, value]) => value !== undefined));
      await tx
        .updateTable('memory')
        .set({ ...memory, data: { ...memoryData(original.data), ...patch } })
        .where('id', '=', id)
        .execute();
    });
    return this.getByIdBuilder(id).executeTakeFirstOrThrow();
  }

  @GenerateSql({ params: [DummyValue.UUID] })
  async delete(id: string) {
    await this.db.deleteFrom('memory').where('id', '=', id).execute();
  }

  /**
   * Remove the plain `on_this_day` memory a rule memory has just superseded. Scoped to one
   * owner, one trigger day and one year, and never touches a saved memory.
   *
   * Written as an unconditional DELETE ... WHERE rather than a read-then-delete: when the
   * owner has `on_this_day` disabled, or retention already removed the row, there is simply
   * nothing to match. That keeps correctness independent of whether the on-this-day loop has
   * run for the day — it only decides whether this has any effect. (In practice it always
   * has: the on-this-day loop writes up to 3 days ahead and runs first inside the same lock,
   * so the row exists before any rule for that day is evaluated.)
   */
  @GenerateSql({ params: [{ ownerId: DummyValue.UUID, year: DummyValue.NUMBER, showAt: DummyValue.DATE }] })
  async deleteOnThisDay({ ownerId, year, showAt }: { ownerId: string; year: number; showAt: Date }) {
    await this.db
      .deleteFrom('memory')
      .where('ownerId', '=', ownerId)
      .where('type', '=', MemoryType.OnThisDay)
      .where('isSaved', '=', false)
      .where('showAt', '=', showAt)
      .where(sql<string>`memory.data->>'year'`, '=', String(year))
      .execute();
  }

  @GenerateSql({ params: [DummyValue.UUID, DummyValue.STRING, DummyValue.STRING] })
  async hasRuleMemory(ownerId: string, ruleId: string, dedupeKey: string) {
    const result = await this.db
      .selectFrom('memory')
      .select('id')
      .where('ownerId', '=', ownerId)
      .where('type', '=', MemoryType.Rule)
      .where(sql<string>`memory.data->>'ruleId'`, '=', ruleId)
      .where(sql<string>`memory.data->>'dedupeKey'`, '=', dedupeKey)
      .where('deletedAt', 'is', null)
      .executeTakeFirst();

    return !!result;
  }

  @GenerateSql({ params: [DummyValue.UUID, [DummyValue.UUID]] })
  @ChunkedSet({ paramIndex: 1 })
  async getAssetIds(id: string, assetIds: string[]) {
    if (assetIds.length === 0) {
      return new Set<string>();
    }

    const results = await this.db
      .selectFrom('memory_asset')
      .select(['assetId'])
      .where('memoriesId', '=', id)
      .where('assetId', 'in', assetIds)
      .execute();

    return new Set(results.map(({ assetId }) => assetId));
  }

  @GenerateSql({ params: [DummyValue.UUID, [DummyValue.UUID]] })
  async addAssetIds(id: string, assetIds: string[]) {
    if (assetIds.length === 0) {
      return;
    }

    await this.db
      .insertInto('memory_asset')
      .values(assetIds.map((assetId) => ({ memoriesId: id, assetId })))
      .execute();
  }

  @Chunked({ paramIndex: 1 })
  @GenerateSql({ params: [DummyValue.UUID, [DummyValue.UUID]] })
  async removeAssetIds(id: string, assetIds: string[]) {
    if (assetIds.length === 0) {
      return;
    }

    await this.db.deleteFrom('memory_asset').where('memoriesId', '=', id).where('assetId', 'in', assetIds).execute();
  }

  private getByIdBuilder(
    id: string,
    viewerId?: string,
    hiddenScope?: TimelineHiddenScope,
    visibleSpaceIds: string[] = [],
    includeDeleted = false,
  ) {
    return this.db
      .selectFrom('memory')
      .selectAll('memory')
      .select((eb) =>
        jsonArrayFrom(
          eb
            .selectFrom('asset')
            .selectAll('asset')
            .innerJoin('memory_asset', 'asset.id', 'memory_asset.assetId')
            .whereRef('memory_asset.memoriesId', '=', 'memory.id')
            .orderBy('asset.localDateTime', 'asc')
            .where('asset.visibility', '=', sql.lit(AssetVisibility.Timeline))
            .where('asset.deletedAt', 'is', null)
            .$if(!!viewerId && !!hiddenScope && !timelineHiddenScopeIsEmpty(hiddenScope), (qb) =>
              qb.where((eb) =>
                eb.or([
                  eb('asset.ownerId', '!=', asUuid(viewerId!)),
                  hiddenFromOwnTimeline(eb, hiddenScope!, { kind: 'inline', visibleSpaceIds, viewerId: viewerId! })!,
                ]),
              ),
            ),
        ).as('assets'),
      )
      .where('id', '=', id)
      .$if(!includeDeleted, (qb) => qb.where('deletedAt', 'is', null));
  }
}
