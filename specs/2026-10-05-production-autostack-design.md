# HP: контракт внешнего auto-stack и Motion Photo maintenance

Этот документ — обязательный production-контекст для разработки `docice545/gallery`, ветка `work`.
Данные о HP и количестве стопок предоставлены владельцем 2026-10-05; это снимок, а не результат
обращения из Codex к production. Аудит кода выполнен на
`6a4c8dcda33d9c188fbf696b533d79e0cf2e4ae3` относительно официального production baseline
`da5480ae42b77db9cae729f2447ec9b3079ba4a7`.

## Production и границы изменений

- Noodle Gallery: приложение **5.7.0 build 29825657**, сервер **5.7.1**;
  `https://imm.lampax.top`. Версии приложения и сервера различаются намеренно; этот снимок не
  является указанием понизить версию следующей custom-сборки.
- Единственный автоматический stack processor:
  `/opt/noodle-auto-stacks/noodle-gallery-maintenance.py`.
- Systemd: `noodle-gallery-maintenance.service` и `noodle-gallery-maintenance.timer`;
  timer enabled, active (waiting); первый запуск через 5 минут, затем примерно каждый час.
- Репозиторий HP: `/opt/gallery-fork`; Compose: `/opt/immich/docker-compose.yml`;
  Gallery service `immich-server`, контейнер `immich_server`, custom image `gallery-server:docice-work`.
- Внешние AI Memories, `/opt/gallery-ai/gallery_ai_memories.py`, `gallery-ai-daily.service/timer`
  и `gallery-memory-carousel` остаются отдельной инфраструктурой.
- HP также обслуживает VPN, AWG, Xray, AdGuard Home и DNS/routing. Изменять или перезапускать эти
  компоненты, Docker networking или production-контейнеры в ходе разработки нельзя без отдельного
  прямого указания. Этот аудит не выполняет deployment и не запускает maintenance на HP.

Встроенного auto-stack worker в исследованном коде нет. `asset_exif.autoStackId` извлекается из EXIF,
но не запускает группировку. [Исследование auto-stacking](research/03-automatic-stacking.md) не
разрешает включать второй алгоритм. Перенос внутрь Gallery — отдельная миграция: сначала остановить
и отключить внешний timer/service, убедиться в отсутствии выполняющегося прохода, затем включать
единственный новый processor. Обратный переход требует такого же исключения параллельной работы.

## Политика владельцев

| Пользователь | ownerId | Автоматические стопки | Подтверждённый снимок |
| --- | --- | --- | --- |
| docice | `de9b2d19-cd6a-4b82-8230-33e17134a3bf` | Включены | 423 stacks, 1160 assets in stacks |
| Lenia | `47f6a3fc-75d9-4214-899f-8b4234eb8202` | Включены | 109 stacks, 166 assets in stacks |
| chudo_anna / Anna | `bb8ccc0b-9322-40ea-9ae5-672d497b3e01` | **Намеренно отключены** | 0 stacks, 0 assets in stacks |

У docice после полного пересоздания первый проход создал 423 stacks; второй дал
`EXTEND existing: 0`, `CREATE new: 0`: алгоритм сошёлся. Ранее существовавшие 757 стопок Anna штатно
расформированы через API. Внешний maintenance содержит:

```python
STACK_EXCLUDED_OWNERS = {
    "bb8ccc0b-9322-40ea-9ae5-672d497b3e01",
}
```

Это пользовательское решение. Не удалять исключение и не включать Anna автоматически после
обновления fork. UUID приведены как конфигурационный контекст; не зашивать их в приложение, DTO
или migration. Anna исключена **только из automatic stacks**, но продолжает участвовать в Motion
Photo cleanup. Отключение stacks не должно становиться общим запретом обработки медиа.

## Контракт алгоритма

Используются временная близость фотографий и уже существующие visual embeddings:

| Параметр | Значение |
| --- | --- |
| similarity threshold | 0.90 |
| time window | 300 секунд |
| pairwise floor | 0.89 |
| minimum / maximum stack size | 2 / 5 |
| sharpness ratio | 0.45 |

Существующие стопки сохраняются, одна может расширяться максимум до 5 assets. Автоматически
объединять две существующие стопки нельзя. Primary выбирается по centrality + sharpness с учётом
приоритета ручных решений. Все члены принадлежат одному owner; учитывается `libraryId`.
Cross-owner stacks недопустимы. Новая индексация всей библиотеки или повторный ML-анализ для этой
интеграции не нужны.

Предел 5, одинаковый `libraryId` и запрет объединения двух существующих стопок — правила внешнего
алгоритма. Native ручной Stack API не навязывает эти ограничения: POST с несколькими primaries
может объединить стопки. Не ограничивать ручной API правилами внешнего processor без отдельного
решения. EXTEND через POST может вернуть новый stack ID; consumers используют ID ответа.

