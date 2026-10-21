# FOTO Build 17 editor — checkpoint 2026-10-21

**Текущее состояние: редактор подготовлен к локальному объединению; production не изменялся.**
Проверенный editor runtime checkpoint: `9fab4c70f`; CI source-only guard: `bbd8c5a7a`.
Полные SHA, реальные receipts и hashes сохранены в evidence JSON.
Итог: **357 различных Flutter + 221 backend unit + 46 automation PASS**, 0 FAIL/SKIP в этих scoped suites. Общий CI имеет отдельно подтверждённые baseline FAIL (см. отчёт).

- [Отчёт и границы проверки](FOTO_BUILD17_EDITOR_TEST_REPORT.md).
- [Команды безопасного переноса/объединения на HP](FOTO_BUILD17_EDITOR_HP_HANDOFF.md).
- [Машиночитаемые receipts/hashes](FOTO_BUILD17_EDITOR_EVIDENCE.json).
- [Устройство редактора и API-границы](specs/2026-10-21-foto-editor-design.md).

Ниже сохранена история этапов; прежние pending-пункты закрыты последующими записями.
Canonical progress/pending/manifest HP отсутствовали в Cloud и не заменялись фиктивными файлами.
Актуальные **pending**: локальное объединение с непубликованными правками HP, повторные проверки
merged HEAD и устройства/реальные codecs/Synology, затем отдельное разрешение на final build/signing.
APK/backend не собирались, подпись не выполнялась, PR нельзя сливать в main.

Branch: `codex/foto-build17-editor`. Start: `9c3a3d8fa9fe137e55752b3ca075e0208cb93c5b`.
Issue: https://github.com/docice545/gallery/issues/3 including owner layout clarification.

## Stage 1 recovered

- Restored targeted Freezed generation, removed seven invalid orphan filter bodies and duplicate
  EditorMode declaration from the supplied checkpoint. Flutter now compiles/analyzes cleanly.
- Original + all 32 effects are selectable; filter thumbnails show the actual source image.
- Eight corrections and filter intensity share one affine color matrix between preview and export;
  removed calls to nonexistent `ColorFilter.compose` and fixed shadows icon.
- Existing crop/rotate/flip, PNG copy saving, load timeout and save retry remain intact.
- Added serialized `editor-codegen` / `editor-localize` stages to the existing flock runner.
  Generated files remain ignored per repository convention. No APK/backend build was started.

## Evidence from this Cloud session

Runner state/logs: `/tmp/foto-build17-cloud-state/stages` (ephemeral, not HP state).

- Targeted Freezed generation and localization generation: PASS.
- Full Flutter analyze: PASS, no issues (receipt `ecf36b3d68ca2ae8…`).
- Provider: 11 PASS after fixing missing checkpoint test imports (receipt `96ab840e…`).
- Pixel pipeline: 41 PASS, including each correction and preview/export parity for every effect
  at partial intensity (receipt `9f35efa5…`).
- Existing correction/export/save-retry suite: 55 passed; that run also failed to load the provider
  test, subsequently corrected and rerun separately as above (`cb2ba592…`).
- Existing editor utility crop/transform tests: 24 PASS in the initial compile-debugging run.
- No physical Android/iOS, real HEIC/RAW, Synology, AI-sidecar or production tests performed.

## Remaining work

Stage 2 layout, shared document undo/redo, text styling, stickers, object gestures/layers;
editor integration/regression tests, multilingual strings, compatibility/copy safety report;
final handoff and unmerged PR. This checkpoint is NOT completion of Issue 3.

## Environment / repeatable commands

Pinned existing Flutter 3.47.2 / Dart 3.13.2, Node 24.21.0 / pnpm 11.24.0.
Use the repository's existing dependency locks; no API schema change or client regeneration needed.
On Cloud, environment setup is `/tmp/foto-editor-env.sh` (contains only paths/environment switches).

