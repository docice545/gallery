# Trash / Restore: фактическая проверка review-патча

Дата: 2026-10-09. Исходный review SHA:
`1d773fd6fad785414b3f7bdc1f7484a1b5bf4e7d`.
Production `work`: `42790b06edc21438811e56e40c431eee37c24894`.
Патч находится только в `audit/gallery-cmp-trash-vaapi-20261009`.
Production, NAS, signing и paused workstreams не использовались.

## Среда и границы доказательств

- Linux cloud workspace, Flutter **3.47.2**, Dart **3.13.2**, Node **24.21.0**.
- PostgreSQL **14** запускается существующим Testcontainers medium harness,
  pinned image `ghcr.io/immich-app/postgres:14-vectorchord0.4.3`. Полный image
  digest закреплён в `server/test/medium/globalSetup.ts`.
- Harness создаёт новую template DB, выполняет upstream/fork migrations и
  использует независимые test DB clones. Подключения только к cloud Docker;
  ни production URL, ни HP/Redis/NAS credentials не использовались.
- Четыре interleaving-теста используют независимые транзакции и observer
  connection. Второй запрос реально ожидает row lock; перед release проверяется
  `pg_stat_activity.wait_event_type = 'Lock'`. Это не mock и не два последовательных
  вызова, названных concurrency test.
- File lifecycle использует `mkdtemp` и синтетические bytes внутри одной
  test-owned папки. Real FileDelete handler вызывает настоящий unlink только
  для этих путей; исходные bytes и независимый bystander сравниваются.
- Для существующих RAW fixtures был загружен один публичный `glarus.nef`
  из `immich-app/test-assets` commit `ec56cc6c1d76c45bc9615dc6ea232470a2b0a3a1`.
  Файл находится в ignored `e2e/test-assets`; он не пользовательский и не входит
  в патч. Без него соответствующие исходные medium tests дают ENOENT.
- Mobile persistence/restart проверяется Drift/SQLite fixtures, в том числе
  существующими file-backed reopen tests. Ни MediaStore, ни PhotoKit, ни реальные
  кодеки Live Photo на телефоне этим не проверяются.

## Результаты

| Проверка | Результат |
| --- | --- |
| Полный Flutter suite после folder/Viewer fix | **4564 PASS, 1 SKIP**, 0 FAIL; 367 секунд |
| Folder + cached search + filter/grouping focused tests | **21 PASS**, 0 FAIL |
| Полный Flutter analyze, `--fatal-infos` | **PASS: No issues found**, 5.3 секунды |
| Format всех tracked Dart в `mobile/lib` и `mobile/test` | **PASS: 1255 files, 0 changed** |
| Все tracked mobile Dart files | **FAIL: 6 pre-existing** unformatted files вне app/test scope, перечислены ниже |
| PostgreSQL medium regression, 21 test files | **627 PASS, 12 SKIP**, 639 total; 21 files PASS |
| Новый PG lifecycle suite | **17 PASS**; включён в результат 627 |
| Focused backend unit, 6 files | **512 PASS**, 0 FAIL |
| Полный backend unit suite | **6601 PASS, 2 FAIL, 1 expected fail, 12 SKIP**; 6616 total, 208 files |
| Повтор двух failed backend files на исходном `1d773fd6fa` | Те же **2 FAIL**, 33 PASS; подтверждён baseline |
| `tsc --noEmit` | **PASS** |
| ESLint изменённых 13 TypeScript files, `--max-warnings 0` | **PASS** |
| Prettier тех же TypeScript files | **PASS** |
| `nest build`, `tsc-alias`, `bin/sync-gallery-migrations.mjs` | **PASS**; только local ignored build outputs |
| `git diff --check` | **PASS** |
| Android/iOS native build, physical S23/iPhone | **NOT RUN** в этой задаче |
| HP deployment, queue audit, rollback на HP | **NOT RUN**; план требует approval и HP validation |

Полный backend suite не зелёный. Failures не отключались:

