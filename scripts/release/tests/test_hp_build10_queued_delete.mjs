import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { IDS, admit, retainedOnly, finishJob, digest, fileScope, verifyCleanupIntent, backingIdentity } from '../hp_build10_queued_delete.mjs';

const ownerId = '11111111-1111-4111-8111-111111111111';
const upload = '/data/upload/' + ownerId;

test('helper bind namespace preserves the exact NFS backing coordinate', () => {
  const production = { path: upload, device: '1', inode: '2', mountType: 'nfs', mountSource: '10.10.10.95:/volume1/Immich',
    mountRoot: '/', mountTarget: '/data', mountId: '10', mountNamespace: 'production' };
  const helper = { ...production, mountRoot: '/upload/'+ownerId, mountTarget: upload,
    mountId: '20', mountNamespace: 'helper' };
  assert.deepEqual(backingIdentity(production), backingIdentity(helper));
  for (const change of [{ mountSource: '10.10.10.95:/volume1/another' }, { mountRoot: '/different' },
    { mountType: 'nfs4' }, { device: 'changed' }, { inode: 'changed' }]) {
    assert.notDeepEqual(backingIdentity(production), backingIdentity({ ...helper, ...change }));
  }
});

function fixture() {
  const jobs = IDS.map(id => ({ id, name: 'FileDelete', data: { files: ['/data/thumbs/fixture-' + id] },
    opts: { removeOnComplete: true }, hash: id.padStart(64, '0') }));
  for (let i = 0; i < 21; i++) jobs.push({ id: String(1000 + i), name: i % 2 ? 'MemoryGenerate' : 'SessionCleanup',
    data: {}, opts: {}, hash: String(i).padStart(64, '0') });
  return { paused: true, atomic: true, inventoryComplete: true, deletionHashes: 6,
    counts: { active: 0, wait: 0, paused: 27, delayed: 0, prioritized: 0, 'waiting-children': 0, failed: 0 },
    knownBackgroundJobs: ['FileDelete', 'MemoryGenerate', 'SessionCleanup', 'AssetDelete'], jobs };
}
test('admission identifies six jobs and retains all 21 ordinary/Memories jobs unchanged', () => {
  const row = fixture(), before = digest(row);
  assert.equal(admit(row).length, 21); assert.equal(digest(row), before);
});
test('admits the actual six temporaryOwnerId payloads without rewriting any job', () => {
  const row = fixture();
  for (const job of row.jobs.slice(0, 6)) job.data = { files: [upload + '/fixture-' + job.id + '.jpg'], temporaryOwnerId: ownerId };
  const before = digest(row);
  assert.equal(admit(row).length, 21);
  assert.equal(digest(row), before);
  for (const job of row.jobs.slice(0, 6)) assert.deepEqual(fileScope(job, job.data.files[0], '/data', ['/data/thumbs']), {
    jobId: job.id, jobHash: job.hash, file: job.data.files[0], path: job.data.files[0], root: upload,
    kind: 'temporary-upload', ownerId,
  });
});
for (const [name, file, suppliedOwner] of [
  ['bare managed original', '/data/upload/'+ownerId+'/file.jpg', undefined],
  ['another owner', '/data/upload/22222222-2222-4222-8222-222222222222/file.jpg', ownerId],
  ['prefix sibling', upload+'-other/file.jpg', ownerId],
  ['managed library', '/data/library/'+ownerId+'/file.jpg', ownerId],
  ['external NAS', '/external/file.jpg', ownerId],
  ['traversal', upload+'/../another/file.jpg', ownerId],
  ['relative traversal', '../data/upload/'+ownerId+'/file.jpg', ownerId],
  ['quarantine entry', upload+'/.gallery-deletion-quarantine/file.jpg', ownerId],
]) test('does not manufacture cleanup permission for ' + name, () => {
  const job = { id: IDS[0], hash: 'sealed', data: { files: [file], ...(suppliedOwner ? { temporaryOwnerId: suppliedOwner } : {}) } };
  assert.throws(() => fileScope(job, file, '/data', ['/data/thumbs']));
});
const cleanupSpec = { jobId: IDS[0], file: upload+'/file.jpg', path: upload+'/file.jpg', root: upload,
  kind: 'temporary-upload', ownerId };
const intentChecks = () => ({ referenced: async () => false, tombstone: async () => false,
  owner: async () => ({ id: ownerId, deletedAt: null }) });
