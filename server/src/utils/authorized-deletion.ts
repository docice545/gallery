import { createHash } from 'node:crypto';
import { constants } from 'node:fs';
import fs from 'node:fs/promises';
import { basename, dirname, isAbsolute, relative, resolve, sep } from 'node:path';
import type { DeletionFile } from 'src/schema/tables/asset-deletion.table.js';

// Safe public codes only. Never put original paths, identifiers or fs error messages in API/log output.
export class DeletionError extends Error {
  constructor(public readonly code: string) {
    super(code);
  }
}
export const deletionCode = (error: unknown) =>
  error instanceof DeletionError ? error.code : 'ORIGINAL_DELETE_FAILED';
export const below = (root: string, file: string) => {
  const part = relative(root, file);
  return part !== '' && part !== '..' && !part.startsWith(`..${sep}`) && !isAbsolute(part);
};

// Disposable derivatives use the ordinary repository unlink, but must not
// traverse a symlinked parent into an original-media directory.
export async function verifyDisposablePath(file: string, roots: string[]): Promise<void> {
  const root = roots.find((candidate) => below(candidate, file));
  if (!root || (await fs.realpath(root)) !== root || (await fs.realpath(dirname(file))) !== dirname(file)) {
    throw new DeletionError('DISPOSABLE_PATH_NOT_CANONICAL');
  }
}

export async function validateDeletionRoots(roots: string[], otherRoots: string[]): Promise<void> {
  if (process.platform !== 'linux' || roots.length === 0 || roots.length > 128) {
    throw new DeletionError('UNSUPPORTED_DELETION_SCOPE');
  }
  for (const root of roots) {
    if (!isAbsolute(root) || root !== resolve(root) || root === '/' || (await fs.realpath(root)) !== root) {
      throw new DeletionError('NONCANONICAL_DELETION_ROOT');
    }
    const own = await fs.stat(root, { bigint: true });
    if (!own.isDirectory()) {
      throw new DeletionError('INVALID_DELETION_ROOT');
    }
    // Check lexical containment AND directory identities along ancestors to detect NFS/bind aliases.
    const ancestors = new Set<string>();
    for (let cursor = root; cursor !== '/'; cursor = dirname(cursor)) {
      const value = await fs.stat(cursor, { bigint: true });
      ancestors.add(`${value.dev}:${value.ino}`);
    }
    for (const other of otherRoots) {
      let canonical: string;
      try {
        canonical = await fs.realpath(other);
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
          continue;
        }
        // An inaccessible other owner's scope cannot be proved disjoint.
        throw new DeletionError('OTHER_OWNER_ROOT_UNAVAILABLE');
      }
      if (root === canonical || below(root, canonical) || below(canonical, root)) {
        throw new DeletionError('OVERLAPPING_OWNER_ROOTS');
      }
      const otherStat = await fs.stat(canonical, { bigint: true });
      if (ancestors.has(`${otherStat.dev}:${otherStat.ino}`)) {
        throw new DeletionError('OVERLAPPING_OWNER_ROOTS');
      }
      for (let cursor = canonical; cursor !== '/'; cursor = dirname(cursor)) {
        const value = await fs.stat(cursor, { bigint: true });
        if (value.dev === own.dev && value.ino === own.ino) {
          throw new DeletionError('OVERLAPPING_OWNER_ROOTS');
        }
      }
    }
    // This never creates a probe file. EROFS/EACCES during the real authorized unlink still fail closed.
    await fs.access(root, constants.W_OK | constants.X_OK);
  }
}

async function openParent(file: string, root: string, identity?: DeletionFile) {
  if (!isAbsolute(file) || file !== resolve(file) || !below(root, file)) {
    throw new DeletionError('ORIGINAL_OUTSIDE_AUTHORIZED_ROOT');
  }
  let parent = await fs.open(root, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
  try {
    const stat = await parent.stat({ bigint: true });
    if (identity && (String(stat.dev) !== identity.rootDevice || String(stat.ino) !== identity.rootInode)) {
      throw new DeletionError('DELETION_ROOT_CHANGED');
    }
    for (const component of relative(root, dirname(file)).split(sep)) {
      if (!component) {
        continue;
      }
      const next = await fs.open(
        `/proc/self/fd/${parent.fd}/${component}`,
        constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW,
      );
      await parent.close();
      parent = next;
    }
    return parent;
  } catch (error) {
    await parent.close();
    throw error;
  }
}

export async function snapshotOriginal(file: string, roots: string[]): Promise<DeletionFile> {
  const root = roots.find((candidate) => below(candidate, file));
  if (!root) {
    throw new DeletionError('ORIGINAL_OUTSIDE_AUTHORIZED_ROOT');
  }
  const rootStat = await fs.stat(root, { bigint: true });
  const parent = await openParent(file, root);
  try {
    const handle = await fs.open(
      `/proc/self/fd/${parent.fd}/${basename(file)}`,
      constants.O_RDONLY | constants.O_NOFOLLOW,
    );
    try {
      const before = await handle.stat({ bigint: true });
      if (!before.isFile() || before.nlink !== 1n) {
        throw new DeletionError('ORIGINAL_NOT_EXCLUSIVE_REGULAR_FILE');
      }
      const sha256 = createHash('sha256');
      const sha1 = createHash('sha1');
      // Stream from the opened descriptor; never load a video into RAM.
      for await (const chunk of handle.createReadStream({ autoClose: false })) {
        sha256.update(chunk);
        sha1.update(chunk);
      }
      const after = await handle.stat({ bigint: true });
      if (before.size !== after.size || before.mtimeNs !== after.mtimeNs || before.ctimeNs !== after.ctimeNs) {
        throw new DeletionError('ORIGINAL_CHANGED_DURING_VERIFICATION');
      }
      return {
        path: file,
        root,
        rootDevice: String(rootStat.dev),
        rootInode: String(rootStat.ino),
        device: String(before.dev),
        inode: String(before.ino),
        size: String(before.size),
        modified: String(before.mtimeNs),
        sha256: sha256.digest('hex'),
        sha1: sha1.digest('hex'),
      };
    } finally {
      await handle.close();
    }
  } finally {
    await parent.close();
  }
}

// Called ONLY by the existing Gallery deletion lifecycle after its durable authorization journal exists.
export async function unlinkOriginal(proof: DeletionFile): Promise<void> {
  const parent = await openParent(proof.path, proof.root, proof);
  try {
    const anchored = `/proc/self/fd/${parent.fd}/${basename(proof.path)}`;
    let actual: DeletionFile;
    try {
      actual = await snapshotOriginal(proof.path, [proof.root]);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
        // A committed proof of the previously existing file is required for idempotent recovery.
        return;
      }
      throw error;
    }
    if (
      actual.device !== proof.device ||
      actual.inode !== proof.inode ||
      actual.size !== proof.size ||
      actual.modified !== proof.modified ||
      actual.sha256 !== proof.sha256
    ) {
      throw new DeletionError('ORIGINAL_IDENTITY_CHANGED');
    }
    const current = await fs.lstat(anchored, { bigint: true });
    if (
      !current.isFile() ||
      String(current.dev) !== proof.device ||
      String(current.ino) !== proof.inode ||
      current.nlink !== 1n ||
      String(current.mtimeNs) !== proof.modified
    ) {
      throw new DeletionError('ORIGINAL_IDENTITY_CHANGED');
    }
    await fs.unlink(anchored);
  } finally {
    await parent.close();
  }
}
