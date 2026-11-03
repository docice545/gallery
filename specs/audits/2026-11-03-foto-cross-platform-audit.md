# FOTO / Noodle Gallery: аудит совместимости и допуска к выпуску

Снимок этапа A [Issue 18](https://github.com/docice545/gallery/issues/18), 2026-11-03.
**Production NO-GO.** Наличие реализации, успешные отдельные тесты, успешный CI,
подписанный артефакт и проверка обновления на устройстве — разные уровни доказательств.
Этот отчёт фиксирует код и воспроизведённые проверки, а не подтверждает исправность установленного приложения.

## Источники и границы

Прочитаны непосредственно страницы GitHub: полный актуальный текст
[Issue 18](https://github.com/docice545/gallery/issues/18) (`updatedAt=2026-11-03T17:26:45Z`),
[Issue 17](https://github.com/docice545/gallery/issues/17) (`17:26:39Z`, включая раздел 8 и комментарии),
[PR 16](https://github.com/docice545/gallery/pull/16),
[PR 15](https://github.com/docice545/gallery/pull/15),
[PR 7](https://github.com/docice545/gallery/pull/7), включая исторические комментарии и последние уточнения о flaky.
Git refs получены с origin, ancestry и blob equality проверены локально.

GitHub HTML и Git доступны. GitHub API заблокирован сетевым proxy среды (`CONNECT 403`);
это не доказательство отказа прав репозитория. Для API подготовлено добавление `api.github.com`
в настройки среды, но в действующей политике его ещё нет. Поэтому публикация отчёта,
создание PR, authenticated review threads, полный job log и branch protection пока недоступны.
В HTML PR 16 нет видимых review-комментариев; исчерпывающий статус unresolved threads не подтверждён.
Сетевые ограничения не обходились. Этот файл сам по себе не означает публикацию комментария в Issue 18.

Рабочая ветка `codex/issue18-cross-platform-audit` создана от точного HEAD PR 16.
HP, Synology, production DB/Redis/Docker, реальные фотографии, ключи подписи и чужие файлы не использовались.
Тестовые контейнеры ниже относятся только к отдельной Cloud-среде и синтетическим fixtures.
Onboarding-проверки на `main` не присвоены PR 16.

## История и границы сборок

| Направление | Подтверждённый SHA / состояние | Вывод |
| --- | --- | --- |
| main | `b216af2be0dd5867c45221724f9612afff62abb8` | Содержит PR 7 по ancestry |
| PR 7 | `3cc9631b7a2a48d2889808da5db7a62cc1345fea`, open, 68 commits | Base `codex/foto-build17-unified` / `ace2eab962524479a61e6891410983a7f41ba0fa`; повторный перенос не нужен |
| PR 15 | `0c8be542121d415f4d748dda20367044cd200d40`, draft, 11 commits | Base `integration/foto-build32-checkpoint` / `f61b05e1637466db9b53368c7ae6a2bbe76498a0`; полностью предок PR 16 |
| PR 16 | `fda0ef2004bfb0e7f5908eda51e45a817c7be2e2`, draft, 17 commits | Base `fix/foto-build35-stack-trash` / `03d8ee5aa7cbe318736556b380249487beed8b8e`; 70 файлов, +4795/−239; не merged |
| Build 36 backup | `ad7a8e77a3662756a8bb72574ceb98343ad7b706` | Предок текущей Build 37, отдельный checkpoint |
| Build 37 | `6c8882bbf2bfd69dfd8984342c142db25b45f223` | Три коммита после backup; `6c8882bbf` переносит mobile-защиты. История PR 16 не является предком, но дерево `mobile/` побайтово совпадает с PR 16 |
| HP integration (только remote Git) | `3482120f1c2875ef2b16c28e8737ca71243155f9` | Содержит PR 16 и ещё восемь коммитов. Это не проверка checkout или установленного HP |

[Инвентарь открытых PR](foto-2026-11-03/open-prs.json): 13 PR, одна страница, номера 4–16.
Редактор 4/6, dedup 5, compatibility 7, release 8/9, Android 10/11/13/14,
acceptance 12, editor/sync 15, Build 36 16. Их наличие не означает принятую интеграцию.

Восемь коммитов integration после PR 16: четыре уточнения требований/границ
`e09450793`, `b9d5bbae4`, `e4fdb95d1`, `26223d228`, затем:

- [`67b424c70`](https://github.com/docice545/gallery/commit/67b424c70d5c978ce561f93821cc3c9d21acc876): существующее исправление pinned API test для необязательных `acceptOnly` / `accepted`; проверяет определения и optionality до проекции из immutable baseline. Не заменяет baseline hash.
- `9bc0a9b50`: metadata Build 36 и явный source/branch guard в Android release tooling, Java из mise.
- `643d0a79e`: проверка packaged Web, CLI, обоих WASM plugins, BuildKit OCI digest.
- `3482120f1`: baseline миграций Build 35 `0c8be5421`, вместо более старой сборки.

Эти решения следует использовать при последующей интеграции, а не писать заново.
Build 35 остаётся отдельным rollback-артефактом; его bytes/signature/installed provenance здесь не получены.
Build 36 требует universal APK `versionCode=36`, исходный ключ и in-place 35→36;
Build 37 требует отдельной приёмки и `versionCode=37`. Generic store workflow с epoch-minute
versionCode не является рецептом этих custom-сборок.

## Что действительно сделал первый Codex

| Область | Код и регрессии | Статус аудита |
| --- | --- | --- |
| Cold-start Motion | [scope](../../mobile/lib/presentation/widgets/timeline/live_photo_scope.widget.dart), [AutoRoute tests](../../mobile/test/presentation/widgets/timeline/live_photo_scope_test.dart) | Реализовано: live `root.currentSegments` вместо устаревшего `RouteData.isActive`; ModalRoute/TickerMode/lifecycle gates сохранены. Samsung пока не проверен |
| Viewer после Trash | [Web deletion tests](../../web/src/lib/components/asset-viewer/AssetViewer.deletion.spec.ts), [gallery tests](../../web/src/lib/components/shared-components/gallery-viewer/GalleryViewer.spec.ts), [mobile stack tests](../../mobile/test/domain/services/stack_trash_selection_test.dart) | Адресные source fixes уже существуют; Web повторно PASS, native Android pending |
| Stack primary / restore | [repository](../../server/src/repositories/stack.repository.ts), [real DB tests](../../server/test/medium/specs/services/stack-trash-selection.spec.ts) | Locks и primary repair реализованы; синтетические PG-проверки PASS. Membership намеренно сохраняется при 0/1 активном кадре для restore |
| WS и selection | [WS tests](../../web/src/lib/managers/timeline-manager/internal/websocket-support.spec.ts), [selection tests](../../web/src/lib/managers/selection-command-handlers.spec.ts) | Реализовано и повторно проверено в Web; это не доказательство исправления Samsung multi-select |
| Local albums / counts / cleanup | [device cleanup tests](../../mobile/test/unit/presentation/actions/local_album_device_deletion_test.dart), [cleanup action](../../mobile/test/unit/presentation/actions/local_album_cleanup_action_test.dart), [reactive counts](../../mobile/test/providers/infrastructure/local_album_reactive_provider_test.dart) | Реализовано, тесты есть; OS denial/partial completion/MediaStore на устройстве не подтверждены |
| Recently added | [timeline repository](../../mobile/lib/infrastructure/repositories/timeline.repository.dart) | Capture-time sorting и стабильные ID применены в соответствующем пути, без глобальной смены сортировки |

PR 16 сообщает 396 Flutter tests / 25 files, 383 Web / 19 files, 351 backend unit,
24 medium и scoped analysis/format на указанных там code checkpoints.
Это исторические результаты автора, а не новые прогоны этого аудита.
Предупреждения native finalizer при exit 0 не объявляются безвредными без диагностики.
PR также документирует случайно собранный debug APK в run 41595405377 и отменённый run 41626480359;
последующий skip сборки не равен успешной сборке.

## Контракт Backend / mobile / Web

[Полный статический индекс](foto-2026-11-03/api-index.json) содержит **412 OpenAPI operations**,
307 имеют лексические ссылки на operationId в production `mobile/lib` / `web/src`;
также сохранены 19 raw `invokeAPI` call sites. Для каждой операции есть RFC6901 pointer
в [спецификацию](../../open-api/immich-openapi-specs.json), содержащую security, parameters,
requestBody, responses и DTO refs. SHA256 спецификации:
`57547e110e9ab5eb05ff69de9d6ff714d88857b4c9089aada364626d430fe08e`.
Индекс включает все опубликованные операции, в том числе без обнаруженного caller;
лексическая ссылка не доказывает выполнение. Native/dynamic URLs проверяются отдельно ниже.
Это исходный аудит, а не полная HTTP-трасса всех клиентов.

| Поверхность | Текущий контракт / ограничения | Источник |
| --- | --- | --- |
| Login / session / OAuth | Bearer, cookie, session header, API key; scopes и owner проверяет сервер. Это session-token API, отдельный JWT refresh flow не следует придумывать. Logout инвалидирует session; expiry/401 требует проверки reconnect/relogin на установленном клиенте | [auth service](../../server/src/services/auth.service.ts), [mobile auth](../../mobile/lib/repositories/auth_api.repository.dart), [network](../../mobile/lib/infrastructure/repositories/network.repository.dart) |
| Endpoint discovery | `/.well-known/immich`, normalize URL, `/server/ping`; 5s availability timeout. Неверный DNS/HTTP/TLS и ошибки route gate — разные классы отказа | [API service](../../mobile/lib/services/api.service.dart) |
| Timeline / pagination | `/timeline/*`, search page/size/next-page и sync cursors имеют разные контракты. Не подменять UUID/cursor offset-индексом; nullable EXIF/person/media поля разрешаются через DTO и Dart patches | [API spec](../../open-api/immich-openapi-specs.json), [patches](../../mobile/lib/utils/openapi_patching.dart), [timeline repository](../../mobile/lib/infrastructure/repositories/timeline.repository.dart) |
| Media / Live pair | `/assets/{id}/original`, `/thumbnail?size&edited&c`, `/video/playback`; cache version содержит thumbHash. Still и `livePhotoVideoId` — связанные assets; нельзя превращать их в независимые повторные uploads | [image URLs](../../mobile/lib/utils/image_url_builder.dart), [asset DTO](../../server/src/dtos/asset-response.dto.ts), [PhotoKit saver](../../mobile/ios/Runner/Sync/LivePhotoSaveApiImpl.swift) |
| Sync / ACK | JSON-lines `/sync/stream`; version-selected Assets/PartnerAssets/Albums/AlbumAssets; capability-gated новые типы. Legacy `/sync/ack` enum заморожен, extended session получает 409 и использует `/sync/ack/v2`. FOTO отправляет fork-only streams: обратная совместимость FOTO→stock server не заявляется | [controller](../../server/src/controllers/sync.controller.ts), [mobile stream](../../mobile/lib/infrastructure/repositories/sync_api.repository.dart), [pinned tests](../../server/src/utils/client-contracts.spec.ts) |
| Albums / favorites / archive / search | Отдельные owner/shared-space permissions; локальные альбомы не тождественны remote IDs. Favorites пользователя и offline tombstone не заменять глобальным флагом/Trash | [PR 7](https://github.com/docice545/gallery/pull/7), [contract tests](../../server/src/utils/original-noodle-gallery-contracts.spec.ts), [library visibility tests](../../server/test/medium/specs/sync/sync-library-asset-visibility-gate.spec.ts) |
| Trash / errors | Preflight, irreversible admission, status и terminal completion — разные ответы. 409 shared motion сохраняет originals; это намеренное отличие от stock. Нельзя показывать completed по одному accepted. Общие API errors нормализуются фильтром; не все ошибочные ответы описаны per-operation | [asset API caller](../../mobile/lib/repositories/asset_api.repository.dart), [deletion DTO](../../server/src/dtos/asset-deletion.dto.ts), [error filter](../../server/src/middleware/global-exception.filter.ts) |
| Editor copies | Android: exact returned MediaStore ID, проверка bucket/path/identity, durable import retry без второго PNG; только output album opt-in. Magic Eraser optional timezone hint не ломает старые bodyless clients | [edited copy service](../../mobile/lib/domain/services/edited_copy.service.dart), [editor save](../../mobile/lib/presentation/pages/edit/edit.page.dart), [PG copy-date test](../../server/test/medium/specs/services/magic-eraser-copy-date.spec.ts) |
| Upload / background / offline / dedup | Существующие upload checksum/duplicate paths и owner-scoped sync, durable pending operations и thumbnail cache. Android scoped editor import уже готов; iOS fallback `syncLocal(full:true)` не доказывает такой же output album opt-in и backup wakeup | [copy service](../../mobile/lib/domain/services/edited_copy.service.dart), [sync repository](../../server/src/repositories/sync.repository.ts), [offline warmup](../../mobile/lib/domain/services/offline_thumbnail_warmup.dart) |
| NAS / originals / auto-stack | Native Stack DELETE сохраняет assets, suppression/owner guards и единственный внешний processor. Нельзя включать второй worker или отменять исключение Anna из auto-stack; Motion cleanup независим | [production contract](../2026-10-05-production-autostack-design.md), [PG compatibility suite](../../server/test/medium/specs/services/stack-maintenance-compatibility.spec.ts) |

Контракт уже versioned: immutable fixtures FOTO17/Immich3.3.5, расширения sync enum/ACK,
генерация TS/Dart, oasdiff к точной base SHA, coverage backward-compatible Dart patches.
Новую параллельную API-версию или новый SDK здесь создавать не требуется.

### Матрица клиентов

| Клиент | Доказательства | Непроверенная часть |
| --- | --- | --- |
| FOTO Build 35 → 36 Android | PR 15 включён; PR 16 source и targeted regressions; исходники Build 37 mobile сейчас идентичны | Samsung cold start, MediaStore, P0 selection/device-only deletion, signing и in-place upgrade |
| FOTO iOS | Общий Flutter API, PhotoKit native code, Python archive/provenance tests | Native compile именно candidate SHA, реальный iPhone, SideStore re-sign/refresh/upgrade |
| Web | 197 повторных regression tests на PR 16 | Совместный candidate backend/browser E2E, реальные большие библиотеки и perf |
| Stock Immich 3.3.5 Android/iOS | PR 7 frozen schemas, API/PG contracts | Реальные binaries/PhotoKit; 409 shared-motion policy исключает обещание полного stock parity |
| Stock Noodle 5.8 / 5.9 Android | Текущий PR 16 checks показывает success emulator E2E обеих версий | Полные logs сейчас недоступны; physical device, полный набор пользовательских сценариев не подтверждён |
| Stock Noodle iOS/Web | Legacy routes и source fixtures PR 7 | Реальное приложение/distribution и текущая версия backend не проверены |

Последний комментарий PR 7: API 1391 pass / 4 skipped на каждой архитектуре;
Web browser 353 pass **+50 flaky**, UI 114 pass **+2 flaky**, maintenance 3 pass **+1 flaky**.
Это история SHA `3cc9631b7`, не результат PR 16. Старый JSON compatibility gate всё ещё
содержит `BLOCKED_NO_KVM` и `NOT TESTED`; он не отменяет более свежий success emulator checks,
но его также нельзя автоматически переписать в physical-device PASS.

## Samsung Live Photo и раздел 8 Build 37

Исходное наблюдение: cold start `setting=true foreground=true route=false scrolling=false`;
resume без Viewer: 08:10:48 resumed, 08:10:51 route/enabled/visible, 08:10:52 position-advanced.
Тест PR 16 явно воспроизводит cold AutoRoute tab с `routeData.isActive == false`,
при `ModalRoute.isCurrent == true` и включённом TickerMode. Есть tab/viewer/lifecycle сценарии.
Это подходящее source-level исправление именно route eligibility; новый таймер, forced true
или Viewer warmup не нужны. Закрытие дефекта требует того же сценария на Samsung с Build 36.

`UnknownHostException imm.lampax.top` остаётся отдельным DNS/network наблюдением:
production resolver/VPN не проверялся и не менялся. Warmup уже ограничен одной активной
операцией, page=40, 3 consecutive failures, timeout=12s, owner/session/network gates.
В [MainTimelinePage](../../mobile/lib/presentation/pages/dev/main_timeline.page.dart) успешный sync,
owners update, setting/connectivity event могут запускать новый проход с начала после завершения.
Это возможная повторная работа, но cache hit не равен сетевой загрузке. Нужны счётчики
cache hit/miss, прочитанных rows/bytes и profile traces; без них perf patch не обоснован.

| Требование Issue 17 | Текущий статус | Ответственность / приёмка |
| --- | --- | --- |
| **P0 один tap выбирает много фото** | Причина по source audit не установлена; перенос PR 16 не доказывает исправление | Build 37: stable asset IDs, gestures/rebuild, exact selected IDs до подтверждения, reject stale/ambiguous selection; Samsung reproduction |
| **P0 device-only trash** | Есть local cleanup и OS-confirmed result tests; поведение Samsung не подтверждено | Build 37: server copies не трогать, отдельный смысл от album-everywhere; cancel/deny/partial/failure должны сохранять truthful result |
| Ровно **2→1** | Build 36 сохраняет stack membership для restore. Каноническое требование 37 — оставшийся снимок standalone, persisted grouping dissolve где применимо | Межкомпонентная зависимость для автора Build 37: согласовать restore/sync contract, cover/non-cover/offline/restart; не менять backend 36 молча |
| Панели / статус-бар / переключатель годов-месяцев | Новая UX реализация не обнаружена в отличиях mobile 37 от 36 | Build 37, safe-area/insets/zoom/gestures и реальные русские строки |
| Компактные confirmations / notifications | Требование актуально, наличие старых widgets не является приёмкой | Build 37; не объявлять success до ACK, ошибки/partial должны быть видны |
| 120 Hz | Измерений устройства нет | Samsung profile build: UI/raster frame budget 8.33ms, p95/p99, jank и trace; screenshot/unit tests FPS не доказывают |
| Floating toolbar, Save Copy для Live, swipe-left album delete, exit после удаления последнего, 500–700ms animation/reduced motion | Зафиксированы в каноническом Issue 17; не реализованы этим треком | Отдельная Build 37 ветка и собственная приёмка |

## iOS / SideStore

Повторно проверены [project settings](../../mobile/ios/Runner.xcodeproj/project.pbxproj),
[Info.plist](../../mobile/ios/Runner/Info.plist), [branding config](../../branding/config.json),
[build script](../../mobile/scripts/ios_build_only.sh),
[archive verifier](../../mobile/scripts/verify_ios_archive.py),
[IPA packager](../../mobile/scripts/package_unsigned_ios.py),
[release fetcher](../../mobile/scripts/release/ios_unsigned.py),
[SideStore preparation](../../mobile/scripts/release/prepare_sidestore.py).

- Bundle release identity `de.opennoodle.gallery`; app group `group.de.opennoodle.gallery.share`;
  main deployment target iOS 15, ShareExtension 16, Widget 17. Legacy OAuth scheme сохраняется
  намеренно. Branding должен применяться до проверки фактического archive; source plist сам по себе не artifact identity.
- Photo read/add descriptions, background fetch/processing и App Group entitlements существуют.
  Repository team ID не доказывает наличия разрешённых сертификатов/profiles.
- Flutter pinned 3.47.2, frozen packages, codegen, CocoaPods lock, unsigned archive/IPA checks
  уже реализованы. `build-mobile.yml`: macOS 26 / Xcode 26.2; gallery lane: macOS 15.
  Возможность успешной сборки обоими toolchains не подтверждается только YAML.
- Старый iOS-readiness документ не следует читать как текущий список отсутствующего кода:
  [background worker](../../mobile/ios/Runner/Background/BackgroundWorkerApiImpl.swift),
  scoped cache cleanup, Live Photo pair validator/saver и resource export уже существуют.
  Cancellation ждёт native terminal callback; still-only fallback явный, created local ID проверяется.
- `gallery-build-mobile.yml` уже отдаёт `Photos-unsigned.ipa`; дублировать packager не нужно.
  Второй `build-mobile.yml` сохраняет unsigned archive, но не сохраняет созданный им unsigned IPA.
  Release fetcher жёстко привязан к `work`, что мешает проверять отдельную reviewed ветку без её переноса.
- SideStore preparer требует отдельный output, SHA input, действительный выбранный Personal Team,
  сохраняет main/Share/Widget identities и оригинальный IPA; ad-hoc seed **ещё не installable signature**.
  Нельзя придумывать Apple credentials, использовать repository team как credential или обещать отсутствие expiry.
  Лимиты provisioning/refresh/App Groups/extensions проверить на выбранном аккаунте и версии SideStore;
  исторические числа из design doc не являются проверкой текущей политики Apple.
- iPhone required: limited/denied Photos, iCloud-only HEIC/Live resources, cancel/import failure,
  background expiration, login/offline/reconnect, static editor copy→output album→backup,
  trash/restore, оба extensions, reinstall-free upgrade с сохранением local DB/keychain/group data.

## Фактические проверки и существующий CI

[Машиночитаемые результаты](foto-2026-11-03/local-checks.json), exact source `fda0ef200`:

| Запуск в этой среде | Результат | Предел доказательства |
| --- | --- | --- |
| Server unit: client-contracts, original-noodle-gallery-contracts, notification, trash | **102 pass / 1 fail**, 4 files | Schema digest mismatch воспроизведён. Уже исправлен в integration `67b424c70`; immutable baseline не менять |
| Medium: stack-trash-selection, trash-timeline, stack repository, stack-maintenance, magic-eraser-copy-date, sync-stack, library visibility | **61 pass**, 7 files | Реальная отдельная PostgreSQL, migrations, synthetic fixtures; не HP DB |
| Web: viewer deletion, thumbnail, gallery viewer, timeline viewer/delete/keyboard, selection commands, WS, timeline manager, actions deletion | **197 pass**, 10 files | Vitest; не native device и не full browser E2E |
| `python3 -m unittest discover -s mobile/scripts/tests -v` | **108 pass** | Archive/packaging/provenance fixtures; не Swift compilation и не подпись |
| Flutter analyze/test, Android APK, macOS/iOS build | **Не запускались здесь** | Flutter/Android toolchain и macOS недоступны; чужой PASS не присвоен |

Полные текущие [PR 16 checks](https://github.com/docice545/gallery/pull/16/checks)
с job URLs сохранены [отдельно](foto-2026-11-03/pr16-checks.json).
На HEAD `fda0ef200`: failed Dart analysis, API contract regressions, ShellCheck, SQL schema,
Test & Lint Server, Medium, ARM E2E, Unit Test Mobile и Flutter coverage; x64 E2E cancelled.
OpenAPI generation, Web lint/unit/E2E, migration order, stock 5.8/5.9 emulators,
iOS source/simulator contracts, Android durable cache и ряд tooling checks — success.
Build/sign jobs skipped. Failure причины, кроме локально воспроизведённого schema test,
не установлены без logs. Нельзя объявлять их инфраструктурными или закрытыми.

| Проверка / workflow | Уже существует | Нужное уточнение |
| --- | --- | --- |
| [test.yml](../../.github/workflows/test.yml) | Server unit/medium/API E2E, migrations/schema, SDK drift, Web TS/Svelte/unit/browser, mobile unit | Общий красный CI блокирует выпуск; разбирать exact SHA logs, а не выключать assertions |
| [check-openapi](../../.github/workflows/check-openapi.yml) | oasdiff pinned action, exact PR base SHA, fail-on ERR, Dart required-field patches | Вместе с generation drift достаточно; не добавлять параллельный diff tool |
| [static analysis](../../.github/workflows/static_analysis.yml) | Frozen Flutter install/codegen/analyze/format | Нужен успешный exact candidate run; сейчас failed |
| [compatibility](../../.github/workflows/original-noodle-gallery-compatibility.yml) | Pinned stock APK provenance, 5.8/5.9 emulators + disposable backend, native source contracts, cache regression | Physical device result отдельно; старые JSON evidence snapshots имеют дату/границы |
| [build-mobile](../../.github/workflows/build-mobile.yml), [gallery mobile](../../.github/workflows/gallery-build-mobile.yml) | Android signing и unsigned iOS path | PR signing exclusions зависят от имён веток; root job может получить `mich` на новой ветке. Нужен общий запрет PR signing и отдельная unsigned hosted lane |
| [docker](../../.github/workflows/docker.yml) | Build matrix и reusable pinned build action | Retag/push разрешается через `!head.repo.fork`, а не explicit event policy. PR 16 merge skipped — это факт конкретного run, не универсальная гарантия. PR должен build без registry writes |
| [manual server artifact](../../.github/workflows/gallery-trash-server-build.yml) | Artifact-only recipe + rollback proof | Более новые fixes уже в integration; не запускать старый migration baseline как Build 36 release |
| [release wrappers](../../.github/workflows/gallery-release-mobile.yml) | Manual version, source record, existing store signing | Это store release, не автоматически safe Build 36/SideStore. Branch protection / protected environment фактически не проверены через API |

## Решения этапа A и минимальный follow-up

1. **Повторная реализация PR 16/15/7 не нужна.** Сохранить их source checkpoints и отличать
   runtime/device acceptance от reported tests. Schema failure закрывается существующим
   `67b424c70`, release identity fixes — существующими integration commits, отдельной согласованной интеграцией.
2. **Адресный release-tooling fix:** разрешить явно указанную reviewed iOS branch с теми же
   strict SHA/clean/remote/run/artifact guards, default `work` сохранить. Проверить wrong branch/SHA,
   failed/skipped/signed runs и idempotent fetch/retry. Это не требует Apple keys и не касается Android UI.
3. **CI safety:** заменить branch-name exceptions общим запретом PR signing/self-hosted runner/
   registry publication; unsigned Android — hosted, pinned source/version, без key files,
   с подтверждённым отсутствием подписи и SHA receipt. Существующие contract/web/mobile tests сохранить.
4. **Недостающая IPA handoff:** сохранять уже создаваемый unsigned IPA в build-only workflow;
   не выпускать его за signed/install-tested. Не создавать второй SideStore packager.
5. **Не делать без доказательств:** новый LivePhoto patch, warmup/perf rewrite, iOS editor album
   перепроектирование без PhotoKit verification, изменение persisted 2→1 semantics Build 36.
   Эти gaps остаются открытыми; Android section 8 принадлежит Build 37.

## Условия handoff и GO/NO-GO

В этом аудите не получены Docker release digest, original-key signed universal APK или native IPA.
Значения SHA256 таких артефактов отсутствуют, а не заполнены placeholder-успехом.

| Проверка | Где / кто может подтвердить | Допуск |
| --- | --- | --- |
| Exact source + все critical CI checks без failed/cancelled; skipped не PASS | GitHub, candidate SHA; требуется API/log access | Pending |
| Build 35 APK bytes/cert/version + Build 36 universal36 same cert + payload provenance | Существующий trusted signing host/HP; без чтения ключей в Cloud | Pending |
| 35→36 in-place, cold-start/resume/tab/viewer, local-only delete и preserved server photo | Samsung, синтетический test album | Pending |
| Build 37 section 8, exact 2→1, 120Hz trace | Отдельная Build 37 Samsung acceptance | Pending |
| Native unsigned archive/IPA + identities/entitlements + SHA receipt | macOS/Xcode CI at reviewed SHA | Pending |
| SideStore legitimate signing, refresh/expiry, upgrade сохранность | Пользовательский Apple account + iPhone | Pending |
| HP effective image/config, NAS roots, restore/backup evidence, original-preservation policy | Отдельная read-only проверка владельцем и reviewed deployment plan | Pending |

Rollback: сохранить installed Build 35 APK/сертификат и current image digest/config;
подготовить проверенный backup/restore до любого deployment. Сравнение migration sources
с Build 35 не доказывает состояние live DB или возможность простого image downgrade.
Фактическое восстановление проверять на изолированной копии; production rollback не выполнять автоматически.
Не трогать Synology originals и существующий внешний auto-stack processor.

**NO-GO сохраняется**, пока critical CI и native/device/backup evidence не получены.
Документированные pending проверки не считаются завершёнными этапами B–D или production-ready.

## Follow-up после фиксации аудита A

Исходный аудит A сохранён отдельным commit `b076ab127`; таблицы выше описывают
PR 16 `fda0ef200`, а не автоматически обновляются до результатов нового кандидата.
После аудита выполнены адресные изменения:

- `066f65f2a`: iOS unsigned handoff принимает `--expected-branch` с default `work`.
  Локальный branch/SHA, clean tree, remote ref, run branch/SHA и receipt проверяются вместе;
  старый receipt без branch допустим только для исторического `work`. Повторный fetch не
  создаёт новый artifact и не переписывает output другого происхождения.
- PR Android signing закрыт для всех имён веток. Signing по push также закрыт:
  legacy trusted-host job требует manual caller и `android_release=true`, Gallery Android
  signing допускает manual event. Signed iOS inputs на PR/push отклоняются.
- Hosted unsigned universal Android lane сохраняет исходную version/build metadata через branding,
  проверяет фактический package/version, отсутствие v1/v2/v3 signing material, ZIP и библиотеки
  всех трёх ABI, записывает checksum и source SHA. `releaseReady=false`, device acceptance pending.
  **В PR 16 pubspec всё ещё `5.7.3+26`**: такой CI output честно останется 26, а не будет назван
  signed Build 36. Для 36/37 нужны отдельные reviewed release recipes и исходный ключ.
- PR Docker compilation выделен в read-only workflow: существующие server и CPU ML Dockerfiles,
  linux/amd64, `push=false`, без registry login/cache writes/retag. Публикующий Docker workflow
  не запускается для PR. ARM/GPU release coverage этим job не заявляется.
- Root build-only iOS теперь сохраняет уже создаваемый unsigned IPA; второй packager не добавлен.
- По критическому уточнению пользователя добавлены два обязательных Live Photo job, source и
  real-player emulator. [Полный gate и Samsung acceptance](../testing/2026-11-03-live-photo-release-gate.md)
  описывает все восемь сценариев, ordered stage chain, ограничения emulator и 120 Hz.
- Перед Gallery mobile и root Build Mobile signing проверяются успешные exact-source push runs Build Mobile,
  Test и Static Code Analysis. Обязательные Live Photo jobs проверяются в точном attempt;
  skipped/failed/missing/duplicate и недоступный API блокируют этот путь.

Локальная follow-up проверка: **123 Python artifact/provenance fixtures PASS**, **20 workflow-scope
checks PASS**, YAML formatting и `git diff --check` PASS. Новые Dart/native assertions
в Cloud не исполнялись: Flutter/Android SDK здесь отсутствуют. Hosted validation подключён
к push только audit-ветки дополнительно к существующим main/release triggers;
этот push не может запустить signing. Результат hosted run следует проверять отдельно.

Actionlint 1.7.7 после раскрытия YAML aliases и объявления существующих runner labels
показывает одинаковые четыре baseline/candidate замечания: required+default environment в двух
workflows, undefined `steps.token` и отсутствующий `matrix.runner-mapping` в старом Docker publish
workflow. Новых замечаний нет; это **не** общий чистый actionlint PASS. Исходный lint без
нормализации дополнительно не понимает новые GitHub YAML aliases/macOS 26; эти ограничения
старого lint tool отделены от реальных inherited warnings. Эти старые release warnings не исправлены
под видом Live Photo работы и остаются в общей очереди допуска.

Backend schema-test fix и Build 36 release-tool fixes уже находятся в integration и не скопированы
в эту ветку. Android UI и production runtime не изменялись. Native iOS/Samsung acceptance,
подпись/обновление 35→36, physical 120 Hz, актуальный backup/rollback и публикация issue/PR
через недоступный GitHub API остаются незавершёнными. Релиз не разрешён.
