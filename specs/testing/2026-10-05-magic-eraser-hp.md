# Волшебный ластик: подготовка и проверка на HP

Это инструкция для владельца HP, а не автоматически выполняемый deployment.
В Cloud production не изменялся. Функция выключена без отдельного inpainting
service и его конфигурации. Существующие ML, AI Memories/carousel/auto-stack,
PostgreSQL и Redis не заменяются.

Нужен один Gallery API process, один inpainting container, CPU-only Torch,
проверенный Big-LaMa checkpoint и приватный общий токен. Начальная конфигурация:
два CPU, рабочая область модели до 512px, одна активная задача, до трёх ожидающих,
лимит container RAM 3GiB, максимальный original 36MP. До включения проверьте
свободную память сверх уже используемой Gallery ML и остальных сервисов.
Ожидаемое время на i3-9100T не измерено: ориентир — секунды/десятки секунд,
возможны более долгие задержки под нагрузкой. UHD 630/OpenVINO не используются
этим CPU image; GPU-драйверы и `/dev/dri` для него не нужны.

## Подготовка без изменения работающих контейнеров

```bash
set -euo pipefail
cd /opt/gallery-fork

# Сохраняем локальные изменения/историю: допускается только чистый fast-forward.
test "$(git branch --show-current)" = work
git rev-parse HEAD
git status --short
test -z "$(git status --porcelain)"
git fetch origin refs/heads/work:refs/remotes/origin/work
git merge --ff-only origin/work
test "$(git rev-parse HEAD)" = "$(git rev-parse origin/work)"
git merge-base --is-ancestor 5928803825f85c1807f71d8c9e40a9b65a6329b1 HEAD

# Проверяем ресурсы; не останавливаем существующий ML для освобождения RAM.
free -h
docker stats --no-stream

# Модель хранится отдельно от production Memories и от Git checkout.
sudo install -d -m 0755 -o "$(id -u)" -g "$(id -g)" /opt/gallery-inpainting/models
hp_lama_sha=344c77bbcb158f17dd143070d1e789f38a66c04202311ae3a258ef66667a9ea9
hp_lama_path=/opt/gallery-inpainting/models/big-lama.pt
if [ ! -f "$hp_lama_path" ]; then
  curl --fail --location --show-error \
    https://github.com/Sanster/models/releases/download/add_big_lama/big-lama.pt \
    -o "$hp_lama_path.partial"
  printf '%s  %s\n' "$hp_lama_sha" "$hp_lama_path.partial" | sha256sum --check
  mv "$hp_lama_path.partial" "$hp_lama_path"
fi
printf '%s  %s\n' "$hp_lama_sha" "$hp_lama_path" | sha256sum --check
chmod 0644 "$hp_lama_path"

# Создаём приватную конфигурацию один раз. Токен не печатается и не коммитится.
# Существующий файл сохраняется; прежде чем менять его, проверьте его локально.
if ! sudo test -e /opt/immich/gallery-inpainting.env; then
  (
    umask 077
    hp_eraser_env=$(mktemp /tmp/gallery-inpainting-env.XXXXXX)
    trap 'rm -f "$hp_eraser_env"' EXIT
    printf 'GALLERY_INPAINTING_URL=http://gallery-inpainting:3004\n' > "$hp_eraser_env"
    printf 'GALLERY_INPAINTING_TOKEN=' >> "$hp_eraser_env"
    openssl rand -hex 32 >> "$hp_eraser_env"
    printf 'INPAINTING_MODEL_SHA256=%s\n' "$hp_lama_sha" >> "$hp_eraser_env"
    sudo install -m 0600 "$hp_eraser_env" /opt/immich/gallery-inpainting.env
  )
fi

# Новая модель загружается только при подготовке; фотографии никуда не отправляются.
# Образ содержит CPU Torch и HTTP worker, checkpoint монтируется отдельно.
docker build -f inpainting/Dockerfile \
  -t gallery-inpainting:docice-work inpainting

# Пересобираем API с прежней совместимой release version, не меняя main.
docker build -f server/Dockerfile \
  --build-arg BUILD_VERSION=5.7.1 \
  --build-arg BUILD_REPOSITORY=docice545/gallery \
  --build-arg BUILD_SOURCE_REF=work \
  --build-arg BUILD_SOURCE_COMMIT="$(git rev-parse HEAD)" \
  --build-arg BUILD_IMAGE=gallery-server:docice-work \
  -t gallery-server:docice-work .

# Проверяем release manifest до пересоздания production server.
# Этот процесс не запускает Gallery и не подключается к production БД.
test "$(docker run --rm --entrypoint node gallery-server:docice-work \
  -p 'JSON.parse(require("node:fs").readFileSync("/usr/src/app/server/package.json", "utf8")).version')" = 5.7.1

# Ластик не добавляет и не изменяет schema/migrations.
test -z "$(git diff --name-only 5928803825f85c1807f71d8c9e40a9b65a6329b1 HEAD -- server/src/schema mobile/drift_schemas mobile/lib/data/db)"
```

