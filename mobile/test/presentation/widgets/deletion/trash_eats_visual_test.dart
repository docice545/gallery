import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/compact_selection_toolbar.dart';
import 'package:immich_mobile/presentation/widgets/deletion/ghost_trap.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon.dart';

import '../bottom_sheet/toolbar_test_app.dart';

const _output = String.fromEnvironment('FOTO_TRASH_VISUAL_DIR');

Future<ui.Image> _photo() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 200, 200), Paint()..color = const Color(0xff62c4e9));
  canvas.drawCircle(const Offset(145, 42), 22, Paint()..color = const Color(0xffffe29b));
  canvas.drawPath(
    Path()
      ..moveTo(0, 155)
      ..lineTo(65, 60)
      ..lineTo(150, 155)
      ..close(),
    Paint()..color = const Color(0xff567d72),
  );
  canvas.drawPath(
    Path()
      ..moveTo(60, 155)
      ..lineTo(130, 90)
      ..lineTo(200, 155)
      ..close(),
    Paint()..color = const Color(0xff315e58),
  );
  canvas.drawRect(const Rect.fromLTWH(0, 155, 200, 45), Paint()..color = const Color(0xff1d7db0));
  final picture = recorder.endRecording();
  final image = await picture.toImage(200, 200);
  picture.dispose();
  return image;
}

