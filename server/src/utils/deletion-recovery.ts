import { createHash, createPublicKey, verify } from 'node:crypto';
import { constants } from 'node:fs';
import fs, { type FileHandle } from 'node:fs/promises';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import type { DeletionRootIdentity } from 'src/schema/tables/asset-deletion.table.js';
import { DeletionError, validQuarantineIdentity } from 'src/utils/authorized-deletion.js';

const MAX_AGE = 24 * 60 * 60 * 1000;
const SHA256 = /^[a-f\d]{64}$/;
const ROOT_KEYS = [
  'path',
  'device',
  'inode',
  'mountId',
  'mountNamespace',
  'mountType',
  'mountSource',
  'mountRoot',
  'mountTarget',
] as const;

export interface DeletionRecoveryEvidence {
  version: 1;
  ownerId: string;
  scope: string;
  roots: DeletionRootIdentity[];
  verifiedAt: string;
  expiresAt: string;
  postgres: {
    backupSHA256: string;
    receiptSHA256: string;
    checkedAt: string;
    restore: 'PASS_ISOLATED_SQL_TRANSACTION';
    productionChanged: false;
    assetCount: number;
    migrationCount: number;
    postgresImage: string;
  };
  mounts: Record<
    string,
    {
      snapshotReferenceSHA256: string;
      snapshotProvenanceSHA256: string;
      verifiedAt: string;
      samples: { kind: 'photo' | 'video'; sha256: string; size: number }[];
    }
  >;
}

function requireEvidence(value: unknown, code = 'DELETION_RECOVERY_INVALID'): asserts value {
  if (!value) {
    throw new DeletionError(code);
  }
}

function record(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function exactKeys(value: Record<string, unknown>, keys: readonly string[]) {
  return Object.keys(value).length === keys.length && keys.every((key) => Object.hasOwn(value, key));
}

function nonempty(value: unknown): value is string {
  return typeof value === 'string' && value.length > 0 && value.length <= 4096 && !value.includes('\0');
}

function positiveInteger(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value > 0;
}

function hash(value: unknown): value is string {
  return typeof value === 'string' && SHA256.test(value);
}

function timestamp(value: unknown) {
  requireEvidence(
    typeof value === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|\+00:00)$/.test(value),
  );
  const result = Date.parse(value);
  requireEvidence(Number.isFinite(result) && new Date(result).toISOString().slice(0, 19) === value.slice(0, 19));
  return result;
}

function fresh(value: unknown, now: number, verifiedAt: number) {
  const time = timestamp(value);
  requireEvidence(time <= now && time <= verifiedAt);
  requireEvidence(time > now - MAX_AGE, 'DELETION_RECOVERY_EXPIRED');
  return time;
}

function rootIdentity(value: unknown): value is DeletionRootIdentity {
  return (
    record(value) &&
    exactKeys(value, ROOT_KEYS) &&
    ROOT_KEYS.every((key) => nonempty(value[key])) &&
    isAbsolute(value.path as string) &&
    value.path !== '/' &&
    value.path === resolve(value.path as string)
  );
}

function parseJson(bytes: Buffer): unknown {
  const text = bytes.toString('utf8');
  requireEvidence(Buffer.from(text, 'utf8').equals(bytes));
  try {
    return JSON.parse(text);
  } catch {
    throw new DeletionError('DELETION_RECOVERY_INVALID');
  }
}

function base64(value: unknown) {
  requireEvidence(typeof value === 'string' && value.length > 0);
  const bytes = Buffer.from(value, 'base64');
  requireEvidence(bytes.toString('base64') === value);
  return bytes;
}

// The application must have read-only access to BOTH the key and evidence store.
// Checking W_OK does not create a file and also detects read-only bind mounts.
async function readOnlyMount(path: string, opened?: FileHandle) {
  requireEvidence(process.platform === 'linux');
  const handle = opened ?? (await fs.open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK));
  try {
    const info = await fs.readFile(`/proc/self/fdinfo/${handle.fd}`, 'utf8');
    const mountId = /^mnt_id:\s*(\d+)$/m.exec(info)?.[1];
    const mounts = await fs.readFile('/proc/self/mountinfo', 'utf8');
    const row = mounts.split('\n').find((row) => row.startsWith(`${mountId} `));
    requireEvidence(mountId && row);
    const [left, right] = row.split(' - ', 2);
    const mountOptions = left.split(' ', 6)[5];
    const superOptions = right?.split(' ', 3)[2];
    requireEvidence(mountOptions && superOptions);
    return mountOptions.split(',').includes('ro') || superOptions.split(',').includes('ro');
  } finally {
    if (!opened) {
      await handle.close();
    }
  }
}

