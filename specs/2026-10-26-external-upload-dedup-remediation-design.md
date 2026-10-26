# FOTO: безопасное устранение существующих External / Managed дублей

Дата: 26.10.2026. Область — адресные пары одного владельца, без повторной миграции
Google Takeout, перестроения библиотек и изменения NAS-оригиналов из Cloud.

## Статус и границы

Исправление допуска новых загрузок и устранение уже существующих пар — разные операции.
Тесты нового upload admission не доказывают безопасность будущего объединения старых записей.
В этом изменении **нет выполняющего очистку инструмента, SQL-миграции данных, задания удаления
или production-применения**. Ниже — проект отдельной операции и read-only проверки для владельца HP.
Реализован только [offline-планировщик снимка аудита](../scripts/external-upload-dedup/README.md),
с синтетическими тестами одной/шести пар, конфликтов и неизменности исходных записей.
Он формирует BLOCKED или REVIEW_REQUIRED, не проверяет NAS/БД и не имеет режима apply.
Сам merger требует реализации, integration/crash-recovery тестов и отдельного согласования.
Шесть существующих пар не объявляются устранёнными.

Владелец сообщил о шести именах:

- `20261025_173327.jpg`;
- `20261025_174654.jpg`;
- `20261025_211132.jpg`;
- `20261025_211137.jpg`;
- `20261025_211140.jpg`;
- `20261025_211145.jpg`.

Для первого имени известны External UUID `e7ec895a-e799-4816-a17a-a5416d5c6776` и Managed
UUID `b23305e8-e709-494f-a6fa-117d164d5591`, размер 2 511 210 байт. Это входные данные пользователя,
а не результат проверки production из Cloud. Владелец должен подтвердить UUID остальных пар;
имя файла, размер и общий `duplicateId` сами по себе не разрешают объединение.

Обе физические папки находятся на Synology: External
`/volume1/homes/chudo_anna/Photos`, Managed `/volume1/Immich/upload`.
Контейнерные и HP-пути необходимо получить из фактических mounts. Нельзя трактовать Managed
как HP-копию или менять эту архитектуру для дедупликации.

## Почему штатный Duplicate Resolve недостаточен

`server/src/services/duplicate.service.ts:resolveGroup` сохраняет часть информации: объединяет
доступные альбомы и теги, favorite/archive, rating/description, однозначные GPS, editable shared
spaces. Он может поставить `SidecarWrite`, затем переводит лишние assets в Trash. Сбой создания
checksum aliases логируется после предыдущих изменений. Это разрешение пользовательской группы
похожих фото, а не атомарное сохранение всех зависимостей двух идентичных оригиналов.

Он не переносит все перечисленные ниже отношения. Его нельзя использовать как готовую
безопасную массовую очистку этих пар. Нельзя просто вызвать Trash → Empty Trash: durable
`asset_deletion_tombstone` хранит content checksum/aliases без FK на asset и может запретить
повторную загрузку или сканирование того же содержимого у **сохраняемого** External asset.
Объединение объектов не является пользовательским удалением содержимого.

## Обязательный аудит зависимостей

Схема fork развивается; перед любой реализацией надо перечислить реальные FK через `pg_catalog`
и дополнительно проверить ссылки без FK. Таблица — минимальная карта по текущим исходникам,
не закрытый список разрешённых таблиц.

