# FOTO Build 17 — допуск PR #6 / #7 / #8 к локальной интеграции

Дата: 22.10.2026. **BLOCKED для интеграции/production**. Работа выполнена в Cloud,
без доступа к HP, NAS, рабочим БД/Redis или signing key. Ни один PR не объединён
в unified. Production READY не заявляется.

## Обязательное предварительное условие — VERIFIED

До любых изменений проверены живые GitHub refs:

- `codex/foto-build17-pr7-acceptance` = `2364b82e9246a08174ad6d5278bc7227388e8e31`.
- PR #7 / `codex/foto-build17-client-compat` первоначально имел **тот же HEAD**.
- Все 16 acceptance-коммитов после CLI HEAD
  `8759f9bd9c8f94adfdf8df81dc67b158aaddbf90` присутствуют в истории PR #7,
  включая OpenAPI, MemoryV2 conversion, durable SQLite journal и crash/retry tests.
- GitHub compare: identical; `mergeable=true`, open, не merged. Локальный
  `git merge-base --is-ancestor` подтверждает ancestry. Сам перенос в этом задании
  **не выполнялся**.

[Исходная квитанция GitHub](foto17-release-20261022/acceptance-transfer.json).
Поверх принятого HEAD в PR #7 обычным push опубликован только
`c79c843b9b5efdc3620c1e026ec06edcfe4d8294`: Prettier двух server-файлов и три
`async` mock без await → `Promise.resolve` в web unit tests. Assertions, API,
права удаления, recovery-proof, миграции и runtime не изменены. Accepted HEAD
остаётся его предком, история не переписана.

## Точные источники и CI

