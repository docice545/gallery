# Build 11 final audit: `a0301e219`

Дата аудита: 2026-10-15. Проверка выполнена только на синтетических данных; production,
Docker production, PostgreSQL/NAS/VPN/Redis и реальные media не использовались.

## Итог

**PASS после отдельного исправления `e2aecb46b`.** Коммит `a0301e219` оставлял
несовместимость в wire contract: DTO принимал только токен `gallery-recovery-v1...`,
тогда как действующие release/authorization-инструменты передают SHA-256 digest
подписанного Ed25519 envelope. Это блокировало легитимную подготовку удаления ответом 400.
Отдельный коммит перевёл DTO на тот же digest contract, который проверяет production
`verifyRecoveryEvidence`, и добавил регрессионную проверку.

## Аудит удаления

| Область | Результат | Основание |
|---|---|---|
| Live Photo JPG на NFS + MP4 на SSD | **PASS** | Companion MP4 допускается только из owner-scoped `EncodedVideo`; JPG остаётся в исходном root. Синтетические medium-тесты проверяют пару, owner/library boundaries и отказ для MP4 вне encoded-video root. |
| Повторное получение SSD identity | **PASS** | При storage authorization повторно собираются root identities; `samePhysicalRootIdentity` допускает только сохранение path/device/inode/mount type/source/root/target. Mount ID и namespace считаются ephemeral. |
| Привязка quarantine | **PASS** | `bindQuarantine` открывает root и quarantine через fd, проверяет directory/dev/inode/uid/gid/mode и пустоту; persisted binding коммитится до capture. NFS root-squash сценарии проверены с mapped UID/GID. |
| TOCTOU и подмена | **PASS** | Hash/stat до и после capture, fd-anchored parent/root, повторная проверка policy непосредственно перед rename, atomic rename в private quarantine, advisory locks и проверка shared references. Подмена source/quarantine сохраняет оригинал и блокирует удаление. |
| Crash/restart | **PASS** | Receipt остаётся durable после ошибки rename/fsync/unlink; retry использует сохранённый quarantine. Для SSD проверено восстановление после изменения только mount ID/namespace при неизменной физической identity; `bindQuarantine` повторно проверяет фактический quarantine dev/inode/uid/gid. |
| Смена mount identity | **PASS с ограничением** | Разрешается только для `authorizationMode=storage` и совпадения физической identity; изменённые device/inode/source/root/target или quarantine identity блокируются. Recovery-mode продолжает требовать полное совпадение. |

## Recovery contract

**PASS:** `scripts/release/authorize_library.py` и disposable server smoke передают digest
`[a-f0-9]{64}` файла signed envelope; server повторно читает trust store, проверяет digest,
Ed25519 signature, owner/scope, root identities, expiry, PostgreSQL receipt и samples.
Повторная проверка выполняется при preparation, consent и непосредственно перед unlink.

`server/src/utils/recovery-evidence.ts` содержит старый self-contained
`gallery-recovery-v1...` формат, но production service/release wire path его не использует;
production verifier находится в `server/src/utils/deletion-recovery.ts`. Это оставлено как
технический риск сопровождения: мёртвый формат нельзя считать действующим API и его следует
либо удалить отдельной задачей, либо явно пометить deprecated.

Прямое сравнение с `accb078c1` **не подтверждено**: объект отсутствует в локальном git
(`bad revision`). Сравнение выполнено с доступными предшественниками `19452ecfa` и
`95ae75790`; для окончательной побайтовой проверки нужен сам commit или его patch.

## Проверки

- `cd server && pnpm test --run src/services/managed-deletion.service.spec.ts src/utils/authorized-deletion.spec.ts src/utils/recovery-evidence.spec.ts` — **133/133 PASS**.
- `server/test/medium/specs/services/authorized-deletion.spec.ts` — **82/82 PASS** ранее записано в validation log, включая NFS-like quarantine, Live Photo scope, TOCTOU, restart и mount-identity regression.
- `python3 -m unittest scripts.release.tests.test_release_candidate scripts.release.tests.test_server_artifact_smoke scripts.release.tests.test_trash_predeploy scripts.release.tests.test_trash_recovery_inputs` — **113 PASS, 6 skipped**.
- Полный Python release suite — **146 PASS, 10 skipped** (`BUILD11_python_release_tests_rerun.log`).
- Server type-check, production build/postbuild migration sync и `git diff --check` — **PASS** по validation logs.

## Оставшиеся риски

1. Реальный NFS server/root-squash и смена mount namespace не запускались; fixtures моделируют Linux/NFS-like поведение.
2. `accb078c1` недоступен локально, поэтому его точное соответствие не доказано.
3. Recovery proof зависит от защищённого read-only trust store и корректного Ed25519 key provisioning; deployment этого хранилища в рамках аудита не проверялся.
4. Синтетические тесты не являются доказательством поведения конкретного NAS при нестандартных `rename`, `fsync` или server-side ACL semantics.

Деплой не выполнялся. Исправление находится в отдельном коммите `e2aecb46b`.

## Финальный аудит NFS intent, 2026-10-15

Оба локальных файла доступны и целы: `gallery-build11-nfs-recovery-CANDIDATE.patch`
(16 714 bytes, SHA-256 `7b985e968a79e563a7c0ca3bfac0519b4dea2cad14fb39273f4fa594fa7b0697`)
и `gallery-build11-nfs-intent-REVIEW.patch` (14 422 bytes, SHA-256
`fe5cbc5387134865126401d989ec76bd05f113f0b5757db61eeda309d42f7e7e`). Оба патча
содержат один durable-quarantine intent слой и не применяются целиком к HEAD:
`git apply --check` останавливается на устаревшем контексте `asset.repository.ts`,
поэтому перенесены только нужные hunks.

В отдельном рабочем изменении добавлен `quarantineDirectory` с UUID-валидацией,
транзакционным сохранением имени до первого `mkdir`, повторным использованием этого
имени после сбоя, проверкой пустоты/режима и исключением динамических quarantine-путей
из внешнего индекса. Добавлены unit-регрессии crash-after-mkdir и malformed/non-empty
intent; medium fixture теперь моделирует UUID-каталог.

Актуальные проверки: unit authorized-deletion **111/111 PASS**; medium
`authorized-deletion.spec.ts` **82/82 PASS**; `pnpm exec tsc --noEmit` **PASS**;
Prettier, ESLint и `git diff --check` **PASS**. Medium suite включает Live Photo JPG
на NFS-like root и MP4 в owner encoded-video root, quarantine, повтор после сбоя,
смену mount ID/namespace, подмену quarantine и сохранение чужих файлов.

`result-2.txt` в доступных checkout и каталогах аудита не найден. Реальный NFS/root-squash,
NAS ACL и mount namespace не запускались; medium helper остаётся синтетической моделью.
Production, Docker, PostgreSQL/NAS/VPN/Redis и deployment не затрагивались.

Статус: **READY_FOR_REVIEW**.