| Область | Что сохранить или почему остановиться |
| --- | --- |
| Владелец и библиотека | Оба owner UUID совпадают; External library принадлежит ему, доступна и не удалена. Не передавать права через checksum alias. |
| Оригинал и все файлы | Exact bytes, тип, размер, SHA-256, стабильная inode/stat identity, читаемость и NFS mount identity. Инвентаризация `asset_file`, sidecar, edited/encoded/preview и `video_stream`, `asset_audio/video/keyframe`; ни один общий путь не удалять. |
| EXIF и пользовательская метаинформация | `asset_exif`, `asset_metadata` JSON, даты, GPS, description, rating, lockable свойства, параметры загрузки. Не перезаписывать несовпадающие ручные значения и EXIF файла автоматически. |
| Альбомы и обсуждения | `album_asset`, thumbnail assets, `album_space_asset`, shared-space albums и grants. `activity` имеет также составной FK `(albumId,assetId)`; перенос комментариев/лайков должен сохранять id, автора и дату, разбирать unique-like конфликты. |
| Стопки и ручные запреты | `asset.stackId`, `stack.primaryAssetId`, `stack_suppression`. Разные стопки, primary и suppression требуют явной политики; не объединять стопки по checksum и не запускать внешний auto-stack processor. Anna остаётся исключённой из auto-stack. |
| Избранное и видимость | `asset.isFavorite`, **все** `asset_favorite(userId,assetId)`, archive/locked/hidden и edit state. Не делать скрытую/закрытую фотографию видимой из-за объединения. |
| Лица, люди, животные | `asset_face`, `person`/`shared_space_person` representative face, `person_group`, `face_identity_face`, verdicts/declines/scan state и shared-space face relations. Сохранять ручные назначения, отрицательные решения и face UUID; конфликт координат/назначений останавливает пару. ML/Inpainting не запускать. |
| Публикации и доступ | `shared_link_asset`, `shared_space_asset` и library-based grants, shared-space thumbnail; partner доступ косвенно owner-scoped. Сопоставить effective ACL до и после; не расширять чужие права. Не выводить shared-link keys/passwords. |
| Воспоминания | `memory_asset` и ссылки `memory_candidate.assetIds` в JSON. Только инвентаризация; изменение Memories сейчас не разрешено. Наличие требующей изменения зависимости — стоп-фактор для будущего apply до отдельного решения. |
| Правки и производные результаты | `asset_edit` sequence/parameters и triggers, OCR/search/embeddings, job status. Даже равные исходники могут иметь разные неразрушающие правки; такую пару нельзя молча схлопнуть. |
| Синхронизация и удаление | Все audit/watermark/checkpoint механизмы, `asset_duplicate_checksum`, существующие deletion receipts/policy. Не удалять историю, не изобретать receipt физического удаления External и не выдавать Managed UUID за существующий файл. |
| Операции без FK | `move_history.entityId`, `storage_migration_log.entityId`, `workflow_log.triggerDataId`, JSON/массивы, очереди и активные jobs. Снять bounded read-only состояние штатным локальным способом; Redis и jobs не менять. Не выполнять глобальный SCAN/поиск по всей БД. |

`asset_duplicate_checksum` — owner/checksum → asset association, но legacy Duplicate Resolve
может записать checksum удалённой **другой версии** на keeper. Alias и perceptual `duplicateId`
позволяют найти кандидата, но не заменяют побайтовую проверку. `sha1-path` вычисляется из
`"path:" + normalizedPath`, поэтому его нельзя сравнивать с file SHA-1 как доказательство
различия изображений или переписывать у External в рамках очистки.

## Проект адресного объединения после отдельного согласования

1. Сначала применить и проверить предотвращение новых дублей. Для старых пар сформировать
   **фиксированный allowlist** owner + 12 подтверждённых UUID + canonical paths и manifest
   зависимостей с fingerprint. Dry-run не делает никаких мутаций и не вычисляет новые пары
   по одному имени/размеру/duplicateId. Любой неоднозначный результат требует решения.
2. Подтвердить ровно две независимые regular-file копии одинаковых bytes, доступность External
   под identity сервера, фактические NFS roots и неизменность файлов во время чтения.
   Symlink, изменившийся mount/inode/mtime/size, I/O failure, incomplete receipt, неподтверждённые
   grants, conflicting edits/manual decisions — запрет apply для этой пары.
3. Предпочтительный survivor — **существующий External UUID и его неизменный путь**, если все
   проверки пройдены. Никакой фиктивной Managed записи и переписывания ownership/libraryId.
   Если это не сохраняет поведение зависимостей, пару оставить без изменений до решения.
4. Будущая реализация должна создать durable merge journal с operation ID, source/survivor,
   identity файлов, полным before/after manifest и ожидаемыми watermarks. Это отдельный механизм
   объединения, а не `asset_deletion_tombstone`. Повторы одного operation ID идемпотентны.
   Нужны owner/content serialization и короткая DB-транзакция с повторной проверкой обеих строк
   и зависимостей: длительное хеширование не держит row lock.
