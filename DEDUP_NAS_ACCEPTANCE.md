# FOTO Build 17 — повторная приёмка дедупликации, синхронизации и NAS

Область: существующая реализация, синтетические файлы и отдельные PostgreSQL/SQLite.
Ветка `codex/foto-build17-dedup-acceptance`, база `d7a31f3420b483974a7247613791cdbc395cacd4`.
Исправленный source checkpoint: `9cba0246791603e3ff1fbcffaa46e65124906522`. PR: https://github.com/docice545/gallery/pull/5.
Редактор не включён в эту ветку; он передаётся отдельным PR 4.

**Это приёмка кода для локального объединения, не разрешение на production и не проверка HP/NFS.**
PASS всегда ограничен указанным видом теста. Тест с реальной БД и mock очередью не является
полным HTTP/device/worker E2E. NOT VERIFIED не означает успешную проверку.

## Что уже существовало

Сохранены `f687de397f83f0301358151641d2b7e7cfd64312`,
`af2dc2df70f1e93f06b2aa3201f33fe68108c419`,
`97e446038947fb9ee7955f0258b524dedc8ec1b9` и Cloud-исправления из базовой ветки.
`AssetRepository.create/createAll` используют общий advisory lock владельца; managed uploads
имеют unique checksum constraint, внешние записи — owner/library/path checksum.
`asset_duplicate_checksum` сохраняет как фактические content hashes внешнего импорта, так и
пользовательские checksum-resolution aliases. Поэтому имя таблицы не доказывает равенство байтов.
`duplicateId` — группа, включая визуально похожие версии; не разрешение на удаление и не хеш.

External-only оригинал не подтверждает завершённый managed backup телефона. Explicit Trash
блокирует автоматический reupload; Active + deletedAt + isOffline index tombstones сохраняют
другую семантику. Durable permanent-deletion receipts сохраняют запрет воскрешения после удаления.
Эти механизмы не заменялись и политики удаления не включались.

## Воспроизведённые дефекты и исправления

### Backend

Первый корректно подготовленный PostgreSQL прогон: **6 PASS / 5 FAIL**.

1. `AssetRepository.create()` всегда начинал с `duplicateId=null`, теряя переданную группу.
   Теперь сохраняет явно переданное значение. Разные bytes остаются разными assets.
2. Managed checksum-resolution alias мог придать разным файлам одну «точную» группу.
   Теперь для managed keeper проверяется его собственный checksum; upload barrier решения
   пользователя не удалён и не подменён автоматическим восстановлением.
3. Проверялся owner alias, но не owner asset, на который он указывает. Несогласованная legacy
   запись могла изменить чужой duplicateId. В join добавлена независимая проверка owner.
4. Аналогичная чужая alias могла подавить внешний импорт; join createAll теперь проверяет
   согласованность обоих owners. Чужие файлы и metadata не изменяются.
5. Повтор пути в одном пакете/повторная доставка committed batch вызывали unique-constraint
   error и откат всего пакета. `ON CONFLICT DO NOTHING` сохраняет существующие ID/metadata
   и принимает новые записи без перезаписи оригинала.

### Переиндексация offline external original после смены пути

Ещё один подтверждённый дефект: alias указывала на `Active + isOffline=true + deletedAt!=NULL`
external index tombstone и навсегда подавляла найденный под новым путём файл тех же bytes.
Новый regression до исправления: **12 PASS / 1 FAIL**. Теперь только этот узкий класс index rows
исключён из барьера surviving-content. В одной транзакции создаётся новая активная запись и
checksum pointer перепривязывается к ней. Старая offline запись, её ID, timestamp, owner,
library и связи не меняются; она не становится пользовательской Trash. Альбомы между IDs
автоматически не переносятся. Настоящие Trashed/Deleted продолжают блокировать переимпорт.

