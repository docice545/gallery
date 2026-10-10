import { deletionScopes, emptyTrash } from '@immich/sdk';
import { modalManager, toastManager } from '@immich/ui';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { handleEmptyTrash } from './trash.service';

vi.mock('@immich/sdk', async (original) => ({ ...(await original()), deletionScopes: vi.fn(), emptyTrash: vi.fn() }));
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
    await handleEmptyTrash();
    expect(emptyTrash).not.toHaveBeenCalled();
    expect(toastManager.primary).toHaveBeenCalledWith(expect.stringContaining('external_deletion_blocked'));
  });
  it('permits managed-only Empty Trash after explicit authorization', async () => {
    vi.mocked(deletionScopes).mockResolvedValue([{ scope: 'managed', count: 12, authorized: true }]);
    vi.mocked(emptyTrash).mockResolvedValue({ count: 12 });
    await handleEmptyTrash();
    expect(emptyTrash).toHaveBeenCalledTimes(1);
  });
});