test('verified active owner + real cleanup marker + no references admits confirmed upload cleanup', async () => {
  await verifyCleanupIntent(cleanupSpec, intentChecks());
});
for (const [name, change] of [
  ['active/shared/Live asset reference', c => c.referenced = async () => true],
  ['unknown owner', c => c.owner = async () => undefined],
  ['other owner', c => c.owner = async () => ({ id: 'different', deletedAt: null })],
  ['deleted owner', c => c.owner = async () => ({ id: ownerId, deletedAt: new Date() })],
  ['original deletion tombstone', c => c.tombstone = async () => true],
]) test('cleanup intent rejects ' + name, async () => {
  const checks = intentChecks(); change(checks); await assert.rejects(verifyCleanupIntent(cleanupSpec, checks));
});
for (const [name, alter] of [
  ['unpaused', r => r.paused = false], ['active', r => r.counts.active = 1],
  ['failed', r => r.counts.failed = 1], ['missing job', r => r.jobs.pop()],
  ['unexpected ID', r => r.jobs[0].id = '999'], ['orphan deletion', r => r.deletionHashes++],
  ['another original deletion', r => r.jobs[6].name = 'AssetDelete'],
  ['unknown job', r => r.jobs[6].name = 'Unknown'], ['parent', r => r.jobs[0].parentKey = 'parent'],
  ['upload cleanup', r => r.jobs[0].data.temporaryOwnerId = 'owner'],
  ['extra upload intent fields', r => r.jobs[0].data = { files: ['anything'], temporaryOwnerId: ownerId, enabled: true }],
  ['empty file data', r => r.jobs[0].data.files = [null]],
  ['retained completion history', r => r.jobs[0].opts.removeOnComplete = false],
]) test('rejects ' + name + ' before execution', () => { const r = fixture(); alter(r); assert.throws(() => admit(r)); });
test('deployment admits ONLY exact preserved paused jobs, not SCAN-only zero', () => {
  const initial = fixture(), retained = admit(initial);
  const now = { ...initial, deletionHashes: 0, jobs: retained, counts: { ...initial.counts, paused: 21 } };
  retainedOnly(now, retained);
  for (const change of [r => r.paused = false, r => r.counts.active = 1,
    r => r.deletionHashes = 1, r => r.jobs[0].hash = 'changed', r => r.jobs.reverse()]) {
    const bad = structuredClone(now); change(bad); assert.throws(() => retainedOnly(bad, retained));
  }
});
test('acknowledges only after successful handler, both absences and safety recheck', async () => {
  const calls = [];
  await finishJob({ data: {} }, [{ path: '/fixture', root: '/root', quarantineName: 'nonce' }], {
    handler: async () => { calls.push('handler'); return 'success'; }, success: 'success',
    absent: async () => { calls.push('absent'); return true; },
    recheck: async () => calls.push('recheck'), acknowledge: async () => calls.push('ack'),
  });
  assert.deepEqual(calls, ['handler', 'absent', 'absent', 'recheck', 'ack']);
});
for (const outcome of ['failed', 'skipped', undefined, 'throw']) test('does not erase a job after handler ' + outcome, async () => {
  let acknowledged = false;
  await assert.rejects(finishJob({ data: {} }, [{ path: '/fixture' }], {
    handler: async () => { if (outcome === 'throw') throw Error('failure'); return outcome; }, success: 'success',
    absent: async () => true, recheck: async () => {}, acknowledge: async () => acknowledged = true,
  }));
  assert.equal(acknowledged, false);
});
for (const step of ['source', 'quarantine', 'recheck']) test('retains job when ' + step + ' verification fails', async () => {
  let acknowledged = false, call = 0;
  await assert.rejects(finishJob({ data: {} }, [{ path: '/fixture', root: '/root', quarantineName: 'nonce' }], {
    handler: async () => 'success', success: 'success',
    absent: async () => ++call !== (step === 'source' ? 1 : step === 'quarantine' ? 2 : -1),
    recheck: async () => { if (step === 'recheck') throw Error('changed'); }, acknowledge: async () => acknowledged = true,
  }));
  assert.equal(acknowledged, false);
});

