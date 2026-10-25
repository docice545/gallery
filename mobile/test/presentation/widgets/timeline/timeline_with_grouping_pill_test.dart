import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/models/timeline_temporal_scope.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/domain/services/user.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/pages/trash.page.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_grouping_footer.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_route_scope.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/infrastructure/user.provider.dart' as infra;
import 'package:immich_mobile/providers/photos_filter/timeline_query.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/services/server_info.service.dart';
import 'package:immich_ui/immich_ui.dart' as ui;
import 'package:intl/date_symbol_data_local.dart';
import 'package:mocktail/mocktail.dart';
// easy_localization initializes shared_preferences internally; tests need the mock initializer.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences/shared_preferences.dart';

import '../../../test_utils.dart';
import '../../../widget_tester_extensions.dart';

class _MockTimelineFactory extends Mock implements TimelineFactory {}

class _MockUserService extends Mock implements UserService {}

class _MockServerInfoService extends Mock implements ServerInfoService {}

class _StubCurrentUserNotifier extends CurrentUserProvider {
  _StubCurrentUserNotifier(super.service, UserDto user) {
    state = user;
  }
}

UserDto _testUser() =>
    UserDto(id: 'user-1', email: 'user-1@example.com', name: 'user-1', profileChangedAt: DateTime(2024));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Drift db;

  setUpAll(() async {
    TestUtils.init();
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    await initializeDateFormatting('en');
    registerFallbackValue(const TimelineTemporalScope.none());
    registerFallbackValue(GroupAssetsBy.day);
    db = Drift(drift.DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: StoreRepository(db), listenUpdates: false);
    await SettingsRepository.ensureInitialized(db);
  });

  setUp(() async {
    await Store.clear();
    await Store.put(StoreKey.serverEndpoint, 'http://test-server');
    await SettingsRepository.instance.write(SettingsKey.timelineTilesPerRow, 3);
  });

  tearDownAll(() async {
    await Store.clear();
    await db.close();
  });

  group('Timeline.withGroupingPill', () {
    testWidgets('Trash opts into a measured footer and uses a measured selection action bar', (tester) async {
      await _pumpTimeline(tester, withGroupingPill: true, trashPage: true);
      expect(find.byType(TimelineGroupingFooter), findsOneWidget);
      expect(find.byKey(const Key('timeline-grouping-bottom-pill')), findsNothing);
      final timeline = tester.widget<Timeline>(find.byType(Timeline));
      expect(timeline.dockGroupingPill, isTrue);

      final container = ProviderScope.containerOf(tester.element(find.byType(Timeline)));
      container
          .read(multiSelectProvider.notifier)
          .selectAsset(
            TestUtils.createRemoteAsset(id: 'trashed', ownerId: 'user-1').copyWith(deletedAt: DateTime(2025)),
          );
      await tester.pumpAndSettle();
      expect(find.byType(TimelineGroupingFooter), findsNothing);
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.bottomNavigationBar, timeline.bottomSheet);
      final actions = tester.getRect(find.byWidget(timeline.bottomSheet!));
      expect(tester.getRect(find.byType(CustomScrollView)).bottom, lessThanOrEqualTo(actions.top));
      expect(find.text('Delete permanently'), findsOneWidget);
      expect(find.text('Restore'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('docked grouping reserves photo space and leaves floating notifications above the footer', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(960, 1800);
      tester.view.devicePixelRatio = 3;
      tester.view.padding = const FakeViewPadding(bottom: 72);
      tester.view.viewPadding = tester.view.padding;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);

      await _pumpTimeline(tester, withGroupingPill: true, dockGroupingPill: true, textScale: 1.8);

      expect(find.byKey(const Key('timeline-grouping-bottom-pill')), findsNothing);
      expect(find.byType(TimelineGroupingFooter), findsOneWidget);
      final footer = tester.getRect(find.byKey(const Key('timeline-grouping-footer')));
      final grid = tester.getRect(find.byType(CustomScrollView));
      expect(grid.bottom, lessThanOrEqualTo(footer.top));
      expect(footer.bottom, 600);
      expect(tester.getRect(find.byKey(const Key('timeline-grouping-selector'))).bottom, lessThanOrEqualTo(576));

      ui.snackbar.success(
        'Фотографии восстановлены',
        action: ui.SnackbarAction(label: 'Отменить', onPressed: () {}),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(SnackBar)).bottom, lessThanOrEqualTo(footer.top));
      expect(find.text('Отменить').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('selection footer replaces grouping and notifications clear the measured action bar', (tester) async {
      const selectionKey = Key('trash-selection-layout');
      await _pumpTimeline(
        tester,
        withGroupingPill: true,
        dockGroupingPill: true,
        bottomSheet: const SizedBox(key: selectionKey, height: 136, child: Text('Удалить навсегда / Восстановить')),
      );
      final container = ProviderScope.containerOf(tester.element(find.byType(Timeline)));
      container.read(multiSelectProvider.notifier).selectAsset(TestUtils.createRemoteAsset(id: 'selected'));
      await tester.pumpAndSettle();
      expect(find.byType(TimelineGroupingFooter), findsNothing);
      final actions = tester.getRect(find.byKey(selectionKey));
      expect(tester.getRect(find.byType(CustomScrollView)).bottom, lessThanOrEqualTo(actions.top));

      ui.snackbar.error('Не удалось удалить оригинал: разрешение внешней библиотеки отсутствует');
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(SnackBar)).bottom, lessThanOrEqualTo(actions.top));

      // A successful restore/delete clears selection. The grouping footer must
      // reappear below an already visible notification without covering it.
      container.read(multiSelectProvider.notifier).reset();
      await tester.pumpAndSettle();
      expect(find.byKey(selectionKey), findsNothing);
      final footer = tester.getRect(find.byKey(const Key('timeline-grouping-footer')));
      expect(tester.getRect(find.byType(SnackBar)).bottom, lessThanOrEqualTo(footer.top));
      expect(tester.takeException(), isNull);
    });

    testWidgets('docked grouping clears the keyboard without an invisible floating hit target', (tester) async {
      await _pumpTimeline(tester, withGroupingPill: true, dockGroupingPill: true, keyboardInset: 280);
      expect(find.byKey(const Key('timeline-grouping-selector')), findsNothing);
      expect(find.byKey(const Key('timeline-grouping-bottom-pill')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('withGroupingPill renders the pill overlay', (tester) async {
      await _pumpTimeline(tester, withGroupingPill: true);

      expect(find.byKey(const Key('timeline-grouping-bottom-pill')), findsOneWidget);
    });

    testWidgets('withGroupingPill adds pill clearance to the content bottom padding', (tester) async {
      await _pumpTimeline(tester, withGroupingPill: false);
      final extentWithout = tester.state<ScrollableState>(find.byType(Scrollable).first).position.maxScrollExtent;

      await _pumpTimeline(tester, withGroupingPill: true);
      final extentWith = tester.state<ScrollableState>(find.byType(Scrollable).first).position.maxScrollExtent;

      // pillHeight(58) + bottomFloat(26) = 84 extra clearance when the flag is on.
      expect(extentWith - extentWithout, closeTo(84, 0.5));
    });

    testWidgets('default (false) renders no pill and no clearance — existing callers unchanged', (tester) async {
      // Pump the flag-on timeline first to get a baseline extent with 84 padding.
      await _pumpTimeline(tester, withGroupingPill: true);
      final extentWith = tester.state<ScrollableState>(find.byType(Scrollable).first).position.maxScrollExtent;

      // Now pump flag-off: no pill visible, no extra clearance.
      await _pumpTimeline(tester, withGroupingPill: false);
      expect(find.byKey(const Key('timeline-grouping-bottom-pill')), findsNothing);
      final extentWithout = tester.state<ScrollableState>(find.byType(Scrollable).first).position.maxScrollExtent;

      // The scroll extent must be 84 less with the flag off (exactly the pill clearance removed).
      expect(extentWith - extentWithout, closeTo(84, 0.5));
    });

    testWidgets('multiselect with the flag on: pill hides, clearance stays constant (+120 modifier), '
        'then reset restores pill and clearance', (tester) async {
      // Pass bottomSheet: null so the GeneralBottomSheet (which needs extra providers)
      // is not rendered — assertions are about the pill and the SliverPadding only.
      await _pumpTimeline(tester, withGroupingPill: true, bottomSheet: null);

      // Capture the baseline scroll extent (pill clearance only, no multiselect).
      final extentBase = tester.state<ScrollableState>(find.byType(Scrollable).first).position.maxScrollExtent;

      // Enable multiselect by selecting an asset via the scoped container.
      final container = ProviderScope.containerOf(tester.element(find.byType(Timeline)));
      final asset = TestUtils.createRemoteAsset(id: 'test-asset');
      container.read(multiSelectProvider.notifier).selectAsset(asset);
      await tester.pumpAndSettle();

      // Pill is hidden while multiselect is active.
      expect(tester.widget<AnimatedOpacity>(find.byKey(const Key('timeline-grouping-bottom-pill-opacity'))).opacity, 0);
      // 84 clearance + 120 bottomSheetOpenModifier = 204 → scroll extent grows by 120 vs baseline.
      final extentMultiselect = tester.state<ScrollableState>(find.byType(Scrollable).first).position.maxScrollExtent;
      // extentMultiselect = content + 84 + 120 = extentWith + 120
      expect(extentMultiselect - extentBase, closeTo(120, 0.5));

      // Exit multiselect → pill returns, clearance back to 84.
      container.read(multiSelectProvider.notifier).reset();
      await tester.pumpAndSettle();

      expect(tester.widget<AnimatedOpacity>(find.byKey(const Key('timeline-grouping-bottom-pill-opacity'))).opacity, 1);
      final extentAfterReset = tester.state<ScrollableState>(find.byType(Scrollable).first).position.maxScrollExtent;
      expect(extentAfterReset, closeTo(extentBase, 0.5));
    });
  });
}

TimelineService _service() {
  final assets = <BaseAsset>[for (var i = 0; i < 4; i++) TestUtils.createRemoteAsset(id: 'asset-$i')];

  return TimelineService((
    bucketSource: () => Stream.value([TimeBucket(date: DateTime(2025, 1), assetCount: 4)]),
    assetSource: (offset, count) async {
      final end = (offset + count).clamp(0, assets.length);
      if (offset >= end) {
        return const <BaseAsset>[];
      }
      return assets.sublist(offset, end);
    },
    origin: TimelineOrigin.main,
  ));
}

/// Pumps a real [Timeline]. NOTE: [bottomSheet] defaults to null (NO sheet) — unlike
/// [Timeline]'s own default GeneralBottomSheet — so tests stay free of the sheet's providers.
Future<void> _pumpTimeline(
  WidgetTester tester, {
  required bool withGroupingPill,
  bool dockGroupingPill = false,
  bool trashPage = false,
  Widget? bottomSheet,
  double textScale = 1,
  double keyboardInset = 0,
}) async {
  final service = _service();
  final factory = _MockTimelineFactory();
  when(
    () => factory.main(
      any(),
      any(),
      groupBy: any(named: 'groupBy'),
      temporalScope: any(named: 'temporalScope'),
    ),
  ).thenReturn(service);
  when(
    () => factory.trash(
      any(),
      groupBy: any(named: 'groupBy'),
      temporalScope: any(named: 'temporalScope'),
    ),
  ).thenReturn(service);

  final user = _testUser();
  final userService = _MockUserService();
  when(() => userService.tryGetMyUser()).thenReturn(user);
  when(() => userService.watchMyUser()).thenAnswer((_) => const Stream<UserDto?>.empty());

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        timelineFactoryProvider.overrideWithValue(factory),
        infra.userServiceProvider.overrideWithValue(userService),
        currentUserProvider.overrideWith((ref) => _StubCurrentUserNotifier(userService, user)),
        timelineUsersProvider.overrideWith((_) => Stream<List<String>>.value([user.id])),
        serverInfoProvider.overrideWith((ref) => ServerInfoNotifier(_MockServerInfoService())),
      ],
      child: EasyLocalization(
        supportedLocales: const [Locale('en')],
        path: '../i18n',
        assetLoader: const CodegenLoader(),
        fallbackLocale: const Locale('en'),
        child: withStubRouter(
          Builder(
            builder: (context) => MaterialApp(
              locale: context.locale,
              supportedLocales: context.supportedLocales,
              localizationsDelegates: context.localizationDelegates,
              scaffoldMessengerKey: ui.scaffoldMessengerKey,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(textScale),
                  viewInsets: EdgeInsets.only(bottom: keyboardInset),
                ),
                child: child!,
              ),
              home: trashPage
                  ? const TrashPage()
                  : TimelineRouteScope(
                      timelineServiceBuilder: buildPhotosTimelineRouteService,
                      child: Timeline(
                        appBar: null,
                        bottomSheet: bottomSheet,
                        withScrubber: false,
                        withGroupingPill: withGroupingPill,
                        dockGroupingPill: dockGroupingPill,
                      ),
                    ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  addTearDown(service.dispose);
}
