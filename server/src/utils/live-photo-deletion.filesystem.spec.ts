import fs, { type FileHandle, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { StorageCore } from 'src/cores/storage.core.js';
import { AssetType, StorageFolder } from 'src/enum.js';
import {
  DeletionError,
  bindQuarantine,
  collectRootIdentities,
  snapshotOriginal,
  unlinkOriginal,
} from 'src/utils/authorized-deletion.js';
import { assertExclusiveLivePhoto, managedMotionRootPath } from 'src/utils/live-photo-deletion.js';

const ownerId = '11111111-1111-4111-8111-111111111111';
const otherOwnerId = '22222222-2222-4222-8222-222222222222';
const parentId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const motionId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
let directory: string;
let motionPath: string;
let encodedRoot: string;

beforeEach(async () => {
  directory = await mkdtemp(join(tmpdir(), 'gallery-live-photo-filesystem-'));
  StorageCore.setMediaLocation(directory);
  motionPath = StorageCore.getAndroidMotionPath({ id: motionId, ownerId }, motionId);
  encodedRoot = StorageCore.getFolderLocation(StorageFolder.EncodedVideo, ownerId);
  await mkdir(dirname(motionPath), { recursive: true });
  await writeFile(motionPath, 'synthetic motion original');
});

afterEach(async () => {
  vi.restoreAllMocks();
  await rm(directory, { recursive: true, force: true });
});

const rootForMotion = () => {
  assertExclusiveLivePhoto(
    { id: parentId, ownerId, libraryId: null, type: AssetType.Image, livePhotoVideoId: motionId },
    { id: motionId, ownerId, libraryId: null, type: AssetType.Video, originalPath: motionPath },
    [parentId],
    ownerId,
    null,
  );
  const root = managedMotionRootPath(ownerId, null, motionPath, motionId);
  if (!root) throw new Error('test generated path must have a strict managed motion root');
  return root;
};

const preparedMotion = async () => {
  const [identity] = await collectRootIdentities([rootForMotion()]);
  const bound = await bindQuarantine(identity);
  return snapshotOriginal(motionPath, [bound]);
};

const onQuarantineOpen = (callback: (handle: FileHandle) => void) => {
  const openActual = fs.open;
  vi.spyOn(fs, 'open').mockImplementation(async (path, flags, mode) => {
    const handle = await openActual(path, flags, mode);
    if (String(path).endsWith('/.gallery-deletion-quarantine')) callback(handle);
    return handle;
  });
};

describe('synthetic Live Photo originals through real descriptor-relative filesystem operations', () => {
  it('removes the linked image and motion original from separate bounded roots without granting their parent', async () => {
    const imageRoot = join(directory, 'upload', ownerId);
    const imagePath = join(imageRoot, 'synthetic.jpg');
    await mkdir(imageRoot, { recursive: true });
    await writeFile(imagePath, 'synthetic image original');
    const [imageIdentity] = await collectRootIdentities([imageRoot]);
    const imageProof = await snapshotOriginal(imagePath, [await bindQuarantine(imageIdentity)]);
    const motionProof = await preparedMotion();
    await unlinkOriginal(imageProof);
    await unlinkOriginal(motionProof);
    await expect(readFile(imagePath)).rejects.toHaveProperty('code', 'ENOENT');
    await expect(readFile(motionPath)).rejects.toHaveProperty('code', 'ENOENT');
    expect(motionProof.root).toBe(encodedRoot);
    expect(imageProof.root).toBe(imageRoot);
  });

  it('does not authorize another owner physical original under the motion root', async () => {
    const other = StorageCore.getAndroidMotionPath({ id: motionId, ownerId: otherOwnerId }, motionId);
    await mkdir(dirname(other), { recursive: true });
    await writeFile(other, 'other owner must survive');
    await expect(snapshotOriginal(other, await collectRootIdentities([rootForMotion()]))).rejects.toMatchObject({
      code: 'ORIGINAL_OUTSIDE_AUTHORIZED_ROOT',
    });
    expect(await readFile(other, 'utf8')).toBe('other owner must survive');
  });

  it('rejects a symlink in the motion original path without touching its target', async () => {
    const outside = join(directory, 'outside.mp4');
    await writeFile(outside, 'outside original');
    await rm(motionPath);
    await symlink(outside, motionPath);
    await expect(snapshotOriginal(motionPath, await collectRootIdentities([rootForMotion()]))).rejects.toBeDefined();
    expect(await readFile(outside, 'utf8')).toBe('outside original');
  });

  it('rejects ancestor symlink substitution before creating an SSD proof', async () => {
    const identities = await collectRootIdentities([rootForMotion()]);
    const encodedParent = dirname(encodedRoot);
    const saved = encodedParent + '.saved';
    await fs.rename(encodedParent, saved);
    await mkdir(join(directory, 'outside', ownerId), { recursive: true });
    await symlink(join(directory, 'outside'), encodedParent);
    await expect(snapshotOriginal(motionPath, identities)).rejects.toMatchObject({ code: 'DELETION_ROOT_CHANGED' });
    expect(
      await readFile(
        motionPath.replace(encodedParent, () => saved),
        'utf8',
      ),
    ).toBe('synthetic motion original');
  });

  it('rejects a replaced root after snapshot and preserves both original and replacement', async () => {
    const proof = await preparedMotion();
    await fs.rename(encodedRoot, encodedRoot + '.saved');
    await mkdir(dirname(motionPath), { recursive: true });
    await writeFile(motionPath, 'replacement must survive');
    await expect(unlinkOriginal(proof)).rejects.toMatchObject({ code: 'DELETION_ROOT_CHANGED' });
    expect(await readFile(motionPath, 'utf8')).toBe('replacement must survive');
    expect(
      await readFile(
        motionPath.replace(encodedRoot, () => encodedRoot + '.saved'),
        'utf8',
      ),
    ).toBe('synthetic motion original');
  });

  it('rejects an inode replacement after snapshot', async () => {
    const proof = await preparedMotion();
    await fs.rename(motionPath, motionPath + '.saved');
    await writeFile(motionPath, 'replacement must survive');
    await expect(unlinkOriginal(proof)).rejects.toMatchObject({ code: 'ORIGINAL_IDENTITY_CHANGED' });
    expect(await readFile(motionPath, 'utf8')).toBe('replacement must survive');
    expect(await readFile(motionPath + '.saved', 'utf8')).toBe('synthetic motion original');
  });

  it('blocks traversal before any original is moved', async () => {
    expect(() => managedMotionRootPath(ownerId, null, motionPath + '/../unrelated.mp4', motionId)).toThrow();
    await expect(
      snapshotOriginal(`${encodedRoot}/../${otherOwnerId}/photo`, await collectRootIdentities([encodedRoot])),
    ).rejects.toBeDefined();
    expect(await readFile(motionPath, 'utf8')).toBe('synthetic motion original');
  });

  it('rejects a changed filesystem mount identity', async () => {
    const [identity] = await collectRootIdentities([rootForMotion()]);
    await expect(snapshotOriginal(motionPath, [{ ...identity, mountId: 'different-mount' }])).rejects.toMatchObject({
      code: 'DELETION_ROOT_CHANGED',
    });
    expect(await readFile(motionPath, 'utf8')).toBe('synthetic motion original');
  });

  it('does not adopt an unregistered existing SSD quarantine', async () => {
    await mkdir(join(encodedRoot, '.gallery-deletion-quarantine'), { mode: 0o700 });
    const [identity] = await collectRootIdentities([rootForMotion()]);
    await expect(bindQuarantine(identity)).rejects.toMatchObject({ code: 'DELETION_QUARANTINE_CONFLICT' });
    expect(await readFile(motionPath, 'utf8')).toBe('synthetic motion original');
  });

  it('preserves the original when descriptor chmod fails', async () => {
    onQuarantineOpen((handle) => {
      vi.spyOn(handle, 'chmod').mockRejectedValue(
        Object.assign(new Error('synthetic chmod failure'), { code: 'EPERM' }),
      );
    });
    const [identity] = await collectRootIdentities([rootForMotion()]);
    await expect(bindQuarantine(identity)).rejects.toHaveProperty('code', 'EPERM');
    expect(await readFile(motionPath, 'utf8')).toBe('synthetic motion original');
  });

  it('preserves the original when quarantine fsync fails', async () => {
    onQuarantineOpen((handle) => {
      vi.spyOn(handle, 'sync').mockRejectedValue(Object.assign(new Error('synthetic fsync failure'), { code: 'EIO' }));
    });
    const [identity] = await collectRootIdentities([rootForMotion()]);
    await expect(bindQuarantine(identity)).rejects.toHaveProperty('code', 'EIO');
    expect(await readFile(motionPath, 'utf8')).toBe('synthetic motion original');
  });

  it('checks owner consent again before moving a motion original', async () => {
    const proof = await preparedMotion();
    await expect(
      unlinkOriginal(proof, () => Promise.reject(new DeletionError('LIBRARY_DELETION_NOT_AUTHORIZED'))),
    ).rejects.toMatchObject({ code: 'LIBRARY_DELETION_NOT_AUTHORIZED' });
    expect(await readFile(motionPath, 'utf8')).toBe('synthetic motion original');
    expect(await fs.readdir(join(encodedRoot, '.gallery-deletion-quarantine'))).toEqual([]);
  });

  it('retains the exact journal-named original after interruption and resumes without guessing', async () => {
    const proof = await preparedMotion();
    let checks = 0;
    await expect(
      unlinkOriginal(proof, () => {
        if (++checks === 2) return Promise.reject(new DeletionError('SIMULATED_OWNER_CHECK_INTERRUPTION'));
        return Promise.resolve();
      }),
    ).rejects.toMatchObject({ code: 'SIMULATED_OWNER_CHECK_INTERRUPTION' });
    const captured = join(encodedRoot, '.gallery-deletion-quarantine', proof.quarantineName);
    expect(await readFile(captured, 'utf8')).toBe('synthetic motion original');
    await expect(readFile(motionPath)).rejects.toHaveProperty('code', 'ENOENT');
    await unlinkOriginal(JSON.parse(JSON.stringify(proof)));
    await expect(readFile(captured)).rejects.toHaveProperty('code', 'ENOENT');
  });

  it('captures a last-moment replacement but never destroys it', async () => {
    const proof = await preparedMotion();
    let checks = 0;
    await expect(
      unlinkOriginal(proof, async () => {
        if (checks++ !== 0) return;
        await fs.rename(motionPath, motionPath + '.saved');
        await writeFile(motionPath, 'raced replacement must survive');
      }),
    ).rejects.toMatchObject({ code: 'ORIGINAL_IDENTITY_CHANGED' });
    expect(await readFile(motionPath, 'utf8')).toBe('raced replacement must survive');
    expect(await readFile(motionPath + '.saved', 'utf8')).toBe('synthetic motion original');
  });

  it('refuses a hard-linked motion original while preserving all shared bytes', async () => {
    const alias = join(directory, 'another-owner-reference.mp4');
    await fs.link(motionPath, alias);
    await expect(snapshotOriginal(motionPath, await collectRootIdentities([rootForMotion()]))).rejects.toMatchObject({
      code: 'ORIGINAL_NOT_EXCLUSIVE_REGULAR_FILE',
    });
    expect(await readFile(motionPath, 'utf8')).toBe('synthetic motion original');
    expect(await readFile(alias, 'utf8')).toBe('synthetic motion original');
  });
});
