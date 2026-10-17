import { createHash, timingSafeEqual } from 'node:crypto';
import { createReadStream } from 'node:fs';
import fs from 'node:fs/promises';
import type { FileHandle } from 'node:fs/promises';
import { isAbsolute, relative, resolve, sep } from 'node:path';
import { DeletionError } from 'src/utils/authorized-deletion.js';

/**
 * A recovery proof is deliberately an opaque, self-contained token.  It is not
 * a caller supplied checksum: the token names the exact backup and restore
 * receipt, while verification below re-reads both files and the selected roots.
 *
 * The receipt is produced by the isolated restore check (see the release
 * tooling).  `restore.verified` alone is never trusted; the receipt bytes,
 * backup digest, and freshness are checked again by the server.
 */
export const RECOVERY_PROOF_PREFIX = 'gallery-recovery-v1';
const MAX_PROOF_LENGTH = 64 * 1024;
const MAX_EVIDENCE_AGE_MS = 24 * 60 * 60 * 1000;
const MAX_CLOCK_SKEW_MS = 5 * 60 * 1000;
const SHA256 = /^[a-f0-9]{64}$/;
type BigIntStat = Awaited<ReturnType<FileHandle['stat']>>;

export type RecoveryRootEvidence = {
  path: string;
  device: string;
  inode: string;
};

export type RecoveryFileEvidence = {
  path: string;
  device: string;
  inode: string;
  sha256: string;
  size: string;
  modified: string;
};

export type RecoveryEvidence = {
  version: 1;
  roots: RecoveryRootEvidence[];
  backup: RecoveryFileEvidence;
  restore: {
    receipt: RecoveryFileEvidence;
    backupSha256: string;
    verified: true;
    verifiedAt: string;
    validation: 'PASS_ISOLATED_SQL_TRANSACTION';
  };
};

const fail = (code: string): never => {
  throw new DeletionError(code);
};

const isRecord = (value: unknown): value is Record<string, unknown> =>
  !!value && typeof value === 'object' && !Array.isArray(value);

const isString = (value: unknown): value is string => typeof value === 'string';

const isNonNegativeInteger = (value: string): boolean => /^(0|[1-9][0-9]*)$/.test(value);

const assertSha256 = (value: unknown, code: string): string => {
  if (!isString(value) || !SHA256.test(value)) {
    return fail(code);
  }
  return value;
};

const assertAbsolutePath = (value: unknown, code: string): string => {
  if (!isString(value) || !isAbsolute(value) || value !== resolve(value) || value.includes('\0')) {
    return fail(code);
  }
  return value;
};

const parseDate = (value: unknown, code: string): Date => {
  if (!isString(value)) {
    return fail(code);
  }
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) {
    fail(code);
  }
  return date;
};

const stableJson = (value: unknown): string => {
  if (Array.isArray(value)) {
    return `[${value.map((item) => stableJson(item)).join(',')}]`;
  }
  if (isRecord(value)) {
    return `{${Object.keys(value)
      .toSorted()
      .map((key) => `${JSON.stringify(key)}:${stableJson(value[key])}`)
      .join(',')}}`;
  }
  return JSON.stringify(value) ?? 'null';
};

const digest = (value: string): string => createHash('sha256').update(value).digest('hex');

const encode = (value: string): string => Buffer.from(value).toString('base64url');
const decode = (value: string): string => {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) {
    fail('RECOVERY_EVIDENCE_FORMAT_INVALID');
  }
  try {
    return Buffer.from(value, 'base64url').toString('utf8');
  } catch {
    return fail('RECOVERY_EVIDENCE_FORMAT_INVALID');
  }
};

/** Create a token from a recovery receipt assembled by an isolated verifier. */
export const createRecoveryProof = (evidence: RecoveryEvidence): string => {
  const payload = stableJson(evidence);
  return `${RECOVERY_PROOF_PREFIX}.${encode(payload)}.${digest(payload)}`;
};

