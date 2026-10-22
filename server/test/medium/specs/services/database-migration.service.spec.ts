import { DatabaseConnectionParams, createPostgres } from '@immich/sql-tools';
import { Kysely, sql } from 'kysely';
import { FileMigrationProvider, Migrator } from 'kysely/migration';
import { readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { ConfigRepository } from 'src/repositories/config.repository.js';
import { DatabaseRepository } from 'src/repositories/database.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { CompositeMigrationProvider } from 'src/schema/composite-migration-provider.js';
import { DB } from 'src/schema/index.js';
import { getKyselyConfig } from 'src/utils/database.js';

// Helper: create a raw database (no migrations applied)
const createRawDatabase = async (name: string): Promise<Kysely<DB>> => {
  const testUrl = process.env.IMMICH_TEST_POSTGRES_URL!;
  const templateDb = testUrl.split('/').pop()!;
  const connection = {
    connectionType: 'url',
    url: testUrl.replace(`/${templateDb}`, '/postgres'),
  } as DatabaseConnectionParams;
  const pgSql = createPostgres({ maxConnections: 1, connection });

  await pgSql.unsafe(`DROP DATABASE IF EXISTS ${name}`);
  await pgSql.unsafe(`CREATE DATABASE ${name} OWNER postgres`);
  await pgSql.end();

  return new Kysely<DB>(
    getKyselyConfig({
      connectionType: 'url',
      url: testUrl.replace(`/${templateDb}`, () => `/${name}`),
    }),
  );
};

const createRepo = (db: Kysely<DB>) => {
  const configRepository = new ConfigRepository();
  const logger = LoggingRepository.create();
  return new DatabaseRepository(db, logger, configRepository);
};

describe('Database Migration Scenarios', () => {
  // Scenario A: Fresh install
  it('should run all migrations on a fresh database', async () => {
    const db = await createRawDatabase('migration_test_fresh');
    try {
      const repo = createRepo(db);
      await repo.runMigrations();

      const migrations = await repo.getMigrations();
      expect(migrations.length).toBeGreaterThan(0);

      // Verify fork migrations are present
      const forkMigrations = migrations.filter(
        (m) =>
          m.name.includes('CreateStorageMigrationLogTable') ||
          m.name.includes('CreateSharedSpaceTables') ||
          m.name.includes('CreateUserGroupTables'),
      );
      expect(forkMigrations.length).toBe(3);

      // Verify upstream migrations are present
      const upstreamMigrations = migrations.filter((m) => m.name.includes('InitialMigration'));
      expect(upstreamMigrations.length).toBe(1);
    } finally {
      await db.destroy();
    }
  });

  // Scenario B: Immich-to-Gallery migration
  it('should apply fork migrations on top of an upstream-only database', async () => {
    const db = await createRawDatabase('migration_test_immich');
    try {
      // Step 1: Run only upstream migrations (simulates Immich state)
      const upstreamOnlyMigrator = new Migrator({
        db,
        migrationLockTableName: 'kysely_migrations_lock',
        allowUnorderedMigrations: true,
        migrationTableName: 'kysely_migrations',
        provider: new FileMigrationProvider({
          fs: { readdir },
          path: { join },
          // Mirrors CompositeMigrationProvider's `import` hook: without it, FileMigrationProvider
          // falls back to the plain `import(filePath)` defined inside the (externalized) kysely
          // package itself, which Node resolves natively and can't see this project's `src/` path
          // alias. Writing the import call here, in project source, routes it back through
          // vite-node's own module resolution (tsconfigPaths included) so bare `src/...` imports
          // in the migration files resolve the same way they do for the real migrator.
          import: (filePath) => import(filePath),
          // eslint-disable-next-line unicorn/prefer-module
          migrationFolder: join(__dirname, '../../../../src/schema/migrations'),
        }),
      });

      const { error: upstreamError } = await upstreamOnlyMigrator.migrateToLatest();
      expect(upstreamError).toBeUndefined();

      const upstreamMigrations = await db
        .selectFrom('kysely_migrations')
        .select(['name'])
        .orderBy('name', 'asc')
        .execute();

      // Verify no fork migrations applied yet
      const forkMigrationsBefore = upstreamMigrations.filter(
        (m) =>
          m.name.includes('CreateStorageMigrationLogTable') ||
          m.name.includes('CreateSharedSpaceTables') ||
          m.name.includes('CreateUserGroupTables'),
      );
      expect(forkMigrationsBefore).toHaveLength(0);

      // Step 2: Run full Gallery migrator (composite provider)
      const repo = createRepo(db);
      await repo.runMigrations();

      // Step 3: Verify fork migrations were applied
      const allMigrations = await repo.getMigrations();
      const forkMigrationsAfter = allMigrations.filter(
        (m) =>
          m.name.includes('CreateStorageMigrationLogTable') ||
          m.name.includes('CreateSharedSpaceTables') ||
          m.name.includes('CreateUserGroupTables'),
      );
      expect(forkMigrationsAfter).toHaveLength(3);

      // Verify interleaving
      const names = allMigrations.map((m) => m.name);
      const storageIdx = names.findIndex((n) => n.includes('CreateStorageMigrationLogTable'));
      const opusIdx = names.findIndex((n) => n.includes('UpdateOpusCodecName'));
      expect(storageIdx).toBeGreaterThan(-1);
      expect(opusIdx).toBeGreaterThan(-1);
      expect(storageIdx).toBeLessThan(opusIdx);
    } finally {
      await db.destroy();
    }
  });

  // Scenario C: Existing Gallery user — idempotent
  it('should be a no-op when all migrations are already applied', async () => {
    const db = await createRawDatabase('migration_test_gallery');
    try {
      const repo = createRepo(db);
      await repo.runMigrations();
      const firstRun = await repo.getMigrations();

      await repo.runMigrations();
      const secondRun = await repo.getMigrations();

      expect(secondRun.length).toBe(firstRun.length);
      expect(secondRun.map((m) => m.name)).toEqual(firstRun.map((m) => m.name));
    } finally {
      await db.destroy();
    }
  });

  // Scenario D: Rollback
  it('refuses destructive rollback of durable deletion evidence', async () => {
    const db = await createRawDatabase('migration_test_rollback');
    try {
      const repo = createRepo(db);
      // This scenario exercises the existing deletion-evidence rollback boundary,
      // not whatever unrelated additive migration happens to be last today. Start
      // a fresh, empty DB at that real boundary without reverting new user data.
      const provider = new CompositeMigrationProvider([
        join(import.meta.dirname, '../../../../src/schema/migrations'),
        join(import.meta.dirname, '../../../../src/schema/migrations-gallery'),
      ]);
      const baseline = await provider.getMigrations();
      // This later-added overlay is interleaved before 179405 by timestamp but
      // was not present at the original Build 17 deletion boundary. All current
      // migrations are exercised by the fresh/upgrade/idempotency scenarios above.
      delete baseline['1794000000000-AddAssetFavoriteTables'];
      const migrator = new Migrator({
        db,
        migrationLockTableName: 'kysely_migrations_lock',
        migrationTableName: 'kysely_migrations',
        allowUnorderedMigrations: true,
        provider: { getMigrations: () => Promise.resolve(baseline) },
      });
      const { error } = await migrator.migrateTo('1794050000000-OwnerStorageDeletion');
      expect(error).toBeUndefined();
      const before = await repo.getMigrations();
      const lastMigration = before.at(-1)!.name;

      expect(lastMigration).toBe('1794050000000-OwnerStorageDeletion');
      // The additive storage-mode migration has a non-destructive down path:
      // disable new grants while retaining its column, identities and receipts.
      await expect(repo.revertLastMigration()).resolves.toBe(lastMigration);
      const afterStorageRevert = await repo.getMigrations();
      expect(afterStorageRevert).toEqual(before.slice(0, -1));
      await expect(repo.revertLastMigration()).rejects.toThrow(
        'Keep bound deletion policies and durable receipts. Use forward-compatible rollback.',
      );
      expect(await repo.getMigrations()).toEqual(afterStorageRevert);
      const { rows } = await sql<{
        journal: string;
      }>`SELECT to_regclass('asset_deletion_tombstone') AS journal`.execute(db);
      expect(rows[0].journal).toBe('asset_deletion_tombstone');
      const { rows: columns } = await sql<{ column_name: string }>`
        SELECT column_name FROM information_schema.columns
        WHERE table_name='asset_deletion_policy'
        AND column_name IN ('authorizationMode', 'rootIdentities', 'recoveryExpiresAt')
        ORDER BY column_name
      `.execute(db);
      expect(columns.map(({ column_name }) => column_name)).toEqual([
        'authorizationMode',
        'recoveryExpiresAt',
        'rootIdentities',
      ]);
    } finally {
      await db.destroy();
    }
  });

  // Scenario E: Sorted order verification
  it('should return all migrations sorted by name including both upstream and fork', async () => {
    const db = await createRawDatabase('migration_test_sorted');
    try {
      const repo = createRepo(db);
      await repo.runMigrations();

      const migrations = await repo.getMigrations();
      const names = migrations.map((m) => m.name);
      const sorted = names.toSorted();
      expect(names).toEqual(sorted);

      // Verify interleaving
      const storageIdx = names.findIndex((n) => n.includes('CreateStorageMigrationLogTable'));
      const opusIdx = names.findIndex((n) => n.includes('UpdateOpusCodecName'));
      const initialIdx = names.findIndex((n) => n.includes('InitialMigration'));

      expect(initialIdx).toBeLessThan(storageIdx);
      expect(storageIdx).toBeLessThan(opusIdx);
    } finally {
      await db.destroy();
    }
  });

  // Scenario G: Retry after revert
  it('should be able to re-run after a previous successful run', async () => {
    const db = await createRawDatabase('migration_test_retry');
    try {
      const repo = createRepo(db);
      await repo.runMigrations();
      const afterRevert = await repo.getMigrations();

      await repo.runMigrations();
      const afterRerun = await repo.getMigrations();

      expect(afterRerun).toEqual(afterRevert);
    } finally {
      await db.destroy();
    }
  });

  // Scenario H: the fork migration disables PostgreSQL JIT for the connecting role.
  // JIT-compiling the high-cost (but fast-executing) cross-space People aggregates
  // adds a ~2s per-backend LLVM penalty; jit=off makes the People page ~4x faster
  // and regresses nothing (see 1783628194057-DisablePostgresJit).
  it('should disable PostgreSQL JIT for the connecting role', async () => {
    const dbName = 'migration_test_jit';
    const setup = await createRawDatabase(dbName);
    await createRepo(setup).runMigrations();
    await setup.destroy();

    // Open a fresh connection, as the app pool would, after the migration ran.
    // ALTER ROLE ... SET applies to new connections, so this reflects runtime behavior.
    const testUrl = process.env.IMMICH_TEST_POSTGRES_URL!;
    const templateDb = testUrl.split('/').pop()!;
    const db = new Kysely<DB>(
      getKyselyConfig({ connectionType: 'url', url: testUrl.replace(`/${templateDb}`, () => `/${dbName}`) }),
    );
    try {
      const { rows } = await sql<{ jit: string; configured: boolean }>`
        SELECT current_setting('jit') AS jit,
               EXISTS (
                 SELECT 1 FROM pg_roles WHERE rolname = current_user AND 'jit=off' = ANY (rolconfig)
               ) AS configured
      `.execute(db);
      expect(rows[0].configured).toBe(true);
      expect(rows[0].jit).toBe('off');
    } finally {
      await db.destroy();
    }
  });
});