| PR                                                | Ветка / проверенный HEAD                                                                                      | Проверка                                                                                                                                                                                                                             | Допуск                   |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------ |
| [#6](https://github.com/docice545/gallery/pull/6) | `codex/foto-build17-editor-compact` / `5e84b5132427624d926abe28fad788d89ed2431c`                              | 19 success; 6 failures общего Test; редактор в этом задании не изменялся                                                                                                                                                             | BLOCKED                  |
| [#7](https://github.com/docice545/gallery/pull/7) | `codex/foto-build17-client-compat` / `c79c843b9b5efdc3620c1e026ec06edcfe4d8294`                               | [новый Test](https://github.com/docice545/gallery/actions/runs/39846822015): SQL/OpenAPI/strict enum gate и Lint Web PASS; server lint FAIL, ShellCheck и upstream tooling FAIL; остальные проверки на момент записи ещё выполняются | BLOCKED                  |
| [#8](https://github.com/docice545/gallery/pull/8) | `codex/foto-build17-release`; проверяемый код `ba22b5936dcee2bf79c62fabc14a5a073034c1d3`, затем только отчёты | 49+1 orchestration checks PASS в Cloud; новый GitHub CI после публикации проверяется отдельно                                                                                                                                        | BLOCKED до CI/HP-приёмки |

Это snapshot, не обещание будущего CI. Конечные HEAD/check URLs публикуются в PR.
Отменённые workflow публикации Docker и signing APK **не** являются PASS и не
исключаются из строгого gate. Они остановлены, чтобы эта приёмка не изменяла
Docker-артефакты/APK. Обычные test workflows не отменялись и не ослаблялись.

### Сохранённые результаты acceptance HEAD 2364b82e9

[Test 39841802465](https://github.com/docice545/gallery/actions/runs/39841802465):
SQL, OpenAPI Clients, strict OpenAPI, migrations, Dart PASS; Medium **3447 PASS /
17 skipped**, Mobile **5017 PASS / 1 skipped**, Web unit **6468 PASS / 2 skipped /
4 todo**. Это фактический полный CI именно указанного HEAD. Он не выдаётся за
результат нового c79 или объединённого дерева.

Подробные wire-контракты, PostgreSQL и SQLite crash tests сохранены в
[acceptance compatibility report](https://github.com/docice545/gallery/blob/2364b82e9246a08174ad6d5278bc7227388e8e31/specs/testing/2026-10-22-stock-client-compatibility.md).
Новые лёгкие проверки release-инструмента:
[матрица](../../tools/foto-automation/FOTO_BUILD17_RELEASE_TESTS.md),
[49-case log](foto17-release-20261022/orchestration-49.txt),
[1-case gate log](foto17-release-20261022/mandatory-gates-1.txt).

### Подтверждённые красные проверки, без обхода

1. PR #6: SQL/OpenAPI generated drift; web lint три require-await (исправлены в
   PR #7, не дублируются в editor); Test Web: семь assertion/timeout failures в
   `global-search*` / `PersonSuggestionReviewModal`, не ошибка editor layout.
2. PR #7 c79: после успешного format выявлено 11 ESLint ошибок в queue controller/
   service, recovery-evidence и authorized-deletion spec. Runtime-файлы и medium
   spec идентичны unified по Git blob; recovery spec отличается форматированием.
   Это реальные lint blockers, не падение среды. Не отключать правила и не
   ослаблять recovery validation. SQL/Medium PASS не доказывают server unit PASS.
3. Общие ShellCheck errors в legacy diagnostics/release scripts: SC2016,
   SC2155, SC2174, SC2154. Upstream preflight 291 PASS / 1 FAIL / 1 skipped:
   первый `flutter build` Android media pilot расположен до первого branding
   marker в workflow. Эти файлы идентичны unified. Это ошибки baseline gate,
   не причина отменить/проигнорировать CI и не дефект компактного editor.
4. На acceptance2364 API E2E: 1383 PASS / 6 FAIL / 4 skipped, включая два
   Live Photo permanent-delete 409 вместо204, quota/features fixtures и два
   offline-trash expectations. Нельзя заменять ожидаемые коды или создавать
   фиктивный recovery-proof: требуется отдельно согласовать guarded owner
   policy и реальные API fixtures, сохраняя защиту originals.
5. Web E2E acceptance2364: 400 PASS / 1 FAIL / 2 flaky / 7 skipped; reopen-stale-
   detail теряет `reopen-tag`, наблюдаются EXIF keywords. Гипотеза metadata race
   не является доказанной первопричиной; runtime fix не выдумывается.
6. PR #8 до этого обновления: SQL/OpenAPI generated drift, ShellCheck, label gate
   и отменённые publishing workflows. Новый CI обязан оцениваться на новом HEAD.
   Текущий один changelog label не доказывает успешность исторического label job.

Проблемы загрузки прямых логов (403 от хранилища Actions) отделены от ошибок
тестов: для PR #6 получен полный ZIP workflow logs; приведённые failures взяты
из настоящих job logs. Отсутствие лога не считалось PASS.

## Совместный результат — границы доказательства

Cloud `git merge-tree --write-tree --merge-base=<unified>`:

- PR #6 + PR #7 c79: tree `6b640c71bd94334a8e01782c39fe09c24f132659`, **0 conflicts**.
- С release code ba22: tree `b6f960359503068ecad6d8ed88ebe0c8c4077a91`, **0 conflicts**.
- Все **35** файлов recipe tests существуют в этом дереве, включая
  `memory_v2_journal_test.dart` и editor compact layout.

[Точные paths/SHA](foto17-release-20261022/combined-source-trees.json).
Не создавалась объединённая ветка unified, интеграционный runtime не запускался.
Изменения editor и client sync не перекрываются; объединяется только test workflow.
Git tree proof — не Android/iOS/Web или API-to-filesystem E2E.

### Матрицы по клиентам

Пины из acceptance: Immich 3.3.5
`8303cb117e197c700332b33b61b45314c9cc5bb4`; Noodle 5.8.0
`37aa54e632606cc6a62bc6bcbba14c62200147c4`; FOTO unified ace2eab.
Обозначения: **VERIFIED (contract)** — конкретные source/unit/PG/SQLite checks,
не установка оригинального клиента; **NOT VERIFIED** — runtime не выполнялся.

| Клиент                | VERIFIED в заданных границах                                                                                                                                                                     | BLOCKED / NOT VERIFIED                                                                                                                                                                                         |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Immich Android 3.3.5  | Acceptance server sync V2/V3, nullable OAuth, negotiated types, immutable legacy ACK, owner favorites, Memories/trim, offline index ≠ Trash; прежние auth/upload/album API definitions сохранены | Реальный stock APK, background backup, MediaStore/permissions, offline/retry, Live Photos/HEIC; полная API E2E красная                                                                                         |
| Immich iOS 3.3.5      | Общие server wire/PG checks выше                                                                                                                                                                 | Отдельный запуск iOS; PhotoKit limited/full permission, iCloud-only originals, HEIC/HEIF/video/Live Photos, background URLSession/BGTaskScheduler, low-power/restart/network; Android не заменяет эту проверку |
| Noodle Android 5.8.0  | Contract sync negotiation/favorites/shared-space routes/Memories/trim                                                                                                                            | Настоящий original APK → upload/restore/guarded NAS deletion; AI/OS cleanup не проверены                                                                                                                       |
| Noodle iOS 5.8.0      | Те же version-pinned server contracts, fork-aware Memories                                                                                                                                       | IPA/native PhotoKit/iCloud/HEIC/Live Photos/background/retry не проверены                                                                                                                                      |
| Noodle Web 5.8.0      | PG personal favorites с реальными stock flags, editable/shared-space face routes и owner isolation                                                                                               | Немодифицированный Web не запущен; web E2E всего fork имеет blocker detail tags                                                                                                                                |
| FOTO Build 17 Android | Durable MemoryV2 journal/crash-retry; ни один неизвестный stream type не ACK без применения; 380 различных финальных editor Flutter cases/real rendered goldens сохранены в PR #6                | Подписанный APK и физический Android, общий backend runtime, настоящий AI/NAS не проверены                                                                                                                     |

Editor proof не повторялся без изменения кода:
[EDITOR_COMPACT_ACCEPTANCE](https://github.com/docice545/gallery/blob/5e84b5132427624d926abe28fad788d89ed2431c/EDITOR_COMPACT_ACCEPTANCE.md),
[evidence-index](https://github.com/docice545/gallery/blob/5e84b5132427624d926abe28fad788d89ed2431c/specs/testing/editor-compact-20261021/evidence-index.json).
Пять режимов без scrolling, большая фотография, сворачиваемые drawing settings,
Android/iOS platform layouts, safe-area/keyboard/landscape подтверждены Flutter,
а не реальным iPhone/Android. AI client error classification проверена тестами,
реальная inference не подтверждена.

## Допуск release-конвейера

| Свойство                                    | Доказательство                                                                                           | Статус                                                                 |
| ------------------------------------------- | -------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| Точные PR SHA/approval/все CI               | Required checks нельзя убрать, duplicate names fail closed; red/pending/cancelled/unknown блокируют      | VERIFIED (fixtures), реальная интеграция BLOCKED                       |
| Отдельный worktree, без изменения HP source | Настоящие temp Git cases: clean/dirty/conflict/repeat/ancestry                                           | VERIFIED (Cloud temp Git); HP NOT VERIFIED                             |
| Последовательность и лимиты                 | Vitest/Flutter workers1, Gradle workers1/no daemon, supervisor/shared locks, no retry loop               | VERIFIED (recipes/fixtures), HP нагрузка NOT VERIFIED                  |
| Rootless existing builder/cache             | Только own socket, foto17-limited limits/history; отказ без create/prune/fallback                        | VERIFIED (mock), реальный HP NOT VERIFIED                              |
| Existing APK key                            | Owned0600 files, trusted certificate pin, APK/package/version/source validation; новый ключ не создаётся | VERIFIED (negative mocks), настоящий key/APK NOT VERIFIED              |
| Checkpoints/resume                          | Hashes source/config/toolchain/log/output; atomic snapshots, RUNNING не PASS, retry только явно          | VERIFIED (temp files/fault injection); реальный OOM не воспроизводился |
| Первый check read-only                      | Startup без pycache + inventory не пишет state/source; pinned files API download                         | VERIFIED (fixtures/syntax); HP command не исполнялась                  |
| NAS originals/shared library/dedup          | Existing owner/PG/filesystem synthetic tests сохранены, нет новых roots/permissions                      | VERIFIED в прошлых synthetic checks; реальный Synology NOT VERIFIED    |
| Production backup/rollback                  | Никаких фиктивных receipt, dump или image compatibility заявлений                                        | NOT VERIFIED, отдельная приёмка                                        |

## Единственный следующий безопасный шаг

[Versioned установка и только `--check`](../../tools/foto-automation/FOTO_BUILD17_RELEASE.md#установка-инструмента-doctoriceadm-без-изменения-исходного-checkout).
Пять файлов закреплены commit ba22 и SHA-256; существующие HP worktrees,
manifest/history/ключи/образы/кеши не меняются. Конфигурация остаётся unapproved.
Никаких `--prepare`, `--test`, `--build`, deployment или replay deletion intents
до устранения gates и отдельной приёмки. Инвентаризацию считать private.
