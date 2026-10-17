# Фото: сборка на HP и установка только server

Команды ниже предназначены для выполнения владельцем HP. Codex их на production
не выполняет. Используются существующие `/opt/gallery-fork`,
`/opt/immich/docker-compose.yml`, service `immich-server`, container `immich_server`,
image `gallery-server:docice-work`. Новых миграций, изменений схемы или API в этой
задаче нет. Внешние AI Memories/carousel/auto-stack остаются без изменений.

Сервер остаётся release **5.7.1**; мобильный клиент **5.7.2 build 2** уже собран
и установлен по уточнению владельца в инструкции продолжения. Новая release
сборка в текущей задаче не требуется. Блок сборки ниже сохраняет историческую
воспроизводимую команду; для следующего обновления номер определяет отдельная задача.
Версия сервера задаётся аргументом Docker `BUILD_VERSION=5.7.1`. Переменная Compose
`IMMICH_VERSION`, тег образа и `BUILD_SOURCE_REF` сами по себе версию API не задают.
Runtime environment override для версии не нужен.

## Фактический SSD layout HP

Layout подтверждён владельцем 2026-10-05; в Cloud диски HP не проверялись.

| Данные | Текущее размещение |
| --- | --- |
| Checkout и его build outputs | `/opt/gallery-fork` — **bind mount** каталога `/mnt/hp-data/gallery-fork` на SSD; это один checkout |
| Gradle cache | `~/.gradle` → `/mnt/hp-data/build-cache/gradle`; сохранить существующий cache и связь |
| Flutter/Dart Pub cache | `~/.pub-cache` → `/mnt/hp-data/build-cache/pub-cache`; сохранить существующий cache и связь |
| Big-LaMa checkpoint | `/mnt/hp-data/gallery-inpainting/models/big-lama.pt`; использовать существующий read-only model mount, см. [проверку ластика](2026-10-05-magic-eraser-hp.md#проверка-существующей-модели-и-mount) |
| Gallery/Immich data | `/mnt/hp-data/immich/...`; это подтверждённое размещение данных, не сведения о путях Synology external libraries |
| Docker root | Остаётся на NVMe; checkout на SSD не переносит Docker images/layers/volumes на SSD |

Физические пути выше уточнены владельцем в инструкции продолжения. Старое имя
вроде `/opt/gallery-inpainting/models` само по себе не определяет диск.
Не создавать второй checkout, caches или checkpoint, не скачивать модель
повторно, не менять bind mounts, `fstab`, Docker `data-root` или signing.
Android использует прежний `android/key.jks`, alias **`foto`** и прежний certificate.

Ниже — **только read-only проверки для владельца HP**, не команды Codex на
production. Запускать в той же shell/build environment, где обычно собирается
APK. Они выводят только paths/mounts, без паролей, токенов и полного environment.
Если Gradle запускается с `-g`/`--gradle-user-home` или `-Dgradle.user.home`,
сопоставить этот override с показанным путём, не менять его.

```bash
set -euo pipefail
cd /opt/gallery-fork

# realpath раскрывает symlinks; backing directory bind mount проверяет findmnt.
findmnt --mountpoint /opt/gallery-fork --output TARGET,SOURCE,FSTYPE,OPTIONS
findmnt --target /mnt/hp-data/gallery-fork --output TARGET,SOURCE,FSTYPE,OPTIONS
test "$(stat -c '%d:%i' /opt/gallery-fork)" = \
  "$(stat -c '%d:%i' /mnt/hp-data/gallery-fork)"
realpath -e /opt/gallery-fork /mnt/hp-data/gallery-fork

hp_gradle_cache=${GRADLE_USER_HOME:-$HOME/.gradle}
hp_pub_cache=${PUB_CACHE:-$HOME/.pub-cache}
for hp_cache_path in "$hp_gradle_cache" "$hp_pub_cache"; do
  test -d "$hp_cache_path"
  hp_cache_real=$(realpath -e "$hp_cache_path")
  printf 'Cache: %s -> %s\n' "$hp_cache_path" "$hp_cache_real"
  findmnt --target "$hp_cache_real" --output TARGET,SOURCE,FSTYPE,OPTIONS
done

# Existing Flutter metadata показывает фактический package path этой сборки.
# pub get здесь не запускается: если metadata отсутствует, проверка останавливается.
hp_pigeon_root=$(python3 -c 'import json,pathlib,urllib.parse as u; p=pathlib.Path("mobile/.dart_tool/package_config.json").resolve(); c=json.loads(p.read_text()); r=next(x["rootUri"] for x in c["packages"] if x["name"]=="pigeon"); uri=u.urlparse(u.urljoin(p.as_uri(),r)); assert uri.scheme=="file"; print(pathlib.Path(u.unquote(uri.path)).resolve(strict=True))')
printf 'Flutter package metadata (pigeon): %s\n' "$hp_pigeon_root"
findmnt --target "$hp_pigeon_root" --output TARGET,SOURCE,FSTYPE,OPTIONS

hp_docker_root=$(docker info --format '{{.DockerRootDir}}')
hp_docker_root_real=$(realpath -e "$hp_docker_root")
printf 'Docker root: %s -> %s\n' "$hp_docker_root" "$hp_docker_root_real"
findmnt --target "$hp_docker_root_real" --output TARGET,SOURCE,FSTYPE,OPTIONS
lsblk --output NAME,TYPE,TRAN,ROTA,MOUNTPOINTS
```

Сверить block device из `findmnt` с `lsblk`: caches/model/checkout уже используют
SSD, Docker root — NVMe. Несовпадение требует выяснения текущей конфигурации;
оно не является разрешением на перенос данных. Остальные блоки этого runbook —
сохранённая инструкция для отдельного будущего build/deployment владельцем.
В задаче framing/SSD/iOS audit они **не выполняются**, server 5.7.1,
PostgreSQL/Redis/ML, Big-LaMa deployment, VPN/DNS/AWG и внешний worker сохраняются.

## Отдельная будущая сборка и установка владельцем

Выполняйте блоки последовательно в Bash. При ошибке остановитесь и исправьте её;
команды не выполняют reset, force push, обновление зависимостей или compose down.
Резервное копирование production остаётся частью вашей обычной процедуры.

```bash
set -euo pipefail
cd /opt/gallery-fork

# 1. Проверяем ветку, SHA и отсутствие локальных изменений.
git branch --show-current
git rev-parse HEAD
git status --short
test "$(git branch --show-current)" = work
test -z "$(git status --porcelain)"
git merge-base --is-ancestor 07f7a8a8e98a52ba7bcd70a30c3b8018a00775c0 HEAD

# 2–4. Получаем work и применяем только fast-forward, без merge-коммита.
git fetch origin refs/heads/work:refs/remotes/origin/work
git merge --ff-only origin/work
git rev-parse HEAD
test "$(git rev-parse HEAD)" = "$(git rev-parse origin/work)"
test -z "$(git status --porcelain)"

# Сохраняем ID контейнеров, которые не должны быть пересозданы.
hp_container_snapshot=$(mktemp /tmp/photos-containers.XXXXXX)
docker inspect --format '{{.Name}} {{.Id}}' \
  immich_postgres immich_redis immich_machine_learning > "$hp_container_snapshot"

# Проверяем, что существующий compose действительно использует custom image.
# Полный config (в котором могут быть credentials) НЕ выводится на экран.
docker compose --project-directory /opt/immich \
  -f /opt/immich/docker-compose.yml config --format json | \
  python3 -c 'import json,sys; c=json.load(sys.stdin); assert c["services"]["immich-server"]["image"] == "gallery-server:docice-work", "Unexpected server image"'

# 5. Собираем из текущего fork HEAD; signing-файлы исключены из Docker context.
docker build -f server/Dockerfile \
  --build-arg BUILD_VERSION=5.7.1 \
  --build-arg BUILD_REPOSITORY=docice545/gallery \
  --build-arg BUILD_SOURCE_REF=work \
  --build-arg BUILD_SOURCE_COMMIT="$(git rev-parse HEAD)" \
  --build-arg BUILD_IMAGE=gallery-server:docice-work \
  -t gallery-server:docice-work .

# Проверяем version manifest в новом образе ДО пересоздания server.
# Этот короткий процесс не запускает Gallery и не подключает production volumes.
test "$(docker run --rm --entrypoint node gallery-server:docice-work \
  -p 'JSON.parse(require("node:fs").readFileSync("/usr/src/app/server/package.json", "utf8")).version')" = 5.7.1

# 6. Пересоздаём ТОЛЬКО server; dependencies не запускаем/не пересоздаём.
cd /opt/immich
docker compose -f /opt/immich/docker-compose.yml up -d \
  --no-deps --no-build --pull never --force-recreate immich-server

# 7. Ожидаем health server (до 120 секунд) и проверяем именно собранный image.
hp_server_healthy=false
for hp_attempt in {1..60}; do
  hp_server_health=$(docker inspect --format '{{.State.Health.Status}}' immich_server)
  if [ "$hp_server_health" = healthy ]; then
    hp_server_healthy=true
    break
  fi
  sleep 2
done
test "$hp_server_healthy" = true
docker inspect --format '{{.Name}} {{.State.Status}} {{.State.Health.Status}} {{.Image}}' immich_server
test "$(docker inspect --format '{{.Image}}' immich_server)" = \
  "$(docker image inspect --format '{{.Id}}' gallery-server:docice-work)"

# 8. Миграции этой задачей не добавлены/не изменены. Не запускаем schema reset,
# migrations:revert или ручные SQL-команды. Server сохраняет обычную проверку
# схемы и применение уже существующих миграций при старте.
cd /opt/gallery-fork
test -z "$(git diff --name-only 07f7a8a8e98a52ba7bcd70a30c3b8018a00775c0 HEAD -- server/src/schema mobile/drift_schemas mobile/lib/data/db)"

# 9. Проверяем локальный HTTP endpoint и затем публичный reverse proxy.
docker exec immich_server node --input-type=module -e \
  'const r=await fetch("http://127.0.0.1:2283/api/server/version"); if(!r.ok) throw new Error(`HTTP ${r.status}`); const v=await r.json(); console.log(v); if(v.major!==5||v.minor!==7||v.patch!==1||v.prerelease!==null) process.exit(1);'
curl --fail --silent --show-error https://imm.lampax.top/api/server/version | \
  python3 -c 'import json,sys; v=json.load(sys.stdin); print(v); assert (v["major"],v["minor"],v["patch"],v["prerelease"]) == (5,7,1,None)'

# 10. ID PostgreSQL, Redis и ML должны совпасть с ID до установки.
hp_container_after=$(mktemp /tmp/photos-containers-after.XXXXXX)
docker inspect --format '{{.Name}} {{.Id}}' \
  immich_postgres immich_redis immich_machine_learning > "$hp_container_after"
diff -u "$hp_container_snapshot" "$hp_container_after"
rm "$hp_container_snapshot" "$hp_container_after"
```

Для APK используйте тот же установленный Flutter **3.47.2**, Dart **3.13.2**,
Java **17**, Android SDK 36 и прежний release key. Не запускайте полный
`apply-branding.sh` в этом checkout: технические/native идентификаторы и launcher
name уже настроены, мобильный loader применяет локализованный бренд сам.

```bash
set -euo pipefail
cd /opt/gallery-fork/mobile
export ANDROID_HOME="$HOME/Android/Sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
flutter --version
java -version

# Только проверяем наличие старых signing-файлов и их игнорирование Git.
# Не читаем пароли, не создаём ключ и не заменяем key.jks.
test -s android/key.jks
test -s android/key.properties
git check-ignore android/key.jks android/key.properties
test -z "$(git ls-files -- android/key.jks android/key.properties)"

# 11. OpenAPI не менялся; существующий generated/openapi с HP сохраняется.
# Если его нет в новом checkout, сначала выполните из корня: mise //:open-api-dart.
test -f generated/openapi/pubspec.yaml
flutter pub get --enforce-lockfile

# Pigeon: используем existing package_config, сохраняя Pub cache на SSD.
# Не подставляем новый cache path и не создаём второй cache в $HOME.
hp_pigeon_bin=$(python3 -c 'import json,pathlib,urllib.parse as u; p=pathlib.Path(".dart_tool/package_config.json").resolve(); c=json.loads(p.read_text()); r=next(x["rootUri"] for x in c["packages"] if x["name"]=="pigeon"); uri=u.urlparse(u.urljoin(p.as_uri(),r)); assert uri.scheme=="file"; print(pathlib.Path(u.unquote(uri.path)).resolve(strict=True)/"bin/pigeon.dart")')
test -f "$hp_pigeon_bin"
for hp_pigeon_file in pigeon/*.dart; do
  dart --packages=.dart_tool/package_config.json "$hp_pigeon_bin" \
    --input "$hp_pigeon_file"
done

# Остальные generators запускаем Flutter-aware, как в предыдущей сборке HP.
flutter pub run easy_localization:generate -S ../i18n
flutter pub run bin/generate_keys.dart
flutter pub run drift_dev make-migrations
flutter pub run drift_dev schema generate \
  --data-classes --companions drift_schemas/main/ test/drift/main/generated/
flutter pub run build_runner build
dart format lib/routing/router.gr.dart \
  lib/generated/codegen_loader.g.dart lib/generated/translations.g.dart
dart analyze --fatal-infos
flutter test --no-pub test/presentation/widgets/timeline \
  test/presentation/widgets/images/thumbnail_live_photo_test.dart \
  test/presentation/widgets/asset_viewer/timeline_preview_video_viewer_test.dart \
  test/widgets/common/photos_branding_test.dart \
  test/widgets/common/immich_sliver_app_bar_logo_test.dart \
  test/providers/server_info_provider_test.dart \
  test/modules/utils/version_compatibility_test.dart \
  test/repositories/asset_media_repository_test.dart \
  test/repositories/download_repository_test.dart \
  test/repositories/file_media_repository_test.dart \
  test/services/download_service_test.dart \
  test/providers/asset_viewer/download_provider_test.dart \
  test/unit/presentation/actions/share_action_test.dart

# 12. Фото 5.7.2 build 2. Gradle/AGP/Kotlin и release key не меняем.
flutter build apk --release --build-name=5.7.2 --build-number=2
hp_apk=/opt/gallery-fork/mobile/build/app/outputs/flutter-apk/app-release.apk
test -s "$hp_apk"

# 13. Проверяем package/applicationId, versionName и versionCode APK.
"$ANDROID_HOME/build-tools/36.0.0/aapt2" dump badging "$hp_apk" | \
  python3 -c 'import shlex,sys; line=next(x for x in sys.stdin if x.startswith("package:")); print(line.strip()); fields=dict(x.split("=",1) for x in shlex.split(line)[1:]); assert fields["name"] == "de.opennoodle.gallery"; assert fields["versionName"] == "5.7.2"; assert fields["versionCode"] == "2"'

# 14. Проверяем подпись прежним release certificate. Пароли не выводятся.
hp_signature=$("$ANDROID_HOME/build-tools/36.0.0/apksigner" verify \
  --verbose --print-certs "$hp_apk")
printf '%s\n' "$hp_signature"
hp_certificate_sha=$(printf '%s\n' "$hp_signature" | \
  awk -F ': ' '/^Signer #1 certificate SHA-256 digest:/{print tolower($2)}' | tr -d ':')
test "$hp_certificate_sha" = ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18

# 15. Итоговый APK. Не добавляем бинарник или signing-файлы в Git.
printf 'APK: %s\n' "$hp_apk"
git status --short
```

После установки APK перепроверьте login/account: приложение 5.7.2 build 2,
server 5.7.1; предупреждение о несуществующем обновлении сервера отсутствует,
когда latest server release равен 5.7.1. Реальное более новое server release
по-прежнему вызывает уведомление. На Samsung проверьте scroll, одиночные и
смешанные группы, badges/selection/tap и muted one-shot Motion Photo. Для iOS
окончательная проверка требует macOS/Xcode и iPhone с paired Apple Live Photo.


Для дополнения Share/Download API сервера, Pigeon и схемы БД не менялись.
Новый Android FileProvider-мост написан вручную; дополнительного native codegen
для него не требуется. Если все ранее сгенерированные файлы уже есть на HP,
после `flutter pub get --enforce-lockfile` обязательны только генераторы
`easy_localization:generate` и `bin/generate_keys.dart`. Блок полного codegen
выше сохранён для воспроизводимой сборки с чистого checkout.

После установки проверьте server-only JPEG/HEIC, большое видео и смешанный
multi-share в Telegram/WhatsApp/почту; отмену зависшей загрузки; повторный Share
без повторной загрузки; чтение предыдущего Share-файла после следующего Share.
Share не должен создавать запись в Samsung Gallery. «Скачать на устройство»
должно создать её, сохранить MIME и оригинальные bytes и не дублировать уже
имеющийся локальный файл. Для Samsung Motion Photo проверьте сохранение
встроенного движения; для Apple Live Photo окончательная проверка PhotoKit
требует iPhone. Подробные сценарии и ограничения находятся в
`specs/testing/2026-10-04-server-only-originals-validation.md`.
