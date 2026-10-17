# Контракт внешнего генератора Memories

Gallery AI v3.7 — отдельный сервис. По предоставленному контракту он использует
официальный `POST /api/memories`, создаёт `type: "rule"` с
`data.ruleId: "gallery_ai_highlight"`, хранит `title`, `subtitle`, `dedupeKey`,
`score`, `context`, `generator`, `version`, `theme` и объединяет фото и видео.
Три пользователя имеют отдельные API keys. Исходники и production-конфигурация
этого сервиса не входят в Gallery checkout и этой работой не изменяются.

Документ дополняет [дизайн ручного управления Memories](2026-10-05-memory-user-management-design.md):
тот описывает hide/delete и durable suppression; здесь зафиксированы read API
для внешнего сервиса, реальные ограничения поиска и media API.

## Owner-only lifecycle snapshot

`GET /api/memories/lifecycle` требует `memory.read`. Владелец берётся только из
аутентификации, а не из query. Данные партнёров и SharedSpaces не включаются,
даже если обычный список Memories доступен через sharing.

Параметры: `size` — integer 1..1000, default 100; `after` — UUIDv4 последнего
выданного элемента. Сортировка — UUID `id` ascending. Следующая страница
использует `id > after`. Ответ:

```json
{
  "items": [
    {
      "assetIds": ["<photo UUID>", "<video UUID>"],
      "data": {
        "dedupeKey": "<provider key>",
        "generator": "gallery_ai",
        "ruleId": "gallery_ai_highlight",
        "title": "День у моря",
        "version": "3.7"
      },
      "fingerprint": "<sha256>",
      "id": "<memory UUID>",
      "isSaved": false,
      "seenAt": "2026-10-05T12:00:00.000Z",
      "type": "rule"
    }
  ],
  "nextCursor": "<last emitted memory UUID>"
}
```

`seenAt`, `showAt`, `hideAt`, `deletedAt` отсутствуют при SQL NULL.
`nextCursor` отсутствует на последней странице; пустой ответ — `{"items": []}`.
`data` сохраняет неизвестные поля и нормализует поддерживаемые legacy
JSON-string/array формы тем же `memoryData`, который используется обычными
Memory DTO. Read API ничего не переписывает в БД.

Это полный snapshot **существующих строк Memory**, включая будущие, скрытые,
saved, pending proposals и строки без отображаемых assets. Hard-deleted Memory
в нём уже нет. `assetIds` — фактические `memory_asset` relations: нет фильтра
thumbnail, Timeline visibility, archived/trashed status или скрытых альбомов.
API не читает originals и не даёт право на media. Каждое последующее чтение
asset/preview/video отдельно проходит соответствующую проверку доступа.

Fingerprint — SHA-256 от уникальных asset IDs, отсортированных и соединённых
запятой. Он отражает membership, а не provider key, тему, название, дату или
содержимое файла. Пустой membership имеет SHA-256 пустой строки.

Реализация: `MemoryController.getMemoryLifecycle`,
`MemoryService.getLifecycle`, `MemoryRepository.getLifecycle`, DTO в
`server/src/dtos/memory.dto.ts`. Repository намеренно читает только `memory`
и `memory_asset`, без JOIN к asset-проекции обычного viewer.

## Durable rejection snapshot

`GET /api/memories/rejections` использует ту же owner-only authentication,
permission и UUID pagination. Он читает только существующие
`memory_candidate.state = "dismissed"`:

```json
{
  "items": [
    {
      "assetIds": ["<photo UUID>", "<video UUID>"],
      "fingerprint": "<sha256>",
      "id": "<candidate UUID>",
      "memoryId": null,
      "state": "dismissed"
    }
  ]
}
```

`assetIds` нормализует поддерживаемые legacy JSON strings в массив; запись в
БД не изменяется. `memoryId` обязательно nullable: FK `ON DELETE SET NULL`
сохраняет rejection после физического удаления Memory. Saved/pending candidate
не входит в этот endpoint. Нет JOIN, требующего surviving Memory.

Это snapshot решений, не event feed. В таблице нет decision timestamp или
`updatedAt`; старый saved/pending row может стать dismissed намного позже
своего `createdAt`. Этот timestamp намеренно не выдан как время решения.
`remindAt` также не является временем решения.

