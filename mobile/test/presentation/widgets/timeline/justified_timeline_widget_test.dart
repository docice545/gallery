import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/timeline_config.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/remote_image_api.g.dart';
import 'package:immich_mobile/presentation/widgets/images/face_aware_thumbnail_scope.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/segment.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/segment_builder.dart';
import 'package:immich_mobile/presentation/widgets/timeline/header.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/multi_select_status_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/scrubber.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/scrubber_segments.dart';
import 'package:immich_mobile/presentation/widgets/timeline/segment.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/sliver_segmented_list.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.state.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/providers/haptic_feedback.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/thumbnail_framing.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';

import '../../../test_utils.dart';
import '../../../widget_tester_extensions.dart';

const _spacing = 3.0;
final _testConfig = StateProvider<AppConfig>((_) => const AppConfig());
const _captureArtifacts = bool.fromEnvironment('FOTO_MOSAIC_CAPTURE');
const _artifactDirectory = String.fromEnvironment(
  'FOTO_MOSAIC_ARTIFACT_DIR',
  defaultValue: '/tmp/foto-justified-timeline',
);

Finder _tile(String id) => find.byWidgetPredicate((widget) => widget is ThumbnailTile && widget.asset?.id == id);

class _Readonly extends ReadOnlyModeNotifier {
  @override
  bool build() => false;
}

class _NoHaptics extends HapticNotifier {
  _NoHaptics(super.ref);

  @override
  void heavyImpact() {}
}

class _Fixture {
  const _Fixture(this.container, this.segments, this.boundary, this.scroll);

  final ProviderContainer container;
  final List<Segment> segments;
  final GlobalKey boundary;
  final ScrollController scroll;
}

RemoteAsset _asset(String id, {double ratio = 1}) =>
    TestUtils.createRemoteAsset(id: id, width: (ratio * 500).round(), height: 500).copyWith(name: 'Screenshot_$id.png');

const _sourceColors = [
  Color(0xFF3F6E67),
  Color(0xFFAA684B),
  Color(0xFF4B6F98),
  Color(0xFF81719B),
  Color(0xFF8E9651),
  Color(0xFFB76F87),
];
Color _sourceColor(String id) => _sourceColors[id.codeUnits.fold(0, (sum, code) => sum + code) % _sourceColors.length];

/// Synthetic source pixels delivered through the real native-image request
/// contract. The production decoder consumes and frees this allocation. No HTTP
/// server, original photo, device media or external storage is involved.
Map<String, int> _sourcePixels(String id, Size sourceSize) {
  final base = _sourceColor(id);
  final ratio = sourceSize.width / sourceSize.height;
  final width = math.max(32, (160 * math.min(ratio, 2)).round());
  final height = math.max(32, (width / ratio).round());
  final pointer = malloc<Uint8>(width * height * 4);
  final pixels = pointer.asTypedList(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final index = (y * width + x) * 4;
      final foreground = y > height * .56 + math.sin(x / width * math.pi * 2) * height * .10;
      final highlight =
          (x - width * .68) * (x - width * .68) + (y - height * .23) * (y - height * .23) < width * width * .025;
      final factor = highlight
          ? 1.30
          : foreground
          ? .63
          : 1.0;
      pixels[index] = (base.r * 255 * factor).round().clamp(0, 255);
      pixels[index + 1] = (base.g * 255 * factor).round().clamp(0, 255);
      pixels[index + 2] = (base.b * 255 * factor).round().clamp(0, 255);
      pixels[index + 3] = 255;
    }
  }
  return {'pointer': pointer.address, 'width': width, 'height': height, 'rowBytes': width * 4};
}

Future<Uint8List> _capture(WidgetTester tester, GlobalKey key, {String? name}) async {
  return (await tester.runAsync(() async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      if (_captureArtifacts && name != null) {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        final directory = Directory(_artifactDirectory);
        await directory.create(recursive: true);
        await File('${directory.path}/$name.png').writeAsBytes(png!.buffer.asUint8List());
      }
      final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return rgba!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }))!;
}

List<int> _pixel(Uint8List bytes, int width, Offset point) {
  final index = (point.dy.floor() * width + point.dx.floor()) * 4;
  return bytes.sublist(index, index + 4);
}

