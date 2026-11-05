# FOTO Unified Action Bars — approved visual system v1 (2026-11-05)

> DESIGN REFERENCE ONLY. Do not auto-merge this branch, rebuild APK, deploy Docker or overwrite Codex work. Approved by product owner in chat. The SVG next to this file is a visual contract, not production code.

## Visual goal

One coherent, extremely slim Samsung One UI-inspired floating pill language throughout FOTO, while preserving FOTO's own icons, features, behavior, permissions and semantics. Existing compact selection components from commit `06af1905e` are the first place to reuse; avoid a competing action-bar system.

**Approved labels in fullscreen viewer, left to right:** `Отправить`, `Изменить`, `Добавить`, `Объектив`, `Удалить`. Replace long `Поделиться` visible caption with `Отправить` (keep full accessibility description where useful). **Never wrap captions at normal font size.**

## Canonical tokens / gradation

| Token | Standard | Adaptive behavior |
| --- | --- | --- |
| outer horizontal margin | 12–16 dp, same across screens at same viewport | respect safe area |
| pill width | available content width (viewport minus identical margins) | never force 5 actions into insufficient width |
| top pill visual height | 40–44 dp | may grow for 150–200% fonts or accessibility |
| bottom pill visual height | target 48–52 dp | grow if captions/touch areas require |
| pill corner radius | fully rounded (height / 2) | same visual language everywhere |
| icon optical size | 20–22 dp | preserve icon family and baseline |
| caption | short, single line at normal scale, centered | adaptive typography/layout at 150–200%; no clipping |
| touch target | at least 48×48 dp, including invisible hit regions | avoid overlap of adjacent targets |
| icon-to-caption gap | 1–3 dp | no extra vertical whitespace |
| inner vertical padding | minimal | do not reduce touch targets |
| action distribution | centered, equal visual slots | 2–5 actions; preserve identical outer pill width |
| delete/destructive icon | semantic red, accessible contrast | don't recolor non-destructive actions red |
| light background | soft neutral light grey matching FOTO theme | use actual theme tokens, not hard-coded mock colors |
| dark background | neutral dark grey matching FOTO theme | use actual theme tokens |
| transitions | preserve existing FOTO motion | avoid layout jumps |
| elevation | subtle or none, no large halo | respect existing theme |

The sample SVG uses illustrative colors (#e6e4e9 / #25232b / #c92b35) and is NOT an instruction to hardcode them. Resolve from Flutter theme and verify contrast.

**Critical:** 48–52 dp is a visual target, not a hard cap. If five labeled buttons plus accessible hit areas do not fit, use safe adaptive behavior and report the real dimensions. Do not clip text, shrink hit targets, hide actions silently or overlap content. 200% text may need a taller pill or a contextual alternative.

## Iconography

Use one consistent outline family (Lucide-style / equivalent existing Flutter icon set) with ~2 dp stroke at 20–22 dp, rounded joins/caps. Prefer existing FOTO assets if visually equivalent. Do not add an unrelated icon package solely for this design. Canonical pictograms:
- Send/share: `share-2`, caption `Отправить`.
- Edit: `pencil`, caption `Изменить`.
- Add to album: `folder-plus`, caption `Добавить`.
- Visual search: `scan-search`, caption `Объектив`; use Google Lens brand only if permitted.
- Delete/trash: `trash-2`, caption `Удалить`.
- Restore: `rotate-ccw`, caption `Восстановить`.
- Move: `move`, caption `Переместить` only when it fits; otherwise approved shorter context-specific text, never ellipsis.
- Back: `chevron-left`.
- Favorite: `heart`.
- More: `ellipsis`.
- The existing extra top-viewer button must remain; the SVG uses a neutral placeholder and is NOT authority to replace its real function.

Use semantic red for irreversible destructive actions, preserve existing red delete affordance. Distinguish trash, remove from album, remove local copy, permanently delete. Do not rename operations in ways that change meaning.

## Context matrix — audit before coding

| Screen / state | Same pill shell? | Actions |
| --- | --- | --- |
| Fullscreen photo (local) | Yes | Send, Edit, Add, Lens, Delete, only if supported |
| Fullscreen photo (cloud) | Yes | Same where supported; cloud-specific permissions/download |
| Fullscreen video | Yes | Preserve existing video actions; do not pretend Lens supports video |
| Timeline selected items | Yes | Existing selection actions, count, batch permissions, Undo |
| Album contents (FOTO) | Yes | Existing actions only; keep album semantics |
| Local device albums/folders | Yes | Existing local-file actions; preserve SAF/MediaStore permissions |
| Library / device folders | Yes | Existing context actions |
| Trash (single and selected) | Yes | Restore, Delete permanently; preserve confirmation and recoverability |
| Favorites, search results, memories | Audit | Only migrate if an analogous action bar exists |
| Editor tools | No forced migration | Do not rewrite editor toolbars |
| Bottom sheets / modal dialogs | No forced migration | Do not convert dialogs into pills |
| Navigation | No forced migration | Do not replace navigation bar |

Do not show irrelevant actions merely to fill empty slots. 2–5 actions should use the same external width and height, with centered inner distribution. Preserve action ordering where behavior depends on it.

## Compact top viewer bar

One-line date/time (e.g. `5 нояб. 18:22`) centered where space permits, back left, preserve every currently existing top action on the right. Visual height ~40–44 dp; tap areas >=48 dp; preserve status-bar safe area, gestures, favorites, and the currently existing extra button. For long date or 200% text, adapt without clipping.

## Lens technical requirement

Investigate *supported public Android intents* for sending a still image to installed Google/Lens. No undocumented explicit activities or unsupported deep links. If direct Lens launch is not supported, use Android Sharesheet with safe content URI and `FLAG_GRANT_READ_URI_PERMISSION`, clearly describing the actual behavior. Cloud photos require a temporary local readable copy. Never upload on user's behalf without a tap. Handle missing apps, return navigation, permissions and errors. No FOTO backend changes.

## Implementation sequence and safety

1. Inspect active Codex worktree and previous pending tasks (timeline delete animation, Adaptive Mosaic). Finish them first, never discard uncommitted changes.
2. Audit all actual action surfaces and list what is reusable from `06af1905e`. Establish one reusable visual shell with per-context action configuration.
3. Migrate fullscreen viewer first, then selection/timeline, albums, local folders, trash, other eligible action surfaces. Keep existing state machines and callbacks.
4. Add Lens as a separate verified integration.
5. Screenshot matrix at Samsung ~390×844 dp, light/dark, font scales 1.0, 1.5, 2.0, 2/3/4/5 actions. Test localization, long date, safe areas, video, cloud, local, trash and multi-select.
6. Run Flutter analyze and relevant widget/integration tests. Report physical Samsung as DEVICE_REQUIRED unless actually executed.
7. Commit app code separately. Do not build APK, update versionCode, sign, touch Docker/backend/production, or perform a merge without explicit permission.

## Acceptance criteria

- The *same* slim pill silhouette, width/margins, icons, typography and baseline across eligible FOTO surfaces.
- No wrapped `Отправить` caption at 100% scale.
- Context-specific actions, correct destructive semantics, no feature regression.
- Top viewer pill noticeably slimmer, existing controls retained.
- Light/dark themes and 200% font usable, not merely screenshot-perfect at 100%.
- Google Lens integration works via verified supported path or clearly documented share fallback.
- Screenshots and test results in the implementation commit.
- No APK or production deployment.

Visual sample: [foto-unified-action-bars.svg](./foto-unified-action-bars.svg).
