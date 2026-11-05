import { access, mkdtemp, readFile, rm, unlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { Kysely } from 'kysely';
import type { DB } from 'src/schema/index.js';
import { StorageCore } from 'src/cores/storage.core.js';
import { AssetFileType, AssetStatus, JobStatus, StorageFolder } from 'src/enum.js';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { AssetService } from 'src/services/asset.service.js';
import { StorageService } from 'src/services/storage.service.js';
import { newMediumService } from 'test/medium.factory.js';
import { getKyselyDB, newTestService } from 'test/utils.js';

class CleanupProbe extends StorageService {
  cleanup(paths: string[], referenced: (path: string) => Promise<boolean>) {
    return this.deleteDisposableFiles({ files: paths }, referenced);
  }
}

let db: Kysely<DB>;
let root: string;
beforeAll(async () => {
  db = await getKyselyDB();
});
afterAll(async () => {
  await db.destroy();
});
beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), 'gallery-derivative-deletion-'));
  const actual = StorageCore.getBaseFolder;
  vi.spyOn(StorageCore, 'getBaseFolder').mockImplementation((folder) =>
    folder === StorageFolder.Thumbnails ? root : actual(folder),
  );
});
afterEach(async () => {
  vi.restoreAllMocks();
  await rm(root, { recursive: true, force: true });
});

async function fixture() {
  const { ctx } = newMediumService(AssetService, { database: db, real: [AssetRepository], mock: [LoggingRepository] });
  const { user } = await ctx.newUser();
  const { asset } = await ctx.newAsset({
    ownerId: user.id,
    originalPath: join(root, 'original.jpg'),
    status: AssetStatus.Deleted,
    deletedAt: new Date(),
  });
  await db
    .insertInto('asset_deletion_tombstone')
    .values({
      assetId: asset.id,
      operationId: asset.id,
      ownerId: user.id,
      libraryId: null,
      scope: 'managed',
      originalPath: asset.originalPath,
      checksum: asset.checksum,
      checksumAlgorithm: asset.checksumAlgorithm,
      contentChecksum: Buffer.alloc(0),
      aliases: [],
      files: [],
      authorization: { actor: user.id, recoveryProof: '', policyUpdatedAt: new Date().toISOString() },
      state: 'files-removed',
      errorCode: null,
    })
    .execute();
  const repo = new AssetRepository(db);
  const { sut, mocks } = newTestService(CleanupProbe);
  mocks.storage.unlink.mockImplementation(unlink);
  const cleanup = (paths: string[], referenced: (path: string) => Promise<boolean>) =>
    sut.cleanup(paths, referenced).then((state) => state === JobStatus.Success);
  return { ctx, user, asset, repo, mocks, cleanup };
}
async function derivative(id: string, name: string, type: AssetFileType) {
  const path = join(root, name);
  await writeFile(path, `synthetic ${name}`);
  await db.insertInto('asset_file').values({ assetId: id, type, path }).execute();
  return path;
}

