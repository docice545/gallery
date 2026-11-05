import 'dart:ui' as ui;

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

  Future<void> mount(
    WidgetTester tester, {
    bool reduced = false,
    bool requireDecodedPhoto = false,
    ui.Image? photo,
  }) async {
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
                              valueListenable: assets,
                              builder: (_, ids, _) => Align(
                                alignment: Alignment.topLeft,
                                child: Wrap(
                                  children: [
                                    for (final id in ids)
                                      GhostSource(
                                        key: ValueKey(id),
                                        assetKey: id,
                                        requireImage: requireDecodedPhoto,
                                        child: Builder(
                                          builder: (_) {
                                            photoBuilds++;
                                            return SizedBox(
                                              key: ValueKey('photo-$id'),
                                              width: 110,
                                              height: 160,
                                              child: requireDecodedPhoto
                                                  ? RawImage(image: photo, fit: BoxFit.fill)
                                                  : ColoredBox(color: id == 'one' ? Colors.blue : Colors.amber),
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
                            valueListenable: target,
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

  Future<GhostFlight?> prepare(WidgetTester tester, [List<String> ids = const ['one']]) => tester
      .runAsync<GhostFlight?>(() => container.read(ghostTrapProvider).prepare(context, ids, GhostTrashKind.server));
}

GhostTrapPainter _paint(WidgetTester tester) =>
    tester.widget<CustomPaint>(find.byKey(const ValueKey('ghost-trap-flight'))).painter! as GhostTrapPainter;

void _ghostTest(String description, WidgetTesterCallback callback) =>
    testWidgets(description, callback, timeout: const Timeout(Duration(seconds: 45)));

Future<ui.Image> _decodedPhoto() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 64, 96), Paint()..color = Colors.blue);
  canvas.drawRect(const Rect.fromLTWH(64, 0, 64, 96), Paint()..color = Colors.amber);
  final picture = recorder.endRecording();
  final original = await picture.toImage(128, 96);
  picture.dispose();
  final png = await original.toByteData(format: ui.ImageByteFormat.png);
  original.dispose();
  final codec = await ui.instantiateImageCodec(png!.buffer.asUint8List());
  final frame = await codec.getNextFrame();
  codec.dispose();
  return frame.image;
}

void main() {
  testWidgets('intake feedback happens once after confirmed swallowing, never pending or cancelled', (tester) async {
    final scene = _Scene();
    await scene.mount(tester);
    var feedback = 0;
    Future<GhostFlight?> prepare() => tester.runAsync<GhostFlight?>(
      () => scene.container
          .read(ghostTrapProvider)
          .prepare(scene.context, ['one'], GhostTrashKind.server, onIntake: () => feedback++),
    );
    final cancelled = await prepare();
    await tester.pump(const Duration(seconds: 2));
    expect(feedback, 0);
    cancelled!.cancel();
    await cancelled.confirmed();
    expect(feedback, 0);
    await tester.pump();
    final flight = await prepare();
    final done = flight!.confirmed();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 490));
    expect(feedback, 0);
    await tester.pump(const Duration(milliseconds: 30));
    expect(feedback, 1);
    await tester.pump(const Duration(milliseconds: 200));
    await done;
    await flight.confirmed();
    expect(feedback, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  _ghostTest('decoded pixels are captured once and retained through every flight phase', (tester) async {
    final photo = (await tester.runAsync(_decodedPhoto))!;
    addTearDown(photo.dispose);
    final scene = _Scene();
    await scene.mount(tester, requireDecodedPhoto: true, photo: photo);
    final flight = await scene.prepare(tester);
    expect(flight, isNotNull);
    await tester.pump();
    final captured = _paint(tester).image;
    expect([captured.width, captured.height], [110, 160]);
    final pixels = (await tester.runAsync(() => captured.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
    List<int> pixel(int x, int y) => pixels.buffer.asUint8List((y * captured.width + x) * 4, 4).toList();
    expect(pixel(10, 80), [33, 150, 243, 255]);
    expect(pixel(100, 80), [255, 193, 7, 255]);
    expect(_paint(tester).confirmed, isFalse);
    final builds = scene.photoBuilds;
    final done = flight!.confirmed();
    await tester.pump();
    for (final elapsed in [100, 200, 200, 100]) {
      await tester.pump(Duration(milliseconds: elapsed));
      expect(identical(_paint(tester).image, captured), isTrue);
      expect(_paint(tester).target, tester.getCenter(find.byKey(const Key('visible-bin'))));
      expect(scene.photoBuilds, builds);
    }
    await tester.pump(const Duration(milliseconds: 41));
    await tester.runAsync(() => done.timeout(const Duration(seconds: 2)));
    await tester.pump();
    expect(find.byKey(const ValueKey('ghost-trap-flight')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  _ghostTest('an undecoded image cannot become a successful photo flight', (tester) async {
    final scene = _Scene();
    await scene.mount(tester, requireDecodedPhoto: true);
    expect(await scene.prepare(tester), isNull);
    await tester.pump();
    expect(find.byKey(const ValueKey('ghost-trap-flight')), findsNothing);
    expect(find.byKey(const ValueKey('photo-one')), findsOneWidget);
  });
  _ghostTest(
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
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.byKey(const ValueKey('ghost-trap-flight')), findsNothing);
      await tester.runAsync(() => done.timeout(const Duration(seconds: 2)));
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

  _ghostTest('denial or server error restores the source without any completed animation', (tester) async {
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

  _ghostTest('batch has one representative; reduced motion fades in 180ms after confirmation', (tester) async {
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
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byKey(const ValueKey('ghost-trap-flight')), findsNothing);
    await tester.runAsync(() => done.timeout(const Duration(seconds: 2)));
    await tester.pump();
    expect(find.byKey(const ValueKey('ghost-trap-flight')), findsNothing);
  });

  _ghostTest('an offstage bin is never an animation target; target disappearance cancels the effect', (tester) async {
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

  _ghostTest('app pause cancels pending pixels; it cannot confer deletion success', (tester) async {
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
