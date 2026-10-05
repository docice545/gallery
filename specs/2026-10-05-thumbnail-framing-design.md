# Face-aware framing в основной мобильной ленте

## Источник координат и область действия

`FaceAwareThumbnailScope` включён только вокруг существующего `Timeline` в
`MainTimelinePage`. Остальные thumbnail surfaces сохраняют прежнее кадрирование.
Имеющиеся owner-scoped `asset_face` sync streams уже записывают размеры изображения
и bounding boxes в Drift. `thumbnailFaceBoundsProvider` читает индексированный
`assetId` через `PeopleDatabaseRepository.watchAssetFaces`; исключает deleted и
невидимые faces, но допускает лица без присвоенного personId.

Нет запросов asset detail на каждую плитку, новой ML-обработки, загрузки оригиналов
или производных media. Подписка autoDispose существует только у смонтированной
плитки. Shared Space faces другого owner, ещё не синхронизированные faces и
local-only assets могут не иметь этих данных: используется прежний центрированный
cover. Для отредактированного asset также остаётся fallback: старые координаты
лица нельзя применять к изменённой системе координат без преобразования edits.

## Геометрия

Каждый box нормализуется по своим `imageWidth/imageHeight`, независимо от размера
декодированного thumbnail. `faceAwareThumbnailFraming` работает с фактическими
размерами декодированного изображения и текущей плитки:

1. Отбрасывает некорректные, перевёрнутые, non-finite и полностью внешние boxes;
   частично внешние координаты ограничивает диапазоном 0…1.
2. Вычисляет union всех пригодных лиц и размер source crop для `BoxFit.cover`.
3. Сдвигает допустимый crop так, чтобы union целиком оставался видимым. Целевая
   точка — центр union, чуть выше центра плитки при наличии пространства; это
   ограниченное геометрией предпочтение, а не фиксированный vertical offset.
4. Если лица слишком далеко друг от друга и весь union нельзя вместить в cover,
   выбирает `contain`: все люди остаются видимыми, размер плитки не меняется.

Orientation должна быть уже применена существующим decode pipeline: серверные
preview и ML face detection используют upright изображения. Экранные пиксели
не вращаются повторно, EXIF и оригинал не переписываются. Корректность локальных
PhotoKit/Android decoding при EXIF rotation остаётся физическим acceptance check.

## Память, локальные thumbnails и playback

Существующий `Thumbnail` RenderBox применяет fit/alignment к предыдущему и
текущему изображению во время fade. При приходе face metadata изменяется только
paint; image provider не перезагружается при неизменном decode request.

У локального изображения, для которого уже известны faces, decode target
сохраняет исходное соотношение сторон внутри прежнего `kThumbnailResolution`
budget. Это не позволяет PhotoKit `aspectFill` заранее обрезать portrait source
до квадрата. `LocalThumbProvider` cache identity теперь включает target size,
чтобы старый square request не подменил новый aspect-preserving thumbnail.
Remote thumbnail pipeline и его лимиты остаются прежними.

`TimelineLivePhotoTile` получает те же normalized boxes. Его существующий
`FittedBox` использует тот же helper для видеосоставляющей. Регистрация кандидата,
visibility threshold, settling delay, meaningful-scroll правило, mute, one-shot,
остановка и disposal не менялись. При обновлении faces asset остаётся тем же:
это не новый viewport, не новый playback lease и не разрешение повторного запуска.
Hero, hit testing, selection и badges остаются на прежних слоях.

Still и motion могут различаться полем зрения; статические координаты не заменяют
face tracking внутри видео. Для таких пар необходима физическая проверка, а не
обещание сохранить движущееся лицо в каждом кадре по неподвижному still box.

## Проверяемые контракты

Geometry tests покрывают одно/несколько лиц, portrait/landscape, границы и invalid
metadata. Widget tests проверяют реальные PNG pixels, отсутствие re-decode,
contain fallback, Hero/badges/selection/tap, bounded local request и неизменность
активного one-shot при приходе faces. Provider tests используют настоящую Drift DB,
проверяют normalization, реактивные изменения/deletion и запрет HTTP. Existing
timeline/autoplay suites дополнительно проверяют one-candidate/no-loop/no-cascade
и meaningful-scroll. macOS/iPhone/Samsung эти tests не заменяют.
