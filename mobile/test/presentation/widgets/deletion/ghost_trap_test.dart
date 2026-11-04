import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/presentation/widgets/deletion/ghost_trap.dart';

class _Scene {
  final assets = ValueNotifier(['one', 'two', 'three']);
  final target = ValueNotifier(true);
  late BuildContext context;
  late ProviderContainer container;
  int photoBuilds = 0;

  Future<void> mount(WidgetTester tester, {bool reduced = false}) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (ctx) {
              context = ctx;
              container = ProviderScope.containerOf(ctx);
              return MediaQuery(
                data: MediaQuery.of(ctx).copyWith(disableAnimations: reduced),
                child: Builder(
                  builder: (ctx) {
                    context = ctx;
                    return Scaffold(
                      body: Column(
                        children: [
                          Expanded(
                            child: ValueListenableBuilder(
                              listenable: assets,
                              builder: (_, ids, _) => Align(
                                alignment: Alignment.topLeft,
                                child: Wrap(
                                  children: [
                                    for (final id in ids)
                                      GhostSource(
                                        key: ValueKey(id),
                                        assetKey: id,
                                        requireImage: false,
                                        child: Builder(
                                          builder: (_) {
                                            photoBuilds++;
                                            return SizedBox(
                                              key: ValueKey('photo-$id'),
                                              width: 110,
                                              height: 160,
                                              child: ColoredBox(color: id == 'one' ? Colors.blue : Colors.amber),
                                            );
                                          },
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          ValueListenableBuilder(
                            listenable: target,
                            builder: (_, shown, _) => Offstage(
                              offstage: !shown,
                              child: GhostTrashTarget(
                                kind: GhostTrashKind.server,
                                child: IconButton(
                                  key: const Key('visible-bin'),
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () {},
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      assets.dispose();
      target.dispose();
    });
  }

  Future<GhostFlight?> prepare(WidgetTester tester, [List<String> ids = const ['one']]) =>
      tester.runAsync(() => container.read(ghostTrapProvider).prepare(context, ids, GhostTrashKind.server));
}

GhostTrapPainter _paint(WidgetTester tester) =>
    tester.widget<CustomPaint>(find.byKey(const ValueKey('ghost-trap-flight'))).painter! as GhostTrapPainter;

void main() {
  testWidgets(
    'pending operation holds the actual photo and grid; confirmed 640ms effect reflows without rebuilding images',
    (tester) async {
      final scene = _Scene();
      await scene.mount(tester);
      final before = tester.getTopLeft(find.byKey(const ValueKey('photo-two')));
      final flight = await scene.prepare(tester);
      expect(flight, isNotNull);
      scene.assets.value = ['two', 'three']; // Existing reversible optimistic cache update.
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(_paint(tester).confirmed, isFalse, reason: 'elapsed time does not grant an OS/server receipt');
      expect(_paint(tester).progress, 0);
      expect(tester.getTopLeft(find.byKey(const ValueKey('photo-two'))), before);
      final image = _paint(tester).image;
      final builds = scene.photoBuilds;
      final done = flight!.confirmed();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(_paint(tester).confirmed, isTrue);
      expect(identical(_paint(tester).image, image), isTrue);
      expect(_paint(tester).target, tester.getCenter(find.byKey(const Key('visible-bin'))));
      await tester.pump(const Duration(milliseconds: 230));
      expect(identical(_paint(tester).image, image), isTrue);
      await tester.pump(const Duration(milliseconds: 170));
      expect(tester.getTopLeft(find.byKey(const ValueKey('photo-two'))), before);
      await tester.pump(const Duration(milliseconds: 120));
      await done;
      await tester.pump();
      expect(find.byKey(const ValueKey('ghost-trap-flight')), findsNothing);
      expect(tester.getTopLeft(find.byKey(const ValueKey('photo-two'))).dx, 0);
      expect(
        scene.photoBuilds,
        builds,
        reason: 'animation repaints isolated layers, never rebuilds the timeline/photos',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('denial or server error restores the source without any completed animation', (tester) async {
    final scene = _Scene();
    await scene.mount(tester);
    final flight = await scene.prepare(tester);
    expect(flight, isNotNull);
    scene.assets.value = ['two', 'three'];
    await tester.pump();
    expect(_paint(tester).confirmed, isFalse);
    scene.assets.value = ['one', 'two', 'three']; // Durable operation rollback precedes dismissal.
    flight!.cancel();
    await tester.pump();
    expect(find.byKey(const ValueKey('photo-one')), findsOneWidget);
    expect(find.byKey(const ValueKey('ghost-trap-flight')), findsNothing);
    expect(tester.getTopLeft(find.byKey(const ValueKey('photo-two'))).dx, 110);
    await flight.confirmed(); // A stale completion cannot resurrect a cancelled effect.
    await tester.pump();
    expect(find.byKey(const ValueKey('ghost-trap-flight')), findsNothing);
  });

  testWidgets('batch has one representative; reduced motion fades in 180ms after confirmation', (tester) async {
    final scene = _Scene();
    await scene.mount(tester, reduced: true);
    final flight = await scene.prepare(tester, ['one', 'two', 'three']);
    expect(flight, isNotNull);
    await tester.pump();
    expect(find.byKey(const ValueKey('ghost-trap-flight')), findsOneWidget);
    expect(_paint(tester).reducedMotion, isTrue);
    final done = flight!.confirmed();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 179));
    expect(find.byKey(const ValueKey('ghost-trap-flight')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    await done;
    await tester.pump();
    expect(find.byKey(const ValueKey('ghost-trap-flight')), findsNothing);
  });

  testWidgets('an offstage bin is never an animation target; target disappearance cancels the effect', (tester) async {
    final scene = _Scene();
    await scene.mount(tester);
    scene.target.value = false;
    await tester.pump();
    expect(await scene.prepare(tester), isNull);
    scene.target.value = true;
    await tester.pump();
    final flight = await scene.prepare(tester);
    expect(flight, isNotNull);
    scene.target.value = false;
    await tester.pump();
    await flight!.confirmed();
    await tester.pump();
    expect(find.byKey(const ValueKey('ghost-trap-flight')), findsNothing);
  });

  testWidgets('app pause cancels pending pixels; it cannot confer deletion success', (tester) async {
    final scene = _Scene();
    await scene.mount(tester);
    final flight = await scene.prepare(tester);
    expect(flight, isNotNull);
    scene.container.read(ghostTrapProvider).didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump();
    expect(find.byKey(const ValueKey('ghost-trap-flight')), findsNothing);
    expect(await scene.prepare(tester), isNull);
    scene.container.read(ghostTrapProvider).didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(await scene.prepare(tester), isNotNull);
  });
}
