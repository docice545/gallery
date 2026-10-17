import { Kysely, sql } from 'kysely';
import { createHash } from 'node:crypto';
import { AssetType, AssetVisibility, MemoryType } from 'src/enum.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { MemoryRepository } from 'src/repositories/memory.repository.js';
import { DB } from 'src/schema/index.js';
import { MemoryService } from 'src/services/memory.service.js';
import { memoryFingerprint } from 'src/utils/memory-candidate.js';
import { newMediumService } from 'test/medium.factory.js';
import { factory } from 'test/small.factory.js';
import { getKyselyDB } from 'test/utils.js';

let database: Kysely<DB>;

const setup = () => {
  const { sut, ctx } = newMediumService(MemoryService, {
    database,
    real: [MemoryRepository],
    mock: [LoggingRepository],
  });
  return { sut, ctx, repository: ctx.get(MemoryRepository) };
};

const candidateId = (index: number) => `51000000-0000-4000-8000-${index.toString().padStart(12, '0')}`;
const memoryId = (index: number) => `52000000-0000-4000-8000-${index.toString().padStart(12, '0')}`;

const insertCandidate = (
  ownerId: string,
  assetIds: string[],
  options: { id?: string; memoryId?: string; state?: 'pending' | 'saved' | 'dismissed' } = {},
) =>
  database
    .insertInto('memory_candidate')
    .values({
      ownerId,
      assetIds,
      fingerprint: memoryFingerprint(assetIds),
      state: options.state ?? 'dismissed',
      memoryId: options.memoryId ?? null,
      remindAt: new Date('2026-10-05T00:00:00Z'),
      ...(options.id && { id: options.id }),
    })
    .returningAll()
    .executeTakeFirstOrThrow();

beforeAll(async () => {
  database = await getKyselyDB();
});

afterAll(async () => {
  await database?.destroy();
});

