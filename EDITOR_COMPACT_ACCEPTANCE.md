# FOTO Build 17 — компактный редактор Android/iOS

Дата проверки: 21.10.2026. База: `codex/foto-build17-unified`,
`ace2eab962524479a61e6891410983a7f41ba0fa`.
Ветка: `codex/foto-build17-editor-compact`.
Проверенный код и тесты сохранены в `c5adf6b63caeef3f88967c2fcef4de21e70b5d24`.

Результат: **PASS для перечисленных Flutter-проверок; готово к рассмотрению и локальному объединению**.
Это не допуск APK/IPA или всего FOTO к production. Нативные устройства и AI E2E остаются NOT VERIFIED.
Этот отчёт уточняет прежний `EDITOR_ACCEPTANCE.md`: теперь пять постоянно видимых основных разделов,
а AI-ластик находится в меню ⋮. Backend, API-контракт, native iOS/Android, подпись и originals не изменялись.

## Исправления

- Первоначально настройки свёрнуты: фото получает оставшуюся область после верхней панели и компактных инструментов.
- Сверху: назад, undo/redo, сохранение и ⋮. Сброс правок и слои доступны через ⋮.
- Снизу всегда доступны обрезка, фильтры/коррекция, рисование, текст и стикеры. Горизонтальной прокрутки основных разделов нет.
  При недостатке ширины или крупном шрифте остаются иконки с полными tooltip/semantic labels.
- В рисовании постоянно видны перо, маркер, кисть и ластик штрихов. Цвет, толщина, прозрачность и геометрия раскрываются кнопкой настроек.
- В landscape используется боковая панель; в portrait — нижняя. Settings ограничены по высоте и прокручиваются отдельно.
  Crop controller и документ сохраняются при перестройке. Появление клавиатуры не переключает ориентацию по высоте оставшегося body.
- AI: disabled capability/503 означает недоступный AI-сервис; 400 — неподходящую фотографию; 401/403 сохраняют свою причину.
  Для 404 проверяются обычные авторизованные метаданные asset и текущего пользователя: чужое фото не объявляется «старым сервером».
  Неисправный/несовпадающий ответ и транспортные ошибки дают ошибку проверки с повтором. Проверка не скачивает original и не создаёт AI-job.
  Одинаковые причины показаны на входе в редактор и непосредственно на AI-странице. Добавлены переводы en/de/fr/it/nl/pl/es/ru/zh_Hans/zh_Hant.

## Матрица приёмки

| Требование                                                         | Реальный компонент                                           | Подтверждение                                                                                                         | Статус                                |
| ------------------------------------------------------------------ | ------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------- | ------------------------------------- |
| Большое фото без искажения/обрезки                                 | `edit.page.dart`, `_EditorPreview`, `EditorViewport`         | Размер viewport и BoxFit, golden, crop/export/EXIF tests; portrait-панель изначально ≤104 logical px при 393×852      | PASS — Flutter                        |
| Верхние действия и пять доступных разделов                         | `_EditorBottomPanel`, `EditorModeBar`                        | Hit-testing всех пяти кнопок без ensureVisible на 320×720, 393×852, 852×393 для Android и iOS                         | PASS — Flutter                        |
| Компактное рисование и сворачивание настроек                       | `MarkupControls`                                             | Проверка четырёх инструментов, переключения настроек, истории; отрисованный штрих в golden                            | PASS — Flutter                        |
| Safe-area, клавиатура, поворот                                     | `EditImagePage`                                              | Cutouts, landscape/portrait, text scale 2, keyboard insets; сохранение CropController и документа на обеих платформах | PASS — Flutter                        |
| Точные координаты и история                                        | `AnnotationCanvas`, `EditorViewport`, `editor.provider.dart` | Реальные Flutter gestures, zoom/pan/rotate/reflection/crop, нормализованные точки, resize, undo/redo                  | PASS — Flutter                        |
| 8 коррекций и 32 фильтра                                           | `ColorAdjustment`, фильтры, exporter                         | 41 color-pipeline tests: pixel-сравнение preview/export, исходные пиксели не меняются                                 | PASS — Flutter renderer               |
| Текст, стикеры, объекты и слои                                     | `MarkupControls`, `AnnotationCanvas`, `AnnotationEditor`     | Создание, изменение стилей, порядок слоёв, удаление, геометрия и история                                              | PASS — Flutter                        |
| Сохранение и ошибки без замены оригинала                           | Save flow, `EditedImageExporter`, loader                     | Save retry/cancel/double tap, корректные PNG/JPEG/EXIF, сохранение копии; native Photos/upload замоканы               | PASS — клиентские проверки            |
| Причины недоступности AI и повтор                                  | Repository + `magic_eraser_availability.dart`                | Generated API client с HTTP stub; widget-tests disabled/API/photo/access/network/503 и retry                          | PASS — transport/widget, не inference |
| Совместимость с нашим форком на iOS                                | Общие Dart-компоненты и существующий `ApiService`            | iOS platform variants, cutouts/home indicator, keyboard/orientation/history; имена API и auth headers сохранены       | PASS — общий Flutter-слой             |
| Нативные iOS/Android, HEIC-плагины, Photos permissions, signed app | Существующие native bridges                                  | Xcode/устройства и нативная сборка в этой задаче не запускались                                                       | NOT VERIFIED                          |
| Реальный AI inference и Save-to-NAS                                | Действующий backend/AI/NAS                                   | Сервис, модели и production не вызывались                                                                             | NOT VERIFIED                          |

