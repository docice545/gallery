# FOTO original icon system v1 — approved

**APPROVED by the user: `ccdb8a892`**, Viewer/editor sheets, 20/22/24 dp sizes and action mapping. Integration reuses this exact geometry and existing handlers. Approval does not waive action mapping, accessibility, contrast or hit-target tests; substantial future geometry changes require separate review. All paths were authored for this proposal; no Samsung images, SVGs or traced assets were used.

- [Compact overview](overview.png): 84 glyphs, both themes.
- [Viewer full sheet](viewer.png) and [editor full sheet](editor.png): each glyph at 20 / 22 / 24 logical dp, normal, pressed/selected, disabled and destructive variants.
- [Interactive offline sheet](preview.html): open locally at 100% browser zoom, filter Viewer/editor; toolbar samples show 48 × 48 dp targets. PNGs are reference-scale exports, not Samsung captures.
- [Exact action mapping](action-mapping.md): current actions and engine bindings; unavailable actions remain unavailable. `foto_icon_mapping.dart` covers every existing `ActionButtonType`, `EditorMode`, and `AnnotationTool`.

## Geometry and tokens

24-unit construction grid, round caps and joins, shared corner vocabulary and optical stroke widths of 1.65 / 1.75 / 1.85 dp for 20 / 22 / 24 dp glyphs. Familiar action metaphors remain recognizable. Device trash has a phone/bin silhouette distinct from server trash. Save Copy combines overlapping pages with the save symbol; select-group remains a checked group.

The reference sheet uses the existing FOTO brand colors `#4150AF` and `#ACCBFA` and illustrative surface colors. The Flutter candidate resolves colors from the actual theme (`onSurface`, `primary`, `error`, disabled `onSurface` at 38%), including user theme overrides; it does not hardcode the preview surface palette. Active state has both color and a container, disabled buttons do not dispatch. `FotoIconButton` retains standard pressed/focus feedback, tooltip, accessible action name, selected semantics and a 48 dp hit target, without permanent captions. Production adoption must use translated existing action labels.

The HTML shows translucent surfaces (light 92%, dark 94%) and all state/size variants. Static sheets show their reference surface colors. Contrast for enabled reference states exceeds 3:1 against the respective panel/container; disabled variants intentionally have lower emphasis. Actual theme overrides, photo backgrounds, outdoor legibility and recognizability still require device review. A design sheet cannot prove 120 Hz performance.

## Reproduction

From repository root:

```bash
python3 specs/design/foto-icons-v1/generate.py
dart format mobile/lib/presentation/widgets/icons/proposal/foto_icon_paths.dart
uv run --with cairosvg==2.9.1 python - <<'PY'
from pathlib import Path
import cairosvg
root = Path('specs/design/foto-icons-v1')
for name in ('overview', 'viewer', 'editor'):
    cairosvg.svg2png(url=str(root / f'{name}.svg'), write_to=str(root / f'{name}.png'))
PY
cd mobile
flutter test --no-pub test/presentation/widgets/icons/foto_icon_proposal_test.dart
```

`manifest.json` is the source for SVG paths, generated Dart, the sheets and action mapping. `generate.py` uses Python's standard library. PNG rasterization uses CairoSVG and DejaVu Sans; vector geometry is also available as SVG. SDK formatting and Flutter widget checks run in GitHub CI; no local Flutter result is claimed where the SDK is unavailable.

The widget suite covers exhaustive enum mappings and both themes at each size, visible states, icon-only controls, 48 dp geometry, semantics/tooltips and disabled-action safety. The committed SVG/PNG contact sheets preserve the reviewed artifact (their embedded pending label is historical and superseded by the approval above). They are not hardware screenshots or automatic Flutter golden acceptance. The runtime Viewer/editor integration is covered separately by actual-control and gesture tests.