describe('owner-only memory lifecycle and rejection snapshots', () => {
  it('keeps three owners separate even when partners and shared spaces expose their memories', async () => {
    const { sut, ctx, repository } = setup();
    const users = await Promise.all(Array.from({ length: 3 }, () => ctx.newUser()));
    const [viewer, partner, contributor] = users.map(({ user }) => user);
    const assets = await Promise.all(users.map(({ user }) => ctx.newAsset({ ownerId: user.id })));
    const memories = await Promise.all(users.map(({ user }) => ctx.newMemory({ ownerId: user.id })));
    for (let index = 0; index < users.length; index++) {
      await ctx.newMemoryAsset({ memoryId: memories[index].memory.id, assetId: assets[index].asset.id });
      await insertCandidate(users[index].user.id, [assets[index].asset.id]);
    }
    await ctx.newPartner({ sharedById: partner.id, sharedWithId: viewer.id });
    const { space } = await ctx.newSharedSpace({ createdById: contributor.id });
    await ctx.newSharedSpaceMember({ spaceId: space.id, userId: viewer.id, showInTimeline: true });
    await ctx.newSharedSpaceMember({ spaceId: space.id, userId: contributor.id, showInTimeline: true });
    await ctx.newSharedSpaceAsset({ spaceId: space.id, assetId: assets[2].asset.id });

    const browsed = await repository.searchAccessible(viewer.id, {});
    const browseIds = browsed.map(({ id }) => id);
    expect(browseIds).toEqual(expect.arrayContaining(memories.map(({ memory }) => memory.id)));
    for (let index = 0; index < users.length; index++) {
      const auth = factory.auth({ user: users[index].user });
      const lifecycle = await sut.getLifecycle(auth, { size: 100 });
      const rejections = await sut.getRejections(auth, { size: 100 });
      expect(lifecycle.items.map(({ id }) => id)).toEqual([memories[index].memory.id]);
      expect(lifecycle.items[0].assetIds).toEqual([assets[index].asset.id]);
      expect(rejections.items).toHaveLength(1);
      expect(rejections.items[0].assetIds).toEqual([assets[index].asset.id]);
      expect(lifecycle.nextCursor).toBeUndefined();
      expect(rejections.nextCursor).toBeUndefined();
    }
  });

  it('returns complete mixed-media membership and unknown-rule metadata regardless of display eligibility', async () => {
    const { sut, ctx } = setup();
    const { user } = await ctx.newUser();
    const auth = factory.auth({ user });
    const assets = await Promise.all([
      ctx.newAsset({ ownerId: user.id, type: AssetType.Image }),
      ctx.newAsset({ ownerId: user.id, type: AssetType.Video, duration: 12_345 }),
      ctx.newAsset({ ownerId: user.id, visibility: AssetVisibility.Archive }),
      ctx.newAsset({ ownerId: user.id, visibility: AssetVisibility.Hidden }),
      ctx.newAsset({ ownerId: user.id, visibility: AssetVisibility.Locked }),
      ctx.newAsset({ ownerId: user.id, isOffline: true }),
      ctx.newAsset({ ownerId: user.id, deletedAt: new Date('2026-10-01T00:00:00Z') }),
    ]);
    const assetIds = assets.map(({ asset }) => asset.id);
    const data = {
      ruleId: 'gallery_ai_v3_7_external_rule',
      title: 'An external mixed-media memory',
      subtitle: 'Preserve metadata without knowing the rule',
      candidateState: 'pending',
      context: { sources: ['photo', 'video'], generatorVersion: '3.7' },
    };
    const dates = {
      seenAt: new Date('2026-10-04T12:00:00Z'),
      showAt: new Date('2030-10-05T12:00:00Z'),
      hideAt: new Date('2030-10-06T12:00:00Z'),
      deletedAt: new Date('2026-10-04T13:00:00Z'),
    };
    const { memory } = await ctx.newMemory({
      ownerId: user.id,
      type: MemoryType.Rule,
      data,
      isSaved: true,
      ...dates,
      deletedAt: null,
    });
    await database.updateTable('memory').set({ deletedAt: dates.deletedAt }).where('id', '=', memory.id).execute();
    for (const assetId of assetIds.toReversed()) {
      await ctx.newMemoryAsset({ memoryId: memory.id, assetId });
    }

    const response = await sut.getLifecycle(auth, { size: 100 });
    expect(response.items).toHaveLength(1);
    expect(response.items[0]).toEqual(
      expect.objectContaining({ id: memory.id, type: MemoryType.Rule, data, isSaved: true, ...dates }),
    );
    expect(response.items[0].assetIds.toSorted()).toEqual(assetIds.toSorted());
    expect(response.items[0].fingerprint).toBe(
      createHash('sha256').update(assetIds.toSorted().join(',')).digest('hex'),
    );
    expect(response.items[0]).not.toHaveProperty('assets');
  });

  it('paginates lifecycle by ID across upcoming, expired, saved, hidden and empty memories', async () => {
    const { sut, ctx } = setup();
    const { user } = await ctx.newUser();
    const { user: other } = await ctx.newUser();
    const auth = factory.auth({ user });
    const ids = [1, 3, 5, 7, 9].map((index) => memoryId(index));
    const changes = [
      { showAt: new Date('2030-01-01T00:00:00Z') },
      { hideAt: new Date('2020-01-01T00:00:00Z') },
      { isSaved: true },
      { deletedAt: new Date('2026-10-01T00:00:00Z') },
      {},
    ];
    for (const index of [4, 2, 0, 3, 1]) {
      await ctx.newMemory({
        id: ids[index],
        ownerId: user.id,
        memoryAt: new Date(`2026-10-${(10 - index).toString().padStart(2, '0')}T12:00:00Z`),
        ...changes[index],
        deletedAt: null,
      });
      if (changes[index].deletedAt) {
        await database
          .updateTable('memory')
          .set({ deletedAt: changes[index].deletedAt })
          .where('id', '=', ids[index])
          .execute();
      }
    }
    await ctx.newMemory({ id: memoryId(2), ownerId: other.id });
    await ctx.newMemory({ id: memoryId(8), ownerId: other.id });

    const first = await sut.getLifecycle(auth, { size: 2 });
    expect(first.items.map(({ id }) => id)).toEqual(ids.slice(0, 2));
    expect(first.nextCursor).toBe(ids[1]);
    const second = await sut.getLifecycle(auth, { size: 2, after: first.nextCursor });
    expect(second.items.map(({ id }) => id)).toEqual(ids.slice(2, 4));
    expect(second.nextCursor).toBe(ids[3]);
    const last = await sut.getLifecycle(auth, { size: 2, after: second.nextCursor });
    expect(last.items.map(({ id }) => id)).toEqual(ids.slice(4));
    expect(last.nextCursor).toBeUndefined();
    expect(last.items[0]).toEqual(
      expect.objectContaining({
        assetIds: [],
        seenAt: undefined,
        showAt: undefined,
        hideAt: undefined,
        deletedAt: undefined,
        fingerprint: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      }),
    );
    const exhausted = await sut.getLifecycle(auth, { size: 2, after: ids[4] });
    expect(exhausted.items).toEqual([]);
    expect(exhausted.nextCursor).toBeUndefined();
  });

  it('paginates only dismissed candidates without exposing foreign, pending or saved rows', async () => {
    const { sut, ctx } = setup();
    const { user } = await ctx.newUser();
    const { user: other } = await ctx.newUser();
    const auth = factory.auth({ user });
    const ids = [1, 4, 7].map((index) => candidateId(index));
    for (const id of ids.toReversed()) {
      await insertCandidate(user.id, [factory.uuid()], { id });
    }
    await insertCandidate(other.id, [factory.uuid()], { id: candidateId(2) });
    await insertCandidate(user.id, [factory.uuid()], { id: candidateId(3), state: 'pending' });
    await insertCandidate(user.id, [factory.uuid()], { id: candidateId(5), state: 'saved' });
    await insertCandidate(other.id, [factory.uuid()], { id: candidateId(8) });

    const first = await sut.getRejections(auth, { size: 2 });
    expect(first.items.map(({ id }) => id)).toEqual(ids.slice(0, 2));
    expect(first.items.every(({ state, memoryId }) => state === 'dismissed' && memoryId === null)).toBe(true);
    expect(first.nextCursor).toBe(ids[1]);
    const last = await sut.getRejections(auth, { size: 2, after: first.nextCursor });
    expect(last.items.map(({ id }) => id)).toEqual(ids.slice(2));
    expect(last.nextCursor).toBeUndefined();
    const exact = await sut.getRejections(auth, { size: 3 });
    expect(exact.items.map(({ id }) => id)).toEqual(ids);
    expect(exact.nextCursor).toBeUndefined();
    const exhausted = await sut.getRejections(auth, { size: 2, after: ids[2] });
    expect(exhausted.items).toEqual([]);
    expect(exhausted.nextCursor).toBeUndefined();
  });

  it('normalizes legacy JSON representations without rewriting memory or rejection history', async () => {
    const { sut, ctx } = setup();
    const { user } = await ctx.newUser();
    const auth = factory.auth({ user });
    const { asset } = await ctx.newAsset({ ownerId: user.id });
    const { memory } = await ctx.newMemory({ ownerId: user.id, type: MemoryType.Rule });
    await ctx.newMemoryAsset({ memoryId: memory.id, assetId: asset.id });
    const legacyData = [
      { ruleId: 'unknown_external_rule', title: 'Original title', context: { location: 'Paris' } },
      JSON.stringify({ title: 'Generated title', subtitle: 'Generated description', candidateState: 'dismissed' }),
    ];
    await database
      .updateTable('memory')
      .set({ data: sql<Record<string, unknown>>`${legacyData}::jsonb` })
      .where('id', '=', memory.id)
      .execute();
    const candidate = await insertCandidate(user.id, [asset.id], { memoryId: memory.id });
    await database
      .updateTable('memory_candidate')
      .set({ assetIds: sql<string[]>`${JSON.stringify([asset.id])}::jsonb` })
      .where('id', '=', candidate.id)
      .execute();
    const beforeMemory = await database.selectFrom('memory').selectAll().where('id', '=', memory.id).execute();
    const beforeCandidate = await database
      .selectFrom('memory_candidate')
      .selectAll()
      .where('id', '=', candidate.id)
      .execute();

    const lifecycle = await sut.getLifecycle(auth, { size: 100 });
    expect(lifecycle.items[0].data).toEqual({
      ruleId: 'unknown_external_rule',
      title: 'Generated title',
      subtitle: 'Generated description',
      context: { location: 'Paris' },
      candidateState: 'dismissed',
    });
    const rejections = await sut.getRejections(auth, { size: 100 });
    expect(rejections.items[0]).toEqual(
      expect.objectContaining({
        id: candidate.id,
        assetIds: [asset.id],
        fingerprint: candidate.fingerprint,
        memoryId: memory.id,
        state: 'dismissed',
      }),
    );
    expect(await database.selectFrom('memory').selectAll().where('id', '=', memory.id).execute()).toEqual(beforeMemory);
    expect(await database.selectFrom('memory_candidate').selectAll().where('id', '=', candidate.id).execute()).toEqual(
      beforeCandidate,
    );
  });

  it('distinguishes durable manual rejection from retention and internal deletion', async () => {
    const { sut, ctx, repository } = setup();
    const { user } = await ctx.newUser();
    const auth = factory.auth({ user });
    const assets = await Promise.all(Array.from({ length: 4 }, () => ctx.newAsset({ ownerId: user.id })));
    const memories = await Promise.all(
      assets.map(() =>
        ctx.newMemory({
          ownerId: user.id,
          createdAt: new Date('2020-01-01T00:00:00Z'),
          showAt: new Date('2020-01-02T00:00:00Z'),
          isSaved: false,
        }),
      ),
    );
    for (let index = 0; index < memories.length; index++) {
      await ctx.newMemoryAsset({ memoryId: memories[index].memory.id, assetId: assets[index].asset.id });
    }
    await repository.hideForUser(memories[0].memory.id, user.id);
    await repository.deleteForUser(memories[1].memory.id, user.id);
    await repository.delete(memories[2].memory.id);

    const beforeCleanup = await sut.getLifecycle(auth, { size: 100 });
    expect(beforeCleanup.items.map(({ id }) => id).toSorted()).toEqual(
      [memories[0].memory.id, memories[3].memory.id].toSorted(),
    );
    expect(beforeCleanup.items.find(({ id }) => id === memories[0].memory.id)?.deletedAt).toBeInstanceOf(Date);
    const choices = await sut.getRejections(auth, { size: 100 });
    expect(choices.items).toHaveLength(2);
    expect(choices.items.flatMap(({ assetIds }) => assetIds).toSorted()).toEqual(
      [assets[0].asset.id, assets[1].asset.id].toSorted(),
    );

    await repository.cleanup(1);
    const lifecycleAfterCleanup = await sut.getLifecycle(auth, { size: 100 });
    expect(lifecycleAfterCleanup.items).toEqual([]);
    const afterCleanup = await sut.getRejections(auth, { size: 100 });
    expect(afterCleanup.items.map(({ fingerprint }) => fingerprint).toSorted()).toEqual(
      choices.items.map(({ fingerprint }) => fingerprint).toSorted(),
    );
    expect(afterCleanup.items.every(({ state, memoryId }) => state === 'dismissed' && memoryId === null)).toBe(true);
    const originalAssets = await database
      .selectFrom('asset')
      .select(['id', 'deletedAt'])
      .where(
        'id',
        'in',
        assets.map(({ asset }) => asset.id),
      )
      .execute();
    expect(originalAssets).toHaveLength(4);
    expect(originalAssets.every(({ deletedAt }) => deletedAt === null)).toBe(true);
  });
});
