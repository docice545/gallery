# Trash / Restore: граница необратимого удаления и безопасное обновление HP

## Область и статус

Продолжение `1d773fd6fad785414b3f7bdc1f7484a1b5bf4e7d`, review-ветка
`audit/gallery-cmp-trash-vaapi-20261009`. Production `work` —
`42790b06edc21438811e56e40c431eee37c24894`.
Изменения CMP/Shizuku/VAAPI/QSV/OpenVINO приостановлены. Этот патч не меняет
их код, signing, API routes/DTO/permissions, схемы БД или production.

**NOT READY для production deployment без проверки очереди HP, backup оригиналов,
физического acceptance и отдельного разрешения.** Это не означает, что
автоматические целевые проверки являются физической проверкой Samsung/Synology.
Результаты прогона хранятся в
`specs/testing/2026-10-09-trash-release-validation.md`.

## Реальный путь действия

1. `mobile/lib/presentation/actions/delete.action.dart` и
   `mobile/lib/domain/services/asset.service.dart` отделяют обычный Trash от permanent
   delete. Bulk использует тот же путь. Cloud-запрос — `DELETE /api/assets` с
   `force:false`; local-only — существующий PhotoManager/native API.
2. `RemoteAssetRepository.beginTrashOperation` атомарно сохраняет optimistic
   состояние и captured revision в Drift. Серверное отклонение откатывает именно
   эту revision; неопределённый transport/server outcome сохраняет pending.
   `SyncStreamService` проверяет его после успешного sync, даже без asset events;
   холодный старт сохраняет/восстанавливает незавершённый intent.
3. `server/src/services/asset.service.ts::deleteAll` проверяет доступ и изменяет
   status/deletedAt. В обычном Trash этот метод не вызывает unlink.
   Новая `markDeletionState` не разрешает переход `Deleted -> Trashed`.
   Событие содержит только реально изменённые ID.
4. Timeline/album/search SQL и мобильные Drift queries исключают Trash.
   checksum-linked local twin подавляется в объединённой Timeline. Загруженные
   search pages наблюдают durable Trash-маркеры, включая поздний ответ поиска.
   Их безопасная первоначальная пустая выдача предшествует чтению маркеров.
   Cached folder list теперь также проецирует этот поток. Открытый из папки
   Viewer использует существующий `fromAssetStream`, а не статический
   `fromAssets`, поэтому Trash/Restore обновляют его без нового HTTP-запроса.
5. `POST /api/trash/restore/assets` → `TrashService.restoreAssets` →
   `TrashRepository.restoreAll` обновляет только `Trashed` и возвращает фактические
   ID. Count, event и очистка duplicate tombstones основаны на этих ID.
   Клиент не интерпретирует частичный batch count или Restore-All count как
   подтверждение всех выбранных assets; остаётся per-ID reconciliation.
   Поздний ответ Restore не снимает новую revision Trash.
6. Restore не переписывает capture/localDateTime/timezone/EXIF, album membership,
   stackId или livePhotoVideoId. В штатном timeline результат сортируется по
   исходной дате, а Trash — по deletedAt. Повторный Restore не создаёт новый asset.
7. Retention/Empty Trash/permanent delete — отдельная необратимая стадия:
   `AssetDeleteCheck` / `AssetEmptyTrash` → `AssetDelete` → удаление DB row →
   `FileDelete`. Последний уже содержит пути файлов, а не restorable asset.

## Исправления этой итерации

В исходном review уже были cutoff для новых retention jobs, actual Restore IDs,
revision guards и реактивное подавление cached search. В этой итерации добавлены:

- **Legacy jobs без cutoff:** разрешены только для уже `Deleted` row. Active,
  restored и Trashed не удаляются. Старое задание нельзя классифицировать по
  возрасту, имени файла, mtime, наличию deletedAt или предположению, что это Trash.
- **Library cleanup:** новые jobs содержат `deletionReason:'library'` и `libraryId`,
  обязательно `deleteOnDisk:false`. Атомарная проверка требует той же soft-deleted
  библиотеки. Неполный/противоречивый library payload завершается Failed до эффектов.
