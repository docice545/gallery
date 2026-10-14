# Gallery Build 11: Android sync / backup и release checkpoint 2026-10-14

## Точная текущая точка продолжения (имеет приоритет над историей ниже)

Cloud branch: `candidate/gallery-5.7.3-build11-upstream`.
Новый application source: `89447178806ccc509ff0b52358b7491842041047`, версия
**5.7.3 (11)**. Immutable build ref: `build/gallery-build11-89447178`.
Старый source `f26b4605` и его успешные APK/IPA/backend artifacts **SUPERSEDED**:
они не содержат новых runtime fixes. Его build ref не менялся. Неопубликованные
HP-исправления неизвестны и **НЕ интегрированы**; доказательства ниже Cloud-only.
Production/`work` не изменяются, merge в HP branch не выполняется.

## Последний release checkpoint — имеет приоритет над предыдущими CI заметками

Tooling HEAD `c96c92a7f14e15408d6e223316f377dbe5014f1e` опубликован.
Current proof **IN_PROGRESS**:
https://github.com/docice545/gallery/actions/runs/38544077473.
Он использует backend38484089051 / Android38486187028 / iOS38484090958 и
rollback38288841511. Все compiled application inputs остаются source89447178.
Три app workflows не повторялись, production и HP changes не трогались.

- `d2d02b346c…`: 32 diagnostic tests PASS; fixed labels без raw stderr/argv.
- `b7eb7ba594…`: speculative empty-index repair. Его PLATFORM_CONTENT guard
  **SUPERSEDED**: пустые unqualified fields не доказывают absence requested child.
- `bf9d3edef6…`: verified component inner checksum notice до installation gates.
- `aa9fd9c0d2…`: generated AMD64 package выбирает тот же verified Valkey child
  67878c70… (configc439a6b7…) из upstream indexc123e371…; sourceCompose неизменен,
  точная single-image substitution и provenance checksum защищены.
- `d21948271d…`: исправляет overstrict root-platform assumption. Root identity,
  Descriptor и RepoDigest проверяются отдельно; обязательный explicit selected
  linux/amd64 manifest/config проверяется всегда. Нет fallback или pull на
  selected-inspection failure, нет повторных speculative pulls.
- `3d8df8366b…`: ранний bounded public dependency probe и 40 diagnostic tests
  PASS. Run38526321706 подтвердил Valkey digest/config/platform/availability
  **PASS**, но завершился FAIL при возврате Docker в classic store; это не
  installation PASS. Failed logs доступны через `gh run view --log-failed`.
- `e4152b7d4a…`: guarded CI-only Docker transition; официальный unit Docker28.4
  ограничивает starts до3/60s. `reset-failed docker.service` перед намеренным
  restart устраняет счётчик только на пустом disposable CI runner, не меняет
  daemon unit или release identity checks. EXIT trap сохраняет первичный отказ.
  Probe допускает только отсутствующий точный immutable Valkey reference,
  удаляет только его после PASS без force/prune и проверяет отсутствие; actual
  installation сохраняет холодный cache и исходный порядок dependency pulls.
  **21 PASS**, включая foreign-container/remote-options/cleanup/restore failures.
  `/tmp/build11-ci-docker-transition-root-tests.log`.
- Run38540870600: guarded transitions/probe cleanup/classic rollback PASS;
  actual installer остановился на Valkey selected platform. Bounded diagnostic
  впервые подтвердил actual metadata-only cache: immutable root/manifest
  identity matches, `Available=false`, expected platform content unavailable.
- `d7da5131eb…`: после реального selected-command failure и verified parent
  выполняется API/CLI gate, один exact digest pull и полная повторная проверка
  parent/target stability и selected platform. Cached success остаётся offline,
  cold initial pull не повторяется. Integrity/JSON/custom gate failures не
  разрешают refill, неуспешный pull или selected lookup остаётся STOP.
  **66 PASS**: 52 installer +7 package +7 platform;
  `/tmp/build11-bounded-selected-content-refill-tests.log`.
- Run38542645355 FAIL: Docker28.4/API1.51 всё ещё сообщает expected Valkey
  `Available=false` в actual installation. Нельзя утверждать, что refill
  уже доказан actual CI; unit tests PASS этого не заменяют. Где именно Docker
  теряет content (shared layers/GC/store switches), по bounded metadata не доказано.
- `c96c92a7f1…`: CI закрепляет Docker CE/CLI29.9.0, подтверждённый signed
  official APT inventory предыдущего run. Immutable dependency digest/config,
  platform и all31 installation gates неизменны. Только disposable CI engine,
  никакого обновления DockerHP или приложения. Signed selector/transition
  suite **21 PASS**; `/tmp/build11-docker29-signed-bootstrap-tests.log`.

Current focused **66 PASS**: 52 installer +7 package +7 Docker platform;
`/tmp/build11-bounded-selected-content-refill-tests.log`. Linked PostgreSQL guard
**45 PASS,4 opt-in Docker SKIP**: `/tmp/build11-valkey-linked-pg-predeploy-tests.log`.
Compile, Bash/YAML/embedded-Python syntax, docs formatting, whitespace и
byte-identical source/official Compose checks PASS.

Actual failed proof chain: 38519250044 confirmed selected **VALKEY_PINNED**
platform lookup unavailable, API1.51. Next38520267120/38521936065 hit the now
removed overstrict PLATFORM_CONTENT guard before config creation; эти failed
runs НЕ доказывают absence actual requested child и НЕ являются install PASS.
Run38523289687 снова завершился на selected Valkey lookup; ранний38526321706
успешно выполнил тот же lookup на fresh containerd. Причина старого отказа
без availability metadata не установлена. Прогретый cache не используется для
скрытия этого отказа. Run38540870600 уже FAIL с verified missing content.
Следующий шаг: дождаться38544077473, читать actual stage/code, все31
installation gates и artifact receipt.
Не повторять component builds, full Flutter/PG suites или source audits.

