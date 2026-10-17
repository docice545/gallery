# Внешний AI Memories API: итог проверки

Работа продолжена поверх Magic Eraser
`7dd47c463f996d210d53b817aa95d16e757af729`. Ручное управление Memories сохранено
в `58027759277f995032d37adfd0feccbfaf18c75e`. Во время push remote получил
пользовательский documentation commit `30b2d01b41489dd8dfcd2470d65a369290b94ecb`.
Обе истории сохранены обычным merge
`2d4c269c76d7d2f1dfa7686f204321f64d6bd8a8`; force push/rebase/squash не было.

## Выполнено

- Ручные hide/delete и немедленное обновление mobile carousel/list, persistent
  suppression, защита originals и existing sync описаны в
  [первом validation](2026-10-05-memory-management-validation.md).
- Read-only аудит external Rule, mixed media, metadata, stock reconciliation,
  retention, Smart Search, preview/video/Live Photo, API keys и Shared Spaces.
- Additive `GET /memories/lifecycle`, `GET /memories/rejections`, owner-only
  pagination; HTTP 409 дополнен `code=MEMORY_SUPPRESSED`. Новых таблиц нет.
- Mobile/web viewers подтверждают первый owner просмотр existing PUT `seenAt`.
  Save/rejection не меняются от просмотра; Shared Space owner не изменяется.
- OpenAPI и TypeScript SDK обновлены; ignored Dart client сгенерирован и проверен.
- [External contract/integration](../2026-10-05-external-memory-integration-audit.md),
  [безопасные HP команды](2026-10-05-memory-hp-update.md) и отдельный
  [iOS distribution report](../2026-10-05-ios-free-distribution-design.md).

## Окончательные результаты

| Проверка                                                       | Результат                                                                      |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| Server regression: Memory, Magic Eraser, asset, stack, version | **554 tests / 15 suites passed**, exit 0                                       |
| Focused Memory unit                                            | **177 tests / 5 suites passed**, включает unknown external Rule reconciliation |
| PostgreSQL, ручные действия и существующий sync                | **39 tests / 4 suites passed**                                                 |
| PostgreSQL, новый lifecycle/rejection                          | **6 tests / 1 suite passed**                                                   |
| Реальный Nest HTTP/API key/PG/sync/original filesystem/restart | **18/18 contracts passed**, естественный exit 0                                |
| Mobile targeted acknowledgement/player/Memory regression       | **85 passed**, exit 0                                                          |
| Mobile полная выбранная regression, 82 файла                   | **735 passed**, exit 0                                                         |
| Полный Dart analyze                                            | **No issues found**, exit 0                                                    |
| Dart format                                                    | **20 файлов, 0 изменений**, exit 0                                             |
| Web Memory/metadata/acknowledgement                            | **41 tests / 3 suites passed**, exit 0                                         |
| Whole-web TypeScript                                           | passed, exit 0                                                                 |
| Whole-web Svelte check                                         | **0 errors / 0 warnings**, exit 0                                              |
| Whole-server TypeScript и server build/postbuild               | passed, exit 0                                                                 |
| Scoped server/web ESLint                                       | passed, 0 warnings                                                             |
| OpenAPI/TypeScript SDK build/Dart SDK generation               | passed, exit 0                                                                 |
| Существующие 168 migrations, schema drift                      | passed на свежей тестовой БД; новых migrations нет                             |

Числа отдельных прогонов пересекаются и не складываются в число уникальных tests.
HTTP helper использует только новую disposable loopback БД, синтетические
accounts/API keys, 16 маленьких JPEG и MP4. Original files каждого asset
проверяются SHA-256 после удаления Memory. Проверяются две owner сессии и
посторонний key, запрет без `memory.read`, typed suppression, saved/viewed
независимость, retention без user rejection, hard-delete history и restart.
Fixtures, PG/Redis containers и native EXIF process закрыты/удалены.

В ходе работы исправлены найденные ошибки: двойная JSONB сериализация старого
candidate writer; pause/resume foreground race и timer после native acknowledgement;
неправильное повторное использование завершённого postgres.js pool в тестовом
restart harness; новое web lint требование использовать `SvelteSet`.
В broad mobile запуске один существующий source-failure test ожидал async file
IO после фиксированного числа event-loop turns и получил 0 callbacks вместо 1.
Fixture теперь ждёт фактического callback с bounded timeout; повторный полный
82-file запуск прошёл 735/735. Assertions не удалялись и production fallback
не менялся ради этого test. Первоначальный failure log сохранён в Cloud.
Окончательные проверки после исправлений проходят. Production код shutdown и
dependencies ради harness не менялись.

Существующие diagnostics: experimental WASI, Nest legacy route conversion,
отсутствующий тестовый SSR, Flutter VM finalizer сообщение в broad regression
до этой задачи. Dart SDK generator также печатает существующее patch newline/
fuzz предупреждение. Они не скрыты и не выдаются за новые test failures.
Android SDK, физический Samsung, macOS/Xcode и iPhone отсутствуют: APK/IPA,
native signature, device UX и реальная межустройственная sync не проверялись.

## Ограничения и остающаяся интеграция

