# FOTO: проверка justified-фотоленты

База: `170f972f8edfed524208661ad811dda20de7fbb2`, завершённый Build 29.
Ветка: `codex/foto-justified-photo-timeline`.
Решение и причины изменений: [design](../2026-11-02-foto-justified-timeline-design.md).

## Результаты облачной проверки

| Проверка                                    | Статус     | Результат                                                        |
| ------------------------------------------- | ---------- | ---------------------------------------------------------------- |
| Flutter regression                          | PASS       | 818 тестов; без skipped/failing тестов в итоговом прогоне        |
| Полный Flutter analyze                      | PASS       | No issues found; Flutter 3.47.2 / Dart 3.13.2                    |
| Генерация Drift/Freezed                     | PASS       | Штатный build_runner, схема БД и версии зависимостей не менялись |
| `dart format` изменённых Dart-файлов        | PASS       | 21 файл, 0 дальнейших изменений                                  |
| `git diff --check`                          | PASS       | Без ошибок                                                       |
| Повторный Flutter-rendering с экспортом PNG | PASS       | 9 widget tests; эти тесты уже входят в 818                       |
| Реальный Samsung Galaxy S23                 | NOT TESTED | Устройства и доступа к нему в Cloud нет                          |
| Android emulator / device FPS               | NOT TESTED | Снимки получены из widget rendering, не эмулятора                |
| APK, production deployment                  | NOT RUN    | Не выполнялись                                                   |

Профильные новые проверки: 13 geometry tests, 11 thumbnail/framing/pixel tests,
11 repository tests с настоящей Drift/SQLite, 9 widget/rendering tests. Они входят
в общий итог 818, а не прибавляются к нему повторно.

Проверяются одиночный кадр и пара, смешанные и длинные портретные последовательности,
крайние/неизвестные размеры, точная сумма ширин и spacing, высота рядов, неполный
последний ряд, порядок, границы дат/месяцев/лет, меняющиеся размеры при том же
количестве assets, clipping в LTR/RTL, long press/tap/выбор даты, неизменность Hero
и widget identity, enlarged text и отсутствие overflow. Тест на 50 000 элементов
проверяет ограниченное число созданных render children и сохранение ограниченного
буфера при переходе к следующей странице.

В регрессию включены Memories главной страницы, zoom/scroll target/scrubber,
обычные thumbnail-политики вне новой сетки, Motion/Live Photo, Magic Eraser Build 28,
сохранение серверной копии и instant Trash Build 29. Ни один тест не отключён.
Устаревшие ожидания растянутого последнего ряда, inset выбранного кадра и старой
иконки Stack заменены проверками текущего поведения. Источники медиа и autoplay
не переписывались.

Отдельный cloud Dart JIT benchmark после трёх прогревов: построение геометрии
50 000 элементов, ширина 390, spacing 3, 10 измерений: 10.216–28.904 мс,
медиана 18.293 мс. Это только вычисление геометрии на облачном CPU, без SQL,
декодирования и отрисовки; оно не доказывает FPS или расход памяти Samsung.

## Команды воспроизведения

Используйте pinned toolchain из `mobile/mise.toml`. После получения зависимостей
по существующему lockfile выполните штатную генерацию OpenAPI/Drift/Freezed/Pigeon
и локализаций (`mise run //mobile:codegen`). Не копируйте generated-файлы от другого
SHA с отличающимся API или схемой.

Из `mobile/`:

```bash
flutter analyze --no-pub
flutter test --no-pub --concurrency=2 \
  test/presentation/widgets/timeline \
  test/presentation/widgets/images \
  test/presentation/pages/dev \
  test/infrastructure/repositories/timeline_mosaic_metadata_test.dart \
  test/infrastructure/repositories/timeline_repository_test.dart \
  test/infrastructure/repositories/timeline_temporal_scope_repository_test.dart \
  test/domain/services/timeline_factory_grouping_test.dart \
  test/domain/services/timeline_factory_temporal_scope_test.dart \
  test/presentation/pages/drift_asset_selection_timeline_page_test.dart \
  test/pages/edit/magic_eraser_page_test.dart \
  test/pages/edit/magic_eraser_editor_integration_test.dart \
  test/domain/utils/background_sync_test.dart \
  test/infrastructure/repositories/magic_eraser_saved_copy_sync_test.dart \
  test/domain/services/instant_trash_acceptance_service_test.dart \
  test/infrastructure/repositories/instant_trash_acceptance_test.dart \
  test/presentation/pages/instant_trash_cleanup_test.dart
```

## Визуальные материалы

В Cloud сохранены `/workspace/foto-justified-timeline-artifacts/`:

