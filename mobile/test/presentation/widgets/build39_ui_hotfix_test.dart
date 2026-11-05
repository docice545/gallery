import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/colors.dart';
import 'package:immich_mobile/domain/models/memory.model.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/actions/action.widget.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/base_bottom_sheet.widget.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/compact_selection_toolbar.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon.dart';
import 'package:immich_mobile/presentation/widgets/memory/memory_lane.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/multi_select_status_button.widget.dart';
import 'package:immich_mobile/theme/color_scheme.dart';
import 'package:immich_mobile/theme/theme_data.dart';

import '../../test_utils.dart';
import '../../unit/presentation/presentation_context.dart';
import 'bottom_sheet/toolbar_test_app.dart';

class _Action extends ActionBuilder {
  const _Action(this.label, this.onTap);
  final String? label;
  final FutureOr<void> Function() onTap;
  @override
  ActionItem? create(BuildContext context, WidgetRef ref) => label == null
      ? null
      : ActionItem(icon: Icons.photo_outlined, label: label!, onAction: onTap, onSecondaryAction: onTap);
}

Future<ui.Image> capture(WidgetTester tester, GlobalKey key, String name) async => (await tester.runAsync(() async {
  final image = await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage(pixelRatio: 1);
  const directory = String.fromEnvironment('FOTO_UI_CAPTURE_DIR');
  if (directory.isNotEmpty) {
    await Directory(directory).create(recursive: true);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$directory/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
  }
  return image;
}))!;
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestUtils.init();
    await (FontLoader('GoogleSans')..addFont(rootBundle.load('fonts/GoogleSans/GoogleSans-Regular.ttf'))).load();
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final brightness in Brightness.values) {
    for (final section in ['local', 'album', 'timeline']) {
      final labels = switch (section) {
        'local' => ['Удалить с устройства', 'Поделиться', 'Загрузить'],
        'album' => ['В корзину', 'Поделиться', 'Создать ссылку'],
        _ => ['Удалить', 'Поделиться', 'Добавить'],
      };
      final kinds = switch (section) {
        'local' => [FotoIconKind.deviceTrash, FotoIconKind.share, FotoIconKind.upload],
        'album' => [FotoIconKind.trash, FotoIconKind.share, FotoIconKind.link],
        _ => [FotoIconKind.trash, FotoIconKind.share, FotoIconKind.addAlbum],
      };
      for (final scale in [1.0, 2.0]) {
        testWidgets('Build39 $section selection is content sized $brightness font $scale', (tester) async {
          final fixture = await PresentationContext.create();
          addTearDown(fixture.dispose);
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final key = GlobalKey();
          var taps = 0;
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                ...fixture.overrides,
                ...fixture.selected({TestUtils.createRemoteAsset(id: 'selected')}),
              ],
              child: toolbarTestApp(
                locale: const Locale('ru'),
                theme: getThemeData(
                  colorScheme: brightness == Brightness.light
                      ? ImmichColorPreset.indigo.themeOfPreset.light
                      : ImmichColorPreset.indigo.themeOfPreset.dark,
                  locale: const Locale('ru'),
                ),
                home: MediaQuery(
                  data: MediaQueryData(
                    size: const Size(390, 844),
                    padding: const EdgeInsets.fromLTRB(8, 24, 8, 24),
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: RepaintBoundary(
                    key: key,
                    child: Scaffold(
                      body: Stack(
                        children: [
                          Positioned.fill(
                            child: ListView(
                              padding: const EdgeInsets.only(top: 80),
                              children: [
                                for (final color in [
                                  const Color(0xFF387E78),
                                  const Color(0xFFAA684B),
                                  const Color(0xFF4B6F98),
                                ])
                                  Padding(
                                    padding: const EdgeInsets.all(3),
                                    child: AspectRatio(
                                      aspectRatio: 16 / 9,
                                      child: ColoredBox(
                                        color: color,
                                        child: const Center(
                                          child: Icon(Icons.landscape_outlined, size: 64, color: Colors.white70),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const Positioned(top: 24, left: 12, child: MultiSelectStatusButton()),
                          if (section == 'timeline')
                            Align(
                              alignment: Alignment.bottomCenter,
                              child: CompactSelectionToolbar(
                                deleteButton: IconButton(
                                  icon: FotoIcon(
                                    kind: kinds[0],
                                    semanticLabel: labels[0],
                                    size: 24,
                                    state: FotoIconState.destructive,
                                  ),
                                  onPressed: () => taps++,
                                ),
                                shareButton: IconButton(
                                  icon: FotoIcon(
                                    kind: kinds[1],
                                    semanticLabel: labels[1],
                                    size: 24,
                                    state: FotoIconState.normal,
                                  ),
                                  onPressed: () => taps++,
                                ),
                                createButton: IconButton(
                                  icon: FotoIcon(
                                    kind: kinds[2],
                                    semanticLabel: labels[2],
                                    size: 24,
                                    state: FotoIconState.normal,
                                  ),
                                  onPressed: () => taps++,
                                ),
                                moreActions: [ListTile(title: const Text('Архивировать'), onTap: () {})],
                              ),
                            )
                          else
                            BaseBottomSheet(
                              initialChildSize: .25,
                              actions: [
                                ActionColumnButton(action: _Action(null, () {})),
                                for (var i = 0; i < labels.length; i++)
                                  ActionColumnButton(fotoKind: kinds[i], action: _Action(labels[i], () => taps++)),
                              ],
                              slivers: const [SliverToBoxAdapter(child: Text('Альбомы'))],
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          (await capture(tester, key, 'selection-$section-${brightness.name}-$scale')).dispose();
          final surface = find
              .descendant(
                of: find.byType(section == 'timeline' ? CompactSelectionToolbar : BaseBottomSheet),
                matching: find.byType(Material),
              )
              .first;
          final rect = tester.getRect(surface);
          expect(
            rect.height,
            lessThan(scale == 1 ? 130 : 220),
            reason: 'No screen-fraction blank sheet for only three actions',
          );
          expect(rect.bottom, lessThanOrEqualTo(820));
          expect(rect.left, greaterThanOrEqualTo(12));
          final status = find.byType(MultiSelectStatusButton);
          expect(tester.getSize(status).height, 48);
          final paintedCount = tester.getRect(find.byKey(const ValueKey('selection-count-surface')));
          expect(paintedCount.height, 32);
          expect(paintedCount.width, lessThan(100));
          expect(find.descendant(of: status, matching: find.text('1')), findsOneWidget);
          for (final label in labels) {
            final paragraph = tester.renderObject<RenderParagraph>(find.text(label));
            expect(paragraph.didExceedMaxLines, isFalse);
            final word = label.split(' ').reduce((a, b) => a.length > b.length ? a : b);
            final start = label.indexOf(word);
            expect(
              paragraph.getBoxesForSelection(TextSelection(baseOffset: start, extentOffset: start + word.length)),
              hasLength(1),
              reason: 'Do not split $word across lines',
            );
            if (section == 'timeline') {
              await tester.tap(
                find.byWidgetPredicate((widget) => widget is FotoIcon && widget.kind == kinds[labels.indexOf(label)]),
              );
            } else {
              await tester.tap(find.text(label));
            }
            await tester.pumpAndSettle();
          }
          expect(taps, 3);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        });
      }
    }
    testWidgets('Build39 memory card paints no grey backing or shadow $brightness', (tester) async {
      debugDisableShadows = false;
      addTearDown(() => debugDisableShadows = true);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const background = Color(0xFF1D8875);
      const photo = Color(0xFFEAB44F);
      final memory = Memory(
        id: 'synthetic',
        createdAt: DateTime(2024),
        updatedAt: DateTime(2024),
        ownerId: 'owner',
        type: MemoryTypeEnum.onThisDay,
        data: const MemoryData({'title': 'Летний день'}),
        isSaved: false,
        memoryAt: DateTime(2024),
        assets: [TestUtils.createRemoteAsset(id: 'synthetic')],
      );
      final key = GlobalKey();
      await tester.pumpWidget(
        toolbarTestApp(
          locale: const Locale('ru'),
          theme: getThemeData(
            colorScheme: brightness == Brightness.light
                ? ImmichColorPreset.indigo.themeOfPreset.light
                : ImmichColorPreset.indigo.themeOfPreset.dark,
            locale: const Locale('ru'),
          ),
          home: RepaintBoundary(
            key: key,
            child: Scaffold(
              backgroundColor: background,
              body: Center(
                child: SizedBox(
                  width: 148,
                  height: 200,
                  child: MemoryCard(
                    memory: memory,
                    thumbnailBuilder: (_) => const ColoredBox(color: photo),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final image = await capture(tester, key, 'memory-${brightness.name}');
      debugDisableShadows = true;
      final data = (await tester.runAsync(
        () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
      ))!.buffer.asUint8List();
      final rect = tester.getRect(find.byType(MemoryCard));
      List<int> pixel(Offset p) {
        final index = (p.dy.floor() * 390 + p.dx.floor()) * 4;
        return data.sublist(index, index + 4);
      }

      expect(pixel(Offset(rect.right + 1, rect.center.dy)), [
        29,
        136,
        117,
        255,
      ], reason: 'No shadow beyond photo bounds');
      expect(pixel(rect.topLeft + const Offset(1, 1)), [
        29,
        136,
        117,
        255,
      ], reason: 'No backing underneath clipped corners');
      expect(pixel(rect.topCenter + const Offset(0, 10)), [234, 180, 79, 255]);
      image.dispose();
      expect(find.text('Летний день'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('compact action retains busy guard and secondary action', (tester) async {
    final fixture = await PresentationContext.create();
    addTearDown(fixture.dispose);
    final pending = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: fixture.overrides,
        child: toolbarTestApp(
          home: Scaffold(
            body: BaseBottomSheet(
              actions: [
                ActionColumnButton(
                  action: _Action('Action', () {
                    calls++;
                    return pending.future;
                  }),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Action'));
    await tester.pump();
    await tester.tap(find.text('Action'));
    await tester.longPress(find.text('Action'));
    expect(calls, 1, reason: 'A pending destructive action must not run twice');
    pending.complete();
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Action'));
    await tester.pumpAndSettle();
    expect(calls, 2, reason: 'Secondary actions remain accessible');
    expect(tester.takeException(), isNull);
  });
}
