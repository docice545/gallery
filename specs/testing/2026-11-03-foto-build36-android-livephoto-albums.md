# FOTO Build 36: Android Live Photo and local albums

Status: **NOT RELEASE READY**. This record covers Android development after
`e04fa68681e89af075f665068c6ec64ae70b3cc0` on
`codex/foto-build36-web-backend-final`, PR <https://github.com/docice545/gallery/pull/16>.
The PR was open, draft, and at the required SHA when this stage started.

Tested Android code checkpoint: `31a6e9a9eabe82fac0061de54611c91eb09d4485`.
HP handoff checkpoint: `f300576ee4e91852e435c37f7d14c735171d7568`;
its Android/locale files are identical, with the complete CI exclusions added.
The subsequent documentation commit does not change application code.

No HP, production, NAS, real media or production keystore was accessed or changed.
An existing GitHub E2E job automatically built a debug emulator APK on checkpoint
`46a9e2830`; this was outside the no-APK instruction. The in-progress equivalent
run on `31a6e9a9e` was cancelled, and a branch-only exclusion was added to prevent
further debug APK jobs. This incident is not a production release or signed-upgrade
validation. No production-signed APK or Samsung installation was performed.
The unpublished HP integration branch was neither verified nor modified. No
old HP patch was cherry-picked. The prior Web/Backend checkpoints are preserved.

## Causes and fixes

### P0: Live Photo cold start

`RouteData.isActive` reads AutoRoute's URL/history snapshot. After the actual
Splash-to-tab-shell startup transition, the nested Feed route can already be
displayed while that snapshot still omits it. A new widget harness uses a real
`RootStackRouter`, Splash replacement, `AutoTabsRouter` and the production-style
600 ms tab fade. It demonstrates all of these simultaneously:

- Feed is the controller's current route and exists in `root.currentSegments`.
- `ModalRoute.isCurrent` and `TickerMode` are true.
- `RouteData.isActive` is false; before the fix no preview starts.

The scope now checks the current controller branch by **route match identity**,
retaining `ModalRoute.isCurrent` and `TickerMode` checks. It does not set route
activity to a constant or alter native playback, source resolution, timeouts or
server behavior. Setting, selection, filter, foreground and scroll suppression
remain in force.

Five real-router regressions cover cold startup without visiting Viewer, tab
switch/return, Viewer and pageless dialog coverage, foreground/selection, and
scroll settling. These validate eligibility and widget lifecycle; native pixels
on Samsung still require device validation.

Two pre-existing Android/iOS preview tests asserted that remote-only motion
must never create a player, contradicting the already implemented remote-pair
feature and the user's working playback trace. Both original failures were
reproduced on exact base `e04fa6868` in an isolated temporary source copy.
The same cases now verify paired `/video/playback`, configured authentication,
muted/non-looping load/play, ignoring an unrelated cached local path and rejecting
a missing video pair. Native runtime code was not changed to satisfy these tests.

### P1: selected device photos

The local-album sheet used server `DeleteAction`, whose visibility requires
remote IDs. Local-only selections therefore had no usable delete action.
It now uses the existing `CleanupLocalAction`:

`CleanupLocalAction → CleanupService.deleteLocalAssetsDetailed → AssetMediaRepository.deleteAll(trash: true) → Android MediaStore`.

The existing identity verification, Android consent, cancellation and per-ID
acknowledgements remain authoritative. The action never invokes server Trash or
permanent deletion. A shared Timeline operation guard prevents repeat activation
and overlap with the whole-album action. Only acknowledged local IDs are removed
from selection; rejected and cloud-only selections remain. Context/account/server
checks prevent stale asynchronous UI changes. Notifications contain counts;
existing detailed native/service diagnostics remain in logs.

### P1: all photos in a local album

The reachable album toolbar menu now contains **«Удалить с устройства все
фотографии альбома»**, without requiring selection. It snapshots the repository's
joined existing local assets, displays the exact count and asks for confirmation.
Before cleanup it rechecks membership, name, type, checksum and creation/update
revision. New arrivals, moved items and changed/reused IDs are not added to the
confirmed operation. It does not call `deleteAlbum()` or use raw orphan link IDs.

The existing device cleanup path handles the eligible IDs. Partial results leave
unacknowledged files in Drift and selection. It never deletes server copies.
Thirteen widget regressions exercise the actual menu/dialog path, empty album,
cancel/reject/partial success, duplicate requests, cross-action overlap, changed
membership/revision, server change and disposal during lookup.

