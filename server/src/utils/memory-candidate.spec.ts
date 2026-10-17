import {
  MemorySuppressedException,
  memoryAssetIds,
  memoryData,
  memoryFingerprint,
  similarMemoryAssets,
} from 'src/utils/memory-candidate.js';

describe('memory candidate deduplication', () => {
  it('exposes a stable suppression code without changing the conflict status or message', () => {
    const error = new MemorySuppressedException();
    expect(error.code).toBe('MEMORY_SUPPRESSED');
    expect(error.getStatus()).toBe(409);
    expect(error.message).toBe('A similar memory was hidden or deleted by the user');
    expect(error.getResponse()).toEqual({ message: error.message, code: error.code });
  });

  it('ignores order and duplicate asset ids', () => {
    expect(memoryFingerprint(['a', 'b', 'a'])).toBe(memoryFingerprint(['b', 'a']));
  });
  it('rejects nearly identical proposals but allows different moments', () => {
    expect(similarMemoryAssets(['a', 'b', 'c', 'd', 'e'], ['a', 'b', 'c', 'd'])).toBe(true);
    expect(similarMemoryAssets(['a', 'b'], ['c', 'd'])).toBe(false);
    expect(similarMemoryAssets([], [])).toBe(false);
  });

  it('preserves rejection history written by the former double-encoded JSONB writer', () => {
    expect(similarMemoryAssets(['a', 'b', 'c', 'd', 'e'], JSON.stringify(['a', 'b', 'c', 'd']))).toBe(true);
    expect(memoryAssetIds(JSON.stringify(['a', 'b']))).toEqual(['a', 'b']);
  });

  it('recovers legacy candidate/display updates while preserving AI metadata and newest text', () => {
    expect(
      memoryData([
        { year: 2024, ruleId: 'gallery_ai_highlight', title: 'Original title', context: { location: 'Paris' } },
        JSON.stringify({ title: 'New title', candidateState: 'saved' }),
        JSON.stringify({ subtitle: 'Description', candidateState: 'dismissed' }),
      ]),
    ).toEqual({
      year: 2024,
      ruleId: 'gallery_ai_highlight',
      title: 'New title',
      context: { location: 'Paris' },
      subtitle: 'Description',
      candidateState: 'dismissed',
    });
  });

  it('bounds legacy recovery and ignores malformed/nested data without prototype pollution', () => {
    const normalized = memoryData([
      { title: 'Original' },
      'invalid',
      ['nested'],
      JSON.parse('{"__proto__":{"inherited":true}}'),
    ]);
    expect(normalized.title).toBe('Original');
    expect(Object.getPrototypeOf(normalized)).toBe(Object.prototype);
    expect(normalized.inherited).toBeUndefined();
    expect(
      memoryData([
        { year: 2024 },
        ...Array.from({ length: 100 }, (_, index) => JSON.stringify({ title: String(index) })),
      ]),
    ).toEqual({ year: 2024, title: '99' });
  });

  it.each([null, undefined, '', 'not-json', '{}', '[1]', { ids: ['a'] }])(
    'ignores malformed legacy memberships %j',
    (value) => {
      expect(memoryAssetIds(value)).toEqual([]);
      expect(similarMemoryAssets(['a'], value)).toBe(false);
    },
  );
});
