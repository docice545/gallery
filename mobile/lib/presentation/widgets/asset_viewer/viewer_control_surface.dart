import 'package:flutter/material.dart';

/// A bounded translucent surface keeps the photo visible and gives the approved
/// icons stable contrast even over white pixels. No per-frame blur/image decode.
class ViewerControlSurface extends StatelessWidget {
  const ViewerControlSurface({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Theme(
    data: Theme.of(context).copyWith(
      colorScheme: Theme.of(context).colorScheme.copyWith(
        surface: const Color(0xff202124),
        onSurface: Colors.white,
        primary: const Color(0xffa8c7fa),
        primaryContainer: const Color(0xff304769),
        error: const Color(0xffffb4ab),
      ),
      iconTheme: const IconThemeData(color: Colors.white, size: 22),
    ),
    child: Material(
      color: const Color(0xd9202124),
      borderRadius: BorderRadius.circular(28),
      clipBehavior: Clip.antiAlias,
      child: child,
    ),
  );
}