## Ручная активация после проверки конфигурации

Используйте `inpainting/compose.example.yml` вместе с существующим
`/opt/immich/docker-compose.yml`. Убедитесь, что `immich-server` и новый service
имеют общую приватную Docker network. Пример рассчитан на стандартную Compose
`default` network; если HP использует именованные custom networks, адаптируйте
только сеть нового service к существующей сети server. Не заменяйте сети server
так, чтобы пропала связь с PostgreSQL/Redis. Порт 3004 не публикуется на хосте.

Файл токена имеет режим 0600; команды Compose ниже запускаются с `sudo`, чтобы
не ослаблять права. Не выводите полный Compose config, содержащий токен.

```bash
set -euo pipefail
cd /opt/immich
hp_eraser_compose=/opt/gallery-fork/inpainting/compose.example.yml

# Проверяем только image и сети, не выводя credentials.
sudo docker compose --project-directory /opt/immich \
  -f /opt/immich/docker-compose.yml -f "$hp_eraser_compose" config --format json | \
  python3 -c 'import json,sys; c=json.load(sys.stdin); s=c["services"]; assert s["immich-server"]["image"]=="gallery-server:docice-work"; assert not s["gallery-inpainting"].get("ports"); a=set(s["immich-server"].get("networks",{})); b=set(s["gallery-inpainting"].get("networks",{})); assert a & b, "Inpainting and server need a common private network"; print("Images, private port and shared network validated")'

# Запоминаем ID контейнеров, которые не должны пересоздаваться.
hp_eraser_before=$(mktemp /tmp/gallery-eraser-before.XXXXXX)
docker inspect --format '{{.Name}} {{.Id}}' \
  immich_postgres immich_redis immich_machine_learning > "$hp_eraser_before"

# Только новый AI worker. Existing dependencies не пересоздаём.
sudo docker compose --project-directory /opt/immich \
  -f /opt/immich/docker-compose.yml -f "$hp_eraser_compose" \
  up -d --no-deps --no-build --pull never gallery-inpainting

# Ждём private health: токен берётся внутри контейнера и не выводится.
sudo docker compose --project-directory /opt/immich \
  -f /opt/immich/docker-compose.yml -f "$hp_eraser_compose" \
  exec -T gallery-inpainting python -c \
  'import json,os,time,urllib.request
for attempt in range(20):
  try:
    r=urllib.request.Request("http://127.0.0.1:3004/health",headers={"Authorization":"Bearer "+os.environ["GALLERY_INPAINTING_TOKEN"]})
    h=json.load(urllib.request.urlopen(r,timeout=10))
    if h["ready"] and h["engine"]=="big-lama":
      print(h)
      break
  except OSError:
    pass
  time.sleep(1)
else:
  raise SystemExit("Inpainting worker is not ready")'

# Только Gallery API получает optional URL/token; PG/Redis/ML не трогаем.
sudo docker compose --project-directory /opt/immich \
  -f /opt/immich/docker-compose.yml -f "$hp_eraser_compose" \
  up -d --no-deps --no-build --pull never --force-recreate immich-server

# Ждём health server, затем проверяем прежнюю release version.
hp_eraser_server_healthy=false
for hp_attempt in {1..60}; do
  if [ "$(docker inspect --format '{{.State.Health.Status}}' immich_server)" = healthy ]; then
    hp_eraser_server_healthy=true
    break
  fi
  sleep 2
done
test "$hp_eraser_server_healthy" = true
docker inspect --format '{{.Name}} {{.State.Status}} {{.State.Health.Status}}' immich_server
test "$(docker inspect --format '{{.Image}}' immich_server)" = \
  "$(docker image inspect --format '{{.Id}}' gallery-server:docice-work)"
docker exec immich_server node --input-type=module -e \
  'const r=await fetch("http://127.0.0.1:2283/api/server/version"); if(!r.ok) throw new Error(`HTTP ${r.status}`); const v=await r.json(); console.log(v); if(v.major!==5||v.minor!==7||v.patch!==1||v.prerelease!==null) process.exit(1);'
curl --fail --silent --show-error https://imm.lampax.top/api/server/version | \
  python3 -c 'import json,sys; v=json.load(sys.stdin); print(v); assert (v["major"],v["minor"],v["patch"])==(5,7,1)'

# У остальных production-контейнеров должны сохраниться ID.
hp_eraser_after=$(mktemp /tmp/gallery-eraser-after.XXXXXX)
docker inspect --format '{{.Name}} {{.Id}}' \
  immich_postgres immich_redis immich_machine_learning > "$hp_eraser_after"
diff -u "$hp_eraser_before" "$hp_eraser_after"
rm "$hp_eraser_before" "$hp_eraser_after"
```

