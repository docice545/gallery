import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/segment_builder.dart';
import 'package:immich_mobile/presentation/widgets/timeline/scrubber.widget.dart';
import 'package:immich_mobile/providers/haptic_feedback.provider.dart';
import 'package:intl/date_symbol_data_local.dart';

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
}) async {
  final secondState = secondAttached ?? ValueNotifier(false);
  if (secondAttached == null) {
    addTearDown(secondState.dispose);
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: [hapticFeedbackProvider.overrideWith(_NoHaptics.new)],
      child: MaterialApp(
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
                      buckets: [TimeBucket(date: DateTime(2026, 11, 2), assetCount: 30)],
                      tileHeight: 100,
                      columnCount: 3,
                    ).generate(),
                    timelineHeight: 240,
                    hasAppBar: false,
                    snapToMonth: false,
                    child: CustomScrollView(
                      key: _scrollKey,
                      primary: childController == null,
                      controller: childController,
                      slivers: const [SliverToBoxAdapter(child: SizedBox(height: 2000))],
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
  setUpAll(() => initializeDateFormatting('en'));

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

  testWidgets('a second attachment during a drag cannot broadcast a stale jump and recovery keeps the thumb usable', (
    tester,
  ) async {
    final controller = ScrollController();
    final secondAttached = ValueNotifier(false);
    addTearDown(controller.dispose);
    addTearDown(secondAttached.dispose);
    await _mount(tester, controller, secondAttached: secondAttached);
    await _revealThumb(tester);
    final handlers = tester.widget<GestureDetector>(_thumb);
    handlers.onVerticalDragStart!(DragStartDetails());
    await tester.pump();
    secondAttached.value = true;
    await tester.pump();
    expect(controller.positions, hasLength(2));
    final positions = controller.positions.toList();
    final before = positions.map((position) => position.pixels).toList();
    handlers.onVerticalDragUpdate!(
      DragUpdateDetails(globalPosition: const Offset(790, 200), delta: const Offset(0, 50)),
    );
    await tester.pump();
    expect(positions.map((position) => position.pixels).toList(), before);
    expect(tester.takeException(), isNull);
    handlers.onVerticalDragEnd!(DragEndDetails());
    secondAttached.value = false;
    await tester.pump();
    await _revealThumb(tester);
    expect(controller.positions, hasLength(1));
    expect(_thumb, findsOneWidget);
    final offset = controller.offset;
    await tester.drag(_thumb, const Offset(0, 30));
    await tester.pump();
    expect(controller.offset, greaterThan(offset));
    expect(tester.takeException(), isNull);
  });
}