void main() {
  late Drift db;
  final sourceSizes = <String, Size>{};
  final requests = <String>[];
  var offlinePreviewFailure = false;
  const requestChannel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.RemoteImageApi.requestImage',
    RemoteImageApi.pigeonChannelCodec,
  );
  const cancelChannel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.RemoteImageApi.cancelRequest',
    RemoteImageApi.pigeonChannelCodec,
  );

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestUtils.init();
    final font = FontLoader('GoogleSans');
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      font.addFont(rootBundle.load('fonts/GoogleSans/GoogleSans-$weight.ttf'));
    }
    await font.load();
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    db = Drift(drift.DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await SettingsRepository.ensureInitialized(db);
    await StoreService.init(storeRepository: StoreRepository(db), listenUpdates: false);
    await Store.put(StoreKey.serverEndpoint, 'https://example.test/api');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockDecodedMessageHandler(requestChannel, (message) async {
      final arguments = message! as List<Object?>;
      final url = arguments.first! as String;
      requests.add(url);
      if (offlinePreviewFailure && Uri.parse(url).queryParameters['size'] == 'preview') {
        return ['network-unavailable', 'Synthetic offline refusal', null];
      }
      final path = Uri.parse(url).pathSegments;
      expect(path.last, 'thumbnail');
      final id = path[path.indexOf('assets') + 1];
      return <Object?>[_sourcePixels(id, sourceSizes[id] ?? const Size(500, 500))];
    });
    messenger.setMockDecodedMessageHandler(cancelChannel, (_) async => <Object?>[null]);
  });

  setUp(() async {
    requests.clear();
    offlinePreviewFailure = false;
    sourceSizes.clear();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await SettingsRepository.instance.clear(SettingsKey.values);
  });

  tearDownAll(() async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockDecodedMessageHandler(requestChannel, null);
    messenger.setMockDecodedMessageHandler(cancelChannel, null);
    await Store.clear();
    await SettingsRepository.reset();
    await db.close();
  });

  Future<_Fixture> mount(
    WidgetTester tester,
    List<RemoteAsset> assets, {
    Size size = const Size(390, 844),
    List<Bucket>? buckets,
    double textScale = 1,
    double decodePixelRatio = 1,
    TimelineAssetSource? source,
    bool withHeaders = false,
    bool realTimeline = false,
    bool selectionChrome = false,
    ValueNotifier<double>? prefixHeight,
    double selectionExpandedHeight = kToolbarHeight,
    EdgeInsets insets = EdgeInsets.zero,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final asset in assets) {
      sourceSizes[asset.id] = Size(asset.width!.toDouble(), asset.height!.toDouble());
    }
    final groups =
        buckets ??
        [Bucket(assetCount: assets.length, aspectRatios: assets.map((asset) => asset.width! / asset.height!).toList())];
    final service = TimelineService((
      origin: TimelineOrigin.main,
      bucketSource: () => Stream.value(groups),
      assetSource: source ?? (offset, count) async => assets.skip(offset).take(count).toList(),
    ));
    addTearDown(service.dispose);
    await tester.pump();
    if (assets.isNotEmpty) {
      await service.loadAssets(0, math.min(20, assets.length));
    }
    final segments = FixedSegmentBuilder(
      buckets: groups,
      tileHeight: (size.width - _spacing * 2) / 3,
      columnCount: 3,
      spacing: _spacing,
      groupBy: withHeaders ? GroupAssetsBy.day : GroupAssetsBy.none,
      denseLayout: true,
    ).generate();
    final boundary = GlobalKey();
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final list = CustomScrollView(
      controller: scroll,
      scrollCacheExtent: const ScrollCacheExtent.pixels(180),
      slivers: [
        SliverSegmentedList(
          segments: segments,
          delegate: SliverChildBuilderDelegate(
            (context, index) => segments.findByIndex(index)?.builder(context, index),
            childCount: segments.isEmpty ? 0 : segments.last.lastIndex + 1,
          ),
        ),
      ],
    );
    await tester.pumpConsumerWidgetRaw(
      MediaQuery(
        data: MediaQueryData(
          size: size,
          devicePixelRatio: decodePixelRatio,
          padding: insets,
          viewPadding: insets,
          textScaler: TextScaler.linear(textScale),
        ),
        child: RepaintBoundary(
          key: boundary,
          child: ColoredBox(
            color: Colors.white,
            child: Theme(
              data: ThemeData(fontFamily: 'GoogleSans'),
              child: FaceAwareThumbnailScope(
                child: realTimeline
                    ? Timeline(
                        appBar: selectionChrome
                            ? SliverAppBar(expandedHeight: selectionExpandedHeight, title: const Text('FOTO'))
                            : null,
                        bottomSheet: selectionChrome ? const SizedBox.shrink() : null,
                        topSliverWidget: prefixHeight == null
                            ? null
                            : SliverToBoxAdapter(
                                child: ValueListenableBuilder<double>(
                                  valueListenable: prefixHeight,
                                  builder: (_, height, _) =>
                                      SizedBox(height: height, child: const Text('Cached memories')),
                                ),
                              ),
                        denseLayout: true,
                        withStack: true,
                      )
                    : list,
              ),
            ),
          ),
        ),
      ),
      overrides: [
        timelineServiceProvider.overrideWithValue(service),
        timelineArgsProvider.overrideWithValue(
          TimelineArgs(maxWidth: size.width, maxHeight: size.height, spacing: _spacing, denseLayout: true),
        ),
        readonlyModeProvider.overrideWith(_Readonly.new),
        hapticFeedbackProvider.overrideWith(_NoHaptics.new),
        appConfigProvider.overrideWith((ref) => ref.watch(_testConfig)),
        thumbnailFaceBoundsProvider.overrideWith((_, _) => Stream.value(const [])),
        stackCountsProvider.overrideWith((_) => Stream.value({})),
      ],
    );
    await EasyLocalization.of(tester.element(find.byType(CustomScrollView)))!.setLocale(const Locale('ru'));
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(tester.element(find.byType(CustomScrollView)));
    return _Fixture(
      container,
      segments,
      boundary,
      realTimeline ? PrimaryScrollController.of(tester.element(find.byType(CustomScrollView))) : scroll,
    );
  }

  testWidgets('offline year navigation, decoded cached photos and late memories share one geometry', (tester) async {
    offlinePreviewFailure = true;
    final prefix = ValueNotifier(0.0);
    addTearDown(prefix.dispose);
    final fixture = await mount(
      tester,
      [
        for (var year = 2026; year >= 2012; year--)
          for (var i = 0; i < 15; i++) _asset('year-$year-$i').copyWith(createdAt: DateTime(year)),
      ],
      realTimeline: true,
      prefixHeight: prefix,
      decodePixelRatio: 3,
      buckets: [
        for (var year = 2026; year >= 2012; year--)
          TimeBucket(date: DateTime(year), assetCount: 15, aspectRatios: List.filled(15, 1)),
      ],
    );
    final config = fixture.container.read(_testConfig.notifier);
    config.state = config.state.copyWith(timeline: config.state.timeline.copyWith(floatingDate: true));
    await tester.pumpAndSettle();
    fixture.scroll.jumpTo(25);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    final scrubber = tester.widget<Scrubber>(find.byType(Scrubber));
    final stops = buildScrubberSegments(
      layoutSegments: scrubber.layoutSegments,
      timelineHeight: scrubber.timelineHeight - scrubber.topPadding - scrubber.bottomPadding,
      groupBy: scrubber.groupBy,
    );
    final stop = stops.firstWhere((segment) => segment.date.year == 2020);
    final thumb = find.byWidgetPredicate((widget) => widget is GestureDetector && widget.onVerticalDragUpdate != null);
    final gesture = await tester.startGesture(tester.getCenter(thumb));
    await gesture.moveBy(const Offset(0, 20));
    await gesture.moveTo(
      Offset(
        tester.getCenter(thumb).dx,
        tester.getTopLeft(find.byType(Scrubber)).dy + scrubber.topPadding + stop.startOffset,
      ),
    );
    await tester.pump();
    final label = find.byKey(const Key('timeline-floating-date-text'));
    expect(tester.widget<Text>(label).data, contains('2020'));
    await gesture.up();
    // Asset rows and native decode complete on separate frames. Keep the date
    // assertion above independent of either completion, then inspect pixels.
    for (var frame = 0; frame < 6; frame++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    final visible = tester.widgetList<ThumbnailTile>(find.byType(ThumbnailTile)).where((tile) {
      final rect = tester.getRect(_tile(tile.asset!.id));
      return rect.top >= 120 && rect.bottom < 750;
    }).toList();
    expect(visible, isNotEmpty);
    expect(visible.first.asset!.id, startsWith('year-2020-'));
    final id = visible.first.asset!.id;
    final before = tester.getRect(_tile(id));
    final pixels = await _capture(tester, fixture.boundary, name: 'offline-year-2020');
    for (final tile in visible) {
      final color = _sourceColor(tile.asset!.id);
      expect(_pixel(pixels, 390, tester.getRect(_tile(tile.asset!.id)).center), [
        (color.r * 255).round(),
        (color.g * 255).round(),
        (color.b * 255).round(),
        255,
      ], reason: 'every visible photo must contain decoded source pixels, never a grey placeholder');
    }
    expect(requests.any((url) => Uri.parse(url).queryParameters['size'] == 'preview'), isTrue);
    prefix.value = 330;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.getRect(_tile(id)), before);
    expect(tester.widget<Text>(label).data, contains('2020'));
    await _capture(tester, fixture.boundary, name: 'offline-year-2020-after-memories');
    expect(tester.takeException(), isNull);
  });

  testWidgets('late memories preserve visible photo through insertion, resize and removal', (tester) async {
    final prefix = ValueNotifier(0.0);
    addTearDown(prefix.dispose);
    final fixture = await mount(
      tester,
      [for (var i = 0; i < 80; i++) _asset('offline-$i')],
      realTimeline: true,
      prefixHeight: prefix,
    );
    fixture.scroll.jumpTo(700);
    await tester.pumpAndSettle();
    final id = tester
        .widgetList<ThumbnailTile>(find.byType(ThumbnailTile))
        .firstWhere((tile) {
          final rect = tester.getRect(_tile(tile.asset!.id));
          return rect.top > 150 && rect.bottom < 700;
        })
        .asset!
        .id;
    final before = tester.getRect(_tile(id));
    for (final height in [224.0, 330.0, 0.0]) {
      prefix.value = height;
      await tester.pumpAndSettle();
      expect(tester.getRect(_tile(id)), before, reason: 'prefix $height cannot move the visible photo');
      expect(fixture.scroll.offset, 700 + height);
      expect(tester.takeException(), isNull);
    }
    fixture.scroll.jumpTo(0);
    await tester.pumpAndSettle();
    prefix.value = 224;
    await tester.pumpAndSettle();
    expect(fixture.scroll.offset, 0, reason: 'fresh memories remain visible at the beginning');
  });

  testWidgets('selection replaces an expanded header without moving the visible photo or changing its ID', (
    tester,
  ) async {
    final assets = [for (var i = 0; i < 60; i++) _asset('anchor-$i')];
    final fixture = await mount(
      tester,
      assets,
      realTimeline: true,
      selectionChrome: true,
      selectionExpandedHeight: 220,
      insets: const EdgeInsets.only(top: 28),
    );
    fixture.scroll.jumpTo(480);
    await tester.pumpAndSettle();
    final visible = tester.widgetList<ThumbnailTile>(find.byType(ThumbnailTile)).firstWhere((tile) {
      final rect = tester.getRect(_tile(tile.asset!.id));
      return rect.top > 150 && rect.bottom < 700;
    }).asset!;
    final before = tester.getRect(_tile(visible.id));
    await tester.longPress(_tile(visible.id));
    await tester.pumpAndSettle();
    expect(fixture.container.read(multiSelectProvider).selectedAssets.single.id, visible.id);
    expect(tester.getRect(_tile(visible.id)), before);
    await tester.tap(find.byType(MultiSelectStatusButton));
    await tester.pumpAndSettle();
    expect(tester.getRect(_tile(visible.id)), before);
    expect(fixture.container.read(multiSelectProvider).selectedIds, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(320, 720), const Size(720, 320)]) {
    testWidgets('actual Timeline selection count stays in one safe toolbar after taps and scroll at $size', (
      tester,
    ) async {
      const insets = EdgeInsets.fromLTRB(24, 28, 24, 24);
      final assets = [for (var i = 0; i < 36; i++) _asset('selection-$i')];
      final fixture = await mount(
        tester,
        assets,
        realTimeline: true,
        selectionChrome: true,
        size: size,
        textScale: 2,
        insets: insets,
        buckets: [
          for (var day = 0; day < 6; day++)
            TimeBucket(date: DateTime(2026, 11, 3 - day), assetCount: 6, aspectRatios: List.filled(6, 1)),
        ],
      );
      await tester.longPress(_tile(assets.first.id));
      await tester.pumpAndSettle();
      final status = find.byType(MultiSelectStatusButton);
      final toolbar = find.byKey(const ValueKey('timeline-selection-toolbar'));
      void checkCount(int expected) {
        expect(fixture.container.read(multiSelectProvider).selectedIds, hasLength(expected));
        expect(find.descendant(of: status, matching: find.text('$expected')), findsOneWidget);
        expect(status, findsOneWidget);
        final rect = tester.getRect(status);
        expect(rect.top, greaterThanOrEqualTo(insets.top));
        expect(rect.bottom, lessThanOrEqualTo(insets.top + kToolbarHeight));
        expect(rect.height, greaterThanOrEqualTo(48));
        expect(rect.left, greaterThanOrEqualTo(insets.left));
        expect(rect.right, lessThanOrEqualTo(size.width - insets.right));
        expect(status.hitTestable(), findsOneWidget);
      }

      checkCount(1);
      expect(toolbar, findsOneWidget);
      final firstHeader = tester.getRect(find.byType(TimelineHeader).first);
      expect(firstHeader.top, greaterThanOrEqualTo(insets.top + kToolbarHeight));
      await tester.tap(_tile(assets[1].id));
      await tester.pump();
      checkCount(2);
      await tester.tap(_tile(assets[1].id));
      await tester.pump();
      checkCount(1);
      expect(fixture.container.read(multiSelectProvider).selectedAssets.single.id, assets.first.id);
      final initialButton = tester.getRect(status);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -450));
      await tester.pumpAndSettle();
      checkCount(1);
      expect(tester.getRect(status), initialButton);
      // The opaque pinned bar owns its entire area; scrolled date/header hit
      // targets cannot compete with the count or the system status inset.
      expect(tester.widget<SliverAppBar>(toolbar).pinned, isTrue);
      expect(tester.widget<SliverAppBar>(toolbar).backgroundColor!.a, 1);
      await tester.tap(status);
      await tester.pumpAndSettle();
      expect(status, findsNothing);
      expect(fixture.container.read(multiSelectProvider).selectedIds, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final selectionChrome in [false, true]) {
    testWidgets(
      'real Timeline switches presentation and density while preserving the selected asset and scroll anchor (selection chrome: $selectionChrome)',
      (tester) async {
        final assets = [
          for (var i = 0; i < 60; i++) _asset('mode-$i', ratio: [.45, 1.5, .75][i % 3]),
        ];
        final fixture = await mount(
          tester,
          assets,
          realTimeline: true,
          selectionChrome: selectionChrome,
          buckets: [
            for (var day = 0; day < 6; day++)
              TimeBucket(
                date: DateTime(2026, 11, 3 - day),
                assetCount: 10,
                aspectRatios: assets.skip(day * 10).take(10).map((asset) => asset.width! / asset.height!).toList(),
              ),
          ],
        );
        fixture.scroll.jumpTo(900);
        await tester.pumpAndSettle();
        final visible = tester
            .widgetList<ThumbnailTile>(find.byType(ThumbnailTile))
            .where((tile) {
              final rect = tester.getRect(_tile(tile.asset!.id));
              return rect.top >= 0 && rect.bottom <= 844;
            })
            .first
            .asset!;
        await tester.longPress(_tile(visible.id));
        await tester.pumpAndSettle();
        final selectedBefore = fixture.container
            .read(multiSelectProvider)
            .selectedAssets
            .map((asset) => asset.id)
            .toSet();
        expect(selectedBefore, {visible.id});
        final config = fixture.container.read(_testConfig.notifier);
        config.state = config.state.copyWith(
          timeline: config.state.timeline.copyWith(presentation: TimelinePresentation.immersive),
        );
        await tester.pumpAndSettle();
        expect(
          fixture.container.read(multiSelectProvider).selectedAssets.map((asset) => asset.id).toSet(),
          selectedBefore,
        );
        final immersiveSegments = fixture.container.read(timelineSegmentProvider).requireValue;
        expect(immersiveSegments.every((segment) => segment.headerExtent == 0), isTrue);
        expect(
          fixture.scroll.offset,
          greaterThan(0),
          reason: 'Presentation switching must not reset to the newest photo',
        );
        expect(_tile(visible.id), findsOneWidget);
        List<List<List<double>>> geometry(List<Segment> segments) => [
          for (final segment in segments.cast<FixedSegment>())
            [
              for (var row = 0; row < segment.rows.rowCount; row++)
                [segment.rows.heightForRow(row), ...segment.rows.widthsForRow(row)],
            ],
        ];
        final geometryBefore = geometry(immersiveSegments);
        config.state = config.state.copyWith(timeline: config.state.timeline.copyWith(tilesPerRow: 2));
        await tester.pumpAndSettle();
        expect(fixture.container.read(timelineArgsProvider).columnCount, 2);
        final resizedSegments = fixture.container.read(timelineSegmentProvider).requireValue;
        expect(resizedSegments.cast<FixedSegment>().map((segment) => segment.columnCount), everyElement(2));
        expect(geometry(resizedSegments), isNot(equals(geometryBefore)));
        // Justified density is a target: a particular mixed-aspect row can retain
        // its partition and width. Verify the real tile against the new layout,
        // rather than imposing a hard per-photo size change on the mosaic.
        final assetIndex = assets.indexWhere((asset) => asset.id == visible.id);
        final segment = resizedSegments.cast<FixedSegment>().singleWhere(
          (segment) =>
              assetIndex >= segment.firstAssetIndex && assetIndex < segment.firstAssetIndex + segment.bucket.assetCount,
        );
        final relativeIndex = assetIndex - segment.firstAssetIndex;
        final row = segment.rows.rowForAssetIndex(relativeIndex);
        final expectedWidth = segment.rows.widthsForRow(row)[relativeIndex - segment.rows.firstAssetIndexForRow(row)];
        expect(
          _tile(visible.id).hitTestable(),
          findsOneWidget,
          reason: 'Density changes must restore the actual visible mosaic, including while selection chrome is active',
        );
        expect(tester.getRect(_tile(visible.id)).width, closeTo(expectedWidth, .01));
        expect(fixture.scroll.offset, greaterThan(0));
        config.state = config.state.copyWith(
          timeline: config.state.timeline.copyWith(presentation: TimelinePresentation.classic),
        );
        await tester.pumpAndSettle();
        expect(
          fixture.container.read(timelineSegmentProvider).requireValue.every((segment) => segment.headerExtent > 0),
          isTrue,
        );
        expect(
          fixture.container.read(multiSelectProvider).selectedAssets.map((asset) => asset.id).toSet(),
          selectedBefore,
        );
        expect(
          _tile(visible.id).hitTestable(),
          findsOneWidget,
          reason: 'Returning to Classic must retain the same visible photo',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final ratios in [
    <double>[.5],
    <double>[.5, 1.8],
    <double>[.55, 1.7, 1, .7, 1.4, .45],
  ]) {
    testWidgets('real sliver mosaic renders ${ratios.length} images without empty cells or original requests', (
      tester,
    ) async {
      final assets = [for (var i = 0; i < ratios.length; i++) _asset('image-$i', ratio: ratios[i])];
      final fixture = await mount(tester, assets);
      expect(find.byType(ThumbnailTile), findsNWidgets(assets.length));
      expect(
        tester.widgetList<ThumbnailTile>(find.byType(ThumbnailTile)).map((tile) => tile.asset!.id),
        assets.map((asset) => asset.id),
      );
      final rows = <double, List<Rect>>{};
      for (final asset in assets) {
        final rect = tester.getRect(_tile(asset.id));
        expect(rect.width, greaterThan(0));
        expect(rect.height, greaterThan(0));
        rows.putIfAbsent(rect.top, () => []).add(rect);
      }
      for (final row in rows.values) {
        for (var i = 1; i < row.length; i++) {
          expect(row[i].top, row.first.top);
          expect(row[i].height, row.first.height);
          expect(row[i].left - row[i - 1].right, closeTo(_spacing, 1e-6));
        }
        expect(row.last.right, lessThanOrEqualTo(390 + 1e-6));
      }
      final bytes = await _capture(tester, fixture.boundary);
      for (final asset in assets) {
        final center = tester.getRect(_tile(asset.id)).center;
        expect(_pixel(bytes, 390, center), isNot([255, 255, 255, 255]));
      }
      expect(requests, isNotEmpty);
      expect(requests.every((url) => Uri.parse(url).path.endsWith('/thumbnail')), isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('selection keeps image geometry and elements stable with the existing six-pixel tile corners', (
    tester,
  ) async {
    final assets = [for (var i = 0; i < 6; i++) _asset('select-$i', ratio: i.isEven ? .65 : 1.35)];
    final fixture = await mount(tester, assets);
    final rectangles = {for (final asset in assets) asset.id: tester.getRect(_tile(asset.id))};
    final elements = {for (final asset in assets) asset.id: tester.element(_tile(asset.id))};
    final initialRequests = requests.length;
    final before = await _capture(tester, fixture.boundary, name: 'portrait-unselected-390x844');
    await tester.longPress(_tile(assets.first.id));
    await tester.pumpAndSettle();
    expect(fixture.container.read(multiSelectProvider).selectedAssets, contains(assets.first));
    final selected = await _capture(tester, fixture.boundary, name: 'portrait-selected-390x844');
    expect(
      _pixel(before, 390, rectangles[assets.first.id]!.center),
      isNot(_pixel(selected, 390, rectangles[assets.first.id]!.center)),
    );
    final first = rectangles[assets.first.id]!;
    // Sample fully outside the six-pixel arc, away from its antialiased edge.
    expect(_pixel(selected, 390, first.topLeft + const Offset(.5, .5)), [255, 255, 255, 255]);
    final firstRow = rectangles.values.where((rect) => rect.top == first.top).toList();
    expect(firstRow.length, greaterThan(1));
    expect(_pixel(before, 390, firstRow.last.topRight + const Offset(-.5, .5)), [255, 255, 255, 255]);
    expect(_pixel(before, 390, firstRow.first.topRight + const Offset(-.5, .5)), [
      255,
      255,
      255,
      255,
    ], reason: 'Build 31-32 rounds internal tile corners as well as group edges');
    final nextRow = rectangles.values.firstWhere((rect) => rect.top > first.top);
    expect(_pixel(before, 390, nextRow.topLeft + const Offset(.5, .5)), [
      255,
      255,
      255,
      255,
    ], reason: 'following rows retain the same tile corners');
    expect(_pixel(before, 390, nextRow.topLeft + const Offset(6, 6)), isNot([255, 255, 255, 255]));
    for (final asset in assets) {
      final clip = tester.widget<ClipRRect>(find.ancestor(of: _tile(asset.id), matching: find.byType(ClipRRect)).first);
      expect(clip.borderRadius, BorderRadius.circular(6));
    }
    await tester.tap(_tile(assets[1].id));
    await tester.pumpAndSettle();
    expect(fixture.container.read(multiSelectProvider).selectedAssets, unorderedEquals(assets.take(2)));
    await tester.tap(_tile(assets.first.id));
    await tester.pumpAndSettle();
    expect(fixture.container.read(multiSelectProvider).selectedAssets, unorderedEquals([assets[1]]));
    fixture.container.read(multiSelectProvider.notifier).reset();
    await tester.pumpAndSettle();
    for (final asset in assets) {
      expect(tester.getRect(_tile(asset.id)), rectangles[asset.id]);
      expect(tester.element(_tile(asset.id)), same(elements[asset.id]));
    }
    expect(requests.length, initialRequests, reason: 'selection must not restart thumbnail requests');
    expect(tester.takeException(), isNull);
  });

  testWidgets('date and month boundaries preserve order and date selection across differently shaped rows', (
    tester,
  ) async {
    final assets = [_asset('november', ratio: .55), _asset('october-a', ratio: 1.6), _asset('october-b', ratio: .7)];
    final fixture = await mount(
      tester,
      assets,
      buckets: [
        TimeBucket(date: DateTime(2026, 11, 1), assetCount: 1, aspectRatios: const [.55]),
        TimeBucket(date: DateTime(2026, 10, 24), assetCount: 2, aspectRatios: const [1.6, .7]),
      ],
      withHeaders: true,
    );
    expect(fixture.segments.map((segment) => segment.header), [HeaderType.monthAndDay, HeaderType.monthAndDay]);
    final dateHeaders = find.byType(TimelineHeader);
    expect(dateHeaders, findsNWidgets(2));
    final firstHeader = tester.getRect(dateHeaders.first);
    final secondHeader = tester.getRect(dateHeaders.last);
    final firstPhoto = tester.getRect(_tile(assets.first.id));
    final nextPhoto = tester.getRect(_tile(assets[1].id));
    expect(firstPhoto.top - firstHeader.bottom, closeTo(_spacing, 1e-6));
    expect(nextPhoto.top - secondHeader.bottom, closeTo(_spacing, 1e-6));
    expect(secondHeader.top - firstPhoto.bottom, inInclusiveRange(0, _spacing + 1e-6));
    await _capture(tester, fixture.boundary, name: 'month-boundaries-390x844');
    final button = find.descendant(of: dateHeaders.at(1), matching: find.byType(IconButton));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(fixture.container.read(multiSelectProvider).selectedAssets, unorderedEquals(assets.skip(1)));
    expect(fixture.container.read(multiSelectProvider).selectedAssets, isNot(contains(assets.first)));
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(390, 844), const Size(320, 568), const Size(844, 390)]) {
    testWidgets('mosaic and headers fit $size with enlarged text without RenderFlex overflow', (tester) async {
      final assets = [for (var i = 0; i < 12; i++) _asset('sized-$i', ratio: i.isEven ? .6 : 1.4)];
      final fixture = await mount(
        tester,
        assets,
        size: size,
        textScale: 1.6,
        buckets: [
          TimeBucket(
            date: DateTime(2026, 11, 1),
            assetCount: assets.length,
            aspectRatios: assets.map((asset) => asset.width! / asset.height!).toList(),
          ),
        ],
        withHeaders: true,
      );
      for (final tile in tester.widgetList<ThumbnailTile>(find.byType(ThumbnailTile))) {
        expect(tester.getRect(_tile(tile.asset!.id)).right, lessThanOrEqualTo(size.width + 1e-6));
      }
      await _capture(tester, fixture.boundary, name: 'mosaic-${size.width.toInt()}x${size.height.toInt()}-text160');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a 50000-item mosaic keeps image loading and render children bounded while scrolling', (tester) async {
    final sourceRequests = <(int, int)>[];
    final fixture = await mount(
      tester,
      [],
      buckets: [Bucket(assetCount: 50000, aspectRatios: List.filled(50000, 1))],
      source: (offset, count) async {
        sourceRequests.add((offset, count));
        return List.generate(math.min(count, 50000 - offset), (index) => _asset('large-${offset + index}'));
      },
    );
    expect(find.byType(ThumbnailTile).evaluate().length, lessThan(50));
    expect(sourceRequests.every((request) => request.$2 <= 1024), isTrue);
    fixture.scroll.jumpTo(100000);
    await tester.pump();
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pumpAndSettle();
    expect(find.byType(ThumbnailTile).evaluate().length, lessThan(50));
    expect(sourceRequests.any((request) => request.$1 > 0), isTrue);
    expect(sourceRequests.every((request) => request.$2 <= 1024), isTrue);
    expect(requests.length, lessThan(100));
    expect(tester.takeException(), isNull);
  });
}
