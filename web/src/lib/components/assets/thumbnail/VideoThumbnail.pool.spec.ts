import { cleanup, fireEvent, render } from '@testing-library/svelte';
import { tick, type ComponentProps } from 'svelte';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { LIVE_PHOTO_SETTLING_DELAY, setLivePhotoFeedActive } from '$lib/utils/live-photo-autoplay';
import VideoThumbnail from './VideoThumbnail.svelte';

class PlaybackObserver {
  static instances: PlaybackObserver[] = [];
  targets = new Set<Element>();
  disconnect = vi.fn(() => this.targets.clear());

  constructor(private readonly callback: IntersectionObserverCallback) {
    PlaybackObserver.instances.push(this);
  }

  observe(target: Element) {
    this.targets.add(target);
  }

  notify(target: Element, ratio = 1) {
    this.callback(
      [{ target, isIntersecting: ratio > 0, intersectionRatio: ratio } as IntersectionObserverEntry],
      this as unknown as IntersectionObserver,
    );
  }
}

let documentHidden = false;
beforeEach(() => {
  vi.useFakeTimers();
  documentHidden = false;
  vi.spyOn(document, 'hidden', 'get').mockImplementation(() => documentHidden);
  vi.stubGlobal('IntersectionObserver', PlaybackObserver);
  PlaybackObserver.instances = [];
  (document.scrollingElement ?? document.documentElement).scrollTop = 0;
  setLivePhotoFeedActive(false);
  setLivePhotoFeedActive(true);
});
afterEach(() => {
  cleanup();
  setLivePhotoFeedActive(false);
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

const rectangle = (offset = 0) =>
  new DOMRect(window.innerWidth / 2 - 50, window.innerHeight / 2 - 50 + offset, 100, 100);

const mount = (url: string, offset = 0, props: Partial<ComponentProps<typeof VideoThumbnail>> = {}) => {
  const mounted = render(VideoThumbnail, { url, isLivePhoto: true, visibleAutoplay: true, ...props });
  const element = mounted.container.firstElementChild as HTMLElement;
  let bounds = rectangle(offset);
  vi.spyOn(element, 'getBoundingClientRect').mockImplementation(() => bounds);
  return {
    ...mounted,
    element,
    place: (offset: number) => {
      bounds = rectangle(offset);
    },
  };
};

const visible = (element: HTMLElement, ratio = 1) => {
  const observer = PlaybackObserver.instances.find((observer) => observer.targets.has(element));
  expect(observer).toBeDefined();
  observer!.notify(element, ratio);
};
const settle = async (delay = LIVE_PHOTO_SETTLING_DELAY) => {
  await vi.advanceTimersByTimeAsync(delay);
  await tick();
};
const videos = () => [...document.querySelectorAll<HTMLVideoElement>('video[src]')];

describe('VideoThumbnail with the real shared playback pool', () => {
  it('ten visible Live Photos allocate one source for the central photo regardless of registration order', async () => {
    const mounted = Array.from({ length: 10 }, (_, index) =>
      mount(`/motion-${index}.mp4`, index === 9 ? 0 : 20 * (index + 1)),
    );
    await tick();
    for (const item of mounted) {
      visible(item.element);
    }
    expect(videos()).toHaveLength(0);
    await settle(LIVE_PHOTO_SETTLING_DELAY - 1);
    expect(videos()).toHaveLength(0);
    await settle(1);
    expect(videos()).toHaveLength(1);
    expect(videos()[0].getAttribute('src')).toBe('/motion-9.mp4');
    expect(videos()[0].loop).toBe(false);
    await fireEvent.ended(videos()[0]);
    for (const item of mounted) {
      visible(item.element);
    }
    await settle(5000);
    expect(videos()).toHaveLength(0);
  });

  it('scrolling releases the current source immediately, then selects a newly centered photo after settling', async () => {
    const first = mount('/first.mp4');
    const next = mount('/next.mp4', 100);
    await tick();
    visible(first.element);
    visible(next.element);
    await settle();
    const oldVideo = videos()[0];
    const pause = vi.spyOn(oldVideo, 'pause');
    const load = vi.spyOn(oldVideo, 'load');
    first.place(-100);
    next.place(0);
    (document.scrollingElement ?? document.documentElement).scrollTop = 100;
    document.dispatchEvent(new Event('scroll'));
    expect(oldVideo.hasAttribute('src')).toBe(false);
    expect(pause).toHaveBeenCalledOnce();
    expect(load).toHaveBeenCalledOnce();
    await tick();
    expect(videos()).toHaveLength(0);
    await settle(LIVE_PHOTO_SETTLING_DELAY - 1);
    expect(videos()).toHaveLength(0);
    await settle(1);
    expect(videos()).toHaveLength(1);
    expect(videos()[0].getAttribute('src')).toBe('/next.mp4');
  });

  it('tab changes release resources and one settled activation never duplicates the decoder', async () => {
    const first = mount('/tab.mp4');
    await tick();
    visible(first.element);
    await settle();
    const oldVideo = videos()[0];
    documentHidden = true;
    document.dispatchEvent(new Event('visibilitychange'));
    expect(oldVideo.hasAttribute('src')).toBe(false);
    await settle(5000);
    expect(videos()).toHaveLength(0);
    documentHidden = false;
    document.dispatchEvent(new Event('visibilitychange'));
    await settle(LIVE_PHOTO_SETTLING_DELAY - 1);
    expect(videos()).toHaveLength(0);
    await settle(1);
    expect(videos()).toHaveLength(1);
    const resumedVideo = videos()[0];
    expect(resumedVideo).not.toBe(oldVideo);
    document.dispatchEvent(new Event('visibilitychange'));
    await settle(1000);
    expect(videos()).toEqual([resumedVideo]);
    expect(PlaybackObserver.instances).toHaveLength(1);
  });

  it('unmounting the selected component frees its source and observer without starting a neighbor', async () => {
    const first = mount('/disposed.mp4');
    const neighbor = mount('/neighbor.mp4', 100);
    await tick();
    visible(first.element);
    visible(neighbor.element);
    await settle();
    const oldVideo = videos()[0];
    const pause = vi.spyOn(oldVideo, 'pause');
    const load = vi.spyOn(oldVideo, 'load');
    const observer = PlaybackObserver.instances.find((observer) => observer.targets.has(first.element))!;
    first.unmount();
    expect(oldVideo.hasAttribute('src')).toBe(false);
    expect(pause).toHaveBeenCalledOnce();
    expect(load).toHaveBeenCalledOnce();
    expect(observer.disconnect).toHaveBeenCalledOnce();
    await settle(5000);
    expect(videos()).toHaveLength(0);
  });

  it('ordinary video hover preempts a Live Photo through the same budget and leaves no two attached sources', async () => {
    const photo = mount('/photo.mp4');
    await tick();
    visible(photo.element);
    await settle();
    const photoVideo = videos()[0];
    const hover = mount('/ordinary.mp4', 50, { isLivePhoto: false, visibleAutoplay: false, enablePlayback: true });
    await tick();
    visible(hover.element);
    expect(photoVideo.hasAttribute('src')).toBe(false);
    await tick();
    expect(videos()).toHaveLength(1);
    const ordinaryVideo = videos()[0];
    expect(ordinaryVideo.getAttribute('src')).toBe('/ordinary.mp4');
    expect(ordinaryVideo.loop).toBe(true);
    hover.unmount();
    expect(ordinaryVideo.hasAttribute('src')).toBe(false);
    await settle(5000);
    expect(videos()).toHaveLength(0);
  });

  it('hovering the current Live Photo changes its priority without reloading and natural completion stays final', async () => {
    const photo = mount('/same.mp4');
    await tick();
    visible(photo.element);
    await settle();
    const video = videos()[0];
    const load = vi.spyOn(video, 'load');
    await photo.rerender({ url: '/same.mp4', isLivePhoto: true, visibleAutoplay: true, enablePlayback: true });
    expect(videos()).toEqual([video]);
    expect(load).not.toHaveBeenCalled();
    expect(PlaybackObserver.instances).toHaveLength(1);
    await fireEvent.ended(video);
    visible(photo.element);
    await settle(5000);
    expect(videos()).toHaveLength(0);
    await photo.rerender({ url: '/same.mp4', isLivePhoto: true, visibleAutoplay: true, enablePlayback: false });
    await photo.rerender({ url: '/same.mp4', isLivePhoto: true, visibleAutoplay: true, enablePlayback: true });
    await tick();
    expect(videos()).toHaveLength(1);
    expect(videos()[0].loop).toBe(false);
  });

  it('a retained component releases its old route source and registers fresh geometry for the next route', async () => {
    const photo = mount('/retained.mp4', 0, { playbackContext: '/first' });
    await tick();
    visible(photo.element);
    await settle();
    const oldVideo = videos()[0];
    const oldObserver = PlaybackObserver.instances[0];
    await photo.rerender({
      url: '/retained.mp4',
      isLivePhoto: true,
      visibleAutoplay: true,
      playbackContext: '/second',
    });
    expect(oldVideo.hasAttribute('src')).toBe(false);
    expect(oldObserver.disconnect).toHaveBeenCalledOnce();
    expect(videos()).toHaveLength(0);
    oldObserver.notify(photo.element);
    expect(videos()).toHaveLength(0);
    visible(photo.element);
    await settle(LIVE_PHOTO_SETTLING_DELAY - 1);
    expect(videos()).toHaveLength(0);
    await settle(1);
    expect(videos()).toHaveLength(1);
    expect(videos()[0]).not.toBe(oldVideo);
    expect(videos()[0].getAttribute('src')).toBe('/retained.mp4');
  });
});
