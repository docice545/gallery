# FOTO Build 36: stack deletion and Viewer validation

Base: `03d8ee5aa7cbe318736556b380249487beed8b8e`, branch
`fix/foto-build35-stack-trash`.

Code checkpoint: `44bda909e89be136e8e9b39a69f667bd67055264`, branch
`codex/foto-build36-web-backend-final`.

Review: <https://github.com/docice545/gallery/pull/16>. No automatic merge,
production access, deployment, APK build, signing or real-user deletion was performed.
This is a tested code checkpoint, **not release readiness or a measured FPS claim**.

## Confirmed defects and changes

| Area | Reproduced defect | Correction |
| --- | --- | --- |
| Web GalleryViewer | Deleting an inner stack frame absent from the top-level list executed `splice(-1, 1)` and removed an unrelated last photograph. | Guard missing indices; replace the representative separately from frame navigation; duplicate acknowledgements do not navigate twice. |
| Web AssetViewer | The handler used the currently displayed ID rather than the acknowledged frame ID; local stack selection, preview and count could remain stale. | Capture `action.asset.id`, remove only confirmed frames, select next then previous, retain singleton context, clear removed previews, close/advance only when empty. |
| Web asynchronous state | Late `getStack()` replies and local/WebSocket duplicate events could restore stale state or navigate twice. Plain cursor mutation was not reliably reactive with Svelte 5. | Version/identity guards, per-ID reconciliation and reactive cursor replacement without remounting the Viewer. Disable repeated deletion through reconciliation. |
| Web Timeline | A Viewer pre-action removed/navigated before deletion succeeded. Collapsed selection did not consistently expand all stack members. | Apply deletion after success; explicitly opt collapsed Timeline selection into validated, owner-consistent expansion. Raw search/gallery/Viewer selection keeps single-frame semantics. Fetch at most four stack descriptions concurrently before mutating anything. |
| Web Undo and events | Rapid trash/restore was reordered by batching additions before removals; old pending updates could reinsert a locally removed row. | Keep the last event per ID, discard older queued events for a confirmed local removal, cancel trailing work on disconnect and avoid duplicate subscriptions. A later genuine restore remains eligible. |
| Backend | Soft trash/partial restore could leave `primaryAssetId` pointing to a trashed frame, hiding active survivors. | Lock affected stacks in stable order and repair their visible primary transactionally; retain an already active manual primary. Keep stack rows and member links, including zero/one active member, so restoration retains structure. Project singleton stack metadata as `null`. |
| Backend notifications | A session with no open Viewer did not receive the newly promoted representative/count; restore-all lacked the existing restore event. | Emit existing owner-scoped asset updates for distinct active representatives, and existing restore events for actually restored IDs. Exclude Locked/Hidden assets from normal session payloads. Fetch representative DTOs in batches of at most 1000, not per frame. |
| Android Viewer | A real widget/Drift regression test showed that optimistic removal of the primary made the collapsed timeline temporarily empty and closed the Viewer while siblings remained. A final deletion could leave the next standalone photo's old details cached. | Retain one logical stack page during reconciliation, map neighbouring indices correctly and refresh the active page/details. Reject late refreshes, preserve the last usable frame on refresh failure and restore the rejected frame on API failure. |

Android changes are limited to `asset_viewer.page.dart`, `asset_page.widget.dart`
and a regression test. The original **220 ms easeOutCubic** transition is unchanged.
No photo-grid layout, API/schema, migration, permanent-deletion worker, NAS policy,
editor, upload pipeline or Live/Motion Photo implementation was changed.

## Published checkpoints

| Commit | Scope |
| --- | --- |
| `6b5a5850d628901ca32844b6c4b5358963e608ca` | Android retained stack page and regression tests |
| `72188ac315b67485b9992f59444c2aa502ee5f4b` | Android final-frame/standalone transition |
| `f6c9c49324067f33845a7453cec0883e23ad0884` | Backend stack repair, notifications and fixtures |
| `23fe749169dcbfdd7f8195b9f86e39c134faa051` | Web Viewer/Gallery reconciliation and tests |
| `bd74f364d817d50f280d14554cc75bfbd4cce9f1` | Collapsed selection expansion and repeated-action guards |
| `44bda909e89be136e8e9b39a69f667bd67055264` | WebSocket ordering/lifecycle and stale-update regression |

