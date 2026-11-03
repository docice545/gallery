# Issue 18: синхронизация требований и результаты продолжения


Повторно прочитаны полные актуальные Issue 17 (обновление 21:47 МСК), Issue 18 и PR 16.
API теперь доступен. PR 16 по-прежнему draft/open, HEAD fda0ef200, не merged;
REST reviews=0, inline comments=0; GraphQL reviewThreads.totalCount=0,
hasNextPage=false. Проверка branch protection получает HTTP403 Resource not accessible by integration:
наличие workflow не означает включённые required checks в настройках репозитория.
Прежние замечания о недоступном API в исходном аудите описывают первоначальный снимок, а не текущее состояние.

Build 37 origin остаётся на 6c8882bbf2bfd69dfd8984342c142db25b45f223. Его mobile/ побайтово
совпадает с PR 16. Локальные неопубликованные изменения другого Codex этой проверкой не видны.
Android UI в этой ветке не изменяется. Ниже расхождения для владельца Issue 17:

| Требование владельца | Фактическая реализация на опубликованном Build 37 | Оставшаяся работа |
| --- | --- | --- |
| 1. Компактный Samsung-style Viewer **и редактор**, иконки без подписей | Частично: существующие engine/undo/redo/Save Copy есть, но EditAssetAction открывает EditImageRoute; edit.page.dart сохраняет _EditorBottomPanel и EditorModeBar с Text под иконками (около строки 1028) | Реальный компактный editing workspace, без обёртки над старой панелью; сохранить команды/edits/accessibility; изучить PR 4/6 в UI-треке |
| 2. Swipe только раскрывает красную корзину | **Не соответствует:** album_selector.widget.dart:622 использует Dismissible, confirmDismiss сразу открывает showDialog; onDismissed вызывает deleteAlbum | Отдельный reveal-state и tap action; swipe-only/back/cancel/rapid gestures не вызывают destructive callback |
| 3. Все поддерживаемые списки, включая «На этом устройстве» | Не выполнено: LocalAlbumsPage использует LargeLeadingTile без reveal; remote grid и space album surfaces не имеют общей подтверждённой реализации | Инвентарь owned/shared/device/grid/list и единый согласованный action; основную ленту не переделывать |
| 4. Один FOTO confirm → соответствующий Trash, без дополнительных backup/окон и permanent delete | Частично: device CleanupLocalAction и album cleanup имеют OS consent, per-ID ACK и проверки snapshot. Однако remote deleteAlbum удаляет album metadata и не эквивалентен переносу media в Trash; новый swipe contract не реализован | Согласовать безопасную карту album→assets, device/server scope, права, partial/deny. Не обещать everywhere-delete там, где он не поддержан. Системный Android consent сохраняется |
| 5. Компактное уведомление перед Years/Months/All **по z-order** | Частично: ToastService/ScaffoldMessenger и grouping footer/pill существуют; новая геометрия и порядок слоёв не доказаны | Уведомление полностью читаемо поверх control; после исчезновения control работает. Не подменять z-order требованием физически разместить выше |
| 6. Один tap не выбирает посторонние фото | Не подтверждено исправление: tap toggle и index-based drag range существуют, новых Build 37 изменений нет | Воспроизведение, точные IDs на tap и повторная валидация перед confirm; rapid scroll/refresh/date-header/album transitions. Причину не объявлять установленной |
| 7. Ровно 2→1: оставшийся кадр standalone | Частично: AssetStackRow скрывается при length<2; Build 36 сохраняет persisted membership для restore. Требование dissolve и отсутствие возврата после sync/restart целиком не выполнено | UI и persisted contract согласовать с backend/restore без удаления последнего оригинала; cover/non-cover/offline/error/restart |
| 8. Timeline Live Photo non-regression | Source fix PR16 сохранён; на SHA 86eeb429f **оба новых CI gate PASS**, в том числе настоящий ExoPlayer и цепочка selected→native-ready→play-request-accepted→position-advanced | Samsung cold start, все 8 сценариев, визуальное движение и 120 Hz profile остаются NOT TESTED; релиз блокируется |

