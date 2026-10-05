# Google Photos albums: только подготовка и dry-run

Этот инструмент восстанавливает **план** принадлежности уже существующих Gallery assets к альбомам из Google Takeout. Он не загружает media, не создаёт альбомы, не пишет в БД и не имеет режима `apply`. Реальные Google JSON пока отсутствуют; это не мешает тестам. Для разработки использованы только синтетические fixtures.

Архитектура, ограничения scanner и будущего application-layer apply: [design](../../specs/2026-10-05-google-photos-albums-design.md). Реальные HP/Synology mount paths и ownership библиотек здесь не выдумываются.

## Требования и запуск тестов

Python 3.10+; только стандартная библиотека, без `pip install`.

```bash
python3 -m unittest discover -s tools/google-photos-albums/tests -v
```

## Источники

`--takeout` указывает на **read-only** дерево Google Photos metadata. Media в нём не обязательны. Поддерживается известный каталог `Google Photos` и его найденный subtree в `Takeout/`; прочие Google services, например Gmail, не сканируются. Для проверенного изолированного дерева Photos с другим именем нужен явный `--photos-root-confirmed`. Этот флаг нельзя использовать для смешанного экспорта Google.

Список известных названий Google Photos корня ограничен. Неизвестный локализованный root требует подтверждения. Year/service directories, распознаваемые сейчас, включают `2020`, `Photos from 2020`, `Фотографии за 2020`, а также известные служебные имена; неизвестная структура должна быть проверена человеком.

Два взаимоисключающих источника Gallery metadata:

1. `--inventory` — offline snapshot. Самая безопасная проверка без сети.
2. `--server` — официальный read-only API: current user, metadata search с pagination и собственные альбомы. POST `/search/metadata` — операция чтения, а не изменение. Оригиналы/preview не скачиваются. HTTPS обязателен; redirect запрещён. API key читается из переменной окружения (по умолчанию `GALLERY_TAKEOUT_API_KEY`), а не из аргумента командной строки. Нужны read permissions `user.read`, `asset.read`, `album.read`; mutation permissions не нужны.

`--owner` обязателен и содержит Gallery owner UUID. Online adapter проверяет current user до чтения библиотеки. Offline snapshot и ledger должны иметь тот же owner. Assets других пользователей не участвуют в matching; отсутствие owner у record приводит к отказу.

### Offline inventory

```json
{
  "albums": [
    {
      "albumName": "Existing unrelated album",
      "assetIds": ["existing-asset-id"],
      "id": "existing-album-id",
      "ownerId": "00000000-0000-0000-0000-000000000001"
    }
  ],
  "assets": [
    {
      "exifInfo": { "fileSizeInByte": 123456 },
      "fileCreatedAt": "2020-01-01T00:00:00Z",
      "height": 3000,
      "id": "existing-asset-id",
      "isOffline": false,
      "isTrashed": false,
      "livePhotoVideoId": null,
      "originalFileName": "photo.jpg",
      "originalPath": "/existing/container/library/photo.jpg",
      "ownerId": "00000000-0000-0000-0000-000000000001",
      "type": "IMAGE",
      "visibility": "timeline",
      "width": 4000
    }
  ],
  "ownerId": "00000000-0000-0000-0000-000000000001"
}
```

Обычный `checksum` внешнего asset нельзя использовать как content hash: Gallery external scanner хранит SHA1 пути (`sha1-path`), а стандартный asset API не сообщает алгоритм. Строгое доказательство content hash разрешено только как явно заданный `contentChecksum: {"algorithm": "sha1"|"sha256", "value": "hex-or-base64"}`. В offline inventory также допустим явно подтверждённый `checksumAlgorithm: "sha1"` или `isExternal: false` для настоящего uploaded asset; эти утверждения нельзя придумывать для external library.

