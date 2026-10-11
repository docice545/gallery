import { createHash } from 'node:crypto';
import fs, { type FileHandle, link, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, join } from 'node:path';
import type { DeletionRootIdentity } from 'src/schema/tables/asset-deletion.table.js';
import {
  DeletionError,
  assertDisjointDeletionRootMounts,
  collectRootIdentities,
  snapshotOriginal,
  unlinkOriginal,
  validateDeletionRoots,
  verifyDisposablePath,
} from 'src/utils/authorized-deletion.js';

let root: string;
beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), 'gallery-authorized-delete-'));
});
afterEach(async () => {
  vi.restoreAllMocks();
  await rm(root, { recursive: true, force: true });
});

const quarantinePath = () => join(root, '.gallery-deletion-quarantine');
const looseMkdir = () => {
  const mkdirActual = fs.mkdir;
  const chmodActual = fs.chmod;
  vi.spyOn(fs, 'mkdir').mockImplementation(async (path, options) => {
    const result = await mkdirActual(path, options);
    if (String(path).endsWith('/.gallery-deletion-quarantine')) await chmodActual(path, 0o777);
    return result;
  });
};
const onQuarantineOpen = (callback: (handle: FileHandle) => void) => {
  const openActual = fs.open;
  vi.spyOn(fs, 'open').mockImplementation(async (file, flags, mode) => {
    const handle = await openActual(file, flags, mode);
    if (String(file).endsWith('/.gallery-deletion-quarantine')) callback(handle);
    return handle;
  });
};

