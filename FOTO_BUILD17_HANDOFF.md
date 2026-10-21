# FOTO Build 17 — Cloud checkpoint, 21 октября 2026

Ветка: **codex/foto-build17-web-handoff**. Исходный проверенный commit:
`2315ae789a3824c7a60dc688e541c30648385e03`.
Разработка ведётся только от него; main не использовалась и merge не выполнялся.

## Сохранённые изменения

- `2711a54ff52214f43b4ce9ffa63d12a8e1e996a3`: последовательный runner, общий session/stage flock,
  supervision дерева процессов, остановка без retry после OOM, crash-safe manifest transaction.
- `cc378e4c3`: mapper `duplicateId`, исправление ложного подтверждения external-only файла как
  managed mobile backup, PostgreSQL-регрессии с синтетическими файлами. Исходные исправления
  `f687de397`, `af2dc2df7`, `97e446038` сохранены. Дедупликация не опирается на имя/дату.
- `830ec05cb9e871a99b713fb5b3502d07f402c1b7`: клиенты, версия 17, unsigned release mode,
  checkpoints сборок, последовательный mobile codegen, предыдущий опубликованный checkpoint.
- Дополнительная проверка сохранила explicit external Trash как запрет автоматического reupload,
  отдельно от offline Active index tombstones. Реальный FAIL нового теста сначала воспроизведён,
  затем исправлен без миграции или изменения production данных.
- Дополнения runner: общий legacy lock на весь срок сессии, PID-bound entry для защиты от
  вложенного continuation, fail-fast проверка полного JDK и фиксация его identity в receipt.
  TLS для Java использует проверяемый системный truststore; проверки сертификатов не отключались.
- OpenAPI/TypeScript/Dart регенерированы закреплёнными генераторами. **Одно** смысловое изменение
  схемы: optional nullable `AssetMediaResponseDto.duplicateId`. Итоговый spec diff — 7 строк,
  SDK diff — 2 строки; массовых изменений API нет.
- Mobile version: **5.7.3+17**, applicationId **de.opennoodle.gallery**. Release без существующего
  ключа теперь **unsigned**, вместо опасного fallback на debug key. Поддержано существующее
  расположение ключа из signing configuration. Новых ключей не создавалось.
- Исправлены четыре analyzer warning в local Trash repository: только braces, логика не изменена.

## Фактически выполнено

Все тяжёлые этапы выполнялись последовательно через runner; не запускался локальный Codex.

| Проверка | Результат |
| --- | --- |
| Automation, Linux flock/signals/subreaper/pidfd, mock systemd argv, manifest interruption | 37/37 PASS после исправления APK runner |
| Backend asset-media/repository/library/metadata unit | 418/418 PASS |
| Backend deletion/recovery/Trash/storage/Big-LaMa contracts unit | 485/485 PASS |
| Изолированный PostgreSQL: upload/library/5 duplicate admission cases/authorized deletion, финальный прогон | 177/177 PASS |
| Неизменённые Live Photo root admission / retry, ранее выполненные | 18/18 PASS |
| Server TypeScript, targeted ESLint, Nest build + migration sync | PASS |
| TypeScript SDK build после регенерации | PASS |
| Flutter sync/backup/delete/restore/autoplay existing regressions | 177 PASS |
| Новый Dart upload-response contract | 3/3 PASS |
| Local Trash repository / hash retry | 7/7 PASS |
| Flutter analyze, всё приложение | PASS, No issues found |
| Production signing / физический Android / реальный Synology | NOT TESTED |

Первый medium run имел 7 failures: 6 старых assertions не учитывали уже добавленный `duplicateId`,
один требовал уничтожить/не сохранять external row при гонке с managed upload. Assertions
исправлены по контракту сохранности обеих копий, усилены проверкой общей byte-verified группы.
Новый external-only admission тест сначала воспроизвёл реальный FAIL; после исправления SQL — PASS.
Первый Flutter run: 177 PASS, 3 FAIL только в новых assertions, которые не учитывали `Optional`.
Исправлен wire roundtrip test, отдельно повторены и пройдены эти 3 теста. Остальные 177 не повторялись.
Analyzer сначала был заблокирован read-only HOME, затем показал 4 warnings; поддерживаемый cache
override и braces исправили оба случая. Проверки не выключались.

OOM смоделирован SIGKILL дочернего процесса, **не реальным исчерпанием памяти**. Systemd properties
и host-wrapper тестировались через mocks; настоящий HP cgroup/OOM остаётся операторской проверкой.
Произвольные команды вне runner не получают его flock автоматически. В managed протоколе
прямые Vitest/tsc/Flutter/Gradle запрещены; runner технически исключает перекрытие своих запусков.

## RAW fixture

Восстановлен только локальный тестовый `glarus.nef`, без коммита бинарных данных. Его provenance
проверен по upstream tree `ec56cc6c1d76c45bc9615dc6ea232470a2b0a3a1`:
Git blob `34f5c57b5d1f5f2e7eab78268e345116c42f6433`, размер 9,057,784 bytes,
SHA-256 `42446c7fc0b15f38cceb7f94cab469445ec65990ad2bc206297fbb28807e1f14`.
Все три RAW-сценария входят в прошедший library medium suite. Файл скопирован из старого
Cloud каталога только после совпадения blob hash/size с официальным upstream; исходник не изменён.

