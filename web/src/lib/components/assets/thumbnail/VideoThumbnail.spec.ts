import { cleanup, fireEvent, render } from '@testing-library/svelte';
import { tick } from 'svelte';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import VideoThumbnail from './VideoThumbnail.svelte';

const observation = vi.hoisted(() => ({
  registrations: [] as {
    change: (active: boolean) => void;
    options: { mode: 'automatic' | 'hover'; key: string; context: string };
    complete: ReturnType<typeof vi.fn>;
    setMode: ReturnType<typeof vi.fn>;
    suspend: ReturnType<typeof vi.fn>;
    destroy: ReturnType<typeof vi.fn>;
  }[],
}));
vi.mock('$lib/utils/live-photo-autoplay', () => ({
  observeLivePhotoPlayback: (
    _element: HTMLElement,
    change: (active: boolean) => void,
    options: { mode: 'automatic' | 'hover'; key: string; context: string },
  ) => {
    const registration = {
      change,
      options,
      complete: vi.fn(() => change(false)),
      setMode: vi.fn(),
      suspend: vi.fn(() => change(false)),
      destroy: vi.fn(() => change(false)),
    };
    observation.registrations.push(registration);
    return registration;
  },
}));

beforeEach(() => {
  vi.clearAllMocks();
  observation.registrations.length = 0;
});
afterEach(() => {
  cleanup();
  vi.useRealTimers();
});

const registration = () => observation.registrations.at(-1)!;

