import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/platform/local_image_api.g.dart';
import 'package:immich_mobile/platform/remote_image_api.g.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/timeline_compact_selection.dart';
import 'package:immich_mobile/presentation/widgets/deletion/ghost_trap.dart';
import 'package:immich_mobile/presentation/widgets/images/face_aware_thumbnail_scope.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/thumbnail_framing.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart';

import '../../../test_utils.dart';
import '../../../unit/factories/local_asset_factory.dart';
import '../../../unit/presentation/presentation_context.dart';
import '../../../widget_tester_extensions.dart';
import '../bottom_sheet/toolbar_test_app.dart';

enum _Case { server, local, disabled, reduced, rejected, osCancelled, unloaded }

class _Writable extends ReadOnlyModeNotifier {
  @override
  bool build() => false;
}

final _config = StateProvider((ref) => const AppConfig());
final _flight = find.byKey(const ValueKey('ghost-trap-flight'));
Finder _tile(String id) => find.byWidgetPredicate((widget) => widget is ThumbnailTile && widget.asset?.id == id);
GhostTrapPainter _painter(WidgetTester tester) => tester.widget<CustomPaint>(_flight).painter! as GhostTrapPainter;

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var frame = 0; frame < 200 && !ready(); frame++) {
    await tester.pump(const Duration(milliseconds: 5));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
  }
  expect(ready(), isTrue, reason: 'Real timeline/capture must become ready within the bounded frame loop');
}

// The production thumbnail decoder consumes/frees these synthetic pixels.
// No GhostSource override, fake animation or requireImage=false is involved.
Map<String, int> _pixels(String id) {
  const width = 128;
  const height = 96;
  final pointer = malloc<Uint8>(width * height * 4);
  final bytes = pointer.asTypedList(width * height * 4);
  final color = id.endsWith('0') ? const Color(0xff397c74) : const Color(0xffb06b47);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final offset = (y * width + x) * 4;
      final factor = y > height / 2 ? .65 : 1.0;
      bytes[offset] = (color.r * 255 * factor).round();
      bytes[offset + 1] = (color.g * 255 * factor).round();
      bytes[offset + 2] = (color.b * 255 * factor).round();
      bytes[offset + 3] = 255;
    }
  }
  return {'pointer': pointer.address, 'width': width, 'height': height, 'rowBytes': width * 4};
}

Future<Uint8List> _capture(WidgetTester tester, GlobalKey key, String name) async {
  return (await tester.runAsync(() async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      const directory = String.fromEnvironment('FOTO_TIMELINE_DELETE_CAPTURE');
      if (directory.isNotEmpty) {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(directory).create(recursive: true);
        await File('$directory/$name.png').writeAsBytes(png!.buffer.asUint8List());
      }
      return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }))!;
}

