# Timeline Live/Motion Photo: качество изображения и общее кадрирование

Дата: 2026-10-05. Репозиторий `docice545/gallery`, ветка `work`.
Baseline этой отдельной задачи: `1077df262d632e08905ff1c465423f3ddfe5e455` —
Takeout/date-repair уже завершён и отправлен в `origin/work` до начала изменений mobile.

Два предоставленных пользователем Android screenshot показывают резкий still в
полноэкранном viewer и мягкое изображение той же Live/Motion Photo в крупной
timeline tile. Screenshot не доказывает, что autoplay был активен. Частные
фотографии не добавляются в репозиторий. Диагноз ниже основан на tracing кода,
request/widget tests; физический повтор на Samsung ещё необходим.

## Найденная причина

`fixed/segment.model.dart` уже передавал размер remote decode с учётом DPR,
но `getThumbnailImageProvider` всегда выбирал серверный `size=thumbnail`.
Больший decode не восстанавливает отсутствующие pixels. Thumbnail имеет
default **250 px по короткой стороне**, не по длинной: сервер использует
`resize(size, size, {fit: 'outside', withoutEnlargement: true})`.
`RemoteImageProvider` завершал stream этим изображением, без последующего
upgrade. Local timeline tiles продолжали запрашивать фиксированные 320×320,
а face-aware вариант — aspect-preserving изображение с длинной стороной 320.
Для крупной/high-DPI tile этих источников недостаточно.

Viewer использует другой путь: `RemoteFullImageProvider` показывает thumbnail,
затем `size=preview` (default 1440 px по короткой стороне), затем original только
если соответствующая настройка включена. Local full-image provider запрашивает
размер viewport×DPR. Поэтому viewer мог быть резким при мягкой timeline tile.

URL/decode-size/checksum cache keys уже присутствовали. Проблема была в выборе
финального источника и размере local request, а не в отсутствии cache key.
Native player использует aspect-fit внутри внешнего Flutter crop. Если video
aspect отличается от still, возникает дополнительное letterboxing/другое поле
зрения. Нельзя исправить это придуманным focal offset или повернуть video по
одним только raw dimensions.

## Источники до, во время и после autoplay

| Состояние | Отображаемый источник |
| --- | --- |
| Initial / scrolling / settling / autoplay выключен или ineligible | Still: local thumbnail request либо существующий server thumbnail/preview по размеру tile; thumbhash остаётся кратким placeholder |
| Candidate выбран, motion ещё загружается | Тот же still остаётся под скрытой native surface |
| Motion готов и presentation contract совместим | Existing `NativeVideoViewer`, paired video; тот же внешний crop/focal geometry |
| Motion закончился / stop / error / неподходящее качество или geometry | Native surface скрывается, остаётся тот же still; scope освобождает единственную reservation |
| Widget/cache rebuild | Provider key включает выбранный URL и bounded decode size; прежний маленький thumbnail не подменяет preview |

Remote motion source не изменён: authenticated
`/api/assets/{livePhotoVideoId}/video/playback`; сервер отдаёт encoded video, а
при его отсутствии original paired video по существующему контракту.
iOS может использовать уже локальный paired subtype. Android embedded motion
image использует существующую server-extracted пару. Новых assets, video frame
thumbnails, prefetch очереди или второго player нет.

## Размер и ограничения запросов

Новый pure helper `buildTimelineThumbnailRequest` получает реальные внутренние
constraints tile, DPR и известный upright source size. Для cover вычисляется
`scale = max(tileWidth×DPR/sourceWidth, tileHeight×DPR/sourceHeight)`; для contain
используется минимум. Сохраняется полный source aspect, включая часть за crop,
чтобы PhotoKit не обрезал лицо до передачи изображения Flutter.

Scale ограничен native source size. Длинная сторона ограничена **1440 px**,
а decode округляется вверх по **128 px** для повторного использования соседних
cache sizes. Нужная короткая сторона ≤250 использует thumbnail; большие запросы
используют существующий preview. Выбор source делается до bucket rounding, чтобы
достаточный 250 px thumbnail не превращался в лишний preview request.
Неизвестный source aspect использует conservative physical viewport fallback.
Новая main-timeline логика не запрашивает still originals даже при включённом
viewer `loadOriginal`.

`requiredSize` отдельно сохраняет unrounded bounded physical requirement для
motion. Например, tile 360×202.5 при DPR 3 требует 1080×607.5; still decode bucket
1152×648 не должен запретить достаточно резкое video 1080×608. Gate учитывает
микроскопическую floating-point погрешность, не снижая pixel requirement.

