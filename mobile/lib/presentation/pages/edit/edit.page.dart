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
import 'package:immich_mobile/presentation/pages/edit/widgets/adjustment_panel.dart';
import 'package:immich_mobile/presentation/pages/edit/widgets/filter_panel.dart';
import 'package:immich_mobile/presentation/pages/edit/widgets/filtered_image.dart';
import 'package:immich_mobile/presentation/pages/edit/widgets/markup_controls.dart';
import 'package:immich_mobile/presentation/widgets/images/remote_image_provider.dart';
import 'package:immich_mobile/providers/theme.provider.dart';
import 'package:immich_mobile/repositories/file_media.repository.dart';
import 'package:immich_mobile/theme/theme_data.dart';
import 'package:immich_mobile/utils/annotation_editor.dart';
import 'package:immich_mobile/utils/edited_image_exporter.dart';
import 'package:immich_mobile/utils/editor_geometry.dart';
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
  bool _straightening = false;
  bool _magicEraserOpen = false;
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
    _settingsExpanded = false;
  }

  Future<void> _openMagicEraser() async {
    if (_magicEraserOpen || ref.read(editorStateProvider).isApplyingEdits) {
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
          await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => MagicEraserPage(asset: asset)));
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
        child: Builder(
          builder: (context) => Scaffold(
            appBar: AppBar(
              toolbarHeight: _editorHeaderHeight(context),
              backgroundColor: Colors.black,
              leadingWidth: 48,
              leading: IconButton(
                key: const Key('editor-back'),
                tooltip: context.t.back,
                onPressed: state.isApplyingEdits ? null : () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back),
              ),
              actions: [
                IconButton(
                  key: const Key('editor-header-undo'),
                  tooltip: context.t.undo,
                  onPressed: !state.isApplyingEdits && state.canUndo ? notifier.undo : null,
                  icon: const Icon(Icons.undo),
                ),
                IconButton(
                  key: const Key('editor-header-redo'),
                  tooltip: context.t.magic_eraser_redo,
                  onPressed: !state.isApplyingEdits && state.canRedo ? notifier.redo : null,
                  icon: const Icon(Icons.redo),
                ),
                _SaveEditsButton(onSave: _saveCopy, enabled: allowTransformEdits),
              ],
            ),
            backgroundColor: Colors.black,
            body: SafeArea(
              bottom: false,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final sidePanel =
                      MediaQuery.orientationOf(context) == Orientation.landscape && constraints.maxWidth >= 480;
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
                    maxHeight: constraints.maxHeight,
                    sidePanel: sidePanel,
                    settingsExpanded: _settingsExpanded,
                    onToggleSettings: () => setState(() => _settingsExpanded = !_settingsExpanded),
                    mode: _mode,
                    allowTransformEdits: allowTransformEdits,
                    asset: widget.asset,
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
                        _settingsExpanded = mode != EditorMode.draw && mode != EditorMode.shapes;
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
                  return Stack(
                    children: [
                      Positioned.fill(child: content),
                      if (state.isApplyingEdits && !_writingCopy)
                        Positioned(
                          top: 8,
                          right: 8,
                          child: Material(
                            color: const Color(0xff191919),
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

class _EditorBottomPanel extends StatelessWidget {
  final ImageProvider source;
  final double maxHeight;
  final bool sidePanel;
  final bool settingsExpanded;
  final VoidCallback onToggleSettings;
  final EditorMode mode;
  final bool allowTransformEdits;
  final RemoteAsset? asset;
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
    required this.source,
    required this.maxHeight,
    required this.sidePanel,
    required this.settingsExpanded,
    required this.onToggleSettings,
    required this.mode,
    required this.allowTransformEdits,
    required this.asset,
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
        if (next == EditorMode.magicEraser) {
          onMode(next);
        } else if (next == active) {
          onToggleSettings();
        } else {
          onMode(next);
        }
      },
    );
    final draw = mode == EditorMode.draw || mode == EditorMode.shapes;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final footerHeight = modeBar.preferredHeight(context) + bottomInset;
    // A keyboard can leave less room than even the primary toolbar. Keep the
    // document and restore the controls when space returns, without overflow.
    if (maxHeight < footerHeight) {
      return const SizedBox.shrink();
    }
    const headerHeight = 48.0;
    final canvasReserve = sidePanel ? 0.0 : min(maxHeight - footerHeight, min(120.0, maxHeight * .35));
    final auxiliaryFits = maxHeight - canvasReserve >= footerHeight + headerHeight + (settingsExpanded ? 48 : 0);
    final showSettings = settingsExpanded && auxiliaryFits;
    final minimumHeight =
        footerHeight + (auxiliaryFits && (draw || showSettings) ? headerHeight : 0) + (showSettings ? 48 : 0);
    final limit = sidePanel ? maxHeight : min(maxHeight - canvasReserve, max(minimumHeight, maxHeight * .32));
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
              if (draw && auxiliaryFits)
                markup(controls: false)
              else if (showSettings)
                Row(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(mode.label(context), maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                    _SecondaryEditorTools(
                      allowTransformEdits: allowTransformEdits,
                      onMode: onMode,
                      onReset: onReset,
                      onLayers: onLayers,
                    ),
                    IconButton(
                      key: const Key('editor-toggle-settings'),
                      tooltip: context.tr('collapse'),
                      onPressed: onToggleSettings,
                      icon: const Icon(Icons.expand_more),
                    ),
                  ],
                ),
              if (showSettings)
                Flexible(
                  fit: sidePanel ? FlexFit.tight : FlexFit.loose,
                  child: SingleChildScrollView(
                    key: const Key('editor-active-settings'),
                    primary: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (draw)
                          _SecondaryEditorTools(
                            allowTransformEdits: allowTransformEdits,
                            onMode: onMode,
                            onReset: onReset,
                            onLayers: onLayers,
                          ),
                        if (mode == EditorMode.crop && allowTransformEdits) ...[
                          Wrap(
                            alignment: WrapAlignment.center,
                            children: [
                              TextButton(
                                key: const Key('editor-crop-frame'),
                                onPressed: () => onStraightening(false),
                                child: Text(context.t.editor_crop_frame),
                              ),
                              TextButton(
                                key: const Key('editor-crop-straighten'),
                                onPressed: () => onStraightening(true),
                                child: Text(context.t.editor_straighten),
                              ),
                            ],
                          ),
                          if (straightening) const _StraightenControls() else const _TransformControls(),
                        ],
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
                      ],
                    ),
                  ),
                ),
              if (sidePanel && !showSettings) const Spacer(),
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
  static const _modes = [EditorMode.crop, EditorMode.draw, EditorMode.text, EditorMode.magicEraser];

  double preferredHeight(BuildContext context) => max(56, 36 + MediaQuery.textScalerOf(context).scale(12) * 2.4);

  @override
  Widget build(BuildContext context) {
    final activeMode = switch (mode) {
      EditorMode.adjustments || EditorMode.filters => EditorMode.crop,
      EditorMode.shapes || EditorMode.stickers => EditorMode.draw,
      _ => mode,
    };
    return SizedBox(
      key: const Key('editor-mode-bar'),
      height: preferredHeight(context),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Keep readable labels at the user's actual text scale. At large
          // accessibility sizes the four tools scroll rather than hiding text.
          final labelStyle = _labelStyle.copyWith(
            fontFamily: Theme.of(context).textTheme.labelSmall?.fontFamily,
            fontWeight: FontWeight.w500,
          );
          final widths = _modes.map((entry) {
            final label = entry.label(context);
            final longest = label.split(RegExp(r'\s+')).reduce((a, b) => a.length >= b.length ? a : b);
            final painter = TextPainter(
              text: TextSpan(text: longest, style: labelStyle),
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
            )..layout();
            final width = max(48.0, painter.width.ceilToDouble() + 18);
            painter.dispose();
            return width;
          }).toList();
          final total = widths.fold<double>(0, (sum, width) => sum + width);
          final spare = max(0.0, constraints.maxWidth - total) / _modes.length;
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var index = 0; index < _modes.length; index++)
                  SizedBox(
                    width: widths[index] + spare,
                    height: preferredHeight(context),
                    child: Semantics(
                      selected: _modes[index] == activeMode,
                      child: TextButton(
                        key: Key('editor-mode-${_modes[index].name}'),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          foregroundColor: _modes[index] == activeMode ? Colors.yellow : Colors.white70,
                          backgroundColor: _modes[index] == activeMode ? const Color(0xff303030) : null,
                        ),
                        onPressed: allowTransformEdits || _modes[index] == EditorMode.magicEraser
                            ? () => onMode(_modes[index])
                            : null,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(_modes[index].icon, size: 24),
                            const SizedBox(height: 2),
                            Text(_modes[index].label(context), textAlign: TextAlign.center, style: labelStyle),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SecondaryEditorTools extends StatelessWidget {
  final bool allowTransformEdits;
  final ValueChanged<EditorMode> onMode;
  final VoidCallback onReset;
  final VoidCallback onLayers;

  const _SecondaryEditorTools({
    required this.allowTransformEdits,
    required this.onMode,
    required this.onReset,
    required this.onLayers,
  });

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    key: const Key('editor-more'),
    tooltip: context.t.editor_tools_more,
    icon: const Icon(Icons.more_horiz),
    onSelected: (value) {
      switch (value) {
        case 'reset':
          onReset();
        case 'layers':
          onLayers();
        case 'filters':
          onMode(EditorMode.filters);
        case 'stickers':
          onMode(EditorMode.stickers);
      }
    },
    itemBuilder: (context) => [
      PopupMenuItem(
        key: const Key('editor-reset'),
        value: 'reset',
        enabled: allowTransformEdits,
        child: Text(context.t.editor_revert),
      ),
      PopupMenuItem(value: 'layers', enabled: allowTransformEdits, child: Text(context.t.editor_layers)),
      PopupMenuItem(
        key: const Key('editor-mode-filters'),
        value: 'filters',
        enabled: allowTransformEdits,
        child: Text(context.t.editor_filters),
      ),
      PopupMenuItem(
        key: const Key('editor-mode-stickers'),
        value: 'stickers',
        enabled: allowTransformEdits,
        child: Text(context.t.editor_stickers),
      ),
    ],
  );
}

class _StraightenControls extends ConsumerWidget {
  const _StraightenControls();

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
          onChangeEnd: (_) => notifier.endGesture(),
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

TextStyle _editorSaveLabelStyle(BuildContext context) => TextStyle(
  fontSize: 14,
  height: 1.2,
  fontWeight: FontWeight.w500,
  fontFamily: Theme.of(context).textTheme.labelLarge?.fontFamily,
);

double _editorSaveWidth(BuildContext context) {
  final available = MediaQuery.sizeOf(context).width - MediaQuery.paddingOf(context).horizontal - 144;
  final painter = TextPainter(
    text: TextSpan(
      text: context.t.magic_eraser_save_copy.replaceFirst(' ', '\n'),
      style: _editorSaveLabelStyle(context),
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout();
  final width = min(max(48.0, available), max(112.0, painter.width.ceilToDouble() + 18));
  painter.dispose();
  return width;
}

double _editorHeaderHeight(BuildContext context) {
  final painter = TextPainter(
    text: TextSpan(
      text: context.t.magic_eraser_save_copy.replaceFirst(' ', '\n'),
      style: _editorSaveLabelStyle(context),
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout(maxWidth: max(1, _editorSaveWidth(context) - 16));
  final height = max(56.0, painter.height + 16);
  painter.dispose();
  return height;
}

class _SaveEditsButton extends ConsumerWidget {
  final VoidCallback onSave;
  final bool enabled;

  const _SaveEditsButton({required this.onSave, required this.enabled});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isApplyingEdits = ref.watch(editorStateProvider.select((state) => state.isApplyingEdits));
    final hasUnsavedEdits = ref.watch(editorStateProvider.select((state) => state.hasUnsavedEdits));
    return SizedBox(
      width: _editorSaveWidth(context),
      height: _editorHeaderHeight(context),
      child: TextButton(
        key: const Key('editor-save'),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(48, 48),
        ),
        onPressed: enabled && hasUnsavedEdits && !isApplyingEdits ? onSave : null,
        child: Tooltip(
          message: context.t.magic_eraser_save_copy,
          child: Semantics(
            label: context.t.magic_eraser_save_copy,
            excludeSemantics: true,
            child: isApplyingEdits
                ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
                : Text(
                    context.t.magic_eraser_save_copy.replaceFirst(' ', '\n'),
                    textAlign: TextAlign.center,
                    style: _editorSaveLabelStyle(context),
                  ),
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
