import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/timeline_config.dart';
import 'package:immich_mobile/domain/models/map.model.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/models/timeline_temporal_scope.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/domain/services/user.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/base_bottom_sheet.widget.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/general_bottom_sheet.widget.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/map_bottom_sheet.widget.dart';
import 'package:immich_mobile/presentation/widgets/map/map.state.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_grouping_bottom_pill.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_grouping_footer.widget.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:mocktail/mocktail.dart';
// easy_localization initializes shared_preferences internally; tests need the mock initializer.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences/shared_preferences.dart';

import '../../../test_utils.dart';
import '../../../widget_tester_extensions.dart';

class _MockTimelineFactory extends Mock implements TimelineFactory {}

class _MockSettingsRepository extends Mock implements SettingsRepository {}

class _MockUserService extends Mock implements UserService {}

class _StubReadOnlyModeNotifier extends ReadOnlyModeNotifier {
  @override
  bool build() => false;
}

class _StubCurrentUserNotifier extends CurrentUserProvider {
  _StubCurrentUserNotifier(super.service, UserDto user) {
    state = user;
  }
}

class _MutableMapStateNotifier extends MapStateNotifier {
  _MutableMapStateNotifier(this._initial);

  final MapState _initial;

  @override
  MapState build() => _initial;

  // NOTE: MapState.== compares bounds only; tests update with changed bounds
  // so the simulated pan is the only thing that can reach the options stream.
  void update(MapState next) => state = next;
}

UserDto _user(String id) => UserDto(id: id, email: '$id@example.com', name: id, profileChangedAt: DateTime(2024));

/// A real TimelineService over an empty bucket so the timeline renders without
/// Store/thumbnail plumbing while the grouping pill stays interactive.
TimelineService _mapService() => TimelineService((
  bucketSource: () => Stream.value([TimeBucket(date: DateTime(2024, 1), assetCount: 0)]),
  assetSource: (offset, count) async => const <BaseAsset>[],
  origin: TimelineOrigin.map,
));

typedef _Harness = ({
  _MockTimelineFactory factory,
  _MockSettingsRepository settings,
  _MutableMapStateNotifier mapNotifier,
});

