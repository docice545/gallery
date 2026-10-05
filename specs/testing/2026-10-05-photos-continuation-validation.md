# «Фото»: продолжение приостановленной задачи и результаты проверки

Дата: 2026-10-05. Репозиторий docice545/gallery, ветка work.
Starting SHA: 171a1f5be28d7d93c1aa4c5b276c4bba27787475.
Production server 5.7.1 и установленный Android 5.7.2 build 2 не обновлялись.

## A. CONTINUATION

При возобновлении сначала проверены working tree, diff, история и настоящий
origin/work. Незавершённая face-aware работа сохранена: локальный DAO/provider
faces, thumbnail geometry/rendering, aspect-preserving local decode, presentation
motion overlay, первые geometry/cache tests и черновики HP docs. Они доведены до
проверенного состояния, а не написаны заново. Первые 84 теста подтвердили исходный
diff; затем добавлены widget/Drift tests и остальные требования новой инструкции.

Существующая история сохранена. Первые два новых коммита:

- 8847de5df41f611775bbc25cd5620bffe2fdab9f — fix(mobile): preserve faces in timeline thumbnails.
- 1b0e0fb47357d238df2620b90056935ed50d6edc — fix(trash): group mobile and web timelines by deletion date.

Tooling, HP/iOS документация и этот отчёт сохраняются следующим отдельным
коммитом. Его точный SHA и результат push приведены в итоговом ответе; SHA не
встраивается в собственный файл коммита. Нет reset/rebase/squash/force push,
main merge, release или production deployment.

## B. FACE-AWARE FRAMING

Завершено в общем Flutter main timeline. Уже синхронизированные asset_face boxes
читаются из индексированного локального Drift запроса; нет дополнительного
asset-detail HTTP, новой face detection или whole-library face cache.

Одно лицо задаёт constrained focal crop; несколько лиц задают union. Helper
учитывает actual decoded aspect ratio и размер плитки, ограничивая сдвиг так,
чтобы лица целиком оставались в source crop. Если union не помещается в cover,
используется contain с прежним размером плитки. Это не постоянный vertical offset.
Invalid/невидимые/deleted boxes исключаются. Нет faces, local-only/unavailable
shared faces или edited координаты — прежний безопасный center fallback.

Локальный decode для известных faces сохраняет source aspect внутри прежнего
thumbnail pixel budget, чтобы PhotoKit aspectFill не обрезал лицо заранее.
Cache identity учитывает размер request. Обновление geometry само по себе меняет
paint, а не playback registration.

Still и текущий motion FittedBox используют один helper. Autoplay selector,
80% visibility, settling delay, mute, one-shot/no-loop/no-cascade, meaningful
scroll, navigation и disposal не менялись. Face updates не создают новый lease.
Оригиналы, EXIF и существующая photo/video pair не меняются. Координаты still
не являются tracking лица в движущемся видео; несовпадающее поле зрения и EXIF
rotation на native decode требуют физической проверки.

Доказательства: geometry, actual PNG render, no-redecode при прежнем request,
реактивный Drift/provider disposal без HTTP, local request aspect, Hero/badges/
selection/tap и активный one-shot. Подробная архитектура:
[thumbnail-framing-design](../2026-10-05-thumbnail-framing-design.md).

## C. TRASH

Authoritative deletion timestamp — существующий server asset.deletedAt,
синхронизированный в mobile remote_asset.deletedAt через V1/V2.

Mobile Trash теперь descending deletedAt, включая day/month/year groups,
temporal scopes и pagination; равные timestamps имеют стабильный ID tie-break.
Дневные группы используют календарь устройства. Существующее optimistic
клиентское время заменяется authoritative server временем после sync.

Web Trash использует прежний time-bucket timeline и UTC deletion groups. Добавлен
режим orderBy=deletedAt только при isTrashed=true, а в AssetResponse и columnar
bucket response — optional deletedAt. DTO/service проверяют комбинацию. Counts,
bucket data и covers используют одну deletion date; headers/sort/live updates/
Restore согласованы. Нет whole-library browser sync или per-thumbnail requests.

