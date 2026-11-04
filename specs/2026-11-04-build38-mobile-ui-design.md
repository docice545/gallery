# Build 38: cold Viewer transitions, date overlay and foreground media changes

Source base: `46fc1b3c1d30d8e9893def0ce953a882aff7fa27`, existing
`codex/issue17-smart-timeline` / PR20. Build37 production is reported working by
the user. The provided installed-artifact identifier is
`9323699b65154146bd9928002ecd89d60590472091cc1df204c11a23b36b51be` (64 hex digits);
it cannot establish a Git source SHA in this SHA-1 repository.

Scope is the three Android UI corrections below. No Backend/API, Docker,
PostgreSQL, Redis, NAS, production data, signing or APK build is involved.
The package version has not been released/bumped by this source-only change.

## Cold Viewer transition

Two code paths explain why a cache-cold transition differs from a warm one:

- `ImageWrapper` returned `CustomChildWrapper` before decoding and
  `PhotoViewCore` afterwards. That replaces the subtree and its Hero state when
  the first frame arrives, potentially during a navigation flight. Loading also
  used the whole viewport as the Hero's image rectangle, even for a landscape
  image contained within a portrait screen.
- `ThumbnailTile` put the request-planning `LayoutBuilder` *inside* its Hero,
  then used that subtree as the shuttle. Growing/shrinking flight constraints
  selected different decode buckets/cache keys instead of retaining the tile's
  already-requested bounded image. New thumbnail requests/fades could occur
  during both push and pop.

The loading and decoded states now retain the same `PhotoViewCore`/Hero.
Known upright, unedited asset dimensions supply loading geometry only; they are
not decode targets. A bounded thumbnail replaces the loading spinner. Unknown
or edited geometry retains the existing fallback. The tile computes its
thumbnail request outside the Hero; the shuttle reuses the resolved child.
Placeholder callbacks check `mounted` before updating tile state.

Route duration, navigation, gestures, adjacent-image preloading, original-image
preferences and Live Photo ownership/lifecycle rules are unchanged. No Viewer
warm-up, permanent route flag or new playback timer is introduced. These source
causes do **not** establish the S23 GPU/raster contribution: that still needs a
physical cold-start profile capture.

## Centered date and theme colors

`Scrubber` previously placed the date at `start: 12` with `topStart` alignment,
with a black background and white text independent of theme. It now uses equal
horizontal insets and top-center alignment. Its existing vertical/SafeArea
formula, appearance/fade timers, scroll gestures, right-edge thumb and
`IgnorePointer` behavior remain unchanged. Long text is constrained and
ellipsized; large fonts/RTL do not move the center.

Both surfaces use the existing `ColorScheme.primary`, which already reflects
the user's theme preset/dynamic accent. The date uses an opaque, accent-tinted
`surfaceContainerHigh`, avoiding contrast changes caused by the photo beneath.
Black/white foreground is chosen by luminance (at least 4.5:1). Thumb geometry
and its existing primary/darkened-primary background remain unchanged; arrows
now select contrasting ink and repaint when the theme changes. There is still
one date overlay and no new setting.

## Foreground MediaStore updates

The app already depended on `photo_manager`, whose Android plugin implements a
ContentObserver, but no app callback registered/started it. Local SQLite refresh
was requested by entry/resume/manual actions, leaving an already-open Photos
screen stale when a screenshot was saved.

`local_media_refresh.provider.dart`, owned by the signed-in gallery shell,
registers that existing observer while Android gallery access is available and
the app is active. A 350 ms event coalescing window invokes the existing native
generation-based local sync, never a per-tile query or a periodic poll. Bursts
coalesce; notifications during a pass schedule one subsequent pass. Observer
registration is serialized, removed on disposal and stopped in the background.
Resume catches up even if notifications were missed. No remote sync/upload is
started by an observer event. Existing album visibility/backup-selection policy
is retained; this does not silently opt new folders into backup.

`BackgroundSyncManager.syncLocal(enqueue: true)` retains a dirty request when
another caller already owns a pass; cancellation clears queued work. Resume
local sync starts independently of the remote request and lets native
version/generation checks decide whether a full scan is necessary. Existing
Android delta deletion reconciliation still enumerates album IDs (not full
image metadata/bytes); Android 10 and older retain their existing full-sync
fallback. Thus the 1–2 second target is device/library dependent.

A related race was found in native checkpointing: `checkpointSync()` read the
latest generation *after* processing cursors. A screenshot published during
that pass could be absent from the cursor but included in the checkpoint, so
even a queued delta would skip it. `MediaGenerationCheckpoint` retains the
pre-read generation/version. Changes during the pass remain eligible on the
next event/resume; replay is safe because repository writes upsert by asset ID.

## Verification and reproducible local commands

**Status: Flutter/analyzer/JVM/device tests NOT RUN for this patch.** The user
chose local testing. This cloud environment has no Flutter/Dart SDK; no GitHub
workflow was dispatched and no APK was created. Commits use `[skip ci]` to avoid
existing automatic mobile builds. Local `git diff --check`, actionlint and a
WASM Dart formatter/parser check were run. The WASM formatter is not the pinned
Dart SDK; the exact formatter/analyzer remains required below.

