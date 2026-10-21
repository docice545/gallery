# FOTO Build 17 — результаты проверки редактора

**Назначение: готовность ветки редактора к локальному объединению на HP. Это не production-релиз.**

Задача: https://github.com/docice545/gallery/issues/3, включая уточнение
https://github.com/docice545/gallery/issues/3#issuecomment-6312121710.
Повторная проверка комментариев 21.10.2026: новых уточнений не обнаружено.
Исходный checkpoint: `9c3a3d8fa9fe137e55752b3ca075e0208cb93c5b`.
Исходная база: `d7a31f3420b483974a7247613791cdbc395cacd4`.
Точный проверенный код и хеши файлов: [FOTO_BUILD17_EDITOR_EVIDENCE.json](FOTO_BUILD17_EDITOR_EVIDENCE.json).

## Выполненные проверки

| Проверка                                                                           | Фактический результат                                             |
| ---------------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| Основной набор редактора: 17 файлов                                                | **262 PASS**, 0 FAIL, 0 SKIP                                      |
| После исправления aspect history: crop/provider/UI + API/AI, 10 файлов             | **171 PASS**, 0 FAIL, 0 SKIP                                      |
| Дополнительный object/Unicode raster run                                           | **11 PASS**, 0 FAIL, 0 SKIP; 10 повторены для нового emoji случая |
| Различные Flutter-тесты в этих прогонах                                            | **357 PASS**; 87 повторений, setup/teardown исключены             |
| Backend unit: MagicEraserService, AssetMediaService, editor visibility             | **221 PASS**, 0 FAIL, 0 SKIP                                      |
| Automation/manifest/CI scope, Python unittest                                      | **44 PASS**, 0 FAIL, 0 SKIP                                       |
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
