import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/map.model.dart';
import 'package:immich_mobile/models/map/map_state.model.dart';
import 'package:immich_mobile/providers/locale_provider.dart';
import 'package:immich_mobile/providers/map/map_state.provider.dart';
import 'package:immich_mobile/providers/theme.provider.dart';
import 'package:immich_mobile/theme/theme_data.dart';
import 'package:immich_mobile/widgets/map/map_thumbnail.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:mocktail/mocktail.dart';

// Platform rendering is deliberately absent: tests drive the same public
// creation/style callbacks as the native view without network or GPS access.
class _Platform extends MapLibrePlatform with Mock {
  @override
  Widget buildView(
    Map<String, dynamic> params,
    void Function(int) created,
    Set<Factory<OneSequenceGestureRecognizer>>? gestures,
  ) => const SizedBox.expand();
  @override
  void dispose() => super.dispose();
}

class _Controller extends Mock implements MapLibreMapController {}

class _State extends MapStateNotifier {
  @override
  MapState build() =>
      const MapState(themeMode: ThemeMode.light, lightStyleFetched: AsyncData('https://custom.test/style'));
  void source(String value) => state = state.copyWith(lightStyleFetched: AsyncData(value));
}

void main() {
  setUpAll(() {
    registerFallbackValue(const GeojsonSourceProperties());
    registerFallbackValue(const CircleLayerProperties());
    registerFallbackValue(const SymbolLayerProperties());
    registerFallbackValue(CameraUpdate.newLatLngZoom(const LatLng(0, 0), 0));
    registerFallbackValue(SymbolOptions.defaultOptions);
    registerFallbackValue(Uint8List(0));
  });
  late _State state;
  late _Controller controller;
  late MapLibrePlatform Function() oldFactory;
  setUp(() {
    oldFactory = MapLibrePlatform.createInstance;
    MapLibrePlatform.createInstance = _Platform.new;
    state = _State();
    controller = _Controller();
    when(() => controller.getStyle()).thenAnswer((_) async => '{"version":8,"layers":[]}');
    when(() => controller.moveCamera(any())).thenAnswer((_) async => true);
    when(() => controller.addSource(any(), any())).thenAnswer((_) async {});
    when(() => controller.addCircleLayer(any(), any(), any())).thenAnswer((_) async {});
    when(() => controller.addSymbolLayer(any(), any(), any())).thenAnswer((_) async {});
    when(() => controller.setGeoJsonSource(any(), any())).thenAnswer((_) async {});
    when(() => controller.addImage(any(), any())).thenAnswer((_) async {});
    when(() => controller.addSymbol(any())).thenThrow(StateError('pin unavailable'));
  });
  tearDown(() => MapLibrePlatform.createInstance = oldFactory);

  MapViewport extent(double latitude) => MapViewport(
    photoCount: 2,
    bounds: LatLngBounds(southwest: LatLng(latitude, 37), northeast: LatLng(latitude + 1, 38)),
  );
  const markers = <String, dynamic>{
    'type': 'FeatureCollection',
    'features': [
      {'id': 'photo'},
    ],
  };
  Future<void> pump(WidgetTester tester, MapThumbnail thumbnail) async {
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
        child: MaterialApp(home: Scaffold(body: thumbnail)),
      ),
    );
  }

  void ready(WidgetTester tester) {
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    map.onMapCreated!(controller);
    map.onStyleLoadedCallback!();
  }

  testWidgets('base map is revealed before labels finish and survives optional pin failure', (tester) async {
    final labels = Completer<String?>();
    when(() => controller.getStyle()).thenAnswer((_) => labels.future);
    await pump(tester, const MapThumbnail(centre: LatLng(55, 37), showMarkerPin: true));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    ready(tester);
    await tester.pump();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(MapLibreMap), findsOneWidget);
    labels.complete('{"version":8,"layers":[]}');
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('old effect cleanup cannot cancel a replacement style generation or its clusters', (tester) async {
    await pump(tester, MapThumbnail(centre: const LatLng(0, 0), viewport: extent(55), photoMarkers: markers));
    ready(tester);
    await tester.pumpAndSettle();
    verify(() => controller.setGeoJsonSource('asset-map-markers', markers)).called(1);
    tester.widget<MapLibreMap>(find.byType(MapLibreMap)).onStyleLoadedCallback!();
    await tester.pumpAndSettle();
    verify(() => controller.addSource(any(), any())).called(2);
    verify(() => controller.getStyle()).called(2);
    verify(() => controller.setGeoJsonSource('asset-map-markers', markers)).called(1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new extent reuses native preview and moves camera without rebuilding sources', (tester) async {
    await pump(tester, MapThumbnail(centre: const LatLng(0, 0), viewport: extent(55), photoMarkers: markers));
    ready(tester);
    await tester.pump();
    await tester.pump();
    final native = tester.element(find.byType(MapLibreMap));
    clearInteractions(controller);
    await pump(tester, MapThumbnail(centre: const LatLng(0, 0), viewport: extent(56), photoMarkers: markers));
    await tester.pump();
    expect(identical(tester.element(find.byType(MapLibreMap)), native), isTrue);
    verify(() => controller.moveCamera(any())).called(1);
    verifyNever(() => controller.addSource(any(), any()));
    expect(tester.takeException(), isNull);
  });

  testWidgets('source switch and unmount cancel pending old initialization', (tester) async {
    final pending = Completer<void>();
    when(() => controller.addSource(any(), any())).thenAnswer((_) => pending.future);
    await pump(tester, MapThumbnail(centre: const LatLng(0, 0), viewport: extent(55), photoMarkers: markers));
    ready(tester);
    await tester.pump();
    final oldNative = tester.element(find.byType(MapLibreMap));
    state.source('https://custom.test/next-style');
    await tester.pump();
    expect(identical(tester.element(find.byType(MapLibreMap)), oldNative), isFalse);
    await tester.pumpWidget(const SizedBox());
    pending.complete();
    await tester.pump();
    verifyNever(() => controller.addCircleLayer(any(), any(), any()));
    verifyNever(() => controller.setGeoJsonSource(any(), any()));
    expect(tester.takeException(), isNull);
  });
}
