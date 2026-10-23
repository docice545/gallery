# FOTO Build 17 — исправление оставшихся CI-блокеров

Продолжение от PR6 `5e84b5132427624d926abe28fad788d89ed2431c`, PR7
`c79c843b9b5efdc3620c1e026ec06edcfe4d8294`, PR8
`7713ba765edb0994a905fd01a49c3bc9a67f65fa`. Изменения сохраняются небольшими
коммитами в соответствующих ветках, обычный push с проверкой old remote SHA.
Acceptance2364 и все 16 коммитов уже находились в PR7; повторного переноса нет.
Unified/HP/production/БД/Redis/NAS/VPN/ключи/APK/существующие images не менялись.

**На момент записи новые CI ещё выполняются; READY не заявляется заранее.**
Финальные статусы и ссылки добавляются в PR comments после завершения, без
повторного запуска успешно завершённых тяжёлых suites из-за одного отчёта.

## Разбор исходных красных jobs

| Проверка                                      | Причина / классификация                                                                                        | Исправление и границы                                                                                                                                                                                                                        |
| --------------------------------------------- | -------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| API: exclusive uploaded Live Photo returns409 | Реальный дефект admission: companion внутри bound Upload всё равно проверялся как SSD-generated                | После проверки DB-связи/owner/library/exclusive references используется уже разрешённый root. Новый SSD root не добавляется, snapshot/mount/inode/TOCTOU/revocation проверки сохранены. 2 новые medium filesystem/PG cases, managed+external |
| API: shared motion returns409                 | Устаревший upstream test против явно принятой fail-closed fork-policy; существующий medium test требует отказа | Runtime guard не меняется. HTTP test проверяет отказ, сохранность обоих still/общего motion, ссылок и читаемых original bytes. Это документированное исключение политики, не разрешение удалять общий файл                                   |
| API: quota response                           | Stale exact response fixture, не ошибка used quota                                                             | DTO уже объявляет additive nullable duplicateId; тест требует explicit null и сохраняет проверки201/quota. Дедупликация не меняется                                                                                                          |
| API: server/features                          | Stale fixture двух существующих flags                                                                          | Exact response дополнен authorizedDeletion/ownerStorageDeletion. Объявление capabilities/runtime не меняется                                                                                                                                 |
| API: offline empty/restore                    | Stale expectations смешивали external index invalidation с пользовательским Trash                              | Требуется isOffline=true, isTrashed=false до/после Empty/Restore; чтение synthetic original сохраняется. Не создаётся owner deletion intent                                                                                                  |
| Web: reopen-tag missing                       | Реальный metadata bug: XMP не регистрировался при уже существующем thumbnail/preview                           | handleSidecarWrite проверяет отсутствие sidecarFile, а не пустоту всех files. 3 unit cases: thumbnail/preview/encoded video. Browser assertion сохранён; добавлены API preconditions и завершение sidecar/metadata queues                    |
| Server format/lint                            | Наследованные import order / formatting / Unicorn errors                                                       | Целевые style fixes; recovery counts теперь требуют safe integer (строже). Нет отключения правил или ослабления proof                                                                                                                        |
| ShellCheck                                    | 5 legacy scripts: intended child expansion и masking/status/mkdir warnings                                     | Quoted heredoc сохраняет literal child script; assignment/export раздельно; trap status объявлен; новые output directories создаются с umask077. Ни один diagnostic/deploy script не запускался                                              |
| Upstream workflow tooling                     | Pilot flutter build появлялся до branding marker                                                               | Реальный branding step до pilot build, с сохранением source version/build. Validator не ослаблен, APK/pilot не запускались                                                                                                                   |
| SQL schema #6/#8                              | Генератор предлагал удалить два migration-owned UPDATE OF guards, отсутствующих в code metadata                | Explicit @Trigger synchronize=false сохраняет точный immutable DDL; нет новой миграции и нет DROP guards                                                                                                                                     |
| SQL golden #6/#8                              | 4 generated queries устарели относительно существующего source                                                 | Обновлены по фактическому CI git diff; patch применён с git apply --check. Это snapshots, не выполнение SQL на production                                                                                                                    |
| OpenAPI #6/#8                                 | Generator output не форматировался; JSON полностью равен по данным                                             | Взяты существующие formatter recipes из PR7 и SDK config. Не заменяются schemas/contracts; semantic JSON equality VERIFIED по реальному generated artifact                                                                                   |
| Publishing/signing cancellations              | Source-review refs отсутствовали в старом guard allowlist; возможен запуск self-hosted mich                    | Ограничения source review распространены на актуальные refs. E2E #7/#8 остаются включены (2 scope tests). Скipped publishing не считается runtime/build PASS                                                                                 |
| Доступ к отдельным Actions logs               | Часть signed log URLs указывает на запрещённый policy host                                                     | Использованы официальные full-run ZIP/артефакты и доступные job logs; network policy не менялась, приватные download URLs не публикуются                                                                                                     |

