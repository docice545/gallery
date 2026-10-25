export const LIVE_PHOTO_SETTLING_DELAY = 350;
export const LIVE_PHOTO_VISIBILITY_THRESHOLD = 0.8;

type PlaybackMode = 'automatic' | 'hover';
type Geometry = {
  visibleFraction: number;
  distanceFromCenter: number;
  top?: number;
  left?: number;
  pointerBounds?: { left: number; top: number; right: number; bottom: number };
};
type RegistrationOptions = {
  mode?: PlaybackMode;
  key?: string;
  context?: string;
  measure?: () => Geometry | undefined;
};
type PlaybackEntry = {
  token: symbol;
  key: string;
  context?: string;
  mode: PlaybackMode;
  grantedMode?: PlaybackMode;
  visible: boolean;
  suspended: boolean;
  geometry?: Geometry;
  measure?: () => Geometry | undefined;
  change: (active: boolean) => void;
};

/** One shared thumbnail decoder, with one automatic pass per settled viewport. */
export class LivePhotoPlaybackPool {
  private entries = new Map<symbol, PlaybackEntry>();
  private active?: PlaybackEntry;
  private foreground = true;
  private feedActive = true;
  private consumed = false;
  private scrolling = false;
  private moved = false;
  private context?: string;
  private timer?: ReturnType<typeof setTimeout>;
  private cleanup?: () => void;
  private scrollPositions = new WeakMap<EventTarget, { x: number; y: number }>();
  private pointers = new Set<number>();
  private pointer?: { x: number; y: number };
  private refreshing = false;
  private refreshAgain = false;

  register(change: (active: boolean) => void, options: RegistrationOptions = {}) {
    const token = Symbol();
    const entry: PlaybackEntry = {
      token,
      key: options.key ?? '',
      context: options.context ?? this.context,
      mode: options.mode ?? 'automatic',
      visible: false,
      suspended: false,
      measure: options.measure,
      change,
    };
    this.entries.set(token, entry);
    this.listen();
    return {
      visible: (visible: boolean, geometry?: Geometry) => {
        if (!this.entries.has(token)) {
          return;
        }
        entry.visible = visible;
        entry.geometry = geometry ?? { visibleFraction: visible ? 1 : 0, distanceFromCenter: 0 };
        if (!visible) {
          entry.suspended = false;
        }
        this.refresh();
      },
      setMode: (mode: PlaybackMode) => {
        if (!this.entries.has(token) || entry.mode === mode) {
          return;
        }
        entry.mode = mode;
        if (mode === 'hover') {
          entry.suspended = false;
        } else if (this.active === entry && entry.grantedMode === 'hover') {
          this.revoke();
        }
        this.refresh();
      },
      complete: () => {
        entry.suspended = true;
        this.finish(entry);
      },
      suspend: () => {
        entry.suspended = true;
        this.finish(entry);
      },
      destroy: () => {
        if (!this.entries.delete(token)) {
          return;
        }
        if (this.active === entry) {
          this.revoke();
        }
        this.refresh();
        if (this.entries.size === 0) {
          this.clearTimer();
          this.cleanup?.();
          this.cleanup = undefined;
          this.pointers.clear();
          this.pointer = undefined;
          // Virtualized scrolling can replace every tile before settling.
          // Carry that actual movement into the next registration's budget;
          // a same-viewport rerender must keep its consumed budget instead.
          if (this.moved) {
            this.consumed = false;
          }
          this.scrolling = false;
          this.moved = false;
        }
      },
    };
  }

  setContext(context: string) {
    const changed = this.context !== undefined && this.context !== context;
    this.context = context;
    if (changed) {
      this.rearm();
    }
  }

  setFeedActive(active: boolean) {
    if (this.feedActive === active) {
      return;
    }

    this.feedActive = active;
    if (active) {
      this.rearm();
    } else {
      this.refresh();
    }
  }

