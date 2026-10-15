import { createHash } from 'node:crypto';
import { mkdtemp, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { type RecoveryEvidence, createRecoveryProof } from 'src/utils/recovery-evidence.js';

const sha256 = (value: string | Buffer): string => createHash('sha256').update(value).digest('hex');

/** Disposable, filesystem-bound evidence for medium tests; never points at real media. */
export const makeRecoveryProof = async (root: string): Promise<{ proof: string; cleanup: () => Promise<void> }> => {
  const directory = await mkdtemp(join(tmpdir(), 'gallery-test-recovery-'));
  const backup = join(directory, 'backup.sql.gz');
  const receipt = join(directory, 'backup-verified.json');
  const backupBytes = Buffer.from('synthetic disposable recovery backup');
  await writeFile(backup, backupBytes);
  const checkedAt = new Date().toISOString();
  const receiptValue = {
    assetCount: 1,
    backupSHA256: sha256(backupBytes),
    backupModifiedAt: checkedAt,
    backupPath: backup,
    checkedAt,
    migrationCount: 1,
    postgresImage: 'sha256:synthetic-test-postgres',
    productionChanged: false,
    restore: 'PASS_ISOLATED_SQL_TRANSACTION',
  };
  await writeFile(receipt, JSON.stringify(receiptValue));
  const [rootStat, backupStat, receiptStat] = await Promise.all([
    stat(root, { bigint: true }),
    stat(backup, { bigint: true }),
    stat(receipt, { bigint: true }),
  ]);
  const evidence: RecoveryEvidence = {
    version: 1,
    roots: [{ path: root, device: String(rootStat.dev), inode: String(rootStat.ino) }],
    backup: {
      path: backup,
      device: String(backupStat.dev),
      inode: String(backupStat.ino),
      sha256: sha256(backupBytes),
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
      backupSha256: sha256(backupBytes),
      verified: true,
      verifiedAt: checkedAt,
      validation: 'PASS_ISOLATED_SQL_TRANSACTION',
    },
  };
  return { proof: createRecoveryProof(evidence), cleanup: () => rm(directory, { recursive: true, force: true }) };
};
