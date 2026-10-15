import { Kysely, sql } from 'kysely';
import { randomUUID } from 'node:crypto';
import { mkdir, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { StorageCore } from 'src/cores/storage.core.js';
import { AssetStatus, AssetType, StorageFolder } from 'src/enum.js';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { DB } from 'src/schema/index.js';
import { AssetService } from 'src/services/asset.service.js';
import { collectRootIdentities } from 'src/utils/authorized-deletion.js';
import { newMediumService } from 'test/medium.factory.js';
import { getKyselyDB } from 'test/utils.js';

const diagnosticUrl = new URL('../../../../../scripts/diagnostics/livephoto_deletion_roots.mjs', import.meta.url);
const { collectDatabaseDiagnostics } = await import(diagnosticUrl.href);
let db: Kysely<DB>;
let directory: string;
let previousMediaLocation: string | undefined;

beforeAll(async () => {
  db = await getKyselyDB();
  try {
    previousMediaLocation = StorageCore.getMediaLocation();
  } catch {
    // This isolated module graph need not have bootstrapped storage.
  }
});
afterAll(async () => {
  if (previousMediaLocation !== undefined) StorageCore.setMediaLocation(previousMediaLocation);
  await db.destroy();
});
beforeEach(async () => {
  directory = await mkdtemp(join(tmpdir(), 'gallery-readonly-root-diagnostic-'));
  StorageCore.setMediaLocation(directory);
});
afterEach(async () => {
  await rm(directory, { recursive: true, force: true });
});

const fixture = async () => {
  const { ctx } = newMediumService(AssetService, { database: db, real: [AssetRepository], mock: [LoggingRepository] });
  StorageCore.setMediaLocation(directory);
  const { user } = await ctx.newUser();
  const upload = StorageCore.getFolderLocation(StorageFolder.Upload, user.id);
  const encoded = StorageCore.getFolderLocation(StorageFolder.EncodedVideo, user.id);
  await Promise.all([mkdir(upload, { recursive: true }), mkdir(encoded, { recursive: true })]);
  const { asset: motion } = await ctx.newAsset({
    ownerId: user.id,
    type: AssetType.Video,
    originalPath: join(encoded, '17', 'f4', `${randomUUID()}-MP.mp4`),
  });
  const { asset: still } = await ctx.newAsset({
    ownerId: user.id,
    originalPath: join(upload, '94', 'c5', `${randomUUID()}.jpg`),
    livePhotoVideoId: motion.id,
    status: AssetStatus.Deleted,
    deletedAt: new Date(),
  });
  const repo = new AssetRepository(db);
  await repo.setDeletionPolicy(user.id, 'managed', {
    enabled: true,
    authorizationMode: 'storage',
    roots: [upload],
    rootIdentities: await collectRootIdentities([upload]),
    recoveryProof: '',
    recoveryExpiresAt: null,
    authorizedBy: user.id,
  });
  const policy = await repo.getDeletionPolicy(user.id, 'managed');
  await db
    .insertInto('asset_deletion_tombstone')
    .values(
      [still, motion].map((asset) => ({
        assetId: asset.id,
        operationId: still.id,
        ownerId: user.id,
        libraryId: null,
        scope: 'managed',
        originalPath: asset.originalPath,
        checksum: asset.checksum,
        checksumAlgorithm: asset.checksumAlgorithm,
        contentChecksum: Buffer.alloc(0),
        aliases: [],
        authorization: {
          mode: 'storage',
          actor: user.id,
          recoveryProof: '',
          policyUpdatedAt: new Date(policy!.updatedAt).toISOString(),
        },
        files: [],
        state: 'failed' as const,
        errorCode: 'ORIGINAL_OUTSIDE_AUTHORIZED_ROOT',
      })),
    )
    .execute();
  return { user, still, motion, upload, encoded };
};

describe('read-only installed-source root diagnostic', () => {
  it.each([AssetType.Video, AssetType.Image])(
    'identifies path admission for a %s companion without opening media or changing receipts',
    async (type) => {
      const f = await fixture();
      await db.updateTable('asset').set({ type }).where('id', '=', f.motion.id).execute();
      const before = await db
        .selectFrom('asset_deletion_tombstone')
        .selectAll()
        .where('ownerId', '=', f.user.id)
        .orderBy('assetId')
        .execute();
      await db.connection().execute(async (connection) => {
        await sql`SET default_transaction_read_only = on`.execute(connection);
        try {
          const result = await collectDatabaseDiagnostics(
            connection,
            { AssetRepository, StorageCore, StorageFolder, sql },
            [f.still.id, f.motion.id, f.user.id],
          );
          expect(result.transactionReadOnly).toBe(true);
          expect(result.roles[0].paths[0].snapshotStage).toBe('PATH_PREDICATES_PASS');
          expect(result.roles[0].paths[0].candidates).toEqual([{ label: 'policy-1', below: true }]);
          expect(result.roles[1].type).toBe(type);
          expect(result.roles[1].paths[0].snapshotStage).toBe(
            type === AssetType.Video ? 'PATH_PREDICATES_PASS' : 'SNAPSHOT_ROOT_NOT_FOUND',
          );
          expect(JSON.stringify(result)).not.toContain(directory);
          expect(JSON.stringify(result)).not.toContain(f.user.id);
          expect(JSON.stringify(result)).not.toContain(f.still.id);
          expect(JSON.stringify(result)).not.toContain(f.motion.id);
        } finally {
          await sql`SET default_transaction_read_only = off`.execute(connection);
        }
      });
      expect(
        await db
          .selectFrom('asset_deletion_tombstone')
          .selectAll()
          .where('ownerId', '=', f.user.id)
          .orderBy('assetId')
          .execute(),
      ).toEqual(before);
      // The declared media paths do not exist. A successful diagnostic therefore
      // cannot have opened, hashed, renamed, recreated or unlinked either original.
      expect(await db.selectFrom('asset').select('id').where('ownerId', '=', f.user.id).execute()).toHaveLength(2);
    },
  );

  it('refuses an ordinary read-write session before reading operation data', async () => {
    const f = await fixture();
    await expect(
      collectDatabaseDiagnostics(db, { AssetRepository, StorageCore, StorageFolder, sql }, [
        f.still.id,
        f.motion.id,
        f.user.id,
      ]),
    ).rejects.toMatchObject({ code: 'READ_ONLY_NOT_CONFIRMED' });
  });
});
