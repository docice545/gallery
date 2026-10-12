# Подтверждённые queued deletions и установка ea51

Owner approval: удалить ранее запрошенные пользователями файлы и затем установить
готовый ea51 image. Исходные данные HP: backgroundTask paused, 27 jobs;
FileDelete IDs `886, 887, 888, 929, 930, 953`. Это не blanket authorization
для NAS originals без owner/scope/receipt/recovery доказательств.

## Что выполняет инструмент

`hp_build10_queued_delete.py` использует существующий RUN_ROOT, prepared hardened
rollback и неизменённый `image_release.py`. Никаких rebuild, Git merge, SQL
updates, retention activation, Memories/VPN изменений или новых credentials.
Проверяются все 27 jobs, их raw hash/data/options, порядок и atomic LLEN/ZCARD
всех семи состояний, плюс bounded orphan inventory. SCAN не доказывает пустоту.
Данные jobs/пути файлов остаются только в private JSON (0600); выводятся numeric
IDs, известные names, counts и fixed error codes.

В frozen source `JobService.onJobRun` не пробрасывает Failed/exception как BullMQ
failure. Простое resume может привести к removeOnComplete при оставшемся файле.
Поэтому инструмент НЕ resume/drain/clean/retry очередь и НЕ запускает остальные
21 jobs. Они остаются paused с неизменными data/options/hash/порядком.

Перед удалениями проверяется frozen target/rollback, полное совпадение guards и
migrations, Compose, source/version, API и microservices, unrelated containers.
`prepare-images` проверяет только image/config/migration readiness; это не PASS
очередей и не deployment approval. Обычный `prepare` сохраняет полный queue gate.

Для шести jobs создаётся краткоживущий handler container **из того же готового
ea51 image**, не новый образ или NAS service. AppModule/cron/API/microservices в
нём не bootstrap. Он использует уже существующую network namespace; все volumes
сервера, originals и evidence подключаются RO. Только уже существующие RW
`thumbs`, `encoded-video`, `profile` подключаются RW. Host/NAS mount flags не
меняются. Root directory device/inode/UID/GID проверяются до/после bind; source
symlinks, неоднозначные/nested mounts и изменённые fingerprints — STOP.
Read-only rootfs, no-new-privileges, cap-drop ALL + FOWNER (для NFS root squash),
0.5 CPU, 512 MiB, 128 PIDs. Никакого SYS_ADMIN, privileged, host networking или
больших chmod/chown. Env file содержит существующие настройки (0600), никогда
не выводится. Baked source target не заменяется пустым source старого image.

Исполняется настоящий `StorageService.handleDeleteFiles` с native repositories
и READ ONLY PostgreSQL transaction. Профиль/shared/live references дополнительно
проверяются. Native filesystem dependency использует существующие
`snapshotOriginal/bindQuarantine/unlinkOriginal`: identity/checksum proof,
descriptor-relative traversal, atomic capture, 0700 quarantine, повторная
проверка references и защита от ancestor substitution. Все пути сначала
проверяются на disposable scope и физическое отделение от upload/library/external
roots. Максимум 256 paths/job и 4 GiB данных. Root bindings/nonce/checksum сохраняются
на HP **до capture/unlink**. Эти manifests не являются recoveryProof/backup evidence.

BullMQ `Job.remove({removeChildren:false})` вызывается только после `Success`
handler и проверенного отсутствия каждого source и captured file, при неизменном
job hash и paused queue. Это ACK фактически выполненного removeOnComplete job;
никакого удаления заданий вместо файлов. Failed/Skipped/исключение, оставшийся
файл/capture, shared reference или изменённая queue сохраняют job и блокируют
deployment. При partial failure report отличает completed jobs от failed job и
remaining files; private proofs позволяют verified retry в той же namespace.

## Hard STOP, без обходов

- Legacy FileDelete с upload/library/external original: нужны реальные
  owner/scope/deletion intent/receipt и актуальная recovery authorization.
  Plain path и operator confirmation не заменяют эти сведения. Нельзя подставлять
  temporaryOwnerId, менять job payload или policies через SQL.
