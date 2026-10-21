import { Kysely } from 'kysely';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { AssetRejectReason, AssetUploadAction } from 'src/dtos/asset-media-response.dto.js';
import { AssetStatus, ChecksumAlgorithm } from 'src/enum.js';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { DB } from 'src/schema/index.js';
import { AssetMediaService } from 'src/services/asset-media.service.js';
import { newMediumService } from 'test/medium.factory.js';
import { factory } from 'test/small.factory.js';
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
