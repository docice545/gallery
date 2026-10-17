import { execFileSync } from 'node:child_process';
import { type KeyObject, createHash, generateKeyPairSync, sign } from 'node:crypto';
import { constants } from 'node:fs';
import fs from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { DeletionRootIdentity } from 'src/schema/tables/asset-deletion.table.js';
import { type DeletionRecoveryEvidence, verifyRecoveryEvidence } from 'src/utils/deletion-recovery.js';

const NOW = Date.parse('2026-10-10T12:00:00.000Z');
const HOUR = 60 * 60 * 1000;
const iso = (time: number) => new Date(time).toISOString();
const identity: DeletionRootIdentity = {
  path: '/photos/owner',
  device: '123',
  inode: '456',
  mountId: '42',
  mountNamespace: 'mnt:[123456]',
  mountType: 'nfs4',
  mountSource: 'nas:/photos',
  mountRoot: '/',
  mountTarget: '/photos',
};

function report(): DeletionRecoveryEvidence {
  return {
    version: 1,
    ownerId: 'owner',
    scope: 'MANAGED',
    roots: [{ ...identity }],
    verifiedAt: iso(NOW),
    expiresAt: iso(NOW + HOUR),
    postgres: {
      backupSHA256: 'a'.repeat(64),
      receiptSHA256: 'b'.repeat(64),
      checkedAt: iso(NOW - HOUR),
      restore: 'PASS_ISOLATED_SQL_TRANSACTION',
      productionChanged: false,
      assetCount: 2,
      migrationCount: 1,
      postgresImage: `sha256:${'c'.repeat(64)}`,
    },
    mounts: {
      [identity.path]: {
        snapshotReferenceSHA256: 'd'.repeat(64),
        snapshotProvenanceSHA256: 'e'.repeat(64),
        verifiedAt: iso(NOW - HOUR),
        samples: [
          { kind: 'photo', sha256: '1'.repeat(64), size: 1024 },
          { kind: 'video', sha256: '2'.repeat(64), size: 4096 },
        ],
      },
    },
  };
}

let directory: string;
let store: string;
let publicKey: string;
let privateKey: KeyObject;
let writablePaths: Set<string>;
let readOnlyPaths: boolean;

async function publish(value: unknown, signer = privateKey) {
  const payload = Buffer.from(JSON.stringify(value));
  const envelope = Buffer.from(
    JSON.stringify({
      version: 1,
      algorithm: 'Ed25519',
      payload: payload.toString('base64'),
      signature: sign(null, payload, signer).toString('base64'),
    }),
  );
  const digest = createHash('sha256').update(envelope).digest('hex');
  await fs.chmod(store, 0o700);
  await fs.writeFile(join(store, `${digest}.json`), envelope, { mode: 0o444 });
  await fs.chmod(store, 0o555);
  return digest;
}

async function rewrite(digest: string, value: (envelope: Record<string, unknown>) => void) {
  const file = join(store, `${digest}.json`);
  const envelope = JSON.parse(await fs.readFile(file, 'utf8'));
  value(envelope);
  const bytes = Buffer.from(JSON.stringify(envelope));
  const changed = createHash('sha256').update(bytes).digest('hex');
  await fs.chmod(store, 0o700);
  await fs.writeFile(join(store, `${changed}.json`), bytes, { mode: 0o444 });
  await fs.chmod(store, 0o555);
  return changed;
}

