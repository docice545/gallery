import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/models/map/map_state.model.dart';
import 'package:immich_mobile/providers/locale_provider.dart';
import 'package:immich_mobile/providers/map/map_state.provider.dart';
import 'package:immich_mobile/providers/theme.provider.dart';
import 'package:immich_mobile/theme/theme_data.dart';
import 'package:immich_mobile/widgets/map/map_theme_override.dart';

class _State extends MapStateNotifier {
  @override
  MapState build() => const MapState(
    themeMode: ThemeMode.system,
    lightStyleFetched: AsyncData('https://tiles.openfreemap.org/styles/positron'),
    darkStyleFetched: AsyncData('https://tiles.openfreemap.org/styles/dark'),
  );
  MapState get current => state;
  void update(MapState value) => state = value;
}

void main() {
  late _State state;
  AsyncValue<String>? style;
  Future<void> pump(WidgetTester tester, {ThemeMode? mode}) async {
    state = _State();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mapStateNotifierProvider.overrideWith(() => state),
          localeProvider.overrideWithValue(const Locale('ru')),
          immichThemeProvider.overrideWith(
            (_) => ImmichTheme(
              light: ColorScheme.fromSeed(seedColor: Colors.indigo),
              dark: ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: Brightness.dark),
            ),
          ),
        ],
        child: MaterialApp(
          home: MapThemeOverride(
            themeMode: mode,
            mapBuilder: (value) {
              style = value;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
  }

  tearDown(() => style = null);

  testWidgets('system brightness changes between full-colour default light/dark styles', (tester) async {
    tester.binding.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.binding.platformDispatcher.clearPlatformBrightnessTestValue);
    await pump(tester);
    expect(style!.valueOrNull, 'https://tiles.openfreemap.org/styles/liberty');
    tester.binding.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pump();
    expect(style!.valueOrNull, 'https://tiles.openfreemap.org/styles/fiord');
    tester.binding.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pump();
    expect(style!.valueOrNull, 'https://tiles.openfreemap.org/styles/liberty');
    expect(tester.takeException(), isNull);
  });

  testWidgets('custom URL and inline JSON survive theme changes and async config arrival', (tester) async {
    await pump(tester, mode: ThemeMode.light);
    state.update(state.current.copyWith(lightStyleFetched: const AsyncData('{"version":8,"layers":[]}')));
    await tester.pump();
    expect(style!.valueOrNull, '{"version":8,"layers":[]}');
    state.update(state.current.copyWith(lightStyleFetched: const AsyncData('https://custom.test/positron.json')));
    await tester.pump();
    expect(style!.valueOrNull, 'https://custom.test/positron.json');
  });

  testWidgets('explicit widget theme wins and errors/loading stay observable', (tester) async {
    await pump(tester, mode: ThemeMode.dark);
    expect(style!.valueOrNull, 'https://tiles.openfreemap.org/styles/fiord');
    state.update(state.current.copyWith(themeMode: ThemeMode.light, darkStyleFetched: const AsyncLoading()));
    await tester.pump();
    expect(style!.isLoading, isTrue);
    state.update(state.current.copyWith(darkStyleFetched: const AsyncError('offline', StackTrace.empty)));
    await tester.pump();
    expect(style!.error, 'offline');
    await tester.pumpWidget(const SizedBox());
    tester.binding.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pump();
    tester.binding.platformDispatcher.clearPlatformBrightnessTestValue();
    expect(tester.takeException(), isNull);
  });
}