1. `server/src/schema/revert-to-immich.spec.ts:61`: существующий switch-back script
   не перечисляет `1791070000000-AddStackSuppression`,
   `1791071000000-AddMemoryCandidates`, `1793400000000-FixMemoryCandidateSchema`.
   Наш server-image rollback не использует этот script и не возвращает production
   schema к upstream Immich.
2. `server/src/utils/shared-space-album-scope.guard.spec.ts:462`: guard считает
   import `spaceAlbumAssetExists` в `memory.repository.ts:22` read arm без gate.
   Это результат guard test, а не доказательство доступа к private assets.
   Memories code не изменялся; ошибка воспроизводится на точном baseline.

Шесть pre-existing format failures также воспроизведены на baseline:
`mobile/packages/ui/lib/src/previews/{close_button,formatted_text,icon_button,password_input}.dart`,
`mobile/packages/ui/test/formatted_text_test.dart`, `mobile/pigeon/network_api.dart`.
Ни один из них не изменён этим патчем. Checks не ослаблены.

Во время полного Flutter suite существующий native finalizer выводит
`Callbacks into Dart VM are currently prohibited` при teardown отдельных test
isolates. Финальный suite завершился успешно; это сообщение не скрывается
и не является physical/native acceptance.

## Проверенное поведение

| Сценарий | Доказательство |
| --- | --- |
| Single/bulk photo и video Trash → Restore | Real PG services/queries и полный Flutter suite; actual restored IDs/count |
| Restore выигрывает у старого retention job | PG row lock; cutoff UPDATE после ожидания возвращает false |
| Retention выигрывает у Restore | PG row lock; Deleted не возвращается в Active и не подтверждается как restored |
| Restore → новое Trash / новый retention период | PG и Drift revisions; старый cutoff/Restore ack не побеждает новую операцию |
| Повторный Trash после irreversible claim | PG row lock; не открывает Deleted row для Restore |
| Legacy job без cutoff после Restore | Skip; DB row, original bytes, album/pair сохраняются |
| Library removal versus retention/legacy job | Удаляется индекс/generated thumbnail; synthetic original сохраняется |
| Два concurrent delete workers | Оба читают один snapshot; только DELETE RETURNING winner отправляет FileDelete/event |
| Live Photo / Motion Photo | Synthetic still+hidden motion сохраняются при Trash/Restore; permanent delete удаляет unused pair, не bystander |
| Shared motion / orphan scope | Linked companion/still не подходит для orphan cleanup claim |
| Chronology/timezone/album | Capture date, localDateTime, timezone, membership и pair ID не меняются; порядок восстановлен, повторный Restore count=0 |
| Offline/reconnect/restart | Existing Dart operation/reconciliation tests, SQLite reopen; real offline NAS cleanup fixture сохраняет original |
| Cached Photos search + late response | Durable marker projection; fail closed до первого marker snapshot |
| Folder list + opened Viewer | Existing `fromAssetStream`; bulk Trash/Restore/re-Trash, late HTTP, permanent delete marker removal, disposal и fetch revision |
| Main Timeline / pagination / selection | Полный Flutter suite и PG timeline/sync/album suites; native gestures отдельно не проверены |

## Изменённые файлы

Server implementation:
`src/repositories/asset.repository.ts`, `src/services/{asset,library,metadata}.service.ts`,
`src/types.ts`.

Server tests/fixtures:
`src/services/{asset,metadata}.service.spec.ts`, `test/medium.factory.ts`,
`test/repositories/asset.repository.mock.ts`,
`test/medium/specs/services/{asset,library,timeline}.service.spec.ts`,
`test/medium/specs/services/trash-retention-lifecycle.spec.ts`.
Эти пути относительны `server/`.

Mobile:
`lib/providers/folder.provider.dart`, `lib/pages/library/folder/folder.page.dart`,
`test/providers/folder_provider_test.dart`,
`test/presentation/pages/dev/timeline_filter_grouping_integration_test.dart`.
Пути относительны `mobile/`.

Документы:
`specs/2026-10-09-trash-release-safety-design.md`, этот validation record и
только Trash-раздел `specs/2026-10-09-cmp-trash-vaapi-design.md`.

## Воспроизводимые команды

Из `mobile/`, после обычного pinned dependency resolution/codegen проекта:

