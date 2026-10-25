import { expect, test, type Page, type Route } from '@playwright/test';
import { readFileSync } from 'node:fs';
import {
  createDefaultTimelineConfig,
  generateTimelineData,
  toAssetResponseDto,
  type Changes,
  type TimelineData,
} from 'src/ui/generators/timeline.js';
import { setupBaseMockApiRoutes } from 'src/ui/mock-network/base-network.js';
import { setupTimelineMockApiRoutes, TimelineTestContext } from 'src/ui/mock-network/timeline-network.js';

const ownerId = 'ad002b29-cf9e-4d67-bab1-91ad63fcd354';
const feedVideoSelector = '#asset-grid [data-asset] video, #search-content [data-asset] video';
const changes: Changes = { albumAdditions: [], assetDeletions: [], assetArchivals: [], assetFavorites: [] };
let data: TimelineData;
let playbackRequests: string[];

// A valid, multi-frame H.264 fixture supports both one-shot feed playback and
// restarting the same media in the manual fullscreen viewer. Synthetic only:
// ffmpeg -f lavfi -i color=c=steelblue:s=32x32:r=2 -t 60 -an -c:v libx264
//   -profile:v baseline -pix_fmt yuv420p -movflags +faststart live-photo-autoplay.mp4
const timelineMp4 = readFileSync(new URL('../../fixtures/live-photo-autoplay.mp4', import.meta.url));

const fulfillVideo = async (route: Route) => {
  const range = route.request().headers().range;
  const match = range?.match(/^bytes=(\d+)-(\d*)$/);
  if (!range) {
    await route.fulfill({ contentType: 'video/mp4', headers: { 'Accept-Ranges': 'bytes' }, body: timelineMp4 });
    return;
  }
  const start = match ? Number(match[1]) : timelineMp4.length;
  const end = match?.[2] ? Math.min(Number(match[2]), timelineMp4.length - 1) : timelineMp4.length - 1;
  if (start > end || start >= timelineMp4.length) {
    await route.fulfill({ status: 416, headers: { 'Content-Range': `bytes */${timelineMp4.length}` } });
    return;
  }
  await route.fulfill({
    status: 206,
    contentType: 'video/mp4',
    headers: { 'Accept-Ranges': 'bytes', 'Content-Range': `bytes ${start}-${end}/${timelineMp4.length}` },
    body: timelineMp4.subarray(start, end + 1),
  });
};

type PlaybackProbe = { maxSources: number; maxPlaying: number; started: string[]; ended: string[] };
type ProbedWindow = Window & { fotoLivePhotoProbe: PlaybackProbe };

test.setTimeout(60_000);
test.use({ viewport: { width: 1600, height: 1200 } });

const expectPlaying = async (page: Page, container = '#asset-grid') => {
  // A fresh Vite server may compile the timeline before its first mount.
  await expect(page.locator(`${container} [data-asset]`).first()).toBeVisible({ timeout: 45_000 });
  await expect(page.locator(`${container} [data-asset] video`)).toHaveCount(1);
  await expect
    .poll(() =>
      page.locator(`${container} [data-asset] video`).evaluateAll((videos) => {
        const video = videos[0] as HTMLVideoElement | undefined;
        return !!video && video.muted && video.playsInline && !video.paused && video.currentTime > 0;
      }),
    )
    .toBe(true);
  return page.locator(`${container} [data-asset] video`);
};

const expectSingleDecoder = async (page: Page) => {
  const probe = await page.evaluate(() => (globalThis as ProbedWindow).fotoLivePhotoProbe);
  expect(probe.maxSources).toBeLessThanOrEqual(1);
  expect(probe.maxPlaying).toBeLessThanOrEqual(1);
};

const focusedAsset = async (page: Page) =>
  page
    .locator('#asset-grid [data-asset] video')
    .evaluate((video) => video.closest<HTMLElement>('[data-asset]')!.dataset.asset);

const visibleCandidates = async (page: Page) =>
  page.locator('#asset-grid [data-asset]').evaluateAll((elements) =>
    elements
      .map((element) => {
        const rect = element.getBoundingClientRect();
        let left = Math.max(0, rect.left);
        let right = Math.min(innerWidth, rect.right);
        let top = Math.max(0, rect.top);
        let bottom = Math.min(innerHeight, rect.bottom);
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
        const area = rect.width * rect.height;
        return {
          id: (element as HTMLElement).dataset.asset,
          ratio: area > 0 ? Math.min(1, (Math.max(0, right - left) * Math.max(0, bottom - top)) / area) : 0,
          distance:
            (rect.left + rect.width / 2 - innerWidth / 2) ** 2 + (rect.top + rect.height / 2 - innerHeight / 2) ** 2,
        };
      })
      .filter((candidate) => candidate.ratio >= 0.8)
      .toSorted((a, b) => b.ratio - a.ratio || a.distance - b.distance),
  );

