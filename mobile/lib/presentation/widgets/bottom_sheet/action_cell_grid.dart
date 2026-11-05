import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Equal action columns with room for localized labels and accessibility fonts.
/// Only this small action area relayouts; it never drives the photo grid.
class ActionCellGrid extends StatelessWidget {
  const ActionCellGrid({super.key, required this.children, this.compact = false});

  final List<Widget> children;
  final bool compact;

  static bool contains(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_ActionGridScope>() != null;

  static bool isCompact(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ActionGridScope>()?.compact ?? false;

  @override
  Widget build(BuildContext context) => _ActionGridScope(
    compact: compact,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final fontSize = compact ? 11.0 : 14.0;
          final scale = MediaQuery.textScalerOf(context).scale(fontSize) / fontSize;
          final preferredWidth = compact ? 64 * math.max(1, scale) : 104 * math.sqrt(math.max(1, scale));
          final columns = math.min(
            math.max(1, children.length),
            (constraints.maxWidth / preferredWidth).floor().clamp(1, compact ? 4 : 6),
          );
          final cellWidth = (constraints.maxWidth - (columns - 1) * 4) / columns;
          return Wrap(
            alignment: WrapAlignment.center,
            spacing: 4,
            runSpacing: 4,
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
