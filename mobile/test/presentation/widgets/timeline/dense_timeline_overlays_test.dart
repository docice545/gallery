import 'dart:math' as math;

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/local_image_api.g.dart';
import 'package:immich_mobile/platform/remote_image_api.g.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/segment_builder.dart';
import 'package:immich_mobile/presentation/widgets/timeline/live_photo_autoplay.dart';
import 'package:immich_mobile/presentation/widgets/timeline/live_photo_scope.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.state.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_drag_region.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';

import '../../../test_utils.dart';
import '../../../widget_tester_extensions.dart';

const _viewportWidth = 360.0;
const _spacing = 2.0;

RemoteAsset _asset(String id, {double ratio = 1, bool live = false, bool stack = false, bool localVideo = false}) =>
    TestUtils.createRemoteAsset(id: id, width: (ratio * 1000).round(), height: 1000).copyWith(
      localId: localVideo ? 'device-$id' : null,
      livePhotoVideoId: live ? '$id-video' : null,
      stackId: stack ? 'stack-one' : null,
    );

class _Readonly extends ReadOnlyModeNotifier {
  @override
  bool build() => false;
}

class _PlaybackLog {
  final starts = <String>[];
  final stops = <String>[];
  final alive = <String>{};
  final completions = <String, VoidCallback>{};
  int maxConcurrent = 0;
}

class _Preview extends StatefulWidget {
  const _Preview({super.key, required this.asset, required this.log, required this.onCompleted});

  final BaseAsset asset;
  final _PlaybackLog log;
  final VoidCallback onCompleted;

  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  @override
  void initState() {
    super.initState();
    widget.log.starts.add(widget.asset.id);
    widget.log.alive.add(widget.asset.id);
    widget.log.completions[widget.asset.id] = widget.onCompleted;
    widget.log.maxConcurrent = math.max(widget.log.maxConcurrent, widget.log.alive.length);
  }

  @override
  void dispose() {
    widget.log.stops.add(widget.asset.id);
    widget.log.alive.remove(widget.asset.id);
    widget.log.completions.remove(widget.asset.id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.green);
}

Finder _tile(String id) => find.byWidgetPredicate((widget) => widget is ThumbnailTile && widget.asset?.id == id);

Finder _inTile(String id, Finder matching) => find.descendant(of: _tile(id), matching: matching);

Future<void> _settlePreview(WidgetTester tester) async {
  // Focus changes first resolve the local component, then publish its proof in
  // a geometry frame. Flush those frames before advancing the settling timer.
  await tester.pump();
  await tester.pump();
  await tester.pump(livePhotoSettlingDelay);
  await tester.pump();
}

void main() {
  late Drift db;
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

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestUtils.init();
    db = Drift(drift.DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await SettingsRepository.ensureInitialized(db);
    await StoreService.init(storeRepository: StoreRepository(db), listenUpdates: false);
    await Store.put(StoreKey.serverEndpoint, 'https://example.test/api');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockDecodedMessageHandler(requestChannel, (_) async => <Object?>[null]);
    messenger.setMockDecodedMessageHandler(cancelChannel, (_) async => <Object?>[null]);
    messenger.setMockDecodedMessageHandler(localRequestChannel, (_) async => <Object?>[null]);
    messenger.setMockDecodedMessageHandler(localCancelChannel, (_) async => <Object?>[null]);
  });

  setUp(() async {
    await SettingsRepository.instance.clear(SettingsKey.values);
  });

