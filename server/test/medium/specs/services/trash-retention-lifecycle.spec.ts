import { Kysely, type Transaction, sql } from 'kysely';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout } from 'node:timers/promises';
import { StorageCore } from 'src/cores/storage.core.js';
import { AssetFileType, AssetStatus, AssetType, AssetVisibility, JobName, JobStatus } from 'src/enum.js';
import { AccessRepository } from 'src/repositories/access.repository.js';
import { AlbumRepository } from 'src/repositories/album.repository.js';
import { AssetJobRepository } from 'src/repositories/asset-job.repository.js';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { DuplicateRepository } from 'src/repositories/duplicate.repository.js';
import { EventRepository } from 'src/repositories/event.repository.js';
import { JobRepository } from 'src/repositories/job.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { PartnerRepository } from 'src/repositories/partner.repository.js';
import { SharedSpaceRepository } from 'src/repositories/shared-space.repository.js';
import { StackRepository } from 'src/repositories/stack.repository.js';
import { StorageRepository } from 'src/repositories/storage.repository.js';
import { TrashRepository } from 'src/repositories/trash.repository.js';
import { UserRepository } from 'src/repositories/user.repository.js';
import { DB } from 'src/schema/index.js';
import { AssetService } from 'src/services/asset.service.js';
import { StorageService } from 'src/services/storage.service.js';
import { TimelineService } from 'src/services/timeline.service.js';
import { TrashService } from 'src/services/trash.service.js';
import { snapshotOriginal, unlinkOriginal } from 'src/utils/authorized-deletion.js';
import { newMediumService } from 'test/medium.factory.js';
import { factory } from 'test/small.factory.js';
import { getKyselyDB } from 'test/utils.js';

let database: Kysely<DB>;
beforeAll(async () => {
  database = await getKyselyDB();
});
afterAll(async () => {
  await database.destroy();
});

const setup = () => {
  const result = newMediumService(AssetService, {
    database,
    real: [
      AssetRepository,
      AssetJobRepository,
      AccessRepository,
      AlbumRepository,
      TrashRepository,
      DuplicateRepository,
      PartnerRepository,
      SharedSpaceRepository,
      StackRepository,
      UserRepository,
    ],
    mock: [EventRepository, JobRepository, LoggingRepository, StorageRepository],
  });
  result.ctx.getMock(EventRepository).emit.mockResolvedValue();
  result.ctx.getMock(JobRepository).queue.mockResolvedValue();
  return result;
};

// Require a PostgreSQL lock wait, not an arbitrary sleep or two sequential calls.
const compete = async <A, B>(
  first: (tx: Transaction<DB>) => Promise<A>,
  second: (tx: Transaction<DB>) => Promise<B>,
) => {
  const locked = Promise.withResolvers<void>();
  const release = Promise.withResolvers<void>();
  const waiter = Promise.withResolvers<number>();
  const a = database.transaction().execute(async (tx) => {
    const result = await first(tx);
    locked.resolve();
    await release.promise;
    return result;
  });
  void a.catch(locked.reject);
  await locked.promise;
  const b = database.transaction().execute(async (tx) => {
    const { rows } = await sql<{ pid: number }>`select pg_backend_pid() as pid`.execute(tx);
    waiter.resolve(rows[0].pid);
    return second(tx);
  });
  void b.catch(waiter.reject);
  try {
    const pid = await waiter.promise;
    const deadline = Date.now() + 2000;
    let blocked = false;
    while (Date.now() < deadline) {
      const { rows } = await sql<{ wait: string | null }>`
        select wait_event_type as wait from pg_stat_activity where pid = ${pid}`.execute(database);
      if (rows[0]?.wait === 'Lock') {
        blocked = true;
        break;
      }
      await setTimeout(5);
    }
    expect(blocked, 'the second connection must actually wait on the first transaction').toBe(true);
  } finally {
    release.resolve();
    await Promise.allSettled([a, b]);
  }
  return Promise.all([a, b]);
};

const oldTrash = async () => {
  const { ctx } = setup();
  const { user } = await ctx.newUser();
  const { asset } = await ctx.newAsset({
    ownerId: user.id,
    status: AssetStatus.Trashed,
    deletedAt: new Date('2026-01-01'),
    fileCreatedAt: new Date('2020-01-01'),
  });
  return asset;
};
const cutoff = new Date('2026-02-01');

