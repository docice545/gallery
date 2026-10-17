# Управление воспоминаниями и приоритет ручных решений

Исходная ветка этой задачи: `work`, HEAD
`7dd47c463f996d210d53b817aa95d16e757af729`. Magic Eraser и предыдущие
custom функции уже сохранены. Эта функция расширяет существующие Memories,
не меняя originals, AI Memories service или production maintenance scripts.

## Найденный API и модель хранения

Локальный fork, upstream Immich v2.7.5/current main и open-noodle/gallery
используют `DELETE /memories/:id` и существующие PUT/PATCH обновления Memory.
DELETE удаляет строку Memory; каскад удаляет её `memory_asset` relations,
но не строки `asset` и не исходные файлы. `hideAt` является расписанием
показа, применяется при date-filtered search и не скрывает Memory из полного
списка. Пользовательского permanent hide endpoint в upstream нет.

Fork уже имеет `memory_candidate`: owner, canonical asset fingerprint,
JSON assetIds, state и nullable memoryId. Candidate Dismiss оставляет terminal
`dismissed` history и скрывает Memory через `deletedAt`. Fingerprint — SHA-256
от отсортированного уникального набора asset IDs. Similarity — Jaccard >=0.8.
History переживает hard deletion Memory благодаря nullable FK ON DELETE SET NULL.

Existing MemoryV1 sync переносит `deletedAt` и data; hard delete записывается
в MemoryDeleteV1 audit. Drift уже исключает `deletedAt` Memories. Значит, новое
хранилище suppression, migration или sync entity не нужны.

## Выбранная архитектура

Удаление остаётся существующим upstream DELETE. Только пользовательское
удаление записывает terminal dismissal до удаления Memory в той же transaction.
Автоматические cleanup/reconcile deletions не превращаются в пользовательский
запрет: они сохраняют прежнюю production семантику.

Скрытие добавляет optional `isHidden: true` в существующий MemoryUpdateDto.
Оно атомарно сохраняет dismissal и `deletedAt`/updatedAt; Memory остаётся
server-side tombstone, исключённой из carousel, list, ordinary search и deep links.
Клиент проверяет подтверждённый tombstone: старый сервер, проигнорировавший
новое поле, не должен создавать иллюзию сохранённого hide.

Создание Memory через API, создание candidate и scheduled generation проверяют
общий durable history под тем же owner advisory lock. Ручное решение имеет
приоритет над concurrent creation/Save/Later. API возвращает 409 для подавленного
создания; scheduled generator пропускает такой результат и продолжает остальные.
AI `gallery_ai_highlight` представлен external producer, а не отдельной
реализацией в checkout, поэтому guard основан на owner/asset membership,
а не на ненадёжном title, date или только одном предполагаемом ruleId.

Suppression использует исходный candidate asset set и актуальный набор Memory
при пользовательском решении. Если unique fingerprint уже связан с другой
Memory этого владельца, linked Memory также становится hidden tombstone только
при точном совпадении её **текущего** набора assets. Если пользователь уже
изменил этот candidate на другую подборку, такая Memory сохраняется. Saved
candidate/deep link/offline cache не должны обойти terminal dismissal.
Не выполняется similarity-wide массовое удаление других Memories.
Assets при любых этих операциях остаются нетронутыми.

Это консервативная политика: существенно тот же набор photos не создаёт новую
Memory при другой дате, title, порядке assets или следующей годовщине.
Например, подавленный набор «2 года назад» не должен возвращаться лишь под
заголовком «3 года назад». History не содержит контекст type/year. Отличающаяся
подборка допускается; duplicate exports с новыми asset IDs требуют отдельного
семантического дедупа и этой функцией не идентифицируются.

## Совместимость старого JSONB

Реальные PostgreSQL тесты выявили ошибку в прежнем candidate коде: предварительно
сериализованные JSON strings повторно сериализовались драйвером. `assetIds`
мог сохраняться JSONB строкой вместо массива; обновление `data` через `||`
могло превращать объект с AI title/context в массив. Это препятствовало
корректной проверке similarity и сохранению AI metadata.

Новые записи передают драйверу native массивы и объекты. Чтение поддерживает
legacy JSON-string membership и ограниченное восстановление старого `data`
из плоских частей: максимум 64 части и 64 KiB на JSON строку, без рекурсивного
обхода. Обычный update выбранного Memory пишет корректный объект обратно.
Нет массовой миграции, изменения схемы или обещания переписать всю БД.

## Мобильное поведение

Memory Viewer получает owner-only меню: «Не показывать это воспоминание» и
«Удалить воспоминание». Перед DELETE есть подтверждение: «Удалить это
воспоминание? Фото и видео из библиотеки удалены не будут». Во время меню,
диалога и запроса воспроизведение приостанавливается; отмена сохраняет zoom
и продолжает просмотр. Успех закрывает viewer и немедленно исключает карточку
из carousel/list без перезапуска.

Запрос подтверждается сервером прежде локального исключения. Local Drift
tombstone защищает offline fallback/restart; user-scoped confirmed removal
filter защищает от позднего результата уже начатого server fetch. Existing
sync/change watcher обновляет server-backed providers при изменении Memory
на другом устройстве. Asset Viewer, библиотеки originals и Memory zoom не
меняются. Все новые строки добавляются во все required locales.

## Production boundary

Fork гарантирует suppression в собственных API/generation paths. Владелец
подтвердил, что production external AI использует API, поэтому повторная
публикация подавленной подборки получает 409 и должна считаться manual suppression.
Самого `/opt/gallery-ai/gallery_ai_memories.py` здесь нет: обработка отказа,
next-day replacement и отсутствие автоматической cleanup через ручной DELETE
требуют проверки внешнего consumer. Его интеграция выполняется отдельно
владельцем и не изменяется/deploy-ится Codex. Прямые SQL inserts остаются вне
application-level guard, но подтверждённая production архитектура их не использует.

Нет нового API route, новой таблицы, migration, application/bundle ID,
dependency upgrade или изменения Magic Eraser/AI Memories/carousel/auto-stack
production files. Нативная проверка UI и синхронизации на физических устройствах
дополняет automated unit/HTTP/DB tests.

## Проверенные upstream источники

- [Immich v2.7.5 Memory DTO](https://github.com/immich-app/immich/blob/v2.7.5/server/src/dtos/memory.dto.ts).
- [Immich current Memory DTO](https://github.com/immich-app/immich/blob/main/server/src/dtos/memory.dto.ts).
- [Immich current Memory controller](https://github.com/immich-app/immich/blob/main/server/src/controllers/memory.controller.ts).
- [Gallery current Memory DTO](https://github.com/open-noodle/gallery/blob/main/server/src/dtos/memory.dto.ts).

Источники прочитаны 2026-10-05. Архитектура исходит из фактического кода fork,
а не из предположения о наличии upstream hide endpoint.