describe('private quarantine initialization on Synology-like filesystems', () => {
  it('secures a newly created 0777 directory through its descriptor before capturing any original', async () => {
    const file = join(root, 'photo.heic');
    await writeFile(file, 'disposable original');
    const proof = await snapshotOriginal(file, await collectRootIdentities([root]));
    looseMkdir();
    const pathChmod = vi.spyOn(fs, 'chmod');
    const descriptorChmod = vi.fn();
    onQuarantineOpen((handle) => {
      const actual = handle.chmod.bind(handle);
      vi.spyOn(handle, 'chmod').mockImplementation(async (mode) => {
        descriptorChmod(mode);
        await actual(mode);
      });
    });
    let checks = 0;
    await unlinkOriginal(proof, async () => {
      const stat = await fs.stat(quarantinePath());
      expect(stat.mode & 0o7777).toBe(0o700);
      if (++checks === 1) expect(await readFile(file, 'utf8')).toBe('disposable original');
    });
    expect(descriptorChmod).toHaveBeenCalledExactlyOnceWith(0o700);
    expect(pathChmod).not.toHaveBeenCalled();
    await expect(readFile(file)).rejects.toHaveProperty('code', 'ENOENT');
    await unlinkOriginal(proof);
    expect(descriptorChmod).toHaveBeenCalledTimes(1);
  });

  it.each([0o777, 0o755, 0o1700, 0o2700])('never repairs an existing directory with mode %o', async (mode) => {
    const file = join(root, 'photo');
    await writeFile(file, 'original must survive');
    const proof = await snapshotOriginal(file, await collectRootIdentities([root]));
    await mkdir(quarantinePath());
    await fs.chmod(quarantinePath(), mode);
    const chmod = vi.fn();
    onQuarantineOpen((handle) => {
      vi.spyOn(handle, 'chmod').mockImplementation(chmod);
    });
    await expect(unlinkOriginal(proof)).rejects.toMatchObject({ code: 'DELETION_QUARANTINE_CONFLICT' });
    expect(chmod).not.toHaveBeenCalled();
    const stat = await fs.stat(quarantinePath());
    expect(stat.mode & 0o7777).toBe(mode);
    expect(await readFile(file, 'utf8')).toBe('original must survive');
  });

  it('reuses an existing private directory without calling chmod', async () => {
    const file = join(root, 'video');
    await writeFile(file, 'disposable video');
    const proof = await snapshotOriginal(file, await collectRootIdentities([root]));
    await mkdir(quarantinePath(), { mode: 0o700 });
    const chmod = vi.fn().mockRejectedValue(new Error('existing directory must not be chmodded'));
    onQuarantineOpen((handle) => {
      vi.spyOn(handle, 'chmod').mockImplementation(chmod);
    });
    await unlinkOriginal(proof);
    expect(chmod).not.toHaveBeenCalled();
    await expect(readFile(file)).rejects.toHaveProperty('code', 'ENOENT');
  });

  it.each(['EACCES', 'EROFS', 'ESTALE', 'ETIMEDOUT'])(
    'a descriptor chmod %s failure cannot capture or delete an original',
    async (code) => {
      const file = join(root, 'photo');
      await writeFile(file, 'original must survive');
      const proof = await snapshotOriginal(file, await collectRootIdentities([root]));
      looseMkdir();
      onQuarantineOpen((handle) => {
        vi.spyOn(handle, 'chmod').mockRejectedValue(Object.assign(new Error('injected chmod failure'), { code }));
      });
      await expect(unlinkOriginal(proof)).rejects.toHaveProperty('code', code);
      expect(await readFile(file, 'utf8')).toBe('original must survive');
      expect(await fs.readdir(quarantinePath())).toEqual([]);
    },
  );

  it('rejects a successful chmod acknowledgement when actual permissions remain public', async () => {
    const file = join(root, 'photo');
    await writeFile(file, 'original must survive');
    const proof = await snapshotOriginal(file, await collectRootIdentities([root]));
    looseMkdir();
    onQuarantineOpen((handle) => {
      vi.spyOn(handle, 'chmod').mockResolvedValue();
    });
    await expect(unlinkOriginal(proof)).rejects.toMatchObject({ code: 'DELETION_QUARANTINE_CONFLICT' });
    expect(await readFile(file, 'utf8')).toBe('original must survive');
    expect(await fs.readdir(quarantinePath())).toEqual([]);
  });

  it('rejects foreign ownership before chmod', async () => {
    const file = join(root, 'photo');
    await writeFile(file, 'original must survive');
    const proof = await snapshotOriginal(file, await collectRootIdentities([root]));
    looseMkdir();
    const chmod = vi.fn();
    onQuarantineOpen((handle) => {
      const statActual = handle.stat.bind(handle);
      vi.spyOn(handle, 'stat').mockImplementation(async () => ({
        ...(await statActual({ bigint: true })),
        uid: BigInt(process.getuid!() + 1),
        isDirectory: () => true,
      }));
      vi.spyOn(handle, 'chmod').mockImplementation(chmod);
    });
    await expect(unlinkOriginal(proof)).rejects.toMatchObject({ code: 'DELETION_QUARANTINE_CONFLICT' });
    expect(chmod).not.toHaveBeenCalled();
    expect(await readFile(file, 'utf8')).toBe('original must survive');
  });

  it.each(['uid', 'dev', 'ino'] as const)('rejects a changed %s after descriptor chmod', async (field) => {
    const file = join(root, 'photo');
    await writeFile(file, 'original must survive');
    const proof = await snapshotOriginal(file, await collectRootIdentities([root]));
    looseMkdir();
    onQuarantineOpen((handle) => {
      const actual = handle.chmod.bind(handle);
      vi.spyOn(handle, 'chmod').mockImplementation(async (mode) => {
        await actual(mode);
        const statActual = handle.stat.bind(handle);
        vi.spyOn(handle, 'stat').mockImplementation(async () => {
          const stat = await statActual({ bigint: true });
          return { ...stat, [field]: stat[field] + 1n, isDirectory: () => true };
        });
      });
    });
    await expect(unlinkOriginal(proof)).rejects.toMatchObject({ code: 'DELETION_QUARANTINE_CONFLICT' });
    expect(await readFile(file, 'utf8')).toBe('original must survive');
    expect(await fs.readdir(quarantinePath())).toEqual([]);
  });

  it('rejects a changed directory type after descriptor chmod', async () => {
    const file = join(root, 'photo');
    await writeFile(file, 'original must survive');
    const proof = await snapshotOriginal(file, await collectRootIdentities([root]));
    looseMkdir();
    onQuarantineOpen((handle) => {
      const actual = handle.chmod.bind(handle);
      vi.spyOn(handle, 'chmod').mockImplementation(async (mode) => {
        await actual(mode);
        const statActual = handle.stat.bind(handle);
        vi.spyOn(handle, 'stat').mockImplementation(async () => ({
          ...(await statActual({ bigint: true })),
          isDirectory: () => false,
        }));
      });
    });
    await expect(unlinkOriginal(proof)).rejects.toMatchObject({ code: 'DELETION_QUARANTINE_CONFLICT' });
    expect(await readFile(file, 'utf8')).toBe('original must survive');
  });

  it.each(['directory', 'symlink'])(
    'rejects a %s substituted between lstat and open without chmodding it',
    async (type) => {
      const file = join(root, 'photo');
      const outside = join(root, 'outside');
      await mkdir(outside, { mode: 0o755 });
      await fs.chmod(outside, 0o755);
      await writeFile(file, 'original must survive');
      await writeFile(join(outside, 'control'), 'outside must survive');
      const proof = await snapshotOriginal(file, await collectRootIdentities([root]));
      looseMkdir();
      const openActual = fs.open;
      const chmod = vi.fn();
      let replaced = false;
      vi.spyOn(fs, 'open').mockImplementation(async (path, flags, mode) => {
        if (!replaced && String(path).endsWith('/.gallery-deletion-quarantine')) {
          replaced = true;
          await fs.rename(quarantinePath(), quarantinePath() + '.saved');
          if (type === 'directory') await mkdir(quarantinePath(), { mode: 0o755 });
          else await symlink(outside, quarantinePath());
        }
        const handle = await openActual(path, flags, mode);
        vi.spyOn(handle, 'chmod').mockImplementation(chmod);
        return handle;
      });
      await expect(unlinkOriginal(proof)).rejects.toHaveProperty(
        'code',
        type === 'directory' ? 'DELETION_QUARANTINE_CONFLICT' : 'ENOTDIR',
      );
      expect(chmod).not.toHaveBeenCalled();
      expect(await readFile(file, 'utf8')).toBe('original must survive');
      expect(await readFile(join(outside, 'control'), 'utf8')).toBe('outside must survive');
      const stat = await fs.stat(outside);
      expect(stat.mode & 0o7777).toBe(0o755);
    },
  );

  it('detects quarantine replacement during chmod before moving the original', async () => {
    const file = join(root, 'photo');
    await writeFile(file, 'original must survive');
    const proof = await snapshotOriginal(file, await collectRootIdentities([root]));
    looseMkdir();
    onQuarantineOpen((handle) => {
      const actual = handle.chmod.bind(handle);
      vi.spyOn(handle, 'chmod').mockImplementation(async (mode) => {
        await actual(mode);
        await fs.rename(quarantinePath(), quarantinePath() + '.saved');
        await mkdir(quarantinePath(), { mode: 0o700 });
        await fs.chmod(quarantinePath(), 0o700);
        await writeFile(join(quarantinePath(), 'control'), 'replacement must survive');
      });
    });
    await expect(unlinkOriginal(proof)).rejects.toMatchObject({ code: 'DELETION_QUARANTINE_CONFLICT' });
    expect(await readFile(file, 'utf8')).toBe('original must survive');
    expect(await readFile(join(quarantinePath(), 'control'), 'utf8')).toBe('replacement must survive');
    expect(await fs.readdir(quarantinePath() + '.saved')).toEqual([]);
  });

  it('blocks ancestor-symlink substitution during chmod and preserves the outside directory', async () => {
    const allowed = join(root, 'allowed');
    const outside = join(root, 'outside');
    await mkdir(allowed);
    await mkdir(outside, { mode: 0o755 });
    await fs.chmod(outside, 0o755);
    const file = join(allowed, 'photo');
    await writeFile(file, 'authorized original must survive');
    await writeFile(join(outside, 'photo'), 'outside must survive');
    const proof = await snapshotOriginal(file, await collectRootIdentities([allowed]));
    looseMkdir();
    onQuarantineOpen((handle) => {
      const actual = handle.chmod.bind(handle);
      vi.spyOn(handle, 'chmod').mockImplementation(async (mode) => {
        await actual(mode);
        await fs.rename(allowed, allowed + '.saved');
        await symlink(outside, allowed);
      });
    });
    await expect(unlinkOriginal(proof)).rejects.toMatchObject({ code: 'DELETION_ROOT_CHANGED' });
    expect(await readFile(join(allowed + '.saved', 'photo'), 'utf8')).toBe('authorized original must survive');
    expect(await readFile(join(outside, 'photo'), 'utf8')).toBe('outside must survive');
    const stat = await fs.stat(outside);
    expect(stat.mode & 0o7777).toBe(0o755);
  });

  it('rejects mount-namespace identity changes during chmod', async () => {
    const file = join(root, 'photo');
    await writeFile(file, 'original must survive');
    const proof = await snapshotOriginal(file, await collectRootIdentities([root]));
    looseMkdir();
    onQuarantineOpen((handle) => {
      const actual = handle.chmod.bind(handle);
      vi.spyOn(handle, 'chmod').mockImplementation(async (mode) => {
        await actual(mode);
        const readlinkActual = fs.readlink;
        vi.spyOn(fs, 'readlink').mockImplementation(async (path, options) =>
          String(path) === '/proc/self/ns/mnt' ? 'mnt:[changed]' : readlinkActual(path, options),
        );
      });
    });
    await expect(unlinkOriginal(proof)).rejects.toMatchObject({ code: 'DELETION_QUARANTINE_CONFLICT' });
    expect(await readFile(file, 'utf8')).toBe('original must survive');
    expect(await fs.readdir(quarantinePath())).toEqual([]);
  });

  it('rejects a different quarantine mount ID during chmod even when device and inode match', async () => {
    const file = join(root, 'photo');
    await writeFile(file, 'original must survive');
    const proof = await snapshotOriginal(file, await collectRootIdentities([root]));
    looseMkdir();
    onQuarantineOpen((handle) => {
      const actual = handle.chmod.bind(handle);
      vi.spyOn(handle, 'chmod').mockImplementation(async (mode) => {
        await actual(mode);
        const readActual = fs.readFile;
        const changedMountId = proof.rootIdentity.mountId + '999';
        vi.spyOn(fs, 'readFile').mockImplementation(async (path, options) => {
          const result = await readActual(path, options);
          if (typeof result !== 'string') return result;
          if (String(path) === '/proc/self/fdinfo/' + handle.fd)
            return result.replace(/^mnt_id:\s*\d+$/m, () => 'mnt_id:\t' + changedMountId);
          if (String(path) === '/proc/self/mountinfo') {
            const line = result.split('\n').find((line) => line.startsWith(proof.rootIdentity.mountId + ' '))!;
            return result + '\n' + line.replace(/^\d+ /, () => changedMountId + ' ');
          }
          return result;
        });
      });
    });
    await expect(unlinkOriginal(proof)).rejects.toMatchObject({ code: 'DELETION_QUARANTINE_CONFLICT' });
    expect(await readFile(file, 'utf8')).toBe('original must survive');
    expect(await fs.readdir(quarantinePath())).toEqual([]);
  });

  it('preserves a captured file after interruption and retries without changing existing permissions', async () => {
    const file = join(root, 'video');
    await writeFile(file, 'disposable video');
    const proof = await snapshotOriginal(file, await collectRootIdentities([root]));
    looseMkdir();
    const chmod = vi.fn();
    onQuarantineOpen((handle) => {
      const actual = handle.chmod.bind(handle);
      vi.spyOn(handle, 'chmod').mockImplementation(async (mode) => {
        chmod(mode);
        await actual(mode);
      });
    });
    let calls = 0;
    await expect(
      unlinkOriginal(proof, () => {
        if (++calls === 2) throw new DeletionError('DELETION_RECOVERY_EXPIRED');
        return Promise.resolve();
      }),
    ).rejects.toMatchObject({ code: 'DELETION_RECOVERY_EXPIRED' });
    const captured = join(quarantinePath(), proof.quarantineName);
    expect(await readFile(captured, 'utf8')).toBe('disposable video');
    await unlinkOriginal(proof);
    expect(chmod).toHaveBeenCalledExactlyOnceWith(0o700);
    await expect(readFile(captured)).rejects.toHaveProperty('code', 'ENOENT');
  });

  it('a permission change after capture blocks unlink and cannot be repaired by a retry', async () => {
    const file = join(root, 'photo');
    await writeFile(file, 'original must survive');
    const proof = await snapshotOriginal(file, await collectRootIdentities([root]));
    looseMkdir();
    let calls = 0;
    await expect(
      unlinkOriginal(proof, async () => {
        if (++calls === 2) await fs.chmod(quarantinePath(), 0o777);
      }),
    ).rejects.toMatchObject({ code: 'DELETION_QUARANTINE_CONFLICT' });
    const captured = join(quarantinePath(), proof.quarantineName);
    expect(await readFile(captured, 'utf8')).toBe('original must survive');
    await expect(unlinkOriginal(proof)).rejects.toMatchObject({ code: 'DELETION_QUARANTINE_CONFLICT' });
    const stat = await fs.stat(quarantinePath());
    expect(stat.mode & 0o7777).toBe(0o777);
    expect(await readFile(captured, 'utf8')).toBe('original must survive');
  });
});