Sidecar JSON ограничен 16 MiB, offline inventory — 128 MiB; превышение прекращает dry-run без output. Полная библиотека в памяти представлена metadata, без media; parsed JSON потребляет больше RAM, чем файл на диске, поэтому даже в этих пределах нужен запас. Online adapter ограничивает размер отдельной страницы, но итоговая owner metadata library также хранится в памяти. Matcher заранее индексирует path/name/content checksum; не делает полный проход по всем assets для каждого JSON.

### Явное соответствие путей

Metadata можно восстановить отдельно от Synology media. `--path-map` — read-only JSON с проверенными соответствиями путей. `metadataPrefix` относителен `--takeout`; `assetPrefix` — точный **server-side** `originalPath` prefix из inventory, а не предположение о host mount.

```json
[
  {
    "assetPrefix": "/actual/server/library/original-folder",
    "metadataPrefix": "Takeout/Google Photos/Original folder"
  }
]
```

Работает наиболее длинный prefix. `..`, относительный target и конфликтующие mappings запрещены. Без mapping `sourceMedia` формируется из пути metadata root и Google title; совпадение с server originalPath нельзя предполагать.

`--hash-media` необязателен и выключен по умолчанию. Он потоково читает **только реально находящийся рядом с source metadata оригинал**, порциями 1 MiB, для независимого SHA1/size доказательства. Никогда не хэширует mapped Gallery target для подтверждения собственного предположения. Если metadata-only дерево не содержит media, content hash просто недоступен. Ничего не пишется в исходник; на больших видео чтение может быть долгим. Symlink files/directories не читаются.

## Dry-run

```bash
# Offline: никакого обращения к production.
python3 tools/google-photos-albums/takeout_albums.py \
  --owner 00000000-0000-0000-0000-000000000001 \
  --takeout '/verified/metadata/Google Photos' \
  --inventory /verified/audit/inventory.json \
  --path-map /verified/audit/path-map.json \
  --output /verified/audit/new-dry-run.json
```

После будущего восстановления JSON и проверки path map на HP (не выполнять сейчас):

```bash
# API key своего owner должен уже находиться в GALLERY_TAKEOUT_API_KEY.
# Это только чтение Gallery; JSON/media на Synology не меняются.
python3 /opt/gallery-fork/tools/google-photos-albums/takeout_albums.py \
  --owner de9b2d19-cd6a-4b82-8230-33e17134a3bf \
  --takeout /mnt/hp-data/takeout-metadata/docice \
  --photos-root-confirmed \
  --server https://imm.lampax.top \
  --api-key-env GALLERY_TAKEOUT_API_KEY \
  --path-map /mnt/hp-data/takeout-audit/docice-path-map.json \
  --output /mnt/hp-data/takeout-audit/docice-dry-run.json
```

Это **предлагаемые отдельные audit/metadata locations**, не утверждение о существующих Synology mounts. Каталоги/output parent должны быть подготовлены владельцем отдельно; tool не создаёт дерево на NAS. При повторном запуске используйте новое audit filename или `--output -` (JSON в stdout). Существующий output не перезаписывается. Output запрещён внутри source metadata, mapped media roots и всех известных inventory media directories, а также вместо входного snapshot/ledger/path-map. Файл создаётся с ограниченными правами (0600). Mapping содержит личные filenames/paths/Google metadata; храните его как приватный аудит.

## Что доказывает parser

