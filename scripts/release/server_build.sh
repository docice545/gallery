#!/usr/bin/env bash
# Build/export only. Never loads a production Compose file or changes services.
set -euo pipefail
[[ $# == 2 || ( $# == 3 && "$3" == --check ) ]] || { echo 'Usage: server_build.sh EXPECTED_FULL_SHA NEW_OUTPUT_DIRECTORY [--check]' >&2; exit 2; }
release_sha="$1"
output="$2"
[[ "$release_sha" =~ ^[0-9a-f]{40}$ ]] || { echo 'FAIL full lowercase SHA required'; exit 1; }
# Recorded production schema baseline. A different reviewed baseline must be
# supplied explicitly; it is recorded with every migration name/content hash.
migration_base="${MIGRATION_BASE_SHA:-e6ab95e695f085c3016072ebff44d4ba02695cb5}"
[[ "$migration_base" =~ ^[0-9a-f]{40}$ ]] || { echo 'FAIL full migration baseline SHA required'; exit 1; }
root="$(git rev-parse --show-toplevel)"
tooling_sha="$(git rev-parse HEAD)"
git cat-file -e "${release_sha}^{commit}" 2>/dev/null || { echo 'FAIL source commit unavailable'; exit 1; }
git merge-base --is-ancestor "$release_sha" "$tooling_sha" || { echo 'FAIL source is not an ancestor of this tooling'; exit 1; }
git cat-file -e "${migration_base}^{commit}" 2>/dev/null || { echo 'FAIL migration baseline commit unavailable'; exit 1; }
git merge-base --is-ancestor "$migration_base" "$release_sha" || { echo 'FAIL migration baseline is not an ancestor of source'; exit 1; }
# A failed build-only check may be corrected without recompiling a successful
# native IPA. An older explicit source is permitted ONLY when all application,
# Dockerfile, branding and dependency inputs are identical to this checkout.
git diff --quiet "$release_sha" "$tooling_sha" -- server mobile packages web i18n branding \
  package.json pnpm-lock.yaml pnpm-workspace.yaml .pnpmfile.cjs patches .dockerignore \
  || { echo 'FAIL application/build inputs differ from source; select current SHA'; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo 'FAIL checkout is not clean'; exit 1; }
origin="$(git remote get-url origin)"
[[ "$origin" == 'https://github.com/docice545/gallery.git' || "$origin" == 'https://github.com/docice545/gallery' || "$origin" == 'git@github.com:docice545/gallery.git' ]] || { echo 'FAIL wrong repository'; exit 1; }
source_metadata="$(python3 - "$root" "$release_sha" "$migration_base" <<'PY_SOURCE_METADATA'
import hashlib, json, pathlib, re, subprocess, sys

root, source, baseline = sys.argv[1:]
def git(*args):
    return subprocess.check_output(['git', '-C', root, *args])
def need(value, message):
    if not value:
        raise SystemExit('FAIL ' + message)

# Read the committed source, never the worktree or caller's version variables.
pubspec = git('show', source + ':mobile/pubspec.yaml').decode()
entries = re.findall(r'^version:\s*([^\n]+)$', pubspec, re.MULTILINE)
need(len(entries) == 1, 'one committed mobile release version required')
match = re.fullmatch(r'((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))\+([1-9][0-9]*)\s*', entries[0])
need(match is not None, 'committed mobile semantic version and positive build required')
version, build = match.group(1), int(match.group(2))
need(build <= 2100000000, 'committed mobile build exceeds Android version code limit')

roots = ('server/src/schema/migrations', 'server/src/schema/migrations-gallery')
# Preserve the upstream filename/ledger identity; never rename a migration that
# existing databases have applied. This is the sole nonstandard source name and
# is admitted only with its immutable, reviewed bytes.
legacy_sources = {
    'server/src/schema/migrations/1774548649115-AddChecksumAlgorithm.ts.ts':
        '64f3e4c147deb4d57d92dbc5e556ef081110923f08953865bb0bba36312944af',
}
def migrations(commit):
    found = {}
    for entry in git('ls-tree', '-r', '-z', commit, '--', *roots).split(b'\0'):
        if not entry:
            continue
        header, raw_path = entry.split(b'\t', 1)
        path = raw_path.decode()
        if not path.endswith('.ts'):
            continue
        mode, kind, _ = header.decode().split()
        name = pathlib.PurePosixPath(path).stem
        digest = hashlib.sha256(git('show', commit + ':' + path)).hexdigest()
        need(mode in ('100644', '100755') and kind == 'blob' and
             str(pathlib.PurePosixPath(path).parent) in roots and
             (re.fullmatch(r'[0-9]+-[A-Za-z0-9_-]+', name) or legacy_sources.get(path) == digest),
             'regular named migration source required')
        need(name not in found or found[name]['sha256'] == digest, 'conflicting duplicate migration source')
        found[name] = {'name': name, 'path': path, 'sha256': digest}
    return found

before, after = migrations(baseline), migrations(source)
need(before.keys() <= after.keys(), 'existing migration removed; separate compatibility review required')
need(all(before[name]['sha256'] == after[name]['sha256'] for name in before),
     'existing migration modified; separate compatibility review required')
added = sorted(after.keys() - before.keys())
print(json.dumps({'sourceCommit': source, 'serverVersion': version, 'mobileVersion': version,
                  'mobileBuild': build, 'migrationBase': baseline,
                  'schemaDelta': 'MIGRATION_FILES_ADDED' if added else 'NONE_FROM_MIGRATION_BASE',
                  'migrationsAdded': added, 'migrationFilesAdded': [after[name] for name in added]}))
PY_SOURCE_METADATA
)"
# Check exact source metadata and migration delta without Docker or artifact output.
if [[ "${3:-}" == --check ]]; then
  python3 -c 'import json, sys; print(json.dumps(json.loads(sys.argv[1]), indent=2))' "$source_metadata"
  exit 0
fi
release_version="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1])["serverVersion"])' "$source_metadata")"
release_build="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1])["mobileBuild"])' "$source_metadata")"
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
FORK_VERSION="$release_version" BUILD_NUMBER="$release_build" bash "$context/branding/scripts/apply-branding.sh" > "$output/branding.log" 2>&1
image="gallery-server:trash-${release_sha:0:12}"
docker build --platform linux/amd64 --file "$context/server/Dockerfile" \
  --build-arg "BUILD_VERSION=$release_version" --build-arg "BUILD_SOURCE_REF=v$release_version" \
  --build-arg "BUILD_SOURCE_COMMIT=$release_sha" --build-arg BUILD_REPOSITORY=docice545/gallery \
  --build-arg "BUILD_ID=${GITHUB_RUN_ID:-$release_build}" --tag "$image" "$context"
docker image inspect "$image" > "$output/image-inspect.json"
python3 - "$output/image-inspect.json" "$release_sha" "$release_version" <<'PY'
import json, sys
image = json.load(open(sys.argv[1]))[0]
env = dict(value.split('=', 1) for value in image['Config']['Env'] if '=' in value)
assert image['Architecture'] == 'amd64'
assert env['IMMICH_SOURCE_COMMIT'] == sys.argv[2]
assert env['IMMICH_SOURCE_REF'] == 'v' + sys.argv[3]
assert env['IMMICH_REPOSITORY'] == 'docice545/gallery'
print('PASS image architecture and source revision')
PY
docker run --rm --network none --read-only --entrypoint node "$image" -e '
const [version, metadata] = process.argv.slice(1);
const p=require("./server/package.json"); if(p.version!==version) process.exit(1);
const fs=require("fs"); if(!fs.existsSync("./server/dist/main.js")) process.exit(1);
for(const migration of JSON.parse(metadata).migrationFilesAdded) {
  const compiled = "./" + migration.path.replace("/src/", "/dist/").replace(/\.ts$/, ".js");
  if(!fs.existsSync(compiled)) process.exit(1);
}
console.log("PASS packaged server version " + version + ", compiled entrypoint and source migration additions");' "$release_version" "$source_metadata"
docker save "$image" | gzip -n > "$output/gallery-server-linux-amd64.tar.gz"
python3 - "$output" "$release_sha" "$image" "$tooling_sha" "$source_metadata" <<'PY'
import hashlib, json, pathlib, sys
directory = pathlib.Path(sys.argv[1]); artifact = directory / 'gallery-server-linux-amd64.tar.gz'
digest = hashlib.file_digest(artifact.open('rb'), 'sha256').hexdigest()
image = json.loads((directory / 'image-inspect.json').read_text())[0]
metadata = json.loads(sys.argv[5])
assert metadata['sourceCommit'] == sys.argv[2]
manifest = dict(**metadata, toolingCommit=sys.argv[4],
                imageTag=sys.argv[3], imageId=image['Id'], platform='linux/amd64', archiveSHA256=digest,
                deployment='NOT_DEPLOYED', signing='NOT_APPLICABLE')
(directory / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
(directory / 'SHA256SUMS').write_text(digest + '  ' + artifact.name + '\n')
print('PASS backend artifact:', artifact)
print('SHA256:', digest)
PY
