// Opt-in real HTTP / PostgreSQL / sync / filesystem contract.
// Only a fresh, explicitly named localhost test database and localhost Redis are
// accepted. All users/media are synthetic; production libraries are never read.
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { promisify } from 'node:util';
import { NestFactory } from '@nestjs/core';
import { exiftool } from 'exiftool-vendored';
import { DateTime } from 'luxon';
import pg from 'pg';
import sharp from 'sharp';

const database = new URL(process.env.DB_URL ?? '');
assert.ok(['127.0.0.1', 'localhost'].includes(database.hostname), 'Only localhost test databases are allowed');
assert.match(database.pathname, /memory[_-]e2e/, 'Use an explicitly named disposable memory_e2e database');
assert.ok(['127.0.0.1', 'localhost'].includes(process.env.REDIS_HOSTNAME), 'Only localhost test Redis is allowed');

const directory = await mkdtemp(join(tmpdir(), 'gallery-memory-e2e-fixtures-'));
process.env.IMMICH_ENV = 'testing';
process.env.IMMICH_HOST = '127.0.0.1';
process.env.IMMICH_PORT = '0';
process.env.IMMICH_WORKERS_INCLUDE = 'api';
process.env.IMMICH_MEDIA_LOCATION = join(directory, 'media');
process.env.IMMICH_BUILD_DATA = join(directory, 'build');
process.env.IMMICH_TELEMETRY_INCLUDE = '';
process.env.IMMICH_LOG_LEVEL = 'warn';
// The feature is independent of the optional Magic Eraser sidecar.
delete process.env.GALLERY_INPAINTING_URL;
delete process.env.GALLERY_INPAINTING_TOKEN;

const client = new pg.Client({ connectionString: database.href });
let app;
let databaseRepository;
let websocketRedisClients = [];
let base;
let token;
let checks = 0;
const today = DateTime.utc().startOf('day');
const onThisDayDate = today.minus({ years: 2 }).plus({ hours: 12 }).toISO();
const captureDate = '2023-01-12T09:34:56.000Z';
const digest = (bytes) => createHash('sha256').update(bytes).digest('hex');
const assets = [];

async function check(name, operation) {
  await operation();
  checks++;
  console.log(`PASS ${name}`);
}

async function api(path, { method = 'GET', body, auth = token, apiKey, status, raw = false } = {}) {
  const response = await fetch(new URL(path, base), {
    method,
    headers: {
      ...(apiKey ? { 'x-api-key': apiKey } : auth && { Authorization: `Bearer ${auth}` }),
      ...(body && !(body instanceof FormData) && { 'Content-Type': 'application/json' }),
    },
    body: body instanceof FormData ? body : body && JSON.stringify(body),
    signal: AbortSignal.timeout(60_000),
  });
  if (status !== undefined) {
    assert.equal(
      response.status,
      status,
      `Unexpected HTTP status for ${method} ${path}: ${await response.clone().text()}`,
    );
  } else if (!response.ok) {
    assert.fail(`HTTP ${response.status} for ${method} ${path}: ${await response.text()}`);
  }
  if (raw) return Buffer.from(await response.arrayBuffer());
  if (response.status === 204) return;
  return response.json();
}

async function upload(index, date = captureDate) {
  let bytes = await sharp({
    create: { width: 32, height: 32, channels: 3, background: { r: 20 + index * 10, g: 90, b: 110 } },
  })
    .jpeg()
    .toBuffer();
  if (date === onThisDayDate) {
    const path = join(directory, 'synthetic-anniversary-original.jpg');
    await writeFile(path, bytes);
    await exiftool.write(
      path,
      {
        DateTimeOriginal: DateTime.fromISO(date).toUTC().toFormat('yyyy:MM:dd HH:mm:ss'),
        OffsetTimeOriginal: '+00:00',
      },
      { writeArgs: ['-overwrite_original'] },
    );
    bytes = await readFile(path);
  }
  return uploadBytes(bytes, `synthetic-memory-${index}.jpg`, date);
}