External v3.7 source не входит в checkout, не прочитан и не изменён. Gallery
гарантирует user suppression своих API writes, но consumer должен читать
snapshots, хранить owner ledger, трактовать typed 409, публиковать одну замену
из буфера и сохранять обычный интервал. Direct Smart Search требует legacy flat
body; unrelated structured search/facets inconsistencies только документированы.
Cross-user diversity и preview sanitization остаются внешними задачами;
provider credentials/телеметрия/переиндексация не добавлялись.

Rejection API не является датированным event log: созданный ранее candidate
может стать dismissed позже, hard-delete лишает его provider metadata/Memory ID.
Поэтому полный polling начинается заново и после DELETE использует ledger
fingerprint/membership. Исчезновение без dismissal не считается dislike.
Если external cleanup использует ручной DELETE, его intent необходимо отдельно
разделить до production rollout; автоматический retirement API не внедрялся.

По iOS выполнено исследование/план, а не установка. SideStore stable 0.6.4
официально помечен broken sign-in; исправленный alpha, бесплатный refresh,
App Groups/bundle identity и update automation требуют отдельного подтверждения
и физического пилота. Production-ready zero-maintenance бесплатная подпись
не доказана. Native IDs, entitlements и CI не менялись.

Production HP, существующие AI/carousel/auto-stack scripts, originals, signing
keys и application IDs не затронуты. Ничего не deploy-илось и release не создан.

## Полный список файлов этой работы

### Mobile и tests

- `mobile/lib/domain/services/memory.service.dart`
- `mobile/lib/infrastructure/repositories/memory.repository.dart`
- `mobile/lib/presentation/pages/library.page.dart`
- `mobile/lib/presentation/pages/memory.page.dart`
- `mobile/lib/presentation/pages/memory_list.page.dart`
- `mobile/lib/presentation/widgets/asset_viewer/video_viewer.widget.dart`
- `mobile/lib/presentation/widgets/memory/memory_actions.widget.dart`
- `mobile/lib/presentation/widgets/memory/memory_card.widget.dart`
- `mobile/lib/presentation/widgets/memory/memory_lane.widget.dart`
- `mobile/lib/providers/asset_viewer/video_player_provider.dart`
- `mobile/lib/providers/infrastructure/memory.provider.dart`
- `mobile/lib/providers/photos_filter/memory_lane.provider.dart`
- `mobile/lib/repositories/memory_api.repository.dart`
- `mobile/test/domain/services/memory_service_test.dart`
- `mobile/test/medium/repositories/memory_repository_test.dart`
- `mobile/test/presentation/widgets/asset_viewer/timeline_preview_video_viewer_test.dart`
- `mobile/test/presentation/widgets/memory/memory_actions_test.dart`
- `mobile/test/providers/asset_viewer/video_player_provider_test.dart`
- `mobile/test/providers/infrastructure/memory_provider_test.dart`
- `mobile/test/repositories/memory_api_repository_test.dart`

### Server и tests

- `server/src/controllers/memory.controller.spec.ts`
- `server/src/controllers/memory.controller.ts`
- `server/src/dtos/memory.dto.spec.ts`
- `server/src/dtos/memory.dto.ts`
- `server/src/repositories/memory.repository.spec.ts`
- `server/src/repositories/memory.repository.ts`
- `server/src/services/memory.service.spec.ts`
- `server/src/services/memory.service.ts`
- `server/src/utils/memory-candidate.spec.ts`
- `server/src/utils/memory-candidate.ts`
- `server/test/medium/specs/repositories/memory-lifecycle.repository.spec.ts`
- `server/test/medium/specs/repositories/memory-user-management.repository.spec.ts`
- `server/test/memory-management-real-api.e2e.mjs`

### Локализации

- `i18n/de.json`
- `i18n/en.json`
- `i18n/es.json`
- `i18n/fr.json`
- `i18n/it.json`
- `i18n/nl.json`
- `i18n/pl.json`
- `i18n/ru.json`
- `i18n/zh_Hans.json`
- `i18n/zh_Hant.json`

### OpenAPI

- `open-api/immich-openapi-specs.json`

### SDK

- `packages/sdk/src/fetch-client.ts`

### Web просмотр

- `web/src/lib/utils/memory-viewed.spec.ts`
- `web/src/lib/utils/memory-viewed.ts`
- `web/src/routes/(user)/memories/[id]/[[photos=photos]]/[[assetId=id]]/MemoryViewer.svelte`

### Документация

- `specs/2026-10-05-external-memory-integration-audit.md`
- `specs/2026-10-05-ios-free-distribution-design.md`
- `specs/2026-10-05-memory-user-management-design.md`
- `specs/testing/2026-10-05-external-memory-validation.md`
- `specs/testing/2026-10-05-memory-hp-update.md`
- `specs/testing/2026-10-05-memory-management-e2e.md`
- `specs/testing/2026-10-05-memory-management-validation.md`

### Сохранённый параллельный пользовательский коммит

- `CODEX_MEMORIES_VAAPI_TASK.md` — принят из `30b2d01b41`, его задания здесь не реализовывались.
