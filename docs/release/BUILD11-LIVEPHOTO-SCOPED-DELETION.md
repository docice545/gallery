# Gallery 5.7.3: безопасное удаление Live Photo JPG/NAS + MP4/SSD

Это серверный patch, а не production deployment. Android Build 12, package IDs,
версии приложений, API-контракт, Compose, storage permissions и workers не меняются.
Обновление до Gallery 5.8.0 не выполняется. Реальные семейные файлы не использовались.

## База, причина и исправления

База ветки `fix/build11-livephoto-scoped-original-deletion`:
`accb078c1bfce1f1fbfbba0f84fe904bf196e108`. Она уже содержит HP split-root fix
`92af234687caeca9307aa7d4ea2a51553eecf9cf` и NFS journal fix
`bb0dbbb2eb8a0ca82c54fb24421f661c6f98af67`.

Подтверждённый владельцем production runtime передаёт в `snapshotOriginal`
только policy.rootIdentities. При upload-only policy путь связанного MP4 на
encoded-video не имеет разрешённого корня, поэтому возникает
`ORIGINAL_OUTSIDE_AUTHORIZED_ROOT`. Нормальная транзакция сохраняет оба failed
receipt с общим operationId, но не удаляет файлы. В Cloud-базе узкий допуск уже
реализован; повторно добавлять весь encoded-video в policy не требуется.
Регрессионный тест воспроизводит старую ошибку настоящим snapshot с upload-only
roots и проверяет штатный retry **тех же** failed receipts.

Найдены и исправлены дополнительные барьеры полного server lifecycle:

1. Service recheck перед unlink разрешал только upload/library root, отвергая
   уже проверенный repository motion root. Теперь исключение действует только
   для конкретного originalPath/assetId после повторной проверки relationship
   в repository. Оно не доступно API подготовки политик и не расширяет roots.
2. SSD quarantine identity хранилась только в одном child receipt. Другая Live
   Photo получала EEXIST. Теперь под прежними global/owner locks используются
   только непротиворечивые bindings из server-owned managed child receipts
   этого owner: canonical generated path, physical root и quarantine identity.
   Диск сам по себе не доказывает регистрацию. Незавершённый чужой intent нельзя
   заимствовать: сначала требуется recovery исходной операции.
3. Shared livePhotoVideoId раньше приводил к пропуску child при удалении JPG.
   Теперь любой лишний parent reference отклоняет операцию до создания intent.
   Проверяются Image→Video, owner, library и другие ссылки на original/sidecar.
4. Порядок публикации jobs не гарантирует порядок выполнения. Родительский
   original ждёт durable companion `files-removed` или `complete`; удаление
   родительской DB row по-прежнему ждёт `complete` companion.
5. Структурная запись новой Live Photo связи теперь сериализована owner lock и
   повторной проверкой child под row lock. Связь, проверенная API раньше,
   не может позднее присоединить ресурс, уже находящийся в irreversible Deleted.
   Обычные живые связи и несвязанные metadata updates сохраняют поведение.

SSD исключение ограничено **managed scope** и точным путём, который формирует
`StorageCore.getAndroidMotionPath(child, child.id)` (`<id>-MP.mp4` в owner root).
Одного `.mp4`, имени или prefix недостаточно. Другие файлы и sidecars проходят
обычную policy. External library не получает неявных прав на SSD; её originals
должны находиться в явно разрешённых library roots. Apple Live Photo/video,
находящиеся в обычном upload/library root, используют обычную авторизацию.
Если реальный generated original имеет другой формат пути — STOP и проверка
writer/source; нельзя вручную переписывать path или расширять roots.

## Защита и совместимость

Новые таблицы, колонки, миграции, ключи и SQL-активация политик не нужны.
Существующие IDs, owner/library, user Trash timestamp и receipt.operationId
сохраняются. Failed files-empty receipts возобновляются через обычный запрос
permanent deletion/штатный worker. Files-removed/complete не переписываются в failed.
Нет ручного удаления tombstones, догадок по отсутствующему original или запуска
legacy FileDelete без его прежней проверки.

`authorized-deletion.ts`, `deletion-recovery.ts`, Ed25519 verification,
checksum, fd-relative capture/unlink, NFS mapped UID/GID, inode/mount identity,
shared original checks и consent revocation не изменены. Существующий NFS intent
protocol используется для SSD так же, как для другого bounded root. Неизвестный
EEXIST и неоднозначное mkdir→observed COMMIT окно остаются fail-closed. Код не
переносит и не удаляет suspect quarantine автоматически.

Смена контейнера допускает только прежний storage-mode rebind после доказанного
совпадения physical root и inode/UID/GID/private mode самого quarantine.
Незавершённый journal другой mount namespace автоматически не переносится.
Recovery-mode по-прежнему проверяет подпись, freshness и соответствие roots.