Возле полуночи mobile-local и web-UTC день может различаться: это обозначенный
timezone контракт, не изменение capture metadata. Restore снимает deletion state
и возвращает исходную capture chronology. Permanent delete semantics прежние.
fileCreatedAt/localDateTime, EXIF, bytes и Live/Motion links не изменяются.
Новых таблиц/колонок/migrations нет. Старые клиенты совместимы; новая web-корзина
требует обновлённый fork API, который сейчас не deployed.
Подробнее: [trash-date-design](../2026-10-05-trash-date-design.md).

## D. SSD LAYOUT

Зафиксированы фактические пути владельца:

- /mnt/hp-data/gallery-fork — физический checkout.
- /opt/gallery-fork — bind mount того же checkout.
- ~/.gradle → /mnt/hp-data/build-cache/gradle.
- ~/.pub-cache → /mnt/hp-data/build-cache/pub-cache.
- /mnt/hp-data/gallery-inpainting/models/big-lama.pt — существующая модель.
- /mnt/hp-data/immich/... — Gallery data.
- Docker root/build storage остаётся на системном NVMe.

Layout не менялся: нет переносов, второй копии model/caches/checkout, повторного
скачивания модели, изменения mounts/fstab/Docker root или Big-LaMa deployment.
HP docs содержат read-only проверки; прежние release команды отделены как
исторические/будущие действия владельца и в этой задаче не выполнялись.

## E. IOS READINESS

Полная 37-row status matrix и source references:
[ios-readiness-design](../2026-10-05-ios-readiness-design.md).

READY означает реализованную общую логику, а не verified signed iOS build:
Photos/dense layout/filter/selection, upload queue, Magic Eraser editor/server
pipeline, Memories/AI Memories UI, manual stacks, remote Trash actions и auth
имеют shared implementation. Ordinary Share/Download также имеют iOS native paths.

NEEDS_IOS_IMPLEMENTATION — конкретные необходимые изменения:

1. Дождаться cancellation/drain активных sync/hash/upload futures перед закрытием
   DB/engine; передавать достоверный failure/cancel в native completion.
2. Ограничить clearCache собственными cache subdirectories вместо recursive
   удаления всего Directory.systemTemp; защищать active exports/imports/uploads
   и retention системного Share.
3. Сохранить Apple pair identity/resources при исходящем и входящем Live Photo
   Share; нынешний ordinary Share передаёт один файл на asset.
4. Отличать успешный saveLivePhoto от image-only fallback после ошибки пары.
5. Сделать credentials-free macOS build-only lane, правильные archive/artifact
   paths и отдельный signing/export/upload gate.
6. Согласовать заявленную minimum iOS: Runner 15, Share Extension 16, Widget 17.
   Если используется Xcode Cloud, закрепить project Flutter pin и полный codegen.

Опциональный APNs push отсутствует; local notifications реализованы. Android
MANAGE_MEDIA, локальный trash restore, external view intent и lock/charging
controls не нужно копировать в Swift заглушками. Это не блокеры ordinary Share/
Download/Memories, а отдельные native capabilities/parity решения.

NEEDS_TESTING_ON_MAC_IPHONE: PhotoKit limited/full/Add access, Apple Live pairs,
Samsung embedded originals/fallback, iCloud export/upload/Save, native playback
HEIC/HEVC/HDR/orientation, face framing, background expiration/lock/reboot,
native registration, auth/TLS/cookies/endpoint change, notifications, Share
Extension/iPad popover, Memories gestures/mixed media, Eraser gestures/save и
manual stack/Trash UI.

BLOCKED: финальный native release/signing acceptance до macOS/Xcode compile,
проверки profiles/entitlements/App Groups трёх targets и signed install/update
на физическом iPhone. Все 9 Pigeon definitions проверены; 7 Swift-enabled
контрактов имеют implementation/registration. Два intentionally Kotlin-only
API guarded на iOS. Разобраны 10 plist/entitlements файлов.
IPA, signing, bundle ID, native sources и CI не менялись. SideStore dependency
в приложение не добавлялась.

