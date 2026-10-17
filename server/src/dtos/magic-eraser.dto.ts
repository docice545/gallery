import { createZodDto } from 'nestjs-zod';
import z from 'zod';

export const MAGIC_ERASER_LIMITS = { maxStrokes: 64, maxPoints: 8192, maxRadius: 0.25, maxPixels: 36_000_000 };

const StrokeSchema = z.object({
  points: z
    .array(
      z.object({
        x: z.number().min(0).max(1).meta({ format: 'double' }),
        y: z.number().min(0).max(1).meta({ format: 'double' }),
      }),
    )
    .min(1)
    .max(1024),
  radius: z.number().min(0.001).max(MAGIC_ERASER_LIMITS.maxRadius).meta({ format: 'double' }),
  erase: z.boolean(),
});

const CreateSchema = z
  .object({
    strokes: z.array(StrokeSchema).min(1).max(MAGIC_ERASER_LIMITS.maxStrokes),
  })
  .superRefine(({ strokes }, ctx) => {
    if (strokes.reduce((sum, stroke) => sum + stroke.points.length, 0) > MAGIC_ERASER_LIMITS.maxPoints) {
      ctx.addIssue({ code: 'custom', path: ['strokes'], message: 'Too many mask points' });
    }
    if (strokes.every((stroke) => stroke.erase)) {
      ctx.addIssue({ code: 'custom', path: ['strokes'], message: 'Mask must contain an additive stroke' });
    }
  })
  .meta({ id: 'MagicEraserCreateDto' });

const JobParamsSchema = z.object({ id: z.uuidv4(), jobId: z.uuidv4() }).meta({ id: 'MagicEraserJobParamsDto' });
const StatusSchema = z.enum(['queued', 'processing', 'ready', 'failed', 'saved', 'cancelled']);
const JobSchema = z
  .object({
    id: z.uuidv4(),
    status: StatusSchema,
    assetId: z.uuidv4().optional(),
    errorCode: z.enum(['unavailable', 'invalid', 'busy', 'processing_failed']).optional(),
  })
  .meta({ id: 'MagicEraserJobResponseDto' });
const CapabilitiesSchema = z
  .object({
    enabled: z.boolean(),
    model: z.literal('big-lama'),
    maxStrokes: z.number().int(),
    maxPoints: z.number().int(),
    maxRadius: z.number().meta({ format: 'double' }),
    maxPixels: z.number().int(),
    saveCopyOnly: z.literal(true),
  })
  .meta({ id: 'MagicEraserCapabilitiesDto' });

export type MagicEraserStatus = z.infer<typeof StatusSchema>;
export class MagicEraserCreateDto extends createZodDto(CreateSchema) {}
export class MagicEraserJobParamsDto extends createZodDto(JobParamsSchema) {}
export class MagicEraserJobResponseDto extends createZodDto(JobSchema) {}
export class MagicEraserCapabilitiesDto extends createZodDto(CapabilitiesSchema) {}
