# FOTO Build 39 — фирменное удаление непосредственно из Timeline

Проверено в облаке 2026-11-05 поверх принятого `06af1905efe80bbe3fe342a94e5c97245a270fba`, на той же ветке `codex/foto-build38-unified-16`. Рабочее дерево перед задачей было чистым. Это отдельное дополнение №4; геометрия строк, панели и воспоминания из первых трёх исправлений не переделывались.

## Подтверждённые причины и исправление

В Timeline уже были `GhostSource`, `GhostTrashTarget` и вызовы подготовки/подтверждения эффекта из реальных `DeleteAction` / `CleanupLocalAction`. Но проверка готовности захватываемой фотографии искала только `RenderImage`. Штатная миниатюра Timeline рисуется собственным `_ThumbnailRenderBox`: даже загруженные фотографии не проходили эту проверку, и удаление шло без эффекта. Два новых интеграционных теста на принятом HEAD воспроизвели отсутствие `ghost-trap-flight` при одиночном и массовом удалении.

Добавлен небольшой контракт `DecodedImageSource`, который сообщает о реально отображаемых декодированных пикселях. Градиент незагруженной карточки не считается фотографией. Координатор теперь распознаёт и штатный `RenderImage`, и рендерер миниатюр; снимок по-прежнему берётся с существующей карточки, без открытия viewer и без запроса оригинала.

После включения эффекта пиксельная проверка выявила две ошибки его взаимодействия с сеткой:

- Внешний `ClipRRect` обрезал перемещаемых соседей по их новым границам. `GhostSource` перенесён наружу относительно этого clip: фотография и её скругление теперь перемещаются вместе существующим механизмом reflow.
- При изменении размера соседней ячейки новый decode size, а иногда переход thumbnail → preview, сбрасывал уже готовую фотографию в градиент. Сохраняются пиксели **того же источника** до готовности новой версии размера. Другой asset, endpoint, revision, edit-параметр или локальный checksum не считается тем же источником. Переработки планировщика качества/декодирования и кеша нет.

Траектория, деформация фотографии, поглощение корзиной, крышка, лёгкое встряхивание и длительность прежние: 640 мс, при системном уменьшении анимаций — существующий сокращённый вариант 180 мс. Массовое удаление использует одну видимую представительную миниатюру, как и предусмотрено существующим эффектом; операция получает **все выбранные ID**. Подтверждения, Undo, права, серверные/локальные операции и настройки удаления не изменены.

## Проверки

Новый `timeline_ghost_deletion_test.dart` использует реальный Timeline, выделение long-press/tap, компактную панель, actions и собственный рендерер Thumbnail. Подменены только платформенный источник синтетических пикселей и внешние операции. Изменение каталога приходит до возврата результата операции — это проверяет работу эффекта при реальном перестроении сетки, а не только изолированный painter.

18 новых проверок: по 1, 3 и 4 выбранных изображения для серверного/локального удаления; эффект выключен без перезапуска; reduced motion; отказ сервера; отмена Android; незагруженные миниатюры; сохранение пикселей при resize и очистка при повторном использовании ячейки для другого asset. Проверяются точные ID, один вызов операции при повторном нажатии, ожидание подтверждения, исходная карточка/целевая корзина, фазы эффекта, пиксели соседей до/во время/после reflow, очистка выделения только при успехе. Размер рендера — 390×844 с системными отступами.

| Проверка | Фактический результат | Лог |
| --- | --- | --- |
| Новые single/bulk тесты с app-файлами принятого HEAD | 2 FAIL: загруженные миниатюры не запускают эффект, exit 1 | [baseline-final.log](logs/baseline-final.log) |
| Пиксели соседей после исправления распознавания, до переноса clip | 2 FAIL: вместо фотографии фон | [reflow-check.log](logs/reflow-check.log) |
| Соседи при resize до сохранения декодированного источника | 2 FAIL, 5 PASS: серверная и локальная миниатюры становятся градиентом | [resize-red.log](logs/resize-red.log) |
| Новый интеграционный набор после исправлений | 18 PASS, exit 0 | [matrix-final.log](logs/matrix-final.log) |
| Полный набор регрессий (включая первые три исправления, Live Photo, offline, выделение, жесты и существующие actions удаления) | **809 PASS**, exit 0 | [final-regressions.log](logs/final-regressions.log) |
| Анализ пяти изменённых Dart-файлов | No issues found, exit 0 | [final-analyze.log](logs/final-analyze.log) |

Для воспроизведения из `mobile/` после стандартной подготовки зависимостей (Flutter 3.47.2, Dart 3.13.2):

```bash
flutter test --no-pub \
  test/presentation/widgets/timeline/timeline_ghost_deletion_test.dart \
  --reporter expanded \
  --dart-define=FOTO_TIMELINE_DELETE_CAPTURE=/tmp/foto-timeline-deletion
```

Полный регрессионный набор:

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
  --reporter expanded
```

Анализ из `mobile/`, Bash:

```bash
mapfile -t files < <(sed 's@^mobile/@@' ../specs/testing/foto-build39-timeline-deletion/changed-dart-files.txt)
flutter analyze --no-pub "${files[@]}"
```

## Фактический тестовый рендер

| Операция | Выделение | Полёт | Поглощение и reflow | Завершение |
| --- | --- | --- | --- | --- |
| Сервер, 1 | [PNG](frames/timeline-server-1-before.png) | [PNG](frames/timeline-server-1-flight.png) | [PNG](frames/timeline-server-1-intake.png) | [PNG](frames/timeline-server-1-after.png) |
| Сервер, 3 | [PNG](frames/timeline-server-3-before.png) | [PNG](frames/timeline-server-3-flight.png) | [PNG](frames/timeline-server-3-intake.png) | [PNG](frames/timeline-server-3-after.png) |
| Устройство, 1 | [PNG](frames/timeline-local-1-before.png) | [PNG](frames/timeline-local-1-flight.png) | [PNG](frames/timeline-local-1-intake.png) | [PNG](frames/timeline-local-1-after.png) |
| Устройство, 3 | [PNG](frames/timeline-local-3-before.png) | [PNG](frames/timeline-local-3-flight.png) | [PNG](frames/timeline-local-3-intake.png) | [PNG](frames/timeline-local-3-after.png) |

Это непосредственный Flutter-рендер на синтетических цветных изображениях в тестовой теме, а не снимки Samsung или пользовательские фотографии. Просмотрены исходное выделение, полёт, intake и итоговая сетка; пиксельные assertions отдельно проверяют сохранение изображений соседей. PNG не редактировались. Для исходной версии запускались те же новые тесты; app-файлы затем восстановлены побайтно, без смены ветки или reset.

В копиях логов удалены только конечные пробелы строк. Сохранены ожидаемые сообщения о синтетическом отказе удаления и диагностическое сообщение Flutter engine о Dart VM callbacks при тестовом native-image декодировании (встречается также до исправления). PASS означает успешное завершение assertions и exit 0, а не отсутствие диагностических строк. Контрольные суммы: [SHA256SUMS](SHA256SUMS), [проверенные исходники](checked-source.sha256).

`DEVICE_REQUIRED`: фактическое удаление локальных/облачных фото на Samsung, системный диалог Android, плавность и haptic на устройстве. Облачный widget-тест не заменяет эту приёмку. Новый APK не собирался; подпись, versionCode, applicationId, backend, Docker, редактор и production не затронуты. `[skip ci]` в коммите предотвращает автоматическую APK-сборку при push.