beforeEach(async () => {
  directory = await fs.mkdtemp(join(tmpdir(), 'gallery-recovery-test-'));
  store = join(directory, 'evidence');
  publicKey = join(directory, 'public.pem');
  await fs.mkdir(store, { mode: 0o555 });
  const keys = generateKeyPairSync('ed25519');
  privateKey = keys.privateKey;
  await fs.writeFile(publicKey, keys.publicKey.export({ type: 'spki', format: 'pem' }), { mode: 0o444 });
  await fs.chmod(directory, 0o555);
  vi.stubEnv('GALLERY_DELETION_RECOVERY_DIR', store);
  vi.stubEnv('GALLERY_DELETION_RECOVERY_PUBLIC_KEY', publicKey);
  vi.spyOn(Date, 'now').mockReturnValue(NOW);
  writablePaths = new Set();
  readOnlyPaths = true;
  const actualAccess = fs.access;
  // Local fixtures model the EROFS boundary of a read-only bind mount. The
  // report, public key, bytes, hashes and cryptographic checks are all real.
  vi.spyOn(fs, 'access').mockImplementation(async (path, mode) => {
    const file = String(path);
    if (readOnlyPaths && file.startsWith(directory) && mode === constants.W_OK && !writablePaths.has(file)) {
      throw Object.assign(new Error('Synthetic read-only mount'), { code: 'EROFS' });
    }
    await actualAccess(path, mode);
  });
});

afterEach(async () => {
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
  await fs.chmod(directory, 0o700);
  await fs.chmod(store, 0o700);
  await fs.rm(directory, { recursive: true, force: true });
});

