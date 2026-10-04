# Motion / Live Photo previews in the mobile timeline

The main Photos timeline opts into `TimelineLivePhotoScope`. Other grids and
viewers retain their existing behavior. The scope reuses `BaseAsset`:
an image qualifies when `isMotionPhoto` is true (`AssetPlaybackStyle.livePhoto`).
Remote assets derive this from the existing `livePhotoVideoId` relation; local
assets use the platform playback style. No asset records or media formats are
created by this feature.

Only live-photo tiles register geometry. Cached rows do not allocate a player or
fetch a video. After 350 ms without scrolling or touch gestures, the coordinator
selects one image with at least 80% of its tile area visible. It prefers the most
visible image, then the one closest to the viewport center. A still-visible active
tile keeps its lease. Visibility excludes system and bottom navigation insets.

Every scroll (including scrubber jumps), pointer interaction, selection mode,
filter sheet, route/tab change, disabled setting, or background lifecycle revokes
playback. Tile removal and insufficient visibility revoke the lease too. Native
playback is paused on revocation, and the platform view/controller is removed.
Rebuilds during Flutter's locked tree phase are deferred; asynchronous source and
ready callbacks verify that the lease still exists. Only changed tiles rebuild.

Playback runs once per settled viewport. Completion/errors return to the photo
without automatically walking through the other visible photos. An 8-second
watchdog includes source loading and prevents a stalled preview from retaining
resources indefinitely. Another preview requires a different best asset and a
net scroll displacement of at least 25% of the last playback viewport height
(minimum 96 logical pixels). The displacement is measured from the last playback,
so small drags can eventually reach a genuinely new region, but back-and-forth
jitter cannot rearm the original region. Gestures, layout/candidate churn,
selection, settings, filter sheets and navigation/lifecycle transitions preserve
the consumed viewport. A remounted tile of the same asset cannot bypass this gate.

`NativeVideoViewer` supplies an explicit timeline preview mode, with the same
native player and source resolution as the existing viewer. Its notifier is
isolated from viewer controls, casting, the global motion flag, and wakelock.
Volume zero and loop false are applied before loading. Remote previews use the
authenticated `/assets/{livePhotoVideoId}/video/playback` endpoint, regardless of
the viewer's original-video preference. There is no video prefetch or additional
cache; only the active source is requested. The platform view uses logical tile
dimensions and cover cropping, not the original photo's pixel dimensions.

On Android, existing server-extracted Motion Photo video pairs are used even for
merged assets: `photo_manager`'s subtype export returns the image on Android.
Local-only embedded Samsung photos without a server pair therefore remain static.
On iOS, existing local subtype export supplies the paired movie after checking
the paired subtype's local availability (`withSubtype: true`), not just the still
photo; cloud-only sources fall back to an existing server pair or a
static photo. The native export/availability behavior still requires device testing.

The persistent, default-on setting is
`SettingsKey.timelineAutoplayLivePhotos` / `AppConfig.timeline.autoplayLivePhotos`,
under Settings → Photo Grid. Its title uses the existing i18n system (English and
the nine maintained Gallery translations; other languages retain English fallback).
No server/API/database migration or application/package/bundle ID change is needed.

## Device acceptance

- Samsung: upload JPEG and HEIC Motion Photos, confirm server pairing, and verify
  silent inline playback, correct orientation/crop, photo restoration on completion,
  and normal tap opening. Try fast flings, scrubber jumps, pinch, long-press selection,
  stack badges/cover changes, filter sheet, tabs/routes, and app background/resume.
- Measure frame smoothness, RAM and network while scrolling a motion-heavy library.
  Confirm one native decoder and one source request at a time; disabling the setting
  must produce no new motion requests. Also test slow/offline/erroring playback.
- macOS/Xcode plus iPhone: test AVPlayer/platform-view rendering, paired local MOV
  export, PhotoKit permissions (including limited access), cloud-only assets, muted
  audio, orientation/cropping, backgrounding and transitions. Repeat the selection,
  stack, Memories zoom, and timeline navigation checks.

Flutter unit/widget tests validate selection, geometry thresholds, settings,
single active playback, source routing, silent load ordering, cancellation,
resource/listener cleanup, and actual thumbnail Hero/badge/selection behavior.
They do not certify native decoder performance or physical-device permissions.