Verified **inner binary** checksums (Checks receipt38520267120, все source894):

- Backend archive: `4a764b110ba0ffc2603b0219234811c1873c55b981cc59eed1cca30cc0e28d8d`.
- Backend config image ID: `sha256:bd078fdd96f29950d77ee28977e4cd9592d5cd8f5a2ee5afd07fa0c4e5a45044`.
- APK: `5453796e99c11d8bd2110f7b60726f02c8d2c9dac0ffbbbcfdb4b5a136200934`.
- APK CI certificate: `f02566bc4479f9a4668baf829fe909ca06acaa44d723f1360b0e5db7d311e0f3`.
- Unsigned IPA: `69882d5de38ec46e11217a350bb49af5adcfb67aeaead20220c637e60e678652`.

Source receipt cached `/workspace/gallery-build11-cloud-artifacts/component-receipt-89447178.json`.
Это compiled-components proof, **не distribution/install readiness**.
Production HP restore/NFS/six+21/device acceptance и HP signing остаются gates.

Завершённые опубликованные commits:

- `0753a3eb4cbe074a972ac876d8211209f3a6860b`: настоящий старый HTTP Empty Trash
  контракт/controller + PG14 tests; неиспользуемый legacy service409 не был
  поломкой API. Sanitized Docker operation/category/APIversion diagnostics для CI.
- `b3a7262a02f075a4d287001d3306c82d50a1f23b`: paired Live Photo autoplay в
  remote/local albums, локальный filter scope, narrow header Wrap; 116 PASS.
- `be1962a1799d3677425cb38c7498168bbac276d3`: stable checksum backup identity,
  owner/device intent, offline-index protection, completed receipts, OS-only retry,
  late local scan/cached-active receipt handling, cache cleanup, account guards.
- `5be385d3e3e2012a44596ffa9cb50eadd5eac79b`: запрет stale selected localId
  fallback в OS unlink; честное предупреждение, 40 widget tests PASS.
- `661f85d294164a138ac263c455fbccd61a1e1da5`: iOS discovery→remote→hash→upload
  вместо гонки четырёх параллельных этапов; budget/cancellation/drain сохранены.
- `89447178806ccc509ff0b52358b7491842041047`: strict analysis cleanup,
  без изменения поведения/constructor arguments; 42 affected tests PASS.
- Tooling-only: `b2f46d2f83dafcf3f74da0b633e213d08b756823` закрепляет точную
  pinned PostgreSQL index/amd64 identity для containerd; classic guard сохранён.
- Tooling-only: `541f6f3b8e` добавляет штатный `refresh-recovery`: новый backup,
  настоящий isolated restore, неизменные старые receipts и append-only activation.
  Read-only status работает после 24h; apply/rollback сохраняют строгую freshness.
- Tooling-only: `6eb9f52fa3` добавляет обязательный actual CI restore уже
  обновлённой DB с сохранением всех policy fields, ledger и storage grants.
- Tooling-only: `2434b5795fc94374a929fbbef9b3387b5021d3d9` исправляет точную
  причину failed installation: Docker CE/CLI 28.4.0 в disposable CI VM и ранний
  API>=1.49/CLI `--platform` preflight. Identity checks не ослаблены.

Final validation после всех runtime fixes:

- **Полный Flutter: 4786 PASS, 1 SKIP, 0 FAIL** (260s).
  `/tmp/build11-cloud-final-flutter.log`; concurrency4, no-pub, expanded.
- **Полный analyze --fatal-infos: No issues found**.
  `/tmp/build11-cloud-final-analyze-fixed.log`.
- Current web deletion/Trash/Live Photo regressions: **24 PASS**,
  `/tmp/build11-cloud-final-web-focused.log`. Unchanged Chromium8 PASS сохранён.
- Backup/local-sync/background regression85 PASS; real HashService+Drift28 PASS.
  Hashing не зависит от candidates/counts, unknown reused ID не блокирует hash.
- iOS actual worker6 PASS, 60 affected PASS; native bridge mocked, не device PASS.
- Sync service94 PASS; device receipt + pending40 PASS; OS retry UI15 PASS.
- Backend runtime не менялся: full unit6858 PASS+1 expected+12skip,
  PG14 3370 PASS+12skip сохранены; новые controller7/PG HTTP lifecycle17 PASS.
- Build11 Python88 PASS+1 opt-in Docker SKIP. Signed recovery-proof не ослаблен;
  новых миграций эти продолжения не вводят. Existing additive179405 остаётся.
- Актуальный полный Build11 tooling suite: **122 PASS, 1 SKIP, 0 FAIL**.
  `/tmp/build11-final-release-tooling-tests.log`, SHA256
  `6a4d1f817b98409aaa691bfa08657a9d1efb757d66412370955c0e5cfc841c97`.
  Включает 21 recovery-refresh, 13 transition, 31 installation-harness tests.
  Эти unit fixtures не означают actual installation PASS.
- PostgreSQL identity/predeploy: **45 PASS, 4 opt-in Docker SKIP**,
  `/tmp/build11-pg-containerd-preflight-tests.log`, SHA256
  `b9370fade7ca68da79e545981908b93e4b2ce78020fe2b7f7c8a8591ff40f67a`.
  Bash syntax, Python compile, whitespace и docs formatting PASS.
