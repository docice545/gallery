# Мобильная неделя: Android на HP и бесплатный iOS pilot

Инструкция относится к `docice545/gallery`, ветке `work`, клиенту **5.7.2 build 5**.
В APK входят настраиваемая Library и подготовленные общие mobile Trash исправления;
server-only исправление rescan race требует отдельного согласованного server deploy.
Это команды для владельца, а не выполненная установка на HP/iPhone.
Production server остаётся **5.7.1**. Здесь нет server build/deploy, Takeout,
миграций PostgreSQL, перезапуска контейнеров или изменения VPN/DNS.

## Android release APK на существующем HP

В Cloud проверено только наличие инструментов/файлов: Android SDK,
`apksigner` и постоянные `android/key.jks` / `android/key.properties`
отсутствуют. Создавать замену или debug-подпись для production нельзя.
Реальный release APK надо собрать на HP, где уже существует ключ **alias foto**.

`/opt/gallery-fork` — существующий bind mount `/mnt/hp-data/gallery-fork`.
Gradle/Pub caches и Big-LaMa уже находятся на SSD; Docker root остаётся на NVMe.
Команды ничего не перемещают, не дублируют caches и не запускают Big-LaMa.

Запускать этот блок после публикации всех проверенных mobile commits в `origin/work`.
При незакоммиченных изменениях или невозможности fast-forward он останавливается;
не применять reset/clean/restore автоматически.

```bash
set -euo pipefail
cd /opt/gallery-fork

# Проверить mount и текущую работу; сохранить её отдельно при непустом status.
findmnt -T /opt/gallery-fork
git status --short
git rev-parse HEAD
test "$(git branch --show-current)" = work
test -z "$(git status --porcelain)"

# Только fast-forward; main не меняется.
git fetch origin refs/heads/work:refs/remotes/origin/work
git merge --ff-only origin/work
hp_mobile_head=$(git rev-parse HEAD)
test "$hp_mobile_head" = "$(git rev-parse origin/work)"
printf 'Mobile source HEAD: %s\n' "$hp_mobile_head"

cd mobile
export ANDROID_HOME="$HOME/Android/Sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
# Используем уже установленный JDK 17; не обновляем Gradle/AGP/Kotlin.
test -d /usr/lib/jvm/java-17-openjdk-amd64
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export PATH="$JAVA_HOME/bin:$PATH"
java -version
flutter --version
python3 - <<'PY_TOOLCHAIN'
import json, subprocess
from pathlib import Path
assert json.loads(subprocess.check_output(
    ['flutter', '--version', '--machine'], text=True
))['frameworkVersion'] == '3.47.2'
assert 'version: 5.7.2+5' in Path('pubspec.yaml').read_text()
java = subprocess.run(['java', '-version'], capture_output=True, text=True)
assert java.returncode == 0 and 'version "17.' in java.stderr
PY_TOOLCHAIN

# Проверить старые signing-файлы, не читая/печатая их содержимое.
test -s android/key.jks
test -s android/key.properties
git check-ignore android/key.jks android/key.properties
test -z "$(git ls-files -- android/key.jks android/key.properties)"
# Исключить случайные CI overrides; Gradle использует существующий key.properties.
unset ALIAS ANDROID_KEY_PASSWORD ANDROID_STORE_PASSWORD PR_NUMBER

# OpenAPI не менялся; уже сгенерированный HP SDK сохраняется.
# Если его нет, отдельно выполните из корня `mise run //:open-api-dart`
# и затем вернитесь сюда. Этот task генерирует клиент, не запускает Gallery.
test -f generated/openapi/pubspec.yaml
flutter pub get --enforce-lockfile

