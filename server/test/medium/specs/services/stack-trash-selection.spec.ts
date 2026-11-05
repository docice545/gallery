import { Kysely } from 'kysely';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { StorageCore } from 'src/cores/storage.core.js';
import { AuthDto } from 'src/dtos/auth.dto.js';
import {
  AssetStatus,
  AssetVisibility,
  ChecksumAlgorithm,
  StorageFolder,
  SyncEntityType,
  SyncRequestType,
} from 'src/enum.js';
import { AccessRepository } from 'src/repositories/access.repository.js';
import { AssetFavoriteRepository } from 'src/repositories/asset-favorite.repository.js';
import { AssetJobRepository } from 'src/repositories/asset-job.repository.js';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { ConfigRepository } from 'src/repositories/config.repository.js';
import { EventRepository } from 'src/repositories/event.repository.js';
import { JobRepository } from 'src/repositories/job.repository.js';
import { LibraryRepository } from 'src/repositories/library.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { SharedSpaceRepository } from 'src/repositories/shared-space.repository.js';
import { StackRepository } from 'src/repositories/stack.repository.js';
import { StorageRepository } from 'src/repositories/storage.repository.js';
import { SystemMetadataRepository } from 'src/repositories/system-metadata.repository.js';
import { TrashRepository } from 'src/repositories/trash.repository.js';
import { UserRepository } from 'src/repositories/user.repository.js';
import { DB } from 'src/schema/index.js';
import { AssetService } from 'src/services/asset.service.js';
import { NotificationService } from 'src/services/notification.service.js';
import { StackService } from 'src/services/stack.service.js';
import { TrashService } from 'src/services/trash.service.js';
import { snapshotOriginal, unlinkOriginal, validateDeletionRoots } from 'src/utils/authorized-deletion.js';
import { SyncTestContext, newMediumService } from 'test/medium.factory.js';
import { getKyselyDB, newTestService } from 'test/utils.js';

let database: Kysely<DB>;
let directory: string;
const types = [SyncRequestType.AssetsV2, SyncRequestType.StacksV1];
const timelineAssets = async (assets: AssetRepository, auth: AuthDto) => {
  const result = await assets.getTimeBucket('2026-10-01', { userIds: [auth.user.id], withStacked: true }, auth);
  return JSON.parse(result.assets) as {
    id: string[];
    stack: (string[] | null)[];
  };
};

beforeAll(async () => {
  database = await getKyselyDB();
});
afterAll(async () => {
  await database.destroy();
});
beforeEach(async () => {
  directory = await mkdtemp(join(tmpdir(), 'foto-stack-trash-selection-'));
});
afterEach(async () => {
  vi.restoreAllMocks();
  await rm(directory, { recursive: true, force: true });
});

