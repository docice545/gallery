# Локальный release-конвейер FOTO Build 17

Это инструмент подготовки **локальных** артефактов на HP Ubuntu 24.04. Он не
развёртывает приложение, не запускает собранный backend/worker, не выполняет старые
deletion intents и не меняет production. Существующий образ
`foto-build17:ace2eab96`, объединённая ветка, worktrees, APK и кеши сохраняются.

Исполняемый файл: `foto-build17-release`. Python 3.11+; стандартная библиотека.
Переиспользуются `foto-stage-runner.py` (supervisor/locks),
`foto-mobile-codegen.sh` и `foto-android-build.sh`. Их исходники, существующие
launcher, systemd units, канонические progress/pending/manifest не изменяются.

## Проверенное состояние GitHub, 23.10.2026

| Назначение            | Ref / SHA                                                                              | Состояние                       |
| --------------------- | -------------------------------------------------------------------------------------- | ------------------------------- |
| База HP               | `codex/foto-build17-unified`, `ace2eab962524479a61e6891410983a7f41ba0fa`               | Проверяется заново при запуске  |
| Редактор              | PR #6, `codex/foto-build17-editor-compact`, `df3e0daf14f7593808a039df080c32cd05a7a503` | OPEN; новый CI проверять по SHA |
| Backend compatibility | PR #7, `codex/foto-build17-client-compat`, `3cc9631b7a2a48d2889808da5db7a62cc1345fea`  | OPEN; новый CI проверять по SHA |
| Код инструмента       | `codex/foto-build17-release-reviewed-overlap`, `c035601cf131ac4e3dfcf304581314e66d2180c0`               | 14 targeted config-proof + 11 related regressions PASS; новый CI — отдельно |

Пример config намеренно содержит `approved=false` и не содержит реальных путей
к ключу/свойствам или выдуманного certificate fingerprint. **До завершения нового CI и ручной приёмки точных SHA интеграция заблокирована.** Инструмент не исправляет их красный
CI и не предлагает обход. Таблица — snapshot, не замена новым запросам GitHub.

Обязательные CI jobs заданы отдельно для editor и compatibility: редактору нужны
mobile checks, совместимости — также server/medium/OpenAPI/schema/migration checks.
Минимальный набор нельзя убрать через config. Имена обязательных checks должны
быть однозначны: даже две успешные записи одного имени требуют review, а не выбора
по порядку API. Обязательны также строгие OpenAPI/mobile patch, web и E2E gates. Необязательный skipped job не
считается тестом; любой красный, отменённый, незавершённый или неизвестный job
блокирует допуск обоих PR. Проверка собственного rootless endpoint повторяется
непосредственно перед запросами builder/image, включая повторный запуск.

## Установка и продолжение остановленного релиза

Используйте [один проверяемый блок установки и запуска на HP](FOTO_BUILD17_FINAL_HP.md).
Он проверяет подтверждённый PREPARED checkpoint, Buildx v0.35 inspect/history status
и доказанную эквивалентность единственного изменения certificate pin,
устанавливает новые versioned bytes и сохраняет **тот же существующий config**,
все worktrees и историю manifest и явно запускает `--finalize` в отдельном tmux.
Новый config с угаданным ключом/approvals не создаётся. Причина старого
`PARTIALLY_APPLIED_PR_REVIEW_REQUIRED` и узкая reviewed-проверка описаны в
[отчёте](FOTO_BUILD17_RELEASE_OVERLAP.md).

Старый install pin0bd44fb68 не содержит этого исправления. Он сохраняется на HP,
но не используется для повторной попытки подготовки этой пары PR.

## Что подтвердить на HP перед первым prepare

1. Фактические HEAD/branch/dirty/untracked всех worktrees из `--check`. Данные
   другого worktree не считаются интегрированными. Только указанный исходный
   checkout обязан быть чистым; остальные сохраняются и отображаются в inventory.
2. Доступ `gh` к `docice545/gallery` под **codex-gallery**. Review двух точных
   PR SHA и их зелёный CI. В config поставить `approved=true`, заполнить
   `approval_note` для каждого проверенного SHA. Это операторская приёмка, не
   выдуманная GitHub review и не обход branch protection.
3. Реальные пути существующих **непустых, owned codex-gallery, 0600** keystore и
   `key.properties`. Публичный SHA-256 сертификата взять из ранее доверенного
   установленного/подписанного APK (`apksigner verify --print-certs EXISTING.apk`),
   а не из нового результата. Секретные значения в config не переносятся.