async function denyWritable(path: string, opened?: FileHandle) {
  try {
    await fs.access(path, constants.W_OK);
  } catch (error) {
    if (['EACCES', 'EROFS'].includes((error as NodeJS.ErrnoException).code ?? '')) {
      return (error as NodeJS.ErrnoException).code === 'EROFS' || (await readOnlyMount(path, opened));
    }
    throw error;
  }
  throw new DeletionError('DELETION_RECOVERY_INVALID');
}

async function protectedAncestors(path: string) {
  for (let cursor = dirname(path); ; cursor = dirname(cursor)) {
    const stat = await fs.stat(cursor);
    requireEvidence(stat.isDirectory() && (stat.mode & 0o022) === 0);
    const readOnlyFileSystem = await denyWritable(cursor);
    requireEvidence(readOnlyFileSystem || stat.uid !== process.getuid?.());
    if (readOnlyFileSystem || cursor === '/') {
      return;
    }
  }
}

async function protectedDirectory(path: string) {
  requireEvidence(isAbsolute(path) && path === resolve(path) && path !== '/');
  requireEvidence((await fs.realpath(path)) === path);
  const handle = await fs.open(path, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
  try {
    const stat = await handle.stat();
    requireEvidence(stat.isDirectory() && (stat.mode & 0o022) === 0);
    const readOnlyFileSystem = await denyWritable(path, handle);
    // A process can chmod a directory it owns, even when W_OK currently fails.
    requireEvidence(readOnlyFileSystem || stat.uid !== process.getuid?.());
    if (!readOnlyFileSystem) {
      await protectedAncestors(path);
    }
    return handle;
  } catch (error) {
    await handle.close();
    throw error;
  }
}

async function protectedFile(path: string, maximum: number) {
  requireEvidence(isAbsolute(path) && path === resolve(path));
  requireEvidence((await fs.realpath(path)) === path);
  const directory = await protectedDirectory(dirname(path));
  try {
    const handle = await fs.open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    try {
      const readOnlyFileSystem = await denyWritable(path, handle);
      const before = await handle.stat({ bigint: true });
      requireEvidence(
        before.isFile() &&
          before.nlink === 1n &&
          (before.mode & 0o022n) === 0n &&
          before.size > 0n &&
          before.size <= BigInt(maximum) &&
          (readOnlyFileSystem || before.uid !== BigInt(process.getuid?.() ?? -1)),
      );
      const bytes = await handle.readFile();
      const after = await handle.stat({ bigint: true });
      requireEvidence(
        before.size === BigInt(bytes.length) &&
          before.size === after.size &&
          before.mtimeNs === after.mtimeNs &&
          before.ctimeNs === after.ctimeNs,
      );
      return bytes;
    } finally {
      await handle.close();
    }
  } finally {
    await directory.close();
  }
}

function validateReport(report: unknown, ownerId: string, scope: string, roots: DeletionRootIdentity[], now: number) {
  requireEvidence(record(report));
  requireEvidence(
    exactKeys(report, ['version', 'ownerId', 'scope', 'roots', 'verifiedAt', 'expiresAt', 'postgres', 'mounts']) &&
      report.version === 1 &&
      nonempty(report.ownerId) &&
      nonempty(report.scope),
  );
  requireEvidence(report.ownerId === ownerId && report.scope === scope, 'DELETION_RECOVERY_SCOPE_MISMATCH');
  requireEvidence(Array.isArray(report.roots) && report.roots.length > 0 && report.roots.length <= 128);
  requireEvidence(report.roots.every(rootIdentity));
  const reportedRoots = new Map<string, DeletionRootIdentity>(report.roots.map((root) => [root.path, root]));
  requireEvidence(reportedRoots.size === report.roots.length);
  requireEvidence(
    roots.length === reportedRoots.size &&
      new Set(roots.map((root) => root.path)).size === roots.length &&
      roots.every((root) => {
        const reported = reportedRoots.get(root.path);
        const { quarantineIdentity, ...storage } = root;
        return (
          rootIdentity(storage) &&
          (quarantineIdentity === undefined || validQuarantineIdentity(quarantineIdentity)) &&
          reported &&
          ROOT_KEYS.every((key) => reported[key] === root[key])
        );
      }),
    'DELETION_ROOT_CHANGED',
  );
  const verifiedAt = fresh(report.verifiedAt, now, now);
  const expiresAt = timestamp(report.expiresAt);
  requireEvidence(expiresAt > verifiedAt && expiresAt <= verifiedAt + MAX_AGE);
  requireEvidence(expiresAt > now, 'DELETION_RECOVERY_EXPIRED');
  const postgres = report.postgres;
  requireEvidence(
    record(postgres) &&
      exactKeys(postgres, [
        'backupSHA256',
        'receiptSHA256',
        'checkedAt',
        'restore',
        'productionChanged',
        'assetCount',
        'migrationCount',
        'postgresImage',
      ]) &&
      hash(postgres.backupSHA256) &&
      hash(postgres.receiptSHA256) &&
      postgres.restore === 'PASS_ISOLATED_SQL_TRANSACTION' &&
      postgres.productionChanged === false &&
      positiveInteger(postgres.assetCount) &&
      positiveInteger(postgres.migrationCount) &&
      typeof postgres.postgresImage === 'string' &&
      /^sha256:[a-f\d]{64}$/.test(postgres.postgresImage),
  );
  const restoredAt = fresh(postgres.checkedAt, now, verifiedAt);
  requireEvidence(expiresAt <= restoredAt + MAX_AGE);
  requireEvidence(record(report.mounts) && exactKeys(report.mounts, reportedRoots.keys().toArray()));
  for (const mount of Object.values(report.mounts)) {
    requireEvidence(
      record(mount) &&
        exactKeys(mount, ['snapshotReferenceSHA256', 'snapshotProvenanceSHA256', 'verifiedAt', 'samples']) &&
        hash(mount.snapshotReferenceSHA256) &&
        hash(mount.snapshotProvenanceSHA256),
    );
    const exportedAt = fresh(mount.verifiedAt, now, verifiedAt);
    requireEvidence(expiresAt <= exportedAt + MAX_AGE);
    requireEvidence(Array.isArray(mount.samples) && mount.samples.length >= 2 && mount.samples.length <= 128);
    const kinds = new Set<string>();
    for (const sample of mount.samples) {
      requireEvidence(
        record(sample) &&
          exactKeys(sample, ['kind', 'sha256', 'size']) &&
          (sample.kind === 'photo' || sample.kind === 'video') &&
          hash(sample.sha256) &&
          positiveInteger(sample.size),
      );
      kinds.add(sample.kind);
    }
    requireEvidence(kinds.size === 2);
  }
  return new Date(expiresAt).toISOString();
}

/** Re-read the local trust store on every call, including immediately before unlink. */
export async function verifyRecoveryEvidence(
  digest: string,
  ownerId: string,
  scope: string,
  roots: DeletionRootIdentity[],
): Promise<{ digest: string; expiresAt: string }> {
  requireEvidence(hash(digest));
  try {
    const evidenceDirectory = process.env.GALLERY_DELETION_RECOVERY_DIR ?? '/run/gallery-deletion-recovery/evidence';
    const publicKeyPath =
      process.env.GALLERY_DELETION_RECOVERY_PUBLIC_KEY ?? '/run/gallery-deletion-recovery/public.pem';
    const bytes = await protectedFile(join(evidenceDirectory, `${digest}.json`), 1024 * 1024);
    requireEvidence(createHash('sha256').update(bytes).digest('hex') === digest);
    const envelope = parseJson(bytes);
    requireEvidence(
      record(envelope) &&
        exactKeys(envelope, ['version', 'algorithm', 'payload', 'signature']) &&
        envelope.version === 1 &&
        envelope.algorithm === 'Ed25519',
    );
    const payload = base64(envelope.payload);
    const signature = base64(envelope.signature);
    requireEvidence(signature.length === 64);
    const publicKeyBytes = await protectedFile(publicKeyPath, 64 * 1024);
    let publicKey;
    try {
      publicKey = createPublicKey(publicKeyBytes);
    } catch {
      throw new DeletionError('DELETION_RECOVERY_INVALID');
    }
    requireEvidence(publicKey.asymmetricKeyType === 'ed25519' && verify(null, payload, publicKey, signature));
    const expiresAt = validateReport(parseJson(payload), ownerId, scope, roots, Date.now());
    return { digest, expiresAt };
  } catch (error) {
    if (error instanceof DeletionError) {
      throw error;
    }
    throw new DeletionError('DELETION_RECOVERY_UNAVAILABLE');
  }
}
