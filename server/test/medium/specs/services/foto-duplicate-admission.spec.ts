import { Kysely, sql } from 'kysely';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { AssetRejectReason, AssetUploadAction } from 'src/dtos/asset-media-response.dto.js';
import { AssetStatus, ChecksumAlgorithm } from 'src/enum.js';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { DB } from 'src/schema/index.js';
import { AssetMediaService } from 'src/services/asset-media.service.js';
import { mediumFactory, newMediumService } from 'test/medium.factory.js';
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
});
afterEach(async () => {
  await rm(root, { recursive: true, force: true });
});

const fixture = async () => {
  const { sut, ctx } = newMediumService(AssetMediaService, {
    database: db,
    real: [AssetRepository],
    mock: [LoggingRepository],
  });
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

it('does not acknowledge an external-only original as a completed managed mobile backup', async () => {
  const { sut, ctx, asset, bytes, checksum, auth, user } = await fixture();
  await expect(sut.getUploadAssetIdByChecksum(auth, checksum.toString('hex'))).resolves.toBeUndefined();
  await expect(
    sut.bulkUploadCheck(auth, { assets: [{ id: 'phone', checksum: checksum.toString('hex') }] }),
  ).resolves.toEqual({ results: [{ id: 'phone', action: AssetUploadAction.ACCEPT }] });
  expect(await readFile(asset.originalPath)).toEqual(bytes);
  const external = await ctx.get(AssetRepository).getById(asset.id);
  expect(external?.isFavorite).toBe(true);
  expect(await db.selectFrom('asset').select('id').where('ownerId', '=', user.id).execute()).toHaveLength(1);
});

it('acknowledges the actual managed copy after upload, retaining the external original and its metadata', async () => {
  const { sut, ctx, asset, bytes, checksum, auth, user } = await fixture();
  const mobilePath = join(root, 'mobile.jpg');
  await writeFile(mobilePath, bytes);
  const managed = await ctx.get(AssetRepository).create({
    ...asset,
    id: undefined,
    libraryId: null,
    isExternal: false,
    originalPath: mobilePath,
    checksum,
    checksumAlgorithm: ChecksumAlgorithm.sha1File,
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
    await expect(sut.getUploadAssetIdByChecksum(auth, checksum.toString('hex'))).resolves.toBeUndefined();
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