## F. GOOGLE PHOTOS MIGRATION PREPARATION

Реализован standalone Python stdlib parser + indexed matcher + read-only CLI:
offline inventory или owner-verified HTTPS Gallery API. Единственный POST —
существующий metadata search, семантически чтение. Нет originals/previews download,
API mutations, PostgreSQL access или apply mode.

Parser читает только Google Photos subtree либо явно подтверждённый isolated
Photos root. Album требует metadata evidence; plain directory/year/service
не становится album. Новое title-only metadata.json отдельно помечается
REQUIRES_ALBUM_CONFIRMATION и не увеличивает albumsToCreate. Sidecars задают
membership именно в album directory. Поддержаны old albumData/new flat metadata,
JPEG/HEIC/HEIF/RAW/video и другие текущие server-supported extensions, edited/
truncated/indexed names, duplicate provenance и mixed media.

Matcher требует явный owner; online key identity совпадает с ним, все responses
проверяются. Filename-only недостаточно. Доказательства: mapped original path,
name/type, capture timestamp, реальные size/dimensions и подтверждённый content
hash. External library checksum SHA1(path) не считается hash bytes. Optional
hashing потоково читает только независимый source file рядом с metadata, никогда
mapped Gallery target для подтверждения своей догадки.

EXACT/HIGH_CONFIDENCE/AMBIGUOUS/MISSING сохраняют reasons/candidates. Неоднозначный
indexed suffix (N) не превращается в guessed filename. Trashed/offline/locked и
unlinked hidden assets исключены; уверенно найденный server-linked motion
component относится к существующему logical still membership. Фото/видео не
конвертируются и pair не меняется.

Deterministic JSON mapping содержит owner/source JSON/media/Google metadata,
target asset/confidence/evidence/albums и причины ambiguity/missing. Отчёт:
доказанные albums/candidates, proposed new/already ledger-mapped albums,
membership counts, четыре match classes, duplicates/unsupported/unknown.
Отдельно указано число unique existing assets, поскольку один asset может быть
в нескольких albums. Output вне source/media/input files, no overwrite, 0600.

Будущая idempotency подготовлена через read-only owner ledger и set membership
replay; Native album membership API уже не создаёт дубликат при повторном add.
Настоящий apply, atomic journal и crash recovery ещё не реализованы/не разрешены.
Нельзя обещать exactly-once album creation: server album DTO не имеет Takeout
source marker, title-only reuse запрещён. Другой export layout требует
reconciliation. AMBIGUOUS/MISSING никогда не являются автоматической миграцией.

Можно восстановить точно доказанные titles, descriptions и memberships к
найденным existing assets, включая один asset в нескольких albums.
Приблизительно — edited/transformed metadata associations и ограниченный
chronological order, после review. Нельзя придумать manual Google sequence,
cover без устойчивой association, comments/likes/share rights и отсутствующую
metadata; Gallery поддерживает chronological asc/desc, не произвольные positions.
Подробности: [Takeout design](../2026-10-05-google-photos-albums-design.md) и
[tool README](../../tools/google-photos-albums/README.md).

## G. JSON RESTORE PLAN

Сейчас JSON на Synology отсутствуют — ожидаемо. Пользователь восстанавливает их
позже; Codex не восстанавливал и не искал production JSON как обязательное условие.

Нужны оригинальные Google Photos item sidecars для photos/videos, old .json и
new .supplemental-metadata.json (включая исходные truncated/(N) filenames);
metadata каждого user album и sidecars его members в каждом album directory.
Только year sidecars не доказывают album memberships. Сохранить исходное Photos
export tree и filenames; originals повторно не копировать/не импортировать.

Scanner игнорирует настоящую .json extension, не создаёт assets и не применяет
JSON как XMP/EXIF. Два real fast-glob tests это подтвердили. Вернуть JSON рядом
с media допустимо для этой семантики, но directory traversal/watch overhead
ненулевой, unlink может создать noop removal job; HP/NFS/SMB ошибки не проверены.
Поэтому предпочтительно отдельное новое metadata-only место на SSD:

