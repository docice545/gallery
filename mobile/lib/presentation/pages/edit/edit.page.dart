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
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/pages/edit/annotation_canvas.dart';
import 'package:immich_mobile/presentation/pages/edit/editor.provider.dart';
import 'package:immich_mobile/presentation/pages/edit/editor_mode.dart';
import 'package:immich_mobile/presentation/pages/edit/editor_viewport.dart';
import 'package:immich_mobile/presentation/pages/edit/magic_eraser.page.dart';
import 'package:immich_mobile/presentation/pages/edit/magic_eraser_availability.dart';
import 'package:immich_mobile/presentation/pages/edit/widgets/adjustment_panel.dart';
import 'package:immich_mobile/presentation/pages/edit/widgets/filter_panel.dart';
import 'package:immich_mobile/presentation/pages/edit/widgets/filtered_image.dart';
import 'package:immich_mobile/presentation/pages/edit/widgets/markup_controls.dart';
import 'package:immich_mobile/presentation/widgets/images/remote_image_provider.dart';
import 'package:immich_mobile/providers/theme.provider.dart';
import 'package:immich_mobile/repositories/file_media.repository.dart';
import 'package:immich_mobile/repositories/magic_eraser.repository.dart';
import 'package:immich_mobile/theme/theme_data.dart';
import 'package:immich_mobile/utils/annotation_editor.dart';
import 'package:immich_mobile/utils/edit_save_policy.dart';
import 'package:immich_mobile/utils/edited_image_exporter.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:immich_mobile/widgets/common/immich_toast.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:path_provider/path_provider.dart';

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
  final _annotations = AnnotationEditor();
  late EditorMode _mode;
  AnnotationTool _tool = AnnotationTool.pen;
  Color _color = Colors.blue;
  double _strokeWidth = 5;
  double _opacity = 1;
  String? _selectedId;
  bool _cancelSave = false;
  bool _writingCopy = false;
  bool _settingsExpanded = false;
  final _previewKey = GlobalKey();
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
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xff191919),
      builder: (context) => StatefulBuilder(
        builder: (context, update) => SafeArea(
          child: SizedBox(
            height: 360,
            child: Column(
              children: [
                Text(context.tr('editor_layers'), style: const TextStyle(color: Colors.white)),
                Expanded(
                  child: ListView(
                    children: [
                      for (final element in _annotations.elements.reversed)
                        ListTile(
                          key: ValueKey('editor-layer-${element.id}'),
                          selected: _selectedId == element.id,
                          textColor: Colors.white,
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
                                icon: const Icon(Icons.arrow_upward),
                                onPressed: () {
                                  _annotations.reorder(element.id, _annotations.elements.indexOf(element) + 1);
                                  _syncAnnotationDirty();
                                  update(() {});
                                },
                              ),
                              IconButton(
                                tooltip: context.tr('editor_layer_down'),
                                icon: const Icon(Icons.arrow_downward),
                                onPressed: () {
                                  _annotations.reorder(element.id, _annotations.elements.indexOf(element) - 1);
                                  _syncAnnotationDirty();
                                  update(() {});
                                },
                              ),
                              IconButton(
                                tooltip: context.tr('editor_delete_layer'),
                                icon: const Icon(Icons.delete_outline),
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
    );
  }

  @override
  void initState() {
    super.initState();
    _annotations.replaceAll(ref.read(editorStateProvider).annotations);
    _mode = widget.asset?.isEditable ?? true ? EditorMode.crop : EditorMode.magicEraser;
    _settingsExpanded = _mode == EditorMode.magicEraser;
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
    _cancelSave = false;
    _cancelLoad = Completer<void>();
    _writingCopy = false;
    ref.read(editorStateProvider.notifier).setIsEditing(true);
    String? path;
    ui.Image? source;
    ui.Image? rendered;
    var saved = false;
    try {
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
      final copy = await ref
          .read(fileMediaRepositoryProvider)
          .saveImageWithFile(
            path,
            title: 'gallery-edit-${DateTime.now().millisecondsSinceEpoch}.png',
            relativePath: 'DCIM/Noodle Gallery',
          );
      if (copy == null) {
        throw StateError('Unable to save edited copy');
      }
      saved = true;
    } catch (error) {
      if (mounted && !_cancelSave) {
        ImmichToast.show(
          context: context,
          msg: context.tr(error is ImageExportLimitException ? 'editor_export_too_large' : 'editor_export_failed'),
          toastType: ToastType.error,
        );
      }
    } finally {
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
    if (saved && mounted) {
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

  Future<void> _chooseSaveMode() async {
    if (ref.read(editorStateProvider).isApplyingEdits) {
      return;
    }
    final mode = await showDialog<EditSaveMode>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('edit-save-mode-dialog'),
        title: Text(context.t.save),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('edit-save-copy'),
              leading: const Icon(Icons.copy),
              title: Text(context.t.magic_eraser_save_copy),
              subtitle: Text(context.tr('editor_copy_explanation')),
              onTap: () => Navigator.of(context).pop(EditSaveMode.copy),
            ),
            ListTile(
              key: const Key('edit-replace-original'),
              enabled: EditSavePolicy.canReplace(
                isExternalLibrary: true,
                isMotionPhoto: widget.asset?.isMotionPhoto ?? false,
              ),
              leading: const Icon(Icons.save),
              title: Text(context.t.replace_with_upload),
              subtitle: Text(context.t.external_deletion_blocked),
            ),
          ],
        ),
        actions: [
          TextButton(
            key: const Key('edit-save-cancel'),
            onPressed: () => Navigator.of(context).pop(EditSaveMode.cancel),
            child: Text(context.t.cancel),
          ),
        ],
      ),
    );
    if (mode == EditSaveMode.copy && mounted) {
      await _saveCopy();
    }
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
    final allowTransformEdits = widget.asset?.isEditable ?? true;

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
      child: Theme(
        data: getThemeData(colorScheme: ref.watch(immichThemeProvider).dark, locale: context.locale),
        child: Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.black,
            leading: IconButton(
              key: const Key('editor-back'),
              tooltip: context.t.back,
              onPressed: state.isApplyingEdits ? null : () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back),
            ),
            actions: [
              if (!state.isApplyingEdits) ...[
                IconButton(
                  key: const Key('editor-header-undo'),
                  tooltip: context.t.undo,
                  onPressed: state.canUndo ? notifier.undo : null,
                  icon: const Icon(Icons.undo),
                ),
                IconButton(
                  key: const Key('editor-header-redo'),
                  tooltip: context.t.magic_eraser_redo,
                  onPressed: state.canRedo ? notifier.redo : null,
                  icon: const Icon(Icons.redo),
                ),
              ],
              if (allowTransformEdits) _SaveEditsButton(onSave: _chooseSaveMode),
              if (state.isApplyingEdits && !_writingCopy)
                TextButton(
                  key: const Key('editor-cancel-export'),
                  onPressed: _cancelExport,
                  child: Text(context.t.cancel),
                ),
              PopupMenuButton<String>(
                key: const Key('editor-more'),
                icon: const Icon(Icons.more_vert),
                enabled: !state.isApplyingEdits,
                onSelected: (value) {
                  switch (value) {
                    case 'reset':
                      _reset();
                    case 'magic':
                      setState(() {
                        _mode = EditorMode.magicEraser;
                        _settingsExpanded = true;
                      });
                    case 'layers':
                      unawaited(_layers());
                    case 'close':
                      Navigator.of(context).maybePop();
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    key: const Key('editor-reset'),
                    value: 'reset',
                    enabled: state.hasEdits,
                    child: Text(context.tr('editor_revert')),
                  ),
                  PopupMenuItem(
                    key: const Key('editor-mode-magicEraser'),
                    value: 'magic',
                    enabled: widget.asset != null,
                    child: Text(context.t.magic_eraser),
                  ),
                  PopupMenuItem(
                    value: 'layers',
                    enabled: allowTransformEdits,
                    child: Text(context.tr('editor_layers')),
                  ),
                  PopupMenuItem(value: 'close', child: Text(context.t.close)),
                ],
              ),
            ],
          ),
          backgroundColor: Colors.black,
          body: SafeArea(
            bottom: false,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final sidePanel =
                    MediaQuery.orientationOf(context) == Orientation.landscape && constraints.maxWidth >= 560;
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
                  maxHeight: constraints.maxHeight,
                  sidePanel: sidePanel,
                  settingsExpanded: _settingsExpanded,
                  onToggleSettings: () => setState(() => _settingsExpanded = !_settingsExpanded),
                  mode: _mode,
                  allowTransformEdits: allowTransformEdits,
                  asset: widget.asset,
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
                  onMode: (mode) => setState(() {
                    _mode = mode;
                    _settingsExpanded = mode != EditorMode.draw && mode != EditorMode.shapes;
                    _tool = mode.defaultTool;
                    _selectedId = null;
                  }),
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
                return AbsorbPointer(
                  absorbing: state.isApplyingEdits,
                  child: sidePanel
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: SafeArea(top: false, child: preview)),
                            SizedBox(width: min(320, max(272, constraints.maxWidth * .38)), child: panel),
                          ],
                        )
                      : Column(
                          children: [
                            Expanded(child: preview),
                            if (allowTransformEdits || widget.asset != null) panel,
                          ],
                        ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _EditorBottomPanel extends StatelessWidget {
  final ImageProvider source;
  final double maxHeight;
  final bool sidePanel;
  final bool settingsExpanded;
  final VoidCallback onToggleSettings;
  final EditorMode mode;
  final bool allowTransformEdits;
  final RemoteAsset? asset;
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
    required this.source,
    required this.maxHeight,
    required this.sidePanel,
    required this.settingsExpanded,
    required this.onToggleSettings,
    required this.mode,
    required this.allowTransformEdits,
    required this.asset,
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
  Widget build(BuildContext context) {
    const surface = Color(0xff191919);
    final modeBar = EditorModeBar(
      mode: mode,
      allowTransformEdits: allowTransformEdits,
      hasMagicEraser: asset != null,
      onMode: (next) {
        final active = mode == EditorMode.adjustments
            ? EditorMode.filters
            : mode == EditorMode.shapes
            ? EditorMode.draw
            : mode;
        if (next == active) {
          onToggleSettings();
        } else {
          onMode(next);
        }
      },
    );
    final draw = mode == EditorMode.draw || mode == EditorMode.shapes;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final limit = sidePanel ? maxHeight : max(modeBar.preferredHeight(context) + bottomInset, maxHeight * .34);
    Widget markup({required bool controls}) => MarkupControls(
      mode: mode,
      tool: tool,
      color: color,
      width: width,
      opacity: opacity,
      canUndo: canUndo,
      canRedo: canRedo,
      textStyle: textStyle,
      onTextStyle: onTextStyle,
      onSticker: onSticker,
      onGestureStart: onGestureStart,
      onGestureEnd: onGestureEnd,
      onTool: onTool,
      onColor: onColor,
      onWidth: onWidth,
      onOpacity: onOpacity,
      onUndo: onUndo,
      onRedo: onRedo,
      compact: true,
      isSettingsOpen: settingsExpanded,
      showToolStrip: !controls,
      settingsExpanded: controls,
      onToggleSettings: onToggleSettings,
    );
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: min(maxHeight, limit)),
      child: Container(
        key: const Key('editor-bottom-panel'),
        width: double.infinity,
        decoration: const BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (draw)
                markup(controls: false)
              else if (settingsExpanded)
                Row(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(mode.label(context), maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                    IconButton(
                      key: const Key('editor-toggle-settings'),
                      tooltip: context.tr('collapse'),
                      onPressed: onToggleSettings,
                      icon: const Icon(Icons.expand_more),
                    ),
                  ],
                ),
              if (settingsExpanded)
                Flexible(
                  fit: sidePanel ? FlexFit.tight : FlexFit.loose,
                  child: SingleChildScrollView(
                    key: const Key('editor-active-settings'),
                    primary: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (mode == EditorMode.crop && allowTransformEdits) const _TransformControls(),
                        if (mode == EditorMode.filters || mode == EditorMode.adjustments) ...[
                          Wrap(
                            alignment: WrapAlignment.center,
                            children: [
                              TextButton(
                                key: const Key('editor-color-filters'),
                                onPressed: () => onMode(EditorMode.filters),
                                child: Text(context.t.editor_filters),
                              ),
                              TextButton(
                                key: const Key('editor-color-adjustments'),
                                onPressed: () => onMode(EditorMode.adjustments),
                                child: Text(context.t.editor_adjustments),
                              ),
                            ],
                          ),
                          if (mode == EditorMode.filters) FilterPanel(source: source) else const AdjustmentPanel(),
                        ],
                        if (mode == EditorMode.draw ||
                            mode == EditorMode.text ||
                            mode == EditorMode.shapes ||
                            mode == EditorMode.stickers)
                          markup(controls: true),
                        if (mode == EditorMode.magicEraser && asset != null) _MagicEraserButton(asset: asset!),
                      ],
                    ),
                  ),
                ),
              if (sidePanel && !settingsExpanded) const Spacer(),
              modeBar,
            ],
          ),
        ),
      ),
    );
  }
}

