# FOTO Build 17 — результаты проверки редактора

**Назначение: готовность ветки редактора к локальному объединению на HP. Это не production-релиз.**

Задача: https://github.com/docice545/gallery/issues/3, включая уточнение
https://github.com/docice545/gallery/issues/3#issuecomment-6312121710.
Повторная проверка комментариев 21.10.2026: новых уточнений не обнаружено.
Исходный checkpoint: `9c3a3d8fa9fe137e55752b3ca075e0208cb93c5b`.
Исходная база: `d7a31f3420b483974a7247613791cdbc395cacd4`.
Точный проверенный код и хеши файлов: [FOTO_BUILD17_EDITOR_EVIDENCE.json](FOTO_BUILD17_EDITOR_EVIDENCE.json).

## Финальная приёмка Samsung-style UI

Полная таблица «требование → компонент → подтверждение → статус» и три golden-снимка:
[FOTO_BUILD17_EDITOR_ACCEPTANCE.md](FOTO_BUILD17_EDITOR_ACCEPTANCE.md).
Исправленный код: `906ad0e6822cd2d85393f035b5a7e4d167f30152`.
**READY_FOR_LOCAL_INTEGRATION относится только к редактору**, без заявления о готовности всего Build 17.

Аудит воспроизвёл и исправил пять UI-дефектов: горизонтальное меню на iOS, обрезанную drawing pill
в compact landscape с крупным текстом, обрезанные названия разделов, неточную RU подпись фильтров
и обрезанный «Вернуть» при 200% текста. Добавлены 10 acceptance cases и три собственных golden
на синтетическом изображении; существующие тесты не ослаблены.

- **73 PASS / 0 FAIL / 0 SKIP**: 10 новых UI/golden + 57 прежних editor/AI integration + 6 save/retry.
- После удаления двух неиспользуемых test imports: **10/10 PASS**, обычное сравнение golden,
  без обновления эталонов; **полный Flutter analyze PASS, No issues found**.
- Format, RU JSON Prettier и diff whitespace: **PASS**. Суммарно в scoped Flutter evidence
  **367 различных cases**; повторные 73/10 не прибавляются к прежним 357.
- Backend/API/OpenAPI, native Android/iOS, зависимости и AI runtime не менялись. Прежние
  backend/automation/raster проверки сохранены, не запускались повторно без причины.

Новые реальные receipts, отфильтрованные логи и SHA-256 находятся в
[foto-editor-evidence/acceptance/](foto-editor-evidence/acceptance/) и evidence JSON.
Ниже сохранена история прежних прогонов и CI: полный Mobile CI относится к `bbd8c5a7a`,
**не** к новому UI-коммиту. Общие CI/дубликаты и другие подсистемы этим аудитом не ремонтировались.
Устройства, настоящий Synology и ML inference остаются **NOT TESTED**, как указано в матрице.

## Выполненные проверки

| Проверка                                                                           | Фактический результат                                             |
| ---------------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| Основной набор редактора: 17 файлов                                                | **262 PASS**, 0 FAIL, 0 SKIP                                      |
| После исправления aspect history: crop/provider/UI + API/AI, 10 файлов             | **171 PASS**, 0 FAIL, 0 SKIP                                      |
| Дополнительный object/Unicode raster run                                           | **11 PASS**, 0 FAIL, 0 SKIP; 10 повторены для нового emoji случая |
| Различные Flutter-тесты в этих прогонах                                            | **357 PASS**; 87 повторений, setup/teardown исключены             |
| Backend unit: MagicEraserService, AssetMediaService, editor visibility             | **221 PASS**, 0 FAIL, 0 SKIP                                      |
| Automation/manifest/CI scope, Python unittest                                      | **46 PASS**, 0 FAIL, 0 SKIP                                       |
| GitHub полный Mobile suite на `bbd8c5a7a`                                          | **4985 PASS, 1 SKIP, 0 FAIL**; map-theme flaky suite, не редактор |
| Flutter analyze, всё приложение после исправлений                                  | **PASS — No issues found**                                        |
| Targeted Freezed + локализация штатными генераторами                               | **PASS**                                                          |
| Dart format, Prettier i18n/workflows, Bash syntax, Python compile, diff whitespace | **PASS**                                                          |
| Editor OpenAPI/DTO/server/native/lockfile diff                                     | **Отсутствует**; новая регенерация клиентов и миграция не нужны   |

