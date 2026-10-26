import { Kysely, sql } from 'kysely';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, rename, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DiskStorageBackend } from 'src/backends/disk-storage.backend.js';
import { StorageCore } from 'src/cores/storage.core.js';
import { AssetMediaStatus, AssetRejectReason, AssetUploadAction } from 'src/dtos/asset-media-response.dto.js';
import { mapAsset } from 'src/dtos/asset-response.dto.js';
import { AssetStatus, ChecksumAlgorithm, JobName, JobStatus, StorageFolder, SyncRequestType } from 'src/enum.js';
import { AccessRepository } from 'src/repositories/access.repository.js';
import { AssetJobRepository } from 'src/repositories/asset-job.repository.js';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { CryptoRepository } from 'src/repositories/crypto.repository.js';
import { EventRepository } from 'src/repositories/event.repository.js';
import { JobRepository } from 'src/repositories/job.repository.js';
import { LibraryRepository } from 'src/repositories/library.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { SharedSpaceRepository } from 'src/repositories/shared-space.repository.js';
import { StorageRepository } from 'src/repositories/storage.repository.js';
import { DB } from 'src/schema/index.js';
import { AssetMediaService } from 'src/services/asset-media.service.js';
import { LibraryService } from 'src/services/library.service.js';
import { StorageService } from 'src/services/storage.service.js';
import { verifyExternalOriginal } from 'src/utils/external-original.js';
import { SyncTestContext, mediumFactory, newMediumService } from 'test/medium.factory.js';
import { factory, newUuid } from 'test/small.factory.js';
import { getKyselyDB } from 'test/utils.js';

let db: Kysely<DB>;
let root: string;
beforeAll(async () => {
  db = await getKyselyDB();
});
afterAll(async () => {
  await db.destroy();
});
beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), 'foto-duplicate-'));
  vi.spyOn(StorageCore, 'getMediaLocation').mockReturnValue(root);
  (StorageService as any).diskBackend = new DiskStorageBackend(root);
});
afterEach(async () => {
  vi.restoreAllMocks();
  await rm(root, { recursive: true, force: true });
});

const fixture = async () => {
  const { sut, ctx } = newMediumService(AssetMediaService, {
    database: db,
    real: [
      AccessRepository,
      AssetJobRepository,
      AssetRepository,
      CryptoRepository,
      LibraryRepository,
      SharedSpaceRepository,
      StorageRepository,
    ],
    mock: [EventRepository, JobRepository, LoggingRepository],
  });
  ctx.getMock(EventRepository).emit.mockResolvedValue();
  ctx.getMock(JobRepository).queue.mockResolvedValue();
  ctx.getMock(JobRepository).queueAll.mockResolvedValue();
  const { user } = await ctx.newUser();
  const { library } = await ctx.newLibrary({ ownerId: user.id });
  const originalPath = join(root, 'external.jpg');
  const bytes = Buffer.from('synthetic same-content photo, not family media');
  await writeFile(originalPath, bytes);
  const checksum = createHash('sha1').update(bytes).digest();
  const { asset } = await ctx.newAsset({
    ownerId: user.id,
    libraryId: library.id,
    isExternal: true,
    originalPath,
    checksum: createHash('sha1').update(originalPath).digest(),
    checksumAlgorithm: ChecksumAlgorithm.sha1Path,
    isFavorite: true,
  });
  await db.insertInto('asset_duplicate_checksum').values({ ownerId: user.id, assetId: asset.id, checksum }).execute();
  const auth = factory.auth({ user: { id: user.id } });
  return { sut, ctx, user, asset, bytes, checksum, auth };
};

it('acknowledges the verified available External original by its real UUID without a Managed copy', async () => {
  const { sut, ctx, asset, bytes, checksum, auth, user } = await fixture();
  await expect(sut.getUploadAssetIdByChecksum(auth, checksum.toString('hex'))).resolves.toMatchObject({
    id: asset.id,
    status: AssetMediaStatus.DUPLICATE,
  });
  await expect(
    sut.bulkUploadCheck(auth, { assets: [{ id: 'phone', checksum: checksum.toString('hex') }] }),
  ).resolves.toEqual({
    results: [
      {
        id: 'phone',
        action: AssetUploadAction.REJECT,
        reason: AssetRejectReason.DUPLICATE,
        assetId: asset.id,
        isTrashed: false,
      },
    ],
  });
  expect(await readFile(asset.originalPath)).toEqual(bytes);
  const external = await ctx.get(AssetRepository).getById(asset.id);
  expect(external?.isFavorite).toBe(true);
  expect(await db.selectFrom('asset').select('id').where('ownerId', '=', user.id).execute()).toHaveLength(1);
});

it('retains the newly discovered content identity after an old version lookup, including its Trash barrier', async () => {
  const { sut, ctx, asset, auth, checksum, user } = await fixture();
  const replacement = Buffer.from('synthetic changed External original discovered during admission');
  const currentChecksum = createHash('sha1').update(replacement).digest();
  await writeFile(asset.originalPath, replacement);
  await expect(sut.getUploadAssetIdByChecksum(auth, checksum.toString('hex'))).resolves.toBeUndefined();
  const current = await ctx.get(AssetRepository).getById(asset.id);
  expect(current?.contentChecksum).toEqual(currentChecksum);
  expect(
    await db
      .selectFrom('asset_duplicate_checksum')
      .select('assetId')
      .where('ownerId', '=', user.id)
      .where('checksum', '=', currentChecksum)
      .executeTakeFirst(),
  ).toEqual({ assetId: asset.id });
  await db
    .updateTable('asset')
    .set({ status: AssetStatus.Trashed, deletedAt: new Date() })
    .where('id', '=', asset.id)
    .execute();
  await expect(
    sut.bulkUploadCheck(auth, { assets: [{ id: 'phone', checksum: currentChecksum.toString('hex') }] }),
  ).resolves.toEqual({
    results: [
      {
        id: 'phone',
        action: AssetUploadAction.REJECT,
        reason: AssetRejectReason.DUPLICATE,
        assetId: asset.id,
        isTrashed: true,
      },
    ],
  });
  expect(await readFile(asset.originalPath)).toEqual(replacement);
});