test.beforeEach(async ({ context }) => {
  playbackRequests = [];
  const config = createDefaultTimelineConfig();
  data = generateTimelineData({ ...config, ownerId, months: [{ ...config.months[0], pattern: 'single-day' }] });
  for (const assets of data.buckets.values()) {
    for (const [index, asset] of assets.entries()) {
      asset.ratio = 1;
      asset.isImage = true;
      asset.isVideo = false;
      asset.duration = null;
      asset.livePhotoVideoId = `00000000-0000-4000-8000-${String(index).padStart(12, '0')}`;
    }
  }
  const state = new TimelineTestContext();
  state.adminId = ownerId;
  await setupBaseMockApiRoutes(context, ownerId);
  await context.route('**/api/shared-spaces', (route) => route.fulfill({ json: [] }));
  await context.route('**/api/faces?*', (route) => route.fulfill({ json: [] }));
  await context.route('**/api/search/suggestions/filters*', (route) =>
    route.fulfill({
      json: {
        cameraMakes: [],
        countries: [],
        hasAssetsInAlbum: true,
        hasAssetsNotInAlbum: false,
        hasFavorites: false,
        hasUnnamedPeople: false,
        mediaTypes: ['IMAGE'],
        people: [],
        ratings: [],
        tags: [],
      },
    }),
  );
  await context.route('**/api/memories/statistics*', (route) => route.fulfill({ json: { total: 0 } }));
  await context.route('**/custom.css', (route) => route.fulfill({ contentType: 'text/css', body: '' }));
  await setupTimelineMockApiRoutes(context, data, changes, state);
  await context.route('**/api/assets/*/video/playback*', async (route) => {
    playbackRequests.push(new URL(route.request().url()).pathname);
    await fulfillVideo(route);
  });
  await context.addInitScript((selector) => {
    const probe: PlaybackProbe = { maxSources: 0, maxPlaying: 0, started: [], ended: [] };
    Object.defineProperty(globalThis, 'fotoLivePhotoProbe', { value: probe });
    const snapshot = () => {
      const sources = [...document.querySelectorAll<HTMLVideoElement>(selector)].filter((video) =>
        video.hasAttribute('src'),
      );
      probe.maxSources = Math.max(probe.maxSources, sources.length);
      probe.maxPlaying = Math.max(probe.maxPlaying, sources.filter((video) => !video.paused && !video.ended).length);
    };
    const record = (event: Event, target: string[]) => {
      if (!(event.target instanceof HTMLVideoElement && event.target.matches(selector))) {
        return;
      }

      target.push(event.target.closest<HTMLElement>('[data-asset]')!.dataset.asset!);
      snapshot();
    };
    document.addEventListener('play', (event) => record(event, probe.started), { capture: true });
    document.addEventListener('ended', (event) => record(event, probe.ended), { capture: true });
    document.addEventListener('loadstart', snapshot, { capture: true });
    new MutationObserver(snapshot).observe(document, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['src'],
    });
  }, feedVideoSelector);
});

test('ten or more visible Live Photos allocate one decoder and prefer the central visible candidate', async ({
  page,
}, testInfo) => {
  await page.goto('/photos');
  await expectPlaying(page);
  const candidates = await visibleCandidates(page);
  expect(candidates.length).toBeGreaterThanOrEqual(10);
  expect(await focusedAsset(page)).toBe(candidates[0].id);
  expect(await focusedAsset(page)).not.toBe(
    await page.locator('#asset-grid [data-asset]').first().getAttribute('data-asset'),
  );
  await expect(page.locator('#immich-asset-viewer')).toHaveCount(0);
  expect(new Set(playbackRequests).size).toBe(1);
  await expectSingleDecoder(page);
  await page.screenshot({ path: testInfo.outputPath('synthetic-live-photo-single-player.png') });
});

