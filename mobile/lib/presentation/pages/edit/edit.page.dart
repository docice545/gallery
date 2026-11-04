import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:auto_route/auto_route.dart';
import 'package:crop_image/crop_image.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/aspect_ratios.dart';
import 'package:immich_mobile/domain/models/annotation.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/asset_edit.model.dart';
import 'package:immich_mobile/domain/services/edited_copy.service.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/pages/edit/annotation_canvas.dart';
import 'package:immich_mobile/presentation/pages/edit/editor.provider.dart';
import 'package:immich_mobile/presentation/pages/edit/editor_mode.dart';
import 'package:immich_mobile/presentation/pages/edit/editor_viewport.dart';
import 'package:immich_mobile/presentation/pages/edit/magic_eraser.page.dart';
import 'package:immich_mobile/presentation/pages/edit/widgets/adjustment_panel.dart';
import 'package:immich_mobile/presentation/pages/edit/widgets/editor_chrome.dart';
import 'package:immich_mobile/presentation/pages/edit/widgets/editor_dock.dart';
import 'package:immich_mobile/presentation/pages/edit/widgets/filter_panel.dart';
import 'package:immich_mobile/presentation/pages/edit/widgets/filtered_image.dart';
import 'package:immich_mobile/presentation/pages/edit/widgets/markup_controls.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon_mapping.dart';
import 'package:immich_mobile/presentation/widgets/images/remote_image_provider.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/haptic_feedback.provider.dart';
import 'package:immich_mobile/repositories/file_media.repository.dart';
import 'package:immich_mobile/utils/annotation_editor.dart';
import 'package:immich_mobile/utils/edited_image_exporter.dart';
import 'package:immich_mobile/utils/editor_geometry.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:immich_mobile/widgets/common/immich_toast.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart' show AssetEntity;

export 'editor_mode.dart';

@RoutePage()
class EditImagePage extends ConsumerStatefulWidget {
  final Image image;
  final Future<void> Function(List<AssetEdit> edits) applyEdits;
  final RemoteAsset? asset;

  const EditImagePage({super.key, required this.image, required this.applyEdits, this.asset});

  @override
  ConsumerState<EditImagePage> createState() => _EditImagePageState();
}

class _EditImagePageState extends ConsumerState<EditImagePage> with TickerProviderStateMixin {
  final _log = Logger('MagicEraserCopySync');
  final _annotations = AnnotationEditor();
  late EditorMode _mode;
  AnnotationTool _tool = AnnotationTool.pen;
  Color _color = Colors.blue;
  double _strokeWidth = 5;
  double _opacity = 1;
  String? _selectedId;
  bool _cancelSave = false;
  bool _writingCopy = false;
  AssetEntity? _pendingCopy;
  EditedCopyService? _pendingImporter;
  bool _settingsExpanded = false;
  bool _straightening = false;
  bool _magicEraserOpen = false;
  final _previewKey = GlobalKey();
  Offset? _lastPhotoPoint;
  Completer<void>? _cancelLoad;
  AnnotationElement _textStyle = AnnotationElement(
    id: 'text-style',
    tool: AnnotationTool.text,
    points: const [Offset.zero],
    color: Colors.blue,
    width: 1,
    opacity: 1,
    fontFamily: 'sans-serif',
  );

  AnnotationElement? get _selected => _annotations.elements.where((element) => element.id == _selectedId).firstOrNull;

  void _reset() {
    ref.read(editorStateProvider.notifier).resetEdits();
    setState(() => _selectedId = null);
  }

  void _setTextStyle(AnnotationElement style) {
    _textStyle = style;
    final selected = _selected;
    if (selected != null && selected.isText) {
      _annotations.update(
        selected.copyWith(
          fontSize: style.fontSize,
          fontFamily: style.fontFamily,
          outlineColor: style.outlineColor,
          outlineWidth: style.outlineWidth,
          backgroundColor: style.backgroundColor,
        ),
      );
      _syncAnnotationDirty();
    }
    setState(() {});
  }

  void _setInk({Color? color, double? opacity}) {
    _color = color ?? _color;
    _opacity = opacity ?? _opacity;
    final selected = _selected;
    if (selected != null && (selected.isCaption || _tool == AnnotationTool.move)) {
      _annotations.update(selected.copyWith(color: color, opacity: opacity));
      _syncAnnotationDirty();
    }
    setState(() {});
  }

  void _addSticker(String sticker) {
    final element = AnnotationElement(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      tool: AnnotationTool.sticker,
      points: const [Offset(.4, .4)],
      color: _color,
      width: 1,
      opacity: _opacity,
      text: sticker,
      fontSize: .2,
    );
    _annotations.add(element);
    _syncAnnotationDirty();
    setState(() {
      _selectedId = element.id;
      _tool = AnnotationTool.move;
    });
  }

