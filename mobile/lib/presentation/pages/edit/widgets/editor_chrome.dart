import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Use MaterialApp's resolved theme: it already combines FOTO's persisted
/// preference and live platform brightness. Never apply a theme to image pixels
/// or replace the document/controllers when only the chrome changes.
class EditorChrome extends StatelessWidget {
  const EditorChrome({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      AnnotatedRegion<SystemUiOverlayStyle>(value: editorSystemUiStyle(context), child: child);
}

SystemUiOverlayStyle editorSystemUiStyle(BuildContext context) {
  final colors = Theme.of(context).colorScheme;
  final icons = colors.brightness == Brightness.dark ? Brightness.light : Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: icons,
    statusBarBrightness: colors.brightness,
    systemNavigationBarColor: colors.surface,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: icons,
    systemNavigationBarContrastEnforced: false,
  );
}