  setForeground(foreground: boolean) {
    if (this.foreground === foreground) {
      return;
    }
    this.foreground = foreground;
    if (foreground) {
      this.rearm();
    } else {
      this.pointers.clear();
      this.pointer = undefined;
      this.scrolling = false;
      this.moved = false;
      this.refresh();
    }
  }

  /** Stop synchronously; only actual movement opens a fresh automatic budget. */
  scroll(moved = true) {
    this.moved ||= moved;
    this.scrolling = true;
    this.clearTimer();
    this.revoke();
    if (this.pointers.size === 0) {
      this.timer = setTimeout(() => {
        this.timer = undefined;
        this.scrolling = false;
        if (this.moved) {
          this.consumed = false;
          for (const entry of this.entries.values()) {
            entry.suspended = false;
          }
        }
        this.moved = false;
        this.refresh(true);
      }, LIVE_PHOTO_SETTLING_DELAY);
    }
  }

  destroy() {
    this.clearTimer();
    this.revoke();
    this.entries.clear();
    this.cleanup?.();
    this.cleanup = undefined;
    this.pointers.clear();
    this.pointer = undefined;
  }

  trackScrollParents(element: HTMLElement) {
    for (let current: HTMLElement | null = element; current; current = current.parentElement) {
      this.rememberPosition(current);
    }
    this.rememberPosition(document.scrollingElement ?? document.documentElement);
  }

  private rememberPosition(target: EventTarget) {
    if (!this.scrollPositions.has(target) && target instanceof Element) {
      this.scrollPositions.set(target, { x: target.scrollLeft, y: target.scrollTop });
    }
  }

  private listen() {
    if (this.cleanup || typeof document === 'undefined') {
      return;
    }
    this.setForeground(!document.hidden);
    let width = window.innerWidth;
    let height = window.innerHeight;
    const scroll = (event: Event) => {
      const target =
        event.target instanceof Element ? event.target : (document.scrollingElement ?? document.documentElement);
      const previous = this.scrollPositions.get(target);
      const position = { x: target.scrollLeft, y: target.scrollTop };
      this.scrollPositions.set(target, position);
      this.scroll(!!previous && (previous.x !== position.x || previous.y !== position.y));
    };
    const wheel = () => this.scroll(false);
    const pointerMove = (event: PointerEvent) => {
      if (event.pointerType === 'mouse' || event.pointerType === 'pen') {
        this.pointer = { x: event.clientX, y: event.clientY };
      }
    };
    const pointerDown = (event: PointerEvent) => {
      if (!(event.pointerType === 'touch' || event.pointerType === 'pen')) {
        return;
      }

      this.pointers.add(event.pointerId);
      this.scroll(false);
    };
    const pointerUp = (event: PointerEvent) => {
      if (this.pointers.delete(event.pointerId)) {
        this.scroll(false);
      }
    };
    const resize = () => {
      if (width === window.innerWidth && height === window.innerHeight) {
        return;
      }

      width = window.innerWidth;
      height = window.innerHeight;
      this.scroll(true);
    };
    const visibility = () => this.setForeground(!document.hidden);
    const hide = () => this.setForeground(false);
    const show = () => this.setForeground(!document.hidden);
    document.addEventListener('scroll', scroll, { capture: true, passive: true });
    document.addEventListener('wheel', wheel, { capture: true, passive: true });
    document.addEventListener('pointermove', pointerMove, { capture: true, passive: true });
    document.addEventListener('pointerdown', pointerDown, { capture: true, passive: true });
    document.addEventListener('pointerup', pointerUp, { capture: true, passive: true });
    document.addEventListener('pointercancel', pointerUp, { capture: true, passive: true });
    document.addEventListener('visibilitychange', visibility);
    // Observe viewport dimensions, including height-only changes; document layout
    // can resize independently and ResizeObserver does not report the viewport.
    // eslint-disable-next-line unicorn/prefer-observer-apis
    window.addEventListener('resize', resize, { passive: true });
    window.addEventListener('pagehide', hide);
    window.addEventListener('pageshow', show);
    this.cleanup = () => {
      document.removeEventListener('scroll', scroll, true);
      document.removeEventListener('wheel', wheel, true);
      document.removeEventListener('pointermove', pointerMove, true);
      document.removeEventListener('pointerdown', pointerDown, true);
      document.removeEventListener('pointerup', pointerUp, true);
      document.removeEventListener('pointercancel', pointerUp, true);
      document.removeEventListener('visibilitychange', visibility);
      window.removeEventListener('resize', resize);
      window.removeEventListener('pagehide', hide);
      window.removeEventListener('pageshow', show);
    };
  }