it('keeps verified External Trash authoritative without a legacy alias, then restores the same real object', async () => {
  const data = await fixture();
  const { sut, ctx, asset, auth, checksum, bytes, user } = data;
  await sut.getUploadAssetIdByChecksum(auth, checksum.toString('hex'));
  await db
    .deleteFrom('asset_duplicate_checksum')
    .where('ownerId', '=', user.id)
    .where('assetId', '=', asset.id)
    .execute();
  await db
    .updateTable('asset')
    .set({ status: AssetStatus.Trashed, deletedAt: new Date() })
    .where('id', '=', asset.id)
    .execute();
  await expect(
    sut.bulkUploadCheck(auth, { assets: [{ id: 'phone', checksum: checksum.toString('hex') }] }),
  ).resolves.toEqual({
    results: [
      {
        id: 'phone',
        action: AssetUploadAction.REJECT,
        reason: AssetRejectReason.DUPLICATE,
        assetId: asset.id,
        isTrashed: true,
      },
    ],
  });
  const file = await incomingUpload(data);
  await expect(sut.uploadAsset(auth, uploadDto(), file)).resolves.toMatchObject({
    id: asset.id,
    status: AssetMediaStatus.DUPLICATE,
  });
  expect(await db.selectFrom('asset').select('id').where('ownerId', '=', user.id).execute()).toEqual([
    { id: asset.id },
  ]);
  await db
    .updateTable('asset')
    .set({ status: AssetStatus.Active, deletedAt: null })
    .where('id', '=', asset.id)
    .execute();
  await expect(sut.getUploadAssetIdByChecksum(auth, checksum.toString('hex'))).resolves.toMatchObject({
    id: asset.id,
    status: AssetMediaStatus.DUPLICATE,
  });
  expect(await readFile(asset.originalPath)).toEqual(bytes);
  const restored = await ctx.get(AssetRepository).getById(asset.id);
  expect(restored?.originalPath).toBe(asset.originalPath);
});

it('preserves a historical pair and acknowledges its real Managed UUID pending a separately approved merge', async () => {
  const { sut, ctx, asset, bytes, checksum, auth, user } = await fixture();
  const mobilePath = join(root, 'mobile.jpg');
  await writeFile(mobilePath, bytes);
  const duplicateId = newUuid();
  await db.updateTable('asset').set({ duplicateId }).where('id', '=', asset.id).execute();
  const managed = await ctx.get(AssetRepository).create({
    ...asset,
    id: undefined,
    libraryId: null,
    isExternal: false,
    originalPath: mobilePath,
    checksum,
    checksumAlgorithm: ChecksumAlgorithm.sha1File,
    duplicateId,
  });
  expect(managed.duplicateId).not.toBeNull();
  await expect(sut.getUploadAssetIdByChecksum(auth, checksum.toString('hex'))).resolves.toMatchObject({
    id: managed.id,
  });
  const external = await ctx.get(AssetRepository).getById(asset.id);
  expect(external).toMatchObject({
    id: asset.id,
    ownerId: user.id,
    libraryId: asset.libraryId,
    isFavorite: true,
    duplicateId: managed.duplicateId,
  });
  expect(await readFile(asset.originalPath)).toEqual(bytes);
  expect(await readFile(managed.originalPath)).toEqual(bytes);
});

it('does not acknowledge another owners managed copy', async () => {
  const { sut, ctx, checksum, bytes, asset } = await fixture();
  const mobilePath = join(root, 'first-owner-mobile.jpg');
  await writeFile(mobilePath, bytes);
  await ctx.get(AssetRepository).create({
    ...asset,
    id: undefined,
    libraryId: null,
    isExternal: false,
    originalPath: mobilePath,
    checksum,
    checksumAlgorithm: ChecksumAlgorithm.sha1File,
  });
  const { user } = await ctx.newUser();
  const auth = factory.auth({ user: { id: user.id } });
  await expect(sut.getUploadAssetIdByChecksum(auth, checksum.toString('hex'))).resolves.toBeUndefined();
  await expect(
    sut.bulkUploadCheck(auth, { assets: [{ id: 'other-phone', checksum: checksum.toString('hex') }] }),
  ).resolves.toEqual({ results: [{ id: 'other-phone', action: AssetUploadAction.ACCEPT }] });
});

it('retains the explicit external Trash barrier against automatic mobile reupload', async () => {
  const { sut, asset, checksum, auth, bytes } = await fixture();
  await db
    .updateTable('asset')
    .set({ status: AssetStatus.Trashed, deletedAt: new Date() })
    .where('id', '=', asset.id)
    .execute();
  await expect(
    sut.bulkUploadCheck(auth, { assets: [{ id: 'phone', checksum: checksum.toString('hex') }] }),
  ).resolves.toEqual({
    results: [
      {
        id: 'phone',
        action: AssetUploadAction.REJECT,
        reason: AssetRejectReason.DUPLICATE,
        assetId: asset.id,
        isTrashed: true,
      },
    ],
  });
  await expect(sut.getUploadAssetIdByChecksum(auth, checksum.toString('hex'))).resolves.toMatchObject({ id: asset.id });
  expect(await readFile(asset.originalPath)).toEqual(bytes);
});

it('does not treat active offline index tombstones as user Trash or a managed backup', async () => {
  const { sut, asset, checksum, auth, bytes } = await fixture();
  await db
    .updateTable('asset')
    .set({ status: AssetStatus.Active, isOffline: true, deletedAt: new Date() })
    .where('id', '=', asset.id)
    .execute();
  await expect(
    sut.bulkUploadCheck(auth, { assets: [{ id: 'phone', checksum: checksum.toString('hex') }] }),
  ).resolves.toEqual({ results: [{ id: 'phone', action: AssetUploadAction.ACCEPT }] });
  await expect(sut.getUploadAssetIdByChecksum(auth, checksum.toString('hex'))).resolves.toBeUndefined();
  await expect(
    db.selectFrom('asset').select(['status', 'isOffline']).where('id', '=', asset.id).executeTakeFirst(),
  ).resolves.toEqual({ status: AssetStatus.Active, isOffline: true });
  expect(await readFile(asset.originalPath)).toEqual(bytes);
});