describe('trusted recovery evidence for original deletion', () => {
  it('verifies exact signed bytes from a read-only local store', async () => {
    const digest = await publish(report());
    await expect(verifyRecoveryEvidence(digest, 'owner', 'MANAGED', [identity])).resolves.toEqual({
      digest,
      expiresAt: iso(NOW + HOUR),
    });
  });

  it('keeps the signed storage identity valid when a trusted quarantine binding is added', async () => {
    const digest = await publish(report());
    const bound: DeletionRootIdentity = {
      ...identity,
      quarantineIdentity: {
        device: identity.device,
        inode: '789',
        mountId: identity.mountId,
        mountNamespace: identity.mountNamespace,
        uid: '1024',
        gid: '100',
      },
    };
    await expect(verifyRecoveryEvidence(digest, 'owner', 'MANAGED', [bound])).resolves.toHaveProperty('digest', digest);
    // Only optional, structurally valid registry metadata may accompany the
    // nine signed storage fields. It cannot substitute for signed evidence.
    await expect(
      verifyRecoveryEvidence(digest, 'owner', 'MANAGED', [{ ...bound, device: '999' }]),
    ).rejects.toMatchObject({ code: 'DELETION_ROOT_CHANGED' });
    await expect(
      verifyRecoveryEvidence(digest, 'owner', 'MANAGED', [
        { ...bound, quarantineIdentity: { ...bound.quarantineIdentity!, uid: '-1' } },
      ]),
    ).rejects.toMatchObject({ code: 'DELETION_ROOT_CHANGED' });
  });

  it('binds an external library scope and supports root order changes', async () => {
    const value = report();
    const second = { ...identity, path: '/photos/owner-two', inode: '999' };
    value.scope = 'library-id';
    value.roots.push(second);
    value.mounts[second.path] = structuredClone(value.mounts[identity.path]);
    const digest = await publish(value);
    await expect(verifyRecoveryEvidence(digest, 'owner', 'library-id', [second, identity])).resolves.toHaveProperty(
      'digest',
      digest,
    );
  });

  it('accepts additional verified recovery samples from the existing NAS proof', async () => {
    const value = report();
    value.mounts[identity.path].samples.push({ kind: 'photo', sha256: '3'.repeat(64), size: 2048 });
    const digest = await publish(value);
    await expect(verifyRecoveryEvidence(digest, 'owner', 'MANAGED', [identity])).resolves.toHaveProperty(
      'digest',
      digest,
    );
  });

  it('does not authorize an arbitrary admin-supplied SHA256', async () => {
    await expect(verifyRecoveryEvidence('f'.repeat(64), 'owner', 'MANAGED', [identity])).rejects.toMatchObject({
      code: 'DELETION_RECOVERY_UNAVAILABLE',
    });
    await expect(verifyRecoveryEvidence('../not-a-digest', 'owner', 'MANAGED', [identity])).rejects.toMatchObject({
      code: 'DELETION_RECOVERY_INVALID',
    });
  });

  it.each([
    ['other-owner', 'MANAGED'],
    ['owner', 'other-library'],
  ])('rejects owner/scope mismatch (%s/%s)', async (owner, scope) => {
    const digest = await publish(report());
    await expect(verifyRecoveryEvidence(digest, owner, scope, [identity])).rejects.toMatchObject({
      code: 'DELETION_RECOVERY_SCOPE_MISMATCH',
    });
  });

  it.each(Object.keys(identity) as (keyof DeletionRootIdentity)[])('rejects changed root %s', async (key) => {
    const digest = await publish(report());
    const changed = { ...identity, [key]: `${identity[key]}-changed` };
    await expect(verifyRecoveryEvidence(digest, 'owner', 'MANAGED', [changed])).rejects.toMatchObject({
      code: 'DELETION_ROOT_CHANGED',
    });
  });

  it('rejects missing or duplicated expected roots', async () => {
    const digest = await publish(report());
    for (const roots of [[], [identity, identity]]) {
      await expect(verifyRecoveryEvidence(digest, 'owner', 'MANAGED', roots)).rejects.toMatchObject({
        code: 'DELETION_ROOT_CHANGED',
      });
    }
  });

  it('rejects envelopes signed with an untrusted key', async () => {
    const digest = await publish(report(), generateKeyPairSync('ed25519').privateKey);
    await expect(verifyRecoveryEvidence(digest, 'owner', 'MANAGED', [identity])).rejects.toMatchObject({
      code: 'DELETION_RECOVERY_INVALID',
    });
  });

  it('rejects payload mutation even when the outer digest matches', async () => {
    const digest = await publish(report());
    const changed = await rewrite(digest, (envelope) => {
      envelope.payload = Buffer.from(JSON.stringify({ ...report(), ownerId: 'other-owner' })).toString('base64');
    });
    await expect(verifyRecoveryEvidence(changed, 'owner', 'MANAGED', [identity])).rejects.toMatchObject({
      code: 'DELETION_RECOVERY_INVALID',
    });
  });

  it('rejects a digest that no longer matches the stored file', async () => {
    const digest = await publish(report());
    const file = join(store, `${digest}.json`);
    await fs.chmod(file, 0o600);
    await fs.appendFile(file, '\n');
    await fs.chmod(file, 0o444);
    await expect(verifyRecoveryEvidence(digest, 'owner', 'MANAGED', [identity])).rejects.toMatchObject({
      code: 'DELETION_RECOVERY_INVALID',
    });
  });

  it.each(['signature', 'algorithm', 'version', 'payload'])('rejects malformed envelope %s', async (key) => {
    const digest = await publish(report());
    const changed = await rewrite(digest, (envelope) => {
      envelope[key] = key === 'version' ? 2 : 'invalid';
    });
    await expect(verifyRecoveryEvidence(changed, 'owner', 'MANAGED', [identity])).rejects.toMatchObject({
      code: 'DELETION_RECOVERY_INVALID',
    });
  });
  it('rejects an unsigned envelope even with its correct whole-file digest', async () => {
    const digest = await publish(report());
    const changed = await rewrite(digest, (envelope) => {
      delete envelope.signature;
    });
    await expect(verifyRecoveryEvidence(changed, 'owner', 'MANAGED', [identity])).rejects.toMatchObject({
      code: 'DELETION_RECOVERY_INVALID',
    });
  });

  it.each([
    [
      'invalid normalized PG timestamp',
      (value: DeletionRecoveryEvidence) => {
        value.postgres.checkedAt = '2026-10-09T24:00:00Z';
      },
      'DELETION_RECOVERY_INVALID',
    ],
    [
      'expired report',
      (value: DeletionRecoveryEvidence) => {
        value.verifiedAt = iso(NOW - 1);
        value.expiresAt = iso(NOW);
      },
      'DELETION_RECOVERY_EXPIRED',
    ],
    [
      'future report',
      (value: DeletionRecoveryEvidence) => {
        value.verifiedAt = iso(NOW + 1);
      },
      'DELETION_RECOVERY_INVALID',
    ],
    [
      'long lifetime',
      (value: DeletionRecoveryEvidence) => {
        value.expiresAt = iso(NOW + 25 * HOUR);
      },
      'DELETION_RECOVERY_INVALID',
    ],
    [
      'stale PG restore',
      (value: DeletionRecoveryEvidence) => {
        value.postgres.checkedAt = iso(NOW - 24 * HOUR);
      },
      'DELETION_RECOVERY_EXPIRED',
    ],
    [
      'future PG restore',
      (value: DeletionRecoveryEvidence) => {
        value.postgres.checkedAt = iso(NOW + 1);
      },
      'DELETION_RECOVERY_INVALID',
    ],
    [
      'stale export',
      (value: DeletionRecoveryEvidence) => {
        value.mounts[identity.path].verifiedAt = iso(NOW - 24 * HOUR);
      },
      'DELETION_RECOVERY_EXPIRED',
    ],
    [
      'future export',
      (value: DeletionRecoveryEvidence) => {
        value.mounts[identity.path].verifiedAt = iso(NOW + 1);
      },
      'DELETION_RECOVERY_INVALID',
    ],
    [
      'restore expiry exceeded',
      (value: DeletionRecoveryEvidence) => {
        value.postgres.checkedAt = iso(NOW - 23.5 * HOUR);
      },
      'DELETION_RECOVERY_INVALID',
    ],
    [
      'export expiry exceeded',
      (value: DeletionRecoveryEvidence) => {
        value.mounts[identity.path].verifiedAt = iso(NOW - 23.5 * HOUR);
      },
      'DELETION_RECOVERY_INVALID',
    ],
  ] as const)('rejects %s', async (_name, modify, code) => {
    const value = report();
    modify(value);
    const digest = await publish(value);
    await expect(verifyRecoveryEvidence(digest, 'owner', 'MANAGED', [identity])).rejects.toMatchObject({ code });
  });

  it.each([
    (value: DeletionRecoveryEvidence) => {
      value.postgres.restore = 'BACKUP_EXISTS' as never;
    },
    (value: DeletionRecoveryEvidence) => {
      value.postgres.productionChanged = true as never;
    },
    (value: DeletionRecoveryEvidence) => {
      value.postgres.receiptSHA256 = '';
    },
    (value: DeletionRecoveryEvidence) => {
      value.postgres.assetCount = 0;
    },
    (value: DeletionRecoveryEvidence) => {
      value.postgres.postgresImage = 'postgres:latest';
    },
    (value: DeletionRecoveryEvidence) => {
      delete value.mounts[identity.path];
    },
    (value: DeletionRecoveryEvidence) => {
      value.mounts[identity.path].snapshotProvenanceSHA256 = '';
    },
    (value: DeletionRecoveryEvidence) => {
      value.mounts[identity.path].samples.pop();
    },
    (value: DeletionRecoveryEvidence) => {
      value.mounts[identity.path].samples[1].kind = 'photo';
    },
    (value: DeletionRecoveryEvidence) => {
      value.mounts[identity.path].samples[0].size = 0;
    },
    (value: DeletionRecoveryEvidence) => {
      value.mounts[identity.path].samples[0].sha256 = 'not-verified';
    },
    (value: DeletionRecoveryEvidence) => {
      value.roots.push({ ...identity });
    },
  ])('rejects incomplete recovery evidence case %#', async (modify) => {
    const value = report();
    modify(value);
    const digest = await publish(value);
    await expect(verifyRecoveryEvidence(digest, 'owner', 'MANAGED', [identity])).rejects.toMatchObject({
      code: 'DELETION_RECOVERY_INVALID',
    });
  });

  it.each(['store', 'key-directory', 'evidence-file', 'key-file'] as const)('rejects a writable %s', async (target) => {
    const digest = await publish(report());
    const path = {
      store,
      'key-directory': directory,
      'evidence-file': join(store, `${digest}.json`),
      'key-file': publicKey,
    }[target];
    writablePaths.add(path);
    await fs.chmod(path, 0o700);
    await expect(verifyRecoveryEvidence(digest, 'owner', 'MANAGED', [identity])).rejects.toMatchObject({
      code: 'DELETION_RECOVERY_INVALID',
    });
  });

  it('rejects chmod-only read-only directories owned by the application', async () => {
    const digest = await publish(report());
    readOnlyPaths = false;
    await expect(verifyRecoveryEvidence(digest, 'owner', 'MANAGED', [identity])).rejects.toMatchObject({
      code: 'DELETION_RECOVERY_INVALID',
    });
  });

  it('recognizes read-only mount flags when mode checks return EACCES', async () => {
    const digest = await publish(report());
    readOnlyPaths = false;
    const actualReadFile = fs.readFile;
    vi.spyOn(fs, 'readFile').mockImplementation(async (...args: Parameters<typeof fs.readFile>) => {
      const bytes = await actualReadFile(...args);
      if (String(args[0]) === '/proc/self/mountinfo') {
        return String(bytes)
          .split('\n')
          .map((line) => {
            if (!line) {
              return line;
            }
            const [left, right] = line.split(' - ', 2);
            const fields = left.split(' ');
            fields[5] = 'ro';
            return `${fields.join(' ')} - ${right}`;
          })
          .join('\n');
      }
      return bytes;
    });
    await expect(verifyRecoveryEvidence(digest, 'owner', 'MANAGED', [identity])).resolves.toHaveProperty(
      'digest',
      digest,
    );
  });

  it('rejects a mutable ancestor of a store outside a read-only mount', async () => {
    const digest = await publish(report());
    readOnlyPaths = false;
    vi.spyOn(process, 'getuid').mockReturnValue(2000);
    await expect(verifyRecoveryEvidence(digest, 'owner', 'MANAGED', [identity])).rejects.toMatchObject({
      code: 'DELETION_RECOVERY_INVALID',
    });
  });

  it('rejects a FIFO without waiting for a writer', async () => {
    const digest = await publish(report());
    const file = join(store, `${digest}.json`);
    await fs.chmod(store, 0o700);
    await fs.rm(file);
    execFileSync('mkfifo', [file], { stdio: 'ignore' });
    await fs.chmod(store, 0o555);
    await expect(verifyRecoveryEvidence(digest, 'owner', 'MANAGED', [identity])).rejects.toMatchObject({
      code: 'DELETION_RECOVERY_INVALID',
    });
  });

  it('rejects symlinked evidence files and directory ancestors', async () => {
    const digest = await publish(report());
    const file = join(store, `${digest}.json`);
    await fs.chmod(directory, 0o700);
    await fs.chmod(store, 0o700);
    await fs.rename(file, join(directory, 'outside.json'));
    await fs.symlink(join(directory, 'outside.json'), file);
    await fs.chmod(store, 0o555);
    await fs.chmod(directory, 0o555);
    await expect(verifyRecoveryEvidence(digest, 'owner', 'MANAGED', [identity])).rejects.toMatchObject({
      code: 'DELETION_RECOVERY_INVALID',
    });
    await fs.chmod(directory, 0o700);
    await fs.symlink(store, join(directory, 'linked-store'));
    await fs.chmod(directory, 0o555);
    vi.stubEnv('GALLERY_DELETION_RECOVERY_DIR', join(directory, 'linked-store'));
    await expect(verifyRecoveryEvidence(digest, 'owner', 'MANAGED', [identity])).rejects.toMatchObject({
      code: 'DELETION_RECOVERY_INVALID',
    });
  });

  it('re-reads evidence and key availability on every unlink check', async () => {
    const digest = await publish(report());
    await verifyRecoveryEvidence(digest, 'owner', 'MANAGED', [identity]);
    vi.mocked(Date.now).mockReturnValue(NOW + HOUR);
    await expect(verifyRecoveryEvidence(digest, 'owner', 'MANAGED', [identity])).rejects.toMatchObject({
      code: 'DELETION_RECOVERY_EXPIRED',
    });
    vi.mocked(Date.now).mockReturnValue(NOW);
    await fs.chmod(directory, 0o700);
    await fs.rm(publicKey);
    await fs.chmod(directory, 0o555);
    await expect(verifyRecoveryEvidence(digest, 'owner', 'MANAGED', [identity])).rejects.toMatchObject({
      code: 'DELETION_RECOVERY_UNAVAILABLE',
    });
  });
});
