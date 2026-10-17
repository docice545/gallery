import { createHash, generateKeyPairSync, sign } from 'node:crypto';
import { constants } from 'node:fs';
import fs from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { vi } from 'vitest';
import type { DeletionRootIdentity } from 'src/schema/tables/asset-deletion.table.js';
import type { DeletionRecoveryEvidence } from 'src/utils/deletion-recovery.js';

/** Synthetic reports signed with a disposable key; production verification remains enabled. */
export async function createTestRecoveryEvidenceStore() {
  const directory = await fs.mkdtemp(join(tmpdir(), 'gallery-test-recovery-'));
  const evidence = join(directory, 'evidence');
  const publicKeyFile = join(directory, 'public.pem');
  const key = generateKeyPairSync('ed25519');
  const previousDirectory = process.env.GALLERY_DELETION_RECOVERY_DIR;
  const previousKey = process.env.GALLERY_DELETION_RECOVERY_PUBLIC_KEY;
  await fs.mkdir(evidence, { mode: 0o555 });
  await fs.writeFile(publicKeyFile, key.publicKey.export({ type: 'spki', format: 'pem' }), { mode: 0o444 });
  await fs.chmod(directory, 0o555);
  process.env.GALLERY_DELETION_RECOVERY_DIR = evidence;
  process.env.GALLERY_DELETION_RECOVERY_PUBLIC_KEY = publicKeyFile;
  const actualAccess = fs.access;
  // The test fixture cannot mount :ro without privileges. Simulate only that
  // filesystem boundary; root/media access and recovery verification stay real.
  const access = vi.spyOn(fs, 'access').mockImplementation(async (path, mode) => {
    if (String(path).startsWith(`${directory}/`) && mode === constants.W_OK) {
      throw Object.assign(new Error('Synthetic read-only mount'), { code: 'EROFS' });
    }
    if (String(path) === directory && mode === constants.W_OK) {
      throw Object.assign(new Error('Synthetic read-only mount'), { code: 'EROFS' });
    }
    await actualAccess(path, mode);
  });

  return {
    async install(ownerId: string, scope: string, roots: DeletionRootIdentity[]) {
      const now = Date.now();
      const checkedAt = new Date(now - 1000).toISOString();
      const expiresAt = new Date(now + 60 * 60 * 1000).toISOString();
      const report: DeletionRecoveryEvidence = {
        version: 1,
        ownerId,
        scope,
        roots,
        verifiedAt: new Date(now).toISOString(),
        expiresAt,
        postgres: {
          backupSHA256: createHash('sha256').update('synthetic backup fixture').digest('hex'),
          receiptSHA256: createHash('sha256').update('synthetic completed isolated restore receipt').digest('hex'),
          checkedAt,
          restore: 'PASS_ISOLATED_SQL_TRANSACTION',
          productionChanged: false,
          assetCount: 1,
          migrationCount: 1,
          postgresImage: `sha256:${'a'.repeat(64)}`,
        },
        mounts: Object.fromEntries(
          roots.map((root) => [
            root.path,
            {
              snapshotReferenceSHA256: createHash('sha256').update(`synthetic snapshot:${root.path}`).digest('hex'),
              snapshotProvenanceSHA256: createHash('sha256').update(`synthetic export:${root.path}`).digest('hex'),
              verifiedAt: checkedAt,
              samples: [
                {
                  kind: 'photo' as const,
                  sha256: createHash('sha256').update('synthetic photo').digest('hex'),
                  size: 15,
                },
                {
                  kind: 'video' as const,
                  sha256: createHash('sha256').update('synthetic video').digest('hex'),
                  size: 15,
                },
              ],
            },
          ]),
        ),
      };
      const payload = Buffer.from(JSON.stringify(report));
      const envelope = Buffer.from(
        JSON.stringify({
          version: 1,
          algorithm: 'Ed25519',
          payload: payload.toString('base64'),
          signature: sign(null, payload, key.privateKey).toString('base64'),
        }),
      );
      const digest = createHash('sha256').update(envelope).digest('hex');
      await fs.chmod(evidence, 0o700);
      try {
        await fs.writeFile(join(evidence, `${digest}.json`), envelope, { mode: 0o444, flag: 'wx' });
      } finally {
        await fs.chmod(evidence, 0o555);
      }
      return { digest, expiresAt };
    },
    async cleanup() {
      access.mockRestore();
      if (previousDirectory === undefined) {
        delete process.env.GALLERY_DELETION_RECOVERY_DIR;
      } else {
        process.env.GALLERY_DELETION_RECOVERY_DIR = previousDirectory;
      }
      if (previousKey === undefined) {
        delete process.env.GALLERY_DELETION_RECOVERY_PUBLIC_KEY;
      } else {
        process.env.GALLERY_DELETION_RECOVERY_PUBLIC_KEY = previousKey;
      }
      await fs.chmod(directory, 0o700);
      await fs.chmod(evidence, 0o700);
      await fs.rm(directory, { recursive: true, force: true });
    },
  };
}

export async function installTestRecoveryEvidence(ownerId: string, scope: string, roots: DeletionRootIdentity[]) {
  const store = await createTestRecoveryEvidenceStore();
  try {
    return { ...(await store.install(ownerId, scope, roots)), cleanup: store.cleanup };
  } catch (error) {
    await store.cleanup();
    throw error;
  }
}
