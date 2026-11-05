<script lang="ts">
  import { browser } from '$app/environment';
  import { focusTrap } from '$lib/actions/focus-trap';
  import { shortcuts } from '$lib/actions/shortcut';
  import type { Action, OnAction, PreAction } from '$lib/components/asset-viewer/actions/action';
  import NextAssetAction from '$lib/components/asset-viewer/actions/NextAssetAction.svelte';
  import PreviousAssetAction from '$lib/components/asset-viewer/actions/PreviousAssetAction.svelte';
  import AssetViewerNavBar from '$lib/components/asset-viewer/AssetViewerNavBar.svelte';
  import { preloadManager } from '$lib/components/asset-viewer/PreloadManager.svelte';
  import OnEvents from '$lib/components/OnEvents.svelte';
  import { AssetAction, ProjectionType } from '$lib/constants';
  import { activityManager } from '$lib/managers/activity-manager.svelte';
  import { assetViewerManager } from '$lib/managers/asset-viewer-manager.svelte';
  import { authManager } from '$lib/managers/auth-manager.svelte';
  import { editManager, EditToolType } from '$lib/managers/edit/edit-manager.svelte';
  import { eventManager } from '$lib/managers/event-manager.svelte';
  import type { TimelineAsset } from '$lib/managers/timeline-manager/types';
  import { getAssetActions } from '$lib/services/asset.service';
  import { faceManager } from '$lib/stores/face.svelte';
  import { ocrManager } from '$lib/stores/ocr.svelte';
  import { alwaysLoadOriginalVideo } from '$lib/stores/preferences.store';
  import { SlideshowNavigation, SlideshowState, slideshowStore } from '$lib/stores/slideshow.store';
  import { getSharedLink, handlePromiseError } from '$lib/utils';
  import type { OnUndoDelete } from '$lib/utils/actions';
  import { navigateToAsset } from '$lib/utils/asset-utils';
  import { handleError } from '$lib/utils/handle-error';
  import { navigate } from '$lib/utils/navigation';
  import { InvocationTracker } from '$lib/utils/invocationTracker';
  import { SlideshowHistory } from '$lib/utils/slideshow-history';
  import { toTimelineAsset } from '$lib/utils/timeline-util';
  import {
    AssetTypeEnum,
    getAssetInfo,
    getStack,
    type AlbumResponseDto,
    type AssetResponseDto,
    type PersonResponseDto,
    type StackResponseDto,
  } from '@immich/sdk';
  import { CommandPaletteDefaultProvider } from '@immich/ui';
  import { onDestroy, onMount, untrack } from 'svelte';
  import { SvelteMap, SvelteSet } from 'svelte/reactivity';
  import type { SwipeCustomEvent } from 'svelte-gestures';
  import { t } from 'svelte-i18n';
  import { fly } from 'svelte/transition';
  import Thumbnail from '../assets/thumbnail/Thumbnail.svelte';
  import ActivityStatus from './ActivityStatus.svelte';
  import ActivityViewer from './ActivityViewer.svelte';
  import DetailPanel from './DetailPanel.svelte';
  import EditorPanel from './editor/EditorPanel.svelte';
  import TrimArea from './editor/trim-tool/trim-area.svelte';
  import CropArea from './editor/transform-tool/CropArea.svelte';
  import ImagePanoramaViewer from './ImagePanoramaViewer.svelte';
  import OcrButton from './OcrButton.svelte';
  import PhotoViewer from './PhotoViewer.svelte';
  import SlideshowBar from './SlideshowBar.svelte';
  import SlideshowMetadataOverlay from './SlideshowMetadataOverlay.svelte';
  import VideoViewer from './VideoWrapperViewer.svelte';

  export type AssetCursor = {
    current: AssetResponseDto;
    nextAsset?: AssetResponseDto;
    previousAsset?: AssetResponseDto;
  };

  interface Props {
    cursor: AssetCursor;
    showNavigation?: boolean;
    withStacked?: boolean;
    isShared?: boolean;
    album?: AlbumResponseDto;
    person?: PersonResponseDto;
    onAssetChange?: (asset: AssetResponseDto) => void;
    preAction?: PreAction;
    onAction?: OnAction;
    onUndoDelete?: OnUndoDelete;
    onClose?: (assetId: string) => void;
    onRemoveFromAlbum?: (assetIds: string[]) => void;
    onRandom?: () => Promise<{ id: string } | undefined>;
    spaceId?: string;
    /** Shared-space surface + the caller's write capability on it — see `Timeline` (#889). */
    space?: { id: string; canWrite: boolean };
  }

  let {
    cursor,
    showNavigation = true,
    withStacked = false,
    isShared = false,
    album,
    person,
    onAssetChange,
    preAction,
    onAction,
    onUndoDelete,
    onClose,
    onRemoveFromAlbum,
    onRandom,
    spaceId,
    space,
  }: Props = $props();

  const {
    restartProgress: restartSlideshowProgress,
    stopProgress: stopSlideshowProgress,
    slideshowNavigation,
    slideshowState,
    slideshowRepeat,
    slideshowAutoplay,
  } = slideshowStore;
  const stackThumbnailSize = 60;
  const stackSelectedThumbnailSize = 65;

  let previewStackedAsset: AssetResponseDto | undefined = $state();
  let stack: StackResponseDto | null = $state(null);
  let retainedStack: StackResponseDto | null = null;
  const deletedAssetIds = new SvelteSet<string>();
  const deletionTasks = new SvelteMap<string, Promise<void>>();
  let stackRefreshVersion = 0;
  let destroyed = false;
  const asset = $derived(previewStackedAsset ?? cursor.current);
  const nextAsset = $derived(cursor.nextAsset);
  const previousAsset = $derived(cursor.previousAsset);
  let sharedLink = getSharedLink();
  let fullscreenElement = $state<Element>();

  let isPlayingOriginalVideo = $state($alwaysLoadOriginalVideo);
  let slideshowStartAssetId = $state<string>();

  const setPlayOriginalVideo = (value: boolean) => {
    isPlayingOriginalVideo = value;
  };

  const normalizeStack = (response: StackResponseDto): StackResponseDto => {
    const assets = response.assets.filter(({ id, isTrashed }) => !deletedAssetIds.has(id) && !isTrashed);
    const primaryAssetId = assets.some(({ id }) => id === response.primaryAssetId)
      ? response.primaryAssetId
      : (assets[0]?.id ?? response.primaryAssetId);
    const summary = assets.length > 1 ? { id: response.id, primaryAssetId, assetCount: assets.length } : null;
    return { ...response, primaryAssetId, assets: assets.map((asset) => ({ ...asset, stack: summary })) };
  };

  const refreshStack = async () => {
    const version = ++stackRefreshVersion;
    const current = cursor.current;
    if (authManager.isSharedLink || !withStacked) {
      return;
    }

    if (!current.stack) {
      stack = null;
      if (!retainedStack?.assets.some(({ id }) => id === current.id)) {
        retainedStack = null;
      }
      return;
    }

    const refreshed = await getStack({ id: current.stack.id });
    if (destroyed || version !== stackRefreshVersion || cursor.current.id !== current.id) {
      return;
    }
    const normalized = normalizeStack(refreshed);
    retainedStack = normalized.assets.some(({ id }) => id === current.id) ? normalized : null;
    stack = retainedStack && retainedStack.assets.length > 1 ? retainedStack : null;
  };

  const handleFavorite = async () => {
    if (!album || !album.isActivityEnabled) {
      return;
    }

    try {
      await activityManager.toggleLike();
    } catch (error) {
      handleError(error, $t('errors.unable_to_change_favorite'));
    }
  };

  const onAssetUpdate = (updatedAsset: AssetResponseDto) => {
    if (asset.id === updatedAsset.id) {
      cursor = { ...cursor, current: updatedAsset };
    }
  };

  const onAssetsUndoArchive = async (assets: TimelineAsset[]) => {
    if (assets.length === 0) {
      return;
    }
    const restoredAsset = assets[0];
    await assetViewerManager.setAssetId(restoredAsset.id);
    await navigate({ targetRoute: 'current', assetId: restoredAsset.id });
  };

  const handleUndoDelete: OnUndoDelete = (assets) => {
    for (const restoredAsset of assets) {
      deletedAssetIds.delete(restoredAsset.id);
    }
    onUndoDelete?.(assets);
  };

  onMount(() => {
    syncAssetViewerOpenClass(true);
    const slideshowStateUnsubscribe = slideshowState.subscribe((value) => {
      if (value === SlideshowState.PlaySlideshow) {
        slideshowHistory.reset();
        slideshowHistory.queue(toTimelineAsset(asset));
        handlePromiseError(handlePlaySlideshow());
      } else if (value === SlideshowState.StopSlideshow) {
        handlePromiseError(handleStopSlideshow());
      }
    });

    const slideshowNavigationUnsubscribe = slideshowNavigation.subscribe((value) => {
      if (value !== SlideshowNavigation.Shuffle) {
        return;
      }

      slideshowHistory.reset();
      slideshowHistory.queue(toTimelineAsset(asset));
    });

    return () => {
      slideshowStateUnsubscribe();
      slideshowNavigationUnsubscribe();
    };
  });

  onDestroy(() => {
    destroyed = true;
    stackRefreshVersion++;
    activityManager.reset();
    assetViewerManager.resetPanelState();
    syncAssetViewerOpenClass(false);
    preloadManager.destroy();
  });

  const closeViewer = () => {
    onClose?.(asset.id);
  };

  const closeEditor = async () => {
    if (editManager.hasAppliedEdits) {
      const refreshedAsset = await getAssetInfo({ id: asset.id, spaceId });
      onAssetChange?.(refreshedAsset);
      assetViewerManager.setAsset(refreshedAsset);
    }
    assetViewerManager.closeEditor();
  };

  const tracker = new InvocationTracker();
  const navigateAsset = (order?: 'previous' | 'next') => {
    if (!order) {
      if ($slideshowState === SlideshowState.PlaySlideshow) {
        order = $slideshowNavigation === SlideshowNavigation.AscendingOrder ? 'previous' : 'next';
      } else {
        return;
      }
    }

    preloadManager.cancelBeforeNavigation(order);

    if (tracker.isActive()) {
      return;
    }

    void tracker.invoke(async () => {
      const isShuffle =
        $slideshowState === SlideshowState.PlaySlideshow && $slideshowNavigation === SlideshowNavigation.Shuffle;

      let hasNext: boolean;

      if (isShuffle) {
        hasNext = order === 'previous' ? slideshowHistory.previous() : slideshowHistory.next();
        if (!hasNext) {
          const asset = await onRandom?.();
          if (asset) {
            slideshowHistory.queue(asset);
            hasNext = true;
          }
        }
      } else {
        hasNext =
          order === 'previous' ? await navigateToAsset(cursor.previousAsset) : await navigateToAsset(cursor.nextAsset);
      }

      if ($slideshowState !== SlideshowState.PlaySlideshow) {
        return;
      }

      if (hasNext) {
        $restartSlideshowProgress = true;
        return;
      }

      if ($slideshowRepeat && slideshowStartAssetId) {
        await assetViewerManager.setAssetId(slideshowStartAssetId, spaceId);
        $restartSlideshowProgress = true;
        return;
      }

      await handleStopSlideshow();
    }, $t('error_while_navigating'));
  };

  const navigateStack = (direction: 'previous' | 'next') => {
    if (!stack || !withStacked || assetViewerManager.isShowEditor) {
      return;
    }
    const assets = stack.assets;
    const currentIndex = assets.findIndex(({ id }) => id === asset.id);
    if (currentIndex === -1) {
      return;
    }
    const nextIndex = direction === 'previous' ? currentIndex - 1 : currentIndex + 1;
    if (nextIndex < 0 || nextIndex >= assets.length) {
      return;
    }
    cursor = { ...cursor, current: assets[nextIndex] };
  };

  /**
   * Slide show mode
   */

  let assetViewerHtmlElement = $state<HTMLElement>();

  const slideshowHistory = new SlideshowHistory((asset) => {
    handlePromiseError(assetViewerManager.setAssetId(asset.id, spaceId).then(() => ($restartSlideshowProgress = true)));
  });

  const handleVideoStarted = () => {
    if ($slideshowState === SlideshowState.PlaySlideshow) {
      $stopSlideshowProgress = true;
    }
  };

  const handlePlaySlideshow = async () => {
    slideshowStartAssetId = asset.id;
    if (!$slideshowAutoplay) {
      $slideshowState = SlideshowState.PauseSlideshow;
    }
    try {
      await assetViewerHtmlElement?.requestFullscreen?.();
    } catch (error) {
      handleError(error, $t('errors.unable_to_enter_fullscreen'));
      $slideshowState = SlideshowState.StopSlideshow;
    }
  };

  const handleStopSlideshow = async () => {
    try {
      if (document.fullscreenElement) {
        await document.exitFullscreen();
      }
    } catch (error) {
      handleError(error, $t('errors.unable_to_exit_fullscreen'));
    } finally {
      $stopSlideshowProgress = true;
      $slideshowState = SlideshowState.None;
    }
  };

  const handleStackedAssetMouseEvent = (isMouseOver: boolean, stackedAsset: AssetResponseDto) => {
    previewStackedAsset = isMouseOver ? stackedAsset : undefined;
  };

  const handlePreAction = (action: Action) => {
    preAction?.(action);
  };

  const handleDeletedAssets = async (
    ids: string[],
    action?: Extract<Action, { type: AssetAction.DELETE | AssetAction.TRASH }>,
  ) => {
    const removed = new Set(ids.filter((id) => !deletedAssetIds.has(id)));
    if (removed.size === 0) {
      return;
    }
    const previousStack = stack ?? retainedStack;
    const removedAsset = action?.asset ?? previousStack?.assets.find(({ id }) => removed.has(id)) ?? cursor.current;
    const relevant =
      removed.has(cursor.current.id) ||
      previousStack?.assets.some(({ id }) => removed.has(id)) ||
      (previewStackedAsset && removed.has(previewStackedAsset.id));
    for (const id of removed) {
      deletedAssetIds.add(id);
    }
    const completedAction = action ?? { type: AssetAction.TRASH, asset: toTimelineAsset(removedAsset) };
    const targetStackId = removedAsset.stack?.id ?? (relevant ? previousStack?.id : undefined);
    const isInTargetStack = () =>
      cursor.current.id === removedAsset.id ||
      (!!targetStackId &&
        (cursor.current.stack?.id === targetStackId ||
          (retainedStack?.id === targetStackId && retainedStack.assets.some(({ id }) => id === cursor.current.id))));
    if (!relevant && !action) {
      return;
    }
    if (!withStacked || !targetStackId) {
      await Promise.resolve(onAction?.(completedAction));
      return;
    }

    // Invalidate pre-deletion requests before any cursor change can start another refresh.
    const inTargetStack = isInTargetStack();
    if (inTargetStack) {
      stackRefreshVersion++;
      previewStackedAsset = undefined;
    }
    const source = previousStack?.id === targetStackId ? previousStack : null;
    let updated = normalizeStack(
      source ?? { id: targetStackId, primaryAssetId: removedAsset.id, assets: inTargetStack ? [cursor.current] : [] },
    );
    const selectSurvivor = (response: StackResponseDto) => {
      retainedStack = response;
      stack = response.assets.length > 1 ? response : null;
      const order = source?.assets ?? response.assets;
      const currentIndex = order.findIndex(({ id }) => id === cursor.current.id);
      const next = order.slice(currentIndex + 1).find(({ id }) => !deletedAssetIds.has(id));
      const previous = order.slice(0, currentIndex).findLast(({ id }) => !deletedAssetIds.has(id));
      const selectedId = deletedAssetIds.has(cursor.current.id) ? (next ?? previous)?.id : cursor.current.id;
      const selected = response.assets.find(({ id }) => id === selectedId) ?? response.assets[0];
      if (selected) {
        cursor = { ...cursor, current: selected };
      }
    };
    if (source && inTargetStack) {
      selectSurvivor(updated);
    }
    const version = inTargetStack ? ++stackRefreshVersion : stackRefreshVersion;
    try {
      const refreshed = normalizeStack(await getStack({ id: targetStackId }));
      updated = refreshed;
      if (!destroyed && version === stackRefreshVersion && isInTargetStack()) {
        selectSurvivor(updated);
      }
    } catch {
      // A depleted stack may have disappeared. Keep the confirmed local removals on a refresh failure.
    }
    if (destroyed) {
      return;
    }
    updated = normalizeStack(updated);

    await Promise.resolve(
      onAction?.({
        ...completedAction,
        stackHandled: true,
        stack: updated.assets.length > 1 ? updated : null,
        replacementAsset: updated.assets.find(({ id }) => id === updated.primaryAssetId),
      }),
    );

    if (!destroyed && updated.assets.length === 0 && isInTargetStack()) {
      const next = cursor.nextAsset && !deletedAssetIds.has(cursor.nextAsset.id) ? cursor.nextAsset : undefined;
      const previous =
        cursor.previousAsset && !deletedAssetIds.has(cursor.previousAsset.id) ? cursor.previousAsset : undefined;
      if (!(await navigateToAsset(next)) && !(await navigateToAsset(previous))) {
        closeViewer();
      }
    }
  };

  const handleConfirmedDeletion = (
    ids: string[],
    action?: Extract<Action, { type: AssetAction.DELETE | AssetAction.TRASH }>,
  ) => {
    const freshIds = ids.filter((id) => !deletedAssetIds.has(id));
    if (freshIds.length === 0) {
      return Promise.all(ids.map((id) => deletionTasks.get(id)).filter((task) => task !== undefined)).then(() => {});
    }
    const task = handleDeletedAssets(freshIds, action);
    for (const id of freshIds) {
      deletionTasks.set(id, task);
    }
    return task;
  };

  const onAssetsDelete = (ids: string[]) => handleConfirmedDeletion(ids);

  const handleAction = async (action: Action) => {
    switch (action.type) {
      case AssetAction.DELETE:
      case AssetAction.TRASH: {
        await handleConfirmedDeletion([action.asset.id], action);
        eventManager.emit('AssetsDelete', [action.asset.id]);
        return;
      }
      case AssetAction.REMOVE_ASSET_FROM_STACK: {
        stackRefreshVersion++;
        stack = action.stack;
        retainedStack = action.stack;
        if (stack) {
          cursor = { ...cursor, current: stack.assets[0] };
        }
        break;
      }
      case AssetAction.STACK:
      case AssetAction.SET_STACK_PRIMARY_ASSET: {
        stackRefreshVersion++;
        stack = action.stack;
        retainedStack = action.stack;
        break;
      }
      case AssetAction.SET_PERSON_FEATURED_PHOTO: {
        const assetInfo = await getAssetInfo({ id: asset.id, spaceId });
        cursor.current = { ...asset, people: assetInfo.people };
        eventManager.emit('AssetUpdate', cursor.current);
        break;
      }
      case AssetAction.RATING: {
        cursor.current = {
          ...asset,
          exifInfo: {
            ...asset.exifInfo,
            rating: action.rating,
          },
        };
        break;
      }
      case AssetAction.UNSTACK: {
        closeViewer();
        break;
      }
      case AssetAction.RESTORE: {
        deletedAssetIds.delete(action.asset.id);
        await refreshStack();
        break;
      }
      // no default
    }

    onAction?.(action);
  };

  let isFullScreen = $derived(!!fullscreenElement);

  $effect(() => {
    if (album && !album.isActivityEnabled && activityManager.commentCount === 0) {
      assetViewerManager.closeActivityPanel();
    }
  });
  $effect(() => {
    if (album && isShared && asset.id) {
      handlePromiseError(activityManager.init(album.id, asset.id));
    }
  });

  const syncAssetViewerOpenClass = (isOpen: boolean) => {
    if (browser) {
      document.body.classList.toggle('asset-viewer-open', isOpen);
    }
  };

  const refresh = async () => {
    const current = asset;
    const preview = previewStackedAsset;
    await refreshStack();
    if (destroyed) {
      return;
    }
    ocrManager.clear();
    faceManager.clear();
    if (!sharedLink) {
      if (preview) {
        await ocrManager.getAssetOcr(preview.id);
        await faceManager.getAssetFaces(preview.id);
      }
      await ocrManager.getAssetOcr(current.id);
      await faceManager.getAssetFaces(current.id);
    }
  };

  $effect(() => {
    // eslint-disable-next-line @typescript-eslint/no-unused-expressions
    asset;
    untrack(() => handlePromiseError(refresh()));
  });

  let lastCursor = $state<AssetCursor>();

  $effect(() => {
    if (cursor.current.id === lastCursor?.current.id) {
      return;
    }
    if (lastCursor) {
      preloadManager.updateAfterNavigation(lastCursor, cursor, sharedLink);
    }
    if (!lastCursor) {
      preloadManager.initializePreloads(cursor, sharedLink);
    }
    lastCursor = cursor;
  });

  const viewerKind = $derived.by(() => {
    if (previewStackedAsset) {
      return previewStackedAsset.type === AssetTypeEnum.Image ? 'PhotoViewer' : 'StackVideoViewer';
    }
    if (assetViewerManager.isShowEditor && editManager.selectedTool?.type === EditToolType.Trim) {
      return 'TrimArea';
    }
    if (asset.type === AssetTypeEnum.Video) {
      return 'VideoViewer';
    }
    if (assetViewerManager.isPlayingMotionPhoto && asset.livePhotoVideoId) {
      return 'LiveVideoViewer';
    }
    if (
      asset.exifInfo?.projectionType === ProjectionType.EQUIRECTANGULAR ||
      (asset.originalPath && asset.originalPath.toLowerCase().endsWith('.insp'))
    ) {
      return 'ImagePanaramaViewer';
    }
    if (assetViewerManager.isShowEditor && editManager.selectedTool?.type === EditToolType.Transform) {
      return 'CropArea';
    }
    return 'PhotoViewer';
  });

  const showActivityStatus = $derived(
    $slideshowState === SlideshowState.None &&
      isShared &&
      ((album && album.isActivityEnabled) || activityManager.commentCount > 0) &&
      !activityManager.isLoading,
  );

  const showOcrButton = $derived(
    $slideshowState === SlideshowState.None &&
      asset.type === AssetTypeEnum.Image &&
      !assetViewerManager.isShowEditor &&
      ocrManager.hasOcrData,
  );

  const { Tag, TagPeople } = $derived(getAssetActions($t, asset));
  const showDetailPanel = $derived(
    asset.hasMetadata &&
      $slideshowState === SlideshowState.None &&
      assetViewerManager.isShowDetailPanel &&
      !assetViewerManager.isShowEditor,
  );

  const onSwipe = (event: SwipeCustomEvent) => {
    if (assetViewerManager.zoom > 1) {
      return;
    }

    if (ocrManager.showOverlay) {
      return;
    }

    if (event.detail.direction === 'left') {
      navigateAsset('next');
    } else if (event.detail.direction === 'right') {
      navigateAsset('previous');
    }
  };
