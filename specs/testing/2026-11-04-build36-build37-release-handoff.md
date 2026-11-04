# Build36 / Build37: воспроизводимые сборки и безопасный handoff

**Production NO-GO. Команды ниже не выполнялись на HP или телефонах.** GitHub PR проверяет synthetic merge checkout; финальный release требует успешного CI **точного исходного SHA**. Не подставлять автоматически движущийся HEAD. Текущий reviewed candidate выбирается после закрытия программных gates; [чек-лист](../../BUILD37_CHECKLIST.md) и [устройства](2026-11-04-build37-device-acceptance.md) обязательны. Наличие unsigned APK/IPA не разрешает подпись/установку/merge/deployment.

Build36 остаётся в PR19 с совместимостью/Backend PR21 (`5.7.3+36`), Build37 — PR20 (`5.7.3+37`). Не выдавать Build37 как36 и не понижать versionCode для обхода обновления. Старые инструкции Build8/10/11, их SHA, APK hash и CI run IDs не являются источником36/37. Legacy `create_candidate_profile.py` содержит исторические значения; не использовать его без отдельной актуализации под новый кандидат. SHA256 новых APK/Docker/IPA определяется **после фактической сборки**, здесь он не выдумывается.

## HP: read-only входные проверки

Требуется заранее согласованный чистый checkout нужного40-символьного SHA, существующие SSD/cache пути, pinned Flutter/Dart/mise и Java из `mobile/mise.toml` (сейчас21)/Android SDK36. Не менять HP checkout/ветку, контейнеры, Docker root, VPN или ключи автоматически. Если состояние не совпало — остановить сборку и сохранить чужие изменения; не применять reset/clean/merge.

```bash
set -euo pipefail
cd /opt/gallery-fork
read -r -p 'Reviewed full source SHA: ' release_sha
read -r -p 'Reviewed build number (36 or 37): ' release_build
[[ "$release_sha" =~ ^[0-9a-f]{40}$ ]]
[[ "$release_build" == 36 || "$release_build" == 37 ]]
test "$(git rev-parse HEAD)" = "$release_sha"
test -z "$(git status --porcelain)"
test "$(git show "$release_sha:mobile/pubspec.yaml" | sed -n 's/^version: //p')" = "5.7.3+$release_build"
python3 mobile/scripts/require_live_photo_ci.py \
  --repository docice545/gallery --expected-commit "$release_sha"
bash scripts/release/server_build.sh "$release_sha" "/tmp/foto-build-$release_build-$release_sha-check" --check
```

`require_live_photo_ci.py` fail-closed: exact-source push, последний attempt, все обязательныеjobs успешны; PR synthetic merge/старый green/skipped не проходят. До появления подходящего push gate это **ожидаемый блокер**, не повод отключить проверку. Изменение release-ref/CI после review и любые merge требуют отдельного согласования. Скриптserver `--check` проверяет committedversion и неизменность существующих migrations, Docker не запускает. Для35→36 и36→37 inventory сохраняет все175 миграций подтверждённого Build35 source `0c8be542121d415f4d748dda20367044cd200d40`; это не утверждение о состоянии liveHP DB.

## HP: Docker build/export, без замены production

После отдельного разрешения HP build, из того же проверенного checkout и с ещё не существующим каталогом:

```bash
release_output="/tmp/foto-build-$release_build-$release_sha"
test ! -e "$release_output"
bash scripts/release/server_build.sh "$release_sha" "$release_output"
```

Скрипт архивирует committed source, применяет branding в собственной временной копии, собирает linux/amd64, проверяет labels/env/source/migration inventory, packagedWeb/CLI/дваWASMplugin, экспортируетimage/receipt с BuildKit manifestdigest иconfigdigest. Он не читает production Compose и не заменяет контейнеры. Проверить фактический imageID/digest и tarSHA256 из результата; локальный imageID не выдавать за registryRepoDigest до публикации. Container replacement/push/deployment не входят в этот шаг.

## HP: подписанный universal APK существующим оригинальным ключом

**Только после отдельного разрешения подписи.** Сборка создаёт кандидат для аппаратного теста обновления; production остаётся NO-GO до завершения этого теста и остальных H1–H8. Использовать только прежние ignored `key.properties`/keystore, уже настроенные владельцем на HP. Не копировать/выводить/генерировать ключи. Перед запуском сверить установленный35/36 certificateSHA256 с оригинальным, package=`de.opennoodle.gallery`, утверждённыйsource/version. Исторически ожидаемый оригинальныйcertificate хранится в `android_release.py`; если он не совпадает с baseline, остановиться и выяснить, а не заменить expectedhash.

Строгий builder проверяет явно указанную существующую ветку, чистый source и pinnedSDK. Параметр `--expected-branch` позволяет сохранить ветки36/37; legacy default `work` здесь не используется. Подготовка checkout к утверждённому SHA — отдельное действие пользователя; команды ниже её **не** выполняют. `build` действительно подписывает, хотя не имеет отдельного CLI flag; не запускать его в рамках unsigned-проверки.

```bash
read -r -p 'Reviewed existing branch: ' release_branch
read -r -p 'Installed baseline versionCode (35 or 36): ' installed_build
test "$(git branch --show-current)" = "$release_branch"
[[ "$installed_build:$release_build" == 35:36 || "$installed_build:$release_build" == 36:37 ]]
python3 scripts/release/android_release.py preflight \
  --repository /opt/gallery-fork --expected-head "$release_sha" --expected-branch "$release_branch" \
  --installed-build-number "$installed_build" --build-number "$release_build"
# Следующая команда ТОЛЬКО после отдельного согласования подписи:
python3 scripts/release/android_release.py build \
  --repository /opt/gallery-fork --expected-head "$release_sha" --expected-branch "$release_branch" \
  --installed-build-number "$installed_build" --build-number "$release_build"
python3 scripts/release/android_release.py postflight \
  --repository /opt/gallery-fork --expected-head "$release_sha" --expected-branch "$release_branch" \
  --installed-build-number "$installed_build" --build-number "$release_build"
```

