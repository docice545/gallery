# FOTO source-coordinate photo editor design

The editor extends Gallery's existing Flutter route, annotations and authenticated image pipeline.
It does not add an independent editing API, database schema or storage convention. The original
server asset and its Live/Motion association remain unchanged. Editing is limited to one owned,
non-Trash, non-index-tombstone image through the existing action guards and capability checks.

## Document and rendering

`EditorState` is generated with Freezed. Crop, orthogonal rotation/reflection, eight color
adjustments, filter/intensity and immutable annotation elements form one document. UI selection,
source loading and save status are not edits. Bounded document history retains 100 snapshots;
a slider/crop gesture or an object gesture commits one step, and reset is reversible.

CropImage remains the crop interaction implementation. Its programmatic aspect/crop notifications
are guarded during history replay. Selecting a preset records the final source-pixel crop in one
transaction; intermediate controller notifications cannot become undo steps or discard redo.
Original ratio uses decoded dimensions when EXIF dimensions are unavailable.

Normalized annotation points address the full oriented source, independent of preview resolution,
letterboxing, crop and viewport zoom. Object rotation/scale operate in source-pixel space around
an anchor, so non-square photos do not skew the transform. Hit testing applies the inverse object
transform; source crop/rotation/reflection and zoom/pan are shared by the image and annotation
surface. Outside the crop tool the visible source crop is clipped and fitted to available space.

One affine color matrix composes the eight corrections and filter intensity. Main preview and
export use that same matrix. Annotations are painted afterwards and therefore are not tinted by
photo filters. Lazy thumbnails use the actual source ImageProvider, not a black overlay or a
provider-owned ui.Image handle that the route might dispose.

Text styles and original vector stickers/emoji share AnnotationPainter between preview/export.
Fonts use platform families; no proprietary artwork or model/font download is required. Platform
emoji/HEIC/RAW support is conditional; generic raster tests do not prove a particular device codec
or emoji font. Text background/outline/opacity and object transforms are immutable document data.

## Gesture ownership and limits

A selected movable object can own a two-finger gesture; otherwise two fingers navigate the image.
The shared notifier prevents viewport zoom from applying a second transform to the same gesture.
Additional pointers, cancellation, resize and tool changes abandon drafts. A remaining finger
never resumes drawing after a pinch. Stroke erasing removes drawn annotations only, not captions,
stickers or source pixels; AI erasing is a separate authenticated server job.

History and per-stroke point retention are bounded; exports reject images above 32 MP rather than
silently reducing quality. Source load has a 30-second deadline and explicit cancellation that
releases listeners/timers. Only one save is allowed in a route at a time. Cancel prevents persistence
at the next export boundary; an already submitted native photo-library write is not advertised as
cancellable. Native decoder memory/permissions still require physical-device validation.

## Persistence and API boundaries

Save creates a new PNG in the device photo library using the existing FileMediaRepository. The
full original is requested with `edited=false` through the existing authenticated provider so
source geometry is not applied twice. A load/decode/permission failure leaves the document dirty
and retryable, never changes the server asset, and cleans only the temporary export. There is no
silent low-resolution preview fallback and no original replacement option.

Decoded EXIF orientation is baked into the output raster; the old orientation tag must not be
copied back. Other EXIF is not copied into this PNG. The original bytes/metadata stay untouched.
The copy is uploaded only through existing device backup if enabled; the UI states that boundary.
The passed legacy applyEdits callback remains API-compatible but is never called by copy export.

Live/Motion manual editing remains disabled to avoid silently changing one component of a pair.
The existing explicit AI still-copy workflow remains available; it never claims to export a new
motion pair. No deletion policies, NAS paths, queues, Memories or server worker settings change.

The AI route uses the server's bounded oriented source preview, independently of the unsaved
manual crop. Its mask coordinates refer to that displayed source. Existing owner/permission,
job bounds, cancellation, result expiry and explicit-copy API contracts remain authoritative.
No new OpenAPI fields, database migrations or native platform APIs are introduced by this editor.
