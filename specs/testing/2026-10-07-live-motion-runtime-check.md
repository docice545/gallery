# Live/Motion timeline: runtime verification boundary

Baseline: `75633fc0d0071c18d9e48ce1017e830d8556416d`. The S23 user reports
static timeline Live/Motion in «Фото» 5.7.2 build 4/5. This report remains a
physical-device defect until an actual failing stage is identified; passing
mock-controller tests cannot close it.

## Preserved path

`DriftPhotoPage` / the main timeline uses `TimelineLivePhotoScope` and the existing
timeline asset/thumbnail widgets. Image assets with the existing `livePhotoVideoId`
or local Live Photo playback style qualify; ordinary photos/videos do not. At
least 80% visibility, 350 ms settling, center preference and meaningful viewport
movement are unchanged. Scroll/touch, selection, filter, navigation, background
and disposal revoke the single playback lease. One completion/failure consumes
the viewport; no loop or next-photo cascade is introduced.

The still keeps the existing tile × DPR / source-aspect calculation, bounded
1440 px long side and thumbnail → preview selection. No timeline original request
is added. Face-aware alignment/union/contain fallback and the still/motion geometry
from the previous commits remain unchanged. `7b39a7f73b` already fixed rejection
of ordinary lower-resolution / different-aspect paired camera videos. It is in
this baseline and must not be presented as a newly discovered S23 fix.

The selected tile alone creates `NativeVideoViewer`. Android uses the existing
server-extracted paired video's `/assets/{pairedId}/video/playback`, not a local
motion JPEG as video. iOS can use an already-local paired PhotoKit resource and
otherwise that same authenticated playback route. The sharp still is retained
during loading and restored on end/error/revocation. Native metadata controls the
surface size; mute and non-loop are configured before load. Existing eight-second
watchdog and foreground/navigation cancellation behavior are retained.

## New diagnostic/test preparation

The production path now emits bounded, anonymous stage records through the
existing application logger. There are no new analytics, polling or diagnostic
server calls. Records intentionally contain no filenames, asset IDs, URLs,
tokens, local paths or pairing identifiers:

```text
Timeline motion: enabled=... setting=... selecting=... filter=... foreground=... route=... scrolling=...
Timeline motion: registered=... live=... visible=...
Timeline motion: selected
Timeline motion: platform-view-created
Timeline motion: source:server-pair-playback
Timeline motion: native-load-accepted
Timeline motion: native-ready:WIDTHxHEIGHT
Timeline motion: play-request-accepted
Timeline motion: position-advanced
Timeline motion: finished:ended
```

Scope records are deduplicated independently for state and measured geometry.
Position is logged only on the first actual advance. Failures distinguish
source-unavailable, invalid geometry, load/play/native errors, timeout and
backgrounding. An acknowledgement of `play()` does not prove frames were visible.
Unknown/edited still geometry has its own skip record instead of being silently
confused with a decoder failure. Timeline exception messages are suppressed in
these records; ordinary viewer logging remains unchanged.

The integration test mounts the **production** `TimelineLivePhotoScope` /
`TimelineLivePhotoTile` geometry and `NativeVideoViewer`, with no preview-builder,
native-channel or controller replacement. Only asset lookup is a fixture. A
synthetic 160×90 H.264 / 1.5 s clip is served by a loopback HTTP server requiring
the existing native cookie/custom-header contract. Still dimensions are 4000×3000
to exercise the paired camera-aspect mismatch. The test requires real native
position progress and natural end, rejects watchdog completion and verifies no
second visible Live Photo starts. Native decoding requires an Android device or
the CI emulator; this is distinct from the Linux PlatformView-creation test.

## Physical S23 acceptance

1. Install the new **HP-key-signed** validation build without deleting the current
   app. Enable the existing timeline autoplay setting; do not reset app data.
2. Use one known paired server-only Samsung Motion Photo; repeat with a local+
   remote pair, portrait/landscape, a face-aware crop and no faces.
3. Scroll meaningfully, stop with ≥80% of the tile visible, and observe one muted
   pass. Compare the sharp still before/after; check crop stability and no cascade.
4. Repeat fast/slow scroll, tap to viewer, selection, filter, background/foreground
   and navigation. The same settled viewport must not rearm after these actions.
5. If still static, export only the bounded `Timeline motion:` records for this
   attempt through the existing logs UI. The last stage identifies whether the
   problem is eligibility, platform creation, source/HTTP, metadata, decoder/play
   or visible composition. Include the APK's actual build/commit and non-private
   codec/dimensions. No personal image, cookie, URL or credentials are needed.
6. Native `position-advanced` with a static-looking surface requires inspection of
   Android composition on the S23; it must not be labelled a server/source failure.

Native CI results, physical S23 results and physical iPhone results must be reported
separately. No new S23 root cause or successful physical playback is claimed by
this repository-side preparation alone.
