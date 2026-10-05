# Google Photos albums: read-only подготовка восстановления

Дата аудита: 2026-10-05. Репозиторий `docice545/gallery`, ветка `work`.
Это подготовка parser/matcher/dry-run для уже существующих assets, **не импорт
оригиналов и не production apply**. Google Takeout JSON сейчас отсутствуют на
Synology по сообщению владельца; отсутствие JSON не является ошибкой разработки.
Fixtures синтетические. Production, Synology и PostgreSQL из этой среды не
опрашивались и не изменялись.

## Что известно о HP, а что ещё требует read-only discovery

Подтверждённые владельцем пути: checkout `/mnt/hp-data/gallery-fork`, его bind
mount `/opt/gallery-fork`, Gradle `/mnt/hp-data/build-cache/gradle`, Pub
`/mnt/hp-data/build-cache/pub-cache`, Big-LaMa
`/mnt/hp-data/gallery-inpainting/models/big-lama.pt`, Gallery data
`/mnt/hp-data/immich/...`; Docker root остаётся на NVMe. Они не являются
подтверждением расположения **Synology External Library originals**. Не
переносить и не дублировать перечисленные данные.

В tracked-конфигурации fork нет фактического production NFS/CIFS mount,
`immich_server` volume mapping и списка External Libraries из production БД.
Поэтому точные Synology mount paths, import paths, library IDs и распределение
библиотек по владельцам пока **не установлены**. Нельзя подставлять выдуманные
`/volume1/...`, `/mnt/nas/...` или принимать Gallery upload directory за NAS.

Известны лишь предоставленные владельцем UUID, без привязки к конкретной
External Library:

| Пользователь | Явный owner scope                      |
| ------------ | -------------------------------------- |
| docice       | `de9b2d19-cd6a-4b82-8230-33e17134a3bf` |
| Lenia        | `47f6a3fc-75d9-4214-899f-8b4234eb8202` |
| chudo_anna   | `bb8ccc0b-9322-40ea-9ae5-672d497b3e01` |

Следующие команды предназначены владельцу HP, только для чтения; в Codex они
не выполнялись. Они не выводят полный Compose config, env контейнера или
credentials:

```bash
# Только точки монтирования сетевых файловых систем.
findmnt --types nfs,nfs4,cifs --output TARGET,SOURCE,FSTYPE

# Только selected Docker mounts: без Config.Env и токенов.
docker inspect --format '{{json .Mounts}}' immich_server |
  python3 -c 'import json,sys; print(json.dumps([{k:m.get(k) for k in ("Type","Source","Destination","RW")} for m in json.load(sys.stdin)],ensure_ascii=False,indent=2))'
```

Для библиотеки нужны `id`, `ownerId`, `name`, `importPaths`,
`exclusionPatterns` из **GET `/api/libraries`**. Endpoint требует admin и
`library.read` (`server/src/controllers/library.controller.ts`); обычный user
key не обязан его открывать. Не выдавать migrator admin/DB-доступ ради matching:
администратор может отдельно сохранить обезличенный manifest libraries,
а inventory assets получить ключом выбранного владельца. Не запускать
`POST /libraries/{id}/scan`, validate, rescan, reindex или jobs.

Важно различать четыре пространства путей:

1. Исходный relative path внутри Takeout.
2. HP host mount path на Synology.
3. Container `Destination` + относительный media path; именно он записан в
   Gallery `asset.originalPath`.
4. Отдельный read-only metadata root на SSD, если выбран изолированный restore.

Manifest должен связать их явно. Статический UUID пользователя не доказывает
ownership файлам, экспортам или библиотекам.

## External Library scanner и восстановление JSON рядом с media

Цепочка подтверждена в исходниках:

- `server/src/utils/mime-types.ts`: `getSupportedFileExtensions()` возвращает
  только image/video extensions. `.json` и `.xmp` в этом списке отсутствуют.
- `StorageRepository.asGlob()` строит `ROOT/**/*{supported extensions}`;
  `crawl()` и `walk()` используют case-insensitive fast-glob, только files.
  `LibraryService.handleSyncAll()` использует `walk()` с import paths и
  exclusion patterns.
- Library watcher add/change использует тот же список extensions. Добавленные
  `IMG.jpg.json`, `IMG.jpg.supplemental-metadata.json`, `metadata.json` и `.JSON`
  игнорируются этим matcher.
