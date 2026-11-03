# Build 37: invariant editor viewport

Issue 17 section 12 replaces the earlier growing-controls layout. The existing
`EditImagePage`, `EditorState`, `CropController`, `AnnotationEditor`, Save Copy
and Magic Eraser request/import lifecycle remain the editing implementation.
There is no second editor or new persistence path.

`EditorDock` reserves one **56 dp** row plus the current bottom SafeArea inset.
Category selection replaces that row with contextual controls. A pinned Back
control restores categories; horizontally scrollable overflow retains 48 dp
hit targets on narrow screens and at large font scale. The AppBar remains 56 dp
with accessible Back/Cancel, Undo, Redo and explicit Save Copy controls.

Parameters use the same dock's `OverlayPortal` and `TapRegion`, capped at 160 dp
above the dock. They never enter the Column that sizes the photo. Color and
slider completion dismiss the popup; outside taps close it without a modal
barrier intercepting drawing. A new parameter replaces the previous popup.
The existing MarkupControls callbacks still update the same document/history.
The existing MagicEraserPage also uses the common dock; brush options, result
comparison and error messages do not add persistent rows. The layers picker is
a bounded temporary dialog rather than an expanding bottom sheet.

The retained preview element and CropController avoid tool-depth remounts. With
unchanged constraints and content geometry, `EditorViewport` keeps its zoom/pan
transform. Crop changes intrinsically alter content geometry. Keyboard opening
can temporarily resize the viewport; closing it restores the baseline. Extremely
short IME layouts may hide the dock while preserving the document.

The FOTO vector proposal is used as a **draft candidate**, per the user's section
12 request. Its separate [contact sheet](foto-icons-v1/README.md) remains
**ICON DESIGN APPROVAL PENDING**. No implicit design approval or Samsung asset
copy is implied by wiring the candidate controls in this Draft PR.

## Evidence

`editor_compact_layout_test.dart` measures exact viewport rectangles across
categories, pen/marker/brush/eraser, color/width/opacity and repeated back navigation
at phone, narrow and landscape sizes on Android/iOS widget platforms. It checks
zoom, crop-controller identity, drawing, undo/redo, IME and orientation. Existing
copy-import/retry, crop history and Magic Eraser functional suites keep their
behavior assertions; their locators follow the new contextual navigation.

Seven `fixed_dock_*.png` files are actual Flutter widget renders of the same
synthetic photo at identical 393 × 852 logical pixels. Their source SHA and
measured rectangles are recorded in `editor-dock-review/measurements.json` once
the render job succeeds. Before images remain addressable at source
`b61867889c0a47a06ff19d7be1f0ca00c72c1945`, under
`mobile/test/pages/edit/goldens/compact_android_portrait.png` and
`compact_android_portrait_draw.png`.

The explicit PR label `review:editor-screenshots` requests the render job. Normal
regression jobs compare golden files; they never update them. The render job
runs the structural/history assertions with `--update-goldens` and publishes
only seven PNGs plus the geometry receipt to the existing review branch. A moved
source SHA or any failing assertion blocks publication; no force update is used.
These are review baselines, not approved icon designs or physical-device results.

Samsung comparison, original-media/Save Copy acceptance, all eight PR 16 Live
Photo scenarios and profile-mode UI/raster timing at 120 Hz remain required.
No Backend, production, signing, device installation, merge or deployment is
part of this layout change. Backend rating-race reproduction was handed to its
owner in Issue 18 and remains an independent release blocker.
