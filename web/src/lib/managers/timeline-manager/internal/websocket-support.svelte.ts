import { throttle } from 'lodash-es';
import { SvelteMap, SvelteSet } from 'svelte/reactivity';
import type { Unsubscriber } from 'svelte/store';
import type { TimelineManager } from '$lib/managers/timeline-manager/timeline-manager.svelte';
import type { PendingChange, TimelineAsset } from '$lib/managers/timeline-manager/types';
import { websocketEvents } from '$lib/stores/websocket';
import { toTimelineAsset } from '$lib/utils/timeline-util';

export class WebsocketSupport {
  #pendingChanges: PendingChange[] = [];
  #unsubscribers: Unsubscriber[] = [];
  #timelineManager: TimelineManager;

  #processPendingChanges = throttle(() => {
    const { add, update, remove } = this.#getPendingChangeBatches();
    if (add.length > 0) {
      this.#timelineManager.upsertAssetsFromLiveEvent(add);
    }
    if (update.length > 0) {
      this.#timelineManager.upsertAssetsFromLiveEvent(update);
    }
    if (remove.length > 0) {
      this.#timelineManager.removeAssets(remove);
    }
    this.#pendingChanges = [];
  }, 2500);

  constructor(timeineManager: TimelineManager) {
    this.#timelineManager = timeineManager;
  }

  connectWebsocketEvents() {
    if (this.#unsubscribers.length > 0) {
      return;
    }
    this.#unsubscribers.push(
      websocketEvents.on('on_upload_success', (asset) =>
        this.#addPendingChanges({ type: 'add', values: [toTimelineAsset(asset)] }),
      ),
      websocketEvents.on('on_asset_trash', (ids) => this.#addPendingChanges({ type: 'trash', values: ids })),
      websocketEvents.on('on_asset_update', (asset) =>
        this.#addPendingChanges({ type: 'update', values: [toTimelineAsset(asset)] }),
      ),
      websocketEvents.on('on_asset_delete', (id: string) => this.#addPendingChanges({ type: 'delete', values: [id] })),
    );
  }

  disconnectWebsocketEvents() {
    this.#processPendingChanges.cancel();
    this.#pendingChanges = [];
    for (const unsubscribe of this.#unsubscribers) {
      unsubscribe();
    }
    this.#unsubscribers = [];
  }

  discardPendingAssets(ids: string[]) {
    const removed = new SvelteSet(ids);
    this.#pendingChanges = this.#pendingChanges.map((change): PendingChange => {
      switch (change.type) {
        case 'add':
        case 'update': {
          return { ...change, values: change.values.filter((asset) => !removed.has(asset.id)) };
        }
        case 'trash':
        case 'delete': {
          return { ...change, values: change.values.filter((id) => !removed.has(id)) };
        }
      }
    });
  }

  #addPendingChanges(...changes: PendingChange[]) {
    this.#pendingChanges.push(...changes);
    this.#processPendingChanges();
  }

  #getPendingChangeBatches() {
    const batch: {
      add: TimelineAsset[];
      update: TimelineAsset[];
      remove: string[];
    } = {
      add: [],
      update: [],
      remove: [],
    };
    const latest = new SvelteMap<string, { type: PendingChange['type']; asset?: TimelineAsset }>();
    for (const { type, values } of this.#pendingChanges) {
      switch (type) {
        case 'add':
        case 'update': {
          for (const asset of values) {
            latest.set(asset.id, { type, asset });
          }
          break;
        }
        case 'delete':
        case 'trash': {
          for (const id of values) {
            latest.set(id, { type });
          }
          break;
        }
      }
    }
    for (const [id, change] of latest) {
      if (change.type === 'add') {
        batch.add.push(change.asset!);
      } else if (change.type === 'update') {
        batch.update.push(change.asset!);
      } else {
        batch.remove.push(id);
      }
    }
    return batch;
  }
}
