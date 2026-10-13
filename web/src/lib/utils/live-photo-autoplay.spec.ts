import { describe, expect, it, vi } from 'vitest';
import { LivePhotoPlaybackPool, observeLivePhotoPlayback } from './live-photo-autoplay';

describe('Live Photo decoder budget', () => {
  it('grants a cold visible feed without viewer warmup', () => {
    const pool = new LivePhotoPlaybackPool();
    const change = vi.fn();
    const lease = pool.register(change);
    lease.visible(true);
    expect(change).toHaveBeenLastCalledWith(true);
  });

  it('limits decoders and grants the next visible item after scroll/disposal', () => {
    const pool = new LivePhotoPlaybackPool(2);
    const changes = Array.from({ length: 4 }, () => vi.fn());
    const leases = changes.map((change) => pool.register(change));
    for (const lease of leases) {
      lease.visible(true);
    }
    expect(changes[0]).toHaveBeenLastCalledWith(true);
    expect(changes[1]).toHaveBeenLastCalledWith(true);
    expect(changes[2]).not.toHaveBeenCalled();
    leases[0].visible(false);
    expect(changes[0]).toHaveBeenLastCalledWith(false);
    expect(changes[2]).toHaveBeenLastCalledWith(true);
    leases[1].destroy();
    expect(changes[3]).toHaveBeenLastCalledWith(true);
  });

  it('pauses in background and resumes only visible entries', () => {
    const pool = new LivePhotoPlaybackPool();
    const change = vi.fn();
    const lease = pool.register(change);
    lease.visible(true);
    pool.setForeground(false);
    expect(change).toHaveBeenLastCalledWith(false);
    lease.visible(false);
    pool.setForeground(true);
    expect(change).toHaveBeenLastCalledWith(false);
    lease.visible(true);
    expect(change).toHaveBeenLastCalledWith(true);
  });

  it('disposal is idempotent and cannot recreate a removed decoder', () => {
    const pool = new LivePhotoPlaybackPool();
    const change = vi.fn();
    const lease = pool.register(change);
    lease.visible(true);
    lease.destroy();
    lease.destroy();
    lease.visible(true);
    expect(change.mock.calls).toEqual([[true], [false]]);
  });
});

describe('Live Photo visibility lifecycle', () => {
  it('requires half visibility, releases on failure, retries after leaving and disconnects', () => {
    let intersect: IntersectionObserverCallback = () => {};
    const disconnect = vi.fn();
    vi.stubGlobal(
      'IntersectionObserver',
      class {
        constructor(callback: IntersectionObserverCallback) {
          intersect = callback;
        }
        observe() {}
        disconnect = disconnect;
      },
    );
    const change = vi.fn();
    const observer = observeLivePhotoPlayback(document.createElement('div'), change);
    const visible = (ratio: number) =>
      intersect(
        [{ isIntersecting: ratio > 0, intersectionRatio: ratio } as IntersectionObserverEntry],
        {} as IntersectionObserver,
      );
    visible(0.1);
    expect(change).not.toHaveBeenCalled();
    visible(1);
    expect(change).toHaveBeenLastCalledWith(true);
    observer.suspend();
    expect(change).toHaveBeenLastCalledWith(false);
    visible(1);
    expect(change).toHaveBeenLastCalledWith(false);
    visible(0);
    visible(1);
    expect(change).toHaveBeenLastCalledWith(true);
    observer.suspend();
    const hidden = vi.spyOn(document, 'hidden', 'get');
    hidden.mockReturnValue(true);
    document.dispatchEvent(new Event('visibilitychange'));
    hidden.mockReturnValue(false);
    document.dispatchEvent(new Event('visibilitychange'));
    expect(change).toHaveBeenLastCalledWith(true);
    hidden.mockRestore();
    observer.destroy();
    expect(change).toHaveBeenLastCalledWith(false);
    expect(disconnect).toHaveBeenCalledOnce();
    vi.unstubAllGlobals();
  });
});
