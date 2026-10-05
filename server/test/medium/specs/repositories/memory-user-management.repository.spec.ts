import { ConflictException, NotFoundException } from '@nestjs/common';
import { Kysely, sql } from 'kysely';
import { AssetVisibility, MemoryType } from 'src/enum.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { MemoryRepository } from 'src/repositories/memory.repository.js';
import { DB } from 'src/schema/index.js';
import { BaseService } from 'src/services/base.service.js';
import { MemorySuppressedException } from 'src/utils/memory-candidate.js';
import { newMediumService } from 'test/medium.factory.js';
import { getKyselyDB } from 'test/utils.js';

let database: Kysely<DB>;

const setup = async (type = MemoryType.OnThisDay, count = 5) => {
  const { ctx } = newMediumService(BaseService, { database, real: [], mock: [LoggingRepository] });
  const sut = ctx.get(MemoryRepository);
  const { user } = await ctx.newUser();
  const assets = await Promise.all(
    Array.from({ length: count }, () => ctx.newAsset({ ownerId: user.id, visibility: AssetVisibility.Timeline })),
  );
  const assetIds = assets.map(({ asset }) => asset.id);
  const dto = {
    ownerId: user.id,
    type,
    data: type === MemoryType.OnThisDay ? { year: 2024 } : { ruleId: 'gallery_ai_highlight', title: 'AI highlight' },
    memoryAt: new Date('2024-10-05T12:00:00Z'),
  };
  const memory = await sut.create(dto, new Set(assetIds));
  return { ctx, sut, user, assets, assetIds, dto, memory };
};

beforeAll(async () => {
  database = await getKyselyDB();
});

afterAll(async () => {
  await database?.destroy();
});