const parseProof = (proof: string): unknown => {
  if (!isString(proof) || proof.length > MAX_PROOF_LENGTH) {
    fail('RECOVERY_EVIDENCE_FORMAT_INVALID');
  }
  const parts = proof.split('.');
  if (parts.length !== 3 || parts[0] !== RECOVERY_PROOF_PREFIX || !SHA256.test(parts[2])) {
    fail('RECOVERY_EVIDENCE_FORMAT_INVALID');
  }
  const payload = decode(parts[1]);
  const actualDigest = digest(payload);
  const expected = Buffer.from(parts[2], 'hex');
  const actual = Buffer.from(actualDigest, 'hex');
  if (!timingSafeEqual(actual, expected)) {
    fail('RECOVERY_EVIDENCE_DIGEST_INVALID');
  }

  let raw: unknown;
  try {
    raw = JSON.parse(payload);
  } catch {
    fail('RECOVERY_EVIDENCE_FORMAT_INVALID');
  }
  if (stableJson(raw) !== payload || !isRecord(raw) || raw.version !== 1) {
    fail('RECOVERY_EVIDENCE_FORMAT_INVALID');
  }
  return raw;
};

const fileEvidence = (value: unknown, code: string): RecoveryFileEvidence => {
  const record = isRecord(value) ? value : fail(code);
  const path = assertAbsolutePath(record.path, code);
  if (
    !isString(record.device) ||
    !isString(record.inode) ||
    !/^\d+$/.test(record.device) ||
    !/^\d+$/.test(record.inode)
  ) {
    return fail(code);
  }
  const sha256 = assertSha256(record.sha256, code);
  if (!isString(record.size) || !isNonNegativeInteger(record.size) || !isString(record.modified)) {
    return fail(code);
  }
  return {
    path,
    device: record.device,
    inode: record.inode,
    sha256,
    size: record.size,
    modified: record.modified,
  };
};

const rootEvidence = (value: unknown): RecoveryRootEvidence => {
  const record = isRecord(value) ? value : fail('RECOVERY_ROOT_EVIDENCE_INVALID');
  const path = assertAbsolutePath(record.path, 'RECOVERY_ROOT_EVIDENCE_INVALID');
  if (
    !isString(record.device) ||
    !isString(record.inode) ||
    !/^\d+$/.test(record.device) ||
    !/^\d+$/.test(record.inode)
  ) {
    return fail('RECOVERY_ROOT_EVIDENCE_INVALID');
  }
  return { path, device: record.device, inode: record.inode };
};

const parseEvidence = (raw: unknown): RecoveryEvidence => {
  const record = isRecord(raw) ? raw : fail('RECOVERY_ROOT_EVIDENCE_INVALID');
  if (record.version !== 1 || !Array.isArray(record.roots) || record.roots.length === 0 || record.roots.length > 128) {
    return fail('RECOVERY_ROOT_EVIDENCE_INVALID');
  }
  const roots = record.roots.map(rootEvidence);
  const backup = fileEvidence(record.backup, 'RECOVERY_BACKUP_EVIDENCE_INVALID');
  const restore = isRecord(record.restore) ? record.restore : fail('RECOVERY_RESTORE_NOT_VERIFIED');
  if (restore.verified !== true || restore.validation !== 'PASS_ISOLATED_SQL_TRANSACTION') {
    return fail('RECOVERY_RESTORE_NOT_VERIFIED');
  }
  const backupSha256 = assertSha256(restore.backupSha256, 'RECOVERY_RESTORE_EVIDENCE_INVALID');
  const verifiedAt = parseDate(restore.verifiedAt, 'RECOVERY_RESTORE_EVIDENCE_INVALID');
  const receipt = fileEvidence(restore.receipt, 'RECOVERY_RESTORE_EVIDENCE_INVALID');
  return {
    version: 1,
    roots,
    backup,
    restore: {
      receipt,
      backupSha256,
      verified: true,
      verifiedAt: verifiedAt.toISOString(),
      validation: 'PASS_ISOLATED_SQL_TRANSACTION',
    },
  };
};

const isBelow = (root: string, file: string): boolean => {
  const part = relative(root, file);
  return part !== '' && part !== '..' && !part.startsWith(`..${sep}`) && !isAbsolute(part);
};