Android can suppress its system consent dialog when `MANAGE_MEDIA` is granted.
The existing FOTO confirmation is preserved for that permission state; the normal
path still requests Android consent. No permission or native deletion policy was
changed. Do not claim every device/permission state necessarily shows an OS dialog.

### P2: album reactivity and Serv 3/0

Two defects were reproduced independently of physical files:

1. Cached `FutureProvider` values kept count 3 and an old cover after verified
   mocked MediaStore cleanup removed all three actual Drift rows and the real
   Timeline became empty. Album and thumbnail providers now consume repository
   watch queries. Thumbnail subscriptions auto-dispose offscreen; reopening reads
   the current cover, and switching the Drift source drops the old subscription.
2. Album-index counts used link rows while Timeline uses joined local-asset rows.
   A synthetic legacy orphan-link fixture showed count 3 versus content 0. The
   index now counts actual joined asset IDs. No orphan links or media are deleted.

Existing Future repository/service APIs remain available. Thumbnail ties have a
stable asset-ID order. Empty album definitions and backup settings are retained;
the normal visible album list continues to omit empty albums.

This proves code-level causes of inconsistent counts; it does **not** establish
which cause produced the particular physical Samsung Serv observation. File
availability and permissions still need a device check. Temporal scope remains
intact: a deliberately filtered album may legitimately show fewer photos than its
unfiltered index count. Both local bucket and asset queries already use the same
route-local scope, so that filter was not removed to mask a discrepancy.

### P2: Recently Added

Only `recentlyAdded()` switches from upload order to capture order
(`SortAssetsBy.taken`). An opt-in asset-ID tie-break makes equal timestamps stable
across pages. The main Timeline's sorting is unchanged. Existing owner, uploaded,
trash and visibility filters, archived photos, raw stack members and local-calendar
bucket handling are preserved; no timestamps or EXIF are rewritten.

## Changed source and test files

- `.github/workflows/build-mobile.yml`
- `.github/workflows/gallery-build-mobile.yml`
- `.github/workflows/original-noodle-gallery-compatibility.yml`
- `i18n/de.json`
- `i18n/en.json`
- `i18n/es.json`
- `i18n/fr.json`
- `i18n/it.json`
- `i18n/nl.json`
- `i18n/pl.json`
- `i18n/ru.json`
- `i18n/zh_Hans.json`
- `i18n/zh_Hant.json`
- `mobile/lib/domain/services/local_album.service.dart`
- `mobile/lib/infrastructure/repositories/local_album.repository.dart`
- `mobile/lib/infrastructure/repositories/timeline.repository.dart`
- `mobile/lib/presentation/actions/delete.action.dart`
- `mobile/lib/presentation/pages/local_timeline.page.dart`
- `mobile/lib/presentation/widgets/bottom_sheet/local_album_bottom_sheet.widget.dart`
- `mobile/lib/presentation/widgets/timeline/live_photo_scope.widget.dart`
- `mobile/lib/providers/infrastructure/album.provider.dart`
- `mobile/lib/widgets/common/mesmerizing_sliver_app_bar.dart`
- `mobile/test/infrastructure/repositories/local_album_count_consistency_test.dart`
- `mobile/test/infrastructure/repositories/timeline_recently_added_capture_test.dart`
- `mobile/test/presentation/widgets/asset_viewer/timeline_preview_video_viewer_test.dart`
- `mobile/test/presentation/widgets/timeline/live_photo_scope_test.dart`
- `mobile/test/providers/infrastructure/local_album_reactive_provider_test.dart`
- `mobile/test/unit/presentation/actions/local_album_cleanup_action_test.dart`
- `mobile/test/unit/presentation/actions/local_album_device_deletion_test.dart`

## Checkpoints

| SHA | Scope |
| --- | --- |
| `070703be093e0f11943fd47bffedf542ba7c7cda` | Branch-only CI guard against automatic APK signing |
| `acd159a10232464c02140da4c5cad7aa1cc3149c` | Cold AutoRoute startup fix and real-router tests |
| `9fee33bf6bbeafb07bd37d7b3b0efdad0c0578d7` | Selected local-album device cleanup |
| `32e81072312cc737ad4aeeb2f1e0cefecd5c355f` | Existing remote-pair preview contract tests |
| `93521a1a5f8105157f5f3835922aa5804a9d64f6` | Reactive counts/covers and consistent joined counts |
| `46a9e2830fbe2c505b99b286fb8ab15411909b6f` | Recently Added capture chronology |
| `31a6e9a9eabe82fac0061de54611c91eb09d4485` | Count-confirmed whole-album device cleanup |
| `8d5590fe13bedad771219cbcd78a562a9d9a8b29` | Exact-branch exclusion for the separate debug APK E2E job |
| `f300576ee4e91852e435c37f7d14c735171d7568` | Formatting of the touched compatibility workflow |