## Polling и внешний ledger

Каждый polling cycle начинает оба обхода **без `after`**, получает страницы
через `nextCursor` до его отсутствия и затем объединяет результат с предыдущим
состоянием. Cursor позволяет обойти текущие строки, но не является checkpoint
новых событий. UUIDv4 не отсортирован по времени; новая строка может оказаться
перед предыдущим cursor. Несколько HTTP pages не образуют единую атомарную
транзакцию: изменения во время обхода обнаруживаются следующим полным cycle.

Генератор хранит ledger отдельно для каждого authenticated owner:
provider `dedupeKey` → accepted Memory UUID, фактический fingerprint и membership.
После hard DELETE provider metadata и original Memory UUID нельзя восстановить
из nullable candidate FK. Fingerprint и asset IDs позволяют связать сохранившийся
rejection с ledger; API не обещает восстановления provider key.

Исчезновение Memory из lifecycle само по себе не означает ручной отказ.
Retention и nightly overlap reconciliation удаляют Memories без записи
rejection. Explicit hide/delete/candidate-dismiss создают durable dismissed
membership. `isSaved`, `seenAt` и rejection — независимые признаки:

| Признак                          | Значение                                                                                                            |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `seenAt`                         | Последняя подтверждённая запись о просмотре; отсутствие не доказывает, что старый клиент никогда не открывал Memory |
| `isSaved`                        | Текущее сохранение Memory; не ручной отказ и не просмотр                                                            |
| `showAt`/`hideAt`                | Расписание показа; истечение окна не rejection                                                                      |
| `deletedAt` в lifecycle          | Существующая hidden/dismissed tombstone                                                                             |
| Rejection membership             | Terminal ручное решение не предлагать существенно ту же подборку                                                    |
| Исчезнувшая Memory без rejection | Удалённая строка с неизвестной внешнему poller причиной; не следует придумывать user decision                       |

Новые mobile и web viewers подтверждают первый просмотр собственной Memory
через существующий PUT с одним полем `seenAt`. Каждый viewer отправляет не более
одного такого запроса на Memory, без запроса на каждый кадр/asset; чужие Shared
Space Memories не изменяются от имени владельца. Ошибка/offline не прерывает
просмотр. Старый клиент и неудачная acknowledgement оставляют состояние unknown.
`isSaved=false` и отсутствие `seenAt` **никогда не являются dislike**.

Сервер подавляет повторное создание существенно той же подборки по owner и
Jaccard overlap >=0.8. Порядок IDs, новая дата, title, ruleId и saved flag не
обходят запрет. Duplication файлов с новыми asset IDs этим правилом не определяется.

`MemorySuppressedException` остаётся HTTP 409 и сохраняет English message:

```json
{
  "code": "MEMORY_SUPPRESSED",
  "message": "A similar memory was hidden or deleted by the user"
}
```

Внешний сервис считает именно этот code terminal suppression. Другие 409 могут
обозначать duplicate candidate или уже принятое решение и не равнозначны ему.
Обычный POST не idempotent по `data.dedupeKey`: повтор после timeout способен
создать active duplicate. Новый read-контракт не добавляет idempotency; ledger
и проверка результата остаются обязанностью внешнего сервиса.

## Совместимость существующих Memory writes

`MemoryCreateDto.data` — произвольный JSON record. Создание сохраняет custom
metadata. Неизвестный `gallery_ai_highlight` видим и unmanaged для nightly overlap
reconciler: он не strip/delete такую Memory. Unsaved Memory по-прежнему подчиняется
обычному retention. Если в будущем ruleId зарегистрируют как native type, эту
границу управления потребуется пересмотреть.

PUT/PATCH update принимает `isHidden`, `isSaved`, `seenAt`, `memoryAt`, `title`,
`subtitle`; произвольный `data` PATCH не поддерживается. Изменение title/subtitle
merges поверх existing data и сохраняет остальные поля. PATCH исключён из
OpenAPI; документированный SDK использует PUT. Этот контракт не расширяет writes.

Creation и add-assets owner-only. Обычный POST молча отбрасывает не-owned IDs;
returned `assets` также является отображаемой Timeline/non-trashed проекцией.
Поэтому fingerprint из response thumbnails не всегда совпадает с фактическим
membership. Новый lifecycle даёт каноническое значение. Для трёх независимых
owners подборка формируется в их отдельных scope.

