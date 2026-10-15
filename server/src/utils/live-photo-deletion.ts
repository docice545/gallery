import { isAbsolute, resolve } from 'node:path';
import { StorageCore } from 'src/cores/storage.core.js';
import { AssetType, StorageFolder } from 'src/enum.js';
import { DeletionError } from 'src/utils/authorized-deletion.js';

type Parent = {
  id: string;
  ownerId: string;
  libraryId: string | null;
  type: AssetType;
  livePhotoVideoId: string | null;
};
type Motion = { id: string; ownerId: string; libraryId: string | null; type: AssetType; originalPath: string };

/** The relationship, not a filename or a directory prefix, authorizes a companion. */
export function assertExclusiveLivePhoto(
  parent: Parent,
  child: Motion,
  referenceIds: string[],
  ownerId: string,
  libraryId: string | null,
): void {
  if (
    parent.type !== AssetType.Image ||
    parent.ownerId !== ownerId ||
    child.ownerId !== ownerId ||
    parent.libraryId !== libraryId ||
    child.libraryId !== libraryId ||
    parent.livePhotoVideoId !== child.id ||
    child.id === parent.id ||
    child.type !== AssetType.Video
  )
    throw new DeletionError('MOTION_SCOPE_MISMATCH');
  if (referenceIds.length !== 1 || referenceIds[0] !== parent.id)
    throw new DeletionError('ORIGINAL_SHARED_WITH_OTHER_ASSET');
}

/** This exception cannot extend an external library's explicitly authorized roots. */
export function managedMotionRootPath(
  ownerId: string,
  libraryId: string | null,
  path: string,
  assetId: string,
): string | undefined {
  if (!isAbsolute(path) || resolve(path) !== path) throw new DeletionError('MOTION_SCOPE_MISMATCH');
  const root = StorageCore.getFolderLocation(StorageFolder.EncodedVideo, ownerId);
  if (!path.startsWith(`${root}/`)) return;
  if (libraryId !== null || path !== StorageCore.getAndroidMotionPath({ id: assetId, ownerId }, assetId))
    throw new DeletionError('MOTION_SCOPE_MISMATCH');
  return root;
}
