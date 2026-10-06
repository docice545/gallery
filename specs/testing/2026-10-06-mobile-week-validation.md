# Library, Trash и финальная мобильная проверка

Начальная база: `1f2faaeb556c02e3df562e4f09a9fb0d21f7cc45`, `work`.
Все исходные commits сохранены. Это продолжение мобильной недели, без Memories
rendering/VAAPI, production deployment и реального Takeout.

## Library

Центральный `libraryCardRegistry` содержит 16 уникальных стабильных IDs/actions:
Favorites, Archive, Public links, Trash, Spaces, People, Places, On device,
Albums, Memories, Folders, Locked folder, Partners, Recently added, Videos,
Live/Motion. Дублирующие Albums/Spaces quick links заменены одной записью.
Albums и Memories переиспользуют существующие routes и previews. Screenshots
не имеет надёжного существующего route; Not in album требует отдельного
изолированного filter scope. Эти optional shortcuts не добавлены.

Настроить: кнопка tune в Library app bar; sheet со всеми карточками, включая
скрытые и временно недоступные, Switch, drag handles, Reset defaults.
Сохраняется точный пользовательский порядок. Последовательные карточки одного
presentation type упаковываются в строки по 2/4; неполная строка занимает всю
ширину. Collection previews ограничены высотой 224 logical px. SliverList
создаёт видимые строки; скрытый People не подписывается на face preview provider.
Скрытие People не меняет settings ML, person data или face-aware framing.

Настройки используют существующий локальный Store key 145, JSON map по
canonical configured server URL + user ID. Это не новый server API и не schema
migration. Logout/relogin сохраняет выбор; другой owner/server имеет свои
preferences. Неподдерживаемые IDs игнорируются, новые добавляются по актуальному
default, скрытые сохраняют положение, reset использует текущий registry.
Записи сериализованы, scope захвачен до await; завершение записи A не меняет B.
Ошибка записи показывается пользователю.

Recently added использует `uploadedAt`, который приходит из server `createdAt`,
а не capture time. Live/Motion — пагинируемый локальный SQL на базе main merged
query: remote still type=image + `livePhotoVideoId`, local native
`playbackStyle.livePhoto`. Правила owners/partners/Shared Spaces, hidden albums,
stack primary, trash и local/remote dedup сохраняются. Hidden motion — ресурс
still, не отдельная плитка. Новых thumbnail requests по каждому tile нет.

## Trash: доказанные механизмы и пределы проверки

Canonical server soft-trash выставляет `status=Trashed` и `deletedAt`; sync V1/V2
передаёт timestamp. Remote/main Photos SQL требует `deletedAt IS NULL`; Trash
требует обратное. Повторный sync/upsert сохраняет timestamp. Поля DTO/API и
30-day policy не меняются. Нет owner-specific fix.

Воспроизведён Android local twin: ранее хешированный local ID получает новое
`updatedAt`; upsert сбрасывает checksum в NULL; local Photos arm временно теряет
связь с retained remote Trash row и показывает local copy. Исправление публикует
изменённую ранее хешированную запись только после проверки native content hash.
Не используются имя файла, capture date или предположение о неизменных bytes.
Новые файлы сохраняют обычный deferred hashing; ошибка/отмена не должна делать
checkpoint успешного незавершённого sync.

Отдельно stack viewer допускал trashed children; repository теперь исключает
`deletedAt != NULL`, сохраняя archive/visibility semantics. Temporal row decoder
учитывает nullable API width/height/duration, обнаруженные новыми sync tests.

Воспроизведена PostgreSQL race external rescan: asset прочитан Active+offline,
после await stat пользователь перемещает его в Trash; старый scan очищает
`deletedAt`, сохраняя status Trashed. Write-time SQL CASE в markOnline сохраняет
пользовательский Trash timestamp, если текущий DB status уже не Active.
Это отдельный server fix без API/schema/migration. Он требует будущего
согласованного server update; production сейчас не изменён.

Эти воспроизведения не доказывают, какой механизм сработал на конкретном Samsung.
Нужно сравнить ID показанного Photos item и Trash item, наличие local copy,
actual app/server source versions. Если внешний файл перемещён/переименован,
external scan может создать новый ID по новому path, сохранив старый в Trash;
это другая identity, которую нельзя автоматически объединять по filename.

## Проверки и дальнейший допуск