- После Docker correction: полный Build11 tooling **129 PASS, 1 SKIP**,
  `/tmp/build11-final-docker-corrected-tooling.log`; Docker/install focused
  **43 PASS**, `/tmp/build11-docker-platform-fix-tests.log`, SHA256
  `c6766e2812bc68fc567c51d890819d9da94e5a7d919d4eb86188ff19cc580c07`.
  Actual Cloud Docker28.4.0/API1.51 readonly capability check PASS. Никаких
  containers/daemon изменений в Cloud; actual new CI readiness ещё не заявляется.

Уже запущенные **новые** builds (не дублировать):

- Backend/web: https://github.com/docice545/gallery/actions/runs/38484089051
  **SUCCESS**, artifact `gallery-trash-server-linux-amd64`, ID11858938573,
  605061147 bytes. GitHub ZIP SHA256
  `6e19132928f9747f9248ce792a1d58ac0141c3929d6350dad2b0db8d4a7609b3`.
  Это checksum ZIP artifact, не внутреннего Docker archive/image identity.
  Actual disposable PG HTTP lifecycle и hardened rollback smoke PASS.
- Unsigned iOS: https://github.com/docice545/gallery/actions/runs/38484090958
  **SUCCESS**, `ios-unsigned-ipa` ID11860071853, ZIP SHA256
  `45b54927254d844e2ccf1126269f1d59822f0dc2b3b910aee668364914493ab4`;
  `ios-unsigned-archive` ID11859008510, ZIP SHA256
  `9455b28ee6e47bc233aa4f6087d8c6b2caaa74365c8df3f709f26e5370e0b06e`.
- Android: https://github.com/docice545/gallery/actions/runs/38486187028
  **SUCCESS**, `android-media-pilot-validation-apk` ID11861136880,
  ZIP SHA256 `2aed72b139ffe8a945b2de0f67454932b0fbbde07548964bc53ddbbae367c5f7`;
  native reports ID11861351523, ZIP SHA256
  `b0347b1255527d29b60955d5997aab09b3ea233109999cd14f7c83ea3e646e14`.

Все три exact source89447178 и SUCCESS. Не пересобирать их из-за tooling-only fixes.
Backend использует existing reviewed rollback run38288841511/sourcec4c2d199…;
iOS existing workflow development + empty version (никаких Store/TestFlight).
Android выполнен после iOS: shared concurrency не отменил IPA. APK использует
CI debug certificate, не HP update. Unsigned IPA требует прежней SideStore подписи.

Actual distribution proof **FAILED**, ошибка теперь точно установлена:
https://github.com/docice545/gallery/actions/runs/38509927962,
workflow HEAD `038afbe7c8bfa04c44417b03c4c73288d80a26c2`, application89447178.
Использует три успешных run IDs выше и прежний hardened rollback38288841511.
Checks API: `DOCKER_PLATFORM_FLAG_UNSUPPORTED`, operation
`DOCKER_IMAGE_INSPECT_PLATFORM`, client/server API **1.48**, returnCode125,
stage `interrupted configuration creation`. Требуется CLI+daemon API>=1.49.
Это CI toolchain blocker, не application defect. Same-source seal и classic
proof PASS; все 31 installation/upgrade/rollback gates пока НЕ PASS.
Small report `gallery-build11-verification-report-38509927962`, ID11868764505,
ZIP SHA256 `8992b4d5b26d435481ce1b0923a9c0fb824740228c71fe30006333279b1dcfc0`.
Исправление сохранено в `2434b5795f…`; следующий шаг — rerun только release-proof
на опубликованном tooling HEAD с прежними successful component run IDs.
Signed APT pin сохраняет standard socket/systemctl и Compose plugin;
API/flag readiness проверяется до fixture startup, classic→containerd сохранён.
`docker/setup-docker-action` проверен и не подходит: создаёт другой daemon/socket.
Следующий proof `38514544036` на tooling814ec5142a FAILED **до** artifact download:
`PINNED_OFFICIAL_DOCKER_PACKAGE_UNAVAILABLE`. Global runner repository selection
не подтверждает наличие exact official package. Поправка использует отдельный
job-local HTTPS Docker APT source и штатный официальный runner key
`/usr/share/keyrings/docker.gpg`, не меняя global sources или package version.
Новые bounded Checks notices показывают exact version/repository availability,
без credentials или personal metadata. Embedded selector tests: **5 PASS**.
Proof `38516103681` FAILED до artifact download: `RUNNER_OFFICIAL_DOCKER_KEY_REQUIRED`.
Runner действительно не содержит штатный Docker key. Bootstrap теперь получает
**публичный** vendor GPG key через verified HTTPS в новый job-owned temp directory,
проверяет OpenPGP format и использует его только через Signed-By в job-local APT
source. Global keyrings/sources не изменяются, signatures/TLS не отключаются.
Это CI-only correction; app artifacts по-прежнему valid source89447178.
Не пересобирать components при tooling-only correction. Old failed
proof38424787561 не был install PASS. New diagnostics доступны через Checks API
даже когда redirected blob log запрещён Cloud policy. Записывать реальные
artifact IDs/checksums из manifest, не подставлять ZIP hash вместо binary hash.

Последний proof `38516670951` на tooling `1a5158240a` FAILED уже после
успешного Docker28.4/API1.51 bootstrap. Checks diagnostic: image inspect
`--platform linux/amd64`, returnCode1, `PRIVATE_ERROR_OMITTED`, первая stage
`interrupted configuration creation`. То есть прежняя API1.48 причина исправлена,
но actual 31 installation gates пока не прошли.

