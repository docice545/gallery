# Реальная HTTP/БД проверка управления воспоминаниями

`server/test/memory-management-real-api.e2e.mjs` — отдельный opt-in интеграционный
тест. Он запускает настоящий Nest `ApiModule` на loopback, применяет существующие
миграции к новой PostgreSQL, создаёт синтетического владельца и постороннего
пользователя, загружает небольшие JPEG/MP4 через HTTP и использует две независимые
сессии владельца. Production-библиотека, NAS и внешние AI scripts не используются.

Проверяются обычное `on_this_day` воспоминание «2 года назад», скрытие через
существующий PUT/PATCH, удаление через DELETE, отсутствие воспоминаний в списке,
карточках текущего дня и статистике, сохранность оригиналов по SHA-256, owner
access, существующий sync stream, долговечность после повторного запуска Nest,
отказ API повторно создавать AI Memory или candidate по подавленным asset IDs.
Проверка включает порядок IDs, изменённые title/date/dedupeKey, сходство Jaccard
ровно 0,8, ручное скрытие ранее сохранённого candidate и отказ позднего Save.
Новые rejection записи проверяются как JSONB массивы; одна запись намеренно
преобразуется в JSONB строку старого формата для проверки совместимости без
миграции. Memory с фото и видео удаляется вместе со связями, оба originals
сохраняются и проверяются по SHA-256.

Для стандартного воспоминания вызывается настоящая реализация scheduled
`createOnThisDayMemories` с реальными repositories. Остальные nightly rule/ML
evaluators и внешний production AI cron этим тестом не запускаются. Тест
проверяет серверный контракт, которым пользуется production AI producer;
поведение внешнего скрипта при HTTP 409 следует проверить отдельно.

Anniversary original получает EXIF дату и проходит реальные metadata/thumbnail
handlers, поскольку стандартный generator выбирает только previewable assets.
Перед regeneration assertion проверяется, что реальный SQL generator input
действительно содержит исходную фотографию; отсутствие подходящих assets не
может дать ложный успешный результат. BullMQ worker отдельно не запускается.

Существующий upstream access guard возвращает **HTTP 400** для отсутствующего,
скрытого или недоступного Memory. Тест сохраняет этот контракт, а окончательное
удаление дополнительно проверяет по отсутствию строки и `memory_asset` связей в
PostgreSQL. Исходные `asset` строки и байты original проверяются отдельно.

## Запуск только в изолированной Cloud/dev-среде

Нужны Node 24, server dependencies, `ffmpeg` и Docker. На managed Cloud сохранить
существующие Docker proxy/CA/auth настройки. Это не deployment и не следует
использовать production PostgreSQL, Redis или media directory.

```bash
set -euo pipefail
cd /workspace/gallery

# Явно выбираем локальный Docker daemon, сохраняя его proxy/auth настройки.
local_docker() {
  env -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_TLS \
    -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
    docker --host=unix:///var/run/docker.sock "$@"
}

memory_test_pg="gallery-memory-e2e-pg-$$"
memory_test_redis="gallery-memory-e2e-redis-$$"
memory_test_password="$(node -e 'process.stdout.write(require("node:crypto").randomUUID())')"
cleanup_memory_test() {
  # Удаляем только контейнеры и anonymous volumes этого тестового запуска.
  local_docker rm -fv "$memory_test_pg" "$memory_test_redis" >/dev/null 2>&1 || true
}
trap cleanup_memory_test EXIT

local_docker run -d --name "$memory_test_pg" --cpus=1 --memory=1g \
  --shm-size=128m -p 127.0.0.1:35436:5432 \
  -e POSTGRES_PASSWORD="$memory_test_password" -e POSTGRES_USER=postgres \
  -e POSTGRES_DB=gallery_memory_e2e \
  ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23 \
  -c fsync=off -c shared_preload_libraries=vchord.so \
  -c config_file=/var/lib/postgresql/data/postgresql.conf >/dev/null

local_docker run -d --name "$memory_test_redis" --cpus=0.5 --memory=128m \
  -p 127.0.0.1:36380:6379 \
  redis:7-alpine@sha256:858f009f9709ce576febc734aa78b8f6d624b82571f9ddb6bda4377c833b3499 \
  redis-server --save '' --appendonly no >/dev/null

for memory_test_attempt in $(seq 1 60); do
  if local_docker exec "$memory_test_pg" pg_isready -U postgres \
      -d gallery_memory_e2e >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
local_docker exec "$memory_test_pg" pg_isready -U postgres -d gallery_memory_e2e

# Helper принимает только явно названную новую loopback тестовую БД.
export DB_URL="postgres://postgres:${memory_test_password}@127.0.0.1:35436/gallery_memory_e2e"
export REDIS_HOSTNAME=127.0.0.1 REDIS_PORT=36380
cd server
pnpm build
node test/memory-management-real-api.e2e.mjs
```

Порты 35436/36380 привязаны только к loopback. Если они заняты, Docker завершит
запуск с ошибкой; чужие контейнеры не удаляются. Helper отказывается работать с
уже инициализированной БД, remote DB/Redis или именем БД без `memory_e2e`.
Все original файлы создаются внутри собственного временного media directory.
В конце закрываются Nest, его Redis pub/sub connections, EXIF process и DB client;
directory удаляется. Принудительный успешный `process.exit` не используется.

Проверено 2026-10-05: **14/14 contracts passed, естественный exit 0**; собственные
PostgreSQL/Redis контейнеры и fixture directory удалены. Первый restart запуск
прошёл assertions, но выявил утечку соединений в harness: `app.module` создаёт
postgres.js instance при import, который нельзя повторно использовать после
`end()`. Каждый тестовый restart теперь загружает свежий экземпляр модуля,
воспроизводя обычный production process restart, и явно закрывает repository.
Production startup/shutdown код ради теста не изменён.

## Ограничения

Этот сценарий не проверяет Flutter UI, фактическое второе устройство, offline
кэш или внешний AI cron. Они покрываются focused mobile/server tests и ручной
проверкой на устройствах. Sync HTTP подтверждает передачу soft-delete update и
hard-delete tombstone, но сам по себе не доказывает отображение мобильной UI.