Сумма 262 + 171 + 11 не является числом уникальных тестов. Setup/teardown hooks также не считаются тестами.
Все тяжёлые процессы выполнялись последовательно через `foto-stage-runner.py`, Flutter concurrency=1,
общий flock, CPU affinity ≤2. Проверки не запускали локальный Codex, systemd HP или production.
Приведённые результаты относятся к коду, а не к новой APK.

В [foto-editor-evidence/](foto-editor-evidence/) сохранены настоящие отфильтрованные строки успешных
прогонов. JSON содержит время, команды, исходный HEAD + digest изменений, SHA-256 исходного лога
и опубликованной версии. HTTP-заголовки/тела, переменные окружения и побочный вывод не публикуются.
После последнего Dart-исправления проверены все затронутые provider/crop/UI сценарии; неизменённые
raster/gesture/export сценарии не запускались повторно без причины.

## Что подтверждено

- Freezed EditorState компилируется. Удалены семь ошибочных дублированных блоков checkpoint,
  повторный enum и вызовы отсутствующего `ColorFilter.compose`.
- Восемь коррекций реально меняют raster. Доступны original + все 32 эффекта; интенсивность,
  настоящие ленивые thumbnails и экспорт используют общий цветовой pipeline.
- Реальные пиксели preview/export совпадают для всех фильтров и ортогональных transform-комбинаций,
  текста с обводкой/фоном и повёрнутых/масштабированных векторных стикеров.
- Шесть разделов в требуемом порядке; верхние Вернуть/Сохранить/⋮; blue pen, purple marker,
  brush, stroke eraser, divider, undo, redo. EN/RU, portrait/landscape, 320 dp, text scale 130–200%.
- Текст: шрифты, цвет, размер, обводка/фон со своими цветами, opacity, редактирование выбранного слоя.
  Собственные vector stickers и emoji без загрузки шрифтов/проприетарных ресурсов.
- Source-relative координаты, crop, rotate, flip, zoom/pan; object move/scale/rotate, отмена и retry.
  Отдельные gestures для объекта и viewport. Ластик штрихов сохраняет текст, стикеры и фотографию.
- Общая история документа ограничена 100 шагами; slider/объект — один шаг; reset обратим.
  Программная синхронизация CropController не создаёт новый пользовательский edit и не стирает redo.
- Четыре дополнительных aspect-теста: square, wide, original, original без EXIF; undo/redo/rotation.
- JPEG/PNG декодированы и экспортированы. Реальный синтетический JPEG Orientation=6 проверен
  по размерам и цветам. Оригинальные байты не менялись. Повторная PNG-декодировка не поворачивает их дважды.
- Сохранение только новой локальной PNG-копии; callback изменения server edits не вызывается.
  Timeout/decode failure/отказ native-save сохраняют документ, освобождают временный файл и допускают retry.
  Отмена source load сразу снимает listener и timer; поздний frame не меняет новый запрос.
- Экспорт ограничен 32 MP; stroke/history ограничены. UI блокирует повторный save во время операции.
- AI-контракты: ownership/доступ, original-aligned mask, cancel, bounded source/result previews,
  explicit copy, ошибки/offline. Backend unit проверяет сохранность синтетического NAS original,
  владельца, private job directories, concurrent-job bounds. Inference в этих unit-тестах mocked.

Ранние FAIL были воспроизведены и исправлены: компиляция checkpoint, переполнения панели,
оставшийся deadline timer при отмене, перекрытие text affordance и неатомарный aspect undo.
Старые ожидания меню/ластика обновлены именно под новые требования владельца; проверки пикселей,
ownership и сохранности оригинала сохранены.

## Не подтверждено в Cloud