it('preserves an explicit perceptual group without conflating different bytes', async () => {
  const { ctx, asset, user, bytes } = await fixture();
  const duplicateId = newUuid();
  const editedBytes = Buffer.from('synthetic edited version with different content');
  const editedPath = join(root, 'edited.jpg');
  await writeFile(editedPath, editedBytes);
  const edited = await ctx.get(AssetRepository).create({
    ...asset,
    id: undefined,
    libraryId: null,
    isExternal: false,
    originalPath: editedPath,
    checksum: createHash('sha1').update(editedBytes).digest(),
    checksumAlgorithm: ChecksumAlgorithm.sha1File,
    duplicateId,
  });
  expect(edited.duplicateId).toBe(duplicateId);
  expect(edited.ownerId).toBe(user.id);
  const external = await ctx.get(AssetRepository).getById(asset.id);
  expect(external?.duplicateId).toBeNull();
  expect(await readFile(asset.originalPath)).toEqual(bytes);
  expect(await readFile(edited.originalPath)).toEqual(editedBytes);
});

it('does not treat a checksum-resolution alias as proof that different originals have identical bytes', async () => {
  const { ctx, asset, user } = await fixture();
  const keeper = await ctx
    .get(AssetRepository)
    .create(mediumFactory.assetInsert({ ownerId: user.id, checksum: Buffer.from('keeper-content') }));
  const otherChecksum = createHash('sha1').update('different edited bytes').digest();
  await db
    .insertInto('asset_duplicate_checksum')
    .values({ ownerId: user.id, assetId: keeper.id, checksum: otherChecksum })
    .execute();
  const uploaded = await ctx.get(AssetRepository).create({
    ...asset,
    id: undefined,
    libraryId: null,
    isExternal: false,
    originalPath: join(root, 'distinct-version.jpg'),
    checksum: otherChecksum,
    checksumAlgorithm: ChecksumAlgorithm.sha1File,
  });
  expect(uploaded.duplicateId).toBeNull();
  const kept = await ctx.get(AssetRepository).getById(keeper.id);
  expect(kept?.duplicateId).toBeNull();
});

it('does not change another owners asset through a mismatched checksum alias', async () => {
  const { ctx, asset, checksum, user, bytes } = await fixture();
  const { user: other } = await ctx.newUser();
  // Both FKs are valid but the legacy alias is internally inconsistent. Neither
  // owner nor content identity may be inferred from the alias owner alone.
  await db.insertInto('asset_duplicate_checksum').values({ ownerId: other.id, assetId: asset.id, checksum }).execute();
  const uploaded = await ctx.get(AssetRepository).create({
    ...asset,
    id: undefined,
    ownerId: other.id,
    libraryId: null,
    isExternal: false,
    originalPath: join(root, 'other-owner.jpg'),
    checksum,
    checksumAlgorithm: ChecksumAlgorithm.sha1File,
  });
  expect(uploaded.duplicateId).toBeNull();
  expect(uploaded.ownerId).toBe(other.id);
  expect(await ctx.get(AssetRepository).getById(asset.id)).toMatchObject({ ownerId: user.id, duplicateId: null });
  expect(await readFile(asset.originalPath)).toEqual(bytes);
});

it('does not suppress an external import through another owners mismatched alias', async () => {
  const { ctx, asset, checksum } = await fixture();
  const { user: other } = await ctx.newUser();
  const { library } = await ctx.newLibrary({ ownerId: other.id });
  await db.insertInto('asset_duplicate_checksum').values({ ownerId: other.id, assetId: asset.id, checksum }).execute();
  const ids = await ctx.get(AssetRepository).createAll([
    {
      ...mediumFactory.assetInsert({
        ownerId: other.id,
        libraryId: library.id,
        isExternal: true,
        originalPath: join(root, 'other-library.jpg'),
        checksum: createHash('sha1').update('other-library-path').digest(),
        checksumAlgorithm: ChecksumAlgorithm.sha1Path,
      }),
      contentChecksum: checksum,
    },
  ]);
  expect(ids).toHaveLength(1);
});

it('accepts the same original once when an interrupted library batch is redelivered', async () => {
  const { ctx, user, bytes } = await fixture();
  const { library } = await ctx.newLibrary({ ownerId: user.id });
  const originalPath = join(root, 'redelivered.jpg');
  await writeFile(originalPath, bytes);
  const original = mediumFactory.assetInsert({
    ownerId: user.id,
    libraryId: library.id,
    isExternal: true,
    originalPath,
    checksum: createHash('sha1').update(originalPath).digest(),
    checksumAlgorithm: ChecksumAlgorithm.sha1Path,
  });
  const repository = ctx.get(AssetRepository);
  const ids = await repository.createAll([original, { ...original, id: newUuid() }]);
  expect(ids).toHaveLength(1);
  const { album } = await ctx.newAlbum({ ownerId: user.id }, ids);
  await db.updateTable('asset').set({ isFavorite: true }).where('id', '=', ids[0]).execute();
  await expect(repository.createAll([original])).resolves.toEqual([]);
  const rows = await db.selectFrom('asset').select('id').where('originalPath', '=', originalPath).execute();
  expect(rows).toEqual([{ id: ids[0] }]);
  expect(await repository.getById(ids[0])).toMatchObject({ isFavorite: true });
  await expect(
    db.selectFrom('album_asset').select('assetId').where('albumId', '=', album.id).execute(),
  ).resolves.toEqual([{ assetId: ids[0] }]);
  expect(await readFile(originalPath)).toEqual(bytes);
});

