<script lang="ts">
  import { cleanClass } from '$lib';
  import { observeLivePhotoPlayback } from '$lib/utils/live-photo-autoplay';
  import { Icon } from '@immich/ui';
  import { mdiAlertCircleOutline, mdiPauseCircleOutline, mdiPlayCircleOutline } from '@mdi/js';
  import { Duration } from 'luxon';
  import { untrack } from 'svelte';
  import type { ClassValue } from 'svelte/elements';
  import LoadingSpinner from '$lib/components/shared-components/LoadingSpinner.svelte';

  interface Props {
    url: string;
    durationInSeconds?: number;
    enablePlayback?: boolean;
    visibleAutoplay?: boolean;
    isLivePhoto?: boolean;
    playbackAllowed?: boolean;
    playbackContext?: string;
    playbackOnIconHover?: boolean;
    showTime?: boolean;
    curve?: boolean;
    playIcon?: string;
    pauseIcon?: string;
    class?: ClassValue;
  }

  let {
    url,
    durationInSeconds = 0,
    enablePlayback = $bindable(false),
    visibleAutoplay = false,
    isLivePhoto = false,
    playbackAllowed = true,
    playbackContext = undefined,
    playbackOnIconHover = false,
    showTime = true,
    curve = false,
    playIcon = mdiPlayCircleOutline,
    pauseIcon = mdiPauseCircleOutline,
    class: className,
  }: Props = $props();

  let container: HTMLDivElement | undefined = $state();
  interface PlaybackSession {
    token: symbol;
    source: string;
    oneShot: boolean;
  }
  let session: PlaybackSession | undefined = $state();
  let playback = $derived(!!session);
  let livePhoto = $derived(isLivePhoto || visibleAutoplay);
  let requestedMode: 'automatic' | 'hover' = $derived(enablePlayback ? 'hover' : 'automatic');
  let playbackRequested = $derived(playbackAllowed && (livePhoto ? visibleAutoplay || enablePlayback : enablePlayback));
  let playbackSource = $derived(url);
  let playbackContextKey = $derived(
    playbackContext ?? (typeof window === 'undefined' ? '' : `${location.pathname}${location.search}`),
  );
  let registration = $state<ReturnType<typeof observeLivePhotoPlayback>>();
  let registrationToken: symbol | undefined;
  const releasedPlayers = new WeakSet<HTMLVideoElement>();

  const releasePlayer = (video: HTMLVideoElement | undefined) => {
    if (!video || releasedPlayers.has(video)) {
      return;
    }
    releasedPlayers.add(video);
    video.pause();
    video.removeAttribute('src');
    video.load();
  };

  $effect(() => {
    const oneShot = livePhoto;
    const source = playbackSource;
    const context = playbackContextKey;
    if (!container || !playbackRequested) {
      return;
    }
    const token = Symbol();
    registrationToken = token;
    const lease = observeLivePhotoPlayback(
      container,
      (active) => {
        untrack(() => {
          if (registrationToken !== token) {
            return;
          }
          // Stop the decoder synchronously: Svelte removes the old DOM node on
          // its next flush, while the shared pool may grant another tile now.
          session = undefined;
          releasePlayer(player);
          session = active ? { token: Symbol(), source, oneShot } : undefined;
          if (active) {
            loading = true;
            error = false;
            remainingSeconds = durationInSeconds;
          }
        });
      },
      { mode: untrack(() => requestedMode), key: source, context },
    );
    registration = lease;
    return () => {
      if (registrationToken === token) {
        registrationToken = undefined;
        registration = undefined;
        untrack(() => {
          session = undefined;
          releasePlayer(player);
        });
      }
      lease.destroy();
    };
  });

  $effect(() => {
    if (livePhoto) {
      registration?.setMode(requestedMode);
    }
  });

  const isCurrentSession = (video: HTMLVideoElement, current: PlaybackSession) =>
    video === player && session?.token === current.token;

  const finishPlayback = (video: HTMLVideoElement, current: PlaybackSession, failed = false) => {
    if (!isCurrentSession(video, current)) {
      return;
    }
    error = failed;
    loading = false;
    session = undefined;
    releasePlayer(video);
    if (failed) {
      registration?.suspend();
    } else {
      registration?.complete();
    }
  };

  let remainingSeconds = $state(durationInSeconds);
  let loading = $state(true);
  let error = $state(false);
  let player: HTMLVideoElement | undefined = $state();

  $effect(() => {
    if (!session) {
      remainingSeconds = durationInSeconds;
    }
  });

  $effect(() => {
    if (!player) {
      return;
    }
    const video = player;
    return () => releasePlayer(video);
  });
  const onMouseEnter = () => {
    if (playbackAllowed && playbackOnIconHover) {
      enablePlayback = true;
    }
  };

  const onMouseLeave = () => {
    if (playbackOnIconHover) {
      enablePlayback = false;
    }
  };
</script>

<div bind:this={container} class="size-full">
  {#if session}
    {#key session.token}
      {@const current = session}
      <video
        bind:this={player}
        class={cleanClass('h-full w-full object-cover', className)}
        class:rounded-xl={curve}
        muted
        playsinline
        autoplay
        loop={!current.oneShot}
        preload="none"
        src={current.source}
        onplay={({ currentTarget }) => {
          if (isCurrentSession(currentTarget, current)) {
            loading = false;
            error = false;
          } else {
            currentTarget.pause();
          }
        }}
        onended={({ currentTarget }) => {
          if (current.oneShot) {
            finishPlayback(currentTarget, current);
          }
        }}
        onerror={({ currentTarget }) => {
          if (currentTarget instanceof HTMLVideoElement) {
            finishPlayback(currentTarget, current, true);
          }
        }}
        ontimeupdate={({ currentTarget }) => {
          if (!isCurrentSession(currentTarget, current)) {
            return;
          }
          const remaining = currentTarget.duration - currentTarget.currentTime;
          remainingSeconds = Math.min(Math.ceil(Number.isNaN(remaining) ? Infinity : remaining), durationInSeconds);
        }}
      ></video>
    {/key}
  {/if}

  <div
    class="@container absolute inset-x-0 top-0 flex place-items-center justify-end gap-1 text-xs font-medium text-white text-shadow-[1px_1px_6px_rgb(0_0_0)]"
  >
    {#if showTime}
      <span class="hidden pt-2 @min-[100px]:inline">
        {#if remainingSeconds < 60}
          {Duration.fromObject({ seconds: remainingSeconds }).toFormat('m:ss')}
        {:else if remainingSeconds < 3600}
          {Duration.fromObject({ seconds: remainingSeconds }).toFormat('mm:ss')}
        {:else}
          {Duration.fromObject({ seconds: remainingSeconds }).toFormat('h:mm:ss')}
        {/if}
      </span>
    {/if}

    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <span
      class="pe-2 pt-2 drop-shadow-[1px_1px_6px_rgb(0_0_0)] @max-[99px]:scale-75 @max-[99px]:pe-1 @max-[99px]:pt-1"
      onmouseenter={onMouseEnter}
      onmouseleave={onMouseLeave}
    >
      {#if error}
        <Icon icon={mdiAlertCircleOutline} size="24" class="text-red-600" />
      {:else if playback}
        {#if loading}
          <LoadingSpinner size="large" />
        {:else}
          <Icon icon={pauseIcon} size="24" />
        {/if}
      {:else}
        <Icon icon={playIcon} size="24" />
      {/if}
    </span>
  </div>
</div>
