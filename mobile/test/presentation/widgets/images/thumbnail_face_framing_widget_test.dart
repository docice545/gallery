import 'dart:async';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/local_image_api.g.dart';
import 'package:immich_mobile/platform/remote_image_api.g.dart';
import 'package:immich_mobile/presentation/widgets/images/face_aware_thumbnail_scope.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/local_image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/live_photo_autoplay.dart';
import 'package:immich_mobile/presentation/widgets/timeline/live_photo_scope.widget.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/thumbnail_framing.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';

import '../../../test_utils.dart';
import '../../../widget_tester_extensions.dart';

const _topFace = Rect.fromLTRB(0.32, 0.02, 0.64, 0.20);
const _bottomFace = Rect.fromLTRB(0.32, 0.90, 0.64, 0.99);
const _tapKey = Key('framed-tile-tap');

class _CountingMemoryImage extends MemoryImage {
  const _CountingMemoryImage(super.bytes, {required this.onLoad});

  final VoidCallback onLoad;

  @override
  ImageStreamCompleter loadImage(MemoryImage key, ImageDecoderCallback decode) {
    onLoad();
    return super.loadImage(key, decode);
  }
}

Future<Uint8List> _portraitPng() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 100, 200), Paint()..color = const Color(0xFF0000FF));
  canvas.drawRect(const Rect.fromLTRB(32, 4, 64, 40), Paint()..color = const Color(0xFFFF0000));
  canvas.drawRect(const Rect.fromLTRB(32, 180, 64, 198), Paint()..color = const Color(0xFF008000));
  final picture = recorder.endRecording();
  final image = await picture.toImage(100, 200);
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Future<Uint8List> _capture(WidgetTester tester, GlobalKey key) async {
  return (await tester.runAsync(() async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return bytes!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }))!;
}

List<int> _pixel(Uint8List bytes, int x, int y) => bytes.sublist((y * 100 + x) * 4, (y * 100 + x) * 4 + 4);

class _PlaybackLog {
  int starts = 0;
  int stops = 0;
  VoidCallback? complete;
}

class _Preview extends StatefulWidget {
  const _Preview({required this.log, required this.onCompleted});
  final _PlaybackLog log;
  final VoidCallback onCompleted;

  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  @override
  void initState() {
    super.initState();
    widget.log.starts++;
  }

  @override
  Widget build(BuildContext context) {
    widget.log.complete = widget.onCompleted;
    return const ColoredBox(color: Colors.green);
  }

  @override
  void dispose() {
    widget.log.stops++;
    super.dispose();
  }
}

