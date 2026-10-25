import 'dart:math';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/models/annotation.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/pages/edit/editor_mode.dart';

/// Original vector chrome; no Samsung artwork or downloaded fonts are used.
class MarkupControls extends StatelessWidget {
  final EditorMode mode;
  final AnnotationTool tool;
  final Color color;
  final double width;
  final double opacity;
  final bool canUndo;
  final bool canRedo;
  final AnnotationElement textStyle;
  final ValueChanged<AnnotationElement> onTextStyle;
  final ValueChanged<String> onSticker;
  final ValueChanged<AnnotationTool> onTool;
  final ValueChanged<Color> onColor;
  final ValueChanged<double> onWidth;
  final ValueChanged<double> onOpacity;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onGestureStart;
  final VoidCallback onGestureEnd;
  final bool compact;
  final bool showToolStrip;
  final bool settingsExpanded;
  final bool isSettingsOpen;
  final VoidCallback? onToggleSettings;

  const MarkupControls({
    super.key,
    this.compact = false,
    this.showToolStrip = true,
    this.settingsExpanded = true,
    this.isSettingsOpen = false,
    this.onToggleSettings,
    required this.mode,
    required this.tool,
    required this.color,
    required this.width,
    required this.opacity,
    required this.canUndo,
    required this.canRedo,
    required this.textStyle,
    required this.onTextStyle,
    required this.onSticker,
    required this.onTool,
    required this.onColor,
    required this.onWidth,
    required this.onOpacity,
    required this.onUndo,
    required this.onRedo,
    required this.onGestureStart,
    required this.onGestureEnd,
  });

