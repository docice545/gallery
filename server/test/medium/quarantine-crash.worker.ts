import { Kysely } from 'kysely';
import { writeFileSync } from 'node:fs';
import fs from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { DB } from 'src/schema/index.js';
import { unlinkOriginal } from 'src/utils/authorized-deletion.js';
import { getKyselyConfig } from 'src/utils/database.js';
import { emulateNfsRootSquash } from 'test/nfs-quarantine.js';

// Run only through quarantine-crash.config.mjs. The parent checks the marker,
// the actual abnormal process exit and independently committed PostgreSQL rows.
// The parent SIGKILLs this worker's owned process group at the private barrier.
it('terminates the synthetic worker at the requested filesystem checkpoint', async () => {
  const input = JSON.parse(process.env.GALLERY_NFS_CRASH_INPUT!);
  const databaseUrl = new URL(input.databaseUrl);
  if (
    !['localhost', '127.0.0.1'].includes(databaseUrl.hostname) ||
    !/^\/immich_[a-z0-9_]+$/.test(databaseUrl.pathname) ||
    !String(input.root).startsWith(join(tmpdir(), 'gallery-quarantine-crash-pg-'))
  ) {
    throw new Error('Refusing non-disposable crash fixture');
  }
  const db = new Kysely<DB>(getKyselyConfig({ connectionType: 'url', url: input.databaseUrl }));
  await emulateNfsRootSquash(input.root);
  // Only reproduce the existing test evidence helper's synthetic read-only
  // mount boundary; signatures, timestamps and recovery contents remain real.
  const store = process.env.GALLERY_DELETION_RECOVERY_DIR!;
  const directory = dirname(store);
  const accessActual = fs.access;
  vi.spyOn(fs, 'access').mockImplementation(async (path, mode) => {
    if ((String(path) === directory || String(path).startsWith(directory + '/')) && mode === 2) {
      throw Object.assign(new Error('Synthetic read-only evidence mount'), { code: 'EROFS' });
    }
    await accessActual(path, mode);
  });
  let injected = false;
  const crash = async () => {
    injected = true;
    writeFileSync(join(input.root, 'crash-checkpoint.json'), JSON.stringify({ stage: input.stage, pid: process.pid }), {
      flag: 'wx',
      mode: 0o600,
    });
    await new Promise<void>(() => {});
    throw new Error('Crash barrier unexpectedly returned');
  };
  const isQuarantine = (path: unknown) => String(path).endsWith('/.gallery-deletion-quarantine');
  const mkdirActual = vi.mocked(fs.mkdir).getMockImplementation()!;
  vi.spyOn(fs, 'mkdir').mockImplementation(async (path, options) => {
    if (isQuarantine(path) && input.stage === 'before-mkdir') await crash();
    const result = await mkdirActual(path, options);
    if (isQuarantine(path) && input.stage === 'after-mkdir') await crash();
    return result;
  });
  const rootStat = await fs.stat(input.root, { bigint: true });
  const openActual = vi.mocked(fs.open).getMockImplementation()!;
  vi.spyOn(fs, 'open').mockImplementation(async (path, flags, mode) => {
    const handle = await openActual(path, flags, mode);
    const stat = await handle.stat({ bigint: true });
    const q = isQuarantine(path);
    if (q) {
      const chmodActual = handle.chmod.bind(handle);
      vi.spyOn(handle, 'chmod').mockImplementation(async (mode) => {
        if (input.stage === 'before-chmod') await crash();
        await chmodActual(mode);
        if (input.stage === 'after-chmod') await crash();
      });
    }
    if (q || (stat.dev === rootStat.dev && stat.ino === rootStat.ino)) {
      const syncActual = handle.sync.bind(handle);
      vi.spyOn(handle, 'sync').mockImplementation(async () => {
        await syncActual();
        if ((q && input.stage === 'after-quarantine-sync') || (!q && input.stage === 'after-root-sync')) await crash();
      });
    }
    return handle;
  });
  try {
    await new AssetRepository(db).removeAuthorizedOriginals(input.assetId, unlinkOriginal);
    expect(injected).toBe(true);
  } finally {
    await db.destroy();
  }
});