```bash
python3 tools/foto-automation/foto-stage-runner.py --repo "$PWD" --state "$SAFE_STATE" editor-codegen
python3 tools/foto-automation/foto-stage-runner.py --repo "$PWD" --state "$SAFE_STATE" editor-localize
python3 tools/foto-automation/foto-stage-runner.py --repo "$PWD" --state "$SAFE_STATE" flutter-analyze
python3 tools/foto-automation/foto-stage-runner.py --repo "$PWD" --state "$SAFE_STATE" flutter-test test/pages/edit/editor_color_pipeline_test.dart
```

HP's canonical progress/pending files and both manifests are not mounted in Cloud. Their contents
and any unpublished HP changes have not been fabricated, overwritten or incorporated. Keep them
and append only results actually obtained after local integration. Existing unsigned APK on the
prior handoff branch does NOT contain this editor. User forbids final builds/signing at this stage.

## Stage 2 checkpoint

- One bounded 100-step document undo/redo history across crop/rotation/flips, corrections,
  effects, text, stickers and drawn layers. Slider gestures coalesce; reset is undoable.
- Six-section dark rail; top Revert / Save / vertical menu. Drawing pill order and blue/purple
  pens follow the owner clarification. Text has fonts, size, color, outline, background,
  opacity. Built-in vector stickers plus emoji use no proprietary artwork/downloaded fonts.
- Normalized source coordinates, pixel-space object rotation/scaling, two-finger object gestures
  distinct from viewport navigation, layer selection/reordering/deletion. Stroke eraser leaves
  captions/stickers and the source raster untouched. Long strokes and history have bounds.
- Cropped preview outside the crop tool now matches the exported crop. Saving is device-copy
  only, with an honest backup explanation. Added immediate source-load cancellation, deadline
  cleanup, 32 MP export guard, explicit errors, permission-failure retry and temporary cleanup.
- Added English/Russian plus the nine required companion locales. Two tiny JPEG/PNG fixtures
  are synthetic, generated using Pillow 12.3.0. JPEG EXIF orientation is baked into output;
  original bytes/metadata remain intact. Other EXIF is not carried into the new PNG.

Validation at this checkpoint, all serialized:

- **262/262 editor Flutter tests PASS**, log `e44dbe34…-2efe5f38…` (17 explicit test files).
- Full Flutter analyze: **PASS / no issues**, log `2faaf686…-a19bc85d…`.
- Existing automation safety/manifest tests: **37/37 PASS**.
- Pixel tests include styled text and transformed vector stickers, 32 filter intensities,
  all source rotations/flips, originals unchanged. Gestures include cancellation and retry.
- Early runs exposed and corrected layout overflow, a leftover cancellation deadline timer,
  the old duplicate filter/compile errors and an overlapping text-edit affordance. Final
  checkpoint has no failures. The changed old eraser-text assertion follows the user's
  explicit new requirement: erase drawn lines only; the old seven-section navigation tests
  now exercise the requested six sections. Pixel/ownership assertions were retained.

Still pending: scoped API/AI contract regression run; explicit aspect-preset gesture/history
integration coverage; final review, editor documentation and PR. No final builds/signing.

## Stage 3 crop/API verification

A new real widget test reproduced an additional defect: changing an aspect preset caused
CropController's intermediate notifications to enter document history; undo could not return
to the baseline. Programmatic controller replay is now guarded, final ratio correction is
stored in the same preset transaction, and Original ratio falls back to decoded dimensions
when EXIF is absent. Four new square/wide/original/no-EXIF tests include undo/redo and rotation.

- **171/171 PASS** in the post-fix crop/provider/editor/API/AI Flutter run (`c6201faa…`).
  This overlaps 77 cases with the earlier 262-pass run: **356 distinct Flutter cases**, not 433.
  Setup/teardown hooks are excluded from that total. Zero remaining failures or skipped cases.
- **221/221 PASS** backend unit contracts (`9b118c19…`, MagicEraserService, AssetMediaService,
  editor visibility utilities). Inference is mocked; synthetic temporary filesystem only.
- Full Flutter analyze after the fix: **PASS**, no issues (`da5aa3b7…`).
- OpenAPI, backend runtime, native Android/iOS code, dependency locks and deletion policies
  have no editor-task diff. No schema/client regeneration or migration was necessary.

Real HEIC/RAW device decoding, native photo permissions, real Synology and actual ML inference
remain local acceptance checks; they are not claimed by these Flutter/HTTP/unit tests.