Источник для таблицы — тот же mobile/ tree PR 16 и Build 37. Ключевые файлы:
`mobile/lib/presentation/pages/edit/edit.page.dart`, `presentation/actions/edit_asset.action.dart`,
`presentation/widgets/album/album_selector.widget.dart`, `presentation/pages/local_album.page.dart`,
`domain/services/remote_album.service.dart`, `presentation/widgets/asset_viewer/asset_stack.widget.dart`,
`presentation/widgets/timeline/timeline_drag_selection.dart`, `services/toast.service.dart`,
`mobile/packages/ui/lib/src/snackbar.dart`.

### CI SHA 86eeb429f: все jobs проверены через API

Run: https://github.com/docice545/gallery/actions/runs/41694382792

- pre-job: PASS.
- Live Photo timeline non-regression: PASS, 5m18s.
- Live Photo native decoded motion: PASS, реальный emulator, 15m40s.
- Release artifact and provenance checks: PASS, 51s.
- Flutter tests and coverage: **FAIL, 5871 pass / 6 fail** (GitHub annotations).
- Verify or explicitly release iOS: queued, результат отсутствует.
- Build and sign Android: skipped, ожидаемая safety policy для push.
- Unsigned universal Android: skipped, текущая lane запускается на PR; это не успешная APK-сборка.

Полные job logs перенаправляются API на productionresultssa2.blob.core.windows.net, который пока
не разрешён сетевой политикой среды. Диагноз шести Flutter failures ещё не установлен.
Добавление домена в прежний опубликованный environment draft отклонено как draft_not_editable;
настройка доступа к этому storage host не сохранена. Проверки не ослабляются ради зелёного CI.


## Переиспользованные исправления и проверка

| Оригинал integration | Коммит этой ветки | Проверенная область |
| --- | --- | --- |
| 67b424c70 | 238ce222d | Optional acceptOnly/accepted без замены immutable schema baseline |
| 9bc0a9b50 | eef57e7fe | Build 36 metadata, Android explicit branch/source guards и Java из mise |
| 643d0a79e | 52ceed56e | Packaged Web/CLI/WASM и BuildKit manifest digest |
| 3482120f1 | 965c80c8a | Build 35 migration baseline 0c8be5421 |

Перенос сделан cherry-pick -x, без git merge. Commit 9bc0a9b50 также содержит iOS explicit-branch
helper: это пересечение было неполно указано в первом аудите. В двух пересекающихся iOS files
сохранена уже проверенная реализация audit-ветки с дополнительным dispatch branch match и legacy
receipt guards; повторный helper/набор одинаковых тестов не добавлен. Android UI не изменён.

После переноса на 965c80c8a:

- API contract suites: **14 PASS / 2 files**. Прежний воспроизведённый schema mismatch устранён
  переиспользованным тестовым исправлением. Это не новая реализация Backend API и не подтверждение
  полной совместимости установленного клиента.
- `scripts/release/tests`: **509 PASS, 17 SKIP, 526 total**. Это fixtures/guards; строки PASS,
  печатаемые синтетическими mocks, не являются выполненной production миграцией или подписью.
- `server_build.sh --check`, explicit migration baseline 0c8be5421: source 965c80c8a,
  version 5.7.3, build 36, schemaDelta NONE_FROM_MIGRATION_BASE. Docker не запускался этим check.
- Старые 61 disposable-PG и 197 targeted-Web PASS относятся к исходному fda0ef200;
  runtime Backend/Web с тех пор не изменён. Они не переименованы в новый полный CI PASS.

Найден дополнительный metadata gap: root Build Mobile применял branding без version/build inputs,
тогда как Gallery workflow уже сохранял committed metadata. Root unsigned IPA мог получить build 1
по fallback action. Переиспользован существующий source-metadata подход Gallery; добавлена защита
в workflow-scope regression. Это не результат native сборки; iOS receipt всё равно проверяет bytes.

CI запускает существующие release tool tests и добавляет audit branch в push triggers Test/Static
Code Analysis. Так exact-source release gate может проверить эту ветку без merge; PR merge-SHA
не подменяет source SHA. Все добавленные lanes используют hosted runners.

Follow-up validation: 123 mobile-tool fixtures PASS, 21 workflow-scope tests PASS;
YAML formatting, shell syntax всех документированных HP-команд и ссылки отчёта проверены.
На трёх изменённых workflows actionlint после раскрытия aliases имеет то же одно inherited
required+default замечание, что baseline 86eeb429f; новых замечаний нет.
[Машиночитаемые результаты](foto-2026-11-03/resync-checks.json) сохраняют SHA256 локальных logs
и отдельные результаты GitHub jobs; это не hashes release artifacts.