Future<void> _write(ui.Image image, String name) async {
  if (_output.isEmpty) {
    return;
  }
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  await Directory(_output).create(recursive: true);
  await File('$_output/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await (FontLoader('Roboto')..addFont(rootBundle.load('fonts/GoogleSans/GoogleSans-Regular.ttf'))).load();
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  testWidgets('intake occludes opaque photo pixels behind the front wall before disappearance', (tester) async {
    final red = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 100, 100), Paint()..color = Colors.red);
      final picture = recorder.endRecording();
      final image = await picture.toImage(100, 100);
      picture.dispose();
      return image;
    });
    addTearDown(red!.dispose);
    Future<Uint8List> frame(double progress, String name) async => (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawColor(const Color(0xffeeeeee), BlendMode.src);
      GhostTrapPainter(
        image: red,
        source: const Rect.fromLTWH(24, 60, 128, 160),
        target: const Offset(160, 420),
        progress: progress,
        confirmed: true,
        reducedMotion: false,
        glow: Colors.blue,
        binSurface: Colors.white,
      ).paint(canvas, const Size(320, 480));
      final picture = recorder.endRecording();
      final image = await picture.toImage(320, 480);
      picture.dispose();
      await _write(image, 'occlusion-$name');
      final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return rgba!.buffer.asUint8List();
    }))!;
    List<int> pixel(Uint8List data, int x, int y) => data.sublist((y * 320 + x) * 4, (y * 320 + x) * 4 + 4);
    final inside = await frame(.72, 'inside');
    expect(pixel(inside, 160, 411), [244, 67, 54, 255], reason: 'photo is still opaque above the opening');
    expect(pixel(inside, 160, 420), [255, 255, 255, 255], reason: 'front wall covers the lower photo');
    final swallowed = await frame(.79, 'swallowed');
    var redPixels = 0;
    for (var i = 0; i < swallowed.length; i += 4) {
      if (swallowed[i] == 244 && swallowed[i + 1] == 67 && swallowed[i + 2] == 54) {
        redPixels++;
      }
    }
    expect(redPixels, 0, reason: 'photo is fully inside before drawing it stops at .80; no fade or teleport');
  });

  for (final brightness in Brightness.values) {
    testWidgets('real toolbar $brightness captures all phases without moving its label or hit region', (tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final photo = (await tester.runAsync(_photo))!;
      addTearDown(photo.dispose);
      final boundary = GlobalKey();
      final assets = ValueNotifier([0, 1, 2]);
      addTearDown(assets.dispose);
      late BuildContext context;
      late ProviderContainer container;
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: ProviderScope(
            child: toolbarTestApp(
              theme: ThemeData(brightness: brightness, colorSchemeSeed: Colors.teal, fontFamily: 'Roboto'),
              home: Builder(
                builder: (ctx) {
                  context = ctx;
                  container = ProviderScope.containerOf(ctx);
                  return Scaffold(
                    appBar: AppBar(
                      title: const Text('FOTO'),
                      actions: const [Padding(padding: EdgeInsets.all(16), child: Text('1 selected'))],
                    ),
                    body: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(padding: EdgeInsets.all(16), child: Text('November 2026')),
                        ValueListenableBuilder(
                          valueListenable: assets,
                          builder: (_, ids, _) => Row(
                            children: [
                              for (final i in ids)
                                Expanded(
                                  key: ValueKey(i),
                                  child: Padding(
                                    padding: const EdgeInsets.all(2),
                                    child: GhostSource(
                                      assetKey: 'photo-$i',
                                      child: SizedBox(
                                        height: 170,
                                        child: RawImage(image: photo, fit: BoxFit.cover),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    bottomNavigationBar: CompactSelectionToolbar(
                      deleteButton: GhostTrashTarget(
                        kind: GhostTrashKind.server,
                        child: FotoIconButton(
                          key: const Key('delete-hit-region'),
                          kind: FotoIconKind.trash,
                          label: 'Move to trash',
                          destructive: true,
                          onPressed: () {},
                        ),
                      ),
                      shareButton: FotoIconButton(kind: FotoIconKind.share, label: 'Share', onPressed: () {}),
                      createButton: IconButton(icon: const Icon(Icons.add), onPressed: () {}),
                      moreActions: const [],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = tester.getRect(find.byKey(const Key('delete-hit-region')));
      final label = tester.getRect(find.text('Delete'));
      final neighbor = find.descendant(
        of: find.byWidgetPredicate((widget) => widget is GhostSource && widget.assetKey == 'photo-1'),
        matching: find.byType(RawImage),
      );
      final neighborBefore = tester.getRect(neighbor);
      expect(button.shortestSide, 48);
      Future<void> capture(String phase) async {
        await tester.runAsync(() async {
          final image = await (boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage(
            pixelRatio: 1,
          );
          await _write(image, '${brightness.name}-$phase');
          image.dispose();
        });
      }

      await capture('00-before');
      final flight = await tester.runAsync(
        () => container.read(ghostTrapProvider).prepare(context, ['photo-0'], GhostTrashKind.server),
      );
      expect(flight, isNotNull);
      await tester.pump();
      await capture('01-pending');
      assets.value = [1, 2]; // Synthetic successful deletion receipt; existing reflow holds their positions.
      final completed = flight!.confirmed();
      await tester.pump();
      var elapsed = 0;
      for (final (ms, phase) in [
        (160, '02-flight'),
        (330, '03-lid-open'),
        (420, '04-approach'),
        (461, '05-inside'),
        (506, '06-swallowed'),
        (544, '07-shake'),
        (588, '08-settle'),
      ]) {
        await tester.pump(Duration(milliseconds: ms - elapsed));
        elapsed = ms;
        await capture(phase);
        expect(tester.getRect(find.byKey(const Key('delete-hit-region'))), button);
        expect(tester.getRect(find.text('Delete')), label);
        if (ms <= 506) {
          expect(tester.getRect(neighbor), neighborBefore, reason: 'retain photo extent and cover crop through intake');
        }
        final painter =
            tester.widget<CustomPaint>(find.byKey(const ValueKey('ghost-trap-flight'))).painter! as GhostTrapPainter;
        expect(painter.target, button.center, reason: 'flight ends at icon, never at the whole labelled capsule');
      }
      await tester.pump(Duration(milliseconds: 641 - elapsed));
      await tester.runAsync(() => completed);
      await tester.pump();
      await capture('09-after');
      expect(find.byKey(const ValueKey('ghost-trap-flight')), findsNothing);
      expect(tester.getRect(neighbor).width, greaterThan(neighborBefore.width));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
