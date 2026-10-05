# Memories: обновление HP после ручного подтверждения

Эти команды подготовлены для владельца и **не выполнялись на production**.
Сервер: `/opt/gallery-fork`, Compose `/opt/immich/docker-compose.yml`, service
`immich-server`, container `immich_server`, image `gallery-server:docice-work`.
Схема БД/Drift и signing key в этой задаче не менялись. iOS signing services
не устанавливаются. Existing AI Memories/carousel/auto-stack scripts не меняются.

## Существующий storage layout

По подтверждению владельца 2026-10-05 `/opt/gallery-fork` — bind mount с
`/mnt/hp-data/gallery-fork` на SSD. `~/.gradle` → `/mnt/hp-data/build-cache/gradle`,
`~/.pub-cache` → `/mnt/hp-data/build-cache/pub-cache`, Big-LaMa checkpoint:
`/mnt/hp-data/gallery-inpainting/models/big-lama.pt`; Gallery/Immich data:
`/mnt/hp-data/immich/...`. Docker root остаётся на NVMe. Это один checkout и одна
существующая копия модели. Пути уточнены владельцем в инструкции продолжения;
[read-only проверка](2026-10-04-photos-hp-build.md#фактический-ssd-layout-hp)
показывает фактические mounts и build environment, а
[проверка модели](2026-10-05-magic-eraser-hp.md#проверка-существующей-модели-и-mount)
использует действующий read-only mount.

Никакие данные не переносить и не дублировать; модель повторно не скачивать.
Не менять Android `key.jks`/alias `foto`, Big-LaMa deployment или Docker data-root.
Блоки установки ниже относятся к отдельному будущему обновлению владельцем.
В текущей задаче framing/SSD/iOS readiness audit они **не выполняются**;
production server 5.7.1, PostgreSQL/Redis/ML, VPN/DNS/AWG и внешний auto-stack
worker остаются без изменений.

## Только Gallery server

Сначала сделать обычный backup по вашей принятой production процедуре. Блок
сохраняет активный Compose project и набор override files из существующего
контейнера, чтобы случайно не выключить уже включённый Magic Eraser.
Он не выводит Compose credentials и останавливается при неизвестной конфигурации.

```bash
set -euo pipefail
cd /opt/gallery-fork

# Проверяем локальную ветку и чистоту; не удаляем локальные изменения.
test "$(git branch --show-current)" = work
git rev-parse HEAD
git status --short
test -z "$(git status --porcelain)"
git fetch origin refs/heads/work:refs/remotes/origin/work
git merge --ff-only origin/work
test "$(git rev-parse HEAD)" = "$(git rev-parse origin/work)"
git merge-base --is-ancestor 7dd47c463f996d210d53b817aa95d16e757af729 HEAD
git rev-parse HEAD

# Схемы/миграции этого дополнения не затронуты; DB команды не нужны.
test -z "$(git diff --name-only 7dd47c463f996d210d53b817aa95d16e757af729 HEAD -- server/src/schema mobile/drift_schemas mobile/lib/data/db)"

# Сохраняем прежний compatible server release и фактический source commit.
docker build -f server/Dockerfile \
  --build-arg BUILD_VERSION=5.7.1 \
  --build-arg BUILD_REPOSITORY=docice545/gallery \
  --build-arg BUILD_SOURCE_REF=work \
  --build-arg BUILD_SOURCE_COMMIT="$(git rev-parse HEAD)" \
  --build-arg BUILD_IMAGE=gallery-server:docice-work \
  -t gallery-server:docice-work .
test "$(docker run --rm --entrypoint node gallery-server:docice-work \
  -p 'JSON.parse(require("node:fs").readFileSync("/usr/src/app/server/package.json", "utf8")).version')" = 5.7.1

# Используем ровно активный Compose project и прежние override files.
hp_memory_project=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' immich_server)
hp_memory_files=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' immich_server)
test -n "$hp_memory_project"
test "$hp_memory_project" != '<no value>'
test -n "$hp_memory_files"
test "$hp_memory_files" != '<no value>'
IFS=',' read -r -a hp_memory_file_list <<< "$hp_memory_files"
hp_memory_compose_args=()
for hp_memory_file in "${hp_memory_file_list[@]}"; do
  test -f "$hp_memory_file"
  hp_memory_compose_args+=(-f "$hp_memory_file")
done
hp_memory_compose() {
  sudo docker compose --project-directory /opt/immich \
    --project-name "$hp_memory_project" "${hp_memory_compose_args[@]}" "$@"
}
hp_memory_compose config --format json | \
  python3 -c 'import json,sys; c=json.load(sys.stdin); assert c["services"]["immich-server"]["image"]=="gallery-server:docice-work"; print("Server image validated; active overrides preserved")'

# Запоминаем все посторонние контейнеры, включая ластик, если он уже запущен.
hp_memory_before=$(mktemp /tmp/gallery-memory-before.XXXXXX)
hp_memory_after=$(mktemp /tmp/gallery-memory-after.XXXXXX)
trap 'rm -f "$hp_memory_before" "$hp_memory_after"' EXIT
docker ps -a --format '{{.Names}} {{.ID}}' | \
  awk '$1 != "immich_server"' | sort > "$hp_memory_before"

# Пересоздаём только server, без dependencies, build или pull других images.
hp_memory_compose up -d --no-deps --no-build --pull never --force-recreate immich-server
hp_memory_healthy=false
for hp_memory_attempt in {1..60}; do
  if [ "$(docker inspect --format '{{.State.Health.Status}}' immich_server)" = healthy ]; then
    hp_memory_healthy=true
    break
  fi
  sleep 2
done
test "$hp_memory_healthy" = true
docker inspect --format '{{.Name}} {{.State.Status}} {{.State.Health.Status}}' immich_server
test "$(docker inspect --format '{{.Image}}' immich_server)" = \
  "$(docker image inspect --format '{{.Id}}' gallery-server:docice-work)"
curl --fail --silent --show-error https://imm.lampax.top/api/server/version | \
  python3 -c 'import json,sys; v=json.load(sys.stdin); print(v); assert (v["major"],v["minor"],v["patch"])==(5,7,1)'

# Проверяем, что PG/Redis/ML, AI worker и другие контейнеры не пересозданы.
docker ps -a --format '{{.Names}} {{.ID}}' | \
  awk '$1 != "immich_server"' | sort > "$hp_memory_after"
diff -u "$hp_memory_before" "$hp_memory_after"
```

Если production Compose использует нестандартный `--env-file`, сохраните его
в своей штатной процедуре вызова Compose; block не угадывает неизвестную
конфигурацию. При failed health изучить локальные server logs, не перезапускать
PostgreSQL/Redis/ML для исправления проблемы. Приватные logs/config не публиковать.

## Android и интеграция AI

Использовать mobile codegen/build/signature раздел
[проверенного HP runbook](2026-10-05-magic-eraser-hp.md#mobile-и-физические-проверки):
generated Dart OpenAPI client, localization keys/loader, build_runner, analyze,
APK `5.7.2 build 2`, **если этот номер ещё не использован**. Для полностью чистой
mobile среды дополнительно выполнить прежний Pigeon/Drift codegen; новые schema
здесь не добавлены. Java 17, SDK36, Gradle/AGP/Kotlin и постоянный signing key
сохраняются. Не печатать `key.properties` и не генерировать новый ключ.

Итоговый APK: `/opt/gallery-fork/mobile/build/app/outputs/flutter-apk/app-release.apk`.
Application ID: `de.opennoodle.gallery`; certificate SHA-256:
`ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18`.

После server update проверить собственными API keys через существующий локальный
client новый [lifecycle/rejection контракт](../2026-10-05-external-memory-integration-audit.md).
Ключи не вставлять в отчёт/командную историю. Внешний generator integration —
отдельное изменение владельца: owner ledger, full snapshots, typed 409, одна
next-day buffer replacement и последующий интервал 3–7 дней. Обычный DELETE
не использовать для автоматического housekeeping.