## Validation evidence

| Check | Result | Boundary |
| --- | --- | --- |
| Web targeted Vitest | PASS: 383 tests, 19 files | Viewer, Timeline, Thumbnail, selection, WebSocket, virtualization, image loader and scroll-anchor logic; no real browser painting |
| Backend unit | PASS: 351 tests, 4 service files | Asset, Stack, Notification and Trash services |
| Backend medium | PASS: 24 tests, 2 files | Disposable local PostgreSQL, actual migrations, synthetic owners/assets/files; primary trash, partial/full restore, 2/3/5 members, singleton DTOs, ownership and concurrency |
| Android Flutter | PASS: 18 tests | Eight new real Viewer/Drift widget regressions and ten nearest Viewer/provider/zoom/stack regressions; no physical Samsung |
| Android scoped analyze | PASS: no issues | Two changed runtime files and the new test; not a whole-repository analyze claim |
| Web production build | PASS | Existing Vite/static-adapter build, SDK built from the same source |
| Backend TypeScript | PASS | `pnpm check` |
| Web TypeScript / Svelte | PASS with environment qualification below | Full `check:typescript`; full `check:svelte`, zero errors/warnings |
| Scoped ESLint / Prettier | PASS with environment qualification for Web ESLint | All 27 changed Web and 9 Backend source/test files, all lint rules enabled |
| `git diff --check` | PASS | Entire change from the required base |
| Pinned API contract tests / GitHub API compatibility job | FAIL, inherited: 12 PASS / 1 FAIL | Identical failure reproduced on exact base `03d8ee5`; see below |
| GitHub automatic Android signing | CANCELLED | Queued signing job cancelled to respect the no-APK instruction; not a successful check |
| Full Docker image build | NOT TESTED | Build-only commands below; no production container started |
| Chromium/Playwright visual E2E, Samsung and iOS | NOT TESTED | No claims about actual frames, smoothness or unchanged-device update |
| Production PostgreSQL/NAS/real files | NOT TESTED | No access attempted |

The default Cloud dependency lookup initially resolved tscompat's undeclared
TypeScript import to an incompatible global TypeScript 7 runtime and Web Node
types to global `@types/node` 17 (`Dirent.parentPath` missing). Full Web type and
all-rule lint checks passed after **ignored local dependency links** pointed to
already lockfile-installed TypeScript 6.0.3 and Node types 24.13.3. No tracked
package, lockfile, configuration, version or lint-rule changes were made. This
does not establish that the unmodified dependency layout passes on a fresh HP/CI
installation; reproduce its resolution before claiming a clean-environment gate.
Svelte teardown `derived_inert` and Node WASI warnings were not hidden.
Production build also retains warnings about bundle size and the existing
`justified-layout-wasm` URL being resolved at runtime; browser staging must verify
that asset resolves. Neither warning was silenced by this patch.

GitHub's API compatibility job failed at
`server/src/utils/client-contracts.spec.ts:77`: expected schema digest
`b78d3afa7fc51d0acb1f6c97a586b60cf805d94c5752e0653afdded955c60167`,
received `7fe64572752448c06cb4906a3b2e69ad55330dfdaf6fed750b642cd9ab770a50`.
The same two contract specs were run against files extracted from exact base
`03d8ee5` in a disposable directory: **12 PASS / 1 FAIL**, exactly as on the
checkpoint. Both specs, OpenAPI and contract fixtures are byte-identical between
base and checkpoint. The gate remains **FAIL**; do not alter the immutable
baseline hash simply to make it pass. Investigation of the historical schema
difference is recorded in PR 16 as a separate remaining release gate.
Skipped, pending or cancelled GitHub jobs are not included in the PASS totals.

The representative-notification regression verifies one bulk DTO lookup for
1000 representatives and three for 2001, replacing the intermediate per-frame
lookup implementation. These are request-count tests, not HP SQL/NFS latency or
FPS measurements. No full-library benchmark was performed.

Reproduce targeted Backend checks in an **isolated development environment**:

```bash
cd server
pnpm test --run src/services/asset.service.spec.ts \
  src/services/stack.service.spec.ts src/services/notification.service.spec.ts \
  src/services/trash.service.spec.ts --maxWorkers=1
pnpm test:medium --run test/medium/specs/services/stack-trash-selection.spec.ts \
  test/medium/specs/services/stack-maintenance-compatibility.spec.ts --maxWorkers=1
pnpm check
```

