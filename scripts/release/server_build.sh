#!/usr/bin/env bash
# Build/export only. Never loads a production Compose file or changes services.
set -euo pipefail
[[ $# == 2 ]] || { echo 'Usage: server_build.sh EXPECTED_FULL_SHA NEW_OUTPUT_DIRECTORY' >&2; exit 2; }
release_sha="$1"
output="$2"
[[ "$release_sha" =~ ^[0-9a-f]{40}$ ]] || { echo 'FAIL full lowercase SHA required'; exit 1; }
root="$(git rev-parse --show-toplevel)"
tooling_sha="$(git rev-parse HEAD)"
git cat-file -e "${release_sha}^{commit}" 2>/dev/null || { echo 'FAIL source commit unavailable'; exit 1; }
git merge-base --is-ancestor "$release_sha" "$tooling_sha" || { echo 'FAIL source is not an ancestor of this tooling'; exit 1; }
# A failed build-only check may be corrected without recompiling a successful
# native IPA. An older explicit source is permitted ONLY when all application,
# Dockerfile, branding and dependency inputs are identical to this checkout.
git diff --quiet "$release_sha" "$tooling_sha" -- server mobile packages web i18n branding \
  package.json pnpm-lock.yaml pnpm-workspace.yaml .pnpmfile.cjs patches .dockerignore \
  || { echo 'FAIL application/build inputs differ from source; select current SHA'; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo 'FAIL checkout is not clean'; exit 1; }
origin="$(git remote get-url origin)"
[[ "$origin" == 'https://github.com/docice545/gallery.git' || "$origin" == 'https://github.com/docice545/gallery' || "$origin" == 'git@github.com:docice545/gallery.git' ]] || { echo 'FAIL wrong repository'; exit 1; }
for dependency in docker git tar jq python3 convert; do
  command -v "$dependency" >/dev/null || { echo "FAIL missing $dependency"; exit 1; }
done
docker info >/dev/null
[[ ! -e "$output" ]] || { echo 'FAIL output already exists; nothing overwritten'; exit 1; }
context="$(mktemp -d)"
trap 'rm -rf -- "$context"' EXIT
mkdir -m 700 -p "$output"
output="$(realpath "$output")"
# Build a committed tree, never local signing files, generated files or .env.
git archive --format=tar "$release_sha" | tar -x -C "$context"
FORK_VERSION=5.7.2 BUILD_NUMBER=9 bash "$context/branding/scripts/apply-branding.sh" > "$output/branding.log" 2>&1
image="gallery-server:trash-${release_sha:0:12}"
docker build --platform linux/amd64 --file "$context/server/Dockerfile" \
  --build-arg BUILD_VERSION=5.7.2 --build-arg BUILD_SOURCE_REF=v5.7.2 \
  --build-arg "BUILD_SOURCE_COMMIT=$release_sha" --build-arg BUILD_REPOSITORY=docice545/gallery \
  --build-arg "BUILD_ID=${GITHUB_RUN_ID:-9}" --tag "$image" "$context"
docker image inspect "$image" > "$output/image-inspect.json"
python3 - "$output/image-inspect.json" "$release_sha" <<'PY'
import json, sys
image = json.load(open(sys.argv[1]))[0]
env = dict(value.split('=', 1) for value in image['Config']['Env'] if '=' in value)
assert image['Architecture'] == 'amd64'
assert env['IMMICH_SOURCE_COMMIT'] == sys.argv[2]
assert env['IMMICH_SOURCE_REF'] == 'v5.7.2'
assert env['IMMICH_REPOSITORY'] == 'docice545/gallery'
print('PASS image architecture and source revision')
PY
docker run --rm --network none --entrypoint node "$image" -e '
const p=require("./server/package.json"); if(p.version!=="5.7.2") process.exit(1);
const fs=require("fs"); if(!fs.existsSync("./server/dist/main.js")) process.exit(1);
console.log("PASS packaged server version 5.7.2 and compiled entrypoint");'
docker save "$image" | gzip -n > "$output/gallery-server-linux-amd64.tar.gz"
python3 - "$output" "$release_sha" "$image" "$tooling_sha" <<'PY'
import hashlib, json, pathlib, sys
directory = pathlib.Path(sys.argv[1]); artifact = directory / 'gallery-server-linux-amd64.tar.gz'
digest = hashlib.file_digest(artifact.open('rb'), 'sha256').hexdigest()
image = json.loads((directory / 'image-inspect.json').read_text())[0]
manifest = dict(sourceCommit=sys.argv[2], toolingCommit=sys.argv[4], serverVersion='5.7.2', mobileVersion='5.7.2', mobileBuild=9,
                imageTag=sys.argv[3], imageId=image['Id'], platform='linux/amd64', archiveSHA256=digest,
                deployment='NOT_DEPLOYED', schemaDelta='ADDITIVE_AUTHORIZED_DELETION', migrationsAdded=['1793600000000-AddAuthorizedAssetDeletion'], signing='NOT_APPLICABLE')
(directory / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
(directory / 'SHA256SUMS').write_text(digest + '  ' + artifact.name + '\n')
print('PASS backend artifact:', artifact)
print('SHA256:', digest)
PY
