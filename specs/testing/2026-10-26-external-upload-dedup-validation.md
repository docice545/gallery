# FOTO: проверка предотвращения External / Managed дублей

Дата: 26.10.2026. Отдельная ветка от `dd1cab300a309d3774f7fab7594501ff8d7ba25c`.
Production, HP, Synology, старый APK и телефон недоступны из Cloud и здесь не проверялись.
Ни deployment, ни сборка/подпись/установка APK не выполняются этим изменением.

## Причина и новый контракт

Прежний admission намеренно не считал active External asset завершённым backup: Managed
поиск исключал `libraryId != null`, поэтому разрешал второй оригинал с file SHA-1.
External использует `sha1-path`; `asset_duplicate_checksum` находил связь содержимого, но
также содержит aliases после разрешения **разных** версий. Он не является доказательством
равенства bytes. Общий `duplicateId` мог сгруппировать уже созданные записи, не предотвращая
создание второго постоянного файла.

Новый admission для уже проиндексированного кандидата проверяет одного владельца asset/library,
active/online/nondeleted состояние, читает существующий External original, сравнивает SHA-1 и
file identity до/после чтения. Источник checksum — фактические bytes, а не имя, EXIF size или
alias. Ожидаемые filesystem ошибки возвращают «нет доступного совпадения» с диагностикой;
остальные ошибки не превращаются в успешный duplicate. Read deadline — 30 секунд на проверку
кандидата; bulk preflight объединяет повторные checksums и не читает кандидатов параллельно.
Это не общий deadline всей большой batch: её длительность зависит от числа кандидатов и NFS.

При достоверном совпадении возвращается **существующий External UUID**, без выдуманного
Managed asset и постоянного второго original. Multipart путь повторяет проверку под тем же
owner serialization перед insert; временный upload очищается штатным путём. Новый файл без
доступного совпадения сохраняется через прежний Managed Upload. Старые Trash/permanent-delete
барьеры остаются отдельными от успешного backup acknowledgement.

Nullable `asset.contentChecksum` отделяет проверенный content SHA-1 от path identity/legacy
resolution aliases. DTO и sync checksum используют content checksum, когда он известен;
это позволяет прежнему клиенту объединять локальный файл с **реальным** External asset.
Новых API endpoints/response properties и обязательного обновления Android не вводится.
Backup acknowledgement подтверждает доступность External в момент проверки, а не обещает,
что пользователь никогда позже не отключит/изменит библиотеку.

Проверка старой версии файла, обнаружившая изменённые bytes, сохраняет новую настоящую
content identity и её свободный alias атомарно. Уже занятый alias не перезаписывается.
Explicit Trash проверяется также по verified content identity, поэтому отсутствие или
конфликт старого alias не разрешает повторно загрузить только что удалённую версию.
Restore сохраняет исходный External UUID/path; ни один original при admission не изменяется.

## Границы доказанного

Автотесты проверяют положительный External admission, multipart без preflight,
повторные/параллельные запросы, прежний SHA-1 API, DTO/sync checksum и локальную merged timeline;
отрицательные случаи — другой owner, другая версия с тем же именем/alias, offline/missing/
изменившийся original, timeout, удалённая библиотека и существующие Trash/deletion receipts.
Файлы — synthetic fixtures, PostgreSQL — изолированный Testcontainers. Точные итоговые команды,
количества и результаты публикуются после завершения общего прогона, не подменяя физическую
проверку NFS/Samsung.

Предварительный checksum-only запрос старого протокола опирается на честный file SHA-1 клиента;
он не содержит bytes для побайтового сравнения с телефоном. На этапе upload проверяется SHA-1
фактически присланного содержимого. SHA-1 протокол не становится криптографическим доказательством
отсутствия специально созданной коллизии.

Сервер не обходит файловую систему в поисках ещё не проиндексированных оригиналов. Если External
файл физически есть, но его asset/identity ещё не индексированы, либо upload выигрывает гонку
**до** индексации, обещать глобально одну физическую копию нельзя без отдельного reconciliation.
Не добавляются NAS crawl, массовый rescan или удаление дублей. Если External недоступен, новая
Managed копия обеспечивает backup; последующее возвращение External может требовать отдельного
разбора. Это ограничение не маскируется скрытием плитки.

Шесть исторических пар не устраняются admission-исправлением. Их зависимости, read-only HP
проверки и проект адресного обратимого объединения описаны в
[`2026-10-26-external-upload-dedup-remediation-design.md`](../2026-10-26-external-upload-dedup-remediation-design.md).
Cleanup tool и его тесты не реализованы; применение требует отдельного согласования.

## Миграция и безопасная подготовка выпуска

Добавлена fork migration `1796000000400-AddVerifiedAssetContentChecksum`: nullable bytea column
и owner/content partial index. **Нет массового backfill** из legacy aliases: они могут
обозначать другую версию, а старый индекс не доказывает нынешнюю доступность файла.
Перед будущим выпуском нужно оценить DDL locks/время индексации на локальной копии схемы и
проверить migration provider на копии существующей пользовательской БД. Production миграции
этим заданием не запускаются.