describe('PostgreSQL deletion claims compete with Restore and a newer Trash', () => {
  it('Restore commits first; the blocked expiry claim rechecks deletedAt and skips', async () => {
    const asset = await oldTrash();
    const [restored, claimed] = await compete(
      (tx) => new TrashRepository(tx).restoreAll([asset.id]),
      (tx) => new AssetRepository(tx).claimExpiredDeletion(asset.id, cutoff),
    );
    expect(restored).toEqual([asset.id]);
    expect(claimed).toBe(false);
    const row = await database.selectFrom('asset').selectAll().where('id', '=', asset.id).executeTakeFirstOrThrow();
    expect(row.status).toBe(AssetStatus.Active);
  });

  it('expiry commits first; the blocked Restore cannot acknowledge the Deleted row', async () => {
    const asset = await oldTrash();
    const [claimed, restored] = await compete(
      (tx) => new AssetRepository(tx).claimExpiredDeletion(asset.id, cutoff),
      (tx) => new TrashRepository(tx).restoreAll([asset.id]),
    );
    expect(claimed).toBe(true);
    expect(restored).toEqual([]);
  });

  it('a new Trash wins the row lock; the old cutoff cannot claim its new retention period', async () => {
    const asset = await oldTrash();
    const [, claimed] = await compete(
      (tx) =>
        new AssetRepository(tx).markDeletionState([asset.id], {
          status: AssetStatus.Trashed,
          deletedAt: new Date('2026-10-09'),
        }),
      (tx) => new AssetRepository(tx).claimExpiredDeletion(asset.id, cutoff),
    );
    expect(claimed).toBe(false);
  });

  it('a new Trash cannot reopen a Deleted claim while the worker is removing it', async () => {
    const asset = await oldTrash();
    const [claimed, changed] = await compete(
      (tx) => new AssetRepository(tx).claimExpiredDeletion(asset.id, cutoff),
      (tx) =>
        new AssetRepository(tx).markDeletionState([asset.id], {
          status: AssetStatus.Trashed,
          deletedAt: new Date('2026-10-09'),
        }),
    );
    expect(claimed).toBe(true);
    expect(changed).toEqual([]);
    expect(await new TrashRepository(database).restoreAll([asset.id])).toEqual([]);
  });

  it('retention cannot turn external-library removal into physical original deletion', async () => {
    const { ctx } = setup();
    const { user } = await ctx.newUser();
    const { library } = await ctx.newLibrary({ ownerId: user.id });
    const { asset } = await ctx.newAsset({
      ownerId: user.id,
      libraryId: library.id,
      isExternal: true,
      deletedAt: new Date('2026-01-01'),
    });
    const assets = new AssetRepository(database);
    // Library removal sets deletedAt on Active assets, independently of Trash.
    expect(await assets.claimExpiredDeletion(asset.id, cutoff)).toBe(false);
    await assets.markDeletionState([asset.id], { status: AssetStatus.Trashed, deletedAt: new Date('2026-01-01') });
    await database.updateTable('library').set({ deletedAt: new Date() }).where('id', '=', library.id).execute();
    // It must also win over retention of an asset already in Trash.
    expect(await assets.claimExpiredDeletion(asset.id, cutoff)).toBe(false);
    expect(await assets.claimDeletion(asset.id, { reason: 'library', libraryId: library.id })).toBe(true);
    expect(await assets.claimDeletion(asset.id)).toBe(false);
  });

  it('preserves expired offline index cleanup but a file recovered before the claim is not eligible', async () => {
    const { ctx } = setup();
    const { user } = await ctx.newUser();
    const { library } = await ctx.newLibrary({ ownerId: user.id });
    const { asset } = await ctx.newAsset({
      ownerId: user.id,
      libraryId: library.id,
      isExternal: true,
      isOffline: true,
      deletedAt: new Date('2026-01-01'),
      status: AssetStatus.Active,
    });
    const assets = new AssetRepository(database);
    await assets.updateAll([asset.id], { isOffline: false });
    expect(await assets.claimExpiredDeletion(asset.id, cutoff)).toBe(false);
    await assets.updateAll([asset.id], { isOffline: true });
    expect(await assets.claimExpiredDeletion(asset.id, cutoff)).toBe(true);
  });

  it('two legacy deletion workers cannot remove an original without its durable authorization', async () => {
    const { sut, ctx } = setup();
    const { user } = await ctx.newUser();
    const { asset } = await ctx.newAsset({ ownerId: user.id, status: AssetStatus.Deleted, deletedAt: cutoff });
    const repo = ctx.get(AssetJobRepository);
    const getSnapshot = repo.getForAssetDeletion.bind(repo);
    const bothFetched = Promise.withResolvers<void>();
    let fetched = 0;
    const snapshot = vi.spyOn(repo, 'getForAssetDeletion').mockImplementation(async (id) => {
      const result = await getSnapshot(id);
      if (++fetched === 2) {
        bothFetched.resolve();
      }
      await bothFetched.promise;
      return result;
    });
    try {
      const results = await Promise.all([
        sut.handleAssetDeletion({ id: asset.id, deleteOnDisk: true }),
        sut.handleAssetDeletion({ id: asset.id, deleteOnDisk: true }),
      ]);
      expect(results).toEqual([JobStatus.Skipped, JobStatus.Skipped]);
      expect(ctx.getMock(EventRepository).emit).not.toHaveBeenCalled();
      expect(ctx.getMock(JobRepository).queue).not.toHaveBeenCalled();
    } finally {
      bothFetched.resolve();
      snapshot.mockRestore();
    }
  });
});

