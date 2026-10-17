<script lang="ts">
  import { managedDeletionErrorMessage } from '$lib/utils/deletion-message';
  import {
    managedDeletionStatus,
    libraryDeletionStatus,
    setLibraryDeletionConsent,
    setManagedDeletionConsent,
    type ManagedDeletionStatusDto,
  } from '@immich/sdk';
  import { Button, modalManager } from '@immich/ui';
  import { onMount } from 'svelte';
  import { t } from 'svelte-i18n';

  let status = $state<ManagedDeletionStatusDto>();
  let { libraryId, libraryName }: { libraryId?: string; libraryName?: string } = $props();
  let busy = $state(false);
  let error = $state<string>();

  const load = async () => {
    try {
      status = libraryId ? await libraryDeletionStatus({ id: libraryId }) : await managedDeletionStatus();
      error = undefined;
    } catch (error_) {
      error = managedDeletionErrorMessage($t, error_);
    }
  };
  onMount(() => {
    void load();
  });

  const run = async (action: () => Promise<void>) => {
    busy = true;
    error = undefined;
    try {
      await action();
      await load();
    } catch (error_) {
      await load();
      error = managedDeletionErrorMessage($t, error_);
    } finally {
      busy = false;
    }
  };
  const consent = async () => {
    if (!status) {
      return;
    }
    const enabled = !status.enabled;
    if (
      enabled &&
      !(await modalManager.showDialog({
        prompt: $t(libraryId ? 'external_deletion_confirm' : 'managed_deletion_confirm'),
      }))
    ) {
      return;
    }
    await run(() =>
      libraryId
        ? setLibraryDeletionConsent({ id: libraryId, managedDeletionConsentDto: { enabled, confirmed: true } })
        : setManagedDeletionConsent({ managedDeletionConsentDto: { enabled, confirmed: true } }),
    );
  };
</script>

<details class="mx-4 my-2 rounded-sm border p-3">
  <summary class="cursor-pointer font-medium"
    >{libraryId
      ? `${libraryName || $t('external_deletion_scope')} (${libraryId})`
      : $t('managed_deletion_title')}</summary
  >
  <p class="my-3">{$t(libraryId ? 'external_deletion_description' : 'managed_deletion_description')}</p>
  {#if error}
    <p role="alert">{error}</p>
    <Button onclick={load} disabled={busy}>{$t('retry')}</Button>
  {/if}
  {#if status}
    <p class="my-3">
      {status.prepared
        ? status.enabled
          ? $t(libraryId ? 'external_deletion_enabled' : 'managed_deletion_enabled')
          : $t('managed_deletion_prepared')
        : $t(libraryId ? 'external_deletion_preparation_required' : 'managed_deletion_preparation_required')}
    </p>
    <Button onclick={consent} disabled={busy || (!status.enabled && !status.prepared)}>
      {status.enabled
        ? $t('managed_deletion_disable')
        : $t(libraryId ? 'external_deletion_enable' : 'managed_deletion_enable')}
    </Button>
  {/if}
</details>