Read-only registry audit подтверждает SHA256 обеих OCI indexes, их точные
linux/amd64 child manifests и config blobs: PostgreSQL b1d33572…→178719ae…,
Valkey67878c70…→c439a6b7…. Ни descriptors, ни configs не содержат AMD64 variant.
Не подменять platform на предположенный variant и не ослаблять identity checks.
Tooling commit `d2d02b346c81d2c84d3004fa3c9f357ef9caf4ab` добавляет fixed
POSTGRES_PINNED/VALKEY_PINNED diagnostic и authoritative Moby platform-not-found /
content-missing classifications, без публикации stderr, argv, credentials или
private paths. **32 affected harness tests PASS**, Python compile/diff check PASS.
Application inputs по-прежнему byte-identical source89447178; no rebuild.

Текущий повтор только release-proof:
https://github.com/docice545/gallery/actions/runs/38519250044,
HEAD `d2d02b346c81d2c84d3004fa3c9f357ef9caf4ab`, component runs прежние.
На checkpoint Docker bootstrap, source seal и tamper fixtures PASS;
classic actual image/rollback proof выполняется. Дождаться результата, прочитать
Checks annotations; не дублировать run. Distribution всё ещё NOT READY до actual
31-gate PASS и published compiled package. Следующий шаг — точный classified
platform failure (если повторится), минимальное tooling correction и only proof rerun.

Proof `38519250044` завершился FAIL за6m13s: теперь точная диагностика
`DOCKER_REQUESTED_PLATFORM_UNAVAILABLE`, **VALKEY_PINNED**, API1.51, returnCode1.
PostgreSQL inspection прошёл; API1.48/bootstrap проблема не повторилась.
Source seal, image tamper guards и actual classic rollback proof PASS.
Distribution не опубликован; small report ID11873496454, ZIP SHA256
`c785314467a253f7f4bc22465ece086b8a2c5b216d075ee860fa537b8f1aebde`.

Tooling correction `b7eb7ba594ddd19a34e60dd8f43fc4321dafbd23` исправляет
подтверждённый source-level blind spot Moby/containerd: unqualified inspect
может вернуть доверенный index с отсутствующим локальным child. Только exact
index+descriptor+RepoDigest с пустыми Os/Architecture допускает один exact
pinned linux/amd64 pull; затем повторяются parent/child/OS/arch checks.
Wrong digest, descriptor, registry, OS/arch отклоняются до repair; unsupported
platform не заменяется fallback. **49 installer/Docker tests PASS**, включая
6 новых regressions; compile/whitespace PASS. Real CI resolution ещё не PASS.

Workflow tooling `bf9d3edef69ab887d4f8ca21247dcfc7f94c71e6` дополнительно
публикует typed verified **component** inner SHA256 receipt после sealer,
до installation gates. Это не final readiness receipt. YAML/Bash/embedded
Python syntax PASS. Application source89447178 остаётся неизменным.
Текущий единственный proof https://github.com/docice545/gallery/actions/runs/38520267120
на HEADbf9d3edef69…: **IN_PROGRESS**. Не дублировать, дождаться результатов.

Физические S23/iPhone, актуальная restored HP DB upgrade/rollback, реальные NFS
и current6+21 queue receipts остаются NOT TESTED/operator gates. Source review или
синтетические tests не превращают их в PASS. Production/signing/deployment нет.

---

# Предыдущая передача (историческая, f26 artifacts больше не текущий candidate)

Ветка `candidate/gallery-5.7.3-build11-upstream`. Production `work/main` не
изменялись. Не переносить эту ветку поверх незакоммиченных HP изменений:
интеграция только отдельно после их сохранения/review.

**Application source заморожен:** `f26b46059726ca3c55c63c3ce1edde7e45d8404f`,
version `5.7.3+11`. Immutable build ref: `build/gallery-build11-f26b4605`.
Последний завершённый tooling/docs commit:
`b4daf53432253d98c25074c7acd4ea57969c867a`.
Final HEAD определяется `git log -1`; handoff не может содержать свой собственный SHA.

## Актуальный STOP: final installation CI, не application build

Distribution run38424787561 **FAILED** (HEAD448c536195),
https://github.com/docice545/gallery/actions/runs/38424787561.
Same-source APK/IPA/backend seal, tamper tests и actual classic image/rollback
proof PASS. Containerd+installation step FAILED; Checks API подтверждает
`PACKAGED_INSTALLER_COMMAND_FAILED_PRIVATE_OUTPUT_OMITTED`.
Финальный compiled distribution не опубликован; **NOT READY**.

Создан настоящий небольшой artifact
`gallery-build11-verification-report-38424787561`, ID11827544540,
14545 bytes, ZIP SHA256
`4e325a2c677f1975ec714e52a8d42124ffa20d0dbefac91e375283587d7d718d`.
Он содержит candidate profile, реальные image/rollback/upstream reports и
`build11-installation-lab.json` с точной stage/line. Это не installable distribution.
Чтение отчёта и job115391216929 logs перенаправляется на
`productionresultssa1.blob.core.windows.net`, отсутствующий в runtime allowlist;
обычный и require_escalated download вернули403. API/Git auth работают.
Не обходить proxy/сетевую политику, не просить новый token и не повторять CI вслепую.

Cloud configuration draft сохранён: добавлен ТОЛЬКО host1, сохранены прежние
hosts, package-manager preset и ранее подготовленный host14. Draft `saved`,
`requires_publish=true`; это НЕ применённая runtime policy. Нужно применить
добавление через настройки Cloud, затем один раз скачать маленький report и
прочитать точную Docker-command/stage/line. Если CLI продолжает в независимой
dev-среде с уже разрешённым GitHub access, эквивалентный read-only download:

```bash
gh run download 38424787561 --repo docice545/gallery \
  --name gallery-build11-verification-report-38424787561 \
  --dir /tmp/gallery-build11-verification-38424787561
gh run view 38424787561 --repo docice545/gallery --log-failed
```

