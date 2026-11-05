# FOTO Unified Action Bars — cloud validation

Approved source: branch [`design/foto-unified-action-bars-20261105`](https://github.com/docice545/gallery/tree/design/foto-unified-action-bars-20261105), commit `df426526e283c05a64c1c40c98782713c2192f52`.

Both [specification](https://github.com/docice545/gallery/blob/df426526e283c05a64c1c40c98782713c2192f52/specs/design/foto-unified-action-bars/README.md) and [SVG](https://github.com/docice545/gallery/blob/df426526e283c05a64c1c40c98782713c2192f52/specs/design/foto-unified-action-bars/foto-unified-action-bars.svg) were read using `git show` after `git fetch origin design/foto-unified-action-bars-20261105`. The SVG was rendered and inspected as the visual reference. No branch switch, merge or reset was performed.

Work continues on `codex/foto-build38-unified-16`. Starting HEAD was `3678203a4d12972ddce6871cc343b4e181b96881`, with a clean worktree. Completed predecessors remain in its ancestry:

- Accepted first three fixes: `06af1905efe80bbe3fe342a94e5c97245a270fba`.
- Branded Timeline deletion: `7685d6dfb1f27f05c2d3a414e4f49529c2a829e7` ([evidence](../foto-build39-timeline-deletion/README.md)).
- Adaptive Mosaic: `1e070783ce8232d48408b6b87ee491920af95c87` ([evidence](../foto-build39-adaptive-mosaic/README.md)).
- Google Lens action: `3678203a4d12972ddce6871cc343b4e181b96881` ([technical investigation and evidence](../foto-google-lens/README.md)).

## Implementation

The existing `SelectionToolbarFrame`, `ActionCellGrid`, `SelectionToolbarAction`, `ViewerControlSurface` and `ImmichColumnButton` form one shared shell and labeled action. There is no second toolbar system. Actual action builders, selected asset IDs, owner checks, asynchronous busy guards, secondary share actions and deletion confirmations remain in use.

| Context | Preserved behavior |
| --- | --- |
| Fullscreen owned cloud photo | **Отправить / Изменить / Добавить / Объектив / Удалить**, filtered through existing eligibility |
| Fullscreen local-only photo | Send, Lens, device deletion; Upload remains in More. Existing editor/Add eligibility is retained; unavailable actions do not fill slots |
| Fullscreen video | Existing video controls and supported actions; no Lens entry for video |
| Timeline selection | Existing server/device deletion, Send, Add and contextual More; target remains the exact trash icon for the existing animation |
| FOTO albums | Server trash, Send, Link and More; album owner actions and collection picker remain available |
| Device albums / Library folders | Device removal, Send, Upload and More; original cleanup/upload and permission paths |
| Library favorites/archive, partner views, spaces, locked folders | Their existing action lists use the common `BaseBottomSheet` compact shell; expanded contextual sheets retain their existing content |
| Trash viewer and selected items | The same Restore / Delete permanently panel, owner/readonly restrictions and irreversible-delete confirmation |

The visible short captions **Отправить**, **Объектив**, **С устройства**, **Ссылка** keep the full underlying operation as their accessible label/tooltip. The approved scan-search pictogram was added to the existing FOTO outline family; the existing Share icon is unchanged. Theme tokens supply surface, foreground and destructive colors.

Fullscreen OCR moves to More; the readonly viewer retains its existing OCR access. Upload and OCR are tested through their actual relocated actions. Top controls retain Back, Live/Motion playback, shared-album comments, Favorite and More. The date/time is localized on one line when it fits, and uses an additional line when necessary.

## Measured layout and visual evidence

[Before/after comparisons](visual-comparison.md): **54 actual Flutter render pairs** across nine contexts, both themes, 390×844 dp and text scales 100%, 150%, 200%. Every PNG has an adjacent geometry record. The reference run renders source from `3678203a4`; [restoration record](baseline-restoration.json) verifies the current source was restored byte for byte afterward.

These are production widgets rendered by Flutter with real FOTO fonts, icons, localization, themes and action providers over a deliberately synthetic background. They are **not screenshots from a physical Samsung**. No screenshot content was generated or retouched to simulate success.

- Normal bottom surface: **366×52 dp**, horizontal margins **12 dp**, bottom edge above the **24 dp** navigation inset.
- Normal top painted capsule: **44 dp**; actual Back/action touch regions **48×48 dp**, with status inset respected.
- Shared-album Live Photo retains all four trailing actions and places its date on another line if needed.
- Accessible 200% viewer: five actions use a **189 dp** tall capsule; common four-action contexts use **126 dp**, and trash two actions use **126 dp** when their full captions need separate rows. This follows the specification's explicit accessible-height exception.
- Tests assert readable one-line captions, non-overlapping action rectangles, actual touch regions >=48 dp, identical outer width for 2/3/4/5 actions, absence of ellipsis, and no layout overflow.
- [Timeline deletion frames](timeline-delete/) use the real thumbnail renderer, real action and existing effect for single/batch local/server deletion. They include the resulting mosaic after reflow.
- [Lens / viewer return frames](lens-return/) include an actual decoded `PhotoView` before and after the handoff. Tests assert identical controller transform, zoom/pan, route and control state after lifecycle resume.

## Executed validation

- **1222 tests PASS**, process exit 0: [regression.log](regression.log).
- **30 changed Dart files: no analysis issues**, process exit 0: [analyze.log](analyze.log).
- **54 baseline renders completed**, process exit 0: [baseline-render.log](baseline-render.log). This is reference generation, not approval of the previous layout.
- **17 focused stack/local-deletion tests PASS** after updating the retired button finders: [updated-fixtures.log](updated-fixtures.log); these also pass in the final 1222-test run.

Earlier failing iterations were corrected and are not counted as passes. Logs only normalize trailing whitespace. The full final log retains injected error-path output, Drift fixture warnings and the engine finalizer diagnostic observed in earlier runs; test status is determined by assertions and the process exit, not by suppressing log lines.

The suite covers the 79 new toolbar checks (54 context renders, relocated Upload/OCR behavior, 24 combinations of action count/theme/font), all related pre-existing toolbar tests, actual raster-editor entry/copy tests, local/cloud permissions, stack deletion and rejection recovery, trash confirmation/cancel, single/batch Ghost Trap, disabled/reduced-animation modes, both mosaic modes, the 00:39/00:17/00:11 scenario, date boundaries, selection, scroll anchoring and 50,000-item virtualization. No model, repository, deletion service, editor, native sharing implementation or mosaic layout algorithm was modified by this commit.

Existing test fixtures were adapted to find the shared labeled button and full tooltip instead of the retired icon-only button type/long visible caption. Assertions on callbacks, IDs, selection, stack survivors, server rejection, image transform and irreversible confirmation were retained. Text geometry tests load the actual font instead of the test-only Ahem font.

Reproduce with Flutter **3.47.2 / Dart 3.13.2**, dependencies and generated sources already prepared:

```bash
bash specs/testing/foto-unified-action-bars/run-regression.sh
xargs flutter analyze --no-pub < specs/testing/foto-unified-action-bars/analyze-files.txt
cd mobile
flutter test --no-pub test/presentation/widgets/asset_viewer/unified_action_bars_test.dart \
  test/presentation/widgets/bottom_sheet/unified_action_shell_test.dart \
  --dart-define=FOTO_UNIFIED_CAPTURE=/tmp/foto-unified-action-bars/after
```

Full changed-file list: [changed-files.txt](changed-files.txt). Dart analysis inputs: [analyze-files.txt](analyze-files.txt). Source and evidence checksums: [source-sha256.txt](source-sha256.txt), [SHA256SUMS](SHA256SUMS).

## Google Lens: actual integration and limits

**Implemented route: the public Android Sharesheet fallback**, using the existing `ACTION_SEND` path, temporary read permission, `ClipData`/`EXTRA_STREAM`, and a `content://` URI from FOTO's existing FileProvider. No undocumented Lens Activity, package-forcing or deep link is used. Checked Android/Google documentation did not establish a public supported direct Lens image-launch contract; the linked Lens report contains the checked official sources.

The bottom **Объектив** entry opens an explanatory dialog. A second explicit choice opens the system chooser. Local/merged photos use the existing local-copy sharing path; cloud-only photos obtain a local JPEG preview via the existing media repository. Live Photo sends the still image only. FOTO does not forward an image to Google through its backend. Existing cancellation, progress, errors and retry remain in place. If Google/Lens is unavailable, the chooser allows a compatible installed application; the UI does not claim Google Lens will always be listed.

Local/cloud preparation, permission/URI/native-channel parameters, cancellation, failure, and return to a zoomed/panned viewer are automatically tested. These tests do **not** prove that an installed Google app accepted and processed an image on Samsung.

**DEVICE_REQUIRED:** Android 13–16 / Samsung One UI, actual Google/Lens present and absent, chooser acceptance, real media permissions, return to FOTO, system font/insets and smooth animation on hardware. [Device discovery](devices.log) reports no connected devices. APK was not built; production, backend, Docker, application ID, versionCode and signing were not changed. This report is cloud UI validation, not final hardware acceptance.