Medium tests provision a disposable container via Testcontainers. Do not supply
production DB credentials or redirect them to the running HP database.

Web commands are `pnpm test --run <spec paths> --maxWorkers=1`,
`pnpm check:typescript`, `pnpm check:svelte` and `pnpm build` from `web/`.
There is no `npm run check` script. Install with the repository's pinned pnpm and
`pnpm install --frozen-lockfile`; do not let `npx` install a different Vitest.

## Changed code and test files

- `mobile/lib/presentation/widgets/asset_viewer/asset_page.widget.dart`
- `mobile/lib/presentation/widgets/asset_viewer/asset_viewer.page.dart`
- `mobile/test/presentation/widgets/asset_viewer/viewer_stack_deletion_test.dart`
- `server/src/repositories/asset.repository.ts`
- `server/src/repositories/stack.repository.ts`
- `server/src/repositories/trash.repository.ts`
- `server/src/services/notification.service.spec.ts`
- `server/src/services/notification.service.ts`
- `server/src/services/trash.service.spec.ts`
- `server/src/services/trash.service.ts`
- `server/test/medium/specs/services/stack-trash-selection.spec.ts`
- `server/test/repositories/asset.repository.mock.ts`
- `web/src/lib/components/asset-viewer/AssetViewer.deletion.spec.ts`
- `web/src/lib/components/asset-viewer/AssetViewer.svelte`
- `web/src/lib/components/asset-viewer/__test__/deletion-navbar.stub.svelte`
- `web/src/lib/components/asset-viewer/__test__/deletion-thumbnail.stub.svelte`
- `web/src/lib/components/asset-viewer/actions/DeleteAction.svelte`
- `web/src/lib/components/asset-viewer/actions/action.ts`
- `web/src/lib/components/assets/thumbnail/Thumbnail.svelte`
- `web/src/lib/components/assets/thumbnail/__test__/Thumbnail.spec.ts`
- `web/src/lib/components/shared-components/gallery-viewer/GalleryViewer.spec.ts`
- `web/src/lib/components/shared-components/gallery-viewer/GalleryViewer.svelte`
- `web/src/lib/components/timeline/Timeline.svelte`
- `web/src/lib/components/timeline/TimelineAssetViewer.spec.ts`
- `web/src/lib/components/timeline/TimelineAssetViewer.svelte`
- `web/src/lib/components/timeline/actions/DeleteAssetsAction.spec.ts`
- `web/src/lib/components/timeline/actions/DeleteAssetsAction.svelte`
- `web/src/lib/components/timeline/actions/TimelineKeyboardActions.spec.ts`
- `web/src/lib/components/timeline/actions/TimelineKeyboardActions.svelte`
- `web/src/lib/managers/command-context-manager.svelte.ts`
- `web/src/lib/managers/selection-command-handlers.spec.ts`
- `web/src/lib/managers/selection-command-handlers.ts`
- `web/src/lib/managers/timeline-manager/internal/websocket-support.spec.ts`
- `web/src/lib/managers/timeline-manager/internal/websocket-support.svelte.ts`
- `web/src/lib/managers/timeline-manager/timeline-manager.svelte.spec.ts`
- `web/src/lib/managers/timeline-manager/timeline-manager.svelte.ts`
- `web/src/lib/utils/actions-deletion.spec.ts`
- `web/src/lib/utils/actions.ts`
- `web/src/routes/(user)/photos/[[assetId=id]]/+page.svelte`

## Manual staging and device acceptance

Use synthetic images and disposable users only. Run these cases in a real
browser and on Samsung before any production decision:

1. In 2/3/5-member stacks, delete the first, middle, last and primary frame from
   Viewer. Verify only that frame disappears, next/previous selection is correct,
   the cover/count update without reopening, and an unrelated last Timeline tile
   remains. Delete successively down to one, then zero; never show `1/1`.
2. Delay/reject a deletion, press delete repeatedly, navigate to another stack
   before a delayed `getStack()` completes and repeat a WebSocket event. Confirm
   no duplicate request/navigation, stale selection, false success or lost frame.
3. Delete whole collapsed stacks, mixed standalone/stack selections and a date
   selection; restore through toast Undo and Trash, including restore-all and a
   nonprimary frame while the old primary remains trashed. Verify no duplicate
   tiles, lost links or cross-user/Locked/Hidden updates.
