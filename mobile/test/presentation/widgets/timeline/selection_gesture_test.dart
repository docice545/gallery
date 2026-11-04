import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_drag_region.dart';

void main() {
  testWidgets('taps and vertical scrolling never start a range selection', (tester) async {
    final started = <int>[];
    final entered = <int>[];
    final tapped = <int>[];
    var ended = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: TimelineDragRegion(
          onStart: (index) => started.add(index.assetIndex),
          onAssetEnter: (index) => entered.add(index.assetIndex),
          onEnd: () => ended++,
          child: ListView.builder(
            itemCount: 40,
            itemBuilder: (context, index) => TimelineAssetIndexWrapper(
              assetIndex: index,
              segmentIndex: 0,
              child: GestureDetector(
                key: ValueKey(index),
                onTap: () => tapped.add(index),
                child: const SizedBox(height: 100, child: ColoredBox(color: Colors.blue)),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey(1)));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey(2)));
    await tester.drag(find.byType(ListView), const Offset(0, -250));
    await tester.pumpAndSettle();
    expect(tapped, [1, 2]);
    expect(started, isEmpty);
    expect(entered, isEmpty);
    expect(ended, 0);
  });

  testWidgets('only a recognized long press starts a range, and cancel clears its anchor', (tester) async {
    final started = <int>[];
    final entered = <int>[];
    var ended = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: TimelineDragRegion(
          onStart: (index) => started.add(index.assetIndex),
          onAssetEnter: (index) => entered.add(index.assetIndex),
          onEnd: () => ended++,
          child: Column(
            children: List.generate(
              3,
              (index) => TimelineAssetIndexWrapper(
                assetIndex: index,
                segmentIndex: 0,
                child: SizedBox(
                  key: ValueKey(index),
                  height: 100,
                  width: 400,
                  child: const ColoredBox(color: Colors.blue),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey(0))));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
    expect(started, [0]);
    await gesture.moveTo(tester.getCenter(find.byKey(const ValueKey(2))));
    expect(entered, [2]);
    await gesture.cancel();
    await tester.pump();
    expect(ended, 1);
    await tester.tap(find.byKey(const ValueKey(1)));
    await tester.pump();
    expect(started, [0]);
    expect(entered, [2]);
    expect(ended, 1);
  });

  testWidgets('a date header is not a photo selection anchor', (tester) async {
    var started = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: TimelineDragRegion(
          onStart: (_) => started++,
          child: Column(
            children: [
              const SizedBox(key: Key('header'), height: 80, width: 400, child: Text('November')),
              TimelineAssetIndexWrapper(
                assetIndex: 0,
                segmentIndex: 0,
                child: const SizedBox(height: 100, width: 400, child: ColoredBox(color: Colors.blue)),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.longPress(find.byKey(const Key('header')));
    expect(started, 0);
  });
}
