import 'package:flutter/material.dart';

/// A bounded translucent surface keeps the photo visible and gives the approved
/// icons stable contrast even over white pixels. No per-frame blur/image decode.
class ViewerControlSurface extends StatelessWidget {
  const ViewerControlSurface({super.key, required this.child, this.pill = false, this.visualHeight});
  final Widget child;
  final bool pill;
  final double? visualHeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final background = colors.surfaceContainerHigh.withValues(alpha: .96);
    final foreground = colors.onSurface;

    Widget surface({Widget? child}) => Material(
      color: background,
      shape: pill
          ? const StadiumBorder()
          : RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(28),
              side: BorderSide(color: colors.outlineVariant.withValues(alpha: .55)),
            ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
    return Theme(
      data: theme.copyWith(
        colorScheme: colors.copyWith(surface: background, onSurface: foreground),
        iconTheme: IconThemeData(color: foreground, size: 22),
      ),
      child: visualHeight == null
          ? surface(child: child)
          : Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(
                  child: Center(
                    child: SizedBox(height: visualHeight, width: double.infinity, child: surface()),
                  ),
                ),
                // The slim painted capsule does not clip its 48dp touch regions.
                Material(type: MaterialType.transparency, child: child),
              ],
            ),
    );
  }
}