describe('bulk Restore preserves album membership and chronological timeline placement', () => {
  it('acknowledges only restorable photos/videos/Live stills; repeated Restore has no duplicate or ghost', async () => {
    const { sut, ctx } = setup();
    const { user } = await ctx.newUser();
    const { asset: motion } = await ctx.newAsset({
      ownerId: user.id,
      type: AssetType.Video,
      visibility: AssetVisibility.Hidden,
    });
    const ids: string[] = [];
    for (const [day, type, livePhotoVideoId] of [
      [2, AssetType.Image, null],
      [5, AssetType.Video, null],
      [8, AssetType.Image, motion.id],
    ] as const) {
      const date = new Date(`2020-01-0${day}T06:30:00Z`);
      const { asset } = await ctx.newAsset({
        ownerId: user.id,
        type,
        livePhotoVideoId,
        fileCreatedAt: date,
        localDateTime: date,
      });
      await ctx.newExif({ assetId: asset.id, timeZone: 'UTC' });
      ids.push(asset.id);
    }
    const { asset: anchor } = await ctx.newAsset({
      ownerId: user.id,
      fileCreatedAt: new Date('2020-01-10T22:00:00Z'),
      localDateTime: new Date('2020-01-11T01:00:00Z'),
    });
    await ctx.newExif({ assetId: anchor.id, timeZone: 'UTC+03:00' });
    const { asset: claimed } = await ctx.newAsset({ ownerId: user.id, status: AssetStatus.Deleted, deletedAt: cutoff });
    const { album } = await ctx.newAlbum({ ownerId: user.id }, [...ids, anchor.id, claimed.id]);
    const auth = factory.auth({ user });
    const timeline = ctx.getService(TimelineService);
    const bucket = async (): Promise<string[]> =>
      JSON.parse(await timeline.getTimeBucket(auth, { timeBucket: '2020-01-01', albumId: album.id })).id;
    const expected = [anchor.id, ...ids.toReversed()];
    expect(await bucket()).toEqual(expected);
    await sut.deleteAll(auth, { ids, force: false });
    expect(await bucket()).toEqual([anchor.id]);
    const trash = ctx.getService(TrashService);
    expect(await trash.restoreAssets(auth, { ids: [...ids, claimed.id] })).toEqual({ count: 3 });
    expect(await bucket()).toEqual(expected);
    expect(await trash.restoreAssets(auth, { ids })).toEqual({ count: 0 });
    expect(await bucket()).toEqual(expected);
    expect(ctx.getMock(EventRepository).emit.mock.calls.filter(([name]) => name === 'AssetRestoreAll')).toEqual([
      ['AssetRestoreAll', { assetIds: expect.arrayContaining(ids), userId: user.id }],
    ]);
    // Re-trash the restored batch: an old unclassified job still cannot delete it.
    await sut.deleteAll(auth, { ids, force: false });
    for (const id of ids) {
      expect(await sut.handleAssetDeletion({ id, deleteOnDisk: true })).toBe(JobStatus.Skipped);
    }
    expect(await trash.restoreAssets(auth, { ids })).toEqual({ count: 3 });
    expect(await bucket()).toEqual(expected);
    const still = await new AssetRepository(database).getById(ids[2]);
    expect(still?.livePhotoVideoId).toBe(motion.id);
  });
});