## REST API и пользовательские решения

Все внешние stack mutations выполняются **только native Noodle API**. Прямые PostgreSQL записи
для CREATE, EXTEND, смены primary, detach или DELETE запрещены. Серверная реализация API сама
выполняет свои транзакции; это не разрешение внешнему скрипту воспроизводить SQL.

| Endpoint | Permission | Сохраняемый контракт |
| --- | --- | --- |
| `GET /api/stacks`, `GET /api/stacks/{id}` | `stack.read` | Owner-scoped stacks; ответ `id`, `primaryAssetId`, `assets` |
| `POST /api/stacks` | `stack.create` + `asset.update` | `assetIds`, первый становится primary; assets остаются обычными assets |
| `PUT /api/stacks/{id}`; существующий PATCH alias | `stack.update` | Выбор `primaryAssetId` среди членов стопки |
| `DELETE /api/stacks/{id}`; bulk `DELETE /api/stacks` | `stack.delete` | HTTP 204; расформирование, **не удаление assets** |
| `DELETE /api/stacks/{id}/assets/{assetId}` | `stack.update` | Отсоединение не-primary, без удаления original |
| `GET /api/stacks/suppressions?page=N` | `stack.read` | Fork extension: запреты текущего owner, страницы по 1000 `{assetId}` |
| `PUT /api/assets/{id}` / bulk `PUT /api/assets` | `asset.update` | Owner-only structural visibility writes; `hidden` не удаляет original |

`asset.stackId` имеет FK `ON DELETE SET NULL`; удаление stack не вызывает asset/file deletion.
`StackResponseDto` и `AssetResponseDto.stack` (`id`, `primaryAssetId`, `assetCount`) сохранены.
Shared Space editor не получает права создавать личную стопку из чужих assets или менять чужую
visibility. Automation использует API identity соответствующего owner и перечисленные permissions.

В fork уже есть `stack_suppression`: ручное расформирование сохраняет запрет для всех членов,
удаление отдельного члена — для него. Решение и mutation коммитятся вместе; автоматическое создание
берёт тот же owner lock. Запрет намеренно консервативен: asset исключается из будущих автоматических
групп, а не только из одной прежней комбинации. Ручной POST остаётся доступным и не очищает запрет.

### Обнаруженные ограничения и минимальная интеграция

1. **Автоматический POST без признака автоматизации считается ручным.** Для каждого CREATE и EXTEND
   передавать `{"assetIds":["...","..."],"automatic":true}`. Иначе suppression обходится. Server
   проверяет запреты также для expanded children существующего primary внутри транзакции.
   HTTP 400 `Automatic stacking suppressed by user` означает пользовательское решение; не повторять
   запрос с `automatic:false` и не делать бесконечные retries.
2. **Maintenance должен учитывать запреты заранее.** Прочитать все страницы suppressions, начиная
   с 1 и до страницы короче 1000, отдельно для каждого owner и каждого прохода. Исключать assets
   из CREATE/EXTEND и автоматической смены primary; не переписывать вручную восстановленную стопку
   с suppressed members. При недоступности этого API нельзя считать пустой список доказанным и
   продолжать автоматические изменения, обещая сохранность ручных решений.
3. **Смена primary пока не имеет атомарного automatic guard.** PUT/PATCH не различает источник;
   ручной выбор primary не записывается в suppression. Одного предварительного чтения недостаточно
   при гонке. Минимальная безопасная внешняя политика — сохранять primary существующей стопки,
   выбирать centrality + sharpness при создании новой. Если требуется пересчитывать primary при
   EXTEND, нужна отдельная интеграция с явным marker ручного выбора и проверкой внутри API-транзакции;
   нельзя заявлять, что такая защита уже реализована.
4. **Каждый REST DELETE сейчас создаёт suppression.** API не различает пользовательский отказ и
   техническое массовое пересоздание. После DELETE → automatic POST assets будут отклонены.
   Штатный алгоритм сохраняет existing stacks и не нуждается в таком reset. Не добавлять очистку
   suppression в maintenance; административное пересоздание требует отдельного решения, сохраняющего
   реальные ручные запреты. Ранее выполненное расформирование Anna не повторять.
5. **Сам внешний скрипт в Cloud недоступен.** Не подтверждено, что установленная версия отправляет
   `automatic:true`, читает suppressions или сохраняет ручной primary. Наличие native API вызовов
   подтверждает транспортную совместимость, но не все эти гарантии. Проверка/adaptation production
   script выполняется отдельно владельцем, без автоматического редактирования из fork.

