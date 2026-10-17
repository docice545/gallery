import { Kysely } from 'kysely';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { performance } from 'node:perf_hooks';
import { StorageCore } from 'src/cores/storage.core.js';
import { AssetStatus, AssetType, AssetVisibility, ChecksumAlgorithm, JobStatus, StorageFolder } from 'src/enum.js';
import { AccessRepository } from 'src/repositories/access.repository.js';
import { AssetJobRepository } from 'src/repositories/asset-job.repository.js';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { StorageRepository } from 'src/repositories/storage.repository.js';
import { UserRepository } from 'src/repositories/user.repository.js';
import { DB } from 'src/schema/index.js';
import { AssetService } from 'src/services/asset.service.js';
import { newMediumService } from 'test/medium.factory.js';
import { factory } from 'test/small.factory.js';
import { getKyselyDB, newTestService } from 'test/utils.js';

const generate = (args: string[]) =>
  execFileSync('ffmpeg', ['-nostdin', '-v', 'error', '-filter_threads', '1', ...args], { timeout: 30_000 });

// Explicitly opt in: real disposable PostgreSQL + local filesystem, no Redis or HTTP.
// Factory-created identities bypass ingestion; decoding/transcoding and queued derivatives
// are outside these service/worker measurements. ffmpeg only generates tiny local inputs.
describe.skipIf(process.env.GALLERY_LOCAL_DELETE_MATRIX !== '1')('local mixed-media deletion matrix', () => {
  let db: Kysely<DB>;
  let base: string;
  beforeAll(async () => {
    db = await getKyselyDB();
  });
  afterAll(async () => {
    await db?.destroy();
  });
  beforeEach(async () => {
    base = await mkdtemp(join(tmpdir(), 'gallery-local-delete-matrix-'));
  });
  afterEach(async () => {
    vi.restoreAllMocks();
    await rm(base, { recursive: true, force: true });
  });

  const setup = async (count: number) => {
    const { ctx } = newMediumService(AssetService, {
      database: db,
      real: [AssetRepository],
      mock: [LoggingRepository],
    });
    const { user } = await ctx.newUser();
    const root = join(base, user.id);
    await mkdir(root);
    const encodedRoot = join(base, StorageFolder.EncodedVideo, user.id);
    await mkdir(encodedRoot, { recursive: true });
    const imagePath = join(base, 'source.png');
    const videoPath = join(base, 'source.mp4');
    generate(['-f', 'lavfi', '-i', 'color=c=blue:s=32x32', '-frames:v', '1', '-threads', '1', imagePath]);
    generate([
      '-f',
      'lavfi',
      '-i',
      'color=c=red:s=32x32:r=5',
      '-t',
      '0.4',
      '-c:v',
      'libx264',
      '-threads',
      '1',
      '-pix_fmt',
      'yuv420p',
      videoPath,
    ]);
    const image = await readFile(imagePath);
    const video = await readFile(videoPath);
    const actualFolder = StorageCore.getFolderLocation;
    const actualLibrary = StorageCore.getLibraryFolder;
    vi.spyOn(StorageCore, 'getFolderLocation').mockImplementation((folder, owner) =>
      owner === user.id && folder === StorageFolder.Upload
        ? root
        : owner === user.id && folder === StorageFolder.EncodedVideo
          ? encodedRoot
          : actualFolder(folder, owner),
    );
    vi.spyOn(StorageCore, 'getLibraryFolder').mockImplementation((owner) =>
      owner.id === user.id ? root : actualLibrary(owner),
    );
    const createService = () => {
      const repo = new AssetRepository(db);
      const test = newTestService(AssetService, {
        asset: repo,
        access: new AccessRepository(db),
        assetJob: new AssetJobRepository(db),
        storage: new StorageRepository(ctx.getMock(LoggingRepository)),
      });
      const users = new UserRepository(db);
      test.mocks.user.get.mockImplementation((id, options) => users.get(id, options));
      test.mocks.sharedSpace.getSpacePersonsForAsset.mockResolvedValue([]);
      test.mocks.event.emit.mockResolvedValue();
      test.mocks.user.updateUsage.mockResolvedValue();
      test.mocks.job.queue.mockResolvedValue();
      test.mocks.job.isAssetDeleteBatchCancelled.mockResolvedValue(false);
      return { ...test, repo };
    };
    const service = createService();
    const auth = factory.auth({ user });
    await service.sut.setManagedDeletionConsent(auth, true);
    const originals: Array<{ id: string; originalPath: string; data: Buffer; selectedIndex: number }> = [];
    const selected: string[] = [];
    const composition = { photos: 0, videos: 0, livePhotos: 0 };
    const add = async (index: number, isVideo: boolean, component = false, livePhotoVideoId: string | null = null) => {
      const originalPath = join(
        component ? encodedRoot : root,
        `${index}${component ? '-motion' : ''}.${isVideo ? 'mp4' : 'png'}`,
      );
      const data = isVideo ? video : image;
      await writeFile(originalPath, data);
      const { asset } = await ctx.newAsset({
        ownerId: user.id,
        originalPath,
        originalFileName: originalPath.split('/').at(-1),
        type: isVideo ? AssetType.Video : AssetType.Image,
        visibility: component ? AssetVisibility.Hidden : AssetVisibility.Timeline,
        livePhotoVideoId,
        checksum: createHash('sha1').update(`${index}:${component}`).update(data).digest(),
        checksumAlgorithm: ChecksumAlgorithm.sha1File,
        status: AssetStatus.Trashed,
        deletedAt: new Date('2026-01-01T00:00:00Z'),
      });
      originals.push({ id: asset.id, originalPath, data, selectedIndex: index });
      return asset.id;
    };
    for (let index = 0; index < count; index++) {
      if (index % 3 === 2) {
        const motionId = await add(index, true, true);
        selected.push(await add(index, false, false, motionId));
        composition.livePhotos++;
      } else {
        selected.push(await add(index, index % 3 === 1));
        composition[index % 3 === 1 ? 'videos' : 'photos']++;
      }
    }
    return { ...service, createService, user, auth, originals, selected, composition };
  };

  const verifyComplete = async (f: Awaited<ReturnType<typeof setup>>) => {
    const receipts = await db
      .selectFrom('asset_deletion_tombstone')
      .selectAll()
      .where('ownerId', '=', f.user.id)
      .execute();
    expect(receipts).toHaveLength(f.originals.length);
    expect([
      ...new Set(
        receipts
          .filter((receipt) => receipt.state !== 'complete')
          .map((receipt) => `${receipt.state}:${receipt.errorCode}`),
      ),
    ]).toEqual([]);
    expect(await db.selectFrom('asset').select('id').where('ownerId', '=', f.user.id).execute()).toEqual([]);
    for (const original of f.originals) {
      await expect(readFile(original.originalPath)).rejects.toHaveProperty('code', 'ENOENT');
    }
    return receipts;
  };

  it.each([1, 10, 100, 1000])(
    'measures the entire service/worker deletion for %i selected assets',
    async (count) => {
      const f = await setup(count);
      const rssStart = process.memoryUsage().rss;
      let rssPeak = rssStart;
      const sample = setInterval(() => {
        rssPeak = Math.max(rssPeak, process.memoryUsage().rss);
      }, 20);
      const start = performance.now();
      let admissionMs: number;
      let elapsedMs: number;
      try {
        const result = await f.sut.permanentlyDelete(f.auth, f.selected);
        admissionMs = performance.now() - start;
        expect(result).toHaveLength(count);
        expect([
          ...new Set(
            result
              .filter((item) => item.state !== (count > 200 ? 'pending' : 'complete'))
              .map((item) => `${item.state}:${item.code}`),
          ),
        ]).toEqual([]);
        if (count > 200) {
          await expect(f.sut.handleAssetDeletionBatch({ ownerId: f.user.id, ids: f.selected })).resolves.toBe(
            JobStatus.Success,
          );
        }
        elapsedMs = performance.now() - start;
      } finally {
        clearInterval(sample);
      }
      const rssEnd = process.memoryUsage().rss;
      rssPeak = Math.max(rssPeak, rssEnd);
      await verifyComplete(f);
      process.stdout.write(
        `LOCAL_DELETE_MATRIX ${JSON.stringify({
          count,
          originals: f.originals.length,
          ...f.composition,
          path: count > 200 ? 'admission+direct-worker' : 'inline-service',
          admissionMs: Math.round(admissionMs),
          elapsedMs: Math.round(elapsedMs),
          selectedPerSecond: Number(((count * 1000) / elapsedMs).toFixed(3)),
          rssStart,
          rssPeak,
          rssEnd,
          result: 'PASS',
        })}\n`,
      );
    },
    900_000,
  );

  it('resumes a 401-item mixed batch with fresh service/repository instances after the first 200-item chunk', async () => {
    const f = await setup(401);
    const job = { ownerId: f.user.id, ids: f.selected };
    const originalDelete = f.sut.permanentlyDelete.bind(f.sut);
    let calls = 0;
    const interruption = vi.spyOn(f.sut, 'permanentlyDelete').mockImplementation(async (...args) => {
      if (++calls === 2) throw new Error('SYNTHETIC_CHUNK_INTERRUPTION');
      return originalDelete(...args);
    });
    await expect(f.sut.handleAssetDeletionBatch(job)).rejects.toThrow('SYNTHETIC_CHUNK_INTERRUPTION');
    const completed = f.originals.filter((item) => item.selectedIndex < 200);
    const remaining = f.originals.filter((item) => item.selectedIndex >= 200);
    const before = await db
      .selectFrom('asset_deletion_tombstone')
      .selectAll()
      .where('ownerId', '=', f.user.id)
      .execute();
    expect(before).toHaveLength(completed.length);
    expect([
      ...new Set(
        before
          .filter((receipt) => receipt.state !== 'complete')
          .map((receipt) => `${receipt.state}:${receipt.errorCode}`),
      ),
    ]).toEqual([]);
    for (const item of completed) await expect(readFile(item.originalPath)).rejects.toHaveProperty('code', 'ENOENT');
    for (const item of remaining) expect(await readFile(item.originalPath)).toEqual(item.data);
    interruption.mockRestore();
    const fresh = f.createService();
    const restart = performance.now();
    await expect(fresh.sut.handleAssetDeletionBatch(job)).resolves.toBe(JobStatus.Success);
    const resumedMs = Math.round(performance.now() - restart);
    const after = await verifyComplete(f);
    for (const receipt of before) expect(after.find((item) => item.assetId === receipt.assetId)).toEqual(receipt);
    process.stdout.write(
      `LOCAL_DELETE_RECOVERY ${JSON.stringify({
        count: f.selected.length,
        originals: f.originals.length,
        completedBeforeInterruption: completed.length,
        preservedBeforeResume: remaining.length,
        resumedMs,
        unchangedCompletedReceipts: before.length,
        result: 'PASS',
      })}\n`,
    );
  }, 900_000);
});
