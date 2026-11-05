import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { PermanentDeletionDto, PermanentDeletionResultDto } from 'src/dtos/asset-deletion.dto.js';

const read = (path: string) => JSON.parse(readFileSync(resolve(import.meta.dirname, '../../..', path), 'utf8'));
const api = read('open-api/immich-openapi-specs.json');
const baseline = read('server/test/contracts/foto17-base-api.json');
const official = read('server/test/contracts/immich-3.3.5-sync-shapes.json');
const canonical = (value: any): any =>
  Array.isArray(value)
    ? value.map((item: any) => canonical(item))
    : value && typeof value === 'object'
      ? Object.fromEntries(
          Object.keys(value)
            .sort()
            .map((k) => [k, canonical(value[k])]),
        )
      : value;
const digest = (value: unknown) =>
  createHash('sha256')
    .update(JSON.stringify(canonical(value)))
    .digest('hex');

const shape = (value: any): any => {
  if (value.$ref) return shape(api.components.schemas[value.$ref.split('/').at(-1)]);
  return {
    ...Object.fromEntries(
      ['type', 'format', 'nullable', 'enum', 'required'].filter((k) => k in value).map((k) => [k, value[k]]),
    ),
    ...(value.properties && {
      properties: Object.fromEntries(Object.entries(value.properties).map(([k, v]) => [k, shape(v)])),
    }),
    ...(value.items && { items: shape(value.items) }),
    ...Object.fromEntries(
      ['allOf', 'anyOf', 'oneOf'].filter((k) => k in value).map((k) => [k, value[k].map((item: any) => shape(item))]),
    ),
  };
};

describe('pinned client contracts', () => {
  it('preserves every existing FOTO operation definition', () => {
    const operations = Object.fromEntries(
      baseline.operationKeys.map((key: string) => {
        const [method, path] = key.split(' ', 2);
        const operation = structuredClone(api.paths[path]?.[method]);
        // Normalize only explicitly tested additive extensions. Every
        // pre-existing definition remains pinned to the immutable digest.
        if (key === 'get /sync/ack') {
          delete operation.responses['409'];
        } else if (key === 'post /assets/{id}/magic-eraser/{jobId}/save') {
          // The save hint is optional; bodyless clients retain this exact legacy
          // operation. Check the additive contract before comparing the rest.
          expect(operation.requestBody).toEqual({
            required: false,
            content: { 'application/json': { schema: { $ref: '#/components/schemas/MagicEraserSaveDto' } } },
          });
          delete operation.requestBody;
        }
        return [key, operation];
      }),
    );
    expect(digest(operations)).toBe(baseline.operationsDigest);
  });
  it('keeps the new save offset hint optional for existing bodyless clients', () => {
    const schema = api.components.schemas.MagicEraserSaveDto;
    expect(schema.default).toEqual({});
    expect(schema.required ?? []).toEqual([]);
    expect(schema.properties.timeZoneOffsetMinutes).toMatchObject({ type: 'integer', minimum: -720, maximum: 840 });
  });
  it('keeps irreversible admission opt-in while accepting legacy deletion request and result bodies', () => {
    const id = '123e4567-e89b-42d3-a456-426614174000';
    const request = { ids: [id], confirmed: true };
    const result = { id, state: 'pending' };

    expect(PermanentDeletionDto.schema.parse(request)).toEqual(request);
    expect(PermanentDeletionDto.schema.parse({ ...request, acceptOnly: true })).toEqual({
      ...request,
      acceptOnly: true,
    });
    expect(PermanentDeletionDto.schema.safeParse({ ...request, acceptOnly: false }).success).toBe(false);
    expect(PermanentDeletionDto.schema.safeParse({ ...request, confirmed: false }).success).toBe(false);
    expect(PermanentDeletionResultDto.schema.parse(result)).toEqual(result);
    expect(PermanentDeletionResultDto.schema.parse({ ...result, accepted: true })).toEqual({
      ...result,
      accepted: true,
    });
    expect(PermanentDeletionResultDto.schema.safeParse({ ...result, accepted: false }).success).toBe(false);
  });
  it('preserves every existing schema except explicitly checked additive extensions', () => {
    const schemas = Object.fromEntries(
      baseline.schemaKeys.map((key: string) => [key, structuredClone(api.components.schemas[key])]),
    );
    // The new named enum is structurally identical to the old response enum,
    // checked below against the immutable baseline rather than an updated hash.
    schemas.SyncAckDto.properties.type.$ref = '#/components/schemas/SyncEntityType';
    // Build 29 added two opt-in admission flags. Check their complete wire
    // definitions and optionality before projecting only those properties out
    // of the immutable legacy schema comparison. Never re-pin the baseline hash.
    expect(schemas.PermanentDeletionDto.properties.acceptOnly).toEqual({
      description: 'Commit an irreversible decision and delete files in the background.',
      enum: [true],
      type: 'boolean',
    });
    expect(schemas.PermanentDeletionDto.required).not.toContain('acceptOnly');
    expect(schemas.PermanentDeletionResultDto.properties.accepted).toEqual({
      description: 'An owner-scoped irreversible PostgreSQL intent is committed.',
      enum: [true],
      type: 'boolean',
    });
    expect(schemas.PermanentDeletionResultDto.required).not.toContain('accepted');
    delete schemas.PermanentDeletionDto.properties.acceptOnly;
    delete schemas.PermanentDeletionResultDto.properties.accepted;
    expect(digest(schemas)).toBe(baseline.schemasDigest);
    for (const [key, values] of Object.entries(baseline.syncEnums))
      expect(api.components.schemas[key].enum).toEqual(expect.arrayContaining(values as string[]));
  });
  it('freezes the legacy ACK enum and exposes extensions only on the versioned read', () => {
    expect(api.components.schemas.LegacySyncEntityType.enum).toEqual(baseline.syncEnums.SyncEntityType);
    expect(api.components.schemas.SyncAckDto.properties.type.$ref).toBe('#/components/schemas/LegacySyncEntityType');
    expect(api.paths['/sync/ack'].get.responses['409'].description).toBe(
      'Extended sync checkpoints require GET /sync/ack/v2',
    );
    expect(api.paths['/sync/ack/v2'].get.responses['200'].content['application/json'].schema.items.$ref).toBe(
      '#/components/schemas/SyncAckV2Dto',
    );
    expect(api.components.schemas.SyncAckV2Dto.properties.type.$ref).toBe('#/components/schemas/SyncEntityType');
  });
  it.each(Object.keys(official.schemas))('%s matches the pinned official Android/iOS wire schema', (key) => {
    expect(shape(api.components.schemas[key])).toEqual(official.schemas[key]);
  });
  it('exposes all eight new canonical Noodle routes with stable operation IDs', () => {
    const required = [
      'updateAssetFavorites',
      'getEditableAssets',
      'getSpaceAssetFaces',
      'createSpacePerson',
      'createSpaceAssetFace',
      'deleteSpaceAssetFace',
      'attachSpacePersonFace',
      'detachSpacePersonFace',
    ];
    const operations = Object.values(api.paths).flatMap((path: any) =>
      Object.values(path).map((v: any) => v.operationId),
    );
    expect(operations).toEqual(expect.arrayContaining(required));
  });
});