## Доказательства и промежуточные ошибки

- Исходные failures взяты из завершённых runs39846822015 (PR7),39669332218
  (PR6),39848333021 (PR8), не предположены из названия job.
- Генерация PR6 run39872536914, artifact12467630026 содержит только OpenAPI JSON
  и SDK; artifact привязан к PR head61678 через workflow, имя содержит GitHub
  merge-ref SHA422d083496e100497ace69e84176af2d1f91bebd. JSON deep equality с
  source — true. Mass replacement generated JSON не выполнялся.
- SQL этого же run прошёл migrations/schema; затем сообщил stale
  asset.job.repository.sql, asset.repository.sql, memory.repository.sql,
  sync.repository.sql. Полный реальный diff497 lines сохранён в Cloud и применён
  только к этим generated paths. Не выдан за выполнение production миграции.
- Промежуточный e0af3 на #6 обнаружил мои пропущенные imports Trigger/function;
  исправлены. Новый filesystem test первоначально читал files через status helper,
  который их не возвращает; исправлен на typed query в disposable test DB.
  Неудачные/отменённые прогоны сохранены в Actions, не посчитаны успешными.
- Старые 3447/5017/6468 и 50 release PASS остаются historical evidence соответствующих
  SHA. Свежие PASS нового HEAD фиксируются только после завершения новых CI.
- Отменяются только superseded runs моих промежуточных heads, чтобы не тратить
  runner slots; актуальные обязательные checks не отменяются и не пропускаются.

## Согласованная локальная интеграция

Проверяемые candidates: #6 `97377d908a275d3057c5cabdb2b0bf262c7e8dfe`, #7
`e9bcf4ed7c2cadb90807c3801c1e2f06bf67dc90`, release code
`ba84d19db42d3231caf6bb98804ef6960b94c5d6` (затем только документация).
Git merge-tree #6+#7: tree9eb5d75b69fdbd833839d703b3592b437d96ec77,
0 conflicts. С release code до обновления config/workflow:
tree7b65d93835abece4ae163a0f6868e153c03b794e,0 conflicts.

Guard annotations согласованы без переноса acceptance или feature-мержей:
common migration-owned guard отделён от дополнительных catalog annotations.
@Trigger с functionName эквивалентен тонкому upstream @TriggerFunction wrapper;
условия/timing/actions/functions и immutable migration DDL сохранены. SQL CI нового
HEAD обязан подтвердить отсутствие drift. Merge-tree не создаёт merge в ветке,
не выполняет runtime и не заменяет приёмку клиентов.

## Совместимость и безопасность

Пинованные Immich3.3.5/Noodle5.8.0/FOTO contracts и acceptance MemoryV2 journal,
ACK/SQLite crash-retry не менялись. Изменения backend не модифицируют оригинальные
клиенты, редактор, Flutter sync или mobile backup. Legacy/signed recovery-proof,
owner revocation, shared-file refusal, NFS identity, symlink/path guards сохранены.

Физические Android/iOS, PhotoKit/iCloud/background/Live Photos/HEIC, stock Web,
настоящий Synology и AI inference E2E — **NOT VERIFIED**. Тесты CI используют
синтетические файлы, isolated PostgreSQL/Redis; это не production validation.
Подписанный APK, HP builder, backup/rollback требуют отдельной локальной приёмки.
Никакой skip publishing или PASS unit не объявляет эти требования выполненными.

## Следующий безопасный шаг

