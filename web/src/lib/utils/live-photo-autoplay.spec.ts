import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  LIVE_PHOTO_SETTLING_DELAY,
  LivePhotoPlaybackPool,
  observeLivePhotoPlayback,
  setLivePhotoFeedActive,
} from './live-photo-autoplay';

const geometry = (distanceFromCenter = 0, visibleFraction = 1, top = distanceFromCenter, left = 0) => ({
  visibleFraction,
  distanceFromCenter,
  top,
  left,
});

describe('one settled Live Photo playback lease', () => {
  let pool: LivePhotoPlaybackPool;
  beforeEach(() => {
    vi.useFakeTimers();
    pool = new LivePhotoPlaybackPool();
  });
  afterEach(() => {
    pool.destroy();
    vi.restoreAllMocks();
    vi.useRealTimers();
  });

  const settle = () => vi.advanceTimersByTime(LIVE_PHOTO_SETTLING_DELAY);

  it('selects one of ten visible photos by center after settling, independent of registration order', () => {
    const active = new Set<number>();
    const maximum: number[] = [];
    const changes = Array.from({ length: 10 }, (_, index) =>
      vi.fn((value: boolean) => {
        if (value) {
          active.add(index);
        } else {
          active.delete(index);
        }
        maximum.push(active.size);
      }),
    );
    for (const index of [8, 1, 9, 3, 6, 0, 7, 5, 2, 4]) {
      pool.register(changes[index], { key: `photo-${index}` }).visible(true, geometry(Math.abs(index - 4)));
    }
    expect(active.size).toBe(0);
    vi.advanceTimersByTime(LIVE_PHOTO_SETTLING_DELAY - 1);
    expect(active.size).toBe(0);
    vi.advanceTimersByTime(1);
    expect([...active]).toEqual([4]);
    expect(Math.max(...maximum)).toBe(1);
    vi.advanceTimersByTime(10_000);
    expect([...active]).toEqual([4]);
  });

  it('prefers visibility before distance and requires 80 percent visibility', () => {
    const partial = vi.fn();
    const centered = vi.fn();
    const visible = vi.fn();
    pool.register(partial, { key: 'partial' }).visible(true, geometry(0, 0.79));
    pool.register(centered, { key: 'centered' }).visible(true, geometry(1, 0.8));
    pool.register(visible, { key: 'visible' }).visible(true, geometry(100, 0.95));
    settle();
    expect(visible).toHaveBeenCalledExactlyOnceWith(true);
    expect(centered).not.toHaveBeenCalled();
    expect(partial).not.toHaveBeenCalled();
  });

  it('uses geometry then stable identity for ties, never registration order', () => {
    const later = vi.fn();
    const earlier = vi.fn();
    pool.register(later, { key: 'z' }).visible(true, geometry());
    pool.register(earlier, { key: 'a' }).visible(true, geometry());
    settle();
    expect(earlier).toHaveBeenCalledExactlyOnceWith(true);
    expect(later).not.toHaveBeenCalled();
  });

  it('keeps indistinguishable duplicate registrations static', () => {
    const changes = [vi.fn(), vi.fn()];
    for (const change of changes) {
      pool.register(change, { key: 'same-video' }).visible(true, geometry());
    }
    settle();
    expect(changes[0]).not.toHaveBeenCalled();
    expect(changes[1]).not.toHaveBeenCalled();
  });

  it('completion releases its source without cascading, even after more visibility callbacks', () => {
    const first = vi.fn();
    const next = vi.fn();
    const firstLease = pool.register(first, { key: 'first' });
    firstLease.visible(true, geometry());
    pool.register(next, { key: 'next' }).visible(true, geometry(1));
    settle();
    firstLease.complete();
    firstLease.visible(true, geometry());
    vi.advanceTimersByTime(10_000);
    expect(first.mock.calls).toEqual([[true], [false]]);
    expect(next).not.toHaveBeenCalled();
  });

  it('a new moved viewport ranks the completed central photo again instead of cascading to a weaker candidate', () => {
    const center = vi.fn();
    const edge = vi.fn();
    const lease = pool.register(center, { key: 'center' });
    lease.visible(true, geometry());
    pool.register(edge, { key: 'edge' }).visible(true, geometry(100));
    settle();
    lease.complete();
    pool.scroll();
    settle();
    expect(center.mock.calls).toEqual([[true], [false], [true]]);
    expect(edge).not.toHaveBeenCalled();
  });

  it('failure and selected disposal consume the viewport rather than loading another candidate', () => {
    const first = vi.fn();
    const next = vi.fn();
    const firstLease = pool.register(first, { key: 'first' });
    firstLease.visible(true, geometry());
    const nextLease = pool.register(next, { key: 'next' });
    nextLease.visible(true, geometry(1));
    settle();
    firstLease.suspend();
    firstLease.destroy();
    nextLease.visible(true, geometry());
    settle();
    expect(first.mock.calls).toEqual([[true], [false]]);
    expect(next).not.toHaveBeenCalled();
  });

  it('destroying and re-registering every component in the same viewport cannot reload video', () => {
    const change = vi.fn();
    const first = pool.register(change, { key: 'same-video' });
    first.visible(true, geometry());
    settle();
    first.destroy();
    const replacement = pool.register(change, { key: 'same-video' });
    replacement.visible(true, geometry());
    settle();
    expect(change.mock.calls).toEqual([[true], [false]]);
    replacement.destroy();
    replacement.destroy();
    replacement.visible(true, geometry());
    expect(change.mock.calls).toEqual([[true], [false]]);
  });

  it('settles on the next virtualized viewport when scrolling unmounts every old tile', () => {
    const first = vi.fn();
    const next = vi.fn();
    const lease = pool.register(first, { key: 'old-viewport' });
    lease.visible(true, geometry());
    settle();
    pool.scroll(true);
    lease.destroy();
    pool.register(next, { key: 'new-viewport' }).visible(true, geometry());
    vi.advanceTimersByTime(LIVE_PHOTO_SETTLING_DELAY - 1);
    expect(first.mock.calls).toEqual([[true], [false]]);
    expect(next).not.toHaveBeenCalled();
    vi.advanceTimersByTime(1);
    expect(next).toHaveBeenCalledExactlyOnceWith(true);
  });

  it('scroll intent without movement cannot replay video after every tile remounts', () => {
    const first = vi.fn();
    const next = vi.fn();
    const lease = pool.register(first, { key: 'same-viewport' });
    lease.visible(true, geometry());
    settle();
    pool.scroll(false);
    lease.destroy();
    pool.register(next, { key: 'same-viewport' }).visible(true, geometry());
    settle();
    expect(first.mock.calls).toEqual([[true], [false]]);
    expect(next).not.toHaveBeenCalled();
  });

  it('revokes immediately on scroll and remeasures center even when every IO ratio remains one', () => {
    let firstDistance = 0;
    let secondDistance = 10;
    const first = vi.fn();
    const second = vi.fn();
    pool.register(first, { key: 'first', measure: () => geometry(firstDistance) }).visible(true);
    const secondLease = pool.register(second, { key: 'second', measure: () => geometry(secondDistance) });
    secondLease.visible(true);
    settle();
    pool.scroll();
    expect(first.mock.calls).toEqual([[true], [false]]);
    firstDistance = 10;
    secondDistance = 0;
    // IO updates during the scroll must not cancel the settling timer.
    secondLease.visible(true);
    vi.advanceTimersByTime(LIVE_PHOTO_SETTLING_DELAY - 1);
    expect(second).not.toHaveBeenCalled();
    vi.advanceTimersByTime(1);
    expect(second).toHaveBeenCalledExactlyOnceWith(true);
  });

  it('continual scroll activity postpones playback until 350 ms after the last event', () => {
    const change = vi.fn();
    pool.register(change, { key: 'photo' }).visible(true, geometry());
    pool.scroll();
    vi.advanceTimersByTime(300);
    pool.scroll();
    vi.advanceTimersByTime(300);
    expect(change).not.toHaveBeenCalled();
    vi.advanceTimersByTime(50);
    expect(change).toHaveBeenCalledExactlyOnceWith(true);
  });

  it('a wheel/scroll notification without movement cannot rearm a consumed viewport', () => {
    const change = vi.fn();
    pool.register(change, { key: 'photo' }).visible(true, geometry());
    settle();
    pool.scroll(false);
    settle();
    expect(change.mock.calls).toEqual([[true], [false]]);
  });

  it('losing visibility immediately stops the selected photo without a cascade', () => {
    const first = vi.fn();
    const next = vi.fn();
    const lease = pool.register(first, { key: 'first' });
    lease.visible(true, geometry());
    pool.register(next, { key: 'next' }).visible(true, geometry(1));
    settle();
    lease.visible(true, geometry(0, 0.79));
    expect(first.mock.calls).toEqual([[true], [false]]);
    settle();
    expect(next).not.toHaveBeenCalled();
  });

  it('a tab activation grants one fresh settled pass and repeated foreground notifications cannot duplicate it', () => {
    const change = vi.fn();
    pool.register(change, { key: 'photo' }).visible(true, geometry());
    settle();
    pool.setForeground(false);
    expect(change.mock.calls).toEqual([[true], [false]]);
    pool.setForeground(true);
    vi.advanceTimersByTime(LIVE_PHOTO_SETTLING_DELAY - 1);
    expect(change).toHaveBeenCalledTimes(2);
    vi.advanceTimersByTime(1);
    pool.setForeground(true);
    settle();
    expect(change.mock.calls).toEqual([[true], [false], [true]]);
  });

  it('viewer context pauses every mode, then grants a single pass after real feed reactivation', () => {
    const change = vi.fn();
    pool.register(change, { key: 'photo' }).visible(true, geometry());
    settle();
    pool.setFeedActive(false);
    expect(change.mock.calls).toEqual([[true], [false]]);
    pool.setFeedActive(true);
    settle();
    expect(change.mock.calls).toEqual([[true], [false], [true]]);
    pool.setFeedActive(true);
    settle();
    expect(change).toHaveBeenCalledTimes(3);
  });

  it('same route does not replay; a real route change opens a new settled context', () => {
    const change = vi.fn();
    pool.setContext('/photos');
    const lease = pool.register(change, { key: 'photo' });
    lease.visible(true, geometry());
    settle();
    lease.complete();
    pool.setContext('/photos');
    settle();
    expect(change).toHaveBeenCalledTimes(2);
    pool.setContext('/albums/example');
    settle();
    expect(change.mock.calls).toEqual([[true], [false]]);
    const currentRoute = pool.register(change, { key: 'photo' });
    currentRoute.visible(true, geometry());
    settle();
    expect(change.mock.calls).toEqual([[true], [false], [true]]);
  });

  it('an outgoing route cannot regain playback during a slow route transition', () => {
    const outgoing = vi.fn();
    const incoming = vi.fn();
    pool.setContext('/photos');
    const oldLease = pool.register(outgoing, { key: 'outgoing' });
    oldLease.visible(true, geometry());
    settle();
    pool.setContext('/albums/new');
    oldLease.visible(true, geometry());
    settle();
    expect(outgoing.mock.calls).toEqual([[true], [false]]);
    const nextLease = pool.register(incoming, { key: 'incoming' });
    nextLease.visible(true, geometry(100));
    // Stale observer callbacks keep the old route's more-central tile visible.
    oldLease.visible(true, geometry());
    settle();
    expect(incoming).toHaveBeenCalledExactlyOnceWith(true);
    expect(outgoing.mock.calls).toEqual([[true], [false]]);
    oldLease.destroy();
    oldLease.complete();
    expect(incoming).toHaveBeenCalledExactlyOnceWith(true);
  });

  it('ordinary hover uses the same slot and old source revocation precedes the new grant', () => {
    const events: string[] = [];
    pool
      .register(
        (active) => {
          events.push(`live:${active}`);
        },
        { key: 'live' },
      )
      .visible(true, geometry());
    settle();
    const hover = pool.register(
      (active) => {
        events.push(`hover:${active}`);
      },
      { key: 'hover', mode: 'hover' },
    );
    hover.visible(true, geometry(10));
    expect(events).toEqual(['live:true', 'live:false', 'hover:true']);
    hover.destroy();
    settle();
    expect(events).toEqual(['live:true', 'live:false', 'hover:true', 'hover:false']);
  });

  it('hovering an already active automatic Live Photo preserves its source and one-shot completion', () => {
    const change = vi.fn();
    const lease = pool.register(change, { key: 'live' });
    lease.visible(true, geometry());
    settle();
    lease.setMode('hover');
    lease.setMode('automatic');
    expect(change).toHaveBeenCalledExactlyOnceWith(true);
    lease.complete();
    lease.visible(true, geometry());
    settle();
    expect(change.mock.calls).toEqual([[true], [false]]);
  });

  it('a hover-started Live Photo stops on leave and cannot cascade into automatic playback', () => {
    const change = vi.fn();
    const lease = pool.register(change, { key: 'live', mode: 'hover' });
    lease.visible(true, geometry());
    lease.setMode('automatic');
    settle();
    expect(change.mock.calls).toEqual([[true], [false]]);
    lease.setMode('hover');
    expect(change.mock.calls).toEqual([[true], [false], [true]]);
    lease.complete();
    lease.visible(true, geometry());
    expect(change).toHaveBeenCalledTimes(4);
  });

  it('stale handles cannot stop or recreate a newer selection', () => {
    const first = vi.fn();
    const second = vi.fn();
    const old = pool.register(first, { key: 'old' });
    old.visible(true, geometry());
    settle();
    old.destroy();
    pool.register(second, { key: 'new' }).visible(true, geometry());
    pool.scroll();
    settle();
    old.complete();
    old.suspend();
    old.visible(true);
    expect(second).toHaveBeenCalledExactlyOnceWith(true);
  });
});