const assertFresh = (value: Date, code: string): void => {
  const age = Date.now() - value.getTime();
  if (age > MAX_EVIDENCE_AGE_MS || age < -MAX_CLOCK_SKEW_MS) {
    fail(code);
  }
};

const hashFile = async (
  path: string,
): Promise<{ sha256: string; device: bigint; inode: bigint; size: bigint; modified: bigint }> => {
  let real: string;
  try {
    real = await fs.realpath(path);
  } catch {
    return fail('RECOVERY_EVIDENCE_FILE_UNAVAILABLE');
  }
  if (real !== path) {
    fail('RECOVERY_EVIDENCE_FILE_NOT_CANONICAL');
  }
  let stat: BigIntStat;
  try {
    stat = await fs.stat(path, { bigint: true });
  } catch {
    return fail('RECOVERY_EVIDENCE_FILE_UNAVAILABLE');
  }
  if (!stat.isFile() || stat.nlink !== 1n) {
    fail('RECOVERY_EVIDENCE_FILE_INVALID');
  }
  const before = stat;
  const hash = createHash('sha256');
  try {
    for await (const chunk of createReadStream(path)) {
      hash.update(chunk);
    }
  } catch {
    return fail('RECOVERY_EVIDENCE_FILE_UNAVAILABLE');
  }
  let after: BigIntStat;
  try {
    after = await fs.stat(path, { bigint: true });
  } catch {
    return fail('RECOVERY_EVIDENCE_FILE_UNAVAILABLE');
  }
  if (
    !after.isFile() ||
    after.nlink !== 1n ||
    before.size !== after.size ||
    before.mtimeNs !== after.mtimeNs ||
    before.ctimeNs !== after.ctimeNs
  ) {
    fail('RECOVERY_EVIDENCE_FILE_CHANGED');
  }
  return {
    sha256: hash.digest('hex'),
    device: after.dev,
    inode: after.ino,
    size: after.size,
    modified: after.mtimeNs,
  };
};

const assertFileMatches = async (file: RecoveryFileEvidence, kind: 'backup' | 'receipt'): Promise<void> => {
  const actual = await hashFile(file.path);
  if (
    actual.sha256 !== file.sha256 ||
    actual.device.toString() !== file.device ||
    actual.inode.toString() !== file.inode ||
    actual.size.toString() !== file.size ||
    actual.modified.toString() !== file.modified
  ) {
    fail(kind === 'backup' ? 'RECOVERY_BACKUP_CHANGED' : 'RECOVERY_RESTORE_EVIDENCE_CHANGED');
  }
};

const readJson = async (path: string, code: string): Promise<Record<string, unknown>> => {
  try {
    const value: unknown = JSON.parse(await fs.readFile(path, 'utf8'));
    if (!isRecord(value)) {
      return fail(code);
    }
    return value;
  } catch (error) {
    if (error instanceof DeletionError) {
      throw error;
    }
    return fail(code);
  }
};

/**
 * Verify a proof against the roots that will be authorized for deletion.
 * Every check is repeated at consent time, so a proof cannot be replayed after
 * a root replacement, backup rewrite, or restore receipt expiry.
 */
