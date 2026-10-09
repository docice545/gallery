# «Фото»: воспроизводимая мобильная сборка и проверка

Текущий release — **5.7.2 (8)**, source **`6a558b554e26e8c0fc5bc5c99259a92e7ef26a56`**.
Для текущего Stage 1 использовать **только раздел 0**: все artifacts уже собраны,
новых mobile/backend builds не требуется. Разделы 1–8 ниже — прежний общий
build/pilot workflow, а не последовательность текущего deployment.
Production-аудит завершён; интеграция, recovery validation, deployment,
возобновление retention и HP signing требуют отдельных разрешений.

Этот runbook выполняет владелец на HP/macOS. Он не обновляет production server,
PostgreSQL/Redis/ML/Big-LaMa, внешние Memories/auto-stack workers, Synology,
VPN/AWG/Xray/DNS и не повторяет закрытую миграцию Anna. Из Codex production
сборка с постоянным Android ключом не выполнялась: **PREPARED / NEEDS_HP_VALIDATION**.
Прохождение CI/dev проверок не означает физическую проверку S23/iPhone.

## 0. Stage 1: один execution package, без повторных сборок

| Компонент | SUCCESS run / artifact                                                                                                                   | Source / версия                                |
| --------- | ---------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------- |
| Backend   | [37953392247](https://github.com/docice545/gallery/actions/runs/37953392247/artifacts/11626603468), `gallery-trash-server-linux-amd64`   | `6a558b55…`, server 5.7.1                      |
| Android   | [37944044747](https://github.com/docice545/gallery/actions/runs/37944044747/artifacts/11624073289), `android-media-pilot-validation-apk` | тот же source, 5.7.2 (8), CI debug certificate |
| iOS       | [37936380827](https://github.com/docice545/gallery/actions/runs/37936380827/artifacts/11618922989), `ios-unsigned-ipa`                   | тот же source, 5.7.2 (8), unsigned             |

Backend tooling commit `d3f999e7d21c7c7f4e9b9bc5ac1e1af62de6cf3d` отличается
от source; receipt содержит оба. Последующий execution package также **не меняет
application source**, не требует CI rebuild и не подменяет SHA artifacts.

### Обязательные prerequisites

1. Отдельно разрешить интеграцию source в `work`; HP checkout должен быть чистым
   `work` на точном `6a558b55…`. Этот пакет **не выполняет Git merge**. Скопировать
   tooling отдельно через `git archive`, чтобы source checkout остался точным.
2. Выполнить проверку восстановления backup в отдельном PostgreSQL с тем же
   image ID, `--network none`, без production volumes/ports, CPU 1 / RAM 2 GiB.
   Нужны минимум 3 GiB свободной RAM и 8 GiB Docker disk. Для deployment выбранный
   SQL/gzip backup должен быть свежим, **младше 1 часа**; 17-часовой backup из
   аудита достаточен для первоначальной репетиции, но не для финального gate.
   Новый backup создать штатным, отдельно одобренным способом. Копия старого dump
   с новым mtime не является свежим backup. Пакет не запускает
   backup job, не повторяет historical analysis и не меняет production БД.
3. В DSM/существующей backup-системе подтвердить реальный recovery point **для всех
   NFS shares с managed/external originals**. Из этого snapshot/backup экспортировать
   по одному несекретному фото и видео с каждого mount в отдельную локальную HP
   папку. Не восстанавливать поверх NAS. Сравнить исходные и восстановленные bytes.
   Проверить scope, дату, доступность recovery point и playback восстановленного
   видео. Пакет проверяет byte hashes; источник восстановления и полный snapshot
   scope подтверждает оператор. Видимый каталог snapshot не заменяет этот шаг.
4. Подготовить существующий admin API key в приватном regular файле `0600`, с
   `job.create`, `asset.upload/read/download/delete` и нужными
   account permissions. Значения ключей/паролей не выводить и не помещать в shell
   history. API доступен по loopback `127.0.0.1:2283`; redirects запрещены.
5. Docker/Compose доступен `doctoriceadm` напрямую или через уже разрешённый
   `sudo -n docker`. Пакет не меняет sudoers/groups, NAS permissions или networking.
   На время перехода согласовать короткое окно без user permanent-delete и без
   новых library-removal операций. Не останавливать внешние workers/timers.

Полный HP audit — JSON report в TXT, все 10 sections PASS, `errors=[]`, queues
пустые, `inventoryComplete=true`, legacy/FileDelete ноль. Все 293 Active+deletedAt
классифицированы offline external index tombstones. Эти строки не «исправлять».
При изменении image/container/topology, появлении job, несовпадении migration
inventory или неподтверждённом recovery пакет останавливается. Очереди не чистятся.
Дополнительный deletion consumer требует отдельного review, а не автоматического
перезапуска. В текущем Stage 1 **новых schema migrations нет**. Точный runtime
inventory включает build-time compatibility aliases; неизвестный/pending name — STOP.

`nas-proof.json` — приватный `0600` файл на HP. Keys `mounts` брать **точно** из
`containers[role=immich_server].externalMounts[].containerMountpoint` audit.
Для каждого key нужны `operator_attests_snapshot_export: true`, реальный
`snapshot_reference` и `samples` из photo/video. Ниже только схема, не реальные
media paths; proof не коммитить и не публиковать:

```json
{
  "mounts": {
    "<containerMountpoint из audit>": {
      "operator_attests_snapshot_export": true,
      "snapshot_reference": "<реальный DSM/backup recovery point>",
      "samples": [
        { "kind": "photo", "original": "<NAS sample>", "recovered": "<HP restored sample>" },
        { "kind": "video", "original": "<NAS sample>", "recovered": "<HP restored sample>" }
      ]
    }
  }
}
```

### Один последовательный блок оператора

**Не выполнять до соответствующих разрешений.** Полный `GALLERY_TOOLING_SHA`
брать из финального handoff; это SHA пакета, а не source. Параметры audit/backup/
proof/key заполнить реальными приватными путями на HP. `set -euo pipefail`
останавливает блок на первом FAIL. Никаких автоматических retries, очередей
`clear/remove`, server builds или mobile rebuilds здесь нет.

```bash
set -euo pipefail
umask 077
test "$(id -un)" = doctoriceadm
: "${GALLERY_TOOLING_SHA:?Полный SHA execution package из handoff}"
: "${GALLERY_HP_AUDIT:?Путь завершённого PASS audit TXT}"
: "${GALLERY_SQL_BACKUP:?Путь свежего штатного .sql.gz backup}"
: "${GALLERY_NAS_PROOF:?Путь приватного nas-proof.json}"
: "${GALLERY_ADMIN_KEY_FILE:?Путь приватного существующего admin API key}"

# Скачать tooling без изменения checkout/work; artifacts скачиваются один раз.
git -C /opt/gallery-fork fetch origin candidate/gallery-trash-5.7.2-build8
test "$(git -C /opt/gallery-fork rev-parse FETCH_HEAD)" = "$GALLERY_TOOLING_SHA"
release_dir="$(mktemp -d /mnt/hp-data/gallery-trash-release-XXXXXXXX)"
mkdir -m 700 "$release_dir/tools" "$release_dir/state" "$release_dir/artifacts"
git -C /opt/gallery-fork archive "$GALLERY_TOOLING_SHA" scripts/release |
  tar -x -C "$release_dir/tools"
mkdir "$release_dir/artifacts/backend" "$release_dir/artifacts/android" "$release_dir/artifacts/ios"
gh run download 37953392247 -R docice545/gallery -n gallery-trash-server-linux-amd64 -D "$release_dir/artifacts/backend"
gh run download 37944044747 -R docice545/gallery -n android-media-pilot-validation-apk -D "$release_dir/artifacts/android"
gh run download 37936380827 -R docice545/gallery -n ios-unsigned-ipa -D "$release_dir/artifacts/ios"

runner="$release_dir/tools/scripts/release/trash_execute.sh"
args=("$release_dir/state" "$release_dir/artifacts" "$GALLERY_HP_AUDIT" "$GALLERY_SQL_BACKUP" "$GALLERY_NAS_PROOF" "$GALLERY_ADMIN_KEY_FILE")
bash "$runner" verify "${args[@]}"

# Разрешение только на изолированную recovery validation; production пока не меняется.
GALLERY_RECOVERY_APPROVED=YES bash "$runner" recover "${args[@]}"

# Только после отдельного deployment approval: pause + live queue/schema gates,
# backup Compose/.env/old image; новый server API-only; остальных не пересоздаёт.
GALLERY_DEPLOYMENT_APPROVED=YES bash "$runner" deploy "${args[@]}"
GALLERY_DEPLOYMENT_APPROVED=YES bash "$runner" acceptance "${args[@]}"

# ОТДЕЛЬНОЕ разрешение возобновить существующую 30-day retention/deletion policy.
# После этого expired managed Trash может штатно удаляться с writable NAS.
GALLERY_DEPLOYMENT_APPROVED=YES GALLERY_RETENTION_RESUME_APPROVED=YES \
  bash "$runner" enable-workers "${args[@]}"

# Только после signing approval и integration: переподписать уже готовый APK.
export ANDROID_HOME="$HOME/Android/Sdk"
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export PATH="$JAVA_HOME/bin:$PATH"
GALLERY_SIGNING_APPROVED=YES bash "$runner" sign-android "${args[@]}"
printf 'iOS unsigned IPA: %s\nRelease receipts: %s\n' \
  "$release_dir/artifacts/ios/Photos-unsigned.ipa" "$release_dir/state"
```

Повторно не запускать весь блок для скачивания: сохранить `release_dir`, `runner`
и `args`. Verify/подпись/override/recovery receipts переиспользуются при совпадении;
deployment journal запрещает слепое повторное deployment. При незавершённом
restore private log сохраняется, исправить причину и использовать новую state
папку; не удалять receipt ради обхода gate. Proof/recovery проверены не более
24 часов назад; backup перед deployment всё ещё младше 1 часа.

### Немедленный rollback и persistence override

При FAIL health/acceptance остановить дальнейшие шаги. Сохранить тот же `state`
и выполнить только после разрешения:

```bash
GALLERY_DEPLOYMENT_APPROVED=YES bash "$runner" rollback "${args[@]}"
```

Rollback сверяет journal/config hashes и live image, требует paused/empty queue
если workers работали, возвращает **ровно предыдущий image ID** только для
`immich-server`, затем проверяет health/version и IDs других контейнеров.
**Старые deletion workers остаются выключенными, очередь paused**. Он не
откатывает DB, не восстанавливает NAS bytes и не запускает switch-back SQL.
Если очередь уже непуста, health API недоступен при работающих workers либо
конфигурация изменилась — STOP для индивидуального решения, не force-delete.
Нельзя вернуть старые workers без нового queue/recovery review.

Base Compose/.env не редактируются: journal сохраняет их private backups/hashes,
пакет добавляет только server image/worker environment override. После успешного
enable всегда использовать фактический Compose base из journal **вместе с**
`normal-workers.override.json`; после rollback — `rollback-api-only.override.json`.
Команда `docker compose up` с одним старым base может вернуть прежний image и
убрать worker gate. Docker restart существующего контейнера сохраняет override
environment. State/previous-server-image.tar сохранять до окончания приёмки,
никаких global prune/down/volume removal.

### Mobile handoff и disposable acceptance

Android signer проверяет input SHA/certificate/package/CMP manifest/ARM64 native
libs, переподписывает прежним alias `foto` через stdin, сверяет неизменность всех
application ZIP entries и native alignment, затем HP certificate и checksum.
Не создаёт ключи, не выполняет Flutter/Gradle/codegen, не устанавливает приложение.
Итог: `/opt/gallery-fork/mobile/build/release-handoff/android-5.7.2-8-6a558b554e26/Foto.apk`
и `manifest.json`, ожидаемый cert
`ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18`.
Установить поверх build 7 без uninstall/очистки данных. CI APK до переподписи
не является update. Реальная HP подпись и S23 update пока **NEEDS_HP/DEVICE_VALIDATION**.

iOS `Photos-unsigned.ipa` — прежний SUCCESS artifact, unsigned. Использовать
только действующую **SideStore + LocalDevVPN** схему и тот же Personal Team/
bundle mapping для update. Выбрать **Keep App Extensions (Register App ID for
Each Extension)**; main profile не заменяет отдельные extension App IDs.
Сохранить Runner/ShareExtension/WidgetExtension и App Group. Если существующая
установка использует подготовленный seed, применить прежний
`mobile/scripts/release/prepare_sidestore.py` на Mac **с тем же team/mapping**;
это отдельная подготовка, не iOS rebuild и не новый signing service. Без этой
проверки исходный unsigned IPA напрямую не устанавливать. SideStore re-sign,
7-day refresh и сохранность session/data требуют физического iPhone.

Автоматический `acceptance` загружает **новый уникальный synthetic PNG**, никогда
не принимает чужой asset ID и отказывается от duplicate upload. Проверяет
Trash/Restore/idempotence, capture date/localDateTime и original bytes, оставляет
fixture Active. Он не вызывает permanent delete, retention или NAS unlink.
На S23/iPhone дополнительно создать отдельные несекретные disposable photo/video/
Live/Motion fixtures и test album: single/bulk Trash, restart/reconnect, delayed
sync, Restore→Trash, album membership, chronology/timezone, отсутствие ghosts/
duplicates, native/local-device confirmation и сохранность session после update.
Никаких destructive тестов на существующих семейных фото. Permanent/retention
проверки — только в изолированном storage, не production originals.

### Проверки execution tooling

Guard/failure/identity tests, JDK 17 source-launcher с **mock apksigner**, реальный
disposable SQL/gzip restore и Compose recreate/rollback выполнены в cloud.
Rollback orchestration сохраняет ID соседнего fixture container и API-only gate;
это не проверка HP health/network/конкретной production БД. HP restore выбранного
backup, DSM recovery, production-key signing и physical acceptance **не выполнены**.
Для tiny restore fixture cloud disk gate отдельно смоделирован: требование
8 GiB для реального HP restore не снято и не считается проверенным здесь.

```bash
GALLERY_RELEASE_TEST_JAVA=/path/to/existing/jdk17/bin/java \
  python3 -m unittest discover -s scripts/release/tests -p 'test_trash_execution.py'
# Только isolated local Docker; cached images, без production endpoints:
GALLERY_DISPOSABLE_RELEASE_TESTS=1 GALLERY_RELEASE_TEST_JAVA=/path/to/existing/jdk17/bin/java \
  python3 -m unittest discover -s scripts/release/tests -p 'test_trash_execution.py'
bash -n scripts/release/trash_execute.sh
```

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
approval. HP read-only queue/backups/mount report уже PASS; recovery proof и
deployment/retention approvals остаются обязательными. Использовать раздел 0.
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
| Server deployment/rollback                         | Disposable SQL restore, guarded Compose recreate/rollback, failure tests      | **PREPARED BUT NEEDS HP VALIDATION**, см. раздел 0                           |
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
