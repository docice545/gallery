# FOTO Build 17 — приёмка редактора

**READY_FOR_LOCAL_INTEGRATION — редактор, не весь release.**
Ветка `codex/foto-build17-editor`, [PR 4](https://github.com/docice545/gallery/pull/4),
получать `cf2cca55b8187fbf91582048dc1ed6d4d1138ec2`.
Проверенный UI-код `906ad0e6822cd2d85393f035b5a7e4d167f30152`.
Это сохранённые результаты выполненной приёмки, не выдуманный новый прогон.

[Полная исходная таблица и golden](https://github.com/docice545/gallery/blob/cf2cca55b8187fbf91582048dc1ed6d4d1138ec2/FOTO_BUILD17_EDITOR_ACCEPTANCE.md),
[evidence/receipts/SHA-256](https://github.com/docice545/gallery/blob/cf2cca55b8187fbf91582048dc1ed6d4d1138ec2/FOTO_BUILD17_EDITOR_EVIDENCE.json).
Тесты не повторялись без изменения редактора. Дедупликация вынесена в другой PR.

## Требование → компонент → подтверждение

Пути исходников ниже относительно `mobile/lib/`; имена тестов — `mobile/test/`.

| Требование                                                                           | Файл/компонент                                    | Подтверждение                                                                                       | Статус                                                          |
| ------------------------------------------------------------------------------------ | ------------------------------------------------- | --------------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| Тёмный фон, fit фото, верхние Вернуть/Сохранить/вертикальное ⋮                       | `presentation/pages/edit/edit.page.dart`          | Android/iOS widget variants; четыре размера; real glyph bounds; portrait/landscape goldens          | PASS — Flutter renderer                                         |
| Шесть разделов, точные RU подписи, жёлтый активный режим                             | `EditorModeBar`, `editor_mode.dart`               | 10 acceptance cases, порядок/цвет/полнота названий, no ellipsis                                     | PASS                                                            |
| Safe-area, крупный текст и targets                                                   | `_EditorBottomPanel`, SafeArea                    | 393×852, 852×393, 720×320, 320×720; 100/200%; drawing targets ≥48×48                                | PASS — simulated insets                                         |
| Плавающая drawing pill, blue pen/purple marker/brush/stroke eraser/divider/undo/redo | `widgets/markup_controls.dart`                    | Exact order/styles/radius, actual tool selection, visible bounds и golden                           | PASS                                                            |
| Текст/fonts/color/size/outline/background/opacity                                    | `AnnotationCanvas`, `AnnotationPainter`, controls | Object raster comparisons, edit/cancel/retry; landscape text golden                                 | PASS — project/test fonts                                       |
| Stickers/emoji, selection/layers/gestures                                            | `annotation_editor.dart`, canvas/provider         | Move/scale/rotate, layer order/delete, Unicode raster, cancel                                       | PASS — synthetic widgets/pixels                                 |
| Undo/redo/reset, aspect/crop history                                                 | `editor.provider.dart`, CropController binding    | Atomic aspect transaction, bounded history, dirty state, baseline reset                             | PASS                                                            |
| Восемь коррекций                                                                     | `utils/color_adjustment.dart`, AdjustmentPanel    | Восемь visible raster corrections, unchanged source bytes                                           | PASS                                                            |
| Original + 32 фильтра/intensity/thumbnails                                           | `constants/filters.dart`, FilterPanel             | Catalog/bounds, 32 partial-intensity preview/export pixel comparisons                               | PASS                                                            |
| Source coordinates zoom/pan/rotate/crop/resize                                       | viewport/canvas/exporter                          | Реальные gestures + inverse transforms + transformed text/sticker/drawing pixels                    | PASS — Flutter renderer                                         |
| Save-copy, original preservation, failure/cancel/retry                               | `_saveCopy`, `EditedImageExporter`                | 6 repeated save/retry cases; no `applyEdits`/server replacement                                     | PASS — mock native save                                         |
| AI-ластик: UI/API/mask integration, independent stroke eraser                        | existing MagicEraser route/repository             | 57 editor integration cases и прежние API/mask/backend contracts; старый инцидент не расследовался  | PASS — integration/mocks, не inference                          |
| JPEG/PNG/EXIF orientation                                                            | exporter/loader                                   | Synthetic PNG/JPEG Orientation=6; pixels/source preservation                                        | PASS                                                            |
| Android/iPhone native Photos/MediaStore, device codecs/fonts/emoji                   | platform APIs                                     | Нужны реальные устройства после локального merge                                                    | NOT VERIFIED                                                    |
| Физические cutouts, TalkBack, background/resume, производительность                  | system UI/native lifecycle                        | Widget insets не заменяют S23/iPhone                                                                | NOT VERIFIED                                                    |
| Реальный Synology upload/backup и thumbnail/preview новой copy                       | shared backend/backup                             | Нужна отдельная synthetic test library, original hash до/после                                      | NOT VERIFIED                                                    |
| Реальный Big-LaMa inference                                                          | existing non-production sidecar                   | В этом acceptance не запускался; модели не устанавливались                                          | NOT VERIFIED                                                    |
| Полный EXIF в PNG / ручное редактирование Motion pair                                | export policy                                     | Кроме запечённой ориентации EXIF не копируется; Motion manual edit отключён, AI still-copy сохранён | NOT VERIFIED как расширенная функция; не заявлена реализованной |
| Browser export                                                                       | mobile dart:io/PhotoManager                       | Этот Flutter mobile стек его не предоставляет; Svelte editor не менялся                             | NOT VERIFIED / не поддерживается этим стеком                    |

## Исправления и фактические результаты

Пять подтверждённых UI-дефектов исправлены: iOS horizontal menu; compact landscape clipping
инструментов; обрезанные rail labels; «Фильтры / тон» вместо «Фильтры / коррекция»; обрезанный
крупный «Вернуть». Ни один старый regression test этим финальным UI-аудитом не ослаблен.

- **73 PASS / 0 FAIL / 0 SKIP**: 10 новых + 57 editor/AI integration + 6 save/retry.
- После удаления двух unused test imports **10/10 PASS**, три обычных golden comparisons.
- Полный Flutter analyze редакторной ветки **PASS, No issues found**.
- Совокупное scoped Flutter evidence **367 различных cases**; 73/10 — перекрывающиеся прогоны,
  не дополнительные уникальные тесты. Прежние 221 backend unit / 46 automation PASS сохранены.
- Исторический full Mobile CI 4985 PASS / 1 SKIP / 0 FAIL относится к `bbd8c5a7a`, а не к свежему
  unified HEAD. Глобальные CI failures перечислены в `LOCAL_INTEGRATION_HANDOFF.md`.

Три golden — собственные UI эталоны, software renderer Flutter 3.47.2, synthetic raster,
существующие GoogleSans/MaterialIcons. Это **не** pixel reference Samsung и не доказательство
идентичного native rendering. Реальные ограничения перечислены выше, а не отмечены PASS.

Новая APK, backend image, production signing и merge не выполнялись. Оригиналы NAS/Immich,
Memories и HP state не затрагивались. Канонические HP progress/pending/manifest не доступны,
поэтому Cloud не заменял их фиктивной историей. После получения обеих веток следовать
`LOCAL_INTEGRATION_HANDOFF.md`, повторить обязательные проверки на фактическом merged HEAD.
