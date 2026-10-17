import { expect, test, type Page } from '@playwright/test';
import {
  createDefaultTimelineConfig,
  generateTimelineData,
  toAssetResponseDto,
  type Changes,
  type TimelineData,
} from 'src/ui/generators/timeline.js';
import { setupBaseMockApiRoutes } from 'src/ui/mock-network/base-network.js';
import { MINIMAL_MP4_BUFFER } from 'src/ui/mock-network/face-editor-network.js';
import { setupTimelineMockApiRoutes, TimelineTestContext } from 'src/ui/mock-network/timeline-network.js';

const ownerId = 'ad002b29-cf9e-4d67-bab1-91ad63fcd354';
let data: TimelineData;
const changes: Changes = { albumAdditions: [], assetDeletions: [], assetArchivals: [], assetFavorites: [] };

test.setTimeout(60_000);
const expectPlaying = async (page: Page, container = '#asset-grid') => {
  // A fresh Vite test server must compile the timeline before the app can mount.
  // Keep playback checks separate from that initial application readiness wait.
  await expect(page.locator(`${container} [data-asset]`).first()).toBeVisible({ timeout: 45_000 });
  await expect.poll(() => page.locator(`${container} [data-asset] video`).count()).toBeGreaterThan(0);
  await expect.poll(() => page.locator(`${container} [data-asset] video`).count()).toBeLessThanOrEqual(3);
  await expect
    .poll(() =>
      page
        .locator(`${container} [data-asset] video`)
        .first()
        .evaluate(
          (video: HTMLVideoElement) => video.muted && video.playsInline && !video.paused && video.currentTime > 0,
        ),
    )
    .toBe(true);
};

test.beforeEach(async ({ context }) => {
  const config = createDefaultTimelineConfig();
  data = generateTimelineData({ ...config, ownerId, months: [config.months[0]] });
  for (const assets of data.buckets.values()) {
    for (const [index, asset] of assets.entries()) {
      asset.isImage = true;
      asset.isVideo = false;
      asset.duration = null;
      asset.livePhotoVideoId = `00000000-0000-4000-8000-${String(index).padStart(12, '0')}`;
    }
  }
  const state = new TimelineTestContext();
  state.adminId = ownerId;
  await setupBaseMockApiRoutes(context, ownerId);
  await context.route('**/api/memories/statistics*', (route) => route.fulfill({ json: { total: 0 } }));
  await context.route('**/custom.css', (route) => route.fulfill({ contentType: 'text/css', body: '' }));
  await setupTimelineMockApiRoutes(context, data, changes, state);
});

test('cold feed plays without hover or viewer initialization, with bounded decoders', async ({ page }) => {
  await page.goto('/photos');
  await expectPlaying(page);
  await expect(page.locator('#immich-asset-viewer')).toHaveCount(0);
});

test('virtualized scrolling releases offscreen videos and initializes newly visible Live Photos', async ({ page }) => {
  await page.goto('/photos');
  await expectPlaying(page);
  const firstId = await page
    .locator('#asset-grid [data-asset] video')
    .first()
    .evaluate((video) => (video.closest('[data-asset]') as HTMLElement).dataset.asset);
  const grid = page.locator('#asset-grid');
  await grid.evaluate((element) => {
    element.scrollTop = element.scrollHeight;
  });
  await expectPlaying(page);
  await expect(page.locator(`[data-asset="${firstId}"] video`)).toHaveCount(0);
  await grid.evaluate((element) => {
    element.scrollTop = 0;
  });
  await expectPlaying(page);
});

test('opening viewer releases feed decoders and returning restarts them', async ({ page }) => {
  await page.goto('/photos');
  await expectPlaying(page);
  await page.locator('#asset-grid [data-asset]').first().click();
  await expect(page.getByLabel('Go back', { exact: true })).toBeVisible();
  await expect(page.locator('#asset-grid [data-asset] video')).toHaveCount(0);
  await page.getByLabel('Go back', { exact: true }).click();
  await expectPlaying(page);
});

test('background visibility pauses decoding and foreground resumes without viewer playback', async ({ page }) => {
  await page.goto('/photos');
  await expectPlaying(page);
  await page.evaluate(() => {
    Object.defineProperty(document, 'hidden', { configurable: true, value: true });
    document.dispatchEvent(new Event('visibilitychange'));
  });
  await expect(page.locator('#asset-grid [data-asset] video')).toHaveCount(0);
  await page.evaluate(() => {
    Object.defineProperty(document, 'hidden', { configurable: true, value: false });
    document.dispatchEvent(new Event('visibilitychange'));
  });
  await expectPlaying(page);
});

test('a failed cold playback retries once without opening the viewer', async ({ page, context }) => {
  let failedId: string | undefined;
  let attempts = 0;
  await context.route('**/api/assets/*/video/playback*', async (route) => {
    const id = new URL(route.request().url()).pathname.split('/', 4)[3];
    failedId ??= id;
    if (id === failedId && ++attempts === 1) {
      await route.fulfill({ status: 500 });
      return;
    }
    await route.fulfill({ status: 200, contentType: 'video/mp4', body: MINIMAL_MP4_BUFFER });
  });
  await page.goto('/photos');
  await expect(page.locator('#asset-grid [data-asset]').first()).toBeVisible({ timeout: 15_000 });
  await expect.poll(() => attempts, { timeout: 15_000 }).toBe(2);
  await expectPlaying(page);
  await expect(page.locator('#immich-asset-viewer')).toHaveCount(0);
});

test('reload initializes the feed independently of playback history', async ({ page }) => {
  await page.goto('/photos');
  await expectPlaying(page);
  await page.reload();
  await expectPlaying(page);
});

test('album uses the same visible Live Photo initialization', async ({ page }) => {
  await page.goto(`/albums/${data.album.id}`);
  await expectPlaying(page);
});

test('search results animate associated motion videos without opening a viewer', async ({ page, context }) => {
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
});
