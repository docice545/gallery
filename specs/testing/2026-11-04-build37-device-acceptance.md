# Build37: воспроизводимая аппаратная приёмка

**BLOCKED: device acceptance pending. Production NO-GO.** Этот документ подготовлен в облаке; перечисленные команды на Samsung/iPhone/HP не выполнялись. Текущий программный статус — [единый чек-лист](../../BUILD37_CHECKLIST.md). Пользователь отдельно разрешает установку/подпись/работу HP; сценарии используют выделенный тестовый аккаунт и синтетические фото. Не очищать данные установленного FOTO и не использовать архив пользователя для разрушительных проверок.

## Доказательство исходников и среды

Сохранить полный SHA, PR/checks URLs, APK SHA256, versionName/versionCode, certificateSHA256; Samsung model/Android/security patch, разрешение/масштаб дисплея/шрифта, навигационные отступы, ориентацию, тему, частоту дисплея и энергосбережение. Записать сеть/сервер SHA и размеры тестовой библиотеки. Все8 Live Photo сценариев проверять на одной сборке; после изменения playback/UI/native кода повторить. Логи могут содержать личные пути/ID — публиковать только синтетический набор и очищенные выдержки.

## Samsung: восемь обязательных Live Photo сценариев H1

Предварительно: autoplay включён, в первом экране минимум2 настоящих Motion/Live Photo с различимым движением, одна обычная фотография, стопка из2 изображений. Сохранить исходные bytes/checksum в тестовом наборе. Снимать экран так, чтобы было видно движение, а не только badge/обложку.

1. Завершить процесс FOTO, открыть иконкой непосредственно Timeline; Viewer заранее не открывать. Для первого выбранного asset получить `selected → native-ready → play-request-accepted → position-advanced` и реально движущийся кадр.
2. Оставить первый экран видимым: выбранная Live Photo движется, вторая одновременно не играет. Отметить на записи выбранное синтетическое фото и время начала/окончания сценария; сопоставить с последовательностью событий.
3. Прокрутить выбранную за пределы экрана и вернуть. Старый player прекращает воспроизведение; вновь видимый получает новый корректный lease/события и движение.
4. Войти в выделение одним long press, затем одинарными тапами выбрать1→many→1 и выйти. Ни тап по фото, ни scroll не выбирает посторонние IDs; playback восстанавливается только у допустимой видимой фотографии.
5. Открыть Viewer, swipe/zoom/pan, вернуться. Timeline route не активен за Viewer; после возврата играет ровно один видимый кандидат.
6. Home → возврат без завершения процесса. В фоне нет воспроизведения; после resume новое допустимое playback подтверждено движением и `position-advanced`.
7. Быстро прокручивать между двумя Live Photo, чередовать Viewer/back/selection. Ни в кадрах, ни в событиях нет перекрывающихся активных players; поздний native ACK от отозванного lease ничего не возобновляет.
8. Повторить переходы/удаление/анимации при120Гц. Нет зависаний/конфликта animation controllers. Метрики ниже измеряются отдельно; статичный screenshot или simulatorPASS этого не доказывает.

Для событий включить уровень журналирования **INFO** в дополнительных настройках до холодного запуска. После сценария открыть существующий экран «Журналы» и сохранить экспорт через его кнопку «Поделиться» локально; ничего не отправлять автоматически. `LogService` сохраняет INFO и в release, тогда как вывод через `dPrint` в logcat зависит от debug-режима, поэтому один пустой logcat не доказывает отсутствие событий. Отбирать строки `Timeline motion:` по записанным границам времени. Существующие bounded stage-события намеренно не содержат asset IDs, URL или generation; идентифицировать тестовое фото по видеозаписи/его заранее записанному ID, не придумывать отсутствующие поля журнала. Сам export stage-логов не заменяет видимое движение и контроль второй Live Photo в кадре.

Не включать permanent `route=true`, Viewer warmup, polling/retry timers. Любая регрессия H1 блокирует выпуск. Холодный запуск проверять **помимо** profile-сессии: подключение отладчика и прогрев не должны подменять его.

## Samsung: profile UI/raster H2

Сборщик `mobile/lib/utils/diagnostics/frame_capture.dart` регистрируется только при `kProfileMode` и явном `FOTO_FRAME_CAPTURE=true`. В release/обычном profile нет callback/extension. Один bounded буфер40000 кадров, без чтения изображений, per-frame decode, сетевых запросов или periodic timer. Stop один раз ждёт доставку финальной пачки engine timings и отбрасывает кадры после stop. Отчёт содержит raw UI/raster микросекунды, nearest-rank p50/p95/p99, число/процент кадров, где **UI или raster** превысили8,333мс. Их длительности не суммируются: pipeline работает параллельно. Это не полный compositor/display trace; реальные refresh rate, пропуски presents и shader/decode причины проверять также в DevTools/Perfetto.

После отдельного разрешения установки profile-сборки, в отдельной чистой checkout выбранного SHA, с уже существующим разрешённым developer signing setup (если ключа нет — не генерировать):

```bash
cd mobile
profile_sha=$(git rev-parse HEAD)
test -z "$(git status --porcelain)"
mise run install:ci
mise run codegen
mise exec -- flutter run --profile -d SAMSUNG_SERIAL \
  --dart-define=FOTO_FRAME_CAPTURE=true \
  --dart-define=FOTO_PROFILE_SOURCE_SHA="$profile_sha"
```