// Real stock compiled handler + existing descriptor/quarantine primitives.
// Every file is synthetic under a new private /tmp directory; no database/network.
const native = process.env.GALLERY_NATIVE_DELETION_FIXTURES === 'YES';
async function nativeFixture(t, temporary = false) {
  const root = await fs.mkdtemp(join(tmpdir(), 'gallery-queued-native-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  await fs.mkdir(join(root, 'thumbs'));
  const admitted = temporary ? join(root, 'upload', ownerId) : join(root, 'thumbs');
  if (temporary) await fs.mkdir(admitted, { recursive: true });
  const secure = await import('../../../server/dist/utils/authorized-deletion.js');
  const { StorageRepository } = await import('../../../server/dist/repositories/storage.repository.js');
  const { StorageService } = await import('../../../server/dist/services/storage.service.js');
  const { StorageCore } = await import('../../../server/dist/cores/storage.core.js');
  const { JobStatus } = await import('../../../server/dist/enum.js');
  StorageCore.setMediaLocation(root);
  const quiet = { setContext() {}, warn() {} };
  const context = Object.create(StorageService.prototype);
  context.logger = quiet; context.assetRepository = { isOriginalReferenced: async () => false };
  context.storageRepository = new StorageRepository(quiet);
  const file = join(admitted, 'photo'); await fs.writeFile(file, 'synthetic derivative');
  const [identity] = await secure.collectRootIdentities([admitted]);
  const bound = await secure.bindQuarantine(identity);
  const proof = await secure.snapshotOriginal(file, [bound]);
  context.storageRepository.unlink = async () => secure.unlinkOriginal(proof);
  return { root, file, proof, context, secure, JobStatus };
}
test('native handler deletes fixture, then ack follows verified source and quarantine absence', { skip: !native }, async t => {
  const f = await nativeFixture(t); let ack = false;
  const absent = async p => { try { await fs.lstat(p); return false; } catch (e) { if (e.code === 'ENOENT') return true; throw e; } };
  await finishJob({ data: { files: [f.file] } }, [f.proof], { success: f.JobStatus.Success,
    handler: data => f.context.handleDeleteFiles(data), absent, recheck: async () => {}, acknowledge: async () => ack = true });
  assert.equal(ack, true); assert.equal(await absent(f.file), true);
});
test('native handler completes the real temporaryOwnerId upload contract then acknowledges', { skip: !native }, async t => {
  const f = await nativeFixture(t, true); let acknowledged = false;
  const absent = async p => { try { await fs.lstat(p); return false; } catch (e) { if (e.code === 'ENOENT') return true; throw e; } };
  await finishJob({ data: { files: [f.file], temporaryOwnerId: ownerId } }, [f.proof], {
    handler: data => f.context.handleDeleteFiles(data), success: f.JobStatus.Success, absent,
    recheck: async () => {}, acknowledge: async () => acknowledged = true,
  });
  assert.equal(acknowledged, true); assert.equal(await absent(f.file), true);
});
test('native temporary cleanup preserves another owner and shared original', { skip: !native }, async t => {
  const f = await nativeFixture(t, true);
  assert.equal(await f.context.handleDeleteFiles({ files: [f.file], temporaryOwnerId: '22222222-2222-4222-8222-222222222222' }), f.JobStatus.Failed);
  f.context.assetRepository.isOriginalReferenced = async () => true;
  assert.equal(await f.context.handleDeleteFiles({ files: [f.file], temporaryOwnerId: ownerId }), f.JobStatus.Failed);
  assert.equal(await fs.readFile(f.file, 'utf8'), 'synthetic derivative');
});
test('native temporary upload ancestor substitution cannot redirect deletion', { skip: !native }, async t => {
  const f = await nativeFixture(t, true), outside = join(f.root, 'outside'); await fs.mkdir(outside);
  await fs.writeFile(join(outside, 'photo'), 'outside must survive');
  const verify = f.context.storageRepository.verifyDisposablePath;
  f.context.storageRepository.verifyDisposablePath = async (...args) => {
    await verify(...args); await fs.rename(join(f.root, 'upload', ownerId), join(f.root, 'saved'));
    await fs.symlink(outside, join(f.root, 'upload', ownerId));
  };
  assert.equal(await f.context.handleDeleteFiles({ files: [f.file], temporaryOwnerId: ownerId }), f.JobStatus.Failed);
  assert.equal(await fs.readFile(join(outside, 'photo'), 'utf8'), 'outside must survive');
  assert.equal(await fs.readFile(join(f.root, 'saved', 'photo'), 'utf8'), 'synthetic derivative');
});
test('interrupted temporary upload capture is verified on retry before job acknowledgement', { skip: !native }, async t => {
  const f = await nativeFixture(t, true); let checks = 0, acknowledged = false;
  f.context.storageRepository.unlink = () => f.secure.unlinkOriginal(f.proof, async () => {
    if (++checks === 2) throw Error('interrupted');
  });
  const data = { files: [f.file], temporaryOwnerId: ownerId };
  assert.equal(await f.context.handleDeleteFiles(data), f.JobStatus.Failed);
  const captured = join(f.proof.root, '.gallery-deletion-quarantine', f.proof.quarantineName);
  assert.equal(await fs.readFile(captured, 'utf8'), 'synthetic derivative');
  f.context.storageRepository.unlink = () => f.secure.unlinkOriginal(f.proof);
  const absent = async p => { try { await fs.lstat(p); return false; } catch (e) { if (e.code === 'ENOENT') return true; throw e; } };
  await finishJob({ data }, [f.proof], { handler: d => f.context.handleDeleteFiles(d), success: f.JobStatus.Success,
    absent, recheck: async () => {}, acknowledge: async () => acknowledged = true });
  assert.equal(acknowledged, true); assert.equal(await absent(captured), true);
});
test('native handler refuses a legacy managed original', { skip: !native }, async t => {
  const f = await nativeFixture(t); await fs.mkdir(join(f.root, 'upload'));
  const original = join(f.root, 'upload', 'original'); await fs.writeFile(original, 'must survive');
  assert.equal(await f.context.handleDeleteFiles({ files: [original] }), f.JobStatus.Failed);
  assert.equal(await fs.readFile(original, 'utf8'), 'must survive');
});
test('native handler keeps a shared/live derivative', { skip: !native }, async t => {
  const f = await nativeFixture(t); f.context.assetRepository.isOriginalReferenced = async () => true;
  assert.equal(await f.context.handleDeleteFiles({ files: [f.file] }), f.JobStatus.Failed);
  assert.equal(await fs.readFile(f.file, 'utf8'), 'synthetic derivative');
});
test('native adapter blocks ancestor substitution after ordinary path verification', { skip: !native }, async t => {
  const f = await nativeFixture(t), outside = join(f.root, 'outside'); await fs.mkdir(outside);
  await fs.writeFile(join(outside, 'photo'), 'outside original');
  const verify = f.context.storageRepository.verifyDisposablePath;
  f.context.storageRepository.verifyDisposablePath = async (...args) => {
    await verify(...args); await fs.rename(join(f.root, 'thumbs'), join(f.root, 'saved'));
    await fs.symlink(outside, join(f.root, 'thumbs'));
  };
  assert.equal(await f.context.handleDeleteFiles({ files: [f.file] }), f.JobStatus.Failed);
  assert.equal(await fs.readFile(join(outside, 'photo'), 'utf8'), 'outside original');
  assert.equal(await fs.readFile(join(f.root, 'saved', 'photo'), 'utf8'), 'synthetic derivative');
});
test('interrupted native capture retains job/file and permits verified retry', { skip: !native }, async t => {
  const f = await nativeFixture(t); let checks = 0;
  f.context.storageRepository.unlink = () => f.secure.unlinkOriginal(f.proof, async () => {
    if (++checks === 2) throw Error('interrupted');
  });
  assert.equal(await f.context.handleDeleteFiles({ files: [f.file] }), f.JobStatus.Failed);
  const captured = join(f.proof.root, '.gallery-deletion-quarantine', f.proof.quarantineName);
  assert.equal(await fs.readFile(captured, 'utf8'), 'synthetic derivative');
  f.context.storageRepository.unlink = () => f.secure.unlinkOriginal(f.proof);
  assert.equal(await f.context.handleDeleteFiles({ files: [f.file] }), f.JobStatus.Success);
  await assert.rejects(fs.lstat(captured), { code: 'ENOENT' });
});
test('changed checksum is never acknowledged as native success', { skip: !native }, async t => {
  const f = await nativeFixture(t); await fs.writeFile(f.file, 'changed payload');
  assert.equal(await f.context.handleDeleteFiles({ files: [f.file] }), f.JobStatus.Failed);
  assert.equal(await fs.readFile(f.file, 'utf8'), 'changed payload');
});
