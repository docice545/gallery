import {
  MemoryCreateDto,
  MemoryLifecycleSearchDto,
  MemoryRejectionsResponseDto,
  MemoryResponseDto,
  MemoryUpdateDto,
  mapMemory,
} from 'src/dtos/memory.dto.js';
import { MemoryType } from 'src/enum.js';
import { RuleMemoryData } from 'src/types.js';
import { MemoryFactory } from 'test/factories/memory.factory.js';
import { getForMemory } from 'test/mappers.js';
import { factory } from 'test/small.factory.js';

describe('Memory DTOs', () => {
  describe('MemoryLifecycleSearchDto', () => {
    it('defaults to bounded snapshots and strips untrusted owner filters', () => {
      expect(MemoryLifecycleSearchDto.schema.parse({ ownerId: 'another-user', since: '2020-01-01' })).toEqual({
        size: 100,
      });
    });

    it('accepts a UUIDv4 keyset cursor and coerces page size', () => {
      const after = factory.uuid();
      expect(MemoryLifecycleSearchDto.schema.parse({ after, size: '1000' })).toEqual({ after, size: 1000 });
    });

    it.each([{ after: 'invalid' }, { size: 0 }, { size: 1001 }, { size: 1.5 }])(
      'rejects invalid pagination %j',
      (dto) => {
        expect(MemoryLifecycleSearchDto.schema.safeParse(dto).success).toBe(false);
      },
    );
  });

  it('requires rejection state and allows the memory link to be lost after hard deletion', () => {
    const item = { id: factory.uuid(), fingerprint: 'fingerprint', assetIds: [], state: 'dismissed', memoryId: null };
    expect(MemoryRejectionsResponseDto.schema.safeParse({ items: [item] }).success).toBe(true);
    expect(MemoryRejectionsResponseDto.schema.safeParse({ items: [{ ...item, state: 'saved' }] }).success).toBe(false);
  });

  describe('MemoryUpdateDto', () => {
    it('accepts explicit permanent hide on the existing update API', () => {
      expect(MemoryUpdateDto.schema.parse({ isHidden: true })).toEqual({ isHidden: true });
    });

    it('does not provide a bypass to revive a suppressed memory', () => {
      expect(MemoryUpdateDto.schema.safeParse({ isHidden: false }).success).toBe(false);
    });
  });
  describe('MemoryCreateDto', () => {
    it('should accept generic rule memory data', () => {
      const result = MemoryCreateDto.schema.safeParse({
        type: MemoryType.Rule,
        data: {
          ruleId: 'birthday',
          dedupeKey: 'birthday:person-1:2026-04-23',
          title: 'Happy birthday, Alice',
          context: { personId: 'person-1' },
        } satisfies RuleMemoryData,
        memoryAt: new Date().toISOString(),
      });

      expect(result.success).toBe(true);
    });

    it('should preserve on-this-day validation', () => {
      const result = MemoryCreateDto.schema.safeParse({
        type: MemoryType.OnThisDay,
        data: {},
        memoryAt: new Date().toISOString(),
      });

      expect(result.success).toBe(false);
      expect(result.error?.issues).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            message: 'Invalid input: expected number, received undefined',
            path: ['data', 'year'],
          }),
        ]),
      );
    });
  });

  describe('mapMemory', () => {
    it('preserves titles and rule metadata from legacy double-encoded display updates', () => {
      const memory = MemoryFactory.create({
        type: MemoryType.Rule,
        data: [
          { ruleId: 'gallery_ai_highlight', title: 'Original' },
          JSON.stringify({ title: 'Generated title', subtitle: 'Generated description', candidateState: 'saved' }),
        ] as any,
      });
      const result = mapMemory(getForMemory(memory) as any, factory.auth());
      expect(result.title).toBe('Generated title');
      expect(result.subtitle).toBe('Generated description');
      expect(result.data.ruleId).toBe('gallery_ai_highlight');
      expect(MemoryResponseDto.schema.safeEncode(result).success).toBe(true);
    });
    it('surfaces generated display text on an existing on-this-day memory', () => {
      const memory = MemoryFactory.create({
        type: MemoryType.OnThisDay,
        data: { year: 2024, title: 'A day by the sea', subtitle: 'An afternoon together' },
      });
      const result = mapMemory(getForMemory(memory) as any, factory.auth());
      expect(result.title).toBe('A day by the sea');
      expect(result.subtitle).toBe('An afternoon together');
      expect(result.data.year).toBe(2024);
    });
    it('should surface server-owned title and subtitle for rule memories', () => {
      const memory = MemoryFactory.create({
        type: MemoryType.Rule,
        data: {
          ruleId: 'birthday',
          dedupeKey: 'birthday:person-1:2026-04-23',
          title: 'Happy birthday, Alice',
          subtitle: 'Photos from different years',
        } satisfies RuleMemoryData,
      });

      const result = mapMemory(getForMemory(memory) as any, factory.auth());

      expect(result).toEqual(
        expect.objectContaining({
          type: MemoryType.Rule,
          data: memory.data,
          title: 'Happy birthday, Alice',
          subtitle: 'Photos from different years',
        }),
      );
      expect(MemoryResponseDto.schema.safeEncode(result).success).toBe(true);
    });

    it('should preserve on-this-day responses without server-owned titles', () => {
      const memory = MemoryFactory.create({ type: MemoryType.OnThisDay, data: { year: 2024 } });

      const result = mapMemory(getForMemory(memory) as any, factory.auth());

      expect(result).toEqual(
        expect.objectContaining({
          type: MemoryType.OnThisDay,
          data: { year: 2024 },
          title: undefined,
          subtitle: undefined,
        }),
      );
      expect(MemoryResponseDto.schema.safeEncode(result).success).toBe(true);
    });
  });
});
