# FOTO Build 17 — результаты Cloud-проверок

Дата: 21.10.2026. Ветка: `codex/foto-build17-web-handoff`.
Исходный commit: `2315ae789a3824c7a60dc688e541c30648385e03`.
Исходники APK: `244ae32fc6dc1bf1199ea1bbd3c06a1e85e8948d`. Backend/тесты выполнялись на его исходниках и
предшествующих проверенных checkpoints; после изменения SQL повторён только затронутый medium набор.

## Реальные результаты

| Проверка                                                                 | Результат    | Граница подтверждения                                                                                |
| ------------------------------------------------------------------------ | ------------ | ---------------------------------------------------------------------------------------------------- |
| Automation regression                                                    | 37/37 PASS   | Реальные временные flock/process/signals/pidfd; mock systemd                                         |
| Backend asset-media/repository/library/metadata unit                     | 418/418 PASS | 4 specs                                                                                              |
| Backend deletion/recovery/Trash/storage/Magic Eraser unit                | 485/485 PASS | 7 specs                                                                                              |
| PostgreSQL upload/library/duplicate admission/authorized deletion medium | 177/177 PASS | 4 specs, PostgreSQL14 в отдельном контейнере, синтетические файлы                                    |
| Live Photo roots/retry medium, неизменённые                              | 18/18 PASS   | Из ранее прошедших 102: 84 deletion повторены в финальных 177, не считаются дважды                   |
| TypeScript + targeted ESLint + Nest build                                | PASS         | Полная компиляция backend, sync 73 Gallery migrations и 2 aliases                                    |
| OpenAPI + TypeScript/Dart generators + SDK build                         | PASS         | Одно semantic schema addition: optional nullable duplicateId                                         |
| Flutter existing backup/sync/trash/delete/autoplay                       | 177 PASS     | 6 specs, без физического устройства                                                                  |
| Dart wire-contract                                                       | 3/3 PASS     | Отсутствующий, null и отдельный duplicateId                                                          |
| Local Trash/hash retry                                                   | 7/7 PASS     | Отдельный medium spec                                                                                |
| Flutter analyze                                                          | PASS         | Всё приложение, No issues found                                                                      |
| Android release build                                                    | PASS         | Release build, package/version/ZIP/alignment проверены                                               |
| Big-LaMa real model HTTP E2E                                             | 11/11 PASS   | Реальная CPU-модель + HTTP + новые PostgreSQL14/Redis + synthetic files; все test containers удалены |
| Реальный Synology/NFS, HP cgroup OOM                                     | NOT TESTED   | Не было доступа/разрешения на production                                                             |
| Samsung S23/iOS физические устройства                                    | NOT TESTED   | Cloud не имеет этих устройств                                                                        |
| GitHub asset upload / download                                           | BLOCKED      | upload HTTP401 Bad credentials; draft создан без assets                                              |
| Подпись существующим HP-ключом                                           | NOT TESTED   | Ключ не получался, не создавался и не изменялся                                                      |

Количество уникальных пройденных cases: backend unit **903**, PostgreSQL medium **195**,
Flutter **187**, automation **37**. Числа не означают выполнение всего upstream test suite.

## Найденные и исправленные ошибки

- Mapper не включал `duplicateId`: 83 TypeScript errors устранены независимым Cloud patch;
  неопубликованный HP mapper не импортировался и не заменялся.
- External-only активный asset ложно считался completed managed backup. Телефон теперь получает
  возможность загрузить managed copy. Реальные PG cases подтверждают сохранение external original,
  избранного, принадлежности библиотеке и owner isolation. Подтверждённая byte-identity group сохраняется.
- Явный external Trash должен запрещать автоматический reupload. Новый тест сначала воспроизвёл
  FAIL, затем PASS. `Active + isOffline + deletedAt` остаётся offline index tombstone, не Trash.
- Первые medium 7 failures: старые assertions не учитывали optional `duplicateId`; race test
  ошибочно требовал единственный row вместо сохранения external+managed. Assertions исправлены
  по контракту сохранности обеих копий и усилены проверкой группы одинакового содержимого.
- Первые Flutter 3 failures были только в новых assertions (`Optional<String?>`); wire-roundtrip
  исправлен, все 3 повторно PASS. Другие 177 успешно завершённые cases повторно не запускались.
- Первый APK build остановился из-за JRE без JAVA_COMPILER, не OOM. Использован отдельный полный
  Temurin21.0.2+13, подтверждённый официальной SHA-256. Пины AGP/Kotlin/Gradle не менялись.
- Второй APK build выявил stale plugin registrant: Flutter3.47 с --no-pub пропускал release
  generation, оставляя dev-only integration_test в Java-коде. Runner теперь проверяет frozen
  lockfile, затем использует штатную release generation. Две новые регрессии подтверждают
  порядок и отказ до build при ошибке frozen dependencies. Test plugin не перенесён в runtime.
- Без ключа release больше не получает debug signature: Cloud output остаётся unsigned.

## Автоматизация и OOM