it('rolls back an interrupted identity write and safely retries without acknowledging a missing backup', async () => {
  const { ctx, user, asset, checksum, auth, sut, bytes } = await fixture();
  const originalPath = join(root, 'retry-upload.jpg');
  await writeFile(originalPath, bytes);
  const managed = mediumFactory.assetInsert({
    ownerId: user.id,
    libraryId: null,
    originalPath,
    checksum,
    checksumAlgorithm: ChecksumAlgorithm.sha1File,
  });
  await sql`CREATE FUNCTION foto_fail_identity() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'synthetic interruption before identity commit'; END $$`.execute(db);
  await sql`CREATE TRIGGER foto_fail_identity BEFORE INSERT ON asset_duplicate_checksum
    FOR EACH ROW EXECUTE FUNCTION foto_fail_identity()`.execute(db);
  try {
    await expect(ctx.get(AssetRepository).create(managed)).rejects.toThrow('synthetic interruption');
    await expect(sut.getUploadAssetIdByChecksum(auth, checksum.toString('hex'))).resolves.toMatchObject({
      id: asset.id,
    });
    await expect(db.selectFrom('asset').select('id').where('id', '=', managed.id!).execute()).resolves.toEqual([]);
    const external = await ctx.get(AssetRepository).getById(asset.id);
    expect(external?.duplicateId).toBeNull();
  } finally {
    await sql`DROP TRIGGER foto_fail_identity ON asset_duplicate_checksum`.execute(db);
    await sql`DROP FUNCTION foto_fail_identity()`.execute(db);
  }
  const created = await ctx.get(AssetRepository).create(managed);
  await expect(sut.getUploadAssetIdByChecksum(auth, checksum.toString('hex'))).resolves.toMatchObject({
    id: created.id,
  });
  expect(await readFile(asset.originalPath)).toEqual(bytes);
  expect(await readFile(originalPath)).toEqual(bytes);
});

it('reimports a renamed NAS original without reviving or changing its offline index tombstone', async () => {
  const { ctx, asset, checksum, user, bytes } = await fixture();
  const renamed = join(root, 'renamed.jpg');
  await rename(asset.originalPath, renamed);
  const deletedAt = new Date('2026-10-01T12:00:00Z');
  await db
    .updateTable('asset')
    .set({ status: AssetStatus.Active, isOffline: true, deletedAt })
    .where('id', '=', asset.id)
    .execute();
  const imported = await ctx.get(AssetRepository).createAll([
    {
      ...mediumFactory.assetInsert({
        ownerId: user.id,
        libraryId: asset.libraryId,
        isExternal: true,
        originalPath: renamed,
        checksum: createHash('sha1').update(renamed).digest(),
        checksumAlgorithm: ChecksumAlgorithm.sha1Path,
      }),
      contentChecksum: checksum,
    },
  ]);
  expect(imported).toHaveLength(1);
  expect(await ctx.get(AssetRepository).getById(asset.id)).toMatchObject({
    status: AssetStatus.Active,
    isOffline: true,
    deletedAt,
    originalPath: asset.originalPath,
  });
  expect(await ctx.get(AssetRepository).getById(imported[0])).toMatchObject({
    ownerId: user.id,
    libraryId: asset.libraryId,
    originalPath: renamed,
    status: AssetStatus.Active,
    deletedAt: null,
  });
  await expect(
    db
      .selectFrom('asset_duplicate_checksum')
      .select('assetId')
      .where('ownerId', '=', user.id)
      .where('checksum', '=', checksum)
      .executeTakeFirst(),
  ).resolves.toEqual({ assetId: imported[0] });
  expect(await readFile(renamed)).toEqual(bytes);
});

it('still blocks renamed content explicitly trashed by the owner, even when marked offline', async () => {
  const { ctx, asset, checksum, user, bytes } = await fixture();
  const renamed = join(root, 'trashed-renamed.jpg');
  await rename(asset.originalPath, renamed);
  await db
    .updateTable('asset')
    .set({ status: AssetStatus.Trashed, isOffline: true, deletedAt: new Date() })
    .where('id', '=', asset.id)
    .execute();
  await expect(
    ctx.get(AssetRepository).createAll([
      {
        ...mediumFactory.assetInsert({
          ownerId: user.id,
          libraryId: asset.libraryId,
          isExternal: true,
          originalPath: renamed,
          checksum: createHash('sha1').update(renamed).digest(),
          checksumAlgorithm: ChecksumAlgorithm.sha1Path,
        }),
        contentChecksum: checksum,
      },
    ]),
  ).resolves.toEqual([]);
  expect(await readFile(renamed)).toEqual(bytes);
});

it('retains two separate originals in one batch while storing one content anchor and retrying safely', async () => {
  const { ctx, asset, user } = await fixture();
  const bytes = Buffer.from('another synthetic photo present at two independent paths');
  const contentChecksum = createHash('sha1').update(bytes).digest();
  const files = [join(root, 'copy-one.jpg'), join(root, 'copy-two.jpg')];
  for (const file of files) await writeFile(file, bytes);
  const batch = files.map((originalPath) => ({
    ...mediumFactory.assetInsert({
      ownerId: user.id,
      libraryId: asset.libraryId,
      isExternal: true,
      originalPath,
      checksum: createHash('sha1').update(originalPath).digest(),
      checksumAlgorithm: ChecksumAlgorithm.sha1Path,
    }),
    contentChecksum,
  }));
  const repository = ctx.get(AssetRepository);
  const ids = await repository.createAll(batch);
  expect(ids).toHaveLength(2);
  await expect(repository.createAll(batch)).resolves.toEqual([]);
  const anchors = await db
    .selectFrom('asset_duplicate_checksum')
    .select('assetId')
    .where('ownerId', '=', user.id)
    .where('checksum', '=', contentChecksum)
    .execute();
  expect(anchors).toHaveLength(1);
  expect(ids).toContain(anchors[0].assetId);
  for (const file of files) expect(await readFile(file)).toEqual(bytes);
});

