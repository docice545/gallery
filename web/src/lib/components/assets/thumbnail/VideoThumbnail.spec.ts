import { cleanup, fireEvent, render, waitFor } from '@testing-library/svelte';
import { tick } from 'svelte';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import VideoThumbnail from './VideoThumbnail.svelte';

const observation = vi.hoisted(() => ({ change: (_: boolean) => {}, suspend: vi.fn(), destroy: vi.fn() }));
vi.mock('$lib/utils/live-photo-autoplay', () => ({
  observeLivePhotoPlayback: (_element: HTMLElement, change: (active: boolean) => void) => {
    observation.change = change;
    return { suspend: observation.suspend, destroy: observation.destroy };
  },
}));

beforeEach(() => {
  vi.clearAllMocks();
  observation.suspend.mockImplementation(() => observation.change(false));
  observation.destroy.mockImplementation(() => observation.change(false));
});
afterEach(() => {
  cleanup();
  vi.useRealTimers();
});

describe('Live Photo thumbnail controller lifecycle', () => {
  it('cold visible grant creates a muted inline autoplay decoder; disposal removes its source', async () => {
    const { container, unmount } = render(VideoThumbnail, { url: '/motion.mp4', visibleAutoplay: true });
    await tick();
    expect(container.querySelector('video')).toBeNull();
    observation.change(true);
    await tick();
    const video = container.querySelector('video')!;
    expect(video.autoplay).toBe(true);
    expect(video.muted).toBe(true);
    expect(video.hasAttribute('playsinline')).toBe(true);
    const pause = vi.spyOn(video, 'pause');
    const load = vi.spyOn(video, 'load');
    unmount();
    await tick();
    expect(pause).toHaveBeenCalledOnce();
    expect(load).toHaveBeenCalledOnce();
    expect(video.hasAttribute('src')).toBe(false);
    expect(observation.destroy).toHaveBeenCalledOnce();
  });

  it('retries one playback error then releases the slot, without an unbounded reload loop', async () => {
    vi.useFakeTimers();
    const { container } = render(VideoThumbnail, { url: '/motion.mp4', visibleAutoplay: true });
    await tick();
    observation.change(true);
    await tick();
    const first = container.querySelector('video')!;
    await fireEvent.error(first);
    await vi.advanceTimersByTimeAsync(500);
    await tick();
    const second = container.querySelector('video')!;
    expect(second).not.toBe(first);
    await fireEvent.error(second);
    await tick();
    expect(observation.suspend).toHaveBeenCalledOnce();
    expect(container.querySelector('video')).toBeNull();
    await vi.advanceTimersByTimeAsync(5000);
    expect(container.querySelector('video')).toBeNull();
  });

  it('disabling visibility autoplay releases observer and preserves ordinary hover playback', async () => {
    const { container, rerender } = render(VideoThumbnail, { url: '/motion.mp4', visibleAutoplay: true });
    await tick();
    observation.change(true);
    await tick();
    await rerender({ url: '/motion.mp4', visibleAutoplay: false, enablePlayback: false });
    await waitFor(() => expect(container.querySelector('video')).toBeNull());
    expect(observation.destroy).toHaveBeenCalledOnce();
    await rerender({ url: '/motion.mp4', visibleAutoplay: false, enablePlayback: true });
    await waitFor(() => expect(container.querySelector('video')).not.toBeNull());
  });
});
