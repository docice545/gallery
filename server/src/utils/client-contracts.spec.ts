import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

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
        return [key, api.paths[path]?.[method]];
      }),
    );
    expect(digest(operations)).toBe(baseline.operationsDigest);
  });
  it('preserves every existing schema except additive sync enum extensions', () => {
    const schemas = Object.fromEntries(baseline.schemaKeys.map((key: string) => [key, api.components.schemas[key]]));
    expect(digest(schemas)).toBe(baseline.schemasDigest);
    for (const [key, values] of Object.entries(baseline.syncEnums))
      expect(api.components.schemas[key].enum).toEqual(expect.arrayContaining(values as string[]));
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
