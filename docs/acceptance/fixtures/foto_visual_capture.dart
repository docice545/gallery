// Copied into mobile/test only by capture-cloud-visuals.sh; synthetic UI evidence.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/memory.model.dart';
import 'package:immich_mobile/presentation/widgets/album/album_trash_reveal.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/compact_selection_toolbar.dart';
import 'package:immich_mobile/presentation/widgets/memory/memory_lane.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_grouping_bottom_pill.widget.dart';
import 'package:immich_mobile/providers/infrastructure/memory.provider.dart';

import 'presentation/widgets/bottom_sheet/toolbar_test_app.dart';
import 'test_utils.dart';
import 'unit/presentation/presentation_context.dart';

class Scene extends CustomPainter {
  const Scene();
  @override
  void paint(Canvas c, Size s) {
    c.drawRect(Offset.zero & s, Paint()..color = const Color(0xff638b8c));
    c.drawCircle(
      Offset(s.width * .7, s.height * .25),
      s.shortestSide * .15,
      Paint()..color = const Color(0xffe4cf9d),
    );
    c.drawPath(
      Path()
        ..moveTo(0, s.height * .8)
        ..lineTo(s.width * .35, s.height * .4)
        ..lineTo(s.width * .65, s.height * .7)
        ..lineTo(s.width, s.height * .45)
        ..lineTo(s.width, s.height)
        ..lineTo(0, s.height)
        ..close(),
      Paint()..color = const Color(0xff315552),
    );
  }

  @override
  bool shouldRepaint(Scene oldDelegate) => false;
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await (FontLoader('Roboto')
          ..addFont(rootBundle.load('fonts/GoogleSans/GoogleSans-Regular.ttf')))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final brightness in Brightness.values) {
    testWidgets('review real grouping pill $brightness', (tester) async {
      final fixture = await PresentationContext.create();
      addTearDown(fixture.dispose);
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(bottom: 24);
      addTearDown(tester.view.reset);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        ProviderScope(
          overrides: fixture.overrides,
          child: toolbarTestApp(
            locale: const Locale('ru'),
            theme: ThemeData(
              brightness: brightness,
              colorSchemeSeed: Colors.teal,
              fontFamily: 'Roboto',
            ),
            home: RepaintBoundary(
              key: boundary,
              child: Scaffold(
                appBar: AppBar(title: const Text('FOTO')),
                body: const Stack(
                  children: [
                    Positioned(
                      top: 12,
                      left: 12,
                      right: 12,
                      height: 260,
                      child: CustomPaint(painter: Scene()),
                    ),
                    TimelineGroupingBottomPill(),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final id in ['years', 'months', 'all']) {
        final button = find.byKey(Key('timeline-grouping-$id'));
        expect(button, findsOneWidget);
        await tester.tap(button);
        await tester.pumpAndSettle();
      }
      final pill = tester.getRect(
        find.byKey(const Key('timeline-grouping-bottom-pill')),
      );
      expect(pill.bottom, lessThanOrEqualTo(852 - 24));
      await tester.runAsync(() async {
        final output = Directory(Platform.environment['FOTO_VISUAL_EVIDENCE']!);
        await output.create(recursive: true);
        final rendered =
            await (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final data = await rendered.toByteData(format: ui.ImageByteFormat.png);
        await File('${output.path}/${brightness.name}-grouping.png')
            .writeAsBytes(data!.buffer.asUint8List());
        rendered.dispose();
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
    testWidgets(
      'review actual controls, whole-row swipe and 16 memory cards $brightness',
      (tester) async {
        final fixture = await PresentationContext.create();
        addTearDown(fixture.dispose);
        tester.view.physicalSize = const Size(393, 852);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final memories = [
          for (var i = 0; i < 16; i++)
            Memory(
              id: 'memory-$i',
              createdAt: DateTime(2026),
              updatedAt: DateTime(2026),
              ownerId: fixture.currentUser.id,
              type: MemoryTypeEnum.onThisDay,
              data: MemoryData({'title': 'Ноябрь ${2025 - i}'}),
              isSaved: false,
              memoryAt: DateTime(2025 - i, 11),
              assets: [TestUtils.createRemoteAsset(id: 'memory-photo-$i')],
            ),
        ];
        final boundary = GlobalKey();
        var deletions = 0;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              ...fixture.overrides,
              visibleMemoryLaneProvider.overrideWithValue(AsyncData(memories)),
              memoryCandidatesProvider.overrideWith((_) async => const []),
            ],
            child: toolbarTestApp(
              locale: const Locale('ru'),
              theme: ThemeData(
                brightness: brightness,
                colorSchemeSeed: Colors.teal,
                fontFamily: 'Roboto',
              ),
              home: RepaintBoundary(
                key: boundary,
                child: Scaffold(
                  appBar: AppBar(title: const Text('FOTO')),
                  body: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      MemoryLane(
                        thumbnailBuilder: (_) =>
                            const CustomPaint(painter: Scene()),
                      ),
                      const SizedBox(height: 20),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: AlbumTrashReveal(
                          onTrash: () async => deletions++,
                          child: const SizedBox(
                            height: 80,
                            child: ListTile(
                              leading: SizedBox(
                                key: Key('album-cover'),
                                width: 60,
                                height: 60,
                                child: CustomPaint(painter: Scene()),
                              ),
                              title: Text('Камера'),
                              subtitle: Text('24 фото'),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: AspectRatio(
                          aspectRatio: 2.7,
                          child: ClipRRect(
                            borderRadius: BorderRadius.all(Radius.circular(6)),
                            child: CustomPaint(painter: Scene()),
                          ),
                        ),
                      ),
                    ],
                  ),
                  bottomNavigationBar: const CompactSelectionToolbar(
                    deleteButton: Icon(Icons.delete_outline),
                    shareButton: Icon(Icons.share_rounded),
                    createButton: Icon(Icons.create_new_folder_outlined),
                    moreActions: [ListTile(title: Text('Архивировать'))],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        Future<void> capture(String name) async {
          await tester.runAsync(() async {
            final output = Directory(
              Platform.environment['FOTO_VISUAL_EVIDENCE']!,
            );
            await output.create(recursive: true);
            final image =
                await (boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            await File('${output.path}/${brightness.name}-$name.png')
                .writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }

        await capture('before');
        final cover = tester.getTopLeft(find.byKey(const Key('album-cover')));
        final title = tester.getTopLeft(find.text('Камера'));
        await tester.drag(find.byType(AlbumTrashReveal), const Offset(-180, 0));
        await tester.pumpAndSettle();
        expect(deletions, 0);
        expect(
          tester.getTopLeft(find.byKey(const Key('album-cover'))).dx,
          closeTo(cover.dx - 64, .1),
        );
        expect(
          tester.getTopLeft(find.text('Камера')).dx,
          closeTo(title.dx - 64, .1),
        );
        await capture('swiped');
        final lane = find
            .descendant(
              of: find.byType(MemoryLane),
              matching: find.byType(Scrollable),
            )
            .first;
        final position = tester.state<ScrollableState>(lane).position;
        final seen = <String>{};
        for (var step = 0; step <= 40; step++) {
          seen.addAll(
            tester
                .widgetList<MemoryCard>(find.byType(MemoryCard))
                .map((c) => c.memory.id),
          );
          if (position.pixels >= position.maxScrollExtent) break;
          position.jumpTo(
            (position.pixels + 100).clamp(0, position.maxScrollExtent),
          );
          await tester.pumpAndSettle();
        }
        expect(seen, memories.map((m) => m.id).toSet());
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
