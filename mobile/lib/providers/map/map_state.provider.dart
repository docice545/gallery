import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/models/map/map_state.model.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';

final mapStateNotifierProvider = NotifierProvider<MapStateNotifier, MapState>(MapStateNotifier.new);

class MapStateNotifier extends Notifier<MapState> {
  @override
  MapState build() {
    final mapConfig = ref.read(appConfigProvider.select((config) => config.map));

    final lightStyleUrl = ref.read(serverInfoProvider).serverConfig.mapLightStyleUrl;
    final darkStyleUrl = ref.read(serverInfoProvider).serverConfig.mapDarkStyleUrl;

    // Server settings can arrive after this notifier's initial defaults. Keep
    // custom sources reactive without resetting the user's current map theme.
    ref.listen(
      serverInfoProvider.select(
        (info) => (light: info.serverConfig.mapLightStyleUrl, dark: info.serverConfig.mapDarkStyleUrl),
      ),
      (_, urls) {
        state = state.copyWith(lightStyleFetched: AsyncData(urls.light), darkStyleFetched: AsyncData(urls.dark));
      },
    );

    return MapState(
      themeMode: mapConfig.themeMode,
      showFavoriteOnly: mapConfig.favoritesOnly,
      includeArchived: mapConfig.includeArchived,
      withPartners: mapConfig.withPartners,
      relativeTime: mapConfig.relativeDays,
      lightStyleFetched: AsyncData(lightStyleUrl),
      darkStyleFetched: AsyncData(darkStyleUrl),
    );
  }

  void switchTheme(ThemeMode mode) {
    unawaited(ref.read(settingsProvider).write(.mapThemeMode, mode));
    state = state.copyWith(themeMode: mode);
  }
}