describe('owner boundaries in backing mount coordinates', () => {
  const owner: DeletionRootIdentity = {
    path: '/data/owner-a',
    device: '2049',
    inode: '100',
    mountId: '40',
    mountNamespace: 'mnt:[123]',
    mountType: 'ext4',
    mountSource: '/dev/storage',
    mountRoot: '/volume',
    mountTarget: '/data',
  };
  const alias: DeletionRootIdentity = {
    ...owner,
    path: '/other-owner',
    inode: '200',
    mountId: '41',
    mountRoot: '/volume/owner-a/sub',
    mountTarget: '/other-owner',
  };

  it.each(['parent', 'child'])('rejects a nested bind alias when granting the %s root', (grant) => {
    expect(() =>
      assertDisjointDeletionRootMounts(...(grant === 'parent' ? ([owner, alias] as const) : ([alias, owner] as const))),
    ).toThrow(new DeletionError('OVERLAPPING_OWNER_ROOTS'));
  });

  it('allows same-device sibling roots without confusing a common prefix', () => {
    expect(() =>
      assertDisjointDeletionRootMounts(owner, { ...alias, mountRoot: '/volume/owner-a-sibling' }),
    ).not.toThrow();
  });

  it('allows independent local filesystems with matching internal coordinates', () => {
    expect(() => assertDisjointDeletionRootMounts(owner, { ...alias, device: '2050' })).not.toThrow();
  });

  it.each([
    { mountRoot: '../volume' },
    { mountRoot: '/volume/../other' },
    { mountTarget: '/wrong-target' },
    { mountTarget: '/data/../other' },
    { path: '/data/owner-a/../owner-b' },
    { mountNamespace: 'mnt:[456]' },
  ])('rejects unresolved mount coordinates %j', (override) => {
    expect(() => assertDisjointDeletionRootMounts(owner, { ...alias, ...override })).toThrow(
      new DeletionError('UNSUPPORTED_DELETION_FILESYSTEM'),
    );
  });

  it('compares decoded mount coordinates containing spaces and backslashes', () => {
    expect(() =>
      assertDisjointDeletionRootMounts(
        { ...owner, mountRoot: String.raw`/volume with space\name` },
        { ...alias, mountRoot: String.raw`/volume with space\name/owner-a/sub` },
      ),
    ).toThrow(new DeletionError('OVERLAPPING_OWNER_ROOTS'));
  });

  const nfs: DeletionRootIdentity = {
    ...owner,
    mountType: 'nfs4',
    mountSource: '192.0.2.10:/photos',
    mountRoot: '/',
  };

  it.each(['2049', '2050'])('rejects nested NFS exports on device %s', (device) => {
    expect(() =>
      assertDisjointDeletionRootMounts(nfs, {
        ...alias,
        device,
        mountType: 'nfs',
        mountSource: '192.0.2.10:/photos/owner-a/sub',
        mountRoot: '/',
      }),
    ).toThrow(new DeletionError('OVERLAPPING_OWNER_ROOTS'));
  });

  it.each(['2049', '2050'])('allows disjoint exports on the identical NFS server IP, device %s', (device) => {
    expect(() =>
      assertDisjointDeletionRootMounts(nfs, {
        ...alias,
        device,
        mountType: 'nfs4',
        mountSource: '192.0.2.10:/other-photos',
        mountRoot: '/',
      }),
    ).not.toThrow();
  });

  it.each(['nas.example:/photos', '192.0.2.11:/photos', 'unresolved', '192.0.2.10:/photos/../other'])(
    'fails closed for ambiguous NFS server/export identity %s',
    (mountSource) => {
      expect(() =>
        assertDisjointDeletionRootMounts(nfs, { ...alias, device: '2050', mountType: 'nfs4', mountSource }),
      ).toThrow(new DeletionError('UNSUPPORTED_DELETION_FILESYSTEM'));
    },
  );

  it('fails closed for an unresolved overlay/local backing relationship', () => {
    expect(() => assertDisjointDeletionRootMounts(owner, { ...alias, device: '2050', mountType: 'overlay' })).toThrow(
      new DeletionError('UNSUPPORTED_DELETION_FILESYSTEM'),
    );
  });

  it('allows distinct local and remote NFS devices in the application mount namespace', () => {
    expect(() =>
      assertDisjointDeletionRootMounts(owner, {
        ...alias,
        device: '2050',
        mountType: 'nfs4',
        mountSource: '192.0.2.10:/photos',
      }),
    ).not.toThrow();
  });

  it.each(['root', 'descendant'])(
    'uses collected mountinfo to reject A/sub bound at the other owner %s before publishing a grant',
    async (topology) => {
      const allowed = join(root, 'owner-a'),
        other = join(root, 'owner-b');
      await mkdir(allowed);
      await mkdir(join(allowed, 'sub'));
      await mkdir(other);
      const aliasTarget = topology === 'root' ? other : join(other, 'linked');
      if (topology === 'descendant') await mkdir(aliasTarget);
      const originalReadFile = fs.readFile;
      const mountInfo = [
        `40 1 8:1 /volume ${root} rw - ext4 /dev/storage rw`,
        `41 40 8:1 /volume/owner-a/sub ${aliasTarget} rw - ext4 /dev/storage rw`,
      ].join('\n');
      // Only proc mount metadata is synthetic. Directory descriptors and stat
      // identities are real and disjoint; no privileged kernel mount is created.
      vi.spyOn(fs, 'readFile').mockImplementation(async (...args: Parameters<typeof fs.readFile>) => {
        const file = String(args[0]);
        if (file === '/proc/self/mountinfo') return mountInfo;
        if (file.startsWith('/proc/self/fdinfo/')) {
          const opened = await fs.readlink('/proc/self/fd/' + basename(file));
          if (opened === aliasTarget) return 'mnt_id:\t41\n';
          if (opened === allowed || opened === other) return 'mnt_id:\t40\n';
        }
        return originalReadFile(...args);
      });
      await expect(validateDeletionRoots([allowed], [other])).rejects.toMatchObject({
        code: 'OVERLAPPING_OWNER_ROOTS',
      });
      if (topology === 'root') {
        await expect(validateDeletionRoots([other], [allowed])).rejects.toMatchObject({
          code: 'OVERLAPPING_OWNER_ROOTS',
        });
      }
    },
  );
});