Нет новых таблиц, миграций или обязательных background cron scripts. Результат
попадает в обычный asset ingestion. Server API session временная: restart
сбрасывает несохранённый preview, но не меняет original. При нескольких API
replicas этой версии нужна одна replica/привязка editing session к одному process.

## Mobile и физические проверки

После fetch потребуется обновлённый ignored Dart OpenAPI client, localization
keys/loader и `build_runner` для optional argument существующего editor route.
Для генерации OpenAPI используйте существующий repository task из корня
(`mise //:open-api-dart`); затем проверенный HP Flutter-aware codegen и build из
[предыдущей инструкции](2026-10-04-photos-hp-build.md). Схемы Drift и Pigeon для
ластика не менялись. Не создавайте signing keys, не меняйте IDs и не обновляйте
Gradle/AGP/Kotlin из-за предупреждений. Build name/number задавайте явно: если
5.7.2 build 2 ещё является вашим следующим клиентом, используйте прежние параметры;
если он уже опубликован локально, выберите следующий номер в своей процедуре.

```bash
set -euo pipefail
cd /opt/gallery-fork

# Генератор OpenAPI/Java должен быть установлен согласно existing mise config.
# Спецификация API уже закоммичена; запуск server для генерации не требуется.
mise //:open-api-dart
cd mobile
export ANDROID_HOME="$HOME/Android/Sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
flutter --version
java -version

# Только проверяем наличие и игнорирование прежнего ключа, без чтения паролей.
test -s android/key.jks
test -s android/key.properties
git check-ignore android/key.jks android/key.properties
test -z "$(git ls-files -- android/key.jks android/key.properties)"

flutter pub get --enforce-lockfile
flutter pub run easy_localization:generate -S ../i18n
flutter pub run bin/generate_keys.dart
flutter pub run build_runner build
dart format lib/routing/router.gr.dart \
  lib/generated/codegen_loader.g.dart lib/generated/translations.g.dart
dart analyze --fatal-infos
flutter test --no-pub test/pages/edit \
  test/repositories/magic_eraser_repository_test.dart \
  test/unit/domain/models/magic_eraser_test.dart \
  test/unit/presentation/actions/magic_eraser_edit_action_test.dart

# Новый API не требует новых Drift/Pigeon files. Для полностью чистой mobile
# среды выполните также уже проверенный полный codegen из предыдущей инструкции.
# Если 5.7.2 build 2 ещё не использован, собираем с этим следующим номером.
flutter build apk --release --build-name=5.7.2 --build-number=2
hp_eraser_apk=/opt/gallery-fork/mobile/build/app/outputs/flutter-apk/app-release.apk
test -s "$hp_eraser_apk"

# Проверяем тот же applicationId и новый номер APK.
"$ANDROID_HOME/build-tools/36.0.0/aapt2" dump badging "$hp_eraser_apk" | \
  python3 -c 'import shlex,sys; line=next(x for x in sys.stdin if x.startswith("package:")); print(line.strip()); f=dict(x.split("=",1) for x in shlex.split(line)[1:]); assert (f["name"],f["versionName"],f["versionCode"]) == ("de.opennoodle.gallery","5.7.2","2")'

# apksigner не требует вывода паролей. Проверяем прежний постоянный certificate.
hp_eraser_signature=$("$ANDROID_HOME/build-tools/36.0.0/apksigner" verify \
  --verbose --print-certs "$hp_eraser_apk")
printf '%s\n' "$hp_eraser_signature"
hp_eraser_cert=$(printf '%s\n' "$hp_eraser_signature" | \
  awk -F ': ' '/^Signer #1 certificate SHA-256 digest:/{print tolower($2)}' | tr -d ':')
test "$hp_eraser_cert" = ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18
printf 'APK: %s\n' "$hp_eraser_apk"
git status --short
```

На Samsung проверьте кисть/erase/undo/redo/reset, точность маски после zoom/pan,
portrait/landscape и EXIF rotation, ожидание/отмену/ошибку offline, Before/After,
повторный Save без дублей и появление копии в обычном timeline. Original bytes,
дата/часовой пояс и motion source должны сохраниться. Для server-only HEIC/JPEG
подтвердите отсутствие phone-original roundtrip по сетевому трафику. Большая
маска/unsupported image должна выдавать ошибку, а не менять source.

На HP замерьте CPU/RSS/latency холодной и тёплой обработки при 512px, влияние
на существующие ML/AI Memories и отмену активной/queued задачи. Реальная скорость
и визуальное качество на ваших фотографиях не следуют из Cloud unit tests.

Новая копия — static JPEG без исходной Live/Motion связи. Samsung Gallery
не должна показывать её как Motion Photo. Исходный asset сохраняет autoplay.
Для iOS финальная проверка кисти/zoom/navigation и static-copy UX требует
macOS/Xcode и iPhone. Copy не получает stack при создании, однако внешний
auto-stack может позднее сгруппировать её; исключение по metadata
`gallery.magicEraser` — отдельная возможная интеграция владельца, не изменение
production script этой задачей.