# Все Pigeon APIs через locked package_config, без нового Pub cache.
hp_pigeon_main=$(python3 - <<'PY_PIGEON'
import json
from pathlib import Path
from urllib.parse import unquote, urljoin, urlparse
config = Path('.dart_tool/package_config.json').resolve()
package = next(p for p in json.loads(config.read_text())['packages']
               if p['name'] == 'pigeon')
uri = urlparse(urljoin(config.as_uri(), package['rootUri']))
if uri.scheme != 'file':
    raise SystemExit('Pigeon must resolve to a local locked package')
main = Path(unquote(uri.path)) / 'bin/pigeon.dart'
if not main.is_file():
    raise SystemExit('Locked Pigeon executable is missing')
print(main)
PY_PIGEON
)
for hp_pigeon_definition in pigeon/*.dart; do
  dart --packages=.dart_tool/package_config.json "$hp_pigeon_main" \
    --input "$hp_pigeon_definition"
done
dart format lib/platform/
flutter pub run easy_localization:generate -S ../i18n
flutter pub run bin/generate_keys.dart
# Это генераторы local mobile DB кода; production DB не затрагивается.
flutter pub run drift_dev make-migrations
flutter pub run drift_dev schema generate --data-classes --companions \
  drift_schemas/main/ test/drift/main/generated/
flutter pub run build_runner build
dart format lib/routing/router.gr.dart \
  lib/generated/codegen_loader.g.dart lib/generated/translations.g.dart

# Проверить generated-код и mobile regressions перед release build.
flutter analyze
flutter test --no-pub
# Не игнорировать неожиданный tracked diff от codegen.
git diff --exit-code
flutter build apk --release --build-name=5.7.2 --build-number=5
hp_mobile_apk=/opt/gallery-fork/mobile/build/app/outputs/flutter-apk/app-release.apk
test -s "$hp_mobile_apk"

# Проверить фактические applicationId/version APK, не только pubspec.
"$ANDROID_HOME/build-tools/36.0.0/aapt2" dump badging "$hp_mobile_apk" | \
  python3 -c 'import shlex,sys; line=next(x for x in sys.stdin if x.startswith("package:")); print(line.strip()); fields=dict(x.split("=",1) for x in shlex.split(line)[1:]); assert (fields["name"],fields["versionName"],fields["versionCode"]) == ("de.opennoodle.gallery","5.7.2","5")'

# Пароли не нужны для проверки готовой подписи.
hp_mobile_signature=$("$ANDROID_HOME/build-tools/36.0.0/apksigner" verify \
  --verbose --print-certs "$hp_mobile_apk")
printf '%s\n' "$hp_mobile_signature"
hp_mobile_certificate_sha=$(printf '%s\n' "$hp_mobile_signature" | \
  awk -F ': ' '/^Signer #1 certificate SHA-256 digest:/{print tolower($2)}' | tr -d ':')
test "$hp_mobile_certificate_sha" = ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18
sha256sum "$hp_mobile_apk"
printf 'APK: %s\n' "$hp_mobile_apk"
git status --short
```

Ожидаемый путь:
`/opt/gallery-fork/mobile/build/app/outputs/flutter-apk/app-release.apk`.
До реального выполнения нельзя сообщать SHA-256 APK или подтверждать подпись.
На Samsung проверить установку поверх build 4 без удаления данных, Library
show/hide/reorder/reset, Videos/Live Motion routes, sharp still previews,
face-aware framing и muted one-shot autoplay без каскада.

## Бесплатный iOS путь после финального unsigned build

Архитектура остаётся из
[бесплатного SideStore/LocalDevVPN design](../2026-10-05-ios-free-distribution-design.md).
Историческая строка того исследования про paid CI описывает состояние до
создания build-only lane. Уже подтверждённый baseline run `37418220960`
скомпилировал Runner и обе extensions без Apple credentials/signing; новый
финальный run должен проверять **все** mobile изменения и version **5.7.2 (5)**.

6 октября 2026 проверен официальный GitHub Releases API: нового исправленного
стабильного выпуска после указанного design нет. `0.6.4` по-прежнему помечен
**DO NOT USE**; временный кандидат —
[0.7.0-alpha](https://github.com/SideStore/SideStore/releases/tag/0.7.0-alpha),
build `0.7.0-20260911.328+6032424a` (fix Apple sign-in/503). Для `SideStore.ipa`
API указывает SHA-256
`e334f86e6ceeab2e0d886c07611246533f474bb18838cf13ebc09ed1f0d622b5`.
Это release metadata, а не физическое испытание подписания. Alpha остаётся
кандидатом только для pilot; перед установкой повторно проверить release notes.

Unsigned archive и unsigned IPA-пакет для передачи signer — разные формы
одних compiled binaries. Ни один не является уже установленным или подписанным
приложением. Упаковка `Payload/*.app` не создаёт development certificate,
профиль Personal Team, pairing или разрешённые App Groups.

Минимальные действия владельца:

1. Получить только artifact финального успешного `work` run; проверить его
   commit SHA, digest и archive verification. Не использовать старый 3.0.0 (240).
2. Выбрать исправленный официальный SideStore release. Исторический design
   фиксирует broken sign-in у 0.6.4; это не рекомендация устанавливать его.
   Версию signer и его checksum фиксировать перед pilot, без auto-nightly.
3. Подготовить свой Apple Account/2FA, тестовый iPhone, доверенный компьютер
   с USB для initial installation/pairing. Credentials и pairing-файлы
   остаются локально; не передавать их в Gallery или GitHub secrets.
4. Установить SideStore официальным iloader-путём, LocalDevVPN, trust/profile
   и Developer Mode там, где iOS требует. HP Linux может участвовать в initial
   pairing при доступном USB; native build уже выполняется на GitHub macOS.
5. Перед подписанием «Фото» проверить, что Personal Team действительно разрешает
   **исходные** `de.opennoodle.gallery`, `.ShareExtension`, `.Widget` и группу
   `group.de.opennoodle.gallery.share`. SideStore обычно добавляет Team suffix;
   не соглашаться с этим автоматически и не менять идентификаторы приложения.
6. После re-sign проверить каждый embedded profile/entitlements и каждый
   `AppGroupId`: entitlement группы должен совпадать с Info.plist всех трёх
   targets. При невозможности профиля исходных IDs/group остановить pilot и
   сообщить конкретное ограничение. Extensions не удалять молча ради лимита.
7. Испытать первый signed install, PhotoKit/Share/Live Photos/widget/background
   upload, затем update поверх предыдущего build с сохранением session/data.
   Подпись не гарантирует все capabilities: Wi-Fi Info/Associated Domains
   отдельно проверить на фактическом profile и устройстве.
8. Настроить LocalDevVPN и ежедневную автоматизацию `Refresh All Apps`;
   сначала refresh SideStore. Пройти минимум два семидневных цикла с lock,
   reboot, network loss, Low Power Mode и expired/recovery сценариями.

Personal Team/signing выполняются доверенным пользовательским SideStore client.
Без этих личных данных/допусков Cloud не может честно создать installable IPA.
Платный account, App Store Connect, TestFlight, distribution certificates,
новый release lane или зависимость «Фото» от SideStore API не нужны.

Начать с on-device Anisette. Собственный HP Anisette v3/HTTPS source остаётся
отдельным будущим deployment после physical pilot; в этой задаче сервисы,
VPN configuration, proxy/firewall и production network не устанавливаются.
Refresh продлевает текущую версию примерно на семь дней, а обновление приложения
через source требует отдельного Update. Автоматический refresh зависит от iOS
и Apple; при истечении SideStore может снова понадобиться USB-компьютер.
