# FOTO Build 33: мгновенное принятие удаления выбранных объектов корзины

База: `89c33ff3ee30b52a05df58a6373f2cc56c92ef49`, опубликованная ветка
`integration/foto-build32-checkpoint`.
Рабочая ветка: `codex/foto-build33-selected-trash-acceptance`.

Работа по Android MediaStore отменена владельцем и в этот патч не включена.
Production, реальные медиа, контейнеры, серверная БД и APK не затрагивались.

## Причина и реальные точки входа

Серверный механизм Build 29 уже имеется: `AssetService.acceptPermanentDeletion`
→ `AssetApiRepository.acceptPermanentDeletion` → `acceptOnly: true` → долговременные
receipts. «Очистить всю корзину» в `TrashKebabMenu` уже использует этот путь.

Выбранные объекты шли через другой путь:

- `TrashBottomBar` → `ActionColumnButton(DeleteAction(source: timeline))`;
- меню действий → `ActionMenuItem(DeleteAction)`;
- нижняя панель просмотрщика → `DeleteAction(source: viewer)`.

При `trash == false` общий `DeleteAction._deletePermanently` вызывал
`deleteWithResults` и требовал физического `result.complete`. API ожидал worker
через `_waitForDeletionBatch`. Поэтому наличие мгновенного механизма в четырёх
основных файлах Build 29 не исправляло этот отдельный action.

`BatchDeletionController`/`BatchDeletionDialog` остаются в `trash.page.dart`, но
поиск всех вызовов в `mobile/lib` обнаруживает только их объявления. Текущие
пользовательские пути их не создают. Совместимый legacy completion API и его
изолированный тест сохранены; этот патч не переводит неиспользуемый код в новый
сценарий и не переписывает очередь.

## Минимальное исправление

Runtime изменён только в `mobile/lib/presentation/actions/delete.action.dart`.

1. После прежнего подтверждения необратимого удаления вызывается существующий
   `acceptPermanentDeletion` с точным снимком выбранных UUID.
2. Успех определяется `result.accepted`. Просто `pending`, `queued` и HTTP 200
   без подтверждения не дают зелёный результат. `accepted` может оставаться true
   при pending/failed физической обработке: это подтверждение необратимого решения,
   а не физического завершения.
3. Сервис сам сохраняет pending intent и удаляет из Drift только достоверно
   подтверждённые строки. Его durability/replay/owner/server/checksum-защита не
   изменена.
4. Action дополнительно снимает с выделения только принятые UUID. Отклонённые
   элементы и добавленный во время запроса другой selection сохраняются. При
   полном подтверждении показывается зелёный toast; при частичном — существующее
   сообщение об ошибке с accepted/remaining.
5. Новый локализованный текст явно относится к выбранным объектам, не утверждает
   очистку всей корзины или завершение unlink. Добавлен один ключ в 10 обязательных
   локалях; остальные тексты не менялись.
6. Общий guard action source предотвращает второе подтверждение/запрос через
   сохранённый callback либо другую кнопку/меню, пока первый снимок ожидает ответа.
   Прежний async spinner кнопок действует до acceptance. UI физического прогресса
   и polling в этом пути отсутствуют.
7. Undo или отмена после принятия не предлагаются. Отмена до отправки запроса
   оставляет selection и не вызывает сервер.

Потерю ответа после commit разрешает существующая per-ID receipt-проверка API.
Если достоверного ответа нет, сервис сохраняет uncertain intent и не скрывает
объект как успешно принятый. Уже принятый marker блокирует Restore, сохраняется
при перезапуске и не снимается повторным sync.

Размеры существующих запросов сохранены: preflight/status — до 200 ID, admission
— до 5000. Поэтому 500 элементов дают preflight 200/200/100 и один acceptOnly
запрос; это не legacy физическое batch-удаление. Для 5001 элементов проверены
последовательные admission 5000/1. Для 5201 проверена потеря второго ответа после
commit и восстановление через status 200/1. Новых серверных ограничений или очередей нет.

Обычный перенос в корзину, cloud/device/everywhere, локальное подтверждение Android,
раскрытие Stack только в основной ленте и защита чужих assets сохранены. Принятие
удаления из серверной корзины не запускает MediaStore cleanup.

## Проверки Cloud

