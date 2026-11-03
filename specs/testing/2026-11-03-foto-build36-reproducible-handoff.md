# Build 36: воспроизводимая сборка и безопасный handoff

Связано с [Issue 18](https://github.com/docice545/gallery/issues/18) и
[актуальным аудитом](../audits/2026-11-03-issue18-resync.md).
**NO-GO для выпуска. Команды ниже подготовлены, но на HP не выполнялись.**
Сборка/подпись на HP, установка и deployment требуют отдельного разрешения владельца.
Build 37 имеет отдельные source SHA, UI-приёмку и versionCode 37; эти команды предназначены для 36.

## Источник и обязательные входные данные

Оператор использует уже подготовленный чистый build checkout на HP с исходными игнорируемыми
signing files. Не использовать production checkout, не делать reset/clean/checkout поверх чужих
изменений, не копировать/создавать ключи. Этот документ не меняет `/opt/gallery-fork`, production
Compose, Synology или существующий внешний maintenance processor.

Перед запуском задать:

- `FOTO_BUILD_CHECKOUT`: абсолютный путь согласованного build checkout;
- `FOTO_REVIEWED_SHA`: полный 40-character SHA из одобренного PR, **не вычислять автоматически из HEAD**;
- `FOTO_REVIEWED_BRANCH`: `codex/issue18-cross-platform-audit` либо явно одобренная последующая branch;
- `FOTO_ARTIFACT_ROOT`: согласованный каталог новых артефактов вне production/media directories;
- `FOTO_BUILD35_APK`: сохранённый оригинальный Build 35 APK, отдельно подтверждённый как установленная база;
- `FOTO_BUILD_DOCKER_CONTEXT`: существующий согласованный build Docker context; не production daemon.

Точный source SHA указывается в итоговом отчёте PR. Обновление SHA после review требует нового CI.
Не переносить старые green checks, hashes или подписанные APK на новый source.
Flutter/Dart/Java берутся из `mobile/mise.toml` (сейчас Flutter 3.47.2, Java 21.0.2);
Android build-tools 36.0.0, Python >=3.11, mise и gh должны уже быть доступны.

```bash
set -euo pipefail
: "${FOTO_BUILD_CHECKOUT:?Set the reviewed HP build checkout}"
: "${FOTO_REVIEWED_SHA:?Set the full reviewed source SHA from the PR}"
: "${FOTO_REVIEWED_BRANCH:?Set the reviewed branch}"
: "${FOTO_ARTIFACT_ROOT:?Set the approved artifact output root}"
[[ "$FOTO_REVIEWED_SHA" =~ ^[0-9a-f]{40}$ ]]
cd "$FOTO_BUILD_CHECKOUT"
test "$(git rev-parse HEAD)" = "$FOTO_REVIEWED_SHA"
test "$(git branch --show-current)" = "$FOTO_REVIEWED_BRANCH"
test -z "$(git status --porcelain)"
test "$(git show "$FOTO_REVIEWED_SHA:mobile/pubspec.yaml" | sed -n 's/^version: //p')" = '5.7.3+36'
python3 mobile/scripts/require_live_photo_ci.py \
  --repository docice545/gallery --expected-commit "$FOTO_REVIEWED_SHA"
```

Последняя команда read-only. Она требует успешные последние exact-source push runs Build Mobile,
Test и Static Code Analysis, а также оба успешных Live Photo job в точном attempt.
API failure, отсутствующий, skipped или failed Live Photo job блокируют продолжение.
Этот CI check не подтверждает Samsung/iPhone, полный production API traffic или backup recovery.
При текущих full-Flutter failures он должен отказать. Не обходить его ради сборки «релиза».

## Backend Docker: сборка нового артефакта, без замены production

Read-only source preflight не запускает Docker и не создаёт output directory:

```bash
MIGRATION_BASE_SHA=0c8be542121d415f4d748dda20367044cd200d40 \
  bash scripts/release/server_build.sh "$FOTO_REVIEWED_SHA" \
  "$FOTO_ARTIFACT_ROOT/server-$FOTO_REVIEWED_SHA" --check
```

После отдельного разрешения на сборку, только на согласованном build daemon:

```bash
: "${FOTO_BUILD_DOCKER_CONTEXT:?Set the approved non-production build Docker context}"
test ! -e "$FOTO_ARTIFACT_ROOT/server-$FOTO_REVIEWED_SHA"
env -u DOCKER_HOST DOCKER_CONTEXT="$FOTO_BUILD_DOCKER_CONTEXT" \
  MIGRATION_BASE_SHA=0c8be542121d415f4d748dda20367044cd200d40 \
  bash scripts/release/server_build.sh "$FOTO_REVIEWED_SHA" \
  "$FOTO_ARTIFACT_ROOT/server-$FOTO_REVIEWED_SHA"
(
  cd "$FOTO_ARTIFACT_ROOT/server-$FOTO_REVIEWED_SHA"
  sha256sum --check SHA256SUMS
  python3 -m json.tool manifest.json
)
```

Скрипт берёт committed tree через git archive, выполняет pinned-source branding,
buildx build --load под новым SHA-specific tag, проверяет package version, compiled server,
Web, CLI, оба WASM plugins и миграционные inputs. Проверочные containers запускаются
с `--network none --read-only`, без production mounts и запуска server workers.
Он экспортирует `gallery-server-linux-amd64.tar.gz`, `SHA256SUMS`, `manifest.json` и BuildKit metadata.
Registry push, Compose, cutover и media операции отсутствуют.

Не смешивать `imageManifestDigest` (OCI manifest), `imageId` (config digest) и archive SHA256.
`registryPublished=false` не является registry pull receipt. Процесс воспроизводим по inputs;
byte-for-byte одинаковость двух независимых сборок не проверена.
Источник миграций Build 35 — 175 файлов. Их совпадение не доказывает live DB ledger или rollback.

## Android: исходный ключ, universal APK, versionCode 36

Следующий preflight лишь проверяет source/toolchain и наличие/metadata уже существующих
игнорируемых signing files. Содержимое ключей инструментом не читается. Даже этот HP запуск
не выполнялся агентом; каталог и разрешение проверяет оператор.

```bash
python3 scripts/release/android_release.py preflight \
  --repository "$FOTO_BUILD_CHECKOUT" \
  --expected-head "$FOTO_REVIEWED_SHA" --expected-branch "$FOTO_REVIEWED_BRANCH" \
  --installed-build-number 35 --build-number 36
```

Только после отдельного разрешения на использование существующего ключа и сборку:

```bash
python3 scripts/release/android_release.py build \
  --repository "$FOTO_BUILD_CHECKOUT" \
  --expected-head "$FOTO_REVIEWED_SHA" --expected-branch "$FOTO_REVIEWED_BRANCH" \
  --installed-build-number 35 --build-number 36
python3 scripts/release/android_release.py postflight \
  --repository "$FOTO_BUILD_CHECKOUT" \
  --expected-head "$FOTO_REVIEWED_SHA" --expected-branch "$FOTO_REVIEWED_BRANCH" \
  --installed-build-number 35 --build-number 36
```

Скрипт выполняет locked codegen/analyze/tests/native unit tests, собирает release APK и проверяет
реальные package/version, три ABI, release certificate и provenance receipt. Он не вызывает adb install.
Повторный запуск с корректным существующим receipt переиспользует artifact; конфликтующий output
не перезаписывается. Режим `sign-existing` из исторического Build 8 не использовать для Build 36.

После сборки сопоставить именно сохранённый Build 35 APK с новым; не заменять проверку сертификата
совпадением applicationId. Путь output берётся из release tool:

```bash
: "${FOTO_BUILD35_APK:?Set the preserved verified Build 35 APK path}"
: "${ANDROID_HOME:?Use the existing reviewed Android SDK}"
FOTO_BUILD36_APK="$FOTO_BUILD_CHECKOUT/mobile/build/release-handoff/android-5.7.3-36-${FOTO_REVIEWED_SHA:0:12}/Foto.apk"
test -f "$FOTO_BUILD35_APK"
test -f "$FOTO_BUILD36_APK"
for FOTO_APK in "$FOTO_BUILD35_APK" "$FOTO_BUILD36_APK"; do
  "$ANDROID_HOME/build-tools/36.0.0/aapt" dump badging "$FOTO_APK"
  "$ANDROID_HOME/build-tools/36.0.0/apksigner" verify --verbose --print-certs "$FOTO_APK"
  sha256sum "$FOTO_APK"
done
```

Ожидаются applicationId `de.opennoodle.gallery`, build 35→36, тот же исходный certificate.
Pinned certificate в существующем verifier —
`ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18`.
Он должен быть независимо сверён с реальным установленным Build 35/его сохранёнными bytes;
наличие константы в коде этого не доказывает. После подписи ещё требуется отдельно разрешённая
проверка in-place upgrade с сохранением аккаунта, настроек, локальной БД и пользовательских данных.
APK installation/uninstall, clear-data и downgrade команды здесь намеренно отсутствуют.

## iOS: unsigned handoff с HP через macOS CI

HP Linux не компилирует валидированный iOS archive. С HP можно запускать существующую
unsigned macOS lane и получать проверенный artifact; это не Apple signing и не deployment.
Ветка должна содержать проверенную версию workflow. Если её HEAD двигается, preflight/receipt
должны отказать; запрещено подставлять новый SHA без review.

```bash
python3 mobile/scripts/release/ios_unsigned.py preflight \
  --expected-commit "$FOTO_REVIEWED_SHA" --expected-branch "$FOTO_REVIEWED_BRANCH"
python3 mobile/scripts/release/ios_unsigned.py dispatch \
  --expected-commit "$FOTO_REVIEWED_SHA" --expected-branch "$FOTO_REVIEWED_BRANCH" \
  --wait --version 5.7.3 --build 36 \
  --output "$FOTO_ARTIFACT_ROOT/ios-$FOTO_REVIEWED_SHA"
```

Helper запускает Gallery Build Mobile с `build_target=ios`, `version=''`, без pilot/lock refresh.
Он проверяет successful run, workflow/branch/source, реально выполненный unsigned step, отсутствие
signing steps, artifact identity и checksum. Существующий output допускается только при совпадении
receipt. Если уже есть подходящий completed run, `fetch --run RUN_ID` с теми же аргументами
переиспользует его без новой сборки. Root Build Mobile IPA тоже сохраняется, но helper ожидает
Gallery workflow — не подменять run ID от другого workflow.

После получения `Photos-unsigned.ipa` и `release-manifest.json`:

```bash
FOTO_IPA_DIR="$FOTO_ARTIFACT_ROOT/ios-$FOTO_REVIEWED_SHA"
FOTO_IPA_SHA256="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha256"])' \
  "$FOTO_IPA_DIR/release-manifest.json")"
python3 mobile/scripts/release/ios_unsigned.py verify \
  --ipa "$FOTO_IPA_DIR/Photos-unsigned.ipa" --input-sha256 "$FOTO_IPA_SHA256" \
  --version 5.7.3 --build 36
```

SideStore должен выполнить законную device signing с аккаунтом владельца; unsigned IPA сам по себе
не является install-ready. Bundle identity, Personal Team ID, App Groups, Share/Widget extensions,
лимиты capabilities/free provisioning, refresh/expiry и сохранность обновления проверяются на iPhone.
Не обещать extension/background parity для бесплатной подписи. Существующий
`mobile/scripts/release/prepare_sidestore.py` создаёт отдельный seed только на Mac; не переписывает
исходный IPA и не заменяет реальную SideStore provisioning/installation. Apple credentials не нужны
для Cloud-аудита и не должны публиковаться.

## Приёмка и rollback перед выпуском

Samsung: все [восемь Live Photo сценариев](2026-11-03-live-photo-release-gate.md), включая cold start
без Viewer, actual video movement и четыре markers; один активный player; profile-mode UI/raster
timings при 120 Hz (budget 8.33 ms, p95/p99 и jank). Дополнительно device-only Trash сохраняет server
copies при OS denial/cancel/partial; точные выбранные IDs; editor Save Copy попадает в нужный
Noodle Gallery album и backup, не opt-in посторонних альбомов. Build 37 UI принимается отдельно.

iPhone: same backend login/timeline/sync, still+motion pair playback/save/share, editor copies,
album discovery/backup, Trash/cancel, offline/reconnect/background, SideStore refresh/expiry и
in-place upgrade. Проверить реальные identities/entitlements и сохранность приложения после resign.

До любого deployment оператор сохраняет current image digest/config, Build 35 bytes/certificate,
проверяет актуальный DB backup и восстановление на изолированной копии, Synology/NAS byte recovery
и действующий внешний maintenance processor. При миграциях нельзя обещать image-only downgrade;
fallback должен соответствовать сохранённым DB/media snapshots и отдельно проверенному restore.
Нельзя восстанавливать/очищать production автоматически. Синтетические source/fixture проверки,
старый backup-файл или прежний release handoff не закрывают эти условия.

Пока нет новых реальных artifacts, соответствующие Docker/APK/IPA SHA256 отсутствуют;
не копировать hashes из исторического Build 8/35 или CI log artifacts. **Release acceptance INCOMPLETE.**
