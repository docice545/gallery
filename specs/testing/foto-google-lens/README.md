# FOTO — Google Объектив через Android Sharesheet

Дополнение выполнено после фирменного удаления (`7685d6dfb1f27f05c2d3a414e4f49529c2a829e7`) и Adaptive Mosaic (`1e070783ce8232d48408b6b87ee491920af95c87`). Основа этого изменения — `1e070783c`, ветка `codex/foto-build38-unified-16`. Принятый `06af1905e` сохранён. Дата проверки — 2026-11-05.

## Реализованный способ

В меню «Ещё» полноэкранной фотографии добавлено действие **«Google Объектив»**. Оно использует существующую иконку поиска по изображению FOTO и оформление текущей темы. Нижняя панель не расширена. Действие доступно для Android-фотографий, включая Live/Motion Photo, в обычном просмотре и альбомах; скрыто для видео, корзины, заблокированной папки и iOS. Readonly-viewer сохраняет существующее ограничение инструментов.

Выбрана интеграция через **стандартный Android Sharesheet**. В изученных официальных материалах Google не найден документированный публичный Intent для передачи изображения прямо в Lens. Внутренние Activity, `googleapp://`/`intent://` deep links и принудительный запуск пакета не используются. FOTO объясняет, что в системном меню нужно выбрать Google или Lens, если установленная версия принимает изображение. Если такого обработчика нет, пользователь может выбрать другое совместимое приложение, отменить действие либо установить/обновить Google. Наличие приложения само по себе не считается доказательством поддержки image-sharing.

Открытие инструментов и информационного диалога не запускает подготовку или передачу файла. Кнопка «Выбрать приложение» начинает подготовку, затем Android показывает Sharesheet. Google получает изображение только если пользователь выберет соответствующий обработчик. Успешный запуск Sharesheet **не выдаётся за успешный поиск в Lens**: дальнейший интерфейс и обработка принадлежат выбранному приложению.

Подготовка и передача повторно используют `AssetMediaRepository.shareAssets` и существующий `OriginalSharePlugin`, без изменения этих app-компонентов:

- Доступная локальная фотография копируется в выделенный временный `outgoing_share/`; оригинал не переименовывается, не перезаписывается и не удаляется. При устаревшем локальном ID сохраняется существующий fallback репозитория к доступному серверному источнику.
- Для cloud-only фотографии используется существующая загрузка JPEG preview через **GET** `/assets/{id}/thumbnail?size=preview…`, затем передаётся локальный временный файл. Запросов передачи изображения в Google через Backend FOTO нет. Для Live Photo выбирается режим `imageOnly`; отдельный motion-компаньон не скачивается. Общая функция обмена Live/Motion Photo не изменена.
- Существующий неэкспортируемый FileProvider создаёт `content://…original_share/…` только для файлов в узком разрешённом cache-path. `ACTION_SEND`, MIME изображения, `EXTRA_STREAM` и `ClipData` передаются через `Intent.createChooser`. На Intent и chooser установлено только временное `FLAG_GRANT_READ_URI_PERMISSION`; `file://`, разрешение записи и широкая публикация каталога не добавлены.
- Существующий кеш сохраняет подготовленный файл после запуска chooser, чтобы получатель успел прочитать его. Отмена подготовки отменяет её token сразу; позднее завершение не открывает второе окно. Ошибка файла, загрузки или запуска chooser оставляет понятные «Повторить»/«Отменить». Повторный запуск происходит только по нажатию.

## Официальные источники и границы вывода

Страницы фактически получены по HTTPS 2026-11-05, HTTP 200:

| Источник | Подтверждённый контракт |
| --- | --- |
| [Android: Send simple data to other apps](https://developer.android.com/training/sharing/send) (перенаправляет на `develop/ui/compose/sharing/send`) | `ACTION_SEND` + `EXTRA_STREAM` + MIME для двоичного содержимого; `Intent.createChooser` открывает системный Sharesheet; получателю нужен доступ к URI |
| [Android: Share files](https://developer.android.com/training/secure-file-sharing/share-file) | FileProvider/content URI и временное read-разрешение через Intent; не требуется открывать исходный файл всему устройству |
| [Android: Common intents](https://developer.android.com/guide/components/intents-common) | `ACTION_WEB_SEARCH` и Google `SEARCH_ACTION` описывают текстовый поисковый запрос; это не контракт передачи фотографии в Lens |
| [Google Search Help: Search with an image on Google](https://support.google.com/websearch/answer/1325808?hl=en&co=GENIE.Platform%3DAndroid) | Пользовательские пути поиска изображения через Google/Chrome и Lens; рекомендуется актуальная версия Google app. Публичный Lens image-launch Intent на странице не указан |

Вывод ограничен этими проверенными публичными контрактами. Здесь не утверждается, что все версии Google/Lens объявляют обработчик `ACTION_SEND`. По этой причине fallback является основным поддерживаемым путём интеграции, а прямой запуск внутреннего экрана Lens не обещается.

## Изменённые файлы

| Файл | Изменение |
| --- | --- |
| `mobile/lib/presentation/actions/google_lens.action.dart` | Новое действие, подсказка по Sharesheet, подготовка по нажатию, прогресс, отмена и повтор после ошибки |
| `mobile/lib/utils/action_button.utils.dart` | Регистрация Lens в существующем меню и ограничения доступности |
| `mobile/lib/presentation/widgets/icons/proposal/foto_icon_mapping.dart` | Одна строка сопоставления нового действия существующей иконке FOTO; editor mapping не изменён |
| `i18n/en.json`, `i18n/ru.json` | Четыре локализованные строки |
| `mobile/test/unit/presentation/actions/google_lens_action_test.dart` | 15 проверок действия, выбора, ошибок, отмены, контекстов и оформления |
| `mobile/test/repositories/asset_media_repository_test.dart` | Два новых теста полного пути Lens → реальный репозиторий → native share channel для локальной и облачной фотографии |
| `mobile/test/presentation/widgets/asset_viewer/google_lens_viewer_test.dart` | Два теста реального PhotoView с масштабом, смещением, меню и возвратом в обеих темах |

Список для анализа — [changed-dart-files.txt](changed-dart-files.txt). Подготовка переводов обновляет только игнорируемые generated-файлы; они не коммитятся.

## Фактически выполненные проверки

Flutter 3.47.2 / Dart 3.13.2, Linux cloud workspace.

| Проверка | Результат | Доказательство |
| --- | --- | --- |
| Целевой набор Lens + существующие проверки share/Live Photo | **51 PASS**, exit 0 | [lens-targeted-final.log](logs/lens-targeted-final.log) |
| Общие регрессии после добавления Lens: Timeline, Adaptive Mosaic, фирменное удаление, viewer, панели, воспоминания, иконки, actions и share | **1 143 PASS**, exit 0 | [final-regressions.log](logs/final-regressions.log) |
| `flutter analyze` шести изменённых Dart-файлов | **No issues found**, exit 0 | [final-analyze.log](logs/final-analyze.log) |
| Android устройства/эмуляторы в среде | Не подключены | [android-devices.log](logs/android-devices.log) |

Всего добавлено 19 тестов. Проверки локального и облачного файла проходят через настоящее действие и настоящий репозиторий, реальные временные файлы и подмену только downloader/native-каналов. Они подтверждают отсутствие работы до явного нажатия, правильный источник/тип, побайтную сохранность локального оригинала, отдельный staging path, JPEG MIME, GET preview без motion-загрузки и сохранение файла для получателя. Это не выполнение Android Activity внутри Flutter-теста.

15 тестов действия охватывают local/cloud/merged, отсутствие обязательной зависимости от пакета Google, пояснение fallback, ошибки и явный retry, отмену кнопкой/Back/dispose во время подготовки, блокировку повторного запуска, поздний progress/completion, ограничения доступности, русский текст при 390×844 и шрифте 100%/200% в обеих темах. Проверка отсутствия Lens подтверждает доступный общий путь и подсказку; реальная конфигурация установленных Android-приложений требует устройства.

В двух дополнительных тестах используется полноценный `AssetViewer` с декодированным изображением 2400×1600 и настоящими жестами PhotoView. После zoom/pan открываются настоящее меню и Lens, выполняется handoff, затем воспроизводится корректная последовательность lifecycle inactive → hidden → paused → hidden → inactive → resumed. Сравниваются route, текущий asset, состояние панелей, экземпляр PhotoView controller, его scale/position и экранный прямоугольник. Отдельные сохранённые регрессии проверяют обычный viewer, альбомы, корзину, видео, Live Photo и существующий значок «Поделиться».

## Тестовый рендер

PNG получены напрямую из Flutter, с загруженным шрифтом GoogleSans, без редактирования изображений. Это синтетическая фотография и тестовые экраны, не скриншоты Google Lens, Android Sharesheet или физического Samsung.

| Сцена | Светлая тема | Тёмная тема |
| --- | --- | --- |
| Русское меню, шрифт 100% | [PNG](frames/lens-menu-light-1.0.png) | [PNG](frames/lens-menu-dark-1.0.png) |
| Диалог, шрифт 100% | [PNG](frames/lens-dialog-light-1.0.png) | [PNG](frames/lens-dialog-dark-1.0.png) |
| Русское меню, шрифт 200% | [PNG](frames/lens-menu-light-2.0.png) | [PNG](frames/lens-menu-dark-2.0.png) |
| Диалог, шрифт 200% | [PNG](frames/lens-dialog-light-2.0.png) | [PNG](frames/lens-dialog-dark-2.0.png) |
| Реальный PhotoView: исходный масштаб/смещение | [PNG](frames/lens-real-viewer-light-before.png) | [PNG](frames/lens-real-viewer-dark-before.png) |
| Реальное меню viewer | [PNG](frames/lens-real-viewer-light-menu.png) | [PNG](frames/lens-real-viewer-dark-menu.png) |
| Диалог поверх viewer | [PNG](frames/lens-real-viewer-light-dialog.png) | [PNG](frames/lens-real-viewer-dark-dialog.png) |
| Возврат в viewer | [PNG](frames/lens-real-viewer-light-after.png) | [PNG](frames/lens-real-viewer-dark-after.png) |

При большом шрифте диалог допускает прокрутку содержимого и вертикальное размещение кнопок вместо уменьшения системного размера текста. Нижняя панель viewer не меняет набор или геометрию из-за нового пункта меню.

## Воспроизводимые команды

Из `mobile/`, после обычной подготовки зависимостей и generated-кода:

```bash
dart run easy_localization:generate -S ../i18n
dart run bin/generate_keys.dart

flutter test --no-pub \
  test/unit/presentation/actions/google_lens_action_test.dart \
  test/repositories/asset_media_repository_test.dart \
  test/presentation/widgets/asset_viewer/google_lens_viewer_test.dart \
  --reporter expanded \
  --dart-define=FOTO_LENS_CAPTURE=/tmp/foto-google-lens/frames

mapfile -t files < <(sed 's@^mobile/@@' ../specs/testing/foto-google-lens/changed-dart-files.txt)
flutter analyze --no-pub "${files[@]}"
```

Полный регрессионный запуск, без сборки APK:

```bash
flutter test --no-pub \
  test/presentation/widgets/timeline \
  test/presentation/widgets/bottom_sheet \
  test/presentation/widgets/memory \
  test/presentation/widgets/build39_ui_hotfix_test.dart \
  test/presentation/widgets/spaces/space_album_bottom_sheet_test.dart \
  test/presentation/widgets/deletion \
  test/presentation/widgets/images \
  test/presentation/widgets/asset_viewer \
  test/presentation/widgets/icons \
  test/providers/asset_viewer \
  test/utils_legacy/action_button_utils_test.dart \
  test/repositories/asset_media_repository_test.dart \
  test/unit/presentation/actions/google_lens_action_test.dart \
  test/unit/presentation/actions/share_action_test.dart \
  test/unit/presentation/actions/ghost_trap_action_test.dart \
  test/unit/presentation/actions/deletion_snapshot_guard_test.dart \
  test/unit/presentation/actions/delete_action_test.dart \
  test/unit/presentation/actions/local_album_device_deletion_test.dart \
  test/unit/presentation/actions/album_ghost_trap_test.dart \
  --reporter expanded \
  --dart-define=FOTO_LENS_CAPTURE=/tmp/foto-google-lens/frames
```

## DEVICE_REQUIRED — Android 13–16 / Samsung One UI

Ни Android 13/14/15/16, ни установленное приложение Google/Lens не запускались в этой среде. `adb devices -l` не показывает устройств; Android emulator отсутствует. Статическая проверка существующего публичного Intent/FileProvider-контракта и Flutter-тесты не заменяют эти испытания.

Для каждого API 33/34/35/36 требуется фактическая проверка локального JPEG/HEIC и облачного фото, открытие выбранного Google/Lens, чтение выданного `content://`, возврат без смены масштаба/позиции и повторный запуск. На Samsung — светлая/тёмная тема, шрифт 200%, системные отступы One UI, отмена Sharesheet, Google отсутствует/отключён/не принимает image-sharing, отказ доступа к фото, ошибка загрузки и повтор. В отдельном сценарии Google/Lens отсутствует: должен оставаться общий Sharesheet, другой совместимый получатель либо отмена, без падения.

Для записи фактической конфигурации и результата на тестовом устройстве:

```bash
adb devices -l
adb shell getprop ro.build.version.release
adb shell getprop ro.build.version.sdk
adb shell getprop ro.build.version.oneui
adb shell pm list packages com.google.android.googlequicksearchbox
adb shell pm list packages com.google.ar.lens
adb logcat -d -v threadtime > foto-lens-device-log.txt
```

Эти команды не устанавливают и не собирают APK. Состояние «проверено на Samsung / Lens» не объявляется до фактического результата.

В копиях логов удалены только конечные пробелы. Сохранены ожидаемые ошибки синтетических отказов и сообщение Flutter engine о Dart VM callbacks, встречающееся также в предыдущих native-image widget-тестах. PASS основан на assertions и exit 0. Контрольные суммы: [SHA256SUMS](SHA256SUMS), [checked-source.sha256](checked-source.sha256).

Adaptive Mosaic, анимация удаления, native share/FileProvider, Backend, Docker, редактор и production не изменены. APK не собирался; подпись, versionCode и applicationId сохранены. Коммит содержит `[skip ci]`, чтобы push не запустил автоматическую APK-сборку.
