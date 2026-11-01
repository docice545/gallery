# FOTO Build 29: протокол проверки и безопасная приёмка

База Build 28: `083ff4109ce8cce292176fe08c00c892fe46c1b7`.
Ветка: `codex/foto-build29-instant-trash-cleanup`.
Семантика описана в [архитектурном решении](../2026-11-01-foto-build29-instant-trash-cleanup-design.md).

## Выполнено в Codex Cloud

| Проверка                                               | Статус              | Результат                                                                                                                                                  |
| ------------------------------------------------------ | ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Точное совпадение опубликованной базы Build 28         | PASS                | `git fetch`, проверка SHA и `ls-remote`; отдельный worktree                                                                                                |
| Flutter unit/widget/repository regression              | PASS                | 528 тестов, 23 файла; включая Build 28 Magic Eraser, background sync, MediaStore и Trash                                                                   |
| Полный `flutter analyze --no-pub`                      | PASS                | No issues found, Flutter 3.47.2 / Dart 3.13.2                                                                                                              |
| Серверные unit                                         | PASS                | 432 теста, 7 файлов                                                                                                                                        |
| Серверная интеграция на реальной disposable PostgreSQL | PASS                | 211 тестов, 14 файлов                                                                                                                                      |
| TypeScript `pnpm --dir server check`                   | PASS                | Без ошибок                                                                                                                                                 |
| ESLint изменённых серверных TS                         | PASS                | `--max-warnings 0`, без отключения правил                                                                                                                  |
| Nest/TypeScript server build                           | PASS                | `pnpm --dir server build`; это не Docker deployment                                                                                                        |
| OpenAPI/SDK                                            | PASS                | Regeneration; ровно два необязательных поля контракта, TS SDK build и Dart client compile                                                                  |
| Генерация SQL documentation                            | PASS с ограничением | 738 запросов / 65 файлов, изменены 3 snapshots; существующие методы с невалидными dummy-аргументами сообщают warnings, это не полный SQL integration audit |
| Миграции существующей схемы на disposable PostgreSQL   | PASS                | Включая `1796000000400`; новые миграции не добавлены                                                                                                       |
| Flutter/Drift/localization code generation             | PASS                | Существующие генераторы; schema/version/dependencies не изменены                                                                                           |
| Форматирование и `git diff --check`                    | PASS                | Dart, изменённые TS, SDK, OpenAPI, 10 локалей                                                                                                              |
| Физическое удаление на настоящей Synology/NFS          | NOT TESTED          | Только синтетические temporary файлы и permission/error fixtures                                                                                           |
| Настоящий restart/отключение питания HP/Redis          | NOT TESTED          | Проверены replay из receipt, новый экземпляр репозитория и bootstrap dispatch; не физическая перезагрузка                                                  |
| Samsung/MediaStore и реальный APK                      | NOT TESTED          | APK не собирался, ADB не использовался                                                                                                                     |
| CI новой ветки                                         | NOT TESTED          | Локальные результаты не выдаются за GitHub CI                                                                                                              |

Первоначальные FAIL устранены: вложенная Kysely transaction при Restore;
двойной audit в legacy Stack deletion; сохранение ненужного MemoryV2 journal;
старое ожидание принятых объектов в Trash; lint и analyzer замечания. Итоговые
прогоны не содержат skipped или failing тестов.

### Что именно проверяют тесты

- Принятие до hash/unlink/зависшей Redis-публикации; запрет успеха для legacy queued
  ответа; повторные UUID, потеря ответа и status reconciliation.
- Реальные конкурентные PostgreSQL accept/restore: выигрывает ровно одно решение.
- Atomic rollback при постороннем owner/неверном Trash; изоляция владельцев и
  scopes; External без разрешения остаётся нетронутым.
- Still + motion, видеокомпоненты, стопки, смешанный selection, прежний retention
  и альбомные связи. Физический формат JPG/HEIC не декодируется этой операцией:
  файловые fixtures подтверждают путь удаления, а не кодеки устройств.
- Pending/preparing/failed не входят в пользовательскую корзину, но receipts
  сохраняются; прямой Restore принятого UUID даёт конфликт.
- Принятый asset не приходит обратно через AssetsV2/cold sync, child FK events
  или обложки. Deprecated AssetsV1 по-прежнему отклоняется.
- Частичный unlink, ENOENT, сохранность asset_file manifest, поздний derivative,
  race с публикацией зарегистрированного файла, защита оригинала/Sidecar/чужого
  файла, отсутствие ложного complete при cleanup failure.
- Реактивная Trash в настоящей Drift; файловая SQLite закрывается и открывается
  заново с сохранённым pending marker; stale Restore/upsert и смена аккаунта,
  сервера или checksum не обходят защиту.
