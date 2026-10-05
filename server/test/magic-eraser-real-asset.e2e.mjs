// Opt-in real CPU-model / HTTP / PostgreSQL / filesystem contract.
// Requires a built server, a ready private Big-LaMa sidecar, and a fresh disposable
// localhost database + Redis. It creates synthetic media and never reads a library.
// Metadata/thumbnail jobs use their real existing handlers in the API process;
// the unrelated ML/geodata workers are intentionally not started.
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { promisify } from 'node:util';
import { NestFactory } from '@nestjs/core';
import { exiftool } from 'exiftool-vendored';
import pg from 'pg';
import sharp from 'sharp';

const database = new URL(process.env.DB_URL ?? '');
assert.ok(['127.0.0.1', 'localhost'].includes(database.hostname), 'Only localhost test databases are allowed');
assert.match(database.pathname, /eraser[_-]e2e/, 'Use an explicitly named disposable eraser_e2e database');
assert.ok(process.env.GALLERY_INPAINTING_URL && process.env.GALLERY_INPAINTING_TOKEN, 'A real sidecar is required');
const sidecar = new URL(process.env.GALLERY_INPAINTING_URL);
assert.ok(['127.0.0.1', 'localhost'].includes(sidecar.hostname), 'This manual test only uses a local sidecar');
assert.ok(['127.0.0.1', 'localhost'].includes(process.env.REDIS_HOSTNAME), 'Only localhost test Redis is allowed');

const directory = await mkdtemp(join(tmpdir(), 'gallery-eraser-e2e-fixtures-'));
process.env.IMMICH_ENV = 'testing';
process.env.IMMICH_HOST = '127.0.0.1';
process.env.IMMICH_PORT = '0';
process.env.IMMICH_WORKERS_INCLUDE = 'api';
process.env.IMMICH_MEDIA_LOCATION = join(directory, 'media');
process.env.IMMICH_BUILD_DATA = join(directory, 'build');
process.env.IMMICH_TELEMETRY_INCLUDE = '';
process.env.IMMICH_LOG_LEVEL = 'warn';

const client = new pg.Client({ connectionString: database.href });

let app;
let websocketRedisClients = [];
let checks = 0;
let token;
let base;
const captureDate = '2023-05-06T09:34:56.000Z';
const digest = (bytes) => createHash('sha256').update(bytes).digest('hex');
async function check(name, operation) {
  await operation();
  checks++;
  console.log(`PASS ${name}`);
}
async function api(path, { method = 'GET', body, raw = false, auth = token, status } = {}) {
  const response = await fetch(new URL(path, base), {
    method,
    headers: {
      ...(auth && { Authorization: `Bearer ${auth}` }),
      ...(body && !(body instanceof FormData) && { 'Content-Type': 'application/json' }),
    },
    body: body instanceof FormData ? body : body && JSON.stringify(body),
    signal: AbortSignal.timeout(60_000),
  });
  if (status !== undefined) {
    assert.equal(response.status, status, `Unexpected HTTP status for ${method} ${path}`);
  } else if (!response.ok) {
    assert.fail(`HTTP ${response.status} for ${method} ${path}: ${await response.text()}`);
  }
  if (raw) {
    return { response, bytes: Buffer.from(await response.arrayBuffer()) };
  }
  return response.json();
}
async function upload(bytes, filename, fields = {}) {
  const form = new FormData();
  form.append('assetData', new Blob([bytes]), filename);
  form.append('fileCreatedAt', captureDate);
  form.append('fileModifiedAt', captureDate);
  for (const [key, value] of Object.entries(fields)) {
    form.append(key, value);
  }
  const result = await api('assets', { method: 'POST', body: form });
  assert.equal(result.status, 'created');
  return result.id;
}