// All original bytes belong to this disposable fixture. No production paths,
// Redis/HTTP, Android media operations, or relaxed deletion policy are involved.
const fixture = async (sizes: number[]) => {
  const sync = new SyncTestContext(database);
  const { auth, user } = await sync.newSyncAuthUser();
  const { sut, ctx } = newMediumService(AssetService, {
    database,
    real: [
      AccessRepository,
      AssetFavoriteRepository,
      AssetJobRepository,
      AssetRepository,
      ConfigRepository,
      LibraryRepository,
      SharedSpaceRepository,
      StackRepository,
      SystemMetadataRepository,
      UserRepository,
    ],
    mock: [EventRepository, JobRepository, LoggingRepository, StorageRepository],
  });
  ctx.getMock(EventRepository).emit.mockResolvedValue();
  ctx.getMock(JobRepository).queue.mockResolvedValue();

  const root = join(directory, 'originals');
  const encoded = join(directory, 'encoded', user.id);
  await mkdir(root);
  await mkdir(encoded, { recursive: true });
  // The authorization boundary also examines other users' configured roots.
  // Keep those derived paths inside this temporary namespace, never /data.
  vi.spyOn(StorageCore, 'getMediaLocation').mockReturnValue(directory);
  const actualFolder = StorageCore.getFolderLocation;
  const actualLibrary = StorageCore.getLibraryFolder;
  vi.spyOn(StorageCore, 'getFolderLocation').mockImplementation((folder, owner) =>
    owner === user.id && folder === StorageFolder.Upload
      ? root
      : owner === user.id && folder === StorageFolder.EncodedVideo
        ? encoded
        : actualFolder(folder, owner),
  );
  vi.spyOn(StorageCore, 'getLibraryFolder').mockImplementation((owner) =>
    owner.id === user.id ? root : actualLibrary(owner),
  );
  const storage = ctx.getMock(StorageRepository);
  const actualStorage = new StorageRepository(ctx.getMock(LoggingRepository));
  storage.checkFileExists.mockImplementation((path, mode) => actualStorage.checkFileExists(path, mode));
  storage.snapshotOriginal.mockImplementation((path, roots) => {
    expect(path.startsWith(`${root}/`), 'only disposable fixture bytes may be inspected').toBe(true);
    return snapshotOriginal(path, roots);
  });
  storage.unlinkOriginal.mockImplementation((file, recheck) => {
    expect(file.path.startsWith(`${root}/`), 'only disposable fixture originals may be removed').toBe(true);
    return unlinkOriginal(file, recheck);
  });
  storage.validateDeletionRoots.mockImplementation(validateDeletionRoots);

  const create = async (name: string) => {
    const bytes = Buffer.from(`synthetic stack selection fixture: ${name}`);
    const path = join(root, `${name}.jpg`);
    await writeFile(path, bytes);
    const captured = new Date('2026-10-26T10:00:00Z');
    const { asset } = await ctx.newAsset({
      ownerId: user.id,
      originalPath: path,
      originalFileName: `${name}.jpg`,
      checksum: createHash('sha1').update(bytes).digest(),
      checksumAlgorithm: ChecksumAlgorithm.sha1File,
      fileCreatedAt: captured,
      localDateTime: captured,
    });
    await ctx.newExif({ assetId: asset.id, fileSizeInByte: bytes.length, timeZone: 'UTC' });
    return { id: asset.id, path, bytes };
  };
  const stacks = [];
  for (const [index, size] of sizes.entries()) {
    const members = [];
    for (let member = 0; member < size; member++) {
      members.push(await create(`stack-${index}-frame-${member}`));
    }
    const stack = await ctx.getService(StackService).create(auth, { assetIds: members.map(({ id }) => id) });
    stacks.push({ stack, members });
  }
  const selectedLoose = sizes.length > 1 ? await create('selected-loose') : null;
  const outsideSelection = await create('outside-selection');
  const initial = await sync.syncStream(auth, types);
  await sync.syncAckAll(auth, initial);
  return { sut, ctx, sync, auth, user, stacks, selectedLoose, outsideSelection };
};