| Сценарий                                                               | Статус и граница                                                                                                                             |
| ---------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| Установка/работа на Samsung S23, Android native permissions/MediaStore | **NOT TESTED**, следующий локальный этап после объединения                                                                                   |
| iPhone Photos permissions, HEIC/HEIF аппаратные codecs                 | **NOT TESTED**; нет физического устройства/macOS                                                                                             |
| NEF/RAW декодирование мобильным codec                                  | **NOT TESTED**; fixture `glarus.nef` доступен (9 057 784 байта), это не доказательство mobile decode                                         |
| Реальный Synology NFS, HP upload/backup                                | **NOT TESTED**; оригиналы NAS не читались/не менялись                                                                                        |
| Новый реальный Big-LaMa E2E                                            | **NOT RUN**; отдельный sidecar для этой задачи не поднимался, модели не устанавливались                                                      |
| Android mobile browser                                                 | Flutter mobile стек использует dart:io/PhotoManager и **не предоставляет web-экспорт**; существующий Svelte web editor не менялся            |
| Live/Motion                                                            | Сохранена существующая AI still-copy поддержка; ручная crop/markup замена motion-пары отключена. Экспорт новой движущейся пары не добавлялся |
| Полный EXIF перенос в новую PNG                                        | **Не реализован**: ориентация запечена в raster; остальные EXIF не копируются. EXIF оригинала не меняется                                    |
| APK/backend build/signature, production, общая интеграция Build 17     | **NOT RUN**, прямо исключены из Issue 3                                                                                                      |

Неподдерживаемый исходный codec не заменяется молча preview пониженного качества: сохранение выдаёт
ошибку и оставляет edits для повторной попытки. Отмена действует до записи в системную фототеку;
начатую native persistence операцию UI не обещает отменить. Новая копия загружается на сервер лишь
обычным backup, если он включён. Успешный mock native-save не объявляется физическим Android-тестом.

## Воспроизведение

Версии: Flutter 3.47.2 / Dart 3.13.2, Node 24.21.0 / pnpm 11.24.0, Vitest 4.1.11.
Существующие locks сохранены. Нужны уже сгенерированные штатные SDK/Drift/Pigeon зависимости Build 17.
В Cloud они имелись; генератор не заменялся заглушкой. Запускайте через существующий runner с приватным
state-каталогом. Точные test targets сохранены в `runs[].argv` JSON; запускать их по одному stage,
не использовать все этапы одновременно.

```bash
python3 tools/foto-automation/foto-stage-runner.py --repo "$PWD" --state "$EDITOR_STATE" editor-codegen
python3 tools/foto-automation/foto-stage-runner.py --repo "$PWD" --state "$EDITOR_STATE" editor-localize
python3 tools/foto-automation/foto-stage-runner.py --repo "$PWD" --state "$EDITOR_STATE" flutter-analyze
python3 -m unittest discover -s tools/foto-automation/tests -q
```

Для каждого test run из JSON используйте `flutter-test` или `unit` и перечисленные после служебных
флагов файлы. Не запускать android-apk/backend-build stage. Последующая локальная интеграция и
устройства требуют собственных результатов, а не переноса Cloud PASS в HP manifest.

## GitHub PR CI — отдельная граница от editor suites

PR: https://github.com/docice545/gallery/pull/4, base `codex/foto-build17-web-handoff`.
Коммит `bbd8c5a7a` добавляет проверенные source-only guards для обоих Docker E2E и сохраняет
обычные path filters. Только PR этой ветки не force-запускает несвязанные Docker/ML suites при
изменении test workflow. Для других PR/push/dispatch штатное поведение сохранено; проверено
по фактическим выражениям GitHub Actions. **46/46** automation tests PASS после изменения.
Метка `changelog:enhancement` добавлена штатно; PR Label Validation PASS.

