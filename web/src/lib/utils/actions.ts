import {
  AssetVisibility,
  deleteAssets as deleteBulk,
  deletionBatchStatus,
  deletionPreflight,
  deletionStatuses,
  getStack,
  permanentDeletion,
  restoreAssets,
} from '@immich/sdk';
import { toastManager } from '@immich/ui';
import { t } from 'svelte-i18n';
import { get } from 'svelte/store';
import { featureFlagsManager } from '$lib/managers/feature-flags-manager.svelte';
import { TimelineManager } from '$lib/managers/timeline-manager/timeline-manager.svelte';
import type { TimelineAsset } from '$lib/managers/timeline-manager/types';
import type { StackResponse } from '$lib/utils/asset-utils';
import { deletionMessage } from './deletion-message';
import { handleError } from './handle-error';

export type OnDelete = (assetIds: string[]) => void;
export type OnUndoDelete = (assets: TimelineAsset[]) => void;
export type OnRestore = (ids: string[]) => void;
export type OnLink = (assets: { still: TimelineAsset; motion: TimelineAsset }) => void;
export type OnUnlink = (assets: { still: TimelineAsset; motion: TimelineAsset }) => void;
export type OnArchive = (ids: string[], visibility: AssetVisibility) => void;
export type OnFavorite = (ids: string[], favorite: boolean) => void;
export type OnStack = (result: StackResponse) => void;
export type OnUnstack = (assets: TimelineAsset[]) => void;
export type OnSetVisibility = (ids: string[]) => void;

export type DeleteAssetsOptions = { includeStacks?: boolean };

const resolveDeleteSelection = async (assets: TimelineAsset[], includeStacks: boolean) => {
  const selected = [...new Map(assets.map((asset) => [asset.id, asset])).values()];
  const covers = includeStacks
    ? selected.filter(
        (asset) =>
          !asset.isTrashed && asset.stack && asset.stack.assetCount > 1 && asset.stack.primaryAssetId === asset.id,
      )
    : [];
  const stacks = new Map<string, Awaited<ReturnType<typeof getStack>>>();
  // Bound requests for large date selections; verify the entire selection
  // before sending any destructive request.
  for (let start = 0; start < covers.length; start += 4) {
    await Promise.all(
      covers.slice(start, start + 4).map(async (cover) => {
        const stack = await getStack({ id: cover.stack!.id });
        if (
          stack.id !== cover.stack!.id ||
          stack.primaryAssetId !== cover.id ||
          stack.assets.every((asset) => asset.id !== cover.id) ||
          stack.assets.some((asset) => asset.ownerId !== cover.ownerId || !asset.id)
        ) {
          throw new Error('Stack selection changed or is not owned by the selected owner');
        }
        stacks.set(cover.id, stack);
      }),
    );
  }
  const ids = new Set<string>();
  const childCover = new Map<string, string>();
  for (const [coverId, stack] of stacks) {
    for (const child of stack.assets) {
      if (!child.isTrashed) {
        childCover.set(child.id, coverId);
      }
    }
  }
  const undoAssets: TimelineAsset[] = [];
  for (const asset of selected) {
    const stack = stacks.get(asset.id);
    if (stack) {
      const active = stack.assets.filter((asset) => !asset.isTrashed);
      if (active.every((child) => child.id !== asset.id)) {
        throw new Error('Selected stack cover is no longer active');
      }
      for (const child of active) {
        ids.add(child.id);
      }
      undoAssets.push({
        ...asset,
        stack:
          active.length > 1 ? { id: stack.id, primaryAssetId: stack.primaryAssetId, assetCount: active.length } : null,
      });
    } else {
      ids.add(asset.id);
      if (!childCover.has(asset.id)) {
        undoAssets.push(asset);
      }
    }
  }
  return { ids: [...ids], undoAssets };
};

const PERMANENT_DELETION_REQUEST_LIMIT = 5000;
const PERMANENT_DELETION_POLL_INTERVAL_MS = 250;
const PERMANENT_DELETION_MAX_POLLS = 1200;

const waitForDeletionBatch = async (batchId: string, ids: string[]) => {
  for (let attempt = 0; attempt < PERMANENT_DELETION_MAX_POLLS; attempt++) {
    const status = await deletionBatchStatus({ batchId });
    if (status.state !== 'pending' && status.state !== 'active') {
      const results = [];
      for (let start = 0; start < ids.length; start += 200) {
        results.push(...(await deletionStatuses({ bulkIdsDto: { ids: ids.slice(start, start + 200) } })));
      }
      return { results, cancelled: status.state === 'cancelled' || status.cancelRequested === true };
    }
    await new Promise((resolve) => setTimeout(resolve, PERMANENT_DELETION_POLL_INTERVAL_MS));
  }
  throw new Error('Permanent deletion batch did not finish in time');
};