- **Motion cleanup:** новые jobs содержат `deletionReason:'motion'`. Claim требует
  Hidden Video и отсутствия текущих still references; linked video и still не
  подходят. Shared motion не удаляется при удалении только одного still.
- **Повторный Trash после claim:** не может вернуть Deleted row в Trashed и
  разрешить Restore перед окончательным removal.
- **Два concurrent deletion workers:** только DELETE RETURNING winner отправляет
  события, изменяет quota и создаёт FileDelete. Второй worker с тем же snapshot
  пропускается. Legacy/Empty Trash consumer также не получает право unlink для
  Deleted row библиотеки, уже soft-deleted штатной library-removal операцией.
- **Retention/library separation:** cutoff не превращает удаление библиотеки в
  unlink оригиналов. Active online row не подходит; soft-deleted library не
  подходит. Существующее cleanup expired offline index сохраняется: Active+
  isOffline с истёкшим deletedAt допустим, а оригинал при isOffline не unlink-ится.
- Обновлены medium fixtures: permanent deletion начинается с настоящего
  `deleteAll(force:true)`, не с удаления Active row через внутренний handler.
  Уточнены exact job payload и пустой Timeline DTO. Flutter grouping integration
  ждёт populated emission после чтения durable markers с ограниченным timeout;
  fail-closed поведение и все assertions counts/grouping сохранены.
- Исправлен отдельный stale folder/Viewer snapshot: durable маркеры применяются
  как к уже загруженным данным, так и к позднему folder response. Restore
  возвращает cached asset на прежнее место; более старый fetch/sort response
  не заменяет новый. При disposal отменяются stream subscriptions и игнорируется
  поздний HTTP response. Шесть новых Flutter/SQLite тестов проверяют этот путь.

Все claim/Restore/Trash проверки выполняются в PostgreSQL UPDATE, не по
предварительному SELECT. Четыре теста реально блокируют вторую транзакцию row lock
и проверяют `pg_stat_activity.wait_event_type='Lock'` перед освобождением первой.
Первым может выиграть Restore, claim или новое Trash. После claim восстановление
уже невозможно; это проверяется actual RETURNING/count, а не mock-предположением.

## Что происходит с оригиналами

| Действие | Gallery DB / UI | Оригинал / NAS |
| --- | --- | --- |
| Обычный server Trash, enabled и не expired | Trashed/deletedAt; исключение из обычных выдач | Не unlink-ится этим действием; оригинал не переезжает в файловую папку Trash |
| Restore до irreversible claim | Active/deletedAt=null; исходная хронология и альбомные связи | Исходные байты остаются прежними |
| Permanent delete / Empty Trash / expiry | Deleted, затем удаление row и связей | При `deleteOnDisk:true` и текущем `!isOffline` удаляются original+sidecar, включая **writable external Synology** |
| Read-only NAS при permanent delete | DB/album links всё равно удаляются | unlink может не пройти; это не поддерживаемый Restore и не сохранение Gallery metadata |
| Expired offline external index | Удаляется индекс и generated resources | Недоступный original не unlink-ится; последующая доступность/scan — отдельный library lifecycle |
| Удалить external library | Удаляются индекс/derived files этой библиотеки | `deleteOnDisk:false` сохраняет originals; это другое действие, чем permanent delete asset |
| NAS file удалён вне Gallery | File watcher может удалить соответствующий DB asset | Файл уже отсутствует; Gallery Trash не отменяет внешнее удаление |
| Local-only Android | Существующий native MediaStore Trash, когда поддерживается; подтверждённые ID обновляют Drift | Файл телефона, не NAS; права/диалог/срок хранения определяет Android |
| Local-only iOS | Существующий PhotoKit delete | Recovery через системный Recently Deleted; не обещается отдельный Gallery Restore для local-only |
| Local+cloud с Manage Local Media выключенным | Немедленный server Trash скрывает checksum twin в Photos | Физическая локальная копия может оставаться видимой в Samsung Gallery |
| Local+cloud с явно включённым Manage Local Media | После sync existing native путь меняет backed-up local copy | Это отдельное разрешённое пользователем управление файлами телефона |