</script>

<CommandPaletteDefaultProvider name={$t('assets')} actions={[Tag, TagPeople]} />
<OnEvents {onAssetUpdate} {onAssetsUndoArchive} {onAssetsDelete} />

<svelte:document
  bind:fullscreenElement
  use:shortcuts={[
    { shortcut: { key: 'ArrowUp' }, onShortcut: () => navigateStack('previous') },
    { shortcut: { key: 'ArrowDown' }, onShortcut: () => navigateStack('next') },
  ]}
/>

<section
  id="immich-asset-viewer"
  class="fixed inset-s-0 top-0 grid size-full grid-cols-4 grid-rows-[64px_1fr] overflow-hidden bg-black"
  use:focusTrap
  bind:this={assetViewerHtmlElement}
>
  <!-- Top navigation bar -->
  {#if $slideshowState === SlideshowState.None && !assetViewerManager.isShowEditor}
    <div class="col-span-4 col-start-1 row-span-1 row-start-1 transition-transform">
      <AssetViewerNavBar
        {asset}
        {album}
        {person}
        {stack}
        preAction={handlePreAction}
        onAction={handleAction}
        onUndoDelete={onUndoDelete ? handleUndoDelete : undefined}
        onClose={onClose ? () => onClose(stack?.primaryAssetId ?? asset.id) : undefined}
        {onRemoveFromAlbum}
        {isPlayingOriginalVideo}
        {setPlayOriginalVideo}
        {space}
      />
    </div>
  {/if}

  {#if $slideshowState !== SlideshowState.None}
    <div class="absolute inset-s-0 top-0 flex w-full justify-start">
      <SlideshowBar
        {isFullScreen}
        assetType={previewStackedAsset?.type ?? asset.type}
        onSetToFullScreen={() => assetViewerHtmlElement?.requestFullscreen?.()}
        onPrevious={() => navigateAsset('previous')}
        onNext={() => navigateAsset('next')}
        onClose={() => ($slideshowState = SlideshowState.StopSlideshow)}
      />
    </div>
  {/if}

  {#if $slideshowState === SlideshowState.None && showNavigation && !assetViewerManager.isShowEditor && !assetViewerManager.isFaceEditMode && previousAsset}
    <div class="col-span-1 col-start-1 row-span-full row-start-1 my-auto justify-self-start">
      <PreviousAssetAction onPreviousAsset={() => navigateAsset('previous')} />
    </div>
  {/if}

  <!-- Asset Viewer -->
  <div data-viewer-content class="relative z-[-1] col-span-4 col-start-1 row-span-full row-start-1">
    {#if viewerKind === 'StackVideoViewer'}
      <VideoViewer
        asset={previewStackedAsset!}
        cacheKey={previewStackedAsset!.thumbhash}
        projectionType={previewStackedAsset!.exifInfo?.projectionType}
        loopVideo={true}
        onPreviousAsset={() => navigateAsset('previous')}
        onNextAsset={() => navigateAsset('next')}
        onClose={closeViewer}
        onVideoEnded={() => navigateAsset()}
        onVideoStarted={handleVideoStarted}
        playOriginalVideo={isPlayingOriginalVideo}
      />
    {:else if viewerKind === 'LiveVideoViewer'}
      <VideoViewer
        {asset}
        assetId={asset.livePhotoVideoId!}
        cacheKey={asset.thumbhash}
        projectionType={asset.exifInfo?.projectionType}
        loopVideo={$slideshowState !== SlideshowState.PlaySlideshow}
        onPreviousAsset={() => navigateAsset('previous')}
        onNextAsset={() => navigateAsset('next')}
        onVideoEnded={() => (assetViewerManager.isPlayingMotionPhoto = false)}
        playOriginalVideo={isPlayingOriginalVideo}
      />
    {:else if viewerKind === 'ImagePanaramaViewer'}
      <ImagePanoramaViewer {asset} />
    {:else if viewerKind === 'TrimArea'}
      <TrimArea {asset} />
    {:else if viewerKind === 'CropArea'}
      <CropArea {asset} />
    {:else if viewerKind === 'PhotoViewer'}
      <PhotoViewer cursor={{ ...cursor, current: asset }} {sharedLink} {onSwipe} />
    {:else if viewerKind === 'VideoViewer'}
      <VideoViewer
        {asset}
        cacheKey={asset.thumbhash}
        projectionType={asset.exifInfo?.projectionType}
        loopVideo={$slideshowState !== SlideshowState.PlaySlideshow}
        extendedControls
        onPreviousAsset={() => navigateAsset('previous')}
        onNextAsset={() => navigateAsset('next')}
        onClose={closeViewer}
        onVideoEnded={() => navigateAsset()}
        onVideoStarted={handleVideoStarted}
        playOriginalVideo={isPlayingOriginalVideo}
      />
    {/if}

    {#if showActivityStatus}
      <div class="absolute inset-e-0 bottom-0 me-8 mb-20">
        <ActivityStatus
          disabled={!album?.isActivityEnabled}
          isLiked={activityManager.isLiked}
          numberOfComments={activityManager.commentCount}
          numberOfLikes={activityManager.likeCount}
          onFavorite={handleFavorite}
        />
      </div>
    {/if}

    {#if showOcrButton}
      <div class="absolute inset-e-0 bottom-0 me-6 mb-6 drop-shadow-[0_0_1px_rgba(0,0,0,0.4)]">
        <OcrButton />
      </div>
    {/if}

    {#if $slideshowState !== SlideshowState.None}
      <SlideshowMetadataOverlay {asset} />
    {/if}
  </div>

  {#if $slideshowState === SlideshowState.None && showNavigation && !assetViewerManager.isShowEditor && !assetViewerManager.isFaceEditMode && nextAsset}
    <div class="col-span-1 col-start-4 row-span-full row-start-1 my-auto justify-self-end">
      <NextAssetAction onNextAsset={() => navigateAsset('next')} />
    </div>
  {/if}

  {#if showDetailPanel || assetViewerManager.isShowEditor}
    <div
      transition:fly={{ duration: 150 }}
      id="detail-panel"
      class={[
        'row-span-4 row-start-1 overflow-y-auto bg-light transition-all dark:border-l dark:border-s-immich-dark-gray',
        showDetailPanel ? 'w-90' : 'w-100',
      ]}
      translate="yes"
    >
      {#if showDetailPanel}
        <DetailPanel {asset} currentAlbum={album} {spaceId} />
      {:else if assetViewerManager.isShowEditor}
        <EditorPanel {asset} onClose={closeEditor} />
      {/if}
    </div>
  {/if}

  {#if stack && stack.assets.length > 1 && withStacked && !assetViewerManager.isShowEditor && $slideshowState === SlideshowState.None}
    {@const stackedAssets = stack.assets}
    <div id="stack-slideshow" class="absolute bottom-0 col-span-4 col-start-1 w-fit max-w-full">
      <div class="no-wrap horizontal-scrollbar relative flex flex-row overflow-x-auto overflow-y-hidden">
        {#each stackedAssets as stackedAsset (stackedAsset.id)}
          <div
            class={['relative inline-block px-1 pb-2 transition-all']}
            style:bottom={stackedAsset.id === asset.id ? '0' : '-10px'}
          >
            <Thumbnail
              imageClass={{ 'border-2 border-white': stackedAsset.id === asset.id }}
              brokenAssetClass="text-xs"
              dimmed={stackedAsset.id !== asset.id}
              asset={toTimelineAsset(stackedAsset)}
              onClick={() => {
                cursor = { ...cursor, current: stackedAsset };
                previewStackedAsset = undefined;
              }}
              onMouseEvent={({ isMouseOver }) => handleStackedAssetMouseEvent(isMouseOver, stackedAsset)}
              readonly
              thumbnailSize={stackedAsset.id === asset.id ? stackSelectedThumbnailSize : stackThumbnailSize}
              showStackedIcon={false}
              disableLinkMouseOver
            />

            {#if stackedAsset.id === asset.id}
              <div class="flex w-full place-content-center place-items-center">
                <div class="mt-0.5 flex size-2 rounded-full bg-white"></div>
              </div>
            {/if}
          </div>
        {/each}
      </div>
    </div>
  {/if}

  {#if isShared && album && assetViewerManager.isShowActivityPanel && authManager.authenticated}
    <div
      transition:fly={{ duration: 150 }}
      id="activity-panel"
      class="row-span-5 row-start-1 w-90 overflow-y-auto transition-all md:w-115 dark:border-l dark:border-s-immich-dark-gray"
      translate="yes"
    >
      <ActivityViewer
        disabled={!album.isActivityEnabled}
        assetType={asset.type}
        albumUsers={album.albumUsers}
        albumId={album.id}
        assetId={asset.id}
      />
    </div>
  {/if}
</section>

<style>
  #immich-asset-viewer {
    contain: layout;
  }

  .horizontal-scrollbar::-webkit-scrollbar {
    width: 8px;
    height: 10px;
  }

  /* Track */
  .horizontal-scrollbar::-webkit-scrollbar-track {
    background: #000000;
    border-radius: 16px;
  }

  /* Handle */
  .horizontal-scrollbar::-webkit-scrollbar-thumb {
    background: rgba(159, 159, 159, 0.408);
    border-radius: 16px;
  }

  /* Handle on hover */
  .horizontal-scrollbar::-webkit-scrollbar-thumb:hover {
    background: #adcbfa;
    border-radius: 16px;
  }
</style>