describe('Live Photo thumbnail controller lifecycle', () => {
  it('creates one muted inline one-shot decoder only after a grant and releases its source on unmount', async () => {
    const { container, unmount } = render(VideoThumbnail, { url: '/motion.mp4', visibleAutoplay: true });
    await tick();
    expect(container.querySelector('video')).toBeNull();
    expect(registration().options).toEqual({
      mode: 'automatic',
      key: '/motion.mp4',
      context: `${location.pathname}${location.search}`,
    });
    registration().change(true);
    await tick();
    const video = container.querySelector('video')!;
    expect(video.autoplay).toBe(true);
    expect(video.muted).toBe(true);
    expect(video.loop).toBe(false);
    expect(video.preload).toBe('none');
    expect(video.hasAttribute('playsinline')).toBe(true);
    const pause = vi.spyOn(video, 'pause');
    const load = vi.spyOn(video, 'load');
    unmount();
    await tick();
    expect(pause).toHaveBeenCalledOnce();
    expect(load).toHaveBeenCalledOnce();
    expect(video.hasAttribute('src')).toBe(false);
    expect(registration().destroy).toHaveBeenCalledOnce();
  });

  it('clears a revoked decoder synchronously before the shared pool can grant another tile', async () => {
    const { container } = render(VideoThumbnail, { url: '/motion.mp4', visibleAutoplay: true });
    await tick();
    registration().change(true);
    await tick();
    const video = container.querySelector('video')!;
    const pause = vi.spyOn(video, 'pause');
    const load = vi.spyOn(video, 'load');
    registration().change(false);
    expect(video.hasAttribute('src')).toBe(false);
    expect(pause).toHaveBeenCalledOnce();
    expect(load).toHaveBeenCalledOnce();
    await tick();
    expect(container.querySelector('video')).toBeNull();
    expect(pause).toHaveBeenCalledOnce();
  });

  it('completes a natural end once without looping, retrying or retaining a decoder', async () => {
    vi.useFakeTimers();
    const { container } = render(VideoThumbnail, { url: '/motion.mp4', visibleAutoplay: true });
    await tick();
    const lease = registration();
    lease.change(true);
    await tick();
    const video = container.querySelector('video')!;
    await fireEvent.ended(video);
    await fireEvent.ended(video);
    expect(lease.complete).toHaveBeenCalledOnce();
    expect(video.hasAttribute('src')).toBe(false);
    await vi.advanceTimersByTimeAsync(5000);
    await tick();
    expect(container.querySelector('video')).toBeNull();
    expect(observation.registrations).toHaveLength(1);
  });

  it('releases an errored decoder without a reload loop or an implicit next-candidate request', async () => {
    vi.useFakeTimers();
    const { container } = render(VideoThumbnail, { url: '/motion.mp4', visibleAutoplay: true });
    await tick();
    const lease = registration();
    lease.change(true);
    await tick();
    const video = container.querySelector('video')!;
    await fireEvent.error(video);
    await fireEvent.error(video);
    expect(lease.suspend).toHaveBeenCalledOnce();
    expect(lease.complete).not.toHaveBeenCalled();
    expect(video.hasAttribute('src')).toBe(false);
    await vi.advanceTimersByTimeAsync(5000);
    await tick();
    expect(container.querySelector('video')).toBeNull();
    expect(observation.registrations).toHaveLength(1);
  });

  it('Live Photo hover requests the same one-shot lease and cannot bypass a disabled viewer gate', async () => {
    const { container, rerender } = render(VideoThumbnail, {
      url: '/motion.mp4',
      isLivePhoto: true,
      visibleAutoplay: true,
      enablePlayback: true,
      playbackOnIconHover: true,
      showTime: false,
    });
    await tick();
    expect(container.querySelector('video')).toBeNull();
    await fireEvent.mouseEnter(container.querySelector('span')!);
    expect(container.querySelector('video')).toBeNull();
    const lease = registration();
    expect(lease.options.mode).toBe('hover');
    expect(lease.setMode).toHaveBeenLastCalledWith('hover');
    lease.change(true);
    await tick();
    const video = container.querySelector('video')!;
    expect(video.loop).toBe(false);
    await rerender({
      url: '/motion.mp4',
      isLivePhoto: true,
      visibleAutoplay: false,
      enablePlayback: true,
      playbackAllowed: false,
    });
    expect(video.hasAttribute('src')).toBe(false);
    expect(container.querySelector('video')).toBeNull();
    expect(lease.destroy).toHaveBeenCalledOnce();
    expect(observation.registrations).toHaveLength(1);
  });

  it('hovering an active automatic Live Photo changes priority without refetching its source', async () => {
    const { container, rerender } = render(VideoThumbnail, {
      url: '/motion.mp4',
      isLivePhoto: true,
      visibleAutoplay: true,
    });
    await tick();
    const lease = registration();
    lease.change(true);
    await tick();
    const video = container.querySelector('video')!;
    const load = vi.spyOn(video, 'load');
    await rerender({ url: '/motion.mp4', isLivePhoto: true, visibleAutoplay: true, enablePlayback: true });
    expect(lease.setMode).toHaveBeenLastCalledWith('hover');
    expect(observation.registrations).toHaveLength(1);
    expect(container.querySelector('video')).toBe(video);
    expect(load).not.toHaveBeenCalled();
    expect(video.loop).toBe(false);
  });

  it('an explicitly hovered Live Photo can play through the pool while visibility autoplay is disabled', async () => {
    const { container } = render(VideoThumbnail, {
      url: '/motion.mp4',
      isLivePhoto: true,
      visibleAutoplay: false,
      enablePlayback: true,
    });
    await tick();
    expect(registration().options.mode).toBe('hover');
    expect(container.querySelector('video')).toBeNull();
    const lease = registration();
    lease.change(true);
    await tick();
    const video = container.querySelector('video')!;
    expect(video.loop).toBe(false);
    await fireEvent.ended(video);
    expect(lease.complete).toHaveBeenCalledOnce();
    expect(container.querySelector('video')).toBeNull();
  });

  it('ordinary video hover uses the shared hover lease and retains looping playback', async () => {
    const { container, rerender } = render(VideoThumbnail, { url: '/ordinary.mp4', enablePlayback: true });
    await tick();
    expect(registration().options).toEqual({
      mode: 'hover',
      key: '/ordinary.mp4',
      context: `${location.pathname}${location.search}`,
    });
    expect(container.querySelector('video')).toBeNull();
    const lease = registration();
    lease.change(true);
    await tick();
    const video = container.querySelector('video')!;
    expect(video.loop).toBe(true);
    await fireEvent.ended(video);
    expect(lease.complete).not.toHaveBeenCalled();
    await rerender({ url: '/ordinary.mp4', enablePlayback: false });
    expect(video.hasAttribute('src')).toBe(false);
    expect(container.querySelector('video')).toBeNull();
    expect(lease.destroy).toHaveBeenCalledOnce();
  });

  it('ordinary icon hover still requests and releases a hover lease', async () => {
    const { container } = render(VideoThumbnail, {
      url: '/ordinary.mp4',
      playbackOnIconHover: true,
      showTime: false,
    });
    await tick();
    expect(observation.registrations).toHaveLength(0);
    const icon = container.querySelector('span')!;
    await fireEvent.mouseEnter(icon);
    expect(registration().options.mode).toBe('hover');
    registration().change(true);
    await tick();
    const video = container.querySelector('video')!;
    await fireEvent.mouseLeave(icon);
    expect(video.hasAttribute('src')).toBe(false);
    expect(container.querySelector('video')).toBeNull();
  });

  it('opening a viewer disables even an internally enabled hover and resuming does not duplicate decoders', async () => {
    const { container, rerender } = render(VideoThumbnail, { url: '/ordinary.mp4', enablePlayback: true });
    await tick();
    const lease = registration();
    lease.change(true);
    await tick();
    const video = container.querySelector('video')!;
    await rerender({ url: '/ordinary.mp4', enablePlayback: true, playbackAllowed: false });
    expect(video.hasAttribute('src')).toBe(false);
    expect(container.querySelector('video')).toBeNull();
    expect(lease.destroy).toHaveBeenCalledOnce();
    lease.change(true);
    await tick();
    expect(container.querySelector('video')).toBeNull();
    await rerender({ url: '/ordinary.mp4', enablePlayback: true, playbackAllowed: true });
    expect(observation.registrations).toHaveLength(2);
    registration().change(true);
    await tick();
    expect(container.querySelectorAll('video')).toHaveLength(1);
    expect(container.querySelector('video')).not.toBe(video);
  });

  it('invalidates an old URL grant and ignores stale ready, error and ended events', async () => {
    const { container, rerender } = render(VideoThumbnail, { url: '/old.mp4', visibleAutoplay: true });
    await tick();
    const oldLease = registration();
    oldLease.change(true);
    await tick();
    const oldVideo = container.querySelector('video')!;
    await rerender({ url: '/new.mp4', visibleAutoplay: true });
    expect(oldVideo.hasAttribute('src')).toBe(false);
    expect(oldLease.destroy).toHaveBeenCalledOnce();
    expect(container.querySelector('video')).toBeNull();
    const newLease = registration();
    oldLease.change(true);
    await tick();
    expect(container.querySelector('video')).toBeNull();
    newLease.change(true);
    await tick();
    const newVideo = container.querySelector('video')!;
    expect(newVideo.getAttribute('src')).toBe('/new.mp4');
    await fireEvent.error(oldVideo);
    await fireEvent.ended(oldVideo);
    await fireEvent.play(oldVideo);
    expect(newLease.suspend).not.toHaveBeenCalled();
    expect(newLease.complete).not.toHaveBeenCalled();
    expect(container.querySelectorAll('video')).toHaveLength(1);
    expect(container.querySelector('video')).toBe(newVideo);
  });

  it('rerendering unchanged source and playback inputs does not fetch or create another video', async () => {
    const { container, rerender } = render(VideoThumbnail, { url: '/motion.mp4', visibleAutoplay: true });
    await tick();
    registration().change(true);
    await tick();
    const video = container.querySelector('video')!;
    const load = vi.spyOn(video, 'load');
    await rerender({ url: '/motion.mp4', visibleAutoplay: true, curve: true, showTime: false });
    expect(observation.registrations).toHaveLength(1);
    expect(container.querySelector('video')).toBe(video);
    expect(load).not.toHaveBeenCalled();
  });
});