4. PATH/JAVA_HOME/ANDROID_HOME существующей toolchain под этим пользователем.
   Pins берутся из repo: Node 24.21.0, pnpm 11.24.0, Flutter 3.47.2, JDK 21.0.2;
   нужны также mise, Extism/Binaryen из mise.lock, Android SDK/build-tools,
   полный JDK с javac. Автоматической установки системных инструментов нет.
5. Rootless socket `/run/user/<uid>/docker.sock`, builder `foto17-limited`,
   его фактические memory=10 GiB / memory-swap=12 GiB и активные workers с
   max-parallelism=1. Нужен buildx с текстовым inspect и JSONL history (`status` нижнего регистра). Если формат отличается
   или история недоступна, конвейер остановится; новый builder не создаётся.
6. Свободное место (пример требует 60 GiB на SSD), память, отсутствие активных
   Codex/build процессов и существующие каталоги shared locks:
   `foto-integration-state`, `gallery-build15-auto`. Ничего не chmod/chown
   рекурсивно. Старые lock-файлы не удалять для обхода BUSY.

Config не содержит произвольных shell-команд. Пути записи ограничены codex-work
и отдельным публичным APK spool. Release state не может перекрываться с source,
экспортом или каноническим automation state. После первого intent config считается
неизменным: для нового PR SHA/настроек нужен **новый** release state; старый сохраняется.

## Справка о режимах после отдельной приёмки (не запускать сейчас)

Все рабочие режимы исполняет codex-gallery. Не запускать через Codex launcher.
Установите уже существующую toolchain в PATH этой сессии, не меняя системные лимиты.

```bash
sudo -u codex-gallery -H tmux new-session -s foto17-release
```

Внутри tmux:

```bash
R=/usr/local/lib/foto-build17-release/c035601cf131ac4e3dfcf304581314e66d2180c0/foto-build17-release
C=/mnt/hp-data/codex-home/foto-build17-release-check-0bd44fb68.json
"$R" --config "$C" --check
```

Затем **отдельно выбирайте** нужный этап; ни один режим не запускает все остальные:

```bash
"$R" --config "$C" --prepare
```

```bash
"$R" --config "$C" --test
```

```bash
"$R" --config "$C" --build
```

```bash
"$R" --config "$C" --verify
```

Отсоединиться: Ctrl-B, D. После нового SSH:
`sudo -u codex-gallery -H tmux attach-session -t foto17-release`.
Не создавайте второй tmux-конвейер при работающем первом.

| Режим   | Действия                                                                                                                                                                                                                                             |
| ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| check   | Read-only Git/worktrees/tracking/remotes/remote heads/PR/CI, свои процессы, tool paths, память/cgroup/disk, rootless contexts/images/cache/builder limits/history, наличие signing files. Без fetch/mkdir/log/state writes и Flutter initialization. |
| prepare | Проверка origin/base/pins/approval/CI, fetch только PR refs в отдельный namespace; локальный branch/worktree в release state; editor → compatibility. Проверка ancestry/patch equivalence до merge. Ни публикации merge, ни изменений unified.       |
| test    | Frozen dependencies, отдельные последовательные SDK/plugin builds, backend/API/Dart/Freezed/i18n codegen; types/lint; по одному unit/medium/Flutter файлу. Любое изменение tracked source останавливает этап и сохраняется для review.               |
| build   | Перепроверка receipts/checksums и CI; existing-key preflight; idle existing builder; image `foto-build17:<full integration SHA>`; затем release APK. Без push или запуска приложения.                                                                |
| verify  | Source/CI/receipts/logs/output SHA, image ID/label/source env/platform, APK zip/apksigner/aapt/package/version/cert. Экспорт только проверенного APK и публичной JSON-квитанции.                                                                     |
| resume  | Только последний выбранный режим, без перехода test → build → deployment. Неоконченный/failed этап требует явной диагностики и retry; успешные этапы переиспользуются по SHA.                                                                        |

Список обязательных файлов тестов зафиксирован в `recipes_for()`. Отсутствие
compatibility tests — ошибка, не SKIP. Medium использует штатные disposable
rootless testcontainers с синтетическими данными. Production dump, production-like
restored DB, реальные NAS mounts и production credentials не подключаются.
DB/Redis/Immich env не передаются тестам. Выполнение миграций возможно только в
этой одноразовой тестовой БД, не на рабочих данных.

## Ресурсы, checkpoints и ошибки

### Единственное форматное изменение certificate pin

