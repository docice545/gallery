import { Kysely } from 'kysely';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { StorageCore } from 'src/cores/storage.core.js';
import { AssetStatus, ChecksumAlgorithm, StorageFolder, SyncEntityType, SyncRequestType } from 'src/enum.js';
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
import { UserRepository } from 'src/repositories/user.repository.js';
import { DB } from 'src/schema/index.js';
import { AssetService } from 'src/services/asset.service.js';
import { StackService } from 'src/services/stack.service.js';
import { snapshotOriginal, unlinkOriginal, validateDeletionRoots } from 'src/utils/authorized-deletion.js';
import { SyncTestContext, newMediumService } from 'test/medium.factory.js';
import { getKyselyDB } from 'test/utils.js';

let database: Kysely<DB>;
let directory: string;
const types = [SyncRequestType.AssetsV2, SyncRequestType.StacksV1];

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
