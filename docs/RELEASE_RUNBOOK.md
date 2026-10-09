# «Фото»: воспроизводимая мобильная сборка и проверка

Текущий release — **5.7.2 (8)**. Backend/очереди/согласованный source SHA и
порядок approval описаны в [Trash release handoff](../specs/testing/2026-10-09-trash-release-handoff.md).
Исторические artifacts ниже не заменяют новый build. До HP диагностики и
разрешения deployment/integration ничего на production не выполнять.

Этот runbook выполняет владелец на HP/macOS. Он не обновляет production server,
PostgreSQL/Redis/ML/Big-LaMa, внешние Memories/auto-stack workers, Synology,
VPN/AWG/Xray/DNS и не повторяет закрытую миграцию Anna. Из Codex production
сборка с постоянным Android ключом не выполнялась: **PREPARED / NEEDS_HP_VALIDATION**.
Прохождение CI/dev проверок не означает физическую проверку S23/iPhone.

## Исторические artifacts build 6 (не текущий release)

| Platform                             | Успешный run / source SHA                                                                                                           | Artifact                                               | SHA-256 файла внутри artifact                                      |
| ------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------ | ------------------------------------------------------------------ |
| Android, release-mode / CI debug key | [37656011448](https://github.com/docice545/gallery/actions/runs/37656011448), attempt 2; `17fc9ede3b934b76617e3c03f70109ff33d6d38b` | `android-media-pilot-validation-apk`, ID `11501431124` | `07c82ca3b90decb4df005f1d273c473a161a5339a03e59334fd056dad39fbf82` |
| iOS, unsigned / Xcode 26.2           | [37661916279](https://github.com/docice545/gallery/actions/runs/37661916279); `102559e9d887c1defdb1d9037b0b691fb3d75371`            | `ios-unsigned-ipa`, ID `11500939142`                   | `24b453f4a7a4e15094e7bed6e1dd095ce617fac384d110f92b4d31684dff089c` |

`ios-unsigned-archive` — ID `11501298710`. Это SHA файлов APK/IPA,
не SHA внешних artifact ZIP. Native/archive verification выполнены в CI;
локальное скачивание в Codex заблокировано storage allowlist. Команды ниже
используются на обычной сети оператора. APK из CI не устанавливать поверх
HP-key-signed приложения: для него нужен HP build из раздела 3.
Финальный documentation HEAD брать из итогового handoff отдельно от source SHA.

## 1. Зафиксировать проверенный исходный commit

Используйте полный SHA из итогового handoff, а не автоматически выбранный
последний HEAD. Номер версии APK сам по себе не доказывает commit сборки.
В handoff различаются **итоговый checkout HEAD** и **source SHA конкретного CI
artifact**. Если после сборки добавлен только отчёт, SHA этого документационного
commit не подменяет source SHA уже готовых APK/IPA. Scripts проверяют точное
значение, а не эквивалентность исходного кода между commits.

```bash
set -euo pipefail
cd /opt/gallery-fork
# Подставить полный SHA проверенного финального commit из handoff.
export GALLERY_EXPECTED_HEAD='<FULL_REVIEWED_COMMIT_SHA>'

# Только чтение: checkout уже bind-mounted с SSD; caches/model не переносить.
findmnt -T /opt/gallery-fork
git branch --show-current
git rev-parse HEAD
git status --short
test "$(git branch --show-current)" = work
test -z "$(git status --porcelain)"

# Только fast-forward. При несовпадении или пользовательской работе остановиться.
git fetch origin refs/heads/work:refs/remotes/origin/work
test "$(git rev-parse origin/work)" = "$GALLERY_EXPECTED_HEAD"
git merge --ff-only origin/work
test "$(git rev-parse HEAD)" = "$GALLERY_EXPECTED_HEAD"
test -z "$(git status --porcelain)"
```

Не применять `reset`, `clean`, squash или force-push. Если remote уже ушёл дальше
проверенного SHA, сначала сверить новый handoff; этот блок намеренно остановится.
`/opt/gallery-fork` является bind mount `/mnt/hp-data/gallery-fork`. Существующие
Gradle/Pub caches и Big-LaMa model находятся на SSD, Docker root — на NVMe;
release tools не перемещают и не дублируют их.

## 2. Android: read-only preflight

Нужны Python 3.11+, существующий Flutter из pin `mobile/mise.toml` (сейчас
3.47.2) и его Dart, JDK 17 для Android, Mise, SDK 36 и Build Tools 36.0.0.
Mise использует свои существующие pinned инструменты для OpenAPI; Android
Gradle продолжает использовать внешний `JAVA_HOME` 17. Ничего не обновлять
ради предупреждений Gradle/AGP/Kotlin.

```bash
cd /opt/gallery-fork
export ANDROID_HOME="$HOME/Android/Sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export PATH="$JAVA_HOME/bin:$PATH"
# Удалить только CI overrides из окружения этого shell; значения не печатать.
unset ALIAS ANDROID_KEY_PASSWORD ANDROID_STORE_PASSWORD PR_NUMBER

python3 scripts/release/android_release.py preflight \
  --expected-head "$GALLERY_EXPECTED_HEAD" --build-number 8
```

Preflight выводит `PASS`/`FAIL`, ничего не устанавливает и не создаёт ключей.
Он требует branch `work`, точный ожидаемый HEAD, чистый working tree,
правильный toolchain и непустые **уже существующие**, ignored/untracked
`mobile/android/key.jks` и `key.properties`. Их содержимое не читается и не
печатается. Существующий alias **foto** и signing configuration сохраняются.
Ошибка preflight — остановка, а не повод создать новый ключ/debug fallback.

## 3. Android: одна безопасная команда сборки

```bash
python3 scripts/release/android_release.py build \
  --expected-head "$GALLERY_EXPECTED_HEAD" --build-number 8
```

Порядок: locked OpenAPI/Flutter dependencies → все Pigeon APIs через existing
package_config → localization/keys/Drift/build_runner → формат tracked Dart
sources → полный Flutter analyze и unit suite → Android Kotlin/AIDL/native
JUnit suite → release APK → фактические package/version/certificate/hash.
Используется существующий `android_media_codegen.sh`; генерация mobile Drift
кода не запускает production DB migrations. Native emulator CI остаётся отдельным
доказательством; HP-команда не выдаёт его за физический Samsung тест.

После native tests выполняется ещё один `flutter pub get --enforce-lockfile`,
затем APK строится со штатным `--pub`. Это необходимо для Flutter 3.47:
`--no-pub` пропускает mode-specific plugin registrant regeneration и оставляет
`integration_test` после debug/integration сборки, хотя release Gradle уже
исключает dev-only plugin. Стандартная Flutter release regeneration сама
исключает этот plugin; integration tests и dependencies не удаляются. SHA-256
lockfile и нормализованный resolved package graph проверяются до/после refresh
и после build. Изменение versions/paths/packages запрещает успешный handoff;
generated timestamp package_config не считается изменением dependency graph.

Build lock исключает одновременные Android release builds. В случае повторного
запуска уже завершённый artifact заново проверяется и возвращается с `PASS REUSED`;
это не заявляет повторного выполнения tests. Незавершённую сборку можно повторить;
отсутствие успешного manifest не превращается в успешный release. Старый стандартный
APK перед новым build сохраняется в приватной output directory, чтобы пропавший
новый output не прошёл как старый файл.

Неожиданный tracked diff после codegen/tests/build останавливает release.
Единственное исключение — исторически tracked
`mobile/android/build/reports/problems/problems-report.html`: если исходный
checkout был чист, tool сохраняет созданный Gradle diagnostic приватно и
восстанавливает **только этот собственный generated report** к исходным bytes.
Другие source/user файлы не восстанавливаются и не удаляются.

Logs находятся в ignored `mobile/build/release-handoff/`, с private permissions;
при failure выводится stage/exit code. Пароли не передаются в command line.
Не публикуйте полный локальный build log без проверки его содержимого.

## 4. Android: read-only postflight и handoff

```bash
python3 scripts/release/android_release.py postflight \
  --expected-head "$GALLERY_EXPECTED_HEAD" --build-number 8
git status --short
```

Ожидается **5.7.2 build 8**, `applicationId=de.opennoodle.gallery`.
Фактический APK обязан пройти `apksigner verify` с единственным сертификатом:

```text
ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18
```

Стандартный Flutter output остаётся
`/opt/gallery-fork/mobile/build/app/outputs/flutter-apk/app-release.apk`.
Versioned handoff содержит `Foto.apk`, `manifest.json` и build logs:

```text
/opt/gallery-fork/mobile/build/release-handoff/android-5.7.2-8-<HEAD_FIRST_12>/
```

Postflight сверяет реальный application ID/version/certificate, streaming SHA-256
файла, полный source SHA/branch и успешные stages в manifest. Не сообщает
фиктивный SHA до выполнения build. CI artifact
`android-media-pilot-validation-apk` подписан временным debug certificate и
**не может обновить установленное HP release-key приложение**. Используйте
проверенный HP `Foto.apk`, устанавливайте поверх существующего приложения без
удаления данных. APK, keys, `key.properties` и profiles не коммитить.
У CI APK source SHA берётся из соответствующего Actions run; у нового HP APK —
из его `manifest.json`, где он обязан совпасть с `GALLERY_EXPECTED_HEAD`.
Более поздний commit только с отчётом не меняет provenance старого CI APK.

Физический S23 / Android 16 / One UI 8.5: проверить сохранение session/data,
Trash после stale sync/restart, Library Albums late preview и hide/reorder/reset,
sharp face-aware Live/Motion thumbnail и один muted one-shot playback после
settling; scroll немедленно останавливает. Для Cloud Picker выполнить
[существующий Shizuku pilot](../specs/testing/2026-10-07-cloud-media-s23-pilot.md):
on-device Wireless Debugging, Shizuku permission, opt-in и ручной выбор «Фото»
в системном Picker. Root/rish/компьютер не требуются; физический результат ещё
должен подтвердить пользователь.

## 5. iOS: unsigned verification, затем отдельный бесплатный install

Production signing, App Store Connect, paid certificates/TestFlight не нужны
для build-only проверки и в эту процедуру не входят.
Программа `mobile/scripts/release/ios_unsigned.py` запускает существующий
`.github/workflows/gallery-build-mobile.yml` с пустым `version`, `build_target=ios`,
`android_media_pilot=false`, `refresh_ios_pods_lock=false`. Tool проверяет точный
remote HEAD и не dispatch-ит новый run при другом активном run `work`.
Нужны Python 3.11+ и обычный GitHub CLI доступ; Apple credentials не нужны.

```bash
export GALLERY_RELEASE_DIR="$HOME/Downloads/foto-release-$GALLERY_EXPECTED_HEAD"
python3 mobile/scripts/release/ios_unsigned.py preflight \
  --expected-commit "$GALLERY_EXPECTED_HEAD"
python3 mobile/scripts/release/ios_unsigned.py dispatch \
  --expected-commit "$GALLERY_EXPECTED_HEAD" --wait \
  --version 5.7.2 --build 8 --output "$GALLERY_RELEASE_DIR/ios"
```

Если точный unsigned run из handoff уже успешен, **пропустить dispatch** и
загрузить его artifact следующим блоком. `GALLERY_IOS_SOURCE_HEAD` — полный
`head_sha` этого run; он может отличаться от итогового checkout HEAD, если после
сборки был добавлен только проверенный документационный отчёт. Не заменять его
значением `git rev-parse HEAD` автоматически.

```bash
export GALLERY_IOS_SOURCE_HEAD='<FULL_RELEASE_SHA_FROM_FINAL_HANDOFF>'
export GALLERY_IOS_RUN_ID='<SUCCESSFUL_BUILD_8_RUN_FROM_FINAL_HANDOFF>'
python3 mobile/scripts/release/ios_unsigned.py fetch --run "$GALLERY_IOS_RUN_ID" \
  --expected-commit "$GALLERY_IOS_SOURCE_HEAD" \
  --version 5.7.2 --build 8 --output "$GALLERY_RELEASE_DIR/ios"
```

Успех должен включать настоящую macOS/Xcode compilation, archive verification
всех трёх bundles и `ios-unsigned-archive` / `ios-unsigned-ipa`; missing artifact
является failure. Не использовать старый run/версию за новый release.
Точный новый run/source SHA/artifact/digest и итоговый checkout HEAD фиксируются
отдельно в handoff. `release-manifest.json.commit` содержит source SHA IPA,
не более поздний HEAD документационного отчёта. Download
проверяет provenance/run SHA, отсутствие paid steps, package metadata всех
трёх targets, ASCII base names и русскую localization. На выходе:
`Photos-unsigned.ipa`, `.sha256`, `release-manifest.json`. Недоступность download
или native artifact — честный failure; сборка не заменяется другой IPA.
Повторный `dispatch --wait --output` с уже готовым handoff проверяет тот же
checkout, receipt/version/build/hash и исходный успешный run, затем возвращает
существующий artifact без нового CI запуска. Чужой, повреждённый или
несоответствующий output останавливает команду до dispatch.

Обычная unsigned IPA сохраняет Runner + ShareExtension + WidgetExtension.
Последующий бесплатный SideStore/LocalDevVPN этап выполняется на физическом
iPhone с Personal Team и собственным Apple ID; это отдельный user-side signing
gate, не «готовая signed IPA» из CI. Base names ASCII, русское launcher name
«Фото» остаётся через localization. Не удалять extensions и не переделывать
App Groups ради предполагаемой ошибки подписи.

Для уже подготовленного SideStore pilot только на Mac, после получения реального
Personal Team ID из собственной SideStore настройки:

```bash
# INPUT_SHA берётся из проверенного Photos-unsigned.ipa.sha256/manifest.
export IPA_SHA='<VERIFIED_INPUT_IPA_SHA256>'
export PERSONAL_TEAM_ID='<YOUR_ACTUAL_PERSONAL_TEAM_ID>'

# Portable read-only проверка входа; Mac codesign пока не запускается.
python3 mobile/scripts/release/prepare_sidestore.py \
  --ipa "$GALLERY_RELEASE_DIR/ios/Photos-unsigned.ipa" \
  --input-sha256 "$IPA_SHA" --team-id "$PERSONAL_TEAM_ID" \
  --version 5.7.2 --build 8 \
  --output "$GALLERY_RELEASE_DIR/ios/Photos-5.7.2-8-SideStore-seed-unsigned.ipa" \
  --check-only

# Отдельный Mac pilot gate: seed/ad-hoc подготовка, не paid distribution signing.
python3 mobile/scripts/release/prepare_sidestore.py \
  --ipa "$GALLERY_RELEASE_DIR/ios/Photos-unsigned.ipa" \
  --input-sha256 "$IPA_SHA" --team-id "$PERSONAL_TEAM_ID" \
  --version 5.7.2 --build 8 \
  --output "$GALLERY_RELEASE_DIR/ios/Photos-5.7.2-8-SideStore-seed-unsigned.ipa"
```

Входная unsigned IPA остаётся неизменной; seed сохраняет обе extensions.
Этот этап не создаёт Apple certificate/profile и не устанавливает приложение.
Реальную бесплатную подпись выдаёт SideStore/Apple Personal Team на iPhone.
Импортировать подготовленную seed IPA в SideStore с **Append Team ID включённым**;
при выборе extensions — **Keep App Extensions (Register App ID for Each Extension)**.
Не выбирать Use Main Profile/Remove App Extensions. Mac seed codesign и реальный
free provisioning/installation требуют отдельной проверки: **NEEDS_MAC_VALIDATION /
NEEDS_PHYSICAL_IPHONE_VALIDATION**, пока они действительно не выполнены.

Основа: [iOS implementation/physical acceptance](../specs/testing/2026-10-05-ios-implementation-validation.md),
[free distribution design](../specs/2026-10-05-ios-free-distribution-design.md),
[HP/free pilot](../specs/testing/2026-10-06-mobile-week-hp-free-pilot.md).
Проверить PhotoKit denied/limited/full/iCloud-only, paired Live import/share/save
и честный image-only fallback, background expiration/cancel/drain, ShareExtension,
Widget/App Group, update/session preservation и два free 7-day refresh cycles.
CI compilation не заменяет эту физическую проверку.

## 6. Server deployment и rollback

**Для текущего Trash safety release требуется backend update** после отдельного
approval. До read-only HP queue/backups/mount report production — NOT READY.
См. [точный порядок и rollback limits](../specs/testing/2026-10-09-trash-release-handoff.md).
Новых DB migrations нет; существующие FileDelete не становятся безопасными
от одной замены image. Только service immich-server, no-deps; не трогать
PostgreSQL/Redis/ML и persistent volumes. Старая mobile-only формулировка
NO SERVER DEPLOYMENT REQUIRED относится к прошлому release и больше
не является инструкцией для этого backend safety патча.

## 7. Memories / VAAPI и независимый rollback

В этой задаче не установлен и не заменён внешний renderer/VAAPI runtime.
Memories/VAAPI setup, activation и rollback tools — **NOT REQUIRED**.
Ранее работающий HP VAAPI путь сохраняется; не отключать его ради mobile release.
Не запускать historical warmup или полный анализ библиотеки.

Исходный `StreamingEncoder`/`assemble_streaming` и доказательства уже завершённого
job всё ещё нужны для корректного исправления отсутствующих source videos и
дальнейшей оптимизации. См.
[точную границу доступных источников](../specs/2026-10-07-memory-video-vaapi-source-boundary.md).
Это **BLOCKED_EXTERNAL_SOURCE / NEEDS_HP_VAAPI_VALIDATION**, а не выполненное
ускорение. Новых `/dev/dri` permissions, Docker/network settings и installation
scripts без исходников здесь нет.

## 8. Физическая приёмка и состояние tooling

До установки сохранить проверенные APK/IPA, receipts и SHA-256. Source HEAD,
run ID и исходный artifact должны соответствовать итоговому handoff.

На **Samsung S23 / Android 16 / One UI 8.5**:

1. Установить HP-key-signed `Foto.apk` поверх существующего «Фото»; проверить
   session, настройки и библиотеку без очистки данных.
2. Отправить фото в Trash, дождаться sync, повторить foreground/background,
   restart и reconnect: оно остаётся только в Trash; Restore возвращает его.
3. Открыть Library до завершения sync. Albums должен обновить mosaic сам;
   проверить empty/loading/error, Retry и одну недоступную обложку. Проверить
   сохранённые show/hide/reorder/reset всех Registry-карточек.
4. Проверить sharp still и muted one-shot Live/Motion в ленте, портрет/landscape,
   лица, быстрый scroll, viewer/navigation и отсутствие каскада. При статичном
   результате сохранить только `Timeline motion:` stage records и build receipt.
5. Установить официальный Shizuku; включить Developer options → Wireless debugging,
   выполнить pairing code на телефоне и Start. В «Фото» выдать Shizuku permission,
   включить provider в Advanced settings, затем вручную выбрать «Фото» в системном
   Photo Picker. Проверить server-only photo в приложении, которое действительно
   вызывает системный Picker, затем большое видео/seek/cancel/network loss.
6. Проверить exclusion Trash/Locked/hidden motion companions, account switching,
   сохранность Google Photos/другой allowlist, reboot и Disable/recovery.
   Привилегированное undo при pending journal требует снова запустить Shizuku;
   обычное чтение media через него не проходит.

На **iPhone iOS 17+** для полного набора extensions:

1. Использовать проверенный SideStore/LocalDevVPN pilot и собственный Apple ID;
   paid Apple Developer/TestFlight не требуются. Проверить actual Personal Team
   profiles, group entitlement и `AppGroupId` всех трёх подписанных targets.
2. После Developer Mode/trust проверить имя «Фото», auth/session, ShareExtension,
   WidgetExtension/App Group и update поверх предыдущей установки.
3. Проверить PhotoKit permissions/local/iCloud, HEIC/HEVC Live Photos,
   still+motion identity, incoming/outgoing Share, Save и image-only fallback.
4. Проверить timeline/face crop, Memories, Trash, manual stacks, Magic Eraser,
   background lock/expiration/cancellation/network loss/upload resume.
5. Проверить ежедневный free refresh с LocalDevVPN и минимум два 7-day цикла,
   включая reboot и восстановление после неудачного refresh. Автоматизация iOS
   не гарантирует продление при любой сети/состоянии устройства.

| Tool                                               | Проверено здесь                                                               | Реальный release gate                                                        |
| -------------------------------------------------- | ----------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Android `android_release.py`                       | guards/failure/idempotency tests, read-only preflight                         | **PREPARED BUT NEEDS HP VALIDATION**: постоянный ключ доступен только на HP  |
| Existing unsigned iOS workflow + `ios_unsigned.py` | metadata/provenance/guards tests; actual macOS build and archive verification | **TESTED** in CI; Cloud download policy and physical install remain separate |
| `prepare_sidestore.py`                             | deterministic mapping, safe ZIP/staging, check-only и mocked codesign tests   | **PREPARED BUT NEEDS MACOS AND PHYSICAL IPHONE VALIDATION**                  |
| Server deployment/rollback                         | Server изменений нет                                                          | **NOT REQUIRED**                                                             |
| Memories/VAAPI setup/rollback                      | External runtime не изменён                                                   | **NOT REQUIRED**                                                             |

Повторяемые тесты tooling:

```bash
python3 -m unittest discover -s scripts/release/tests -p 'test_android_release.py'
python3 -m unittest discover -s mobile/scripts/tests -p 'test_ios*.py'
python3 -m unittest discover -s mobile/scripts/tests -p 'test_package_unsigned_ios.py'
bash -n mobile/scripts/android_media_codegen.sh mobile/scripts/android_native_motion_test.sh mobile/scripts/ios_build_only.sh
```

Fixture/mock tests не заменяют HP signing, Mac codesign или физический S23/iPhone.
Все команды здесь соответствуют committed tooling; установка и production
deployment автоматически из Codex не выполняются.
