# FOTO Build 17: backend compatibility with pinned stock clients

Дата проверки: 22.10.2026. База: `ace2eab962524479a61e6891410983a7f41ba0fa`,
`codex/foto-build17-unified`. Изменения: отдельная ветка
`codex/foto-build17-client-compat`; PR компактного редактора не изменяется.

**Результат:** выявленные B1–B7 исправлены и проверены на уровне backend и
контрактов. Полная готовность установленных Android/iOS/Web приложений
**NOT VERIFIED**. Это не релиз, не сертификат совместимости всех API и не
разрешение на deployment. Production и пользовательские медиа не использовались.

**Приёмка после публикации CLI-изменений:** PR #7 пока **BLOCKED**. На
`8759f9bd9c8f94adfdf8df81dc67b158aaddbf90` подтверждены SQL CI PASS и полный
medium CI **3447 PASS / 17 SKIPPED**, но OpenAPI enum gate остаётся красным,
а Dart codegen обнаружил новый синтаксический дефект. Это не отменяет прежние
backend passes и не является готовностью Android/iOS/Web. Подробности и границы
отдельной ветки приёмки приведены в конце документа.

**Итоговый B2:** возврат индекса online отслеживается узким server-only
`catalog_projection_audit`, а не сбросом при любых external updates. Обычный
library sync остаётся инкрементальным. Последняя проверка: 115/115 PostgreSQL,
12/12 cache cases, 74/74 SyncService unit и 6/6 contracts; наборы перекрываются.
Добавлена пятая additive migration `1796000000300-TrackCatalogIndexRecovery`.

## Источники и границы доказательств

Использован предыдущий анализ от 21.10.2026, а не новая предполагаемая версия
upstream. Закреплены:

