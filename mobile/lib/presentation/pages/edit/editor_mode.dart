import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/models/annotation.model.dart';

/// Editor modes for the image editor.
enum EditorMode { crop, adjustments, filters, draw, text, shapes, stickers, magicEraser }

extension EditorModeExtension on EditorMode {
  AnnotationTool get defaultTool => switch (this) {
    EditorMode.draw => AnnotationTool.pen,
    EditorMode.text => AnnotationTool.text,
    EditorMode.shapes => AnnotationTool.rectangle,
    EditorMode.stickers => AnnotationTool.move,
    _ => AnnotationTool.pen,
  };

  IconData get icon => switch (this) {
    EditorMode.crop => Icons.crop,
    EditorMode.adjustments => Icons.tune,
    EditorMode.filters => Icons.filter,
    EditorMode.draw => Icons.draw,
    EditorMode.text => Icons.title,
    EditorMode.shapes => Icons.category_outlined,
    EditorMode.stickers => Icons.emoji_emotions_outlined,
    EditorMode.magicEraser => Icons.auto_fix_high,
  };

  String label(BuildContext context) => switch (this) {
    EditorMode.crop => context.tr('editor_tool_crop'),
    EditorMode.adjustments => context.tr('editor_adjustments'),
    EditorMode.filters => context.tr('editor_filters'),
    EditorMode.draw => context.tr('editor_tool_markup'),
    EditorMode.text => context.tr('editor_text'),
    EditorMode.shapes => context.tr('editor_shapes'),
    EditorMode.stickers => context.tr('editor_stickers'),
    EditorMode.magicEraser => context.tr('magic_eraser'),
  };
}