5. В одной транзакции сохранить/перенести все разрешённые связи и точные checksum associations,
   устранить допустимые duplicate-key отношения, сохранить ручные решения и выпустить штатные
   sync updates/deletes с долговременной картой source → survivor. Если нужной операции нет в
   штатном API/repository, реализовать и отдельно протестировать её; не воспроизводить FK
   DELETE вручную в production. Никаких глобальных SQL UPDATE/DELETE и sidecar writes.
6. После commit, проверки HTTP original/thumbnail и sync старого клиента подготовить обратимую
   карантинную операцию **только для лишнего Managed original**. Снова проверить identity/hash,
   отсутствие других ссылок на путь и наличие External. Учитывать, что атомарный rename возможен
   только в пределах одного filesystem; никаких copy/unlink fallback через границу mount.
   Journal фиксируется до мутации. Ошибка сохраняет возможность безопасного retry и отката,
   не разрешает трогать External или файлы Samsung. Срок хранения карантина — отдельное решение.
7. После ручной приёмки и истечения согласованного срока можно отдельно разрешить удаление
   карантина. До этого есть временная recovery-копия; это не вторая постоянная Managed копия.
   Цель «одна постоянная копия» достигается лишь после завершённого согласованного применения,
   а не после скрытия второй плитки.

Не объединять пары с параллельной пользовательской правкой: compare-and-swap manifest должен
отменить операцию. Не обещать абсолютной атомарности между PostgreSQL и NAS; durable state
machine и identity-checked recovery обязаны покрывать каждый разрыв.

## Откат будущего применения

- До DB commit: rollback транзакции, оба assets и файла неизменны.
- После commit, до quarantine: восстановление зависимостей из manifest допустимо только после
  проверки watermarks и отсутствия новых пользовательских изменений; иначе остановка для
  адресного reconciliation. Нельзя делать DB-wide restore поверх новых production данных.
- После quarantine: проверенный rename Managed original обратно в **исходное свободное** место
  и восстановление journal/связей согласованным recovery path. Никогда не заменять существующий
  файл. Sync требует компенсирующих событий; уже ACK-нутые события не «откатываются» удалением.
- После безвозвратного удаления recovery-копии полный откат файла возможен только из отдельно
  проверенной резервной копии. Существующий External survivor не удаляется ни на одной стадии.

## Тесты, необходимые до реализации future apply

Отдельная suite должна использовать synthetic regular files и Testcontainers PostgreSQL:
одна/шесть пар, повторный запуск, разные owner/bytes с одинаковым именем, stale alias,
недоступный/подменённый External, разные mounts и symlink, конфликт правок, все строки матрицы
зависимостей, нормальное удаление/restore survivor после merge, старый mobile upload/check/sync,
concurrent upload/scan/delete/metadata edit, crash после каждого durable перехода и rollback.
Нужно доказать отсутствие осиротевших связей, reupload loops, лишних постоянных файлов и
ложных content-deletion receipts. Эти тесты **не объявляются выполненными** этим документом.

## Read-only проверки на HP, выполняемые владельцем

Не выполнять через Cloud. Использовать существующую локальную административную сессию;
пароли/токены/keystore не передавать и не включать в отчёт. Ниже нет deploy, sync, удаления,
jobs, миграций, остановки контейнеров или изменений конфигурации.

### Образ и mounts

```bash
docker inspect --format '{{.Config.Image}} {{.State.Health.Status}}' immich_server
docker inspect --format '{{json .Mounts}}' immich_server
findmnt -T /mnt/synology-immich-managed/upload -o TARGET,SOURCE,FSTYPE,OPTIONS
findmnt -T /mnt/synology-immich-managed/library -o TARGET,SOURCE,FSTYPE,OPTIONS
```

Если реальные HP paths отличаются, подставить paths из mounts, не создавать/перемонтировать
каталоги. External mount проверить аналогично по фактическому источнику.

