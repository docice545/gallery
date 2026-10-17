import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SemVer } from 'semver';

const defaultPackageFile = fileURLToPath(new URL('../package.json', import.meta.url));

// The release branding action stamps package.json before the Docker build. Local
// image builds can stamp the same runtime manifest with BUILD_VERSION instead.
export const stampBuildVersion = (buildVersion, packageFile = defaultPackageFile) => {
  const manifest = JSON.parse(readFileSync(packageFile, 'utf8'));
  const requestedVersion = buildVersion?.trim();
  const version = new SemVer(requestedVersion || manifest.version).version;

  if (requestedVersion) {
    manifest.version = version;
    writeFileSync(packageFile, `${JSON.stringify(manifest, null, 2)}\n`);
  }

  return version;
};

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  console.log(`Server release version: ${stampBuildVersion(process.argv[2])}`);
}