Основные REST routes, permissions, payload/response и безопасный DELETE совместимы с baseline.
Полную совместимость приоритета ручных решений нельзя объявить до проверки перечисленных условий
у внешнего consumer. Версия сервера `5.7.1` сама по себе не доказывает наличие fork suppression API.

## Motion Photo cleanup — независимая функция

Серверная модель — обычный photo asset с `livePhotoVideoId`, указывающим на связанный VIDEO;
motion asset скрыт. Samsung embedded motion извлекается существующим metadata pipeline;
Apple paired photo/video связываются существующим owner/library-scoped механизмом. Новые модели,
дубли и отдельная система группировки не нужны.

Cleanup сохраняет связанный hidden motion video, находит лишний standalone VIDEO с тем же basename
и меняет **только его** `visibility` на `hidden` через native API. Basename сам по себе не доказывает,
что видео лишнее: необходимо исключить linked motion components, сохранить owner/library границы
и не менять `livePhotoVideoId`. Оригиналы на NAS физически не удаляются.

Anna остаётся участником cleanup независимо от запрета stacks. Само `hidden` не уничтожает файл,
но штатно меняет доступность в timeline/shared surfaces; этот RBAC/sync контракт не обходить SQL.
Timeline autoplay читает исходную связь, не пишет visibility или stackId; existing linked component
должен оставаться доступным штатному owner playback. Обычный Share/Download и Magic Eraser не
передают право внешнему stack processor менять original. Magic Eraser создаёт статическую копию,
а исходная Live/Motion пара остаётся неизменной.

## Добровольное включение и отключение по пользователю

Требование: каждый пользователь должен иметь возможность отказаться от automatic stacks либо
явно подключиться. Сейчас управление есть **во внешней конфигурации maintenance**, в частности
через `STACK_EXCLUDED_OWNERS`; пользовательского переключателя в mobile/web и поля UserPreferences
ещё нет. Документ не выдаёт будущий API за действующий.

Для нынешней схемы подключение/отключение конкретного owner — явная настройка внешнего processor
владельцем HP. Отключение останавливает CREATE, EXTEND и автоматическую смену primary только для
этого owner. Оно не расформировывает existing stacks, не удаляет assets, не запрещает ручные stacks
и не отключает Motion cleanup. Включение не стирает manual suppression и не запускает полный reset.
После включения обрабатываются только разрешённые assets; снимок количества стопок может меняться.

Минимальная архитектура будущего самостоятельного переключателя:

- Хранить owner preference через существующий `user_metadata` JSON и native
  `GET/PUT /api/users/me/preferences`; расширить DTO/OpenAPI/clients, без отдельной stack-модели.
  Например, `stacks.auto.enabled` — **предлагаемое, пока не существующее поле**.
- На переходе отсутствие явного выбора сохраняет подтверждённую внешнюю политику: docice/Lenia on,
  Anna off; новые пользователи не подключаются без согласия. Не вводить глобальный default-on,
  который отменит исключение Anna. UUID не должны становиться defaults application code.
- Внешний processor явно читает preference в owner-authenticated контексте; для существующего
  preferences endpoint нужен `userPreference.read`. До согласованного rollout его внешнее
  исключение сохраняет приоритет. Недоступность preference после rollout не превращается в opt-in.
- `false` запрещает все автоматические stack mutations; `true` означает только согласие на
  автопроход и не отменяет решения по отдельным assets. Anna может подключиться только после её
  явного решения и согласованного изменения внешнего ограничения, а не из-за upgrade.
- Для надёжного выключения между чтением preferences и POST потребуется server-side проверка
  automatic mutation под тем же owner lock и согласованный контракт внешнего processor. Никакого
  нового worker в Gallery. Первичный opt-in не должен отправлять существующие снимки на повторный ML.
- Motion cleanup имеет независимую политику; не связывать его с этим toggle. UI добавлять вместе
  с рабочей интеграцией consumer и тестами cross-device persistence/отказа/повторного согласия.

Это расширение требует отдельного согласованного изменения fork и внешнего consumer. В этом аудите
production policy и API не менялись; работающий самостоятельный UI-переключатель не реализован.

## Проверенные точки кода и схемы

