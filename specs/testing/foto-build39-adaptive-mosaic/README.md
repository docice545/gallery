# FOTO Build 39 — Adaptive Mosaic

Проверено 2026-11-05, Flutter 3.47.2 / Dart 3.13.2. Основа — отдельный коммит фирменного удаления `7685d6dfb1f27f05c2d3a414e4f49529c2a829e7`; принятый UI Hotfix `06af1905efe80bbe3fe342a94e5c97245a270fba` сохранён в истории. Ветка — `codex/foto-build38-unified-16`, без merge и смены ветки.

## Причина и геометрия

Прежний алгоритм выбирал число элементов по близости высоты строки к целевой. Для горизонтальных кадров выигрывала одиночная строка: две фотографии становились двумя большими блоками, а три следующих портретных видео — отдельным рядом. Исправление пустого хвоста само по себе не ограничивало такие одиночные строки. Те же 32 новых widget-сценария на app-файлах исходного коммита завершились FAIL; исходные снимки сохранены в `before/`.

Теперь одна группа даты разбивается на заполненные строки или составные блоки. На телефоне при двух и более элементах в группе каждый блок содержит 2–3 элемента. Составной блок допускает крупную ячейку слева и две справа либо зеркальное расположение. Выбор учитывает исходные пропорции, потери при кадрировании, высоту и выбранную плотность; составной блок не навязывается каждой группе. Фото и видео участвуют в одном расчёте.

- На ширине 390 dp минимальная ширина ячейки — 104 dp. Обычная строка ограничена сверху 216–240 dp при плотностях 2–5, составной блок — 280 dp. Одиночная дата — не выше 128 dp; её портретная миниатюра имеет компактную центрированную геометрию. Это явное исключение для действительно единственного материала, без заимствования кадров из соседней даты.
- Две горизонтальные фотографии имеют одинаковую высоту; три обычных портрета получают сбалансированные ячейки. Нечётные группы перераспределяются по 2–3, без одиночного хвоста. На широких экранах количество ячеек адаптируется, максимум 8.
- Составной блок отклоняется при слишком узкой боковой колонке, слишком низкой маленькой ячейке или потере более 30% площади любого превью. Штатное заполнение миниатюры через cover сохраняет пропорции; оригинал и полноэкранный просмотр не меняются.
- Планирование ограничено последовательными окнами по 9 материалов; последние 10 остаются вместе. Полная оптимизация даты могла менять далёкие предыдущие строки после удаления в середине. Два теста воспроизводят это смещение и подтверждают локальность нового выбора. Построение остаётся O(n), поиск строки по смещению — O(log n).
- Неизменяемые прямоугольники ячеек кешируются и используются для загруженных карточек, placeholders, hit testing и scroll-to. Нижняя ячейка составного блока имеет собственное вертикальное смещение. Загрузка пикселей и выделение не участвуют в расчёте геометрии.

Порядок источников сохранён: крупный первый элемент → два правых сверху вниз; либо два левых сверху вниз → крупный третий. Индексы, ID, даты, длительности видео и существующие оверлеи сохраняются. Classic сохраняет заголовки, Immersive — свою компоновку и доступную семантику дат. Pinch, drag-selection, виртуализация, операции удаления и Undo остаются существующими механизмами.

## Изменённые файлы

Полный список девяти Dart-файлов — [changed-dart-files.txt](changed-dart-files.txt).

| Файл | Изменение |
| --- | --- |
| `mobile/lib/presentation/widgets/timeline/fixed/row_layout.dart` | Выбор плотных строк и асимметричных блоков, ограничение размеров, кеш прямоугольников |
| `mobile/lib/presentation/widgets/timeline/fixed/row.dart` | Размещение, размеры и области нажатия дочерних элементов по общей геометрии, включая RTL |
| `mobile/lib/presentation/widgets/timeline/fixed/segment.model.dart` | Передача одной геометрии в миниатюры и placeholders; существующий GhostSource сохранён |
| `mobile/lib/presentation/widgets/timeline/timeline_scroll_target.dart` | Учёт вертикального смещения нижней составной ячейки |
| `mobile/test/presentation/widgets/timeline/adaptive_mosaic_layout_test.dart` | 24 новых проверки размеров, составных блоков, дат, hit testing, кеша и локальности удаления |
| `mobile/test/presentation/widgets/timeline/justified_timeline_widget_test.dart` | 32 новых пиксельных сценария и четыре проверки настоящего Timeline с 50 000 элементами |
| `mobile/test/presentation/widgets/timeline/timeline_ghost_deletion_test.dart` | Четыре новых сценария удаления из середины мозаики, всего 22 интеграционных теста удаления |
| `mobile/test/presentation/widgets/timeline/justified_row_layout_test.dart` | Проверки реальных прямоугольников и покрытия составного блока вместо требования одинаковой высоты всех ячеек |
| `mobile/test/presentation/widgets/timeline/dense_timeline_overlays_test.dart` | Проверка покрытия составной геометрии; отрицательный autoplay-сценарий сохраняет долю видимости ниже 65% при новой ограниченной высоте singleton |

