# FOTO Build 17: backend compatibility with pinned stock clients

Дата проверки: 22.10.2026. База: `ace2eab962524479a61e6891410983a7f41ba0fa`,
`codex/foto-build17-unified`. Изменения: отдельная ветка
`codex/foto-build17-client-compat`; PR компактного редактора не изменяется.

**Результат:** выявленные B1–B7 исправлены и проверены на уровне backend и
контрактов. Полная готовность установленных Android/iOS/Web приложений
**NOT VERIFIED**. Это не релиз, не сертификат совместимости всех API и не
разрешение на deployment. Production и пользовательские медиа не использовались.

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
Исходные файлы и tests относятся к code commit
`57006e191fb0f167d1211d977d9ab8ea15f87d8e`. Дополнительные medium fixtures
исправлены и проверены в `3021cbff08bcb59867d6547ffa9cd58fccbdb8aa`; runtime
backend после 57006e191 не менялся. Отчёты не заменяют native E2E.

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
