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
    final background = colors.surfaceContainerHigh.withValues(alpha: .96);
    final foreground = colors.onSurface;

    return Theme(
      data: theme.copyWith(
        colorScheme: colors.copyWith(surface: background, onSurface: foreground),
        iconTheme: IconThemeData(color: foreground, size: 22),
      ),
      child: Material(
        color: background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
          side: BorderSide(color: colors.outlineVariant.withValues(alpha: .55)),
        ),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }
}