- UI (mock сервиса) показывает зелёный успех только после принятия, не использует
  модальное ожидание физического удаления или CleanupService, переживает уход
  со страницы и повторные нажатия. Сохранность БД проверяется отдельными реальными
  repository tests; UI mock не считается E2E на Samsung.

### Воспроизведение автоматических прогонов

В checkout с уже установленными pinned-зависимостями выполните штатную генерацию
`mise run //mobile:codegen`. Она обновляет generated OpenAPI/Drift/Pigeon/locales,
не собирает APK. Не заменяйте версии Flutter/Dart из `mobile/mise.toml`.

Из корня репозитория:

```bash
pnpm --dir server check
pnpm --dir server exec vitest --config test/vitest.config.mjs run \
  src/services/asset.service.spec.ts \
  src/services/trash.service.spec.ts \
  src/services/storage.service.spec.ts \
  src/services/queue.service.spec.ts \
  src/services/instant-trash-acceptance.spec.ts \
  src/services/instant-trash-storage.spec.ts \
  src/controllers/asset.controller.spec.ts
```

Только с локальным Docker, создающим disposable testcontainers PostgreSQL; не
передавайте production `DB_URL`, Redis или Docker context:

```bash
env -u DOCKER_CONTEXT -u DOCKER_TLS -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
  DOCKER_HOST=unix:///var/run/docker.sock \
  pnpm --dir server exec vitest --config test/vitest.config.medium.mjs run \
  test/medium/specs/services/instant-trash-acceptance.spec.ts \
  test/medium/specs/repositories/permanent-deletion-derivatives.spec.ts \
  test/medium/specs/services/authorized-deletion.spec.ts \
  test/medium/specs/services/stack-trash-selection.spec.ts \
  test/medium/specs/services/trash-retention-lifecycle.spec.ts \
  test/medium/specs/sync/sync-asset.spec.ts \
  test/medium/specs/sync/sync-asset-exif.spec.ts \
  test/medium/specs/sync/sync-album.spec.ts \
  test/medium/specs/sync/sync-album-to-asset.spec.ts \
  test/medium/specs/sync/sync-shared-space.spec.ts \
  test/medium/specs/sync/sync-shared-space-album.spec.ts \
  test/medium/specs/sync/sync-library-asset.spec.ts \
  test/medium/specs/sync/sync-client-compat.spec.ts \
  test/medium/specs/services/trash-timeline.service.spec.ts
```

Из `mobile/`:

```bash
flutter analyze --no-pub
flutter test --no-pub --concurrency=2 \
  test/repositories/permanent_deletion_api_repository_test.dart \
  test/repositories/asset_trash_api_repository_test.dart \
  test/domain/services/instant_trash_acceptance_service_test.dart \
  test/infrastructure/repositories/instant_trash_acceptance_test.dart \
  test/presentation/pages/instant_trash_cleanup_test.dart \
  test/presentation/pages/trash_kebab_menu_test.dart \
  test/presentation/pages/trash_batch_deletion_dialog_test.dart \
  test/infrastructure/repositories/trash_pending_operations_test.dart \
  test/infrastructure/repositories/trash_deletion_timeline_test.dart \
  test/infrastructure/repositories/trash_sync_visibility_test.dart \
  test/infrastructure/repositories/confirmed_remote_deletion_test.dart \
  test/infrastructure/repositories/trash_local_sync_test.dart \
  test/domain/services/sync_stream_service_test.dart \
  test/domain/services/local_sync_service_test.dart \
  test/domain/services/local_trash_sync_service_test.dart \
  test/repositories/asset_media_trash_repository_test.dart \
  test/pages/edit/magic_eraser_page_test.dart \
  test/pages/edit/magic_eraser_editor_integration_test.dart \
  test/domain/utils/background_sync_test.dart \
  test/infrastructure/repositories/magic_eraser_saved_copy_sync_test.dart \
  test/unit/domain/models/magic_eraser_test.dart \
  test/repositories/magic_eraser_repository_test.dart \
  test/unit/presentation/actions/magic_eraser_edit_action_test.dart
```

## Безопасный перенос исходников на HP

Не переключайте существующий production checkout и не удаляйте незакоммиченные
правки. Сначала сохраните `git status --short`, выполните fetch новой ветки и
сверьте **полный** SHA с итоговым отчётом Codex. Создайте отдельный detached
worktree в новом незанятом каталоге. Проверьте:

```bash
git merge-base --is-ancestor 083ff4109ce8cce292176fe08c00c892fe46c1b7 HEAD
git diff --check 083ff4109ce8cce292176fe08c00c892fe46c1b7 HEAD
git diff --name-status 083ff4109ce8cce292176fe08c00c892fe46c1b7 HEAD
git status --short
```

Это не инструкция переключения backend или сборки APK. Для нового UX требуется
совместимый backend с явным `accepted`; до его отдельной приёмки неизвестный
queued-ответ намеренно не даёт успешного мгновенного скрытия.

