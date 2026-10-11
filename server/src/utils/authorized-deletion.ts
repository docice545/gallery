import { createHash, randomUUID } from 'node:crypto';
import { constants } from 'node:fs';
import fs, { type FileHandle } from 'node:fs/promises';
import { basename, dirname, isAbsolute, relative, resolve, sep } from 'node:path';
import type {
  DeletionFile,
  DeletionQuarantineIdentity,
  DeletionRootIdentity,
} from 'src/schema/tables/asset-deletion.table.js';

// Release preflight loads this from the actual compiled image, alongside its migration inventory.
export const AUTHORIZED_DELETION_CAPABILITY = 'bound-root-quarantine-signed-recovery-v1';

export class DeletionError extends Error {
  constructor(public readonly code: string) {
    super(code);
  }
}
export const deletionCode = (error: unknown) =>
  error instanceof DeletionError ? error.code : 'ORIGINAL_DELETE_FAILED';
export const below = (root: string, file: string) => {
  const part = relative(root, file);
  return part !== '' && part !== '..' && !part.startsWith('..' + sep) && !isAbsolute(part);
};

const supported = new Set(['ext4', 'xfs', 'btrfs', 'nfs', 'nfs4', 'overlay', 'tmpfs']);
const quarantine = '.gallery-deletion-quarantine';
const anchored = (fd: number, name: string) => '/proc/self/fd/' + fd + '/' + name;
const decodeMount = (value: string) =>
  value.replaceAll(/\\([0-7]{3})/g, (_, octal: string) => String.fromCodePoint(Number.parseInt(octal, 8)));

// Walk from /, never from a path containing an unchecked ancestor. Every directory stays fd-anchored.
async function openAbsoluteDirectory(path: string): Promise<FileHandle> {
  if (process.platform !== 'linux' || !isAbsolute(path) || path !== resolve(path) || path === '/') {
    throw new DeletionError('NONCANONICAL_DELETION_ROOT');
  }
  let handle = await fs.open('/', constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
  try {
    for (const component of path.split(sep)) {
      if (!component) continue;
      const next = await fs.open(
        anchored(handle.fd, component),
        constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW,
      );
      await handle.close();
      handle = next;
    }
    return handle;
  } catch {
    await handle.close();
    throw new DeletionError('DELETION_ROOT_CHANGED');
  }
}

async function identity(handle: FileHandle, path: string): Promise<DeletionRootIdentity> {
  const stat = await handle.stat({ bigint: true });
  const info = await fs.readFile('/proc/self/fdinfo/' + handle.fd, 'utf8');
  const mountId = /^mnt_id:\s*(\d+)$/m.exec(info)?.[1];
  const namespace = await fs.readlink('/proc/self/ns/mnt');
  const mountInfo = await fs.readFile('/proc/self/mountinfo', 'utf8');
  const line = mountInfo.split('\n').find((line) => line.startsWith(mountId + ' '));
  if (!stat.isDirectory() || !mountId || !line) throw new DeletionError('UNSUPPORTED_DELETION_FILESYSTEM');
  const [left, right] = line.split(' - ', 2);
  const fields = left.split(' ');
  const source = right?.split(' ', 3);
  if (!source || !supported.has(source[0])) throw new DeletionError('UNSUPPORTED_DELETION_FILESYSTEM');
  return {
    path,
    device: String(stat.dev),
    inode: String(stat.ino),
    mountId,
    mountNamespace: namespace,
    mountType: source[0],
    mountSource: decodeMount(source[1]),
    mountRoot: decodeMount(fields[3]),
    mountTarget: decodeMount(fields[4]),
  };
}

export const sameRootIdentity = (a: DeletionRootIdentity, b: DeletionRootIdentity) =>
  (
    [
      'path',
      'device',
      'inode',
      'mountId',
      'mountNamespace',
      'mountType',
      'mountSource',
      'mountRoot',
      'mountTarget',
    ] as const
  ).every((key) => a[key] === b[key]);

export async function collectRootIdentities(roots: string[]): Promise<DeletionRootIdentity[]> {
  if (roots.length === 0 || roots.length > 128 || new Set(roots).size !== roots.length)
    throw new DeletionError('UNSUPPORTED_DELETION_SCOPE');
  const result: DeletionRootIdentity[] = [];
  for (const root of roots) {
    const handle = await openAbsoluteDirectory(root);
    try {
      result.push(await identity(handle, root));
    } finally {
      await handle.close();
    }
  }
  return result;
}

async function openRoot(root: DeletionRootIdentity): Promise<FileHandle> {
  if (!root || !root.mountId || !root.mountNamespace) throw new DeletionError('DELETION_ROOT_CHANGED');
  const handle = await openAbsoluteDirectory(root.path);
  try {
    if (!sameRootIdentity(await identity(handle, root.path), root)) throw new DeletionError('DELETION_ROOT_CHANGED');
    return handle;
  } catch (error) {
    await handle.close();
    throw error;
  }
}

const overlapping = (a: string, b: string) => a === b || below(a, b) || below(b, a);
const isNfs = (root: DeletionRootIdentity) => root.mountType === 'nfs' || root.mountType === 'nfs4';

function mountCoordinate(root: DeletionRootIdentity): string {
  if (
    !isAbsolute(root.mountRoot) ||
    root.mountRoot !== resolve(root.mountRoot) ||
    !isAbsolute(root.mountTarget) ||
    root.mountTarget !== resolve(root.mountTarget) ||
    !isAbsolute(root.path) ||
    root.path !== resolve(root.path) ||
    (root.path !== root.mountTarget && !below(root.mountTarget, root.path))
  )
    throw new DeletionError('UNSUPPORTED_DELETION_FILESYSTEM');
  return resolve(root.mountRoot, relative(root.mountTarget, root.path));
}

function nfsCoordinate(root: DeletionRootIdentity) {
  // Separate NFS exports can have different st_dev values. Their export paths
  // must be included; different server spellings are not proof of separation.
  const source = /^(\[[^\]]+\]|[^:/\s]+):(\/.*)$/.exec(root.mountSource);
  if (!source || source[2] !== resolve(source[2])) throw new DeletionError('UNSUPPORTED_DELETION_FILESYSTEM');
  return { server: source[1].toLowerCase(), path: resolve(source[2], '.' + mountCoordinate(root)) };
}