- `MetadataService.handleSidecarCheck()` ищет recorded sidecar, `IMG.jpg.xmp`
  и `IMG.xmp`. Google JSON не считается XMP, не меняет EXIF/date и не
  применяется к уже существующему media asset автоматически.
- Watcher **unlink** не фильтруется по extension: удаление JSON может вызвать
  `LibraryRemoveAsset` job. Handler ищет точный `(libraryId, originalPath)`;
  при отсутствии asset для JSON ничего не удаляет. Поэтому нулевая нагрузка
  и полное отсутствие технических events не обещаются.

**Вывод:** вернуть настоящие `.json` рядом с media допустимо относительно
семантики scanner: они не превращаются в assets, не запускают импорт
оригиналов и не применяют EXIF. Сохранять настоящую `.json` extension, не
преобразовывать JSON в `.xmp`, не переименовывать/заменять существующие media.
Filesystem traversal/watch всё равно видит больше directory entries; большие
объёмы JSON, SMB/NFS permissions и повреждённые mounts требуют проверки на HP.
Утверждать «полностью без ошибок/нагрузки» без физического HP невозможно.

Два regression tests в `server/src/repositories/storage.repository.spec.ts`
проверяют фактический fast-glob crawl и stream walk: JSON разных форматов и
регистров исключены, JPEG/HEIC/video остаются. Это тест scanner extension
filter, а не тест production Synology.

Для первой миграции **рекомендуется изолированный metadata root**, чтобы не
затрагивать наблюдаемое media дерево:

```text
/mnt/hp-data/takeout-metadata/docice/Takeout/<исходный Photos root>/...
/mnt/hp-data/takeout-metadata/lenia/Takeout/<исходный Photos root>/...
/mnt/hp-data/takeout-metadata/chudo_anna/Takeout/<исходный Photos root>/...
```

Это **новые плановые места для будущего восстановления пользователем**, не
существующие Synology mounts. Они не создавались автоматически. Не копировать
в них оригиналы фотографий, cache, checkout или модель. Tool читает JSON,
сопоставляет через explicit path-map с container `originalPath` inventory;
при изменённой структуре использует другие независимые признаки и сообщает
ambiguity, а не угадывает.

## Какие JSON восстановить

Восстановить все исходные Google Photos item sidecars для фотографий и видео:
`*.jpg.json`, `*.heic.json`, `*.mov.json`, `*.mp4.json`, а также новые
`*.supplemental-metadata.json`, их исходные truncated/(N) варианты. Для каждого
пользовательского album восстановить album metadata (`metadata.json` и
исторический metadata JSON с `albumData`, если он присутствует в экспорте) и
sidecars членов именно в его исходной директории.

Сохранить исходную структуру Google Photos root, album directories, year
directories, split exports и имена JSON. **Один item sidecar из year directory
не восстанавливает membership в пользовательских albums**: нужны также
sidecars/album metadata из соответствующих album directories. Один asset может
иметь несколько таких записей. Исходные filenames и relative paths — данные
для matching, не повод повторно создавать media.

Служебные JSON (print subscriptions, comments, memory titles и т.п.) можно
оставить в экспортном дереве для полного архивного набора; parser классифицирует
их отдельно и не превращает их directories в albums. Их перенос не является
обязательным для album memberships. Не восстанавливать JSON другого Google
Account внутрь metadata root выбранного владельца.

## Переиспользованный Gallery API и data model

Albums уже нативные. `album` хранит title/description/cover/date/order,
`album_user` хранит owner/editor/viewer, `album_asset` — membership с составным
primary key `(albumId, assetId)`. Один asset в нескольких albums поддерживается.
External Library asset не нужно копировать в upload storage.

| Операция                  | Native API/service                                       | Контракт                                                                           |
| ------------------------- | -------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Проверить identity        | `GET /api/users/me`                                      | `user.read`; id должен совпасть с явным owner                                      |
| Inventory                 | `POST /api/search/metadata`                              | Семантически read-only; `asset.read`, legacy flat filters и pagination             |
| Owned albums              | `GET /api/albums?isOwned=true`                           | `album.read`; проверить owner-role в `albumUsers`                                  |
| Album membership          | `GET /api/albums/{id}`                                   | `album.read`; `assets` присутствуют в расширенном get response                     |
| Будущее создание          | `POST /api/albums` → `AlbumService.create`               | `album.create`, `{albumName, description?, assetIds?}`; owner = authenticated user |
| Будущее добавление        | `PUT /api/albums/{id}/assets` → `AlbumService.addAssets` | `albumAsset.create`, `{ids:[existing UUIDs]}`; проверка `asset.share`              |
| Будущие cover/description | `PATCH /api/albums/{id}` → `AlbumService.update`         | `album.update`; cover должен уже входить в album                                   |