## Реальный Smart Search и media API

Проверено по `search.controller.ts`, `search.service.ts`, `search.dto.ts`,
`search.repository.ts`, `auth.service.ts`, `access.repository.ts`,
`asset-response.dto.ts`, `asset-media.service.ts`, `smart-info.service.ts`.

| Область              | Фактическое поведение checkout                                                                                                                                                                                        |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `POST /search/smart` | Требует `asset.read`; legacy flat body. Structured `filter/orderBy/cursor`, хотя advertised DTO, отклоняется 400                                                                                                      |
| Owner scope          | Обычный search включает timeline partners; omission `withSharedSpaces` не означает owner-only. Для независимых owners передавать `ownerId` владельца key                                                              |
| Pagination           | `page >= 1`, `size` default 100/max1000; читать `assets.items` и numeric-string `assets.nextPage`; `assets.total` — размер страницы, не общий total                                                                   |
| Ranking              | Нет score/distance или video match timestamp. Date order сортирует только top500 similarity candidates; relevance pagination допускает повтор IDs, нужен dedup                                                        |
| Facets               | Exact totals относятся к поддерживаемому facet scope. DTO facets omits `ownerId` и `visibility`, поэтому strict owner/timeline totals могут расходиться. Здесь DTO не изменяется                                      |
| SharedSpaces         | `withSharedSpaces` включает только `showInTimeline=true` memberships; explicit `spaceId` проверяет membership, несовместим с `withSharedSpaces=true`                                                                  |
| Ключи                | `x-api-key` аутентифицирует ровно одного owner. Separate permissions: metadata/search `asset.read`, preview/playback `asset.view`, original `asset.download`; API key не даёт elevated-session доступа к locked media |
| Viewer auth          | Ответ, полученный key owner A, не разрешает показать asset пользователю B. Media/detail читаются с actual viewer auth и повторной проверкой membership                                                                |
| Фото и видео         | Asset DTO имеет `type`, nullable integer duration в milliseconds, nullable `livePhotoVideoId`; не предполагать photo-only или строковую duration                                                                      |
| Preview              | `/assets/:id/thumbnail?size=thumbnail                                                                                                                                                                                 | preview | fullsize`; missing preview допустим. Fullsize может redirect к preview/original; original redirect требует download permission |
| Playback             | `/assets/:id/video/playback` поддерживает Range; encoded video preferred, иначе original с возможной неподдерживаемой codec. S3 stream/redirect требует обработки redirects и byte ranges                             |
| Live photo           | IMAGE asset плюс отдельный `livePhotoVideoId`; preview — image, motion — linked video playback. Не дублировать motion как самостоятельную карточку без проверки его visibility                                        |
| Native video search  | Clips >=2 sec: 8 кадров между 5% и 95%, усреднённых в один CLIP asset vector; короткие clips — midpoint. Нет frame results, transcript/audio semantics или matched playback position                                  |

Custom titles/subtitles отображаются и web, и mobile до native fallback по
ruleId. Existing viewers умеют mixed photo/video/live-photo assets. Изменение
source selection, diversity algorithms, native embeddings и reindex не требуется
для этого read-контракта. Нет новых таблиц, migrations, production scripts или
credentials. Owner-only lifecycle/rejections не расширяют SharedSpace grants.

## Что изменить во внешнем gallery_ai v3.7

Production скрипт здесь не изменён; эти пункты являются контрактом последующей
интеграции владельцем, а не уже выполненным rollout:

1. Перед ежедневной публикацией получить полные owner-only lifecycle/rejection
   snapshots отдельным key каждого пользователя (`memory.read`). Вести локальный
   ledger accepted ID/fingerprint/membership, generator/ruleId/dedupeKey и уже
   обработанных rejection IDs. Дополнить ledger живых ранее созданных AI
   Memories через lifecycle; для уже hard-deleted старых Memories без ledger
   generator identity задним числом восстановить нельзя.
2. Отсутствующая Memory без matching dismissal не запускает negative feedback.
   Новый matching отказ нашей AI Memory создаёт запрос **одной** замены из
   буфера на очередной ежедневный запуск. После успешной публикации отметить
   отказ обработанным и снова выбрать обычный интервал 3–7 дней. Retry/error
   не должны создавать по новой замене каждый день. Точную дату отказа API не
   выдаёт: обработка основана на новом наблюдении в ежедневном цикле.