**Совместимость с NFS Crash Recovery проверена совместным запуском:** сохранены
96 исходных medium tests и все 17 crash tests, включая настоящие SIGKILL worker.
Прежние spec/helper не редактировались ради зелёного результата. Не применять
старый ZIP поверх нового patch и не повторять одни изменения дважды.

## Серая плитка

До исправления permanent-deletion preparation назначала deletedAt и JPG, и
Hidden MP4. Мобильная корзина выбирает строки по deletedAt независимо от Hidden,
поэтому могла показывать второй самостоятельный motion tile.

Теперь Hidden companion остаётся irreversible Deleted с receipt, но без отдельного
Trash timestamp. Still сохраняет исходный timestamp. На штатном retry legacy
failed files-empty companion нормализуется только при подтверждённом unique
Image→Hidden Video, owner/library/operationId. Unrelated Hidden Trash, обычные
видео и offline-index tombstones не изменяются. PostgreSQL tests проверяют
getOwnerTrash и настоящий SyncRepository payload, а не только mocked DTO.

Это доказывает серверную проекцию, но не физическую Android UI. Старый локальный
кэш может требовать штатной синхронизации; после успешного удаления child его
server delete event/sync audit должны убрать строку. Не обещать исчезновения
уже закэшированной плитки до device acceptance и не сбрасывать app data.

## Воспроизводимые проверки

Из `server/` в отдельной dev-среде, Node 24.21.0, pnpm 11.24.0, Vitest 4.1.11:

```bash
./node_modules/.bin/tsc --noEmit -p tsconfig.json
./node_modules/.bin/vitest run --config test/vitest.config.mjs \
  src/utils/authorized-deletion.spec.ts src/utils/deletion-recovery.spec.ts \
  src/utils/live-photo-deletion.spec.ts src/utils/live-photo-deletion.filesystem.spec.ts \
  src/services/asset.service.spec.ts src/repositories/asset.repository.spec.ts --reporter=dot
GALLERY_TEST_DURABLE_POSTGRES=1 ./node_modules/.bin/vitest run \
  --config test/vitest.config.medium.mjs \
  test/medium/specs/services/authorized-deletion.spec.ts \
  test/medium/specs/services/build11-storage-deletion-lifecycle.spec.ts \
  test/medium/specs/services/nfs-quarantine-recovery.spec.ts \
  test/medium/specs/services/livephoto-scoped-deletion.spec.ts \
  test/medium/specs/services/livephoto-trash-projection.spec.ts --reporter=dot
```

Medium setup создаёт собственный PostgreSQL14 и clone DB, SQL-проверяет
fsync/full_page_writes/synchronous_commit=on. Требуется только disposable Docker,
никаких production URL, volumes или NAS mounts. NFS helper эмулирует metadata и
mkdir/root-squash; файлы, SHA, fd, rename/chmod/fsync/unlink настоящие и синтетические.
Это **не** результат на реальном Synology NFSv3/ext4 HP.

Результаты и hashes находятся в `BUILD11-LIVEPHOTO-TEST-RESULTS.json`.
Физические Android Build12/Synology acceptance и production deployment: NOT TESTED.
Новые APK/Docker/IPA не собирались; старые артефакты patch не содержат.

## Применение source patch

Основной server-only patch рассчитан на точный base accb078 выше. В комплекте
есть preimage SHA256 и отдельный cumulative server patch для HP snapshot
`92af234...` из предыдущего архива (LP fix уже включён, NFS recovery ещё нет).
Выбрать **один** patch строго по своему preimage, не оба. Cumulative вариант
проверяет совместное применение двух исправлений; это не разрешение production.
При иной базе сохранить изменения и STOP для review diff, не использовать
force/unsafe-paths и не заменять целиком неизвестные файлы.

В тестовой копии с правами её владельца:

```bash
set -euo pipefail
# PATCH и PREIMAGES — полные пути к выбранным файлам из одного verified комплекта.
: "${PATCH:?Set the selected patch file}"
: "${PREIMAGES:?Set the matching baseline SHA256 file}"
sha256sum -c --strict "$PREIMAGES"
git apply --check "$PATCH"
git apply "$PATCH"
git diff --check
```

Затем выполнить тесты выше. Тестовая БД сама применяет прежние migrations;
не запускать их на production. Для исходного отката без последующих правок:
`git apply --reverse --check "$PATCH"` и `git apply --reverse "$PATCH"`.
Такой source rollback не восстанавливает физически удалённые файлы.

## Важный gate уже созданных intents