При `CONFIG_CHANGED_USE_NEW_STATE` стандартная проверка hash не ослаблена.
Для подтверждённого HP checkpoint `e5883358c48a76a82fe7db29b5cd5ac0b1fc76e2`
доступен явный аргумент:
`--certificate-pin-format-proof "$C.before-pin-normalization"`.
Он допустим только с существующим prepared checkpoint без merge-in-flight.
Backup читается как принадлежащий текущему uid regular 0600 файл без symlink.
Его полный canonical JSON hash обязан равняться исходному manifest.configSHA256.
После единственной замены `signing.certificate_sha256` весь JSON обязан совпасть
с текущим config, включая типы. Старый pin — ровно 32 hex-байта через двоеточия,
новый — 64 lowercase hex, сертификат тот же. Другие изменения запрещены.

Ничего в config, backup или идентичности manifest не переписывается. Прежний
config hash остаётся anchor для всех новых этапов; proof перечитывается при каждом
сравнении входов. SHA runner/toolchain/logs/outputs и `apksigner verify` сохраняются.
Смена runtime при уже выполненных stages по-прежнему требует проверки новых входов;
у подтверждённого HP checkpoint stages пустые. После первого продолжения тот же
флаг обязателен для `--resume`/`--verify`. Примеры режимов выше относятся к обычному
неизменённому config; для этого HP используйте полный блок `FOTO_BUILD17_FINAL_HP.md`,
который дополнительно проверяет владельца backup и оба поля отчёта `--check`:
`checkpointConfigValidation=PASS_CERTIFICATE_PIN_FORMAT_EQUIVALENT` и
`builderValidation=PASS_READ_ONLY_LIMITS_AND_IDLE`.

- Общие nonblocking locks release/session/heavy-stage/continue/legacy исключают
  конкуренцию с установленными FOTO launcher. Новые сессии Codex не запускаются.
- Vitest workers/file-parallelism/concurrency=1; Flutter concurrency=1; Gradle
  workers=1, parallel=false, daemon=false, Kotlin in-process; Node heap 4 GiB,
  Java heap 2 GiB; pnpm child/workspace concurrency=1; CPU affinity двух разрешённых CPU через существующий supervisor.
  Это настройки дочерних процессов, не изменение systemd/лимитов HP.
- Дополнительный memory preflight: 5 GiB MemAvailable, 12 GiB перед image build;
  caller cgroup не меньше 6 GiB, если лимит доступен. BuildKit проверяется отдельно.
- Сигналы завершают управляемое дерево. SIGKILL/OOM оставляет RUNNING intent;
  он не считается успехом. У daemon-side BuildKit дополнительно проверяется idle
  history: смерть CLI сама по себе не доказывает остановку build.
- Advisory locks не останавливают произвольные команды другого пользователя.
  Перед каждым новым тяжёлым этапом проверяются свои активные build/Codex процессы.
  Не запускайте некооперирующие сборки вручную во время конвейера.
- Собственный `manifest.json`, immutable snapshots и журналы 0600 находятся
  только в release state. Сохраняются точные Git/PR SHA, toolchain/config/runner
  fingerprints, command recipe, exit code, log/output SHA, image ID, APK/cert SHA.
  Файл DONE не используется. Канонические HP manifest/progress не записываются.

| STOP                                                                              | Действие                                                                                                                                                             |
| --------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| CI_REQUIRED_CHECK_AMBIGUOUS / CI_RED_PENDING_OR_UNKNOWN / REQUIRED_CI_NOT_SUCCESS | Исправить или завершить конкретный GitHub job/PR; не менять gate.                                                                                                    |
| HP_DIRTY_OR_UNTRACKED_PRESERVED                                                   | Сохранить и отдельно проверить локальную работу. Не применять reset/clean/stash.                                                                                     |
| PR_HEAD_CHANGED / REMOTE_BASE_DIFFERS                                             | Повторно принять точные новые SHA, создать отдельный config/state.                                                                                                   |
| MERGE_FAILED / MERGE_INTERRUPTED                                                  | Сохранён конфликтный worktree и список conflicts в manifest. Не выполнять автоматический abort/resolve; исправление PR и новая проверенная интеграция отдельно.      |
| STAGE_FAILED_*_EXIT_137 / DeadlineExceeded в логе                                 | Не перезапускать циклически. Проверить private log, memory/cgroup и builder status/history через check; определить причину. Лимиты/кеш/builder инструмент не меняет. |
| BUILDKIT_ACTIVE / BUILDER_UNHEALTHY / HISTORY_UNAVAILABLE                         | Проверить существующий builder; никаких автоматических restart/bootstrap/create/prune.                                                                               |
| UNSEALED_IMAGE_TAG_EXISTS                                                         | Образ без завершённого receipt не перезаписывается и автоматически не объявляется успешной сборкой. Сохранить его для отдельной проверки.                            |
| STAGE___CHANGED / CORRUPT__                                                       | Сохранить повреждённое состояние. Не править PASS вручную; новая проверенная интеграция/state.                                                                       |
| SIGNING / APK_CERTIFICATE / PACKAGE_OR_VERSION                                    | Проверить существующие ключ/свойства/public pin/toolchain; новый ключ/debug-signature не принимаются.                                                                |

