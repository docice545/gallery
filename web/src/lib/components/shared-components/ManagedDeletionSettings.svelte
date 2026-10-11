<script lang="ts">
  import { managedDeletionErrorMessage } from '$lib/utils/deletion-message';
  import {
    managedDeletionStatus,
    prepareManagedDeletion,
    setManagedDeletionConsent,
    type ManagedDeletionStatusDto,
  } from '@immich/sdk';
  import { Button, modalManager } from '@immich/ui';
  import { onMount } from 'svelte';
  import { t } from 'svelte-i18n';

  let status = $state<ManagedDeletionStatusDto>();
  let busy = $state(false);
  let error = $state<string>();
  let proof = $state('');
  let verified = $state(false);

  const load = async () => {
    try {
      status = await managedDeletionStatus();
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
    if (enabled && !(await modalManager.showDialog({ prompt: $t('managed_deletion_confirm') }))) {
      return;
    }
    await run(() => setManagedDeletionConsent({ managedDeletionConsentDto: { enabled, confirmed: true } }));
  };
</script>

<details class="mx-4 my-2 rounded-sm border p-3">
  <summary class="cursor-pointer font-medium">{$t('managed_deletion_title')}</summary>
  <p class="my-3">{$t('managed_deletion_description')}</p>
  {#if error}
    <p role="alert">{error}</p>
    <Button onclick={load} disabled={busy}>{$t('retry')}</Button>
  {/if}
  {#if status}
    <p class="my-3">
      {status.prepared
        ? status.enabled
          ? $t('managed_deletion_enabled')
          : $t('managed_deletion_prepared')
        : $t('managed_deletion_preparation_required')}
    </p>
    <Button onclick={consent} disabled={busy || (!status.enabled && !status.prepared)}>
      {status.enabled ? $t('managed_deletion_disable') : $t('managed_deletion_enable')}
    </Button>
    {#if status.canPrepare}
      <form
        class="mt-4 flex flex-col gap-3"
        onsubmit={(event) => {
          event.preventDefault();
          if (!busy && verified && /^[a-f0-9]{64}$/.test(proof.trim())) {
            void run(() =>
              prepareManagedDeletion({
                prepareManagedDeletionDto: { recoveryProof: proof.trim(), verifiedExclusiveRoots: true },
              }),
            );
          }
        }}
      >
        <p>{$t('managed_deletion_recovery_help')}</p>
        <label
          >{$t('managed_deletion_recovery_proof')}
          <input
            class="block w-full rounded-sm border p-2"
            bind:value={proof}
            disabled={busy}
            maxlength="64"
            autocomplete="off"
          />
        </label>
        <label
          ><input type="checkbox" bind:checked={verified} disabled={busy} />
          {$t('managed_deletion_exclusive_roots')}</label
        >
        <Button type="submit" disabled={busy || !verified || !/^[a-f0-9]{64}$/.test(proof.trim())}
          >{$t('managed_deletion_prepare')}</Button
        >
      </form>
    {/if}
  {/if}
</details>