Точные string permissions брать из `server/src/enum.ts`; это не инструкция
выдать write scopes dry-run. В текущем tooling **write API не вызываются**.
Не использовать Stack API, Space contribution, share links, library mutations,
asset.update или asset.upload для восстановления личных album memberships.

Код: `server/src/controllers/album.controller.ts`,
`server/src/services/album.service.ts`, `server/src/dtos/album.dto.ts`,
`server/src/repositories/album.repository.ts`,
`server/src/schema/tables/{album,album-asset,album-user}.table.ts`.

В `addAssets` существующий membership возвращает `duplicate`, не создаёт новую
строку; repository также использует `ON CONFLICT DO NOTHING`. Будущий apply
должен считать подтверждённый duplicate уже выполненной операцией. Ошибки
`no_permission` не игнорировать.

## Inventory и устойчивые признаки matching

Read-only API adapter проверяет `/users/me`, затем страницы
`/search/metadata` с `ownerId`, `withExif:true`, `withDeleted:false`,
`isOffline:false`, `withSharedSpaces:false`, стабильным `order:'asc'`,
`page`/`size`. Ответ `assets.items` и `assets.nextPage`;
`assets.total` в этой версии не глобальный count, поэтому не использовать его
как признак полноты. Legacy shape сохраняет совместимость; dormant structured
V3 `filter/orderBy/cursor` здесь использовать нельзя.

Search может включать partner assets; даже scope-фильтр сервера не заменяет
проверку каждого `ownerId` в offline inventory/matcher. `ownerId` только
сужает доступный scope, не даёт администраторский доступ к другому пользователю.
Hidden motion video может присутствовать в inventory для проверки pair, но
не становится независимым обычным album item автоматически. Trashed/offline
и Locked assets не должны автоматически восстанавливаться миграцией.

Доступны `id`, `ownerId`, `libraryId` (deprecated nullable), `type`,
`originalPath`, `originalFileName`, `fileCreatedAt`, `localDateTime`,
`width/height`, `visibility`, `livePhotoVideoId`, `isTrashed`, `isOffline`,
`isEdited`; через `exifInfo`: `fileSizeInByte`, `exifImageWidth/Height`,
`dateTimeOriginal`, `timeZone`. JSON может не содержать size/dimensions/hash;
их отсутствие не заменять выдуманными значениями.

**Checksum ловушка:** API описывает `checksum` как Base64 SHA1, но для External
Library `LibraryService.processEntity()` вычисляет `SHA1('path:'+originalPath)`
и хранит `checksumAlgorithm=sha1Path`. `AssetResponseDto` не отдаёт этот
algorithm. Поэтому API checksum **не доказательство byte identity**; нельзя
сравнивать его с hash содержимого JSON/media или записывать как content hash.
Content matching разрешён лишь для отдельно подтверждённого typed content
checksum manifest или read-only streaming hash исходного media, без скачивания
оригиналов из server. Текущий dry-run не требует hashing всей библиотеки.
Если включён `--hash-media`, читаются только независимые source bytes под
metadata/Takeout root, если оригинал уже там существует; mapped Gallery target
не хешируется как доказательство самого себя. При JSON-only restore отсутствие
таких bytes нормально: checksum evidence не выдумывается.

Уже существует отдельный **GET
`/api/admin/users/{ownerId}/library-manifest`** (`adminUser.read`, admin).
`LibraryManifestService` отдаёт `manifestSchemaVersion=1`, owner, cursor,
owned albums и assets с `assetId`, `objectKey`, `size`, `checksumAlgorithm`
(`sha1` или `sha1-path`), timestamps и album IDs. Это пригодный typed offline
источник, если администратор уже экспортирует manifest; не нужна новая API
или прямая DB query. Он не содержит visibility/dimensions/Live pair, поэтому
обычный owner-scoped search inventory остаётся default и не повышает права.
Нельзя переименовывать `sha1-path` в content SHA1 при нормализации manifest.

Owner-scoped matcher использует explicit path-map, source/title/original name,
media type, capture timestamp и дополнительные реальные size/dimensions/hash
при наличии. Название одного файла никогда не достаточный критерий. Timestamp
`photoTakenTime` использовать как capture evidence; `creationTime` означает
время Google ingestion и не равно съёмке по умолчанию.

