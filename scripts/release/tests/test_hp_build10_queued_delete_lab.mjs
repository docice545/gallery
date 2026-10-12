// Disposable local PostgreSQL/Redis + real native repositories/handler/quarantine.
// No production endpoints, application bootstrap, schema migrations or images built.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { createRequire } from 'node:module';
import { randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { join } from 'node:path';
import { IDS, digest } from '../hp_build10_queued_delete.mjs';

test('six real upload cleanup jobs: read-only SQL guards, native physical deletion, ACK and 21 unchanged paused jobs', {
  skip: process.env.GALLERY_NATIVE_QUEUED_LAB !== 'YES', timeout: 60_000,
}, async t => {
  const server = fileURLToPath(new URL('../../../server', import.meta.url));
  const require = createRequire(server + '/package.json');
  const { Queue } = require('bullmq');
  const postgres = require('postgres');
  const env = { ...process.env };
  for (const key of ['DOCKER_HOST', 'DOCKER_CONTEXT', 'DOCKER_TLS', 'DOCKER_TLS_VERIFY', 'DOCKER_CERT_PATH']) delete env[key];
  const docker = (...args) => execFileSync('docker', ['--host=unix:///var/run/docker.sock', ...args], {
    env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 30_000,
  }).trim();
  const name = 'gallery-upload-fixture-' + randomUUID();
  const label = 'gallery.queued-upload.fixture=' + name;
  const containers = [];
  t.after(() => {
    for (const id of containers.reverse()) {
      const [item] = JSON.parse(docker('inspect', id));
      assert.equal(item.Config.Labels['gallery.queued-upload.fixture'], name);
      docker('rm', '-f', id); // Only these two labelled, disposable fixture IDs.
    }
  });
  const pg = docker('run', '-d', '--pull', 'never', '--label', label, '--name', name+'-pg',
    '--memory', '512m', '--cpus', '1', '--pids-limit', '128', '--tmpfs', '/labdata:rw,size=256m',
    '-p', '127.0.0.1::5432', '-e', 'PGDATA=/labdata', '-e', 'POSTGRES_DB=fixture',
    '-e', 'POSTGRES_PASSWORD=disposable-fixture-only', 'postgres:16-alpine');
  containers.push(pg);
  const redis = docker('run', '-d', '--pull', 'never', '--label', label, '--name', name+'-redis',
    '--memory', '96m', '--cpus', '0.5', '--pids-limit', '64', '-p', '127.0.0.1::6379',
    'redis:7-alpine', 'redis-server', '--save', '', '--appendonly', 'no');
  containers.push(redis);
  const port = (id, key) => JSON.parse(docker('inspect', id))[0].NetworkSettings.Ports[key][0].HostPort;
  const pgPort = port(pg, '5432/tcp'), redisPort = Number(port(redis, '6379/tcp'));
  const db = postgres({ host: '127.0.0.1', port: Number(pgPort), database: 'fixture', username: 'postgres',
    password: 'disposable-fixture-only', max: 1 });
  t.after(() => db.end({ timeout: 2 }));
  let ready = false;
  for (let attempt = 0; attempt < 20; attempt++) {
    try { await db`SELECT 1`; ready = true; break; } catch { await new Promise(r => setTimeout(r, 150)); }
  }
  assert.equal(ready, true, 'local disposable PostgreSQL must start');
  await db.unsafe(`
    CREATE TABLE "user" (id uuid PRIMARY KEY, "deletedAt" timestamptz, "profileImagePath" text);
    CREATE TABLE asset (id uuid PRIMARY KEY, "originalPath" text);
    CREATE TABLE asset_file ("assetId" uuid, path text);
    CREATE TABLE library (id uuid PRIMARY KEY, "importPaths" text[]);
    CREATE TABLE asset_deletion_tombstone ("assetId" uuid PRIMARY KEY, "originalPath" text, aliases jsonb, files jsonb);
  `);
  const owner = '11111111-1111-4111-8111-111111111111';
  await db`INSERT INTO "user" VALUES (${owner}, NULL, NULL)`;
  const media = await fs.mkdtemp(join(tmpdir(), 'gallery-upload-lab-'));
  t.after(() => fs.rm(media, { recursive: true, force: true }));
  for (const path of ['thumbs', 'encoded-video', 'profile', 'library', 'upload/'+owner,
    'upload/22222222-2222-4222-8222-222222222222']) await fs.mkdir(join(media, path), { recursive: true });
  const files = IDS.map(id => join(media, 'upload', owner, 'fixture-'+id+'.jpg'));
  for (const file of files) await fs.writeFile(file, 'synthetic photo bytes');
  // Native deployment paths are relocated ONLY in this lab copy, never in the operator script.
  const previous = {};
  const settings = { IMMICH_MEDIA_LOCATION: media, DB_URL: `postgres://postgres:disposable-fixture-only@127.0.0.1:${pgPort}/fixture`,
    REDIS_HOSTNAME: '127.0.0.1', REDIS_PORT: String(redisPort), REDIS_DBINDEX: '0', REDIS_URL: '',
    REDIS_SOCKET: '', REDIS_USERNAME: '', REDIS_PASSWORD: '', IMMICH_STORAGE_BACKEND: 'disk', IMMICH_S3_BUCKET: '' };
  for (const [key, value] of Object.entries(settings)) { previous[key] = process.env[key]; process.env[key] = value; }
  t.after(() => { for (const [key, value] of Object.entries(previous)) {
    if (value === undefined) delete process.env[key]; else process.env[key] = value;
  } });
  const program = (await fs.readFile(new URL('../hp_build10_queued_delete.mjs', import.meta.url), 'utf8'))
    .replaceAll('/usr/src/app/server', server);
  const fixtureProgram = join(media, 'relocated-operator-fixture.mjs');
  await fs.writeFile(fixtureProgram, program, { mode: 0o600 });
  const { execute } = await import(pathToFileURL(fixtureProgram));
  const { ConfigRepository } = await import(pathToFileURL(server+'/dist/repositories/config.repository.js'));
  const queue = new Queue('backgroundTask', new ConfigRepository().getEnv().bull.config);
  t.after(() => queue.close());
  await queue.pause();
  const client = await queue.client;
  for (const [i, id] of IDS.entries()) {
    // Reproduce native auto-increment numeric IDs; BullMQ forbids custom integer IDs.
    await client.set(queue.toKey('id'), String(Number(id)-1));
    assert.equal((await queue.add('FileDelete', { files: [files[i]], temporaryOwnerId: owner },
      { removeOnComplete: true })).id, id);
  }
  await client.set(queue.toKey('id'), '999');
  for (let i = 0; i < 21; i++) await queue.add(i % 2 ? 'MemoryGenerate' : 'SessionCleanup', { fixture: i },
    { removeOnComplete: true });
  const snapshot = await execute({ action: 'inventory' });
  const values = { snapshot, snapshotSeal: digest(snapshot) };
  assert.equal((await execute({ action: 'admit', ...values })).retained, 21);
  const asset = randomUUID();
  await db`INSERT INTO asset VALUES (${asset}, ${files[0]})`;
  await assert.rejects(execute({ action: 'intent', ...values }), /SHARED_OR_LIVE_FILE_PROTECTED/);
  await db`DELETE FROM asset WHERE id=${asset}`;
  await db`INSERT INTO asset_deletion_tombstone VALUES (${asset}, '/another/original', ${JSON.stringify([files[0]])}::jsonb, '[]'::jsonb)`;
  await assert.rejects(execute({ action: 'intent', ...values }), /UPLOAD_HAS_ASSET_DELETION_INTENT/);
  await db`DELETE FROM asset_deletion_tombstone WHERE "assetId"=${asset}`;
  const intent = await execute({ action: 'intent', ...values });
  const approval = { intent, intentSeal: digest(intent) };
  const proof = await execute({ action: 'prepare', ...values, ...approval });
  await fs.writeFile(join(media, 'private-file-proofs.json'), JSON.stringify(proof), { mode: 0o600 });
  // A reference appearing AFTER preparation must still stop the handler and ACK.
  await db`INSERT INTO asset VALUES (${asset}, ${files[0]})`;
  const stopped = await execute({ action: 'execute', ...values, ...approval, proof });
  assert.equal(stopped.completed, false); assert.equal(stopped.failedJob, IDS[0]);
  // Redis paused-list order is newest first: the five later IDs succeed first.
  // The failed job is retained; successful physical work is reported, never erased.
  assert.equal(stopped.records.length, 5);
  const partial = await execute({ action: 'inventory' });
  assert.equal(partial.counts.paused, 22);
  assert.deepEqual(partial.jobs.filter(j => !IDS.includes(j.id)), snapshot.jobs.filter(j => !IDS.includes(j.id)));
  assert.equal(await fs.readFile(files[0], 'utf8'), 'synthetic photo bytes');
  for (const file of files.slice(1)) await assert.rejects(fs.lstat(file), { code: 'ENOENT' });
  await db`DELETE FROM asset WHERE id=${asset}`;
  const result = await execute({ action: 'execute', ...values, ...approval, proof });
  assert.equal(result.completed, true); assert.equal(result.records.length, 6);
  assert.equal([...stopped.records, ...result.records].reduce((n, r) => n + (r.confirmedUploadCleanupFilesRemoved ?? 0), 0), 6);
  for (const file of files) await assert.rejects(fs.lstat(file), { code: 'ENOENT' });
  assert.equal((await execute({ action: 'gate', ...values, ...approval, proof })).preserved, 21);
  const after = await execute({ action: 'inventory' });
  assert.deepEqual(after.jobs, snapshot.jobs.filter(j => !IDS.includes(j.id)));
  assert.equal(after.paused, true); assert.equal(after.counts.paused, 21); assert.equal(after.deletionHashes, 0);
  assert.equal((await db`SELECT count(*) AS n FROM asset`)[0].n, '0');
  assert.equal((await db`SELECT count(*) AS n FROM asset_deletion_tombstone`)[0].n, '0');
  const resumed = await execute({ action: 'execute', ...values, ...approval, proof });
  assert.equal(resumed.completed, true); assert.equal(resumed.records.length, 6);
  assert.ok(resumed.records.every(r => r.verifiedAbsentAfterPriorAttempt === true));
});
