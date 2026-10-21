# FOTO Build 17 — безопасное локальное объединение редактора на HP

Это передача **исходников проверенной ветки**, не установка в production. Backend/APK и подпись
выполняются позднее, после объединения с остальными компонентами. Ничего ниже не запускает
контейнеры, Codex, миграции, NAS-операции, Memories или удаление фотографий.

Ветка: `codex/foto-build17-editor`. База до WIP: `d7a31f3420b483974a7247613791cdbc395cacd4`.
WIP сохранён: `9c3a3d8fa9fe137e55752b3ca075e0208cb93c5b`.
Нужен **весь** editor branch, включая восстановление Freezed. Не переносить один Stage 2 commit
без Stage 1. Пакет/applicationId, версия 5.7.3+17, ключи и native Android/iOS не менялись.

## Получить код, сохранив незакоммиченную работу HP

Выполнить обычным владельцем dev-репозитория, например `codex-gallery`. Не выполнять из
production checkout. Команды создают отдельный worktree и не переключают исходное рабочее дерево.
`EDITOR_SHA` берётся из опубликованного PR/final report. SHA проверяется на формат и существование;
при несовпадении remote HEAD выполнение останавливается, не подменяет ветку другой версией.

```bash
set -euo pipefail
umask 077
REPO=/mnt/hp-data/codex-work/gallery
EDITOR_SHA=REPLACE_WITH_FULL_PUBLISHED_HEAD
[[ "$EDITOR_SHA" =~ ^[0-9a-f]{40}$ ]]
test "$(git -C "$REPO" remote get-url origin)" = https://github.com/docice545/gallery.git
git -C "$REPO" status --short
git -C "$REPO" fetch origin refs/heads/codex/foto-build17-editor
[[ "$(git -C "$REPO" rev-parse FETCH_HEAD)" == "$EDITOR_SHA" ]]
EDITOR_WT="$(mktemp -d /mnt/hp-data/codex-work/foto-editor-review-XXXXXXXX)"
git -C "$REPO" worktree add --detach "$EDITOR_WT" "$EDITOR_SHA"
printf 'Editor review worktree: %s\nSource: %s\n' "$EDITOR_WT" "$EDITOR_SHA"
```

Если origin настроен через SSH, используйте уже существующий origin после проверки, что он ведёт
в `docice545/gallery`; не переписывать remote, credentials или систему ради команды. Для точного
immutable получения при движении ветки можно fetch указанного полного commit и сверить `FETCH_HEAD`.
Готовый worktree можно проверять отдельно. Не копировать файлы поверх dirty HP checkout.
Не удалять `server/test/mappers.ts`, `.bak`, BUILD11/FOTO логи или untracked файлы.

Локальный CLI затем сохраняет необходимые незакоммиченные HP исправления отдельным проверенным
коммитом (без секретов/артефактов/логов) и объединяет компоненты в **новом dev worktree**, созданном
от фактического локального integration HEAD. Только там:

```bash
git merge --no-ff --no-commit FULL_EDITOR_HEAD
```

При конфликтах сохранить обе стороны и разрешать их в dev worktree, без reset/clean/rebase.
Не выполнять merge в main. Не считать опубликованными или интегрированными отсутствующие в GitHub
HP изменения. Никакого production merge/deploy эти команды не предусматривают.

## Зависимости и проверки после объединения

Flutter 3.47.2 / Dart 3.13.2, Node 24.21.0 / pnpm 11.24.0; versions/locks из репозитория.
Использовать существующие HP SDK/caches; не создавать новый signing key и не устанавливать ML модели.
Сначала проверить наличие штатного сгенерированного `mobile/generated/openapi/api.dart`, Drift/Pigeon
и других Build 17 outputs. Они игнорируются Git, Cloud заглушки вместо них не добавлял.
Если они отсутствуют в новом worktree, выполнить штатный codegen из `mobile/mise.toml` в dev-окружении,
без БД production. Ненужную регенерацию OpenAPI не выполнять: editor API не менялся.

Для уже подготовленного dev-окружения:

```bash
cd "$EDITOR_WT"
EDITOR_STATE="$(mktemp -d /mnt/hp-data/codex-work/foto-editor-checks-XXXXXXXX)"
python3 tools/foto-automation/foto-stage-runner.py --repo "$PWD" --state "$EDITOR_STATE" editor-codegen
python3 tools/foto-automation/foto-stage-runner.py --repo "$PWD" --state "$EDITOR_STATE" editor-localize
python3 tools/foto-automation/foto-stage-runner.py --repo "$PWD" --state "$EDITOR_STATE" flutter-analyze
python3 -m unittest discover -s tools/foto-automation/tests -q
python3 - "$PWD" "$EDITOR_STATE" <<'PY'
import json, subprocess, sys
from pathlib import Path
repo, state = Path(sys.argv[1]), sys.argv[2]
evidence = json.loads((repo / 'FOTO_BUILD17_EDITOR_EVIDENCE.json').read_text())
runner = repo / 'tools/foto-automation/foto-stage-runner.py'
for run in evidence['runs']:
    if run['stage'] not in ('flutter-test', 'unit'):
        continue
    suffix = '_test.dart' if run['stage'] == 'flutter-test' else '.spec.ts'
    targets = [arg for arg in run['argv'] if arg.endswith(suffix)]
    if not targets:
        raise SystemExit('No explicit test targets; preserve logs and stop')
    subprocess.run([sys.executable, str(runner), '--repo', str(repo), '--state', state,
                    run['stage'], *targets], cwd=repo, check=True)
PY
```

Это обычные тесты, не запуск локального Codex или release build. Выполнять последовательно;
runner откажется при занятом общем lock, не ждать бесконечно и не снимать чужой lock.
Не запускать одновременно второй `flutter test`, Vitest, tsc, Gradle или Flutter build.
Если тесты запускаются после локального merge, отчёт должен называть **merged HEAD**.

## Canonical progress/pending/manifest

Cloud **не имеет доступа** к:

- `/mnt/hp-data/codex-work/foto-integration-state/progress.md`;
- `/mnt/hp-data/codex-work/foto-integration-state/pending-tasks.md`;
- `/mnt/hp-data/codex-work/foto-integration.manifest.json` и зеркалу `.../foto-integration-state/manifest.json`.

Их история не заменялась вымышленным manifest. `FOTO_BUILD17_EDITOR_EVIDENCE.json` — отдельный отчёт
Cloud, **не замена HP manifest**. После получения можно append-запись в progress о полученном SHA
и в pending о локальном объединении/устройствах, не выдавая это за HP PASS. После реального merge,
завершения тестов и commit проверять/обновлять существующие manifests штатной crash-safe утилитой:

```bash
CANON=/mnt/hp-data/codex-work/foto-integration.manifest.json
MIRROR=/mnt/hp-data/codex-work/foto-integration-state/manifest.json
python3 tools/foto-automation/foto-manifest.py --check "$CANON" "$MIRROR"
# Только после PASS на точном локальном merged HEAD; каталог содержит реальные receipts:
python3 tools/foto-automation/foto-manifest.py "$CANON" "$MIRROR" \
  "$(git rev-parse HEAD)" "$(git branch --show-current)" "$EDITOR_STATE"
```

При diverged/corrupt manifests остановиться и сохранить файлы/transaction; не создавать пустую историю.
Progress/pending обновить добавлением фактически завершённых локальных этапов и оставшихся gates;
не удалять прежние записи и не переписывать production checkpoints.

## Последующее устройство/хранилище acceptance

Только синтетические фотографии в отдельном non-production окружении:

1. JPEG/PNG и действительно поддерживаемые HEIC/RAW: открыть, поправить все инструменты, crop/rotate,
   вернуться, undo/redo, сохранить копию. Проверить ориентацию и пиксели; оригинал/EXIF/hash неизменны.
2. На S23/iPhone проверить native permissions: deny → понятная ошибка → разрешить → retry;
   cancel до записи; ровно одна новая копия, нет изменённого исходника. Проверить 320 dp, landscape,
   font scale 200%, safe areas/gesture navigation и возврат из background.
3. На Synology test library проверить auth/owner и сохранность original hash/record/album/live links.
   Новая PNG сначала в фототеке телефона; существующий backup загружает её при включённой настройке.
   Проверить upload, thumbnail/preview и отдельность новой записи. Никакого автоматического удаления.
4. AI-ластик: если уже есть безопасный sidecar, original-aligned mask/zoom/pan/cancel, возврат в обычный
   editor сохраняет его документ; explicit save создаёт отдельную still copy. Модели не устанавливать.
5. Motion original pair остаётся неизменной; обычная ручная правка пары не включается. Проверить
   сохранённые upstream Live/Motion функции в общей интеграции, не считать still copy новой Live Photo.

Лишь после объединения/проверок пользователь отдельно разрешает final backend/APK/signing.
Новая APK не собиралась, старые артефакты Build 17 **не содержат** этот редактор. Production rollback
сейчас не требуется: production не менялся. Для отказа от dev-review worktree оставить его для
разбора; исходное рабочее дерево HP и main продолжают работать без переключения/перезаписи.