export const deleteAssets = async (
  force: boolean,
  onAssetDelete: OnDelete,
  assets: TimelineAsset[],
  onUndoDelete: OnUndoDelete | undefined = undefined,
  options: DeleteAssetsOptions = {},
): Promise<boolean> => {
  const $t = get(t);
  try {
    const { ids, undoAssets } = await resolveDeleteSelection(assets, options.includeStacks === true);
    if (force && featureFlagsManager.valueOrUndefined?.authorizedDeletion) {
      const preflight = [];
      // Admit every scope in the entire selection before any irreversible batch.
      for (let start = 0; start < ids.length; start += 200) {
        const batch = ids.slice(start, start + 200);
        const results = await deletionPreflight({ bulkIdsDto: { ids: batch } });
        if (
          results.length !== batch.length ||
          new Set(results.map((r) => r.id)).size !== batch.length ||
          results.some((r) => !batch.includes(r.id) || typeof r.authorized !== 'boolean')
        ) {
          throw new Error('Invalid deletion preflight');
        }
        preflight.push(...results);
      }
      if (preflight.some((r) => !r.authorized)) {
        toastManager.primary(
          $t('deletion_batch_blocked') +
            ' ' +
            preflight
              .filter((r) => !r.authorized)
              .map((r) => deletionMessage($t, r.code, r.scope))
              .join(' '),
        );
        return false;
      }
      const completed: string[] = [];
      const unresolved: string[] = [];
      for (let start = 0; start < ids.length; start += PERMANENT_DELETION_REQUEST_LIMIT) {
        const batch = ids.slice(start, start + PERMANENT_DELETION_REQUEST_LIMIT);
        let results = await permanentDeletion({ permanentDeletionDto: { ids: batch, confirmed: true } });
        if (
          results.length !== batch.length ||
          results.some((item, index) => results.findIndex((other) => other.id === item.id) !== index) ||
          results.some((item) => !batch.includes(item.id))
        ) {
          throw new Error('Invalid permanent deletion acknowledgement');
        }
        const batchIds = new Set(results.map((result) => result.batchId).filter((id): id is string => Boolean(id)));
        if (batchIds.size > 1 || (batchIds.size === 1 && results.some((result) => !result.batchId))) {
          throw new Error('Invalid permanent deletion batch acknowledgement');
        }
        const batchId = [...batchIds][0];
        let cancelled = false;
        if (batchId) {
          const status = await waitForDeletionBatch(batchId, batch);
          results = status.results;
          cancelled = status.cancelled;
        }
        if (
          results.length !== batch.length ||
          results.some((item, index) => results.findIndex((other) => other.id === item.id) !== index) ||
          results.some((item) => !batch.includes(item.id))
        ) {
          throw new Error('Invalid permanent deletion status');
        }
        const removed = results.filter((result) => result.state === 'complete').map((result) => result.id);
        completed.push(...removed);
        unresolved.push(
          ...results
            .filter((result) => result.state !== 'complete')
            .map((result) => deletionMessage($t, result.code, result.scope)),
        );
        // Apply each validated batch before requesting another. A later timeout
        // never hides earlier confirmed results or removes unresolved rows.
        onAssetDelete(removed);
        if (
          cancelled ||
          results.some(
            (r) => r.code === 'LIBRARY_DELETION_NOT_AUTHORIZED' || r.code === 'DELETION_BATCH_NOT_AUTHORIZED',
          )
        ) {
          unresolved.push(
            ...ids.slice(start + PERMANENT_DELETION_REQUEST_LIMIT).map(() => $t('deletion_batch_blocked')),
          );
          break;
        }
      }
      toastManager.primary(
        $t('permanent_deletion_result', {
          values: {
            removed: completed.length,
            remaining: unresolved.length,
            reasons: unresolved.slice(0, 25).join(', '),
          },
        }),
      );
      return completed.length === ids.length;
    }
    await deleteBulk({ assetBulkDeleteDto: { ids, force } });
    onAssetDelete(ids);

    toastManager.primary(
      {
        description: force
          ? $t('assets_permanently_deleted_count', { values: { count: ids.length } })
          : $t('assets_trashed_count', { values: { count: ids.length } }),
        button:
          onUndoDelete && !force
            ? { label: $t('undo'), color: 'secondary', onclick: () => undoDeleteAssets(onUndoDelete, undoAssets, ids) }
            : undefined,
      },
      { timeout: 5000 },
    );
    return true;
  } catch (error) {
    handleError(error, $t('errors.unable_to_delete_assets'));
    return false;
  }
};

const undoDeleteAssets = async (onUndoDelete: OnUndoDelete, assets: TimelineAsset[], ids: string[]) => {
  const $t = get(t);
  try {
    await restoreAssets({ bulkIdsDto: { ids } });
    onUndoDelete?.(assets);
  } catch (error) {
    handleError(error, $t('errors.unable_to_restore_assets'));
  }
};

/**
 * Update the asset stack state in the asset store based on the provided stack response.
 * This function updates the stack information so that the icon is shown for the primary asset
 * and removes any assets from the timeline that are marked for deletion.
 *
 * @param {TimelineManager} timelineManager - The timeline manager to update.
 * @param {StackResponse} stackResponse - The stack response containing the stack and assets to delete.
 */
export function updateStackedAssetInTimeline(timelineManager: TimelineManager, { stack, toDeleteIds }: StackResponse) {
  if (stack === undefined) {
    return;
  }

  timelineManager.update(
    [stack.primaryAssetId],
    (asset) =>
      (asset.stack = {
        id: stack.id,
        primaryAssetId: stack.primaryAssetId,
        assetCount: stack.assets.length,
      }),
  );

  timelineManager.removeAssets(toDeleteIds);
}

/**
 * Update the timeline manager to reflect the unstacked state of assets.
 * This function updates the stack property of each asset to undefined, effectively unstacking them.
 * It also adds the unstacked assets back to the timeline manager.
 *
 * @param timelineManager - The timeline manager to update.
 * @param assets - The array of asset response DTOs to update in the timeline manager.
 */
export function updateUnstackedAssetInTimeline(timelineManager: TimelineManager, assets: TimelineAsset[]) {
  timelineManager.update(
    assets.map((asset) => asset.id),
    (asset) => {
      asset.stack = null;
      return { remove: false };
    },
  );

  timelineManager.upsertAssets(assets);
}
