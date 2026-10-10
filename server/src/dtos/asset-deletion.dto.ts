import { createZodDto } from 'nestjs-zod';
import z from 'zod';

export class PermanentDeletionDto extends createZodDto(
  z
    .object({
      ids: z.array(z.uuid()).min(1).max(200),
      confirmed: z.literal(true),
    })
    .meta({ id: 'PermanentDeletionDto' }),
) {}

export class DeletionPolicyDto extends createZodDto(
  z
    .object({
      ownerId: z.uuid(),
      scope: z
        .string()
        .refine(
          (value) => value === 'managed' || z.uuid().safeParse(value).success,
          'Expected managed or a library UUID',
        ),
      enabled: z.boolean(),
      roots: z.array(z.string().min(1)).min(1).max(128),
      recoveryProof: z.string().regex(/^[a-f0-9]{64}$/),
      verifiedExclusiveRoots: z.literal(true),
    })
    .meta({ id: 'DeletionPolicyDto' }),
) {}

export class PermanentDeletionResultDto extends createZodDto(
  z
    .object({
      id: z.uuid(),
      state: z.enum(['complete', 'pending', 'failed', 'blocked']),
      code: z.string().optional(),
      scope: z.string().optional(),
    })
    .meta({ id: 'PermanentDeletionResultDto' }),
) {}

export class DeletionPreflightResultDto extends createZodDto(
  z
    .object({ id: z.uuid(), scope: z.string().optional(), authorized: z.boolean(), code: z.string().optional() })
    .meta({ id: 'DeletionPreflightResultDto' }),
) {}

export class ManagedDeletionStatusDto extends createZodDto(
  z
    .object({ enabled: z.boolean(), prepared: z.boolean(), canPrepare: z.boolean() })
    .meta({ id: 'ManagedDeletionStatusDto' }),
) {}

export class PrepareManagedDeletionDto extends createZodDto(
  z
    .object({ recoveryProof: z.string().regex(/^[a-f0-9]{64}$/), verifiedExclusiveRoots: z.literal(true) })
    .meta({ id: 'PrepareManagedDeletionDto' }),
) {}

export class ManagedDeletionConsentDto extends createZodDto(
  z.object({ enabled: z.boolean(), confirmed: z.literal(true) }).meta({ id: 'ManagedDeletionConsentDto' }),
) {}

export class TrashDeletionScopeDto extends createZodDto(
  z
    .object({ scope: z.string(), count: z.number().int().nonnegative(), authorized: z.boolean() })
    .meta({ id: 'TrashDeletionScopeDto' }),
) {}