После нового CI: взять точные опубликованные SHA. Для HP пока только
[versioned установка и --check](../../tools/foto-automation/FOTO_BUILD17_RELEASE.md#установка-инструмента-doctoriceadm-без-изменения-исходного-checkout).
Config unapproved, старые state/history/keys/worktrees/cache сохраняются.
Prepare/test/build/deployment не запускались и не следуют автоматически из check.
При красном/неизвестном CI конвейер обязан блокировать интеграцию.

## Уточнение по новым завершённым CI (23 октября, UTC)

Исторические runs39873567046 (#6),39873570471 (#7),39874117896 (#8)
выявили следующие дополнительные проблемы. Их исправления не считаются PASS
до нового обязательного CI актуального HEAD.

- #7 API:1388 PASS/1 FAIL. Единственный отказ — моя ошибочная массовая замена
  precondition обычного Restore. Исправлено: только обычный пользовательский Trash
  требует isTrashed=true/isOffline=false; offline index остаётся false/true.
  Исходные шесть API-отказов в этом прогоне уже отсутствуют.
- #7 Web:401 PASS/2 FAIL/7 SKIPPED в browser suite,110 PASS/6 FAIL/4 SKIPPED в
  mock UI. Старый reopen-tag проходит. Два rating-теста зависели от момента
  metadata enqueue; теперь ожидаются реальные upload-success события и явно
  проверяются три rating=3 через API. Ожидания «3 results» сохранены.
- Mock UI Trash пропускал обязательный deletedAt в columnar ответе; production
  getOrderingDate правильно отказывается выдумывать дату. Исправлен только
  синтетический генератор; добавлены два адресных теста aligned timestamps и
  soft-delete/restore. Это не доказательство удаления настоящих файлов.
- Medium: album_user ACK order предполагал порядок вставки внутри одной ms.
  immich_uuid_v7 содержит random bits. Теперь exact ожидаемые ACK строятся по
  независимо прочитанным persisted updateId и сортируются в порядке протокола;
  роли/userId/число записей/replay сохраняют проверки. Migration test проверяет
  новую идентичность и реальные millisecond timestamps, не лексический random tail.
  Генератор UUID и migration DDL не менялись.
- #7 server unit: scanner принимал точный column-metadata literal за asset read;
  узкое anchored исключение покрыто положительным/двумя отрицательными случаями.
  revert-to-immich manifest дополнен фактическими fork-таблицами/functions/пятью
  migration IDs. Ранний запрет при наличии deletion tombstones сохранён; SQL не
  исполнялся. Конвертация с потерей fork-only overlays не является FOTO rollback.
- Адресный Cloud запуск только двух filesystem guard-specs: **43/43 PASS**,971ms.
  PostgreSQL, browser, native clients и тяжёлые backend suites этим не проверялись.
  Первый запуск из неверного cwd не обнаружил imports и не считается PASS.
- Release fixtures run39874118024: **50/50 PASS +2/2 source-scope PASS** на
  опубликованном ea6c9121fbd583f3f29087b0bd8e37038cdf38c1. Новый HEAD требует
  собственного CI. Основной release executable/locks/rootless/checkpoint/signing
  enforcement не изменён; все примеры approvals по-прежнему false.

Актуальные code candidates после этих исправлений:

- PR6 `ed8cd06773d8cc46dedc935f65c8a08ee60c4eae`
- PR7 `2c13d3588aa5ed56b8b508080f46adb4ac35a1c5`
- PR8 code/config `10a9d2d58a925f5a29806a17f145a2308beb902b` (документация следующим коммитом)

Окончательные CI результаты публикуются в PR comments по точному новому HEAD.
Красный/неизвестный/отменённый обязательный check блокирует локальную интеграцию.
Нельзя выдавать previous PASS или skipped publishing за новый successful build.

## Исправления новых тестов и повторная проверка (23 октября)

- Завершённый PR6 run39877250566:31 successful checks,17 skipped,1 FAIL.
  Medium3420 PASS/17 SKIPPED. Единственная причина server job —
  unicorn/consistent-function-scoping у нового millis helper. Подтверждено полным
  реальным логом и адресным AST-only lint; helper вынесен на module scope.
  Адресный повтор этой rule с max-warnings0 — PASS; это не полный ESLint/TSC.
- API ARM в #7/#8 обнаружил ошибку нового synthetic fixture: getTimeBucket
  нормализует ISO month key к YYYY-MM-01, а test передавал Map c YYYY-MM.
  Исправлен только test key; исходные assert id/deletedAt/restore сохранены.
- Новый spaces fixture ожидал websocket upload-success, но сам spec не подключал
  websocket. Это мой test regression, не инфраструктура. Теперь подключение
  создаётся в beforeEach до uploads, disconnect/очистка event callbacks — в afterEach.
  Browser ожидание трёх рейтингов и трёх results не ослаблено.
- Старые/отменённые runs39877247795 и39877334238 не считаются successful.
  Перезапуск вызван новым исходным SHA и исправлениями подтверждённых ошибок,
  не попыткой получить случайный green. Обязательные CI-gates не отключались.

Новые опубликованные editor/compat candidates:
`b83f987beb1bc63b52a865d0dde1741cefa46e1f` /
`2eac8c9a93b44a9afe9abb4290dc07172ce8b28d`.
Release tool/config pin `1a29751ff3faffc92d28aa9e1a23b06105fa5d06`; последующий commit меняет только отчёт/README.

До завершения собственного обязательного CI новых HEAD статус **BLOCKED**.
Точные terminal statuses/ссылки дописываются в PR body/comments без doc-only
повтора тяжёлых suites. Runtime/mobile/immutable migrations этим раундом не менялись.
