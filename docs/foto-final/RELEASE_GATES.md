# FOTO final RC release gates

Statuses use `PASS`, `FAIL`, `BLOCKED`, or `NOT TESTED`. A passing source test
does not imply device or production readiness.

| Gate | Status | Evidence | Required follow-up |
|---|---|---|---|
| Complete offline integration line selected | PASS | `origin/fix/foto-offline-library-20261027` at `2eb2816f9` | Keep branch ancestry recorded |
| `1796000000400-AddVerifiedAssetContentChecksum` present | PASS | `server/src/schema/migrations-gallery/ORDER` | Disposable PG migration run |
| Stack deletion selection | PASS (source) | `dd1cab300` and stack-trash tests | Flutter/device run |
| All-user duplicate audit | BLOCKED | `hp-readonly-audit.py` prepared; no HP/NAS access | Run per-user on HP |
| Android empty-Trash performance | SOURCE FIX TESTED / HP BLOCKED | 239 server tests; receipt aggregation changed from N+1 to two queries | Benchmark disposable PG/NFS and Samsung |
| Web Live Photo | PASS (Cloud tests on prior source line) | Web unit/component checks | Chromium with real media |
| Android/iOS playback | BLOCKED | SDK/device unavailable | Samsung and iOS E2E |
| Places and Russian geodata | BLOCKED | Source restored | HP geodata and device rendering |
| Magic Eraser inference | BLOCKED | API/Python tests only | HP `immich-gallery-inpainting-1` |
| Production migration/NAS switch | BLOCKED | No HP access and no approval | Owner-approved staging then switch |
| Overall RELEASE READY | NOT RELEASE READY | Mandatory device/HP gates open | Do not publish APK or production |
| RC source version for next APK | PASS (source) | `mobile/pubspec.yaml` is `5.7.3+22`; package/signing checks remain HP-only | Build and sign on HP after approval |
| Integration PR | BLOCKED by Cloud auth | Branch is published; `gh pr create` returned 403 with invalid `GH_TOKEN` | Restore GitHub CLI token and use compare URL |

| Original Noodle Gallery Android/iOS compatibility | API contract + disposable real-backend smoke PASS (run `40866220811`); APK provenance PASS; hosted Android E2E PENDING; iOS NOT TESTED | `server/src/utils/original-noodle-gallery-contracts.spec.ts`, official APK hashes/signatures, `.github/workflows/original-noodle-gallery-compatibility.yml` | Complete unchanged-client Android/iOS runtime acceptance before release |
| `SQLITE_CORRUPTION_RECOVERY` | SOURCE FIX / Flutter test + device runtime PENDING | `docs/foto-final/SQLITE_CORRUPTION_RECOVERY.md`, `mobile/lib/data/db/sqlite_health.dart`, `mobile/test/data/db/sqlite_health_test.dart` | Run Flutter fixture tests and device recovery replay; repair only a captured copy with `.backup`/`.recover`/REINDEX based on diagnosis |
| `ANDROID_CLOUD_MEDIA_SHIZUKU` | SOURCE PASS / device runtime NOT TESTED | `mobile/android/app/src/main/kotlin/app/alextran/immich/cloudmedia/`, `specs/2026-10-06-cloud-media-shizuku-design.md`, Kotlin policy tests | Verify admission/read-back/undo, Photo Picker media and account isolation on Android 16; Samsung Gallery support remains device-specific |
| `SCREENSHOT_THUMBNAIL_FRAMING` | SOURCE FIX / CI + APK PENDING | `docs/foto-final/SCREENSHOT_THUMBNAIL_FRAMING.md`, `thumbnail_framing_test.dart`, rendered-pixel widget fixture | Run Flutter tests, final APK timeline/album/offline emulator, then Samsung S23 |
| `OFFLINE_GRAY_SCREEN_RECOVERY` | SOURCE FIX / CI + APK PENDING | `docs/foto-final/OFFLINE_GRAY_SCREEN_RECOVERY.md`, durable Android cache tests, offline emulator workflow | Run cold/offline/process-death/auth-expiry matrix on final APK; then Samsung S23 |