describe('browser viewport and resource lifecycle', () => {
  let callbacks: IntersectionObserverCallback[];
  let disconnects: ReturnType<typeof vi.fn>[];
  let handles: ReturnType<typeof observeLivePhotoPlayback>[];
  let rectangles: Map<HTMLElement, DOMRect>;

  beforeEach(() => {
    vi.useFakeTimers();
    callbacks = [];
    disconnects = [];
    handles = [];
    rectangles = new Map();
    vi.spyOn(document, 'hidden', 'get').mockReturnValue(false);
    vi.stubGlobal(
      'IntersectionObserver',
      class {
        constructor(callback: IntersectionObserverCallback) {
          callbacks.push(callback);
          disconnects.push(this.disconnect);
        }
        observe() {}
        disconnect = vi.fn();
      },
    );
    setLivePhotoFeedActive(false);
    setLivePhotoFeedActive(true);
  });

  afterEach(() => {
    for (const handle of handles) {
      handle.destroy();
    }
    document.body.replaceChildren();
    document.body.style.removeProperty('height');
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  const rectangle = (offset = 0) =>
    new DOMRect(window.innerWidth / 2 - 50, window.innerHeight / 2 - 50 + offset, 100, 100);
  const observe = (key: string, offset = 0, parent = document.body, mode: 'automatic' | 'hover' = 'automatic') => {
    const element = document.createElement('div');
    rectangles.set(element, rectangle(offset));
    vi.spyOn(element, 'getBoundingClientRect').mockImplementation(() => rectangles.get(element)!);
    parent.append(element);
    const change = vi.fn();
    const handle = observeLivePhotoPlayback(element, change, { key, mode });
    handles.push(handle);
    return { element, change, handle, index: callbacks.length - 1 };
  };
  const visible = (index: number, ratio = 1) =>
    callbacks[index](
      [{ isIntersecting: ratio > 0, intersectionRatio: ratio } as IntersectionObserverEntry],
      {} as IntersectionObserver,
    );
  const settle = () => vi.advanceTimersByTime(LIVE_PHOTO_SETTLING_DELAY);

  it('uses one ref-counted document subscription and cleans every observer, timer and listener', () => {
    const add = vi.spyOn(document, 'addEventListener');
    const remove = vi.spyOn(document, 'removeEventListener');
    const first = observe('first');
    const second = observe('second', 10);
    visible(first.index);
    visible(second.index);
    expect(add.mock.calls.filter(([name]) => name === 'scroll')).toHaveLength(1);
    first.handle.destroy();
    expect(remove.mock.calls.filter(([name]) => name === 'scroll')).toHaveLength(0);
    second.handle.destroy();
    expect(remove.mock.calls.filter(([name]) => name === 'scroll')).toHaveLength(1);
    expect(disconnects.every((disconnect) => disconnect.mock.calls.length === 1)).toBe(true);
    expect(vi.getTimerCount()).toBe(0);
  });

  it('suspends synchronously for nested scrolling and remeasures candidates whose IO ratio stayed one', () => {
    const scroller = document.createElement('div');
    document.body.append(scroller);
    const first = observe('first', 0, scroller);
    const second = observe('second', 100, scroller);
    visible(first.index);
    visible(second.index);
    settle();
    scroller.scrollTop = 100;
    scroller.dispatchEvent(new Event('scroll'));
    expect(first.change.mock.calls).toEqual([[true], [false]]);
    rectangles.set(first.element, rectangle(-100));
    rectangles.set(second.element, rectangle());
    settle();
    expect(second.change).toHaveBeenCalledExactlyOnceWith(true);
  });

  it('a stale hover cannot preempt the new center after scrolling under a stationary pointer', () => {
    const scroller = document.createElement('div');
    document.body.append(scroller);
    const oldHover = observe('old-hover', 0, scroller, 'hover');
    const center = observe('new-center', 150, scroller);
    oldHover.element.dispatchEvent(
      new PointerEvent('pointermove', {
        bubbles: true,
        pointerType: 'mouse',
        clientX: window.innerWidth / 2,
        clientY: window.innerHeight / 2,
      }),
    );
    visible(oldHover.index);
    visible(center.index);
    settle();
    expect(oldHover.change).toHaveBeenCalledExactlyOnceWith(true);
    scroller.scrollTop = 150;
    scroller.dispatchEvent(new Event('scroll'));
    rectangles.set(oldHover.element, rectangle(-150));
    rectangles.set(center.element, rectangle());
    settle();
    expect(oldHover.change.mock.calls).toEqual([[true], [false]]);
    expect(center.change).toHaveBeenCalledExactlyOnceWith(true);
  });

  it('wheel and scroll without actual displacement never restart an already consumed source', () => {
    const item = observe('still');
    visible(item.index);
    settle();
    document.dispatchEvent(new Event('wheel'));
    document.dispatchEvent(new Event('scroll'));
    settle();
    expect(item.change.mock.calls).toEqual([[true], [false]]);
  });

  it('ignores document-only resize and reselects once after a height-only viewport change', () => {
    const first = observe('first');
    const second = observe('second', 200);
    visible(first.index);
    visible(second.index);
    settle();
    expect(first.change).toHaveBeenCalledExactlyOnceWith(true);

    document.body.style.height = '2000px';
    dispatchEvent(new Event('resize'));
    settle();
    expect(first.change).toHaveBeenCalledExactlyOnceWith(true);
    expect(second.change).not.toHaveBeenCalled();

    vi.stubGlobal('innerHeight', innerHeight + 400);
    dispatchEvent(new Event('resize'));
    expect(first.change).toHaveBeenLastCalledWith(false);
    vi.advanceTimersByTime(LIVE_PHOTO_SETTLING_DELAY - 1);
    expect(second.change).not.toHaveBeenCalled();
    vi.advanceTimersByTime(1);
    expect(second.change).toHaveBeenCalledExactlyOnceWith(true);
  });

  it('hides immediately on tab/page suspension and resumes only one source without duplicate subscriptions', () => {
    const item = observe('tab');
    visible(item.index);
    settle();
    const hidden = vi.spyOn(document, 'hidden', 'get');
    hidden.mockReturnValue(true);
    document.dispatchEvent(new Event('visibilitychange'));
    expect(item.change.mock.calls).toEqual([[true], [false]]);
    hidden.mockReturnValue(false);
    document.dispatchEvent(new Event('visibilitychange'));
    settle();
    expect(item.change.mock.calls).toEqual([[true], [false], [true]]);
    dispatchEvent(new Event('pagehide'));
    expect(item.change).toHaveBeenLastCalledWith(false);
    dispatchEvent(new Event('pageshow'));
    settle();
    expect(item.change.mock.calls).toEqual([[true], [false], [true], [false], [true]]);
  });

  it('keeps touch scrolling suspended until the pointer is released and settling completes', () => {
    const item = observe('touch');
    visible(item.index);
    document.dispatchEvent(new PointerEvent('pointerdown', { pointerType: 'touch', pointerId: 7 }));
    vi.advanceTimersByTime(1000);
    expect(item.change).not.toHaveBeenCalled();
    document.dispatchEvent(new PointerEvent('pointerup', { pointerType: 'touch', pointerId: 7 }));
    settle();
    expect(item.change).toHaveBeenCalledExactlyOnceWith(true);
  });

  it('uses the shared 80 percent observer boundary and rejects insufficiently visible media', () => {
    const item = observe('boundary');
    visible(item.index, 0.79);
    settle();
    expect(item.change).not.toHaveBeenCalled();
    visible(item.index, 0.8);
    settle();
    expect(item.change).toHaveBeenCalledExactlyOnceWith(true);
  });
});
