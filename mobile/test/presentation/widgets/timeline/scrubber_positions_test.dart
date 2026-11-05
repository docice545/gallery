import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/place.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/constants.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/segment_builder.dart';
import 'package:immich_mobile/presentation/widgets/timeline/scrubber.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/scrubber_segments.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.state.dart';
import 'package:immich_mobile/providers/haptic_feedback.provider.dart';
import 'package:immich_mobile/providers/place_names.provider.dart';
import 'package:immich_mobile/utils/place_names.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../../../test_utils.dart';

const _scrollKey = Key('scrubbed-scroll');
final _thumb = find.byWidgetPredicate(
  (widget) => widget is GestureDetector && widget.onVerticalDragStart != null && widget.onVerticalDragUpdate != null,
);

class _NoHaptics extends HapticNotifier {
  _NoHaptics(super.ref);

  @override
  void selectionClick() {}
}

Future<void> _mount(
  WidgetTester tester,
  ScrollController controller, {
  ValueNotifier<bool>? secondAttached,
  ScrollController? childController,
  bool showFloatingDate = false,
  BaseAsset? asset,
  String? location,
  VoidCallback? onPhotoTap,
  ThemeMode themeMode = ThemeMode.system,
  Color accent = Colors.blue,
  Locale locale = const Locale('en'),
  double textScale = 1,
  double contentStart = 0,
  double scrollHeight = 2000,
  bool snapToMonth = false,
  List<TimeBucket>? buckets,
}) async {
  final secondState = secondAttached ?? ValueNotifier(false);
  if (secondAttached == null) {
    addTearDown(secondState.dispose);
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        hapticFeedbackProvider.overrideWith(_NoHaptics.new),
        timelineDateLocationProvider.overrideWith(
          (ref, id) async => location == null ? null : Place(name: location, assetId: id),
        ),
        placeDisplayNamesProvider.overrideWith((ref, locale) => PlaceDisplayNames(locale.toLanguageTag(), const {})),
      ],
      child: MaterialApp(
        themeMode: themeMode,
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: accent)),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark),
        ),
        locale: locale,
        supportedLocales: const [Locale('en'), Locale('ru'), Locale('de'), Locale('ar')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        scrollBehavior: const MaterialScrollBehavior().copyWith(scrollbars: false),
        home: PrimaryScrollController(
          controller: controller,
          child: ValueListenableBuilder<bool>(
            valueListenable: secondState,
            builder: (context, second, child) => Column(
              children: [
                SizedBox(
                  height: 240,
                  child: Scrubber(
                    key: const Key('scrubber'),
                    layoutSegments: FixedSegmentBuilder(
                      buckets:
                          buckets ??
                          [
                            TimeBucket(date: DateTime(2026, 11, 2), assetCount: 15),
                            TimeBucket(date: DateTime(2026, 11, 1), assetCount: 15),
                          ],
                      tileHeight: 100,
                      columnCount: 3,
                    ).generate(),
                    timelineHeight: 240,
                    hasAppBar: false,
                    snapToMonth: snapToMonth,
                    contentStartOffset: () => contentStart,
                    topPadding: 24,
                    showFloatingDate: showFloatingDate,
                    assetAtIndex: (_) => asset,
                    child: CustomScrollView(
                      key: _scrollKey,
                      primary: childController == null,
                      controller: childController,
                      slivers: [
                        SliverToBoxAdapter(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: onPhotoTap,
                            child: SizedBox(height: scrollHeight),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (second)
                  SizedBox(
                    height: 240,
                    child: CustomScrollView(
                      controller: controller,
                      slivers: const [SliverToBoxAdapter(child: SizedBox(height: 2000))],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });
}

Future<void> _revealThumb(WidgetTester tester) async {
  await tester.drag(find.byKey(_scrollKey), const Offset(0, -100));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  testWidgets('year jump uses measured content origin before any image has loaded', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await _mount(
      tester,
      controller,
      showFloatingDate: true,
      snapToMonth: true,
      contentStart: 300,
      scrollHeight: 10000,
      buckets: [for (var year = 2026; year >= 2012; year--) TimeBucket(date: DateTime(year, 1, 1), assetCount: 15)],
    );
    await _revealThumb(tester);
    final scrubber = tester.widget<Scrubber>(find.byType(Scrubber));
    final stops = buildScrubberSegments(
      layoutSegments: scrubber.layoutSegments,
      timelineHeight: scrubber.timelineHeight - scrubber.topPadding - scrubber.bottomPadding,
      groupBy: scrubber.groupBy,
    );
    final oldYear = stops.firstWhere((segment) => segment.scrollLabel.contains('2020'));
    final gesture = await tester.startGesture(tester.getCenter(_thumb));
    await gesture.moveBy(const Offset(0, 20));
    await gesture.moveTo(
      Offset(
        tester.getCenter(_thumb).dx,
        tester.getTopLeft(find.byType(Scrubber)).dy + scrubber.topPadding + oldYear.startOffset,
      ),
    );
    await tester.pump();
    expect(find.text('Jan 1, 2020'), findsOneWidget);
    expect(find.text('Jan 1, 2026'), findsNothing);
    expect(scrubber.assetAtIndex?.call(15), isNull, reason: 'date navigation cannot wait for decoded photos');
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  setUpAll(() => initializeDateFormatting());

  for (final viewport in [const Size(360, 640), const Size(800, 400)]) {
    for (final locale in [const Locale('ru'), const Locale('de'), const Locale('ar')]) {
      testWidgets('date stays centered through live theme/accent changes: $viewport $locale', (tester) async {
        tester.view.physicalSize = viewport;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
        final controller = ScrollController();
        addTearDown(controller.dispose);
        await _mount(tester, controller, showFloatingDate: true, locale: locale, textScale: 2);
        await _revealThumb(tester);
        final label = find.byKey(const Key('timeline-floating-date'));
        final text = find.byKey(const Key('timeline-floating-date-text'));
        final thumb = find.byKey(const Key('timeline-scroll-thumb'));
        final top = tester.getRect(label).top;
        final thumbRect = tester.getRect(thumb);
        final light = tester.widget<Material>(label).color!;
        void check() {
          final rect = tester.getRect(label);
          expect(rect.center.dx, closeTo(viewport.width / 2, .01));
          expect(rect.top, top);
          expect(rect.right, lessThanOrEqualTo(viewport.width - kScrubberThumbHeight - 12));
          final background = tester.widget<Material>(label).color!.computeLuminance();
          final foreground = tester.widget<Text>(text).style!.color!.computeLuminance();
          final contrast = (background > foreground)
              ? (background + .05) / (foreground + .05)
              : (foreground + .05) / (background + .05);
          expect(contrast, greaterThanOrEqualTo(4.5));
          expect(tester.takeException(), isNull);
        }

        check();
        tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        check();
        expect(tester.widget<Material>(label).color, isNot(light));
        expect(tester.getRect(thumb), thumbRect);
        final dark = tester.widget<Material>(label).color;
        await _mount(
          tester,
          controller,
          showFloatingDate: true,
          locale: locale,
          textScale: 2,
          themeMode: ThemeMode.light,
          accent: Colors.orange,
        );
        await tester.pump(const Duration(milliseconds: 250));
        check();
        expect(tester.widget<Material>(label).color, isNot(dark));
        // Explicit light mode overrides the system's still-dark brightness.
        expect(Theme.of(tester.element(label)).brightness, Brightness.light);
      });
    }
  }

  for (final location in [null, 'Saint Petersburg, a deliberately long location name']) {
    testWidgets('one fixed date overlay ignores photo gestures and uses optional local place: $location', (
      tester,
    ) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      var taps = 0;
      await _mount(
        tester,
        controller,
        showFloatingDate: true,
        asset: TestUtils.createRemoteAsset(id: 'visible-photo'),
        location: location,
        onPhotoTap: () => taps++,
      );
      final label = find.byKey(const Key('timeline-floating-date'));
      expect(label, findsNothing);
      await _revealThumb(tester);
      await tester.pump();
      expect(label, findsOneWidget);
      final before = tester.getRect(label);
      expect(before.top, greaterThanOrEqualTo(24));
      expect(before.bottom, lessThan(240));
      expect(before.right, lessThan(tester.view.physicalSize.width));
      final place = find.byKey(const Key('timeline-floating-location-text'));
      expect(place, location == null ? findsNothing : findsOneWidget);
      if (location != null) {
        expect(tester.widget<Text>(place).overflow, TextOverflow.ellipsis);
      }
      await tester.tapAt(before.center);
      expect(taps, 1);
      final thumbGesture = await tester.startGesture(tester.getCenter(_thumb));
      await thumbGesture.moveBy(const Offset(0, 30));
      await thumbGesture.moveBy(const Offset(0, 40));
      await tester.pump();
      expect(tester.getRect(label).topLeft, before.topLeft);
      expect(label, findsOneWidget);
      // A held drag must not fade the date even after the idle timeout.
      await tester.pump(const Duration(seconds: 2));
      expect(label, findsOneWidget);
      await thumbGesture.up();
      controller.jumpTo(1500);
      await tester.pump();
      expect(find.text('Nov 1, 2026'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(label, findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  test('location fallback uses existing nonblank metadata only', () {
    expect(timelinePlaceLabel(' City ', 'State', 'Country'), 'City');
    expect(timelinePlaceLabel(' ', 'State', 'Country'), 'State');
    expect(timelinePlaceLabel(null, null, 'Country'), 'Country');
    expect(timelinePlaceLabel(null, ' ', null), isNull);
  });

  testWidgets('a shared primary controller with two positions never reads an ambiguous position', (tester) async {
    final controller = ScrollController();
    final secondAttached = ValueNotifier(true);
    addTearDown(controller.dispose);
    addTearDown(secondAttached.dispose);
    await _mount(tester, controller, secondAttached: secondAttached);
    expect(controller.positions, hasLength(2));
    await _revealThumb(tester);
    expect(tester.takeException(), isNull);
    expect(_thumb, findsNothing);
    final positions = controller.positions.toList();
    expect(positions.first.pixels, greaterThan(0));
    expect(positions.last.pixels, 0, reason: 'Scrolling the first view must not jump the other attachment');
  });

  testWidgets('an unattached primary controller is safe and does not control a different child controller', (
    tester,
  ) async {
    final primary = ScrollController();
    final child = ScrollController();
    addTearDown(primary.dispose);
    addTearDown(child.dispose);
    await _mount(tester, primary, childController: child);
    expect(primary.hasClients, isFalse);
    await _revealThumb(tester);
    expect(tester.takeException(), isNull);
    expect(child.offset, greaterThan(0));
    expect(_thumb, findsNothing);
  });

  testWidgets('a single attached position still supports thumb dragging without the floating date', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await _mount(tester, controller);
    await _revealThumb(tester);
    expect(controller.positions, hasLength(1));
    expect(_thumb, findsOneWidget);
    final before = controller.offset;
    await tester.drag(_thumb, const Offset(0, 60));
    await tester.pump();
    expect(controller.offset, greaterThan(before));
    expect(find.text('Nov 2, 2026'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a second attachment during a real thumb drag does not leave ordinary scrolling locked', (tester) async {
    final controller = ScrollController();
    final secondAttached = ValueNotifier(false);
    addTearDown(controller.dispose);
    addTearDown(secondAttached.dispose);
    await _mount(tester, controller, secondAttached: secondAttached);
    await _revealThumb(tester);
    final beforeDrag = controller.offset;
    final thumbGesture = await tester.startGesture(tester.getCenter(_thumb));
    await thumbGesture.moveBy(const Offset(0, 30));
    await thumbGesture.moveBy(const Offset(0, 10));
    await tester.pump();
    expect(controller.offset, greaterThan(beforeDrag), reason: 'The thumb must have accepted the real pointer drag');
    secondAttached.value = true;
    await tester.pump();
    expect(controller.positions, hasLength(2));
    final positions = controller.positions.toList();
    final before = positions.map((position) => position.pixels).toList();
    await thumbGesture.moveBy(const Offset(0, 50));
    await tester.pump();
    expect(positions.map((position) => position.pixels).toList(), before);
    expect(tester.takeException(), isNull);
    // Rebuilding while both positions are attached removes the thumb detector.
    // Its disposed recognizer will not deliver onEnd for this accepted gesture.
    secondAttached.value = false;
    await tester.pump();
    expect(_thumb, findsNothing);
    await thumbGesture.up();
    final container = ProviderScope.containerOf(tester.element(find.byType(Scrubber)));
    final listGesture = await tester.startGesture(tester.getCenter(find.byKey(_scrollKey)));
    await listGesture.moveBy(const Offset(0, -60));
    await tester.pump();
    expect(container.read(timelineStateProvider).isScrolling, isTrue);
    await listGesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(controller.positions, hasLength(1));
    expect(_thumb, findsOneWidget);
    final offset = controller.offset;
    await tester.drag(_thumb, const Offset(0, 30));
    await tester.pump();
    expect(controller.offset, greaterThan(offset));
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling an accepted thumb gesture restores ordinary scroll notifications', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await _mount(tester, controller);
    await _revealThumb(tester);
    final thumbGesture = await tester.startGesture(tester.getCenter(_thumb));
    await thumbGesture.moveBy(const Offset(0, 30));
    await thumbGesture.moveBy(const Offset(0, 10));
    await tester.pump();
    await thumbGesture.cancel();
    final container = ProviderScope.containerOf(tester.element(find.byType(Scrubber)));
    final listGesture = await tester.startGesture(tester.getCenter(find.byKey(_scrollKey)));
    await listGesture.moveBy(const Offset(0, -60));
    await tester.pump();
    expect(container.read(timelineStateProvider).isScrolling, isTrue);
    await listGesture.up();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