Оба launcher используют общую Codex session lock и legacy lock; prompt обновляется после lock.
PID-bound entry блокирует вложенный continuation. Тяжёлые stages имеют один неблокирующий flock.
Vitest workers/concurrency=1, Flutter concurrency=1, Gradle workers=1/parallel=false/daemon=false,
Kotlin in-process, Node3072MiB, Java2GiB, CPU affinity2. Системные HP лимиты8G/1G/200% сохранены.
Supervisor завершает группу и отделившихся descendants через Linux subreaper/pidfd. В systemd
KillMode=control-group/OOMPolicy=stop/Restart=no. Retry после FAIL/RUNNING только явный.

Manifest обновляется транзакционно с before/after hashes и fsync/rename, существующая history
сохраняется. Успешные receipts связаны с исходниками, инструментами, логами и output SHA-256.
Повреждённый/неполный checkpoint блокирует reuse. Ни один HP manifest не копировался в Cloud.

**Реальное исчерпание памяти на HP не воспроизводилось.** SIGKILL test моделирует только exit
дочернего процесса. Команды вне managed runner не получают его lock автоматически. Реальный
Codex/HP launcher в ходе разработки не запускался.

## RAW fixture

`glarus.nef`: размер9,057,784 bytes, Git blob `34f5c57b5d1f5f2e7eab78268e345116c42f6433`,
upstream tree `ec56cc6c1d76c45bc9615dc6ea232470a2b0a3a1`,
SHA-256 `42446c7fc0b15f38cceb7f94cab469445ec65990ad2bc206297fbb28807e1f14`.
Скопирован из прежнего Cloud fixture только после проверки по официальному upstream tree.
Все3RAW cases действительно PASS; бинарный fixture не добавлен в Git.

## Артефакт / оставшиеся gates

APK: `Foto-5.7.3-build17-unsigned.apk`, `188090091` bytes.
SHA-256: `49e2ee65a8dd881085edf2934b72cf19985f28ee9918de37ce99eb1cd70efd08`. Package`de.opennoodle.gallery`, version`5.7.3+17`.
Проверка подписи: **UNSIGNED (apksigner exit=1, no signing certificate)**. Проверка ZIP/alignment: **PASS**.

GitHub draft-release (требуется вход владельца): https://github.com/docice545/gallery/releases. Assets в draft отсутствуют: upload endpoint получил HTTP401, download не подтверждён.
Локальный полный комплект: `/workspace/foto-build17-release-244ae32fc6dc`.
Повторная сборка для исправления upload не нужна. Signed APK SHA появится только после фактической подписи на HP.
Инструкция: `docs/FOTO_BUILD17_HP_HANDOFF.md`. Ни установки приложения, ни backend deployment
здесь не было. Android/iOS permissions, background OS behavior и настоящий NFS проверяются
оператором на специально созданных тестовых объектах, отдельно от семейного архива.

Production DB/Redis/NAS, originals, recovery-proof, deletion policies, VPN/DNS/routing/nginx
не менялись. Автоматическое retention и старые deletion intents не активировались.

**Итог: BLOCKED для полностью подписанного/проверенного на HP продукта до прохождения gates.**

## Коммиты реализации

- `2711a54ff52214f43b4ce9ffa63d12a8e1e996a3` — fix(foto): serialize guarded checks and preserve crash checkpoints
- `cc378e4c3559b7efe10d5523796372f03a51c510` — fix(foto): require managed copies before acknowledging mobile backups
- `830ec05cb9e871a99b713fb5b3502d07f402c1b7` — build(foto): prepare Build 17 clients and guarded unsigned Android
- `b348929efaba55ad122eb9c8edcaecba7961693e` — fix(foto): preserve Trash upload barriers and exclusive Codex sessions
- `244ae32fc6dc1bf1199ea1bbd3c06a1e85e8948d` — fix(android): regenerate release plugins after frozen dependency check

## Изменённые файлы относительно исходного HEAD

- `FOTO_BUILD17_HANDOFF.md`
- `docs/FOTO_BUILD17_HP_HANDOFF.md`
- `docs/FOTO_BUILD17_TEST_REPORT.md`
- `mobile/android/.gitignore`
- `mobile/android/app/build.gradle`
- `mobile/lib/infrastructure/repositories/trashed_local_asset.repository.dart`
- `mobile/pubspec.yaml`
- `mobile/test/repositories/asset_media_response_contract_test.dart`
- `open-api/immich-openapi-specs.json`
- `packages/sdk/src/fetch-client.ts`
- `server/src/repositories/asset.repository.ts`
- `server/test/mappers.ts`
- `server/test/medium/specs/services/asset-media.service.spec.ts`
- `server/test/medium/specs/services/foto-duplicate-admission.spec.ts`
- `server/test/medium/specs/services/library.service.spec.ts`
- `tools/foto-automation/.gitignore`
- `tools/foto-automation/README.md`
- `tools/foto-automation/codex-foto-continue`
- `tools/foto-automation/codex-gallery-safe`
- `tools/foto-automation/foto-android-build.sh`
- `tools/foto-automation/foto-integration-continue-v2`
- `tools/foto-automation/foto-manifest.py`
- `tools/foto-automation/foto-mobile-codegen.sh`
- `tools/foto-automation/foto-prompt-entry.sh`
- `tools/foto-automation/foto-stage-runner.py`
- `tools/foto-automation/tests/test_manifest.py`
- `tools/foto-automation/tests/test_stage_runner.py`