При дополнительной приёмке на `550324e08` новый red-test воспроизвёл overflow 54 px на 568×320 с горизонтальными cutouts (0 PASS / 2 FAIL).
Причина: лимит панели учитывал только нижний ряд, но не обязательную полосу рисования/заголовок. Финальный патч резервирует их высоту
и минимум места под раскрытые настройки. Если клавиатура не оставляет достаточно места, вспомогательные настройки временно скрываются
с сохранением состояния. При высоте меньше самого ряда временно скрывается и ряд; после закрытия клавиатуры он возвращается.
Вывод воспроизведения сохранён в `short-landscape-before-fix.txt` (нормализованы только конечные пробелы).

## Фактические проверки

Flutter **3.47.2**, Dart **3.13.2**, Linux software renderer; все тяжёлые команды выполнялись последовательно,
через существующий `foto-stage-runner.py`, `flutter test --concurrency=1`.

| Запуск                                                              | Результат       | Примечание                                                                                                                           |
| ------------------------------------------------------------------- | --------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Исходный red-test на базе                                           | 2 PASS / 6 FAIL | Шесть layout-сценариев воспроизвели проблему до исправления; этот результат не выдаётся за успешный                                  |
| Compact + acceptance + save + integration                           | 88/88 PASS      | Обычное golden-сравнение без `--update-goldens`                                                                                      |
| AI transport + page + editor integration                            | 115/115 PASS    | До добавления двух дополнительных owner/metadata тестов                                                                              |
| Финальный AI repository                                             | 32/32 PASS      | Включая оба дополнительных теста; неизвестные/подменённые metadata не доказывают отсутствие API                                      |
| Оставшиеся editor regressions + расширенный compact suite           | 243/243 PASS    | 17 compact cases, включая новые реальные strokes для Android/iOS; остальные 226 — геометрия, цвета, экспорт, форматы и entry/actions |
| Финальная проверка после исправления короткого окна                 | 100/100 PASS    | Compact 21 + acceptance 10 + save 6 + crop history 4 + editor integration 59; golden без обновления                                  |
| Финальный compact suite с дополнительными assertions                | 21/21 PASS      | Оба platform variants, доступный picker в коротком окне, клавиатура оставляет 84/44 px body, документ сохранён                       |
| Scoped `flutter analyze --no-pub`                                   | PASS, 0 issues  | Все editor pages/widgets, AI repository и соответствующие tests                                                                      |
| Dart format, Prettier изменённых i18n/workflows, `git diff --check` | PASS            | Только изменённые области                                                                                                            |
| Source-only workflow guards                                         | 2/2 PASS        | Семь build/sign/E2E jobs запрещены для этой review-ветки, обычные PR/dispatch guards сохранены                                       |
| Frozen Flutter dependencies / локализация                           | PASS            | Lockfile сохранён; OpenAPI не менялся и не регенерировался                                                                           |

