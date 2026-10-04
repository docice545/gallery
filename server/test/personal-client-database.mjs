// Focused real-PostgreSQL contracts. Uses an isolated schema in a loopback-only test DB.
// Build the server first. TEST_DATABASE_URL must point at a disposable local PostgreSQL.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { Kysely, PostgresDialect, sql } from 'kysely';
import pg from 'pg';
import { StackRepository } from '../dist/repositories/stack.repository.js';
import { MemoryRepository } from '../dist/repositories/memory.repository.js';
import { columns } from '../dist/database.js';
import * as suppressionMigration from '../dist/schema/migrations-gallery/1791070000000-AddStackSuppression.js';
import * as candidateMigration from '../dist/schema/migrations-gallery/1791071000000-AddMemoryCandidates.js';

const url = new URL(process.env.TEST_DATABASE_URL ?? '');
assert.ok(['localhost', '127.0.0.1'].includes(url.hostname), 'Only local test databases are allowed');
const schema = `personal_client_test_${randomUUID().replaceAll('-', '')}`;
const admin = new Kysely({ dialect: new PostgresDialect({ pool: new pg.Pool({ connectionString: url.href }) }) });
await sql.raw(`CREATE SCHEMA "${schema}"`).execute(admin);
const db = new Kysely({
  dialect: new PostgresDialect({
    pool: new pg.Pool({
      connectionString: url.href,
      options: `-c search_path=${schema},public`,
    }),
  }),
});
let passed = 0;
async function check(name, operation) {
  await operation();
  passed++;
  console.log(`PASS ${name}`);
}
try {
  await sql`CREATE TABLE "user" (id uuid PRIMARY KEY)`.execute(db);
  await sql`CREATE TABLE stack (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), "ownerId" uuid REFERENCES "user"(id),
    "primaryAssetId" uuid, "createdAt" timestamptz DEFAULT now(), "updatedAt" timestamptz DEFAULT now())`.execute(db);
  await sql`CREATE TABLE asset (id uuid PRIMARY KEY, "ownerId" uuid REFERENCES "user"(id),
    "stackId" uuid REFERENCES stack(id) ON DELETE SET NULL, "deletedAt" timestamptz,
    "updatedAt" timestamptz DEFAULT now(), "fileCreatedAt" timestamptz DEFAULT now(),
    "localDateTime" timestamp DEFAULT now(), visibility text DEFAULT 'timeline')`.execute(db);
  await sql`CREATE TABLE asset_exif ("assetId" uuid PRIMARY KEY REFERENCES asset(id))`.execute(db);
  for (const column of columns.exif.filter((column) => column !== 'asset_exif.assetId')) {
    await sql.raw(`ALTER TABLE asset_exif ADD COLUMN "${column.split('.')[1]}" text`).execute(db);
  }
  await sql`CREATE TABLE memory (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), "ownerId" uuid REFERENCES "user"(id),
    type text, data jsonb NOT NULL, "isSaved" boolean NOT NULL DEFAULT false, "memoryAt" timestamptz NOT NULL,
    "createdAt" timestamptz NOT NULL DEFAULT now(), "updatedAt" timestamptz NOT NULL DEFAULT now(),
    "deletedAt" timestamptz, "seenAt" timestamptz, "showAt" timestamptz, "hideAt" timestamptz)`.execute(db);
  await sql`CREATE TABLE memory_asset ("memoriesId" uuid REFERENCES memory(id) ON DELETE CASCADE,
    "assetId" uuid REFERENCES asset(id) ON DELETE CASCADE)`.execute(db);
  await check('both migrations apply', async () => {
    await suppressionMigration.up(db);
    await candidateMigration.up(db);
  });
  const ownerId = randomUUID();
  const otherId = randomUUID();
  await db
    .insertInto('user')
    .values([{ id: ownerId }, { id: otherId }])
    .execute();
  const assets = Array.from({ length: 8 }, () => randomUUID());
  await db
    .insertInto('asset')
    .values(assets.map((id) => ({ id, ownerId })))
    .execute();
  await db
    .insertInto('asset_exif')
    .values(assets.map((assetId) => ({ assetId })))
    .execute();
  const stacks = new StackRepository(db);
  await check('stack creation rejects foreign assets and expanded legacy foreign children', async () => {
    const foreignId = randomUUID();
    await db.insertInto('asset').values({ id: foreignId, ownerId: otherId }).execute();
    const legacy = await db
      .insertInto('stack')
      .values({ ownerId, primaryAssetId: assets[7] })
      .returning('id')
      .executeTakeFirstOrThrow();
    try {
      await assert.rejects(stacks.create({ ownerId }, [assets[0], foreignId]), /same owner/);
      await db.updateTable('asset').set({ stackId: legacy.id }).where('id', 'in', [assets[7], foreignId]).execute();
      await assert.rejects(stacks.create({ ownerId }, [assets[7], assets[6]]), /same owner/);
      const members = await db.selectFrom('asset').select('id').where('stackId', '=', legacy.id).execute();
      assert.equal(members.length, 2);
    } finally {
      await db.deleteFrom('stack').where('id', '=', legacy.id).execute();
      await db.deleteFrom('asset').where('id', '=', foreignId).execute();
    }
  });
  let stack = await stacks.create({ ownerId }, assets.slice(0, 3));
  await check('detach persists suppression without deleting the asset', async () => {
    await stacks.manuallyRemove(ownerId, stack.id, assets[1]);
    const row = await db.selectFrom('asset').selectAll().where('id', '=', assets[1]).executeTakeFirstOrThrow();
    assert.equal(row.stackId, null);
    assert.deepEqual(await stacks.getSuppressions(otherId, 1), []);
    assert.deepEqual(await stacks.getSuppressions(ownerId, 1), [{ assetId: assets[1] }]);
  });
  await check('automatic create rejects suppression but manual create remains allowed', async () => {
    await assert.rejects(stacks.create({ ownerId }, assets.slice(0, 2), true), /suppressed/);
    stack = await stacks.create({ ownerId }, assets.slice(0, 2));
    assert.equal(stack.assets.length, 3);
  });
  await check('dissolve persists all members and leaves every asset intact', async () => {
    await stacks.manuallyDissolve(ownerId, [stack.id]);
    assert.equal((await stacks.getSuppressions(ownerId, 1)).length, 3);
    assert.equal((await db.selectFrom('asset').selectAll().execute()).length, 8);
    await assert.rejects(stacks.create({ ownerId }, [assets[0], assets[2]], true), /suppressed/);
  });
  const memories = new MemoryRepository(db);
  await check('display enrichment preserves existing memory identity and metadata', async () => {
    const original = await db
      .insertInto('memory')
      .values({
        ownerId,
        type: 'on_this_day',
        memoryAt: new Date(),
        data: { year: 2025, context: { source: 'existing-generator' } },
      })
      .returningAll()
      .executeTakeFirstOrThrow();
    const updated = await memories.updateDisplay(original.id, {}, { title: 'День у моря', subtitle: 'Вместе' });
    assert.equal(updated.id, original.id);
    assert.equal(updated.type, original.type);
    assert.equal(updated.data.year, 2025);
    assert.deepEqual(updated.data.context, original.data.context);
    assert.equal(updated.data.title, 'День у моря');
    const cleared = await memories.updateDisplay(original.id, {}, { title: null });
    assert.equal(cleared.data.title, null);
    assert.equal(cleared.data.subtitle, 'Вместе');
    await db.deleteFrom('memory').where('id', '=', original.id).execute();
  });
  const input = {
    ownerId,
    type: 'rule',
    data: { title: 'A day by the sea', subtitle: 'Together', ruleId: 'external_ai' },
    memoryAt: new Date(),
  };
  const candidate = await memories.createCandidate(input, assets.slice(3, 6));
  await check('ordinary save cannot bypass the candidate decision', async () => {
    await assert.rejects(memories.update(candidate.memoryId, { isSaved: true }), /decision endpoint/);
  });
  await check('candidate creation is idempotent and owner isolated', async () => {
    const retry = await memories.createCandidate(input, assets.slice(3, 6).reverse());
    assert.equal(retry.id, candidate.id);
    assert.equal(retry.created, false);
    assert.equal((await memories.getCandidates(otherId)).length, 0);
    await assert.rejects(memories.decideCandidate(otherId, candidate.id, 'save'), /not found/);
    const rows = await memories.searchBuilder(ownerId, {}).select('id').execute();
    assert.deepEqual(rows, []);
  });
  await check('later stays pending and defers server delivery', async () => {
    const later = await memories.decideCandidate(ownerId, candidate.id, 'later');
    assert.equal(later.state, 'pending');
    assert.equal((await memories.getCandidates(ownerId)).length, 0);
  });
  await check('dismiss persists even after the underlying memory is removed', async () => {
    await memories.decideCandidate(ownerId, candidate.id, 'dismiss');
    await db.deleteFrom('memory').where('id', '=', candidate.memoryId).execute();
    await assert.rejects(memories.createCandidate(input, assets.slice(3, 6)), /declined/);
  });
  await check('save rejects a removed memory without losing the persistent decision history', async () => {
    const removed = await memories.createCandidate(input, assets.slice(0, 2));
    await db.deleteFrom('memory').where('id', '=', removed.memoryId).execute();
    await assert.rejects(memories.decideCandidate(ownerId, removed.id, 'save'), /no longer exists/);
    const pending = await db
      .selectFrom('memory_candidate')
      .selectAll()
      .where('id', '=', removed.id)
      .executeTakeFirstOrThrow();
    assert.equal(pending.state, 'pending');
    assert.equal(pending.memoryId, null);
    await memories.decideCandidate(ownerId, removed.id, 'dismiss');
    await assert.rejects(memories.createCandidate(input, assets.slice(0, 2)), /declined/);
  });
  await check('more than twenty empty proposals cannot hide a newer valid candidate', async () => {
    const proposalAssets = Array.from({ length: 22 }, () => randomUUID());
    await db
      .insertInto('asset')
      .values(proposalAssets.map((id) => ({ id, ownerId: otherId })))
      .execute();
    const emptyIds = [];
    for (const assetId of proposalAssets.slice(0, 21)) {
      const proposal = await memories.createCandidate({ ...input, ownerId: otherId }, [assetId]);
      emptyIds.push(proposal.id);
    }
    await db
      .updateTable('memory_candidate')
      .set({ createdAt: new Date(Date.now() - 86_400_000) })
      .where('id', 'in', emptyIds)
      .execute();
    await db
      .updateTable('asset')
      .set({ visibility: 'archive' })
      .where('id', 'in', proposalAssets.slice(0, 21))
      .execute();
    const valid = await memories.createCandidate({ ...input, ownerId: otherId }, proposalAssets.slice(21));
    const due = await memories.getCandidates(otherId);
    assert.deepEqual(
      due.map((row) => row.id),
      [valid.id],
    );
  });
  await check('saved candidate becomes a permanent ordinary memory', async () => {
    const saved = await memories.createCandidate(input, assets.slice(6, 8));
    await memories.decideCandidate(ownerId, saved.id, 'save');
    const row = await db.selectFrom('memory').selectAll().where('id', '=', saved.memoryId).executeTakeFirstOrThrow();
    assert.equal(row.isSaved, true);
    assert.equal(row.hideAt, null);
    assert.equal(row.data.title, input.data.title);
    assert.equal(row.data.candidateState, 'saved');
    assert.equal((await memories.searchBuilder(ownerId, {}).select('id').execute()).length, 1);
  });
  await check('rollback retains saved memories and removes decision tables', async () => {
    await candidateMigration.down(db);
    await suppressionMigration.down(db);
    assert.equal((await db.selectFrom('memory').selectAll().execute()).length, 1);
    const row = await sql`SELECT to_regclass(${`${schema}.memory_candidate`}) AS table`.execute(db);
    assert.equal(row.rows[0].table, null);
  });
  console.log(`${passed} PostgreSQL contracts passed`);
} finally {
  await db.destroy();
  await sql.raw(`DROP SCHEMA "${schema}" CASCADE`).execute(admin);
  await admin.destroy();
}