`LocalImageRequest` округляет **положительные** target axes вверх минимум до 1 px.
Иначе panorama 30000×10 с target 1440×0.48 превращалась бы в native original-size
sentinel из-за `toInt()`. Explicit `Size.zero`, используемый full viewer для
original, сохранён.

Remote decode/cache budget — максимум 1440² pixels, около 7.9 MiB RGBA для
квадратного bitmap, без учёта временных buffers и framework cache. Большинство
tile decode меньше. Native local request также bounded, но существующий iOS
PhotoKit `.fast` может вернуть больше target; его retry `.exact` применяется
только выше native 16384 px texture limit. **1440 нельзя выдавать за доказанный
лимит actual iOS allocation**. Native player buffers тоже не равны still budget.
Эти величины требуют Instruments/физической проверки, native sizing не меняется.

Большие tiles получают больше bytes, чем прежний 250 px источник — это необходимая
цена резкости. Используется готовый server preview, native HTTP/image caches и
lazy rows, без thumbnail-specific metadata requests или загрузки оригиналов.
Face metadata читается из существующей owner-scoped local DB. При поступлении
face union, требующей contain, requirement может снизиться и изменить provider
key; request остаётся bounded и обычно использует cached derived source.

## Общее кадрирование и безопасный fallback

Still и motion получают одну canonical upright image size и один список faces.
Оба вызывают существующий `faceAwareThumbnailFraming`: constrained crop для
подходящего лица, union для нескольких, contain если union не помещается в
cover, center при отсутствии faces. Фиксированный вертикальный offset не добавлен.
Flutter motion canvas имеет source aspect и тот же `BoxFit`/`Alignment`.

Перед показом native surface проверяются реальные native video dimensions:
aspect должен совпадать со still с допуском только на codec integer rounding;
оба pixel axes должны покрывать `requiredSize`. Низкое разрешение или иной aspect
сохраняют чёткий still и завершают текущую one-shot reservation. Не скачивается
второй video ради retry и не запускается следующее live photo в том же viewport.

У разных camera crops/стабилизации нет spatial registration metadata. Даже
совпадающий aspect не доказывает абсолютно одинаковое поле зрения; проверить
реальные Samsung/Apple pairs необходимо. Для несовпадающих aspect реализация
намеренно оставляет static still, а не обещает одинаковый crop.

Edited Live/Motion still и неизвестная upright geometry в main timeline остаются
статичными: edit-aware video transform отсутствует. Это не меняет pair identity
или поведение full viewer. Presentation fallback тоже потребляет одну выбранную
reservation, без cascading autoplay.

Pinned native player на iOS сообщает `naturalSize` без `preferredTransform`.
Swapped portrait dimensions не считаются доказательством rotation: такая пара
без подтверждённой общей geometry остаётся статичной. Native dependency, Swift,
Kotlin и identifiers не изменены. Исправление источника/DPR/cache относится к
общему Flutter-пути Android и iOS; окончательной physical iOS проверки нет.

## Сохранённый autoplay и UI контракт

Selector/controller, threshold **80%**, settling **350 ms**, meaningful-scroll
threshold, muted one-shot, no loop/no cascade, scroll stop, navigation и lease
disposal не менялись. Presentation suitability действует только на выбранную
surface. Завершение сразу скрывает native texture даже до удаления widget.
Hero, selection, stack badge, motion/upload badges, gestures, dense layout,
pagination и server models сохранены; scope ограничен main Photos timeline.

## Проверки

Targeted tests покрывают source selection/decode/DPR/bounds, landscape/portrait,
faces/union/contain/center, local/remote parity, no-original requests, cache/rebuild,
source suitability, hidden surface до readiness и после completion, resize,
edited/unknown geometry и все существующие one-shot/no-loop/no-cascade правила.

Первый общий прогон: 460 passed, 1 failed. Failure — существующая проверка
фиксированного 320×320 local decode; expectation обновлена на physical-size
request 504×896 для tile 160×160 при DPR 3, aspect и bounds усилены. Ошибка не
скрывается; финальный общий повтор проходит все assertions.

| Проверка | Результат |
| --- | --- |
| Images + все timeline widgets + asset viewer + synchronized face bounds + remote image request | **473 passed**, exit 0 |
| Memory widgets и main timeline Memory lane | **19 passed**, exit 0 |
| Дополнительная floating-point regression в pure motion suite | **43 passed**, exit 0; входят в основной набор |
| Full `flutter analyze --no-pub` | **No issues found**, exit 0 |
| `dart format --output=none --set-exit-if-changed` | **15 Dart files, 0 changed** |

