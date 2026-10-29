# OFFLINE_GRAY_SCREEN_RECOVERY release gate

Status: **SOURCE FIX PENDING CI / APK RUNTIME**. This gate is separate from
the existing offline catalogue and thumbnail warmup checks.

The offline path is intended to read the Drift timeline first and load durable
thumbnail bytes before any network request. The Android cache previously keyed
only by the session credential and asset revision, and wrote the durable copy
asynchronously after exposing the decoded image. That left a process-death
window and made server identity ambiguous. Authentication failures also skipped
an already-authorized local thumbnail. A missing or corrupt cache item must stay
local to one tile and never blank the whole timeline.

The fix makes the cache key include a versioned server identity, account
credential, asset id, media size, edit flag, and thumbnail revision; removes
corrupt entries on read; commits a fetched thumbnail before handing it to
Flutter; and permits cached-thumbnail fallback for DNS and expired-session
errors while preserving 404 deletion diagnostics. The SQLite corruption guard
still stops unsafe writes without deleting the primary database.

Tests and evidence:

- `mobile/android/app/src/test/kotlin/app/alextran/immich/images/OfflineThumbnailCacheTest.kt`
  covers server separation, account separation, revision invalidation,
  corruption removal, and durable reads after recreation.
- `mobile/test/domain/services/offline_thumbnail_warmup_test.dart` covers
  offline, Wi-Fi, and explicitly consented cellular prefetch policy.
- `mobile/test/presentation/widgets/images/thumbnail_face_framing_widget_test.dart`
  verifies rendered image pixels without an HTTP request, including the local
  thumbnail path used after process death.
- `.github/workflows/original-noodle-gallery-compatibility.yml` runs the
  Flutter widget tests and Android cache unit tests, and its emulator job is
  required to exercise the final APK with network disabled after prefetch.

Required runtime matrix before PASS:

- cold start in airplane mode;
- online to offline without closing;
- force-stop/process death followed by offline launch;
- reconnect;
- expired auth, DNS, 404, missing original, partial cache, and corrupt cache;
- photos from multiple years remain visible from Drift metadata and durable
  thumbnails, with a per-photo missing-media state when no thumbnail exists.

The gate remains open until the final Android APK run and, where available, a
Samsung S23 run record these cases with commit SHA and rendered screenshots.
