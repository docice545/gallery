# Shared trash action capsule

User clarification implemented with one `TrashActionBar` used by trash timeline selection and fullscreen trash viewing. Exactly Restore and Delete permanently are shown, in that order. Existing actions retain owner/selection validation and the irreversible confirmation. Repeated Restore presses are ignored while its request is pending. The trash viewer omits share/OCR/edit/upload/other bottom actions, its top action menu, favorite/activity actions and the download floating action. Other viewers retain their existing branches. The deletion animation is unchanged by this clarification.

The actual widget captures below use a blank component host, a 393×852 viewport and 24 dp system navigation inset. They are component evidence, not Samsung/fullscreen photo screenshots. Selection and viewer PNG bytes are identical for every corresponding theme and text scale. Reviewed captions are complete, on one line; at large text sizes the same capsule uses two full-width action rows instead of clipping or ellipsis. At normal size it uses two icon/caption columns. Restore follows the FOTO primary color; permanent deletion uses the semantic error color.

| Theme | Selection | Viewer | Large text |
|---|---|---|---|
| Light | [frame](light-selection-1.0.png) | [frame](light-viewer-1.0.png) | [frame](light-selection-2.0.png) |
| Dark | [frame](dark-selection-1.0.png) | [frame](dark-viewer-1.0.png) | [frame](dark-selection-2.0.png) |

Actual tests: 182 viewer/action/trash regression tests PASS (including Live/Motion source and lifecycle tests); 20 focused capsule tests PASS (English/Russian, 320/393 dp widths, light/dark, 1×/2× text, both sources, confirmation/cancel/restore double tap); analyzer zero issues. Physical device checks remain DEVICE_REQUIRED. [Receipts](receipts.json).

Reproduce from `mobile/` after normal code generation:

```sh
flutter test --no-pub --dart-define=FOTO_TRASH_BAR_VISUAL_DIR=/tmp/foto-trash-bar \
  test/presentation/widgets/bottom_sheet/trash_action_bar_test.dart --reporter expanded
```