describe('durable user memory management', () => {
  it.each([MemoryType.OnThisDay, MemoryType.Rule])(
    'deletes %s memories and links while keeping original assets',
    async (type) => {
      const { sut, user, memory, assetIds } = await setup(type);
      await sut.deleteForUser(memory.id, user.id);

      expect(await sut.get(memory.id)).toBeUndefined();
      expect(
        await database.selectFrom('memory_asset').selectAll().where('memoriesId', '=', memory.id).execute(),
      ).toEqual([]);
      const assets = await database
        .selectFrom('asset')
        .select(['id', 'deletedAt'])
        .where('id', 'in', assetIds)
        .execute();
      expect(assets).toHaveLength(assetIds.length);
      expect(assets.every(({ deletedAt }) => deletedAt === null)).toBe(true);
      const rejection = await database
        .selectFrom('memory_candidate')
        .selectAll()
        .where('ownerId', '=', user.id)
        .executeTakeFirstOrThrow();
      expect(rejection.state).toBe('dismissed');
      expect(rejection.memoryId).toBeNull();
      expect(rejection.assetIds.toSorted()).toEqual(assetIds.toSorted());
    },
  );

  it.each([MemoryType.OnThisDay, MemoryType.Rule])(
    'hides %s memories from lane, full list and deep link',
    async (type) => {
      const { sut, user, memory, assetIds } = await setup(type);
      const hidden = await sut.hideForUser(memory.id, user.id);
      expect(hidden.deletedAt).toBeInstanceOf(Date);
      expect(hidden.assets.map(({ id }) => id).toSorted()).toEqual(assetIds.toSorted());
      expect(await sut.get(memory.id)).toBeUndefined();
      expect(await sut.searchAccessible(user.id, {})).toEqual([]);
      expect(await sut.searchAccessible(user.id, { for: new Date() })).toEqual([]);
      const statistics = await sut.statisticsAccessible(user.id, {});
      expect(statistics.total).toBe(0);
      expect(
        await database.selectFrom('memory_asset').selectAll().where('memoriesId', '=', memory.id).execute(),
      ).toHaveLength(assetIds.length);
    },
  );

  it('suppresses reordered near-identical AI POSTs despite a changed title, rule, date and saved flag', async () => {
    const { sut, user, memory, assetIds, dto } = await setup();
    await sut.deleteForUser(memory.id, user.id);
    const changed = {
      ...dto,
      type: MemoryType.Rule,
      data: { ruleId: 'gallery_ai_highlight', title: 'A newly generated title' },
      isSaved: true,
      memoryAt: new Date('2026-10-06T12:00:00Z'),
    };
    await expect(sut.create(changed, new Set(assetIds.toReversed()))).rejects.toBeInstanceOf(MemorySuppressedException);
    await expect(sut.create(changed, new Set(assetIds.slice(0, 4)))).rejects.toBeInstanceOf(MemorySuppressedException);
    await expect(sut.createCandidate(changed, assetIds.slice(0, 4))).rejects.toBeInstanceOf(ConflictException);
    expect(await sut.create(changed, new Set(assetIds.slice(0, 3)))).toBeDefined();
  });

  it('keeps suppression after retention cleanup physically removes a hidden row', async () => {
    const { sut, user, memory, assetIds, dto } = await setup();
    await sut.hideForUser(memory.id, user.id);
    await database
      .updateTable('memory')
      .set({ createdAt: new Date('2020-01-01'), showAt: null, isSaved: false })
      .where('id', '=', memory.id)
      .execute();
    await sut.cleanup(1);
    expect(await database.selectFrom('memory').select('id').where('id', '=', memory.id).execute()).toEqual([]);
    await expect(new MemoryRepository(database).create(dto, new Set(assetIds))).rejects.toBeInstanceOf(
      MemorySuppressedException,
    );
  });

  it('limits suppression to the owner and prevents a foreign hide/delete', async () => {
    const { ctx, sut, user, memory, assetIds, dto } = await setup();
    const { user: other } = await ctx.newUser();
    await expect(sut.hideForUser(memory.id, other.id)).rejects.toBeInstanceOf(NotFoundException);
    await expect(sut.deleteForUser(memory.id, other.id)).rejects.toBeInstanceOf(NotFoundException);
    expect(await database.selectFrom('memory_candidate').selectAll().where('ownerId', '=', other.id).execute()).toEqual(
      [],
    );
    await sut.deleteForUser(memory.id, user.id);
    // Repository-level check is owner-scoped; the service separately restricts asset ownership.
    expect(await sut.create({ ...dto, ownerId: other.id }, new Set(assetIds))).toBeDefined();
  });

  it('does not record internal reconciliation/retention deletion as a user choice', async () => {
    const { sut, user, memory, assetIds, dto } = await setup();
    await sut.delete(memory.id);
    expect(await database.selectFrom('memory_candidate').selectAll().where('ownerId', '=', user.id).execute()).toEqual(
      [],
    );
    expect(await sut.create(dto, new Set(assetIds))).toBeDefined();
  });

  it('dismisses a saved candidate and preserves both original and edited memberships', async () => {
    const { ctx, sut, user, memory, assetIds, dto } = await setup(MemoryType.Rule);
    await sut.delete(memory.id);
    const candidate = await sut.createCandidate(dto, assetIds);
    await sut.decideCandidate(user.id, candidate.id, 'save');
    const replacements = await Promise.all(Array.from({ length: 5 }, () => ctx.newAsset({ ownerId: user.id })));
    const replacementIds = replacements.map(({ asset }) => asset.id);
    await sut.removeAssetIds(candidate.memoryId!, assetIds);
    await sut.addAssetIds(candidate.memoryId!, replacementIds);
    await sut.hideForUser(candidate.memoryId!, user.id);

    await expect(sut.decideCandidate(user.id, candidate.id, 'save')).rejects.toBeInstanceOf(ConflictException);
    await expect(sut.decideCandidate(user.id, candidate.id, 'later')).rejects.toBeInstanceOf(ConflictException);
    await expect(sut.create(dto, new Set(assetIds))).rejects.toBeInstanceOf(MemorySuppressedException);
    await expect(sut.create(dto, new Set(replacementIds))).rejects.toBeInstanceOf(MemorySuppressedException);
  });

  it('checks newer rejection history before returning an older exact saved candidate', async () => {
    const { sut, user, memory, assetIds, dto } = await setup(MemoryType.Rule);
    await sut.delete(memory.id);
    const old = await sut.createCandidate(dto, assetIds);
    await sut.decideCandidate(user.id, old.id, 'save');
    const similar = await sut.create(dto, new Set(assetIds.slice(0, 4)));
    await sut.hideForUser(similar.id, user.id);
    await expect(sut.createCandidate(dto, assetIds)).rejects.toBeInstanceOf(MemorySuppressedException);
  });

  it('respects legacy JSON-string rejection memberships without a data migration', async () => {
    const { sut, user, memory, assetIds, dto } = await setup();
    await sut.deleteForUser(memory.id, user.id);
    // Reproduce the former writer: postgres.js encodes this already-stringified value again.
    await database
      .updateTable('memory_candidate')
      .set({ assetIds: sql<string[]>`${JSON.stringify(assetIds)}::jsonb` })
      .where('ownerId', '=', user.id)
      .execute();
    await expect(sut.create(dto, new Set(assetIds))).rejects.toBeInstanceOf(MemorySuppressedException);
    await expect(sut.createCandidate(dto, assetIds.slice(0, 4))).rejects.toBeInstanceOf(MemorySuppressedException);
  });

  it('repairs legacy candidate data only when the selected row is changed', async () => {
    const { sut, user, memory } = await setup(MemoryType.Rule);
    const old = [
      { ruleId: 'gallery_ai_highlight', title: 'Original title', context: { location: 'Paris' } },
      JSON.stringify({ title: 'Generated title', subtitle: 'Generated description', candidateState: 'saved' }),
    ];
    await database
      .updateTable('memory')
      .set({ data: sql<Record<string, unknown>>`${old}::jsonb` })
      .where('id', '=', memory.id)
      .execute();
    const hidden = await sut.hideForUser(memory.id, user.id);
    expect(hidden.data).toEqual({
      ruleId: 'gallery_ai_highlight',
      title: 'Generated title',
      subtitle: 'Generated description',
      context: { location: 'Paris' },
      candidateState: 'dismissed',
    });
  });

  it('writes display changes as a JSON object while preserving recovered original metadata', async () => {
    const { sut, memory } = await setup(MemoryType.Rule);
    const old = [
      { ruleId: 'gallery_ai_highlight', context: { location: 'Paris' } },
      JSON.stringify({ title: 'Old title' }),
    ];
    await database
      .updateTable('memory')
      .set({ data: sql<Record<string, unknown>>`${old}::jsonb` })
      .where('id', '=', memory.id)
      .execute();
    const updated = await sut.updateDisplay(memory.id, {}, { title: 'New title', subtitle: 'New description' });
    expect(updated.data).toEqual({
      ruleId: 'gallery_ai_highlight',
      context: { location: 'Paris' },
      title: 'New title',
      subtitle: 'New description',
    });
    const subtitleOnly = await sut.updateDisplay(memory.id, {}, { title: undefined, subtitle: 'Updated description' });
    expect(subtitleOnly.data.title).toBe('New title');
    expect(subtitleOnly.data.subtitle).toBe('Updated description');
  });

  it('tombstones an exact linked duplicate so it cannot survive via deep link or offline sync', async () => {
    const { sut, user, memory, assetIds, dto } = await setup(MemoryType.Rule);
    await sut.delete(memory.id);
    const old = await sut.createCandidate(dto, assetIds);
    await sut.decideCandidate(user.id, old.id, 'save');
    const direct = await sut.create(dto, new Set(assetIds));
    await sut.hideForUser(direct.id, user.id);
    expect(await sut.get(old.memoryId!)).toBeUndefined();
    const row = await database
      .selectFrom('memory')
      .select('deletedAt')
      .where('id', '=', old.memoryId!)
      .executeTakeFirstOrThrow();
    expect(row.deletedAt).toBeInstanceOf(Date);
    await expect(sut.decideCandidate(user.id, old.id, 'save')).rejects.toBeInstanceOf(ConflictException);
  });

  it('does not hide a previously saved candidate that now contains an unrelated edited moment', async () => {
    const { ctx, sut, user, memory, assetIds, dto } = await setup(MemoryType.Rule);
    await sut.delete(memory.id);
    const old = await sut.createCandidate(dto, assetIds);
    await sut.decideCandidate(user.id, old.id, 'save');
    const replacements = await Promise.all(Array.from({ length: 5 }, () => ctx.newAsset({ ownerId: user.id })));
    const replacementIds = replacements.map(({ asset }) => asset.id);
    await sut.removeAssetIds(old.memoryId!, assetIds);
    await sut.addAssetIds(old.memoryId!, replacementIds);

    const direct = await sut.create(dto, new Set(assetIds));
    await sut.hideForUser(direct.id, user.id);
    const preserved = await sut.get(old.memoryId!);
    expect(preserved?.deletedAt).toBeNull();
    expect(preserved?.assets.map(({ id }) => id).toSorted()).toEqual(replacementIds.toSorted());
    const visible = await sut.searchAccessible(user.id, {});
    expect(visible.map(({ id }) => id)).toEqual([old.memoryId]);
    await expect(sut.create(dto, new Set(assetIds))).rejects.toBeInstanceOf(MemorySuppressedException);
  });
});
