# FOTO Build 17 — финальная приёмка редактора

**Вердикт: READY_FOR_LOCAL_INTEGRATION — только ветка редактора.** Подтверждённых незакрытых
дефектов редактора по доступным Cloud-проверкам нет. Это не готовность всего Build 17 к production.

Задание: [Issue 3](https://github.com/docice545/gallery/issues/3) и уточнение владельца
от 21.10.2026, [PR 4](https://github.com/docice545/gallery/pull/4), оставлен открытым и не объединён.
Аудит начат на `c755c03cc8c9c560063e403fdac733971541f04b`; исправленный код:
`906ad0e6822cd2d85393f035b5a7e4d167f30152` (`codex/foto-build17-editor`).

PASS ниже означает именно указанную проверку компонентов/widget/raster. Проверки устройств,
настоящего NAS и inference перечислены отдельно; их результаты не подменены mock-результатами.
Неизменённые функции не перепроверялись без причины: прежние receipts и тестовые имена сохранены
в [evidence JSON](FOTO_BUILD17_EDITOR_EVIDENCE.json) и [отчёте](FOTO_BUILD17_EDITOR_TEST_REPORT.md).

## Матрица требований

Пути `pages/edit/…`, `utils/…` в колонке подтверждения относятся к `mobile/test/`.
Новые приёмочные проверки — [editor_acceptance_test.dart](mobile/test/pages/edit/editor_acceptance_test.dart).

| Требование | Файл / компонент | Подтверждение | Статус |
| --- | --- | --- | --- |
| Чёрный/очень тёмный экран независимо от внешней светлой темы | `edit.page.dart`: `EditImagePage.build`, `Scaffold`, `Theme` | Новые Android/iOS widget cases проверяют `Colors.black` и `Brightness.dark`; golden портрета | PASS |
| Верхние «Вернуть», «Сохранить», вертикальное ⋮ | `EditImagePage`, `_SaveEditsButton` | Реальные RU glyphs/расположение кнопок; `Icons.more_vert` на Android и iOS; подписи целиком, без пересечения и меньше 14 px в проверенных форматах не становятся | PASS |
| Фото максимально вписано с сохранением пропорций | `_EditorPreview`, `EditorViewport` | Новые четыре формата сравнивают реальные размеры/центр с `applyBoxFit`; прежние `decoded … fills available … area at every quarter-turn` повторно проходят в UI-регрессии | PASS |
| Шесть прокручиваемых разделов в точном порядке | `EditorModeBar`, `editor_mode.dart` | AI → Обрезка / поворот → Фильтры / коррекция → Рисование → Стикеры → Текст; `RenderParagraph.didExceedMaxLines=false` для всех RU подписей | PASS |
| Выбор раздела, жёлтая активная подпись | `EditorModeBar`: selected semantics / button style | Новые проверки переключают Рисование/Стикеры/Текст, проверяют `Colors.yellow`; прежние EN/RU циклы всех шести режимов повторно проходят | PASS |
| Safe-area и крупные touch targets | `SafeArea`, `_EditorBottomPanel`, `EditorModeBar` | 393×852, 852×393, 720×320, 320×720; реальные `FakeViewPadding`, текст 100/200%; полные кнопки вне insets, drawing targets ≥48×48; golden compact | PASS (симуляция) |
| Тёмно-серая плавающая pill над навигацией | `widgets/markup_controls.dart`: `MarkupControls` | Проверены цвет `#303030`, radius 32, положение выше rail, круглый selected background; golden | PASS |
| Синяя ручка, фиолетовый маркер, кисть, ластик, разделитель, undo, redo | `MarkupControls`, `EditImagePage.onTool` | Новая проверка точного порядка, `VerticalDivider`, blue/purple; прежний `six-section rail and drawing pill …` повторно проверяет реальный выбор marker с opacity .45 | PASS |
| Цвет, размер, прозрачность рисования | `MarkupControls`, `_setInk`, `AnnotationCanvas` | Прежние EN/RU widget cases меняют sliders, проверяют данные настоящего canvas; повторно проходят после layout-правки | PASS |
| Ластик удаляет только нарисованные линии | `AnnotationEditor`, `AnnotationCanvas` | Прежние `annotation_eraser_geometry_test.dart` и `editor_objects_test.dart`: линии под текстом/стикерами, геометрия и один undo; код не менялся | PASS |
| Текст: ввод/изменение, шрифт, цвет, размер, обводка/фон, opacity | `_promptText`, `_setTextStyle`, `MarkupControls`, `AnnotationPainter` | Прежние `text outline background size opacity and font …`, edit/cancel/empty/unchanged и text-after-transform повторно проходят; новый landscape golden содержит настоящие glyphs FOTO | PASS |
| Стикеры/emoji | `_addSticker`, `MarkupControls`, `AnnotationPainter` | Прежние `editor_objects_test.dart`: transformed vector/Unicode output; добавление star/heart через UI, слои и undo повторно проходят | PASS |
| Слои: выбор, порядок, удаление | `_layers`, `AnnotationEditor`, общий provider | `sticker layers select, reorder, delete and undo …` повторно проходит; неизменённые immutability/object tests сохранены | PASS |
| Жесты move / scale / rotate объекта | `AnnotationCanvas`, `annotation_editor.dart` | Прежние `editor_objects_test.dart`: two-finger transaction, cancel/retry, inverse source transform; код этих компонентов не менялся | PASS |
| Общая undo/redo/reset история | `editor.provider.dart`, `CropController` binding | Повторно проходят mode-switch, dirty state, undo/redo и reset к server baseline; прежние history/aspect cases и лимит 100 сохранены | PASS |
| Восемь коррекций: brightness, contrast, saturation, exposure, temperature, shadows, highlights, hue | `AdjustmentPanel`, `ColorAdjustment`, provider | Прежние `renders a visible … correction and preserves original pixels` для каждого ключа; общая матрица preview/export, исходники pipeline не менялись | PASS |
| Original + 32 фильтра, intensity и настоящие thumbnails | `constants/filters.dart`, `FilterPanel`, `FilteredImage` | Прежние catalog/boundaries и 32 raster comparisons при partial intensity; код фильтров/панелей не менялся | PASS |
| Предпросмотр соответствует экспорту | `_EditorPreview`, `ColorAdjustment`, `EditedImageExporter`, `AnnotationPainter` | Прежние filter/text/sticker pixel comparisons; `all display rotations and flips keep actual preview pixels and exported markup aligned` повторно проходит | PASS |
| Координаты zoom/pan/rotate/crop, resize, letterbox | `_EditorPreview`, `EditorViewport`, `AnnotationCanvas` | Повторно проходят реальные жесты two-finger navigation, transformed drawing/text, letterbox, resize и crop corners; прежние object/resize/eraser inverse-transform tests сохранены | PASS |
| JPEG/PNG, EXIF orientation | `EditedImageExporter`, original source provider | Прежние реальные synthetic PNG/JPEG Orientation=6 decode/export, исходные bytes неизменны; код декодирования/экспорта не менялся | PASS |
| Сохранение новой копии, оригинал не заменяется | `_loadOriginalImage`, `_saveCopy`, copy dialog | Повторно прошли 6 `editor_save_retry_test.dart`: PNG copy, decode fail, cancel, permission denied → retry; `applyEdits`/server mutation не вызываются | PASS (mock native API) |
| Ошибки, cancel, retry, bounds | `EditedImageExporter`, `_saveCopy`, состояние editor | Те же 6 повторных save cases; прежние deadline/listener cleanup, 32 MP bounds и source error tests; UI блокирует повторный save | PASS |
| AI-ластик остаётся отдельным от ластика штрихов | `_MagicEraserButton`, существующие route/repository/mask components | Повторный UI integration suite проверяет capability/retry/cancel, недоступность AI не ломает editor; eraser штрихов не запускает AI | PASS (интеграция) |
| AI mask/координаты, authenticated API и явная still-copy | `MagicEraserPage`, `MagicEraserRepository`, существующий mask controller | Прежние mask gesture/payload/auth/cancel/owner-error tests и 221 backend unit сохранены; AI-код, API и backend не менялись и повторно не расследовались | PASS (контракты/mocks) |

## Подтверждённые дефекты и минимальные исправления

1. `PopupMenuButton` без заданной иконки выбирал горизонтальное меню на iOS. Теперь явно `more_vert`.
2. Ограничение всей нижней панели половиной экрана не учитывало footer safe inset и крупный текст:
   в 720×320 при 200% кнопка выходила за settings viewport (bottom 236 против 223). Теперь высота
   учитывает rail, inset и минимум одной полной 48 px строки с padding; остальное остаётся фото.
3. `maxWidth:100` обрезал даже обычную подпись «Обрезка / поворот». В горизонтально прокручиваемой
   rail названия теперь получают естественную ширину.
4. RU подпись «Фильтры / тон» заменена требуемой «Фильтры / коррекция». Смысл существующего EN key
   и девяти остальных переводов проверен и не менялся; новых ключей нет.
5. При 200% фиксированные верхние slots обрезали «Вернуть». Заголовки действий теперь вписываются
   через `FittedBox.scaleDown`; при крупном тексте необязательная галочка Save уступает место подписи.
   Новые тесты проверяют видимые границы glyphs, отсутствие пересечения и эффективный размер ≥14 px.
   При обычном размере прежняя Save-иконка сохранена, существующие Save tests не изменялись.

Изменён runtime только `mobile/lib/presentation/pages/edit/edit.page.dart` и одна RU строка.
Ни один существующий тест не ослаблен/удалён. Прежде проходившие случаи не заменены новыми mock-ами.

## Фактически выполнено в этом аудите

- **73 PASS / 0 FAIL / 0 SKIP**: 10 новых acceptance cases + 57 прежних editor/AI integration
  cases + 6 прежних save/retry cases. Это осмысленный повтор из-за изменений общего UI и Save.
- После удаления двух лишних test imports: **10/10 PASS**, снова обычное сравнение трёх golden
  без `--update-goldens`. Это повтор тех же 10 cases, не ещё 10 новых тестов.
- Полный `flutter analyze --no-pub`: **PASS, No issues found**. Dart format / RU JSON Prettier /
  `git diff --check`: **PASS**.
- Прежние 357 различных Flutter / 221 backend / 46 automation cases повторно целиком не запускались.
  Совокупно редакторное покрытие содержит 367 различных Flutter cases, а не 357+73+10.
- Все тяжёлые команды последовательно через существующий runner/flock, concurrency=1, CPU ≤2.
  Production, backend/APK build, подпись, ML-модели, Memories и данные HP не затронуты.

Реальные отфильтрованные логи, SHA-256 и исходные runner receipts:
[evidence JSON](FOTO_BUILD17_EDITOR_EVIDENCE.json), [acceptance evidence](foto-editor-evidence/acceptance/).
Ранние reproducer FAIL и текущий финальный PASS различены, тестовые setup ошибки не названы
дефектами production. Tests выполнялись перед коммитом; receipt хранит фактический HEAD+dirty digest,
а hashes подтверждают идентичность проверенных файлов опубликованному коду.

## Golden / визуальный просмотр

Три эталона просмотрены после генерации, затем успешно сравнены в обычном test run:

- [RU portrait, рисование](mobile/test/pages/edit/goldens/editor_ru_draw_portrait.png);
- [RU landscape, текст и вырезы](mobile/test/pages/edit/goldens/editor_ru_text_landscape.png);
- [RU compact landscape, 200%](mobile/test/pages/edit/goldens/editor_ru_compact_large_text.png).

Это собственная UI на синтетической сетке цветов, не копия или pixel reference Samsung.
Использованы закреплённый Flutter 3.47.2, software renderer и уже имеющиеся GoogleSans/MaterialIcons.
Generic `sans-serif` для golden caption привязан к шрифту проекта, чтобы Ahem не скрывал glyphs.
Эталоны не доказывают тождество системных шрифтов, emoji и рендеринга на физических устройствах.
Длинное необязательное название режима в центре AppBar может сокращаться; три требуемых действия
остаются полными. Rail и settings прокручиваются; все инструменты не обязаны помещаться одновременно.

## Что требует устройства или отдельного non-production окружения

| Требование | Файл / компонент | Необходимое подтверждение | Статус |
| --- | --- | --- | --- |
| Реальные Samsung S23 cutouts/gesture navigation, TalkBack, background/resume, нагрузка | Flutter viewport / Android system UI | Установка позднее собранной объединённой APK; пройти те же режимы и реальные жесты | не проверено |
| Нативное сохранение Android/iOS, отказ Photos/MediaStore → разрешение → retry | `FileMediaRepository`, PhotoManager | Физическое устройство: одна новая копия, оригинал/настройки/backup не повреждены | не проверено |
| Системные serif/monospace/emoji и native codecs HEIC/HEIF/RAW | Platform fonts / image codec | Проверить действительно поддерживаемые форматы и glyphs на Android/iPhone; наличие NEF fixture само по себе не доказательство | не проверено |
| Настоящий Synology, загрузка новой PNG через backup, thumbnail/preview | Существующий backend / sync | Только после локального объединения, на отдельной синтетической тестовой библиотеке; сравнить hash оригинала | не проверено |
| Реальный Big-LaMa inference | Существующий безопасный sidecar | Только отдельное разрешённое non-production окружение, без установки моделей в рамках этого аудита | не проверено |
| Полный EXIF в новой PNG / новая движущаяся Motion-пара | Текущий экспорт | EXIF кроме запечённой ориентации не копируется; ручная замена Motion-пары не включена. Существующая AI still-copy сохранена | не реализовано, сохранённая граница scope |
| Мобильный браузер | Flutter mobile export / существующий Svelte editor | Mobile export зависит от dart:io/PhotoManager; web-экспорт не добавлялся и не заявляется | не поддерживается этим стеком |

Для локального объединения использовать [HP handoff](FOTO_BUILD17_EDITOR_HP_HANDOFF.md).
Никаких HP-команд, изменения canonical manifest, merge, production deployment или реальных
операций с фотографиями этот аудит не выполнял. Общие ошибки CI и другие подсистемы не дорабатывались.