The first CI guard adds only this development branch to the two existing Android
signing exclusions. GitHub confirmed that job **SKIPPED**, which is not a successful test.
The separate offline-emulator job also compiled an APK and was missed by that first
guard; it now has its own exact-branch exclusion. No test assertions were disabled.
Flutter test jobs remain enabled. No dependency, package ID or signing setting changed.

## Validation and limitations

- **PASS: 396 Flutter tests across 25 targeted files** in the final combined run,
  exit 0, including the new 13 whole-album cases and earlier Build 36 Viewer tests.
- **PASS: scoped Flutter analyze**, all 16 changed Dart runtime/test files, no issues.
- **PASS: dart format**, all 16 files, zero changes needed; targeted Prettier for
  all three touched workflow files and all ten changed locale files; `git diff --check`.
- Earlier red/green evidence: real cold route failed before the fix; selected
  cleanup's seven new cases produced five failures on the old runtime; album/query
  regressions produced six failures before the stream/count/sort fixes.
- The Flutter test process emitted nonfatal native-finalizer diagnostics
  (`Callbacks into the Dart VM are currently prohibited`) and existing multiple-Drift
  fixture warnings. These were not suppressed. Exit 0 and passed assertions do not
  establish that those diagnostics are harmless on a physical device; investigate
  them separately before a release-readiness claim.
- **FAIL, inherited:** the API-contract schema digest gate documented in the
  [previous checkpoint](2026-11-03-foto-build36-stack-viewer.md). Backend/OpenAPI
  were not changed or re-audited in this stage.
- **NOT TESTED:** physical Samsung/native frames/MediaStore consent and actual file
  deletion; browser visuals; full Docker image; signed APK upgrade; production smoke.
  The prior Web/Backend test results retain their original tested SHA, not a new run.

No unfinished application edits remain after the code checkpoint. No full UI
performance audit, production repair or real-file scan was performed.

## Safe HP source and test procedure

These commands create a fresh detached review worktree. They do not overwrite the
unpublished HP integration branch or its changes/backups, build/sign an APK, start
containers, migrate a real database or install anything on Samsung. Adjust only the
checkout path if necessary. Generation is confined to the review worktree; stop
and inspect any unexpected tracked API/schema diff rather than committing it.

```bash
set -euo pipefail
FOTO_REPO=/home/doctoriceadm/gallery-build29-integration
FOTO_BASE_SHA=e04fa68681e89af075f665068c6ec64ae70b3cc0
FOTO_SOURCE_SHA=f300576ee4e91852e435c37f7d14c735171d7568
FOTO_REVIEW=/home/doctoriceadm/foto-build36-android-review-${FOTO_SOURCE_SHA:0:12}
git -C "$FOTO_REPO" fetch origin \
  refs/heads/codex/foto-build36-web-backend-final:refs/remotes/origin/codex/foto-build36-web-backend-final
git -C "$FOTO_REPO" cat-file -e "${FOTO_SOURCE_SHA}^{commit}"
git -C "$FOTO_REPO" merge-base --is-ancestor "$FOTO_BASE_SHA" "$FOTO_SOURCE_SHA"
test ! -e "$FOTO_REVIEW"
git -C "$FOTO_REPO" worktree add --detach "$FOTO_REVIEW" "$FOTO_SOURCE_SHA"
test "$(git -C "$FOTO_REVIEW" rev-parse HEAD)" = "$FOTO_SOURCE_SHA"
cd "$FOTO_REVIEW"
mise //mobile:install:ci
mise //mobile:codegen
mapfile -t FOTO_DART < <(git diff --name-only "$FOTO_BASE_SHA" "$FOTO_SOURCE_SHA" -- ':(glob)mobile/**/*.dart')
cd mobile
mise exec -- dart format --output=none --set-exit-if-changed "${FOTO_DART[@]#mobile/}"
mise exec -- flutter analyze --no-pub "${FOTO_DART[@]#mobile/}"
mise exec -- flutter test --no-pub --concurrency=1 \
  test/presentation/widgets/timeline/live_photo_scope_test.dart \
  test/presentation/widgets/timeline/live_photo_autoplay_test.dart \
  test/presentation/widgets/timeline/live_photo_presentation_test.dart \
  test/presentation/widgets/asset_viewer/timeline_preview_video_viewer_test.dart \
  test/presentation/widgets/images/thumbnail_live_photo_test.dart \
  test/presentation/widgets/images/timeline_thumbnail_request_test.dart \
  test/unit/presentation/actions/delete_action_test.dart \
  test/unit/presentation/actions/local_album_device_deletion_test.dart \
  test/unit/presentation/actions/local_album_cleanup_action_test.dart \
  test/services/cleanup.service_test.dart \
  test/repositories/asset_media_trash_repository_test.dart \
  test/repositories/asset_media_response_contract_test.dart \
  test/infrastructure/repositories/local_album_count_consistency_test.dart \
  test/infrastructure/repositories/timeline_recently_added_capture_test.dart \
  test/providers/infrastructure/local_album_reactive_provider_test.dart \
  test/infrastructure/repositories/local_album_repository_test.dart \
  test/medium/repositories/timeline_repository_test.dart \
  test/infrastructure/repositories/timeline_temporal_scope_repository_test.dart \
  test/infrastructure/repositories/timeline_year_grouping_test.dart \
  test/domain/services/edited_copy_service_test.dart \
  test/presentation/widgets/asset_viewer/viewer_stack_deletion_test.dart \
  test/presentation/widgets/asset_viewer/asset_viewer_system_ui_test.dart \
  test/presentation/widgets/asset_viewer/asset_page_zoom_reset_test.dart \
  test/providers/asset_viewer/asset_viewer_provider_test.dart \
  test/presentation/widgets/asset_viewer/asset_stack_widget_test.dart
git -C "$FOTO_REVIEW" diff --check
git -C "$FOTO_REVIEW" status --short
```

