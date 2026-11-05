import { exiftool } from 'exiftool-vendored';
import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import sharp from 'sharp';
import type { Kysely } from 'kysely';
import type { DB } from 'src/schema/index.js';
import { AssetJobRepository } from 'src/repositories/asset-job.repository.js';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { ConfigRepository } from 'src/repositories/config.repository.js';
import { EventRepository } from 'src/repositories/event.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { MagicEraserRepository } from 'src/repositories/magic-eraser.repository.js';
import { MapRepository } from 'src/repositories/map.repository.js';
import { MetadataRepository } from 'src/repositories/metadata.repository.js';
import { StorageRepository } from 'src/repositories/storage.repository.js';
import { SystemMetadataRepository } from 'src/repositories/system-metadata.repository.js';
import { TagRepository } from 'src/repositories/tag.repository.js';
import { MetadataService } from 'src/services/metadata.service.js';
import { clearConfigCache } from 'src/utils/config.js';
import { newMediumService } from 'test/medium.factory.js';
import { getKyselyDB } from 'test/utils.js';

let db: Kysely<DB>;
let directory: string;

beforeAll(async () => {
  db = await getKyselyDB();
});

beforeEach(async () => {
  clearConfigCache();
  directory = await mkdtemp(join(tmpdir(), 'foto-eraser-copy-date-'));
});

afterEach(async () => {
  clearConfigCache();
  vi.restoreAllMocks();
  await rm(directory, { recursive: true, force: true });
});

afterAll(async () => {
  await exiftool.end();
  await db.destroy();
});

it.each([0, 180, 330, -600])(
  'keeps the new save instant and local day after repeated metadata extraction, offset %i',
  async (offset) => {
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
      mock: [EventRepository, StorageRepository, LoggingRepository, MapRepository],
    });
    ctx.getMock(StorageRepository).stat.mockImplementation((path) => stat(path));
    ctx.getMock(EventRepository).emit.mockResolvedValue();
    ctx.getMock(MapRepository).reverseGeocode.mockResolvedValue({ country: 'Russia', state: 'Moscow', city: 'Moscow' });
    const { user } = await ctx.newUser();
    const originalPath = join(directory, 'original.jpg');
    const resultPath = join(directory, 'result.jpg');
    const originalBytes = await sharp({ create: { width: 30, height: 20, channels: 3, background: '#123456' } })
      .jpeg()
      .toBuffer();
    await writeFile(originalPath, originalBytes);
    const originalDate = new Date('2020-02-03T10:20:30Z');
    const { asset: original } = await ctx.newAsset({
      originalPath,
      ownerId: user.id,
      fileCreatedAt: originalDate,
      fileModifiedAt: originalDate,
      localDateTime: new Date('2020-02-03T13:20:30Z'),
    });
    const sourceExif = {
      dateTimeOriginal: originalDate,
      timeZone: 'UTC+3',
      make: 'Samsung',
      latitude: 55.7558,
      longitude: 37.6173,
    };
    await ctx.newExif({ assetId: original.id, ...sourceExif });

    // Magic Eraser produces an untagged upright still before copy metadata is
    // written. Only synthetic temporary bytes and a disposable DB are used.
    const eraser = new MagicEraserRepository();
    await eraser.normalize(originalPath, resultPath);
    const savedAt = new Date('2026-11-02T22:05:12.345Z');
    await eraser.writeCopyMetadata(resultPath, sourceExif, savedAt, offset);
    const { asset: copy } = await ctx.newAsset({
      originalPath: resultPath,
      originalFileName: 'original-magic-eraser.jpg',
      ownerId: user.id,
      fileCreatedAt: savedAt,
      fileModifiedAt: savedAt,
    });
    await ctx.newExif({ assetId: copy.id, description: '' });

    for (let run = 0; run < 2; run++) {
      await sut.handleMetadataExtraction({ id: copy.id });
      const actual = await db
        .selectFrom('asset')
        .innerJoin('asset_exif', 'asset_exif.assetId', 'asset.id')
        .select(['fileCreatedAt', 'localDateTime', 'dateTimeOriginal', 'timeZone', 'latitude', 'longitude'])
        .where('asset.id', '=', copy.id)
        .executeTakeFirstOrThrow();
      expect(actual.fileCreatedAt).toEqual(savedAt);
      expect(actual.dateTimeOriginal).toEqual(savedAt);
      expect(actual.localDateTime).toEqual(new Date(savedAt.getTime() + offset * 60_000));
      expect(actual.timeZone).not.toBeNull();
      expect(actual.latitude).toBeCloseTo(sourceExif.latitude, 5);
      expect(actual.longitude).toBeCloseTo(sourceExif.longitude, 5);
    }
    const unchanged = await db
      .selectFrom('asset')
      .innerJoin('asset_exif', 'asset_exif.assetId', 'asset.id')
      .select(['fileCreatedAt', 'dateTimeOriginal', 'timeZone'])
      .where('asset.id', '=', original.id)
      .executeTakeFirstOrThrow();
    expect(unchanged).toEqual({ fileCreatedAt: originalDate, dateTimeOriginal: originalDate, timeZone: 'UTC+3' });
    expect(await readFile(originalPath)).toEqual(originalBytes);
  },
);