4. Observe another logged-in session with no Viewer open: the promoted cover and
   count must update. Reconnect the socket, alternate rapid trash/restore and
   return from Viewer: the correct tile and scroll position must remain.
5. On Android, delay the server response while deleting the primary, visit a
   neighbouring photo and return. Check retained frame, details, zoom and the
   existing 220 ms transition. Reject a later deletion: restore that frame, not
   an earlier accepted deletion. Confirm Live/Motion Photo/video still render.
6. Check large Timeline/album scrolling, selection overlays/action panels, menus,
   dialogs, Trash, Archive, Favourites and section navigation. Check image/cache
   continuity on Viewer open/close, orientation changes and throttled networking.
   Observe black frames, stale images, count jumps, input latency and scroll
   restoration; capture browser/Flutter frame traces before asserting smoothness.

No broad performance rewrite was performed. Existing virtualization, preload,
image-cache and scroll-anchor regressions passed; the full UI's real rendering
and performance remain a device/browser acceptance gate.

## Safe HP build-only procedure

The owner runs these commands after reviewing the PR. They create a separate
detached worktree and a **new image tag**; they do not check out over the existing
HP worktree, touch `.pre-*`/backups, start containers or run migrations.
Adjust only `FOTO_REPO` if the published checkout is stored elsewhere.

```bash
set -euo pipefail
FOTO_REPO=/home/doctoriceadm/gallery-build29-integration
FOTO_SOURCE_SHA=44bda909e89be136e8e9b39a69f667bd67055264
FOTO_BASE_SHA=03d8ee5aa7cbe318736556b380249487beed8b8e
FOTO_SHORT=${FOTO_SOURCE_SHA:0:12}
FOTO_REVIEW=/home/doctoriceadm/foto-build36-review-${FOTO_SHORT}
FOTO_IMAGE=gallery-server:foto-5.7.3-build36-${FOTO_SHORT}

git -C "$FOTO_REPO" fetch origin \
  refs/heads/codex/foto-build36-web-backend-final:refs/remotes/origin/codex/foto-build36-web-backend-final
git -C "$FOTO_REPO" cat-file -e "${FOTO_SOURCE_SHA}^{commit}"
git -C "$FOTO_REPO" merge-base --is-ancestor "$FOTO_BASE_SHA" "$FOTO_SOURCE_SHA"
test ! -e "$FOTO_REVIEW"
git -C "$FOTO_REPO" worktree add --detach "$FOTO_REVIEW" "$FOTO_SOURCE_SHA"
test "$(git -C "$FOTO_REVIEW" rev-parse HEAD)" = "$FOTO_SOURCE_SHA"
git -C "$FOTO_REVIEW" diff --check "$FOTO_BASE_SHA" HEAD
test -z "$(git -C "$FOTO_REVIEW" status --porcelain)"

docker inspect --format '{{.Config.Image}} {{.Image}}' immich_server
docker build --file "$FOTO_REVIEW/server/Dockerfile" \
  --tag "$FOTO_IMAGE" \
  --build-arg BUILD_VERSION=5.7.3-build36 \
  --build-arg BUILD_SOURCE_COMMIT="$FOTO_SOURCE_SHA" \
  --build-arg BUILD_SOURCE_REF=codex/foto-build36-web-backend-final \
  --build-arg BUILD_REPOSITORY=docice545/gallery \
  --build-arg BUILD_IMAGE="$FOTO_IMAGE" \
  "$FOTO_REVIEW"
docker image inspect --format '{{.Id}}' "$FOTO_IMAGE"
```

The repository's existing `server/Dockerfile` builds Backend and Web together.
It does not invoke `branding/apply-branding.sh`, which is absent at this base;
do not add that nonexistent command from older generic instructions. No new
migration is introduced by this patch. Existing startup migrations still require
the owner's ordinary staging/backup review before deployment.

A **new Backend/Web image is required** to deliver these fixes. A **later Android
rebuild is also required** to deliver the two proven Viewer fixes. No APK was
built here and no version, application ID or signing settings were changed.
Keep the established HP certificate and use an update-compatible versionCode;
do not uninstall or clear application data. Production switching, rollback and
device installation remain separate owner-approved operations.