test('nested scrolling immediately retires the old source and settles on a new central candidate', async ({ page }) => {
  await page.goto('/photos');
  const first = await expectPlaying(page);
  const firstVideo = await first.elementHandle();
  const firstId = await focusedAsset(page);
  const grid = page.locator('#asset-grid');
  // Assert the synchronous stop and the entire scrolling interval in the
  // browser. Host round trips can exceed the 350 ms settling window on CI.
  await grid.evaluate(async (element, oldVideo) => {
    const previousOffset = element.scrollTop;
    element.scrollTop += 600;
    if (element.scrollTop === previousOffset) {
      throw new Error(`The synthetic timeline did not scroll (${element.clientHeight}/${element.scrollHeight})`);
    }
    element.dispatchEvent(new Event('scroll'));
    const previousPlayer = oldVideo as HTMLVideoElement;
    if (!previousPlayer.paused || previousPlayer.hasAttribute('src') || element.querySelector('video[src]')) {
      throw new Error('Scrolling did not synchronously release the old feed source');
    }
    // Continuing viewport movements restart the settling delay.
    for (let index = 0; index < 5; index++) {
      element.scrollTop += 24;
      element.dispatchEvent(new Event('scroll'));
      await new Promise((resolve) => setTimeout(resolve, 50));
      if (element.querySelector('video[src]')) {
        throw new Error('A feed decoder was created during scrolling');
      }
    }
  }, firstVideo);
  await expectPlaying(page);
  expect(await focusedAsset(page)).not.toBe(firstId);
  const settledCandidates = await visibleCandidates(page);
  expect(await focusedAsset(page)).toBe(settledCandidates[0].id);
  await grid.evaluate((element) => {
    element.scrollTop = element.scrollHeight;
  });
  await expectPlaying(page);
  await expect(page.locator(`[data-asset="${firstId}"] video`)).toHaveCount(0);
  await grid.evaluate((element) => {
    element.scrollTop = 0;
  });
  await expectPlaying(page);
  await expectSingleDecoder(page);
});

test('natural completion returns to the still without looping or cascading to another photo', async ({ page }) => {
  await page.goto('/photos');
  const video = await expectPlaying(page);
  expect(await video.evaluate((element) => (element as HTMLVideoElement).loop)).toBe(false);
  const requests = playbackRequests.length;
  await video.evaluate((element) => {
    const player = element as HTMLVideoElement;
    player.currentTime = player.duration - 0.02;
  });
  await expect.poll(() => page.evaluate(() => (globalThis as ProbedWindow).fotoLivePhotoProbe.ended.length)).toBe(1);
  await expect(page.locator('#asset-grid [data-asset] video')).toHaveCount(0);
  await page.waitForTimeout(700);
  await expect(page.locator('#asset-grid [data-asset] video')).toHaveCount(0);
  expect(playbackRequests).toHaveLength(requests);
  await expectSingleDecoder(page);
});

test('opening the viewer releases feed playback while manual remote Live Photo playback still works', async ({
  page,
}) => {
  // Verify explicit manual playback even with fullscreen autoplay disabled.
  // A fresh browser can otherwise reject a newly mounted unmuted player's
  // asynchronous autoplay after the Motion Photo button has lost activation.
  await page.addInitScript(() => localStorage.setItem('auto-play-video', 'false'));
  await page.goto('/photos');
  const video = await expectPlaying(page);
  const previous = await video.elementHandle();
  await page.locator('#asset-grid [data-asset]').first().click();
  await expect(page.getByLabel('Go back', { exact: true })).toBeVisible();
  await expect(page.locator('#asset-grid [data-asset] video')).toHaveCount(0);
  expect(
    await previous!.evaluate((element) => (element as HTMLVideoElement).paused && !element.hasAttribute('src')),
  ).toBe(true);
  await page.getByRole('button', { name: 'Play Motion Photo', exact: true }).click();
  const viewerVideo = page.locator('[data-viewer-content] video');
  await expect(viewerVideo).toHaveCount(1);
  await expect
    .poll(() =>
      viewerVideo.evaluate((element) => {
        const player = element as HTMLVideoElement;
        return { ready: player.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA, error: player.error?.code ?? null };
      }),
    )
    .toEqual({ ready: true, error: null });
  await page.getByRole('button', { name: 'Play', exact: true }).click();
  await expect
    .poll(() =>
      viewerVideo.evaluate((element) => {
        const player = element as HTMLVideoElement;
        return {
          paused: player.paused,
          advanced: player.currentTime > 0,
          currentTime: player.currentTime,
          readyState: player.readyState,
          networkState: player.networkState,
          error: player.error?.code ?? null,
        };
      }),
    )
    .toEqual(expect.objectContaining({ paused: false, advanced: true, error: null }));
  await expect(page.locator('#asset-grid [data-asset] video')).toHaveCount(0);
  await page.getByLabel('Go back', { exact: true }).click();
  await expectPlaying(page);
  await expectSingleDecoder(page);
});

test('repeated visibility changes retire sources and never duplicate foreground decoders', async ({ page }) => {
  await page.goto('/photos');
  await expectPlaying(page);
  for (let index = 0; index < 2; index++) {
    const video = await page.locator('#asset-grid [data-asset] video').elementHandle();
    // Headless pages do not reliably become hidden on bringToFront. Physical
    // tab acceptance remains separate from this browser listener regression.
    await page.evaluate(() => {
      Object.defineProperty(document, 'hidden', { configurable: true, value: true });
      document.dispatchEvent(new Event('visibilitychange'));
    });
    await expect(page.locator('#asset-grid [data-asset] video')).toHaveCount(0);
    expect(
      await video!.evaluate((element) => (element as HTMLVideoElement).paused && !element.hasAttribute('src')),
    ).toBe(true);
    await page.evaluate(() => {
      Object.defineProperty(document, 'hidden', { configurable: true, value: false });
      document.dispatchEvent(new Event('visibilitychange'));
    });
    await expectPlaying(page);
  }
  await expectSingleDecoder(page);
});

