# Issue 17 sections 9–10: density audit and Build 37 handoff

Canonical requirements: [Issue 17](https://github.com/docice545/gallery/issues/17),
body updated 2026-11-03 23:21:54 Europe/Moscow. This supplements the completed
[Issue 18 audit](https://github.com/docice545/gallery/issues/18#issuecomment-6612841556).
It does not replace the canonical issue or claim Samsung visual acceptance.

Build 36 integration remains in PR 19. Build 37 presentation changes remain owned
by `codex/foto-build37-android-ui`. Published Build 37 HEAD was
`6c8882bbf2bfd69dfd8984342c142db25b45f223`; PR 16 HEAD was
`fda0ef2004bfb0e7f5908eda51e45a817c7be2e2`. Unpublished work by its owner is unknown.

## Existing implementation

- `mobile/lib/presentation/widgets/timeline/fixed/row_layout.dart` implements
  aspect-aware justified rows. `columnCount` is a density input, not a fixed row
  count. Search is bounded; row offsets are cached and searched by binary search.
- With width `w`, spacing `s`, density `d`, the default target is
  `clamp(((w - s * (d - 1)) / d) * 1.55, 96, 280)`. Actual row heights depend on
  aspect sums and row partitioning; a target is not a measured thumbnail size.
- Main mobile Timeline opts into `denseLayout`, uses 3 dp spacing, and watches
  `appConfig.timeline.tilesPerRow`. All tile corners use 6 dp in the inherited
  Build 31–32 implementation. Settings default to 4 and currently permit 2–6;
  section 9 acceptance explicitly exercises 2–5.
- Current aspect clamp is **0.25–3.0**, not 0.65–1.65. A typical 0.45 screenshot
  survives this clamp. A 72 dp minimum tile width protects badges/selection.
  Extreme aspect ratios or height bounds can require cover crop. A single-photo
  day uses a full-width bounded cover tile, inherited from checkpoint
  `d3d413ad8235b7f7fd8e627ccc8a7192f6fdf2c9`. Do not remove these guards blindly or
  claim every possible extreme image is shown uncropped.

Computed defaults at width 390 dp and gap 3 dp (not Samsung measurements):

| Density | Target row height, dp |
| --- | ---: |
| 2 | 280 |
| 3 | 198.4 |
| 4 | 147.6375 |
| 5 | 117.18 |

At width 360 dp, density 3 targets 182.9 dp. Replacing that target with the
historical 135 dp reference would usually make the grid denser. No such change
is justified without matching the actual installed SHA, viewport and media.

## Setting propagation and remaining work

The main Timeline watches density; `timelineSegmentProvider` rebuilds segments
when width/density changes. It deliberately ignores height-only changes to avoid
restarting the bucket stream. Existing date groups, asset indices and cached
row targeting must survive a density change.

`TimelinePinchZoom` reads density only in `initState`. Its `_perRow`,
`_scaleFactor` and `_baseScaleFactor` do not subscribe to later settings changes.
This is a **code-level risk requiring a widget reproduction**, not a proven
cause of the reported Google Photos mismatch. Reproduce without remounting:
start at 4, change settings to 2, return to the retained Timeline, pinch outward;
check that the gesture starts from 2 and cannot jump toward the stale value 4.
Cover settings changes, pinch completion/cancellation and reverse gestures.
The settings slider itself also initializes a hook state from the watched value;
check external updates while it remains mounted.

Section 10 now additionally requires persisted Classic FOTO / immersive
presentation selection, separate from density. The current `TimelineConfig`
has no such presentation setting. Existing Years/Months/All overview modes are
not this feature. Build 37 must preserve Classic, implement reversible switching
with a retained scroll anchor, and add a transient SafeArea-aware date/optional
location overlay without extra geocoding/network requests. These UI changes are
not implemented in the Build 36 stabilization branch.

## Regression coverage and execution boundary

New cases in `justified_row_layout_test.dart` exercise production defaults for
densities 2–5 at widths 320/390/844, monotonic size preference, natural screenshot
proportions with more than three tiles, and mixed date groups/asset indices/row
targets across density and resize. They do not hardcode Google Photos parity.

New cases in `dense_timeline_overlays_test.dart` render density 2–5 with a
screenshot Live Photo stack, landscape and portrait; assert exactly one tile
per representative asset, one stack badge, motion badge, usable finite geometry
and no widget exception. These supplement existing selection, resize, image
request, overlay and playback tests. Full Flutter CI executes both files.

```bash
cd mobile
flutter test --no-pub --concurrency=1 \
  test/presentation/widgets/timeline/justified_row_layout_test.dart \
  test/presentation/widgets/timeline/justified_timeline_widget_test.dart \
  test/presentation/widgets/timeline/dense_timeline_overlays_test.dart
bash scripts/live_photo_regressions.sh
```

Local Flutter execution is unavailable in this cloud environment: the SDK
download endpoint is blocked by its configured network policy. CI results must
be linked for the actual tested SHA; adding tests is not a PASS. The independent
native decoded-motion CI gate and all existing lifecycle/route/visibility/single
playback lease checks remain required. No runtime playback or grid code changed
in this handoff.

## Physical acceptance: pending

The current issue body/comments contain no downloadable side-by-side screenshot
attachments. No Samsung display measurements or profile traces were collected.
For the owner with device access:

1. Record installed source SHA/version, phone model, display scaling, orientation,
   logical viewport and selected density. Use comparable media in both apps.
2. Capture matching Google Photos/FOTO screenshots for densities 2–5; record
   actual tile widths/heights, row populations, crop, gaps and date-heading space.
3. Calibrate density 3 from that evidence, retaining adaptive rows, stack
   representatives, chronology and screenshot proportions. Test both Classic and
   immersive modes once section 10 exists. Record any deliberate crop tradeoff.
4. Recheck settings→Timeline→pinch, resize, date/asset scroll anchors, exact
   selection IDs and stack 2→1 without deleting the surviving photo.
5. Perform all eight Samsung Live Photo scenarios, including cold start directly
   into Timeline and actual movement with `selected → native-ready →
   play-request-accepted → position-advanced`. No Viewer warmup, permanent active
   route or periodic timer workaround.
6. Profile UI/raster frame times, p95/p99 and jank in profile mode at 120 Hz
   (~8.33 ms budget), including density/mode switching, scrolling, selection,
   Viewer/back, background/resume and deletion animations.

**Visual parity and 120 Hz acceptance remain pending. Production remains NO-GO.**
