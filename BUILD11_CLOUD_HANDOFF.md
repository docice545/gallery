# Gallery Build 11: актуальное продолжение 2026-10-13

Ветка `candidate/gallery-5.7.3-build11-upstream`. Production `work/main` не
изменялись. Не переносить эту ветку поверх незакоммиченных HP изменений:
интеграция только отдельно после их сохранения/review.

**Application source заморожен:** `f26b46059726ca3c55c63c3ce1edde7e45d8404f`,
version `5.7.3+11`. Immutable build ref: `build/gallery-build11-f26b4605`.
Последний завершённый tooling commit:
`8369b9f531abee8546f685f29f845bd718fec84c`.
Final HEAD определяется `git log -1`; handoff не может содержать свой собственный SHA.

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
  Cloud read of redirected iOS logs returned403; escalation was not granted.
  Do not retry/bypass; byte/version verification is still performed by artifact CI sealer.
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
   Exact failing command/cause is not yet known: redirected job log returned403;
   read-only escalation for job115254649938 also returned403. Exact failure is
   `CONNECT tunnel failed, response403`; redirect host
   `productionresultssa14.blob.core.windows.net` is absent from the cloud allowlist.
   A draft adds ONLY that host and preserves every configured domain; it requires
   application/publication in environment settings. No credential is missing or requested.
   Do not bypass policy, weaken identity checks or rerun blindly.
   Previous proof38384393537 failed before lab: adapter omitted ARCHIVE_SHA.
   Fixed8369b9f5; 3 regression tests PASS including actual small-image Docker load/save, no mocks-only identity claim.
   This proof passed classic Docker; containerd/package/lab step failed.
   Whether actual installation lab started/completed is NOT VERIFIED; no published distribution artifact.
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
