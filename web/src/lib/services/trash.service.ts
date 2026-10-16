import { deletionScopes, restoreTrash } from '@immich/sdk';
import { modalManager, toastManager, type ActionItem } from '@immich/ui';
import { mdiDeleteForeverOutline, mdiHistory } from '@mdi/js';
import type { MessageFormatter } from 'svelte-i18n';
import { featureFlagsManager } from '$lib/managers/feature-flags-manager.svelte';
import type { TimelineAsset } from '$lib/managers/timeline-manager/types';
import { deleteAssets } from '$lib/utils/actions';
import { deletionMessage } from '$lib/utils/deletion-message';
import { handleError } from '$lib/utils/handle-error';
import { getFormatter } from '$lib/utils/i18n';

type TrashSnapshot = () => Promise<TimelineAsset[]>;
type RemoveTrashAssets = (ids: string[]) => void;

export const getTrashActions = ($t: MessageFormatter, getSnapshot: TrashSnapshot, onAssetDelete: RemoveTrashAssets) => {
  const RestoreAll: ActionItem = {
    title: $t('restore_all'),
    icon: mdiHistory,
    onAction: () => handleRestoreTrash(),
  };

  const Empty: ActionItem = {
    title: $t('empty_trash'),
    icon: mdiDeleteForeverOutline,
    onAction: () => handleEmptyTrash(getSnapshot, onAssetDelete),
  };

  return { RestoreAll, Empty };
};

export const handleEmptyTrash = async (getSnapshot: TrashSnapshot, onAssetDelete: RemoveTrashAssets) => {
  const $t = await getFormatter();

  const confirmed = await modalManager.showDialog({ prompt: $t('empty_trash_confirmation') });
  if (!confirmed) {
    return;
  }

  try {
    if (!featureFlagsManager.valueOrUndefined?.authorizedDeletion) {
      toastManager.primary($t('deletion_batch_blocked'));
      return;
    }
    const scopes = await deletionScopes();
    const blocked = scopes.filter((scope) => !scope.authorized);
    if (blocked.length > 0) {
      toastManager.primary(
        $t('deletion_batch_blocked') +
          ' ' +
          blocked
            .map(({ scope, count }) => `${deletionMessage($t, 'LIBRARY_DELETION_NOT_AUTHORIZED', scope)} (${count})`)
            .join(' '),
      );
      return;
    }
    const assets = await getSnapshot();
    if (assets.length === 0) {
      toastManager.primary($t('assets_permanently_deleted_count', { values: { count: 0 } }));
      return;
    }
    await deleteAssets(true, onAssetDelete, assets);
  } catch (error) {
    handleError(error, $t('errors.unable_to_empty_trash'));
  }
};

export const handleRestoreTrash = async () => {
  const $t = await getFormatter();

  const confirmed = await modalManager.showDialog({ prompt: $t('assets_restore_confirmation') });
  if (!confirmed) {
    return;
  }

  try {
    const { count } = await restoreTrash();
    toastManager.primary($t('assets_restored_count', { values: { count } }));
  } catch (error) {
    handleError(error, $t('errors.unable_to_restore_trash'));
  }
};
