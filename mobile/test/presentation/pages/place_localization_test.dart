import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/place.model.dart';
import 'package:immich_mobile/domain/models/timeline_temporal_scope.model.dart';
import 'package:immich_mobile/domain/services/place_name.service.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/platform/remote_image_api.g.dart';
import 'package:immich_mobile/presentation/pages/place.page.dart';
import 'package:immich_mobile/presentation/pages/place_detail.page.dart';
import 'package:immich_mobile/presentation/widgets/map/place_list_tile.widget.dart';
import 'package:immich_mobile/providers/infrastructure/map.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/place_names.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/widgets/common/mesmerizing_sliver_app_bar.dart';
import 'package:mocktail/mocktail.dart';

import '../../unit/presentation/presentation_context.dart';
import '../../widget_tester_extensions.dart';

class _Factory extends Mock implements TimelineFactory {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const annino = Place(name: 'Annino', assetId: 'preview-a', state: 'Moscow', country: 'Russia');
  const degunino = Place(name: 'Vostochnoe Degunino', assetId: 'preview-d', state: 'Moscow', country: 'Russia');
  const request = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.RemoteImageApi.requestImage',
    RemoteImageApi.pigeonChannelCodec,
  );
  const cancel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.RemoteImageApi.cancelRequest',
    RemoteImageApi.pigeonChannelCodec,
  );
  late PresentationContext fixture;
  late _Factory factory;
  late List<PlaceLabelRequest> lookups;

  setUpAll(() async {
    registerFallbackValue(const TimelineTemporalScope.none());
    registerFallbackValue(annino);
    final font = FontLoader('GoogleSans');
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      font.addFont(rootBundle.load('fonts/GoogleSans/GoogleSans-$weight.ttf'));
    }
    await font.load();
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  setUp(() async {
    fixture = await PresentationContext.create();
    factory = _Factory();
    lookups = [];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockDecodedMessageHandler(request, (_) async => <Object?>[null]);
    messenger.setMockDecodedMessageHandler(cancel, (_) async => <Object?>[null]);
    when(
      () => factory.place(
        any(),
        any(),
        any(),
        selectedPlace: any(named: 'selectedPlace'),
        groupBy: any(named: 'groupBy'),
        temporalScope: any(named: 'temporalScope'),
      ),
    ).thenAnswer(
      (_) => TimelineService((
        origin: TimelineOrigin.place,
        assetSource: (_, _) async => const [],
        bucketSource: () => Stream.value(const []),
      )),
    );
  });
  tearDown(() async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockDecodedMessageHandler(request, null);
    messenger.setMockDecodedMessageHandler(cancel, null);
    await fixture.dispose();
  });

  Future<RootStackRouter> mount(WidgetTester tester, {List<Place> places = const [annino, degunino]}) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final router = RootStackRouter.build(
      routes: [
        AutoRoute(initial: true, page: PageInfo('Places', builder: (_) => const PlacePage())),
        AutoRoute(
          page: PageInfo(
            PlaceDetailRoute.name,
            builder: (data) {
              final args = data.argsAs<PlaceDetailRouteArgs>();
              return PlaceDetailPage(place: args.place, selectedPlace: args.selectedPlace);
            },
          ),
        ),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      router.dispose();
    });
    await tester.pumpWidget(
      localizedForTest(
        ProviderScope(
          overrides: fixture.overrides,
          child: ProviderScope(
            overrides: [
              placeDetailsProvider.overrideWith((ref) async => places),
              persistedPlaceLabelsProvider.overrideWith(
                (ref) async => {PlaceNameService.key(degunino, 'ru'): 'Восточное Дегунино'},
              ),
              resolvedPlaceLabelsProvider.overrideWith((ref) => {}),
              localizedPlaceLabelProvider.overrideWith((ref, request) async {
                lookups.add(request);
                return request.place.name;
              }),
              placeSearchAliasesProvider.overrideWith((ref, query) async => []),
              initialMapViewportProvider.overrideWith((ref) async => throw StateError('Synthetic offline map fixture')),
              timelineFactoryProvider.overrideWithValue(factory),
              timelineUsersProvider.overrideWith((ref) => Stream.value([fixture.currentUser.id])),
            ],
            child: Builder(
              builder: (context) => MaterialApp.router(
                theme: ThemeData.dark(
                  useMaterial3: true,
                ).copyWith(textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'GoogleSans')),
                locale: context.locale,
                supportedLocales: context.supportedLocales,
                localizationsDelegates: context.localizationDelegates,
                routerConfig: router.config(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await EasyLocalization.of(tester.element(find.byType(PlacePage)))!.setLocale(const Locale('ru'));
    await tester.pumpAndSettle();
    return router;
  }

  Future<void> capture(WidgetTester tester, String name) async {
    if (const bool.fromEnvironment('FOTO_CAPTURE_PLACES')) {
      debugPrint('PLACES_REVIEW $name viewport=393x852 synthetic=true');
      await expectLater(find.byType(Overlay), matchesGoldenFile('goldens/places_$name.png'));
    }
  }

  testWidgets(
    'actual list -> route -> title uses Annino consistently and preserves source identity across language changes',
    (tester) async {
      await mount(tester);
      expect(find.text('Аннино'), findsOneWidget);
      expect(find.text('Восточное Дегунино'), findsOneWidget);
      expect(find.text('Vostochnoe Degunino'), findsNothing);
      await capture(tester, 'ru_list');
      await tester.tap(find.text('Аннино'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(PlaceDetailPage), findsOneWidget);
      expect(tester.widget<PlaceDetailPage>(find.byType(PlaceDetailPage)).place, 'Annino');
      expect(tester.widget<PlaceDetailPage>(find.byType(PlaceDetailPage)).selectedPlace, annino);
      expect(tester.widget<MesmerizingSliverAppBar>(find.byType(MesmerizingSliverAppBar)).title, 'Аннино');
      await capture(tester, 'ru_detail');
      await EasyLocalization.of(tester.element(find.byType(PlaceDetailPage)))!.setLocale(const Locale('en'));
      await tester.pumpAndSettle();
      expect(tester.widget<MesmerizingSliverAppBar>(find.byType(MesmerizingSliverAppBar)).title, 'Annino');
      await capture(tester, 'en_detail');
      await EasyLocalization.of(tester.element(find.byType(PlaceDetailPage)))!.setLocale(const Locale('ru'));
      await tester.pumpAndSettle();
      expect(tester.widget<MesmerizingSliverAppBar>(find.byType(MesmerizingSliverAppBar)).title, 'Аннино');
      verify(
        () => factory.place(
          'Annino',
          any(),
          fixture.currentUser.id,
          selectedPlace: annino,
          groupBy: any(named: 'groupBy'),
          temporalScope: any(named: 'temporalScope'),
        ),
      ).called(greaterThanOrEqualTo(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('localized search reuses the same label, while scrolling does not issue lookups for each tile', (
    tester,
  ) async {
    await mount(
      tester,
      places: [
        annino,
        degunino,
        for (var i = 0; i < 40; i++) Place(name: 'Unknown $i', assetId: 'u-$i'),
      ],
    );
    final opening = lookups.length;
    expect(opening, lessThanOrEqualTo(24), reason: '12 opening previews per initial/selected language');
    await tester.fling(find.byType(CustomScrollView), const Offset(0, -1800), 2500);
    await tester.pumpAndSettle();
    expect(lookups.length, opening);
    await tester.fling(find.byType(CustomScrollView), const Offset(0, 2500), 3000);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Восточное');
    await tester.pumpAndSettle();
    expect(find.byType(PlaceListTile), findsOneWidget);
    expect(find.text('Восточное Дегунино'), findsOneWidget);
    await capture(tester, 'ru_search');
    expect(lookups.length, opening);
    expect(tester.takeException(), isNull);
  });
}
