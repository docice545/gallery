# FOTO Build 19: device-local timeline motion

Base: `4aa7f41996b9e310224333059743e4bad7f1c249` (production Build 18).
Only Android/mobile behavior changes. No server API, database schema, production
storage, auto-stack policy, album configuration or signing identity changes.

## Reproduced implementation defects

The timeline candidate chooser did not exclude remote storage. Android timeline
source selection explicitly discarded a motion photo's local asset and could
select its server video pair. A local still or merged relationship therefore did
not establish a usable local video component. Android PhotoManager's subtype
export is not the iOS Live Photo video export and cannot prove this component.
Controller/player regressions reproduce remote eligibility and source selection
independently of production services. They do not establish the exact decoder or
MediaProvider behavior on the reported Samsung device.

Asset model equality also intentionally excludes checksum and, for remote
representations, local linkage. Hashing can change checksum without changing
mtime. The tile must explicitly re-register these source revisions; otherwise a
cold-start hash completion can leave the scope using obsolete source proof.

## Selection, source proof and ownership

The scope selects one visible local/merged image marked as Live Photo, using the
existing visibility/focus rule. Remote assets are rejected before local lookup
and at the controller and player boundaries. A merged remote representation
looks up its `localId` in the device database, without resolving a remote video.

Before granting a playback lease the scope obtains a device-local video file.
The controller requires that proof, and the exact same path is supplied to the
player as a file source. The timeline source branch returns before any server
asset lookup or URL construction. Fullscreen manual remote playback retains its
existing source path and has a separate regression test.

One source resolution is in flight at a time. Token and asset-revision checks
discard late results. Navigation/background/disposal cancel resolution and
revoke playback. A missing/denied/unsupported component stays static until focus
or feed activation changes, without trying every visible photo. The existing
settling delay, single lease, one-shot viewport budget and bounded player retry
remain in force. Only native position progress consumes a successful playback;
native ready/load/error races are tested with a controllable player.

## Android local component

`StorageRepository.getLocalMotionVideo` uses a local native method. Its input is
the expected local ID, filename, creation/modification times and checksum
revision. Native code queries a typed MediaStore image URI, verifies identity,
opens the original read-only and identifies the embedded video from metadata:

- Samsung SEF `MotionPhoto_Data`, including the HEIC `mpv2` offset/length form;
- Google XMP MicroVideoOffset and Motion Photo container directory forms.

The parser never searches arbitrary image bytes for an incidental MP4 signature.
All offsets/lengths are bounded; metadata probes read at most 1 MiB. The selected
range is streamed to private temporary cache, capped at 64 MiB per video, then
validated with Android MediaExtractor for a video track and positive dimensions.
Native code rechecks the MediaStore revision before publishing the cache file.
There is no network or permanent-delete fallback and no write to original media.

Cache identity includes the local revision; retained videos are capped at three
files/128 MiB plus a bounded in-progress partial. Extraction uses one executor,
cancellation checks, a provider cancellation signal and a 20-second response
watchdog. A blocked provider cannot produce a late playback source or spawn an
unbounded replacement population. No media permission is requested automatically.

Synthetic parser tests establish layout/bounds behavior, not actual Samsung
format/codec acceptance. Unrecognized legacy/trailing-data layouts fail closed
and remain stills. Physical Samsung testing and provider/decoder behavior remain
explicit acceptance gates; see the validation handoff.

## Linked backup albums

An album returned by `getBackupAlbums()` can legitimately have no
`linkedRemoteAlbumId`; ordinary photo backup does not require album linking.
`syncLinkedAlbums()` quietly skips that case and retains diagnostics for a
configured link whose remote album is absent. Cancellation prevents new remote
work and is still forwarded to active requests. No links are created or changed
by this fix.

The existing `manageLinkedAlbums()` creation path is called when the user enables
`backup.syncAlbums` in backup settings, and when leaving album selection while
that setting is enabled. Its default is false; existing owner/name reuse remains
unchanged. Resume/websocket paths synchronize existing links under the setting.
The actual Samsung configuration was not available to inspect, so this audit
does not infer that the user enabled album linking.

## Validation boundary

Tests use synthetic models, temporary files, mocked channels and player events;
no production account or media is used. There is no Drift migration, dependency
upgrade or backend build. Release signing and an actual update over signed
Build 18 are separate from successful compilation. Follow
[`testing/2026-10-24-foto-build19-android-validation.md`](testing/2026-10-24-foto-build19-android-validation.md)
for the recorded checks and remaining signing/physical gates.