  tearDownAll(() async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockDecodedMessageHandler(requestChannel, null);
    messenger.setMockDecodedMessageHandler(cancelChannel, null);
    messenger.setMockDecodedMessageHandler(localRequestChannel, null);
    messenger.setMockDecodedMessageHandler(localCancelChannel, null);
    await Store.clear();
    await SettingsRepository.reset();
    await db.close();
  });

  Future<ProviderContainer> mountRows(
    WidgetTester tester,
    List<RemoteAsset> assets, {
    List<int>? groups,
    int columns = 3,
    double viewportHeight = 450,
    ScrollController? scroll,
    _PlaybackLog? playback,
  }) async {
    var offset = 0;
    final buckets = (groups ?? [assets.length]).map((count) {
      final rowAssets = assets.skip(offset).take(count);
      offset += count;
      return Bucket(
        assetCount: count,
        aspectRatios: [for (final asset in rowAssets) (asset.width ?? 1) / (asset.height ?? 1)],
      );
    }).toList();
    final service = TimelineService((
      origin: TimelineOrigin.main,
      bucketSource: () => Stream.value(buckets),
      assetSource: (offset, count) async => assets.skip(offset).take(count).toList(),
    ));
    addTearDown(service.dispose);
    // Let the bucket subscription initialize its bounded buffer/total count.
    await tester.pump();
    await service.loadAssets(0, assets.length);
    final segments = FixedSegmentBuilder(
      buckets: buckets,
      tileHeight: (_viewportWidth - _spacing * (columns - 1)) / columns,
      columnCount: columns,
      spacing: _spacing,
      groupBy: GroupAssetsBy.none,
      denseLayout: true,
    ).generate();

    final list = ListView(
      controller: scroll,
      padding: EdgeInsets.zero,
      children: [
        for (final segment in segments)
          for (var index = segment.gridIndex; index <= segment.lastIndex; index++)
            Builder(builder: (context) => segment.builder(context, index)),
      ],
    );

    await tester.pumpConsumerWidgetRaw(
      Center(
        child: SizedBox(
          width: _viewportWidth,
          height: viewportHeight,
          child: playback == null
              ? list
              : TimelineLivePhotoScope(
                  localVideoResolver: (asset) async {
                    expect(asset.storage, AssetState.merged);
                    expect(asset.localId, isNotEmpty);
                    return '/local/${asset.localId}.mp4';
                  },
                  previewBuilder: (asset, onCompleted, onStarted, onFailed) {
                    onStarted();
                    return _Preview(
                      key: ValueKey('preview-${asset.id}'),
                      asset: asset,
                      log: playback,
                      onCompleted: onCompleted,
                    );
                  },
                  child: list,
                ),
        ),
      ),
      overrides: [
        timelineServiceProvider.overrideWithValue(service),
        timelineArgsProvider.overrideWithValue(
          TimelineArgs(
            maxWidth: _viewportWidth,
            maxHeight: viewportHeight,
            columnCount: columns,
            spacing: _spacing,
            showStorageIndicator: true,
            denseLayout: true,
          ),
        ),
        readonlyModeProvider.overrideWith(_Readonly.new),
        appConfigProvider.overrideWithValue(const AppConfig()),
        stackCountsProvider.overrideWith((_) => Stream.value({'stack-one': 3})),
      ],
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
    return ProviderScope.containerOf(tester.element(find.byType(ListView)));
  }

  testWidgets('a solitary portrait stays compact and centered with motion and stack badges', (tester) async {
    final asset = _asset('single', ratio: 0.6, live: true, stack: true);
    await mountRows(tester, [asset]);
    await tester.pumpAndSettle();

    final rect = tester.getRect(_tile(asset.id));
    // Build 39 keeps an isolated date portrait proportional and bounded.
    expect(rect.height, 128);
    expect(rect.width / rect.height, closeTo(.6, .001));
    expect(rect.center.dx, closeTo(tester.getRect(find.byType(ListView)).center.dx, .001));
    final motion = tester.getRect(_inTile(asset.id, find.byIcon(Icons.motion_photos_on_rounded)));
    final stackCount = tester.getRect(_inTile(asset.id, find.text(' 3')));
    final burst = tester.getRect(_inTile(asset.id, find.byIcon(Icons.photo_library_outlined)));
    final cloud = tester.getRect(_inTile(asset.id, find.byIcon(Icons.cloud_outlined)));
    expect(motion.right, closeTo(rect.right - 10, 0.001));
    expect(motion.top, closeTo(rect.top + 6, 0.001));
    expect(burst.left, closeTo(rect.left + 8, 0.001));
    expect(stackCount.bottom, closeTo(rect.bottom - 8, 0.001));
    expect(stackCount.left, closeTo(burst.right, 0.001));
    expect(burst.top, greaterThan(motion.bottom));
    expect(cloud.right, closeTo(rect.right - 10, 0.001));
    expect(cloud.bottom, closeTo(rect.bottom - 6, 0.001));
    expect(tester.takeException(), isNull);
  });

  for (final density in [2, 3, 4, 5]) {
    testWidgets('density $density keeps a Live Photo stack as one tile beside ordinary photos', (tester) async {
      final assets = [
        _asset('screenshot-stack', ratio: .45, live: true, stack: true),
        _asset('landscape', ratio: 1.5),
        _asset('portrait', ratio: .75),
      ];
      await mountRows(tester, assets, columns: density, viewportHeight: 1000);
      await tester.pumpAndSettle();

      expect(find.byType(ThumbnailTile), findsNWidgets(3));
      expect(
        tester.widgetList<ThumbnailTile>(find.byType(ThumbnailTile)).map((tile) => tile.asset!.id),
        assets.map((asset) => asset.id),
      );
      expect(find.byIcon(Icons.photo_library_outlined), findsOneWidget);
      expect(_inTile('screenshot-stack', find.text(' 3')), findsOneWidget);
      expect(_inTile('screenshot-stack', find.byIcon(Icons.motion_photos_on_rounded)), findsOneWidget);
      for (final asset in assets) {
        final rect = tester.getRect(_tile(asset.id));
        expect(rect.width, greaterThanOrEqualTo(72 - .001));
        expect(rect.height, inExclusiveRange(0, 321));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(tester.view.physicalSize.width));
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('portrait and landscape tiles use different widths and fill a two-asset dense row', (tester) async {
    final assets = [_asset('portrait', ratio: 0.5), _asset('landscape', ratio: 2)];
    await mountRows(tester, assets);
    await tester.pumpAndSettle();

    final portrait = tester.getRect(_tile('portrait'));
    final landscape = tester.getRect(_tile('landscape'));
    expect(landscape.width, greaterThan(portrait.width));
    expect(portrait.width + landscape.width + _spacing, closeTo(_viewportWidth, 0.001));
    expect(landscape.left - portrait.right, closeTo(_spacing, 0.001));
    expect(portrait.top, landscape.top);
    expect(portrait.height, landscape.height);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rebalanced mixed rows fill the width without abandoning the last portrait', (tester) async {
    final assets = [
      _asset('one', ratio: 0.5),
      _asset('two', ratio: 1.8),
      _asset('three'),
      _asset('four', ratio: 1.4),
      _asset('five', ratio: 0.7),
    ];
    await mountRows(tester, assets, viewportHeight: 550);
    await tester.pumpAndSettle();

    final wrappers = find.byType(TimelineAssetIndexWrapper);
    expect(wrappers, findsNWidgets(5));
    final rects = [for (final asset in assets) tester.getRect(_tile(asset.id))];
    final left = rects.map((r) => r.left).reduce(math.min);
    for (var y = rects.first.top + 6; y < rects.map((r) => r.bottom).reduce(math.max) - 6; y += 12) {
      for (var x = left + 6; x < left + _viewportWidth - 6; x += 12) {
        expect(rects.any((rect) => rect.inflate(_spacing / 2 + .01).contains(Offset(x, y))), isTrue);
      }
    }
    expect(rects.every((rect) => rect.width < _viewportWidth && rect.width >= 96), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow portraits retain room for motion, selection and stack badges in a mixed row', (tester) async {
    final assets = [
      _asset('narrow', ratio: 0.2, live: true, stack: true),
      for (var index = 0; index < 3; index++) _asset('wide-$index', ratio: 3),
    ];
    await mountRows(tester, assets, columns: 4);
    await tester.pumpAndSettle();
    await tester.longPress(_tile('narrow'));
    await tester.pumpAndSettle();
    final tile = tester.getRect(_tile('narrow'));
    final selection = tester.getRect(_inTile('narrow', find.byIcon(Icons.check_circle_rounded)));
    final motion = tester.getRect(_inTile('narrow', find.byIcon(Icons.motion_photos_on_rounded)));
    final stack = tester.getRect(_inTile('narrow', find.text(' 3')));
    expect(tile.width, greaterThanOrEqualTo(72));
    expect(motion.overlaps(selection), isFalse);
    expect(tile.contains(stack.topLeft), isTrue);
    expect(tile.contains(stack.bottomRight), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long press and selection taps preserve dense image geometry, Hero and badges', (tester) async {
    final asset = _asset('selected', live: true, stack: true);
    final container = await mountRows(tester, [asset]);
    await tester.pumpAndSettle();
    final before = tester.getRect(_tile(asset.id));

    await tester.longPress(_tile(asset.id));
    await tester.pumpAndSettle();

    expect(container.read(multiSelectProvider).selectedAssets, contains(asset));
    expect(tester.getRect(_tile(asset.id)), before);
    final hero = tester.getRect(_inTile(asset.id, find.byType(Hero)));
    expect(hero, before);
    expect(tester.widget<Hero>(_inTile(asset.id, find.byType(Hero))).tag, '${asset.heroTag}_0');
    final selection = tester.getRect(_inTile(asset.id, find.byIcon(Icons.check_circle_rounded)));
    expect(selection.left, closeTo(before.left + 8, 0.001));
    expect(selection.top, closeTo(before.top + 8, 0.001));
    expect(_inTile(asset.id, find.text(' 3')), findsOneWidget);
    final motion = tester.getRect(_inTile(asset.id, find.byIcon(Icons.motion_photos_on_rounded)));
    expect(motion.right, closeTo(hero.right - 10, 0.001));

    await tester.tap(_tile(asset.id));
    await tester.pumpAndSettle();
    expect(container.read(multiSelectProvider).selectedAssets, isEmpty);
    expect(tester.getRect(_tile(asset.id)), before);
    expect(tester.getRect(_inTile(asset.id, find.byType(Hero))), before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dense geometry selects one central visible motion tile and completion never cascades', (tester) async {
    final playback = _PlaybackLog();
    final assets = [
      _asset('left', ratio: 0.6, live: true, localVideo: true),
      _asset('center', ratio: 0.6, live: true, localVideo: true),
      _asset('right', ratio: 0.6, live: true, localVideo: true),
    ];
    await mountRows(tester, assets, playback: playback);
    expect(playback.starts, isEmpty);
    await _settlePreview(tester);

    expect(playback.starts, ['center']);
    expect(playback.maxConcurrent, 1);
    expect(playback.alive, {'center'});
    expect(_inTile('center', find.byType(Thumbnail)), findsOneWidget);
    expect(find.descendant(of: find.byType(Hero), matching: find.byType(_Preview)), findsNothing);

    playback.completions['center']!();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(playback.alive, isEmpty);
    expect(playback.stops, ['center']);
    expect(playback.starts, ['center']);
    expect(find.byType(Thumbnail), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a cropped viewport below the visibility threshold does not autoplay a motion tile', (tester) async {
    final playback = _PlaybackLog();
    await mountRows(tester, [_asset('cropped', live: true, localVideo: true)], viewportHeight: 60, playback: playback);
    final tileHeight = tester.getSize(_tile('cropped')).height;
    expect(60 / tileHeight, lessThan(.65));
    await _settlePreview(tester);
    expect(playback.starts, isEmpty);
  });

  testWidgets('dense rows stop on scroll and require substantial movement to a different candidate', (tester) async {
    final playback = _PlaybackLog();
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final assets = List.generate(4, (index) => _asset('live-$index', live: true, localVideo: true));
    await mountRows(tester, assets, groups: [1, 1, 1, 1], viewportHeight: 240, scroll: scroll, playback: playback);
    await _settlePreview(tester);
    expect(playback.alive, {'live-0'});

    final gesture = await tester.startGesture(tester.getCenter(_tile('live-0')));
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump();
    expect(playback.alive, isEmpty);
    scroll.jumpTo(20);
    await tester.pump(const Duration(seconds: 1));
    await gesture.up();
    await tester.pump();
    await _settlePreview(tester);
    expect(playback.starts, ['live-0'], reason: 'small movement cannot autoplay this settled region again');

    // Use the actual rendered row height rather than the former square-grid
    // pitch: the next full-width row is the new viewport candidate.
    final rowHeight = tester.getSize(_tile('live-0')).height;
    final secondGesture = await tester.startGesture(tester.getCenter(find.byType(ListView)));
    await secondGesture.moveBy(const Offset(0, -40));
    scroll.jumpTo(rowHeight);
    await tester.pump(const Duration(seconds: 1));
    expect(playback.alive, isEmpty, reason: 'active scrolling cannot create a preview');
    await secondGesture.up();
    await tester.pump();
    await _settlePreview(tester);
    expect(playback.starts, ['live-0', 'live-1']);
    expect(playback.alive, {'live-1'});
    expect(playback.maxConcurrent, 1);
    playback.completions['live-1']!();
    await tester.pump();
    await _settlePreview(tester);
    expect(playback.starts, ['live-0', 'live-1']);
    expect(playback.alive, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
