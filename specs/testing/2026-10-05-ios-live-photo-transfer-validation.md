# iOS Live Photo transfer implementation

Baseline specification: [`../2026-10-05-ios-readiness-design.md`](../2026-10-05-ios-readiness-design.md).
This implements its missing transfer contracts; it does not repeat the readiness audit.

## Outgoing contract

- Original sharing on iOS requests preservation for a Live/Motion asset. The secondary Share
  dialog offers **Live Photo (preserve motion)**, **Original image only**, and the existing preview
  choice. Image-only original is intentional and retains original still bytes.
- `pigeon/live_photo_api.dart` generates Dart and Swift only. `exportLivePhoto(localId)` exports
  PhotoKit `.photo` and `.pairedVideo` resources, including iCloud originals, into one owned
  `outgoing_share/<id>` directory. Resources stream to files without loading a video into RAM.
- `cancelLivePhotoExport(localId)` requests cancellation. Dart still awaits the export future;
  resource writers close/drain before failure cleanup or returning complete paths. Engine detach
  cancels native requests and suppresses callbacks into the destroyed engine.
- For server-only assets, the existing streaming original downloader retrieves still and paired
  `livePhotoVideoId` originals. A merged local model with a removed PhotoKit ID resolves its
  existing remote pair through the local database. No new Gallery asset or PhotoKit save occurs.
- Remote pair staging is cached, both members are retained together, and later shares reuse bytes.
  Existing seven-day outgoing retention remains. A selected share receiver may still be reading
  after the chooser completes, so files are not removed immediately.
- `shareLivePhotos(items, popoverRect)` validates native Apple identity and reconstructs a
  `PHLivePhoto`. UIKit receives `UIActivityItemsConfiguration` backed by the public
  `NSItemProvider(item: NSSecureCoding, typeIdentifier: UTType.livePhoto.identifier)` path.
  `PHLivePhoto` conforms to `NSSecureCoding` and `NSItemProviderReading`, **not**
  `NSItemProviderWriting`; the latter initializer is deliberately not used.
- Incompatible/invalid pairs fail preparation instead of silently sharing a still. Native share
  cancellation prevents late chooser presentation. Compatible receivers must be validated on a
  physical iPhone; passing a native object does not by itself prove receiver fidelity.
- Android keeps its existing original-file Share path. A Samsung Motion Photo is not relabelled
  as an Apple Live Photo when its original resources lack Apple pairing metadata.

## Incoming contract

The existing Share Extension target, bundle ID, App Group and `ShareKey` notification are retained.
Its controller checks `NSItemProvider.canLoadObject(PHLivePhoto.self)` before ordinary images.
`PHAssetResource.assetResources(for: livePhoto)` supplies the original still and paired video.
Both are written to `AppGroup/live_photo_imports/<id>` before an atomic `.live-photo.json` manifest
and `.complete` marker are published. Original bytes, extensions, resource names and pairing
metadata are preserved. An invalid declared Live Photo is rejected, not reduced to a still.

The existing `share_handler` notification carries **one image attachment**. Its owned manifest
provides `ShareIntentAttachment.pairedVideoPath`; raw filename resemblance never proves a pair.
Paths are normalized from file URLs; incomplete manifests, traversal and symlink resources are
rejected. Ordinary images/videos remain accepted, including UIImage-only image providers.
The upload service repeats this validation immediately before transfer: missing motion/manifest
or a dropped pair mapping cannot turn a previously declared Live Photo into an ordinary still.
An evicted handoff directory that cannot acquire its active lease fails safely before upload.

The existing upload API is reused: upload video with `visibility=hidden`, then upload the still
with `livePhotoVideoId`. One logical attachment receives one UI success/failure. Server checksum
deduplication is retained. A duplicate still response does not apply new upload fields, so its
existing pair must be confirmed by the native asset API before reporting preserved-motion success.
An existing unpaired/differently paired still is not modified automatically. A definitely newly
created, proven unlinked motion resource is rolled back through the existing asset API; duplicate
resources are never deleted. Failed/offline verification reports uncertainty and retains the
hidden resource rather than deleting a possibly linked asset. This condition needs a later retry
or explicit review; no destructive repair is guessed.

App Group import cleanup removes an entire consumed pair directory only after seven days and
only without `.active`. Active uploads set/remove that marker in a `try/finally`; successful imports
mark `.consumed`. Unconsumed/incomplete handoffs are retained for retry. A stale active marker
after a killed process is conservatively retained until the handoff is retried; cleanup must not
guess that another process has finished reading. `StorageRepository.clearCache` excludes these
roots. No pairing identifiers, tokens or private resource paths are logged by the new paths.

## Validation and remaining gates

Focused suites cover outgoing native selection, explicit image-only sharing, remote cache reuse,
merged missing-local-ID resolution, native cancellation/drain, atomic paired import, incomplete
resource rejection, traversal/symlink rejection, active/retained/expired directory cleanup, paired
upload ordering, failure/cancellation rollback and duplicate-pair verification.

The final combined Share/import/upload/UI run passed **79 tests**, including **31 added regressions**.
The secondary Share UI tests exercise explicit iOS modes and existing Android/shared quality choices.
See the final combined implementation report for the broad suite counts.
Pigeon generation uses the existing pinned 27.3.0 package; only the new transfer definition is
generated. Dart analysis is clean. Native Swift has not been compiled against the Apple SDK here.

**NEEDS_MAC_VALIDATION:** Runner compilation and Pigeon registrations; Share Extension compilation;
UIKit native item-provider representation; resource APIs and strict actor diagnostics for the
selected Xcode toolchain. Public API declarations were checked against the iOS SDK headers.

**NEEDS_PHYSICAL_IPHONE_VALIDATION:** Photos/iCloud Live Photo export; HEIC/HEVC and orientation;
outgoing transfer through AirDrop/Photos and another compatible receiver with actual motion and
identity preserved; an image-only receiver after intentional still selection; incoming Photos
Share Extension (cold/warm launch), multi-share and cancelled/failed pair; original Gallery asset
dedupe/identity; network loss/retry; seven-day retention and process interruption. The existing
share_handler host-app responder redirect remains a physical-iOS acceptance gate.

No production deployment, media mutation, new server routes/schema, Android signing or package
identifier changes are part of this implementation.
