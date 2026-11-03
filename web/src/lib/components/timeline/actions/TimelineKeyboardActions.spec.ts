import { modalManager } from '@immich/ui';
import { fireEvent, render, waitFor } from '@testing-library/svelte';
import type { AssetMultiSelectManager } from '$lib/managers/asset-multi-select-manager.svelte';
import type { TimelineManager } from '$lib/managers/timeline-manager/timeline-manager.svelte';
import AssetDeleteConfirmModal from '$lib/modals/AssetDeleteConfirmModal.svelte';
import { deleteAssets } from '$lib/utils/actions';
import { toTimelineAsset } from '$lib/utils/timeline-util';
import { assetFactory } from '@test-data/factories/asset-factory';
import TimelineKeyboardActions from './TimelineKeyboardActions.svelte';

vi.mock('$lib/utils/actions', () => ({ deleteAssets: vi.fn(), updateStackedAssetInTimeline: vi.fn() }));
vi.mock('$lib/managers/feature-flags-manager.svelte', () => ({
  featureFlagsManager: { value: { trash: true }, valueOrUndefined: { authorizedDeletion: true } },
}));
vi.mock('$lib/managers/asset-viewer-manager.svelte', () => ({ assetViewerManager: { isViewing: false } }));
vi.mock('$lib/stores/search.svelte', () => ({ searchStore: { isSearchEnabled: false } }));

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((complete) => {
    resolve = complete;
  });
  return { promise, resolve };
}

describe('timeline deletion keyboard guard', () => {
  const mount = (withStacked = true) => {
    const clear = vi.fn();
    const assets = [toTimelineAsset(assetFactory.build({ isTrashed: false }))];
    render(TimelineKeyboardActions, {
      timelineManager: {
        isInitialized: false,
        removeAssets: vi.fn(),
        upsertAssets: vi.fn(),
      } as unknown as TimelineManager,
      assetInteraction: { selectionActive: true, assets, clear } as unknown as AssetMultiSelectManager,
      scrollToAsset: () => false,
      withStacked,
    });
    return { clear, assets };
  };

  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(modalManager, 'show').mockResolvedValue(true as never);
  });
  afterEach(() => vi.restoreAllMocks());

  it('sends one deletion while repeated Delete keys arrive before completion', async () => {
    const deletion = deferred<boolean>();
    vi.mocked(deleteAssets).mockReturnValue(deletion.promise);
    const { clear, assets } = mount();
    await fireEvent.keyDown(document, { key: 'Delete' });
    await fireEvent.keyDown(document, { key: 'Delete', repeat: true });
    expect(deleteAssets).toHaveBeenCalledOnce();
    expect(deleteAssets).toHaveBeenCalledWith(false, expect.any(Function), assets, expect.any(Function), {
      includeStacks: true,
    });
    expect(clear).not.toHaveBeenCalled();
    deletion.resolve(true);
    await waitFor(() => expect(clear).toHaveBeenCalledOnce());
  });

  it('holds the guard through permanent confirmation and cancellation, then allows retry', async () => {
    const confirmation = deferred<boolean>();
    vi.mocked(modalManager.show).mockReturnValueOnce(confirmation.promise as never);
    vi.mocked(deleteAssets).mockResolvedValue(true);
    const { clear } = mount(false);
    await fireEvent.keyDown(document, { key: 'Delete', shiftKey: true });
    await fireEvent.keyDown(document, { key: 'Delete', shiftKey: true, repeat: true });
    expect(modalManager.show).toHaveBeenCalledOnce();
    expect(modalManager.show).toHaveBeenCalledWith(AssetDeleteConfirmModal, { size: 1 });
    expect(deleteAssets).not.toHaveBeenCalled();
    confirmation.resolve(false);
    await waitFor(() => expect(clear).not.toHaveBeenCalled());
    await fireEvent.keyDown(document, { key: 'Delete', shiftKey: true });
    await waitFor(() => expect(deleteAssets).toHaveBeenCalledOnce());
    expect(deleteAssets).toHaveBeenCalledWith(true, expect.any(Function), expect.any(Array), undefined, {
      includeStacks: false,
    });
  });

  it('allows retry after a failed deletion result without clearing the selection', async () => {
    vi.mocked(deleteAssets).mockResolvedValueOnce(false).mockResolvedValueOnce(true);
    const { clear } = mount();
    await fireEvent.keyDown(document, { key: 'Delete' });
    expect(clear).not.toHaveBeenCalled();
    await fireEvent.keyDown(document, { key: 'Delete' });
    await waitFor(() => expect(deleteAssets).toHaveBeenCalledTimes(2));
    await waitFor(() => expect(clear).toHaveBeenCalledOnce());
  });
});
