<script lang="ts">
  import { shortcuts } from '$lib/actions/shortcut';
  import { AssetAction } from '$lib/constants';
  import { featureFlagsManager } from '$lib/managers/feature-flags-manager.svelte';
  import AssetDeleteConfirmModal from '$lib/modals/AssetDeleteConfirmModal.svelte';
  import { showDeleteModal } from '$lib/stores/preferences.store';
  import { deleteAssets as deleteAssetsUtil, type OnUndoDelete } from '$lib/utils/actions';
  import { toTimelineAsset } from '$lib/utils/timeline-util';
  import type { AssetResponseDto } from '@immich/sdk';
  import { IconButton, modalManager } from '@immich/ui';
  import { mdiDeleteForeverOutline, mdiDeleteOutline } from '@mdi/js';
  import { t } from 'svelte-i18n';
  import type { OnAction, PreAction } from './action';

  interface Props {
    asset: AssetResponseDto;
    onAction: OnAction;
    preAction: PreAction;
    onUndoDelete?: OnUndoDelete;
  }

  let { asset, onAction, preAction, onUndoDelete = undefined }: Props = $props();

  const forceDefault = $derived(asset.isTrashed || !featureFlagsManager.value.trash);
  let loading = $state(false);

  const trashOrDelete = async (forceRequest?: boolean) => {
    if (loading) {
      return;
    }
    loading = true;
    try {
      const timelineAsset = toTimelineAsset(asset);
      const force = forceDefault || forceRequest === true;

      if (force && (featureFlagsManager.valueOrUndefined?.authorizedDeletion || $showDeleteModal)) {
        const confirmed = await modalManager.show(AssetDeleteConfirmModal, { size: 1 });
        if (!confirmed) {
          return;
        }
      }

      const type = force ? AssetAction.DELETE : AssetAction.TRASH;
      preAction({ type, asset: timelineAsset });
      await deleteAssetsUtil(
        force,
        (ids) => {
          if (ids.includes(timelineAsset.id)) {
            onAction({ type, asset: timelineAsset });
          }
        },
        [timelineAsset],
        onUndoDelete,
      );
    } finally {
      loading = false;
    }
  };
</script>

<svelte:document
  use:shortcuts={[
    { shortcut: { key: 'Delete' }, onShortcut: () => trashOrDelete() },
    { shortcut: { key: 'Delete', shift: true }, onShortcut: () => trashOrDelete(true) },
  ]}
/>

<IconButton
  color="secondary"
  shape="round"
  variant="ghost"
  icon={forceDefault ? mdiDeleteForeverOutline : mdiDeleteOutline}
  aria-label={forceDefault ? $t('permanently_delete') : $t('delete')}
  disabled={loading}
  onclick={() => trashOrDelete()}
/>