- Старые `{ "albumData": { ... } }` и новые top-level album metadata с `title`, `access` или `date` распознаются. `geoData` встречается и у альбомов, поэтому само по себе не означает photo sidecar.
- Title-only `metadata.json` новой схемы является **кандидатом** `REQUIRES_ALBUM_CONFIRMATION`: не считается доказанным альбомом и не увеличивает `albumsToCreate`.
- Произвольные директории и произвольный JSON с title не являются альбомами. Membership определяется direct sidecars этого подтверждённого album directory, не рекурсивно по unrelated subdirectories.
- Capture time — `photoTakenTime.timestamp`; `creationTime` не подменяет время съёмки.
- Полный Google title помогает при truncated `.supplemental-metadata.json`. Если export basename был изменён и доказательств недостаточно, результат остаётся AMBIGUOUS/MISSING.
- JSON-only suffix `(1)` нельзя без доказательств трактовать как base media или duplicate JSON. Неопределённая association остаётся AMBIGUOUS.
- Edited sidecar filename не сопоставляется с unedited original. JPEG и HEIC не считаются взаимозаменяемыми.
- Extension classification совпадает с текущими image/raw/HEIF/video sets `server/src/utils/mime-types.ts`, включая CR3/NEF/ARW/RAF, HIF/JXL, WMV/TS и другие server-supported types. Parser не декодирует и не конвертирует эти файлы. Test проверяет parity; при upstream изменении набора extensions нужно обновить standalone constants.
- Обычное видео остаётся обычным видео. Серверный `livePhotoVideoId` позволяет уверенно сопоставленный motion component представить членством существующего logical still asset; скрытый unlinked video никогда не добавляется как самостоятельный item. Ни формат Motion/Live, ни связь файлов не меняются.

## Confidence и воспроизводимость

| Результат       | Доказательства                                                                                                            |
| --------------- | ------------------------------------------------------------------------------------------------------------------------- |
| EXACT           | Единственное непротиворечивое совпадение owner/type + typed content hash, либо explicit path + capture time/size          |
| HIGH_CONFIDENCE | Единственное непротиворечивое совпадение owner/type + explicit path, либо original filename + capture time (до 1 секунды) |
| AMBIGUOUS       | Несколько равно сильных matches, недостаточные filename-only признаки или неопределённая indexed sidecar association      |
| MISSING         | Нет подходящего owner-scoped asset; upload не предлагается                                                                |

Path/hash EXACT превосходит более слабое filename+time совпадение; более слабые candidates остаются в evidence. Несколько одинаково EXACT assets, включая content duplicates, всегда AMBIGUOUS. Противоречия size/hash/capture time/dimensions отклоняют candidate; rotated dimensions допускаются. Trashed/offline/locked assets и unlinked hidden media исключены.

Mapping JSON сохраняет owner, source JSON provenance, source media/path, Google metadata, target asset, confidence/evidence, target albums, причины ambiguity/missing и diagnostics. Дубликаты records объединяются только по одинаковой доказуемой source association + metadata, сохраняя все source JSON. Один target asset допустим в нескольких albums; logical still+motion membership дедуплицируется. Summary `matches` считает metadata records, а `uniqueMatchedAssets` — уникальные existing assets.

Нет wall-clock timestamp и случайных IDs: одинаковые входы дают одинаковый JSON. Альбомам не придумываются order/cover. Unknown/malformed/unsupported records попадают в diagnostics; errors чтения директории прекращают сканирование, не создавая ложный полный отчёт. Непонятные records внутри album требуют review.

## Будущий idempotent apply: ещё не реализован

Gallery album DTO не содержит native Takeout source marker. Единственное надёжное связывание existing album — отдельный durable owner-scoped ledger; title-only reuse запрещён. Read-only пример:

```json
{
  "albumMappings": [
    {
      "albumId": "existing-album-id",
      "migrationKey": "google-takeout-album:<sha256-owner-and-relative-album-directory>",
      "ownerId": "00000000-0000-0000-0000-000000000001"
    }
  ],
  "ownerId": "00000000-0000-0000-0000-000000000001"
}
```

`--ledger` только читает этот файл; не создаёт и не обновляет его. Replay показывает лишь недостающие set memberships, без duplicate proposals. Будущий apply должен журналировать намерение/результат атомарно, проверять snapshot заново, использовать `POST /albums` и `PUT /albums/{id}/assets` только для одобренного owner, обрабатывать прерывание после API create, не выбирать AMBIGUOUS и не загружать MISSING. Перемещение/переименование album directories между различными экспортами меняет key и требует отдельного reconciliation; текущий dry-run не обещает идемпотентность реального apply, которого ещё нет.