| Область | Файлы |
| --- | --- |
| Stack REST / DTO / permissions | `server/src/controllers/stack.controller.ts`, `server/src/dtos/stack.dto.ts`, `server/src/enum.ts`, `server/src/repositories/access.repository.ts` |
| Mutation / suppression | `server/src/services/stack.service.ts`, `server/src/repositories/stack.repository.ts` |
| Stack/asset schema | `server/src/schema/tables/{stack,asset,stack-suppression}.table.ts`, `server/src/schema/migrations-gallery/1791070000000-AddStackSuppression.ts` |
| Visibility / Motion API | `server/src/controllers/asset.controller.ts`, `server/src/dtos/{asset,asset-response}.dto.ts`, `server/src/services/{asset,metadata}.service.ts`, `server/src/repositories/asset.repository.ts`, `server/src/utils/asset.util.ts` |
| Sync | `server/src/repositories/sync.repository.ts`, `server/src/schema/tables/stack-audit.table.ts`, `mobile/lib/data/db/main/table/remote/{stack,asset}.dart` |
| Mobile manual stacks | `mobile/lib/repositories/asset_api.repository.dart`, `mobile/lib/domain/services/asset.service.dart`, `mobile/lib/presentation/actions/{stack,manage_stack}.action.dart` |
| Mobile rendering / Motion playback | `mobile/lib/infrastructure/repositories/remote_asset.repository.dart`, `mobile/lib/presentation/widgets/images/thumbnail_tile.widget.dart`, `mobile/lib/presentation/widgets/asset_viewer/asset_stack.widget.dart`, `mobile/lib/presentation/widgets/timeline/{live_photo_autoplay.dart,live_photo_scope.widget.dart}` |
| Web rendering / native actions | `web/src/lib/utils/{asset-utils,actions}.ts`, `web/src/lib/components/assets/thumbnail/Thumbnail.svelte`, `web/src/lib/services/asset.service.ts`, `web/src/lib/components/asset-viewer/actions/AddToStackAction.svelte` |
| Future owner preference | `server/src/dtos/user-preferences.dto.ts`, `server/src/utils/preferences.ts`, `server/src/services/user.service.ts`, `mobile/lib/domain/models/user_metadata.model.dart` |

Относительно baseline asset/stack таблицы, Asset API/DTO, visibility, metadata Motion extraction,
permissions и access repository не изменились. Fork добавил suppression table/migration и строгую
проверку ownership selected/expanded stack assets, сохранив обычные responses. Существующие
`1791071000000-AddMemoryCandidates` и `1793400000000-FixMemoryCandidateSchema` относятся к Memories,
не меняют stackId/visibility/Motion representation. Последние Memory/Magic Eraser задачи не
добавляют stack mutations. В этом аудите новых migrations и API нет; schema reset запрещён.

Для native acceptance на Samsung следует отдельно проверить: unstack/detach переживает следующий
автопроход; выбранный вручную primary сохраняется; docice/Lenia обрабатываются, Anna остаётся без
automatic stacks и с рабочим Motion cleanup; hidden linked video воспроизводится; Gallery/«Фото»
и web получают stack changes через штатную sync. Физический телефон и установленный HP script
в Cloud не проверялись.

## Воспроизводимая проверка контракта

На этом checkout прошли 253 server unit tests (Stack/Asset controller и service, 4 suites),
40 PostgreSQL tests (6 suites, включая 8 новых контрактов), 101 Flutter test (9 suites),
38 web asset service/utils tests (2 suites), server
`tsc --noEmit`, scoped ESLint/Prettier и `git diff --check`. На свежей изолированной PostgreSQL
успешно выполнены 166 existing migrations, включая StackSuppression и corrective MemoryCandidate.
Новых schema/API изменений нет. Предупреждение Node `ExperimentalWarning: WASI` уже существовало.

Новый `server/test/medium/specs/services/stack-maintenance-compatibility.spec.ts` проверяет реальные
DB результаты: asset-preserving dissolve, сохранность hidden Motion video/link, owner isolation,
automatic rejection после ручного unstack, разрешённое ручное восстановление без очистки решений,
suppression expanded children, detach, native extension и скрытие только standalone VIDEO.
Первичные прогоны нового suite выявили ошибки fixture: пустой EXIF upsert и ненастроенный strict
event mock. Fixture исправлен, все 40 tests повторного прогона прошли; runtime не менялся.

При готовых зависимостях, generated clients и локальном Docker daemon:

```bash
# Из server/. Testcontainers создаёт отдельную PostgreSQL, production DB не используется.
pnpm exec vitest --config test/vitest.config.medium.mjs run \
  test/medium/specs/services/stack-maintenance-compatibility.spec.ts \
  test/medium/specs/services/stack.service.spec.ts \
  test/medium/specs/repositories/stack.repository.spec.ts \
  test/medium/specs/sync/sync-stack.spec.ts \
  test/medium/specs/sync/sync-partner-stack.spec.ts \
  test/medium/specs/services/shared-space-stacks.spec.ts
```

Flutter suites покрывают ручные stack actions/API, dense layout и overlays, motion thumbnails,
viewport visibility, one-shot/no-loop, новую область после meaningful scroll и disposal playback.
Нативную сборку и Samsung/Telegram/PhotoKit этим тестированием не подтверждаем; Android SDK,
macOS/Xcode и физические устройства в Cloud отсутствуют.