Это не поручение выполнять команды на HP production. После диагностики исправить
ТОЛЬКО подтверждённую tooling/CI причину, проверить affected tests и повторить
existing Build11 proof workflow. Последний русский runbook commitb4daf53432
тоже должен войти в final package. Backend/APK/IPA не пересобирать без runtime
дефекта: `git diff f26b4605 HEAD -- server mobile web open-api i18n pnpm-lock.yaml
package.json pnpm-workspace.yaml` пустой. Все source inputs сохранены.

## Продолжение: конкретная причина installation CI установлена

Лог run38385050973 теперь получен через штатный GitHub proxy; обхода сетевой
политики не было. Classic/containerd image probes, APK/IPA verification и
provisional package прошли. Actual lab начался и остановился на
`PACKAGED_INSTALLER_PINNED_PUBLIC_DEPENDENCY_IDENTITY_REQUIRED`, до изменения
production (вся среда disposable).

Docker containerd возвращает multi-platform index при обычном inspect без
OS/architecture. Исправление проверяет exact pinned index → linux/amd64 manifest
→ config через `image inspect --platform`, но сохраняет исходный index ID для
идентичности созданного контейнера. Произвольные references/digests/архитектуры
отклоняются. Для clean install нужен Docker Engine/CLI28+, API1.49+; HP upgrade
не обновляет Docker и не пересоздаёт PostgreSQL/Valkey.

Проверки этого исправления: 36 installer tests PASS; Build11 discovery
80 PASS, 1 opt-in Docker test SKIP (81 total); Python compile, diff и Prettier PASS.
Actual classic daemon exact PG/Valkey identity checks PASS. Actual containerd
clean-install/upgrade ещё требует следующего distribution run, а не mock теста.
Workflow теперь сохраняет bounded failure code и небольшие реальные verification
reports даже при отказе полного пакета. Acceptance matrix добавлена в checksum
manifest; её отсутствие или изменение отклоняется.

Текущий actual distribution run:
https://github.com/docice545/gallery/actions/runs/38424787561,
HEAD `448c53619542758add9e9c76cf66baa84f0d07b2`. Same-source sealing и classic
image/rollback proof уже PASS; окончательный failed result указан выше.
Следующий шаг — прочитать окончательный результат/небольшой verification artifact
этого run, без повторной сборки backend/mobile.

Дополнительно исправлен только русский runbook: Ubuntu tty-scoped sudo нужно
подтвердить внутри tmux, до журнала; rollback также использует tmux/private log/
pipefail и verification только после успеха. 10 Bash blocks syntax PASS,
четыре executable wrappers syntax PASS, Prettier/diff PASS. Эти docs ещё должны
войти в окончательный compiled package; не считать старую инструкцию полной.

## Новая выполненная работа

- `83efa782b744f4233a75658b05507b782c1cf617`: CI-only исправление external fixture.
  Первый backend smoke правильно отверг external root внутри managed `/data`.
  Fixture перенесена в отдельный anonymous `/external` volume, проверяется
  upstream validate API перед scan. Application source не менялся, mobile rebuild
  из-за этого не требуется. 33 smoke contract tests PASS.
- `982a4a38228f58492698ec37bf1500ff31a60f60`: private durable initialization
  journal, interruption/resume до записи plan, actual Compose/env/mount/network/
  container verification и отдельный fresh-install image-only rollback с настоящим
  receipt. Default `TARGET_ALREADY_RUNNING` guard остаётся; fake apply receipt нет.
  28 installer +78 image-release tests PASS.
- `553b6f17049575cd566f891fecbe80e6615e2348`: explicit Build11 mode в существующем
  artifact proof workflow, real compiled guard/migration probes, classic/containerd
  descriptor-graph identity mapping, same-source seal и actual installation lab.
  Все 30 lab checks обязательны перед upload. Signed recovery-proof не ослаблен.
  77 Build11 Python tests PASS. Это unit/contracts, не actual installation PASS.
- Полные final backend gates реально выполнены: **6858 passed, 1 expected fail,
  12 skipped**, 0 unexpected failures; **PG14 3370 passed, 12 skipped, 0 failed**,
  189 files. Никаких изменений runtime/fixtures для прохождения этих gates.
  Старый post-fix full-suite blocker закрыт. Flutter/web/browser не повторялись.

Exact commands, limits и log SHA:
`docs/BUILD11-TEST-REPORT.md`; machine-readable cloud evidence
`/tmp/build11-resume-final-gates.json`. Backend unit log SHA
`35cb2b0816979fa89a1e7c8aa52ce1a09793475d7c3f4bde680139f2a69344b4`,
PG14 log SHA `c2f89658dc2e389950b1c2c4193476eaa59f2e656c0f789371887b15ca840b5e`.

## CI/артефакты текущего продолжения

- Backend **SUCCESS**: https://github.com/docice545/gallery/actions/runs/38379404888
  Application source `f26b4605…`, audited tooling HEAD `83efa782b7…`.
  Artifact `gallery-trash-server-linux-amd64`, ID `11802997305`, ZIP SHA256
  `d6f42f03efec15d40443a79aca68d3d6c07c8367a5bc518352fb8a42200025fa`.
  CI реально проверил upload/Trash/Restore, thumbnail/preview, ordinary managed
  deletion, external writable original unlink и old-runtime rollback HTTP.
  Immutable image/archive identities брать из опубликованного manifest, не ZIP hash.