- `EXACT`: единственный кандидат с подтверждённым content identity либо
  mapped original path + capture timestamp (допуск одна секунда) или реальный
  size; согласованы type/owner, нет противоречий доступной metadata.
- `HIGH_CONFIDENCE`: единственный mapped original path без второго доступного
  доказательства либо original filename + type + capture time (одна секунда).
  Size/dimensions, когда доступны, дополнительно проверяются на противоречие.
- `AMBIGUOUS`: несколько кандидатов, противоречие или недостаточно evidence;
  target asset не выбирается случайно.
- `MISSING`: подходящего разрешённого существующего asset нет. Никакого upload.

Конкретные реализованные thresholds/reason strings описаны в
[`tools/google-photos-albums/README.md`](../tools/google-photos-albums/README.md).
HIGH_CONFIDENCE тоже требует просмотра mapping пользователем; AMBIGUOUS/MISSING
никогда не проходят автоматический apply. Отдельный owner scope обязателен,
missing/mismatched owner — fail closed. Дубликаты source records сохраняют
provenance; proposed membership — множество target asset IDs на album.
Inventory индексируется один раз по path/name/typed content hash, затем JSON
проверяется лишь против кандидатов индекса, а не всей библиотеки. Live component
может сопоставиться только с разрешённым owner-scoped still parent; offline,
trashed, Locked и непарный Hidden не являются разрешёнными целями.
Неразрешённый `(N)` в sidecar filename не сворачивается в unindexed original:
при JSON-only данных и без content identity результат AMBIGUOUS.

## Настоящий пользовательский album и пределы Takeout

Existing web importer (`google-takeout-parser.ts`, `scanner.ts`, `uploader.ts`)
уже знает legacy/new supplemental sidecars, `(N)`, truncated и edited names.
Но `detectAlbums()` использует directory names, а uploader **загружает media**.
Это не подходящий production migrator существующих assets: его upload/apply
flow не используется. Файлы web import не менялись ради этой задачи.

Новый offline parser требует доказательство album metadata и Photos root,
а не произвольной папки. Старый shape `{"albumData":{"title":...}}` и новый
top-level album metadata поддерживаются. Реальный Takeout 2025 может иметь
только `{"title":...}` в **album metadata file**: это учитывается только в
известном metadata context, не для arbitrary JSON c title.
Title-only record выводится как `REQUIRES_ALBUM_CONFIRMATION` и не увеличивает
`albumsToCreate`/подтверждённые memberships. Требуется ручная проверка, даже
если его media хорошо matched.
Media sidecar с `photoTakenTime`/media-specific fields не album. Year/service
directories отбрасываются независимо от наличия похожего title; неизвестные
форматы остаются UNKNOWN. Не угадывать локализованное имя служебной папки и не
превращать её автоматически в пользовательский album.

Known Google Photos subtrees выбираются отдельно от Gmail/Drive полного
Takeout. Неизвестное локализованное имя требует выбора проверенного
изолированного Photos root и явного `--photos-root-confirmed`; этот флаг нельзя
применять к смешанному Account export. Reserved year/service names —
консервативный фильтр: настоящий пользовательский album, специально названный
`2024`, `Archive` и т.п., тоже потребует ручного разбора/будущего explicit
classification override. Существование папки не доказывает user-created album.