// Mount IDs differ for bind aliases; inode comparison alone misses a bind of a
// descendant directory. Compare the roots in their backing filesystem instead.
export function assertDisjointDeletionRootMounts(root: DeletionRootIdentity, other: DeletionRootIdentity): void {
  if (root.mountNamespace !== other.mountNamespace) throw new DeletionError('UNSUPPORTED_DELETION_FILESYSTEM');
  const own = mountCoordinate(root),
    theirs = mountCoordinate(other);
  if (isNfs(root) && isNfs(other)) {
    const ownNfs = nfsCoordinate(root),
      otherNfs = nfsCoordinate(other);
    if (ownNfs.server !== otherNfs.server) throw new DeletionError('UNSUPPORTED_DELETION_FILESYSTEM');
    if (overlapping(ownNfs.path, otherNfs.path)) throw new DeletionError('OVERLAPPING_OWNER_ROOTS');
    return;
  }
  if (root.device === other.device && overlapping(own, theirs)) throw new DeletionError('OVERLAPPING_OWNER_ROOTS');
  if (root.device !== other.device && (root.mountType === 'overlay' || other.mountType === 'overlay'))
    throw new DeletionError('UNSUPPORTED_DELETION_FILESYSTEM');
}

export async function validateDeletionRoots(roots: string[], otherRoots: string[]): Promise<DeletionRootIdentity[]> {
  const identities = await collectRootIdentities(roots);
  const mountInfo = await fs.readFile('/proc/self/mountinfo', 'utf8');
  if (mountInfo.length > 4 * 1024 * 1024) throw new DeletionError('UNSUPPORTED_DELETION_FILESYSTEM');
  const mountLines = mountInfo.split('\n').filter(Boolean);
  if (mountLines.length > 4096) throw new DeletionError('UNSUPPORTED_DELETION_FILESYSTEM');
  const mountTargets = mountLines.map((line) => decodeMount(line.split(' - ', 1)[0].split(' ', 5)[4]));
  const otherIdentities = new Map<string, DeletionRootIdentity>();
  const descendantTargets = new Set<string>();
  for (const rootIdentity of identities) {
    const root = rootIdentity.path;
    const own = await fs.stat(root, { bigint: true });
    const ancestors = new Set<string>();
    for (let cursor = root; cursor !== '/'; cursor = dirname(cursor)) {
      const value = await fs.stat(cursor, { bigint: true });
      ancestors.add(String(value.dev) + ':' + value.ino);
    }
    for (const other of otherRoots) {
      let canonical: string;
      try {
        canonical = await fs.realpath(other);
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === 'ENOENT') continue;
        throw new DeletionError('OTHER_OWNER_ROOT_UNAVAILABLE');
      }
      if (root === canonical || below(root, canonical) || below(canonical, root))
        throw new DeletionError('OVERLAPPING_OWNER_ROOTS');
      // A bind alias can also sit below the other owner's root, whose own
      // identity still looks disjoint. Check every visible descendant mount.
      const descendants = mountTargets.filter((target) => below(canonical, target));
      for (const target of descendants) descendantTargets.add(target);
      if (descendantTargets.size > 128) throw new DeletionError('UNSUPPORTED_DELETION_FILESYSTEM');
      for (const target of new Set([canonical, ...descendants])) {
        let otherIdentity = otherIdentities.get(target);
        if (!otherIdentity) {
          const otherHandle = await openAbsoluteDirectory(target);
          try {
            otherIdentity = await identity(otherHandle, target);
            otherIdentities.set(target, otherIdentity);
          } finally {
            await otherHandle.close();
          }
        }
        assertDisjointDeletionRootMounts(rootIdentity, otherIdentity);
      }
      const otherStat = await fs.stat(canonical, { bigint: true });
      if (ancestors.has(String(otherStat.dev) + ':' + otherStat.ino))
        throw new DeletionError('OVERLAPPING_OWNER_ROOTS');
      for (let cursor = canonical; cursor !== '/'; cursor = dirname(cursor)) {
        const value = await fs.stat(cursor, { bigint: true });
        if (value.dev === own.dev && value.ino === own.ino) throw new DeletionError('OVERLAPPING_OWNER_ROOTS');
      }
    }
    await fs.access(root, constants.W_OK | constants.X_OK);
  }
  // Reopen and compare so validation cannot publish a different root than the checked one.
  for (const root of identities) {
    const handle = await openRoot(root);
    await handle.close();
  }
  return identities;
}