- iOS **SUCCESS**: https://github.com/docice545/gallery/actions/runs/38377576890
  Source `f26b4605…`. `ios-unsigned-ipa`, ID `11803385671`, ZIP SHA256
  `6305cb9e5403a6169bac38da9883fa758a0e24f948e8fa90c841e2022f53778a`;
  `ios-unsigned-archive`, ID `11803410088`, ZIP SHA256
  `3f998e516f02e73a656ca069a8965de2a7ab18eefc1877c096fcf05436d6ab62`.
  Build-only, no paid signing/store upload. Unsigned IPA requires existing SideStore.
  APK/IPA/image byte/version verification выполнен distribution CI sealer перед
  последующим installer отказом; успешные mobile artifacts не пересобирать.
- Android **SUCCESS**: https://github.com/docice545/gallery/actions/runs/38379958872.
  Source `f26b4605…`. `android-media-pilot-validation-apk`, ID11803644959, ZIP SHA256
  `7c01dc8ab8391a33f8b813d5531e46aa5df445587158df43258eaf59ffc67517`.
  `android-media-pilot-native-tests`, ID11804900535. CI debug certificate; cannot update HP-signed installation.
  Do not rebuild successful mobile artifacts for tooling-only corrections.
- Compatible rollback remains run38288841511/sourcec4c2d199…/artifact11764458784;
  successful main backend verifies its actual HTTP startup on Build11 schema.
- First main backend run38377573475 failed only external fixture validation;
  it is superseded by successful38379404888, not a second application candidate.

## Точная следующая операция

1. All three component runs are SUCCESS. Existing
   `gallery-trash-release-proof.yml` was dispatched on this tooling branch with `build11=true`,
   source_commit=f26b46059726ca3c55c63c3ce1edde7e45d8404f,
   backend_run=38379404888, android_run=38379958872, ios_run=38377576890,
   rollback_run=38288841511,
   rollback_source=c4c2d1991b01a372aa833a1f5ea0f9acc23be67a.
   For local CLI (read-only GitHub, no production operation):

   ```bash
   gh run view 38385050973 --repo docice545/gallery --log-failed
   ```

   Identify the first genuine failed command and fix only its cause. Main backend,
   Android and iOS are already SUCCESS; no rebuild for tooling-only changes.

2. This workflow downloads each artifact once, validates APK/IPA/image provenance,
   classic+containerd identity, packages binaries, executes actual clean install /
   fresh rollback / representative Build10 upgrade / interrupted rollback /27paused
   job preservation /managed+external physical deletion on synthetic files only.
   On failure: fix tooling/harness only when justified, repeat affected workflow;
   preserve application source unless a real runtime blocker requires changing it.
3. Publish final package/checksums only after all genuine installation checks PASS.
   Current distribution run **38385050973 FAILED** at
   `Verify Build11 on containerd and assemble compiled distribution`; package **NOT READY**.
   Первоначальный доступ к redirected log был403; штатный повтор теперь успешен.
   Причина установлена и исправляется выше: Docker containerd pinned dependency
   platform inspect. Сетевой отказ больше не считается текущим blocker.
   Previous proof38384393537 failed before lab: adapter omitted ARCHIVE_SHA.
   Fixed8369b9f5; 3 regression tests PASS including actual small-image Docker load/save, no mocks-only identity claim.
   This proof passed classic/containerd identity and provisional package.
   Actual installation lab started, failed before config creation; final published
   distribution artifact пока отсутствует. Повторить только affected proof workflow.
4. Update this handoff with final run/artifacts/actual lab results and source/tooling
   SHAs; never present mock fixture packages or GitHub ZIP digest as APK/IPA/image hash.

No HP changes, production restore/delete, real NAS files, signing keys, merge,
queues, VPN/DNS/Memories changes. Physical S23/iPhone, actual HP recovered DB/NFS,
legacy-six reconciliation and remaining21 paused preservation remain operator gates.
New docs: BUILD11-DISTRIBUTION-CI.md, BUILD11-INSTALLATION-LAB.md,
BUILD11-RELEASE-NOTES.md, BUILD11-TEST-REPORT.md; Russian runbook now includes
`gallery-rollback.sh --fresh-install PACKAGE INSTALL_DIRECTORY --execute-approved`.

---

## Предыдущая передача (историческая; новые результаты выше имеют приоритет)

# Gallery Build 11: передача Cloud → CLI

Статус: **NOT READY для production**. Разработка сохранена; это не готовый
установочный релиз и не разрешение deployment/signing/изменения очередей.

## Точная точка продолжения

Ветка: `candidate/gallery-5.7.3-build11-upstream`.
Последний коммит реализации: `ce32f1b2161776dc848138654a9ebc843da71a7e`.
Коммит handoff определяется `git log -1 --format=%H -- BUILD11_CLOUD_HANDOFF.md`;
полный опубликованный HEAD указан в сообщении пользователю. Исходная точка
`3d60f90461511659812eb1341ecda394ba9e1571` сохранена в истории.
Production `work`: `42790b06edc21438811e56e40c431eee37c24894` — не изменялся.
Не переключать и не перезаписывать существующий HP checkout с локальными правками.
Продолжать в отдельной копии этой ветки; никакого reset/rebase/force-push.

Сохранённые коммиты:

- `ec19db84cf692ed5063d413446eab13bda496f05`: verified upstream/compatibility gate.
- `2c963edc541f548139f0d4074e40fb27f7754804`: mobile/web deletion modes, Live Photo autoplay, generated API/SDK.
- `017033c85ab21275f36c04eba812f9d79162af03`: backend owner-storage mode, durable guards и regression tests.
- `ce32f1b2161776dc848138654a9ebc843da71a7e`: installer/signing/rollback tooling.

## Что реализовано

1. Managed permanent deletion обычным аутентифицированным владельцем; для внешних
   библиотек отдельный явно включаемый writable mode, по умолчанию read-only.