export const verifyRecoveryProof = async (proof: string, authorizedRoots: string[]): Promise<void> => {
  const evidence = parseProof(proof);
  const normalized = parseEvidence(evidence);
  if (authorizedRoots.length === 0 || normalized.roots.length !== authorizedRoots.length) {
    fail('RECOVERY_ROOT_MISMATCH');
  }

  const expected = new Set<string>();
  for (const root of authorizedRoots) {
    const absoluteRoot = assertAbsolutePath(root, 'RECOVERY_ROOT_MISMATCH');
    if (absoluteRoot === '/' || (await fs.realpath(absoluteRoot).catch(() => '')) !== absoluteRoot) {
      fail('RECOVERY_ROOT_UNAVAILABLE');
    }
    const stat = await fs.stat(absoluteRoot, { bigint: true }).catch(() => undefined);
    if (!stat) {
      return fail('RECOVERY_ROOT_UNAVAILABLE');
    }
    if (!stat.isDirectory()) {
      fail('RECOVERY_ROOT_UNAVAILABLE');
    }
    const key = `${absoluteRoot}\0${stat.dev}\0${stat.ino}`;
    expected.add(key);
  }

  const actual = new Set<string>();
  for (const root of normalized.roots) {
    const key = `${root.path}\0${root.device}\0${root.inode}`;
    if (actual.has(key)) {
      fail('RECOVERY_ROOT_EVIDENCE_INVALID');
    }
    actual.add(key);
  }
  if (actual.size !== expected.size || [...expected].some((key) => !actual.has(key))) {
    fail('RECOVERY_ROOT_MISMATCH');
  }

  // A backup or receipt under an authorized deletion root could disappear in
  // the operation it authorizes. Keep recovery evidence in a separate store.
  if (normalized.roots.some(({ path }) => isBelow(path, normalized.backup.path))) {
    fail('RECOVERY_BACKUP_ROOT_OVERLAP');
  }
  if (normalized.roots.some(({ path }) => isBelow(path, normalized.restore.receipt.path))) {
    fail('RECOVERY_RECEIPT_ROOT_OVERLAP');
  }

  const backup = await hashFile(normalized.backup.path);
  if (
    backup.sha256 !== normalized.backup.sha256 ||
    backup.device.toString() !== normalized.backup.device ||
    backup.inode.toString() !== normalized.backup.inode
  ) {
    fail('RECOVERY_BACKUP_HASH_MISMATCH');
  }
  if (backup.size.toString() !== normalized.backup.size || backup.modified.toString() !== normalized.backup.modified) {
    fail('RECOVERY_BACKUP_CHANGED');
  }
  if (normalized.restore.backupSha256 !== normalized.backup.sha256) {
    fail('RECOVERY_RESTORE_BACKUP_MISMATCH');
  }
  await assertFileMatches(normalized.restore.receipt, 'receipt');
  const receipt = await readJson(normalized.restore.receipt.path, 'RECOVERY_RESTORE_EVIDENCE_INVALID');
  if (
    receipt.restore !== 'PASS_ISOLATED_SQL_TRANSACTION' ||
    receipt.backupSHA256 !== normalized.backup.sha256 ||
    receipt.backupPath !== normalized.backup.path ||
    typeof receipt.postgresImage !== 'string' ||
    receipt.postgresImage.length === 0 ||
    typeof receipt.assetCount !== 'number' ||
    !Number.isInteger(receipt.assetCount) ||
    receipt.assetCount <= 0 ||
    typeof receipt.migrationCount !== 'number' ||
    !Number.isInteger(receipt.migrationCount) ||
    receipt.migrationCount <= 0 ||
    receipt.productionChanged !== false
  ) {
    fail('RECOVERY_RESTORE_NOT_VERIFIED');
  }
  assertFresh(parseDate(normalized.restore.verifiedAt, 'RECOVERY_RESTORE_EVIDENCE_INVALID'), 'RECOVERY_EVIDENCE_STALE');
  if (isString(receipt.checkedAt)) {
    assertFresh(parseDate(receipt.checkedAt, 'RECOVERY_RESTORE_EVIDENCE_INVALID'), 'RECOVERY_EVIDENCE_STALE');
  } else {
    fail('RECOVERY_RESTORE_EVIDENCE_INVALID');
  }
  if (isString(receipt.backupModifiedAt)) {
    assertFresh(parseDate(receipt.backupModifiedAt, 'RECOVERY_RESTORE_EVIDENCE_INVALID'), 'RECOVERY_EVIDENCE_STALE');
  } else {
    fail('RECOVERY_RESTORE_EVIDENCE_INVALID');
  }
};

export const isRecoveryProofFormat = (proof: unknown): proof is string => {
  if (!isString(proof) || proof.length > MAX_PROOF_LENGTH) {
    return false;
  }
  const [prefix, encoded, checksum] = proof.split('.');
  return prefix === RECOVERY_PROOF_PREFIX && !!encoded && !!checksum && SHA256.test(checksum);
};
