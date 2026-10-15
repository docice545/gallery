import { join } from 'node:path';
import { StorageCore } from 'src/cores/storage.core.js';
import { AssetType, StorageFolder } from 'src/enum.js';
import { assertExclusiveLivePhoto, managedMotionRootPath } from 'src/utils/live-photo-deletion.js';

const ownerId = '11111111-1111-4111-8111-111111111111';
const otherOwnerId = '22222222-2222-4222-8222-222222222222';
const parentId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const motionId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const libraryId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

const parent = () => ({ id: parentId, ownerId, libraryId: null, type: AssetType.Image, livePhotoVideoId: motionId });
const child = () => ({
  id: motionId,
  ownerId,
  libraryId: null,
  type: AssetType.Video,
  originalPath: StorageCore.getAndroidMotionPath({ id: motionId, ownerId }, motionId),
});

beforeEach(() => {
  StorageCore.setMediaLocation('/synthetic-gallery');
});

describe('Live Photo pair authorization', () => {
  it('accepts the exclusively linked managed motion asset', () => {
    expect(() => assertExclusiveLivePhoto(parent(), child(), [parentId], ownerId, null)).not.toThrow();
  });

  it('accepts an exclusive pair in the same external library without granting a managed root', () => {
    const image = { ...parent(), libraryId };
    const video = { ...child(), libraryId };
    expect(() => assertExclusiveLivePhoto(image, video, [parentId], ownerId, libraryId)).not.toThrow();
  });

  it.each([
    ['motion owner', () => [parent(), { ...child(), ownerId: otherOwnerId }, ownerId, null] as const],
    ['image owner', () => [{ ...parent(), ownerId: otherOwnerId }, child(), ownerId, null] as const],
    ['request owner', () => [parent(), child(), otherOwnerId, null] as const],
    ['motion library', () => [parent(), { ...child(), libraryId }, ownerId, null] as const],
    ['image library', () => [{ ...parent(), libraryId }, child(), ownerId, null] as const],
    ['request library', () => [parent(), child(), ownerId, libraryId] as const],
    ['motion type', () => [parent(), { ...child(), type: AssetType.Image }, ownerId, null] as const],
    ['link target', () => [{ ...parent(), livePhotoVideoId: parentId }, child(), ownerId, null] as const],
    [
      'self-referencing motion',
      () => [{ ...parent(), livePhotoVideoId: parentId }, { ...child(), id: parentId }, ownerId, null] as const,
    ],
  ])('rejects a mismatched %s', (_label, make) => {
    const [image, video, requestOwner, requestLibrary] = make();
    expect(() => assertExclusiveLivePhoto(image, video, [parentId], requestOwner, requestLibrary)).toThrowError(
      'MOTION_SCOPE_MISMATCH',
    );
  });

  it.each([
    ['missing', []],
    ['another parent', [motionId]],
    ['two parents', [parentId, motionId]],
    ['duplicated reference', [parentId, parentId]],
  ])('rejects %s live-photo references', (_label, references) => {
    expect(() => assertExclusiveLivePhoto(parent(), child(), references, ownerId, null)).toThrowError(
      'ORIGINAL_SHARED_WITH_OTHER_ASSET',
    );
  });
});

describe('strict managed motion storage mapping', () => {
  it('returns only the exact encoded-video owner directory for the canonical generated asset path', () => {
    expect(managedMotionRootPath(ownerId, null, child().originalPath, motionId)).toBe(
      StorageCore.getFolderLocation(StorageFolder.EncodedVideo, ownerId),
    );
  });

  it('leaves an ordinary managed original under the existing policy', () => {
    expect(
      managedMotionRootPath(ownerId, null, `/synthetic-gallery/upload/${ownerId}/video.mp4`, motionId),
    ).toBeUndefined();
  });

  it('does not grant another owner encoded-video directory', () => {
    const other = StorageCore.getAndroidMotionPath({ id: motionId, ownerId: otherOwnerId }, motionId);
    expect(managedMotionRootPath(ownerId, null, other, motionId)).toBeUndefined();
  });

  it('does not grant a prefix sibling of the encoded-video owner directory', () => {
    const sibling = `${StorageCore.getFolderLocation(StorageFolder.EncodedVideo, ownerId)}-sibling/video.mp4`;
    expect(managedMotionRootPath(ownerId, null, sibling, motionId)).toBeUndefined();
  });

  it('never extends an external library policy to managed encoded storage', () => {
    expect(() => managedMotionRootPath(ownerId, libraryId, child().originalPath, motionId)).toThrow();
  });

  it.each([
    [
      'ordinary mp4 filename',
      () => join(StorageCore.getFolderLocation(StorageFolder.EncodedVideo, ownerId), 'video.mp4'),
    ],
    ['different asset id', () => child().originalPath.replace(motionId + '-MP', () => parentId + '-MP')],
    ['path traversal', () => child().originalPath + '/../unrelated.mp4'],
    ['noncanonical separators', () => child().originalPath.replace('/encoded-video/', '/encoded-video//')],
  ])('rejects %s rather than authorizing by directory or extension alone', (_label, makePath) => {
    expect(() => managedMotionRootPath(ownerId, null, makePath(), motionId)).toThrow();
  });
});