describe('existing Gallery worker original-file guards on disposable files', () => {
  it.each(['photo.heic', 'video.mp4', 'motion.jpg'])('streams and removes only the authorized %s', async (name) => {
    const file = join(root, name);
    const other = join(root, 'bystander');
    await writeFile(file, Buffer.alloc(3 * 1024 * 1024, 17));
    await writeFile(other, 'keep');
    const proof = await snapshotOriginal(file, await collectRootIdentities([root]));
    expect(proof.sha256).toBe(
      createHash('sha256')
        .update(Buffer.alloc(3 * 1024 * 1024, 17))
        .digest('hex'),
    );
    await unlinkOriginal(proof);
    await expect(readFile(file)).rejects.toHaveProperty('code', 'ENOENT');
    expect(await readFile(other, 'utf8')).toBe('keep');
    await unlinkOriginal(proof); // interrupted worker retry, committed identity proof remains required
  });

  it('rejects a replaced file after durable verification', async () => {
    const file = join(root, 'photo');
    await writeFile(file, 'old');
    const proof = await snapshotOriginal(file, await collectRootIdentities([root]));
    await rm(file);
    await writeFile(file, 'new');
    await expect(unlinkOriginal(proof)).rejects.toMatchObject({ code: 'ORIGINAL_IDENTITY_CHANGED' });
    expect(await readFile(file, 'utf8')).toBe('new');
  });

  it('rejects modification of the same inode', async () => {
    const file = join(root, 'photo');
    await writeFile(file, 'old');
    const proof = await snapshotOriginal(file, await collectRootIdentities([root]));
    await writeFile(file, 'new');
    await expect(unlinkOriginal(proof)).rejects.toBeInstanceOf(DeletionError);
  });

  it('rejects hard-linked files', async () => {
    const file = join(root, 'photo');
    await writeFile(file, 'keep');
    await link(file, join(root, 'other-owner'));
    await expect(snapshotOriginal(file, await collectRootIdentities([root]))).rejects.toMatchObject({
      code: 'ORIGINAL_NOT_EXCLUSIVE_REGULAR_FILE',
    });
  });

  it('rejects file and ancestor symlinks', async () => {
    await mkdir(join(root, 'real'));
    await writeFile(join(root, 'real', 'photo'), 'keep');
    await symlink(join(root, 'real'), join(root, 'linked'));
    await symlink(join(root, 'real', 'photo'), join(root, 'photo'));
    await expect(
      snapshotOriginal(join(root, 'linked', 'photo'), await collectRootIdentities([root])),
    ).rejects.toBeDefined();
    await expect(snapshotOriginal(join(root, 'photo'), await collectRootIdentities([root]))).rejects.toBeDefined();
    expect(await readFile(join(root, 'real', 'photo'), 'utf8')).toBe('keep');
  });

  it('rejects traversal and prefix sibling roots', async () => {
    await expect(snapshotOriginal(`${root}/../other`, await collectRootIdentities([root]))).rejects.toBeDefined();
    await expect(snapshotOriginal(`${root}-sibling/photo`, await collectRootIdentities([root]))).rejects.toBeDefined();
  });

  it('rejects roots that overlap another owner', async () => {
    const child = join(root, 'child');
    await mkdir(child);
    await expect(validateDeletionRoots([child], [root])).rejects.toMatchObject({ code: 'OVERLAPPING_OWNER_ROOTS' });
    await expect(validateDeletionRoots([root], [child])).rejects.toMatchObject({ code: 'OVERLAPPING_OWNER_ROOTS' });
    await expect(validateDeletionRoots([root], [root])).rejects.toBeDefined();
  });
  it('allows disposable cache only inside a canonical root and rejects symlink ancestors', async () => {
    const cache = join(root, 'cache');
    const other = join(root, 'originals');
    await mkdir(cache);
    await mkdir(other);
    await writeFile(join(cache, 'preview'), 'disposable');
    await writeFile(join(other, 'photo'), 'keep');
    await verifyDisposablePath(join(cache, 'preview'), [cache]);
    await symlink(other, join(cache, 'link'));
    await expect(verifyDisposablePath(join(cache, 'link', 'photo'), [cache])).rejects.toBeDefined();
    expect(await readFile(join(other, 'photo'), 'utf8')).toBe('keep');
  });
});

