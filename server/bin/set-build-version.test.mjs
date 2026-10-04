import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { stampBuildVersion } from './set-build-version.mjs';

const withManifest = (t, version) => {
  const folder = mkdtempSync(join(tmpdir(), 'gallery-build-version-'));
  t.after(() => rmSync(folder, { recursive: true, force: true }));
  const file = join(folder, 'package.json');
  writeFileSync(file, `${JSON.stringify({ name: 'immich', version, dependencies: { semver: '^7.8.1' } }, null, 2)}\n`);
  return file;
};

test('stamps the runtime package with the Gallery release instead of the upstream package version', (t) => {
  const file = withManifest(t, '3.2.0');
  assert.equal(stampBuildVersion('5.7.1', file), '5.7.1');
  assert.deepEqual(JSON.parse(readFileSync(file, 'utf8')), {
    name: 'immich',
    version: '5.7.1',
    dependencies: { semver: '^7.8.1' },
  });
});

test('accepts the official v-prefixed release input', (t) => {
  const file = withManifest(t, '3.2.0');
  assert.equal(stampBuildVersion('v5.7.1', file), '5.7.1');
});

test('supports later release bumps and release candidates', (t) => {
  const file = withManifest(t, '3.2.0');
  assert.equal(stampBuildVersion('v6.1.0-rc.2', file), '6.1.0-rc.2');
  assert.equal(JSON.parse(readFileSync(file, 'utf8')).version, '6.1.0-rc.2');
});

test('preserves the official pre-stamped package when no build argument is supplied', (t) => {
  const file = withManifest(t, '5.7.1');
  const before = readFileSync(file, 'utf8');
  assert.equal(stampBuildVersion(undefined, file), '5.7.1');
  assert.equal(stampBuildVersion('', file), '5.7.1');
  assert.equal(readFileSync(file, 'utf8'), before);
});

test('keeps the package version as the development fallback', (t) => {
  const file = withManifest(t, '3.2.0');
  assert.equal(stampBuildVersion(undefined, file), '3.2.0');
});

test('fails the build for an invalid release rather than silently reporting the upstream version', (t) => {
  const file = withManifest(t, '3.2.0');
  const before = readFileSync(file, 'utf8');
  for (const invalid of ['v5', 'release', '5.7', '5.7.1-extra!']) {
    assert.throws(() => stampBuildVersion(invalid, file), /Invalid Version/);
  }
  assert.equal(readFileSync(file, 'utf8'), before);
});