export async function verifyDisposablePath(file: string, roots: string[]): Promise<void> {
  const root = roots.find((candidate) => below(candidate, file));
  if (!root || (await fs.realpath(root)) !== root || (await fs.realpath(dirname(file))) !== dirname(file))
    throw new DeletionError('DISPOSABLE_PATH_NOT_CANONICAL');
}

async function openParent(file: string, root: DeletionRootIdentity): Promise<FileHandle> {
  if (
    !isAbsolute(file) ||
    file !== resolve(file) ||
    !below(root.path, file) ||
    relative(root.path, file).split(sep).includes(quarantine)
  ) {
    throw new DeletionError('ORIGINAL_OUTSIDE_AUTHORIZED_ROOT');
  }
  let parent = await openRoot(root);
  try {
    for (const component of relative(root.path, dirname(file)).split(sep)) {
      if (!component) continue;
      const next = await fs.open(
        anchored(parent.fd, component),
        constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW,
      );
      try {
        const nextIdentity = await identity(next, root.path);
        if (
          nextIdentity.mountId !== root.mountId ||
          nextIdentity.mountNamespace !== root.mountNamespace ||
          nextIdentity.device !== root.device
        ) {
          throw new DeletionError('DELETION_ROOT_CHANGED');
        }
      } catch (error) {
        await next.close();
        throw error;
      }
      await parent.close();
      parent = next;
    }
    return parent;
  } catch (error) {
    await parent.close();
    throw error;
  }
}