class EditorModeBar extends StatelessWidget {
  final EditorMode mode;
  final bool allowTransformEdits;
  final bool hasMagicEraser;
  final ValueChanged<EditorMode> onMode;

  const EditorModeBar({
    super.key,
    required this.mode,
    required this.allowTransformEdits,
    required this.hasMagicEraser,
    required this.onMode,
  });

  static const _labelStyle = TextStyle(fontSize: 12, height: 1.2);
  static const _modes = [EditorMode.crop, EditorMode.filters, EditorMode.draw, EditorMode.text, EditorMode.stickers];

  double preferredHeight(BuildContext context) => 64;

  @override
  Widget build(BuildContext context) {
    final activeMode = mode == EditorMode.adjustments
        ? EditorMode.filters
        : mode == EditorMode.shapes
        ? EditorMode.draw
        : mode;
    return SizedBox(
      key: const Key('editor-mode-bar'),
      height: preferredHeight(context),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final labels = constraints.maxWidth / _modes.length >= 72 && MediaQuery.textScalerOf(context).scale(12) <= 16;
          return Row(
            children: [
              for (final entry in _modes)
                Expanded(
                  child: Semantics(
                    selected: entry == activeMode,
                    child: Tooltip(
                      message: entry == EditorMode.crop
                          ? context.tr('editor_crop_rotate')
                          : entry == EditorMode.filters
                          ? context.tr('editor_filters_adjustments')
                          : entry.label(context),
                      child: TextButton(
                        key: Key('editor-mode-${entry.name}'),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 48),
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          foregroundColor: entry == activeMode ? Colors.yellow : Colors.white70,
                          backgroundColor: entry == activeMode ? const Color(0xff303030) : null,
                        ),
                        onPressed: allowTransformEdits ? () => onMode(entry) : null,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(entry.icon, size: 24),
                            if (labels) ...[
                              const SizedBox(height: 3),
                              Text(entry.label(context), maxLines: 1, style: _labelStyle),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _MagicEraserButton extends ConsumerWidget {
  final RemoteAsset asset;

  const _MagicEraserButton({required this.asset});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final capability = ref.watch(magicEraserEnabledProvider(asset.id));
    // A refresh can retain the previous result; require a completed check.
    final enabled = !capability.isLoading && !capability.hasError && capability.asData?.value == true;
    final applyingEdits = ref.watch(editorStateProvider.select((state) => state.isApplyingEdits));
    final message = capability.isLoading
        ? context.t.magic_eraser_checking
        : magicEraserAvailabilityMessage(context, capability.error);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: enabled ? context.t.magic_eraser : message,
            child: OutlinedButton(
              key: const Key('magic-eraser-editor-action'),
              onPressed: !enabled || applyingEdits
                  ? null
                  : () => Navigator.of(
                      context,
                    ).push<bool>(MaterialPageRoute(builder: (_) => MagicEraserPage(asset: asset))),
              child: Row(
                children: [
                  const Icon(Icons.auto_fix_high),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      context.t.magic_eraser,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (!enabled)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (capability.isLoading)
                  const Padding(
                    padding: EdgeInsets.only(right: 12),
                    child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                Semantics(liveRegion: true, child: Text(message, style: context.textTheme.bodySmall)),
                if (!capability.isLoading)
                  TextButton(
                    key: const Key('magic-eraser-capability-retry'),
                    onPressed: applyingEdits ? null : () => ref.invalidate(magicEraserEnabledProvider(asset.id)),
                    child: Text(context.t.retry),
                  ),
              ],
            ),
        ],
      ),
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
              : Icon(ratio.icon, color: color),
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
  const _AspectRatioSelector();

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
              onPressed: () => editorNotifier.setAspectRatio(entry),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _TransformControls extends ConsumerWidget {
  const _TransformControls();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editorNotifier = ref.watch(editorStateProvider.notifier);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            spacing: 8,
            children: [
              Tooltip(
                message: context.t.editor_rotate_left,
                child: ImmichIconButton(
                  icon: Icons.rotate_left,
                  variant: ImmichVariant.ghost,
                  color: ImmichColor.secondary,
                  onPressed: editorNotifier.rotateCCW,
                ),
              ),
              Tooltip(
                message: context.t.editor_rotate_right,
                child: ImmichIconButton(
                  icon: Icons.rotate_right,
                  variant: ImmichVariant.ghost,
                  color: ImmichColor.secondary,
                  onPressed: editorNotifier.rotateCW,
                ),
              ),
              Tooltip(
                message: context.t.editor_flip_horizontal,
                child: ImmichIconButton(
                  icon: Icons.flip,
                  variant: ImmichVariant.ghost,
                  color: ImmichColor.secondary,
                  onPressed: editorNotifier.flipHorizontally,
                ),
              ),
              Tooltip(
                message: context.t.editor_flip_vertical,
                child: Transform.rotate(
                  angle: pi / 2,
                  child: ImmichIconButton(
                    icon: Icons.flip,
                    variant: ImmichVariant.ghost,
                    color: ImmichColor.secondary,
                    onPressed: editorNotifier.flipVertically,
                  ),
                ),
              ),
            ],
          ),
        ),
        const _AspectRatioSelector(),
      ],
    );
  }
}

class _SaveEditsButton extends ConsumerWidget {
  final VoidCallback onSave;

  const _SaveEditsButton({required this.onSave});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isApplyingEdits = ref.watch(editorStateProvider.select((state) => state.isApplyingEdits));
    final hasUnsavedEdits = ref.watch(editorStateProvider.select((state) => state.hasUnsavedEdits));

    return isApplyingEdits
        ? const Padding(
            padding: EdgeInsets.all(8.0),
            child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5)),
          )
        : SizedBox(
            width: MediaQuery.sizeOf(context).width < 360 ? 80 : 112,
            child: TextButton.icon(
              key: const Key('editor-save'),
              style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
              icon: MediaQuery.sizeOf(context).width >= 360 && MediaQuery.textScalerOf(context).scale(14) <= 18
                  ? const Icon(Icons.done_rounded)
                  : null,
              onPressed: hasUnsavedEdits ? onSave : null,
              label: FittedBox(fit: BoxFit.scaleDown, child: Text(context.t.save, maxLines: 1)),
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
        final sideways = editorState.rotationAngle % 180 != 0;
        final available = sideways ? Size(constraints.maxHeight, constraints.maxWidth) : constraints.biggest;
        final visibleCrop = widget.mode == EditorMode.crop ? const Rect.fromLTWH(0, 0, 1, 1) : editorState.crop;
        final visibleSize = Size(imageSize.width * visibleCrop.width, imageSize.height * visibleCrop.height);
        final fitted = applyBoxFit(BoxFit.contain, visibleSize, available).destination;
        final fullSize = Size(fitted.width / visibleCrop.width, fitted.height / visibleCrop.height);

        // Rotate layout and hit testing together. The stack has the decoded
        // image's aspect ratio, so normalized annotations never include letterbox.
        final transformedPreview = RotatedBox(
          quarterTurns: editorState.rotationAngle ~/ 90,
          child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..scaleByDouble(editorState.flipHorizontal ? -1.0 : 1.0, editorState.flipVertical ? -1.0 : 1.0, 1.0, 1.0),
            child: SizedBox(
              key: const Key('editor-image-surface'),
              width: fitted.width,
              height: fitted.height,
              child: ClipRect(
                child: Stack(
                  children: [
                    Positioned(
                      left: -visibleCrop.left * fullSize.width,
                      top: -visibleCrop.top * fullSize.height,
                      width: fullSize.width,
                      height: fullSize.height,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          IgnorePointer(
                            ignoring: widget.mode != EditorMode.crop,
                            child: Listener(
                              onPointerDown: (_) => ref.read(editorStateProvider.notifier).beginGesture(),
                              onPointerUp: (_) => ref.read(editorStateProvider.notifier).endGesture(),
                              onPointerCancel: (_) => ref.read(editorStateProvider.notifier).endGesture(),
                              child: FilteredImage(
                                editorState: editorState,
                                image: widget.image,
                                cropController: cropController,
                                mode: widget.mode,
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
                  ],
                ),
              ),
            ),
          ),
        );

        return EditorViewport(
          key: const Key('editor-preview-viewport'),
          contentSize: sideways ? Size(fitted.height, fitted.width) : fitted,
          navigationActive: _navigationActive,
          objectTransformActive: _objectTransformActive,
          child: RepaintBoundary(child: transformedPreview),
        );
      },
    );
  }
}
