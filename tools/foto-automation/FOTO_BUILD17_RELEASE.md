# Локальный release-конвейер FOTO Build 17

Это инструмент подготовки **локальных** артефактов на HP Ubuntu 24.04. Он не
развёртывает приложение, не запускает собранный backend/worker, не выполняет старые
deletion intents и не меняет production. Существующий образ
`foto-build17:ace2eab96`, объединённая ветка, worktrees, APK и кеши сохраняются.

Исполняемый файл: `foto-build17-release`. Python 3.11+; стандартная библиотека.
Переиспользуются `foto-stage-runner.py` (supervisor/locks),
`foto-mobile-codegen.sh` и `foto-android-build.sh`. Их исходники, существующие
launcher, systemd units, канонические progress/pending/manifest не изменяются.

## Проверенное состояние GitHub, 22.10.2026

| Назначение            | Ref / SHA                                                                              | Состояние                       |
| --------------------- | -------------------------------------------------------------------------------------- | ------------------------------- |
| База HP               | `codex/foto-build17-unified`, `ace2eab962524479a61e6891410983a7f41ba0fa`               | Проверяется заново при запуске  |
| Редактор              | PR #6, `codex/foto-build17-editor-compact`, `ed8cd06773d8cc46dedc935f65c8a08ee60c4eae` | OPEN; новый CI проверять по SHA |
| Backend compatibility | PR #7, `codex/foto-build17-client-compat`, `2c13d3588aa5ed56b8b508080f46adb4ac35a1c5`  | OPEN; новый CI проверять по SHA |
| Код инструмента       | `codex/foto-build17-release`, `10a9d2d58a925f5a29806a17f145a2308beb902b`               | 49 + 1 адресная проверка PASS   |

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

## Установка инструмента (doctoriceadm, без изменения исходного checkout)

Блок получает пять файлов через GitHub API из точного опубликованного commit и
проверяет SHA-256 **каждого** файла. Fetch, checkout и worktree add отсутствуют.
Нужен уже настроенный `gh` под codex-gallery; токен в команды не подставляется.
Выполняет **doctoriceadm** в обычной SSH-сессии; установка через sudo здесь —
явное действие оператора, внутри конвейера sudo/runuser/systemd-run нет.
Новый versioned config оставляет `approved=false`, не требует ключа для check
и не заменяет существующие config/checkpoints. Архивы/образы/APK не скачиваются.

```bash
set -euo pipefail
umask 077
TOOLS_SHA=10a9d2d58a925f5a29806a17f145a2308beb902b
STAGE=$(mktemp -d /tmp/foto17-release-install.XXXXXXXX)
INSTALL=/usr/local/lib/foto-build17-release/$TOOLS_SHA
CFG=/mnt/hp-data/codex-home/foto-build17-release-check-10a9d2d58.json
REPORT=$(mktemp /home/doctoriceadm/foto-build17-check-10a9d2d58.XXXXXXXX.json)
ERRORS=$REPORT.stderr

for f in foto-build17-release foto-stage-runner.py foto-mobile-codegen.sh foto-android-build.sh foto-build17-release.example.json; do
  sudo -u codex-gallery -H gh api \
    "repos/docice545/gallery/contents/tools/foto-automation/$f?ref=$TOOLS_SHA" \
    --jq .content | base64 --decode > "$STAGE/$f"
done
cat > "$STAGE/SHA256SUMS" <<'SHA256SUMS'
713438db5a9acf930a8f68bb7aa3977072bf559c17dc2ac5ba2a30fb232806d7  foto-build17-release
520b1582135cd54ee96508e6a228551b45ef6d207b6db1010d9813c23efb4b40  foto-stage-runner.py
f5183332c0ed397cd929d07b468dc997fd51516b6b27f021c0ce27df91d9bb2e  foto-mobile-codegen.sh
afaecc5b28c2f8d4bb926f1eaedfe9e34926ea3117f0c31523fb5eb4a869aca4  foto-android-build.sh
461b7ab18741ecba0dfe84829f344f991cb3f49c10ec6b34475c0b273fdb710e  foto-build17-release.example.json
SHA256SUMS
(cd "$STAGE" && sha256sum --check SHA256SUMS)
if sudo test -L "$INSTALL"; then
  echo 'STOP INSTALL_DIRECTORY_IS_SYMLINK' >&2
  exit 1
fi
sudo install -d -m0755 "$INSTALL"
for f in foto-build17-release foto-stage-runner.py foto-mobile-codegen.sh foto-android-build.sh foto-build17-release.example.json; do
  if sudo test -e "$INSTALL/$f" || sudo test -L "$INSTALL/$f"; then
    sudo test ! -L "$INSTALL/$f"
    sudo cmp -s "$STAGE/$f" "$INSTALL/$f"
  else
    MODE=0755
    if [ "$f" = foto-build17-release.example.json ]; then MODE=0644; fi
    sudo install -m "$MODE" "$STAGE/$f" "$INSTALL/$f"
  fi
done
if ! sudo test -e "$CFG" && ! sudo test -L "$CFG"; then
  sudo -u codex-gallery install -m0600 "$INSTALL/foto-build17-release.example.json" "$CFG"
fi
if sudo -u codex-gallery -H "$INSTALL/foto-build17-release" --config "$CFG" --check > "$REPORT" 2> "$ERRORS"; then
  printf 'CHECK COMPLETED; inventory only, not release approval: %s\n' "$REPORT"
else
  printf 'CHECK BLOCKED; private report: %s; errors: %s\n' "$REPORT" "$ERRORS" >&2
  exit 1
fi
```

Блок не запускался на HP. Syntax/скачивание точных опубликованных bytes проверяются
в Cloud; это не подтверждение HP toolchain. Не публикуйте private inventory без
просмотра. Ошибка `QUERY_FAILED_GH` требует существующего доступа codex-gallery к
репозиторию; не добавляйте токен в журнал. Ошибка rootless в JSON — основание для
отдельной проверки, не разрешение переключиться на rootful Docker.

`--check` не принимает PR и не проверяет реальную работу приложений. Он показывает
инвентаризацию; даже exit 0 **не разрешает** prepare/test/build. Красные CI PR #6/#7,
неизвестный существующий keystore и native/NAS/AI E2E остаются блокерами.

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
   max-parallelism=1. Нужен buildx с JSON inspect/history. Если формат отличается
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
R=/usr/local/lib/foto-build17-release/10a9d2d58a925f5a29806a17f145a2308beb902b/foto-build17-release
C=/mnt/hp-data/codex-home/foto-build17-release-check-10a9d2d58.json
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
