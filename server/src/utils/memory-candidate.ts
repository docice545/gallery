import { createHash } from 'node:crypto';

export const memoryFingerprint = (assetIds: string[]) =>
  createHash('sha256')
    .update([...new Set(assetIds)].sort().join(','))
    .digest('hex');

/** High overlap, regardless of order or a few replacement photos, suppresses repeated proposals. */
export const similarMemoryAssets = (first: string[], second: string[]) => {
  const a = new Set(first);
  const b = new Set(second);
  if (a.size === 0 || b.size === 0) return false;
  const shared = [...a].filter((id) => b.has(id)).length;
  return shared / (a.size + b.size - shared) >= 0.8;
};
