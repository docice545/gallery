# FOTO Build 19 Web: validation and local HP image build

The Android baseline is `d6e7113529f5f6ff13f2ffeea3a914b46286dbe7` on
`codex/foto-build19-live-photo-local-autoplay` (draft PR 11). Android is outside
this Web change. Production Build 18 is retained as `foto-build18:4aa7f419`.
No production deployment, SSH access, signing key, database, NAS or network
configuration is needed for the checks or image preparation below.

## Web checks

Use the pinned Node `24.21.0` and pnpm `11.24.0`. Preserve the lockfile. Build the
existing TypeScript SDK before installing Web consumers: the workspace injects
SDK build output into their dependency trees. These commands run from the source
root, without a backend process:

```bash
pnpm --filter @immich/sdk install --frozen-lockfile
pnpm --filter @immich/sdk build
SHARP_IGNORE_GLOBAL_LIBVIPS=true pnpm --filter immich-web install --frozen-lockfile
pnpm --filter immich-web exec vitest run
pnpm --filter immich-web check:svelte
pnpm --filter immich-web check:typescript
pnpm --filter immich-web lint
pnpm --filter immich-web format
pnpm --filter immich-web build
```

The final report and PR checks record actual results; this runbook does not
substitute commands for successful execution. Happy-dom component tests do not
establish browser decoding, rendering or memory behavior.

Browser regressions must use the existing mocked UI routes, synthetic video and
a local Web server. Disable Playwright's default Docker Compose webServer with
`PLAYWRIGHT_DISABLE_WEBSERVER=1` and point `PLAYWRIGHT_BASE_URL` to localhost.
Never direct this test suite at production. These regressions use the checked-in
`e2e/src/ui/fixtures/live-photo-autoplay.mp4`: a synthetic 60-second, 120-frame
H.264 clip (3,174 bytes). Its reproducible FFmpeg command is in the spec. HTTP
range responses match browser playback requests. Merely stretching a one-frame
fixture's timing tables produced a network/demux failure when restarting it in
the fullscreen viewer; a valid multi-frame clip confirms the existing manual
viewer without changing its production implementation.

Verify ten visible Live Photos yield at most one automatic player; central and
visible candidates win independently of registration order. Scrolling must
release playback immediately, and settling for about 350 ms may select only one
candidate. Completion must leave the rest static. Check visibility changes,
route/viewer entry and return, unmounting, rapid scroll, and ordinary video hover.
Fullscreen manual Live Photo playback must remain available. Browser findings
apply only to the tested browser/platform and mocked data; production timing,
Safari/Firefox and physical device decoding require separate owner acceptance.

The same pool owns the single feed lease for automatic Live Photos and ordinary
hovered video. Automatic selection samples clipped visibility and distance from
the viewport center after 350 ms. Completion/failure consumes the viewport's
automatic budget; actual scrolling, foreground return or route/viewer return can
open a new budget. Replacing every virtualized tile during movement preserves
that new budget, while a same-viewport remount cannot reload a completed video.
Lease revocation pauses and clears the old source synchronously before another
lease can be granted. Fullscreen manual playback uses its existing separate path.

The full regression also exposed pre-existing search test fixture timing: a
150 ms resolver replaced manually seeded choices, and an earlier manager leaked
its timer. These failures were reproduced on the untouched Android baseline;
test-only fixtures now answer both real SDK suggestion paths and close that
manager. A separate Spaces test now unmounts and drains the UI library's deferred
callbacks before happy-dom teardown. No search/Spaces product code or error
suppression was added.

## Build only new Docker images locally on HP

The owner runs this after reviewing the final Web commit in the report. This
procedure does not switch the production checkout, start Gallery, run migrations
or call Docker Compose. `git archive` supplies the reviewed tracked snapshot;
untracked keys, `.env`, caches and user media cannot enter the build context.
The existing `server/Dockerfile --target web` builds only SDK/Web stages. A tiny
overlay then replaces `/build/www` in the actual Build 18 image, retaining its
server/API, migration files, CLI and plugins. Its API version is not restamped.

Run in Bash using the existing local Docker daemon and credentials:

```bash
set -euo pipefail
cd /mnt/hp-data/foto-build18-source
git rev-parse HEAD
git status --short
test -z "$(git status --porcelain)"
# An existing heavy-build lock needs inspection by its owner; never remove it here.
test ! -e .foto-build18-heavy.lock

git fetch origin \
  refs/heads/codex/foto-build19-live-photo-local-autoplay:refs/remotes/origin/foto-build19-web-review
read -r -p 'Reviewed full Web commit SHA from the report: ' FOTO_WEB_SHA
[[ "$FOTO_WEB_SHA" =~ ^[0-9a-f]{40}$ ]]
git cat-file -e "${FOTO_WEB_SHA}^{commit}"
git merge-base --is-ancestor d6e7113529f5f6ff13f2ffeea3a914b46286dbe7 "$FOTO_WEB_SHA"
git cat-file -e "${FOTO_WEB_SHA}:deployment/foto-build19-web.Dockerfile"
git diff --quiet d6e7113529f5f6ff13f2ffeea3a914b46286dbe7 "$FOTO_WEB_SHA" -- \
  mobile server packages open-api machine-learning
git diff --name-only d6e7113529f5f6ff13f2ffeea3a914b46286dbe7 "$FOTO_WEB_SHA"

FOTO_DOCKER_CONTEXT=default
FOTO_DOCKER_BUILDER=default
foto_docker() {
  env -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_TLS \
    -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
    docker --context "$FOTO_DOCKER_CONTEXT" "$@"
}
FOTO_DOCKER_ENDPOINT=$(docker context inspect "$FOTO_DOCKER_CONTEXT" --format '{{.Endpoints.docker.Host}}')
case "$FOTO_DOCKER_ENDPOINT" in unix://*) ;; *) exit 1 ;; esac
# The docker driver sees daemon-local production/assets tags; remote builders do not.
test "$(foto_docker buildx inspect "$FOTO_DOCKER_BUILDER" --format '{{.Driver}}')" = docker

FOTO_BASE_TAG=foto-build18:4aa7f419
FOTO_BASE_ID=$(foto_docker image inspect "$FOTO_BASE_TAG" --format '{{.Id}}')
FOTO_BASE_USER=$(foto_docker image inspect "$FOTO_BASE_TAG" --format '{{.Config.User}}')
FOTO_BASE_PLATFORM=$(foto_docker image inspect "$FOTO_BASE_TAG" --format '{{.Os}}/{{.Architecture}}')
FOTO_RUNTIME_USER=${FOTO_BASE_USER:-0}
FOTO_WEB_SHORT=${FOTO_WEB_SHA:0:12}
FOTO_WEB_ASSETS_TAG="foto-build19-web-assets:${FOTO_WEB_SHORT}"
FOTO_WEB_IMAGE_TAG="foto-build19-web:${FOTO_WEB_SHORT}"
FOTO_WEB_BUILD_ID="foto-build19-web-${FOTO_WEB_SHORT}"

git archive "$FOTO_WEB_SHA" | foto_docker build \
  --builder "$FOTO_DOCKER_BUILDER" --pull=false \
  --platform "$FOTO_BASE_PLATFORM" \
  --file server/Dockerfile --target web \
  --build-arg "BUILD_ID=$FOTO_WEB_BUILD_ID" \
  --tag "$FOTO_WEB_ASSETS_TAG" -

git archive "$FOTO_WEB_SHA" | foto_docker build \
  --builder "$FOTO_DOCKER_BUILDER" --pull=false \
  --platform "$FOTO_BASE_PLATFORM" \
  --file deployment/foto-build19-web.Dockerfile \
  --build-arg "FOTO_BASE_IMAGE=$FOTO_BASE_TAG" \
  --build-arg "FOTO_WEB_ASSETS_IMAGE=$FOTO_WEB_ASSETS_TAG" \
  --build-arg "FOTO_RUNTIME_USER=$FOTO_RUNTIME_USER" \
  --build-arg "FOTO_WEB_SOURCE_COMMIT=$FOTO_WEB_SHA" \
  --tag "$FOTO_WEB_IMAGE_TAG" -

test "$(foto_docker image inspect "$FOTO_BASE_TAG" --format '{{.Id}}')" = "$FOTO_BASE_ID"
test "$(foto_docker image inspect "$FOTO_WEB_IMAGE_TAG" --format '{{.Config.User}}')" = "$FOTO_RUNTIME_USER"
test "$(foto_docker image inspect "$FOTO_WEB_IMAGE_TAG" --format '{{index .Config.Labels "de.opennoodle.foto.web.source-commit"}}')" = "$FOTO_WEB_SHA"
foto_docker image inspect "$FOTO_WEB_IMAGE_TAG" --format 'New image: {{.Id}}'
```

The Web assets build requires registry/package access through HP's existing
network configuration. A missing local base image, non-local Docker endpoint,
different builder driver or incompatible tool version is a build blocker; do
not pull a similarly named substitute or change Docker/VPN/DNS settings as a
workaround. The current cloud sandbox cannot inspect HP's actual base user or
Docker driver. The read-only preflight supplies those facts locally and restores
the base user instead of assuming root for the resulting runtime.

Keep the original Build 18 image/tag and checkout. No cleanup, image pruning,
container recreation, service start, migration command or deployment follows
these build commands. Installation and rollout remain the owner's separate step.
