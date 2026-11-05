import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/colors.dart';
import 'package:immich_mobile/data/server/activity.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/ocr.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/models/server_info/server_version.model.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/bottom_bar.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_control_surface.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_top_app_bar.widget.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/compact_selection_toolbar.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/favorite_bottom_sheet.widget.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/local_album_bottom_sheet.widget.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/remote_album_bottom_sheet.widget.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/timeline_compact_selection.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/trash_bottom_sheet.widget.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/is_motion_video_playing.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/current_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/ocr.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/theme/color_scheme.dart';
import 'package:immich_mobile/theme/theme_data.dart';
import 'package:mocktail/mocktail.dart';

import '../../../riverpod_mocks.dart';
import '../../../unit/factories/local_asset_factory.dart';
import '../../../unit/factories/remote_album_factory.dart';
import '../../../unit/factories/remote_asset_factory.dart';
import '../../../unit/presentation/presentation_context.dart';
import '../bottom_sheet/toolbar_test_app.dart';

class _Viewer extends AssetViewerStateNotifier {
  _Viewer(this.asset);
  final BaseAsset asset;
  @override
  AssetViewerState build() => AssetViewerState(currentAsset: asset);
}

class _Writable extends ReadOnlyModeNotifier {
  @override
  bool build() => false;
}

class _ActivityApi extends Mock implements ActivityApiRepository {}

class _Album extends CurrentAlbumNotifier {
  _Album(this.album);
  final RemoteAlbum album;
  @override
  RemoteAlbum? build() => album;
}

const _baseline = bool.fromEnvironment('FOTO_UNIFIED_BASELINE');
const _output = String.fromEnvironment('FOTO_UNIFIED_CAPTURE');
Future<void> _capture(WidgetTester tester, GlobalKey key, String name, Map<String, Object> geometry) async {
  if (_output.isEmpty) {
    return;
  }
  await tester.runAsync(() async {
    final image = await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage();
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(_output).create(recursive: true);
    await File('$_output/$name.png').writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
    await File('$_output/$name.txt').writeAsString(geometry.entries.map((e) => '${e.key}: ${e.value}').join('\n'));
  });
}