```bash
flutter --version
flutter test --no-pub
flutter analyze --no-pub --fatal-infos
git ls-files -z -- ':(glob)lib/**/*.dart' ':(glob)test/**/*.dart' \
  | xargs -0 dart format --output=none --set-exit-if-changed
flutter test --no-pub test/providers/folder_provider_test.dart \
  test/providers/photos_filter/photos_filter_search_provider_test.dart \
  test/presentation/pages/dev/timeline_filter_grouping_integration_test.dart
```

Из `server/`, с установленными lockfile dependencies:

```bash
node_modules/.bin/vitest run --config test/vitest.config.mjs --maxWorkers=4
node_modules/.bin/tsc --noEmit
node_modules/.bin/nest build
node_modules/.bin/tsc-alias
node bin/sync-gallery-migrations.mjs
```

PostgreSQL запускать **только в отдельной cloud/staging test environment**, не
на production HP; требуется локальный Docker/Testcontainers:

```bash
node_modules/.bin/vitest run --config test/vitest.config.medium.mjs \
  test/medium/specs/services/trash-retention-lifecycle.spec.ts \
  test/medium/specs/services/trash-timeline.service.spec.ts \
  test/medium/specs/services/asset.service.spec.ts \
  test/medium/specs/services/library.service.spec.ts \
  test/medium/specs/services/album.service.spec.ts \
  test/medium/specs/services/search.service.spec.ts \
  test/medium/specs/services/timeline.service.spec.ts \
  test/medium/specs/services/asset-shared-space-permissions.service.spec.ts \
  test/medium/specs/services/sync.service.spec.ts \
  test/medium/specs/repositories/asset.repository.spec.ts \
  test/medium/specs/repositories/asset-job.repository.spec.ts \
  test/medium/specs/repositories/album.repository.spec.ts \
  test/medium/specs/repositories/search.repository.spec.ts \
  test/medium/specs/utils/search-space-trash-gate.medium.spec.ts \
  test/medium/specs/sync/sync-shared-space-album-trash-lifecycle.spec.ts \
  test/medium/specs/sync/sync-library-asset.spec.ts \
  test/medium/specs/sync/sync-album.spec.ts \
  test/medium/specs/sync/album-space-asset-convergence.spec.ts \
  test/medium/specs/repositories/hidden-album-timeline.medium.spec.ts \
  test/medium/specs/repositories/timeline-bucket-explicit-visibility.medium.spec.ts \
  test/medium/specs/services/timeline-album-contributions.medium.spec.ts
```

## Acceptance перед разрешением production

1. Сначала staging/disposable owner и файлы, отдельный тестовый альбом, известные
   capture dates/timezones. Никаких family originals для permanent/expiry tests.
2. S23: single/bulk photo/video, Live/Motion; Timeline, album, search и folder
   list/Viewer. Trash должен сразу скрывать asset; Restore — возвращать на
   исходную дату, с теми же альбомами и без duplicates.
3. Offline, network timeout, definite rejection, reconnect, cold restart,
   delayed sync, Restore → Trash снова; проверить local-only и backed-up twins
   отдельно. Не принимать отсутствие в Фото за физическое удаление с телефона.
4. Исходные disposable NAS bytes не меняются при soft Trash/Restore. Explicit
   permanent/expiry на writable external library **может unlink оригинал**.
   Read-only mount не возвращает удалённую DB metadata.
5. На HP проверить реальный Trash enabled/days, mount flags, всех consumers,
   private legacy AssetDelete/FileDelete export и текущие file references,
   NAS snapshot и PostgreSQL backup. До проверки FileDelete queue не возобновлять.
6. iPhone local-only deletion/Recently Deleted и native Live pair требуют
   отдельной физической проверки, если планируется iOS release.

**Verdict: NOT READY для production.** Repository-side race fixes и целевые
автоматические проверки не заменяют очередь/backup/physical gates. Полный backend
suite и full tracked-Dart formatting имеют перечисленные исходные failures.
Минимальный reversible deployment/rollback и точечная стратегия legacy jobs:
[`2026-10-09-trash-release-safety-design.md`](../2026-10-09-trash-release-safety-design.md).