## Отдельная физическая приёмка после разрешения владельца

Используйте только staging, отдельного тестового владельца и специально созданные
синтетические медиа. Не очищайте настоящую корзину и не открывайте доступ к чужим
корням ради теста.

1. Обычный Trash/Restore до подтверждения очистки должен работать как прежде.
2. После очистки проверяйте: HTTP acceptance, пустую Trash без ожидания NFS,
   зелёное уведомление, запрещённый Restore, повторный вход/холодный запуск/sync.
3. Прервите только staging worker между принятием и unlink; перезапустите и
   проверьте receipt, продолжение удаления и отсутствие повторного появления.
4. Отдельно моделируйте недоступность staging NFS/Redis, потерю HTTP-ответа и
   частичное удаление derivatives. Статусы должны оставаться диагностируемыми;
   ошибка не делает объект восстанавливаемым и не превращается в complete.
5. Через прежние owner-scoped `POST /assets/deletion-status` либо
   `GET /assets/{id}/deletion-status` проверьте pending/failed/complete без новых
   секретов или изменения политик. Повторять можно только тот же подтверждённый
   тестовый набор UUID.
6. Отдельно проверьте Synthetic Managed/External, still+video, Stack, альбомы,
   повторный scan и upload. Реальное NFS-удаление требует существующей разрешённой
   политики и отдельного подтверждения; отсутствие asset в БД не доказывает unlink.
7. На Samsung проверьте UI и отсутствие неожиданных MediaStore операций. Наличие
   физического оригинала в Samsung Gallery не означает отмену серверного решения.
8. Регрессия Build 28: короткий/длинный pointer stroke, zoom/undo, Big-LaMa preview,
   сохранение копии и появление копии в FOTO; отдельно Motion/Live Photo autoplay.

До этих проверок нет подтверждения production-ready или физического удаления
на реальной NAS. Источник APK, номер версии и signing проверяются отдельно после
нового разрешения на сборку; текущая работа их не изменяет.

## Полный список изменённых файлов

- `i18n/de.json`
- `i18n/en.json`
- `i18n/es.json`
- `i18n/fr.json`
- `i18n/it.json`
- `i18n/nl.json`
- `i18n/pl.json`
- `i18n/ru.json`
- `i18n/zh_Hans.json`
- `i18n/zh_Hant.json`
- `mobile/lib/domain/models/deletion_result.model.dart`
- `mobile/lib/domain/services/asset.service.dart`
- `mobile/lib/domain/services/sync_stream.service.dart`
- `mobile/lib/infrastructure/repositories/remote_asset.repository.dart`
- `mobile/lib/infrastructure/repositories/sync_stream.repository.dart`
- `mobile/lib/presentation/pages/trash.page.dart`
- `mobile/lib/repositories/asset_api.repository.dart`
- `mobile/test/domain/services/instant_trash_acceptance_service_test.dart`
- `mobile/test/infrastructure/repositories/instant_trash_acceptance_test.dart`
- `mobile/test/infrastructure/repositories/trash_pending_operations_test.dart`
- `mobile/test/presentation/pages/instant_trash_cleanup_test.dart`
- `mobile/test/repositories/permanent_deletion_api_repository_test.dart`
- `open-api/immich-openapi-specs.json`
- `packages/sdk/src/fetch-client.ts`
- `server/src/controllers/asset.controller.ts`
- `server/src/dtos/asset-deletion.dto.ts`
- `server/src/queries/asset.job.repository.sql`
- `server/src/queries/sync.repository.sql`
- `server/src/queries/trash.repository.sql`
- `server/src/repositories/asset-job.repository.ts`
- `server/src/repositories/asset.repository.ts`
- `server/src/repositories/sync.repository.ts`
- `server/src/repositories/trash.repository.ts`
- `server/src/services/asset.service.spec.ts`
- `server/src/services/asset.service.ts`
- `server/src/services/base.service.ts`
- `server/src/services/instant-trash-acceptance.spec.ts`
- `server/src/services/instant-trash-storage.spec.ts`
- `server/src/services/queue.service.ts`
- `server/src/services/storage.service.ts`
- `server/src/services/trash.service.spec.ts`
- `server/src/services/trash.service.ts`
- `server/src/types.ts`
- `server/test/medium/specs/repositories/permanent-deletion-derivatives.spec.ts`
- `server/test/medium/specs/services/authorized-deletion.spec.ts`
- `server/test/medium/specs/services/instant-trash-acceptance.spec.ts`
- `server/test/medium/specs/services/trash-retention-lifecycle.spec.ts`
- `server/test/medium/specs/services/trash-timeline.service.spec.ts`
- `server/test/repositories/asset.repository.mock.ts`
- `specs/2026-11-01-foto-build29-instant-trash-cleanup-design.md`
- `specs/testing/2026-11-01-foto-build29-instant-trash-cleanup.md`