  private rearm() {
    this.clearTimer();
    this.revoke();
    this.scrolling = false;
    this.moved = false;
    this.pointers.clear();
    this.pointer = undefined;
    this.consumed = false;
    for (const entry of this.entries.values()) {
      entry.suspended = false;
    }
    if (this.foreground && this.feedActive) {
      this.scroll(false);
    }
  }

  private clearTimer() {
    clearTimeout(this.timer);
    this.timer = undefined;
  }

  private finish(entry: PlaybackEntry) {
    if (this.active !== entry) {
      return;
    }

    this.consumed = true;
    this.clearTimer();
    this.revoke();
  }

  private revoke() {
    const entry = this.active;
    this.active = undefined;
    if (entry) {
      // The component synchronously pauses and clears src before this returns.
      entry.change(false);
    }
  }

  private geometry(entry: PlaybackEntry) {
    return entry.measure ? entry.measure() : entry.geometry;
  }

  private eligible(entry: PlaybackEntry, geometry = this.geometry(entry)) {
    const bounds = geometry?.pointerBounds;
    const pointer = this.pointer;
    const pointerInside =
      !bounds ||
      !pointer ||
      (pointer.x >= bounds.left && pointer.x < bounds.right && pointer.y >= bounds.top && pointer.y < bounds.bottom);
    return (
      (entry.mode !== 'hover' || pointerInside) &&
      this.entries.has(entry.token) &&
      entry.context === this.context &&
      entry.visible &&
      !entry.suspended &&
      geometry !== undefined &&
      Number.isFinite(geometry.visibleFraction) &&
      Number.isFinite(geometry.distanceFromCenter) &&
      geometry.distanceFromCenter >= 0 &&
      geometry.visibleFraction <= 1 &&
      geometry.visibleFraction >= (entry.mode === 'hover' ? Number.EPSILON : LIVE_PHOTO_VISIBILITY_THRESHOLD)
    );
  }

  private best(mode: PlaybackMode) {
    const candidates = [...this.entries.values()]
      .filter((entry) => entry.context === this.context && entry.mode === mode && entry.visible && !entry.suspended)
      .map((entry) => ({ entry, geometry: this.geometry(entry) }))
      .filter((candidate): candidate is { entry: PlaybackEntry; geometry: Geometry } =>
        this.eligible(candidate.entry, candidate.geometry),
      )
      .sort(
        (a, b) =>
          b.geometry.visibleFraction - a.geometry.visibleFraction ||
          a.geometry.distanceFromCenter - b.geometry.distanceFromCenter ||
          (a.geometry.top ?? 0) - (b.geometry.top ?? 0) ||
          (a.geometry.left ?? 0) - (b.geometry.left ?? 0) ||
          a.entry.key.localeCompare(b.entry.key),
      );
    // Indistinguishable duplicate registrations cannot gain priority by order.
    if (candidates.length > 1) {
      const [a, b] = candidates;
      if (
        a.entry.key === b.entry.key &&
        a.geometry.visibleFraction === b.geometry.visibleFraction &&
        a.geometry.distanceFromCenter === b.geometry.distanceFromCenter &&
        (a.geometry.top ?? 0) === (b.geometry.top ?? 0) &&
        (a.geometry.left ?? 0) === (b.geometry.left ?? 0)
      ) {
        return;
      }
    }
    return candidates[0]?.entry;
  }

  private grant(entry: PlaybackEntry) {
    this.revoke();
    if (this.foreground && this.feedActive && !this.scrolling && this.eligible(entry)) {
      this.active = entry;
      entry.grantedMode = entry.mode;
      this.consumed = true;
      entry.change(true);
    }
  }

