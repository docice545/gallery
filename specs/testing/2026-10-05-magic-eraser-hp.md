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

## Существующий SSD layout и deployment

По подтверждению владельца 2026-10-05 `/opt/gallery-fork` — bind mount с
`/mnt/hp-data/gallery-fork` на SSD. `~/.gradle` указывает на
`/mnt/hp-data/build-cache/gradle`, `~/.pub-cache` — на
`/mnt/hp-data/build-cache/pub-cache`. **Big-LaMa checkpoint уже хранится на SSD**:
`/mnt/hp-data/gallery-inpainting/models/big-lama.pt`; использовать ту же модель
через существующий read-only mount. Gallery/Immich data: `/mnt/hp-data/immich/...`.
Docker root остаётся на NVMe. Эти пути подтверждены владельцем; действующий
container mount не изменяется.
Общая [read-only проверка layout](2026-10-04-photos-hp-build.md#фактический-ssd-layout-hp)
показывает bind mount, caches, Flutter metadata и Docker root.

`inpainting/compose.example.yml` — исходный пример, а не доказательство активной
конфигурации HP. Его `/opt/gallery-inpainting/models:/models:ro` не разрешает
создать новый каталог или вторую модель: существующий путь может быть bind mount
или symlink на SSD. Не применять example поверх действующего deployment,
не менять Compose overrides, model mount, token или network, не пересоздавать
контейнеры. Параметры CPU/RAM/512px выше описывают исходный example; фактические
настройки работающего HP этой задачей из Cloud не проверялись.

Ранее этот runbook содержал download/install и ручную активацию sidecar. Для
существующего HP они заменены проверкой уже подключённой модели. Не запускать
`curl` для checkpoint, `install`, `cp`, `mv`, `chmod`, создание token/env files,
Docker build или `compose up` ради подтверждения SSD layout. В текущей задаче
Big-LaMa deployment, production server 5.7.1, PostgreSQL/Redis/ML, VPN/DNS/AWG,
AI Memories и внешний auto-stack worker остаются без изменений.

## Проверка существующей модели и mount

Это **read-only команды для владельца HP**, не выполнение Codex на production.
Docker metadata передаётся только в локальный parser; он выводит model source,
а не tokens или полный config. Не использовать `set -x`. Поиск основан на
Compose service label, а не на предполагаемом container name.

```bash
set -euo pipefail
cd /opt/gallery-fork

mapfile -t hp_lama_containers < <(docker ps -a \
  --filter label=com.docker.compose.service=gallery-inpainting --format '{{.ID}}')
test "${#hp_lama_containers[@]}" -eq 1
hp_lama_container=${hp_lama_containers[0]}

# Находим существующий host source для настроенного INPAINTING_MODEL_PATH.
# Требуем read-only bind mount; каталог и checkpoint не создаются/не меняются.
hp_lama_path=$(docker inspect "$hp_lama_container" | python3 -c '
import json,pathlib,sys
c=json.load(sys.stdin)[0]
env=dict(x.split("=",1) for x in c["Config"]["Env"] if "=" in x)
model=pathlib.PurePosixPath(env.get("INPAINTING_MODEL_PATH","/models/big-lama.pt"))
assert model.is_absolute(), "Model path must be absolute"
matches=[m for m in c["Mounts"] if model==pathlib.PurePosixPath(m["Destination"]) or pathlib.PurePosixPath(m["Destination"]) in model.parents]
assert matches, "Existing model mount not found; do not download or copy a model"
m=max(matches,key=lambda x:len(pathlib.PurePosixPath(x["Destination"]).parts))
assert m["Type"]=="bind" and not m["RW"], "Verify the existing read-only model bind mount without changing deployment"
relative=model.relative_to(pathlib.PurePosixPath(m["Destination"]))
print(pathlib.Path(m["Source"]).joinpath(*relative.parts))')

test -s "$hp_lama_path"
hp_lama_real=$(realpath -e "$hp_lama_path")
printf 'Existing Big-LaMa: %s -> %s\n' "$hp_lama_path" "$hp_lama_real"
findmnt --target "$hp_lama_real" --output TARGET,SOURCE,FSTYPE,OPTIONS
lsblk --output NAME,TYPE,TRAN,ROTA,MOUNTPOINTS
hp_lama_sha=344c77bbcb158f17dd143070d1e789f38a66c04202311ae3a258ef66667a9ea9
printf '%s  %s\n' "$hp_lama_sha" "$hp_lama_real" | sha256sum --check

# Только status/image/resource metadata, без environment credentials.
docker inspect --format '{{.Name}} image={{.Config.Image}} state={{.State.Status}} read_only={{.HostConfig.ReadonlyRootfs}} cpus={{.HostConfig.NanoCpus}} memory={{.HostConfig.Memory}}' "$hp_lama_container"
docker inspect --format '{{.Name}} image={{.Config.Image}} state={{.State.Status}}' immich_server
```

Сопоставить SOURCE device из `findmnt` с `lsblk`: модель должна использовать
существующий SSD. Directory bind mount может иметь логический `/opt/...` source;
`realpath` раскрывает symlink, а backing filesystem определяет `findmnt`.
Если service не найден, найдено несколько экземпляров, mount не read-only или
checksum отличается, остановить проверку и выяснить фактическую конфигурацию.
Это не разрешение скачивать/копировать модель, менять permissions, mount или
перезапускать deployment. Сохраняется один existing checkpoint и один worker.

Нет новых таблиц, миграций или обязательных background cron scripts. Результат
попадает в обычный asset ingestion. Server API session временная: restart
сбрасывает несохранённый preview, но не меняет original. При нескольких API
replicas этой версии нужна одна replica/привязка editing session к одному process.

## Mobile и физические проверки

Блок сборки ниже сохранён для отдельной будущей сборки владельцем; текущий
framing/SSD/iOS audit не выполняет HP build, установку APK или deployment.
Android использует прежний `key.jks`, alias **`foto`** и прежний certificate.

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