Trash disabled означает zero-day retention; исходный код не обещает возможность
восстановления. Live/Motion soft Trash сохраняет still+hidden video связь и файлы;
permanent removal может удалить неиспользуемый companion. Серверные fixtures
проверяют lifecycle и байты синтетических ресурсов, не PhotoKit/кодеки на устройстве.
«Remove from album» меняет membership, не удаляет asset; «Trash» внутри album
использует тот же server Trash, а не незаметный unlink.

## Existing jobs: стратегия перехода без очистки всей очереди

Защита нового consumer — основной механизм: не переписывать старые payload,
не подставлять cutoff задним числом, не удалять backgroundTask целиком.
Новый retention sweep создаст guarded jobs для действительно expired current rows.
Старые Active/Trashed library/motion jobs безопасно пропускаются. Это может отложить
reclaim ненужных index/derived resources; после проверки можно отдельно пересоздать
**только известные** library-removal/orphan cleanup jobs штатным producer.
Это не причина запускать повторную индексацию библиотеки или AI-анализ.

**Особый blocker — уже queued FileDelete.** Они находятся за irreversible DB
boundary, содержат пути и не защищаются asset claim. Нужен приватный полный экспорт
AssetDelete/FileDelete с job IDs, state и payload, плюс проверка ссылок текущей БД.
Путь, снова используемый current asset/asset_file, неизвестный scope или неизвестная
история — STOP; только отдельное рассмотрение/разрешение точечного удаления job.
Не возобновлять неизвестные FileDelete и не считать новый guard их миграцией.

Если подтверждённый FileDelete ссылается на существующий restored/current
original, безопасное действие — **отменить только это конкретное inactive job**
после экспорта и approval: `queue.getJob(jobId)` → сверить name, state и payload
с экспортом → `job.remove()`. Active job таким способом не отменять и не трогать
locks/Redis keys. Проверять, что очередь paused, active=0 и старые consumers
остановлены. Никаких `clean`, `drain`, `obliterate` или удаления queue целиком.
Экспорт сохраняет возможность последующего адресного восстановления intent,
но опасный старый FileDelete **не возвращать автоматически при rollback**.
При необходимости producer должен сформировать новую проверяемую операцию
на основании текущей DB; оригинал restored asset не является cleanup target.

API `GET /api/queues/backgroundTask/jobs` ограничен 1001 результатом. Более того,
запрос без status либо с active вызывает repair dangling active entries. Поэтому
его нельзя выдавать за полный strictly-read-only экспорт. Использовать read-only
BullMQ `getJobs` с явными states, постранично, и `getJobCounts/isPaused` на существующей
configuration; private export не печатать в чат. Не менять Redis keys напрямую.

## Production plan — только после отдельного approval

План подготовлен по репозиторию; **на HP не выполнен и требует HP validation**.
Точные фактические mount flags, retention, image digest и backlog пока неизвестны.
Не применять этот раздел автоматически и не смешивать его с migration Anna.

1. Зафиксировать текущие revision/image ID и container IDs `immich_server`,
   `immich_postgres`, `immich_redis`, `immich_machine_learning`; image metadata
   проверять выборочно, не выводить весь `.Config.Env` с credentials. Проверить
   Trash enabled/days и external mounts read-only/read-write. Определить все
   Gallery microservices consumers, включая отдельный worker, если он есть.
2. Подготовить отдельный staging image из согласованного SHA, не перезаписывая
   предыдущий working image. Сохранить compatible server release metadata
   `IMMICH_SOURCE_REF=v5.7.1`; application IDs/signing не менять.
   `/opt/gallery-fork` — существующий bind mount SSD; не переносить caches/model.
