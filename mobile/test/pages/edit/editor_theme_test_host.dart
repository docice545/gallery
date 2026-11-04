import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/theme.provider.dart';
import 'package:immich_mobile/theme/theme_data.dart';

final editorTestThemeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.system);

List<Override> editorThemeTestOverrides(ThemeMode mode) => [
  editorTestThemeModeProvider.overrideWith((ref) => mode),
  appConfigProvider.overrideWith(
    (ref) => defaultConfig.copyWith(theme: defaultConfig.theme.copyWith(mode: ref.watch(editorTestThemeModeProvider))),
  ),
  immichThemeProvider.overrideWith(
    (ref) => ImmichTheme(
      light: ColorScheme.fromSeed(seedColor: Colors.blue),
      dark: ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Brightness.dark),
    ),
  ),
];

/// Same resolved theme inputs as main.dart, with no app startup/network/media.
class EditorThemeTestApp extends ConsumerWidget {
  const EditorThemeTestApp({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = ref.watch(immichThemeProvider);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      themeMode: ref.watch(appConfigProvider.select((config) => config.theme.mode)),
      theme: getThemeData(colorScheme: palette.light, locale: context.locale),
      darkTheme: getThemeData(colorScheme: palette.dark, locale: context.locale),
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
      locale: context.locale,
      home: child,
    );
  }
}
