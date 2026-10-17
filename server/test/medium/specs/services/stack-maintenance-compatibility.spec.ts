import { Kysely } from 'kysely';
import { AssetType, AssetVisibility } from 'src/enum.js';
import { AccessRepository } from 'src/repositories/access.repository.js';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { EventRepository } from 'src/repositories/event.repository.js';
import { JobRepository } from 'src/repositories/job.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { SharedSpaceRepository } from 'src/repositories/shared-space.repository.js';
import { StackRepository } from 'src/repositories/stack.repository.js';
import { StorageRepository } from 'src/repositories/storage.repository.js';
import { DB } from 'src/schema/index.js';
import { AssetService } from 'src/services/asset.service.js';
import { StackService } from 'src/services/stack.service.js';
import { newMediumService } from 'test/medium.factory.js';
import { factory } from 'test/small.factory.js';
import { getKyselyDB } from 'test/utils.js';

let database: Kysely<DB>;

const setup = () => {
  const { sut, ctx } = newMediumService(StackService, {
    database,
    real: [AccessRepository, AssetRepository, SharedSpaceRepository, StackRepository],
    mock: [EventRepository, JobRepository, LoggingRepository, StorageRepository],
  });
  ctx.getMock(EventRepository).emit.mockResolvedValue();
  return { sut, ctx, assets: ctx.get(AssetRepository) };
};

// Stack responses include EXIF-backed assets, just as the production library does.
const newMedia = async (ctx: ReturnType<typeof setup>['ctx'], ownerId: string, type = AssetType.Image) => {
  const { asset } = await ctx.newAsset({ ownerId, type });
  await ctx.newExif({ assetId: asset.id, timeZone: 'UTC' });
  return asset;
};

beforeAll(async () => {
  database = await getKyselyDB();
});

afterAll(async () => {
  await database?.destroy();
});