describe('authorized derivative cleanup keeps its durable manifest until final completion', () => {
  it('resumes partial unlink after restart without losing asset_file paths', async () => {
    const f = await fixture();
    const first = await derivative(f.asset.id, 'a-thumb.jpg', AssetFileType.Thumbnail);
    const second = await derivative(f.asset.id, 'b-preview.jpg', AssetFileType.Preview);
    let fail = true;
    f.mocks.storage.unlink.mockImplementation(async (path) => {
      if (path === second && fail) throw Object.assign(new Error('synthetic unavailable storage'), { code: 'EIO' });
      await unlink(path);
    });
    expect(await f.repo.removeForDeletion(f.asset, f.cleanup)).toBe(false);
    expect(await f.repo.getDeletionReceipt(f.user.id, f.asset.id)).toMatchObject({
      state: 'files-removed',
      errorCode: 'DERIVATIVE_CLEANUP_FAILED',
    });
    expect(await db.selectFrom('asset_file').select('path').where('assetId', '=', f.asset.id).execute()).toHaveLength(
      2,
    );
    await expect(access(first)).rejects.toMatchObject({ code: 'ENOENT' });
    expect(await readFile(second, 'utf8')).toBe('synthetic b-preview.jpg');
    fail = false;
    expect(await new AssetRepository(db).removeForDeletion(f.asset, f.cleanup)).toBe(true);
    await expect(access(second)).rejects.toMatchObject({ code: 'ENOENT' });
    expect(await f.repo.getDeletionReceipt(f.user.id, f.asset.id)).toMatchObject({
      state: 'complete',
      errorCode: null,
    });
    expect(await db.selectFrom('asset').select('id').where('id', '=', f.asset.id).executeTakeFirst()).toBeUndefined();
    expect(await db.selectFrom('asset_file').select('path').where('assetId', '=', f.asset.id).execute()).toEqual([]);
  });

  it('reads files added after the original deletion snapshot before committing the cascade', async () => {
    const f = await fixture();
    const first = await derivative(f.asset.id, 'a-thumb.jpg', AssetFileType.Thumbnail);
    const stalePaths = await db.selectFrom('asset_file').select('path').where('assetId', '=', f.asset.id).execute();
    expect(stalePaths).toHaveLength(1);
    const late = await derivative(f.asset.id, 'late-preview.jpg', AssetFileType.Preview);
    expect(await f.repo.removeForDeletion(f.asset, f.cleanup)).toBe(true);
    await expect(access(first)).rejects.toMatchObject({ code: 'ENOENT' });
    await expect(access(late)).rejects.toMatchObject({ code: 'ENOENT' });
  });

  it('serializes concurrent derivative publication with the final asset deletion', async () => {
    const f = await fixture();
    await derivative(f.asset.id, 'committed.jpg', AssetFileType.Thumbnail);
    const entered = Promise.withResolvers<void>();
    const resumed = Promise.withResolvers<void>();
    const deleting = f.repo.removeForDeletion(f.asset, async (paths, referenced) => {
      entered.resolve();
      await resumed.promise;
      return f.cleanup(paths, referenced);
    });
    await entered.promise;
    let published = false;
    const publishing = db
      .insertInto('asset_file')
      .values({
        assetId: f.asset.id,
        type: AssetFileType.Preview,
        path: join(root, 'concurrent.jpg'),
      })
      .execute()
      .then(() => {
        published = true;
        return 'inserted';
      })
      .catch((error: { code?: string }) => {
        published = true;
        return error.code;
      });
    try {
      await new Promise((resolve) => setTimeout(resolve, 25));
      expect(published, 'the manifest cannot change while its cleanup transaction owns the asset').toBe(false);
    } finally {
      resumed.resolve();
    }
    expect(await deleting).toBe(true);
    expect(await publishing).toBe('23503');
    expect(await db.selectFrom('asset_file').select('path').where('assetId', '=', f.asset.id).execute()).toEqual([]);
    expect(await f.repo.getDeletionReceipt(f.user.id, f.asset.id)).toMatchObject({ state: 'complete' });
  });

  for (const reference of ['own-original', 'own-sidecar', 'other-owner-file'] as const) {
    it(`retains a path protected by ${reference}`, async () => {
      const f = await fixture();
      const fileName = reference === 'own-original' ? 'original.jpg' : 'protected.jpg';
      const protectedPath = await derivative(f.asset.id, fileName, AssetFileType.Thumbnail);
      if (reference === 'own-sidecar') {
        await db
          .insertInto('asset_file')
          .values({ assetId: f.asset.id, path: protectedPath, type: AssetFileType.Sidecar })
          .execute();
      } else if (reference === 'other-owner-file') {
        const { user } = await f.ctx.newUser();
        const { asset } = await f.ctx.newAsset({ ownerId: user.id });
        await db
          .insertInto('asset_file')
          .values({ assetId: asset.id, path: protectedPath, type: AssetFileType.Preview })
          .execute();
      }
      expect(await f.repo.removeForDeletion(f.asset, f.cleanup)).toBe(false);
      expect(await readFile(protectedPath, 'utf8')).toBe(`synthetic ${fileName}`);
      expect(f.mocks.storage.unlink).not.toHaveBeenCalled();
      expect(await f.repo.getDeletionReceipt(f.user.id, f.asset.id)).toMatchObject({
        state: 'files-removed',
        errorCode: 'DERIVATIVE_CLEANUP_FAILED',
      });
    });
  }

  it('does not declare completion if a derivative manifest exists but no cleanup owner is provided', async () => {
    const f = await fixture();
    const path = await derivative(f.asset.id, 'pending.jpg', AssetFileType.Thumbnail);
    expect(await f.repo.removeForDeletion(f.asset)).toBe(false);
    expect(await readFile(path, 'utf8')).toBe('synthetic pending.jpg');
    expect(await f.repo.getDeletionReceipt(f.user.id, f.asset.id)).toMatchObject({ state: 'files-removed' });
  });
});
