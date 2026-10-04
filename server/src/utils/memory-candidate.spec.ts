import { memoryFingerprint, similarMemoryAssets } from 'src/utils/memory-candidate.js';

describe('memory candidate deduplication', () => {
  it('ignores order and duplicate asset ids', () => {
    expect(memoryFingerprint(['a', 'b', 'a'])).toBe(memoryFingerprint(['b', 'a']));
  });
  it('rejects nearly identical proposals but allows different moments', () => {
    expect(similarMemoryAssets(['a', 'b', 'c', 'd', 'e'], ['a', 'b', 'c', 'd'])).toBe(true);
    expect(similarMemoryAssets(['a', 'b'], ['c', 'd'])).toBe(false);
    expect(similarMemoryAssets([], [])).toBe(false);
  });
});
