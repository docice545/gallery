# Server-only originals: sharing and saving

This extends the existing mobile AssetMediaRepository, background_downloader and
photo_manager paths. It adds no server endpoint, asset model, database schema,
cloud-provider role, package identifier or production-script change.

## Sharing

The existing Share action and original/preview preference remain. Original
means the underlying source bytes (`/assets/{id}/original?edited=false`), including
EXIF and embedded Samsung motion; an explicitly selected preview still uses the
existing edited-preview endpoint. Videos always use originals.

A physically available local original is exported through StorageRepository.
For merged assets, an availability check avoids starting an uncontrolled iCloud
fetch when a Gallery original is available instead. Missing/stale local files
fall back to the authenticated Gallery original endpoint. Local-only assets keep
the existing PhotoManager original-export path.

Native background_downloader streams one selected original at a time into
application cache, with auth headers, progress and cancellation. The cancel
signal is observed independently of progress, including stalled requests. Share
preparation is serialized across repository instances and waits for native
cancellation acknowledgment before retrying the same task. It never imports a
Share file into MediaStore or PhotoKit.

Completed files live in `getTemporaryDirectory()/outgoing_share/<key>/`.
Remote cache keys include server URL, asset identity, update time and quality;
local keys include local ID, file modification/size and name. Completed-cache
markers permit repeat sharing without a second download. Original filenames are
sanitized for paths/control characters; equal batch names get distinct names
without renaming library originals or overwriting earlier recipient files.

A chooser completion/target selection does not establish that a receiver has
finished reading. Cache originals are retained across subsequent shares;
completed directories expire seven days after their last use and are removed
on subsequent preparation. Failed/incomplete downloads are removed promptly.
These are disposable OS cache files, not a permanent offline mirror; the OS can
evict cache under storage pressure. There is no prefetch, library-wide download
or metadata request per thumbnail. Selected large files consume disk space;
file copies/downloads stream and MIME detection reads only 32 bytes.

Android uses a small activity-aware FileProvider bridge for outgoing originals.
The pinned share_plus 10.1.4 clears its entire Android cache on every Share, so
it cannot preserve a previous receiver's files across the next Share. The bridge
avoids a dependency upgrade: it exposes only `cache/outgoing_share/`, verifies
canonical paths, uses read-only URI grants and standard ACTION_SEND/MULTIPLE
with ClipData. Explicit MIME metadata also survives provider process restart.
The existing share_plus path remains on iOS with retained staged files, and for
other existing sharing uses such as logs.

Preparation begins once in dialog state, displays aggregate per-asset progress
and provides Cancel. Late progress after cancellation is ignored safely. Failed
preparation and incomplete selections produce the existing localized error UI.

## Download to device

The existing Download action is explicitly named Download to device. Native
background tasks fetch original still/video bytes and then photo_manager writes
those files through MediaStore/PhotoKit. There is no image/video reencoding.
Each download attempt has its own temporary directory and native task identity,
so equal filenames and delayed callbacks cannot corrupt a retry. Attempt metadata
retains the real remote asset ID; existing persisted tasks remain readable.
Download status becomes complete only after persistent native saving succeeds;
network failures and native save failures remain visible, including failures
that arrive before the first progress event. Late progress cannot overwrite a
terminal status. Local sync/hashing follows actual saving rather than a one-second
timer. Local availability and newly saved local IDs prevent repeat imports. Existing
iCloud-optimized PhotoKit items are kept as existing library items rather than
re-imported from Gallery; the app cannot pin Apple-managed optimized originals
permanently with these public APIs. Truly deleted/stale IDs still fall back to
server-original import.

Android's existing local-file channel corrects the MIME of the newly created,
owned MediaStore item using bounded original-file MIME detection. It accepts
numeric media IDs and image/video MIME values, checks row ownership on Android
10+, and does not accept arbitrary URIs or modify unrelated media. A failure
rolls back that new import instead of leaving a duplicate for a retry.

Linked Apple resources are downloaded together on iOS and passed to the existing
single PhotoKit Live Photo save transaction. Cancellation covers both parts and
their pending records. The package API expects a common title without extension,
so a stem is used for the paired save; per-resource original names are not
independently configurable through this API. PhotoKit still requires compatible
pair metadata. Existing PHPhotosErrorDomain fallback saves a single still, with
its original filename, when the pair is unsupported.

Android saves the original still once. When that file contains native Samsung
embedded motion, those bytes remain intact. A separately paired Apple video is
not imported as a second independent visible photo/video and is not presented
as a reconstructed Samsung Motion Photo. Samsung recognition, third-party
receiver support and PhotoKit acceptance require physical platform testing.
The server asset link, timeline autoplay and manual stack decisions are untouched.

## Cloud Photo Picker

The feasibility assessment and pinned AOSP evidence are in
[Android cloud Photo Picker integration](2026-10-04-android-cloud-media-provider.md).
No CloudMediaProvider is installed. Sideloading an ordinary provider component
alone does not establish admission to a stock Samsung picker's platform allowlist.