## Окружение и продолжение

Cloud checkout: `/workspace/gallery`. Node 24.21.0, pnpm 11.24.0, Vitest 4.1.11,
Flutter 3.47.2 / Dart 3.13.2. Используются lockfiles без обновления зависимостей.
OpenAPI: oazapfts 7.5.0 / generator 7.25.0. Полный Temurin JDK 21.0.2+13 (pin mobile/mise.toml);
архив SHA-256 `454bebb2c9fe48d981341461ffb6bf1017c7b7c6e15c6b0c29b959194ba3aaa5`,
проверен по официальному release Adoptium. Android SDK 36 / build-tools 36.0.0,
NDK 28.2.13676358, CMake 3.22.1, cmdline-tools 19.0. Gradle wrapper — проектный 8.14.

```bash
export PATH="/workspace/.gallery-tools/node-v24.21.0-linux-x64/bin:/workspace/.gallery-tools/pnpm/node_modules/.bin:/workspace/.gallery-tools/flutter/bin:/workspace/.gallery-tools/openapi/node_modules/.bin:$PATH"
export PUB_CACHE=/workspace/.cache/pub
export CI=true FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true
export ANALYZER_STATE_LOCATION_OVERRIDE=/workspace/.cache/dart-analysis
export XDG_CONFIG_HOME=/tmp/foto-build17-xdg-config XDG_DATA_HOME=/tmp/foto-build17-xdg-data XDG_CACHE_HOME=/tmp/foto-build17-xdg-cache
export ANDROID_HOME=/workspace/.gallery-tools/android-sdk-build17
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_USER_HOME=/workspace/.gallery-tools/android-user-build17
export GRADLE_USER_HOME=/workspace/.gallery-tools/gradle-build17
export JAVA_HOME=/workspace/.gallery-tools/java-build17/jdk-21.0.2+13
export FOTO_JAVA_TRUSTSTORE=/etc/ssl/certs/java/cacerts
python3 tools/foto-automation/foto-stage-runner.py --repo /workspace/gallery \
  --state /tmp/foto-build17-cloud-state android-apk
```

Runner receipts и приватные логи: `/tmp/foto-build17-cloud-state/stages/`.
Automation log: `/tmp/foto-build17-automation-tests.log`. SDK setup log:
`/tmp/foto-build17-sdk-install.log`; пакеты проверены по официальному Google catalog.
Не повторять прошедшие suites без изменения соответствующего кода. После ошибки сначала
прочитать конкретный приватный лог; новый запуск неуспешного этапа только с явным `--retry-failed`.

## Следующие этапы на момент checkpoint

1. Первый release APK build на `830ec05cb` остановился через 7m16s: системный Java 21 был JRE
   без JAVA_COMPILER. Полный JDK установлен отдельно, system Java/Gradle/AGP не изменялись.
   После JDK следующая попытка дошла до compileReleaseJavaWithJavac: --no-pub в Flutter3.47
   пропускал release-specific plugin generation и оставлял integration_test в registrant.
   Runner теперь сначала проверяет frozen dependencies, затем вызывает штатную release generation.
   Добавлены два regression test на порядок и fail-fast; test plugin не добавлен в runtime.
   Повторить **только неудавшийся APK этап**, используя существующий Gradle cache.
   Проверить actual package/version/alignment, SHA-256 и отсутствие debug
   подписи. В Cloud нет `mobile/android/key.jks` или `key.properties`; production signing не выполнен.
2. По возможности реальный Big-LaMa E2E только на новом изолированном sidecar/PG/Redis.
   Unit contracts не считаются этим E2E. В Cloud есть cached image/model, но реальный E2E пока не запускался.
3. Дополнить отчёт результатом APK, сохранить manifest/checksums и инструкцию подписи существующим
   HP key. Старый `android_sign_package.py` строго Build 11: не подделывать его profile для Build 17.
4. Push следующего checkpoint в эту же ветку, без force-push.

## HP: что неизвестно и что запрещено менять

Содержимое локальных HP `progress.md`, `pending-tasks.md` и обоих manifest не получено.
Они **не** воссоздавались. HP `server/test/mappers.ts` и `.bak` не переносились и не изменялись;
Cloud mapper исправлен независимо по воспроизводимым 83 TS errors.
Перед переносом выполнять fetch/archive в новый приватный staging, не checkout/reset/clean
существующего HP дерева. Инструкция инструментов: [tools/foto-automation/README.md](tools/foto-automation/README.md).
Production, NAS, PostgreSQL, Redis, VPN/DNS/маршрутизация и реальные фотографии не затрагивались.
Deployment, автоматический запуск Codex, изменение HP limits и merge в main не выполнялись.

**Checkpoint status: BLOCKED до реального APK и проверенной подписи существующим проектным ключом.**