## Final scope / publication

- Stage 1 and Stage 2 code preserved in `89b619d0e` and `91cb5ca55`.
- Aspect replay fix: `d2243baee`; tested real controller + all post-fix editor/API contracts.
- CI source-only guards: `9fab4c70f`, 44 automation tests. Both mobile build/sign workflows
  skip this editor PR; Docker build/publish/retag graph also skips it. Normal test workflows
  remain available; other branches and explicitly invoked release workflows keep their behavior.
- Additional Unicode raster case: 11 object tests PASS (`c62587f9…`), including actual preview/export
  for an emoji. Glyph appearance on physical Android/iOS still depends on system fonts.
- Publish complete branch, create an unmerged PR against `codex/foto-build17-web-handoff`.
  Never apply rc/rc-ml labels or dispatch backend/APK build workflows for this task.
- No backend/native/schema/lock changes, models installed, production media/DB/queues accessed,
  or HP automation launched. Safe local merge and canonical-state update are documented separately.

## PR / CI follow-up

PR #4: https://github.com/docice545/gallery/pull/4 — OPEN, не merged; base
`codex/foto-build17-web-handoff` (`d7a31f3420b483974a7247613791cdbc395cacd4`).
`cd4907fd2` сохранил отчёты/Unicode raster regression. `bbd8c5a7a` ограничил общий Docker E2E для
source-only editor review; новый run реально показывает SKIPPED для обоих E2E/ML/Medium jobs.
Automation: **46/46 PASS** (7 прежних scope cases + 2 новых, 37 manifest/runner cases).

Dart Code Analysis в GitHub прошёл на `cd4907fd2`; Branding, i18n, .github formatting, migration ORDER,
Zizmor и conventional PR title тоже PASS. Changelog label исправлена и проверка PASS.
ShellCheck и upstream assertion FAIL подтверждены на неизменённой базе тем же checker/auditor:
[точные причины и SHA-256](foto-editor-evidence/ci-baseline.json). Эти unrelated baseline gates
не исправлялись изменениями production/release scripts в рамках editor issue. Общий workflow
не объявляется зелёным. Подробности и ограничения: `FOTO_BUILD17_EDITOR_TEST_REPORT.md`.

Cloud не имеет HP canonical progress/pending/manifest; их данные не выдуманы. Дальнейший оператор
должен сохранить имеющуюся историю и внести только реальные результаты локального объединения.
Не запускать final backend/APK/signing на основании одних Cloud unit PASS.

## Завершённый CI checkpoint `bbd8c5a7ae20b9e43b90ab506dbbb32200c3f7d4`

Полный Mobile CI завершён: **4985 PASS / 1 SKIP / 0 FAIL**. Skip — неизменённый flaky map-theme
suite. Полный Dart analysis повторно **PASS**. Это дополнительные проверки совместимости;
4985 уже включает editor cases, складывать их с 357 нельзя. Реальные отфильтрованные логи и SHA-256
сохранены в `foto-editor-evidence/` и `FOTO_BUILD17_EDITOR_EVIDENCE.json`.

Глобальный Test workflow **FAIL**, 6 checks: ShellCheck, Upstream Rebase Tooling, OpenAPI Clients,
SQL Schema Checks, Lint Web, Test Web. Первые два одинаково FAIL при исполнении на исходной базе.
Для остальных четырёх зафиксированы точные ошибки в отчёте; полный baseline run для них НЕ выполнялся.
Web/backend/schema/SDK/locks editor branch не меняет. По Issue 3 их ремонт относится к следующему
локальному unified integration, не к повторному переписыванию редактора. Эти gates не объявлены PASS.

Дальнейший commit содержит handoff/evidence only; runtime hashes остаются проверенными. Не повторять
357/221 tests без изменения runtime или локального объединения. Автоматический docs-head CI может
появиться снова; его статус можно читать в PR #4, не запускать release/RC/build/sign jobs.
Следующий шаг HP: получить точный опубликованный HEAD из PR, отдельный worktree и инструкции
`FOTO_BUILD17_EDITOR_HP_HANDOFF.md`; сохранить свои незакоммиченные файлы и canonical history.