- /mnt/hp-data/takeout-metadata/docice/
- /mnt/hp-data/takeout-metadata/lenia/
- /mnt/hp-data/takeout-metadata/chudo_anna/

Это плановые места, не утверждение о существующих NAS mounts. Реальные Synology
mounts, Gallery library IDs/import paths и их owner allocation не установлены:
production config/credentials отсутствуют в Cloud. Design содержит только
read-only discovery (findmnt, selected Docker mounts, admin GET /libraries).
Оригинальный HP/container путь нельзя угадать по /mnt/hp-data/immich.

После discovery подготовить read-only path-map: metadata relative prefix →
проверенный server originalPath prefix. Для docice выбран audit file
/mnt/hp-data/takeout-audit/docice-path-map.json. Отдельный API key именно docice
передаётся через GALLERY_TAKEOUT_API_KEY с read scopes; пароль/ключ не помещается
в команду или Git. Другие пользователи запускаются отдельно со своим root/key/UUID.
Соответствие Google export выбранному человеку подтверждает владелец; Gallery
asset owner всегда проверяет инструмент.

## H. FILES

Полный список: 58 файлов относительно starting SHA, включая этот отчёт.

### Face-aware framing

- `mobile/lib/data/db/main/dao/person.dart`
- `mobile/lib/presentation/pages/dev/main_timeline.page.dart`
- `mobile/lib/presentation/widgets/images/face_aware_thumbnail_scope.widget.dart`
- `mobile/lib/presentation/widgets/images/local_image_provider.dart`
- `mobile/lib/presentation/widgets/images/thumbnail.widget.dart`
- `mobile/lib/presentation/widgets/images/thumbnail_framing.dart`
- `mobile/lib/presentation/widgets/images/thumbnail_tile.widget.dart`
- `mobile/lib/presentation/widgets/timeline/live_photo_scope.widget.dart`
- `mobile/lib/providers/infrastructure/thumbnail_framing.provider.dart`
- `mobile/test/presentation/widgets/images/local_image_provider_test.dart`
- `mobile/test/presentation/widgets/images/thumbnail_face_framing_widget_test.dart`
- `mobile/test/presentation/widgets/images/thumbnail_framing_test.dart`
- `mobile/test/providers/infrastructure/thumbnail_face_bounds_provider_test.dart`
- `specs/2026-10-05-thumbnail-framing-design.md`

### Trash / API / web

- `mobile/lib/domain/models/timeline.model.dart`
- `mobile/lib/infrastructure/repositories/timeline.repository.dart`
- `mobile/test/infrastructure/repositories/trash_deletion_timeline_test.dart`
- `open-api/immich-openapi-specs.json`
- `packages/sdk/src/fetch-client.ts`
- `server/src/dtos/asset-response.dto.spec.ts`
- `server/src/dtos/asset-response.dto.ts`
- `server/src/dtos/time-bucket.dto.spec.ts`
- `server/src/dtos/time-bucket.dto.ts`
- `server/src/enum.ts`
- `server/src/repositories/asset.repository.ts`
- `server/src/services/timeline.service.spec.ts`
- `server/src/services/timeline.service.ts`
- `server/src/utils/database.ts`
- `server/test/medium/specs/services/trash-timeline.service.spec.ts`
- `specs/2026-10-05-trash-date-design.md`
- `web/src/lib/managers/timeline-manager/timeline-day.svelte.ts`
- `web/src/lib/managers/timeline-manager/timeline-manager.svelte.spec.ts`
- `web/src/lib/managers/timeline-manager/timeline-manager.svelte.ts`
- `web/src/lib/managers/timeline-manager/timeline-month.svelte.ts`
- `web/src/lib/managers/timeline-manager/types.ts`
- `web/src/lib/utils/timeline-util.ts`
- `web/src/routes/(user)/trash/[[photos=photos]]/[[assetId=id]]/+page.svelte`
- `web/src/routes/(user)/trash/[[photos=photos]]/[[assetId=id]]/trash-page.spec.ts`
- `web/src/test-data/factories/asset-factory.ts`

