import { AssetResponseSchema, mapAsset } from 'src/dtos/asset-response.dto.js';
import { AssetStatus, ChecksumAlgorithm } from 'src/enum.js';
import { AssetFactory } from 'test/factories/asset.factory.js';
import { authStub } from 'test/fixtures/auth.stub.js';
import { getForAsset } from 'test/mappers.js';

describe('verified content checksum response compatibility', () => {
  it('exposes verified external bytes through the existing checksum field without changing external identity', () => {
    const pathChecksum = Buffer.alloc(20, 1);
    const contentChecksum = Buffer.alloc(20, 2);
    const asset = AssetFactory.create({
      isExternal: true,
      libraryId: '123e4567-e89b-42d3-a456-426614174000',
      checksum: pathChecksum,
      contentChecksum,
      checksumAlgorithm: ChecksumAlgorithm.sha1Path,
    });

    const response = mapAsset(getForAsset(asset));

    expect(response.checksum).toBe(contentChecksum.toString('base64'));
    expect(response.id).toBe(asset.id);
    expect(response.libraryId).toBe(asset.libraryId);
    expect(response.originalPath).toBe(asset.originalPath);
    expect(response).not.toHaveProperty('contentChecksum');
    expect(AssetResponseSchema.safeParse(response).success).toBe(true);
    expect(asset.checksum).toEqual(pathChecksum);
    expect(asset.checksumAlgorithm).toBe(ChecksumAlgorithm.sha1Path);
    expect(asset.isExternal).toBe(true);
  });

  it('keeps unverified external and managed checksums unchanged', () => {
    for (const isExternal of [true, false]) {
      const asset = AssetFactory.create({ isExternal, contentChecksum: null });
      expect(mapAsset(getForAsset(asset)).checksum).toBe(asset.checksum.toString('base64'));
    }
  });

  it('returns to path identity when server verification is invalidated', () => {
    const asset = AssetFactory.create({
      isExternal: true,
      checksumAlgorithm: ChecksumAlgorithm.sha1Path,
      checksum: Buffer.alloc(20, 1),
      contentChecksum: Buffer.alloc(20, 2),
    });
    expect(mapAsset(getForAsset(asset)).checksum).toBe(asset.contentChecksum!.toString('base64'));
    asset.contentChecksum = null;
    expect(mapAsset(getForAsset(asset)).checksum).toBe(asset.checksum.toString('base64'));
  });

  it('does not present a stale verified digest as an available offline External backup', () => {
    const asset = AssetFactory.create({
      isExternal: true,
      isOffline: true,
      checksumAlgorithm: ChecksumAlgorithm.sha1Path,
      checksum: Buffer.alloc(20, 1),
      contentChecksum: Buffer.alloc(20, 2),
    });
    const response = mapAsset(getForAsset(asset));
    expect(response.checksum).toBe(asset.checksum.toString('base64'));
    expect(response.isOffline).toBe(true);
    expect(asset.contentChecksum).toEqual(Buffer.alloc(20, 2));
  });

  it('does not expose either checksum through sanitized shared-link responses', () => {
    const asset = AssetFactory.create({ contentChecksum: Buffer.alloc(20, 2) });
    const response = mapAsset(getForAsset(asset), { stripMetadata: true });
    expect(response).not.toHaveProperty('checksum');
    expect(response).not.toHaveProperty('contentChecksum');
  });
});

describe('asset deletion timestamps', () => {
  it('maps the real deletion timestamp without substituting capture/update metadata', () => {
    const asset = AssetFactory.create({
      status: AssetStatus.Trashed,
      deletedAt: new Date('2026-10-05T11:12:13.456Z'),
      updatedAt: new Date('2026-10-05T23:00:00Z'),
      localDateTime: new Date('2024-10-05T12:00:00Z'),
    });
    const response = mapAsset(getForAsset(asset));
    expect(response.deletedAt).toBe('2026-10-05T11:12:13.456Z');
    expect(response.isTrashed).toBe(true);
    expect(response.localDateTime).toBe('2024-10-05T12:00:00.000Z');
    expect(AssetResponseSchema.safeParse(response).success).toBe(true);
  });

  it('does not report an Active offline external index tombstone as user Trash', () => {
    const response = mapAsset(
      getForAsset(
        AssetFactory.create({
          status: AssetStatus.Active,
          isOffline: true,
          deletedAt: new Date('2026-10-05T11:12:13.456Z'),
        }),
      ),
    );
    expect(response.isTrashed).toBe(false);
    expect(response.deletedAt).toBeNull();
    expect(response.isOffline).toBe(true);
  });

  it('returns null on restored/non-trash assets and accepts older responses without the optional field', () => {
    const response = mapAsset(getForAsset(AssetFactory.create({ deletedAt: null })));
    expect(response.deletedAt).toBeNull();
    expect(response.isTrashed).toBe(false);
    const olderResponse = { ...response };
    delete olderResponse.deletedAt;
    expect(AssetResponseSchema.safeParse(olderResponse).success).toBe(true);
  });

  it('keeps restricted shared-link metadata sanitized', () => {
    const asset = AssetFactory.create({ deletedAt: new Date('2026-10-05T11:12:13.456Z') });
    const response = mapAsset(getForAsset(asset), { stripMetadata: true });
    expect(response).not.toHaveProperty('deletedAt');
  });
});

describe('personal favorite response projection', () => {
  it('uses the requesting users overlay even for an asset owned by somebody else', () => {
    const asset = AssetFactory.create({ ownerId: authStub.admin.user.id, isFavorite: false });
    const response = mapAsset(getForAsset(asset), { auth: authStub.user1, favoriteAssetIds: new Set([asset.id]) });
    expect(response.isFavorite).toBe(true);
    expect(asset.isFavorite).toBe(false);
  });
  it('does not reveal the link owners overlay to a shared-link visitor', () => {
    const asset = AssetFactory.create({ ownerId: authStub.adminSharedLink.user.id, isFavorite: true });
    const response = mapAsset(getForAsset(asset), {
      auth: authStub.adminSharedLink,
      favoriteAssetIds: new Set([asset.id]),
    });
    expect(response.isFavorite).toBe(false);
  });
});