`flutter run` **устанавливает** приложение; это команда пользователю, не выполненная облачным Codex. Не переустанавливать production APK другим сертификатом, не соглашаться на uninstall/reset. Использовать разрешённый тестовый профиль/устройство. Сохранить напечатанный localhost VM-service HTTP URL приватно (он содержит capability token).

Во втором терминале, после загрузки тестовой библиотеки и подготовки нужного экрана:

```bash
cd mobile
profile_sha=$(git rev-parse HEAD)
mkdir -p ../profile-evidence
read -r -p 'Local VM service HTTP URI: ' profile_vm_uri
mise exec -- dart run tool/capture_frames.dart "$profile_vm_uri" viewer 30 \
  "$profile_sha" ../profile-evidence/viewer.json
```

Повторить с именами `albums`, `selection`, `device-trash`, `server-trash`, `stack-two-to-one`, `live-photo`, `editor`, `timeline-density`. Начинать жесты после `RECORDING`; собирать минимум3 повтора каждого. Сохранить отдельно первый/cold и warm прогоны, не удалять неудачный прогон. Пустой/обрезанный capture или несовпадение embedded sourceSHA — invalid evidence. `reportedDisplayHz` и реальный режим телефона должны соответствовать120Гц; параметр120 сам по себе это не доказывает. `acceptance=REVIEW_REQUIRED` намеренно не вычисляет «release ready».

| Scenario | Действия в30с | Дополнительные наблюдения |
|---|---|---|
| viewer | tap toolbar on/off, swipe, pinch, pan, back10циклов | pan увеличенного фото не перелистывает; swipe/zoom не раскрывают toolbar |
| albums | открытие/назад, scroll, reveal/reverse, trash tap/cancel; list и grid | строка остаётся, один FOTO dialog, нет delete от самого swipe |
| selection | rapid taps1→many→1, scroll/date header, refresh/другой альбом | конкретные IDs, count/checkmarks/SafeArea, никакого массового ошибочного выбора |
| device-trash | синтетические local-only/backup pairs, OS allow/deny, повтор | server copies неизменны, per-ID receipt, без permanent fallback/backup-диалога |
| server-trash | delete одного и batch, offline/ошибка/retry | нет success до ACK, при ошибке фото возвращается; uncertain journal не разрешает backup resurrection |
| stack-two-to-one | две тестовые фото: отдельно удаление cover/второго, restore | оставшийся цел; одна плитка сразу, Viewer/cache/sync/restart/offline согласованы |
| live-photo | восемь H1 переходов кроме cold-launch | реальные position events и max1 player; не только Dart cover |
| editor | markup→marker→color/width, crop/text/MagicEraser/back, темы/keyboard | один dock56+SafeArea, viewport/правки/zoom/pan/undo не теряются |
| timeline-density | оба режима и2–5, вертикальные screenshots, быстрый scroll | gaps/order/stack representative; один transient date label fixed top, скрывается после остановки |

Для каждой строки: UI/raster p50/p95/p99, jank count/percent, thermal/battery/display mode, sourceSHA; загрузить DevTools Performance trace для локализации длительных кадров (build/layout/decode/shader/raster). Не объявлять120fps по среднему или только p50.

## Samsung: геометрия, темы и данные H3/H4/H7/H8

- Сравнить Google Photos и FOTO на одном дисплее/масштабе и одинаковых синтетических изображениях при2–5, особенно3. Измерить tile/row вlogical dp, одинаковые gaps, частоту crop, date header space. [Инструмент алгоритма](../../mobile/tool/timeline_geometry.dart) даёт отдельный программный отчёт; visual parity ещё не установлена.
- Editor light/dark/system: одна и та же фотография/правки; изменить системную тему при открытом редакторе и при открытой палитре; explicit override сохраняется. Док56dp+SafeArea, image rect одинаков на всех глубинах; keyboard/landscape/font2×; палитра не перекрывает последнюю точку рисования. SaveCopy создаёт новый файл, Cancel не меняет исходник; оригинальное motion не меняется.
- Согласованные FOTOv1 icons (`ccdb8a892`): действие соответствует glyph/Tooltip/TalkBack, enabled/selected/disabled contrast и минимум48dp touch target. Новую геометрию отдельно согласовать.
- Удалить последнюю фотографию открытого тестового local album: после подтверждённого удаления возврат к списку; loading/refresh/OS denial этого не делают. Уведомление читаемо поверх Years/Months/All; после скрытия Months работает.
- Места: Аннино list/detail, Восточное Дегунино при доступномru, unknown source fallback, ru→en→ru онлайн/офлайн, search/Timeline. Сохранить place identity/координаты/наборassetIDs до/после; пользовательские album titles/EXIF неизменны. Проверить отсутствие геокодирования приscroll.

## iPhone / SideStore H5

Требует macOS для unsigned Runner+extensions и существующей настройки SideStore пользователя. Не генерировать сертификаты/ключи. До установки сверить archive/IPA sourceSHA/version/build/bundle IDs, extensions/AppGroups/entitlements, SHA256. SimulatorPASS не считается установкой на iPhone.

На отдельном тестовом аккаунте: установка через SideStore и повторный refresh, перезапуск/expiry recovery, login/refresh-token, Timeline/sync/thumbnail/offline/reconnect, LivePhoto still+motion, Viewer→редактор→SaveCopy/Cancel, original motion byte identity, photo-library permissions/limited-access/denial, background/resume, device/server trash и restore. Записать реальный iPhone/iOS/SideStore version и источники артефактов. Apple account/provisioning/signing пользователь выполняет отдельно; никаких секретов в Issue/PR.