async function uploadBytes(bytes, filename, date = captureDate) {
  const form = new FormData();
  form.append('assetData', new Blob([bytes]), filename);
  form.append('fileCreatedAt', date);
  form.append('fileModifiedAt', date);
  const result = await api('assets', { method: 'POST', body: form });
  assert.equal(result.status, 'created');
  assets.push({ id: result.id, hash: digest(bytes) });
  return result.id;
}

function memoryBody(ids, { ai = false, date = captureDate } = {}) {
  return {
    type: ai ? 'rule' : 'on_this_day',
    data: ai
      ? {
          ruleId: 'gallery_ai_highlight',
          generator: 'family-memory-generator',
          version: '3.7',
          theme: 'synthetic-holiday',
          score: 0.82,
          context: { selection: 'diverse', providerIndependent: true },
          title: 'Synthetic AI highlight',
          subtitle: 'Synthetic photo and video collection',
          dedupeKey: randomUUID(),
        }
      : { year: new Date(date).getUTCFullYear() },
    memoryAt: date,
    showAt: today.toISO(),
    hideAt: today.endOf('day').toISO(),
    assetIds: ids,
  };
}

async function snapshot(path, apiKey) {
  const items = [];
  let after;
  for (let page = 0; page < 50; page++) {
    const query = new URLSearchParams({ size: '2', ...(after && { after }) });
    const result = await api(`${path}?${query}`, { apiKey });
    assert.ok(result.items.length <= 2);
    items.push(...result.items);
    if (!result.nextCursor) {
      assert.equal(new Set(items.map((item) => item.id)).size, items.length);
      return items;
    }
    assert.notEqual(result.nextCursor, after);
    after = result.nextCursor;
  }
  assert.fail('Snapshot pagination did not terminate');
}

async function sync(auth) {
  // The SharedSpacesV1 marker preserves rule-memory types for Gallery clients.
  await delay(5);
  const bytes = await api('sync/stream', {
    method: 'POST',
    body: { types: ['MemoriesV1', 'SharedSpacesV1'] },
    auth,
    raw: true,
  });
  const rows = bytes
    .toString()
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  assert.ok(
    rows.some((row) => row.type === 'SyncCompleteV1'),
    'Sync stream must complete without a reset',
  );
  return rows;
}

async function acknowledge(auth, rows) {
  const acks = [
    ...new Map(rows.filter((row) => typeof row.ack === 'string').map((row) => [row.type, row.ack])).values(),
  ];
  if (acks.length > 0) await api('sync/ack', { method: 'POST', auth, status: 204, body: { acks } });
}

async function closeApp() {
  const closing = app;
  const closingDatabase = databaseRepository;
  const closingRedis = websocketRedisClients;
  app = undefined;
  databaseRepository = undefined;
  websocketRedisClients = [];
  try {
    await closing?.close();
  } finally {
    try {
      // Be explicit in this standalone two-instance harness: shutdown owns the
      // Kysely/Postgres pool, independently of Nest's application lifecycle.
      await closingDatabase?.shutdown();
    } finally {
      await Promise.all(
        closingRedis.filter((connection) => connection?.status !== 'end').map((connection) => connection.quit()),
      );
    }
  }
}