После **фактической** диагностики разрешена одна попытка выбранного режима:

```bash
"$R" --config "$C" --resume --retry-failed --diagnosis 'Краткая проверенная причина, без секретов'
```

Этот флаг не обходит CI, source SHA, builder idle, ключ, checksums или конфликт.
Нельзя утверждать, что реальный HP OOM устранён по mock-тесту exit 137.

## Артефакты и перенос APK

Backend остаётся в rootless image store, его полный тег и image ID записываются
в manifest/публичную receipt. Успешный build не считается backend health test.
Никакого docker compose up, image push, queue replay или установки APK нет.

APK первоначально находится в integration worktree:
`mobile/build/app/outputs/flutter-apk/app-release.apk`.
После verify он экспортируется в `/var/tmp/foto-build17-release-artifacts/` под
версированным именем `FOTO-5.7.3-build17-<integration SHA12>-<APK SHA12>.apk`.
Рядом — JSON с полным SHA, размером, package/version/certificate и image ID.
Spool 0755 содержит только APK/публичную receipt 0644, не логи/ключи. Проверяется
владелец, отсутствие записи для group/other, zip, подпись и content hash.

Verify печатает **готовую точную команду** `--receive-apk RECEIPT`, которую
исполняет doctoriceadm установленной versioned копией инструмента. Она атомарно,
без перезаписи другого файла, копирует APK в `/home/doctoriceadm/` с владельцем
doctoriceadm и mode 0644. Внутри неё нет sudo. Межпользовательская передача остаётся
явным действием, поскольку codex-gallery не вправе chown файл другому пользователю.

## Приёмка и откат

После локальных проверок обязательна отдельная приёмка установленного приложения:
backup/retry/offline sync, настоящий дубль и edited copy, альбомы/избранное/Memories,
Trash/Restore/Permanent на синтетическом медиа; компактный редактор на Android и
iOS (portrait/landscape/keyboard/safe-area), Live Photos/HEIC и iOS PhotoKit/iCloud/
background. Реальный Synology и AI E2E требуют отдельного безопасного окружения.
Проверка wire contracts не заменяет эти сценарии.

Для отмены подготовки достаточно не использовать новые candidate branch/image/APK.
Старый checkout/образ/артефакты остаются на месте. Ничего удалять, откатывать БД
или переключать production не требуется. Production deployment и совместимый
rollback проектируются и разрешаются отдельно; этот инструмент их не выполняет.

Матрица реально выполненных тестов: [FOTO_BUILD17_RELEASE_TESTS.md](FOTO_BUILD17_RELEASE_TESTS.md).

## Приёмка исправлений CI

[Разбор причин и исправлений](../../specs/testing/2026-10-22-foto17-ci-blocker-closeout.md).
Source-review workflow не запускают self-hosted signing, APK/IPA publishing или
registry retag. Это ограничения мутаций, не отключение тестов: обычные API/Web E2E
для compatibility/release остаются включены и обязательны. Native/mobile unit,
Dart/static, SQL/OpenAPI и release fixtures проверяются отдельно; skipped build
не считается собранным APK или backend runtime. Старая acceptance-история не
переносилась повторно. Final CI evidence публикуется в PR #6/#7/#8 на точных SHA.

## Явное завершение всей цепочки

После установки и проверки прежнего config в tmux можно явно выбрать
`"$R" --config "$C" --finalize`. Этот режим требует существующего ключа и
последовательно делает prepare/test/build/verify под прежними common locks.
Он не делает deployment и не запускает Codex. `--resume` сохраняет прежнюю
семантику одного последнего этапа; для продолжения полной цепочки нужен явный
`--finalize`. Никакой автоматический retry после ошибок не добавлен.
