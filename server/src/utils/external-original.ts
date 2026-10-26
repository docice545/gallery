import { Selectable } from 'kysely';
import { Stats } from 'node:fs';
import { CryptoRepository } from 'src/repositories/crypto.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { StorageRepository } from 'src/repositories/storage.repository.js';
import { AssetTable } from 'src/schema/tables/asset.table.js';

export const verifyExternalOriginal = async (
  asset: Selectable<AssetTable>,
  { storage, crypto, logger }: { storage: StorageRepository; crypto: CryptoRepository; logger: LoggingRepository },
): Promise<Buffer | null> => {
  // Never trust a resolution alias, filename, stale EXIF size or index flag as
  // evidence of current bytes. No file is changed by this admission check.
  const signal = AbortSignal.timeout(30_000);
  let onAbort: (() => void) | undefined;
  try {
    const work = async () => {
      const before = await storage.stat(asset.originalPath);
      if (!before.isFile()) return null;
      const checksum = await crypto.hashFile(asset.originalPath, signal);
      const after = await storage.stat(asset.originalPath);
      if (!sameOriginal(before, after)) {
        logger.warn(`External upload identity changed during verification: asset=${asset.id}`);
        return null;
      }
      return checksum;
    };
    const deadline = new Promise<never>((_, reject) => {
      onAbort = () => reject(signal.reason);
      signal.addEventListener('abort', onAbort, { once: true });
    });
    return await Promise.race([work(), deadline]);
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (
      signal.aborted ||
      ['ENOENT', 'ENOTDIR', 'EACCES', 'EPERM', 'ESTALE', 'EIO', 'ENXIO', 'ETIMEDOUT'].includes(code ?? '')
    ) {
      logger.warn(
        `External upload original unavailable: asset=${asset.id}, code=${signal.aborted ? 'READ_TIMEOUT' : code}`,
      );
      return null;
    }
    throw error;
  } finally {
    if (onAbort) signal.removeEventListener('abort', onAbort);
  }
};

const sameOriginal = (before: Stats, after: Stats) => {
  return (
    after.isFile() &&
    before.dev === after.dev &&
    before.ino === after.ino &&
    before.size === after.size &&
    before.mtimeMs === after.mtimeMs &&
    before.ctimeMs === after.ctimeMs
  );
};
