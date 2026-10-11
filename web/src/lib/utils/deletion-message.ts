import type { MessageFormatter } from 'svelte-i18n';
import { getServerErrorMessage } from '$lib/utils/handle-error';

const managedDeletionErrorKey = (code?: string) => {
  switch (code) {
    case 'DELETION_RECOVERY_UNAVAILABLE': {
      return 'managed_deletion_recovery_missing';
    }
    case 'DELETION_RECOVERY_INVALID': {
      return 'managed_deletion_recovery_invalid';
    }
    case 'DELETION_RECOVERY_EXPIRED': {
      return 'managed_deletion_recovery_expired';
    }
    case 'DELETION_RECOVERY_SCOPE_MISMATCH': {
      return 'managed_deletion_recovery_scope_mismatch';
    }
    case 'DELETION_ROOT_CHANGED':
    case 'OVERLAPPING_OWNER_ROOTS':
    case 'UNSUPPORTED_DELETION_FILESYSTEM':
    case 'DELETION_QUARANTINE_CONFLICT': {
      return 'managed_deletion_roots_changed';
    }
    case 'MANAGED_DELETION_PREPARATION_REQUIRED': {
      return 'managed_deletion_preparation_required';
    }
    default: {
      return undefined;
    }
  }
};

export const managedDeletionErrorMessage = ($t: MessageFormatter, error: unknown) =>
  $t(managedDeletionErrorKey(getServerErrorMessage(error)) ?? 'errors.unable_to_save_settings');

export const deletionMessage = ($t: MessageFormatter, code?: string, scope?: string) => {
  const key =
    code === 'LIBRARY_DELETION_NOT_AUTHORIZED'
      ? scope === 'managed'
        ? 'managed_deletion_disabled'
        : 'external_deletion_blocked'
      : code === 'DELETION_BATCH_NOT_AUTHORIZED'
        ? 'deletion_batch_blocked'
        : (managedDeletionErrorKey(code) ?? 'deletion_not_completed');
  const label =
    scope === 'managed'
      ? $t('managed_deletion_scope')
      : scope
        ? `${$t('external_deletion_scope')} (${scope})`
        : undefined;
  return label ? `${label}: ${$t(key)}` : $t(key);
};
