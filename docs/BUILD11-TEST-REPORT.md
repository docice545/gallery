# Gallery Build 11: подтверждённые результаты проверок

Application source: `89447178806ccc509ff0b52358b7491842041047`.
Immutable build ref: `build/gallery-build11-89447178`.
Версия: `5.7.3 (11)`. Production не участвовал в проверках.

Этот Cloud source включает исправления автоматического backup, owner-scoped
локального удаления и Live Photos в альбомах. Неопубликованные файлы HP не
получены и не считаются интегрированными. Старые сборки source `f26b4605…`
**SUPERSEDED**: они не содержат новые runtime-исправления и не являются финальными
артефактами этого candidate.

## Итоговый CI: SUCCESS, production acceptance отдельно

[Run38553886139](https://github.com/docice545/gallery/actions/runs/38553886139)
на tooling `ec9a67ab8df18d0509bd61e4642efd69d6b48c86` завершился **SUCCESS**.
Все31 required actual isolated checks, clean teardown и strict checksum sealing
прошли. Compiled distribution опубликован: `gallery-build11-distribution-38553886139`.
Actual lab проверяет clean install/resume/repeat, Build10 upgrade/migration,
asset/user/album/sharing и27paused preservation, thumbnails/previews, disposable
managed/external physical deletion, mixed scopes, rescan tombstones, fresh upgraded
backup restore и hardened rollback после injected failure. Это synthetic Linux
fixtures, а не HP/NFS или физические устройства.

Сохранённые ниже отказы — история исправлений, не current CI status. Cloud logs
подтвердили PASS lab/finalizer и exact source/inner binary hashes; strict finalizer
требует все31 проверки и false для production/device gates. Последний report
artifact опубликован, его скачивание в Cloud было network-denied; повторных
large artifact downloads не выполнялось. Previous385515 small actual lab report
полностью прочитан:32true (31required +fixture), cleanupErrors=[].

Полная production готовность остаётся **BLOCKED_OPERATOR_ACCEPTANCE**: HP fresh
restore/NFS/legacy six+21 и physical S23/iPhone, HP signing и SideStore signing
не выполнялись. [Final handoff](BUILD11-RELEASE-HANDOFF.md) содержит hashes и links.

## Текущие release-tooling проверки

- Explicit platform authority + bounded missing-content refill + immutable
  Valkey child package: **66 PASS** (52 installer,7 package,7 Docker platform).
- Linked PostgreSQL predeployment identity guards: **45 PASS,4 opt-in SKIP**.
- Installation boundaries/diagnostics/read-only imports: **48 PASS**.
- Strict distribution finalizer: **16 PASS**.
- Actual compiled storage resolver / artifact-smoke helpers: **39 PASS**;
  включает6 actual detector cases. Эти два module suites вместе **81 PASS**.
- Disposable Docker transition/probe-cache regressions: **21 PASS**.
- Source894 и upstream Compose byte-identical; application builds сохраняются.
- Actual clean-install/upgrade/rollback CI ещё требует PASS; предыдущие
  `38520267120`/`38521936065` остановились на исправленном overstrict index guard
  до конфигурации. Unit fixtures не означают actual installation PASS.
- Run38526321706: exact Valkey digest/config/platform/availability PASS, затем
  failed Docker classic-store restoration. Tooling-only e4152b7d4a исправляет
  deliberate restart rate counter и fail-closed probe cleanup. Новый proof
  Run38540870600 подтвердил исправление transitions/cleanup, но остановился
  на actual Valkey metadata-only cache (`Available=false`). Tooling-only
  d7da5131eb добавляет один exact-digest refill с полной повторной проверкой.
  Run38542645355 снова FAIL на Docker28.4 metadata-only cache. Новый CI-only
  pin official Docker29.9 не меняет ни одного artifact/dependency identity.
  Signed bootstrap/transition suite29.9: **21 PASS**.
  Run38544077473 на Docker29.9 прошёл actual clean-install/resume/repeat и
  fresh-install rollback/repeat (**6 checks true**, cleanupErrors=[]).
  Он остановился уже при создании queue fixture: env mediaLocation optional,
  actual backend успешно использует auto-detection `/data`. Tooling-only
  e894798194 повторно использует настоящий resolver без изменения runtime env.
  https://github.com/docice545/gallery/actions/runs/38547396269 **FAILURE**:
  snapshot fixture обращался к удалённому upstream album.ownerId. Исправлен
  join album_user role=owner, добавлено сохранение всех sharing roles.
  **4 actual PostgreSQL14 regression PASS**, включая воспроизведение SQLSTATE42703;
  existing installation-boundary suite42 PASS. Application inputs не менялись,
  mobile/backend workflows не повторяются.
- Run38551567325: actual installation lab **PASS**, все31 required checks +
  representative27PausedJobsCreated, cleanupErrors=[]. Прошли clean install,
  resume/repeat, Build10 upgrade/migration, data+sharing+27paused preservation,
  thumbnail/preview jobs, managed/external disposable physical deletion,
  mixed scopes, isolated upgraded backup restore и rollback/repeat.
  Finalizer затем отклонил unmanifested Python bytecode внутри package:
  **ALL_EXECUTABLE_TOOLS_AND_ARTIFACTS_MUST_BE_CHECKSUMMED**. Distribution ещё
  не был опубликован в385515. Tooling fix запрещает запись bytecode, checksum guard остаётся
  строгим. Exact исходный отказ воспроизведён; 6 новых regressions проверили
  read-only direct/deferred imports, восстановление interpreter policy после
  сбоя, strict sealing и rejection/retention посторонних файлов. **48 harness
  +16 finalizer PASS**; последующий final proof385538 SUCCESS.

## Завершённые application gates

| Проверка                                           |  PASS | Ожидаемые / пропущенные              |         FAIL |
| -------------------------------------------------- | ----: | ------------------------------------ | -----------: |
| Финальный полный backend unit suite                | 6 858 | 1 expected failure, 12 skipped       | 0 unexpected |
| Финальный полный PostgreSQL 14 medium suite        | 3 370 | 12 skipped                           |            0 |
| Полный Flutter suite текущего Cloud source         | 4 786 | 1 skipped                            |            0 |
| Полный web suite, сохранённый результат            | 6 458 | 2 skipped, 4 TODO                    |            0 |
| Актуальные focused web deletion tests              |    24 | 4 файла                              |            0 |
| Upstream Empty Trash HTTP controller               |     7 | новый focused suite                  |            0 |
| Upstream Empty Trash PostgreSQL 14                 |    17 | disposable DB                        |            0 |
| iOS background worker: реальная последовательность |     6 | fake native/platform boundaries      |            0 |
| Affected iOS worker / local-sync tests             |    60 | включает worker coverage             |            0 |
| Remote / local album cold-open Live Photo          |     2 | widget controller fixtures           |            0 |
| Album / Live Photo focused suite                   |   116 | 4 файла, включает эти 2 widget tests |            0 |
| Chromium Live Photo lifecycle                      |     8 | synthetic MP4 и mocked API           |            0 |
| Filesystem, signed recovery и guard regressions    |   205 | входит в backend gates               |            0 |

Backend unit: 212 файлов passed, 1 skipped; duration 238.05 s.
PostgreSQL: все 189 файлов passed; duration 443.44 s.
Ожидаемая baseline ошибка: `timeline.controller.spec.ts` →
`should fail if time bucket is invalid` (`it.fails`). Она не скрывается и не
считается подтверждением корректного отклонения invalid time bucket.

Полные backend/PG и web/browser результаты сохранены с предыдущего gate;
неизменённые runtime inputs позволяют использовать их в указанной области.
Новые Empty Trash controller/PG тесты дополнительно проверяют upstream HTTP
контракт. Полный Flutter suite запущен заново после mobile runtime-исправлений:
**4 786 PASS, 1 SKIP, 0 FAIL**. Полный `flutter analyze --fatal-infos`:
**No issues found**. Новые scoped suites входят в полный Flutter результат и
не складываются с ним повторно. Browser 8 не запускался заново: web autoplay
inputs не изменились; его PASS не переносится на physical mobile decoder.
Backend TypeScript, web TypeScript/Svelte, scoped ESLint и форматирование имеют
сохранённые результаты; новые проверки перечислены в handoff.

## Проверенные исправления текущего Cloud source

1. Переиспользованный ОС media ID с другими байтами больше не наследует старый
   backup hash. Действительный новый файл остаётся upload candidate; подтверждённая
   удалённая копия не воскресает после изменения metadata, scan или исчезновения
   server row.
2. «Удалить из «Фото»» при включённой local/remote sync сохраняет телефонную
   копию, подавляя server resurrection. Android offline index tombstones
   остаются offline records; Restore не создаёт новый device file.
3. Завершённый receipt с `permanent=false` обрабатывается как восстановимое
   legacy-состояние. Нельзя считать его доказательством завершённого unlink и
   автоматически удалять устройство на основании отсутствующего server row.
4. После Empty Trash и отказа ОС есть явно подтверждаемое **OS-only retry**.
   Оно выбирает только completed receipts текущего owner и локальные IDs с
   проверенным текущим checksum. Смена аккаунта прекращает OS-операцию;
   неопознанные или устаревшие selection IDs получают предупреждение.
5. Настоящий iOS background worker сканирует устройство, синхронизирует сервер,
   вычисляет native hash и только затем начинает upload. Timeout/cancellation
   дожидаются owned work перед закрытием DB. Неуспешный hash не отправляет
   unhashed кандидатов и не сообщает success.
6. Remote/local album связывает still/motion до cold-open autoplay. Scope и
   owner filters отделяют device assets от cloud album assets. Live Photo
   остаётся muted в ленте и использует ограниченный controller budget. Два
   cold-open widget теста выполнены на 390×844; все 116 scoped cases прошли.

Команды из корня repository, после активации pinned toolchain:

```bash
pnpm --config.verify-deps-before-run=false --dir server exec vitest --config test/vitest.config.mjs --run
pnpm --config.verify-deps-before-run=false --dir server exec vitest --config test/vitest.config.medium.mjs --run --maxWorkers=2 --testTimeout=30000 --hookTimeout=30000
cd mobile
flutter test
flutter analyze --fatal-infos
```

PostgreSQL работал исключительно в disposable testcontainers на проверенном
облачном Docker socket. Применена additive migration
`1794050000000-OwnerStorageDeletion`; использованы настоящие pinned public
test-assets и штатно собранный core plugin WASM. Production DB и NAS не подключались.

SHA-256 финальных локальных логов:

- Backend unit: `35cb2b0816979fa89a1e7c8aa52ce1a09793475d7c3f4bde680139f2a69344b4`.
- PostgreSQL 14: `c2f89658dc2e389950b1c2c4193476eaa59f2e656c0f789371887b15ca840b5e`.
- Текущий полный Flutter: `e0dad6d832d4929aa5e03efd3308af71340d1a919f2e1d3edc1417e23c0808c6`.
- Текущий Flutter analyze: `8ee6ed4f65b29e35647635e81d445aa6ca2e181be14bd3cdfdd9268bd65bacbf`.
- Focused web: `c745e1691d05b60c71d9415b764b0792d0f869195472a1e399f4a918689ea041`.
- Upstream controller: `16909ca1a5199b8b2d9db915db89072d70317517da9aaa6533caf01a1faa3ee4`.
- Upstream PostgreSQL: `98cde3b87ca2c45b5e68bc5fc182ce9198822214071b43c07bb7c1981714f669`.
- iOS worker 6: `381ce32c18bbe9f52d8f265117c2528f20768b3e30fea353c8c09821b73afc22`.
- Affected iOS 60: `9646b6dac4e1919f19e7d46bca1516ddf56743c1c10ce27782bce802a404e2ee`.
- Album / Live Photo 116: `e97975feb2974f049a5c5cf3bf019be36553de6fe9fe3b6880056f3af0f4b503`.

Эти локальные логи хранятся в текущем Cloud workspace под `/tmp`, это не пути
операторской установки. Краткие immutable результаты сохраняются в release
пакете и handoff; приватные данные в Git не включаются.

## Сборки нового source

- [Backend CI 38484089051](https://github.com/docice545/gallery/actions/runs/38484089051):
  **PASS**, `gallery-trash-server-linux-amd64`, artifact ID `11858938573`.
  Реальный disposable PostgreSQL HTTP Trash/Restore и hardened rollback runtime
  smoke прошли вместе со сборкой backend/web.
- [Unsigned iOS CI 38484090958](https://github.com/docice545/gallery/actions/runs/38484090958):
  **PASS**, `ios-unsigned-ipa` ID `11860071853`, `ios-unsigned-archive`
  ID `11859008510`. IPA unsigned и требует существующей SideStore подписи.
- [Android CI 38486187028](https://github.com/docice545/gallery/actions/runs/38486187028):
  **PASS**, `android-media-pilot-validation-apk` ID `11861136880`, native tests
  ID `11861351523`. Native Kotlin и emulator playback, Flutter checks и
  release-mode APK packaging выполнены. Сертификат CI, не HP update identity.
- Compiled installation/distribution proof выполняется только с новыми
  backend/Android/iOS артефактами; старый f26 пакет не закрывает этот gate.

Все три run имеют application SHA, указанный в начале документа. Точные GitHub
ZIP checksums записаны в handoff; внутренние APK/IPA/Docker archive checksums
подтверждает отдельный sealer. ZIP digest не выдаётся за checksum бинарного файла.
Installation CI RUNNING не считается PASS, физический Android/iPhone не проверен.

После application gates исправлены только release tools: корректная pinned
PostgreSQL index identity и штатное обновление recovery evidence после 24 часов.
Build11 Python suite: **122 PASS, 1 SKIP, 0 FAIL**; PostgreSQL/predeploy guards:
**45 PASS, 4 opt-in Docker SKIP, 0 FAIL**. Bash syntax, Python compile,
formatting и unchanged application-input comparison — PASS.
Новый real upgraded-database fresh-backup/restore gate является обязательным в
installation CI; его unit fixtures не объявляются настоящим restore PASS.
SHA256 tooling log: `6a4d1f817b98409aaa691bfa08657a9d1efb757d66412370955c0e5cfc841c97`.

## Границы доказательств

Автоматические проверки используют disposable DB, файлы и пользователей.
Это доказательство application behavior в изолированной среде, а не успешного
удаления с production Synology или на Samsung/iPhone.

Следующие проверки остаются отдельными operator/device gates:

1. Свежий backup реальной HP DB и успешное восстановление именно этих байтов.
2. Реальные NAS recovery evidence, NFS root identities и разрешения конкретных
   библиотек; никаких искусственно обновлённых timestamps или fabricated proofs.
3. Состояние шести legacy FileDelete и неизменность остальных 21 paused jobs.
   Нельзя считать старый журнал подтверждением ещё не проверенного выполнения.
4. Обновление S23 существующим HP-key-signed APK без uninstall и утраты данных.
   CI debug signature не является подписью HP. Private key в CI не используется.
5. Подпись unsigned IPA через существующий SideStore и проверка расширений.
6. OS-confirmed local deletion, denial/partial failures, фон/перезапуск и Live
   Photo playback на физических Android/iOS.
7. Thumbnail/preview, upload/sync, albums/search/face recognition и rollback
   acceptance на HP после отдельно разрешённого deployment.

Настоящие CI run IDs, artifact identities, package SHA-256 и installation lab
report публикуются отдельно после завершения соответствующих операций. Наличие
этого документа не создаёт CI PASS и не разрешает production deployment.
