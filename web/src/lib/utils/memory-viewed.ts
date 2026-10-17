import { type MemoryResponseDto, updateMemory } from '@immich/sdk';

/** A view acknowledgement never changes saved state, assets, or generator data. */
export const markMemoryViewed = async (memory: MemoryResponseDto, viewerId: string): Promise<void> => {
  if (memory.ownerId !== viewerId || memory.seenAt || memory.deletedAt) {
    return;
  }
  const seenAt = new Date().toISOString();
  const response = await updateMemory({ id: memory.id, memoryUpdateDto: { seenAt } });
  memory.seenAt = response.seenAt ?? seenAt;
};