Первый общий Test run был отменён до Docker build Web E2E: GitHub вернул для этого шага
`conclusion=skipped`. После исправления guard в run
[39587545769](https://github.com/docice545/gallery/actions/runs/39587545769) оба Docker E2E,
Medium Server и ML tests пропущены. В mobile/Docker release workflows build/sign/publish/retag
jobs также SKIPPED. Это ограничение текущего editor review, не доказательство готовности релиза.

В общем CI две ошибки доказанно воспроизводятся на исходной базе. Они **не выдаются за PASS**
и по требованиям Issue 3 не расширяют редакторную задачу до общего ремонта Build 17:

- ShellCheck: SC2154 в `hp_build10_image_update.sh:29` и `hp_build10_rollback.sh:23`, SC2174 в
  `server_build.sh:111`, пять SC2016 в `hp_vaapi_audit.sh:47,61,73,110,149`, SC2155 в
  `gallery-nas-recovery-565ef38.sh:6`. Все пять файлов побайтно идентичны `d7a31f342…`.
  ShellCheck **0.11.0**, как в CI, выполнен для исходных Git blobs и текущих файлов: диагностики и
  exit codes совпадают. Новый `foto-editor-localize.sh` проходит этот же checker (exit 0).
- Upstream Rebase Tooling: `src/audits/rebase-confidence.spec.ts > validateGalleryWorkflowText >
passes the current Gallery release workflow static assertions`: `expected false to be true`.
  Фактический аудитор сообщает `gallery-build-mobile.yml must apply branding before flutter build`:
  прежний Android media pilot build стоит раньше первого apply-branding в другом job. Тот же
  неизменённый аудитор запущен с текущими workflow и с workflow из Git base `d7a31f342…`; результат
  **одинаковый FAIL**. Guard редактора не меняет порядок pilot build/branding.
- OpenAPI Clients **FAIL**: генерация меняет `open-api/immich-openapi-specs.json` и
  `packages/sdk/src/fetch-client.ts` относительно сохранённого контракта.
- SQL Schema Checks **FAIL**: генерация создаёт `server/src/1792579982516-TestMigration.ts`.
- Lint Web **FAIL**: `web/src/lib/services/trash-authorization.spec.ts:25,33,39`,
  `@typescript-eslint/require-await` (async mock без await).
- Test Web **FAIL**: 6468 тестов прошли, 2 skipped, 4 todo, но есть unhandled
  `ReferenceError: Element is not defined` из delayed bits-ui dismissible-layer callback,
  `src/lib/components/spaces/space-people-page.spec.ts`. Число пройденных cases не превращает job в PASS.

Server/schema/OpenAPI/SDK/Web/native/locks не менялись editor branch; два Web test files побайтно
идентичны базе (hashes в JSON). Для последних четырёх gates **полный baseline run не выполнялся**;
сходство файлов не выдаётся за успешно выполненный тест. Это конкретные оставшиеся задачи
единой локальной интеграции Build 17, прямо исключённой из Issue 3. Автоматический drift не
коммитился и защита контрактов/миграций не отключалась.

Полный GitHub **Unit Test Mobile — PASS: 4985 passed, 1 skipped, 0 failed** на `bbd8c5a7a`:
[run 39587545769](https://github.com/docice545/gallery/actions/runs/39587545769/job/119180190032).
Skip — существующая `map_theme_override_test.dart` (сообщение `Flaky test, needs investigation`),
файл не менялся. Этот общий suite включает ранее посчитанные editor cases и не складывается с 357.
Dart Code Analysis на том же checkpoint **PASS**:
[run 39587545698](https://github.com/docice545/gallery/actions/runs/39587545698).
Отфильтрованные реальные строки CI: [mobile](foto-editor-evidence/github-mobile-ci.txt),
[global failures](foto-editor-evidence/github-global-ci.txt); hashes полных исходных логов — в evidence.
Итог общего Test workflow **FAIL**, редакторные проверки не скрывают этого результата.

Сравнение с SHA-256 файлов и реальными диагностиками:
[ci-baseline.json](foto-editor-evidence/ci-baseline.json). Никакие production scripts не выполнялись.
Ремонт release scripts/общих схем и HP unified integration остаётся отдельным локальным этапом;
новые ошибки собственно редактора не скрываются baseline-исключением.
