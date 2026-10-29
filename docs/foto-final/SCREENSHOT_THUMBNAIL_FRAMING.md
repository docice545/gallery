# SCREENSHOT_THUMBNAIL_FRAMING release gate

Status: **SOURCE FIX PENDING CI / APK RUNTIME**. This gate is separate from
the older thumbnail-quality and face-framing checks.

The defect was in Flutter rendering: `Thumbnail` used a centered
`BoxFit.cover` fallback whenever no face bounds were available. A screenshot,
document, receipt, or chat export with its useful pixels at an edge was therefore
cropped to a blank white center even though the server and local thumbnail bytes
were valid. `FaceAwareThumbnailScope` could not solve this because it only has
face metadata.

The fix adds an explicit edge-content classification for screenshot/document/chat
names and routes those assets through `BoxFit.contain` in the timeline, albums,
and local/offline thumbnail renderer. Ordinary photographs keep the existing
cover behavior. The same framing decision is used by the bounded decode planner
and Live Photo still preview. Source images and EXIF are unchanged; the server
thumbnail bytes remain the source of truth.

Fixtures and pixel evidence:

- `mobile/test/presentation/widgets/images/thumbnail_framing_test.dart` checks
  screenshot/document classification and full-source framing.
- `mobile/test/presentation/widgets/images/thumbnail_face_framing_widget_test.dart`
  creates a white-center image with black/blue content at the top and bottom,
  renders it through `Thumbnail`, and asserts the actual captured RGBA pixels.

Required evidence before PASS:

1. Flutter widget tests above pass in GitHub Actions.
2. The final Android APK is installed on a hosted emulator and the same edge
   fixture is visible in the timeline, an album, and offline.
3. Samsung S23 physical verification is recorded separately when available.

The gate remains open until all three evidence classes are recorded with the
final commit SHA.