  private refresh(settled = false) {
    if (this.refreshing) {
      this.refreshAgain = true;
      return;
    }
    this.refreshing = true;
    try {
      if (!this.foreground || !this.feedActive) {
        this.clearTimer();
        this.revoke();
        return;
      }
      if (this.scrolling) {
        this.revoke();
        return;
      }
      if (this.active && !this.eligible(this.active)) {
        this.revoke();
      }
      const hover = this.best('hover');
      if (hover) {
        this.clearTimer();
        if (hover !== this.active) {
          this.grant(hover);
        }
        return;
      }
      if (this.active || this.consumed || !this.best('automatic')) {
        this.clearTimer();
        return;
      }
      if (settled) {
        const candidate = this.best('automatic');
        if (candidate) {
          this.grant(candidate);
        }
      } else if (!this.timer) {
        this.timer = setTimeout(() => {
          this.timer = undefined;
          this.refresh(true);
        }, LIVE_PHOTO_SETTLING_DELAY);
      }
    } finally {
      this.refreshing = false;
      if (this.refreshAgain) {
        this.refreshAgain = false;
        this.refresh();
      }
    }
  }
}

const pool = new LivePhotoPlaybackPool();

export const setLivePhotoFeedActive = (active: boolean) => pool.setFeedActive(active);

/** Live geometry is sampled only at selection boundaries, not on every scroll frame. */
const measure = (element: HTMLElement, intersectionRatio: number): Geometry | undefined => {
  const rect = element.getBoundingClientRect();
  if (!element.isConnected || rect.width <= 0 || rect.height <= 0) {
    return;
  }
  let left = Math.max(0, rect.left);
  let top = Math.max(0, rect.top);
  let right = Math.min(window.innerWidth, rect.right);
  let bottom = Math.min(window.innerHeight, rect.bottom);
  for (let parent = element.parentElement; parent; parent = parent.parentElement) {
    const style = getComputedStyle(parent);
    const bounds = parent.getBoundingClientRect();
    if (/(auto|scroll|hidden|clip)/.test(style.overflowX)) {
      left = Math.max(left, bounds.left);
      right = Math.min(right, bounds.right);
    }
    if (/(auto|scroll|hidden|clip)/.test(style.overflowY)) {
      top = Math.max(top, bounds.top);
      bottom = Math.min(bottom, bounds.bottom);
    }
  }
  const fraction = (Math.max(0, right - left) * Math.max(0, bottom - top)) / (rect.width * rect.height);
  return {
    visibleFraction: Math.min(fraction, intersectionRatio),
    distanceFromCenter: Math.hypot(
      rect.left + rect.width / 2 - window.innerWidth / 2,
      rect.top + rect.height / 2 - window.innerHeight / 2,
    ),
    top: rect.top,
    left: rect.left,
    pointerBounds: { left, top, right, bottom },
  };
};

export const observeLivePhotoPlayback = (
  element: HTMLElement,
  change: (active: boolean) => void,
  options: { mode?: PlaybackMode; key?: string; context?: string } = {},
) => {
  let intersectionRatio = 0;
  const context = options.context ?? `${location.pathname}${location.search}`;
  pool.setContext(context);
  const lease = pool.register(change, { ...options, context, measure: () => measure(element, intersectionRatio) });
  pool.trackScrollParents(element);
  let destroyed = false;
  const observer = new IntersectionObserver(
    ([entry]) => {
      intersectionRatio = entry.isIntersecting ? entry.intersectionRatio : 0;
      lease.visible(intersectionRatio > 0);
    },
    { threshold: [0, LIVE_PHOTO_VISIBILITY_THRESHOLD, 1] },
  );
  observer.observe(element);
  return {
    setMode: lease.setMode,
    complete: lease.complete,
    suspend: lease.suspend,
    destroy: () => {
      if (destroyed) {
        return;
      }
      destroyed = true;
      observer.disconnect();
      lease.destroy();
    },
  };
};
