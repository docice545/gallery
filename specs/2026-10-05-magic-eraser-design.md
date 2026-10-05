# Magic Eraser: private CPU inpainting and explicit asset copies

This fork already has server-backed, reversible crop/rotate/mirror edits and
Flutter's crop editor. Those edits are not an AI pixel replacement format. The
existing ML container provides recognition/search/OCR/pet inference, not
inpainting. Magic Eraser therefore extends the editor with a mask screen, and
adds an optional, isolated CPU service. It does not replace the ML service or
the non-destructive edits pipeline.

## Coordinates and originals

The editor fetches a bounded, orientation-normalized JPEG preview from Gallery.
Coordinates and brush radii refer to that unedited original; radii are fractions
of the shorter image dimension. The UI explicitly explains that existing crop,
rotation and mirror edits are not baked into this operation. Zoom/pan changes
the view, never stored mask coordinates. Additive and erasing strokes are
ordered, and undo/redo/reset operate on this mask history.

The phone posts only normalized brush instructions and the source asset ID.
Gallery enforces ownership and reads the original directly from its storage,
including the existing S3-to-local staging mechanism. No original download and
upload roundtrip through the phone is required. Gallery supplies the private
inpainting service with a normalized image and those instructions; bearer
authentication and a configured service URL are required. This optional feature
is unavailable when it is not configured or the sidecar is not healthy. Older
server versions retain their existing editor behavior.

Input limits are 36 million pixels, 64MiB per normalized image, 64 strokes,
1024 points per stroke, 8192 points total, coordinates in [0,1], radius in
[0.001,0.25], and a final painted mask covering at most 75% of the image. Animated
images and videos are excluded. Invalid or unsupported images fail safely.

## Model and resource boundaries

The selected model is Big-LaMa's established TorchScript artifact; the exact
196.14MiB file is SHA-256 verified before loading. See
[the model research](2026-10-05-magic-eraser-research.md) for primary sources,
license comparison, hardware qualifications and the cloud CPU benchmark.
No model is bundled into the APK, and inference never calls a hosted AI API.
The mounted model must be provisioned explicitly by the administrator; the
service does not download models on startup or while processing photographs.

Default inference is CPU-only, two Torch threads, one worker process, and one
active inference. A small bounded waiting queue prevents competing heavy jobs;
queued cancellation does not consume an inference slot. Active native inference
cannot be interrupted safely by Python, so its slot stays reserved until the
worker returns, and cancelled results are discarded. Idle model unloading
reduces persistent resource use. Server preparation is also serialized and
admission is bounded globally and per user.

The painted bounding box gains surrounding context. This region is resized to
a maximum 512-pixel inference edge by default, padded to LaMa's requirements,
inpainted and composited into the full-size image. Only painted pixels are
replaced before JPEG encoding. Output dimensions match the upright original;
JPEG encoding is lossy and does not promise byte-identical unpainted pixels.
Small isolated objects generally retain more working detail than a mask spread
across the whole frame. AI reconstruction is an estimate and should be reviewed
in Before/After before saving.

OpenVINO/UHD 630 acceleration is not implemented or advertised: model FFT
conversion, Intel Gen9 driver compatibility and actual acceleration are not
validated. CPU works without a discrete GPU. MobileSAM is a researched optional
selection aid, not a dependency of the brush-based first version.

## Sessions, result lifetime and saving

Jobs are private, temporary editing sessions bound to an owner and source asset.
The API returns queued/processing/ready/failed/cancelled/saved states, not
invented percentage progress. Temporary files are cleaned after cancellation,
errors, expiration and shutdown; orphan cleanup handles previous process exits.
The current implementation requires one Gallery API process for a given editing
session. A restart loses temporary sessions; the user can start again, and the
original remains unchanged. Multiple API replicas would require shared session
storage and are outside this implementation.

Save a copy is the only persistence action. Gallery writes a JPEG to its managed
upload storage and reuses normal asset ingestion, quota checks, checksums,
metadata extraction, events and thumbnail jobs. Saving is idempotent within the
session, including retry/concurrent taps. It is not an overwrite of the source.
The copy inherits the source visibility, including archived or locked photos,
so editing does not move private content into the ordinary timeline.
Once asset ingestion starts, cancellation does not falsely report that a saved
asset was never created.

The output keeps orientation 1, upright dimensions, the source capture date,
timezone and an allowlist of useful camera/GPS metadata. Source motion pairing
identifiers and stale face/object regions are not copied. Existing generic asset
metadata records provenance under `gallery.magicEraser`, including source ID
and source timezone identity as well as the model, without a new table or
migration. The result is a separate, ordinary
still image with no inherited stack or live-video link. Existing automatic-stack
production tools retain their own policy; no external maintenance code is
changed and the new provenance does not silently override manual stack choices.

## Live/Motion Photo policy

The original Samsung embedded Motion Photo or Apple still/video pair remains
unchanged and still plays through the existing timeline/player. Editing its
still image produces a clearly identified static copy: its video no longer
matches the changed still, so the result must not claim to be a Motion/Live Photo.
The editor can expose only Magic Eraser for such sources without enabling the
existing crop pipeline on asset types it deliberately excludes. No synthetic
second motion asset, false Samsung format or re-pairing is introduced.

## Production boundary

Nothing in this change installs or deploys to HP automatically. No application
ID, bundle ID, existing migration, production Memories/carousel/auto-stack
script, telemetry or cloud AI dependency changes. Activation needs a separately
built private inpainting container, mounted verified weights, a shared private
token, and a rebuilt Gallery server with the new optional API. Existing release
version metadata remains `BUILD_VERSION=5.7.1`; mobile versions are supplied at
build time by the owner. Physical mobile interaction and HP resource timings
remain separate validation work.