try {
  await client.connect();
  const table = await client.query("SELECT to_regclass('public.user') AS name");
  assert.equal(table.rows[0].name, null, 'Refusing an initialized database; create a new disposable database first');
  // Dynamic imports are essential: ApiModule captures validated environment at import time.
  const [
    { ApiModule },
    { configureExpress },
    { ApiService },
    { MetadataService },
    { MediaService },
    { JobStatus },
    { WebsocketRepository },
  ] = await Promise.all([
    import('../dist/app.module.js'),
    import('../dist/app.common.js'),
    import('../dist/services/api.service.js'),
    import('../dist/services/metadata.service.js'),
    import('../dist/services/media.service.js'),
    import('../dist/enum.js'),
    import('../dist/repositories/websocket.repository.js'),
  ]);
  app = await NestFactory.create(ApiModule, {
    bufferLogs: true,
    routeConflictPolicy: { duplicate: 'error' },
    routeResolutionStrategy: 'specificity',
  });
  await configureExpress(app, { ssr: ApiService, permitSwaggerWrite: false });
  // Gallery's existing WebSocketAdapter owns pub/sub connections outside Nest's
  // provider lifecycle. Close these explicitly in this standalone test harness.
  const adapter = app.get(WebsocketRepository).server.of('/').adapter;
  websocketRedisClients = [adapter.pubClient, adapter.subClient];
  base = new URL('/api/', await app.getUrl());
  const credentials = { email: 'synthetic-eraser-e2e@example.invalid', password: randomUUID(), name: 'Synthetic test' };
  const owner = await api('auth/admin-sign-up', { method: 'POST', body: credentials });
  token = (await api('auth/login', { method: 'POST', body: credentials })).accessToken;
  await check('real fresh Gallery API and PostgreSQL startup', async () => {
    assert.deepEqual(await api('server/ping'), { res: 'pong' });
    const migrations = await client.query('SELECT count(*)::int AS count FROM kysely_migrations');
    assert.ok(migrations.rows[0].count > 0);
  });

  const sourcePath = join(directory, 'synthetic-original.jpg');
  const svg = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="960" height="640">
    <defs><linearGradient id="g"><stop stop-color="#8fbb9b"/><stop offset="1" stop-color="#325647"/></linearGradient>
    <pattern id="p" width="24" height="24" patternUnits="userSpaceOnUse"><path d="M0 0 L24 24" stroke="#bbe0b0" stroke-width="2"/></pattern></defs>
    <rect width="960" height="640" fill="url(#g)"/><rect width="960" height="640" fill="url(#p)"/>
    <circle cx="480" cy="320" r="48" fill="#cc2420"/></svg>`);
  await sharp(svg).jpeg({ quality: 96 }).toFile(sourcePath);
  await exiftool.write(
    sourcePath,
    {
      DateTimeOriginal: '2023:05:06 12:34:56',
      OffsetTimeOriginal: '+03:00',
      'Orientation#': 6,
      Make: 'Synthetic Camera',
      Model: 'Gallery E2E',
      ImageDescription: 'Synthetic private inpainting test',
    },
    { writeArgs: ['-overwrite_original'] },
  );
  const original = await readFile(sourcePath);
  const originalHash = digest(original);
  const videoPath = join(directory, 'synthetic-motion.mp4');
  await promisify(execFile)('ffmpeg', [
    '-hide_banner',
    '-loglevel',
    'error',
    '-f',
    'lavfi',
    '-i',
    'color=c=green:s=32x32:d=0.2',
    '-an',
    '-c:v',
    'libx264',
    '-pix_fmt',
    'yuv420p',
    videoPath,
  ]);
  const motionBytes = await readFile(videoPath);
  const motionId = await upload(motionBytes, 'synthetic-motion.mp4');
  const sourceId = await upload(original, 'synthetic-original.jpg', { livePhotoVideoId: motionId });
  const peerBytes = await sharp({ create: { width: 64, height: 64, channels: 3, background: '#a4c5b2' } })
    .jpeg()
    .toBuffer();
  const peerId = await upload(peerBytes, 'stack-peer.jpg');
  const stack = await api('stacks', { method: 'POST', body: { assetIds: [sourceId, peerId] } });
  const metadata = app.get(MetadataService);
  const media = app.get(MediaService);
  await metadata.handleMetadataExtraction({ id: sourceId });
  assert.equal(await media.handleGenerateThumbnails({ id: sourceId }), JobStatus.Success);
  const before = await api(`assets/${sourceId}`);

  await check('server-only original with EXIF, orientation, stack and live pairing', async () => {
    assert.equal(before.ownerId, owner.id);
    assert.equal(before.fileCreatedAt, captureDate);
    assert.equal(before.stack.id, stack.id);
    assert.equal(before.livePhotoVideoId, motionId);
    assert.equal(before.width, 640);
    assert.equal(before.height, 960);
    assert.ok(before.exifInfo.timeZone);
    assert.equal(digest((await api(`assets/${sourceId}/original?edited=false`, { raw: true })).bytes), originalHash);
  });
  await check('authorization enforced on capabilities and mask', async () => {
    await api(`assets/${sourceId}/magic-eraser/capabilities`, { auth: null, status: 401 });
    await api(`assets/${sourceId}/magic-eraser`, {
      method: 'POST',
      auth: null,
      status: 401,
      body: { strokes: [{ points: [{ x: 0.5, y: 0.5 }], radius: 0.11, erase: false }] },
    });
  });
  const capabilities = await api(`assets/${sourceId}/magic-eraser/capabilities`);
  assert.equal(capabilities.enabled, true);
  assert.equal(capabilities.model, 'big-lama');
  assert.equal(capabilities.saveCopyOnly, true);
  const editorSource = await api(`assets/${sourceId}/magic-eraser/source`, { raw: true });
  await check('bounded oriented source preview from server storage', async () => {
    const dimensions = await sharp(editorSource.bytes).metadata();
    assert.equal(dimensions.width, 640);
    assert.equal(dimensions.height, 960);
    assert.equal(editorSource.response.headers.get('content-type').split(';')[0], 'image/jpeg');
  });
  const started = performance.now();
  const job = await api(`assets/${sourceId}/magic-eraser`, {
    method: 'POST',
    status: 202,
    body: { strokes: [{ points: [{ x: 0.5, y: 0.5 }], radius: 0.11, erase: false }] },
  });
  await check('mask validation uses actual HTTP DTO boundary', async () => {
    await api(`assets/${sourceId}/magic-eraser`, {
      method: 'POST',
      status: 400,
      body: { strokes: [{ points: [{ x: 2, y: 0.5 }], radius: 0.11, erase: false }] },
    });
  });
  let ready;
  for (let attempt = 0; attempt < 240; attempt++) {
    ready = await api(`assets/${sourceId}/magic-eraser/${job.id}`);
    if (ready.status === 'ready') {
      break;
    }
    assert.ok(['queued', 'processing'].includes(ready.status), `Unexpected job result ${JSON.stringify(ready)}`);
    await delay(500);
  }
  await check('real CPU Big-LaMa inference returns ready', async () => {
    assert.equal(ready.status, 'ready');
    console.log(`Real API inference wall time: ${((performance.now() - started) / 1000).toFixed(3)}s`);
  });
  const resultPreview = await api(`assets/${sourceId}/magic-eraser/${job.id}/preview`, { raw: true });
  await check('result preview changes selected object and preserves dimensions', async () => {
    const dimensions = await sharp(resultPreview.bytes).metadata();
    assert.equal(dimensions.width, 640);
    assert.equal(dimensions.height, 960);
    const center = (bytes) => sharp(bytes).extract({ left: 316, top: 476, width: 8, height: 8 }).raw().toBuffer();
    const [a, b] = await Promise.all([center(editorSource.bytes), center(resultPreview.bytes)]);
    assert.ok(a.reduce((sum, value, index) => sum + Math.abs(value - b[index]), 0) / a.length > 20);
  });
  const countBeforeSave = (await client.query('SELECT count(*)::int AS count FROM asset')).rows[0].count;
  const saved = await api(`assets/${sourceId}/magic-eraser/${job.id}/save`, { method: 'POST' });
  await check('save copy creates one new normal Gallery asset', async () => {
    assert.equal(saved.status, 'created');
    assert.notEqual(saved.id, sourceId);
    assert.equal((await client.query('SELECT count(*)::int AS count FROM asset')).rows[0].count, countBeforeSave + 1);
  });
  await metadata.handleMetadataExtraction({ id: saved.id });
  assert.equal(await media.handleGenerateThumbnails({ id: saved.id }), JobStatus.Success);
  const copy = await api(`assets/${saved.id}`);
  const copyBytes = (await api(`assets/${saved.id}/original?edited=false`, { raw: true })).bytes;
  await check('saved still owner/date/timezone/orientation and ordinary thumbnails', async () => {
    assert.equal(copy.ownerId, owner.id);
    assert.equal(copy.type, 'IMAGE');
    assert.equal(copy.fileCreatedAt, captureDate);
    assert.equal(copy.visibility, before.visibility);
    assert.equal(copy.exifInfo.timeZone, before.exifInfo.timeZone);
    assert.equal(copy.exifInfo.make, before.exifInfo.make);
    assert.equal(copy.exifInfo.model, before.exifInfo.model);
    assert.equal(copy.exifInfo.description, before.exifInfo.description);
    assert.equal(copy.width, 640);
    assert.equal(copy.height, 960);
    assert.equal(copy.exifInfo.orientation, '1');
    assert.equal(copy.stack, null);
    assert.equal(copy.livePhotoVideoId, null);
    assert.equal(copy.isEdited, false);
    assert.equal(copy.originalFileName, 'synthetic-original-magic-eraser.jpg');
    assert.equal(copy.checksum, createHash('sha1').update(copyBytes).digest('base64'));
    assert.equal(await readFile(copy.originalPath).then(digest), digest(copyBytes));
    assert.ok((await stat(copy.originalPath)).size > 0);
    const thumbnail = await api(`assets/${saved.id}/thumbnail?size=thumbnail`, { raw: true });
    assert.ok(thumbnail.bytes.length > 0);
  });
  await check('source provenance stored by standard metadata API and PostgreSQL', async () => {
    const provenance = await api(`assets/${saved.id}/metadata/gallery.magicEraser`);
    assert.equal(provenance.value.sourceAssetId, sourceId);
    assert.equal(provenance.value.sourceTimeZone, before.exifInfo.timeZone);
    assert.equal(provenance.value.model, 'big-lama');
    assert.equal(provenance.value.stillOnly, true);
    assert.equal(provenance.value.jobId, job.id);
    const row = await client.query('SELECT value FROM asset_metadata WHERE "assetId"=$1 AND key=$2', [
      saved.id,
      'gallery.magicEraser',
    ]);
    assert.deepEqual(row.rows[0].value, provenance.value);
  });
  await check('repeated save is idempotent and original bytes/stack/motion remain intact', async () => {
    assert.deepEqual(await api(`assets/${sourceId}/magic-eraser/${job.id}/save`, { method: 'POST' }), saved);
    assert.equal((await client.query('SELECT count(*)::int AS count FROM asset')).rows[0].count, countBeforeSave + 1);
    const sourceAfter = await api(`assets/${sourceId}`);
    assert.equal(sourceAfter.stack.id, stack.id);
    assert.equal(sourceAfter.stack.assetCount, 2);
    assert.equal(sourceAfter.livePhotoVideoId, motionId);
    assert.equal(digest((await api(`assets/${sourceId}/original?edited=false`, { raw: true })).bytes), originalHash);
    assert.equal(
      digest((await api(`assets/${motionId}/original?edited=false`, { raw: true })).bytes),
      digest(motionBytes),
    );
    assert.equal((await api(`assets/${sourceId}/magic-eraser/${job.id}`)).status, 'saved');
  });
  console.log(`PASS all ${checks} real-model / HTTP / database / filesystem contracts`);
} finally {
  await app?.close();
  await Promise.all(
    websocketRedisClients.filter((connection) => connection?.status !== 'end').map((connection) => connection.quit()),
  );
  await exiftool.end();
  await client.end();
  await rm(directory, { recursive: true, force: true });
}