it('does not reimport an offline original with a pending deletion receipt whose content proof is not prepared yet', async () => {
  const { ctx, asset, checksum, user, bytes } = await fixture();
  const renamed = join(root, 'pending-renamed.jpg');
  await rename(asset.originalPath, renamed);
  await db
    .updateTable('asset')
    .set({ status: AssetStatus.Active, isOffline: true, deletedAt: new Date() })
    .where('id', '=', asset.id)
    .execute();
  // Synthetic intent only: this does not authorize deletion or fabricate a
  // recovery proof. The scanner must respect the existing durable barrier.
  await db
    .insertInto('asset_deletion_tombstone')
    .values({
      assetId: asset.id,
      operationId: asset.id,
      ownerId: user.id,
      libraryId: asset.libraryId,
      scope: asset.libraryId!,
      originalPath: asset.originalPath,
      checksum: asset.checksum,
      checksumAlgorithm: ChecksumAlgorithm.sha1Path,
      contentChecksum: Buffer.alloc(0),
      aliases: [checksum.toString('hex')],
      authorization: {
        mode: 'storage',
        actor: user.id,
        recoveryProof: '',
        policyUpdatedAt: new Date().toISOString(),
      },
      files: [],
      state: 'failed',
      errorCode: 'ORIGINAL_OUTSIDE_AUTHORIZED_ROOT',
    })
    .execute();
  await expect(
    ctx.get(AssetRepository).createAll([
      {
        ...mediumFactory.assetInsert({
          ownerId: user.id,
          libraryId: asset.libraryId,
          isExternal: true,
          originalPath: renamed,
          checksum: createHash('sha1').update(renamed).digest(),
          checksumAlgorithm: ChecksumAlgorithm.sha1Path,
        }),
        contentChecksum: checksum,
      },
    ]),
  ).resolves.toEqual([]);
  expect(await readFile(renamed)).toEqual(bytes);
});

const incomingUpload = async (
  data: Awaited<ReturnType<typeof fixture>>,
  name = '20261025_173327.jpg',
  bytes = data.bytes,
) => {
  const uploadRoot = StorageCore.getFolderLocation(StorageFolder.Upload, data.user.id);
  await mkdir(uploadRoot, { recursive: true });
  const originalPath = join(uploadRoot, `${newUuid()}-${name}`);
  await writeFile(originalPath, bytes);
  return mediumFactory.uploadFile({
    originalPath,
    originalName: name,
    checksum: createHash('sha1').update(bytes).digest(),
    size: bytes.length,
  });
};

const uploadDto = () => ({
  fileCreatedAt: new Date('2026-10-25T17:33:27Z'),
  fileModifiedAt: new Date('2026-10-25T17:33:27Z'),
  assetData: Buffer.from('synthetic multipart body'),
});

it('deduplicates a legacy multipart upload without a checksum preflight and disposes only its incoming files', async () => {
  const data = await fixture();
  const { sut, ctx, asset, auth, bytes, user, checksum } = data;
  const file = await incomingUpload(data);
  const sidecar = await incomingUpload(data, 'phone.xmp', Buffer.from('<xmp>new mobile metadata</xmp>'));
  const { album } = await ctx.newAlbum({ ownerId: user.id }, [asset.id]);
  await ctx.newMetadata({ assetId: asset.id, key: 'description', value: { text: 'preserve External metadata' } });
  const before = await ctx.get(AssetRepository).getById(asset.id);

  await expect(sut.uploadAsset(auth, { ...uploadDto(), isFavorite: false }, file, sidecar)).resolves.toEqual({
    id: asset.id,
    status: AssetMediaStatus.DUPLICATE,
    duplicateId: null,
  });

  const after = await ctx.get(AssetRepository).getById(asset.id);
  expect(after).toMatchObject({
    id: asset.id,
    libraryId: asset.libraryId,
    isExternal: true,
    originalPath: asset.originalPath,
    originalFileName: before!.originalFileName,
    isFavorite: true,
    checksum: before!.checksum,
    checksumAlgorithm: ChecksumAlgorithm.sha1Path,
    contentChecksum: checksum,
    stackId: before!.stackId,
  });
  await expect(
    db.selectFrom('album_asset').select('assetId').where('albumId', '=', album.id).execute(),
  ).resolves.toEqual([{ assetId: asset.id }]);
  await expect(
    db.selectFrom('asset_metadata').select(['key', 'value']).where('assetId', '=', asset.id).execute(),
  ).resolves.toEqual([{ key: 'description', value: { text: 'preserve External metadata' } }]);
  expect(ctx.getMock(EventRepository).emit).not.toHaveBeenCalled();
  expect(ctx.getMock(JobRepository).queue).toHaveBeenCalledTimes(1);
  expect(ctx.getMock(JobRepository).queue).toHaveBeenCalledWith({
    name: JobName.FileDelete,
    data: { files: [file.originalPath, sidecar.originalPath], temporaryOwnerId: user.id },
  });
  const worker = ctx.getService(StorageService);
  await expect(
    worker.handleDeleteFiles({ files: [file.originalPath, sidecar.originalPath], temporaryOwnerId: user.id }),
  ).resolves.toBe(JobStatus.Success);
  await expect(stat(file.originalPath)).rejects.toMatchObject({ code: 'ENOENT' });
  await expect(stat(sidecar.originalPath)).rejects.toMatchObject({ code: 'ENOENT' });
  expect(await readFile(asset.originalPath)).toEqual(bytes);
  await expect(db.selectFrom('asset').select('id').where('ownerId', '=', user.id).execute()).resolves.toEqual([
    { id: asset.id },
  ]);
  await expect(worker.handleDeleteFiles({ files: [asset.originalPath], temporaryOwnerId: user.id })).resolves.toBe(
    JobStatus.Failed,
  );
  expect(await readFile(asset.originalPath)).toEqual(bytes);
});

