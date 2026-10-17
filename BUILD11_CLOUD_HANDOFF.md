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