Штатный recovery sweep уже умеет повторять pending/failed receipts. Поэтому
запуск исправленного сервера при включённом consent может продолжить ранее
заявленные реальные удаления без нового нажатия на кнопку. Этот patch не
активирует очередь и не создаёт такого нового sweep, но снимает прежний отказ.
Перед будущим production rollout оператору нужно отдельно согласовать отзыв
consent затронутых семейных scopes и отсутствие in-flight destructive операций,
сохранить private inventory существующих intents/jobs. Не стирать их и не
менять SQL. Это **не выполнено** в разработке и требует отдельного разрешения.

Acceptance проводить в отдельном тестовом аккаунте без настоящих originals и
старых pending receipts. Возврат consent реальным владельцам — отдельное явное
решение после review всех их pending/failed intents, а не автоматический шаг
deployment или smoke test. Не отключать microservices ради этого gate.

## Развёртывание после отдельного разрешения

1. Согласовать exact patch source/image, текущий immutable production image и
   совместимый rollback image с подлинным source. Проверить отсутствие новых
   migrations, integrity образа и действительность compatibility receipt.
   Образ этого patch ещё не собран: прежние receipts/артефакты не подменять.
2. Штатным preflight проверить fresh PostgreSQL backup/isolated restore,
   NAS recovery, текущие root/mount identities, consent и полный live queue
   inventory. Сохранить receipts. Не очищать/активировать очереди и не выдавать
   новые permissions. Ранее упомянутые 6/21 jobs — отдельный legacy scope.
3. Построить и проверить **только backend** из согласованного source в изоляции,
   не менять Android Build12. Пройти image-only plan существующего
   `scripts/release/image_release.py`, включая exact effective Compose и rollback.
4. Отдельно утвердить apply. Обновить только выбранный immich-server image
   прежним инструментом, сохранив все mounts/evidence/env/networks/volumes,
   PostgreSQL/Redis, ML, inpainting, Memories и прочие HP services.
   Никаких down -v, remove-orphans или force-recreate вручную.
5. Убедиться, что API **и** microservices работают, health/source/image совпали,
   thumbnails/previews/background jobs действуют. Не устанавливать
   API-only worker overrides и не активировать retention как smoke test.
6. Выполнить acceptance ниже только на отдельно согласованной синтетической паре.
   Массовую очистку старой корзины не выполнять.

## Откат сервера

Отдельно согласовать остановку новых destructive requests через штатное owner
consent для затронутого scope и отсутствие in-flight destructive operation.
Не менять queues/SQL вручную. Сохранить новые receipts/quarantine/evidence и
все оригиналы. Использовать **тот же state** подготовленного image-only plan:

```bash
# Только оператор после отдельного rollback approval и готовности его preflight.
python3 scripts/release/image_release.py rollback --state "$RELEASE_STATE" --execute-approved
```

Это интерфейс существующего инструмента, не выполненная операция. Rollback должен
сохранять API+microservices и все тома. Миграции этого patch отсутствуют; данные
journal/tombstones нельзя стирать или откатывать SQL. Старый runtime может вновь
блокировать Live Photo, поэтому не возобновлять deletion до отдельного решения.
Rollback image не восстанавливает уже удалённые originals; для них нужны
проверенные backups/snapshots и отдельная recovery процедура.

## Acceptance одной искусственной Live Photo после deployment approval

1. В отдельном тестовом аккаунте без реальных originals и старых pending
   receipts создать новую синтетическую пару штатным upload/processing.
   Убедиться через приватную read-only проверку: единственная Image→Video связь,
   owner/library совпадают, JPG в upload-owner/NFS, MP4 по canonical generated
   owner path на SSD. Сохранить оба SHA256 и sizes. Не трогать старые семейные LP.
2. Открыть пару на Android Build12 и web; подтвердить motion playback и thumbnails.
   Переместить её в Trash: видна одна карточка, оба original ещё существуют.
3. Restore: still вернулась в правильное время Timeline, motion доступно,
   SHA обоих original не изменился. Ещё раз Trash только этой пары.
4. Selective permanent delete с существующим owner consent: проверить server
   status complete, две связанные complete receipts с одним operationId,
   отсутствие двух asset rows и двух originals, отсутствие второй серой плитки
   после штатного sync/restart приложения. Соседние файлы и чужой owner неизменны.
5. Повторить запрос того же operation/ID: complete/idempotent, без новых удалений.
   При любом failed/blocked сохранить private diagnostics и **не** чистить DB,
   карантин или очереди. Отдельный тест Empty Trash возможен только в изолированном
   тестовом аккаунте, где нет реальных/посторонних Trash assets.

Реальный NAS/device acceptance остаётся операторским gate. Настоящие family
originals, production DB/Compose, VPN/DNS/AWG/nginx в этой задаче не изменялись.
