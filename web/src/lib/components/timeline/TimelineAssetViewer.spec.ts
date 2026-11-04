import { render, waitFor } from '@testing-library/svelte';
import type { Component } from 'svelte';
import type { Action } from '$lib/components/asset-viewer/actions/action';
import { AssetAction } from '$lib/constants';
import type { TimelineManager } from '$lib/managers/timeline-manager/timeline-manager.svelte';
import { navigateToAsset } from '$lib/utils/asset-utils';
import { toTimelineAsset } from '$lib/utils/timeline-util';
import { assetFactory } from '@test-data/factories/asset-factory';
import TimelineAssetViewer from './TimelineAssetViewer.svelte';

const state = vi.hoisted(() => ({
  props: undefined as Record<string, unknown> | undefined,
  asset: undefined as unknown,
}));
vi.mock('$lib/components/asset-viewer/AssetViewer.svelte', () => ({
  default: ((_anchor: unknown, props: Record<string, unknown>) => {
    state.props = props;
    return {};
  }) as Component,
}));
vi.mock('$lib/managers/asset-viewer-manager.svelte', () => ({
  assetViewerManager: {
    get asset() {
      return state.asset;
    },
    setAsset: vi.fn(),
  },
}));
vi.mock('$lib/managers/AssetCacheManager.svelte', () => ({
  assetCacheManager: { invalidate: vi.fn(), getAsset: vi.fn() },
}));
vi.mock('$lib/stores/websocket', () => ({ websocketEvents: { on: vi.fn(() => vi.fn()) } }));
vi.mock('$lib/utils/asset-utils', async (original) => ({ ...(await original()), navigateToAsset: vi.fn() }));
vi.mock('$lib/utils/navigation', () => ({ navigate: vi.fn(), isSharedLinkRoute: vi.fn(() => false) }));

describe('TimelineAssetViewer confirmed deletion', () => {
  const asset = assetFactory.build({ id: 'cover', stack: { id: 'stack', primaryAssetId: 'cover', assetCount: 3 } });
  const manager = {
    getEarlierAsset: vi.fn(),
    getLaterAsset: vi.fn(),
    removeAssets: vi.fn(),
    upsertAssets: vi.fn(),
    update: vi.fn(),
  };

  beforeEach(() => {
    vi.clearAllMocks();
    state.asset = asset;
    state.props = undefined;
    vi.mocked(navigateToAsset).mockResolvedValue(true);
  });

  const mount = async () => {
    render(TimelineAssetViewer, {
      timelineManager: manager as unknown as TimelineManager,
      invisible: false,
      withStacked: true,
    });
    await waitFor(() => expect(state.props).toBeDefined());
    return state.props as { preAction: (action: Action) => Promise<void>; onAction: (action: Action) => Promise<void> };
  };

  it.each([AssetAction.TRASH, AssetAction.DELETE] as const)(
    'does not remove or navigate in preAction for %s',
    async (type) => {
      const props = await mount();
      await props.preAction({ type, asset: toTimelineAsset(asset) });
      expect(manager.removeAssets).not.toHaveBeenCalled();
      expect(navigateToAsset).not.toHaveBeenCalled();
    },
  );

  it('replaces the cover only after success and leaves stack navigation to the viewer', async () => {
    const props = await mount();
    const replacementAsset = assetFactory.build({ id: 'survivor', stack: null });
    await props.onAction({
      type: AssetAction.TRASH,
      asset: toTimelineAsset(asset),
      stackHandled: true,
      stack: null,
      replacementAsset,
    } as Action);
    expect(manager.removeAssets).toHaveBeenCalledWith(['cover']);
    expect(manager.upsertAssets).toHaveBeenCalledWith([toTimelineAsset(replacementAsset)]);
    expect(navigateToAsset).not.toHaveBeenCalled();
  });
});
