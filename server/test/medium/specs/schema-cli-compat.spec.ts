import { schemaDiff, schemaFromCode, schemaFromDatabase } from '@immich/sql-tools';
import { Kysely, sql } from 'kysely';
import { immich_uuid_v7 } from 'src/schema/functions.js';
import { DB } from 'src/schema/index.js';
import { getKyselyDB } from 'test/utils.js';

let db: Kysely<DB>;
beforeAll(async () => {
  db = await getKyselyDB();
});
afterAll(async () => {
  await db?.destroy();
});

it('matches the stricter migration CLI comparison without proposing to remove deletion guards', async () => {
  const source = schemaFromCode({
    overrides: true,
    namingStrategy: 'default',
    uuidFunction: (version) => (version === 7 ? `${immich_uuid_v7.name}()` : 'uuid_generate_v4()'),
  });
  const target = await schemaFromDatabase({
    connection: { connectionType: 'url', url: process.env.IMMICH_TEST_POSTGRES_URL! },
  });
  // These are sql-tools migrations:generate's options, not the runtime's more
  // permissive ignoreExtra rules for existing columns, indexes and triggers.
  const drift = schemaDiff(source, target, {
    tables: { ignoreExtra: true },
    functions: { ignoreExtra: false },
    parameters: { ignoreExtra: true },
    extensions: { ignoreExtra: true },
  });
  expect(drift.asHuman()).toEqual([]);
  expect(drift.asSql()).toEqual([]);
});

it('retains both enabled column-specific security triggers with their exact immutable migration DDL', async () => {
  // sql-tools cannot express UPDATE OF columns. Registering these migration-owned
  // names as unmanaged must never become permission to change or disable a guard.
  const { rows } = await sql<{ name: string; enabled: string; definition: string }>`
    select tgname as name, tgenabled as enabled, pg_get_triggerdef(oid) as definition
    from pg_trigger where tgname in ('gallery_block_deleted_asset', 'gallery_lock_asset_file_path')
    and not tgisinternal order by tgname
  `.execute(db);
  expect(rows).toEqual([
    {
      name: 'gallery_block_deleted_asset',
      enabled: 'O',
      definition:
        'CREATE TRIGGER gallery_block_deleted_asset BEFORE INSERT OR UPDATE OF "originalPath", "ownerId", checksum ON public.asset FOR EACH ROW EXECUTE FUNCTION gallery_block_deleted_asset()',
    },
    {
      name: 'gallery_lock_asset_file_path',
      enabled: 'O',
      definition:
        'CREATE TRIGGER gallery_lock_asset_file_path BEFORE INSERT OR UPDATE OF path ON public.asset_file FOR EACH ROW EXECUTE FUNCTION gallery_lock_asset_file_path()',
    },
  ]);
});