async function hashFile(
  parent: FileHandle,
  name: string,
  root: DeletionRootIdentity,
  file: string,
): Promise<DeletionFile> {
  const handle = await fs.open(
    anchored(parent.fd, name),
    constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
  );
  try {
    const before = await handle.stat({ bigint: true });
    if (!before.isFile() || before.nlink !== 1n || String(before.dev) !== root.device)
      throw new DeletionError('ORIGINAL_NOT_EXCLUSIVE_REGULAR_FILE');
    const mountId = /^mnt_id:\s*(\d+)$/m.exec(await fs.readFile('/proc/self/fdinfo/' + handle.fd, 'utf8'))?.[1];
    if (mountId !== root.mountId) throw new DeletionError('DELETION_ROOT_CHANGED');
    const sha256 = createHash('sha256'),
      sha1 = createHash('sha1');
    for await (const chunk of handle.createReadStream({ autoClose: false })) {
      sha256.update(chunk);
      sha1.update(chunk);
    }
    const after = await handle.stat({ bigint: true });
    if (before.size !== after.size || before.mtimeNs !== after.mtimeNs || before.ctimeNs !== after.ctimeNs)
      throw new DeletionError('ORIGINAL_CHANGED_DURING_VERIFICATION');
    return {
      path: file,
      root: root.path,
      rootDevice: root.device,
      rootInode: root.inode,
      device: String(before.dev),
      inode: String(before.ino),
      size: String(before.size),
      modified: String(before.mtimeNs),
      sha256: sha256.digest('hex'),
      sha1: sha1.digest('hex'),
      rootIdentity: root,
      quarantineName: randomUUID(),
    };
  } finally {
    await handle.close();
  }
}

export async function snapshotOriginal(file: string, roots: DeletionRootIdentity[]): Promise<DeletionFile> {
  const root = roots.find((candidate) => below(candidate.path, file));
  if (!root) throw new DeletionError('ORIGINAL_OUTSIDE_AUTHORIZED_ROOT');
  const parent = await openParent(file, root);
  try {
    return await hashFile(parent, basename(file), root, file);
  } finally {
    await parent.close();
  }
}

const matches = (actual: DeletionFile, proof: DeletionFile) =>
  actual.device === proof.device &&
  actual.inode === proof.inode &&
  actual.size === proof.size &&
  actual.modified === proof.modified &&
  actual.sha256 === proof.sha256;

const QUARANTINE_KEYS = ['device', 'inode', 'mountId', 'mountNamespace', 'uid', 'gid'] as const;

export function validQuarantineIdentity(value: unknown): value is DeletionQuarantineIdentity {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const entry = value as Record<string, unknown>;
  return (
    Object.keys(entry).length === QUARANTINE_KEYS.length &&
    QUARANTINE_KEYS.every((key) => typeof entry[key] === 'string') &&
    ['device', 'inode', 'mountId', 'uid', 'gid'].every((key) => /^(?:0|[1-9]\d*)$/.test(entry[key] as string)) &&
    /^mnt:\[\d+\]$/.test(entry.mountNamespace as string)
  );
}

export const sameQuarantineIdentity = (a: unknown, b: unknown) =>
  validQuarantineIdentity(a) && validQuarantineIdentity(b) && QUARANTINE_KEYS.every((key) => a[key] === b[key]);

async function quarantineIdentity(handle: FileHandle, root: DeletionRootIdentity): Promise<DeletionQuarantineIdentity> {
  const stat = await handle.stat({ bigint: true });
  if (!stat.isDirectory()) throw new DeletionError('DELETION_QUARANTINE_CONFLICT');
  const actual = await identity(handle, root.path);
  if (!sameRootIdentity(actual, { ...root, inode: String(stat.ino) }))
    throw new DeletionError('DELETION_QUARANTINE_CONFLICT');
  return {
    device: String(stat.dev),
    inode: String(stat.ino),
    mountId: actual.mountId,
    mountNamespace: actual.mountNamespace,
    uid: String(stat.uid),
    gid: String(stat.gid),
  };
}

