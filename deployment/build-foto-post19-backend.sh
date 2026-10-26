#!/usr/bin/env bash
# Owner-run build only; no service start, deployment, APK or data operations.
set -euo pipefail
FOTO_FIX_SHA=${1:?Usage: build-foto-post19-backend.sh REVIEWED_FULL_SHA [SOURCE_REPOSITORY]}
FOTO_SOURCE_REPOSITORY=${2:-/mnt/hp-data/foto-build19-source}
cd "$FOTO_SOURCE_REPOSITORY"
FOTO_BASE_SHA=e2a95e6aeee9d9da8d23ca7643a6a061c61944c3
[[ "$FOTO_FIX_SHA" =~ ^[0-9a-f]{40}$ ]]
test "$(git rev-parse HEAD)" = "$FOTO_BASE_SHA"
test -z "$(git status --porcelain)"
test ! -e .foto-build18-heavy.lock
test ! -e .foto-build19-heavy.lock
# Also honor any other active owner-documented build lock; inspect, never delete.

git fetch origin \
  refs/heads/codex/foto-post-build19-asset-consistency:refs/remotes/origin/foto-post19-review
git cat-file -e "${FOTO_FIX_SHA}^{commit}"
git merge-base --is-ancestor "$FOTO_BASE_SHA" "$FOTO_FIX_SHA"
git merge-base --is-ancestor "$FOTO_FIX_SHA" refs/remotes/origin/foto-post19-review
git cat-file -e "${FOTO_FIX_SHA}:deployment/foto-post19-backend.Dockerfile"
git diff --quiet "$FOTO_BASE_SHA" "$FOTO_FIX_SHA" -- \
  package.json pnpm-lock.yaml pnpm-workspace.yaml .pnpmfile.cjs patches \
  packages open-api machine-learning branding \
  server/package.json server/Dockerfile server/bin server/src/schema
git diff --name-only "$FOTO_BASE_SHA" "$FOTO_FIX_SHA"

foto_docker() {
  env -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_TLS \
    -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
    docker --context default "$@"
}
FOTO_DOCKER_ENDPOINT=$(docker context inspect default --format '{{.Endpoints.docker.Host}}')
case "$FOTO_DOCKER_ENDPOINT" in unix://*) ;; *) exit 1 ;; esac
test "$(foto_docker buildx inspect default --format '{{.Driver}}')" = docker

FOTO_BASE_IMAGE=foto-build19-web:e2a95e6
FOTO_BASE_ID=$(foto_docker image inspect "$FOTO_BASE_IMAGE" --format '{{.Id}}')
FOTO_BASE_USER=$(foto_docker image inspect "$FOTO_BASE_IMAGE" --format '{{.Config.User}}')
FOTO_RUNTIME_USER=${FOTO_BASE_USER:-0}
FOTO_BASE_PLATFORM=$(foto_docker image inspect "$FOTO_BASE_IMAGE" --format '{{.Os}}/{{.Architecture}}')
FOTO_FIX_SHORT=${FOTO_FIX_SHA:0:12}
FOTO_ASSETS_IMAGE="foto-post19-backend-assets:${FOTO_FIX_SHORT}"
FOTO_IMAGE_TAG="foto-post19-backend:${FOTO_FIX_SHORT}"
FOTO_BUILD_ID="foto-post19-backend-${FOTO_FIX_SHORT}"
FOTO_API_VERSION=5.7.3
# Refuse to replace any previously built candidate tag.
if foto_docker image inspect "$FOTO_ASSETS_IMAGE" >/dev/null 2>&1; then exit 1; fi
if foto_docker image inspect "$FOTO_IMAGE_TAG" >/dev/null 2>&1; then exit 1; fi

# Existing release branding prerequisites; install nothing in this procedure.
command -v jq >/dev/null
command -v identify >/dev/null
if ! command -v convert >/dev/null && ! command -v magick >/dev/null; then exit 1; fi

