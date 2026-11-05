# FOTO Build 38: bin intake and shared UI evidence

Synthetic photo fixtures rendered by the real Flutter widgets and coordinator, reviewed 2026-11-05. These are not Samsung captures or private user photographs. Physical smoothness, OS haptics, signed upgrade and Live Photo playback remain DEVICE_REQUIRED / HP_REQUIRED. No production operation occurred.

One decoded thumbnail is captured before the operation; only a verified receipt starts the 640 ms effect (album intake 520 ms plus 120 ms row reflow). A continuous 16-segment mesh follows a cubic Bezier path. A hinged lid opens; the opaque front wall hides the photo during intake, then the bin squashes and performs 2.5 damped rocking cycles. The 48 dp button and label stay fixed. Reduced motion retains the 180 ms fade. Failure, partial receipt, app pause, navigation or a disappearing target cannot manufacture a completed effect.

Visual review caught seams in the first strip renderer; the shared mesh removes them. It also caught premature changes to neighboring photos' crop. Their existing render children now retain their dimensions through intake, then relayout during reflow without scaling the photograph or rebuilding its player. Tests assert both geometry and retained decoded image identity.

The small gallery fixture intentionally leaves unused screen space. This is evidence for the actual toolbar and coordinator, not a full offline-feed or OS-deletion acceptance. A synthetic successful receipt removes the selected tile; the last frame shows the two remaining tiles.

| Phase | ms after ACK | Light | Dark |
|---|---:|---|---|
| 00-before | — | [frame](light-00-before.png) | [frame](dark-00-before.png) |
| 01-pending | — | [frame](light-01-pending.png) | [frame](dark-01-pending.png) |
| 02-flight | 160 | [frame](light-02-flight.png) | [frame](dark-02-flight.png) |
| 03-lid-open | 330 | [frame](light-03-lid-open.png) | [frame](dark-03-lid-open.png) |
| 04-approach | 420 | [frame](light-04-approach.png) | [frame](dark-04-approach.png) |
| 05-inside | 461 | [frame](light-05-inside.png) | [frame](dark-05-inside.png) |
| 06-swallowed | 506 | [frame](light-06-swallowed.png) | [frame](dark-06-swallowed.png) |
| 07-shake | 544 | [frame](light-07-shake.png) | [frame](dark-07-shake.png) |
| 08-settle | 588 | [frame](light-08-settle.png) | [frame](dark-08-settle.png) |
| 09-after | 641 | [frame](light-09-after.png) | [frame](dark-09-after.png) |

[Pixel witness during intake](occlusion-inside.png) and [before drawing stops](occlusion-swallowed.png): red image pixels remain fully opaque above the opening while the front wall covers the lower photo. No red pixels remain before the draw stops; normal intake has no fade.

Actual runs: 144 Flutter tests PASS (editor, grid, themes, selection, icons, album swipe, deletion); after the crop correction 19 deletion tests PASS and 3 visual tests PASS; after a regression exposed 40 dp targets under compact theme density, explicit 48 dp controls were added and all 42 bottom-sheet tests PASS. Analyzer reported no issues. Android Gradle ran 117 tests in 11 classes, with zero failures/errors/skips. This JVM result does not imply an installed APK test.

Twelve old editor assertions equated the full photo viewport with its intentionally narrower floating dock. Updated tests independently verify viewport width, centered dock width, unchanged document transform and 48 dp controls. The icon contrast test now computes the WCAG luminance ratio correctly for both foreground/background orderings.

Other changes: semantic viewer surfaces; localized selection labels and text-scaling room; a device delete action for local-only selections; bounded album reveal; consistent dense local/recent/remote album layouts; singleton height follows density. Production versions and deployment are unchanged.

[Receipts and hashes](receipts.json). Raw transient logs remain outside Git in `/workspace/foto-build38-evidence`. After normal mobile code generation, reproduce frames from `mobile/`:

```sh
flutter test --no-pub --dart-define=FOTO_TRASH_VISUAL_DIR=/tmp/foto-trash-eats \
  test/presentation/widgets/deletion/trash_eats_visual_test.dart --reporter expanded
```