| Проверка                                        | Результат                                         |
| ----------------------------------------------- | ------------------------------------------------- |
| Точное совпадение remote HEAD с указанной базой | PASS                                              |
| Профильная Flutter regression, 14 файлов        | **230 PASS**, без skipped/FAIL                    |
| Полный `flutter analyze --no-pub`               | PASS, No issues found                             |
| Генерация и lockfile                            | PASS; Flutter 3.47.2, без обновления зависимостей |
| `dart format` изменённых Dart-файлов            | PASS, 5 файлов, 0 изменений                       |
| Форматирование 10 локалей                       | PASS                                              |
| `git diff --check`                              | PASS                                              |
| Реальный production backend / NAS / Android     | NOT TESTED, не использовались                     |
| APK / Build 34 / deployment                     | NOT RUN                                           |

Добавлены 14 widget-сценариев и 5 API/Drift-сценариев. В итоговые 230 входят:
1/несколько/500 объектов, accepted pending и accepted failed, частичный отказ,
server rejection, queued без proof, потеря ответа после commit, последовательные
запросы, повторное нажатие и retained callback, меню, viewer, уход со страницы,
отмена подтверждения, отсутствие MediaStore/Stack expansion и Undo. Реальная
тестовая SQLite проверяет реактивную корзину для 500/частичных 307 принятых объектов,
сохранность остальных элементов и запрет Restore. Существующие restart/sync/receipt
тесты также включены в прогон. Widget API моки не выдаются за production E2E.

Команда из `mobile/` после штатной генерации проекта:

```bash
flutter analyze --no-pub
flutter test --no-pub --concurrency=2 \
  test/unit/presentation/actions/delete_action_test.dart \
  test/unit/presentation/actions/instant_selected_trash_acceptance_test.dart \
  test/unit/presentation/actions/restore_action_test.dart \
  test/domain/services/instant_trash_acceptance_service_test.dart \
  test/infrastructure/repositories/instant_trash_acceptance_test.dart \
  test/presentation/pages/instant_trash_cleanup_test.dart \
  test/repositories/permanent_deletion_api_repository_test.dart \
  test/repositories/asset_trash_api_repository_test.dart \
  test/infrastructure/repositories/trash_pending_operations_test.dart \
  test/infrastructure/repositories/trash_deletion_timeline_test.dart \
  test/infrastructure/repositories/trash_sync_visibility_test.dart \
  test/infrastructure/repositories/confirmed_remote_deletion_test.dart \
  test/presentation/pages/trash_kebab_menu_test.dart \
  test/presentation/pages/trash_batch_deletion_dialog_test.dart
```

## Отдельная физическая проверка после разрешения владельца

Только на выделенных синтетических тестовых фотографиях и тестовом владельце:

1. Выделить 1, несколько и 500 объектов корзины, подтвердить, проверить spinner
   до acceptance, немедленное скрытие и зелёный toast при pending physical status.
2. На staging остановить только физический worker и убедиться, что пользовательский
   успех не ждёт unlink. Затем безопасно возобновить существующий worker и сверить
   final receipts. Production worker в ходе Cloud-разработки не останавливался.
3. Проверить offline/rejection/lost-response и частичный отказ. Оставшиеся элементы
   доступны для повторной проверки, принятые не восстанавливаются после sync/restart.
4. На физическом Android 16 проверить нижнюю панель, меню, просмотрщик, быстрые
   повторные taps, возврат на страницу и отсутствие неожиданного запроса удаления
   Samsung MediaStore. Физический оригинал телефона этим сценарием не удаляется.

Мозаика Google Photos, заголовки/прокрутка и патч без `_ScrollLabel` не изменены.
Никакие `.pre-*`, untracked-файлы, резервные копии, keystore/applicationId или
номер версии не удалялись и не менялись. Откат патча возвращает прежний мобильный
action; он не отменяет уже зафиксированные сервером решения об удалении.

## Изменённые файлы

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
- `mobile/lib/presentation/actions/delete.action.dart`
- `mobile/test/infrastructure/repositories/instant_trash_acceptance_test.dart`
- `mobile/test/repositories/permanent_deletion_api_repository_test.dart`
- `mobile/test/unit/presentation/actions/delete_action_test.dart`
- `mobile/test/unit/presentation/actions/instant_selected_trash_acceptance_test.dart`
- `specs/testing/2026-11-02-foto-build33-selected-trash-acceptance.md`