void main() {
  late Drift db;
  final localRequests = <List<Object?>>[];
  const remoteRequest = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.RemoteImageApi.requestImage',
    RemoteImageApi.pigeonChannelCodec,
  );
  const remoteCancel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.RemoteImageApi.cancelRequest',
    RemoteImageApi.pigeonChannelCodec,
  );
  const localRequest = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.LocalImageApi.requestImage',
    LocalImageApi.pigeonChannelCodec,
  );
  const localCancel = BasicMessageChannel<Object?>(
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
    messenger.setMockDecodedMessageHandler(remoteRequest, (_) async => <Object?>[null]);
    messenger.setMockDecodedMessageHandler(remoteCancel, (_) async => <Object?>[null]);
    messenger.setMockDecodedMessageHandler(localRequest, (message) async {
      localRequests.add((message! as List<Object?>).toList());
      return <Object?>[null];
    });
    messenger.setMockDecodedMessageHandler(localCancel, (_) async => <Object?>[null]);
  });

  setUp(() async {
    localRequests.clear();
    await SettingsRepository.instance.clear(SettingsKey.values);
  });

  tearDownAll(() async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockDecodedMessageHandler(remoteRequest, null);
    messenger.setMockDecodedMessageHandler(remoteCancel, null);
    messenger.setMockDecodedMessageHandler(localRequest, null);
    messenger.setMockDecodedMessageHandler(localCancel, null);
    await Store.clear();
    await SettingsRepository.reset();
    await db.close();
  });

  Future<void> mountTile(
    WidgetTester tester,
    RemoteAsset asset, {
    required Stream<List<Rect>> Function() faces,
    bool faceScope = true,
    _PlaybackLog? log,
    VoidCallback? onTap,
  }) async {
    final tile = Consumer(
      builder: (context, ref, _) => Center(
        child: SizedBox.square(
          dimension: 160,
          child: GestureDetector(
            key: _tapKey,
            onTap: onTap,
            onLongPress: () => ref.read(multiSelectProvider.notifier).toggleAssetSelection(asset),
            child: ThumbnailTile(asset, heroOffset: 7, showStackIndicator: true),
          ),
        ),
      ),
    );
    final scoped = faceScope ? FaceAwareThumbnailScope(child: tile) : tile;
    await tester.pumpConsumerWidgetRaw(
      log == null
          ? scoped
          : TimelineLivePhotoScope(
              previewBuilder: (_, onCompleted) => _Preview(log: log, onCompleted: onCompleted),
              child: scoped,
            ),
      overrides: [
        thumbnailFaceBoundsProvider.overrideWith((_, assetId) {
          expect(assetId, asset.id);
          return faces();
        }),
        stackCountsProvider.overrideWith((_) => Stream.value({'stack-one': 3})),
      ],
    );
    await tester.pump();
  }

  RemoteAsset motion({String id = 'framed-motion'}) => TestUtils.createRemoteAsset(
    id: id,
    width: 900,
    height: 1600,
  ).copyWith(livePhotoVideoId: '$id-video', stackId: 'stack-one');

  testWidgets('known top face repaints into view using the same decoded PNG and Thumbnail state', (tester) async {
    final bytes = (await tester.runAsync(_portraitPng))!;
    var loads = 0;
    final image = _CountingMemoryImage(bytes, onLoad: () => loads++);
    final faces = ValueNotifier<List<Rect>>(const []);
    addTearDown(faces.dispose);
    final captureKey = GlobalKey();
    await tester.pumpConsumerWidgetRaw(
      Center(
        child: RepaintBoundary(
          key: captureKey,
          child: SizedBox.square(
            dimension: 100,
            child: ValueListenableBuilder<List<Rect>>(
              valueListenable: faces,
              builder: (_, value, _) => Thumbnail(imageProvider: image, faces: value),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() => precacheImage(image, tester.element(find.byType(Thumbnail))));
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(Thumbnail));
    expect(loads, 1);
    expect(_pixel(await _capture(tester, captureKey), 48, 12), [0, 0, 255, 255]);

    faces.value = const [_topFace];
    await tester.pump();

    expect(_pixel(await _capture(tester, captureKey), 48, 12), [255, 0, 0, 255]);
    expect(tester.state(find.byType(Thumbnail)), same(state));
    expect(loads, 1, reason: 'face metadata changes only repaint the existing image');
    expect(tester.takeException(), isNull);
  });

  testWidgets('contain fallback paints both faces when their union cannot fit a cover crop', (tester) async {
    final bytes = (await tester.runAsync(_portraitPng))!;
    final image = MemoryImage(bytes);
    final captureKey = GlobalKey();
    await tester.pumpConsumerWidgetRaw(
      Center(
        child: RepaintBoundary(
          key: captureKey,
          child: SizedBox.square(
            dimension: 100,
            child: Thumbnail(imageProvider: image, faces: const [_topFace, _bottomFace]),
          ),
        ),
      ),
    );
    await tester.runAsync(() => precacheImage(image, tester.element(find.byType(Thumbnail))));
    await tester.pumpAndSettle();
    final pixels = await _capture(tester, captureKey);
    expect(_pixel(pixels, 48, 8), [255, 0, 0, 255]);
    expect(_pixel(pixels, 48, 95), [0, 128, 0, 255]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scoped faces reach still and motion previews without changing Hero, badges or tapping', (tester) async {
    final asset = motion();
    const faces = [_topFace];
    final log = _PlaybackLog();
    var taps = 0;
    await mountTile(tester, asset, faces: () => Stream.value(faces), log: log, onTap: () => taps++);
    final tileRect = tester.getRect(find.byKey(_tapKey));
    final heroRect = tester.getRect(find.byType(Hero));
    expect(tester.widget<Thumbnail>(find.byType(Thumbnail)).faces, same(faces));
    expect(tester.widget<TimelineLivePhotoTile>(find.byType(TimelineLivePhotoTile)).faces, same(faces));
    expect(tester.widget<Hero>(find.byType(Hero)).tag, '${asset.heroTag}_7');
    expect(find.text(' 3'), findsOneWidget);
    expect(find.byIcon(Icons.burst_mode_rounded), findsOneWidget);
    expect(find.byIcon(Icons.motion_photos_on_rounded), findsOneWidget);

    await tester.pump(livePhotoSettlingDelay);
    await tester.pump();
    expect(log.starts, 1);
    expect(tester.getRect(find.byKey(_tapKey)), tileRect);
    expect(tester.getRect(find.byType(Hero)), heroRect);
    await tester.tap(find.byKey(_tapKey));
    await tester.pump();
    expect(taps, 1);
    expect(log.stops, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selection preserves framing, stack badge and the normal inset around the Hero', (tester) async {
    final asset = motion();
    const faces = [_topFace];
    final log = _PlaybackLog();
    await mountTile(tester, asset, faces: () => Stream.value(faces), log: log);
    await tester.pump(livePhotoSettlingDelay);
    await tester.pump();
    expect(log.starts, 1);
    await tester.longPress(find.byKey(_tapKey));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(tester.element(find.byType(ThumbnailTile)));
    expect(container.read(multiSelectProvider).selectedAssets, contains(asset));
    expect(tester.getSize(find.byType(Hero)), const Size.square(148));
    expect(tester.widget<Thumbnail>(find.byType(Thumbnail)).faces, same(faces));
    expect(find.text(' 3'), findsOneWidget);
    expect(log.stops, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('face arrival during playback keeps the lease and completion stays one-shot after later updates', (
    tester,
  ) async {
    final stream = StreamController<List<Rect>>();
    addTearDown(stream.close);
    final log = _PlaybackLog();
    await mountTile(tester, motion(), faces: () => stream.stream, log: log);
    await tester.pump(livePhotoSettlingDelay);
    await tester.pump();
    expect(log.starts, 1);
    final previewState = tester.state(find.byType(_Preview));

    const faces = [_topFace];
    stream.add(faces);
    await tester.pump();
    await tester.pump();
    expect(tester.widget<Thumbnail>(find.byType(Thumbnail)).faces, same(faces));
    expect(tester.widget<TimelineLivePhotoTile>(find.byType(TimelineLivePhotoTile)).faces, same(faces));
    expect(tester.state(find.byType(_Preview)), same(previewState));
    expect(log.starts, 1);
    expect(log.stops, 0);

    log.complete!();
    await tester.pump();
    expect(log.stops, 1);
    stream.add(const [_bottomFace]);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(log.starts, 1, reason: 'new focal metadata must not rearm an already consumed viewport');
    expect(find.byType(_Preview), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('thumbnails outside the face scope never subscribe to face metadata', (tester) async {
    var subscriptions = 0;
    await mountTile(
      tester,
      motion(),
      faceScope: false,
      faces: () {
        subscriptions++;
        return Stream.value(const [_topFace]);
      },
    );
    await tester.pump(const Duration(seconds: 1));
    expect(subscriptions, 0);
    expect(tester.widget<Thumbnail>(find.byType(Thumbnail)).faces, isEmpty);
    expect(tester.widget<TimelineLivePhotoTile>(find.byType(TimelineLivePhotoTile)).faces, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('local face-aware decode requests preserve portrait aspect within the existing size budget', (
    tester,
  ) async {
    final stream = StreamController<List<Rect>>();
    addTearDown(stream.close);
    final asset = motion(id: 'local-backed-motion').copyWith(localId: 'local-photo');
    await mountTile(tester, asset, faces: () => stream.stream);
    expect(localRequests.last.sublist(2, 4), [320, 320]);

    stream.add(const [_topFace]);
    await tester.pump();
    await tester.pump();
    final provider = tester.widget<Thumbnail>(find.byType(Thumbnail)).imageProvider! as LocalThumbProvider;
    expect(provider.size, const Size(180, 320));
    expect(localRequests.last.sublist(2, 4), [180, 320]);
    expect(provider.size.width / provider.size.height, 900 / 1600);
    expect(provider.size.longestSide, 320);
    expect(tester.takeException(), isNull);
  });
}
