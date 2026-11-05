# Build 37: selectable Timeline presentation and existing date overlay

Scope: [Issue 17 sections 9–10](https://github.com/docice545/gallery/issues/17),
including its 2026-11-03 clarification to reuse the existing Scrubber date label.
The implementation is isolated in `codex/issue17-smart-timeline`, based on the
published `codex/foto-build37-android-ui` at `6c8882bbf`. Build 36 / Issue 18 / PR 19
remain separate. The current executor owns all remaining Build37 and compatibility software work. Backend fixes are independently reviewable in PR21 and integrated into PR20; production, original media and signing remain untouched.
CI guards explicitly prevent PR signing and registry publication.

## Behavior and reused components

- `SettingsRepository` persists a named `TimelinePresentation` enum and Classic's
  floating-date preference in the existing settings table. Existing users default
  to Classic with the date disabled, matching published Build 32 behavior. Unknown
  future mode names fall back to Classic. No database migration/reindex is needed.
- `LayoutSettings` offers Classic FOTO / Like Google Photos (Russian translations
  included), independently of the density slider. Density is 2–5 in both modes;
  the setting remains a size preference, never `crossAxisCount=3`.
- `Timeline`, `FixedSegmentBuilder` and `FixedRowLayout` retain the justified
  mosaic, stack representatives, date buckets and source ordering. Classic keeps
  month/day headings. Immersive gives those headers zero visual extent while
  retaining dates in data and row semantics. The existing asset scroll-anchor
  mechanism also handles presentation/density changes. Years/Months/All overview
  navigation remains distinct from this presentation preference.
- The existing `Scrubber` label controller and fade timing are reused. There is
  one date label, positioned below the viewport SafeArea/top controls independently
  of the thumb. It appears during scrolling/dragging and fades after 1.4 seconds
  idle; reduced motion skips the fade. `IgnorePointer` leaves photo taps and
  selection available. The thumb retains its existing fast-scroll behavior.
- Current date comes from a binary search of cached segment geometry, adjusted
  for preceding slivers. Optional place comes from embedded EXIF or the local
  synced SQLite EXIF row for an already buffered visible asset. No network asset
  fetch or geocoder is called. Blank/missing metadata produces date only; long
  location names use an ellipsis.
- `TimelinePinchZoom` now starts each gesture from the current persisted density,
  fixing its stale initState-only value after an external settings change.

## Density evidence boundary

The [density audit](2026-11-03-foto-smart-density-handoff.md) documents actual
Build 31–32 formulas, the 0.25–3.0 ratio clamp, 72 dp minimum tile width and bounded
single-asset cover crop. Defaults are preserved pending matched Samsung evidence;
blindly replacing the density-3 target with 135 dp would usually make this
implementation denser. No same-device Google Photos/FOTO screenshot pair is
available as an attachment in this cloud session or the current issue comments.
**Approximate visual parity is not yet calibrated or accepted.**

## Regression checks

New/extended Flutter tests cover:

- settings stored in real SQLite and restored into a fresh AppConfig snapshot;
  unknown-mode fallback, UI reopening and independent Classic date/density options;
- production density defaults 2–5, portrait/landscape/screenshots, resize, date
  groups and row/asset indices; immersive headers without changed mosaic geometry;
- real Timeline mode/density switching, retained selection and scroll anchor;
- stale-density pinch reproduction on the same retained widget;
- one fixed date overlay across thumb movement, current date changes, idle hiding,
  optional/long location and pointer pass-through to the photo beneath it;
- stack as one tile and motion badge at all four densities.

`.github/workflows/smart-timeline.yml` runs these checks plus the existing PR 16
Live Photo source contracts, followed by the existing native decoded-motion
integration test in a disposable Android emulator. Static analysis and full
Flutter coverage continue in the existing workflows. The native test requires
advancing playback position; mocks and cover rendering alone are insufficient.
No playback lease, route, visibility or app lifecycle gate was replaced.

Local Flutter/Dart execution is unavailable because the configured network policy
blocks the SDK download. The local WASM formatter is a syntax/formatting aid, not
the pinned SDK acceptance result. Use the linked CI run for the tested SHA before
claiming PASS. CI debug APK installation is only in a disposable emulator, never
the user's Samsung/iPhone. No signed release or physical installation is performed.

## Still required

Samsung: matching Google Photos/FOTO screenshots (same display scale, orientation,
source SHA and comparable media), actual tile measurements at densities 2–5,
Classic/immersive switching with selection/stacks, large text/landscape/insets and
date location without network. All eight Live Photo scenarios remain mandatory,
especially cold start directly into Timeline and `selected → native-ready →
play-request-accepted → position-advanced`, one player, Viewer/back and background
resume. Profile UI/raster p95/p99 and jank at 120 Hz (~8.33 ms budget).

All Issue17 editor, album swipe/trash, notifications, exact selection IDs and persisted stack2→1 obligations remain with this executor. Their current implementation/test status is maintained in [the unified checklist](../../BUILD37_CHECKLIST.md), without delegation to another owner. iPhone/SideStore and signed Android
upgrade acceptance remain tracked by Issue 18. **Production/release NO-GO.**

The executable Samsung capture procedure and per-scenario evidence are in [Build37 device acceptance](2026-11-04-build37-device-acceptance.md).