Дополнительно воспроизведены два отрицательных сценария: две byte-identical исходные записи
в одном batch и failed permanent-deletion receipt с ещё пустым `files`. Теперь один checksum
получает один anchor без PostgreSQL `21000`, при этом обе физические копии/asset IDs сохраняются.
Подготовленный deletion intent блокирует повторный импорт и после смены пути по сохранённым
`checksum`/`aliases`, даже до SHA-256 snapshot. Intents не исполняются и не получают новых прав.
Промежуточные **13 PASS / 1 FAIL** и **14 PASS / 1 FAIL** сохранены отдельно от финальных PASS.
Signed recovery-proof, allowed roots и destructive handler не менялись.

### Мобильная проекция

Новые тесты с настоящим in-memory SQLite: **3 PASS / 5 FAIL** до исправления.
`TimelineRepository` в Spaces, shared albums и общих remote queries делал LEFT JOIN на все
локальные assets с тем же checksum. Один server ID появлялся дважды, count оставался 1,
LIMIT/OFFSET повторяли карточку. Это не два серверных оригинала, а ошибка join cardinality.

Переиспользован уже существующий в main/remote-album scalar lookup: один локальный ID,
с детерминированным tie-break по ID. Локальные файлы/строки не удаляются, identities разных
server assets не склеиваются. Связь motion video не меняется. После исправления **8/8 PASS**.
Автоматические stacks и пользовательские исключения не изменялись.

## Матрица

| Проверка                                                                                  | Файл / механизм                                                                | Доказательство                                                                                                                                        | Статус                                                              |
| ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| Один server original + две локальные копии → одна карточка                                | `mobile/lib/infrastructure/repositories/timeline.repository.dart`              | 8 новых SQLite cases: main/Space/album/Trash/counts/pagination/Live                                                                                   | PASS — SQLite                                                       |
| Один asset доступен напрямую и через External Library shared space                        | тот же repository, существующий membership predicate                           | Новый тест не размножает один ID через два пути доступа                                                                                               | PASS — SQLite                                                       |
| Разные пользователи с тем же checksum                                                     | owner filters, новый scalar lookup, repository admission                       | PostgreSQL mismatched-owner negative cases; SQLite отдельные IDs                                                                                      | PASS — БД                                                           |
| Отредактированная версия с другими bytes                                                  | create, checksum и duplicateId                                                 | Новый PG тест сохраняет группу, исходный файл и отдельный edited ID; SQLite отдельная карточка                                                        | PASS — БД/fixtures                                                  |
| External → mobile                                                                         | `foto-duplicate-admission.spec.ts`                                             | External-only ACCEPT; после managed insert возвращается настоящий managed ID; обе реальные fixture-копии неизменны                                    | PASS — PG/service; не HTTP upload                                   |
| Mobile → External, повторный scan, гонка scanner/upload                                   | `library.service.spec.ts` → `external content identity`                        | На финальном source 6 PASS / 70 filtered SKIP; реальный PG/Crypto/Storage, queue/events mocked. Исторический full PG suite 177 PASS сохранён отдельно | PASS — выбранные service/PG cases; HP NOT VERIFIED                  |
| Новый путь NAS-файла после offline indexing                                               | createAll + checksum anchor                                                    | Новые PG cases: новая active запись, старый offline ID/timestamp/связи и bytes сохранены; повтор идемпотентен                                         | PASS — PG/filesystem, не NFS                                        |
| Явный Trash и pending failed deletion receipt не воскрешаются                             | status и tombstone checksum/aliases                                            | Отрицательные PG cases с offline Trash, receipt files=[], новым путём и двумя физическими копиями                                                     | PASS — isolated DB/fixtures                                         |
| Повторная доставка одного пути                                                            | createAll, unique constraints                                                  | Новый PG тест: дубликат внутри пакета и повтор после commit, ID остаётся один, bytes сохранены                                                        | PASS — PG/filesystem                                                |
| Обрыв между asset insert и checksum commit                                                | транзакция create                                                              | Настоящий PG trigger вызывает исключение; нет частичной asset/group записи или ложного backup ACK; после удаления test trigger retry успешен          | PASS — fault injection в отдельной БД                               |
| Повтор sync, reset/offline, pending deletes, permission retry                             | sync/local-trash/backup repositories/services                                  | 240 Flutter cases, SQLite и mocks native/network отдельно; 129 PG medium cases                                                                        | PASS — указанное покрытие                                           |
| Trash/Restore не портят пагинацию и Live Photo link                                       | timeline + existing Trash services                                             | Новые SQLite transitions; существующие PG deletion/trash tests повторены                                                                              | PASS — БД/fixtures                                                  |
| Постоянное удаление, shared references, roots/receipts/recovery                           | `authorized-deletion.spec.ts`                                                  | Входит в 129 PG cases, guarded unlink synthetic files; работа настоящих Redis workers не проверена этим medium suite                                  | PASS — синтетический filesystem/PG                                  |
| Чужие originals / NAS roots не получают новых прав                                        | patch не меняет authorization, roots, unlink, policies                         | Diff + negative PG cases; signed recovery-proof не отключался                                                                                         | PASS — код/fixtures                                                 |
| Реальная фоновая загрузка Android/iOS после обрыва/перезапуска                            | Native APIs + сеть + backend workers                                           | Нужны физическое устройство и выделенная тестовая библиотека                                                                                          | NOT VERIFIED                                                        |
| Фактический NFS root squash, EIO/ESTALE, reconnect и mount substitution на HP/Synology    | NFS client/server                                                              | Здесь temporary Linux filesystem, не NFS и не Synology                                                                                                | NOT VERIFIED                                                        |
| Одна карточка для двух УЖЕ существующих самостоятельных server assets с одинаковыми bytes | duplicateId / внешнее HP maintenance                                           | duplicateId не используется для такого сворачивания в mobile timeline; он также бывает perceptual. Новая автоматическая группировка не добавлялась    | NOT VERIFIED как продуктовое требование; не объявлено реализованным |
| NAS — файловый источник истины во всех managed/upload layouts HP                          | `/external`, `/data/upload`, `/data/encoded-video`, реальные Compose overrides | Требуется фактическое read-only сопоставление mounts и dev конфигурация после объединения                                                             | NOT VERIFIED на HP                                                  |

