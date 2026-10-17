import { MemoryType, type MemoryResponseDto, updateMemory } from '@immich/sdk';
import { markMemoryViewed } from '$lib/utils/memory-viewed';

vi.mock('@immich/sdk', async (importOriginal) => ({
  ...(await importOriginal<typeof import('@immich/sdk')>()),
  updateMemory: vi.fn(),
}));

const memory = (): MemoryResponseDto => ({
  id: 'memory-id',
  ownerId: 'owner-id',
  type: MemoryType.Rule,
  data: { ruleId: 'gallery_ai_highlight', generator: 'family-ai', context: { theme: 'holiday' } },
  assets: [],
  createdAt: '2026-10-05T00:00:00.000Z',
  updatedAt: '2026-10-05T00:00:00.000Z',
  memoryAt: '2024-10-05T00:00:00.000Z',
  isSaved: false,
});

describe('memory viewing acknowledgement', () => {
  it.each([MemoryType.Rule, MemoryType.OnThisDay])('marks an owned %s memory independently of saving', async (type) => {
    const current = { ...memory(), type };
    const originalData = structuredClone(current.data);
    vi.mocked(updateMemory).mockResolvedValue({ ...current, seenAt: '2026-10-05T12:00:00.000Z' });
    await markMemoryViewed(current, current.ownerId);
    expect(updateMemory).toHaveBeenCalledWith({ id: current.id, memoryUpdateDto: { seenAt: expect.any(String) } });
    expect(current.seenAt).toBe('2026-10-05T12:00:00.000Z');
    expect(current.isSaved).toBe(false);
    expect(current.data).toEqual(originalData);
    await markMemoryViewed(current, current.ownerId);
    expect(updateMemory).toHaveBeenCalledTimes(1);
  });

  it('does not acknowledge a shared memory on behalf of another owner', async () => {
    await markMemoryViewed(memory(), 'different-user');
    expect(updateMemory).not.toHaveBeenCalled();
  });

  it('does not revive a removed memory', async () => {
    await markMemoryViewed({ ...memory(), deletedAt: '2026-10-05T12:00:00.000Z' }, 'owner-id');
    expect(updateMemory).not.toHaveBeenCalled();
  });

  it('keeps failed acknowledgement unknown and preserves saved state and source metadata', async () => {
    const current = { ...memory(), isSaved: true };
    const before = structuredClone(current);
    vi.mocked(updateMemory).mockRejectedValue(new Error('offline'));
    await expect(markMemoryViewed(current, current.ownerId)).rejects.toThrow('offline');
    expect(current).toEqual(before);
  });
});