it('keeps one real object and one persistent original across concurrent legacy uploads and later retries', async () => {
  const data = await fixture();
  const { sut, ctx, asset, auth, user, bytes, checksum } = data;
  const files = await Promise.all(Array.from({ length: 3 }, () => incomingUpload(data)));
  const results = await Promise.all(files.map((file) => sut.uploadAsset(auth, uploadDto(), file)));
  expect(results).toEqual(files.map(() => ({ id: asset.id, status: AssetMediaStatus.DUPLICATE, duplicateId: null })));
  for (const file of files) {
    await expect(
      ctx.getService(StorageService).handleDeleteFiles({ files: [file.originalPath], temporaryOwnerId: user.id }),
    ).resolves.toBe(JobStatus.Success);
  }
  for (let retry = 0; retry < 2; retry++) {
    await expect(sut.getUploadAssetIdByChecksum(auth, checksum.toString('hex'))).resolves.toMatchObject({
      id: asset.id,
    });
    await expect(
      sut.bulkUploadCheck(auth, { assets: [{ id: 'old-phone', checksum: checksum.toString('base64') }] }),
    ).resolves.toEqual({
      results: [
        {
          id: 'old-phone',
          action: AssetUploadAction.REJECT,
          reason: AssetRejectReason.DUPLICATE,
          assetId: asset.id,
          isTrashed: false,
        },
      ],
    });
  }
  expect(await readFile(asset.originalPath)).toEqual(bytes);
  await expect(db.selectFrom('asset').select('id').where('ownerId', '=', user.id).execute()).resolves.toEqual([
    { id: asset.id },
  ]);
});

for (const state of ['missing', 'changed-bytes', 'offline', 'deleted-library', 'unreadable'] as const) {
  it(`does not acknowledge an unavailable or nonidentical External original: ${state}`, async () => {
    const data = await fixture();
    const { sut, ctx, asset, auth, checksum } = data;
    switch (state) {
      case 'missing': {
        await rm(asset.originalPath);
        break;
      }
      case 'changed-bytes': {
        await writeFile(asset.originalPath, Buffer.alloc(data.bytes.length, 42));
        break;
      }
      case 'offline': {
        await db.updateTable('asset').set({ isOffline: true }).where('id', '=', asset.id).execute();
        break;
      }
      case 'deleted-library': {
        await db.updateTable('library').set({ deletedAt: new Date() }).where('id', '=', asset.libraryId!).execute();
        break;
      }
      case 'unreadable': {
        const storage = ctx.get(StorageRepository);
        const actualStat = storage.stat.bind(storage);
        vi.spyOn(storage, 'stat').mockImplementation((path) =>
          path === asset.originalPath
            ? Promise.reject(Object.assign(new Error('synthetic access denial'), { code: 'EACCES' }))
            : actualStat(path),
        );

        break;
      }
      // No default
    }
    await expect(sut.getUploadAssetIdByChecksum(auth, checksum.toString('hex'))).resolves.toBeUndefined();
    await expect(
      sut.bulkUploadCheck(auth, { assets: [{ id: 'phone', checksum: checksum.toString('hex') }] }),
    ).resolves.toEqual({
      results: [{ id: 'phone', action: AssetUploadAction.ACCEPT }],
    });
    const file = await incomingUpload(data);
    const response = await sut.uploadAsset(auth, uploadDto(), file);
    expect(response).toMatchObject({ id: expect.any(String), status: AssetMediaStatus.CREATED });
    expect(response.id).not.toBe(asset.id);
    const saved = await ctx.get(AssetRepository).getById(response.id);
    expect(saved).toMatchObject({ libraryId: null, isExternal: false, originalPath: file.originalPath, checksum });
    expect(await readFile(file.originalPath)).toEqual(data.bytes);
  });
}

it('keeps a same-name edited version as a new Managed original rather than matching by name or size', async () => {
  const data = await fixture();
  const edited = Buffer.alloc(data.bytes.length, 55);
  const file = await incomingUpload(data, 'external.jpg', edited);
  const response = await data.sut.uploadAsset(data.auth, uploadDto(), file);
  expect(response.status).toBe(AssetMediaStatus.CREATED);
  expect(response.id).not.toBe(data.asset.id);
  expect(await readFile(data.asset.originalPath)).toEqual(data.bytes);
  expect(await readFile(file.originalPath)).toEqual(edited);
});

it('does not acknowledge another owner through an internally inconsistent External checksum alias', async () => {
  const data = await fixture();
  const { user: other } = await data.ctx.newUser();
  await db
    .insertInto('asset_duplicate_checksum')
    .values({ ownerId: other.id, assetId: data.asset.id, checksum: data.checksum })
    .execute();
  const auth = factory.auth({ user: { id: other.id } });
  await expect(data.sut.getUploadAssetIdByChecksum(auth, data.checksum.toString('hex'))).resolves.toBeUndefined();
  await expect(
    data.sut.bulkUploadCheck(auth, { assets: [{ id: 'other', checksum: data.checksum.toString('hex') }] }),
  ).resolves.toEqual({ results: [{ id: 'other', action: AssetUploadAction.ACCEPT }] });
  expect(await readFile(data.asset.originalPath)).toEqual(data.bytes);
});

for (const type of [SyncRequestType.AssetsV2, SyncRequestType.LibraryAssetsV1]) {
  it(`publishes the verified real content checksum through the existing ${type} contract`, async () => {
    const { sut, ctx, user, asset, checksum, auth } = await fixture();
    const sync = new SyncTestContext(db);
    const { session } = await sync.newSession({ userId: user.id });
    const syncAuth = factory.auth({ user, session });
    // A client may have already cached path identity before the first mobile backup.
    const initial = await sync.syncStream(syncAuth, [type]);
    const initialAsset = initial.find((item) => item.data.id === asset.id);
    expect(initialAsset?.data).toMatchObject({
      id: asset.id,
      checksum: asset.checksum.toString('base64'),
      libraryId: asset.libraryId,
    });
    await sync.syncAckAll(syncAuth, initial);
    await expect(sut.getUploadAssetIdByChecksum(auth, checksum.toString('hex'))).resolves.toMatchObject({
      id: asset.id,
    });
    const refreshed = await sync.syncStream(syncAuth, [type]);
    const refreshedAsset = refreshed.find((item) => item.data.id === asset.id);
    expect(refreshedAsset?.data).toMatchObject({
      id: asset.id,
      checksum: checksum.toString('base64'),
      libraryId: asset.libraryId,
    });
    const row = await ctx.get(AssetRepository).getById(asset.id);
    expect(row).toMatchObject({
      checksum: asset.checksum,
      checksumAlgorithm: ChecksumAlgorithm.sha1Path,
      contentChecksum: checksum,
      isExternal: true,
    });
    expect(mapAsset(row!)).toMatchObject({
      id: asset.id,
      checksum: checksum.toString('base64'),
      originalPath: asset.originalPath,
      libraryId: asset.libraryId,
    });
    await sync.syncAckAll(syncAuth, refreshed);
    await sync.assertSyncIsComplete(syncAuth, [type]);
  });
}