Оригиналы с одинаковым именем/датой, но разными bytes не объединялись. Две самостоятельные
физические копии и два server IDs отличаются от размножения одной карточки через JOIN.
Автоматически скрывать/удалять вторую такую запись по одному duplicateId нельзя: это может быть
edited/perceptual версия. Внешний HP stack processor и индивидуальные исключения описаны в
`specs/2026-10-05-production-autostack-design.md`; его актуальный локальный код здесь недоступен.
Второй алгоритм вместо него не включён. Полную product-приёмку этого поведения нельзя объявить PASS.

## Архитектура хранения

Для External Library NAS хранит originals, Immich — каталог, ссылки, индексы, previews и thumbnails.
Удаление из каталога и физическое удаление различаются; writable external scope требует своей
явной политики. Эти изменения не переносят originals, не включают external deletion/retention,
не меняют mounts и не исполняют старые intents. Active offline index tombstones не мигрируются в Trash.

Managed mobile backup использует настроенный `/data/upload`; назвать его NAS-хранилищем можно
только после проверки реального bind mount. `/data/encoded-video/<owner>` может быть SSD.
Нельзя подменять file checksum хешем пути, расширять roots до `/data` или считать external-only
asset доказательством managed backup. Новая PNG редактора — отдельная локальная копия до её
реальной загрузки штатным backup.

Существующее подавление внешнего импорта при уже имеющемся managed checksum не переносит
физический оригинал на NAS и не проверяет его наличие: это admission оптимизация каталога,
не доказательство NAS backup. Если требуется обязательный индекс каждой физической NAS-копии,
это отдельный несовпадающий контракт; текущий pipeline нельзя назвать его полной реализацией.

## Проверки этой ветки

