import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/providers/locale_provider.dart';
import 'package:immich_mobile/providers/map/map_state.provider.dart';
import 'package:immich_mobile/providers/theme.provider.dart';
import 'package:immich_mobile/theme/theme_data.dart';
import 'package:immich_mobile/widgets/map/map_style_presentation.dart';

/// Applies the user's map theme independently of the rest of the app.
class MapThemeOverride extends ConsumerWidget {
  final ThemeMode? themeMode;
  final Widget Function(AsyncValue<String> style) mapBuilder;

  const MapThemeOverride({required this.mapBuilder, this.themeMode, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = themeMode ?? ref.watch(mapStateNotifierProvider.select((value) => value.themeMode));
    final isDark =
        mode == ThemeMode.dark ||
        mode == ThemeMode.system && MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final appTheme = ref.watch(immichThemeProvider);
    final locale = ref.watch(localeProvider);
    return Theme(
      data: getThemeData(colorScheme: isDark ? appTheme.dark : appTheme.light, locale: locale),
      child: mapBuilder(
        ref
            .watch(
              mapStateNotifierProvider.select((value) => isDark ? value.darkStyleFetched : value.lightStyleFetched),
            )
            .whenData(MapStylePresentation.colorfulStyle),
      ),
    );
  }
}
