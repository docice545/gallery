import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { assetFactory } from '@test-data/factories/asset-factory';
import type { TimelineManager } from '../timeline-manager.svelte';
import { WebsocketSupport } from './websocket-support.svelte';

const handlers = vi.hoisted(() => new Map<string, Set<(value: unknown) => void>>());
vi.mock('$lib/stores/websocket', () => ({
  websocketEvents: {
    on(name: string, handler: (value: unknown) => void) {
      const group = handlers.get(name) ?? new Set();
      group.add(handler);
      handlers.set(name, group);
      return () => group.delete(handler);
    },
  },
}));

describe('timeline WebSocket reconciliation', () => {
  const timeline = { upsertAssetsFromLiveEvent: vi.fn(), removeAssets: vi.fn() };
  let support: WebsocketSupport;
  const emit = (name: string, value: unknown) => {
    for (const handler of handlers.get(name) ?? []) {
      handler(value);
    }
  };
  const photo = (id: string) => assetFactory.build({ id, ownerId: 'owner', isTrashed: false });
  const startBatch = () => {
    emit('on_asset_update', photo('seed'));
    timeline.upsertAssetsFromLiveEvent.mockClear();
    timeline.removeAssets.mockClear();
  };

  beforeEach(() => {
    vi.useFakeTimers();
    vi.clearAllMocks();
    handlers.clear();
    support = new WebsocketSupport(timeline as unknown as TimelineManager);
    support.connectWebsocketEvents();
  });
  afterEach(() => {
    support.disconnectWebsocketEvents();
    vi.useRealTimers();
  });

  it('a restore update supersedes older pending Trash for the same cover', () => {
    startBatch();
    emit('on_asset_trash', ['cover']);
    emit('on_asset_update', photo('cover'));
    vi.advanceTimersByTime(2500);
    expect(timeline.removeAssets).not.toHaveBeenCalled();
    expect(timeline.upsertAssetsFromLiveEvent).toHaveBeenCalledOnce();
    expect(timeline.upsertAssetsFromLiveEvent.mock.calls[0][0].map((a: { id: string }) => a.id)).toEqual(['cover']);
  });

  it('a later deletion never re-inserts the preceding update', () => {
    startBatch();
    emit('on_asset_update', photo('frame'));
    emit('on_asset_delete', 'frame');
    vi.advanceTimersByTime(2500);
    expect(timeline.upsertAssetsFromLiveEvent).not.toHaveBeenCalled();
    expect(timeline.removeAssets).toHaveBeenCalledWith(['frame']);
  });

  it('coalesces duplicate events and preserves the final stack count', () => {
    startBatch();
    emit('on_asset_trash', ['old-cover', 'old-cover']);
    emit('on_asset_update', {
      ...photo('new-cover'),
      stack: { id: 'stack', primaryAssetId: 'new-cover', assetCount: 3 },
    });
    emit('on_asset_update', { ...photo('new-cover'), stack: null });
    vi.advanceTimersByTime(2500);
    expect(timeline.removeAssets).toHaveBeenCalledWith(['old-cover']);
    expect(timeline.upsertAssetsFromLiveEvent.mock.calls[0][0]).toHaveLength(1);
    expect(timeline.upsertAssetsFromLiveEvent.mock.calls[0][0][0].stack).toBeNull();
  });

  it('disconnect releases the delayed batch instead of mutating a destroyed timeline', () => {
    startBatch();
    emit('on_asset_trash', ['frame']);
    support.disconnectWebsocketEvents();
    vi.advanceTimersByTime(3000);
    expect(timeline.removeAssets).not.toHaveBeenCalled();
    expect(timeline.upsertAssetsFromLiveEvent).not.toHaveBeenCalled();
  });

  it('confirmed local removal drops an older queued update but permits a later restore', () => {
    startBatch();
    emit('on_asset_update', photo('frame'));
    support.discardPendingAssets(['frame']);
    vi.advanceTimersByTime(2500);
    expect(timeline.upsertAssetsFromLiveEvent).not.toHaveBeenCalled();
    emit('on_asset_update', photo('frame'));
    vi.advanceTimersByTime(2500);
    expect(timeline.upsertAssetsFromLiveEvent).toHaveBeenCalledOnce();
  });

  it('repeated connection and reconnect do not duplicate subscriptions or retain old work', () => {
    support.connectWebsocketEvents();
    emit('on_asset_update', photo('first'));
    vi.advanceTimersByTime(2500);
    expect(timeline.upsertAssetsFromLiveEvent).toHaveBeenCalledOnce();
    support.disconnectWebsocketEvents();
    timeline.upsertAssetsFromLiveEvent.mockClear();
    support.connectWebsocketEvents();
    emit('on_asset_update', photo('second'));
    expect(timeline.upsertAssetsFromLiveEvent).toHaveBeenCalledOnce();
  });
});
