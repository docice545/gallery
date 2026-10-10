import { createHash } from 'node:crypto';
import { link, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  DeletionError,
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
  await rm(root, { recursive: true, force: true });
});

describe('existing Gallery worker original-file guards on disposable files', () => {
  it.each(['photo.heic', 'video.mp4', 'motion.jpg'])('streams and removes only the authorized %s', async (name) => {
    const file = join(root, name);
    const other = join(root, 'bystander');
    await writeFile(file, Buffer.alloc(3 * 1024 * 1024, 17));
    await writeFile(other, 'keep');
    const proof = await snapshotOriginal(file, [root]);
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
    const proof = await snapshotOriginal(file, [root]);
    await rm(file);
    await writeFile(file, 'new');
    await expect(unlinkOriginal(proof)).rejects.toMatchObject({ code: 'ORIGINAL_IDENTITY_CHANGED' });
    expect(await readFile(file, 'utf8')).toBe('new');
  });

  it('rejects modification of the same inode', async () => {
    const file = join(root, 'photo');
    await writeFile(file, 'old');
    const proof = await snapshotOriginal(file, [root]);
    await writeFile(file, 'new');
    await expect(unlinkOriginal(proof)).rejects.toBeInstanceOf(DeletionError);
  });

  it('rejects hard-linked files', async () => {
    const file = join(root, 'photo');
    await writeFile(file, 'keep');
    await link(file, join(root, 'other-owner'));
    await expect(snapshotOriginal(file, [root])).rejects.toMatchObject({ code: 'ORIGINAL_NOT_EXCLUSIVE_REGULAR_FILE' });
  });

  it('rejects file and ancestor symlinks', async () => {
    await mkdir(join(root, 'real'));
    await writeFile(join(root, 'real', 'photo'), 'keep');
    await symlink(join(root, 'real'), join(root, 'linked'));
    await symlink(join(root, 'real', 'photo'), join(root, 'photo'));
    await expect(snapshotOriginal(join(root, 'linked', 'photo'), [root])).rejects.toBeDefined();
    await expect(snapshotOriginal(join(root, 'photo'), [root])).rejects.toBeDefined();
    expect(await readFile(join(root, 'real', 'photo'), 'utf8')).toBe('keep');
  });

  it('rejects traversal and prefix sibling roots', async () => {
    await expect(snapshotOriginal(`${root}/../other`, [root])).rejects.toBeDefined();
    await expect(snapshotOriginal(`${root}-sibling/photo`, [root])).rejects.toBeDefined();
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
