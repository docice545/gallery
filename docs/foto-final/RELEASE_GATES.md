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

| Original Noodle Gallery Android/iOS compatibility | API contract PASS; APK provenance PASS; hosted Android E2E PENDING; iOS NOT TESTED | `server/src/utils/original-noodle-gallery-contracts.spec.ts`, official APK hashes/signatures, `.github/workflows/original-noodle-gallery-compatibility.yml` | Run workflow on GitHub; complete iOS/macOS and device acceptance before release |
| SQLite corruption recovery | SOURCE PASS / runtime NOT TESTED | `mobile/lib/data/db/sqlite_health.dart`, checkpoint `a00cc2056` | Add fixtures, run Flutter tests and device recovery replay |
| `SCREENSHOT_THUMBNAIL_FRAMING` | SOURCE FIX / CI + APK PENDING | `docs/foto-final/SCREENSHOT_THUMBNAIL_FRAMING.md`, `thumbnail_framing_test.dart`, rendered-pixel widget fixture | Run Flutter tests, final APK timeline/album/offline emulator, then Samsung S23 |
| `OFFLINE_GRAY_SCREEN_RECOVERY` | SOURCE FIX / CI + APK PENDING | `docs/foto-final/OFFLINE_GRAY_SCREEN_RECOVERY.md`, durable Android cache tests, offline emulator workflow | Run cold/offline/process-death/auth-expiry matrix on final APK; then Samsung S23 |
