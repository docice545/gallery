import 'dart:async';
import 'dart:math';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/map.model.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/models/map/map_state.model.dart';
import 'package:immich_mobile/presentation/widgets/map/library_map_preview.widget.dart';
import 'package:immich_mobile/presentation/widgets/map/map.state.dart' show mapMarkerProvider;
import 'package:immich_mobile/providers/infrastructure/map.provider.dart';
import 'package:immich_mobile/providers/locale_provider.dart';
import 'package:immich_mobile/providers/map/map_state.provider.dart';
import 'package:immich_mobile/providers/sync_status.provider.dart';
import 'package:immich_mobile/providers/theme.provider.dart';
import 'package:immich_mobile/theme/theme_data.dart';
import 'package:immich_mobile/widgets/map/map_thumbnail.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

class _MapState extends MapStateNotifier {
  @override
  MapState build() => const MapState(themeMode: ThemeMode.light);
}

void main() {
  Future<void> pump(
    WidgetTester tester,
    Future<MapViewport?> Function(Ref) viewport, {
    LatLng? initial,
    ValueChanged<LatLng?>? onTap,
  }) async {
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: locales.values.toList(),
        path: translationsPath,
        startLocale: const Locale('ru'),
        fallbackLocale: const Locale('en'),
        saveLocale: false,
        assetLoader: const CodegenLoader(),
        child: ProviderScope(
          overrides: [
            initialMapViewportProvider.overrideWith(viewport),
            mapMarkerProvider(null).overrideWith(
              (_) async => {
                'type': 'FeatureCollection',
                'features': [
                  {'id': 'photo'},
                ],
              },
            ),
            mapStateNotifierProvider.overrideWith(_MapState.new),
            localeProvider.overrideWithValue(const Locale('ru')),
            immichThemeProvider.overrideWith(
              (_) => ImmichTheme(
                light: ColorScheme.fromSeed(seedColor: Colors.indigo),
                dark: ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: Brightness.dark),
              ),
            ),
          ],
          child: Builder(
            builder: (context) => MaterialApp(
              locale: context.locale,
              supportedLocales: context.supportedLocales,
              localizationsDelegates: context.localizationDelegates,
              home: Scaffold(
                body: LibraryMapPreview(initialLocation: initial, onTap: onTap),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('cold preview fits real GPS and leaves full-map camera selection automatic', (tester) async {
    final result = Completer<MapViewport?>();
    LatLng? opened = const LatLng(1, 2);
    await pump(tester, (_) => result.future, onTap: (location) => opened = location);
    expect(find.byType(MapThumbnail), findsNothing);
    result.complete(
      MapViewport(
        photoCount: 2,
        bounds: LatLngBounds(southwest: const LatLng(55, 37), northeast: const LatLng(56, 38)),
      ),
    );
    await tester.pump();
    await tester.pump();
    final thumbnail = tester.widget<MapThumbnail>(find.byType(MapThumbnail));
    expect(thumbnail.viewport!.photoCount, 2);
    expect(thumbnail.width, double.infinity);
    expect(thumbnail.height, double.infinity);
    // A 100x100 map left most of the Places header and Library card blank.
    await tester.pump();
    expect(tester.widget<MapThumbnail>(find.byType(MapThumbnail)).photoMarkers!['features'], [
      {'id': 'photo'},
    ]);
    thumbnail.onTap!(const Point(0, 0), const LatLng(0, 0));
    expect(opened, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('explicit place coordinates win without reading the default library anchor', (tester) async {
    var reads = 0;
    await pump(tester, (_) async {
      reads++;
      return null;
    }, initial: const LatLng(10.93, 108.29));
    final thumbnail = tester.widget<MapThumbnail>(find.byType(MapThumbnail));
    expect(thumbnail.centre, const LatLng(10.93, 108.29));
    expect(reads, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no GPS uses neutral world viewport rather than Hawaii or a fake photo pin', (tester) async {
    await pump(tester, (_) async => null);
    await tester.pump();
    final thumbnail = tester.widget<MapThumbnail>(find.byType(MapThumbnail));
    expect(thumbnail.centre, const LatLng(0, 0));
    expect(thumbnail.zoom, 0);
    expect(thumbnail.showMarkerPin, isFalse);
    expect(thumbnail.assetMarkerRemoteId, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sync refresh retains the preview while the next real extent loads', (tester) async {
    final pending = Completer<MapViewport?>();
    var reads = 0;
    final first = MapViewport(
      photoCount: 1,
      bounds: LatLngBounds(southwest: const LatLng(55, 37), northeast: const LatLng(55, 37)),
    );
    await pump(tester, (ref) {
      ref.watch(syncStatusProvider.select((state) => state.remoteContentChangedCount));
      return ++reads == 1 ? Future.value(first) : pending.future;
    });
    await tester.pump();
    final previous = tester.element(find.byType(MapThumbnail));
    final container = ProviderScope.containerOf(tester.element(find.byType(LibraryMapPreview)));
    container.read(syncStatusProvider.notifier).markRemoteContentChanged();
    await tester.pump();
    expect(identical(tester.element(find.byType(MapThumbnail)), previous), isTrue);
    pending.complete(
      MapViewport(
        photoCount: 2,
        bounds: LatLngBounds(southwest: const LatLng(54, 36), northeast: const LatLng(56, 38)),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(tester.widget<MapThumbnail>(find.byType(MapThumbnail)).viewport!.photoCount, 2);
    expect(tester.takeException(), isNull);
  });
}