void main() {
  const requestChannel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.RemoteImageApi.requestImage',
    RemoteImageApi.pigeonChannelCodec,
  );
  const cancelChannel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.RemoteImageApi.cancelRequest',
    RemoteImageApi.pigeonChannelCodec,
  );
  const localRequestChannel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.LocalImageApi.requestImage',
    LocalImageApi.pigeonChannelCodec,
  );
  const localCancelChannel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.LocalImageApi.cancelRequest',
    LocalImageApi.pigeonChannelCodec,
  );
  var decodedImages = true;
  final requests = <String>[];
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestUtils.init();
    await (FontLoader('GoogleSans')..addFont(rootBundle.load('fonts/GoogleSans/GoogleSans-Regular.ttf'))).load();
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockDecodedMessageHandler(requestChannel, (message) async {
      final url = (message! as List<Object?>).first! as String;
      requests.add(url);
      final path = Uri.parse(url).pathSegments;
      expect(path.last, 'thumbnail', reason: 'Deletion must not load full originals or open the viewer');
      return <Object?>[decodedImages ? _pixels(path[path.indexOf('assets') + 1]) : null];
    });
    messenger.setMockDecodedMessageHandler(cancelChannel, (_) async => <Object?>[null]);
    messenger.setMockDecodedMessageHandler(localRequestChannel, (message) async {
      final id = (message! as List<Object?>).first! as String;
      requests.add('local:$id');
      return <Object?>[decodedImages ? _pixels(id) : null];
    });
    messenger.setMockDecodedMessageHandler(localCancelChannel, (_) async => <Object?>[null]);
  });
  setUp(() {
    requests.clear();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });
  tearDownAll(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockDecodedMessageHandler(requestChannel, null);
    messenger.setMockDecodedMessageHandler(cancelChannel, null);
    messenger.setMockDecodedMessageHandler(localRequestChannel, null);
    messenger.setMockDecodedMessageHandler(localCancelChannel, null);
  });

  for (final device in [false, true]) {
    testWidgets('Reflow resize keeps decoded pixels but a recycled ${device ? 'local' : 'server'} tile clears them', (
      tester,
    ) async {
      final fixture = await PresentationContext.create();
      addTearDown(fixture.dispose);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      BaseAsset asset(String id) => device
          ? LocalAssetFactory.create(id: id).copyWith(width: 640, height: 480)
          : TestUtils.createRemoteAsset(id: id, ownerId: fixture.currentUser.id, width: 640, height: 480);
      final original = asset('photo-0');
      final source = ValueNotifier((original, const Size(128, 96), AssetMediaSize.thumbnail));
      addTearDown(source.dispose);
      final key = GlobalKey();
      decodedImages = true;
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: ProviderScope(
            overrides: fixture.overrides,
            child: toolbarTestApp(
              theme: ThemeData(),
              home: Center(
                child: SizedBox.square(
                  dimension: 100,
                  child: ValueListenableBuilder(
                    valueListenable: source,
                    builder: (_, value, _) => Thumbnail.fromAsset(
                      asset: value.$1,
                      size: value.$2,
                      remoteSize: value.$2,
                      remoteMediaSize: value.$3,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await _until(tester, () => requests.isNotEmpty);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.byType(Thumbnail));
      final point = rect.topLeft + const Offset(25, 25);
      final offset = (point.dy.floor() * 390 + point.dx.floor()) * 4;
      Future<List<int>> pixel() async => (await _capture(tester, key, 'resize-$device')).sublist(offset, offset + 4);
      expect(await pixel(), [57, 124, 116, 255]);
      final state = tester.state(find.byType(Thumbnail));
      decodedImages = false;
      // Enlarging the surviving cell crosses the server preview threshold.
      // Its new native request cannot supply pixels in this scenario.
      source.value = (original, const Size(512, 384), AssetMediaSize.preview);
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(Thumbnail)), same(state));
      expect(await pixel(), [57, 124, 116, 255]);
      source.value = (asset('photo-1'), const Size(512, 384), AssetMediaSize.preview);
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(Thumbnail)), same(state));
      expect(await pixel(), isNot([57, 124, 116, 255]), reason: 'A recycled cell must not show the previous asset');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final scenario in _Case.values) {
    for (final count in (scenario == _Case.server || scenario == _Case.local ? [1, 3, 4] : [1, 3])) {
      testWidgets('Timeline $scenario for $count selected photos uses the real action and thumbnail renderer', (
        tester,
      ) async {
        final device = scenario == _Case.local || scenario == _Case.osCancelled;
        final rejected = scenario == _Case.rejected || scenario == _Case.osCancelled;
        final reduced = scenario == _Case.reduced;
        decodedImages = scenario != _Case.unloaded;
        final animated = scenario != _Case.disabled && decodedImages;
        final prefix = 'timeline-${scenario.name}-$count';
        final fixture = await PresentationContext.create();
        addTearDown(fixture.dispose);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final assets = List<BaseAsset>.generate(
          4,
          (i) => device
              ? LocalAssetFactory.create(id: 'photo-$i').copyWith(width: 640, height: 480)
              : TestUtils.createRemoteAsset(id: 'photo-$i', ownerId: fixture.currentUser.id, width: 640, height: 480),
        );
        var catalog = List<BaseAsset>.of(assets);
        final updates = StreamController<List<Bucket>>.broadcast(sync: true);
        List<Bucket> buckets() => [
          if (catalog.isNotEmpty) Bucket(assetCount: catalog.length, aspectRatios: List.filled(catalog.length, 4 / 3)),
        ];
        Stream<List<Bucket>> watch() => Stream.multi((controller) {
          controller.addSync(buckets());
          final subscription = updates.stream.listen(controller.addSync, onDone: controller.closeSync);
          controller.onCancel = subscription.cancel;
        }, isBroadcast: true);

        final timeline = TimelineService((
          origin: TimelineOrigin.main,
          bucketSource: watch,
          assetSource: (offset, amount) async => catalog.skip(offset).take(amount).toList(),
        ));
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(() async {
            await timeline.dispose();
            await updates.close();
          });
        });
        final selected = assets.take(count).toSet();
        final ids = selected.map((asset) => asset.id).toList();
        for (final asset in assets) {
          when(() => fixture.service.asset.service.getAsset(asset)).thenAnswer((_) async => asset);
        }
        final requested = Completer<void>();
        final response = Completer<void>();
        Future<void> operation() async {
          requested.complete();
          await response.future;
          if (scenario == _Case.rejected) {
            throw StateError('Synthetic server rejection');
          }
          if (rejected) {
            return;
          }
          catalog = catalog.where((asset) => !ids.contains(asset.id)).toList();
          updates.add(buckets());
          // Rebuild the real grid before the action finishes, just like a repository update.
          await Future<void>.delayed(Duration.zero);
        }

        if (device) {
          when(() => fixture.service.cleanup.service.deleteLocalAssetsDetailed(ids, trash: true)).thenAnswer((_) async {
            await operation();
            return LocalDeletionResult(deletedIds: rejected ? [] : ids, remainingIds: rejected ? ids : []);
          });
        } else {
          when(() => fixture.service.asset.service.trash(ids)).thenAnswer((_) => operation());
        }
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: ProviderScope(
              overrides: [
                ...fixture.overrides,
                timelineServiceProvider.overrideWithValue(timeline),
                readonlyModeProvider.overrideWith(_Writable.new),
                appConfigProvider.overrideWith((ref) => ref.watch(_config)),
                stackCountsProvider.overrideWith((ref) => Stream.value({})),
                thumbnailFaceBoundsProvider.overrideWith((ref, _) => Stream.value(const [])),
              ],
              child: toolbarTestApp(
                theme: ThemeData(fontFamily: 'GoogleSans'),
                home: withStubRouter(
                  MediaQuery(
                    data: MediaQueryData(
                      size: const Size(390, 844),
                      padding: const EdgeInsets.only(top: 24, bottom: 24),
                      disableAnimations: reduced,
                    ),
                    child: const FaceAwareThumbnailScope(
                      child: Timeline(
                        appBar: SliverAppBar(title: Text('FOTO')),
                        denseLayout: true,
                        bottomSheet: TimelineCompactSelection(),
                        dockGroupingPill: true,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await _until(tester, () => find.byType(ThumbnailTile).evaluate().length == 4 && requests.length >= 4);
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
        await tester.pumpAndSettle();
        final decoded = await _capture(tester, key, '$prefix-loaded');
        for (final asset in decodedImages ? assets : <BaseAsset>[]) {
          final rect = tester.getRect(_tile(asset.id));
          final point = rect.topLeft + Offset(rect.width / 4, rect.height / 4);
          final offset = (point.dy.floor() * 390 + point.dx.floor()) * 4;
          expect(
            decoded.sublist(offset, offset + 4),
            asset.id.endsWith('0') ? [57, 124, 116, 255] : [176, 107, 71, 255],
            reason: 'The real custom thumbnail renderer must contain decoded source pixels before deletion',
          );
        }
        await tester.longPress(_tile(assets.first.id));
        await tester.pumpAndSettle();
        for (final asset in selected.skip(1)) {
          await tester.tap(_tile(asset.id));
          await tester.pumpAndSettle();
        }
        final container = ProviderScope.containerOf(tester.element(find.byType(TimelineCompactSelection)));
        expect(container.read(multiSelectProvider).selectedAssets, selected);
        final source = tester.getRect(_tile(assets.first.id));
        final remainingRects = {for (final asset in assets.skip(count)) asset.id: tester.getRect(_tile(asset.id))};
        if (scenario == _Case.disabled) {
          final config = container.read(_config.notifier);
          config.state = config.state.copyWith(theme: config.state.theme.copyWith(fancyDeletion: false));
          await tester.pumpAndSettle();
        }
        final deleteLabel = device ? 'Delete from Device' : 'Move to trash';
        final bin = tester.getRect(find.byTooltip(deleteLabel));
        await _capture(tester, key, '$prefix-before');
        await tester.tap(find.byTooltip(deleteLabel));
        await _until(tester, () => requested.isCompleted);
        await tester.pump();
        expect(_flight, animated ? findsOneWidget : findsNothing);
        if (animated) {
          expect(_painter(tester).confirmed, isFalse);
          expect(_painter(tester).source, source);
          expect(bin.contains(_painter(tester).target), isTrue);
          expect(_painter(tester).reducedMotion, reduced);
        }
        expect(container.read(multiSelectProvider).selectedAssets, selected);
        // The real action guard must reject a second tap while the receipt is pending.
        await tester.tap(find.byTooltip(deleteLabel));
        await tester.pump();
        response.complete();
        await tester.pump();
        if (animated && !rejected) {
          await _until(tester, () => _flight.evaluate().isNotEmpty && _painter(tester).confirmed);
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
          await tester.pump();
          await tester.pump(Duration(milliseconds: reduced ? 80 : 300));
          expect(_painter(tester).progress, inExclusiveRange(.4, .65));
          final flying = await _capture(tester, key, '$prefix-flight');
          if (!reduced) {
            for (final rect in remainingRects.values) {
              final point = rect.topLeft + Offset(rect.width / 4, rect.height / 4);
              final offset = (point.dy.floor() * 390 + point.dx.floor()) * 4;
              expect(flying.sublist(offset, offset + 4), [
                176,
                107,
                71,
                255,
              ], reason: 'Unselected photos must remain painted during intake and grid reflow');
            }
          }
          await tester.pump(Duration(milliseconds: reduced ? 70 : 240));
          expect(_painter(tester).progress, inExclusiveRange(.8, .98));
          final intake = await _capture(tester, key, '$prefix-intake');
          if (!reduced) {
            for (final asset in assets.skip(count)) {
              final rect = tester.getRect(_tile(asset.id));
              final point = rect.topLeft + Offset(rect.width / 4, rect.height / 4);
              final offset = (point.dy.floor() * 390 + point.dx.floor()) * 4;
              expect(intake.sublist(offset, offset + 4), [
                176,
                107,
                71,
                255,
              ], reason: 'Reflow must keep the same photo visible while its resized thumbnail is decoding');
            }
          }
          await tester.pump(reduced ? ghostTrapReducedDuration : ghostTrapDuration);
        }
        await _until(
          tester,
          () => _flight.evaluate().isEmpty && (rejected || container.read(multiSelectProvider).selectedAssets.isEmpty),
        );
        await tester.pumpAndSettle();
        for (final asset in selected) {
          expect(_tile(asset.id), rejected ? findsOneWidget : findsNothing);
        }
        for (final asset in assets.skip(count)) {
          expect(_tile(asset.id), findsOneWidget);
        }
        expect(container.read(multiSelectProvider).selectedAssets, rejected ? selected : isEmpty);
        expect(find.byType(TimelineCompactSelection), rejected ? findsOneWidget : findsNothing);
        // Native image decoding runs outside the widget test's fake clock. The
        // final resized row must finish decoding before checking its pixels.
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
        await tester.pumpAndSettle();
        final after = await _capture(tester, key, '$prefix-after');
        if (decodedImages && !rejected) {
          for (final asset in assets.skip(count)) {
            final rect = tester.getRect(_tile(asset.id));
            final point = rect.topLeft + Offset(rect.width / 4, rect.height / 4);
            final offset = (point.dy.floor() * 390 + point.dx.floor()) * 4;
            expect(after.sublist(offset, offset + 4), [
              176,
              107,
              71,
              255,
            ], reason: 'Remaining thumbnails must still display real pixels after deletion');
          }
        }
        if (device) {
          verify(() => fixture.service.cleanup.service.deleteLocalAssetsDetailed(ids, trash: true)).called(1);
          verifyNever(() => fixture.service.asset.service.trash(any()));
        } else {
          verify(() => fixture.service.asset.service.trash(ids)).called(1);
          verifyNever(() => fixture.service.cleanup.service.deleteLocalAssetsDetailed(any(), trash: true));
        }
        expect(requests, isNotEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      });
    }
  }
}