- `portrait-unselected-390x844.png` — обычная мозаика;
- `portrait-selected-390x844.png` — overlay и галочка, неизменные прямоугольники;
- `month-boundaries-390x844.png` — разделение месяцев и дат;
- `mosaic-390x844-text160.png` — текст 160%;
- `mosaic-320x568-text160.png` — компактный экран;
- `mosaic-844x390-text160.png` — горизонтальная ориентация.

Это проверенные вручную снимки реального Flutter widget-rendering с синтетическими
изображениями, русской локалью и шрифтами проекта. Они показывают задействованные
настоящие Sliver/Timeline/Thumbnail компоненты, но не полный APK на Samsung.
Пользовательские фотографии или production API не использовались.

Для повторного экспорта в собственный каталог:

```bash
flutter test --no-pub \
  --dart-define=FOTO_MOSAIC_CAPTURE=true \
  --dart-define=FOTO_MOSAIC_ARTIFACT_DIR=/tmp/foto-mosaic-review \
  test/presentation/widgets/timeline/justified_timeline_widget_test.dart
```

В этих тестах gallery layout, размеры/пиксели и жесты настоящие, ответы image API
синтетические. Это не проверка сетевого поведения NAS или декодирования видео на
конкретном телефоне.

## Отдельная приёмка Samsung

После отдельного разрешения на тестовый APK, без удаления данных приложения:

1. Проверить основной экран «Фото» на Galaxy S23: обычные кадры, скриншоты,
   портреты/панорамы, EXIF rotation, существующие отредактированные фото.
2. Прокрутить начало и старые годы большой библиотеки; проверить заголовки,
   Memories, scrubber, pinch zoom и возврат из fullscreen viewer.
3. Выбрать кадры долгим нажатием и обычными taps, целую дату, несколько дат;
   проверить нижние действия и выход из выбора без смещения изображений.
4. Проверить обе темы, поворот, размер текста 160–200%, системные отступы.
5. Проверить Live Photo local/remote согласно прежней настройке: максимум один
   кандидат, остановка при прокрутке/фоне, ручной fullscreen playback.
6. Сверить тепловыделение, RAM, пропуски кадров и запросы миниатюр на настоящей
   библиотеке. Облачный geometry benchmark не заменяет этот шаг.

Схема/данные БД, backend/API, upload/delete/sync, оригиналы, production, ключи
подписи и номер версии не менялись. Исходная ветка Build 29 сохранена. Перенос
следует делать в отдельный worktree по итоговому полному SHA, без reset/переключения
существующего production checkout. Откат исходников возвращает прежнее отображение;
обратных миграций или изменений фотографий нет.

## Полный список изменённых файлов

- `mobile/lib/data/db/main/query/merged_asset.drift`
- `mobile/lib/domain/models/timeline.model.dart`
- `mobile/lib/infrastructure/repositories/timeline.repository.dart`
- `mobile/lib/presentation/widgets/images/thumbnail.widget.dart`
- `mobile/lib/presentation/widgets/images/thumbnail_framing.dart`
- `mobile/lib/presentation/widgets/images/thumbnail_tile.widget.dart`
- `mobile/lib/presentation/widgets/images/timeline_thumbnail_request.dart`
- `mobile/lib/presentation/widgets/timeline/fixed/row_layout.dart`
- `mobile/lib/presentation/widgets/timeline/fixed/segment.model.dart`
- `mobile/lib/presentation/widgets/timeline/fixed/segment_builder.dart`
- `mobile/lib/presentation/widgets/timeline/header.widget.dart`
- `mobile/lib/presentation/widgets/timeline/live_photo_scope.widget.dart`
- `mobile/lib/presentation/widgets/timeline/segment_builder.dart`
- `mobile/lib/presentation/widgets/timeline/timeline.state.dart`
- `mobile/lib/presentation/widgets/timeline/timeline.widget.dart`
- `mobile/test/infrastructure/repositories/timeline_mosaic_metadata_test.dart`
- `mobile/test/presentation/widgets/images/mosaic_thumbnail_test.dart`
- `mobile/test/presentation/widgets/images/thumbnail_face_framing_widget_test.dart`
- `mobile/test/presentation/widgets/images/thumbnail_live_photo_test.dart`
- `mobile/test/presentation/widgets/timeline/dense_timeline_overlays_test.dart`
- `mobile/test/presentation/widgets/timeline/justified_row_layout_test.dart`
- `mobile/test/presentation/widgets/timeline/justified_timeline_widget_test.dart`
- `specs/2026-11-02-foto-justified-timeline-design.md`
- `specs/testing/2026-11-02-foto-justified-timeline.md`