## Фактические результаты

| Проверка | Результат | Лог |
| --- | --- | --- |
| Те же 32 новые визуальные проверки с исходными app-файлами | **32 FAIL**, exit 1 | [baseline-final.log](logs/baseline-final.log) |
| Итоговый регрессионный набор | **873 PASS**, exit 0 | [final-regressions.log](logs/final-regressions.log) |
| 50 000 элементов: четыре настоящих Timeline плюс сохранённый исходный Sliver-тест | **5 PASS**, exit 0 | [virtualization-final.log](logs/virtualization-final.log) |
| `flutter analyze` девяти изменённых Dart-файлов | **No issues found**, exit 0 | [final-analyze.log](logs/final-analyze.log) |

К предыдущим 809 тестам добавлено 64: 24 геометрических, 32 рендера, четыре проверки виртуализации и четыре сценария удаления из середины мозаики. Полный набор включает первые три исправления, Live Photo, offline, выбор одного элемента, жесты, панели, память, изображения и actions удаления. Проверки групп 1/2/3/5/7 охватывают портретные, квадратные и горизонтальные материалы на плотностях 2–5. Сохранены проверки панорам и соседних дат.

Матрица рендера: 10 горизонтальных фото, 10 горизонтальных видео, смешанная группа, последовательность двух горизонтальных фото и видео **00:39 / 00:17 / 00:11** × Classic/Immersive × светлая/тёмная тема × шрифт 100%/200%, экран 390×844. Проверяются реальные размеры карточек, покрытие блока, длительности, цветные пиксели, источник каждого элемента и отсутствие изменения геометрии или выделения соседей при выборе одного материала.

Четыре дополнительных сценария удаления используют реальные Timeline/actions/GhostSource: серверные и локальные источники, по одному и три выбранных элемента из середины. Каталог меняется до ACK операции. Проверяются точные ID, один вызов операции, соответствие пикселей летящей карточки выбранному источнику, сохранение изображений соседей, окончательная геометрия и неизменное смещение реального scroll position. Одиночные сценарии сняты в Classic/light, массовые — в Immersive/dark с шрифтом 200%. Переключатель эффекта, reduced motion, отмена/отказ и незагруженные источники покрыты сохранёнными тестами предыдущего коммита. Семантика массового эффекта прежняя: одна видимая представительная карточка, операция над всеми выбранными ID.

Для 50 000 элементов настоящий Timeline на шрифте 200% создаёт 18 живых ThumbnailTile в Classic и 15 в Immersive после перехода к середине. Геометрия до/после scroll — тот же объект. Запросов миниатюр: 95 при начальной загрузке/переключении плотности, ещё 80 при переходе, 130 уникальных ID суммарно в двух окрестностях. Каждая партия каталога ≤1024; все запросы изображений направлены в thumbnail, оригиналы не запрашиваются. Исходный изолированный Sliver-тест с пределом менее 100 суммарных запросов также сохранён и проходит. Эти измерения не являются замером FPS на Samsung.

## Визуальные доказательства

Непосредственные PNG из Flutter widget-рендера: все 32 пары в [before](before/) и [after](after/). Использованы синтетические изображения с различимыми цветами/рисунком, а не личные фото пользователя. PNG не редактировались. Это проверка Flutter-компоновки, не снимки физического Samsung.

| Сценарий | До | После |
| --- | --- | --- |
| Два горизонтальных фото + видео 00:39/00:17/00:11, Classic/light/100% | [PNG](before/adaptive-samsung-five-classic-light-1.0.png) | [PNG](after/adaptive-samsung-five-classic-light-1.0.png) |
| Та же последовательность, Immersive/dark/200% | [PNG](before/adaptive-samsung-five-immersive-dark-2.0.png) | [PNG](after/adaptive-samsung-five-immersive-dark-2.0.png) |
| 10 горизонтальных фотографий, Classic/light/100% | [PNG](before/adaptive-landscapes-classic-light-1.0.png) | [PNG](after/adaptive-landscapes-classic-light-1.0.png) |
| 10 горизонтальных видео, Classic/light/200% | [PNG](before/adaptive-videos-classic-light-2.0.png) | [PNG](after/adaptive-videos-classic-light-2.0.png) |
| Смешанная группа, Immersive/dark/200% | [PNG](before/adaptive-mixed-immersive-dark-2.0.png) | [PNG](after/adaptive-mixed-immersive-dark-2.0.png) |