- До последнего offline-index исправления: PostgreSQL medium **129 PASS / 0 FAIL / 0 SKIP**, 4 specs.
- Финальный source: admission **15 PASS / 0 FAIL / 0 SKIP**, scanner **6 PASS / 0 FAIL / 70 filtered SKIP**.
  Это 21 выбранный PG case на финальном коде, не новый полный medium suite. 10 backend и 8 mobile cases добавлены в PR.
- Flutter regression: **240 PASS / 0 FAIL / 0 SKIP**, 7 specs, включая 8 новых.
- Backend scoped unit: **223 PASS** повторены после последнего offline-index исправления; входят в расширенные **6878 PASS / 12 SKIP** ниже, а не прибавляются к ним. Полный suite BLOCKED на одном unchanged SharedSpace spec.
- TypeScript type-check: PASS; targeted ESLint/format: PASS.
- Изменённые Dart repository/test: targeted Flutter analyze PASS.
- Полный Flutter analyze этой отдельной ветки: **FAIL**, 131 diagnostics, отсутствует Freezed старого
  EditorState и связанные ошибки. Это не PASS unified source; PR 4 содержит исправление редактора.
  После локального объединения обязательны generation и полный analyze на реальном merged HEAD.
- Automation/source-only CI guards: 39 PASS; не запускают build/sign/publish для
  двух source-review веток. Обычные validation gates не отключены.

Прежние 11/8 cases входят в 129/240. Финальные 15/6 и повторные 223 относятся к последней server-правке;
не складывать повторные исполнения как уникальные тесты. Более ранние Build 17 результаты
903 unit / 195 medium / 187 Flutter сохранены в базовом handoff и не названы новым прогоном.
Источники, commands, реальные receipts, filtered logs и SHA-256: `foto-dedup-evidence/`.

## Ограничения и следующий шаг

Редактор и дедупликация переданы раздельно. Их совместный merged HEAD в Cloud не создавался
по требованию владельца. Production readiness остаётся **NOT VERIFIED**, включая реальный NAS,
native permissions/background transfer, старые HP изменения и внешний maintenance.
Ни backend image, ни APK, ни подпись в этой задаче не создавались. Не устанавливать прежний APK
как содержащий новые исправления. Порядок объединения/проверки/сборки — `LOCAL_INTEGRATION_HANDOFF.md`.

## Расширенный server unit / CI follow-up

На предыдущем source checkpoint `fb3d89d1aeed42f92a6282a933a0b755d9dd5865` для нового GitHub Server CI FAIL проверены все 215 specs без изменения лимитов. Один запрос
всех specs исчерпал V8 heap 3072 MB при collection; проверенный runner остановлен SIGTERM,
его дерево завершено. Затем выполнены 18 последовательных пакетов оставшихся 212 файлов
(раньше прошедшие 3 specs/223 cases не повторены). Итог: **6878 PASS / 12 SKIP**, 213 specs PASS,
1 opt-in MinIO/S3 integration spec SKIP, 1 `shared-space.service.spec.ts` resource-BLOCKED.
Пакет 13 с OOM не объявлен PASS, хотя остальные 11 specs в нём завершились (1526 PASS).
Тот же SharedSpace файл отдельно исчерпал heap на текущем commit и на точной неизменённой базе
с теми же Node/Vitest/dependencies. Полный server suite остаётся BLOCKED, а не «весь зелёный».

Полная server formatting проверка FAIL в двух byte-identical baseline файлах:
`server/src/schema/migrations-gallery/1793400000000-FixMemoryCandidateSchema.ts` и
`server/src/utils/recovery-evidence.spec.ts`. Целевой Prettier на неизменённой базе повторил FAIL.
Миграция Memories и recovery tests не менялись. Raw GitHub job logs заблокированы network policy
log-storage host; известен шаг `ci-unit`, но его внутренняя причина не выдумана. Все локальные
receipts, pre-fix FAIL, baseline OOM и форматировочные сообщения сохранены в evidence JSON.

Release labels PR 5 исправлены штатным metadata API; source build/sign/publish jobs действительно
SKIPPED на source checkpoint. Их roll-up SUCCESS не считается собранным артефактом.
