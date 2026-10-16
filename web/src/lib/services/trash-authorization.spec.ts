import { deletionScopes } from '@immich/sdk';
import { modalManager, toastManager } from '@immich/ui';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { deleteAssets } from '$lib/utils/actions';
import { handleEmptyTrash } from './trash.service';

vi.mock('@immich/sdk', async (original) => ({ ...(await original()), deletionScopes: vi.fn() }));
vi.mock('$lib/utils/actions', () => ({ deleteAssets: vi.fn() }));

vi.mock('$lib/managers/feature-flags-manager.svelte', () => ({
  featureFlagsManager: { valueOrUndefined: { authorizedDeletion: true } },
}));
vi.mock('$lib/utils/i18n', () => ({ getFormatter: () => Promise.resolve((key: string) => key) }));
beforeEach(() => {
  vi.clearAllMocks();
  vi.spyOn(modalManager, 'showDialog').mockResolvedValue(true);
  vi.spyOn(toastManager, 'primary').mockImplementation(() => ({}) as never);
});
describe('Empty Trash scope authorization', () => {
  it('does not send Empty Trash if an external scope remains protected', async () => {
    vi.mocked(deletionScopes).mockResolvedValue([
      { scope: 'managed', count: 12, authorized: true },
      { scope: 'external', count: 3, authorized: false },
    ]);
    await handleEmptyTrash(async () => [{ id: 'asset-1' } as never], vi.fn());
    expect(deleteAssets).not.toHaveBeenCalled();
    expect(toastManager.primary).toHaveBeenCalledWith(expect.stringContaining('external_deletion_blocked'));
  });
  it('permits managed-only Empty Trash after explicit authorization', async () => {
    vi.mocked(deletionScopes).mockResolvedValue([{ scope: 'managed', count: 12, authorized: true }]);
    vi.mocked(deleteAssets).mockResolvedValue(true);
    const remove = vi.fn();
    await handleEmptyTrash(async () => [{ id: 'asset-1' } as never], remove);
    expect(deleteAssets).toHaveBeenCalledWith(true, remove, [{ id: 'asset-1' }]);
  });

  it('does not submit a mutation for an empty owner-scoped snapshot', async () => {
    vi.mocked(deletionScopes).mockResolvedValue([]);
    await handleEmptyTrash(async () => [], vi.fn());
    expect(deleteAssets).not.toHaveBeenCalled();
    expect(toastManager.primary).toHaveBeenCalledWith(expect.stringContaining('assets_permanently_deleted_count'));
  });
});