test('a failed automatic source stays static without repeated requests or another candidate cascade', async ({
  page,
  context,
}) => {
  let attempts = 0;
  await context.route('**/api/assets/*/video/playback*', async (route) => {
    attempts++;
    await route.fulfill({ status: 500 });
  });
  await page.goto('/photos');
  await expect.poll(() => attempts, { timeout: 45_000 }).toBe(1);
  await expect(page.locator('#asset-grid [data-asset] video')).toHaveCount(0);
  await page.waitForTimeout(1200);
  expect(attempts).toBe(1);
  await expect(page.locator('#asset-grid [data-asset] video')).toHaveCount(0);
  await expectSingleDecoder(page);
});

test('unchanged layout notifications keep one source and route unmount releases its resources', async ({ page }) => {
  await page.goto('/photos');
  const playing = await expectPlaying(page);
  const video = await playing.elementHandle();
  const requests = playbackRequests.length;
  await page.evaluate(() => {
    globalThis.dispatchEvent(new Event('resize'));
    globalThis.dispatchEvent(new Event('resize'));
  });
  await page.waitForTimeout(500);
  expect(await video!.evaluate((element) => element.isConnected && !(element as HTMLVideoElement).paused)).toBe(true);
  expect(playbackRequests).toHaveLength(requests);
  await page.locator('a[href="/albums"]').first().click();
  await expect(page).toHaveURL(/\/albums$/);
  await expect(page.locator('#asset-grid')).toHaveCount(0);
  expect(await video!.evaluate((element) => (element as HTMLVideoElement).paused && !element.hasAttribute('src'))).toBe(
    true,
  );
  await expect(page.locator(feedVideoSelector)).toHaveCount(0);
  await page.waitForTimeout(500);
  expect(playbackRequests).toHaveLength(requests);
  await expectSingleDecoder(page);
});

test('ordinary video hover retains playback and yields the shared feed decoder without overlapping Live Photos', async ({
  page,
}) => {
  const ordinary = data.buckets.values().next().value![0];
  ordinary.isImage = false;
  ordinary.isVideo = true;
  ordinary.livePhotoVideoId = null;
  ordinary.duration = 60_000;
  await page.goto('/photos');
  const automatic = await expectPlaying(page);
  const oldVideo = await automatic.elementHandle();
  const tile = page.locator(`#asset-grid [data-asset="${ordinary.id}"]`);
  await tile.hover();
  await expect(tile.locator('video')).toHaveCount(1);
  await expect.poll(() => focusedAsset(page)).toBe(ordinary.id);
  await expect
    .poll(() =>
      tile.locator('video').evaluate((element) => {
        const player = element as HTMLVideoElement;
        return !player.paused && player.currentTime > 0;
      }),
    )
    .toBe(true);
  expect(
    await oldVideo!.evaluate((element) => (element as HTMLVideoElement).paused && !element.hasAttribute('src')),
  ).toBe(true);
  await expect(page.locator('#asset-grid [data-asset] video')).toHaveCount(1);
  await page.mouse.move(0, 0);
  await expect(tile.locator('video')).toHaveCount(0);
  await expectSingleDecoder(page);
});

test('reload initializes one feed player independently of playback history', async ({ page }) => {
  await page.goto('/photos');
  await expectPlaying(page);
  await page.reload();
  await expectPlaying(page);
  await expectSingleDecoder(page);
});

test('album uses the same single visible Live Photo playback budget', async ({ page }) => {
  await page.goto(`/albums/${data.album.id}`);
  await expectPlaying(page);
  await expectSingleDecoder(page);
});

test('ten search results share one motion player without opening a viewer', async ({ page, context }) => {
  const assets = data.buckets
    .values()
    .toArray()
    .flat()
    .slice(0, 10)
    .map((asset) => toAssetResponseDto(asset));
  await context.route('**/api/search/metadata', (route) =>
    route.fulfill({
      json: {
        albums: { total: 0, count: 0, items: [], facets: [] },
        assets: { total: assets.length, count: assets.length, items: assets, facets: [], nextPage: null },
      },
    }),
  );
  await page.goto(`/search?query=${encodeURIComponent(JSON.stringify({ originalFileName: 'test' }))}`);
  await expectPlaying(page, '#search-content');
  await expect(page.locator('#immich-asset-viewer')).toHaveCount(0);
  await expectSingleDecoder(page);
});