### Takeout tooling / scanner

- `server/src/repositories/storage.repository.spec.ts`
- `specs/2026-10-05-google-photos-albums-design.md`
- `tools/google-photos-albums/.gitignore`
- `tools/google-photos-albums/README.md`
- `tools/google-photos-albums/gallery_inventory.py`
- `tools/google-photos-albums/takeout_albums.py`
- `tools/google-photos-albums/tests/fixtures/album-legacy.json`
- `tools/google-photos-albums/tests/fixtures/album-modern.json`
- `tools/google-photos-albums/tests/fixtures/photo.json`
- `tools/google-photos-albums/tests/fixtures/video.json`
- `tools/google-photos-albums/tests/test_gallery_inventory.py`
- `tools/google-photos-albums/tests/test_takeout_albums.py`

### HP / iOS / developer docs / report

- `AGENTS.md`
- `specs/2026-10-05-ios-readiness-design.md`
- `specs/2026-10-05-production-autostack-design.md`
- `specs/testing/2026-10-04-photos-hp-build.md`
- `specs/testing/2026-10-05-magic-eraser-hp.md`
- `specs/testing/2026-10-05-memory-hp-update.md`
- `specs/testing/2026-10-05-photos-continuation-validation.md`

## I. TESTS / CHECKS

| Проверка                                                                                        | Фактический результат                                                              |
| ----------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Flutter face/timeline/autoplay/main timeline/Share/Download/Eraser/Memories/platform regression | 206 passed                                                                         |
| Flutter Trash/Drift/timeline/temporal scope/sync V1/V2                                          | 210 passed                                                                         |
| Earlier focused face/timeline tests                                                             | 84 passed, входят в последующий regression scope                                   |
| New face integration tests                                                                      | 10 passed, входят в 206                                                            |
| Full flutter analyze --no-pub                                                                   | No issues found, 6.8 s                                                             |
| Dart format edited sources/tests                                                                | 16 files, 0 changes                                                                |
| Server timeline/DTO/database/mapAsset unit                                                      | 214 passed                                                                         |
| Server asset/search/memory/sync/view regression                                                 | 590 passed                                                                         |
| Scanner real crawl/walk suite                                                                   | 22 passed, включая 2 новых                                                         |
| Real PostgreSQL Trash/visibility/auto-stack compatibility                                       | 26 passed                                                                          |
| Последний прогон четырёх новых PG tests после native Restore fixture refinement                 | 4 passed                                                                           |
| Existing server migrations in isolated test DB                                                  | 166 succeeded; новой migration нет                                                 |
| Web timeline/Trash regression                                                                   | 149 passed                                                                         |
| Server build / tsc / SDK build / web tsc                                                        | Passed                                                                             |
| Full Svelte check                                                                               | 0 errors, 0 warnings                                                               |
| Server targeted ESLint / scanner ESLint / pure Trash Svelte page ESLint                         | Passed со всеми правилами                                                          |
| Changed web files ESLint with only broken tscompat/tscompat disabled in CLI                     | Passed; config/dependencies не менялись                                            |
| Full web ESLint                                                                                 | Не завершён: существующий plugin crash, см. ниже                                   |
| Prettier affected server/web / OpenAPI normal codegen / SDK normal codegen                      | Passed                                                                             |
| Python tooling tests                                                                            | 94 passed: 79 parser/matcher/CLI + 15 API adapter                                  |
| Standalone synthetic CLI smoke                                                                  | 1 album, 1 EXACT, повтор byte-identical; inputs unchanged, API/apply не вызывались |
| Ruff format/check / Python compile                                                              | Passed                                                                             |
| iOS static plist/entitlements                                                                   | 10 parsed; Swift compile не выполнялся                                             |
| Changed Markdown Bash syntax                                                                    | 19 blocks bash -n; не выполнялись                                                  |
| Git diff / protected file paths                                                                 | Passed; signing/native/DB schema/dependencies/deployment files не менялись         |

