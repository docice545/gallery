# Управление Memories: выполненная проверка

Исходный HEAD: `7dd47c463f996d210d53b817aa95d16e757af729`, ветка `work`.
Magic Eraser уже завершён и сохранён этим коммитом; его реализация не начиналась
повторно. История предыдущих функций сохраняется.

## Результат

Owner меню Memory Viewer позволяет скрыть или удалить Memory, включая обычное
«2 года назад» и `gallery_ai_highlight`. DELETE подтверждается сообщением,
что фото и видео останутся в библиотеке. Успешный ответ немедленно убирает
Memory из carousel/list и закрывает viewer. Ошибка сохраняет карточку и показывает
уведомление; отмена продолжает просмотр с прежним zoom.

Скрытие использует optional `{isHidden:true}` в существующем PUT/PATCH. Удаление
использует upstream DELETE. Existing sync и local Drift tombstone обеспечивают
сохранение состояния; owner-scoped фильтр защищает от позднего stale fetch.
Меню недоступно для чужого Memory, видимого через Shared Space.

Ручные действия записывают terminal `dismissed` в существующий `memory_candidate`
под owner advisory lock. Direct/candidate POST и nightly generation проверяют
fingerprint/Jaccard >=0.8; повторное название/дата не отменяют решение пользователя.
Saved candidate нельзя позднее восстановить Save/Later. Assets и original bytes
при этих операциях не удаляются. Схема и миграции не менялись.

Видео останавливается на время меню/диалога; после отмены продолжает уже загруженный
источник. Pending native pause сериализован, фон/закрытие viewer/смена asset
предотвращают позднее возобновление. Успешное удаление сохраняет pause до конца
navigation. В существующий notifier добавлена проверка mounted после native play
acknowledgement, исключающая создание timer после disposal. Timeline preview
остаётся one-shot/muted/non-looping; его алгоритм выбора candidate не изменён.

## Проверки 2026-10-05

| Проверка                                                      | Итог                                      |
| ------------------------------------------------------------- | ----------------------------------------- |
| Mobile regression, 82 файла                                   | **730 passed**, exit 0                    |
| Memory/player focused regression                              | **37 passed**, exit 0                     |
| Полный Dart analyze, fatal infos                              | **No issues found**, exit 0               |
| Dart format затронутых файлов                                 | **20 файлов, 0 изменений**, exit 0        |
| Server Memory unit, 5 suites                                  | **149 passed**, exit 0                    |
| Server regression, 15 suites                                  | **526 passed**, exit 0                    |
| Настоящая PostgreSQL, 4 medium suites                         | **39 passed**, exit 0; 15 новых сценариев |
| Реальный HTTP/API/sync/original filesystem                    | **14/14 contracts**, естественный exit 0  |
| Существующие 168 DB migrations на новой тестовой БД           | passed; schema drift отсутствует          |
| Whole-server TypeScript                                       | passed                                    |
| Server build/postbuild                                        | passed                                    |
| Scoped ESLint / Prettier                                      | passed; ESLint 0 warnings                 |
| OpenAPI, TypeScript SDK generation/build, Dart SDK generation | passed                                    |
| Frozen mobile dependency resolution                           | passed, lockfile не изменён               |
| Localization keys, 10 языков, placeholders/duplicate keys     | passed                                    |
| `git diff --check`                                            | passed                                    |

Числа разных прогонов пересекаются; складывать их как число уникальных tests нельзя.
Основные логи находятся в `/workspace/gallery-validation/memory-*`; это Cloud
артефакты, не файлы production. Mobile regression включает Magic Eraser,
server-only Share/Download, Memories zoom, dense timeline/stack overlays и
Live/Motion one-shot autoplay. Server regression включает Memory, Magic Eraser,
asset/stack и version service/controller/repository.

Реальные БД тесты первоначально обнаружили прежнюю двойную JSONB сериализацию
candidate memberships и metadata updates. Native array/object writes исправлены;
bounded legacy reader сохраняет старые title/context. Первоначальные failures
не скрыты; окончательные перечисленные проверки прошли. Widget тесты также
выявили pause/resume и pending timer проблемы, исправленные с regression tests.

Остались известные environment/upstream diagnostics: experimental Node WASI;
Nest legacy route conversion; тестовый SSR отсутствует. Flutter regression
напечатал VM finalizer diagnostic, встречавшийся и до этой задачи; assertions
и exit status прошли. Это не заявляется как отсутствие любых предупреждений.

## Что не проверено физически

В Cloud нет Android SDK/физического Samsung, macOS/Xcode или iPhone. APK/IPA
не собирались; подпись, system UI и синхронизацию двух физических устройств
проверить владельцу. Автоматические tests используют две независимые owner
сессии, реальный sync и local cache reopen, но не заменяют эту проверку.

Сценарии: hide/delete обычного «2 года назад» и AI с фото+видео; немедленное
исчезновение из всех списков; restart/offline; появление изменения на втором
устройстве; zoom до/после отмены; открытие меню во время видео; background/menu
cancel; originals остаются; следующая AI публикация не возвращает подавленную
подборку. Новый API rejection/lifecycle для внешнего генератора документируется
отдельным дополнением и проверяется после этого baseline.

## HP и production integration

Deployment не выполнялся. Серверный Docker metadata остаётся `BUILD_VERSION=5.7.1`.
Для clean fast-forward, build и пересоздания **только** `immich-server` используйте
[существующий HP runbook](2026-10-05-magic-eraser-hp.md), сохраняя активный Compose
override ластика, если он уже включён. Новую модель/токен повторно создавать не
нужно. PostgreSQL, Redis, ML, AI Memories/carousel/auto-stack не пересоздавать.

Mobile нужно обновить generated OpenAPI client и localization loader/keys;
Drift/Pigeon schema не менялась. Full codegen/постоянный signing key/APK version
и cert verification описаны в том же runbook. Не заменять ключ и не менять IDs.

Внешний generator подтверждён владельцем как API consumer. Повторное создание
подавленной подборки получает HTTP 409. Сам `/opt/gallery-ai/gallery_ai_memories.py`
не прочитан и не изменён: обработка этого ответа, rejection polling и next-day
replacement из буфера интегрируются владельцем по отдельному API контракту.

## Файлы первого Memory дополнения

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
- `server/src/dtos/memory.dto.spec.ts`
- `server/src/dtos/memory.dto.ts`
- `server/src/repositories/memory.repository.spec.ts`
- `server/src/repositories/memory.repository.ts`
- `server/src/services/memory.service.spec.ts`
- `server/src/services/memory.service.ts`
- `server/src/utils/memory-candidate.spec.ts`
- `server/src/utils/memory-candidate.ts`
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

### Документация

- `specs/2026-10-05-memory-user-management-design.md`
- `specs/testing/2026-10-05-memory-management-e2e.md`
- `specs/testing/2026-10-05-memory-management-validation.md`
