# Server-only originals: validation and physical device checklist

Supplemental starting commit: `2bbad07f2bfb475fe1064953baaadde09c6d6276` on
`work`. The original three-goal task started at
`07f7a8a8e98a52ba7bcd70a30c3b8018a00775c0`; its three completed commits remain
ancestors. No history rewrite, production deployment, release, API/schema change
or production AI/auto-stack change is part of this supplement.

Implementation commit: `0f89d8ad2d4b8128e8734bd1f3cf1711ccab8412`.

## Automated verification

Final results (Flutter 3.47.2 / Dart 3.13.2):

- Regression run: **367 passed**, exit 0. Timeline/layout/autoplay, Memories,
  existing system integration/uploads, branding and version checks.
- Feature/action run: **227 passed**, exit 0. Share/Download repositories/services,
  download panel/state, all existing asset actions, manual stacks and stack API.
- Total: **594 distinct mobile tests passed** in the two final runs. The focused
  Share suite has 26 cases; the 49-case Download/Save run is included, not added
  again to that total.
- Whole `mobile` analysis: `dart analyze --fatal-infos` — **No issues found**, exit 0.
- Changed Dart format check: **17 files, zero changes**, exit 0. One final Share
  formatting discrepancy was corrected before this successful check.
- Ten maintained locale files: Prettier/JSON/new-key validation passed;
  localization/key generators completed. Existing i18n branding script passed
  checks over 89 locales.
- Provider manifest/XML, existing application ID, FileProvider dependency API and
  read-only/narrow-path configuration checked; HP Bash code blocks parse with
  `bash -n`; Git whitespace and history/schema-preservation checks passed.
- No server code or database/schema changed in this supplement, so server tests,
  TypeScript and schema checks were not rerun. Previous server/version checks
  are recorded in `2026-10-04-photos-validation.md`.

Native bridge calls are mocked in Flutter tests; these results are not physical
MediaStore, PhotoKit, Telegram or Samsung tests. Regression logs contain nine
existing `dart_isolate.cc(1403)` teardown diagnostics about prohibited VM callbacks;
this was already reproduced before this supplement. All assertions pass and the
runner exits 0. The final feature/action log contains none of that diagnostic.
Earlier full server lint/format was blocked by two pre-existing Prettier errors
in `1793400000000-FixMemoryCandidateSchema.ts`; that migration remains untouched.
No new analyzer error or failed test remains.

Cloud logs: `cloud-originals-regressions.log`,
`cloud-originals-feature-final.log`, `cloud-originals-analyze-final.log` under
`/workspace/gallery-validation/` (not committed as generated artifacts).

The focused Share suite covers a local original without server requests;
server-only photo/video via the original endpoint; mixed multi-share; filename
collisions; JPEG/HEIC/MP4 and unnamed/server MIME; stale local references;
iOS local-availability checks; cache reuse/invalidation/seven-day expiry;
network failure and partial batch cleanup; cancellation without progress;
retention for earlier receivers; concurrent same-original deduplication and
cancel-before-immediate-retry with delayed native acknowledgment. Share does
not call PhotoManager or NativeSync to import files. Live/stack model links
remain unchanged.

Download tests cover authenticated original photo/video tasks, native persistent
save only after successful download, MIME and unchanged source bytes, save or
permission errors, network errors, in-flight/local duplicate prevention,
paired-resource cancellation/cleanup/retry, and one PhotoKit Live Photo instead
of two independent assets. State tests cover terminal status visibility,
late progress, cancellation and listener disposal. Existing timeline/autoplay,
stack, Memories, upload, branding and version tests are included in the regression
run.

Android SDK is absent in this Cloud environment. No Android APK/native Kotlin
build has run. macOS/Xcode and iPhone are unavailable; no iOS native build has
run. Platform permission prompts, OEM behavior, native receiver access and
release signing require the HP/device checks below.

## Samsung / Android checks

Use the existing application ID and signing key. Build/install **Фото 5.7.2
build 2** with [the HP commands](2026-10-04-photos-hp-build.md); do not recreate
PostgreSQL, Redis or ML. This supplement needs no server deployment to provide
new endpoints; the preceding version-reporting fix still requires
`BUILD_VERSION=5.7.1` when rebuilding a server image.

1. Select a genuinely local original while offline. Share should open the system
   sheet using the local file, without server/thumbnail traffic or a new media
   entry. Confirm the original remains available afterward.
2. Free a backed-up photo locally, sync, then Share from the server-only timeline.
   Confirm progress, correct filename/type, and successful reading in Telegram,
   WhatsApp and mail. Verify the Photo app never opens Asset Viewer unexpectedly.
3. Share a server-only large MP4. Observe increasing progress, smooth navigation,
   bounded app memory and no full-file RAM allocation. Cancel during transfer,
   then immediately retry. The new attempt must not be canceled by the old one.
4. Repeat Share of an unchanged cached original. Verify no second original request.
   Share another item while the first recipient still reads its file; that prior
   content URI must remain readable. Temporary copies must not appear in Samsung
   Gallery/MediaStore. The OS may still evict disposable cache under low storage.
