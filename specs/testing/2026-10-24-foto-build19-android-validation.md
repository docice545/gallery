# FOTO Build 19 Android validation and signing handoff

Base: `4aa7f41996b9e310224333059743e4bad7f1c249` (verified production Build 18).
Branch: `codex/foto-build19-live-photo-local-autoplay`.
Android identity: `de.opennoodle.gallery`, versionName `5.7.3`, versionCode `19`.
The backend remains Build 18; this change requires no backend deployment.

## Current evidence and release gate

- 238 targeted Dart/controller/widget tests passed, including the existing
  native-preview, face-framing, thumbnail-cache and dense-layout regressions
  adapted to local video proof. Full Flutter analyze passed before that
  test-only update; scoped analysis of all four updated suites also passed.
  Ten synthetic Android JVM layout/bounds tests passed after
  successful native compilation. No test accessed user media or production.
- The first complete CI mobile run identified 48 obsolete server-autoplay
  expectations in those four suites; all 86 tests in the corrected suites now
  pass locally, without skips. Full-suite results and current CI status must be
  read from the latest PR checks/report; targeted success alone is insufficient.
- Release compilation passed (`assembleRelease`, 711.9 seconds). APK manifest
  confirms `de.opennoodle.gallery` / `5.7.3` / `19`, minSdk 26 / targetSdk 36, and arm64-v8a,
  armeabi-v7a, x86_64. `zipalign -c -P 16 -v 4` passed.
- Cloud artifact: `/workspace/foto-build19-artifacts/FOTO-5.7.3-build19-unsigned.apk`
  (188,992,279 bytes). SHA-256:
  `4d73a5503daa24b9fc3189b7c52c41c66073dbe2c0f9c490021beb9b8478d818`.
  `apksigner verify` confirms it is unsigned (`DOES NOT VERIFY`, missing signing
  manifest). It is not an installable signed release. No replacement key was
  created and no automatic installation was performed.
- Production certificate matching and an update over signed Build 18 are not yet
  verified. Readiness for user testing remains blocked on production signing and
  certificate/update verification. Record a separate final signed APK path and
  SHA-256 after those checks; signing changes the artifact hash.
- Samsung cold-start playback requires separate physical acceptance. Mock native
  controllers and Linux widget tests do not establish Samsung decoder behavior.

## Samsung acceptance, performed manually by the owner

Do not install an APK automatically. Preserve the signed Build 18 APK and local
settings. The owner installs Build 19 over Build 18 without uninstalling or
clearing application data, after certificate and identity checks below. Record
the device model, Android/One UI versions, APK hash and each result. Use synthetic
test media and a separate test profile/account; do not change production media,
album links, backup selection or server configuration for these checks.

| Check | Expected result |
| --- | --- |
| Update from Build 18 | Android accepts the update; login, settings, local DB and existing album links remain intact. Do not bypass failure by uninstalling. |
| Cold local Live Photo | With autoplay enabled, force-stop and reopen without first visiting the viewer. A focused local Live Photo plays muted once after the viewport settles. |
| Scrolling and focus | Scrolling stops playback immediately. After settling, only the focused eligible tile plays; no cascade, infinite loop or simultaneous players. Repeat with several nearby Live Photos. |
| Return from viewer | Open a local Live Photo, return to the timeline and settle. Autoplay works without requiring manual viewer playback and still obeys the single-player rule. |
| Merged asset | An asset present both locally and remotely uses its accessible local motion component. Verify both online and offline; a server video request must not be used for timeline autoplay. |
| Remote asset | A server-only Live Photo stays static in the timeline, including after scrolling and reopening. Its fullscreen viewer still permits manual remote playback when online. |
| Offline local asset | With networking disabled, accessible local/merged motion still plays. No remote retry loop or video fetch occurs. Ordinary still-image/metadata traffic is separate from autoplay video traffic. |
| Background and navigation | During motion, open another screen or background the app. Playback stops; a late native-ready callback must not restart a hidden/background player. Returning grants only the normal focused preview. |
| Autoplay setting | Turning the existing setting off keeps all timeline Live Photos static; manual fullscreen playback remains available. Re-enable and check focused local playback. |
| Missing local video | Use a synthetic fixture/profile whose local motion component is unavailable. The still remains visible, no server video fallback occurs and failure does not trigger active/infinite retries or multiple players. Do not remove a real user original to create this condition. |
| Resource use | Repeatedly scroll, navigate and background/resume. No growing population of active decoders, sustained hidden playback or unexpected network video downloads. |
| Unlinked backup albums | Existing ordinary unlinked Camera/Screenshots/Download albums require no remote link and produce no missing-link warning. No server albums or links are created by this fix. |
| Existing linked albums | Preserve explicitly configured links and cancellation behavior. A genuinely invalid stored link still produces a diagnostic; do not damage a production link to test it. |

Use local Android logs/network diagnostics with secrets redacted to distinguish
timeline video requests from manual viewer requests. Do not enable a mass sync,
create album links automatically, or change server settings to obtain evidence.
If any check fails, preserve logs and the Build 18 reference; do not claim
physical acceptance or attempt a destructive downgrade/data reset.

## Reproduce the automated checks

