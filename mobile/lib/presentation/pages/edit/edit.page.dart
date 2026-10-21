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
import 'package:openapi/api.dart' show ApiException;
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
  Color _color = Colors.red;
  double _strokeWidth = 5;
  double _opacity = 1;

  @override
  void initState() {
    super.initState();
    _mode = widget.asset?.isEditable ?? true ? EditorMode.crop : EditorMode.magicEraser;
  }

  Future<void> _saveCopy() async {
    ref.read(editorStateProvider.notifier).setIsEditing(true);
    String? path;
    ui.Image? source;
    ui.Image? rendered;
    var saved = false;
    try {
      source = await _loadOriginalImage();
      if (!mounted) {
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
      final bytes = await EditedImageExporter.encodePng(rendered);
      final directory = await getTemporaryDirectory();
      path = '${directory.path}/gallery-edit-${DateTime.now().microsecondsSinceEpoch}.png';
      await File(path).writeAsBytes(bytes, flush: true);
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
    } catch (_) {
      if (mounted) {
        ImmichToast.show(context: context, msg: context.t.error_title, toastType: ToastType.error);
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
      ImmichToast.show(context: context, msg: context.t.success, toastType: ToastType.success);
      Navigator.of(context).pop();
    }
  }

  Future<ui.Image> _loadOriginalImage() async {
    final provider = widget.asset == null
        ? widget.image.image
        : RemoteImageProvider(url: getOriginalUrlForRemoteId(widget.asset!.id, edited: false), edited: false);
    final image = await EditedImageExporter.loadSource(provider);
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
    _annotations.add(
      AnnotationElement(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        tool: AnnotationTool.text,
        points: [point],
        color: _color,
        width: relativeWidth,
        opacity: _opacity,
        text: text.trim(),
      ),
    );
    _syncAnnotationDirty();
    setState(() {});
  }

  void _syncAnnotationDirty() {
    ref.read(editorStateProvider.notifier).setAnnotationsEdited(_annotations.elements.isNotEmpty);
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
    final hasUnsavedEdits = ref.watch(editorStateProvider.select((state) => state.hasUnsavedEdits));
    final allowTransformEdits = widget.asset?.isEditable ?? true;

    return PopScope(
      canPop: !hasUnsavedEdits,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) {
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
            title: Text(
              _mode.label(context),
              key: const Key('editor-mode-title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            leading: ImmichCloseButton(onPressed: () => Navigator.of(context).maybePop()),
            actions: [if (allowTransformEdits) _SaveEditsButton(onSave: _chooseSaveMode)],
          ),
          backgroundColor: Colors.black,
          body: SafeArea(
            bottom: false,
            child: LayoutBuilder(
              builder: (context, constraints) => Column(
                children: [
                  Expanded(
                    child: allowTransformEdits
                        ? _EditorPreview(
                            image: widget.image,
                            annotations: _annotations,
                            tool: _tool,
                            color: _color,
                            width: _strokeWidth,
                            opacity: _opacity,
                            mode: _mode,
                            onTextPosition: _addText,
                            onEditText: _editText,
                            onChanged: (_) {
                              _syncAnnotationDirty();
                              setState(() {});
                            },
                          )
                        : Center(child: InteractiveViewer(child: widget.image)),
                  ),
                  if (allowTransformEdits || widget.asset != null)
                    _EditorBottomPanel(
                      source: widget.image.image,
                      maxHeight: constraints.maxHeight / 2,
                      mode: _mode,
                      allowTransformEdits: allowTransformEdits,
                      asset: widget.asset,
                      tool: _tool,
                      color: _color,
                      width: _strokeWidth,
                      opacity: _opacity,
                      annotations: _annotations,
                      onReset: () {
                        _annotations.clear();
                        _syncAnnotationDirty();
                        ref.read(editorStateProvider.notifier).resetEdits();
                        setState(() {});
                      },
                      onMode: (mode) => setState(() {
                        _mode = mode;
                        _tool = mode.defaultTool;
                      }),
                      onTool: (tool) => setState(() => _tool = tool),
                      onColor: (color) => setState(() => _color = color),
                      onWidth: (width) => setState(() => _strokeWidth = width),
                      onOpacity: (opacity) => setState(() => _opacity = opacity),
                      onUndo: () {
                        _annotations.undo();
                        _syncAnnotationDirty();
                        setState(() {});
                      },
                      onRedo: () {
                        _annotations.redo();
                        _syncAnnotationDirty();
                        setState(() {});
                      },
                    ),
                ],
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
  final EditorMode mode;
  final bool allowTransformEdits;
  final RemoteAsset? asset;
  final AnnotationTool tool;
  final Color color;
  final double width;
  final double opacity;
  final AnnotationEditor annotations;
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
    required this.mode,
    required this.allowTransformEdits,
    required this.asset,
    required this.tool,
    required this.color,
    required this.width,
    required this.opacity,
    required this.annotations,
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
    final surface = Theme.of(context).colorScheme.surface;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Container(
        key: const Key('editor-bottom-panel'),
        width: double.infinity,
        decoration: BoxDecoration(
          color: surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  key: const Key('editor-active-settings'),
                  primary: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (mode == EditorMode.crop && allowTransformEdits) _TransformControls(onReset: onReset),
                      if (mode == EditorMode.adjustments) const AdjustmentPanel(),
                      if (mode == EditorMode.filters) FilterPanel(source: source),
                      if (mode == EditorMode.draw || mode == EditorMode.text || mode == EditorMode.shapes)
                        _MarkupControls(
                          mode: mode,
                          tool: tool,
                          color: color,
                          width: width,
                          opacity: opacity,
                          canUndo: annotations.canUndo,
                          canRedo: annotations.canRedo,
                          onTool: onTool,
                          onColor: onColor,
                          onWidth: onWidth,
                          onOpacity: onOpacity,
                          onUndo: onUndo,
                          onRedo: onRedo,
                        ),
                      if (mode == EditorMode.magicEraser && asset != null) _MagicEraserButton(asset: asset!),
                    ],
                  ),
                ),
              ),
              EditorModeBar(
                mode: mode,
                allowTransformEdits: allowTransformEdits,
                hasMagicEraser: asset != null,
                onMode: onMode,
              ),
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

  @override
  Widget build(BuildContext context) {
    final modes = [
      if (allowTransformEdits) ...const [
        EditorMode.crop,
        EditorMode.adjustments,
        EditorMode.filters,
        EditorMode.draw,
        EditorMode.text,
        EditorMode.shapes,
      ],
      if (hasMagicEraser) EditorMode.magicEraser,
    ];
    final colors = Theme.of(context).colorScheme;
    const labelStyle = TextStyle(fontSize: 12, height: 1.2);
    final labelPainter = TextPainter(
      text: TextSpan(text: modes.map((entry) => entry.label(context)).join(' '), style: labelStyle),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.localeOf(context),
      maxLines: 1,
    )..layout();
    final barHeight = max(64.0, 44 + labelPainter.height.ceilToDouble());
    labelPainter.dispose();
    return SizedBox(
      key: const Key('editor-mode-bar'),
      height: barHeight,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        scrollDirection: Axis.horizontal,
        child: Row(
          spacing: 8,
          children: [
            for (final entry in modes)
              Semantics(
                selected: entry == mode,
                child: Tooltip(
                  message: entry.label(context),
                  child: TextButton(
                    key: Key('editor-mode-${entry.name}'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(64, 48),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      foregroundColor: entry == mode ? colors.onSecondaryContainer : colors.onSurface,
                      backgroundColor: entry == mode ? colors.secondaryContainer : null,
                    ),
                    onPressed: () => onMode(entry),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 100),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(entry.icon, size: 24),
                          const SizedBox(height: 4),
                          Text(entry.label(context), maxLines: 1, overflow: TextOverflow.ellipsis, style: labelStyle),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
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
        : switch (capability.error) {
            ApiException(code: 401) => context.t.magic_eraser_sign_in_required,
            ApiException(code: 403) => context.t.magic_eraser_access_denied,
            ApiException(code: 400) => context.t.magic_eraser_unsupported_photo,
            _ => capability.hasError ? context.t.magic_eraser_check_failed : context.t.magic_eraser_unavailable,
          };
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: enabled ? context.t.magic_eraser : message,
            child: OutlinedButton.icon(
              key: const Key('magic-eraser-editor-action'),
              icon: const Icon(Icons.auto_fix_high),
              label: Text(context.t.magic_eraser),
              onPressed: !enabled || applyingEdits
                  ? null
                  : () => Navigator.of(
                      context,
                    ).push<bool>(MaterialPageRoute(builder: (_) => MagicEraserPage(asset: asset))),
            ),
          ),
          if (!enabled)
            Row(
              children: [
                if (capability.isLoading)
                  const Padding(
                    padding: EdgeInsets.only(right: 12),
                    child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                Expanded(
                  child: Semantics(liveRegion: true, child: Text(message, style: context.textTheme.bodySmall)),
                ),
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
  final VoidCallback onReset;

  const _TransformControls({required this.onReset});

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
              _ResetEditsButton(onPressed: onReset),
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
        : ImmichIconButton(
            icon: Icons.done_rounded,
            color: ImmichColor.primary,
            variant: ImmichVariant.ghost,
            disabled: !hasUnsavedEdits,
            onPressed: onSave,
          );
  }
}

class _ResetEditsButton extends ConsumerWidget {
  final VoidCallback onPressed;

  const _ResetEditsButton({required this.onPressed});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editorState = ref.watch(editorStateProvider);
    return ImmichTextButton(
      key: const Key('editor-reset'),
      labelText: context.t.reset,
      onPressed: onPressed,
      variant: ImmichVariant.ghost,
      expanded: false,
      disabled: !editorState.hasEdits || editorState.isApplyingEdits,
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

  const _EditorPreview({
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
  });

  @override
  ConsumerState<_EditorPreview> createState() => _EditorPreviewState();
}

class _EditorPreviewState extends ConsumerState<_EditorPreview> {
  late final CropController cropController;
  final _navigationActive = ValueNotifier(false);
  Rect? _cropBeforeNavigation;
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editorState = ref.watch(editorStateProvider);

    ref.listen(editorStateProvider, (previous, current) {
      // Only re-apply the aspect ratio when it changes, otherwise the crop rect will shrink on every rotation
      if (previous?.aspectRatio != current.aspectRatio) {
        double? ratio;

        ratio = switch (current.aspectRatio) {
          CropAspectRatio.original => current.originalWidth / current.originalHeight,
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
    });

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final imageSize = _imageSize;
        if (imageSize == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final sideways = editorState.rotationAngle % 180 != 0;
        final available = sideways ? Size(constraints.maxHeight, constraints.maxWidth) : constraints.biggest;
        final fitted = applyBoxFit(BoxFit.contain, imageSize, available).destination;

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
              child: Stack(
                fit: StackFit.expand,
                children: [
                  IgnorePointer(
                    ignoring: widget.mode != EditorMode.crop,
                    child: FilteredImage(
                      editorState: editorState,
                      image: widget.image,
                      cropController: cropController,
                      mode: widget.mode,
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
                      enabled:
                          widget.mode == EditorMode.draw ||
                          widget.mode == EditorMode.text ||
                          widget.mode == EditorMode.shapes,
                      onTextPosition: widget.onTextPosition,
                      onEditText: widget.onEditText,
                      onChanged: widget.onChanged,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

        return EditorViewport(
          key: const Key('editor-preview-viewport'),
          contentSize: sideways ? Size(fitted.height, fitted.width) : fitted,
          navigationActive: _navigationActive,
          child: RepaintBoundary(child: transformedPreview),
        );
      },
    );
  }
}

class _MarkupControls extends StatelessWidget {
  final EditorMode mode;
  final AnnotationTool tool;
  final Color color;
  final double width;
  final double opacity;
  final bool canUndo;
  final bool canRedo;
  final ValueChanged<AnnotationTool> onTool;
  final ValueChanged<Color> onColor;
  final ValueChanged<double> onWidth;
  final ValueChanged<double> onOpacity;
  final VoidCallback onUndo;
  final VoidCallback onRedo;

  const _MarkupControls({
    required this.mode,
    required this.tool,
    required this.color,
    required this.width,
    required this.opacity,
    required this.canUndo,
    required this.canRedo,
    required this.onTool,
    required this.onColor,
    required this.onWidth,
    required this.onOpacity,
    required this.onUndo,
    required this.onRedo,
  });

  @override
  Widget build(BuildContext context) {
    const colors = [Colors.white, Colors.red, Colors.orange, Colors.yellow, Colors.green, Colors.blue, Colors.purple];
    final tools = switch (mode) {
      EditorMode.draw => const [
        (AnnotationTool.pen, Icons.edit),
        (AnnotationTool.brush, Icons.brush),
        (AnnotationTool.highlighter, Icons.highlight),
        (AnnotationTool.eraser, Icons.auto_fix_off),
        (AnnotationTool.move, Icons.open_with),
      ],
      EditorMode.shapes => const [
        (AnnotationTool.arrow, Icons.arrow_forward),
        (AnnotationTool.rectangle, Icons.crop_square),
        (AnnotationTool.ellipse, Icons.circle_outlined),
        (AnnotationTool.move, Icons.open_with),
      ],
      _ => const [(AnnotationTool.text, Icons.title), (AnnotationTool.move, Icons.open_with)],
    };
    return Material(
      key: const Key('editor-markup-controls'),
      color: Colors.black.withValues(alpha: .78),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (tools.length > 1)
                  DropdownButton<AnnotationTool>(
                    key: const Key('annotation-tool-picker'),
                    value: tool,
                    dropdownColor: Colors.grey.shade900,
                    underline: const SizedBox.shrink(),
                    icon: const Icon(Icons.arrow_drop_down, color: Colors.white),
                    items: tools
                        .map(
                          (entry) => DropdownMenuItem(
                            value: entry.$1,
                            child: Icon(entry.$2, color: Colors.white),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        onTool(value);
                      }
                    },
                  )
                else
                  Icon(tools.single.$2, color: Colors.white),
                IconButton(
                  key: const Key('annotation-undo'),
                  tooltip: context.t.undo,
                  onPressed: canUndo ? onUndo : null,
                  icon: const Icon(Icons.undo, color: Colors.white),
                ),
                IconButton(
                  key: const Key('annotation-redo'),
                  tooltip: context.t.magic_eraser_redo,
                  onPressed: canRedo ? onRedo : null,
                  icon: const Icon(Icons.redo, color: Colors.white),
                ),
              ],
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  Text(context.t.color, style: const TextStyle(color: Colors.white, fontSize: 12)),
                  for (final candidate in colors)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: () => onColor(candidate),
                      icon: Icon(Icons.circle, color: candidate, size: 18),
                    ),
                ],
              ),
            ),
            Row(
              children: [
                Text(context.t.size, style: const TextStyle(color: Colors.white, fontSize: 12)),
                Expanded(
                  child: Slider(key: const Key('annotation-width'), min: 1, max: 32, value: width, onChanged: onWidth),
                ),
                const Icon(Icons.opacity, color: Colors.white, size: 18),
                Expanded(
                  child: Slider(
                    key: const Key('annotation-opacity'),
                    min: .1,
                    max: 1,
                    value: opacity,
                    onChanged: onOpacity,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
