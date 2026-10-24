# Android remote-image HTTP diagnostics

The baseline is `e5883358c48a76a82fe7db29b5cd5ac0b1fc76e2`. An Android
`PlatformException(IOException, java.io.IOException: HTTP 404)` does not identify
the requested rendition, asset ID or underlying storage failure. No production
database, service, NFS mount or user media was accessed for this investigation.

## Request and storage path

`getThumbnailImageProvider` and `getFullImageProvider` select a remote ID from
`RemoteAsset.id` or a merged `LocalAsset.remoteId`; the local MediaStore ID is
not used as an Immich ID. `RemoteImageProvider`/`RemoteFullImageProvider` create
`RemoteImageRequest`, which calls the Pigeon `RemoteImageApi.requestImage` API.
Android `RemoteImagesImpl` fetches bytes through Cronet or OkHttp, then returns
encoded or decoded image buffers to the Flutter stream completer.

Requests use either:

- `/api/assets/{id}/thumbnail?size=thumbnail|preview&edited=...`
- `/api/assets/{id}/original?edited=...`

`AssetMediaController` routes these calls to `AssetMediaService`.
`AssetRepository.getForThumbnail` reads the PostgreSQL asset and its derived
`asset_file.path`; missing thumbnail/preview metadata produces an explicit 404.
`getForOriginal` reads `asset.originalPath` or the edited path. The file serving
utility checks readability before sending the file; absent or unreadable files
can also produce 404. Existing metadata therefore does not prove that the
requested file can be read. Permissions failures generally follow the separate
400/401/403 access-check paths in this baseline.

The confirmed production layout remains unchanged: `/data/upload` and
`/data/library` are Synology NFS-backed, while the main `/data` and service data
are on HP. Derived thumbnail/preview paths normally belong to the thumbnails
storage folder under the main media location. A preview 404 does not establish
that the original on Synology is missing.

## Reproduced client defects and correction

The full-image provider previously omitted the server endpoint from its cache
identity and built later requests using the mutable current endpoint. Equal
asset IDs across server changes could reuse a cached or in-flight provider.
The provider now captures the endpoint, uses it for every rendition and includes
it, asset type and decode size in its cache identity. URL construction encodes
the asset ID as one path segment and uses an explicit rendition revision key.

The initial-thumbnail cleanup continuation could independently rethrow a failed
cached request while the primary image stream was already handling the same
failure. Cleanup now owns its continuation without creating a second unhandled
error. A missing initial thumbnail can still be followed by a valid preview;
an unexpected final preview/original failure remains observable. The
`loadOriginal` preference is preserved; a 404 does not force an original fetch.

Both native HTTP clients now preserve status, sanitized request/final paths,
request ID and validated rendition/edited metadata in `HTTP_ERROR`.
`RemoteImageHttpException` exposes those fields in Dart. Authentication headers,
URL credentials, signed query values and fragments are not included. A
deliberately cancelled request that subsequently returns 404 is a cancellation;
an unverified 404 for a live image remains an error. The code does not globally
turn 404 into success or treat a missing local cache row as proof of deletion.

Owner Trash remains viewable, so a trashed asset is not automatically an
expected 404. Restore must permit a new request; failed image loads must not
poison its cache entry. Tests cover cancellation, retry after a 404, endpoint
changes, rendition changes and correct merged-asset ID routing. HTTP server
tests use a local synthetic MockWebServer, never Immich production.

These reproduced client defects are distinct from the reported device failure.
Its exact endpoint and physical cause remain unconfirmed until the new request
diagnostic can be correlated with authorized server-side observations. No
database row or file should be deleted to make the error disappear.

## Other reported messages

`No linked remote album ID found` is an explicit skip in
`SyncLinkedAlbumService.syncLinkedAlbums`. A local backup album may have no
remote-album link; ordinary file backup does not require one. Album sync is
gated by the user's `backup.syncAlbums` setting. Creating links belongs to the
explicit album-management configuration path and is not a repair for this log.
The actual device setting was not available in this workspace.

`Foreground backup cancelled: restarting the backup` is emitted when a new
foreground pass replaces an existing pass. The resume flow can start backup
immediately and again after hashing finishes. An isolated restart can be
normal; repeated cancellation without upload progress needs timed evidence.
`Device sync took - 134ms` reports duration and does not establish successful
backup or explain an HTTP error.
