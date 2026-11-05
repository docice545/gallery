import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Equal action columns with room for localized labels and accessibility fonts.
/// Only this small action area relayouts; it never drives the photo grid.
class ActionCellGrid extends StatelessWidget {
  const ActionCellGrid({super.key, required this.children, this.compact = false, this.labels});

  final List<Widget> children;
  final bool compact;
  final List<String>? labels;

  static bool contains(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_ActionGridScope>() != null;

  static bool isCompact(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ActionGridScope>()?.compact ?? false;

  @override
  Widget build(BuildContext context) => _ActionGridScope(
    compact: compact,
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final fontSize = compact ? 11.0 : 14.0;
          final scale = MediaQuery.textScalerOf(context).scale(fontSize) / fontSize;
          final preferredWidth = compact ? 64 * math.max(1, scale) : 104 * math.sqrt(math.max(1, scale));
          var columns = math.min(
            math.max(1, children.length),
            (constraints.maxWidth / (compact ? 48 : preferredWidth)).floor().clamp(1, compact ? 5 : 6),
          );
          final gap = compact ? 0.0 : 4.0;
          if (compact && labels != null) {
            var widest = 0.0;
            for (final label in labels!) {
              final painter = TextPainter(
                text: TextSpan(
                  text: label,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(fontSize: 11, fontWeight: FontWeight.w500),
                ),
                textScaler: MediaQuery.textScalerOf(context),
                textDirection: Directionality.of(context),
              )..layout();
              widest = math.max(widest, painter.width + 8);
              painter.dispose();
            }
            while (columns > 1 && (constraints.maxWidth - (columns - 1) * gap) / columns < widest) {
              columns--;
            }
          } else if (compact) {
            columns = math.min(columns, math.max(1, (constraints.maxWidth / preferredWidth).floor()));
          }
          final cellWidth = (constraints.maxWidth - (columns - 1) * gap) / columns;
          return Wrap(
            alignment: WrapAlignment.center,
            spacing: gap,
            runSpacing: compact ? 0 : 4,
            children: [
              for (final (index, child) in children.indexed)
                SizedBox(
                  key: ValueKey('selection-action-cell-$index'),
                  width: cellWidth,
                  child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 48), child: child),
                ),
            ],
          );
        },
      ),
    ),
  );
}

class _ActionGridScope extends InheritedWidget {
  const _ActionGridScope({required super.child, required this.compact});
  final bool compact;
  @override
  bool updateShouldNotify(_ActionGridScope oldWidget) => compact != oldWidget.compact;
}