## Samsung acceptance after separately authorized build/update

Use synthetic media and staging, not real-library cleanup. Do not uninstall FOTO
or clear its data. The established certificate/application ID and an upgrade-safe
versionCode remain mandatory. The automatic debug-emulator build incident above
does not validate a production-signed APK or physical Samsung update.

1. Enable **Сетка фотографий → Автовоспроизведение живых фото в ленте**. Stop FOTO
   through Android's app settings and launch from its icon. Do not enter Viewer.
   Settle on a known remote paired Samsung motion image with at least 80% visible
   for at least 350 ms. Confirm actual moving frames, not merely player creation.
2. In the app's local event journal capture only the relevant diagnostic stages:
   `Timeline motion: enabled=true ... route=true scrolling=false`, then `selected`,
   `source:remote-pair-playback`, `platform-view-created`, `native-load-accepted`,
   `native-ready:<width>x<height>`, `play-request-accepted`, `position-advanced`.
   Retain no private media IDs, paths, tokens or raw private logs in GitHub.
3. Repeat with local and backed-up motion photos, tab switches, Viewer roundtrip,
   background/foreground, selection, filter/dialog coverage and active scrolling.
   Verify stop when covered/offscreen and reactivation after returning/settling,
   with no simultaneous burst of players. No ADB is required by this plan.
4. In a disposable local album test selected local-only, backed-up and mixed
   selections. Confirm/cancel Android's system request; also test missing permission
   and partial refusal. Verify only acknowledged IDs disappear from FOTO and Samsung
   main gallery; check the device Trash according to the existing native policy.
   Server copies and server Trash must remain unchanged. Test `MANAGE_MEDIA` with
   its existing FOTO confirmation separately from the normal system-dialog path.
5. Open the album toolbar menu without selecting a photo. Check the exact count,
   cancel, then confirm an operation on synthetic media. Add/move/edit a photo while
   the confirmation is open, repeat activation and leave the screen mid-operation.
   Only the original still-matching eligible snapshot may be removed. Verify that
   rejected/new/moved/revised items remain and all/selected operations do not overlap.
6. Observe the opened album, album list, cover, count, selection and empty state
   without restarting. Verify count 3 → 2 → 0 on actual deletion, correct cover
   replacement and correct behavior after reopening the album.
7. Verify Recently Added using different capture/upload dates, archived photos,
   stack members, timezone boundaries and equal capture dates across pages. Confirm
   the main Timeline retains its existing order and ownership/Locked boundaries.

Real-device results, clean-environment diagnostics, inherited API-contract FAIL,
browser validation, Docker build, signed upgrade and production smoke remain
separate release gates. Do not mark Build 36 RELEASE READY from Cloud tests alone.