it('does not turn an identity-persistence failure into a successful duplicate or a new Managed object', async () => {
  const { sut, ctx, asset, user, checksum, auth, bytes } = await fixture();
  await sql`CREATE FUNCTION foto_fail_verified_identity() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'synthetic verified identity persistence failure'; END $$`.execute(db);
  await sql`CREATE TRIGGER foto_fail_verified_identity BEFORE UPDATE OF "contentChecksum" ON asset
    FOR EACH ROW EXECUTE FUNCTION foto_fail_verified_identity()`.execute(db);
  try {
    await expect(sut.getUploadAssetIdByChecksum(auth, checksum.toString('hex'))).rejects.toThrow(
      'synthetic verified identity',
    );
    await expect(
      sut.bulkUploadCheck(auth, { assets: [{ id: 'phone', checksum: checksum.toString('hex') }] }),
    ).rejects.toThrow('synthetic verified identity');
    await expect(
      db.selectFrom('asset').select(['id', 'contentChecksum']).where('ownerId', '=', user.id).execute(),
    ).resolves.toEqual([{ id: asset.id, contentChecksum: null }]);
    expect(ctx.getMock(JobRepository).queue).not.toHaveBeenCalled();
    expect(await readFile(asset.originalPath)).toEqual(bytes);
  } finally {
    await sql`DROP TRIGGER foto_fail_verified_identity ON asset`.execute(db);
    await sql`DROP FUNCTION foto_fail_verified_identity()`.execute(db);
  }
});

it('serializes a concurrent scan and upload admission without indexing another copy of the existing content', async () => {
  const data = await fixture();
  const { sut, ctx, asset, auth, user, checksum } = data;
  const crypto = ctx.get(CryptoRepository);
  const actualHash = crypto.hashFile.bind(crypto);
  const { promise: blocked, resolve: release } = Promise.withResolvers<void>();
  const { promise: hashing, resolve: entered } = Promise.withResolvers<void>();
  vi.spyOn(crypto, 'hashFile').mockImplementationOnce(async (...args) => {
    entered();
    await blocked;
    return actualHash(...args);
  });
  const file = await incomingUpload(data);
  const upload = sut.uploadAsset(auth, uploadDto(), file);
  await hashing;
  const originalPath = join(root, 'scan-race.jpg');
  await writeFile(originalPath, data.bytes);
  const scan = ctx.get(AssetRepository).createAll([
    {
      ...mediumFactory.assetInsert({
        ownerId: user.id,
        libraryId: asset.libraryId,
        isExternal: true,
        originalPath,
        checksum: createHash('sha1').update(originalPath).digest(),
        checksumAlgorithm: ChecksumAlgorithm.sha1Path,
      }),
      contentChecksum: checksum,
    },
  ]);
  release();
  await expect(upload).resolves.toMatchObject({ id: asset.id, status: AssetMediaStatus.DUPLICATE });
  await expect(scan).resolves.toEqual([]);
  await expect(db.selectFrom('asset').select('id').where('ownerId', '=', user.id).execute()).resolves.toEqual([
    { id: asset.id },
  ]);
  expect(await readFile(originalPath)).toEqual(data.bytes);
  expect(await readFile(asset.originalPath)).toEqual(data.bytes);
});

it('does not group a Managed copy of old bytes with an External file whose contents changed', async () => {
  const data = await fixture();
  const replacement = Buffer.alloc(data.bytes.length, 42);
  await writeFile(data.asset.originalPath, replacement);
  const file = await incomingUpload(data);
  const response = await data.sut.uploadAsset(data.auth, uploadDto(), file);
  expect(response).toMatchObject({ status: AssetMediaStatus.CREATED, duplicateId: null });
  expect(response.id).not.toBe(data.asset.id);
  await expect(data.ctx.get(AssetRepository).getById(data.asset.id)).resolves.toMatchObject({ duplicateId: null });
  expect(await readFile(data.asset.originalPath)).toEqual(replacement);
  expect(await readFile(file.originalPath)).toEqual(data.bytes);
});

it('refreshes a changed External original during normal library sync before accepting the new mobile version', async () => {
  const data = await fixture();
  const { sut, ctx, asset, auth, user, checksum } = data;
  await expect(sut.getUploadAssetIdByChecksum(auth, checksum.toString('hex'))).resolves.toMatchObject({ id: asset.id });
  const replacement = Buffer.alloc(data.bytes.length, 63);
  const newChecksum = createHash('sha1').update(replacement).digest();
  await writeFile(asset.originalPath, replacement);
  await expect(
    ctx.getService(LibraryService).handleSyncAssets({
      libraryId: asset.libraryId!,
      importPaths: [root],
      exclusionPatterns: [],
      assetIds: [asset.id],
      progressCounter: 1,
      totalAssets: 1,
    }),
  ).resolves.toBe(JobStatus.Success);
  await expect(sut.getUploadAssetIdByChecksum(auth, newChecksum.toString('hex'))).resolves.toMatchObject({
    id: asset.id,
    status: AssetMediaStatus.DUPLICATE,
  });
  await expect(sut.getUploadAssetIdByChecksum(auth, checksum.toString('hex'))).resolves.toBeUndefined();
  const file = await incomingUpload(data, 'changed-photo.jpg', replacement);
  await expect(sut.uploadAsset(auth, uploadDto(), file)).resolves.toMatchObject({
    id: asset.id,
    status: AssetMediaStatus.DUPLICATE,
  });
  await expect(
    db
      .selectFrom('asset')
      .select(['id', 'libraryId', 'checksum', 'contentChecksum', 'isExternal'])
      .where('ownerId', '=', user.id)
      .execute(),
  ).resolves.toEqual([
    {
      id: asset.id,
      libraryId: asset.libraryId,
      checksum: asset.checksum,
      contentChecksum: newChecksum,
      isExternal: true,
    },
  ]);
  expect(await readFile(asset.originalPath)).toEqual(replacement);
});