### Существующая локальная psql-сессия: инвентаризация кандидатов

Включить `ON_ERROR_STOP`; транзакция read-only и заканчивается ROLLBACK. Owner выводится из
**обеих** известных записей, а не из имени пользователя или непроверенного hardcoded UUID.
Если первый запрос не возвращает обе строки с одним owner, дальнейший аудит остановить.

```sql
\set ON_ERROR_STOP on
BEGIN READ ONLY;
SET LOCAL statement_timeout = '15s';
SELECT id, "ownerId", "libraryId", "isExternal", status, "isOffline", "deletedAt",
       "originalFileName", "originalPath", "checksumAlgorithm", encode(checksum,'hex') AS checksum,
       "duplicateId", "stackId", "isEdited"
FROM public.asset
WHERE id IN ('e7ec895a-e799-4816-a17a-a5416d5c6776',
             'b23305e8-e709-494f-a6fa-117d164d5591')
ORDER BY id;

WITH confirmed_owner AS (
  SELECT min("ownerId"::text)::uuid AS id FROM public.asset
  WHERE id IN ('e7ec895a-e799-4816-a17a-a5416d5c6776',
               'b23305e8-e709-494f-a6fa-117d164d5591')
  HAVING count(*) = 2 AND count(DISTINCT "ownerId") = 1
)
SELECT a.id, a."ownerId", a."originalFileName", a."originalPath", a."libraryId",
       a."isExternal", a.status, a."isOffline", a."deletedAt", a."duplicateId",
       a."checksumAlgorithm", encode(a.checksum,'hex') AS checksum,
       e."fileSizeInByte", a."stackId", a."livePhotoVideoId", a."isEdited"
FROM public.asset a JOIN confirmed_owner o ON o.id = a."ownerId"
LEFT JOIN public.asset_exif e ON e."assetId" = a.id
WHERE a."originalFileName" = ANY (ARRAY[
  '20261025_173327.jpg','20261025_174654.jpg','20261025_211132.jpg',
  '20261025_211137.jpg','20261025_211140.jpg','20261025_211145.jpg'])
ORDER BY a."originalFileName", a."isExternal" DESC, a.id
LIMIT 25;
ROLLBACK;
```

Ожидание для описанного случая — 12 нужных rows. Иное количество не исправлять автоматически:
сначала уточнить allowlist. `fileSizeInByte` — кэш метаданных, не доказательство физического размера.

### Точечные зависимости известной пары

Сначала пример только для двух **известных** UUID. Остальные десять добавить в `foto_ids`
вручную только после проверки результатов выше. Это psql array literal, не shell interpolation.