Первый полный Flutter run: **4417 PASS, 1 существующий skip**. Library targeted:
**38 PASS** плюс customization UI **7 PASS**. Python iOS lane/archive/icon/IPA:
**79 PASS**. Trash focused **38 PASS**; server **300 unit + 78 PostgreSQL PASS**,
TypeScript/scoped lint/format PASS; final Flutter analyze без замечаний.
Полная повторная проверка после окончательных Trash изменений и
финальный GitHub macOS/Xcode run фиксируются в итоговом отчёте текущей сессии.
Native artifact проверяется строго: все три bundles, nonempty executables,
исходные IDs/App Group, floors 15/16/17, версия **5.7.2 (5)**, compiled icon.
Unsigned IPA имеет `Payload/*.app`, сохраняет extensions и безопасные framework
symlinks; stream copy, ZIP integrity, SHA-256, missing artifacts fail. Подпись
не создаётся и installable IPA без пользовательского provisioning не заявляется.

Pre-existing diagnostics не скрываются: SDK 3.13 выше analyzer 3.12; Flutter VM
finalizer сообщения известны из предыдущих validation docs и не провалили
assertions. Общий Ruff format check нашёл ранее неформатированный
`check_i18n_keys.py`; этот незатронутый файл не менялся, формат затронутых Python
файлов проверяется отдельно. Зависимости не обновлялись ради предупреждений.

Android Cloud SDK и постоянный release key недоступны: native APK здесь не
собирался. [Точные HP-команды](2026-10-06-mobile-week-hp-free-pilot.md) используют
существующий SSD layout, Java 17, Flutter 3.47.2, locked codegen, alias foto и
проверяют фактическую подпись. Не выдан неподтверждённый APK SHA-256.

[Cloud Media Provider](../2026-10-04-android-cloud-media-provider.md) проверен
по Android 16/QPR1 AOSP source: manifest не даёт обычному sideloaded приложению
допуск в системную allowlist. Provider/workaround не добавлен; Samsung policy
физически не подтверждена. Share original/cache и Download/MediaStore сохранены.

## Production server: только план после отдельного разрешения

1. Зафиксировать текущие image ID/digest, HEAD, compose service config и health;
   сохранить предыдущий image под отдельным rollback tag. Не читать credentials.
2. После согласования fetch/fast-forward `work`, построить только server image
   по существующей инструкции с release metadata `IMMICH_SOURCE_REF=v5.7.1` и
   actual source commit. Пользовательский patch не меняет совместимую версию.
3. Recreate только `immich-server` с `--no-deps`, проверить health/version и
   read-only API Trash state. PostgreSQL/Redis/ML не пересоздавать.
4. Schema migration для этого patch не нужна. Не выполнять ручные DB writes.
5. При откате вернуть сохранённый предыдущий image и recreate только server.
   DB rollback не требуется: schema/API не менялись.

Этот документ не разрешает и не выполняет deployment.

## Физическая проверка

Samsung: clean app restart, delta/full refresh, offline→online, сохранённая
локальная копия и server-only managed/external assets для каждого пользователя;
trashed ID отсутствует в Photos, присутствует в Trash, Restore возвращает,
Permanent delete не восстанавливается из cache. Проверить stack children,
Live/Motion pair, local byte edits vs metadata-only revision, сетевые ошибки и
отмену hashing. Anna auto-stack policy не меняется.

Android/iPhone UI: hidden/restore People и других cards, arbitrary reorder,
Reset, пустой набор, phone/tablet layout; local/server photo permissions;
Recently added по added time; Albums/Videos/Live-Motion; sharp DPR≤1440 previews,
face union/contain, autoplay 80%/350ms muted one-shot/no cascade, scroll stop.

iPhone: реальные PhotoKit limited/full/add-only, iCloud-only, HEIC/HEVC и Live
pair share/import/save/fallback; expiration/cancellation/drain и upload resume;
Share Extension/widget/App Groups, signed update/session preservation. Полный
[существующий acceptance plan](2026-10-05-ios-implementation-validation.md)
остаётся базой; если его путь изменился, используйте readiness/implementation
документы из `specs/testing` и `specs/2026-10-05-ios-readiness-design.md`.
Free SideStore/LocalDevVPN pilot остаётся user-side этапом, с проверкой
Personal Team IDs/AppGroupId и минимум двумя refresh cycles.