  Future<void> _layers() async {
    await showDialog<void>(
      context: context,
      builder: (context) => Theme(
        data: Theme.of(context),
        child: Dialog(
          alignment: Alignment.bottomCenter,
          insetPadding: EdgeInsets.fromLTRB(12, 12, 12, MediaQuery.paddingOf(context).bottom + 64),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: StatefulBuilder(
              builder: (context, update) => SafeArea(
                child: SizedBox(
                  height: 216,
                  child: Column(
                    children: [
                      Text(context.tr('editor_layers')),
                      Expanded(
                        child: ListView(
                          children: [
                            for (final element in _annotations.elements.reversed)
                              ListTile(
                                key: ValueKey('editor-layer-${element.id}'),
                                selected: _selectedId == element.id,
                                title: Text(
                                  element.isText
                                      ? element.text!
                                      : element.isSticker
                                      ? context.tr('editor_stickers')
                                      : context.t.editor_draw,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onTap: () {
                                  setState(() {
                                    _selectedId = element.id;
                                    _mode = element.isText
                                        ? EditorMode.text
                                        : element.isSticker
                                        ? EditorMode.stickers
                                        : EditorMode.draw;
                                    _tool = AnnotationTool.move;
                                  });
                                  Navigator.pop(context);
                                },
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      tooltip: context.tr('editor_layer_up'),
                                      icon: FotoIcon(
                                        kind: FotoIconKind.layerUp,
                                        semanticLabel: context.tr('editor_layer_up'),
                                      ),
                                      onPressed: () {
                                        _annotations.reorder(element.id, _annotations.elements.indexOf(element) + 1);
                                        _syncAnnotationDirty();
                                        update(() {});
                                      },
                                    ),
                                    IconButton(
                                      tooltip: context.tr('editor_layer_down'),
                                      icon: FotoIcon(
                                        kind: FotoIconKind.layerDown,
                                        semanticLabel: context.tr('editor_layer_down'),
                                      ),
                                      onPressed: () {
                                        _annotations.reorder(element.id, _annotations.elements.indexOf(element) - 1);
                                        _syncAnnotationDirty();
                                        update(() {});
                                      },
                                    ),
                                    IconButton(
                                      tooltip: context.tr('editor_delete_layer'),
                                      icon: FotoIcon(
                                        kind: FotoIconKind.trash,
                                        semanticLabel: context.tr('editor_delete_layer'),
                                        state: FotoIconState.destructive,
                                      ),
                                      onPressed: () {
                                        _annotations.remove(element.id);
                                        _syncAnnotationDirty();
                                        update(() {});
                                        setState(() => _selectedId = null);
                                      },
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _annotations.replaceAll(ref.read(editorStateProvider).annotations);
    _mode = widget.asset?.isStillCopyEditable ?? true ? EditorMode.crop : EditorMode.magicEraser;
    _settingsExpanded = false;
  }

  Future<void> _openMagicEraser() async {
    if (_magicEraserOpen || _pendingCopy != null || ref.read(editorStateProvider).isApplyingEdits) {
      return;
    }
    _magicEraserOpen = true;
    try {
      while (true) {
        if (!mounted) {
          return;
        }
        final asset = widget.asset;
        if (asset != null) {
          final savedAssetId = await Navigator.of(
            context,
          ).push<String>(MaterialPageRoute<String>(builder: (_) => MagicEraserPage(asset: asset)));
          if (savedAssetId != null && savedAssetId.isNotEmpty && mounted) {
            // A server save is already committed. Refresh the normal Drift
            // stream independently, without blocking the editor or re-uploading.
            unawaited(_refreshMagicEraserLibrary());
          }
          return;
        }
        final retry = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(context.t.magic_eraser),
            content: Text(context.t.editor_magic_local_unavailable),
            actions: [
              TextButton(
                key: const Key('magic-eraser-local-retry'),
                onPressed: () => Navigator.pop(context, true),
                child: Text(context.t.retry),
              ),
              TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.t.close)),
            ],
          ),
        );
        if (retry != true) {
          return;
        }
      }
    } finally {
      _magicEraserOpen = false;
    }
  }

  Future<void> _refreshMagicEraserLibrary() async {
    try {
      // enqueue also requests one follow-up pass if the current stream took
      // its checkpoint before the copy was saved. Its Future may represent
      // that existing pass, so success is not proof the new ID is imported yet.
      if (await ref.read(backgroundSyncProvider).syncRemote(enqueue: true)) {
        return;
      }
      _log.warning('Server copy saved; remote library refresh did not complete');
    } catch (error, stack) {
      _log.warning('Server copy saved; remote library refresh failed', error, stack);
    }
    if (mounted) {
      ImmichToast.show(context: context, msg: context.t.magic_eraser_saved_sync_pending, toastType: ToastType.info);
    }
  }

  void _cancelExport() {
    _cancelSave = true;
    if (!(_cancelLoad?.isCompleted ?? true)) {
      _cancelLoad!.complete();
    }
  }

  @override
  void dispose() {
    _cancelExport();
    super.dispose();
  }

  Future<void> _saveCopy() async {
    if (ref.read(editorStateProvider).isApplyingEdits) {
      return;
    }
    _cancelSave = false;
    _cancelLoad = Completer<void>();
    _writingCopy = _pendingCopy != null;
    ref.read(editorStateProvider.notifier).setIsEditing(true);
    String? path;
    ui.Image? source;
    ui.Image? rendered;
    var imported = false;
    try {
      // Resolve both services before MediaStore creates anything. A late native
      // result can then be indexed even if this editor was removed meanwhile.
      final media = ref.read(fileMediaRepositoryProvider);
      final EditedCopyService importer = _pendingImporter ?? ref.read(editedCopyServiceProvider);
      _pendingImporter = importer;
      if (_pendingCopy == null) {
        final asset = widget.asset;
        if (asset?.width != null && asset?.height != null) {
          EditedImageExporter.validateDimensions(asset!.width!, asset.height!);
        }
        source = await _loadOriginalImage();
        if (!mounted || _cancelSave) {
          return;
        }
        final state = ref.read(editorStateProvider);
        rendered = await EditedImageExporter.render(
          source: source,
          crop: state.crop,
          rotationDegrees: state.rotationAngle,
          straightenDegrees: state.straightenDegrees,
          flipHorizontal: state.flipHorizontal,
          flipVertical: state.flipVertical,
          annotations: _annotations.elements,
          adjustments: state.adjustments,
          selectedFilterIndex: state.selectedFilterIndex,
          filterIntensity: state.filterIntensity,
        );
        if (!mounted || _cancelSave) {
          return;
        }
        final bytes = await EditedImageExporter.encodePng(rendered);
        if (!mounted || _cancelSave) {
          return;
        }
        final directory = await getTemporaryDirectory();
        path = '${directory.path}/gallery-edit-${DateTime.now().microsecondsSinceEpoch}.png';
        await File(path).writeAsBytes(bytes, flush: true);
        if (!mounted || _cancelSave) {
          return;
        }
        setState(() => _writingCopy = true);
        AssetEntity? copy;
        try {
          copy = await media.saveImageWithFile(
            path,
            title: 'gallery-edit-${DateTime.now().millisecondsSinceEpoch}.png',
            relativePath: 'DCIM/Noodle Gallery',
            preserveCreatedAssetOnFailure: true,
          );
        } on SavedMediaImportException catch (error, stack) {
          // A file exists even when its MIME update failed. The importer first
          // records this exact ID durably, then retries metadata and indexing.
          copy = error.asset;
          _log.warning('Edited copy ${copy.id} needs metadata completion', error.cause, stack);
        }
        if (copy == null) {
          throw StateError('Unable to save edited copy');
        }
        _pendingCopy = copy;
        if (mounted) {
          setState(() {});
        }
      }
      final copy = _pendingCopy!;
      await importer.importSavedCopy(copy);
      _pendingCopy = null;
      imported = true;
    } catch (error, stack) {
      final copy = _pendingCopy;
      _log.warning(
        copy == null
            ? 'Edited image export failed before a copy was returned'
            : 'Edited copy ${copy.id} import pending',
        error,
        stack,
      );
      if (mounted && !_cancelSave) {
        ImmichToast.show(
          context: context,
          msg: copy != null
              ? context.t.editor_copy_saved_import_pending
              : context.tr(error is ImageExportLimitException ? 'editor_export_too_large' : 'editor_export_failed'),
          toastType: copy == null ? ToastType.error : ToastType.info,
        );
      }
    } finally {
      if (_pendingCopy == null) {
        _pendingImporter = null;
      }
      source?.dispose();
      rendered?.dispose();
      if (path != null) {
        try {
          await File(path).delete();
        } catch (_) {
          // Temporary cleanup is best effort after the library copy succeeds.
        }
      }
      if (mounted) {
        ref.read(editorStateProvider.notifier).setIsEditing(false);
      }
    }
    if (imported && mounted) {
      ImmichToast.show(context: context, msg: context.tr('editor_save_copy_device'), toastType: ToastType.success);
      Navigator.of(context).pop();
    }
  }

  Future<ui.Image> _loadOriginalImage() async {
    final provider = widget.asset == null
        ? widget.image.image
        : RemoteImageProvider(url: getOriginalUrlForRemoteId(widget.asset!.id, edited: false), edited: false);
    final image = await EditedImageExporter.loadSource(provider, cancel: _cancelLoad?.future);
    return image;
  }

  Future<String?> _promptText({String? initialText}) {
    var draft = initialText ?? '';
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('annotation-text-dialog'),
        title: Text(context.t.edit),
        content: TextFormField(
          key: const Key('annotation-text-input'),
          initialValue: initialText,
          onChanged: (value) => draft = value,
          autofocus: true,
          maxLength: 120,
          minLines: 1,
          maxLines: 4,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
        ),
        actions: [
          TextButton(
            key: const Key('annotation-text-cancel'),
            onPressed: () => Navigator.pop(context),
            child: Text(context.t.cancel),
          ),
          TextButton(
            key: const Key('annotation-text-confirm'),
            onPressed: () => Navigator.pop(context, draft),
            child: Text(initialText == null ? context.t.add : context.t.save),
          ),
        ],
      ),
    );
  }

  Future<void> _editText(AnnotationElement element) async {
    final text = await _promptText(initialText: element.text);
    if (!mounted || text == null || text.trim().isEmpty) {
      return;
    }
    final current = _annotations.elements.where((current) => current.id == element.id).firstOrNull;
    if (current == null || current.text == text.trim()) {
      return;
    }
    _annotations.update(current.copyWith(text: text.trim()));
    _syncAnnotationDirty();
    setState(() {});
  }

  Future<void> _addText(Offset point, double relativeWidth) async {
    final text = await _promptText();
    if (!mounted || text == null || text.trim().isEmpty) {
      return;
    }
    final element = AnnotationElement(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      tool: AnnotationTool.text,
      points: [point],
      color: _color,
      width: relativeWidth,
      opacity: _opacity,
      text: text.trim(),
      fontFamily: _textStyle.fontFamily,
      fontSize: _textStyle.fontSize,
      outlineWidth: _textStyle.outlineWidth,
      outlineColor: _textStyle.outlineColor,
      backgroundColor: _textStyle.backgroundColor,
    );
    _annotations.add(element);
    _syncAnnotationDirty();
    setState(() => _selectedId = element.id);
  }

  void _syncAnnotationDirty() {
    ref.read(editorStateProvider.notifier).setAnnotations(_annotations.elements);
  }

  Future<bool?> _showDiscardChangesDialog() {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.t.editor_discard_edits_title),
        content: Text(context.t.editor_discard_edits_prompt),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            style: ButtonStyle(
              foregroundColor: WidgetStateProperty.all(context.themeData.colorScheme.onSurfaceVariant),
            ),
            child: Text(context.t.cancel),
          ),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: Text(context.t.confirm)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(editorStateProvider);
    final hasUnsavedEdits = state.hasUnsavedEdits;
    ref.listen(editorStateProvider, (previous, current) {
      if (previous?.annotations != current.annotations) {
        _annotations.replaceAll(current.annotations);
      }
    });
    final notifier = ref.read(editorStateProvider.notifier);
    final allowTransformEdits = widget.asset?.isStillCopyEditable ?? true;
    final documentLocked = state.isApplyingEdits || _pendingCopy != null;

    return PopScope(
      canPop: !hasUnsavedEdits && !state.isApplyingEdits,

      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) {
          return;
        }
        if (state.isApplyingEdits) {
          return;
        }
        final shouldDiscard = await _showDiscardChangesDialog() ?? false;
        if (shouldDiscard && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: EditorChrome(
        child: Builder(
          builder: (context) => Scaffold(
            appBar: AppBar(
              toolbarHeight: kToolbarHeight,
              systemOverlayStyle: editorSystemUiStyle(context),
              backgroundColor: Theme.of(context).colorScheme.surface,
              leadingWidth: 48,
              leading: IconButton(
                key: const Key('editor-back'),
                tooltip: context.t.back,
                onPressed: state.isApplyingEdits ? null : () => Navigator.of(context).maybePop(),
                icon: FotoIcon(
                  kind: FotoIconKind.back,
                  semanticLabel: context.t.back,
                  state: state.isApplyingEdits ? FotoIconState.disabled : FotoIconState.normal,
                ),
              ),
              actions: [
                IconButton(
                  key: const Key('editor-header-undo'),
                  tooltip: context.t.undo,
                  onPressed: !documentLocked && state.canUndo ? notifier.undo : null,
                  icon: FotoIcon(
                    kind: FotoIconKind.undo,
                    semanticLabel: context.t.undo,
                    state: !documentLocked && state.canUndo ? FotoIconState.normal : FotoIconState.disabled,
                  ),
                ),
                IconButton(
                  key: const Key('editor-header-redo'),
                  tooltip: context.t.magic_eraser_redo,
                  onPressed: !documentLocked && state.canRedo ? notifier.redo : null,
                  icon: FotoIcon(
                    kind: FotoIconKind.redo,
                    semanticLabel: context.t.magic_eraser_redo,
                    state: !documentLocked && state.canRedo ? FotoIconState.normal : FotoIconState.disabled,
                  ),
                ),
                _SaveEditsButton(onSave: _saveCopy, enabled: allowTransformEdits, retryImport: _pendingCopy != null),
              ],
            ),
            backgroundColor: Theme.of(context).colorScheme.surface,
            body: SafeArea(
              bottom: false,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final preview = allowTransformEdits
                      ? _EditorPreview(
                          key: _previewKey,
                          image: widget.image,
                          annotations: _annotations,
                          tool: _tool,
                          color: _color,
                          width: _strokeWidth,
                          opacity: _opacity,
                          mode: _mode,
                          cropHandles: _mode == EditorMode.crop && !_straightening,
                          selectedId: _selectedId,
                          onSelectionChanged: (id) => setState(() => _selectedId = id),
                          onTextPosition: _addText,
                          onEditText: _editText,
                          onChanged: (_) {
                            _syncAnnotationDirty();
                            setState(() {});
                          },
                        )
                      : Center(child: InteractiveViewer(child: widget.image));
                  final panel = _EditorBottomPanel(
                    source: widget.image.image,
                    avoidPoint: () => _lastPhotoPoint,
                    maxHeight: constraints.maxHeight,
                    settingsExpanded: _settingsExpanded,
                    onToggleSettings: () => setState(() => _settingsExpanded = !_settingsExpanded),
                    mode: _mode,
                    allowTransformEdits: allowTransformEdits,
                    straightening: _straightening,
                    onStraightening: (value) => setState(() => _straightening = value),
                    onLayers: _layers,
                    tool: _tool,
                    color: _color,
                    width: _strokeWidth,
                    opacity: _opacity,
                    canUndo: state.canUndo,
                    canRedo: state.canRedo,
                    textStyle: _selected?.isText == true ? _selected! : _textStyle,
                    onTextStyle: _setTextStyle,
                    onSticker: _addSticker,
                    onReset: _reset,
                    onMode: (mode) {
                      if (mode == EditorMode.magicEraser) {
                        unawaited(_openMagicEraser());
                        return;
                      }
                      setState(() {
                        _mode = mode;
                        _settingsExpanded = true;
                        _tool = mode.defaultTool;
                        _selectedId = null;
                      });
                    },
                    onTool: (tool) => setState(() {
                      _tool = tool;
                      if (tool == AnnotationTool.pen || tool == AnnotationTool.highlighter) {
                        _color = tool == AnnotationTool.pen ? Colors.blue : Colors.purple;
                        _opacity = tool == AnnotationTool.pen ? 1 : .45;
                      }
                    }),
                    onColor: (color) => _setInk(color: color),
                    onWidth: (width) => setState(() => _strokeWidth = width),
                    onOpacity: (opacity) => _setInk(opacity: opacity),
                    onUndo: notifier.undo,
                    onRedo: notifier.redo,
                    onGestureStart: notifier.beginGesture,
                    onGestureEnd: notifier.endGesture,
                  );
                  final content = AbsorbPointer(
                    absorbing: documentLocked,
                    child: Column(
                      children: [
                        Expanded(
                          child: Listener(
                            onPointerDown: (event) => _lastPhotoPoint = event.position,
                            onPointerMove: (event) => _lastPhotoPoint = event.position,
                            onPointerUp: (event) => _lastPhotoPoint = event.position,
                            child: preview,
                          ),
                        ),
                        if (allowTransformEdits || widget.asset != null) panel,
                      ],
                    ),
                  );
                  return Stack(
                    children: [
                      Positioned.fill(child: content),
                      if (state.isApplyingEdits && !_writingCopy)
                        Positioned(
                          top: 8,
                          right: 8,
                          child: Material(
                            color: Theme.of(context).colorScheme.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(24),
                            child: TextButton(
                              key: const Key('editor-cancel-export'),
                              onPressed: _cancelExport,
                              child: Text(context.t.cancel),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EditorBottomPanel extends ConsumerStatefulWidget {
  final ValueGetter<Offset?> avoidPoint;
  final ImageProvider source;
  final double maxHeight;
  final bool settingsExpanded;
  final VoidCallback onToggleSettings;
  final EditorMode mode;
  final bool allowTransformEdits;
  final bool straightening;
  final ValueChanged<bool> onStraightening;
  final VoidCallback onLayers;
  final AnnotationTool tool;
  final Color color;
  final double width;
  final double opacity;
  final bool canUndo;
  final bool canRedo;
  final AnnotationElement textStyle;
  final ValueChanged<AnnotationElement> onTextStyle;
  final ValueChanged<String> onSticker;
  final VoidCallback onGestureStart;
  final VoidCallback onGestureEnd;
  final VoidCallback onReset;
  final ValueChanged<EditorMode> onMode;
  final ValueChanged<AnnotationTool> onTool;
  final ValueChanged<Color> onColor;
  final ValueChanged<double> onWidth;
  final ValueChanged<double> onOpacity;
  final VoidCallback onUndo;
  final VoidCallback onRedo;

  const _EditorBottomPanel({
    required this.avoidPoint,
    required this.source,
    required this.maxHeight,
    required this.settingsExpanded,
    required this.onToggleSettings,
    required this.mode,
    required this.allowTransformEdits,
    required this.straightening,
    required this.onStraightening,
    required this.onLayers,
    required this.tool,
    required this.color,
    required this.width,
    required this.opacity,
    required this.canUndo,
    required this.canRedo,
    required this.textStyle,
    required this.onTextStyle,
    required this.onSticker,
    required this.onGestureStart,
    required this.onGestureEnd,
    required this.onReset,
    required this.onMode,
    required this.onTool,
    required this.onColor,
    required this.onWidth,
    required this.onOpacity,
    required this.onUndo,
    required this.onRedo,
  });

  @override
  ConsumerState<_EditorBottomPanel> createState() => _EditorBottomPanelState();
}

class _EditorBottomPanelState extends ConsumerState<_EditorBottomPanel> {
  String? _parameter;

  void _dismiss() {
    if (_parameter == null) {
      return;
    }
    setState(() => _parameter = null);
    if (widget.straightening) {
      widget.onStraightening(false);
    }
  }

  void _open(String value) {
    setState(() => _parameter = _parameter == value ? null : value);
    widget.onStraightening(_parameter == 'straighten');
  }

  @override
  void didUpdateWidget(covariant _EditorBottomPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mode != widget.mode || oldWidget.settingsExpanded != widget.settingsExpanded) {
      _parameter = null;
    }
  }

  Widget _button(String key, FotoIconKind icon, String label, VoidCallback? action, {bool selected = false}) =>
      FotoIconButton(
        key: Key(key),
        kind: icon,
        label: label,
        selected: selected,
        onPressed: action == null
            ? null
            : () {
                ref.read(hapticFeedbackProvider.notifier).selectionClick();
                action();
              },
      );

  String _toolLabel(BuildContext context, AnnotationTool tool) => context.tr(switch (tool) {
    AnnotationTool.pen => 'editor_pen',
    AnnotationTool.highlighter => 'editor_marker',
    AnnotationTool.brush => 'editor_brush',
    AnnotationTool.eraser => 'editor_stroke_eraser',
    AnnotationTool.move => 'editor_select',
    AnnotationTool.arrow => 'editor_arrow',
    AnnotationTool.rectangle => 'editor_rectangle',
    AnnotationTool.ellipse => 'editor_ellipse',
    _ => 'editor_text',
  });

  @override
  Widget build(BuildContext context) {
    // IME can leave no useful control space. It never changes the document.
    if (widget.maxHeight < EditorDock.height + MediaQuery.paddingOf(context).bottom) {
      return const SizedBox.shrink();
    }
    final notifier = ref.read(editorStateProvider.notifier);
    final draw = widget.mode == EditorMode.draw || widget.mode == EditorMode.shapes;
    Widget markup(MarkupParameter parameter) => MarkupControls(
      mode: widget.mode,
      tool: widget.tool,
      color: widget.color,
      width: widget.width,
      opacity: widget.opacity,
      canUndo: widget.canUndo,
      canRedo: widget.canRedo,
      textStyle: widget.textStyle,
      onTextStyle: widget.onTextStyle,
      onSticker: widget.onSticker,
      onGestureStart: widget.onGestureStart,
      onGestureEnd: widget.onGestureEnd,
      onTool: widget.onTool,
      onColor: widget.onColor,
      onWidth: widget.onWidth,
      onOpacity: widget.onOpacity,
      onUndo: widget.onUndo,
      onRedo: widget.onRedo,
      compact: true,
      showToolStrip: false,
      parameter: parameter,
      onComplete: _dismiss,
    );
    final popover = switch (_parameter) {
      'color' => markup(MarkupParameter.color),
      'width' => markup(MarkupParameter.width),
      'opacity' => markup(MarkupParameter.opacity),
      'text' => markup(MarkupParameter.text),
      'aspect' => _AspectRatioSelector(onSelected: _dismiss),
      'straighten' => _StraightenControls(onComplete: _dismiss),
      'filters' => FilterPanel(source: widget.source),
      'adjustments' => AdjustmentPanel(onComplete: _dismiss),
      _ => null,
    };
    final controls = <Widget>[];
    if (!widget.settingsExpanded) {
      controls.add(
        EditorModeBar(mode: widget.mode, allowTransformEdits: widget.allowTransformEdits, onMode: widget.onMode),
      );
    } else {
      controls.add(
        _button('editor-tools-back', FotoIconKind.back, context.t.back, () {
          _dismiss();
          widget.onToggleSettings();
        }),
      );
      if (widget.mode == EditorMode.crop) {
        controls.addAll([
          _button('editor-rotate-left', FotoIconKind.rotateLeft, context.t.editor_rotate_left, notifier.rotateCCW),
          _button('editor-rotate-right', FotoIconKind.rotateRight, context.t.editor_rotate_right, notifier.rotateCW),
          _button(
            'editor-flip-horizontal',
            FotoIconKind.flipH,
            context.t.editor_flip_horizontal,
            notifier.flipHorizontally,
          ),
          _button('editor-flip-vertical', FotoIconKind.flipV, context.t.editor_flip_vertical, notifier.flipVertically),
          _button('editor-crop-frame', FotoIconKind.aspect, context.t.editor_crop_frame, () => _open('aspect')),
          _button(
            'editor-crop-straighten',
            FotoIconKind.straighten,
            context.t.editor_straighten,
            () => _open('straighten'),
          ),
        ]);
      } else if (draw) {
        for (final tool in [
          AnnotationTool.pen,
          AnnotationTool.highlighter,
          AnnotationTool.brush,
          AnnotationTool.eraser,
          AnnotationTool.move,
          AnnotationTool.arrow,
          AnnotationTool.rectangle,
          AnnotationTool.ellipse,
        ]) {
          controls.add(
            _button('editor-tool-${tool.name}', fotoAnnotationToolIcons[tool]!, _toolLabel(context, tool), () {
              _dismiss();
              widget.onTool(tool);
            }, selected: widget.tool == tool),
          );
        }
        controls.add(_button('editor-width', FotoIconKind.brush, context.t.size, () => _open('width')));
      } else if (widget.mode == EditorMode.text) {
        controls.addAll([
          _button(
            'editor-tool-text',
            FotoIconKind.text,
            context.t.editor_text,
            () => widget.onTool(AnnotationTool.text),
          ),
          _button(
            'editor-tool-move',
            FotoIconKind.move,
            context.tr('editor_select'),
            () => widget.onTool(AnnotationTool.move),
          ),
          _button('editor-text-options', FotoIconKind.textOutline, context.t.settings, () => _open('text')),
        ]);
      } else if (widget.mode == EditorMode.stickers) {
        for (final sticker in [
          ('star', FotoIconKind.star),
          ('heart', FotoIconKind.favorite),
          ('smile', FotoIconKind.smile),
        ]) {
          controls.add(
            _button(
              'editor-sticker-${sticker.$1}',
              sticker.$2,
              '${context.tr('editor_stickers')}: ${sticker.$1}',
              () => widget.onSticker(sticker.$1),
            ),
          );
        }
      } else if (widget.mode == EditorMode.filters || widget.mode == EditorMode.adjustments) {
        controls.addAll([
          _button('editor-color-filters', FotoIconKind.filters, context.t.editor_filters, () => _open('filters')),
          _button(
            'editor-color-adjustments',
            FotoIconKind.adjustments,
            context.t.editor_adjustments,
            () => _open('adjustments'),
          ),
        ]);
      }
      if (draw || widget.mode == EditorMode.text || widget.mode == EditorMode.stickers) {
        controls.addAll([
          _button('editor-color', FotoIconKind.hue, context.t.color, () => _open('color')),
          _button('editor-opacity', FotoIconKind.opacity, context.tr('editor_opacity'), () => _open('opacity')),
          _button('editor-layers', FotoIconKind.layers, context.tr('editor_layers'), widget.onLayers),
        ]);
      }
      controls.add(_button('editor-reset', FotoIconKind.reset, context.t.reset, widget.onReset));
    }
    return EditorDock(
      avoidPoint: widget.avoidPoint,
      leading: widget.settingsExpanded ? controls.removeAt(0) : null,
      controls: controls,
      popover: popover,
      onDismiss: _dismiss,
    );
  }
}

/// Categories occupy this same dock only while no contextual tool row is open.
class EditorModeBar extends StatelessWidget {
  const EditorModeBar({super.key, required this.mode, required this.allowTransformEdits, required this.onMode});
  final EditorMode mode;
  final bool allowTransformEdits;
  final ValueChanged<EditorMode> onMode;
  double preferredHeight(BuildContext context) => 48;

  @override
  Widget build(BuildContext context) => Row(
    key: const Key('editor-mode-bar'),
    children: [
      for (final entry in [
        EditorMode.crop,
        EditorMode.draw,
        EditorMode.text,
        EditorMode.magicEraser,
        EditorMode.filters,
        EditorMode.adjustments,
        EditorMode.shapes,
        EditorMode.stickers,
      ])
        FotoIconButton(
          key: Key('editor-mode-${entry.name}'),
          kind: fotoEditorModeIcons[entry]!,
          label: entry.label(context),
          selected: mode == entry,
          // Local photos retain the existing explanation/retry dialog; opening
          // it never uploads an image or discards the current editor document.
          onPressed: entry == EditorMode.magicEraser || allowTransformEdits ? () => onMode(entry) : null,
        ),
    ],
  );
}

class _StraightenControls extends ConsumerWidget {
  const _StraightenControls({this.onComplete});
  final VoidCallback? onComplete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final angle = ref.watch(editorStateProvider.select((state) => state.straightenDegrees));
    final notifier = ref.read(editorStateProvider.notifier);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('${angle.toStringAsFixed(1)}°'),
        Slider(
          key: const Key('editor-straighten-slider'),
          min: -EditorGeometry.maxStraightenDegrees,
          max: EditorGeometry.maxStraightenDegrees,
          value: angle,
          onChangeStart: (_) => notifier.beginGesture(),
          onChanged: notifier.setStraightenDegrees,
          onChangeEnd: (_) {
            notifier.endGesture();
            onComplete?.call();
          },
          label: '${angle.toStringAsFixed(1)}°',
        ),
      ],
    );
  }
}

class _AspectRatioButton extends StatelessWidget {
  final CropAspectRatio ratio;
  final bool isSelected;
  final VoidCallback onPressed;

  const _AspectRatioButton({required this.ratio, required this.isSelected, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final color = isSelected ? context.primaryColor : context.themeData.iconTheme.color;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          iconSize: 36,
          icon: ratio.ratio != null
              ? _AspectRatioRect(ratio: ratio.ratio!, color: color)
              : FotoIcon(
                  kind: ratio == CropAspectRatio.free ? FotoIconKind.crop : FotoIconKind.aspect,
                  semanticLabel: ratio == CropAspectRatio.free
                      ? context.t.crop_aspect_ratio_free
                      : context.t.crop_aspect_ratio_original,
                  state: isSelected ? FotoIconState.active : FotoIconState.normal,
                ),
          onPressed: onPressed,
        ),
        Text(switch (ratio) {
          CropAspectRatio.free => context.t.crop_aspect_ratio_free,
          CropAspectRatio.original => context.t.crop_aspect_ratio_original,
          _ => '${ratio.numerator}:${ratio.denominator}',
        }, style: context.textTheme.labelSmall),
      ],
    );
  }
}

class _AspectRatioRect extends StatelessWidget {
  final double ratio;
  final Color? color;

  const _AspectRatioRect({required this.ratio, required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 28,
      height: 28,
      child: Center(
        child: AspectRatio(
          aspectRatio: ratio,
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: color ?? Colors.transparent, width: 3),
              borderRadius: const BorderRadius.all(Radius.circular(4)),
            ),
          ),
        ),
      ),
    );
  }
}

class _AspectRatioSelector extends ConsumerWidget {
  const _AspectRatioSelector({this.onSelected});
  final VoidCallback? onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editorState = ref.watch(editorStateProvider);
    final editorNotifier = ref.watch(editorStateProvider.notifier);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: CropAspectRatio.values.map((entry) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: _AspectRatioButton(
              ratio: entry,
              isSelected: editorState.aspectRatio == entry,
              onPressed: () {
                editorNotifier.setAspectRatio(entry);
                onSelected?.call();
              },
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _SaveEditsButton extends ConsumerWidget {
  final VoidCallback onSave;
  final bool enabled;
  final bool retryImport;

  const _SaveEditsButton({required this.onSave, required this.enabled, this.retryImport = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isApplyingEdits = ref.watch(editorStateProvider.select((state) => state.isApplyingEdits));
    final hasUnsavedEdits = ref.watch(editorStateProvider.select((state) => state.hasUnsavedEdits));
    final label = retryImport ? context.t.retry : context.t.magic_eraser_save_copy;
    return SizedBox.square(
      dimension: 48,
      child: TextButton(
        key: const Key('editor-save'),
        style: TextButton.styleFrom(minimumSize: const Size.square(48), padding: EdgeInsets.zero),
        onPressed: enabled && (hasUnsavedEdits || retryImport) && !isApplyingEdits ? onSave : null,
        child: Tooltip(
          message: label,
          child: isApplyingEdits
              ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
              : FotoIcon(
                  kind: FotoIconKind.saveCopy,
                  semanticLabel: label,
                  state: enabled && (hasUnsavedEdits || retryImport) ? FotoIconState.normal : FotoIconState.disabled,
                ),
        ),
      ),
    );
  }
}

class _EditorPreview extends ConsumerStatefulWidget {
  final Image image;
  final AnnotationEditor annotations;
  final AnnotationTool tool;
  final Color color;
  final double width;
  final double opacity;
  final EditorMode mode;
  final bool cropHandles;
  final void Function(Offset point, double relativeWidth)? onTextPosition;
  final ValueChanged<AnnotationElement>? onEditText;
  final ValueChanged<List<AnnotationElement>>? onChanged;
  final String? selectedId;
  final ValueChanged<String?>? onSelectionChanged;

  const _EditorPreview({
    super.key,
    required this.image,
    required this.annotations,
    required this.tool,
    required this.color,
    required this.width,
    required this.opacity,
    required this.mode,
    required this.cropHandles,
    this.onTextPosition,
    this.onEditText,
    this.onChanged,
    this.selectedId,
    this.onSelectionChanged,
  });

  @override
  ConsumerState<_EditorPreview> createState() => _EditorPreviewState();
}

class _EditorPreviewState extends ConsumerState<_EditorPreview> {
  late final CropController cropController;
  final _navigationActive = ValueNotifier(false);
  final _objectTransformActive = ValueNotifier(false);
  Rect? _cropBeforeNavigation;
  bool _applyingControllerState = false;
  ImageStream? _imageStream;
  late final ImageStreamListener _imageListener;
  Size? _imageSize;

  @override
  void initState() {
    super.initState();

    cropController = CropController();
    cropController.crop = ref.read(editorStateProvider.select((state) => state.crop));
    cropController.addListener(onCrop);
    _navigationActive.addListener(_onNavigation);
    _imageListener = ImageStreamListener((info, _) {
      final size = Size(info.image.width.toDouble(), info.image.height.toDouble());
      info.dispose();
      if (mounted && size != _imageSize) {
        setState(() => _imageSize = size);
      }
    });
    _resolveImage();
  }

  void _resolveImage() {
    _imageStream?.removeListener(_imageListener);
    _imageSize = null;
    // Match CropImage's configuration so both surfaces use the same decoded image.
    _imageStream = widget.image.image.resolve(ImageConfiguration.empty);
    _imageStream!.addListener(_imageListener);
  }

  @override
  void didUpdateWidget(covariant _EditorPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image.image != widget.image.image) {
      _resolveImage();
    }
  }

  void onCrop() {
    if (_applyingControllerState) {
      return;
    }
    if (_navigationActive.value) {
      final crop = _cropBeforeNavigation;
      if (crop != null && cropController.crop != crop) {
        cropController.crop = crop;
      }
      return;
    }
    if (!mounted || cropController.crop == ref.read(editorStateProvider).crop) {
      return;
    }

    ref.read(editorStateProvider.notifier).setCrop(cropController.crop);
  }

  void _onNavigation() {
    if (_navigationActive.value) {
      _cropBeforeNavigation = cropController.crop;
    } else {
      _cropBeforeNavigation = null;
    }
  }

  @override
  void dispose() {
    _imageStream?.removeListener(_imageListener);
    cropController.removeListener(onCrop);
    cropController.dispose();
    _navigationActive.removeListener(_onNavigation);
    _navigationActive.dispose();
    _objectTransformActive.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editorState = ref.watch(editorStateProvider);

    ref.listen(editorStateProvider, (previous, current) {
      // A programmatic replay is not a fresh user gesture. In particular changing
      // aspectRatio also notifies CropController with its intermediate crop.
      _applyingControllerState = true;
      try {
        if (previous?.aspectRatio != current.aspectRatio) {
          double? ratio = switch (current.aspectRatio) {
            CropAspectRatio.original =>
              current.originalWidth > 0 && current.originalHeight > 0
                  ? current.originalWidth / current.originalHeight
                  : _imageSize?.aspectRatio,
            _ => current.aspectRatio.ratio,
          };
          if (current.rotationAngle % 180 != 0) {
            ratio = ratio != null ? 1 / ratio : null;
          }
          cropController.aspectRatio = ratio;
        }
        if (cropController.crop != current.crop) {
          cropController.crop = current.crop;
        }
      } finally {
        _applyingControllerState = false;
      }
      // Store the final, image-space ratio correction in the same preset step.
      // Valid historical snapshots replay exactly and do not clear redo.
      if (cropController.crop != ref.read(editorStateProvider).crop) {
        ref.read(editorStateProvider.notifier).setCrop(cropController.crop);
      }
    });

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final imageSize = _imageSize;
        if (imageSize == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final visibleCrop = widget.cropHandles ? const Rect.fromLTWH(0, 0, 1, 1) : editorState.crop;
        final sourceCrop = Rect.fromLTWH(
          imageSize.width * visibleCrop.left,
          imageSize.height * visibleCrop.top,
          imageSize.width * visibleCrop.width,
          imageSize.height * visibleCrop.height,
        );
        final sourceGeometry = EditorGeometry(
          sourceRect: sourceCrop,
          rotationDegrees: editorState.rotationAngle,
          flipHorizontal: editorState.flipHorizontal,
          flipVertical: editorState.flipVertical,
          straightenDegrees: widget.cropHandles ? 0 : editorState.straightenDegrees,
        );
        final scale = min(
          constraints.maxWidth / sourceGeometry.outputSize.width,
          constraints.maxHeight / sourceGeometry.outputSize.height,
        );
        final fullSize = imageSize * scale;
        final geometry = EditorGeometry(
          sourceRect: Rect.fromLTWH(
            sourceCrop.left * scale,
            sourceCrop.top * scale,
            sourceCrop.width * scale,
            sourceCrop.height * scale,
          ),
          rotationDegrees: editorState.rotationAngle,
          flipHorizontal: editorState.flipHorizontal,
          flipVertical: editorState.flipVertical,
          straightenDegrees: widget.cropHandles ? 0 : editorState.straightenDegrees,
        );
        // The image and normalized annotation canvas share one source-space
        // surface. Transform's inverse hit testing maps gestures through exactly
        // the affine geometry used by the full-resolution exporter.
        final transformedPreview = SizedBox(
          width: geometry.outputSize.width,
          height: geometry.outputSize.height,
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minWidth: fullSize.width,
              maxWidth: fullSize.width,
              minHeight: fullSize.height,
              maxHeight: fullSize.height,
              child: Transform(
                transform: geometry.sourceToOutputTransform,
                child: SizedBox(
                  key: const Key('editor-image-surface'),
                  width: fullSize.width,
                  height: fullSize.height,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      IgnorePointer(
                        ignoring: !widget.cropHandles,
                        child: Listener(
                          onPointerDown: (_) => ref.read(editorStateProvider.notifier).beginGesture(),
                          onPointerUp: (_) => ref.read(editorStateProvider.notifier).endGesture(),
                          onPointerCancel: (_) => ref.read(editorStateProvider.notifier).endGesture(),
                          child: FilteredImage(
                            editorState: editorState,
                            image: widget.image,
                            cropController: cropController,
                            mode: widget.mode,
                            showCropHandles: widget.cropHandles,
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: AnnotationCanvas(
                          key: const Key('annotation-canvas'),
                          editor: widget.annotations,
                          tool: widget.tool,
                          color: widget.color,
                          width: widget.width,
                          opacity: widget.opacity,
                          navigationActive: _navigationActive,
                          objectTransformActive: _objectTransformActive,
                          selectedId: widget.selectedId,
                          onSelectionChanged: widget.onSelectionChanged,
                          enabled:
                              widget.mode == EditorMode.draw ||
                              widget.mode == EditorMode.text ||
                              widget.mode == EditorMode.shapes ||
                              widget.mode == EditorMode.stickers,
                          onTextPosition: widget.onTextPosition,
                          onEditText: widget.onEditText,
                          onChanged: widget.onChanged,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );

        return EditorViewport(
          key: const Key('editor-preview-viewport'),
          contentSize: geometry.outputSize,
          navigationActive: _navigationActive,
          objectTransformActive: _objectTransformActive,
          child: RepaintBoundary(child: transformedPreview),
        );
      },
    );
  }
}