Основной набор содержит **101 новый test case**, остальные assertions сохранены;
одна прежняя local-size проверка обновлена и усилена. Основные команды из `mobile/`:

```bash
flutter test --no-pub --reporter expanded \
  test/presentation/widgets/images \
  test/presentation/widgets/timeline \
  test/presentation/widgets/asset_viewer \
  test/providers/infrastructure/thumbnail_face_bounds_provider_test.dart \
  test/infrastructure/loaders/remote_image_request_test.dart
flutter test --no-pub --reporter expanded \
  test/presentation/widgets/memory \
  test/presentation/pages/dev/main_timeline_memory_lane_test.dart
flutter analyze --no-pub
```

В этих Flutter test logs встречается native shutdown diagnostic
`Callbacks into the Dart VM are currently prohibited ... or a finalizer is running`:
пять раз в основном наборе и один раз в Memory наборе, после завершения отдельных
test isolates. Assertions прошли, process exit 0; сообщение не считается
отсутствующим только из-за успешного итогового test status. Это **подтверждённая
pre-existing диагностика**: тот же неизменённый `main_timeline_memory_lane_test`
запущен отдельно с temporary `lib` snapshot из точного baseline `1077df262d`,
с существующими generated files/dependencies: 1 passed, exit 0, тот же native
shutdown error в `tearDownAll`. Current worktree при сравнении не менялся.
Baseline log: `/workspace/gallery-validation/live-quality-memory-baseline.log`.
SQLite/FFI finalizer — возможная причина, но точный диагноз не доказан;
unrelated native/runtime исправление в эту задачу не включается. Production/native
устройств эти тесты не используют.

Server/TypeScript/schema/i18n не изменялись; server tests, schema migrations,
codegen и locale regeneration для этой задачи не требуются. Dependency/build
toolchain upgrades не выполнялись. `git diff --check`, syntax Bash snippets и
список защищённых paths прошли проверки. Изменены только девять mobile source
files, шесть test files и этот внутренний report; server/signing/production paths
не затронуты. Git SHA указывается в финальном отчёте после отдельного commit/push.

## Изменённые файлы

Source:

- `mobile/lib/infrastructure/loaders/local_image_request.dart`
- `mobile/lib/presentation/widgets/asset_viewer/video_viewer.widget.dart`
- `mobile/lib/presentation/widgets/images/image_provider.dart`
- `mobile/lib/presentation/widgets/images/remote_image_provider.dart`
- `mobile/lib/presentation/widgets/images/thumbnail.widget.dart`
- `mobile/lib/presentation/widgets/images/thumbnail_tile.widget.dart`
- `mobile/lib/presentation/widgets/images/timeline_thumbnail_request.dart` (new)
- `mobile/lib/presentation/widgets/timeline/live_photo_presentation.dart` (new)
- `mobile/lib/presentation/widgets/timeline/live_photo_scope.widget.dart`

Tests:

- `mobile/test/presentation/widgets/asset_viewer/timeline_preview_video_viewer_test.dart`
- `mobile/test/presentation/widgets/images/local_image_provider_test.dart`
- `mobile/test/presentation/widgets/images/thumbnail_face_framing_widget_test.dart`
- `mobile/test/presentation/widgets/images/timeline_thumbnail_quality_widget_test.dart` (new)
- `mobile/test/presentation/widgets/images/timeline_thumbnail_request_test.dart` (new)
- `mobile/test/presentation/widgets/timeline/live_photo_presentation_test.dart` (new)

Documentation: `specs/testing/2026-10-05-live-photo-timeline-quality-validation.md`.

## Физическая приёмка

На Samsung: сравнить исходную проблемную пару до autoplay, при playback и после;
repeat cold/warm cache, DPR и layout размеров, portrait/landscape, faces/union,
disabled setting, slow drag/fling, selection/stacks, viewer navigation и возврат.
Проверить пары с небольшим и несовместимым motion component: резкий static fallback
и отсутствие следующего autoplay до нового viewport. Оценить RAM/network/scroll.

На iPhone/macOS: PhotoKit target/actual buffer size и memory, local/cloud-only
Apple pair, AVPlayer rotation/`naturalSize`, face crop, transitions, permissions
и foreground/navigation cancellation; затем native analyze/build на macOS.
В Cloud нет Android SDK, физического Samsung/iPhone или macOS/Xcode. APK/IPA
не собирались и не устанавливались, native/physical успех не заявляется.

Production 5.7.1, server API/DB/schema, NAS originals, signing, Big-LaMa, AI
Memories, внешний auto-stack/Anna exclusion и networking не изменяются.
Deployment не выполняется. Commit/push этой задачи отдельны от Takeout.