describe('isolated original files, real repositories and real file deletion worker', () => {
  it('explicit external-library cleanup removes the index and thumbnail but preserves original bytes', async () => {
    const root = await mkdtemp(join(tmpdir(), 'gallery-library-fixture-'));
    try {
      const { sut, ctx } = setup();
      const { user } = await ctx.newUser();
      const { library } = await ctx.newLibrary({ ownerId: user.id });
      const original = join(root, 'original.jpg');
      const thumbnail = join(root, 'thumbs', 'thumbnail.jpg');
      await mkdir(join(root, 'thumbs'));
      const previousMedia = '/data';
      StorageCore.setMediaLocation(root);
      await writeFile(original, 'synthetic external original');
      await writeFile(thumbnail, 'synthetic generated thumbnail');
      const { asset } = await ctx.newAsset({
        ownerId: user.id,
        libraryId: library.id,
        isExternal: true,
        originalPath: original,
      });
      await ctx.newAssetFile({ assetId: asset.id, type: AssetFileType.Thumbnail, path: thumbnail });
      await database.updateTable('library').set({ deletedAt: new Date() }).where('id', '=', library.id).execute();
      expect(
        await sut.handleAssetDeletion({
          id: asset.id,
          deleteOnDisk: false,
          deletionReason: 'library',
          libraryId: library.id,
        }),
      ).toBe(JobStatus.Success);
      const [job] = ctx.getMock(JobRepository).queue.mock.calls.at(-1)!;
      expect(job).toEqual({ name: JobName.FileDelete, data: { files: [thumbnail] } });
      if (job.name === JobName.FileDelete) {
        const worker = newMediumService(StorageService, {
          database,
          real: [StorageRepository, AssetRepository],
          mock: [LoggingRepository],
        });
        expect(await worker.sut.handleDeleteFiles(job.data)).toBe(JobStatus.Success);
      }
      expect(await new AssetRepository(database).getById(asset.id)).toBeUndefined();
      expect(await readFile(original, 'utf8')).toBe('synthetic external original');
      await expect(readFile(thumbnail)).rejects.toMatchObject({ code: 'ENOENT' });
      StorageCore.setMediaLocation(previousMedia);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  for (const kind of ['photo', 'video', 'Apple Live', 'Samsung Motion', 'external photo', 'offline external video']) {
    it(`${kind}: Trash/Restore and legacy retries preserve originals; permanent deletion has explicit scope`, async () => {
      const root = await mkdtemp(join(tmpdir(), 'gallery-trash-fixture-'));
      try {
        const { sut, ctx } = setup();
        const { user } = await ctx.newUser();
        const { library } = await ctx.newLibrary({ ownerId: user.id });
        const original = join(root, kind.includes('video') ? 'original.mp4' : 'original.jpg');
        const untouched = join(root, 'outside-operation.jpg');
        const bytes = Buffer.from(`non-sensitive synthetic ${kind} original`);
        await writeFile(original, bytes);
        await writeFile(untouched, 'must survive every mode');
        let motionId: string | null = null;
        if (kind.includes('Live') || kind.includes('Motion')) {
          const motionPath = join(root, 'paired.mov');
          await writeFile(motionPath, 'synthetic paired resource');
          const { asset: motion } = await ctx.newAsset({
            ownerId: user.id,
            originalPath: motionPath,
            type: AssetType.Video,
            visibility: AssetVisibility.Hidden,
          });
          motionId = motion.id;
        }
        const captured = new Date('2020-04-15T06:30:00Z');
        const { asset } = await ctx.newAsset({
          ownerId: user.id,
          originalPath: original,
          type: kind.includes('video') ? AssetType.Video : AssetType.Image,
          fileCreatedAt: captured,
          localDateTime: captured,
          livePhotoVideoId: motionId,
          libraryId: kind.includes('external') ? library.id : null,
          isExternal: kind.includes('external'),
          isOffline: kind.includes('offline'),
        });
        await ctx.newExif({ assetId: asset.id, timeZone: 'UTC+03:00', fileSizeInByte: bytes.length });
        const { album } = await ctx.newAlbum({ ownerId: user.id, albumName: 'Fixture album' }, [asset.id]);
        const auth = factory.auth({ user });
        const timeline = ctx.getService(TimelineService);
        const bucket = async (): Promise<string[]> =>
          JSON.parse(await timeline.getTimeBucket(auth, { timeBucket: '2020-04-01', albumId: album.id })).id;

        await sut.deleteAll(auth, { ids: [asset.id], force: false });
        expect(await bucket()).not.toContain(asset.id);
        expect(await sut.handleAssetDeletion({ id: asset.id, deleteOnDisk: true })).toBe(JobStatus.Skipped);
        expect(await ctx.getService(TrashService).restoreAssets(auth, { ids: [asset.id] })).toEqual({ count: 1 });
        const restored = await database
          .selectFrom('asset')
          .selectAll()
          .where('id', '=', asset.id)
          .executeTakeFirstOrThrow();
        expect(restored.fileCreatedAt).toEqual(captured);
        expect(restored.localDateTime).toEqual(captured);
        expect(restored.livePhotoVideoId).toBe(motionId);
        expect(await bucket()).toEqual([asset.id]);
        expect(await readFile(original)).toEqual(bytes);
        expect(await sut.handleAssetDeletion({ id: asset.id, deleteOnDisk: true })).toBe(JobStatus.Skipped);

        // Trash first, explicit owner/library policy, then the existing Immich worker.
        await sut.deleteAll(auth, { ids: [asset.id], force: false });
        await new AssetRepository(database).setDeletionPolicy(user.id, asset.libraryId ?? 'managed', {
          enabled: true,
          roots: [root],
          recoveryProof: 'a'.repeat(64),
          authorizedBy: user.id,
        });
        ctx.getMock(StorageRepository).snapshotOriginal.mockImplementation(snapshotOriginal);
        ctx.getMock(StorageRepository).unlinkOriginal.mockImplementation(unlinkOriginal);
        expect(await sut.permanentlyDelete(auth, [asset.id])).toEqual([
          { id: asset.id, state: 'complete', scope: asset.libraryId ?? 'managed' },
        ]);
        expect(await sut.handleAssetDeletion({ id: asset.id, deleteOnDisk: true })).toBe(JobStatus.Skipped);
        await expect(readFile(original)).rejects.toMatchObject({ code: 'ENOENT' });
        if (motionId) {
          await expect(readFile(join(root, 'paired.mov'))).rejects.toMatchObject({ code: 'ENOENT' });
          expect(await new AssetRepository(database).getById(motionId)).toBeUndefined();
        }
        expect(await readFile(untouched, 'utf8')).toBe('must survive every mode');
      } finally {
        await rm(root, { recursive: true, force: true });
      }
    });
  }

  it('legacy jobs cannot claim Active/Trashed rows; a fresh explicit library cleanup requires a soft-deleted library', async () => {
    const { ctx } = setup();
    const { user } = await ctx.newUser();
    const { library } = await ctx.newLibrary({ ownerId: user.id });
    const { asset } = await ctx.newAsset({ ownerId: user.id, libraryId: library.id, isExternal: true });
    const assets = new AssetRepository(database);
    expect(await assets.claimDeletion(asset.id)).toBe(false);
    expect(await assets.claimDeletion(asset.id, { reason: 'library', libraryId: library.id })).toBe(false);
    await database.updateTable('library').set({ deletedAt: new Date() }).where('id', '=', library.id).execute();
    expect(await assets.claimDeletion(asset.id, { reason: 'library', libraryId: library.id })).toBe(true);
    expect(await new TrashRepository(database).restoreAll([asset.id])).toEqual([]);
  });

  it('motion cleanup rechecks current references and cannot claim a still or a linked video', async () => {
    const { ctx } = setup();
    const { user } = await ctx.newUser();
    const { asset: video } = await ctx.newAsset({
      ownerId: user.id,
      type: AssetType.Video,
      visibility: AssetVisibility.Hidden,
    });
    const { asset: still } = await ctx.newAsset({ ownerId: user.id, livePhotoVideoId: video.id });
    const assets = new AssetRepository(database);
    expect(await assets.claimDeletion(video.id, { reason: 'motion' })).toBe(false);
    expect(await assets.claimDeletion(still.id, { reason: 'motion' })).toBe(false);
    await assets.update({ id: still.id, livePhotoVideoId: null });
    expect(await assets.claimDeletion(video.id, { reason: 'motion' })).toBe(true);
  });
});
