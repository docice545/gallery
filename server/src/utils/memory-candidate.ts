import { ConflictException } from '@nestjs/common';
import { createHash } from 'node:crypto';

/** A durable user choice, distinct from a transient generation or database failure. */
export class MemorySuppressedException extends ConflictException {
  readonly code = 'MEMORY_SUPPRESSED';

  constructor() {
    super({
      message: 'A similar memory was hidden or deleted by the user',
      code: 'MEMORY_SUPPRESSED',
    });
  }
}

export const memoryFingerprint = (assetIds: string[]) =>
  createHash('sha256')
    .update([...new Set(assetIds)].sort().join(','))
    .digest('hex');

/** Older candidate rows could contain a JSON string because their writer encoded JSON twice. */
export const memoryAssetIds = (value: unknown): string[] => {
  if (typeof value === 'string') {
    try {
      value = JSON.parse(value) as unknown;
    } catch {
      return [];
    }
  }
  return Array.isArray(value) && value.every((id) => typeof id === 'string') ? value : [];
};

/** Recover the former object || JSON-string updates without traversing arbitrary nested data. */
export const memoryData = (value: unknown): Record<string, unknown> => {
  if (value !== null && typeof value === 'object' && !Array.isArray(value)) {
    return value as Record<string, unknown>;
  }
  const parts = Array.isArray(value) ? value : [value];
  const selected = parts.length <= 64 ? parts : [parts[0], ...parts.slice(-63)];
  let result: Record<string, unknown> = {};
  for (let part of selected) {
    if (typeof part === 'string' && part.length <= 65_536) {
      try {
        part = JSON.parse(part) as unknown;
      } catch {
        continue;
      }
    }
    if (part !== null && typeof part === 'object' && !Array.isArray(part)) {
      result = { ...result, ...(part as Record<string, unknown>) };
    }
  }
  return result;
};

/** High overlap, regardless of order or a few replacement photos, suppresses repeated proposals. */
export const similarMemoryAssets = (first: unknown, second: unknown) => {
  const a = new Set(memoryAssetIds(first));
  const b = new Set(memoryAssetIds(second));
  if (a.size === 0 || b.size === 0) return false;
  const shared = [...a].filter((id) => b.has(id)).length;
  return shared / (a.size + b.size - shared) >= 0.8;
};