3. Перед выбором buffer candidate исключить suppressed memberships и близкие
   Jaccard >=0.8 наборы. HTTP 409 с `code=MEMORY_SUPPRESSED` — terminal отказ
   конкретной подборки: выбрать другую, не обрушать daily-run. Остальные 409,
   network failures и 5xx не считать dislike. При timeout сначала сверить
   owner ledger/lifecycle, поскольку POST не idempotent.
4. Для будущих POST сохранить provider-independent `data.generator`, `version`,
   `theme`, `context`, `dedupeKey`, `ruleId`, title/subtitle/score сразу при
   создании. Старые AI распознаются по `gallery_ai_highlight`; переписывать
   библиотеку для добавления поля generator не требуется. Все POST asset IDs
   проверять как принадлежащие key owner. Смешанные photo/video допустимы.
5. Считать **видимые сейчас** AI Memories по show/hide window, hidden/candidate
   состоянию и owner, а не числу всех lifecycle rows. Saved и viewed независимы;
   сохранение — положительный сигнал, просмотр — нейтральная история просмотра.

Обычный `DELETE /memories/:id` означает явное ручное rejection независимо от
того, пришёл запрос из session или API key. Если external producer использует
тот же DELETE для своей очистки/замены, это необходимо изменить перед rollout;
intent нельзя угадывать по виду authentication. Внутренний stock retention не
пишет dismissal. Отдельный автоматический retirement route здесь не добавлен
без подтверждения фактического producer workflow; до его согласования producer
не должен использовать ручной DELETE как housekeeping. Unknown `ruleId` не
защищает от retention: unsaved Rule удаляется после configured retention по
`coalesce(showAt,createdAt)`; default 365 дней. `isSaved=true` защищает от этой
очистки, но ручной user rejection имеет приоритет.

## Diversity и приватность остаются во внешнем слое

Gallery не связывается с LiteLLM/Groq/Cloudflare и не получает их credentials.
Предоставленный владельцем preprocessing — локальный decode, RGB, предел около
1600×1600, JPEG без EXIF/GPS/ICC — остаётся обязанностью внешнего сервиса.
Код v3.7 отсутствует здесь, поэтому эта sanitization не объявляется проверенной
тестами Gallery. Нельзя переслать thumbnail response в облако напрямую: следует
всегда заново кодировать локально, проверять размер/тип и разрешённый redirect.
Оригинальный video не отправляется Vision provider; будущие representative
frames извлекаются локально и проходят ту же sanitization.

Для diverse candidate retrieval достаточно существующего flat Smart Search:
несколько динамических themes, ограниченная пагинация `nextPage`, owner filter,
dedup asset IDs и внешнее ранжирование/штраф по истории последних ~8 подборок.
Нет нового endpoint, обещающего scene diversity без модели. Structured search
и facets scope несоответствия перечислены выше и не требуют reindex.

Мягкую cross-user diversity выполнять в внешнем семейном координаторе с уже
разрешёнными отдельными keys: сравнивать собственную локальную history и scene
signatures очищенных previews/событий, снижать score повторяющегося события лишь
при равноценных альтернативах. UUID/fingerprint разных владельцев не доказывает
визуальную схожесть копий одного события. Фиксированных категорий пользователям
не назначать; отсутствие альтернатив не должно блокировать хорошие Memories.
Gallery не открывает cross-user rejection/search endpoint и не объединяет
библиотеки. Упомянутый VAAPI task в параллельном remote commit сохранён как
документ; внешнего StreamingEncoder/carousel pipeline в этой задаче не меняли.

## Проверка

Дополнение: 177 focused server unit tests; 6 PostgreSQL repository tests;
whole-server TypeScript и scoped ESLint/format прошли. Дополнительный scheduled
regression подтверждает, что unknown external Rule с photo/video и custom
metadata переживает stock reconciliation. Реальный HTTP helper расширен
owner API keys, полным membership, сохранением metadata при seen/save/title,
internal retention без rejection, hard-delete correlation и typed 409.
Окончательные результаты общих проверок и полный список файлов приведены в
[отчёте validation](testing/2026-10-05-external-memory-validation.md).