describe('bound roots and atomic capture security regressions', () => {
  it('rejects the original ancestor-symlink exploit BEFORE snapshot', async () => {
    const fs = await import('node:fs/promises');
    const accepted = join(root, 'accepted'),
      outside = join(root, 'outside');
    await mkdir(join(accepted, 'library'), { recursive: true });
    await mkdir(join(outside, 'library'), { recursive: true });
    await writeFile(join(accepted, 'library', 'photo'), 'original');
    await writeFile(join(outside, 'library', 'photo'), 'outside must survive');
    const identities = await collectRootIdentities([join(accepted, 'library')]);
    await fs.rename(accepted, accepted + '.saved');
    await symlink(outside, accepted);
    await expect(snapshotOriginal(join(accepted, 'library', 'photo'), identities)).rejects.toMatchObject({
      code: 'DELETION_ROOT_CHANGED',
    });
    expect(await readFile(join(outside, 'library', 'photo'), 'utf8')).toBe('outside must survive');
    expect(await readFile(join(accepted + '.saved', 'library', 'photo'), 'utf8')).toBe('original');
  });

  it('rejects a root replaced AFTER grant but BEFORE receipt creation', async () => {
    const fs = await import('node:fs/promises');
    const allowed = join(root, 'allowed');
    await mkdir(allowed);
    await writeFile(join(allowed, 'photo'), 'original');
    const identities = await collectRootIdentities([allowed]);
    await fs.rename(allowed, allowed + '.saved');
    await mkdir(allowed);
    await writeFile(join(allowed, 'photo'), 'replacement');
    await expect(snapshotOriginal(join(allowed, 'photo'), identities)).rejects.toMatchObject({
      code: 'DELETION_ROOT_CHANGED',
    });
    expect(await readFile(join(allowed, 'photo'), 'utf8')).toBe('replacement');
  });

  it.each(['mountId', 'mountNamespace', 'mountSource', 'mountRoot', 'mountType', 'device', 'inode'] as const)(
    'rejects mismatched authorized filesystem field %s',
    async (field) => {
      const file = join(root, 'photo');
      await writeFile(file, 'keep');
      const [identity] = await collectRootIdentities([root]);
      await expect(snapshotOriginal(file, [{ ...identity, [field]: 'different' }])).rejects.toMatchObject({
        code: 'DELETION_ROOT_CHANGED',
      });
      expect(await readFile(file, 'utf8')).toBe('keep');
    },
  );

  it('rejects source parent replacement after snapshot without deleting its replacement', async () => {
    const fs = await import('node:fs/promises');
    const parent = join(root, 'parent');
    await mkdir(parent);
    await writeFile(join(parent, 'photo'), 'original');
    const proof = await snapshotOriginal(join(parent, 'photo'), await collectRootIdentities([root]));
    await fs.rename(parent, parent + '.saved');
    await mkdir(parent);
    await writeFile(join(parent, 'photo'), 'replacement');
    await expect(unlinkOriginal(proof)).rejects.toMatchObject({ code: 'ORIGINAL_IDENTITY_CHANGED' });
    expect(await readFile(join(parent, 'photo'), 'utf8')).toBe('replacement');
  });

  it('a last-moment source race is captured, detected and restored, never unlinked', async () => {
    const fs = await import('node:fs/promises');
    const file = join(root, 'photo');
    await writeFile(file, 'original');
    const proof = await snapshotOriginal(file, await collectRootIdentities([root]));
    let calls = 0;
    await expect(
      unlinkOriginal(proof, async () => {
        if (calls++ !== 0) {
          return;
        }

        await fs.rename(file, file + '.saved');
        await writeFile(file, 'raced replacement');
      }),
    ).rejects.toMatchObject({ code: 'ORIGINAL_IDENTITY_CHANGED' });
    expect(await readFile(file, 'utf8')).toBe('raced replacement');
    expect(await readFile(file + '.saved', 'utf8')).toBe('original');
  });

  it('interruption after atomic capture preserves the journal-named file for verified retry', async () => {
    const file = join(root, 'video');
    await writeFile(file, 'original video');
    const proof = await snapshotOriginal(file, await collectRootIdentities([root]));
    let calls = 0;
    await expect(
      unlinkOriginal(proof, () => {
        if (++calls === 2) throw new DeletionError('DELETION_RECOVERY_EXPIRED');
        return Promise.resolve();
      }),
    ).rejects.toMatchObject({ code: 'DELETION_RECOVERY_EXPIRED' });
    const captured = join(root, '.gallery-deletion-quarantine', proof.quarantineName);
    expect(await readFile(captured, 'utf8')).toBe('original video');
    await unlinkOriginal(proof);
    await expect(readFile(captured)).rejects.toHaveProperty('code', 'ENOENT');
  });

  it('rejects a symlink substituted for the quarantine directory', async () => {
    const file = join(root, 'photo');
    await writeFile(file, 'original');
    const proof = await snapshotOriginal(file, await collectRootIdentities([root]));
    const outside = join(root, 'outside');
    await mkdir(outside);
    await symlink(outside, join(root, '.gallery-deletion-quarantine'));
    await expect(unlinkOriginal(proof)).rejects.toBeDefined();
    expect(await readFile(file, 'utf8')).toBe('original');
  });

  it('retains a raced source symlink without unlinking its outside target', async () => {
    const fs = await import('node:fs/promises');
    const file = join(root, 'photo'),
      outside = join(root, 'outside');
    await writeFile(file, 'original');
    await writeFile(outside, 'outside must survive');
    const proof = await snapshotOriginal(file, await collectRootIdentities([root]));
    let calls = 0;
    await expect(
      unlinkOriginal(proof, async () => {
        if (calls++ !== 0) {
          return;
        }

        await fs.rename(file, file + '.saved');
        await symlink(outside, file);
      }),
    ).rejects.toBeDefined();
    expect(await readFile(outside, 'utf8')).toBe('outside must survive');
    expect(await readFile(file + '.saved', 'utf8')).toBe('original');
    const captured = await fs.lstat(join(root, '.gallery-deletion-quarantine', proof.quarantineName));
    expect(captured.isSymbolicLink()).toBe(true);
  });

  it('rejects parent reparenting outside the grant during the authorization check', async () => {
    const fs = await import('node:fs/promises');
    const allowed = join(root, 'allowed'),
      outside = join(root, 'outside');
    await mkdir(join(allowed, 'parent'), { recursive: true });
    await mkdir(outside);
    const file = join(allowed, 'parent', 'photo');
    await writeFile(file, 'original');
    const proof = await snapshotOriginal(file, await collectRootIdentities([allowed]));
    await expect(
      unlinkOriginal(proof, async () => {
        await fs.rename(join(allowed, 'parent'), join(outside, 'moved'));
        await mkdir(join(allowed, 'parent'));
        await writeFile(file, 'replacement');
      }),
    ).rejects.toMatchObject({ code: 'DELETION_ROOT_CHANGED' });
    expect(await readFile(join(outside, 'moved', 'photo'), 'utf8')).toBe('original');
    expect(await readFile(file, 'utf8')).toBe('replacement');
  });

  it('detects writes through a pre-opened descriptor during the final authorization recheck', async () => {
    const fs = await import('node:fs/promises');
    const file = join(root, 'photo');
    await writeFile(file, 'original');
    const proof = await snapshotOriginal(file, await collectRootIdentities([root]));
    const writer = await fs.open(file, 'r+');
    let calls = 0;
    try {
      await expect(
        unlinkOriginal(proof, async () => {
          if (++calls === 2) await writer.write('modified', 0, 'utf8');
        }),
      ).rejects.toMatchObject({ code: 'ORIGINAL_CHANGED_DURING_VERIFICATION' });
      expect(await readFile(join(root, '.gallery-deletion-quarantine', proof.quarantineName), 'utf8')).toBe('modified');
    } finally {
      await writer.close();
    }
  });

  it('rechecks bound root identity after capture without relying on a repository callback', async () => {
    const fs = await import('node:fs/promises');
    const allowed = join(root, 'allowed');
    await mkdir(allowed);
    const file = join(allowed, 'photo');
    await writeFile(file, 'original');
    const proof = await snapshotOriginal(file, await collectRootIdentities([allowed]));
    let calls = 0;
    await expect(
      unlinkOriginal(proof, async () => {
        if (++calls !== 2) return;
        await fs.rename(allowed, allowed + '.saved');
        await mkdir(allowed);
        await writeFile(file, 'replacement must survive');
      }),
    ).rejects.toMatchObject({ code: 'DELETION_ROOT_CHANGED' });
    expect(await readFile(file, 'utf8')).toBe('replacement must survive');
    expect(await readFile(join(allowed + '.saved', '.gallery-deletion-quarantine', proof.quarantineName), 'utf8')).toBe(
      'original',
    );
  });
});
