import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  createRecoveryProof,
  type RecoveryEvidence,
  verifyRecoveryProof,
} from 'src/utils/recovery-evidence.js';

const sha256 = (value: string | Buffer) => createHash('sha256').update(value).digest('hex');

let base: string;
let root: string;
let backup: string;
let receipt: string;
beforeEach(async () => {
  base = await mkdtemp(join(tmpdir(), 'gallery-recovery-evidence-'));
  root = join(base, 'managed');
  backup = join(base, 'db.sql.gz');
  receipt = join(base, 'backup-verified.json');
  await mkdir(root);
  await writeFile(backup, 'disposable database backup');
  await writeFile(
    receipt,
    JSON.stringify({
      assetCount: 1,
      backupSHA256: sha256('disposable database backup'),
      backupModifiedAt: new Date().toISOString(),
      backupPath: backup,
      checkedAt: new Date().toISOString(),
      migrationCount: 1,
      postgresImage: 'sha256:disposable',
      productionChanged: false,
      restore: 'PASS_ISOLATED_SQL_TRANSACTION',
    }),
  );
});
afterEach(async () => rm(base, { recursive: true, force: true }));

const makeEvidence = async (): Promise<RecoveryEvidence> => {
  const checkedAt = new Date().toISOString();
  const receiptValue = {
    assetCount: 1,
    backupSHA256: sha256('disposable database backup'),
    backupModifiedAt: new Date().toISOString(),
    backupPath: backup,
    checkedAt,
    migrationCount: 1,
    postgresImage: 'sha256:disposable',
    productionChanged: false,
    restore: 'PASS_ISOLATED_SQL_TRANSACTION',
  };
  await writeFile(receipt, JSON.stringify(receiptValue));
  const [backupStat, receiptStat, rootStat] = await Promise.all([
    stat(backup, { bigint: true }),
    stat(receipt, { bigint: true }),
    stat(root, { bigint: true }),
  ]);
  return {
    version: 1,
    roots: [{ path: root, device: String(rootStat.dev), inode: String(rootStat.ino) }],
    backup: {
      path: backup,
      device: String(backupStat.dev),
      inode: String(backupStat.ino),
      sha256: sha256('disposable database backup'),
      size: backupStat.size.toString(),
      modified: backupStat.mtimeNs.toString(),
    },
    restore: {
      receipt: {
        path: receipt,
        device: String(receiptStat.dev),
        inode: String(receiptStat.ino),
        sha256: sha256(JSON.stringify(receiptValue)),
        size: receiptStat.size.toString(),
        modified: receiptStat.mtimeNs.toString(),
      },
      backupSha256: sha256('disposable database backup'),
      verified: true,
      verifiedAt: checkedAt,
      validation: 'PASS_ISOLATED_SQL_TRANSACTION',
    },
  };
};

describe('recovery evidence verification', () => {
  it('accepts a current backup plus an independently verified restore receipt', async () => {
    const evidence = await makeEvidence();
    await expect(verifyRecoveryProof(createRecoveryProof(evidence), [root])).resolves.toBeUndefined();
  });

  it('rejects the old arbitrary 64-character digest', async () => {
    await expect(verifyRecoveryProof('a'.repeat(64), [root])).rejects.toMatchObject({
      code: 'RECOVERY_EVIDENCE_FORMAT_INVALID',
    });
  });

  it('rejects a tampered token payload even when its envelope looks valid', async () => {
    const evidence = await makeEvidence();
    const proof = createRecoveryProof(evidence);
    const tampered = `${proof.slice(0, -1)}${proof.endsWith('0') ? '1' : '0'}`;
    await expect(verifyRecoveryProof(tampered, [root])).rejects.toMatchObject({
      code: 'RECOVERY_EVIDENCE_DIGEST_INVALID',
    });
  });

  it('rejects a proof when the backup bytes no longer match', async () => {
    const evidence = await makeEvidence();
    await writeFile(backup, 'replacement backup');
    await expect(verifyRecoveryProof(createRecoveryProof(evidence), [root])).rejects.toMatchObject({
      code: 'RECOVERY_BACKUP_HASH_MISMATCH',
    });
  });

  it('rejects backup existence without a successful restore receipt', async () => {
    const evidence = await makeEvidence();
    const receiptValue = {
      assetCount: 1,
      backupSHA256: evidence.backup.sha256,
      backupModifiedAt: new Date().toISOString(),
      backupPath: backup,
      checkedAt: new Date().toISOString(),
      migrationCount: 1,
      postgresImage: 'sha256:disposable',
      productionChanged: false,
      restore: 'BACKUP_EXISTS_ONLY',
    };
    await writeFile(receipt, JSON.stringify(receiptValue));
    const receiptStat = await stat(receipt, { bigint: true });
    evidence.restore.receipt = {
      path: receipt,
      device: String(receiptStat.dev),
      inode: String(receiptStat.ino),
      sha256: sha256(JSON.stringify(receiptValue)),
      size: receiptStat.size.toString(),
      modified: receiptStat.mtimeNs.toString(),
    };
    await expect(verifyRecoveryProof(createRecoveryProof(evidence), [root])).rejects.toMatchObject({
      code: 'RECOVERY_RESTORE_NOT_VERIFIED',
    });
  });

  it('rejects stale restore evidence', async () => {
    const evidence = await makeEvidence();
    const stale = new Date(Date.now() - 2 * 24 * 60 * 60 * 1000).toISOString();
    const receiptValue = {
      assetCount: 1,
      backupSHA256: evidence.backup.sha256,
      backupModifiedAt: stale,
      backupPath: backup,
      checkedAt: stale,
      migrationCount: 1,
      postgresImage: 'sha256:disposable',
      productionChanged: false,
      restore: 'PASS_ISOLATED_SQL_TRANSACTION',
    };
    await writeFile(receipt, JSON.stringify(receiptValue));
    const receiptStat = await stat(receipt, { bigint: true });
    evidence.restore.receipt = {
      path: receipt,
      device: String(receiptStat.dev),
      inode: String(receiptStat.ino),
      sha256: sha256(JSON.stringify(receiptValue)),
      size: receiptStat.size.toString(),
      modified: receiptStat.mtimeNs.toString(),
    };
    evidence.restore.verifiedAt = stale;
    await expect(verifyRecoveryProof(createRecoveryProof(evidence), [root])).rejects.toMatchObject({
      code: 'RECOVERY_EVIDENCE_STALE',
    });
  });

  it('rejects a proof bound to a different root identity', async () => {
    const evidence = await makeEvidence();
    await expect(verifyRecoveryProof(createRecoveryProof(evidence), [join(base, 'other')])).rejects.toMatchObject({
      code: 'RECOVERY_ROOT_UNAVAILABLE',
    });
  });
});
