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
    final isDark = theme.brightness == Brightness.dark;

    final background = isDark ? const Color(0xe6202124) : const Color(0xf5f7f8fa);

    final foreground = isDark ? Colors.white : const Color(0xff202124);

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