Use an isolated checkout of this branch, Flutter `3.47.2` (bundled Dart
`3.13.2`), Java `21.0.2`, and the checked-in Gradle wrapper. Preserve
`pubspec.lock`; prepare dependencies and generated OpenAPI/Dart/Drift/Pigeon/
translation sources with the tasks in `mobile/mise.toml`. No database schema
changes or migrations are introduced by Build 19.

From `mobile/`, the tested suites are:

```bash
flutter analyze --no-pub
flutter test --no-pub --concurrency=2 \
  test/presentation/widgets/timeline/live_photo_autoplay_test.dart \
  test/presentation/widgets/timeline/live_photo_scope_test.dart \
  test/presentation/widgets/images/thumbnail_live_photo_test.dart \
  test/domain/services/sync_linked_album_service_test.dart
flutter test --no-pub --concurrency=2 \
  test/presentation/widgets/asset_viewer/timeline_video_viewer_test.dart \
  test/infrastructure/repositories/local_motion_video_repository_test.dart \
  test/providers/asset_viewer/video_player_provider_test.dart \
  test/presentation/widgets/timeline/live_photo_presentation_test.dart \
  test/domain/services/live_photos_timeline_factory_test.dart
flutter test --no-pub --concurrency=2 \
  test/presentation/widgets/asset_viewer/timeline_preview_video_viewer_test.dart \
  test/presentation/widgets/images/timeline_thumbnail_quality_widget_test.dart \
  test/presentation/widgets/images/thumbnail_face_framing_widget_test.dart \
  test/presentation/widgets/timeline/dense_timeline_overlays_test.dart
flutter test --no-pub --concurrency=2
cd android
./gradlew :app:testDebugUnitTest --tests '*LocalMotionPhotoLayoutTest'
cd ..
flutter build apk --release --pub --build-name=5.7.3 --build-number=19
```

Use `--pub` for the final release build so the pinned SDK regenerates the release
plugin registrant after tests. Do not patch generated registrants, remove test
dependencies or suppress TLS validation. Cloud proxy/CA trust is command-scoped
build tooling, not a change to production network settings.

## Sign the already-built unsigned APK locally on HP

This is an owner-run artifact operation, not a production service operation.
Transfer only the unsigned APK and its recorded SHA-256 to HP, verify that hash,
and use the existing installed Android Build Tools. Supply the existing keystore
path and alias locally. Never upload the key or passwords, generate a new key,
select debug signing, edit key configuration, or overwrite Build 18 artifacts.
Do not run these commands with shell tracing or session recording enabled.

Run in an interactive Bash terminal; the paths and alias below are not passwords:

```bash
set -euo pipefail
read -r -p 'Verified unsigned Build 19 APK path: ' FOTO_UNSIGNED_APK
read -r -p 'Existing signed production Build 18 APK path: ' FOTO_BUILD18_APK
read -r -p 'Existing production keystore path: ' FOTO_EXISTING_KEYSTORE
read -r -p 'Existing production key alias: ' FOTO_EXISTING_KEY_ALIAS

test -s "$FOTO_UNSIGNED_APK"
test -s "$FOTO_BUILD18_APK"
test -s "$FOTO_EXISTING_KEYSTORE"
FOTO_RELEASE_DIR="$(mktemp -d ./foto-build19-release.XXXXXX)"
FOTO_ALIGNED_APK="$FOTO_RELEASE_DIR/foto-5.7.3-build19-aligned.apk"
FOTO_SIGNED_APK="$FOTO_RELEASE_DIR/foto-5.7.3-build19.apk"

zipalign -P 16 -f 4 "$FOTO_UNSIGNED_APK" "$FOTO_ALIGNED_APK"
apksigner sign --ks "$FOTO_EXISTING_KEYSTORE" \
  --ks-key-alias "$FOTO_EXISTING_KEY_ALIAS" \
  --out "$FOTO_SIGNED_APK" "$FOTO_ALIGNED_APK"
# Answer apksigner's password prompts locally. No --ks-pass/--key-pass arguments.

apksigner verify --verbose --print-certs "$FOTO_BUILD18_APK"
apksigner verify --verbose --print-certs "$FOTO_SIGNED_APK"
zipalign -c -P 16 -v 4 "$FOTO_SIGNED_APK"
aapt dump badging "$FOTO_BUILD18_APK"
aapt dump badging "$FOTO_SIGNED_APK"
sha256sum "$FOTO_SIGNED_APK"
```

Require successful signature verification and exactly the same signer certificate
SHA-256 digest as the actual signed production Build 18 APK. Stop on a mismatch;
do not substitute a certificate inferred from an older document. Require the
same package `de.opennoodle.gallery`, Build 18 versionCode `18`, and Build 19
versionCode `19` / versionName `5.7.3` in `aapt` output. Record the signing-tool
version, signer digest, signed artifact path and SHA-256. A matching certificate
and package establish update prerequisites; only the owner's actual update test
confirms installation over Build 18 and data preservation.

This procedure does not access PostgreSQL, Redis, NAS originals, production
containers, Memories/ML, or VPN/DNS. Signing reads the existing keystore locally
without modifying or exporting it. Keep the original
Build 18 APK and checkout available for rollback planning; do not uninstall or
clear app data as an automatic rollback step.
