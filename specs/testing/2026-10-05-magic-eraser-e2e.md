# Реальный интеграционный тест Magic Eraser

`server/test/magic-eraser-real-asset.e2e.mjs` — отдельный opt-in тест. Он поднимает
на loopback настоящий Nest `ApiModule`, применяет все штатные миграции к свежей
тестовой PostgreSQL, регистрирует тестового владельца и загружает синтетические
JPEG/MP4 через HTTP. Затем HTTP-запрос с маской проходит через Gallery к настоящему
Big-LaMa sidecar; сохранённая копия проходит стандартные metadata и thumbnail
handlers, записывается в PostgreSQL и файловое хранилище.

Моки inpainting, API, upload, EXIF, thumbnails и БД не используются. Штатные
metadata/thumbnail jobs вызываются непосредственно через реальные сервисы в Nest
после upload/save, чтобы не запускать для этого теста остальные ML/geodata workers.
Сам BullMQ worker и мобильный UI этим тестом не проверяются.

Тест проверяет 11 контрактов: startup/migrations, server-only original,
authorization, ориентированный source preview, DTO validation, настоящую CPU
inference, изменение выбранной области и размеры preview, отдельный новый asset,
owner/date/timezone/camera/orientation/thumbnails/checksum/disk persistence,
provenance через HTTP и PostgreSQL, idempotent save и сохранность исходных байтов,
stack и Live Photo video link.

Тест отказывается работать с удалённой БД, с именем БД без `eraser_e2e`/`eraser-e2e`,
с уже инициализированной БД, удалённым sidecar или Redis. Он создаёт собственный
временный media directory и удаляет его после завершения. Тестовую БД и контейнеры
удаляет запускающий сценарий ниже. Исходная production-библиотека не используется.

## Воспроизведение в изолированной Cloud/dev-среде

Нужны Node 24, установленные server dependencies, `ffmpeg`, Docker и уже
настроенный локальный Big-LaMa sidecar из [HP guide](2026-10-05-magic-eraser-hp.md).
`GALLERY_INPAINTING_URL` указывает на его loopback URL; `GALLERY_INPAINTING_TOKEN`
передаётся окружением и никогда не печатается. На managed Cloud необходимо
сохранить Docker proxy/CA configuration, как описано runtime skill.

Это тестовый сценарий, **не production deployment**. Не запускать его против
production Redis, PostgreSQL или библиотеки. Он занимает только loopback порты
35435 и 36379; если они заняты, завершится с ошибкой, не удаляя чужие контейнеры.

```bash
set -euo pipefail
cd /workspace/gallery

# Существующий локальный sidecar должен быть готов и настроен отдельно.
: "${GALLERY_INPAINTING_URL:?Задайте loopback URL тестового sidecar}"
: "${GALLERY_INPAINTING_TOKEN:?Задайте токен тестового sidecar}"

# Явно используем только локальный managed Docker daemon.
local_docker() {
  env -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_TLS \
    -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
    docker --host=unix:///var/run/docker.sock "$@"
}

eraser_test_pg="gallery-eraser-e2e-pg-$$"
eraser_test_redis="gallery-eraser-e2e-redis-$$"
eraser_test_password="$(node -e 'process.stdout.write(require("node:crypto").randomUUID())')"
cleanup_eraser_test() {
  # Удаляем только два контейнера этого запуска и их тестовые anonymous volumes.
  local_docker rm -fv "$eraser_test_pg" "$eraser_test_redis" >/dev/null 2>&1 || true
}
trap cleanup_eraser_test EXIT

local_docker run -d --name "$eraser_test_pg" --cpus=1 --memory=1g \
  --shm-size=128m -p 127.0.0.1:35435:5432 \
  -e POSTGRES_PASSWORD="$eraser_test_password" -e POSTGRES_USER=postgres \
  -e POSTGRES_DB=gallery_eraser_e2e \
  ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23 \
  -c fsync=off -c shared_preload_libraries=vchord.so \
  -c config_file=/var/lib/postgresql/data/postgresql.conf >/dev/null

local_docker run -d --name "$eraser_test_redis" --cpus=0.5 --memory=128m \
  -p 127.0.0.1:36379:6379 \
  redis:7-alpine@sha256:858f009f9709ce576febc734aa78b8f6d624b82571f9ddb6bda4377c833b3499 \
  redis-server --save '' --appendonly no >/dev/null

for eraser_test_attempt in $(seq 1 60); do
  if local_docker exec "$eraser_test_pg" pg_isready -U postgres \
      -d gallery_eraser_e2e >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
local_docker exec "$eraser_test_pg" pg_isready -U postgres -d gallery_eraser_e2e

# Всё хранилище/пользователи/оригиналы в этом запуске синтетические.
export DB_URL="postgres://postgres:${eraser_test_password}@127.0.0.1:35435/gallery_eraser_e2e"
export REDIS_HOSTNAME=127.0.0.1 REDIS_PORT=36379
cd server
pnpm build
node test/magic-eraser-real-asset.e2e.mjs
```

После всех assertions helper закрывает Nest, EXIF processes, PostgreSQL client,
а также Redis pub/sub connections, созданные существующим `WebSocketAdapter`
вне Nest provider lifecycle. Принудительный `process.exit(0)` не используется.
Затем trap удаляет только тестовые PostgreSQL/Redis контейнеры; sidecar остаётся
под управлением запускающего его пользователя.

## Результат Cloud-проверки 5 октября 2026

Все **11 контрактов прошли**, runner exit code **0**, Prettier check и
`node --check` прошли. Финальный прогон занял **2,571 с** от create-job до ready
с уже прогретым CPU-моделью для синтетического JPEG 960×640 с orientation 6
(итоговая копия 640×960). Предыдущий холодный прогон того же сценария — **4,591 с**.
Это не benchmark HP и не обещание скорости на i3-9100T/UHD 630.

Fresh migration + schema drift check прошли штатно. PostgreSQL содержала ровно
четыре asset: исходное still, связанный motion video, stack peer и одну новую
отредактированную копию. Повторный save пятого asset не создал. `sourceTimeZone`
в provenance сохранён как `UTC+3`. После выполнения временные изображения
удалены, own test PostgreSQL/Redis контейнеры удалены. В sidecar временных
job directories не осталось.

В логах startup есть существующие предупреждения об отсутствующем SSR HTML
(API-only test fixture), legacy `/api/*` route conversion и experimental WASI.
Они не помешали API или assertions. Android/iOS UI, настоящий Samsung Motion
контейнер, HEIC, NAS/S3 и реальное Intel оборудование требуют отдельных проверок.
