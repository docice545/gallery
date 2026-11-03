import { modalManager } from '@immich/ui';
import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { assetMultiSelectManager } from '$lib/managers/asset-multi-select-manager.svelte';
import { authManager } from '$lib/managers/auth-manager.svelte';
import { deleteAssets } from '$lib/utils/actions';
import { toTimelineAsset } from '$lib/utils/timeline-util';
import { assetFactory } from '@test-data/factories/asset-factory';
import DeleteAssetsAction from './DeleteAssetsAction.svelte';

vi.mock('$lib/managers/feature-flags-manager.svelte', () => ({
  featureFlagsManager: { valueOrUndefined: { authorizedDeletion: true } },
}));
vi.mock('$lib/utils/actions', async (original) => ({
  ...(await original<typeof import('$lib/utils/actions')>()),
  deleteAssets: vi.fn(),
}));

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((complete) => {
    resolve = complete;
  });
  return { promise, resolve };
}

describe('DeleteAssetsAction pending permanent deletion', () => {
  const selectedAsset = toTimelineAsset(assetFactory.build({ id: 'selected', isTrashed: false }));

  beforeEach(() => {
    vi.restoreAllMocks();
    vi.mocked(deleteAssets).mockReset().mockResolvedValue(true);
    vi.spyOn(modalManager, 'show').mockResolvedValue(true as never);
    authManager.reset();
    assetMultiSelectManager.clear();
    assetMultiSelectManager.selectAsset(selectedAsset);
  });

  afterEach(() => {
    assetMultiSelectManager.clear();
    vi.restoreAllMocks();
  });

  const renderForceMenu = () =>
    render(DeleteAssetsAction, { menuItem: true, force: true, includeStacks: true, onAssetDelete: vi.fn() });
  const clickForceMenu = () => fireEvent.click(screen.getByRole('menuitem', { name: 'permanently_delete' }));

  it('admits one confirmation and one deletion until the full operation settles', async () => {
    const confirmation = deferred<boolean>();
    const deletion = deferred<boolean>();
    vi.mocked(modalManager.show).mockReturnValue(confirmation.promise as never);
    vi.mocked(deleteAssets).mockReturnValue(deletion.promise);
    renderForceMenu();

    await clickForceMenu();
    await clickForceMenu();

    expect(modalManager.show).toHaveBeenCalledOnce();
    expect(deleteAssets).not.toHaveBeenCalled();
    expect(assetMultiSelectManager.hasSelectedAsset(selectedAsset.id)).toBe(true);

    confirmation.resolve(true);
    await waitFor(() => expect(deleteAssets).toHaveBeenCalledOnce());
    await clickForceMenu();

    expect(modalManager.show).toHaveBeenCalledOnce();
    expect(deleteAssets).toHaveBeenCalledWith(true, expect.any(Function), [selectedAsset], undefined, {
      includeStacks: true,
    });
    expect(assetMultiSelectManager.hasSelectedAsset(selectedAsset.id)).toBe(true);

    deletion.resolve(true);
    await waitFor(() => expect(assetMultiSelectManager.selectionActive).toBe(false));
  });

  it('keeps the selection after cancellation and allows a new confirmation', async () => {
    vi.mocked(modalManager.show).mockResolvedValueOnce(false as never);
    renderForceMenu();

    await clickForceMenu();

    expect(deleteAssets).not.toHaveBeenCalled();
    expect(assetMultiSelectManager.hasSelectedAsset(selectedAsset.id)).toBe(true);

    await clickForceMenu();

    await waitFor(() => expect(deleteAssets).toHaveBeenCalledOnce());
    expect(modalManager.show).toHaveBeenCalledTimes(2);
    expect(assetMultiSelectManager.selectionActive).toBe(false);
  });

  it('keeps the selection after a failed deletion result and allows retry', async () => {
    vi.mocked(deleteAssets).mockResolvedValueOnce(false);
    renderForceMenu();

    await clickForceMenu();

    await waitFor(() => expect(deleteAssets).toHaveBeenCalledOnce());
    expect(assetMultiSelectManager.hasSelectedAsset(selectedAsset.id)).toBe(true);

    await clickForceMenu();

    await waitFor(() => expect(deleteAssets).toHaveBeenCalledTimes(2));
    expect(assetMultiSelectManager.selectionActive).toBe(false);
  });
});
