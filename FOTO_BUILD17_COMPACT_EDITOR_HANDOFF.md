# Передача компактного редактора FOTO Build 17

Ветка: `codex/foto-build17-editor-compact`. База строго
`ace2eab962524479a61e6891410983a7f41ba0fa` из `codex/foto-build17-unified`.
В `main` ничего не объединено. Локальные данные/checkpoints/manifest HP не читались и не изменялись.

## Сохранённые изменения

1. `ca25d2639cb33f4e40c789568730bae34bc12328` — компактные панели, пять инструментов, адаптивный viewport и Flutter goldens.
2. `21cdd857dc0a1c909344b14c4bb95632c37a28f2` — source-only CI guards этой ветки, без автоматических APK/Docker/signing.
3. `20c71d932b2ed04c2a8b0b15e7eac8c76a253dcc` — причины AI availability, безопасная read-only диагностика 404, десять локализаций.
4. `03a642d6239f0cc8f0455fd96bc732ba43d04552` — Android/iOS drawing history, адаптация crop regression к свёрнутым настройкам.

5. `c5adf6b63caeef3f88967c2fcef4de21e70b5d24` — исправление подтверждённого overflow в коротком landscape-окне и восстановления панелей после клавиатуры.

PR: https://github.com/docice545/gallery/pull/6.

Подробные доказательства и ограничения: [`EDITOR_COMPACT_ACCEPTANCE.md`](EDITOR_COMPACT_ACCEPTANCE.md).
Следующие documentation-only коммиты не меняют проверенную реализацию. Конечный HEAD определяется через `git rev-parse HEAD` и указан в PR.

## Безопасно получить исходники на HP

В существующем checkout можно выполнить только чтение/получение новой remote-ветки:

```bash
git status --short
git fetch origin codex/foto-build17-editor-compact
git log --oneline ace2eab962524479a61e6891410983a7f41ba0fa..origin/codex/foto-build17-editor-compact
git diff --stat ace2eab962524479a61e6891410983a7f41ba0fa..origin/codex/foto-build17-editor-compact
```

Не делать reset/clean/stash или checkout поверх незакоммиченных HP-изменений. Сначала сохранить их в собственной ветке/checkpoint,
затем отдельно локально объединить review-ветку с вашей integration-веткой. Фактический HP HEAD в этой среде недоступен;
автоматическое объединение и команды deployment не подготовлены и не запускались.

Потенциальные конфликты: `edit.page.dart`, `markup_controls.dart`, AI repository/page, editor widget-tests и i18n.
Не возвращать горизонтальную прокрутку основных режимов или безусловное `404 → enabled=false` при разрешении конфликтов.
Новые ключи локализации требуют обновления generated translations; OpenAPI-контракт не изменился.

## Зависимости и последовательные проверки

Flutter 3.47.2 / Dart 3.13.2, зафиксированные `mobile/mise.toml` и `mobile/pubspec.yaml`; Python 3 для существующего runner.
В Cloud использовались уже доступные совместимые ignored OpenAPI/Freezed/Drift/Pigeon outputs, затем frozen `flutter pub get` и реальная генерация локализации.
Generated outputs, caches, ключи и двоичные сборки не добавлены в Git. Чистому checkout нужны существующие штатные codegen prerequisites;
не переносить generated файлы из другой версии. Не запускать `mise` parallel codegen одновременно с tests.

Ниже команды из корня уже подготовленного локального integration checkout, когда другие тяжёлые проверки и локальная Codex automation не выполняются. Состояние именно этой проверки отделено от канонического HP manifest:

```bash
set -euo pipefail
EDITOR_REPO="$PWD"
EDITOR_STATE="$(mktemp -d "${TMPDIR:-/tmp}/foto-editor-review.XXXXXXXX")"
printf 'Review state: %s\n' "$EDITOR_STATE"
python3 tools/foto-automation/foto-stage-runner.py --repo "$EDITOR_REPO" --state "$EDITOR_STATE" editor-localize
mapfile -t editor_tests < <(rg --files mobile/test/pages/edit | sort | sed -n 's#^mobile/\(.*_test\.dart\)$#\1#p')
python3 tools/foto-automation/foto-stage-runner.py --repo "$EDITOR_REPO" --state "$EDITOR_STATE" flutter-test \
  "${editor_tests[@]}" \
  test/repositories/magic_eraser_repository_test.dart \
  test/unit/providers/editor_document_history_test.dart \
  test/unit/providers/editor_provider_test.dart \
  test/unit/utils/editor_test.dart \
  test/utils/annotation_editor_test.dart \
  test/utils/edited_image_exporter_test.dart \
  test/utils/edited_image_loader_test.dart \
  test/utils/editor_formats_test.dart \
  test/presentation/widgets/asset_viewer/editor_entry_test.dart \
  test/unit/domain/models/magic_eraser_test.dart \
  test/unit/presentation/actions/magic_eraser_edit_action_test.dart
python3 tools/foto-automation/foto-stage-runner.py --repo "$EDITOR_REPO" --state "$EDITOR_STATE" \
  --legacy-lock "$EDITOR_STATE/legacy.lock" session env --chdir=mobile flutter analyze --no-pub \
  lib/presentation/pages/edit lib/repositories/magic_eraser.repository.dart \
  test/pages/edit test/repositories/magic_eraser_repository_test.dart
python3 -m unittest discover -s tools/foto-automation/tests -p test_dedup_source_scope.py -v
git diff --check
```

Этот объединённый список содержит 380 актуальных cases; в Cloud они прошли отдельными последовательными наборами,
с пересечениями, описанными в отчёте. Golden-проверки запускать без `--update-goldens`.
Если `rg` отсутствует на HP, вместо mapfile перечислить 12 существующих файлов `mobile/test/pages/edit/*_test.dart`
с префиксом `test/pages/edit/`; runner специально принимает только явные имена файлов.
Review state находится вне checkout и не является production checkpoint. Runner не запускает Codex;
не запускать локальный Codex или systemd automation из этой инструкции.

## Следующий этап и откат исходников

Здесь не собирались APK/IPA/backend, не менялись signature/package IDs, backend, OpenAPI, NAS и пользовательские данные.
После локального объединения повторить перечисленные тесты при наличии конфликтов, затем отдельно согласовать native builds
и проверки Android/iPhone из отчёта. В общем CI есть ShellCheck FAIL в неизменённых release/diagnostic scripts; подробности и границы — в отчёте и PR. Не считать агрегирующие success с пропущенными build jobs готовыми сборками. Реальная AI inference не проверена и требует безопасного non-production сервиса.

Если локальное объединение ещё не завершено и возник конфликт — `git merge --abort` в отдельной integration worktree.
Если оно уже сохранено — вернуть интеграционный merge отдельным `git revert -m 1 <merge-SHA>` после проверки графа.
Исходную HP-ветку и checkpoint сохранять; не применять reset/clean, не откатывать БД или production-образ ради UI-review.