async function verifyCurrentQuarantine(
  rootIdentity: DeletionRootIdentity,
  expected: DeletionQuarantineIdentity,
  mode: bigint,
): Promise<void> {
  const root = await openRoot(rootIdentity);
  try {
    const current = await fs.open(
      anchored(root.fd, quarantine),
      constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW,
    );
    try {
      const stat = await current.stat({ bigint: true });
      if (
        stat.mode !== mode ||
        String(stat.uid) !== expected.uid ||
        String(stat.gid) !== expected.gid ||
        !sameRootIdentity(await identity(current, rootIdentity.path), {
          ...rootIdentity,
          device: expected.device,
          inode: expected.inode,
          mountId: expected.mountId,
          mountNamespace: expected.mountNamespace,
        })
      )
        throw new DeletionError('DELETION_QUARANTINE_CONFLICT');
    } finally {
      await current.close();
    }
  } finally {
    await root.close();
  }
}

// The caller commits the returned binding in the policy and receipt BEFORE
// calling unlinkOriginal. Never adopt an unregistered EEXIST directory.
export async function bindQuarantine(bound: DeletionRootIdentity): Promise<DeletionRootIdentity> {
  const root = await openRoot(bound);
  let q: FileHandle | undefined;
  try {
    const qpath = anchored(root.fd, quarantine);
    const existing = bound.quarantineIdentity;
    if (!existing) {
      try {
        await fs.mkdir(qpath, { mode: 0o700 });
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === 'EEXIST') throw new DeletionError('DELETION_QUARANTINE_CONFLICT');
        throw error;
      }
    } else if (!validQuarantineIdentity(existing)) {
      throw new DeletionError('DELETION_QUARANTINE_CONFLICT');
    }
    const entry = await fs.lstat(qpath, { bigint: true });
    q = await fs.open(qpath, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
    const stat = await q.stat({ bigint: true });
    if (
      !entry.isDirectory() ||
      !stat.isDirectory() ||
      entry.dev !== stat.dev ||
      entry.ino !== stat.ino ||
      entry.uid !== stat.uid ||
      entry.gid !== stat.gid ||
      String(stat.dev) !== bound.device
    )
      throw new DeletionError('DELETION_QUARANTINE_CONFLICT');
    const captured = await quarantineIdentity(q, bound);
    if (existing) {
      if (!sameQuarantineIdentity(existing, captured) || (stat.mode & 0o7777n) !== 0o700n)
        throw new DeletionError('DELETION_QUARANTINE_CONFLICT');
      await verifyCurrentQuarantine(bound, existing, stat.mode);
      return bound;
    }
    // Local filesystems retain the process UID guard. On NFS, creation plus
    // descriptor chmod proves control of the mapped principal; record that
    // actual UID/GID, rather than assuming it equals the container UID/GID.
    const entries = await fs.readdir('/proc/self/fd/' + q.fd);
    if ((!isNfs(bound) && Number(stat.uid) !== process.getuid?.()) || entries.length > 0)
      throw new DeletionError('DELETION_QUARANTINE_CONFLICT');
    await verifyCurrentQuarantine(bound, captured, stat.mode);
    await q.chmod(0o700);
    if (!sameQuarantineIdentity(await quarantineIdentity(q, bound), captured))
      throw new DeletionError('DELETION_QUARANTINE_CONFLICT');
    await verifyCurrentQuarantine(bound, captured, BigInt(constants.S_IFDIR | 0o700));
    const securedEntries = await fs.readdir('/proc/self/fd/' + q.fd);
    if (securedEntries.length > 0) throw new DeletionError('DELETION_QUARANTINE_CONFLICT');
    await q.sync();
    await root.sync();
    return { ...bound, quarantineIdentity: captured };
  } finally {
    await q?.close();
    await root.close();
  }
}