```sql
\set ON_ERROR_STOP on
\set foto_ids '{e7ec895a-e799-4816-a17a-a5416d5c6776,b23305e8-e709-494f-a6fa-117d164d5591}'
BEGIN READ ONLY;
SET LOCAL statement_timeout = '15s';
SELECT c.conrelid::regclass AS relation, c.confrelid::regclass AS references_relation,
       c.conname, pg_get_constraintdef(c.oid) AS definition
FROM pg_constraint c
WHERE c.contype = 'f' AND c.confrelid IN
  ('public.asset'::regclass,'public.asset_face'::regclass,'public.asset_file'::regclass)
ORDER BY c.confrelid::regclass::text, c.conrelid::regclass::text, c.conname;

-- Выполняются только SELECT count для реальных single-column FK на asset.
-- Идентификаторы берутся из каталога и quote-ятся через format(%I), UUID-array через %L.
SELECT format('SELECT %L AS relation, %L AS fk_column, count(*) AS rows FROM %I.%I WHERE %I = ANY (%L::uuid[]);',
              n.nspname||'.'||t.relname, a.attname, n.nspname, t.relname, a.attname, :'foto_ids')
FROM pg_constraint c
JOIN pg_class t ON t.oid = c.conrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
WHERE c.contype = 'f' AND c.confrelid = 'public.asset'::regclass
  AND cardinality(c.conkey) = 1
ORDER BY n.nspname, t.relname, a.attname
\gexec

SELECT "ownerId", "assetId", encode(checksum,'hex') AS content_or_alias_checksum
FROM public.asset_duplicate_checksum WHERE "assetId" = ANY (:'foto_ids'::uuid[]);
SELECT a.id, l.id AS "libraryId", l."ownerId", l."deletedAt", l."importPaths",
       EXISTS (SELECT 1 FROM public.library_user u
               WHERE u."libraryId" = l.id AND u."userId" = a."ownerId") AS owner_has_grant
FROM public.asset a JOIN public.library l ON l.id = a."libraryId"
WHERE a.id = ANY (:'foto_ids'::uuid[]);
SELECT "assetId", "ownerId", state, "errorCode", "checksumAlgorithm", "originalPath",
       encode("contentChecksum",'hex') AS content_checksum, aliases
FROM public.asset_deletion_tombstone WHERE "assetId" = ANY (:'foto_ids'::uuid[]);
WITH selected AS (
  SELECT id, "ownerId", checksum, "checksumAlgorithm" FROM public.asset
  WHERE id = ANY (:'foto_ids'::uuid[])
), content_candidates AS (
  SELECT "ownerId", checksum FROM selected WHERE "checksumAlgorithm" = 'sha1'
  UNION
  SELECT s."ownerId", d.checksum FROM selected s
  JOIN public.asset_duplicate_checksum d ON d."assetId" = s.id AND d."ownerId" = s."ownerId"
)
SELECT t."assetId", t."ownerId", t.state, t."errorCode",
       encode(t."contentChecksum",'hex') AS content_checksum, t.aliases
FROM public.asset_deletion_tombstone t
WHERE EXISTS (SELECT 1 FROM content_candidates c WHERE c."ownerId" = t."ownerId"
              AND (t.checksum = c.checksum OR t."contentChecksum" = c.checksum
                   OR t.aliases ? encode(c.checksum,'hex')));
SELECT id, state, "assetIds" FROM public.memory_candidate
WHERE "assetIds" ?| (:'foto_ids'::uuid[])::text[];
SELECT "entityId", "pathType", "oldPath", "newPath" FROM public.move_history
WHERE "entityId" = ANY (:'foto_ids'::uuid[]);
SELECT "entityId", "entityType", "fileType", "oldPath", "newPath", "batchId"
FROM public.storage_migration_log WHERE "entityId" = ANY (:'foto_ids'::uuid[]);
SELECT id, "workflowId", result, "triggerDataId" FROM public.workflow_log
WHERE "triggerDataId" = ANY (:'foto_ids'::uuid[]);
ROLLBACK;
```

Count не заменяет manifest: ненулевые relations требуют адресного просмотра значимых полей
и косвенных face/file dependencies. Не использовать `SELECT * FROM user/shared_link` и не
публиковать пароль, ключ shared link или пользовательскую метаинформацию. Для каждой пары
проверить также content/alias deletion receipts по checksum, даже если receipt принадлежит
уже отсутствующему UUID. Запросы не предполагают, что все references имеют FK.

### Содержимое файлов и старый клиент

На HP для каждого **проверенного абсолютного пути**, сопоставленного по mounts, выполнить
`findmnt -T`, `stat`, `sha1sum`, `sha256sum` и `cmp` для пары. Перед/после чтения сравнить stat;
symlink или изменение файла — повод остановиться. Выполнять по одному файлу, без `find`,
глобального hashing и обхода NAS. Те же пути должны быть читаемы из существующего контейнера
под его обычным runtime UID; не менять chmod/chown/mount. Не отправлять сами фото в Cloud.

После согласованного будущего rollout предотвращения дублей проверить в старом Android:
одна тестовая фотография, already-existing external admission, статус backup, restart/re-sync,
одна UUID/плитка и отсутствие нового Managed original. Учитывать текущую настройку локального
удаления; на реальном Samsung никакие удаления не запускать ради этой проверки. Для read-only
этапа до rollout достаточно сопоставить текущие строки и записать версии клиента/сервера.

Ни один production результат этих проверок не подтверждён в облаке. Итоговый dry-run manifest,
тесты будущего merger и решение о применении оформляются отдельно.