  @override
  Widget build(BuildContext context) {
    const palette = [
      Colors.white,
      Colors.black,
      Colors.red,
      Colors.orange,
      Colors.yellow,
      Colors.green,
      Colors.blue,
      Colors.purple,
    ];
    final draw = mode == EditorMode.draw || mode == EditorMode.shapes;
    final tools = draw
        ? const [
            AnnotationTool.pen,
            AnnotationTool.highlighter,
            AnnotationTool.brush,
            AnnotationTool.eraser,
            AnnotationTool.move,
            AnnotationTool.arrow,
            AnnotationTool.rectangle,
            AnnotationTool.ellipse,
          ]
        : const [AnnotationTool.text, AnnotationTool.move];
    String label(AnnotationTool value) => switch (value) {
      AnnotationTool.pen => context.tr('editor_pen'),
      AnnotationTool.highlighter => context.tr('editor_marker'),
      AnnotationTool.brush => context.tr('editor_brush'),
      AnnotationTool.eraser => context.tr('editor_stroke_eraser'),
      AnnotationTool.move => context.tr('editor_select'),
      AnnotationTool.arrow => context.tr('editor_arrow'),
      AnnotationTool.rectangle => context.tr('editor_rectangle'),
      AnnotationTool.ellipse => context.tr('editor_ellipse'),
      _ => context.t.editor_text,
    };
    IconData icon(AnnotationTool value) => switch (value) {
      AnnotationTool.pen => Icons.edit_outlined,
      AnnotationTool.highlighter => Icons.border_color,
      AnnotationTool.brush => Icons.brush,
      AnnotationTool.eraser => Icons.auto_fix_off,
      AnnotationTool.move => Icons.open_with,
      AnnotationTool.arrow => Icons.arrow_forward,
      AnnotationTool.rectangle => Icons.crop_square,
      AnnotationTool.ellipse => Icons.circle_outlined,
      _ => Icons.title,
    };
    Widget history(bool undo) => IconButton(
      key: Key(undo ? 'annotation-undo' : 'annotation-redo'),
      tooltip: undo ? context.t.undo : context.t.magic_eraser_redo,
      onPressed: (undo ? canUndo : canRedo) ? (undo ? onUndo : onRedo) : null,
      icon: Icon(undo ? Icons.undo : Icons.redo),
    );
    final menuWidth = min(264.0, MediaQuery.sizeOf(context).width - 32);
    final selectedToolWidth = min(180.0, MediaQuery.sizeOf(context).width * .45);
    return Material(
      key: Key(compact && draw && !showToolStrip ? 'editor-markup-settings' : 'editor-markup-controls'),
      color: const Color(0xff191919),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: compact && !settingsExpanded ? 0 : 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (draw && showToolStrip)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DecoratedBox(
                  key: const Key('editor-drawing-pill'),
                  decoration: BoxDecoration(color: const Color(0xff303030), borderRadius: BorderRadius.circular(32)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final entry in [
                        AnnotationTool.pen,
                        AnnotationTool.highlighter,
                        AnnotationTool.brush,
                        AnnotationTool.eraser,
                      ])
                        IconButton(
                          key: Key('editor-tool-${entry.name}'),
                          tooltip: label(entry),
                          isSelected: tool == entry,
                          style: IconButton.styleFrom(
                            shape: const CircleBorder(),
                            backgroundColor: tool == entry ? const Color(0xff5a5122) : Colors.transparent,
                          ),
                          selectedIcon: Icon(
                            icon(entry),
                            color: entry == AnnotationTool.pen
                                ? Colors.blue
                                : entry == AnnotationTool.highlighter
                                ? Colors.purple
                                : Colors.yellow,
                          ),
                          icon: Icon(
                            icon(entry),
                            color: entry == AnnotationTool.pen
                                ? Colors.blue
                                : entry == AnnotationTool.highlighter
                                ? Colors.purple
                                : Colors.white,
                          ),
                          onPressed: () => onTool(entry),
                        ),
                      const SizedBox(height: 28, child: VerticalDivider(width: 12)),
                      if (!compact) ...[history(true), history(false)],
                      if (compact)
                        IconButton(
                          key: const Key('editor-toggle-settings'),
                          tooltip: context.tr(isSettingsOpen ? 'collapse' : 'settings'),
                          onPressed: onToggleSettings,
                          icon: Icon(isSettingsOpen ? Icons.expand_more : Icons.tune),
                        ),
                    ],
                  ),
                ),
              ),
            if (settingsExpanded) ...[
              if (mode == EditorMode.stickers)
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final sticker in [
                        ('star', Icons.star),
                        ('heart', Icons.favorite),
                        ('smile', Icons.sentiment_satisfied_alt),
                      ])
                        IconButton(
                          key: Key('editor-sticker-${sticker.$1}'),
                          tooltip: '${context.tr('editor_stickers')}: ${sticker.$1}',
                          onPressed: () => onSticker(sticker.$1),
                          icon: ['star', 'heart', 'smile'].contains(sticker.$1)
                              ? Icon(sticker.$2, color: color)
                              : Text(sticker.$1, style: const TextStyle(fontSize: 32)),
                          iconSize: 36,
                        ),
                    ],
                  ),
                ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (mode != EditorMode.stickers)
                      DropdownButton<AnnotationTool>(
                        key: const Key('annotation-tool-picker'),
                        value: tools.contains(tool) ? tool : tools.first,
                        underline: const SizedBox.shrink(),
                        dropdownColor: const Color(0xff303030),
                        borderRadius: BorderRadius.circular(16),
                        menuWidth: menuWidth,
                        menuMaxHeight: min(288, MediaQuery.sizeOf(context).height * .35),
                        itemHeight: null,
                        selectedItemBuilder: (context) => [
                          for (final entry in tools)
                            SizedBox(
                              width: selectedToolWidth,
                              height: 48,
                              child: Align(
                                alignment: AlignmentDirectional.centerStart,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: AlignmentDirectional.centerStart,
                                  child: Text(label(entry)),
                                ),
                              ),
                            ),
                        ],
                        items: tools
                            .map(
                              (entry) => DropdownMenuItem(
                                key: ValueKey('editor-tool-option-${entry.name}'),
                                value: entry,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                  child: SizedBox(
                                    width: menuWidth - 32,
                                    child: Row(
                                      children: [
                                        Icon(icon(entry), size: 20),
                                        const SizedBox(width: 8),
                                        Expanded(child: Text(label(entry))),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value != null) {
                            onTool(value);
                          }
                        },
                      ),
                    if (!draw && !compact) ...[history(true), history(false)],
                  ],
                ),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    Text(context.t.color),
                    for (final candidate in palette)
                      IconButton(
                        key: ValueKey('editor-color-${candidate.toARGB32()}'),
                        tooltip: '${context.t.color} ${candidate.toARGB32().toRadixString(16)}',
                        onPressed: () => onColor(candidate),
                        icon: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: candidate,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: color == candidate ? Colors.yellow : Colors.grey,
                              width: color == candidate ? 3 : 1,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (mode == EditorMode.text) ...[
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      DropdownButton<String>(
                        key: const Key('editor-font'),
                        value: textStyle.fontFamily ?? 'sans-serif',
                        items: ['sans-serif', 'serif', 'monospace']
                            .map(
                              (font) => DropdownMenuItem(
                                value: font,
                                child: Text('Aa', style: TextStyle(fontFamily: font)),
                              ),
                            )
                            .toList(),
                        onChanged: (font) {
                          if (font != null) {
                            onTextStyle(textStyle.copyWith(fontFamily: font));
                          }
                        },
                      ),
                      FilterChip(
                        key: const Key('editor-text-outline'),
                        label: Text(context.tr('editor_outline')),
                        selected: textStyle.outlineWidth > 0,
                        onSelected: (on) => onTextStyle(textStyle.copyWith(outlineWidth: on ? .006 : 0)),
                      ),
                      PopupMenuButton<Color>(
                        key: const Key('editor-outline-color'),
                        tooltip: context.tr('editor_outline'),
                        icon: Icon(Icons.format_color_text, color: textStyle.outlineColor),
                        onSelected: (color) => onTextStyle(textStyle.copyWith(outlineColor: color, outlineWidth: .006)),
                        itemBuilder: (_) => [
                          for (final color in palette)
                            PopupMenuItem(
                              value: color,
                              child: Icon(Icons.circle, color: color),
                            ),
                        ],
                      ),
                      const SizedBox(width: 8),
                      FilterChip(
                        key: const Key('editor-text-background'),
                        label: Text(context.tr('editor_background')),
                        selected: textStyle.backgroundColor.a > 0,
                        onSelected: (on) =>
                            onTextStyle(textStyle.copyWith(backgroundColor: on ? Colors.black : Colors.transparent)),
                      ),
                      PopupMenuButton<Color>(
                        key: const Key('editor-background-color'),
                        tooltip: context.tr('editor_background'),
                        icon: const Icon(Icons.format_color_fill),
                        onSelected: (color) => onTextStyle(textStyle.copyWith(backgroundColor: color)),
                        itemBuilder: (_) => [
                          for (final color in palette)
                            PopupMenuItem(
                              value: color,
                              child: Icon(Icons.circle, color: color),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                Row(
                  children: [
                    Text(context.t.size),
                    Expanded(
                      child: Slider(
                        key: const Key('editor-text-size'),
                        min: .015,
                        max: .2,
                        value: textStyle.fontSize.clamp(.015, .2),
                        onChangeStart: (_) => onGestureStart(),
                        onChangeEnd: (_) => onGestureEnd(),
                        onChanged: (value) => onTextStyle(textStyle.copyWith(fontSize: value)),
                      ),
                    ),
                  ],
                ),
              ],
              if (draw)
                Row(
                  children: [
                    Text(context.t.size),
                    Expanded(
                      child: Slider(
                        key: const Key('annotation-width'),
                        min: 1,
                        max: 32,
                        value: width,
                        onChanged: onWidth,
                      ),
                    ),
                  ],
                ),
              Row(
                children: [
                  Tooltip(message: context.tr('editor_opacity'), child: const Icon(Icons.opacity, size: 20)),
                  Expanded(
                    child: Slider(
                      key: const Key('annotation-opacity'),
                      min: .1,
                      max: 1,
                      value: opacity,
                      onChangeStart: (_) => onGestureStart(),
                      onChangeEnd: (_) => onGestureEnd(),
                      onChanged: onOpacity,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