Прежний `deployment/build-foto-post19-backend.sh` от `b0aeee5` явно требует отсутствия schema
changes: **не применять его без изменений к этой ветке**. Нужен отдельный проверяемый release
recipe с новой миграцией, прежними API/Web/branding/runtime dependencies и неизменными
production mounts. Новый Docker image и rollback image в Cloud не собраны и не проверены.
Выпуск не считается готовым к production на основании одних unit/medium тестов.

## Откат: почему старого image tag недостаточно

После записи новой migration в Kysely history запуск сырого прежнего образа может завершиться
ошибкой missing migration: в нём отсутствует модуль `1796000000400-AddVerifiedAssetContentChecksum`.
Нельзя обещать image-only rollback на исходный `foto-build19-web:e2a95e6` после применения DDL.
Не выполнять `down` в production и не удалять записи migration history ради запуска старого
образа.

До согласованного deployment требуется подготовить **отдельный rollback-compatible image**:

1. Взять точный прежний runtime image/digest; существующий production tag и образ сохранить.
2. Из проверенной сборки скопировать **только один compiled migration module**
   `1796000000400-AddVerifiedAssetContentChecksum.js` в оба прежних runtime каталога
   `dist/schema/migrations/` и `dist/schema/migrations-gallery/` по их фактическим путям.
   Проверить bytes/SHA-256 и сохранение всех прежних migration aliases. Не заменять `dist`
   целиком, package manifests, старую схему/ORM, Web, CLI, настройки и ключи.
3. На изолированной БД с уже применённой новой migration проверить загрузку **старого**
   migration provider с добавленным модулем и запуск старого runtime. Nullable column/index
   остаются в БД и игнорируются старым кодом. Проверка provider в medium test не заменяет
   проверку фактического собранного контейнера и API/sync smoke tests.
4. Выпускать rollback image под новым immutable tag/digest. Переключение образа и откат делать
   владельцу HP отдельно после проверки; исходный Build 19 не удалять и его tag не перемещать.

Откат runtime сохраняет новые nullable данные, но возвращает прежнюю admission-политику:
старый код снова может допускать Managed дубли. Это операционный компромисс, который нужно
учесть до выпуска, а не повод удалять contentChecksum или originals. Откат будущего применения
cleanup — другая процедура; он подробно отделён в документе remediation.


## Итоговые облачные проверки

| Проверка | Результат |
| --- | --- |
| Полный server unit | 6 979 passed; прежние 12 skipped и 1 expected fail; exit 0 |
| Изолированный PostgreSQL | 327 passed, 17 suites, без пропусков/ошибок; 35 admission cases |
| Старый checksum-контракт Android / Drift | 9 Flutter tests passed; Android runtime не менялся |
| Flutter analyze | No issues found |
| Offline-планировщик аудита | 31 synthetic Node tests passed; режима apply нет |
| TypeScript noEmit | passed |
| ESLint / Prettier | все 21 изменённый TS-файл passed; Dart format passed |
| Backend compilation | Nest + tsc-alias passed; postbuild: 79 fork migrations, 2 aliases |
| Docker runtime / Samsung / NAS | не проверялись; deployment и APK не выполнялись |

Проверены настоящий External UUID, повторные/параллельные загрузки, multipart без header,
новые Managed uploads, разные owner/bytes, stale alias, недоступность, смена версии A→B,
штатная библиотечная проверка, offline/online, Trash/Restore без alias, старые API/ACK и
сохранение связей. Реальные supported AssetsV2 и LibraryAssetsV1 streams проверены с PG.
Dart V1/V2 — тесты декодирования/локального объединения; уже deprecated AssetsV1 request
в backend не включался заново. Точную установленную версию APK и физическое поведение проверяет владелец.

Первый полный прогон выявил пропуск новой migration в manifest отдельного fork-conversion
скрипта; исправлены manifest, derived column/index и registry. Сам скрипт не выполнялся
и для rollback не предлагается. Следующий прогон выявил прежнюю зависимость одного теста
очереди от реальных 20 мс; только тест получил управляемые часы, assertions сохранены,
рабочий код очередей/ML не менялся. Окончательный полный прогон успешен. Проверки не отключались.

Для воспроизведения в чистом изолированном checkout с locked dependencies:

```bash
# Из server/: medium использует собственный Testcontainers PostgreSQL, не production DB.
pnpm exec tsc --noEmit
pnpm exec vitest --config test/vitest.config.mjs run
pnpm exec vitest --config test/vitest.config.medium.mjs run \
  test/medium/specs/services/foto-duplicate-admission.spec.ts \
  test/medium/specs/verified-content-migration.spec.ts \
  test/medium/specs/schema-cli-compat.spec.ts
pnpm run build
```

Полная PG-регрессия дополнительно включала существующие asset/library/duplicate/repository,
DB migration и семь sync/visibility/Trash scopes. Cloud использовал pinned Node 24.21.0,
TypeScript 7.0.2, pnpm 11.24.0, Flutter 3.47.2 / Dart 3.13.2 и уже готовые offline caches.
Обычный build не заменяет branded release image и изолированную проверку rollback image.
Штатные Node WASI warnings сохранены в журналах.
