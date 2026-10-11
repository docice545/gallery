<script lang="ts">
  import { libraryDeletionScopes, type TrashDeletionScopeDto } from '@immich/sdk';
  import { onMount } from 'svelte';
  import { t } from 'svelte-i18n';
  import ManagedDeletionSettings from './ManagedDeletionSettings.svelte';

  let libraries = $state<TrashDeletionScopeDto[]>();
  let failed = $state(false);
  const load = async () => {
    try {
      libraries = await libraryDeletionScopes();
      failed = false;
    } catch {
      failed = true;
    }
  };
  onMount(() => {
    void load();
  });
</script>

<details class="mx-4 my-2 rounded-sm border p-3">
  <summary class="cursor-pointer font-medium">{$t('external_deletion_title')}</summary>
  {#if failed}
    <p role="alert">{$t('errors.unable_to_save_settings')}</p>
    <button type="button" onclick={load}>{$t('retry')}</button>
  {:else if libraries?.length === 0}
    <p>{$t('external_deletion_empty')}</p>
  {/if}
  {#each libraries ?? [] as library (library.scope)}
    <ManagedDeletionSettings libraryId={library.scope} libraryName={library.name} />
  {/each}
</details>