5. Share several photos, several videos and a mixed batch. Include two assets
   named `IMG_0001.JPG` from different dates and two same-named videos. Verify
   distinct files and correct MIME/type/content, including HEIC when supported
   by the recipient. App-side originals must be identical; a recipient may
   choose to compress photos itself.
6. Disable network or simulate an unavailable server. A new uncached Share must
   show an error or allow immediate Cancel. Already cached originals can still
   share offline. Check invalid/expired session handling without leaking auth
   headers to recipients.
7. Download server-only JPEG/HEIC and video. Wait for persistent save completion,
   then find the actual original in Samsung Gallery, Telegram's local selector
   and the system Photo Picker. Verify byte/EXIF preservation and MediaStore MIME.
   Repeat Download and confirm no duplicate local entry or redundant request.
8. Include same-named assets in multi-download. All originals must survive and
   receive separate local entries. Test cancel/retry and denied/revoked media
   permissions; no success indication should precede a completed native save.
9. Cancellation applies while the original is downloading. Once an atomic native
   MediaStore/PhotoKit import has begun, the existing package offers no safe
   cancel API; the operation finishes and reports its real result. Cancel must
   never falsely claim that a file was not imported.
10. Share/Download a Samsung Motion Photo whose stored original retains embedded
    video. Confirm Samsung Gallery actually recognizes movement after saving.
    Android preserves embedded bytes but does not reconstruct Samsung's native
    format from an independent JPEG and MP4. An Apple-origin pair on Android saves
    its still once; it is not advertised as a native Samsung Motion Photo.
11. Check timeline dense rows, stack count/status/live badges, multi-select and
    tapping. Motion autoplay must remain muted, single, one-shot, idle-only and
    require a meaningful new viewport. Verify Memories zoom/manual stacks.
12. Record Samsung model, Android/One UI versions and receiver versions. These
    results cannot be inferred from the Flutter mock tests.

## iPhone / macOS checks

Build the existing iOS target with its unchanged bundle identifier on macOS/Xcode.
Check local and server-only still/video Share through UIActivityViewController,
retained files, mixed sharing, permission denial and download cancellation.
Also test an existing iCloud-optimized PhotoKit item: Download must preserve
that existing item rather than import a duplicate. Apple controls optimization;
this application cannot promise to pin its original permanently on the phone.

Save an original Apple Live Photo with matching native pairing metadata: Photos
should contain one still+paired-video asset that animates. Validate EXIF/resource
bytes and the package's common Live Photo title behavior. For an unsupported
pair, verify the existing single-still fallback, preserving the original still
filename and leaving the server relationship intact.

## System cloud Photo Picker

[The AOSP research](../2026-10-04-android-cloud-media-provider.md) documents the
API and platform admission gates. No provider has been added. A sideload alone
cannot grant this package admission to the stock picker allowlist; neither a
Google Play listing nor SDK 36 is proof of admission. Do not expect server-only
assets in Telegram's own local selector or claim Samsung cloud-picker support.
The guaranteed application workflows are outbound Share and explicit native Save;
their actual platform behavior must still be confirmed above.

## Changed files

### Share and safe cache

- `mobile/android/app/src/main/AndroidManifest.xml`
- `mobile/android/app/src/main/kotlin/app/alextran/immich/MainActivity.kt`
- `mobile/android/app/src/main/kotlin/app/alextran/immich/share/OriginalSharePlugin.kt`
- `mobile/android/app/src/main/res/xml/original_share_paths.xml`
- `mobile/lib/presentation/actions/share.action.dart`
- `mobile/lib/repositories/asset_media.repository.dart`
- `mobile/lib/utils/original_file.dart`

### Save to device and download status

- `mobile/android/app/src/main/kotlin/app/alextran/immich/localfiles/LocalFilesManagerPlugin.kt`
- `mobile/lib/infrastructure/repositories/storage.repository.dart`
- `mobile/lib/presentation/actions/download.action.dart`
- `mobile/lib/presentation/widgets/action_buttons/download_status_floating_button.widget.dart`
- `mobile/lib/providers/asset_viewer/download.provider.dart`
- `mobile/lib/repositories/download.repository.dart`
- `mobile/lib/repositories/file_media.repository.dart`
- `mobile/lib/services/download.service.dart`

### Localization and dependencies

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
- `mobile/pubspec.lock`
- `mobile/pubspec.yaml`

### Tests

- `mobile/test/providers/asset_viewer/download_provider_test.dart`
- `mobile/test/repositories/asset_media_repository_test.dart`
- `mobile/test/repositories/download_repository_test.dart`
- `mobile/test/repositories/file_media_repository_test.dart`
- `mobile/test/services/download_service_test.dart`
- `mobile/test/unit/presentation/actions/download_tag_action_test.dart`
- `mobile/test/unit/presentation/actions/share_action_test.dart`

### Documentation

- `specs/2026-10-04-android-cloud-media-provider.md`
- `specs/2026-10-04-server-only-originals-design.md`
- `specs/testing/2026-10-04-photos-hp-build.md`
- `specs/testing/2026-10-04-server-only-originals-validation.md`