it('projects stale offline proof as path identity until the same indexed original is online again', async () => {
  const { sut, ctx, user, asset, checksum, auth } = await fixture();
  await expect(sut.getUploadAssetIdByChecksum(auth, checksum.toString('hex'))).resolves.toMatchObject({ id: asset.id });
  const sync = new SyncTestContext(db);
  const { session } = await sync.newSession({ userId: user.id });
  const syncAuth = factory.auth({ user, session });
  await db.updateTable('asset').set({ isOffline: true }).where('id', '=', asset.id).execute();
  const offline = await ctx.get(AssetRepository).getById(asset.id);
  expect(offline).toMatchObject({ contentChecksum: checksum, isOffline: true });
  expect(mapAsset(offline!)).toMatchObject({
    id: asset.id,
    checksum: asset.checksum.toString('base64'),
    isOffline: true,
  });
  const offlineEvents = await sync.syncStream(syncAuth, [SyncRequestType.AssetsV2]);
  expect(offlineEvents.find((item) => item.data.id === asset.id)?.data).toMatchObject({
    id: asset.id,
    checksum: asset.checksum.toString('base64'),
  });
  await sync.syncAckAll(syncAuth, offlineEvents);
  await db.updateTable('asset').set({ isOffline: false }).where('id', '=', asset.id).execute();
  const onlineEvents = await sync.syncStream(syncAuth, [SyncRequestType.AssetsV2]);
  expect(onlineEvents.find((item) => item.data.id === asset.id)?.data).toMatchObject({
    id: asset.id,
    checksum: checksum.toString('base64'),
  });
  const online = await ctx.get(AssetRepository).getById(asset.id);
  expect(mapAsset(online!)).toMatchObject({ id: asset.id, checksum: checksum.toString('base64'), isOffline: false });
});

it('does not let stale offline proof prevent admission of an available verified External original', async () => {
  const { sut, ctx, user, asset, bytes, checksum, auth } = await fixture();
  const stalePath = join(root, 'stale-offline-copy.jpg');
  await writeFile(stalePath, bytes);
  const { result: stale } = await ctx.newAsset({
    ownerId: user.id,
    libraryId: asset.libraryId,
    isExternal: true,
    isOffline: true,
    originalPath: stalePath,
    checksum: createHash('sha1').update(stalePath).digest(),
    checksumAlgorithm: ChecksumAlgorithm.sha1Path,
    contentChecksum: checksum,
  });
  await expect(sut.getUploadAssetIdByChecksum(auth, checksum.toString('hex'))).resolves.toMatchObject({ id: asset.id });
  const available = await ctx.get(AssetRepository).getById(asset.id);
  expect(available).toMatchObject({ contentChecksum: checksum, isOffline: false });
  const sync = new SyncTestContext(db);
  const { session } = await sync.newSession({ userId: user.id });
  const events = await sync.syncStream(factory.auth({ user, session }), [SyncRequestType.AssetsV2]);
  expect(events.find((item) => item.data.id === asset.id)?.data).toMatchObject({
    id: asset.id,
    checksum: checksum.toString('base64'),
  });
  expect(events.find((item) => item.data.id === stale.id)?.data).toMatchObject({
    id: stale.id,
    checksum: stale.checksum.toString('base64'),
  });
  await expect(
    db.selectFrom('asset').select('id').where('ownerId', '=', user.id).where('libraryId', 'is', null).execute(),
  ).resolves.toEqual([]);
  expect(await readFile(asset.originalPath)).toEqual(bytes);
  expect(await readFile(stalePath)).toEqual(bytes);
});

it('keeps a Trashed canonical proof unique when another External original changes to the same bytes', async () => {
  const { sut, ctx, user, asset, bytes, checksum, auth } = await fixture();
  await expect(sut.getUploadAssetIdByChecksum(auth, checksum.toString('hex'))).resolves.toMatchObject({ id: asset.id });
  await db
    .updateTable('asset')
    .set({ status: AssetStatus.Trashed, deletedAt: new Date() })
    .where('id', '=', asset.id)
    .execute();
  const changedPath = join(root, 'changed-to-trashed-content.jpg');
  await writeFile(changedPath, bytes);
  const { result: changed } = await ctx.newAsset({
    ownerId: user.id,
    libraryId: asset.libraryId,
    isExternal: true,
    originalPath: changedPath,
    checksum: createHash('sha1').update(changedPath).digest(),
    checksumAlgorithm: ChecksumAlgorithm.sha1Path,
  });
  const repository = ctx.get(AssetRepository);
  await repository.refreshExternalContent(asset.libraryId!, changed.id, (candidate) =>
    verifyExternalOriginal(candidate, {
      storage: ctx.get(StorageRepository),
      crypto: ctx.get(CryptoRepository),
      logger: ctx.getMock(LoggingRepository),
    }),
  );
  const trashed = await repository.getById(asset.id);
  const active = await repository.getById(changed.id);
  expect(trashed).toMatchObject({ contentChecksum: checksum, status: AssetStatus.Trashed });
  expect(active).toMatchObject({ contentChecksum: null, status: AssetStatus.Active });
  expect(mapAsset(trashed!)).toMatchObject({ checksum: checksum.toString('base64'), isTrashed: true });
  expect(mapAsset(active!)).toMatchObject({ checksum: changed.checksum.toString('base64'), isTrashed: false });
  await expect(
    sut.bulkUploadCheck(auth, { assets: [{ id: 'old-phone', checksum: checksum.toString('hex') }] }),
  ).resolves.toEqual({
    results: [
      {
        id: 'old-phone',
        action: AssetUploadAction.REJECT,
        reason: AssetRejectReason.DUPLICATE,
        assetId: asset.id,
        isTrashed: true,
      },
    ],
  });
  expect(await readFile(asset.originalPath)).toEqual(bytes);
  expect(await readFile(changedPath)).toEqual(bytes);
});