// Capture the entry by atomic rename into a private, fd-anchored directory BEFORE validation/unlink.
// Unlike check-then-unlink on a public basename, a swapped source entry is never destroyed:
// the capture is validated, mismatch is restored without overwrite (hard-link+unlink), or retained for recovery.
// The random quarantine name is committed in the DB receipt before this routine runs.
export async function unlinkOriginal(
  proof: DeletionFile,
  beforeUnlink: () => Promise<void> = async () => {},
): Promise<void> {
  if (
    !proof.rootIdentity ||
    !validQuarantineIdentity(proof.rootIdentity.quarantineIdentity) ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(proof.quarantineName)
  )
    throw new DeletionError('NO_ORIGINAL_IDENTITY_PROOF');
  const root = await openRoot(proof.rootIdentity);
  let q: FileHandle | undefined;
  let parent: FileHandle | undefined;
  try {
    const qpath = anchored(root.fd, quarantine);
    q = await fs.open(qpath, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
    const qs = await q.stat({ bigint: true });
    const qi = proof.rootIdentity.quarantineIdentity;
    if ((qs.mode & 0o7777n) !== 0o700n || !sameQuarantineIdentity(await quarantineIdentity(q, proof.rootIdentity), qi))
      throw new DeletionError('DELETION_QUARANTINE_CONFLICT');
    await verifyCurrentQuarantine(proof.rootIdentity, qi, qs.mode);
    const captured = anchored(q.fd, proof.quarantineName);
    try {
      await fs.lstat(captured);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
      parent = await openParent(proof.path, proof.rootIdentity);
      // Validate before capture for normal failures; validate AGAIN after capture to defeat a source race.
      try {
        const original = await hashFile(parent, basename(proof.path), proof.rootIdentity, proof.path);
        if (!matches(original, proof)) throw new DeletionError('ORIGINAL_IDENTITY_CHANGED');
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === 'ENOENT') return;
        throw error;
      }
      await beforeUnlink();
      const currentParent = await openParent(proof.path, proof.rootIdentity);
      try {
        const previous = await parent.stat({ bigint: true });
        const current = await currentParent.stat({ bigint: true });
        if (previous.dev !== current.dev || previous.ino !== current.ino)
          throw new DeletionError('DELETION_ROOT_CHANGED');
      } finally {
        await currentParent.close();
      }
      // The policy wait must not let a changed owner, mode or namespace expose
      // the original by moving it into a directory that is no longer private.
      await verifyCurrentQuarantine(proof.rootIdentity, qi, qs.mode);
      await fs.rename(anchored(parent.fd, basename(proof.path)), captured);
      await parent.sync();
      await q.sync();
    }
    try {
      // Also require directory durability on a resumed capture. An NFS server
      // which rejects fsync must not reach unlink just because the first
      // attempt left a valid quarantine entry behind. Rehash AFTER this wait.
      await q.sync();
      const actual = await hashFile(q, proof.quarantineName, proof.rootIdentity, proof.path);
      if (!matches(actual, proof)) throw new DeletionError('ORIGINAL_IDENTITY_CHANGED');
      const before = await fs.lstat(captured, { bigint: true });
      await beforeUnlink();
      // Reopen from / again even when the caller has no policy callback. The
      // root/quarantine namespace must still be the one admitted by the proof.
      await verifyCurrentQuarantine(proof.rootIdentity, qi, qs.mode);
      const after = await fs.lstat(captured, { bigint: true });
      if (
        !after.isFile() ||
        after.nlink !== 1n ||
        before.dev !== after.dev ||
        before.ino !== after.ino ||
        before.size !== after.size ||
        before.mtimeNs !== after.mtimeNs ||
        before.ctimeNs !== after.ctimeNs
      )
        throw new DeletionError('ORIGINAL_CHANGED_DURING_VERIFICATION');
      await fs.unlink(captured);
      await q.sync();
    } catch (error) {
      // If capture raced a writer, recover the unexpected entry, never overwrite another live entry.
      if (error instanceof DeletionError && error.code === 'ORIGINAL_IDENTITY_CHANGED' && parent) {
        try {
          await fs.link(captured, anchored(parent.fd, basename(proof.path)));
          await fs.unlink(captured);
        } catch {
          /* retained under the durable quarantine name; no unsafe overwrite or guessed deletion */
        }
      }
      throw error;
    }
  } finally {
    await parent?.close();
    await q?.close();
    await root.close();
  }
}