| Клиент                               | Официальный источник                                                                                        | Commit                                     |
| ------------------------------------ | ----------------------------------------------------------------------------------------------------------- | ------------------------------------------ |
| Immich Android/iOS 3.3.5             | [immich-app/immich](https://github.com/immich-app/immich/tree/8303cb117e197c700332b33b61b45314c9cc5bb4)     | `8303cb117e197c700332b33b61b45314c9cc5bb4` |
| Noodle Gallery Android/iOS/Web 5.8.0 | [open-noodle/gallery](https://github.com/open-noodle/gallery/tree/37aa54e632606cc6a62bc6bcbba14c62200147c4) | `37aa54e632606cc6a62bc6bcbba14c62200147c4` |
| FOTO Android 5.7.3+17                | Mobile из объединённой базы этого PR                                                                        | `ace2eab962524479a61e6891410983a7f41ba0fa` |

Одинаковый mobile source не доказывает одинаковое поведение платформ. Версии
App Store/установленных IPA, Android APK и backend HP здесь не определялись.

- **PASS (backend)**: выполнен указанный unit/contract/PostgreSQL тест. Unit
  mocks не объявляются HTTP, filesystem или native E2E.
- **MATCH (source)**: сопоставлен фактически вызываемый контракт закреплённого
  клиента; исполнение приложения **NOT VERIFIED**.
- **NOT VERIFIED**: соответствующий runtime/устройство/инфраструктура не проверены.
- **FAIL → PASS** ниже относится к конкретному дефекту Bn, а не ко всему клиенту.

## Исправления относительно исходного отчёта

| Дефект                                                             | Изменение                                                                                                                                                                                                                                                       | Подтверждение                                                                                                                   |
| ------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| B1: version gate включает неизвестные sync types                   | Реализованы `AuthUsersV2`, `MemoriesV2`, `MemoryToAssetsV2`, `AssetFacesV3`, payload/ACK/feature declarations. V3 faces используют реальный cluster-group scope upstream; V2 остаётся owner-scoped. Неизвестные типы по-прежнему отклоняются                    | `sync.service.spec.ts`, `sync-client-compat.spec.ts`, pinned wire-schema contracts: PASS                                        |
| B2: offline index отображается как user Trash                      | Active + non-null deletedAt исключены из asset и зависимых FK streams. При изменении уже закэшированного индекса сервер выдаёт `SyncReset`, не `AssetDelete` и не фальшивый active asset. Настоящий Trash сохраняется                                           | PostgreSQL client-compat, album/partner/space/library sync regression: PASS                                                     |
| B3: >200 legacy force-delete создаёт batch и возвращает ложный 409 | Только legacy `DELETE /assets` ожидает завершения существующего guarded permanent-delete пути. FOTO batch API сохранён. Проверка всех прав выполняется до destructive stage. Реальная ошибка всё ещё даёт ошибку                                                | Unit границы 199/200/201/1000, no-access/no-side-effect и partial failure: PASS; реальные 1000 файлов на NAS NOT VERIFIED       |
| B4: Memory links переживают скрытый parent                         | Official projection согласованно фильтрует fork rule parents и links; пропущенный parent подтверждается ACK. Fork-aware streams сохраняют rule memories                                                                                                         | Unit и PostgreSQL V1/V2, повторный sync без повторов: PASS                                                                      |
| B5: official client не знает trim enum                             | Только official sync projection пропускает trim с ACK. Persisted edit и rendered video не изменяются; Noodle/FOTO получают trim                                                                                                                                 | Unit и PostgreSQL: PASS                                                                                                         |
| B6: shared favorite меняет чужое избранное                         | Canonical `PUT /assets/favorites`, overlay `(userId, assetId)`, caller projection в detail/search/timeline и asset sync. Owner column сохранён и зеркалируется транзакционно/триггером для старого FOTO. Anonymous shared links не наследуют favorite владельца | Unit, реальные PostgreSQL favorites/search/timeline, concurrency/revocation/backfill: PASS                                      |
| B7: stock Noodle Web получает 404                                  | Добавлены editable и шесть shared-space face routes с upstream-compatible DTO/roles, transactional projection и provenance `createdBy`                                                                                                                          | Controller forwarding unit, face geometry unit, PostgreSQL role/foreign-asset/legacy-face tests: PASS; browser E2E NOT VERIFIED |

### Версия и sync

Не подставляется фиктивная версия сервера. Source `server/package.json` и OpenAPI
по-прежнему `3.2.0`; release branding может объявлять продуктовую `5.7.3`.
Исправлен реальный protocol набор, выбираемый Immich 3.3.5 при объявленной
версии >=3.3, включая branded 5.7.3. Старые version/capability gates Noodle и
FOTO не понижаются. Объявленные sync types реализованы; это **не** заявление
о поддержке всех будущих API Immich.

### Offline indexes и конкурентный sync

Фильтр не переводит индексы в Trash, не удаляет строки/оригиналы и не отправляет
stock-клиенту событие удаления, которое могло бы запустить native cleanup.
Все FK-проекции для исключённого asset также исключены.
Watermark `nowId` снимается **до** invalidation lookup: изменение между lookup
и streaming остаётся после complete ACK и обнаруживается следующим запросом.
Это проверено fault injection на реальном PostgreSQL, не только mock.

Однократная миграция выставляет reset flag уже синхронизировавшимся sessions.
Последующие index invalidations консервативно глобальны: возможен лишний полный
resync другого пользователя; reset не содержит чужих ID. Нагрузочные измерения
на большой HP-медиатеке не выполнялись. Для старого FOTO без AssetFavoritesV1
caller-specific non-owner favorite change также обновляет cache через reset.

### Избранное и сохранность данных

Canonical favorites требуют AssetRead и аутентифицированного субъекта. Legacy
update/updateAll сохраняют прежний AssetUpdate guard; пользовательские данные
не становятся изменяемыми за счёт favorite. Canonical owner writes и старый
owner column согласованы в одной транзакции; non-owner writes не меняют ни
owner flag, ни asset updateId. Новое избранное не выдаёт право читать asset:
после отзыва membership он исчезает из timeline даже при сохранённом overlay.

Проверена точная комбинация параметров страницы Favorites Noodle Web 5.8.0:
`isFavorite=true, withStacked=true, withPartners=true, withSharedSpaces=true,
visibility=timeline`. Снята только несовместимая favorite-проверка; запреты
просмотра чужого Trash/Archive/Locked сохранены.

### Shared-space faces

Перенесены необходимые upstream методы, а не весь новый SharedSpaceService.
Editor/Owner и reachable asset проверяются до изменений. Space face assignment
и verdict записываются в transaction; персональная owner-разметка пользователя,
который не состоит в space, не переписывается attach/detach операциями. Старый face с `createdBy=NULL` не считается созданным
редактором только по `sourceType=manual` и не удаляется новым route.
Drawing требует проверяемых original dimensions, preview geometry преобразуется
существующим алгоритмом. Это metadata операции, не удаление media originals.

## Матрицы после исправлений

### Официальный Immich Android 3.3.5

| Функция                                | Результат и доказательство                                                                                       |
| -------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Auth/OAuth, upload/backup API          | MATCH (source); прежние operations/schemas сохранены; foreground/background device E2E NOT VERIFIED              |
| Sync/version/ACK                       | PASS (backend): B1, four version-selected types, nullable OAuth V2, cluster V3                                   |
| Albums/sharing/search                  | MATCH (source); related FK projection regressions PASS; app E2E NOT VERIFIED                                     |
| Favorites                              | PASS (backend): legacy owner path сохранён, personal overlay не меняет другого owner                             |
| People/faces                           | PASS (backend) V2/V3 scope; ML inference E2E NOT VERIFIED                                                        |
| Memories/trim                          | PASS (backend) B4/B5, неотображаемые fork types не создают dangling link                                         |
| Media/Live Photos/HEIC/video           | MATCH (source); unchanged media/storage guards + 477 regression checks PASS; device codecs/парность NOT VERIFIED |
| Trash/restore/indexes                  | PASS (backend) B2; реальная Android OS confirmation/local-library reconciliation NOT VERIFIED                    |
| Permanent >200                         | PASS (unit) B3; guarded synthetic deletion regression PASS; stock APK → NAS E2E NOT VERIFIED                     |
| Network interruption/native background | NOT VERIFIED                                                                                                     |

### Официальный Immich iOS 3.3.5

| Функция                                           | Результат и доказательство                                                                           |
| ------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Auth/OAuth/upload wire API                        | MATCH (source), backend operations сохранены; запуск IPA NOT VERIFIED                                |
| Sync/version/ACK                                  | PASS (backend) B1 на общем wire contract; iOS local DB execution NOT VERIFIED                        |
| Albums/favorites/search/sharing                   | MATCH (source), personal favorite backend tests PASS; iPhone UI NOT VERIFIED                         |
| People/Memories/trim                              | PASS (backend) B4/B5 и V3 projection; native execution/ML NOT VERIFIED                               |
| Trash/restore/permanent                           | PASS (backend/unit) B2/B3; iOS → backend → NAS E2E NOT VERIFIED                                      |
| PhotoKit/ограниченный доступ/Save to Photos       | NOT VERIFIED: требуется физическое устройство и реальные разрешения                                  |
| iCloud-only assets, HEIC/HEIF, video, Live Photos | MATCH (source) multipart/association APIs; native export/download/re-pairing/codecs NOT VERIFIED     |
| Background upload                                 | NOT VERIFIED: BGTaskScheduler/URLSession, lock/low-power/termination нельзя доказать Android-тестами |
| Смена сети, offline retry, app restart            | NOT VERIFIED на iPhone                                                                               |

### Оригинальный Noodle Android 5.8.0

| Функция                             | Результат и доказательство                                                                                        |
| ----------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| Auth/upload/backup, albums          | MATCH (source); unchanged base operations; stock APK E2E NOT VERIFIED                                             |
| Capability sync                     | PASS (backend): старые streams сохранены, новые types additive                                                    |
| Index vs Trash/restore              | PASS (backend) B2; physical Android media-library behavior NOT VERIFIED                                           |
| Favorite                            | PASS (backend): canonical personal write/read и старый editor fallback. Legacy AssetUpdate restriction не отменён |
| Search/people/Memories/trim         | MATCH (source), fork-aware rule/trim regressions PASS; AI/device E2E NOT VERIFIED                                 |
| Media/Live Photos/video             | MATCH (source); filesystem regression PASS; Android decoding/background NOT VERIFIED                              |
| Permanent/Empty Trash               | PASS (unit/backend) B3 и existing guarded regression; owner policy по-прежнему обязательна                        |
| Local device deletion/network retry | NOT VERIFIED на устройстве                                                                                        |

### Оригинальный Noodle iOS 5.8.0

| Функция                                      | Результат и доказательство                                                                        |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Auth/upload wire API/album/sync              | MATCH (source), targeted backend projection tests PASS; iOS runtime NOT VERIFIED                  |
| Favorite/search/people/Memories              | PASS (backend) целевые B4/B6; исходные Noodle rule semantics сохранены; native UI/ML NOT VERIFIED |
| Trash/restore/permanent                      | PASS (backend/unit) B2/B3; iPhone/NAS E2E NOT VERIFIED                                            |
| PhotoKit permissions/iCloud/HEIC/Live Photos | NOT VERIFIED; наличие iOS source не считается выполненным тестом                                  |
| Фоновый backup/плохая сеть/restart           | NOT VERIFIED на iOS; не приписываются результаты Android                                          |

### Оригинальный Noodle Web 5.8.0

| Функция                         | Результат и доказательство                                                                                       |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Auth/owner assets/upload/albums | MATCH (source); исходные operation definitions сохранены                                                         |
| Favorites page                  | PASS (real PostgreSQL service): canonical write, caller filter, точные stock flags, owner isolation и revocation |
| Editable IDs                    | PASS (unit/contract): существующий permission subset, без нового права записи                                    |
| Shared-space people/face routes | PASS (controller unit + real PostgreSQL): B7, roles, geometry, existing face protection                          |
| Search/people/Memories/media    | MATCH (source); related regression PASS; browser/codec/AI E2E NOT VERIFIED                                       |
| Trash/restore/permanent >200    | PASS (targeted backend), browser API-to-storage E2E NOT VERIFIED                                                 |
| Whole frontend execution        | NOT VERIFIED: немодифицированный Web в браузере не запускался                                                    |

### Наш FOTO Android Build 17

| Функция                                 | Результат и доказательство                                                                      |
| --------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Все прежние API definitions/DTO         | PASS (contract): 403 base operations, все прежние schemas, кроме additive sync enums, сохранены |
| Fork streams/rule Memories/trim         | PASS (unit/PostgreSQL); используются прежние feature gates                                      |
| Favorite across sessions/old FOTO       | PASS (PostgreSQL): owner column mirror, shared overlay и legacy cache reset                     |
| Upload/duplicates/external libraries    | PASS (477 targeted unit + preserved PG regressions); real backup/sync device E2E NOT VERIFIED   |
| Trash/restore/guarded physical deletion | PASS (synthetic regressions), production NAS and installed APK NOT VERIFIED                     |
| Editor/AI/native device copy deletion   | NOT VERIFIED в этой задаче; source clients и PR #6 не изменены                                  |

## OpenAPI и оставшаяся неполнота upstream REST

Generated spec: **411 операций** против 403 в базе. Ни один существующий
method/path/operation definition не удалён и не изменён. Existing schemas
сохранены, кроме расширения двух sync enum. Generated TypeScript SDK обновлён;
typecheck выполнен. Пин wire shapes Immich хранится в
`server/test/contracts/immich-3.3.5-sync-shapes.json`, fingerprint базы —
`server/test/contracts/foto17-base-api.json`.

Добавлены восемь canonical operations: `updateAssetFavorites`,
`getEditableAssets`, `createSpacePerson`, `attachSpacePersonFace`,
`detachSpacePersonFace`, `getSpaceAssetFaces`, `createSpaceAssetFace`,
`deleteSpaceAssetFace`.

Совпадают **379/382** method/path Noodle 5.8.0. Три `/people/users` операции
`getUsersForPeople`, `upsertPeopleUsers`, `removeUsersFromPeople` остаются
отсутствующими. Поиск каждого operation ID в закреплённых `web/src` и
`mobile/lib` Noodle 5.8.0 не обнаружил callers; это SDK-only остаток этого
сравнения, **не полная REST parity**. Из 279 Immich 3.3.5 operations исходно
совпали 268; оставшиеся cluster-group/people-user management APIs также не
реализованы этим PR. Не заявляется поддержка произвольных API consumers.

## Миграции и deployment boundaries

Добавлены/адаптированы:

1. `1794000000000-AddAssetFavoriteTables` — upstream table/audit/backfill,
   без удаления старого owner column.
2. `1796000000000-AddAssetFaceCreatedBy` — nullable actor provenance старых faces.
3. `1796000000100-ResetCatalogSyncProjection` — только session reset flags.
4. `1796000000200-MirrorOwnerFavorites` — mirror function/trigger, declarative
   schema metadata и migration overrides согласованы.

Runtime `allowUnorderedMigrations` и compatibility aliases сохранены.
Проверена настоящая `DatabaseRepository.runMigrations()` на заполненной
синтетической pre-extension БД, включая interleaved migration. Проверены нулевой
schema drift, сохранность IDs/paths/checksums/updateIds/albums/favorites/old face
provenance/offline status. Это **не восстановленная production БД**.

Простой возврат старого image может быть несовместим с новыми migration names
и schema metadata. Для будущего выпуска нужен reviewed rollback image, который
знает эти миграции, либо отдельно проверенный backup/restore plan. `down()` в
изолированном тесте использован только для создания fixture, не является
доказательством безопасного production downgrade. Не удалять overlay-таблицы
для обхода проверки. В этом PR нет deployment/rollback запуска.

## Фактически выполненные проверки

Команды запускались последовательно. `vitest` везде с
`--maxWorkers=1 --no-file-parallelism`; пути ниже относительно `server/`.
В таблице нет суммы уникальных тестов: несколько целевых запусков перекрываются.

| Проверка / сохранённый log                                                                                 | Результат                                                                      |
| ---------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| Initial AssetService + SyncService (`foto-compat-services-tests3.log`)                                     | 306 PASS                                                                       |
| Initial PG sync (`foto-compat-medium.log`)                                                                 | 37 PASS                                                                        |
| Favorite/controller unit (`foto-compat-favorite-unit2.log`)                                                | 360 PASS                                                                       |
| Combined targeted unit (`foto-compat-targeted-unit-final.log`)                                             | 1288 completed; **FAIL run: worker OOM** при 3 GiB, не объявляется полным PASS |
| SharedSpaceService chunks 221/220/220                                                                      | 661 PASS; ранее сохранённый результат                                          |
| SharedSpaceService полный изолированный rerun (`foto-compat-sharedspace-full.log/json`)                    | **661/661 PASS**, exit 0, heap 6144 MiB, 12.71 s, max child RSS 3,621,288 KiB  |
| SharedSpaceController (`foto-compat-space-http-unit.log`)                                                  | 34 PASS; controller mocks, не HTTP E2E                                         |
| Final SyncService + TimelineService (`foto-compat-final-sync-timeline-unit.log`)                           | 171 PASS                                                                       |
| Search/DTO/contracts (`foto-compat-contract-tests.log`)                                                    | 231 PASS                                                                       |
| AssetMedia/Library/Duplicate/AssetRepo/deletion filesystem/recovery (`foto-compat-storage-unit-final.log`) | 477 PASS                                                                       |
| Face geometry (`foto-compat-facebox-unit-final.log`)                                                       | 3 PASS                                                                         |
| PG regression 10 files (`foto-compat-regression-medium.log`)                                               | **333 PASS / 12 existing SKIPPED**, не переисполнялись без причины             |
| PG new routes/schema drift (`foto-compat-new-routes-medium-final.log`)                                     | 9 PASS                                                                         |
| PG client compatibility + favorites/cache (`foto-compat-final-cache-medium.log`)                           | 14 PASS                                                                        |
| PG stock Web favorites flags (`foto-compat-favorites-timeline-medium-exact-final.log`)                     | 1 PASS                                                                         |
| PG shared personal search (`foto-compat-personal-search-medium-final.log`)                                 | 1 selected PASS                                                                |
| PG actual runtime populated-schema upgrade (`foto-compat-upgrade-medium-final.log`)                        | 1 PASS                                                                         |
| Final regenerated contracts + exact stock flags (`foto-compat-final-contract-unit.log`)                    | 7 selected PASS; 96 filtered out, не новые skips                               |
| ESLint zero warnings / TypeScript / generated SDK types / Prettier                                         | PASS (`foto-compat-final-codechecks.json`)                                     |
| Nest compile / migration copy / preview-mode OpenAPI generation                                            | PASS, 77 fork migrations и 2 compatibility aliases                             |
| PG partner personal favorite backfill/incremental (`foto-compat-partner-favorites-medium-final.log`)       | 1 selected PASS; остальные 5 уже PASS до коррекции fixture                     |

Полный SharedSpaceService содержит 661 тест и создаёт набор repository automocks
в каждом `beforeEach`. Failed worker дошёл до V8 heap limit 3 GiB, а не до
доказанного system OOM. В Cloud доступно 32 GiB; изолированный запуск с 6 GiB
heap прошёл. Измерен RSS, но heap-retainer профиль/отсутствие утечек **не
доказаны**. Увеличение heap — параметр конкретной Cloud команды, не изменение
HP/systemd или repository limits. Остальные успешные тяжёлые наборы не
повторялись ради искусственного общего зелёного числа.

Два новых fixture сначала были некорректны: пустой EXIF upsert и отсутствие
partner asset watermark не исполняли заявленный сценарий. Исправлены входные
данные и повторены только соответствующие проверки. Float geometry assertion
проверяет точность до 8 знаков; production rounding не менялся. Ничего не
помечено PASS на основании пропуска теста.

Среда: Node 24.19.0 (repo pin 24.21.0), Vitest 4.1.11, cached pnpm dependencies,
oazapfts 7.5.0. Только disposable PostgreSQL 14 testcontainers:
`ghcr.io/immich-app/postgres:14-vectorchord0.4.3@sha256:dbf18b3ffea4a81434c65b71e20d27203baf903a0275f4341e4c16dfd901fd67`.
Использован локальный cloud Docker socket, не HP. Medium fixture отключает fsync
БД ради тестов; он **не** доказывает production crash durability PostgreSQL.

### Повторение только нужного сценария

```bash
# Из server/, после штатной установки закреплённых workspace dependencies.
NODE_OPTIONS=--max-old-space-size=6144 pnpm exec vitest \
  --config test/vitest.config.mjs run src/services/shared-space.service.spec.ts \
  --maxWorkers=1 --no-file-parallelism

NODE_OPTIONS=--max-old-space-size=4096 pnpm exec vitest \
  --config test/vitest.config.mjs run \
  src/services/sync.service.spec.ts src/services/timeline.service.spec.ts \
  src/utils/client-contracts.spec.ts --maxWorkers=1 --no-file-parallelism

# Только отдельный локальный Docker/testcontainers, никогда production DB URL.
NODE_OPTIONS=--max-old-space-size=4096 pnpm exec vitest \
  --config test/vitest.config.medium.mjs run \
  test/medium/specs/sync/sync-client-compat.spec.ts \
  test/medium/specs/sync/sync-personal-favorites-compat.spec.ts \
  test/medium/specs/services/noodle-space-faces-compat.spec.ts \
  test/medium/specs/services/noodle-favorites-timeline-compat.spec.ts \
  test/medium/specs/migrations/client-compat-preservation.spec.ts \
  --maxWorkers=1 --no-file-parallelism
```

## Остаточные ограничения

- Реальный Synology NFS, телефоны Android/iOS, Apple Photos/iCloud, браузер stock
  Web и AI/ML sidecars **NOT VERIFIED**. Нет нового APK/IPA/image.
- Большие legacy запросы корректно ждут guarded result, но могут превысить timeout
  proxy на медленном NAS. Повтор безопасен через существующие receipts; не
  подменять timeout успешным удалением.
- Политики владельца, root/recovery/physical identity checks, external read-only
  default, запрет автоматического retention и duplicate/checksum semantics
  сохранены. Stock клиент может получить реальный policy refusal; это не повод
  обходить защиту ради совместимости.
- Fork-only rule memories не превращаются в официальный birthday/on-this-day.
  Нет создания фиктивных memories или повторного анализа production Memories.
- Доказательство совместимости реального обновления HP и reviewed rollback
  остаётся за отдельной изолированной release-проверкой. Этот PR не запускает
  старые deletion intents и не меняет queues.
- Dart-клиенты оригинальных приложений не модифицировались/не регенерировались;
  совместимость проверяется серверными wire fixtures. Native E2E обязателен
  перед заявлением о полностью готовом продукте.

Машиночитаемые результаты, method/path comparison и SHA-256 неизменённых
защитных исходников: [results.json](2026-10-22-stock-client-compatibility-results.json).
Последний проверенный code commit:
`ab7f0217eb84668576b2035ee19a52daf1003572`. После первоначального 57006e191
исправлены explicit medium fixtures и schema metadata/generation; storage guard
functions, применённые миграции и media workflows не изменены. Отчёты не заменяют native E2E.

Итог: конкретные backend блокеры B1–B7 закрыты целевыми проверками. Не выявлено
нового blocker в рассмотренных caller paths; полная эксплуатационная
совместимость Android/iOS/Web и production rollout **NOT VERIFIED**.

## GitHub CI: состояние не скрывается

PR: [docice545/gallery/pull/7](https://github.com/docice545/gallery/pull/7).
Первый опубликованный HEAD `d82dc7bc5` **не получил зелёный общий CI**:

- Medium CI обнаружил отсутствующий `AssetFavoriteRepository` в прежних explicit
  fixtures `AssetService`. Добавлен реальный repository в два таких набора и
  StackService fixture, вызывающий AssetService. Assertions не ослаблены.
  Локальный запуск: два файла PASS (56 тестов); stack после исправления —
  8/8 PASS. Первый смешанный запуск 63 PASS/1 FAIL сохранён как failed run,
  а не выдан за полное прохождение.
- `check-openapi` сравнивает с `main`, хотя base этого PR — unified. Аннотации
  содержат шесть добавленных response enum значений в `GET /sync/ack` и четыре
  предупреждения об `AssetDeleteBatch`, уже присутствующем в нашей base.
  Pinned baseline contracts доказывают сохранение прежних operation definitions,
  но **не отменяют** этот gate. Новые sync enums выданы только в соответствующих
  запрошенных streams; ACK API возвращает checkpoints текущей session. В
  закреплённых stock Web/mobile исходниках не найдены callers `getSyncAck`.
  Полная REST parity и произвольные сторонние ACK consumers не заявляются.
  Требуется review этого additive protocol extension; правило не отключено.
- Общий server format локально воспроизводит FAIL в двух **неизменённых от base**
  файлах: `src/schema/migrations-gallery/1793400000000-FixMemoryCandidateSchema.ts`
  и `src/utils/recovery-evidence.spec.ts`. Все изменённые файлы проходят формат,
  lint и typecheck. Старые миграции ради общего форматирования не переписаны.
- ShellCheck и Dart analysis тоже завершились ошибкой. GitHub annotations содержат
  только exit 1/3; полные job logs возвращают `Forbidden` при загрузке из Azure
  Actions storage, в том числе после повторной попытки с разрешением. Точная
  причина этих двух jobs **NOT VERIFIED**, не объявлена автоматически ошибкой base.
- Недостающая changelog label добавлена через API (`changelog:enhancement`).
- Автоматически запущенные PR workflows `Docker` и `Build Mobile` отменены:
  сборка образа/APK и подпись вне этой задачи. Production не изменялся.

Новые изменённые fixtures проверены отдельно; успешно пройденные тяжёлые наборы
не перезапускались. Статус общего CI нужно читать отдельно от целевых backend
PASS. **PR не следует объединять, считая общий CI или native E2E завершёнными.**

### Доработка связанных generated gates

После предыдущего CI проверены и исправлены ещё два воспроизводимых дефекта:

1. **OpenAPI Clients reproducibility.** Pipeline генерировал raw JSON/TypeScript,
   а сохранённые файлы были отформатированы. В существующие `mise` tasks добавлен
   штатный Prettier после генерации spec и SDK, без изменения семантики контрактов.
   Две последовательные генерации точных subcommands дали **нулевой diff**:
   spec SHA-256 `12b0dd2cdb19a71344de79335a75e3d3c7a9ba0a9e4968cf4f32c0b43803c243`,
   SDK SHA-256 `f014a9f7cf92e71d618a49f9f0b745f4279f538ef8f3063d98141e21845a0a4f`.
   `mise` executable в Cloud отсутствует: выполнены его Node/formatter/oazapfts
   subcommands, TOML разобран штатным parser. Контрактный rerun: **6/6 PASS**.
2. **SQL Schema Checks.** Строгий migration CLI, в отличие от runtime drift
   check, предлагал `DROP TRIGGER` для `gallery_block_deleted_asset` и
   `gallery_lock_asset_file_path`. Это существующие migration-owned `UPDATE OF`
   guards; sql-tools не умеет моделировать список колонок trigger event. Их
   имена теперь зарегистрированы в schema metadata с `synchronize:false`.
   Это **не отключение триггеров PostgreSQL** и не изменение старой миграции:
   существующий DDL сохраняется. Новая независимая PostgreSQL-проверка требует
   оба exact `pg_get_triggerdef`, `tgenabled='O'`, нулевой строгий CLI diff и
   отсутствие SQL на изменение guards. **2/2 PASS**. Широкий `ignoreExtra`
   в CLI не добавлялся; DDL не подменялся новым менее строгим триггером.
3. SQL snapshots обновлены штатным `dist/bin/sync-sql.js` против только временной
   migrated PostgreSQL. Девять файлов отражают текущие repositories, в том числе
   ранее не обновлённые base duplicateId/library-sync/memory queries. Это
   generated documentation, не запуск очередей или новых production запросов.
   Generator exit 0 не считается успешным исполнением всех dummy SQL: его
   ожидаемые FK/no-result diagnostics не скрываются.

Новые schema files/test проходят ESLint (0 warnings), TypeScript и Nest compile;
77 fork migrations и 2 aliases по-прежнему копируются. Никакая проверка CI не
отключена. GitHub-run на последнем опубликованном code ещё не считается PASS
по результатам этих локальных проверок. Остальные перечисленные CI/native
ограничения сохраняются до фактического результата.

### Завершение explicit RBAC/migration fixtures

Завершившийся medium CI на предыдущем HEAD показал ещё девять вызовов SearchService
без favorite dependency в `people-identity-rbac` и устаревшее предположение о
последней миграции. Search fixture теперь использует реальный favorites repository.
Совместный локальный запуск RBAC и migration scenarios: **90 PASS / 1 FAIL**;
оставшийся rollback fixture после уточнения — **1 selected PASS / 6 filtered**.
Эти два результата не объявляются единым зелёным CI запуском.

Rollback fixture теперь строит **пустую БД старой storage-mode boundary** реальными
миграциями, исключая позднее добавленный (но interleaved по timestamp) favorite
overlay. Затем, как прежде, проверяет отказ в откате BindDeletionRecovery и
сохранность journal/policy columns. Он не удаляет новые пользовательские favorite
данные, не отключает rollback guard и не заменяет отдельную проверку upgrade со
**всеми** актуальными миграциями. Совместимость latest production downgrade всё
ещё NOT VERIFIED. Оба изменённых файла прошли ESLint и TypeScript.

### Подтверждённый GitHub результат и финальный codegen context

- **SQL Schema Checks PASS в GitHub** на `3194ced8f`: [job 119715287262](https://github.com/docice545/gallery/actions/runs/39746061469/job/119715287262).
  Сам job/status проверен API; это дополнение к локальным проверкам, не inference
  из unit mocks. Миграции/reset/schema comparison/SQL snapshots прошли.
- OpenAPI Clients на том HEAD ещё FAIL. Добавленная ограниченная annotation
  публичного generated diff выявила **raw, неотформатированный spec**. Причина:
  `server/.prettierignore` содержит `*.json`; ранняя проверка из корня не
  воспроизводила этот cwd. Первый formatter fix был неполон.
- Финальные commands используют явный JSON config и empty ignore path для
  конкретного generated spec. SDK получил собственный config, сохраняющий
  существующие single quotes/80 columns. Глобальные ignore rules и проверка
  diff/exit 1 не отключены. **Две генерации из реальных cwd `server/` и root
  прошли с теми же двумя SHA-256; файлы spec и SDK остались побайтно прежними.**
  Старое root-only reproduction не используется как доказательство исправления
  cwd-проблемы. Новый результат: `foto-compat-codegen-exact-cwd.json`.
- Последний codegen context проверен в `923d89de6`; его GitHub rerun до получения
  фактического результата не объявляется успешным. Native E2E и прочие общие
  CI-ограничения выше сохраняются.

### Промежуточная проверка восстановления индекса (широкий вариант отклонён)

**OpenAPI Clients и SQL Schema Checks PASS в GitHub на `44008b276`**.
Это реальный результат jobs, включая Dart generation/nullable-array test в
первом и migration/reset/schema/SQL generation во втором, не только локальная
проверка эквивалентных команд. App/native E2E этим не подтверждается.

Полный medium job выявил следующие дополнительные случаи:

- Shared-space Trash fixture ставил только deletedAt, оставляя статус Active:
  это определение offline index, а не пользовательского Trash. Helper теперь
  устанавливает настоящий `AssetStatus.Trashed`. Все прежние проверки запрета
  backfill EXIF/GPS и доставки owner/convergence metadata сохранены.
- Negative timeline tests сохранены (Archive/Trash/Locked/неявный scope по-прежнему
  запрещены), обновлён только текст сообщения после легального personal favorite.
- AlbumUser ordering fixture разделяет owner/editor creation двумя миллисекундами:
  UUID-v7 в одном миллисекундном интервале не гарантирует ожидаемый тестом порядок.
  Assertions порядка и ролей не заменены игнорирующим порядок сравнением.

Новый поведенческий regression воспроизвёл отдельный B2 recovery defect:
после advanced EXIF/link ACKs внешний index возвращался online, но выдавался
только AssetV2, без прежних EXIF и album links (их собственные updateIds не
изменились). Invalidation теперь консервативно учитывает изменения active external
assets (`libraryId`/`isExternal`) и восстанавливает cache relations при повторном
полном sync. Тест проверяет прежние ID и наличие asset/EXIF/album link, допускает
корректный incremental или reset путь, не требует внутреннюю реализацию ради PASS.

Tradeoff: metadata/new-asset изменения внешних библиотек тоже могут вызвать
глобальный cache reset. Managed uploads остаются incremental. Это не меняет
строки каталога, связи, файлы или permissions, но стоимость лишних resync на
большой реальной NAS-медиатеке **NOT VERIFIED**.

Целевой PostgreSQL rerun всех четырёх затронутых файлов: **76/76 PASS**
(`foto-compat-medium-ci-convergence-final.log`). Включены index return, прежний
invalidation race, album membership, true Trash и timeline проверки. Новый
valid failing-before log: `foto-compat-index-return-regression-before-anchors.log`.
ESLint, TypeScript и Nest compile после исправления PASS. Ранее успешные 333/12,
477 и 661 заново не исполнялись.

### Итоговый узкий журнал восстановления индекса

Широкий external-update reset был отклонён после отдельного необходимого rerun:
**8 FAIL / 27 PASS** в прежних library tests. Assertions не ослаблены для принятия
reset вместо обязательного incremental результата.

Итоговая migration `1796000000300-TrackCatalogIndexRecovery` создаёт только
маленький operational cache audit (`id`, timestamp), без asset/owner/path данных.
AFTER UPDATE trigger пишет событие только при **выходе из Active + deletedAt**.
При входе используется существующий current-index invalidation. При возврате
online журнал сохраняет событие, когда текущая строка уже перестала быть index.
Sync проверяет этот журнал по обычному UUID-v7 watermark, выдаёт `SyncReset` и
восстанавливает прежние FK/EXIF rows. Нового wire type, ACK format или client
изменения нет; обычные metadata/library изменения не пишут событие и не сбрасывают
cache. Journal pruning использует существующий audit job и его 31-day window,
не photo retention. Durable deletion evidence и signed recovery proof не затронуты.

Проверено:

- **115/115 PASS**, 10 PostgreSQL файлов: новые index-return cases, все ранее
  сломанные library incrementals, true Trash, timeline, album ACK ordering,
  строгий CLI schema diff, exact security guards и populated-schema upgrade.
- **12/12 PASS** cache cases после дополнения: свежий service/repository context
  видит persisted recovery; failed transaction откатывает и asset transition,
  и journal insert; fresh audit rows не удаляются pruning; обычный external
  metadata update остаётся incremental. Это не kill/restart процесса или NAS E2E.
- **74/74 SyncService unit PASS**, включая проверку вызова нового audit cleanup
  с 31-day window. Предыдущий strict mock failure (73/1) сохранён отдельно.
- **6/6 pinned contracts PASS** после компиляции/генерации; spec/SDK SHA-256
  прежние. ESLint, TypeScript, Nest build, aliases PASS; теперь **78** fork
  migrations и прежние **2** compatibility aliases.

Прошлые 76 PASS относятся к промежуточному subset и не доказывали library
incremental совместимость; их заменяет финальный 115-case результат. Состояние
общего GitHub CI и native/NFS/AI E2E по-прежнему нельзя подменять этими passes.

### Финальный CI и workflow-plugin fixture

На опубликованном `b0d83c7881b7971fee1903dcc532a26e17fa0708` фактически прошли:

- [OpenAPI Clients](https://github.com/docice545/gallery/actions/runs/39755963588/job/119747911150), включая generation и проверку generated diff.
- [SQL Schema Checks](https://github.com/docice545/gallery/actions/runs/39755963588/job/119747911291), включая новую index-audit migration.
- [Migration ORDER](https://github.com/docice545/gallery/actions/runs/39755963590/job/119747911608).
- Web unit job также завершился success; это не browser/native E2E.

Полный medium job на том HEAD **FAIL**, не PASS. Десять опубликованных annotations
указывают на workflow assertions; total failed count всего job из недоступных blob
logs не устанавливался. Реальное локальное воспроизведение с core-plugin WASM и
cwd `server/`: **14 FAIL / 8 PASS**. Plugin host создаёт AssetService через
BaseService.create из WorkflowExecutionService; explicit test context не передавал
новый AssetFavoriteRepository. Точные ошибки: `getForAssets` / `addAll` у undefined.
Production Nest DI уже регистрирует этот репозиторий; runtime не меняется ради теста.

Исправлен только existing fixture: подключён **реальный** favorites repository.
Прежние assertions сохранены; добавлена проверка canonical overlay после favorite
и unfavorite, вместе с legacy owner flag. Весь файл: **22/22 PASS** на настоящем
WASM core-plugin и disposable PostgreSQL14. Это не mock host execution и не Android,
iOS, Synology либо AI E2E. Проверены ESLint, форматирование и TypeScript.

Точная команда из `server/`:

```bash
NODE_OPTIONS=--max-old-space-size=4096 node_modules/.bin/vitest run \
  --config test/vitest.config.medium.mjs \
  test/medium/specs/workflow/workflow-core-plugin.spec.ts \
  --maxWorkers=1 --no-file-parallelism
```

Перед тестом собраны client SDK, plugin SDK и core-plugin по фактическим scripts.
Использованы checksum-verified release assets из mise.lock: Extism v1.7.0 (сам
binary сообщает 1.6.1) и Binaryen version_124; cache только в `/tmp`. Бинарные
артефакты и dependency links не коммитятся. Первые два локальных 22-failure запуска
были ошибками подготовки/cwd, не воспроизведением CI; их логи сохранены и отдельно
помечены в JSON. Valid red/green: `workflow-medium-exact-cwd-before` →
`workflow-medium-final`. Новая полная CI-проверка до фактического завершения
по-прежнему не объявляется зелёной. Остальные CI/native ограничения сохраняются.

## Повторная приёмка PR #7 после CLI: CI и enum gate

Проверены исходный PR HEAD `ba92d21a4ec1b5fe045ccdb2da3387a4ad76cede` и
опубликованный CLI HEAD `8759f9bd9c8f94adfdf8df81dc67b158aaddbf90`.
Второй является потомком первого; в нём уже имеются обработчики шести sync
типов, изменение CI image и попытки настройки oasdiff. Эти изменения не
воссоздавались. `open-api/immich-openapi-specs.json` у двух HEAD побайтно одинаков.
Исходная база PR остаётся `ace2eab962524479a61e6891410983a7f41ba0fa`.

### Фактический CI и альтернативные журналы

| HEAD        | Проверка              | Результат и доказательство                                                                                                                                                                                                                                                                                                                                                         |
| ----------- | --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ba92d21a4` | SQL Schema Checks     | **FAIL до checkout/migrations**: Initialize containers, Docker pull exit 1. [Job](https://github.com/docice545/gallery/actions/runs/39759865381/job/119761703401). Это не failed schema assertion.                                                                                                                                                                                 |
| `ba92d21a4` | Medium Tests          | **FAIL до тестов**, global setup: `No such image: ghcr.io/immich-app/postgres:14-vectorchord0.4.3@sha256:dbf18b3ffea4a81434c65b71e20d27203baf903a0275f4341e4c16dfd901fd67`. Сообщение Vitest `No test files found` сопровождает ошибку setup; это не доказательство отсутствия spec-файлов. [Job](https://github.com/docice545/gallery/actions/runs/39759865381/job/119761819231). |
| `8759f9bd9` | SQL Schema Checks     | **PASS**: контейнер, app build, migrations, schema reset, generation и changed-files steps. [Job](https://github.com/docice545/gallery/actions/runs/39808230021/job/119928694623).                                                                                                                                                                                                 |
| `8759f9bd9` | Medium Tests          | **3447 PASS / 17 SKIPPED**; 199 passed files / 1 skipped, real GitHub testcontainers run. [Job](https://github.com/docice545/gallery/actions/runs/39808230021/job/119928796786). Никакого повторного полного прогона при приёмке не было.                                                                                                                                          |
| `8759f9bd9` | OpenAPI Clients       | **PASS**, включая generation и changed-files check. [Job](https://github.com/docice545/gallery/actions/runs/39808230021/job/119928694421). Это отдельная проверка от breaking enum gate.                                                                                                                                                                                           |
| `8759f9bd9` | OpenAPI breaking gate | **FAIL**, десять response enum diagnostics: шесть новых sync значений и четыре для уже имеющегося в base `AssetDeleteBatch`. [Job](https://github.com/docice545/gallery/actions/runs/39808230265/job/119927097106).                                                                                                                                                                |
| `8759f9bd9` | Dart analysis/codegen | **FAIL до analysis**, parser: `sync_api.repository.dart:88:1 Expected to find ';'`. [Job](https://github.com/docice545/gallery/actions/runs/39808230071/job/119927525319). В объявлении строки 86 стояла завершающая запятая. Это подтверждённая source regression CLI, не инфраструктурная ошибка.                                                                                |

Первая PostgreSQL image/digest ссылка **идентична в base и ba92**, поэтому
недоступность image на runner не классифицирована как регрессия backend PR #7.
CLI SQL image `14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23`
подтверждён реально завершённым SQL job. Это не доказательство, что прежний image
всегда несуществующий, или что смена SQL image исправила независимый medium job.
Production image, Compose и данные не затрагивались.

Прямые `/actions/jobs/<id>/logs` сейчас перенаправляют на недоступные Azure
hosts (HTTP 403). Однако **архивы целых workflow через
`/actions/runs/<id>/logs` доступны**. Из них извлечены medium/SQL/oasdiff/Dart
журналы, включая указанные counts и parser errors. Check-run annotations, job
steps и artifacts API использованы как дополнительные источники. Отдельного
medium JUnit artifact в перечислении нет; E2E artifacts не выдаются за medium.
В репозиторий сохранены только извлечённые факты и SHA-256 архивов/журналов,
без signed download URLs, credentials или полных необработанных логов.

### Причина enum gate и ограничение исправления

1. В `check-openapi.yml` оба сравнения были привязаны к `main`, тогда как PR
   направлен в unified. У проверенного `main` (`da5480ae42b77db9cae729f2447ec9b3079ba4a7`)
   нет `JobName.AssetDeleteBatch`, а в unified он уже есть. Четыре queue
   diagnostics относятся к baseline mismatch, не к изменениям этого PR.
2. В `SyncEntityType` относительно **самой unified** добавлены `AuthUserV2`,
   `MemoryV2`, `MemoryToAssetV2`, `AssetFaceV3`, `AssetFavoriteV1`,
   `AssetFavoriteDeleteV1`. `SyncAckSchema.type` использует общий enum;
   `SyncController.getSyncAck()` → `SyncService.getAcks()` возвращает все
   checkpoints сессии. Поэтому response contract `GET /sync/ack` расширяется.
   Это настоящий `response-property-enum-value-added`, а не инфраструктурный сбой.
3. `err-ignore: enum-value-added.*` из CLI не совпадает с текстом diagnostic,
   который начинается `in API GET ... added the new ...`; сам ID правила не
   является этим текстом. Полный лог подтверждает и передачу ignore file в
   action, и сохранение всех десяти ошибок. Подбирать более широкий regex,
   отключать правило или менять severity до WARN не разрешено этой приёмкой.
4. Исправление workflow в **отдельной acceptance-ветке** использует локальную
   копию spec из точного `pull_request.base.sha` в обоих jobs. Ручной dispatch
   требует явного `base_ref`, без fallback на main. Oasdiff по-прежнему
   `fail-on: ERR`, без ignore/exclude. Это устраняет неверную базу, но **не
   объявляет шесть настоящих enum additions безопасными**.

Новые stream payloads выдаются только при соответствующем запросе, однако это
само по себе не доказывает совместимость REST ACK со старым closed-enum SDK.
Предыдущий source audit не нашёл вызовов `getSyncAck` в закреплённых stock
clients; это граница evidence, а не разрешение на waiver. До явного решения о
совместимом version/capability контракте ACK либо об ограничении поддерживаемого
REST контракта шесть diagnostics остаются блокером приёмки. Подмена response
schema на произвольную строку или молчаливое скрытие checkpoints не выполнялись.

### Матрица после повторной приёмки

| Клиент                | Backend contracts / SQL / medium                                                     | Новые данные этой приёмки                                                          | Реальное приложение                                                                             |
| --------------------- | ------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Immich Android 3.3.5  | Ранее целевые PASS + MATCH по pinned caller paths; общий medium/SQL PASS на CLI HEAD | Response enum gate для REST ACK остаётся не закрытым; APK не менялся               | **NOT VERIFIED**: устройство, backup/retry/offline, Live Photos/HEIC                            |
| Immich iOS 3.3.5      | Те же backend evidence, не Android E2E                                               | Никакого нового iOS подтверждения                                                  | **NOT VERIFIED**: PhotoKit, iCloud, background upload, Live Photos, HEIC/HEIF, network recovery |
| Noodle Android 5.8.0  | Ранее MATCH по исходникам + backend evidence                                         | Generated SDK parity не равна закрытому breaking gate                              | **NOT VERIFIED**: Android/device lifecycle                                                      |
| Noodle iOS 5.8.0      | Ранее MATCH по исходникам + backend evidence                                         | Android результаты не перенесены на iOS                                            | **NOT VERIFIED**: Apple Photos/iCloud/background/HEIC/Live Photos                               |
| Noodle Web 5.8.0      | Ранее MATCH по caller paths, OpenAPI Clients PASS                                    | Произвольные legacy REST consumers не сертифицированы                              | **NOT VERIFIED**: browser E2E полного stock Web                                                 |
| FOTO Android Build 17 | Ранее backend evidence сохранены                                                     | Найден и исправлен parser defect CLI в acceptance-ветке; нужен завершённый Dart CI | **NOT VERIFIED**: APK/device, новый V2 sync lifecycle и crash/ACK/replay                        |

Ни backend CI, ни static enum comparison не доказывают AI E2E, работу настоящего
Synology или поддержку физических Android/iOS устройств. Нет нового Docker
образа, APK, deployment, merge или изменения PR #6/#8. Для сохранности параллельной
CLI-работы исправления приёмки опубликованы отдельно в
`codex/foto-build17-pr7-acceptance`, не записаны поверх PR #7 force-push.

### Проверки acceptance-кандидата (без повторного SQL/medium)

- `6b7f3db36efad590285209b9be61c72ee373e29c`:
  [Check OpenAPI](https://github.com/docice545/gallery/actions/runs/39827596417)
  сравнил с явным `base_ref=ace2eab962524479a61e6891410983a7f41ba0fa`.
  `check-mobile-patches` **PASS**; breaking check **FAIL** с **ровно шестью**
  `response-property-enum-value-added` для `/sync/ack`. Ни одной диагностики
  `AssetDeleteBatch` больше нет. Это подтверждение исправления baseline,
  **не PASS breaking gate**. Повтор mobile-patch check необходим из-за изменения
  сравниваемой базы; успешные SQL/medium/OpenAPI Clients не повторялись.
- [Dart analysis](https://github.com/docice545/gallery/actions/runs/39826683460)
  того же code commit: codegen **PASS**, затем **FAIL** из-за отсутствующего
  `toMemoryType` у нового generated `SyncMemoryV2TypeEnum` и двух новых lint
  замечаний `prefer_const_constructors` в favorites handlers. Это следующий
  выявленный дефект CLI, не замаскированный результатом parser fix.
- `788f4b2c3c0c38ec692b25bb84cf7734f43b262b`: добавлено отдельное преобразование
  generated enum для wire-значения `on_this_day` в существующий локальный тип;
  birthday явно вызывает `UnsupportedError` до commit/ACK. Новый тип не
  превращается в `rule` или фиктивный on-this-day. Исправлены оба const lint.
  Добавлены три целевых регрессии: SQLite persistence + идемпотентный replay,
  rollback смешанного пакета с birthday, отсутствие ACK при отказе и ACK после
  успешного повтора (последняя — service test с mock repository, не crash E2E).
  Ручной Static Code Analysis запускает только эти три теста после analysis,
  последовательно, без нового image/APK или повторного полного backend suite.
  [Запуск проверки](https://github.com/docice545/gallery/actions/runs/39828130854).
  Результат до фактического завершения не объявлен успешным.

Birthday остаётся **явным ограничением этого мобильного форка**, а не
поддержанной функцией. Backend этого PR в V2 stream выдаёт только on_this_day;
новый тест специально проверяет отказ на неожиданном birthday. Поведение
остальных новых V2 handlers при потере процесса/поздних родительских rows и
полный replay lifecycle требуют отдельной проверки CLI. В частности, V2 memory
links всё ещё используют существующий in-memory deferred set; ACK раньше его
устойчивого сохранения нельзя сертифицировать как crash-safe без такой проверки.

Промежуточный результат `788f4b2c3`: codegen и Dart analysis **PASS** (`No issues
found`); оба SQLite теста **PASS**, service ACK test **FAIL** ещё до вызова
обработчика. Причина тестовой фикстуры — `fromJson` получил результат `toJson`
с вложенным generated enum, ещё не преобразованным в строку JSON-кодером.
Этот failed run сохранён, не выдан за успех продукта.

В `43d1aa9f382ebf60019570c373ba2aa39032181c` исправлена только фикстура через
настоящий `jsonEncode`/`jsonDecode` wire round trip. Ручной targeted step повторяет
только неуспешный service test; два SQLite passes и неизменённая реализация
repository сохранены. [Повтор failed test](https://github.com/docice545/gallery/actions/runs/39829279657)
до завершения имеет статус **PENDING**. Setup/codegen в новом GitHub job нужен для
компиляции исправленного test source; SQL, medium и OpenAPI Clients не запускались.
