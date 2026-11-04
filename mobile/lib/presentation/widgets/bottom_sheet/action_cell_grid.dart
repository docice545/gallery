import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Equal action columns with room for localized labels and accessibility fonts.
/// Only this small action area relayouts; it never drives the photo grid.
class ActionCellGrid extends StatelessWidget {
  const ActionCellGrid({super.key, required this.children});

  final List<Widget> children;

  static bool contains(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_ActionGridScope>() != null;

  @override
  Widget build(BuildContext context) => _ActionGridScope(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
          final preferredWidth = 104 * math.sqrt(math.max(1, scale));
          final columns = (constraints.maxWidth / preferredWidth).floor().clamp(1, 6);
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
  const _ActionGridScope({required super.child});
  @override
  bool updateShouldNotify(_ActionGridScope oldWidget) => false;
}
