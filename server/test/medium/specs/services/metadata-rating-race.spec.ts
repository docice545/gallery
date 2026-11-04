import { Kysely } from 'kysely';
import { Stats } from 'node:fs';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { AssetFileType, JobStatus } from 'src/enum.js';
import { AssetJobRepository } from 'src/repositories/asset-job.repository.js';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { ConfigRepository } from 'src/repositories/config.repository.js';
import { EventRepository } from 'src/repositories/event.repository.js';
import { JobRepository } from 'src/repositories/job.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { MetadataRepository } from 'src/repositories/metadata.repository.js';
import { StorageRepository } from 'src/repositories/storage.repository.js';
import { SystemMetadataRepository } from 'src/repositories/system-metadata.repository.js';
import { TagRepository } from 'src/repositories/tag.repository.js';
import { DB } from 'src/schema/index.js';
import { MetadataService } from 'src/services/metadata.service.js';
import { clearConfigCache } from 'src/utils/config.js';
import { updateLockedColumns } from 'src/utils/database.js';
import { newMediumService } from 'test/medium.factory.js';
import { getKyselyDB, newRandomImage } from 'test/utils.js';

let db: Kysely<DB>;
let directory: string;

beforeAll(async () => {
  db = await getKyselyDB();
  directory = await mkdtemp(join(tmpdir(), 'foto-rating-race-'));
});

afterAll(async () => {
  await db?.destroy();
  if (directory) await rm(directory, { recursive: true, force: true });
});

afterEach(() => {
  vi.restoreAllMocks();
  clearConfigCache();
});

const setup = async () => {
  const { sut, ctx } = newMediumService(MetadataService, {
    database: db,
    real: [
      AssetRepository,
      AssetJobRepository,
      ConfigRepository,
      MetadataRepository,
      SystemMetadataRepository,
      TagRepository,
    ],
    mock: [EventRepository, JobRepository, StorageRepository, LoggingRepository],
  });
  ctx.getMock(EventRepository).emit.mockResolvedValue();
  ctx.getMock(StorageRepository).stat.mockResolvedValue({
    size: 100,
    mtime: new Date(),
    mtimeMs: Date.now(),
    birthtimeMs: Date.now(),
  } as Stats);
  const { user } = await ctx.newUser();
  const path = join(directory, `${user.id}.png`);
  await writeFile(path, newRandomImage());
  const { asset } = await ctx.newAsset({ ownerId: user.id, originalPath: path });
  await ctx.newExif({ assetId: asset.id, rating: null });
  const assets = ctx.get(AssetRepository);
  const metadata = ctx.get(MetadataRepository);
  const readRating = () =>
    db
      .selectFrom('asset_exif')
      .select(['rating', 'lockedProperties'])
      .where('assetId', '=', asset.id)
      .executeTakeFirstOrThrow();
  const rate = (rating: number) =>
    assets.upsertExif({
      exif: updateLockedColumns({ assetId: asset.id, rating }),
      lockedPropertiesBehavior: 'append',
    });
  return { sut, ctx, asset, metadata, readRating, rate };
};

it('does not overwrite rating 3 when an older extraction finishes after the sidecar unlock', async () => {
  const { sut, asset, metadata, readRating, rate } = await setup();
  const reading = Promise.withResolvers<void>();
  const resume = Promise.withResolvers<void>();
  const read = metadata.readTags.bind(metadata);
  vi.spyOn(metadata, 'readTags').mockImplementationOnce(async (path) => {
    const oldTags = await read(path);
    reading.resolve();
    await resume.promise;
    return oldTags;
  });
  const extraction = sut.handleMetadataExtraction({ id: asset.id });
  await reading.promise;
  try {
    await rate(3);
    expect(await sut.handleSidecarWrite({ id: asset.id })).toBe(JobStatus.Success);
    expect(await readRating()).toEqual({ rating: 3, lockedProperties: null });
  } finally {
    resume.resolve();
  }
  await extraction;
  expect(await readRating()).toEqual({ rating: 3, lockedProperties: null });
  expect((await read(`${asset.originalPath}.xmp`)).Rating).toBe(3);
  await sut.handleMetadataExtraction({ id: asset.id });
  expect((await readRating()).rating).toBe(3);
});

it('retains the rating lock and does not register a successful sidecar after file writing fails', async () => {
  const { sut, ctx, asset, metadata, readRating, rate } = await setup();
  await rate(3);
  const exiftool = (metadata as unknown as { exiftool: { write: (...args: unknown[]) => Promise<void> } }).exiftool;
  vi.spyOn(exiftool, 'write').mockRejectedValueOnce(new Error('controlled XMP write failure'));
  await expect(sut.handleSidecarWrite({ id: asset.id })).rejects.toThrow('controlled XMP write failure');
  expect(await readRating()).toEqual({ rating: 3, lockedProperties: ['rating'] });
  expect(
    (await ctx.get(AssetJobRepository).getForSidecarWriteJob(asset.id))?.files.filter(
      (file) => file.type === AssetFileType.Sidecar,
    ),
  ).toEqual([]);
  expect(await sut.handleSidecarWrite({ id: asset.id })).toBe(JobStatus.Success);
  expect(await readRating()).toEqual({ rating: 3, lockedProperties: null });
});
