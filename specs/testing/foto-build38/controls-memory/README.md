# Shared controls and memory lane visual review

Real `CompactSelectionToolbar`, `AlbumTrashReveal` and `MemoryLane` rendered in a synthetic comparison board, not a complete app screen or a Samsung capture. The procedural landscapes contain no private photographs. The blank middle area belongs to the deliberately small comparison fixture, not a feed with failed loading.

Actual run: **4 PASS** (light/dark grouping and comparison board), reviewed all six PNGs. Both cover and title move exactly 64 logical pixels; swiping alone never calls deletion. Scrolling the real lane collects all 16 unique memory IDs. The short Russian overflow label “Ещё” is complete; its full accessible tooltip is retained. Separate toolbar tests pass at 320 logical pixels, 1×/2× text and navigation insets.

| Theme | Before | Swipe reveal |
| --- | --- | --- |
| Light | [closed](light-before.png) | [open](light-swiped.png) |
| Dark | [closed](dark-before.png) | [open](dark-swiped.png) |

The additional [light](light-grouping.png) and [dark](dark-grouping.png) captures exercise the actual grouping pill, all three taps and a 24 dp navigation inset. They are separate control fixtures, not a full timeline screenshot.

Reproduce after normal mobile code generation:

```sh
bash docs/acceptance/capture-cloud-visuals.sh "$PWD" /tmp/foto-controls-memory
```

The wrapper temporarily copies its own uniquely named fixture into the existing mobile test package and removes only that file on exit. No production source or golden baseline is overwritten. Receipt: `../cloud-final-receipts.json`. Candidate: `e2cc9c001d3f8efd7f1762037e16932c56699d2c`. Samsung gesture feel, actual large-library memory ordering and system insets remain **DEVICE_REQUIRED**.
