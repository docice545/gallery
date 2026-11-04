# Offline feed P0 — cloud regression evidence

The Samsung report is the acceptance scenario, not proof of any particular implementation cause. The following failures were reproduced independently before their corresponding fixes:

| Failure | Confirmed mechanism | Correction / regression |
| --- | --- | --- |
| Immediate offline preview failure discards a slower saved thumbnail | Image error detaches the consumer before the fallback stream delivers | Wait for the independent thumbnail attempt before reporting the preview error; successful preview still wins; `remote_image_provider_http_test` |
| Fast-scroll lands on the preceding year | Snap used a guessed prefix and viewport fraction while the date label used the measured grid origin | Both directions use the measured origin and the same local gesture coordinates; 15-year scrubber test before any asset/image is available |
| A cache-only memory lane waits for a hung backend | Local query only started after network failure | Read the owner-scoped cache independently during refresh; replace, never concatenate, the server result; preserve Space-shared cards after successful refresh |
| Late memories move the visible photo | A new/changed prefix changes absolute sliver offsets | Apply a measured sliver scroll correction in the layout pass; no shift at offset zero; insertion/resize/removal tests retain the exact photo and rectangle |
| A failed image stays failed after reconnect | Only asset metadata changes triggered retry | One retry opportunity per offline-to-online transport transition; no per-image polling or retries on ordinary rebuilds; successful images stay cached |
| Photos lacking optional thumbHash bypass the durable cache | Native cache correctly requires a content revision, but the asset provider supplied none | Use synchronized updatedAt as a fallback revision; retain server/session/edit isolation and invalidate after metadata changes |

The local catalog test closes SQLite, clears decoded memory images and reopens the same durable catalog. It covers local-only, empty and checksum-linked mixed libraries, with both stalled and immediately refused remote previews. Pixels are checked, not just tile existence. The real native transport is represented by controlled platform-channel fixtures in Flutter; actual Android disk-cache JVM tests are separate.

## Visual evidence

[Year 2020 after offline fast-scroll](year-2020.png) and [same viewport after late memories](year-2020-after-memories.png) are actual Flutter renders of deterministic synthetic images. They were opened and visually inspected. Every fully visible photo is also checked against its source pixel color, and its identity/rectangle is retained across the prefix update. The floating date is asserted before decoding completes. The first visual pass exposed grey placeholders despite a weak non-white assertion; the final test checks exact source pixels instead.

These images prove the covered date/cache/position behavior, not final visual approval of the complete FOTO interface. No private photographs are included. Ordinary headers under the transient floating-date overlay are still part of the broader UI review.

## Actual final verification

157 Flutter tests passed in 47 seconds (the command below plus `test/domain/models/deletion_snapshot_test.dart` and `test/unit/presentation/actions/deletion_snapshot_guard_test.dart`). `flutter analyze --no-pub`: no issues. 51 pure JVM tests passed for OfflineThumbnailCache, LocalMotionPhotoLayout, SyncTrashPolicy, MediaGenerationCheckpoint and PlaceNamePolicy using Kotlin 2.2.20/JDK 21/JUnit 4.13.2. Full Gradle/APK verification is separate and still in progress after repository HTTP 503 failures. [Receipts](receipts.json) include failures and final successes.

## Reproduction

Use the repository's pinned Flutter SDK and generated artifacts, then:

```sh
cd mobile
flutter test --no-pub --concurrency=2 \
  --dart-define=FOTO_MOSAIC_CAPTURE=true \
  --dart-define=FOTO_MOSAIC_ARTIFACT_DIR=/tmp/foto-offline-evidence \
  test/presentation/widgets/images/remote_image_provider_http_test.dart \
  test/presentation/widgets/images/timeline_thumbnail_request_test.dart \
  test/presentation/widgets/images/thumbnail_face_framing_widget_test.dart \
  test/presentation/widgets/timeline/offline_timeline_restart_test.dart \
  test/presentation/widgets/timeline/scrubber_positions_test.dart \
  test/presentation/widgets/timeline/scrubber_segments_test.dart \
  test/presentation/widgets/timeline/justified_timeline_widget_test.dart \
  test/providers/infrastructure/memory_provider_test.dart \
  test/domain/services/memory_service_test.dart \
  test/presentation/widgets/memory \
  test/presentation/pages/dev/main_timeline_memory_lane_test.dart
```

Receipts list actual successful and failed executions. Raw temporary logs remain outside Git in `/workspace/foto-build38-evidence`. The host Flutter engine emits the pre-existing `Callbacks into the Dart VM are currently prohibited` diagnostic in some image/font-heavy suites; it also occurs in the earlier UI baseline. This diagnostic is retained, not filtered from logs. It requires checking against native builds; a passing widget suite is not proof of a clean device run.

## Hardware gates

`DEVICE_REQUIRED`: Samsung airplane-mode force-stop/relaunch, immediate year dragging, online/offline/online with cold/warm decoded caches, a large real library, late sync/memory updates, route return and Live/Motion Photo playback. Repeat on the final signed APK and record package version, SHA-256, device/API, screen recording and logs. Never uninstall or clear the user's data to run the update acceptance.

`HP_REQUIRED`: build and verify the final signed APK with the existing key, staging backend tests and retained rollback artifact. Cache misses for server-only photos never downloaded to the device cannot manufacture offline pixels. Version/session isolation deliberately prevents using unrelated or stale cached images. The project is not finally accepted by this evidence.
