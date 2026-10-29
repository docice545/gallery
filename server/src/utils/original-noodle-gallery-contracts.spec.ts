import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const read = (path: string) => JSON.parse(readFileSync(resolve(import.meta.dirname, '../../..', path), 'utf8'));

const api = read('open-api/immich-openapi-specs.json');
const gate = read('server/test/contracts/original-noodle-gallery-compatibility.json');

describe('original Noodle Gallery compatibility gate', () => {
  it('pins both official client source versions and keeps native execution unclaimed', () => {
    expect(gate.status).toBe('BLOCKED');
    expect(gate.clients).toHaveLength(2);
    for (const client of gate.clients) {
      expect(client.sourceRepository).toBe('open-noodle/gallery');
      expect(client.sourceCommit).toMatch(/^[0-9a-f]{40}$/);
      expect(client.runtimeStatus).toBe('BLOCKED');
    }
    expect(gate.evidence.nativeAndroid).toBe('NOT TESTED');
    expect(gate.evidence.nativeIOS).toBe('NOT TESTED');
    expect(gate.evidence.realBackend).toMatch(/^(NOT TESTED|PASS_RUN_\d+)$/);
    if (gate.evidence.realBackend.startsWith('PASS_RUN_')) {
      expect(gate.evidence.apiSmokeCommit).toMatch(/^[0-9a-f]{40}$/);
    }
  });

  it('retains every operation required by the unchanged clients', () => {
    for (const { method, path } of gate.apiOperations) {
      expect(api.paths[path]?.[method], `${method.toUpperCase()} ${path}`).toBeDefined();
    }
  });

  it('keeps PR #7 compatibility work attached to the integration line', () => {
    expect(gate.integration.pr).toBe(7);
    expect(gate.integration.requiredCommit).toMatch(/^[0-9a-f]{40}$/);
    expect(gate.integration.requiredCommitIntegrated).toBe(true);
    expect(gate.integration.productionChanged).toBe(false);
  });

  it('records verifiable release provenance for the official Android artifacts', () => {
    for (const version of ['v5.8.0', 'v5.9.0']) {
      const artifact = gate.artifacts[version];
      expect(artifact.url).toContain(`open-noodle/gallery/releases/download/${version}/`);
      expect(artifact.tagCommit).toMatch(/^[0-9a-f]{40}$/);
      expect(artifact.sha256).toMatch(/^[0-9a-f]{64}$/);
      expect(artifact.package).toBe('de.opennoodle.gallery');
      expect(artifact.signatureScheme).toBe('v2');
      expect(artifact.certificateSha256).toMatch(/^[0-9a-f]{64}$/);
      expect(artifact.status).toBe('APK_OBTAINED_AND_SIGNATURE_VERIFIED');
    }
    expect(gate.runtimeChecks.androidEmulator).toBe('BLOCKED_NO_KVM');
    expect(gate.runtimeChecks.iosE2E).toBe('BLOCKED_NO_MACOS');
  });
});
