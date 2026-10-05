# Корзина: дата удаления вместо даты съёмки

Authoritative timestamp — существующий server `asset.deletedAt`. `AssetService`
записывает его при soft delete независимо от `fileCreatedAt/localDateTime`.
Owner sync V1/V2 уже передаёт это поле, и мобильная Drift `remote_asset` уже
сохраняет его. Новые колонки, migrations и повторный library scan не нужны.

## Mobile

`TimelineRepository.trash()` явно выбирает `SortAssetsBy.deleted`. Только этот
запрос использует deletedAt для descending item order, day/month/year buckets,
temporal scope и переходов по периодам. Timestamp переводится в календарь
устройства, как прежний upload-date режим. При равенстве deletion timestamp
ID делает порядок страниц стабильным. Join существующего local original не
подменяет серверную дату удаления датой локального capture.

Существующий optimistic delete показывает клиентское `DateTime.now()` до
получения sync; затем authoritative server timestamp реактивно перегруппировывает
assets. Перезапуск читает persisted Drift data. Обычные Photos timeline, albums,
favorites/search и Memories сохраняют прежние defaults. Restore снимает deletedAt
и возвращает asset в его capture chronology; original bytes, EXIF и Live pair
не изменяются. Android device trash и iOS Recently Deleted — отдельные native
механизмы, а не эта серверная корзина.

## Web и минимальное расширение API

Web использует прежний lazy time-bucket timeline, без загрузки полного sync
или отдельного запроса на каждый thumbnail:

- `orderBy=deletedAt` добавлен в существующий enum. DTO и TimelineService
  принимают его только при `isTrashed=true`; defaults takenAt/createdAt прежние.
- `/timeline/buckets`, `/timeline/bucket`, `/timeline/bucket-covers` используют
  одну deletion column для counts, range filtering, order и cover selection.
- AssetResponse имеет optional `deletedAt`; columnar bucket response — optional
  `deletedAt` array, выровненный по asset IDs. Не-trashed записи возвращают null.
  Sanitized shared-link response не раскрывает дополнительные private metadata.
- Trash page явно выбирает Desc/DeletedAt. День определяется в UTC согласно
  существующему bucket API; это может отличаться от device-local дня mobile
  возле полуночи. Съёмочная timezone не переписывается для устранения различия.
- Within-day updates и новые дни сортируются по точному deletion timestamp;
  Restore исключает запись до попытки прочитать её очищенное deletedAt.

Старые клиенты игнорируют optional fields и сохраняют свои query modes. Новая
web-корзина требует обновлённый fork API; из отсутствующего deletedAt нельзя
выдумать дату удаления по updatedAt/capture date. Production 5.7.1 этой задачей
не развёртывается и не обновляется.

OpenAPI/TypeScript SDK перегенерированы. Zod metadata id прикреплён к итоговой
validated query schema: id на base перед refine заставлял Swagger трактовать
query как wrapper reference, а не flat parameters. Это сохраняет штатную codegen
архитектуру. Mobile получает дату через уже существующий sync и не требует нового
native API или Pigeon generation для исправления корзины.

## Доказательства

Real Drift tests покрывают sync V1/V2, реактивность, month/year drilldown,
pagination, local original merge, mixed photo/video и restore/capture/EXIF.
Server DTO/unit tests проверяют mode validation и настоящий deletedAt вместо
updatedAt; real PostgreSQL tests проверяют buckets/covers/owner isolation и
штатный TrashRepository.restoreAll. Web tests проверяют headers/sort/upsert,
same-day timestamps и удаление восстановленных assets из UI. Native acceptance
на Samsung и macOS/iPhone остаётся отдельной проверкой.