describe('explicit stack selection is a complete remote UUID set', () => {
  it('excludes Hidden/Locked cover and loose-asset metadata while allowing Archive restoration updates', async () => {
    const f = await fixture([3]);
    const { members } = f.stacks[0];
    const [primary, child] = members;
    const assets = f.ctx.get(AssetRepository);
    const { sut: notifications, mocks } = newTestService(NotificationService, { asset: assets });
    const read = vi.spyOn(assets, 'getByIdsForTimelineNotifications');
    for (const visibility of [AssetVisibility.Hidden, AssetVisibility.Locked]) {
      await assets.update({ id: primary.id, visibility });
      await assets.update({ id: f.outsideSelection.id, visibility });
      const assetIds = [child.id, f.outsideSelection.id];
      mocks.websocket.clientSend.mockClear();
      expect(await assets.getByIdsForTimelineNotifications([primary.id, ...assetIds], f.user.id)).toEqual([]);
      read.mockClear();
      await notifications.onAssetsRestore({ assetIds, userId: f.user.id });
      expect(read).not.toHaveBeenCalled();
      expect(mocks.websocket.clientSend.mock.calls).toEqual([['on_asset_restore', f.user.id, assetIds]]);
    }

    await assets.update({ id: f.outsideSelection.id, visibility: AssetVisibility.Archive });
    mocks.websocket.clientSend.mockClear();
    await notifications.onAssetsRestore({ assetIds: [f.outsideSelection.id], userId: f.user.id });
    expect(mocks.websocket.clientSend.mock.calls).toEqual([
      ['on_asset_restore', f.user.id, [f.outsideSelection.id]],
      [
        'on_asset_update',
        f.user.id,
        expect.objectContaining({
          id: f.outsideSelection.id,
          visibility: AssetVisibility.Archive,
          stack: null,
        }),
      ],
    ]);
    for (const member of [...members, f.outsideSelection]) {
      expect(await readFile(member.path)).toEqual(member.bytes);
    }
  });

  it.each([2, 3, 5])(
    'notifies the owner of only the active %i-frame stack cover after Trash and restore',
    async (size) => {
      const f = await fixture([size]);
      const { members, stack } = f.stacks[0];
      const primary = members[0];
      const child = members.at(-1)!;
      const { sut: notifications, mocks } = newTestService(NotificationService, { asset: f.ctx.get(AssetRepository) });
      const send = mocks.websocket.clientSend;

      await f.sut.deleteAll(f.auth, { ids: [child.id], force: false });
      await notifications.onAssetsTrash({ assetIds: [child.id], userId: f.user.id });

      expect(send.mock.calls).toEqual([
        ['on_asset_trash', f.user.id, [child.id]],
        [
          'on_asset_update',
          f.user.id,
          expect.objectContaining({
            id: primary.id,
            ownerId: f.user.id,
            stack: size === 2 ? null : { id: stack.id, primaryAssetId: primary.id, assetCount: size - 1 },
          }),
        ],
      ]);

      send.mockClear();
      await new TrashRepository(database).restoreAll([child.id], f.user.id);
      await notifications.onAssetsRestore({ assetIds: [child.id, child.id], userId: f.user.id });
      expect(send.mock.calls).toEqual([
        ['on_asset_restore', f.user.id, [child.id, child.id]],
        [
          'on_asset_update',
          f.user.id,
          expect.objectContaining({
            id: primary.id,
            stack: { id: stack.id, primaryAssetId: primary.id, assetCount: size },
          }),
        ],
      ]);

      send.mockClear();
      await f.sut.deleteAll(f.auth, { ids: [primary.id], force: false });
      await notifications.onAssetsTrash({ assetIds: [primary.id], userId: f.user.id });
      const active = await f.ctx.getService(StackService).get(f.auth, stack.id);
      expect(send.mock.calls).toEqual([
        ['on_asset_trash', f.user.id, [primary.id]],
        [
          'on_asset_update',
          f.user.id,
          expect.objectContaining({
            id: active.primaryAssetId,
            stack: size === 2 ? null : { id: stack.id, primaryAssetId: active.primaryAssetId, assetCount: size - 1 },
          }),
        ],
      ]);

      send.mockClear();
      const activeIds = active.assets.map(({ id }) => id);
      await f.sut.deleteAll(f.auth, { ids: activeIds, force: false });
      await notifications.onAssetsTrash({ assetIds: activeIds, userId: f.user.id });
      expect(send.mock.calls).toEqual([['on_asset_trash', f.user.id, activeIds]]);
      expect(await f.ctx.get(AssetRepository).getByIdsForTimelineNotifications(activeIds, f.user.id)).toEqual([]);

      send.mockClear();
      const { sut: restore, mocks: restoreMocks } = newTestService(TrashService, {
        trash: new TrashRepository(database),
      });
      restoreMocks.duplicateRepository.deleteConflictingTombstonesForUser.mockResolvedValue();
      restoreMocks.event.emit.mockResolvedValue();
      expect(await restore.restore(f.auth)).toEqual({ count: size });
      const restoredIds = members.map(({ id }) => id);
      expect(restoreMocks.event.emit).toHaveBeenCalledWith('AssetRestoreAll', {
        assetIds: expect.arrayContaining(restoredIds),
        userId: f.user.id,
      });
      await notifications.onAssetsRestore({ assetIds: restoredIds, userId: f.user.id });
      const restored = await f.ctx.getService(StackService).get(f.auth, stack.id);
      expect(send.mock.calls).toEqual([
        ['on_asset_restore', f.user.id, restoredIds],
        [
          'on_asset_update',
          f.user.id,
          expect.objectContaining({
            id: restored.primaryAssetId,
            stack: { id: stack.id, primaryAssetId: restored.primaryAssetId, assetCount: size },
          }),
        ],
      ]);
      const { user: other } = await f.ctx.newUser();
      expect(await f.ctx.get(AssetRepository).getActiveTimelineRepresentativeIds(restoredIds, other.id)).toEqual([]);
      expect(await f.ctx.get(AssetRepository).getByIdsForTimelineNotifications(restoredIds, other.id)).toEqual([]);
    },
  );

  it.each([2, 3, 5])('keeps the %i-frame stack restorable while promoting an active primary on Trash', async (size) => {
    const f = await fixture([size]);
    const { members, stack } = f.stacks[0];
    const [primary, ...survivors] = members;
    const assets = f.ctx.get(AssetRepository);

    await f.sut.deleteAll(f.auth, { ids: [primary.id], force: false });

    const activeStack = await f.ctx.getService(StackService).get(f.auth, stack.id);
    expect(survivors.map(({ id }) => id)).toContain(activeStack.primaryAssetId);
    expect(activeStack.assets.map(({ id }) => id).toSorted()).toEqual(survivors.map(({ id }) => id).toSorted());
    const timeline = await timelineAssets(assets, f.auth);
    expect(timeline.id).toContain(activeStack.primaryAssetId);
    if (size === 2) {
      expect(timeline.stack[timeline.id.indexOf(activeStack.primaryAssetId)]).toBeNull();
      expect(await assets.getById(activeStack.primaryAssetId, { stack: { assets: true } })).toMatchObject({
        stack: null,
      });
    }
    for (const member of members) {
      expect(await assets.getById(member.id)).toMatchObject({ stackId: stack.id });
      expect(await readFile(member.path)).toEqual(member.bytes);
    }
    const trash = new TrashRepository(database);
    expect(await trash.restoreAll([primary.id], f.user.id)).toEqual([primary.id]);
    const restored = await f.ctx.getService(StackService).get(f.auth, stack.id);
    expect(restored.assets.map(({ id }) => id).toSorted()).toEqual(members.map(({ id }) => id).toSorted());
    expect(await f.ctx.getService(StackService).getSuppressions(f.auth, 1)).toEqual([]);
  });

  it('shows a partially restored whole stack without losing its original membership', async () => {
    const f = await fixture([3]);
    const { members, stack } = f.stacks[0];
    const [primary, restoredMember] = members;
    await f.sut.deleteAll(f.auth, { ids: members.map(({ id }) => id), force: false });
    const trash = new TrashRepository(database);

    expect(await trash.restoreAll([restoredMember.id], f.user.id)).toEqual([restoredMember.id]);

    expect(await f.ctx.getService(StackService).get(f.auth, stack.id)).toMatchObject({
      primaryAssetId: restoredMember.id,
      assets: [expect.objectContaining({ id: restoredMember.id })],
    });
    const timeline = await timelineAssets(f.ctx.get(AssetRepository), f.auth);
    expect(timeline.id).toContain(restoredMember.id);
    expect(timeline.stack[timeline.id.indexOf(restoredMember.id)]).toBeNull();
    expect(await f.ctx.get(AssetRepository).getById(primary.id)).toMatchObject({ status: AssetStatus.Trashed });
    expect(await trash.restore(f.user.id)).toBe(2);
    const restored = await f.ctx.getService(StackService).get(f.auth, stack.id);
    expect(restored.assets.map(({ id }) => id).toSorted()).toEqual(members.map(({ id }) => id).toSorted());
    for (const member of members) {
      expect(await f.ctx.get(AssetRepository).getById(member.id)).toMatchObject({ stackId: stack.id });
      expect(await readFile(member.path)).toEqual(member.bytes);
    }
  });

  it('keeps an active primary and every stack link through concurrent Trash and restore', async () => {
    const f = await fixture([3]);
    const { members, stack } = f.stacks[0];
    const [primary, sibling, survivor] = members;
    const assets = f.ctx.get(AssetRepository);
    const stacks = f.ctx.getService(StackService);

    await Promise.all([
      f.sut.deleteAll(f.auth, { ids: [primary.id], force: false }),
      f.sut.deleteAll(f.auth, { ids: [sibling.id], force: false }),
    ]);

    expect(await stacks.get(f.auth, stack.id)).toMatchObject({
      primaryAssetId: survivor.id,
      assets: [expect.objectContaining({ id: survivor.id })],
    });

    const trash = new TrashRepository(database);
    await Promise.all([
      trash.restoreAll([primary.id], f.user.id),
      f.sut.deleteAll(f.auth, { ids: [survivor.id], force: false }),
    ]);

    expect(await stacks.get(f.auth, stack.id)).toMatchObject({
      primaryAssetId: primary.id,
      assets: [expect.objectContaining({ id: primary.id })],
    });
    expect(await assets.getById(primary.id, { stack: { assets: true } })).toMatchObject({
      status: AssetStatus.Active,
      deletedAt: null,
      stack: null,
    });
    expect(await f.sut.get(f.auth, primary.id)).toMatchObject({ id: primary.id, stack: null });
    const timeline = await timelineAssets(assets, f.auth);
    expect(timeline.id).toContain(primary.id);
    expect(timeline.stack[timeline.id.indexOf(primary.id)]).toBeNull();
    for (const member of members) {
      expect(await assets.getById(member.id)).toMatchObject({
        stackId: stack.id,
        status: member.id === primary.id ? AssetStatus.Active : AssetStatus.Trashed,
      });
      expect(await readFile(member.path)).toEqual(member.bytes);
    }
  });

  it.each([2, 3, 5])(
    'trashes and purges all %i selected frames with complete sync tombstones and no orphan',
    async (size) => {
      const f = await fixture([size]);
      const { members, stack } = f.stacks[0];
      const ids = members.map(({ id }) => id);

      await f.sut.deleteAll(f.auth, { ids, force: false });

      const trashed = await database.selectFrom('asset').selectAll().where('id', 'in', ids).execute();
      expect(trashed).toHaveLength(size);
      for (const row of trashed) {
        expect(row.status).toBe(AssetStatus.Trashed);
        expect(row.deletedAt).not.toBeNull();
      }
      for (const member of members) {
        expect(await readFile(member.path)).toEqual(member.bytes);
      }
      const trashSync = await f.sync.syncStream(f.auth, types);
      const trashUpdates = trashSync.filter(({ type }) => type === SyncEntityType.AssetV2);
      expect(trashUpdates.map(({ data }) => data.id as string).toSorted()).toEqual(ids.toSorted());
      for (const { data } of trashUpdates) {
        expect(data.deletedAt).not.toBeNull();
      }
      await f.sync.syncAckAll(f.auth, trashSync);

      expect(await f.sut.emptyAuthorizedTrash(f.auth)).toEqual({ count: size });
      expect(await database.selectFrom('asset').select('id').where('id', 'in', ids).execute()).toEqual([]);
      expect(await database.selectFrom('stack').select('id').where('id', '=', stack.id).execute()).toEqual([]);
      for (const member of members) {
        expect(await f.sut.deletionStatus(f.auth, member.id)).toMatchObject({ id: member.id, state: 'complete' });
        await expect(readFile(member.path)).rejects.toMatchObject({ code: 'ENOENT' });
      }
      const deleted = await f.sync.syncStream(f.auth, types);
      expect(
        deleted
          .filter(({ type }) => type === SyncEntityType.AssetDeleteV1)
          .map(({ data }) => data.assetId as string)
          .toSorted(),
      ).toEqual(ids.toSorted());
      expect(deleted).toContainEqual(
        expect.objectContaining({ type: SyncEntityType.StackDeleteV1, data: { stackId: stack.id } }),
      );
      await f.sync.syncAckAll(f.auth, deleted);
      await f.sync.assertSyncIsComplete(f.auth, types);
      expect(await f.sut.emptyAuthorizedTrash(f.auth)).toEqual({ count: 0 });
      expect(await database.selectFrom('asset').select('id').where('ownerId', '=', f.user.id).execute()).toEqual([
        { id: f.outsideSelection.id },
      ]);
      expect(await readFile(f.outsideSelection.path)).toEqual(f.outsideSelection.bytes);
      expect(await f.ctx.get(AssetRepository).getById(f.outsideSelection.id)).toMatchObject({
        status: AssetStatus.Active,
      });
    },
  );

  it.each([2, 3, 5])(
    'an explicit single primary-frame deletion preserves the other %i-stack members and original UUIDs',
    async (size) => {
      const f = await fixture([size]);
      const { members, stack } = f.stacks[0];
      const [primary, ...survivors] = members;

      // This is intentional for an individual viewer frame. It is the exact
      // failure mode when a collapsed whole-stack selection sent only its primary.
      await f.sut.deleteAll(f.auth, { ids: [primary.id], force: false });
      expect(await f.sut.emptyAuthorizedTrash(f.auth)).toEqual({ count: 1 });

      expect(await f.ctx.get(AssetRepository).getById(primary.id)).toBeUndefined();
      expect(await f.sut.deletionStatus(f.auth, primary.id)).toMatchObject({ state: 'complete' });
      for (const survivor of survivors) {
        const row = await f.ctx.get(AssetRepository).getById(survivor.id);
        expect(row).toMatchObject({ id: survivor.id, status: AssetStatus.Active, deletedAt: null });
        if (size === 2) {
          expect(row?.stackId).toBeNull();
        }
        expect(await readFile(survivor.path)).toEqual(survivor.bytes);
        expect(await f.sut.deletionStatus(f.auth, survivor.id)).toMatchObject({ state: 'blocked' });
      }
      if (size === 2) {
        expect(await f.ctx.get(StackRepository).getById(stack.id)).toBeUndefined();
      } else {
        const remainingStack = await f.ctx.getService(StackService).get(f.auth, stack.id);
        expect(remainingStack.assets.map(({ id }) => id).toSorted()).toEqual(survivors.map(({ id }) => id).toSorted());
        expect(survivors.map(({ id }) => id)).toContain(remainingStack.primaryAssetId);
      }
      const deleted = await f.sync.syncStream(f.auth, types);
      expect(
        deleted.filter(({ type }) => type === SyncEntityType.AssetDeleteV1).map(({ data }) => data.assetId),
      ).toEqual([primary.id]);
      await f.sync.syncAckAll(f.auth, deleted);
      await f.sync.assertSyncIsComplete(f.auth, types);
      const remaining = await database.selectFrom('asset').select('id').where('ownerId', '=', f.user.id).execute();
      expect(remaining.map(({ id }) => id).toSorted()).toEqual(
        [...survivors.map(({ id }) => id), f.outsideSelection.id].toSorted(),
      );
      expect(await readFile(f.outsideSelection.path)).toEqual(f.outsideSelection.bytes);
    },
  );

  it('purges a mixed date-selection batch of 2/3/5-frame stacks without leaving active detached children', async () => {
    const f = await fixture([2, 3, 5]);
    expect(f.selectedLoose).not.toBeNull();
    const ids = [...f.stacks.flatMap(({ members }) => members.map(({ id }) => id)), f.selectedLoose!.id];

    await f.sut.deleteAll(f.auth, { ids, force: false });
    expect(await f.sut.emptyAuthorizedTrash(f.auth)).toEqual({ count: 11 });

    const remaining = await database
      .selectFrom('asset')
      .select(['id', 'status'])
      .where('ownerId', '=', f.user.id)
      .execute();
    expect(remaining).toEqual([{ id: f.outsideSelection.id, status: AssetStatus.Active }]);
    const deleted = await f.sync.syncStream(f.auth, types);
    expect(
      deleted
        .filter(({ type }) => type === SyncEntityType.AssetDeleteV1)
        .map(({ data }) => data.assetId as string)
        .toSorted(),
    ).toEqual(ids.toSorted());
    await f.sync.syncAckAll(f.auth, deleted);
    await f.sync.assertSyncIsComplete(f.auth, types);
    for (const id of ids) {
      expect(await f.sut.deletionStatus(f.auth, id)).toMatchObject({ id, state: 'complete' });
    }
    expect(await readFile(f.outsideSelection.path)).toEqual(f.outsideSelection.bytes);
  });
});