FOTO_BUILD_CONTEXT=$(mktemp -d /mnt/hp-data/foto-post19-context.XXXXXXXX)
git archive "$FOTO_FIX_SHA" | tar -x -C "$FOTO_BUILD_CONTEXT"
# Only tracked reviewed files are archived. No checkout .env, signing files,
# untracked data, caches or user media can enter this new build context.
(
  cd "$FOTO_BUILD_CONTEXT"
  # Same script and verification as .github/actions/apply-branding/action.yml.
  # Explicit version avoids git-describe on an archive with no .git directory.
  FORK_VERSION="$FOTO_API_VERSION" BUILD_NUMBER=19 \
    ./branding/scripts/apply-branding.sh
  ./branding/scripts/verify-branding.sh
)

# This target builds SDK/plugin-SDK/server only; no Web/CLI/plugin runtime or ML
# stage, no running application and no production mount is involved.
foto_docker build --builder default --pull=false \
  --platform "$FOTO_BASE_PLATFORM" \
  --file "$FOTO_BUILD_CONTEXT/server/Dockerfile" --target server \
  --tag "$FOTO_ASSETS_IMAGE" "$FOTO_BUILD_CONTEXT"

test "$(foto_docker image inspect "$FOTO_BASE_IMAGE" --format '{{.Id}}')" = "$FOTO_BASE_ID"
foto_docker build --builder default --pull=false \
  --platform "$FOTO_BASE_PLATFORM" \
  --file "$FOTO_BUILD_CONTEXT/deployment/foto-post19-backend.Dockerfile" \
  --build-arg "FOTO_BACKEND_ASSETS_IMAGE=$FOTO_ASSETS_IMAGE" \
  --build-arg "FOTO_BASE_IMAGE=$FOTO_BASE_IMAGE" \
  --build-arg "FOTO_RUNTIME_USER=$FOTO_RUNTIME_USER" \
  --build-arg "FOTO_BASE_ID=$FOTO_BASE_ID" \
  --build-arg "FOTO_BACKEND_SOURCE_COMMIT=$FOTO_FIX_SHA" \
  --build-arg "FOTO_BUILD_ID=$FOTO_BUILD_ID" \
  --build-arg "FOTO_IMAGE_TAG=$FOTO_IMAGE_TAG" \
  --build-arg "FOTO_API_VERSION=$FOTO_API_VERSION" \
  --tag "$FOTO_IMAGE_TAG" "$FOTO_BUILD_CONTEXT"

test "$(foto_docker image inspect "$FOTO_BASE_IMAGE" --format '{{.Id}}')" = "$FOTO_BASE_ID"
test "$(foto_docker image inspect "$FOTO_IMAGE_TAG" --format '{{.Config.User}}')" = "$FOTO_RUNTIME_USER"
test "$(foto_docker image inspect "$FOTO_IMAGE_TAG" --format '{{index .Config.Labels "de.opennoodle.foto.backend.source-commit"}}')" = "$FOTO_FIX_SHA"
foto_docker image inspect "$FOTO_BASE_IMAGE" "$FOTO_IMAGE_TAG" \
  --format '{"id":{{json .Id}},"layers":{{json .RootFS.Layers}},"entrypoint":{{json (index .Config "Entrypoint")}},"cmd":{{json (index .Config "Cmd")}},"healthcheck":{{json (index .Config "Healthcheck")}},"workdir":{{json (index .Config "WorkingDir")}},"ports":{{json (index .Config "ExposedPorts")}},"volumes":{{json (index .Config "Volumes")}}}' \
  > "$FOTO_BUILD_CONTEXT/image-runtime-checks.jsonl"
python3 - "$FOTO_BUILD_CONTEXT/image-runtime-checks.jsonl" <<'PY'
import json, sys
old, new = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
prefix = old['layers']
assert new['layers'][:len(prefix)] == prefix, 'Candidate does not inherit exact recorded base layers'
for key in ('entrypoint', 'cmd', 'healthcheck', 'workdir', 'ports', 'volumes'):
    assert old.get(key) == new.get(key), key
print('Exact base layer prefix and inherited runtime configuration verified.')
PY
foto_docker image inspect "$FOTO_IMAGE_TAG" --format 'Prepared candidate: {{.Id}}'
test "$(git rev-parse HEAD)" = "$FOTO_BASE_SHA"
test -z "$(git status --porcelain)"
