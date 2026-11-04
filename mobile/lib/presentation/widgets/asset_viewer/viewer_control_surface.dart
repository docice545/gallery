import 'package:flutter/material.dart';

/// A bounded translucent surface keeps the photo visible and gives the approved
/// icons stable contrast even over white pixels. No per-frame blur/image decode.
class ViewerControlSurface extends StatelessWidget {
  const ViewerControlSurface({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final background = colors.surfaceContainerHigh;
    final foreground = colors.onSurface;

    return Theme(
      data: theme.copyWith(
        colorScheme: colors.copyWith(surface: background, onSurface: foreground),
        iconTheme: IconThemeData(color: foreground, size: 22),
      ),
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }
}