describe('external stack maintenance compatibility', () => {
  it('dissolves a stack without deleting originals or its photo/hidden-motion relationship', async () => {
    const { sut, ctx, assets } = setup();
    const { user } = await ctx.newUser();
    const auth = factory.auth({ user });
    const motion = await newMedia(ctx, user.id, AssetType.Video);
    await assets.update({ id: motion.id, visibility: AssetVisibility.Hidden });
    const photo = await newMedia(ctx, user.id);
    await assets.update({ id: photo.id, livePhotoVideoId: motion.id });
    const sibling = await newMedia(ctx, user.id);
    const stack = await sut.create(auth, { assetIds: [photo.id, sibling.id] });
    const ids = [photo.id, sibling.id, motion.id];
    const before = await database
      .selectFrom('asset')
      .select(['id', 'ownerId', 'type', 'originalPath', 'checksum', 'deletedAt', 'visibility', 'livePhotoVideoId'])
      .where('id', 'in', ids)
      .orderBy('id')
      .execute();

    await sut.delete(auth, stack.id);

    const after = await database
      .selectFrom('asset')
      .select(['id', 'ownerId', 'type', 'originalPath', 'checksum', 'deletedAt', 'visibility', 'livePhotoVideoId'])
      .where('id', 'in', ids)
      .orderBy('id')
      .execute();
    expect(after).toEqual(before);
    expect(after).toHaveLength(3);
    expect(await assets.getById(photo.id)).toMatchObject({ stackId: null, livePhotoVideoId: motion.id });
    expect(await assets.getById(sibling.id)).toMatchObject({ stackId: null });
    expect(await ctx.get(StackRepository).getById(stack.id)).toBeUndefined();
    const suppressions = await sut.getSuppressions(auth, 1);
    expect(suppressions.map(({ assetId }) => assetId).toSorted()).toEqual([photo.id, sibling.id].toSorted());
    expect(ctx.getMock(JobRepository).queue).not.toHaveBeenCalled();
    expect(ctx.getMock(JobRepository).queueAll).not.toHaveBeenCalled();
    expect(ctx.getMock(StorageRepository).unlink).not.toHaveBeenCalled();
  });

  it('keeps dissolution and suppression scoped to the authenticated owner', async () => {
    const { sut, ctx, assets } = setup();
    const { user } = await ctx.newUser();
    const { user: other } = await ctx.newUser();
    const auth = factory.auth({ user });
    const otherAuth = factory.auth({ user: other });
    const members = await Promise.all([newMedia(ctx, user.id), newMedia(ctx, user.id)]);
    const otherMembers = await Promise.all([newMedia(ctx, other.id), newMedia(ctx, other.id)]);
    const stack = await sut.create(auth, { assetIds: members.map(({ id }) => id) });
    const otherStack = await sut.create(otherAuth, { assetIds: otherMembers.map(({ id }) => id) });

    await expect(sut.delete(auth, otherStack.id)).rejects.toThrow('Not found or no stack.delete access');
    await sut.delete(auth, stack.id);

    expect(await sut.getSuppressions(otherAuth, 1)).toEqual([]);
    expect(await sut.get(otherAuth, otherStack.id)).toMatchObject({ id: otherStack.id });
    for (const member of otherMembers) {
      expect(await assets.getById(member.id)).toMatchObject({ stackId: otherStack.id, deletedAt: null });
    }
    const suppressions = await sut.getSuppressions(auth, 1);
    expect(suppressions.map(({ assetId }) => assetId).toSorted()).toEqual(members.map(({ id }) => id).toSorted());
  });

  it('rejects automatic recreation while allowing explicit manual restoration without clearing decisions', async () => {
    const { sut, ctx } = setup();
    const { user } = await ctx.newUser();
    const auth = factory.auth({ user });
    const members = await Promise.all([newMedia(ctx, user.id), newMedia(ctx, user.id)]);
    const assetIds = members.map(({ id }) => id);
    const stack = await sut.create(auth, { assetIds, automatic: true });
    await sut.delete(auth, stack.id);

    await expect(sut.create(auth, { assetIds, automatic: true })).rejects.toThrow(
      'Automatic stacking suppressed by user',
    );
    expect(await sut.search(auth, {})).toEqual([]);

    const restored = await sut.create(auth, { assetIds });
    expect(restored.assets.map(({ id }) => id).toSorted()).toEqual(assetIds.toSorted());
    const suppressions = await sut.getSuppressions(auth, 1);
    expect(suppressions.map(({ assetId }) => assetId).toSorted()).toEqual(assetIds.toSorted());
    await expect(sut.create(auth, { assetIds, automatic: true })).rejects.toThrow(
      'Automatic stacking suppressed by user',
    );
    expect(await sut.get(auth, restored.id)).toMatchObject({ id: restored.id });
  });

  it('checks suppressed children expanded from an existing primary before an automatic extension', async () => {
    const { sut, ctx, assets } = setup();
    const { user } = await ctx.newUser();
    const auth = factory.auth({ user });
    const suppressed = await newMedia(ctx, user.id);
    const formerSibling = await newMedia(ctx, user.id);
    const former = await sut.create(auth, { assetIds: [suppressed.id, formerSibling.id] });
    await sut.delete(auth, former.id);
    const primary = await newMedia(ctx, user.id);
    const restored = await sut.create(auth, { assetIds: [primary.id, suppressed.id] });
    const incoming = await newMedia(ctx, user.id);

    await expect(sut.create(auth, { assetIds: [primary.id, incoming.id], automatic: true })).rejects.toThrow(
      'Automatic stacking suppressed by user',
    );

    const unchanged = await sut.get(auth, restored.id);
    expect(unchanged.assets.map(({ id }) => id).toSorted()).toEqual([primary.id, suppressed.id].toSorted());
    expect(await assets.getById(incoming.id)).toMatchObject({ stackId: null, deletedAt: null });
  });

  it('detaches a member without losing its original and protects that member against automated regrouping', async () => {
    const { sut, ctx, assets } = setup();
    const { user } = await ctx.newUser();
    const auth = factory.auth({ user });
    const members = await Promise.all([newMedia(ctx, user.id), newMedia(ctx, user.id), newMedia(ctx, user.id)]);
    const [primary, removed, sibling] = members;
    const stack = await sut.create(auth, { assetIds: members.map(({ id }) => id) });

    await sut.removeAsset(auth, { id: stack.id, assetId: removed.id });

    expect(await assets.getById(removed.id)).toMatchObject({
      stackId: null,
      deletedAt: null,
      originalPath: removed.originalPath,
      checksum: removed.checksum,
    });
    const remaining = await sut.get(auth, stack.id);
    expect(remaining.assets.map(({ id }) => id).toSorted()).toEqual([primary.id, sibling.id].toSorted());
    expect(await sut.getSuppressions(auth, 1)).toEqual([{ assetId: removed.id }]);
    await expect(sut.create(auth, { assetIds: [removed.id, sibling.id], automatic: true })).rejects.toThrow(
      'Automatic stacking suppressed by user',
    );
    expect(await assets.getById(sibling.id)).toMatchObject({ stackId: stack.id });
  });

  it('creates and extends a native same-owner mixed-media stack while retaining its chosen primary and members', async () => {
    const { sut, ctx, assets } = setup();
    const { user } = await ctx.newUser();
    const auth = factory.auth({ user });
    const primary = await newMedia(ctx, user.id);
    const child = await newMedia(ctx, user.id);
    const incoming = await newMedia(ctx, user.id, AssetType.Video);
    const stack = await sut.create(auth, { assetIds: [primary.id, child.id], automatic: true });

    // Native extension references the existing primary; the server expands its children.
    const extended = await sut.create(auth, { assetIds: [primary.id, incoming.id], automatic: true });

    expect(extended.primaryAssetId).toBe(primary.id);
    expect(extended.assets[0].id).toBe(primary.id);
    expect(extended.assets.map(({ id }) => id).toSorted()).toEqual([primary.id, child.id, incoming.id].toSorted());
    expect(await ctx.get(StackRepository).getById(stack.id)).toBeUndefined();
    expect(await sut.getSuppressions(auth, 1)).toEqual([]);
    for (const id of [primary.id, child.id, incoming.id]) {
      expect(await assets.getById(id)).toMatchObject({ ownerId: user.id, stackId: extended.id, deletedAt: null });
    }
  });

  it('rejects cross-owner stack creation without changing either owner assets', async () => {
    const { sut, ctx, assets } = setup();
    const { user } = await ctx.newUser();
    const { user: other } = await ctx.newUser();
    const ownAsset = await newMedia(ctx, user.id);
    const foreignAsset = await newMedia(ctx, other.id);

    await expect(
      sut.create(factory.auth({ user }), { assetIds: [ownAsset.id, foreignAsset.id], automatic: true }),
    ).rejects.toThrow('Not found or no asset.update access');

    expect(await assets.getById(ownAsset.id)).toMatchObject({ ownerId: user.id, stackId: null, deletedAt: null });
    expect(await assets.getById(foreignAsset.id)).toMatchObject({ ownerId: other.id, stackId: null, deletedAt: null });
    expect(await sut.search(factory.auth({ user }), {})).toEqual([]);
    expect(await sut.search(factory.auth({ user: other }), {})).toEqual([]);
  });

  it('hides only a redundant standalone video through the native asset service without changing the linked motion video', async () => {
    const { ctx, assets } = setup();
    const { user } = await ctx.newUser();
    const auth = factory.auth({ user });
    const motion = await newMedia(ctx, user.id, AssetType.Video);
    await assets.update({ id: motion.id, visibility: AssetVisibility.Hidden });
    const photo = await newMedia(ctx, user.id);
    await assets.update({ id: photo.id, livePhotoVideoId: motion.id });
    const redundant = await newMedia(ctx, user.id, AssetType.Video);
    const assetService = ctx.getService(AssetService);

    await assetService.update(auth, redundant.id, { visibility: AssetVisibility.Hidden });

    expect(await assets.getById(redundant.id)).toMatchObject({
      visibility: AssetVisibility.Hidden,
      deletedAt: null,
      originalPath: redundant.originalPath,
      checksum: redundant.checksum,
    });
    expect(await assets.getById(photo.id)).toMatchObject({
      livePhotoVideoId: motion.id,
      visibility: AssetVisibility.Timeline,
      deletedAt: null,
    });
    expect(await assets.getById(motion.id)).toMatchObject({
      visibility: AssetVisibility.Hidden,
      deletedAt: null,
      originalPath: motion.originalPath,
      checksum: motion.checksum,
    });
    expect(ctx.getMock(JobRepository).queue).not.toHaveBeenCalled();
    expect(ctx.getMock(StorageRepository).unlink).not.toHaveBeenCalled();
  });
});