try {
  await client.connect();
  const table = await client.query("SELECT to_regclass('public.user') AS name");
  assert.equal(table.rows[0].name, null, 'Refusing an initialized database; create a fresh disposable database first');
  // ApiModule captures validated environment when imported: set it first.
  const [
    { configureExpress },
    { ApiService },
    { WebsocketRepository },
    { MemoryService },
    { MemoryRepository },
    { DatabaseRepository },
    { AssetRepository },
    { MetadataService },
    { MediaService },
    { JobStatus },
  ] = await Promise.all([
    import('../dist/app.common.js'),
    import('../dist/services/api.service.js'),
    import('../dist/repositories/websocket.repository.js'),
    import('../dist/services/memory.service.js'),
    import('../dist/repositories/memory.repository.js'),
    import('../dist/repositories/database.repository.js'),
    import('../dist/repositories/asset.repository.js'),
    import('../dist/services/metadata.service.js'),
    import('../dist/services/media.service.js'),
    import('../dist/enum.js'),
  ]);
  async function startApp() {
    // app.module creates its Postgres dialect at module evaluation. Reusing that
    // ended postgres.js instance for a second Nest application can reopen
    // sockets which its already-resolved end() no longer closes. Production
    // restart loads a fresh module/process; reproduce that ownership here.
    const { ApiModule } = await import(`../dist/app.module.js?memoryTestInstance=${randomUUID()}`);
    app = await NestFactory.create(ApiModule, {
      bufferLogs: true,
      routeConflictPolicy: { duplicate: 'error' },
      routeResolutionStrategy: 'specificity',
      abortOnError: false,
    });
    databaseRepository = app.get(DatabaseRepository);
    await configureExpress(app, { ssr: ApiService, permitSwaggerWrite: false });
    const adapter = app.get(WebsocketRepository).server.of('/').adapter;
    websocketRedisClients = [adapter.pubClient, adapter.subClient];
    base = new URL('/api/', await app.getUrl());
  }
  await startApp();
  const credentials = {
    email: 'synthetic-memory-owner@example.invalid',
    password: randomUUID(),
    name: 'Synthetic owner',
  };
  const owner = await api('auth/admin-sign-up', { method: 'POST', body: credentials });
  token = (await api('auth/login', { method: 'POST', body: credentials })).accessToken;
  // Distinct sessions exercise server state as two devices would see it.
  const secondToken = (await api('auth/login', { method: 'POST', body: credentials })).accessToken;
  const unrelated = {
    email: 'synthetic-memory-unrelated@example.invalid',
    password: randomUUID(),
    name: 'Unrelated user',
  };
  await api('admin/users', { method: 'POST', body: unrelated });
  const unrelatedToken = (await api('auth/login', { method: 'POST', body: unrelated })).accessToken;
  // These synthetic secrets stay only in this process, never in reports/files.
  const generatorKey = (
    await api('api-keys', {
      method: 'POST',
      body: { name: 'Synthetic external generator', permissions: ['memory.read', 'memory.create', 'memory.update'] },
    })
  ).secret;
  const unrelatedKey = (
    await api('api-keys', {
      method: 'POST',
      auth: unrelatedToken,
      body: { name: 'Synthetic unrelated owner', permissions: ['memory.read'] },
    })
  ).secret;
  const insufficientKey = (
    await api('api-keys', { method: 'POST', body: { name: 'Synthetic asset reader', permissions: ['asset.read'] } })
  ).secret;

  await check('real fresh API startup, all migrations and no schema drift', async () => {
    assert.deepEqual(await api('server/ping'), { res: 'pong' });
    assert.ok((await client.query('SELECT count(*)::int AS count FROM kysely_migrations')).rows[0].count > 0);
    assert.equal((await app.get(DatabaseRepository).getSchemaDrift()).items.length, 0);
  });

  const ordinaryHideId = await upload(0, onThisDayDate);
  // Standard anniversary generation selects previewable, metadata-processed
  // assets. Use the real handlers rather than inserting artificial job rows.
  await app.get(MetadataService).handleMetadataExtraction({ id: ordinaryHideId });
  assert.equal(await app.get(MediaService).handleGenerateThumbnails({ id: ordinaryHideId }), JobStatus.Success);
  const ordinaryDeleteId = await upload(1);
  for (let index = 2; index < 16; index++) await upload(index);
  const videoPath = join(directory, 'synthetic-memory-video.mp4');
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
  const videoId = await uploadBytes(await readFile(videoPath), 'synthetic-memory-video.mp4');
  const hideIds = [...assets.slice(2, 6).map((asset) => asset.id), videoId];
  const deleteIds = assets.slice(7, 12).map((asset) => asset.id);
  const ordinaryHide = await api('memories', {
    method: 'POST',
    body: memoryBody([ordinaryHideId], { date: onThisDayDate }),
  });
  const ordinaryDelete = await api('memories', { method: 'POST', body: memoryBody([ordinaryDeleteId, videoId]) });
  const aiHideBody = memoryBody(hideIds, { ai: true });
  const aiDeleteBody = memoryBody(deleteIds, { ai: true });
  const aiHide = await api('memories', { method: 'POST', body: aiHideBody });
  const aiDelete = await api('memories', { method: 'POST', body: aiDeleteBody });
  await check(
    'owner API keys read complete mixed-media lifecycle snapshots without exposing other owners',
    async () => {
      const rows = await snapshot('memories/lifecycle', generatorKey);
      assert.equal(rows.length, 4);
      const row = rows.find((item) => item.id === aiHide.id);
      assert.deepEqual(row.data, aiHideBody.data);
      assert.deepEqual(new Set(row.assetIds), new Set(hideIds));
      assert.equal(row.fingerprint, digest(Buffer.from([...new Set(hideIds)].sort().join(','))));
      assert.ok(aiHide.assets.some((asset) => asset.type === 'VIDEO'));
      assert.ok(aiHide.assets.some((asset) => asset.type === 'IMAGE'));
      assert.deepEqual(await snapshot('memories/lifecycle', unrelatedKey), []);
      assert.deepEqual(await snapshot('memories/rejections', unrelatedKey), []);
      await api('memories/lifecycle', { auth: null, status: 401 });
      await api('memories/rejections', { apiKey: insufficientKey, status: 403 });
    },
  );

  await check('viewed and saved are independent positive signals and updates preserve external metadata', async () => {
    const seenAt = today.plus({ hours: 12 }).toISO();
    const viewed = await api(`memories/${aiHide.id}`, {
      method: 'PUT',
      apiKey: generatorKey,
      body: { seenAt },
    });
    assert.equal(viewed.seenAt, seenAt);
    assert.equal(viewed.isSaved, false);
    assert.deepEqual(viewed.data, aiHideBody.data);
    const saved = await api(`memories/${aiHide.id}`, {
      method: 'PATCH',
      apiKey: generatorKey,
      body: { isSaved: true, title: 'Edited display title' },
    });
    assert.equal(saved.isSaved, true);
    assert.equal(saved.seenAt, seenAt);
    assert.deepEqual(saved.data, { ...aiHideBody.data, title: 'Edited display title' });
    aiHideBody.data.title = 'Edited display title';
    assert.deepEqual(await snapshot('memories/rejections', generatorKey), []);
  });

  await check('internal retention disappearance creates no user rejection', async () => {
    const body = memoryBody([assets[6].id], { ai: true });
    body.showAt = today.minus({ days: 10 }).toISO();
    const expired = await api('memories', { method: 'POST', apiKey: generatorKey, body });
    await app.get(MemoryRepository).cleanup(1);
    await api(`memories/${expired.id}`, { apiKey: generatorKey, status: 400 });
    assert.deepEqual(await snapshot('memories/rejections', generatorKey), []);
    assert.ok((await snapshot('memories/lifecycle', generatorKey)).some((row) => row.id === aiHide.id && row.isSaved));
  });
  const initialSync = await sync(secondToken);
  await check('ordinary two-years-ago and AI memories are visible to both owner sessions', async () => {
    assert.equal(ordinaryHide.data.year, today.year - 2);
    for (const memory of [ordinaryHide, ordinaryDelete, aiHide, aiDelete]) {
      assert.equal((await api(`memories/${memory.id}`, { auth: secondToken })).ownerId, owner.id);
      assert.ok(initialSync.some((row) => row.type === 'MemoryV1' && row.data.id === memory.id));
    }
    assert.equal((await api('memories/statistics')).total, 4);
  });
  await acknowledge(secondToken, initialSync);

  await check('unauthenticated and unrelated users cannot hide or delete owner memories', async () => {
    await api(`memories/${ordinaryHide.id}`, { method: 'PUT', body: { isHidden: true }, auth: null, status: 401 });
    await api(`memories/${ordinaryHide.id}`, {
      method: 'PUT',
      body: { isHidden: true },
      auth: unrelatedToken,
      status: 400,
    });
    await api(`memories/${aiDelete.id}`, { method: 'DELETE', auth: unrelatedToken, status: 400 });
    assert.equal((await api('memories/statistics')).total, 4);
  });

  await check(
    'ordinary memory hide is durable soft deletion and immediately leaves list, lane and statistics',
    async () => {
      const hidden = await api(`memories/${ordinaryHide.id}`, { method: 'PUT', body: { isHidden: true } });
      assert.ok(hidden.deletedAt);
      assert.equal(hidden.assets[0].id, ordinaryHideId);
      await api(`memories/${ordinaryHide.id}`, { auth: secondToken, status: 400 });
      assert.ok(!(await api('memories')).some((memory) => memory.id === ordinaryHide.id));
      assert.ok(
        !(await api(`memories?for=${today.toISODate()}`, { auth: secondToken })).some(
          (memory) => memory.id === ordinaryHide.id,
        ),
      );
      assert.equal((await api('memories/statistics', { auth: secondToken })).total, 3);
      const stored = await client.query('SELECT "deletedAt" FROM memory WHERE id=$1', [ordinaryHide.id]);
      assert.ok(stored.rows[0].deletedAt);
    },
  );

  await check('ordinary memory DELETE removes only the memory and its links', async () => {
    await api(`memories/${ordinaryDelete.id}`, { method: 'DELETE', status: 204 });
    await api(`memories/${ordinaryDelete.id}`, { status: 400 });
    assert.equal(
      (await client.query('SELECT count(*)::int AS count FROM memory WHERE id=$1', [ordinaryDelete.id])).rows[0].count,
      0,
    );
    assert.equal(
      (await client.query('SELECT count(*)::int AS count FROM memory_asset WHERE "memoriesId"=$1', [ordinaryDelete.id]))
        .rows[0].count,
      0,
    );
    assert.equal((await api(`assets/${ordinaryDeleteId}`)).id, ordinaryDeleteId);
    assert.equal((await api(`assets/${videoId}`)).type, 'VIDEO');
  });

  await check('AI highlight hide and DELETE persist dismissed fingerprints in existing candidate history', async () => {
    // Older decision/display writes could concatenate an encoded JSON string
    // into an array. An existing AI title must survive normalization and hide.
    await client.query('UPDATE memory SET data=jsonb_build_array(data, to_jsonb($2::text)) WHERE id=$1', [
      aiHide.id,
      JSON.stringify({ candidateState: 'saved' }),
    ]);
    const hidden = await api(`memories/${aiHide.id}`, { method: 'PATCH', body: { isHidden: true } });
    assert.equal(hidden.title, aiHideBody.data.title);
    assert.equal(hidden.data.ruleId, 'gallery_ai_highlight');
    assert.ok(!Array.isArray(hidden.data));
    await api(`memories/${aiDelete.id}`, { method: 'DELETE', status: 204 });
    assert.deepEqual(await api('memories', { auth: secondToken }), []);
    assert.equal((await api('memories/statistics')).total, 0);
    const history = await client.query(
      'SELECT state, "assetIds", "memoryId" FROM memory_candidate WHERE "ownerId"=$1',
      [owner.id],
    );
    assert.equal(history.rows.length, 4);
    assert.ok(history.rows.every((row) => row.state === 'dismissed'));
    assert.ok(
      history.rows.every((row) => Array.isArray(row.assetIds)),
      'New rejection history must store JSON arrays, not encoded JSON strings',
    );
    assert.ok(history.rows.some((row) => row.memoryId === null && row.assetIds.includes(deleteIds[0])));
  });

  await check(
    'rejection snapshot survives hard deletion and correlates through canonical owner fingerprints',
    async () => {
      const rejected = await snapshot('memories/rejections', generatorKey);
      assert.equal(rejected.length, 4);
      const aiRejection = rejected.find(
        (row) => row.fingerprint === digest(Buffer.from([...deleteIds].sort().join(','))),
      );
      assert.equal(aiRejection.state, 'dismissed');
      assert.equal(aiRejection.memoryId, null);
      assert.deepEqual(new Set(aiRejection.assetIds), new Set(deleteIds));
      assert.deepEqual(await snapshot('memories/rejections', unrelatedKey), []);
    },
  );

  await check('existing sync delivers soft-delete updates and hard-delete tombstones to another session', async () => {
    const rows = await sync(secondToken);
    for (const memory of [ordinaryHide, aiHide]) {
      assert.ok(rows.some((row) => row.type === 'MemoryV1' && row.data.id === memory.id && row.data.deletedAt));
    }
    for (const memory of [ordinaryDelete, aiDelete]) {
      assert.ok(rows.some((row) => row.type === 'MemoryDeleteV1' && row.data.memoryId === memory.id));
    }
    await acknowledge(secondToken, rows);
    assert.ok(!(await sync(unrelatedToken)).some((row) => row.type === 'MemoryV1' || row.type === 'MemoryDeleteV1'));
  });

  await check('production-style POST refuses identical, reordered and Jaccard 0.8 AI recreation', async () => {
    for (const body of [aiHideBody, aiDeleteBody]) {
      const suppressed = await api('memories', { method: 'POST', apiKey: generatorKey, body, status: 409 });
      assert.equal(suppressed.code, 'MEMORY_SUPPRESSED');
      await api('memories', { method: 'POST', body: { ...body, assetIds: [...body.assetIds].reverse() }, status: 409 });
      await api('memories', {
        method: 'POST',
        body: {
          ...body,
          memoryAt: '2022-02-01T00:00:00.000Z',
          data: { ...body.data, title: 'Changed AI title', dedupeKey: randomUUID() },
        },
        status: 409,
      });
      // Four of five assets produce exactly 0.8 intersection-over-union.
      await api('memories', { method: 'POST', body: { ...body, assetIds: body.assetIds.slice(0, 4) }, status: 409 });
      await api('memories/candidates', { method: 'POST', body, status: 409 });
    }
  });

  await check(
    'legacy double-encoded JSONB rejection history still blocks direct and candidate recreation',
    async () => {
      // Old fork builds could store assetIds as a JSONB string. Reproduce one such
      // row deliberately; compatibility must not require a production migration.
      const legacy = await client.query(
        'UPDATE memory_candidate SET "assetIds" = to_jsonb("assetIds"::text) WHERE "ownerId"=$1 AND "assetIds" @> $2::jsonb',
        [owner.id, JSON.stringify(deleteIds)],
      );
      assert.equal(legacy.rowCount, 1, 'The legacy compatibility assertion must operate on an actual stored rejection');
      await api('memories', { method: 'POST', body: aiDeleteBody, status: 409 });
      await api('memories/candidates', { method: 'POST', body: aiDeleteBody, status: 409 });
    },
  );

  await check('real on-this-day generation respects the hidden two-years-ago choice', async () => {
    // This is the actual scheduled creation implementation with real repositories;
    // the unrelated nightly ML/rule evaluators are deliberately not executed.
    const anniversaries = await app.get(AssetRepository).getByDayOfYear([owner.id], today);
    const sourceYear = anniversaries.find((group) => group.year === today.year - 2);
    assert.ok(
      sourceYear && sourceYear.assets.some((asset) => asset.id === ordinaryHideId),
      'The actual generator input must contain the original anniversary asset',
    );
    await app.get(MemoryService).createOnThisDayMemories(owner.id, today);
    const rows = await client.query('SELECT id FROM memory WHERE "ownerId"=$1 AND "deletedAt" IS NULL AND type=$2', [
      owner.id,
      'on_this_day',
    ]);
    assert.equal(rows.rows.length, 0);
  });

  await check('candidate dismissal itself is enforced by both candidate and direct memory POST', async () => {
    const body = memoryBody(
      assets.slice(12, 14).map((asset) => asset.id),
      { ai: true },
    );
    const candidate = await api('memories/candidates', { method: 'POST', body });
    assert.equal(candidate.state, 'pending');
    await api(`memories/candidates/${candidate.id}/decision`, { method: 'POST', body: { action: 'dismiss' } });
    await api('memories', { method: 'POST', body, status: 409 });
    await api('memories/candidates', { method: 'POST', body, status: 409 });
    assert.deepEqual(await api('memories/candidates'), []);
  });

  await check('manual hide overrides a previously saved AI candidate and blocks a late Save decision', async () => {
    const body = memoryBody(
      assets.slice(14, 16).map((asset) => asset.id),
      { ai: true },
    );
    const candidate = await api('memories/candidates', { method: 'POST', body });
    await api(`memories/candidates/${candidate.id}/decision`, { method: 'POST', body: { action: 'save' } });
    const savedMemory = await api(`memories/${candidate.memory.id}`);
    assert.ok(!Array.isArray(savedMemory.data));
    assert.equal(savedMemory.data.title, body.data.title);
    assert.equal(savedMemory.data.candidateState, 'saved');
    assert.ok((await api('memories')).some((memory) => memory.id === candidate.memory.id));
    await api(`memories/${candidate.memory.id}`, { method: 'PUT', body: { isHidden: true } });
    await api(`memories/candidates/${candidate.id}/decision`, {
      method: 'POST',
      body: { action: 'save' },
      status: 409,
    });
    await api('memories', { method: 'POST', body, status: 409 });
    assert.deepEqual(await api('memories', { auth: secondToken }), []);
    assert.equal(
      (await client.query('SELECT state FROM memory_candidate WHERE id=$1', [candidate.id])).rows[0].state,
      'dismissed',
    );
  });

  await check('every original asset survives all hide/delete/dismiss and failed recreation operations', async () => {
    assert.equal((await client.query('SELECT count(*)::int AS count FROM asset')).rows[0].count, assets.length);
    for (const asset of assets) {
      assert.equal((await api(`assets/${asset.id}`)).id, asset.id);
      assert.equal(digest(await api(`assets/${asset.id}/original?edited=false`, { raw: true })), asset.hash);
    }
    assert.equal(
      (await client.query('SELECT count(*)::int AS count FROM asset WHERE "deletedAt" IS NOT NULL')).rows[0].count,
      0,
    );
  });

  await closeApp();
  await startApp();
  await check(
    'server restart preserves hidden state and suppression for existing and fresh owner sessions',
    async () => {
      assert.deepEqual(await api('memories', { auth: secondToken }), []);
      const freshToken = (await api('auth/login', { method: 'POST', body: credentials })).accessToken;
      assert.deepEqual(await api('memories', { auth: freshToken }), []);
      assert.equal((await api('memories/statistics', { auth: freshToken })).total, 0);
      await api('memories', { method: 'POST', body: aiDeleteBody, auth: freshToken, status: 409 });
      await api('memories/candidates', { method: 'POST', body: aiHideBody, auth: freshToken, status: 409 });
      assert.equal((await snapshot('memories/rejections', generatorKey)).length, 6);
      assert.deepEqual(await snapshot('memories/rejections', unrelatedKey), []);
      await app.get(MemoryService).createOnThisDayMemories(owner.id, today);
      assert.deepEqual(await api('memories', { auth: freshToken }), []);
      assert.equal((await app.get(DatabaseRepository).getSchemaDrift()).items.length, 0);
    },
  );
  console.log(`PASS all ${checks} real HTTP / database / sync / filesystem contracts`);
} finally {
  const failures = [];
  for (const operation of [
    () => closeApp(),
    () => exiftool.end(),
    () => client.end(),
    () => rm(directory, { recursive: true, force: true }),
  ]) {
    try {
      await operation();
    } catch (error) {
      failures.push(error);
    }
  }
  if (failures.length > 0) throw new AggregateError(failures, 'Test lifecycle cleanup failed');
}
