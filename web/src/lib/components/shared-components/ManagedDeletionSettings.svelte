<script lang="ts">
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
  let failed = $state(false);
  let proof = $state('');
  let verified = $state(false);

  const load = async () => {
    try {
      status = await managedDeletionStatus();
      failed = false;
    } catch {
      failed = true;
    }
  };
  onMount(() => {
    void load();
  });

  const run = async (action: () => Promise<void>) => {
    busy = true;
    failed = false;
    try {
      await action();
      await load();
    } catch {
      failed = true;
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
  {#if failed}
    <p role="alert">{$t('errors.unable_to_save_settings')}</p>
    <Button onclick={load} disabled={busy}>{$t('retry')}</Button>
  {/if}
  {#if status}
    <p class="my-3">
      {status.enabled
        ? $t('managed_deletion_enabled')
        : status.prepared
          ? $t('managed_deletion_prepared')
          : $t('managed_deletion_preparation_required')}
    </p>
    <Button onclick={consent} disabled={busy || !status.prepared}>
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
