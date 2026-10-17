import { createZodDto } from 'nestjs-zod';
import z from 'zod';
import { Stack } from 'src/database.js';
import { AssetResponseSchema, mapAsset } from 'src/dtos/asset-response.dto.js';
import { AuthDto } from 'src/dtos/auth.dto.js';

const StackSearchSchema = z
  .object({
    primaryAssetId: z.uuidv4().optional().describe('Filter by primary asset ID'),
  })
  .meta({ id: 'StackSearchDto' });

const StackCreateSchema = z
  .object({
    assetIds: z.array(z.uuidv4()).min(2).describe('Asset IDs (first becomes primary, min 2)'),
    automatic: z.boolean().optional().describe('Respect persistent user suppression for automated grouping'),
  })
  .meta({ id: 'StackCreateDto' });

const StackUpdateSchema = z
  .object({
    primaryAssetId: z.uuidv4().optional().describe('Primary asset ID'),
  })
  .meta({ id: 'StackUpdateDto' });

const StackResponseSchema = z
  .object({
    id: z.uuidv4().describe('Stack ID'),
    primaryAssetId: z.uuidv4().describe('Primary asset ID'),
    assets: z.array(AssetResponseSchema),
  })
  .describe('Stack response')
  .meta({ id: 'StackResponseDto' });

export class StackSearchDto extends createZodDto(StackSearchSchema) {}
export class StackCreateDto extends createZodDto(StackCreateSchema) {}
export class StackUpdateDto extends createZodDto(StackUpdateSchema) {}
export class StackResponseDto extends createZodDto(StackResponseSchema) {}

export class StackSuppressionSearchDto extends createZodDto(
  z.object({ page: z.coerce.number().int().min(1).default(1) }),
) {}
export class StackSuppressionResponseDto extends createZodDto(z.object({ assetId: z.uuidv4() })) {}

export const mapStack = (stack: Stack, { auth }: { auth?: AuthDto }) => {
  const primary = stack.assets.filter((asset) => asset.id === stack.primaryAssetId);
  const others = stack.assets.filter((asset) => asset.id !== stack.primaryAssetId);

  return {
    id: stack.id,
    primaryAssetId: stack.primaryAssetId,
    assets: [...primary, ...others].map((asset) => mapAsset(asset, { auth })),
  };
};