3. Закрыть окно пользовательских mutations; остановить приём **deletion queue**
   и дождаться actual active=0, прежде чем заменять старый consumer. В этой версии
   `PUT /api/queues/backgroundTask {isPaused:true}` отклоняется. Подтверждённый
   existing admin API: `PUT /api/jobs/backgroundTask {"command":"pause"}`
   (legacy route, admin/job.create). До использования проверить его в staging.
   Pause не отменяет active jobs; если они не drain-ятся — STOP, не kill/clean active.
   `GET /api/queues/backgroundTask` даёт read-only counts/status.
4. При paused queue/active=0 и остановленных mutations сохранить private queue
   export, previous pause state, PostgreSQL `pg_dump`/`pg_restore --list`-проверенный
   backup, Compose files/override и immutable previous image. Для NAS originals
   нужен отдельный Synology snapshot/backup с проверяемым restore: DB dump не
   восстанавливает unlink-нутые фото. Не менять/мигрировать Redis/PG/ML или NAS.
5. Проверить DB read-only: status/deletedAt consistency, deleted libraries,
   reachable originals для disposable acceptance, migration history. **Новой
   server/Drift schema migration здесь нет**. Не делать reset/manual production SQL.
   Проверить legacy AssetDelete и все pending FileDelete до возобновления queue.
6. По approval интегрировать согласованный review SHA в work нормальным merge,
   заменить только `immich-server` в `/opt/immich/docker-compose.yml`:
   `docker compose -f /opt/immich/docker-compose.yml up -d --no-deps immich-server`.
   Это пример после выбора проверенного image, не команда, выполненная в Codex.
   Ни один старый unguarded worker не должен продолжать работать рядом с новым.
7. С queue paused проверить health, `/api/server/ping`, `/api/server/version`, login,
   counts/metadata и отсутствие новых migrations/ошибок. Затем только disposable
   single/bulk фото, video, Live/Motion: Trash→Restore→retrash, album и timezone
   chronology, refresh/pagination/offline/reconnect/restart. Сравнить оригинальные
   байты и still/video association. Не тестировать permanent/expiry на family media.
8. После queue audit и acceptance возобновить только эту очередь через
   `PUT /api/jobs/backgroundTask {"command":"resume"}`. Проверить counters,
   пропуск старых jobs и guarded новые jobs. Подтвердить, что PG/Redis/ML IDs не
   изменились. Автопроход/AI workers, Anna stack exclusion, VPN/DNS не трогать.

### Rollback

Снова pause deletion queue и drain active=0. Вернуть сохранённый immutable server
image/точные Compose overrides, recreate **только** immich-server с `--no-deps`.
В отличие от обычного image rollback, **старый unguarded consumer нельзя запускать
с опасным deletion backlog**. Оставить queue paused; при невозможности сохранить
pause использовать существующий API-only worker режим
`IMMICH_WORKERS_EXCLUDE=microservices` в отдельном сохранённом override. Временно
не будут выполняться Gallery background jobs, что предпочтительнее потери файлов.
Не перезапускать PG/Redis/ML и не восстанавливать их volumes поверх живых данных.

Проверить health/login/read-only Timeline и исходные container IDs. Новых schema
changes нет, поэтому rollback не требует SQL downgrade. Уже удалённые originals
не возвращаются от image rollback: восстановление из NAS/DB backups — отдельная
контролируемая операция с согласованной точкой времени. Нельзя считать обычный
`docker compose up` восстановлением фотографий.

## Оставшиеся safety gates

- Private HP queue/current-file-reference audit, особенно FileDelete; реальные
  retention/mount flags и актуальный backup оригиналов.
- Физическая проверка Samsung S23 на disposable assets; iOS native/local deletion
  и Recently Deleted отдельно требуют iPhone, если выпускается iOS.
- Полный backend suite содержит два воспроизводимых pre-existing guard failures;
  они перечислены в validation record и не скрыты/не отключены.
- Explicit approval на integration/deployment. Сейчас work и production неизменны.