Builder проверяет source/пины/lockfile, format/analyze/full Flutter и Gradle `:app:testDebugUnitTest`, неизменность существующих signing files, actual APK manifest/package/version/certificate и все universalABI. Gradle unit tests не заменяют native ExoPlayer CI и реальные Samsung-сценарии H1. Format gate проверяет все tracked Dart-исходники `mobile/lib`, `mobile/test`, `mobile/integration_test` (кроме generated files); тот же список используется в Static CI. Не использовать `--split-per-abi` как единственный артефакт. Не использовать legacy `sign-existing` с зашитыми Build8 hash/run IDs. Сохранить выдаваемые APK/receipt/SHA256 и подпись приватно. Облачный unsigned verifier (`mobile/scripts/verify_unsigned_android.py`) отдельно проверяет отсутствие v1/v2/v3 signature, manifest/version, arm/arm64/x64 и обязательныеnative libraries.

Обновление35→36 и36→37 проверять отдельно на Samsung: **update без uninstall/clear-data**, тот же package/сертификат, большеversionCode. До/после записать login/server/library counts/local IDs/backup settings/queues/trash/stacks и исходныеbytes синтетическихoriginal/motion. H1 cold start обязательно после обновления. При несовместимой подписи не удалять установленное приложение. Восстановление БД — только из заранее проверенного совместимого backup; не понижатьversionCode и не открывать новую БД старымAPK как автоматический rollback.

## macOS: unsigned iOS archive/IPA и SideStore

HP Linux не является iOS buildhost. На macOS/Xcode использовать отдельный чистыйcheckout того жеreviewedSHA, существующий pinnedSDK/CocoaPods и **без signing credentials**:

```bash
set -euo pipefail
read -r -p 'Reviewed full source SHA: ' release_sha
read -r -p 'Reviewed build number (36 or 37): ' release_build
[[ "$release_sha" =~ ^[0-9a-f]{40}$ ]]
[[ "$release_build" == 36 || "$release_build" == 37 ]]
test "$(uname -s)" = Darwin
test "$(git rev-parse HEAD)" = "$release_sha"
test -z "$(git status --porcelain)"
test "$(sed -n 's/^version: //p' mobile/pubspec.yaml)" = "5.7.3+$release_build"
FORK_VERSION=5.7.3 BUILD_NUMBER="$release_build" bash branding/scripts/apply-branding.sh
bash mobile/scripts/ios_build_only.sh
shasum -a 256 mobile/build/ios/ipa/Photos-unsigned.ipa
```

`ios_build_only.sh` использует `CODE_SIGNING_ALLOWED=NO`, проверяетRunner+extensions и упаковываетunsignedIPA; не делать `--refresh-pods-lock` в финальнойсборке. Получившийсяartifact/manifest проверить на sourceSHA, 5.7.3/build36или37, bundleidentity, AppGroups/entitlements, extensioncompatibility. Сохранить lockfile/tool versions иSHA256; outputbytes разных Xcode не считатьбит-в-бит идентичными безпроверки.

`prepare_sidestore.py` по умолчанию делает ad-hoc seed и **не является чисто unsigned/check-only операцией**. Сейчас разрешён только её `--check-only` после заданияteamID владельцем; seed/PersonalTeam signing/SideStore installation/refresh требуют отдельного согласования. Не использовать чужие Applecredentials или новыеkeys. ИсходнуюIPA сохранять, преобразования выполнятьтолько на отдельной копии. Реальный iPhone/SideStore H5 обязателен; simulatorPASS этого не заменяет.

## Safe update / rollback receipt

До любого deployment отдельно согласовать конкретный image digest/SHA/APK certificate/IPAmanifest и независимую проверку backup/restore БД, конфигурации иmedia references. Не копировать/переимпортировать фото радиобновления. Сохранить прежние image/APK/DBversion/конфигурацию; schema migrations требуютсовместимогоrestoreplan. Пользователь выполняет HP update/rollback отдельно; здесь нет `docker compose up`, остановки/замены контейнеров, установкиAPK/IPA или massregeocoding.

## Устранённый CI release-blocker

На PR21 `52ac6472a`, job126427773734 release Javac воспроизвёл отсутствующий `dev.flutter.plugins.integration_test`. Причина установлена по закреплённому [FlutterCommand3.47.2](https://github.com/flutter/flutter/blob/3.47.2/packages/flutter_tools/lib/src/runner/flutter_command.dart) (`regeneratePlatformSpecificToolingIfApplicable` возвращаетпри`!shouldRunPub`) и [injectPlugins](https://github.com/flutter/flutter/blob/3.47.2/packages/flutter_tools/lib/src/flutter_plugins.dart) (releaseфильтруетdevplugins). После обычногоcodegen `--no-pub` оставляет debugregistrant; Gradle release уже исключаетtestclass. CIкоманда теперь `flutter build apk --release --pub` послеfrozeninstall с последующей проверкой неизменности `pubspec.lock`. Integration_test остаётсяdevdependency; generatedJava вручную не правится. Повтор фактической release-компиляции Build37 прошёл на `17f201aa7` и `0a5654701` (run41794499835/job126455642334). Это unsigned hosted CI, не подпись оригинальным ключом и не проверка обновления на Samsung.
