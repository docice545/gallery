// Feed animations share a small decoder budget; ordinary video hover playback is unchanged.
export class LivePhotoPlaybackPool {
  private entries = new Map<symbol, { visible: boolean; active: boolean; change: (active: boolean) => void }>();
  private foreground = true;

  constructor(private readonly limit = 3) {}

  register(change: (active: boolean) => void) {
    const key = Symbol();
    this.entries.set(key, { visible: false, active: false, change });
    return {
      visible: (visible: boolean) => {
        const entry = this.entries.get(key);
        if (entry) {
          entry.visible = visible;
          this.refresh();
        }
      },
      destroy: () => {
        const entry = this.entries.get(key);
        this.entries.delete(key);
        if (entry?.active) {
          entry.change(false);
        }
        this.refresh();
      },
    };
  }

  setForeground(foreground: boolean) {
    this.foreground = foreground;
    this.refresh();
  }

  private refresh() {
    let count = 0;
    for (const entry of this.entries.values()) {
      const active = this.foreground && entry.visible && count++ < this.limit;
      if (entry.active !== active) {
        entry.active = active;
        entry.change(active);
      }
    }
  }
}

const pool = new LivePhotoPlaybackPool();

export const observeLivePhotoPlayback = (element: HTMLElement, change: (active: boolean) => void) => {
  const lease = pool.register(change);
  let visible = false;
  let failed = false;
  let wasHidden = document.hidden;
  const observer = new IntersectionObserver(
    ([entry]) => {
      visible = entry.isIntersecting && entry.intersectionRatio >= 0.5;
      if (!visible) {
        failed = false;
      }
      lease.visible(visible && !failed);
    },
    { threshold: [0, 0.5] },
  );
  const foreground = () => {
    if (wasHidden && !document.hidden) {
      failed = false;
      lease.visible(visible);
    }
    wasHidden = document.hidden;
    pool.setForeground(!document.hidden);
  };
  foreground();
  document.addEventListener('visibilitychange', foreground);
  observer.observe(element);
  return {
    suspend: () => {
      failed = true;
      lease.visible(false);
    },
    destroy: () => {
      observer.disconnect();
      document.removeEventListener('visibilitychange', foreground);
      lease.destroy();
    },
  };
};