Запуски пересекаются: **380 различных финальных Flutter cases** покрыты этими наборами, это не сумма строк таблицы.
Первоначальный запуск с отсутствующими ignored Drift outputs не скомпилировался; после подготовки generated dependencies red-test выполнен отдельно.
Промежуточные ошибки layout и obsolete test selectors исправлены до указанных PASS. Pixel/geometry assertions не удалялись.

Исходные PASS receipts и полные логи скопированы без редактирования в
[`specs/testing/editor-compact-20261021/`](specs/testing/editor-compact-20261021/).
[`evidence-index.json`](specs/testing/editor-compact-20261021/evidence-index.json) содержит соответствие запусков и SHA-256 логов/PNG.
В отдельном `scoped-flutter-analyze.txt` удалены только конечные пробелы строки progress; исходные stage receipts/logs не менялись.
Receipts честно сохраняют исходный HEAD + fingerprint незакоммиченных тогда изменений, позднее сохранённых в приведённых коммитах;
они не являются доказательством production, подписанным recovery-proof или выполнением одного нового объединённого тестового запуска.

## Визуальное подтверждение

Все PNG ниже получены **Flutter widget renderer** из реальной страницы `EditImagePage`, с проектными шрифтами,
русской локалью, DPR=1 и синтетическим изображением. Это не макеты, не Android/iOS system screenshots и не фотографии пользователя.
Шесть новых PNG генерируются тремя тестами (initial + draw); три прежних golden обновлены под новую компоновку.
После генерации выполнено обычное сравнение, изображения просмотрены.

- [Android — старт](mobile/test/pages/edit/goldens/compact_android_portrait.png), [рисование](mobile/test/pages/edit/goldens/compact_android_portrait_draw.png).
- [iOS — старт, safe-area 47/34](mobile/test/pages/edit/goldens/compact_ios_portrait.png), [рисование](mobile/test/pages/edit/goldens/compact_ios_portrait_draw.png).
- [Landscape — старт](mobile/test/pages/edit/goldens/compact_landscape.png), [рисование](mobile/test/pages/edit/goldens/compact_landscape_draw.png).
- [Штрих и фото](mobile/test/pages/edit/goldens/editor_ru_draw_portrait.png), [текст в landscape](mobile/test/pages/edit/goldens/editor_ru_text_landscape.png),
  [компактный экран, крупный шрифт](mobile/test/pages/edit/goldens/editor_ru_compact_large_text.png).

## Удалённый CI

На опубликованном `550324e08183a7f5f9346578befa7acb926a0c2f` прошли полный `Static Code Analysis` (codegen, analyze, format),
`Test i18n`, форматирование `.github` и Zizmor. Build/sign/Docker jobs действительно SKIPPED; успех агрегирующего workflow не считается сборкой.
[Общий Test run](https://github.com/docice545/gallery/actions/runs/39667647019) содержит ShellCheck FAIL в пяти неизменённых файлах:
`hp_vaapi_audit.sh`, `gallery-nas-recovery-565ef38.sh`, `server_build.sh`, `hp_build10_rollback.sh`, `hp_build10_image_update.sh`
(SC2016/SC2155/SC2174/SC2154). Их Git blob SHA сравнены с `ace2eab…` и полностью совпадают. Исправления вне редактора не делались.
Это исторический результат указанного HEAD; актуальный CI конечного HEAD смотреть в [PR #6](https://github.com/docice545/gallery/pull/6).
Полностью зелёный общий CI здесь не заявлен.

## До нативного выпуска

На реальных Android и iPhone проверить ориентацию/системные жесты/клавиатуру, TalkBack/VoiceOver, скорость и потребление памяти
на больших фото/HEIC, Save copy через системный Photos и permissions, а также AI → preview → save-copy на безопасном тестовом backend.
Для этого использовать синтетические/специально созданные изображения. В этой задаче APK/IPA/backend не собирались, production не менялся.