Future<_Harness> _pumpMapTimeline(
  WidgetTester tester, {
  MapState? mapState,
  List<Override> extraOverrides = const [],
  bool fullSheet = false,
  DraggableScrollableController? sheetController,
  double bottomInset = 0,
  double keyboardInset = 0,
  double textScale = 1,
}) async {
  final user = _user('user-1');
  final userService = _MockUserService();
  final factory = _MockTimelineFactory();
  final settings = _MockSettingsRepository();
  final mapNotifier = _MutableMapStateNotifier(
    mapState ??
        MapState(
          bounds: LatLngBounds(northeast: const LatLng(1, 1), southwest: const LatLng(0, 0)),
        ),
  );

  when(() => userService.tryGetMyUser()).thenReturn(user);
  when(() => userService.watchMyUser()).thenAnswer((_) => const Stream<UserDto?>.empty());
  // A fresh service per call: TimelineRouteScope disposes the previous one on
  // every grouping/bounds rebuild.
  when(
    () => factory.geographicMap(
      any(),
      any(),
      any(),
      any(),
      groupBy: any(named: 'groupBy'),
      temporalScope: any(named: 'temporalScope'),
    ),
  ).thenAnswer((_) => _mapService());

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentUserProvider.overrideWith((ref) => _StubCurrentUserNotifier(userService, user)),
        readonlyModeProvider.overrideWith(() => _StubReadOnlyModeNotifier()),
        appConfigProvider.overrideWithValue(const AppConfig(timeline: TimelineConfig(tilesPerRow: 3))),
        settingsProvider.overrideWithValue(settings),
        timelineFactoryProvider.overrideWithValue(factory),
        mapStateProvider.overrideWith(() => mapNotifier),
        ...extraOverrides,
      ],
      // EasyLocalization must wrap the app: TimelineHeader reads context.locale,
      // which null-derefs without the widget in the tree.
      child: EasyLocalization(
        supportedLocales: const [Locale('en')],
        path: '../i18n',
        assetLoader: const CodegenLoader(),
        fallbackLocale: const Locale('en'),
        child: Builder(
          builder: (context) => MaterialApp(
            locale: context.locale,
            supportedLocales: context.supportedLocales,
            localizationsDelegates: context.localizationDelegates,
            home: withStubRouter(
              MediaQuery(
                data: MediaQueryData(
                  size: tester.view.physicalSize / tester.view.devicePixelRatio,
                  padding: EdgeInsets.only(top: 24, bottom: keyboardInset > 0 ? 0 : bottomInset),
                  viewPadding: EdgeInsets.only(top: 24, bottom: bottomInset),
                  viewInsets: EdgeInsets.only(bottom: keyboardInset),
                  textScaler: TextScaler.linear(textScale),
                ),
                child: fullSheet
                    ? Scaffold(
                        body: Stack(children: [MapBottomSheet(controller: sheetController)]),
                      )
                    : const Scaffold(body: MapBottomSheetTimeline()),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  // Bounded pumps instead of pumpAndSettle: timeline loading indicators animate
  // indefinitely, so pumpAndSettle can time out.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  return (factory: factory, settings: settings, mapNotifier: mapNotifier);
}

void main() {
  setUpAll(() async {
    TestUtils.init();
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    await initializeDateFormatting('en');
    registerFallbackValue(
      TimelineMapOptions(
        bounds: LatLngBounds(northeast: const LatLng(0, 0), southwest: const LatLng(0, 0)),
      ),
    );
    registerFallbackValue(
      () => TimelineMapOptions(
        bounds: LatLngBounds(northeast: const LatLng(0, 0), southwest: const LatLng(0, 0)),
      ),
    );
    registerFallbackValue(const Stream<TimelineMapOptions>.empty());
    registerFallbackValue(const TimelineTemporalScope.none());
    registerFallbackValue(GroupAssetsBy.day);
  });

  testWidgets('a docked draggable action sheet measures its extent instead of covering the photo list', (tester) async {
    final controller = DraggableScrollableController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: const SizedBox.expand(key: Key('map-photo-body')),
            bottomNavigationBar: BaseBottomSheet(
              controller: controller,
              expand: false,
              resizeOnScroll: false,
              initialChildSize: 0.23,
              minChildSize: 0.23,
              maxChildSize: 0.85,
              actions: const [],
            ),
          ),
        ),
      ),
    );
    final body = tester.getRect(find.byKey(const Key('map-photo-body')));
    final actionSheet = tester.getRect(find.byType(Card));
    expect(body.height, greaterThan(tester.view.physicalSize.height / tester.view.devicePixelRatio * 0.5));
    expect(body.bottom, lessThanOrEqualTo(actionSheet.top));
    expect(tester.takeException(), isNull);
  });

  testWidgets('starts collapsed with only the count and handle, then opens and closes on tap', (tester) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final harness = await _pumpMapTimeline(tester, fullSheet: true, bottomInset: 24);

    expect(find.byKey(const Key('map-panel-asset-count')), findsOneWidget);
    expect(find.byKey(const Key('map-panel-drag-handle')), findsOneWidget);
    expect(find.byType(Timeline), findsNothing);
    expect(find.byType(TimelineGroupingFooter), findsNothing);
    final collapsedHeader = tester.getRect(find.byKey(const Key('map-panel-toggle')));
    expect(collapsedHeader.height, closeTo(64, 1));
    expect(collapsedHeader.bottom, lessThanOrEqualTo(720 - 24));

    await tester.tap(find.byKey(const Key('map-panel-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(Timeline), findsOneWidget);
    expect(find.byType(TimelineGroupingFooter), findsOneWidget);
    expect(find.byType(TimelineGroupingBottomPill), findsNothing);
    final footerRect = tester.getRect(find.byType(TimelineGroupingFooter));
    final countRect = tester.getRect(find.byKey(const Key('map-panel-asset-count')));
    expect(countRect.bottom, lessThan(footerRect.top));
    expect(footerRect.bottom, lessThanOrEqualTo(720 - 24));
    // Expanding is a layout operation, not another geographic query/service.
    verify(
      () => harness.factory.geographicMap(
        any(),
        any(),
        any(),
        any(),
        groupBy: GroupAssetsBy.day,
        temporalScope: any(named: 'temporalScope'),
      ),
    ).called(1);

    await tester.tap(find.byKey(const Key('map-panel-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(Timeline), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('marker selection can expand an externally controlled panel without owning its controller', (
    tester,
  ) async {
    final controller = DraggableScrollableController();
    addTearDown(controller.dispose);
    await _pumpMapTimeline(tester, fullSheet: true, sheetController: controller);
    expect(controller.isAttached, isTrue);
    expect(find.byType(Timeline), findsNothing);

    final expansion = controller.animateTo(0.65, duration: const Duration(milliseconds: 200), curve: Curves.easeInOut);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await expansion;
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(Timeline), findsOneWidget);
    expect(controller.size, closeTo(0.65, 0.001));
    final timeline = tester.widget<Timeline>(find.byType(Timeline));
    expect((timeline.bottomSheet! as GeneralBottomSheet).expand, isFalse);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    expect(controller.isAttached, isFalse);
    // MapView owns this controller and may use it again before disposing it.
    void listener() {}
    expect(() => controller.addListener(listener), returnsNormally);
    controller.removeListener(listener);
  });

  testWidgets('header drag opens the panel and an empty GPS result stays usable', (tester) async {
    await _pumpMapTimeline(tester, fullSheet: true);
    expect(find.byType(Timeline), findsNothing);

    await tester.drag(find.byKey(const Key('map-panel-toggle')), const Offset(0, -340));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.byType(Timeline), findsOneWidget);
    expect(find.byKey(const Key('map-panel-asset-count')), findsOneWidget);
    expect(find.byKey(const Key('timeline-grouping-months')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('small screen with keyboard and large text keeps the header reachable', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pumpMapTimeline(tester, fullSheet: true, bottomInset: 24, keyboardInset: 220, textScale: 1.6);

    final header = tester.getRect(find.byKey(const Key('map-panel-toggle')));
    expect(header.bottom, lessThanOrEqualTo(568 - 220));
    expect(header.height, greaterThanOrEqualTo(64));
    await tester.tap(find.byKey(const Key('map-panel-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(Timeline), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opens at All grouping with the grouping pill and no forced groupBy', (tester) async {
    final harness = await _pumpMapTimeline(tester);

    verify(
      () => harness.factory.geographicMap(
        ['user-1'],
        'user-1',
        any(),
        any(),
        groupBy: GroupAssetsBy.day,
        temporalScope: const TimelineTemporalScope.none(),
      ),
    ).called(1);
    // Grouping must come from the route-scoped provider, not a Timeline override.
    expect(tester.widget<Timeline>(find.byType(Timeline)).groupBy, isNull);
    final timeline = tester.widget<Timeline>(find.byType(Timeline));
    expect(timeline.dockGroupingPill, isTrue);
    expect((timeline.bottomSheet! as GeneralBottomSheet).expand, isFalse);
    expect(find.byType(TimelineGroupingFooter), findsOneWidget);
    expect(find.byType(TimelineGroupingBottomPill), findsNothing);
  });

  testWidgets('tapping Months regroups the map timeline without persisting the setting', (tester) async {
    final harness = await _pumpMapTimeline(tester);

    await tester.tap(find.byKey(const Key('timeline-grouping-months')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    verify(
      () => harness.factory.geographicMap(
        ['user-1'],
        'user-1',
        any(),
        any(),
        groupBy: GroupAssetsBy.month,
        temporalScope: any(named: 'temporalScope'),
      ),
    ).called(1);
    // Route-local grouping: the map sheet must never persist the grouping setting.
    verifyNever(() => harness.settings.write(SettingsKey.timelineGroupAssetsBy, any<GroupAssetsBy>()));
  });

  testWidgets('withPartners includes partner ids in the map service users', (tester) async {
    final harness = await _pumpMapTimeline(
      tester,
      mapState: MapState(
        bounds: LatLngBounds(northeast: const LatLng(1, 1), southwest: const LatLng(0, 0)),
        withPartners: true,
      ),
      extraOverrides: [
        timelineUsersProvider.overrideWith((_) => Stream<List<String>>.value(['user-1', 'partner-1'])),
      ],
    );

    // The first build may run before the users stream emits (falls back to
    // [user.id]); once it emits, the service must rebuild with both ids.
    verify(
      () => harness.factory.geographicMap(
        ['user-1', 'partner-1'],
        'user-1',
        any(),
        any(),
        groupBy: GroupAssetsBy.day,
        temporalScope: any(named: 'temporalScope'),
      ),
    ).called(1);
  });

  testWidgets('a map move reaches the options stream without rebuilding the service', (tester) async {
    final harness = await _pumpMapTimeline(tester);

    await tester.tap(find.byKey(const Key('timeline-grouping-months')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    // Consume the initial All-grouping build as well, so the verifyNever below
    // is only about what the pan itself triggered.
    verify(
      () => harness.factory.geographicMap(
        any(),
        any(),
        any(),
        any(),
        groupBy: GroupAssetsBy.day,
        temporalScope: any(named: 'temporalScope'),
      ),
    ).called(1);
    final captured = verify(
      () => harness.factory.geographicMap(
        any(),
        any(),
        any(),
        captureAny(),
        groupBy: GroupAssetsBy.month,
        temporalScope: any(named: 'temporalScope'),
      ),
    ).captured;
    expect(captured, hasLength(1));

    // Since immich-29735 the map query subscribes to an options stream, so new
    // bounds travel down that stream instead of rebuilding the service. The
    // route scope — and with it the route-local grouping — stays alive.
    final emitted = <TimelineMapOptions>[];
    final subscription = (captured.single as Stream<TimelineMapOptions>).listen(emitted.add);
    addTearDown(subscription.cancel);

    final pannedBounds = LatLngBounds(northeast: const LatLng(2, 2), southwest: const LatLng(1, 1));
    harness.mapNotifier.update(MapState(bounds: pannedBounds));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(emitted.map((options) => options.bounds), [pannedBounds]);
    // The verify above consumed the tap-triggered call; a pan must add none.
    verifyNever(
      () => harness.factory.geographicMap(
        any(),
        any(),
        any(),
        any(),
        groupBy: any(named: 'groupBy'),
        temporalScope: any(named: 'temporalScope'),
      ),
    );
  });
}