From an isolated checkout of the final PR20 SHA (preserve any HP working-tree
changes), with the repository's mise toolchain/Flutter 3.47.2:

```sh
mise //mobile:install:ci
mise //mobile:codegen
cd mobile
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub
flutter test --no-pub --concurrency=1 \
  test/domain/services/local_media_refresh_test.dart \
  test/providers/local_media_refresh_provider_test.dart \
  test/domain/utils/background_sync_test.dart \
  test/domain/services/local_sync_service_test.dart \
  test/infrastructure/repositories/local_album_repository_test.dart \
  test/presentation/widgets/asset_viewer/viewer_hero_transition_test.dart \
  test/presentation/widgets/asset_viewer/viewer_gestures_test.dart \
  test/presentation/widgets/asset_viewer/asset_page_zoom_reset_test.dart \
  test/presentation/widgets/timeline/scrubber_positions_test.dart \
  test/presentation/widgets/timeline/live_photo_autoplay_test.dart \
  test/presentation/widgets/timeline/live_photo_scope_test.dart \
  test/presentation/widgets/timeline/justified_timeline_widget_test.dart \
  test/presentation/widgets/timeline/offline_timeline_restart_test.dart
cd android
./gradlew :app:testDebugUnitTest --tests 'app.alextran.immich.sync.MediaGenerationCheckpointTest'
```

The JVM command is a unit-test task, not an APK assembly/signing command; it
requires the normal Android SDK/JDK/generated Flutter project setup. The
existing Actions workflow also has a manual `software_only=true` mode for
Dart analysis and these Flutter regressions. Normal PR native gates remain
intact. Do not dispatch the normal mobile/release workflows without approval.

New regression coverage to run:

- Hero state/contained rectangle survive a delayed first decode; actual Navigator
  push/pop with a production ThumbnailTile retains one decode size at simulated
  60/90/120 Hz frame steps. This is **not GPU frame timing or hardware acceptance**.
- One centered date in portrait/landscape, RU/DE/RTL, large text, system theme
  switching while visible, explicit light overriding dark system, new accent,
  contrast, unchanged thumb position; previous drag/fade/gesture tests retained.
- Native photo-manager channel to delta-sync wiring, lifecycle stop/resume;
  burst coalescing, events during sync, cancellation and error recovery.
- SQLite main-Timeline stream updates, duplicate ID replay, chronological order,
  folder movement, metadata date change and deletion.
- Native generation checkpoint keeps a concurrently published screenshot
  eligible, retains old version across a MediaStore reset, and retries a failed
  checkpoint without advancing it.

## Physical acceptance still pending

After separately authorized build/install, test cold process start on S23,
first open/close (portrait, landscape, tall screenshot, local, cached remote,
uncached remote), then repeat. Record UI/raster frame times and first-vs-warm
p50/p95/p99, jank, memory and screenshots/video of any scale/position/black
artifact. Use 120 Hz and 60 Hz on S23; use actual 90 Hz hardware if unavailable
on S23. Software clock steps do not validate any of these rates.

Verify pinch/pan, swipe/back and Live Photo cold Timeline → Viewer → Timeline →
background/resume with one active player and real `position-advanced` evidence.
Check centered dates in system/light/dark, theme/accent changes while scrolling,
large text and rotation, including the right thumb and lower navigation.

With Photos open, create a screenshot, camera file and downloaded image in an
already-visible local album. Measure from MediaStore publication to visible
tile (target roughly 1–2 s), repeat a burst during sync, move/delete/change
metadata, then background/create/resume, including an unavailable server.
Confirm no duplicate IDs, date order, unchanged scroll offset, permission denial
and limited-access behavior. No physical Samsung or other refresh-rate result
is claimed by this patch.

## Follow-up to the HP run (Flutter 3.47.2 / Dart 3.13.2)

The supplied HP evidence is partial: formatter PASS (1623 files), one analyzer
info, and two test failures observed by `+151`; no final suite result was
provided. It must not be described as a completed failed or successful suite.

The repository regression now initializes English `intl` symbols explicitly:
`TimelineRepository` parses SQLite bucket dates using `DateFormat(..., 'en')`,
and a repository test does not execute application localization startup.
`StreamQueue.cancel(immediate: true)` is registered before the first stream read
and runs before database teardown even when parsing/assertions fail. Previously
cancellation existed only on the success path; a paused queue could prevent the
stream close from draining after the original locale exception, causing the
secondary timeout.

The observer test now controls the permission future, verifies denied/no observer,
then verifies granted/native registration before counting its coalescing window.
It asserts zero calls at 349 ms and exactly one at 350 ms, then injects a native
notification and verifies another exact delta call. It also verifies native stop,
resume, disposal and no calls after disposal. Log errors from the refresh path
are asserted rather than silently allowing the service's error handler to hide
an assertion failure. Teardown closes the provider and channel on failure too.
The runtime's 350 ms duration and expected call counts have not been relaxed.

