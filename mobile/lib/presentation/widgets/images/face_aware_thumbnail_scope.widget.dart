import 'package:flutter/widgets.dart';

/// Enable framing only in the main Photos timeline, keeping other thumbnail
/// surfaces and their loading behavior unchanged.
class FaceAwareThumbnailScope extends InheritedWidget {
  const FaceAwareThumbnailScope({super.key, required super.child});

  static bool enabledOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FaceAwareThumbnailScope>() != null;

  @override
  bool updateShouldNotify(FaceAwareThumbnailScope oldWidget) => false;
}