2. Сохранены ownership, shared originals, physical root identity, fd-relative
   quarantine, checksum, tombstone/receipt, revocation, interruption/retry guards.
   Исправлена невозможность отзыва после изменения/удаления library, а также
   внутреннее соответствие mountId/namespace у сохранённого quarantine receipt.
3. Restore и configurable expiration используют существующий lifecycle/очереди.
   На HP paused backgroundTask НЕ активировался; expiration там пока заблокирован.
4. Mobile: Gallery / Device / Everywhere, OS acknowledgement, partial outcomes;
   route/background Live Photo rearming с decoder budget1 и lease-revision guard.
5. Web: видимый Live Photo autoplay с бюджетом3, scroll/viewer/background/retry,
   albums/search; обычная owner configuration вместо admin-only proof UI.
6. Additive migration `1794050000000-OwnerStorageDeletion`; offline291 records
   НЕ конвертируются в Trash. Старые migration bytes не изменены.
7. Подготовлены `gallery-install.sh`, `gallery-upgrade.sh`, `gallery-verify.sh`,
   `gallery-rollback.sh`, compiled package sealer/assembler, private resumable
   signing adapter и русский runbook. Это пока PREPARED, не actual install PASS.
8. Два baseline unit guards исправлены корректно: SQL revert ledger/table list и
   AST-aware shared-space scanner. Tombstone barrier и реальные query guards
   сохранены; никаких отключённых проверок.

**Signed recovery-proof:** `server/src/utils/deletion-recovery.ts` не ослаблен.
Legacy/admin preparation сохраняет Ed25519, owner/scope/root, authenticity,
freshness≤24h и защищённый evidence store; arbitrary64hex не является доказательством.
Новый `authorizationMode=storage` — ранее явно заказанная отдельная normal-owner
политика, а не принятие поддельного signed proof. Не заменять recovery validator
фиктивными PASS, digest или обновлёнными timestamps ради тестов.

## Проверено фактически

| Проверка                                             | Результат                                                     |
| ---------------------------------------------------- | ------------------------------------------------------------- |
| Flutter final full suite                             | 4697 PASS, 1 SKIP, 0 FAIL                                     |
| Flutter full analyze / changed Dart format           | PASS, No issues                                               |
| Web full suite                                       | 6458 PASS, 2 SKIP, 4 TODO                                     |
| Web TypeScript/Svelte/scoped ESLint                  | PASS; Svelte0 errors/warnings                                 |
| Actual Chromium autoplay                             | 8 PASS, synthetic MP4 + mocked local API                      |
| Backend security/crypto/filesystem + repaired guards | 205 PASS                                                      |
| PG14 deletion/retention/stack suites                 | 144 PASS, 0 FAIL                                              |
| PG14 six compatibility suites                        | 340 PASS                                                      |
| New PG14 lifecycle/migration/revocation              | 15 PASS                                                       |
| Official EXIF/plugin recheck                         | 30 PASS                                                       |
| Python tooling targeted runs                         | 201 PASS, 0 FAIL                                              |
| Backend TypeScript / wrapper/Python syntax           | PASS                                                          |
| Structural API/migrations                            | 371 upstream operations +97 upstream migration files retained |
| Starting Build10 fork API → current generated API    | 399 operations retained, no wire failures                     |

Первый полный backend unit run:6851 PASS,2 baseline FAIL,1 expected failure,
12 SKIP. Обе ошибки исправлены; affected security/guard suite205 PASS, полный
unit suite после исправлений ещё не повторён.
Первый full PG14 run:3289 PASS,79 FAIL,12 SKIP. Причины: отсутствовали pinned
public fixtures/plugin WASM, старые synthetic Trash/migration assumptions,
deletion fixture dependencies и timeouts при параллельных suites. Все affected
группы исправлены/повторены успешно; complete final full PG suite НЕ повторён.
Последние stack failures: fixture не задавала StorageCore.mediaLocation после
reset; bootstrap-compatible fixture initialization исправлена,144/144 PASS.
Не выдавать initial failed full runs за финальный полный PASS.

Actual HP restored database, NFS, S23/iPhone, production signing/deployment:
**NOT TESTED / NOT EXECUTED**. Обычный backend compile/OpenAPI/SDKgen PASS, но
`server/dist` не immutable release artifact и требует сборки от final source.

## Артефакты и CI

Успешен только **совместимый hardened rollback**, не основной Build11 сервер:

- Ветка `candidate/gallery-build11-hardened-rollback`.
- Source `c4c2d1991b01a372aa833a1f5ea0f9acc23be67a`.
- https://github.com/docice545/gallery/actions/runs/38288841511
- Artifact `gallery-trash-server-linux-amd64`, ID11764458784.
- Artifact ZIP SHA256:
  `ce262c3ee1d5e15f0639601a4b8afb0521dd4a44e19f81eca128da848615e350`.
- Только exact179405 migration+ORDER добавлены к reviewed Build10 runtime.
  Старый fallback без migration не запустится на новой Kysely ledger.
- Actual Build11→fallback HTTP/Trash/Restore acceptance ещё НЕ выполнен.

Основные Build11 backend/APK/IPA и assembled distribution пока НЕ построены.
Локальный summary: `/workspace/gallery-build11-cloud-artifacts/validation-summary.json`.
Browser outputs сохранены там же, original logs `/tmp/build11-*` и
`/tmp/gallery-build11-*`; эти пути относятся к CLOUD, не к HP.
Git source/docs/tests доступны через опубликованную ветку. Не принимать
синтетические fixture packages в `/tmp` за release artifacts.

## Зависимости и проверенные команды