Просмотрены финальные сравнительные снимки Samsung-последовательности, плотные ряды горизонтальных видео, смешанный составной блок и кадры удаления. На Samsung-последовательности две фотографии находятся слева сверху/снизу, видео 00:39 занимает правую часть блока, затем 00:17/00:11 размещены парой. Промежутки равномерны, внутри блоков пустых прямоугольников нет. Свободная область после конца короткой тестовой группы не является дырой строки.

| Удаление из середины | До | Полёт | Поглощение/reflow | После |
| --- | --- | --- | --- | --- |
| Сервер, 1 | [PNG](deletion/timeline-mosaicServer-1-before.png) | [PNG](deletion/timeline-mosaicServer-1-flight.png) | [PNG](deletion/timeline-mosaicServer-1-intake.png) | [PNG](deletion/timeline-mosaicServer-1-after.png) |
| Сервер, 3 | [PNG](deletion/timeline-mosaicServer-3-before.png) | [PNG](deletion/timeline-mosaicServer-3-flight.png) | [PNG](deletion/timeline-mosaicServer-3-intake.png) | [PNG](deletion/timeline-mosaicServer-3-after.png) |
| Устройство, 1 | [PNG](deletion/timeline-mosaicLocal-1-before.png) | [PNG](deletion/timeline-mosaicLocal-1-flight.png) | [PNG](deletion/timeline-mosaicLocal-1-intake.png) | [PNG](deletion/timeline-mosaicLocal-1-after.png) |
| Устройство, 3 | [PNG](deletion/timeline-mosaicLocal-3-before.png) | [PNG](deletion/timeline-mosaicLocal-3-flight.png) | [PNG](deletion/timeline-mosaicLocal-3-intake.png) | [PNG](deletion/timeline-mosaicLocal-3-after.png) |

Четыре `after/adaptive-50000-*.png` фиксируют геометрию и оверлеи виртуализированного viewport. В этих тестах канал возвращает пустой результат миниатюры: видимые placeholders ожидаемы и не выдаются за проверку готовых пикселей. Загрузку и сохранение настоящих декодированных тестовых пикселей проверяют 32 сценария выше и интеграционные тесты удаления.

## Воспроизведение

Из `mobile/` после стандартной подготовки зависимостей и generated-кода:

```bash
flutter test --no-pub \
  test/presentation/widgets/timeline \
  test/presentation/widgets/bottom_sheet \
  test/presentation/widgets/memory \
  test/presentation/widgets/build39_ui_hotfix_test.dart \
  test/presentation/widgets/spaces/space_album_bottom_sheet_test.dart \
  test/presentation/widgets/deletion \
  test/presentation/widgets/images \
  test/unit/presentation/actions/ghost_trap_action_test.dart \
  test/unit/presentation/actions/deletion_snapshot_guard_test.dart \
  test/unit/presentation/actions/delete_action_test.dart \
  test/unit/presentation/actions/local_album_device_deletion_test.dart \
  test/unit/presentation/actions/album_ghost_trap_test.dart \
  --reporter expanded \
  --dart-define=FOTO_MOSAIC_CAPTURE=true \
  --dart-define=FOTO_MOSAIC_ARTIFACT_DIR=/tmp/foto-adaptive-mosaic/after \
  --dart-define=FOTO_TIMELINE_DELETE_CAPTURE=/tmp/foto-adaptive-mosaic/deletion

flutter test --no-pub \
  test/presentation/widgets/timeline/justified_timeline_widget_test.dart \
  --plain-name '50000-item' --reporter expanded

mapfile -t files < <(sed 's@^mobile/@@' ../specs/testing/foto-build39-adaptive-mosaic/changed-dart-files.txt)
flutter analyze --no-pub "${files[@]}"
```

В исходном контрольном прогоне менялись только четыре app-файла на их версии из `7685d6dfb`; затем текущие файлы восстановлены побайтно. Базовый и итоговый рендеры используют одни и те же новые тесты. При копировании логов удалены только конечные пробелы строк. Сохранены ожидаемые сообщения синтетических отказов и сообщение Flutter engine о Dart VM callbacks при тестовом native-image декодировании, встречающееся также в исходном прогоне. PASS означает успешные assertions и exit 0. Контрольные суммы артефактов — [SHA256SUMS](SHA256SUMS), проверенных исходников — [checked-source.sha256](checked-source.sha256).

`DEVICE_REQUIRED`: визуальная приёмка на физическом Samsung, плавность прокрутки и анимации, системный диалог удаления, haptic и реальные сетевые/локальные источники. Облачные проверки выполнены; аппаратная приёмка не объявляется выполненной. APK не собирался, production не затрагивался. Backend, Docker, редактор, модели/API/БД, applicationId, подпись и versionCode не менялись. `[skip ci]` предотвращает автоматическую APK-сборку при push.
