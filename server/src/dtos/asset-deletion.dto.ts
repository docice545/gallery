import { createZodDto } from 'nestjs-zod';
import z from 'zod';

// Release and authorization tooling submit the SHA-256 digest of the signed
// recovery envelope. The server resolves that digest in its protected trust
// store and verifies the envelope, owner/scope, roots, and freshness there.
const recoveryProof = z.string().regex(/^[a-f0-9]{64}$/);

const PermanentDeletionBatchStateSchema = z
  .enum(['pending', 'active', 'complete', 'failed', 'cancelled'])
  .meta({ id: 'PermanentDeletionBatchState' });

export class PermanentDeletionDto extends createZodDto(
  z
    .object({
      // Requests above the inline limit are handled by the durable bounded worker.
      ids: z.array(z.uuid()).min(1).max(5000),
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
      recoveryProof,
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
      batchId: z.string().optional().describe('Durable batch job id when deletion is queued.'),
    })
    .meta({ id: 'PermanentDeletionResultDto' }),
) {}

export class PermanentDeletionBatchStatusDto extends createZodDto(
  z
    .object({
      id: z.string().describe('Durable deletion batch job id.'),
      state: PermanentDeletionBatchStateSchema,
      cancelRequested: z.boolean().optional().describe('Cancellation requested; an active chunk may still finish.'),
      total: z.number().int().nonnegative(),
      processed: z.number().int().nonnegative(),
      complete: z.number().int().nonnegative(),
      failed: z.number().int().nonnegative(),
      pending: z.number().int().nonnegative(),
    })
    .meta({ id: 'PermanentDeletionBatchStatusDto' }),
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
  z.object({ recoveryProof, verifiedExclusiveRoots: z.literal(true) }).meta({ id: 'PrepareManagedDeletionDto' }),
) {}

export class AdminPrepareDeletionDto extends createZodDto(
  PrepareManagedDeletionDto.schema.extend({ ownerId: z.uuid() }).strict().meta({ id: 'AdminPrepareDeletionDto' }),
) {}

export class ManagedDeletionConsentDto extends createZodDto(
  z.object({ enabled: z.boolean(), confirmed: z.literal(true) }).meta({ id: 'ManagedDeletionConsentDto' }),
) {}

export class TrashDeletionScopeDto extends createZodDto(
  z
    .object({
      scope: z.string(),
      name: z.string().optional(),
      count: z.number().int().nonnegative(),
      authorized: z.boolean(),
    })
    .meta({ id: 'TrashDeletionScopeDto' }),
) {}
