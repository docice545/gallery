import type { MessageFormatter } from 'svelte-i18n';

export const deletionMessage = ($t: MessageFormatter, code?: string, scope?: string) => {
  const key =
    code === 'LIBRARY_DELETION_NOT_AUTHORIZED'
      ? scope === 'managed'
        ? 'managed_deletion_disabled'
        : 'external_deletion_blocked'
      : code === 'DELETION_BATCH_NOT_AUTHORIZED'
        ? 'deletion_batch_blocked'
        : code === 'MANAGED_DELETION_PREPARATION_REQUIRED'
          ? 'managed_deletion_preparation_required'
          : 'deletion_not_completed';
  const label =
    scope === 'managed'
      ? $t('managed_deletion_scope')
      : scope
        ? `${$t('external_deletion_scope')} (${scope})`
        : undefined;
  return label ? `${label}: ${$t(key)}` : $t(key);
};