Full web ESLint падает внутри tscompat/tscompat с TypeError reading 'Class'.
На исходном HEAD reproducer также exit 2 (baseline log), то есть это не новый
Trash regression. CLI отключение одного rule для остальных проверок не выдаётся
за успешный полный lint. Существующее Node ExperimentalWarning WASI сохранилось.

Начальные проверки выявили и исправили: Dart import-order infos, неточные RGB
ожидания новой PNG fixture, пустой EXIF fixture (SQL empty UPDATE SET), sanitization
fixture flag, несколько новых обычных lint issues, unsafe test filename и реальную
ошибку sorting нового web day при upsert. Независимый Takeout review обнаружил
offline/hash/output/indexed-name/context ошибки; они исправлены и защищены tests.
Ни один из этих первых failure не скрыт финальным success.

Логи сохранены в Cloud /workspace/gallery-validation/, не коммитятся. Имена:
face-ios-regression-tests.log, trash-timeline-tests.log,
face-trash-flutter-analyze.log, trash-server-final-unit.log,
trash-server-regressions.log, trash-server-pg-tests.log,
trash-server-native-restore-pg-tests.log, takeout-scanner-regression.log,
trash-web-unit.log, trash-web-eslint-baseline.log и google-albums-unittest.log.
Это test environment, не production logs.

## J. RISKS / НЕПРОВЕРЕННОЕ

- Нет физического Samsung, Android SDK native build, macOS/Xcode/iPhone. Новые
  APK/IPA/release не собирались, установленная 5.7.2 build 2 не заменялась.
- Native orientation/PhotoKit/Live fidelity/background/signing gates требуют
  отдельного этапа; конкретные iOS defects только проаудированы.
- Нет реальных Takeout JSON и production inventory: matching quality на семейном
  архиве будет оценена будущим dry-run, а фактические NAS paths ещё надо установить.
- Reserved/year folder names могут совпасть с настоящим названием user album;
  сейчас они исключены консервативно, требуют manual classification.
- Title-only album metadata требует confirmation; arbitrary cover/order и
  crash-safe production apply не реализованы. Последующий apply требует отдельного
  review и разрешения после mapping.
- Read-only live inventory pagination не транзакционная: при одновременном
  изменении library нужен повтор dry-run; duplicate pages fail closed.
- Metadata-only RAM линейна числу assets/records; online page 32 MiB bounded,
  offline inventory 128 MiB, single sidecar 16 MiB. Media/model не загружаются.
- Production server/container/PG/Redis/ML/Big-LaMa, Synology originals,
  Android signing/key alias/IDs, VPN/DNS/AWG/Xray и внешние AI/auto-stack
  scripts/timers не менялись. Второго auto-stack worker нет.
- Новой schema migration нет. Единственное расширение server contract — optional
  deletion timestamps и Trash-only query mode; применяется будущим отдельным
  согласованным server/web обновлением.

## K. NEXT STEP: одна REAL DATA DRY-RUN команда

Выполнять **после** восстановления только Google Photos JSON в указанное isolated
место, read-only discovery actual paths, подготовки проверенного docice-path-map
и отдельного audit output parent. GALLERY_TAKEOUT_API_KEY должен уже содержать
ключ docice с user.read/asset.read/album.read. Command не содержит credentials;
ничего не создаёт в Gallery, не пишет Synology или БД, только новый приватный
локальный report/mapping. Существующий report не перезаписывает.

```bash
python3 /opt/gallery-fork/tools/google-photos-albums/takeout_albums.py \
  --owner de9b2d19-cd6a-4b82-8230-33e17134a3bf \
  --takeout /mnt/hp-data/takeout-metadata/docice \
  --photos-root-confirmed \
  --server https://imm.lampax.top \
  --api-key-env GALLERY_TAKEOUT_API_KEY \
  --path-map /mnt/hp-data/takeout-audit/docice-path-map.json \
  --output /mnt/hp-data/takeout-audit/docice-dry-run.json
```