Node24.21.0, pnpm11.24.0, Flutter3.47.2 frameworkd3b14c8769, Dartизтого жеSDK,
OpenAPI Generator7.25.0, Linux Docker disposable daemon, PostgreSQL14 pinned
images из `server/test/medium/globalSetup.ts`; actualHP digestbcf633... — другой
проверенный production-compatible вариант, не менять его. Xcode26.2/macOS15
только existing iOS CI; Android SDK36/JDK17 — existing Android CI.
Official test-assets gitlink `ec56cc6c1d76c45bc9615dc6ea232470a2b0a3a1`:
использовались подлинные файлы с проверенными Git blob hashes, не substitutes.
Core plugin WASM собран штатным pinned Extism; на CLI его нужно подготовить,
если cached output отсутствует. Generated Dart client игнорируется Git: его
необходимо штатно создать из committed OpenAPI перед Flutter checks.

В disposable cloud/CI, из корня repository (на HP не обращаться к production
Docker socket для destructive integration tests):

```bash
pnpm --config.verify-deps-before-run=false --dir server exec tsc --noEmit
pnpm --config.verify-deps-before-run=false --dir server exec vitest --config test/vitest.config.mjs --run
pnpm --config.verify-deps-before-run=false --dir server exec vitest --config test/vitest.config.medium.mjs --run --maxWorkers=2 --testTimeout=30000 --hookTimeout=30000
python3 -m unittest discover -s scripts/release/tests -p 'test_build11*.py'
python3 -m unittest discover -s scripts/release/tests -p test_gallery_install.py
python3 -m unittest discover -s scripts/release/tests -p test_android_sign_package.py
python3 scripts/release/upstream_compatibility.py --report /tmp/build11-compatibility.json
(cd open-api && bash bin/generate-dart-sdk.sh)
(cd mobile && flutter pub get --enforce-lockfile && flutter analyze --fatal-infos && flutter test)
```

Не выполнять снова успешные suites без новых изменений. Для окончательного
full unit/PG gate повторение обосновано указанными post-fix omissions.
Build backend только existing `scripts/release/server_build.sh FULL_SOURCE_SHA NEW_OUTPUT`;
чистый exact checkout, no production Compose. HP не должен компилировать final
distribution вручную: сборки выполняются в CI, Android HP-key — отдельный signing
готового payload через `android_sign_package.py` после approval, без пересборки.

## Следующий шаг — без повторного исследования

1. Прочитать этот файл и `git status/log`, сохранить текущую ветку отдельно от
   локальных HP правок. Убедиться, что scoped backend lint/format final PASS.
2. Повторить окончательные full unit/PG suites в disposable CI, не production DB.
3. Зафиксировать один source SHA для всех основных compiled components.
   Existing backend workflow `gallery-trash-server-build.yml` поддерживает
   `rollback_run=38288841511`, `rollback_source=c4c2d1991b01a372aa833a1f5ea0f9acc23be67a`.
   Он скачивает rollback один раз и проверяет actual old-runtime HTTP на upgraded
   schema через `server_artifact_smoke.py SOURCE CANDIDATE_DIR ROLLBACK_DIR`.
4. Existing mobile workflow: `version` ПУСТОЙ; сначала `build_target=ios`, затем
   `build_target=android,android_media_pilot=true`. Shared concurrency group:
   НЕ запускать параллельно и НЕ отменять уже начатые успешные runs.
5. Main artifacts должны иметь один exact head SHA. Если нужны app fixes после
   build — новый обычный commit и rebuild affected components, без fake provenance.
6. **Distribution CI extension unfinished:** `gallery-trash-release-proof.yml`
   пока исторический build8/9; НЕ dispatch default как Build11. Нужны Build11 mode,
   actualimageprobe→compatibility receipt builder, download/seal compiled artifacts,
   `build11_package.py`, реальные clean/upgrade/interruption/rollback lab tests.
   Не синтезировать runtime PASS: assembler требует genuine backend runtime report.
7. Только после successful builds/actual lab tests публиковать package/tag/checksums.
   Нормальные owner operations не должны требовать custom helper; старые шесть
   cleanup jobs — отдельная legacy recovery задача существующего scoped runner.
8. HP gate: exact-six completed receipts/physical absence или approved scoped
   continuation; preserve other21 paused hashes/order. Queue activation/expiration
   в production — отдельное решение, никакого global resume/clear.
9. Actualfreshbackup/restoredcopy/NAS evidence, owner HP-key signing, SideStore
   signing и physical acceptance остаются operator gates. Production deployment
   только после отдельного approval. Не удалять реальные media.

## Upstream и ограничения

Authoritative upstream https://github.com/open-noodle/gallery,
basev5.7.1 `da5480ae42b77db9cae729f2447ec9b3079ba4a7` (Immich3.2.4).
Latestv5.8.0 `37aa54e632606cc6a62bc6bcbba14c62200147c4` НЕ интегрирован:
rebased history,8 migrations, favorites/sync/thumbnail/build изменения требуют
отдельного проверенного upgrade. Stock downgrade с durable tombstones не
поддерживается; использовать compatible Gallery rollback и verified backups.
Generated OpenAPI/SDK diff крупный, но автоматический: structural retention
проверен для всех399 endpoints исходного fork, не только371 official endpoints.
Не переписывать API/types ради косметического сокращения generated diff.

Документы: `docs/BUILD11-UPSTREAM-COMPATIBILITY.md`,
`docs/BUILD11-RELEASE-RUNBOOK.md`, `docs/BUILD11-USER-MANUAL-RU.md`.
Ни full latest-upstream compatibility, ни final production-installable Build11
в этой точке НЕ объявлены доказанными.