Внешнее подтверждение shapes: open-source
[immich-go json.go](https://raw.githubusercontent.com/simulot/immich-go/main/adapters/googlePhotos/json.go) и
[json_test.go](https://raw.githubusercontent.com/simulot/immich-go/main/adapters/googlePhotos/json_test.go),
прочитаны 2026-10-05; это образцы форматов, не гарантия schema всех Takeout
поколений и не копирование importer-кода.

| Свойство                                                 | Реальная восстановимость                                                                                                                    |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| Album title/description                                  | 1:1, если явно присутствуют в album metadata; directory name не подмена отсутствующего title                                                |
| Membership                                               | 1:1 только при полном экспорте album records и однозначном matching existing assets                                                         |
| Один asset в нескольких albums                           | Нативно поддерживается, без duplicate assets                                                                                                |
| Capture date/EXIF/GPS originals                          | Не изменяются этой album migration; Google metadata остаётся evidence/mapping                                                               |
| Album creation date                                      | Только если Takeout поле доказуемо означает creation; `date` не автоматически такое доказательство                                          |
| Cover                                                    | Gallery поддерживает конкретный member asset UUID; Takeout часто не даёт cover identity. Без explicit evidence не угадывать                 |
| Порядок                                                  | Gallery имеет chronological `asc/desc`, а не произвольный per-membership ordinal. Takeout filesystem/JSON traversal не порядок Google album |
| Приблизительная сортировка                               | Только по существующей capture date; не выдавать за исходный manual order                                                                   |
| Shared access, комментарии, likes, collaborative authors | Не переносить автоматически между независимыми системами identities; raw JSON можно сохранить в mapping                                     |
| Google edits ↔ originals, HEIC ↔ JPEG                    | Не автоматически одинаковый asset: версии/форматы могут отличаться. Нужны evidence, иначе ambiguity                                         |
| Live/Motion связь                                        | Использовать существующий still `livePhotoVideoId`; не связывать/развязывать assets, не создавать hidden video заново                       |
| Неэкспортированные album memberships/потерянная metadata | Невосстановимо из имеющихся JSON без другого источника                                                                                      |

## Dry-run, audit mapping и будущая idempotency

Tool располагается в `tools/google-photos-albums/`: standard-library Python,
read-only metadata scan, owner-isolated matcher, deterministic JSON report и
mapping. Output directory должен находиться **вне** metadata/media roots.
Tool запрещает output внутри source root, mapped media prefixes и известных
original media directories inventory, а также перезапись snapshot/ledger/path
map или уже существующего report. Для HP использовать отдельный SSD audit
directory, а не любой Synology host path: неизвестные host mounts невозможно
восстановить только из container `originalPath`.
Snapshot/API inventory содержит только metadata, thumbnails/originals не
запрашиваются. JSON/content hashes используются для provenance, не для
загрузки или изменения файлов. Parser не запускает scanner/ML/reindex.

Report: Google albums found, albums to create/already matched, total
memberships, EXACT/HIGH_CONFIDENCE/AMBIGUOUS/MISSING, potential duplicates,
unsupported/unknown; по album — proposed target и те же счётчики. Mapping:
owner, source JSON/media path, raw Google metadata, proposed asset ID,
confidence/evidence/ambiguity/missing reasons, target album identities.
`matches` считает deduplicated metadata records; один asset в нескольких
albums имеет несколько source records. `uniqueMatchedAssets` отдельно считает
уникальные matched Gallery UUIDs. Неподтверждённые title-only album candidates
выделены отдельным счётчиком и не считаются готовыми к созданию albums.
Повторный run на том же snapshot/tree/config воспроизводим; live API страницы
во время изменений библиотеки не дают транзакционный snapshot, поэтому перед
будущим apply требуется свежая проверка всех matched UUIDs и ownership.

Native Album API **не имеет external generator/source ID или idempotency key**.
Одинаковое название легально для разных albums. Нельзя автоматически объявлять
первый album с таким title миграционным или править unrelated album.
Будущий apply обязан иметь durable локальный ledger: `(owner, export identity,
source album identity) → native album UUID`, состояния pending/created,
membership set и audit report. Existing album требует explicit reviewed
binding. Ledger не хранится в PostgreSQL и не заменяет исходное description
техническим маркером без отдельного решения.

Повторные memberships уже защищены native `(albumId,assetId)` uniqueness;
повторное **создание album** требует дополнительной crash recovery схемы.
Если POST успел, но UUID не записался, нельзя повторять POST вслепую:
ambiguous recovery останавливается для ручной проверки. Один active migrator
на owner; после перезапуска повторно проверить owner/album/membership через
API. Migration ledger + reviewed binding + native duplicate handling дают
план idempotency; текущий dry-run может проверять его offline, но production
apply и гарантия exactly-once album creation **ещё не реализованы**.

В части Takeout нет DB migration, native API changes, реальных albums или
публикации. Никакие внешние AI Memories/auto-stack, Motion cleanup, signing,
контейнеры, Synology originals или production networking не меняются.

## Следующий реальный шаг

1. Владелец сохраняет read-only discovery manifest и проверяет настоящий
   library owner + container media prefixes.
2. Восстанавливает только JSON в выбранный owner-specific metadata root с
   исходной структурой. Migrator ничего не восстанавливает/перемещает сам.
3. Готовит reviewed explicit path-map и read-only owner inventory/API key;
   ключ не помещается в аргументы CLI, Git или mapping.
4. Запускает только dry-run команду из финального отчёта/README.
5. Проверяет report и mapping; AMBIGUOUS/UNKNOWN требуют разбора. Никакого
   production apply до отдельного разрешения и реализации crash-safe ledger.