void main() {
  setUpAll(() async {
    await (FontLoader('GoogleSans')..addFont(rootBundle.load('fonts/GoogleSans/GoogleSans-Regular.ttf'))).load();
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 1.5, 2.0]) {
      for (final section in [
        'viewer-cloud',
        'viewer-live-album',
        'viewer-local',
        'viewer-trash',
        'timeline',
        'album-local',
        'album-foto',
        'library-favorites',
        'trash-selection',
      ]) {
        testWidgets('approved bars $section ${brightness.name} font=$scale', (tester) async {
          final fixture = await PresentationContext.create();
          addTearDown(fixture.dispose);
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final trash = section.contains('trash');
          final local = section.contains('local');
          final viewer = section.startsWith('viewer');
          BaseAsset asset = local
              ? LocalAssetFactory.create(id: 'local').copyWith(createdAt: DateTime(2026, 11, 5, 18, 22))
              : RemoteAssetFactory.create(
                  id: 'cloud',
                  ownerId: fixture.currentUser.id,
                  deletedAt: trash ? DateTime(2026, 11, 5) : null,
                );
          if (asset is RemoteAsset) {
            asset = asset.copyWith(
              createdAt: DateTime(2026, 11, 5, 18, 22),
              livePhotoVideoId: section == 'viewer-live-album' ? 'live-component' : null,
            );
          }
          final album = RemoteAlbumFactory.create(
            ownerId: fixture.currentUser.id,
            isShared: true,
            isActivityEnabled: true,
          );
          final activity = _ActivityApi();
          when(() => activity.getAll(any(), assetId: any(named: 'assetId'))).thenAnswer((_) async => []);
          final timeline = TimelineService((
            assetSource: (_, _) async => [asset],
            bucketSource: () => Stream.value(const []),
            origin: trash ? TimelineOrigin.trash : TimelineOrigin.main,
          ));
          addTearDown(timeline.dispose);
          final bottom = switch (section) {
            'timeline' => const TimelineCompactSelection(),
            'album-local' => const LocalAlbumBottomSheet(),
            'album-foto' => RemoteAlbumBottomSheet(album: RemoteAlbumFactory.create(ownerId: fixture.currentUser.id)),
            'library-favorites' => const FavoriteBottomSheet(),
            'trash-selection' => const TrashBottomBar(docked: true),
            _ => const ViewerBottomBar(),
          };
          final key = GlobalKey();
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                ...fixture.overrides,
                ...fixture.selected({asset}),
                if (section == 'viewer-live-album') currentRemoteAlbumProvider.overrideWith(() => _Album(album)),
                activityApiRepositoryProvider.overrideWithValue(activity),
                assetViewerProvider.overrideWith(() => _Viewer(asset)),
                timelineServiceProvider.overrideWithValue(timeline),
                readonlyModeProvider.overrideWith(_Writable.new),
                assetExifProvider(asset).overrideWith((ref) async => null),
                if (asset is RemoteAsset) ocrAssetProvider(asset.id).overrideWith((ref) async => []),
                serverInfoProvider.overrideWith(
                  (ref) => StubServerInfoNotifier(
                    fixture.service.serverInfo,
                    version: const ServerVersion(major: 2, minor: 6, patch: 0),
                  ),
                ),
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
                    alwaysUse24HourFormat: true,
                    padding: const EdgeInsets.only(top: 24, bottom: 24),
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: RepaintBoundary(
                    key: key,
                    child: Scaffold(
                      appBar: viewer ? const ViewerTopAppBar() : null,
                      extendBodyBehindAppBar: true,
                      extendBody: true,
                      body: Stack(
                        children: [
                          const Positioned.fill(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [Color(0xff4798ac), Color(0xff213f52)],
                                ),
                              ),
                            ),
                          ),
                          Center(
                            child: Text(section, style: const TextStyle(color: Colors.white70, fontSize: 18)),
                          ),
                          if (!viewer) Align(alignment: Alignment.bottomCenter, child: bottom),
                        ],
                      ),
                      bottomNavigationBar: viewer ? bottom : null,
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final bottomSurface = find
              .descendant(of: find.byType(bottom.runtimeType), matching: find.byType(ViewerControlSurface))
              .last;
          final rect = tester.getRect(bottomSurface);
          final geometry = <String, Object>{
            'bottom': rect,
            'fontScale': scale,
            'source': _baseline ? '3678203a4d12972ddce6871cc343b4e181b96881' : 'working tree',
          };
          if (viewer) {
            final topSurface = find.descendant(
              of: find.byType(ViewerTopAppBar),
              matching: find.byType(ViewerControlSurface),
            );
            geometry['top'] = tester.getRect(topSurface);
          }
          await _capture(tester, key, '$section-${brightness.name}-$scale', geometry);
          if (!_baseline) {
            expect(rect.left, 12);
            expect(rect.right, 378);
            expect(rect.bottom, 820);
            expect(rect.height, scale == 1 ? 52 : inInclusiveRange(52, 200));
            final actions = find.descendant(of: bottomSurface, matching: find.byType(SelectionToolbarAction));
            final boxes = <Rect>[];
            for (final element in actions.evaluate()) {
              final action = find.byWidget(element.widget);
              final box = tester.getRect(action);
              expect(box.shortestSide, greaterThanOrEqualTo(48));
              expect(rect.inflate(.01).contains(box.topLeft) && rect.inflate(.01).contains(box.bottomRight), isTrue);
              for (final other in boxes) {
                expect(box.deflate(.01).overlaps(other), isFalse, reason: '$box vs $other');
              }
              boxes.add(box);
              final text = find.descendant(of: action, matching: find.byType(RichText)).first;
              final paragraph = tester.renderObject<RenderParagraph>(text);
              expect(paragraph.didExceedMaxLines, isFalse);
              final content = paragraph.text.toPlainText();
              final lines = paragraph.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: content.length));
              expect(
                lines.map((box) => box.top).toSet(),
                hasLength(1),
                reason: 'Each caption fits without clipping or word wrapping',
              );
            }
            final kinds = tester
                .widgetList<FotoIcon>(find.descendant(of: bottomSurface, matching: find.byType(FotoIcon)))
                .map((w) => w.kind.name)
                .toList();
            if (trash) {
              expect(kinds, ['restore', 'trash']);
            }
            if (section == 'viewer-cloud') {
              expect(kinds, ['share', 'edit', 'addAlbum', 'lens', 'trash']);
            }
            if (section == 'viewer-local') {
              expect(kinds, ['share', 'lens', 'deviceTrash']);
            }
            if (section == 'album-local') {
              expect(kinds, ['deviceTrash', 'share', 'upload', 'more']);
            }
            if (section == 'album-foto') {
              expect(kinds, ['trash', 'share', 'link', 'more']);
            }
            if (viewer) {
              final top = find.byType(ViewerTopAppBar);
              final back = find.descendant(
                of: top,
                matching: find.byWidgetPredicate((w) => w is FotoIconButton && w.kind == FotoIconKind.back),
              );
              expect(tester.getSize(back), const Size.square(48));
              expect(tester.getRect(back).top, greaterThanOrEqualTo(24));
              final topSurface = find.descendant(of: top, matching: find.byType(ViewerControlSurface));
              if (scale == 1 && section != 'viewer-live-album') {
                final painted = find.descendant(
                  of: topSurface,
                  matching: find.byWidgetPredicate(
                    (w) => w is Material && w.type != MaterialType.transparency && w.shape is StadiumBorder,
                  ),
                );
                expect(tester.getSize(painted.first).height, 44);
                expect(tester.getSize(top).height, 76); // 24 status + 48 hit target + 4 padding.
              }
              final paragraph = tester.renderObject<RenderParagraph>(
                find.descendant(
                  of: find.byKey(const ValueKey('viewer-compact-date-time')),
                  matching: find.byType(RichText),
                ),
              );
              expect(paragraph.didExceedMaxLines, isFalse);
              if (trash) {
                expect(find.byTooltip('Дополнительные действия'), findsNothing);
              }
            }
          }
          if (section == 'viewer-live-album') {
            final topKinds = tester
                .widgetList<FotoIcon>(
                  find.descendant(of: find.byType(ViewerTopAppBar), matching: find.byType(FotoIcon)),
                )
                .map((w) => w.kind.name)
                .toList();
            expect(topKinds, ['back', 'live', 'comments', 'favorite', 'more']);
            final live = find.byWidgetPredicate((w) => w is FotoIconButton && w.kind == FotoIconKind.live);
            await tester.tap(live);
            await tester.pumpAndSettle();
            expect(
              ProviderScope.containerOf(
                tester.element(find.byType(ViewerTopAppBar)),
              ).read(isPlayingMotionVideoProvider),
              isTrue,
            );
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        });
      }
    }
  }

  testWidgets('local upload and remote OCR remain usable in viewer More', (tester) async {
    final fixture = await PresentationContext.create();
    addTearDown(fixture.dispose);
    final local = LocalAssetFactory.create();
    final remote = RemoteAssetFactory.create(ownerId: fixture.currentUser.id);
    for (final asset in <BaseAsset>[local, remote]) {
      final timeline = TimelineService((
        assetSource: (_, _) async => [asset],
        bucketSource: () => Stream.value(const []),
        origin: TimelineOrigin.main,
      ));
      addTearDown(timeline.dispose);
      await tester.pumpTestWidget(
        fixture,
        const Column(children: [ViewerTopAppBar(), Spacer(), ViewerBottomBar()]),
        overrides: [
          assetViewerProvider.overrideWith(() => _Viewer(asset)),
          timelineServiceProvider.overrideWithValue(timeline),
          assetExifProvider(asset).overrideWith((ref) async => null),
          if (asset is RemoteAsset)
            ocrAssetProvider(asset.id).overrideWith(
              (ref) async => [
                Ocr(
                  id: 'ocr',
                  assetId: asset.id,
                  x1: 0,
                  y1: 0,
                  x2: 1,
                  y2: 0,
                  x3: 1,
                  y3: 1,
                  x4: 0,
                  y4: 1,
                  boxScore: 1,
                  textScore: 1,
                  text: 'FOTO',
                  isVisible: true,
                ),
              ],
            ),
        ],
      );
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      if (asset == local) {
        expect(find.text('Upload'), findsOneWidget);
        await tester.tap(find.text('Upload'));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 2));
      } else {
        final ocr = find.byWidgetPredicate((w) => w is FotoIcon && w.kind == FotoIconKind.ocr);
        expect(ocr, findsOneWidget);
        await tester.tap(ocr);
        await tester.pumpAndSettle();
        expect(
          ProviderScope.containerOf(tester.element(find.byType(ViewerBottomBar))).read(assetViewerProvider).showingOcr,
          isTrue,
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }
  });
}