## Дополнительные воспроизведённые CI-сбои и исправления

Draft PR: https://github.com/docice545/gallery/pull/19, base Build 36 PR16 branch;
Issue17 не закрывается этим PR. На опубликованном SHA 19b817850 PR Docker compilation прошёл
для server и CPU ML без registry push. OpenAPI Clients, Migration Order и Zizmor PASS;
PR label validation PASS после добавления changelog:bugfix. Это отдельные результаты,
не полный зелёный CI и не production artifacts.

- ShellCheck: воспроизведены 16 замечаний в пяти shell scripts; исправлены quoting/arrays,
  ERR trap и отрицательная grep-проверка. `! grep` под `set -e` мог продолжить smoke после
  обнаружения ошибки. Теперь явная функция отказывает и при error screen, и при unreadable capture;
  regression исполняет эту функцию с синтетическими XML, без ADB. ShellCheck 0.11.0: **58 файлов PASS**.
- Release tooling: default shallow checkout не содержит Build35 ancestor для существующего
  теста 175 миграций. Изолированное воспроизведение depth=1 → FAIL, полная история → PASS.
  Включён fetch-depth: 0 только для этого job; тест сохранён.
- SQL Schema Checks: стадия generation/migrations PASS, но query snapshots устарели относительно
  runtime PR16. Пересборка текущего server и генерация на отдельном пустом cloud PostgreSQL 14
  воспроизвели расхождение двух файлов: asset HAVING count>1 и Trash stack locks/RETURNING.
  Коммит f43cfb2a7 обновляет только generated SQL. Повторная генерация совпала со всеми **41 SQL files**
  (738 recorded queries); disposable container удалён. Ни HP, ни реальные данные не затронуты.
- Release checker: overall green workflow недостаточен. Добавлена отдельная проверка всех
  обязательных jobs точного attempt, включая full Flutter, release tooling и compatibility suites.
  Skipped/missing/duplicate/failed job блокирует выпуск. Push main/release/audit запускает полные
  проверки даже при docs-only diff; это осознанное увеличение CI работы ради exact-source evidence.
- Static Code Analysis SHA19b: **Run analyze PASS**, **Run format FAIL**. Точный список файлов
  остаётся недоступен без полного лога. Format task проверяет mobile/lib, runtime которого эта
  ветка не меняла. Это не доказанный дефект добавленных test files и не повод ослабить форматтер.

Локально после исправлений: **125 mobile-tool tests PASS; 510 release-tool tests PASS / 17 SKIP;
21 scope tests PASS**. Skips — отдельные opt-in Docker/JDK checks; они не засчитаны как выполненные.
YAML Prettier PASS. Actionlint трёх workflows: то же одно inherited required+default замечание,
что и 86eeb429f, без новых. Последний commit требует отдельного GitHub run; старые green результаты
не переносятся на новый SHA. Полная таблица текущих GitHub jobs публикуется в Issue18, чтобы не
создавать новый source SHA только ради обновления статусов.

## Статус A–D и открытые условия

| Этап | Статус | Предел |
| --- | --- | --- |
| A аудит | Выполнено и опубликовано | Runtime/device и restricted branch-protection evidence явно отделены от source audit |
| B адресные исправления | Частично | Проверены source/release fixes; Full Flutter/format blockers пока не диагностированы из-за log-host block; UI gaps переданы владельцу Issue 17 |
| C CI | Частично | Оба Live Photo gate PASS на 86eeb429f; полный Flutter/format FAIL; iOS без completed receipt; новые изменения требуют своего run. Protection API 403 |
| D handoff | Частично | [Команды и критерии](../testing/2026-11-03-foto-build36-reproducible-handoff.md) подготовлены; новых release image/APK/IPA bytes и физических receipts нет |

Аудит опубликован: https://github.com/docice545/gallery/issues/18#issuecomment-6612841556.
Любой последующий candidate SHA получает собственный CI статус. Samsung, iPhone/SideStore,
120 Hz, upgrade 35→36, HP live schema и backup restore остаются незавершёнными. **Production NO-GO.**