- Среди других jobs есть незавершённый AssetDelete/AssetEmptyTrash: нужен отдельный
  разбор именно этих intent/receipt; инструмент их не считает завершёнными.
- Новые/изменённые jobs, orphan deletion hash, active/failed/delayed jobs,
  root substitution, unreferenced quarantine EEXIST, read-only/unavailable NFS,
  unsupported fsync/checksum/shared-file failure, pending migration, config drift.
- При прерывании первой подготовки с незарегистрированным quarantine — STOP,
  не автоматически усыновлять directory. Originals ещё не перемещались.

## Один операторский запуск

Нужны existing Docker/Compose, Python 3.11+, tmux, sudo docker и cached pinned
fallback ZIP либо существующая gh authorization. Свежий recoverable PG backup
и реальные NAS recovery reports должны быть сохранены. Они не повторяются и
не фабрикуются этим инструментом. Не использовать failed predeploy state повторно.

Из pinned tooling commit скачать checksum manifest и **все восемь** файлов:
`hp_build10_rollback.py`, `hp_build10_rollback.sh`, `image_release.py`,
`trash_image_identity.py`, `trash_release.py`, `trash_predeploy.py`,
`hp_build10_queued_delete.py`, `hp_build10_queued_delete.mjs`.
Проверить manifest SHA из handoff, затем все file hashes и Bash/Python syntax.
В tmux, с тем же RUN_ROOT:

```bash
sudo -v
GALLERY_USER_QUEUED_DELETION_APPROVED=YES GALLERY_DEPLOYMENT_APPROVED=YES \
  python3 -B "$TOOLS/hp_build10_queued_delete.py" \
  --run-root /home/doctoriceadm/gallery-build10-release-TxDlXAuj --execute-approved
```

Без `--execute-approved` выполняется только inventory/admission. Explicit flags
реализуют уже данное владельцем approval; отдельные owner consent/recovery права
для originals автоматически не выдаются.

После успешного file drain helper удаляется **до** image update. Стандартная
проверка unrelated-container inventory снова работает без исключений, поэтому
rollback не зависит от существования helper. В случае interrupted file execution
helper удерживается с сохранённой private identity для verified recovery, не
bootstrap workers. Не удалять его до проверки capture/receipt.

В этом операторском workflow queue gate дополнительно разрешает **точно те же
21 paused non-original-deletion jobs** с исходными hashes/order и zero unresolved
AssetDelete/FileDelete; default `image_release.py` empty-queue gate не меняется.
Проверяются также physical absences в production namespace, root identity,
все cardinalities и orphan hashes непосредственно перед update. Это observation
в данный момент, не обещание отсутствия будущих jobs. Очередь остаётся paused.

Установка: только immich-server, image-only, --no-deps/--no-build/--pull never.
API и microservices запускаются нормальной конфигурацией. Не используются
API-only variables, down, remove-orphans, prune, queue clear или SQL restore.
Если update attempt существует и health не прошёл, инструмент вызывает уже
проверенный hardened rollback; возвращает FAIL, а не успех установки.

Reports: `RUN_ROOT/queued-user-deletions/queue-snapshot.json`, `file-proofs.json`,
`deletion-report-*.json`, `installation-report.json`, `stop-*.json`, plus existing
`hardened-rollback/image-state` receipts. Source paths/env/proofs private.
Не повторять image apply после незавершённого apply-attempt. SSH disconnect
решается повторным attach к той же tmux-сессии, не запуском второго executor.

`originalsDeleted: 0` в FileDelete report намеренно означает только derivative
cleanup; это не утверждение об окончательном удалении всех NAS originals.
Physical S23/iPhone, actual HP/NFS jobs и thumbnail/preview postflight здесь
не считаются пройденными. После install проверить disposable upload/preview,
Trash/Restore и source/version/health; разрешения владельцев обновить штатно
после реальных recovery checks (mount namespace сервера изменится).