`flutter_localizations` is declared directly under `dev_dependencies` with
`sdk: flutter`; only its existing lockfile dependency category changes from
transitive to direct dev. Its SDK version and all other locked versions remain
unchanged. No analyzer suppression is added.

Warnings are assessed separately from assertion failures:

- Drift 2.34's `GeneratedDatabase._handleInstantiated` counts open instances by
  `runtimeType`; its warning says **when** two instances use the same executor.
  It does not compare executor identity. Thus that message alone is not evidence
  of a shared-executor race or corrupted production database. The affected
  repository fixture creates a fresh `NativeDatabase.memory()` per test and
  awaits database close; the active stream now has failure-safe cleanup too.
  A warning that remains needs its construction stack to identify the other
  live fixture. `dontWarnAboutMultipleDatabases` is not enabled.
- The exact Dart VM callback diagnostic and stack were not provided. Depending
  on its text, native callbacks after isolate teardown, callbacks from a leaf
  FFI call and callbacks on another thread are different faults. They cannot be
  classified as harmless, fixed, or caused by Drift from the current excerpt.
  Preserve stderr, exit status and the preceding test name; do not suppress the
  diagnostic or change native callback code without that evidence.

For a focused repeat on HP after checking out the final PR20 SHA, from `mobile/`:

```sh
flutter --version
flutter pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub
set -o pipefail
flutter test --no-pub --concurrency=1 --reporter expanded \
  test/providers/local_media_refresh_provider_test.dart \
  test/infrastructure/repositories/local_album_repository_test.dart \
  test/presentation/widgets/timeline/scrubber_positions_test.dart \
  2>&1 | tee /tmp/foto-build38-hp-focused.log
```

Then run the full Build38 software command above with the same `pipefail` and
`2>&1 | tee /tmp/foto-build38-hp-regressions.log`. Retain the final summary and
exit status, including any Drift/VM warnings. These commands create no APK and
perform no signing, merge, deployment or production operation.

### Checkpoint at the user's request to stop and publish

Code commit: `7e66379937e60a82f5d4df465d15b3d6e5364a59` (following
`5e3edb73d0b9c600db02df553b052ecd024c1140`). No additional runtime application
changes were made in this HP-follow-up; the three Build38 fixes are preserved.

**Not all blockers are resolved.** Explicit permission completion did NOT fix
observer `calls == 0`. The first CI rerun disproved that timing hypothesis.
The current test temporarily traces timer creation/firing and includes active
timer states, the fake clock and native-registration toggles in the failure
reason. Use that evidence to establish the actual cause, then remove the
instrumentation; do not increase the delay or weaken the call-count assertion.

First software-only run:
https://github.com/docice545/gallery/actions/runs/41850830480
Job: https://github.com/docice545/gallery/actions/runs/41850830480/job/126646354393

- Dependency installation/codegen and Dart analysis: PASS (the localization
  dependency info is gone).
- Flutter summary: 152 success, 1 failure, 1 error, 0 skipped.
- Locale exception/30 s cleanup timeout no longer occurred. The repository test
  reached the metadata-order assertion, exposing a fixture with changed
  `createdAt` but unchanged `updatedAt`. Android upserts deliberately treat equal
  `updatedAt` as replay. The fixture now supplies a native-style modification
  timestamp; expected chronological order remains unchanged. Retest pending.
- Observer test still failed: expected one initial delta call, got zero.
- Formatter step failed (exit 123) without a formatter diff. It ran at repository
  root, while mise's Flutter/Dart tool configuration is in `mobile/mise.toml`.
  Its working directory/relative paths have been corrected; retest pending.

Second software-only run (code `7e6637993`):
https://github.com/docice545/gallery/actions/runs/41852313101
Job: https://github.com/docice545/gallery/actions/runs/41852313101/job/126651575209
At checkpoint: **IN PROGRESS, dependency installation/code generation**. No
result is claimed. The user requested publication immediately, so it was left
running. No APK/native-emulator job is enabled in this mode. This document-only
checkpoint uses `[skip ci]` and does not restart/cancel that run.

Next steps on HP / in the next session:

1. Read the second run's result and annotations (or execute the focused command
   above). It should provide timer diagnostics if the observer still fails.
2. Fix the confirmed observer cause in the provider/test clock boundary without
   weakening 349/350 ms or lifecycle assertions; remove temporary Zone tracing
   after diagnosis. Keep `addTearDown` cleanup.
3. Confirm the metadata fixture, pinned formatter and analyzer pass, then repeat
   the full Build38 regression command. A completed suite summary is required.
4. Obtain exact Drift/VM warning text and construction/callback stacks. They have
   not been suppressed or declared harmless/fixed.
5. Samsung cold Hero/raster timings, automatic screenshot latency and 60/90/120 Hz
   acceptance remain pending; no APK/signing/deployment authorization is implied.
